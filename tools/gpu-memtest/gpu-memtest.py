#!/usr/bin/python3
# GPU memory integrity test for panfrost (runs on the tablet, root or a user
# with access to /dev/dri/renderD128): uploads random textures, copies them on
# the GPU with a texelFetch pass into an FBO, reads the result back and
# compares byte for byte. Mismatches are reported with their granularity
# (cache lines, pages), which tells cache/coherency problems apart from
# shader or driver bugs. Uses the system Mesa through ctypes (EGL
# surfaceless), so it tests exactly what GNOME uses.
#
#   gpu-memtest.py [ROUNDS] [SIZE]      (default 50 rounds, 1024)
import ctypes as C
import os
import sys
import time

ROUNDS = int(sys.argv[1]) if len(sys.argv) > 1 else 50
SIZE = int(sys.argv[2]) if len(sys.argv) > 2 else 1024

egl = C.CDLL("libEGL.so.1")
gl = C.CDLL("libGLESv2.so.2")

EGL_PLATFORM_SURFACELESS_MESA = 0x31DD
EGL_NONE = 0x3038
EGL_RENDERABLE_TYPE = 0x3040
EGL_OPENGL_ES3_BIT = 0x40
EGL_SURFACE_TYPE = 0x3033
EGL_PBUFFER_BIT = 0x1
EGL_CONTEXT_MAJOR_VERSION = 0x3098
EGL_OPENGL_ES_API = 0x30A0
EGL_NO_SURFACE = C.c_void_p(0)

egl.eglGetPlatformDisplay.restype = C.c_void_p
egl.eglGetPlatformDisplay.argtypes = [C.c_uint, C.c_void_p, C.c_void_p]
egl.eglInitialize.argtypes = [C.c_void_p, C.c_void_p, C.c_void_p]
egl.eglChooseConfig.argtypes = [C.c_void_p, C.c_void_p, C.c_void_p, C.c_int, C.c_void_p]
egl.eglCreateContext.restype = C.c_void_p
egl.eglCreateContext.argtypes = [C.c_void_p, C.c_void_p, C.c_void_p, C.c_void_p]
egl.eglMakeCurrent.argtypes = [C.c_void_p, C.c_void_p, C.c_void_p, C.c_void_p]
egl.eglGetError.restype = C.c_int
gl.glGetString.restype = C.c_char_p
gl.glCreateShader.restype = C.c_uint
gl.glCreateProgram.restype = C.c_uint
gl.glGetUniformLocation.restype = C.c_int


def die(msg):
    sys.exit(f"{msg} (egl error 0x{egl.eglGetError():x})")


dpy = egl.eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, None, None)
if not dpy or not egl.eglInitialize(dpy, None, None):
    die("eglInitialize")
egl.eglBindAPI(EGL_OPENGL_ES_API)
attr = (C.c_int * 5)(EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_NONE)
cfg = C.c_void_p()
n = C.c_int()
if not egl.eglChooseConfig(dpy, attr, C.byref(cfg), 1, C.byref(n)) or n.value < 1:
    # surfaceless may expose no pbuffer configs: any ES3 config is fine
    attr = (C.c_int * 3)(EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_NONE)
    if not egl.eglChooseConfig(dpy, attr, C.byref(cfg), 1, C.byref(n)) or n.value < 1:
        die("eglChooseConfig")
cattr = (C.c_int * 3)(EGL_CONTEXT_MAJOR_VERSION, 3, EGL_NONE)
ctx = egl.eglCreateContext(dpy, cfg, None, cattr)
if not ctx:
    die("eglCreateContext")
if not egl.eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx):
    die("eglMakeCurrent")
print("renderer:", gl.glGetString(0x1F01).decode(), "|", gl.glGetString(0x1F02).decode(), flush=True)

GL_TEXTURE_2D = 0x0DE1
GL_RGBA = 0x1908
GL_RGBA8 = 0x8058
GL_UNSIGNED_BYTE = 0x1401
GL_FRAMEBUFFER = 0x8D40
GL_COLOR_ATTACHMENT0 = 0x8CE0
GL_FRAMEBUFFER_COMPLETE = 0x8CD5
GL_TEXTURE_MIN_FILTER = 0x2801
GL_TEXTURE_MAG_FILTER = 0x2800
GL_NEAREST = 0x2600
GL_VERTEX_SHADER = 0x8B31
GL_FRAGMENT_SHADER = 0x8B30
GL_COMPILE_STATUS = 0x8B81
GL_LINK_STATUS = 0x8B82
GL_TRIANGLES = 0x0004
GL_PACK_ALIGNMENT = 0x0D05
GL_UNPACK_ALIGNMENT = 0x0CF5

VS = b"""#version 300 es
void main() {
    vec2 p = vec2(float((gl_VertexID & 1) << 2) - 1.0, float((gl_VertexID & 2) << 1) - 1.0);
    gl_Position = vec4(p, 0.0, 1.0);
}
"""
# exact copy, plus a per-round constant XORed in so every round's output
# differs from the input buffer (a stale read of an old buffer shows up)
FS = b"""#version 300 es
precision highp float;
precision highp int;
uniform highp sampler2D t;
uniform uint k;
out vec4 o;
void main() {
    uvec4 c = uvec4(texelFetch(t, ivec2(gl_FragCoord.xy), 0) * 255.0 + 0.5);
    c ^= uvec4(k & 255u, (k >> 8) & 255u, (k >> 16) & 255u, (k >> 24) & 255u);
    o = vec4(c) / 255.0;
}
"""


def shader(kind, src):
    s = gl.glCreateShader(kind)
    p = C.c_char_p(src)
    gl.glShaderSource(s, 1, C.byref(p), None)
    gl.glCompileShader(s)
    ok = C.c_int()
    gl.glGetShaderiv(s, GL_COMPILE_STATUS, C.byref(ok))
    if not ok.value:
        log = C.create_string_buffer(4096)
        gl.glGetShaderInfoLog(s, 4096, None, log)
        sys.exit("shader: " + log.value.decode())
    return s


prog = gl.glCreateProgram()
gl.glAttachShader(prog, shader(GL_VERTEX_SHADER, VS))
gl.glAttachShader(prog, shader(GL_FRAGMENT_SHADER, FS))
gl.glLinkProgram(prog)
ok = C.c_int()
gl.glGetProgramiv(prog, GL_LINK_STATUS, C.byref(ok))
if not ok.value:
    sys.exit("link failed")
gl.glUseProgram(prog)
loc_t = gl.glGetUniformLocation(prog, b"t")
loc_k = gl.glGetUniformLocation(prog, b"k")
gl.glUniform1i(loc_t, 0)
vao = C.c_uint()
gl.glGenVertexArrays(1, C.byref(vao))
gl.glBindVertexArray(vao)
gl.glPixelStorei(GL_PACK_ALIGNMENT, 1)
gl.glPixelStorei(GL_UNPACK_ALIGNMENT, 1)


def tex(w, h, data):
    t = C.c_uint()
    gl.glGenTextures(1, C.byref(t))
    gl.glBindTexture(GL_TEXTURE_2D, t)
    gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
    gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
    gl.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, data)
    return t


def xor_expected(src, k):
    kb = k.to_bytes(4, "little")
    m = int.from_bytes(kb * (len(src) // 4), "little")
    return (int.from_bytes(src, "little") ^ m).to_bytes(len(src), "little")


bad_rounds = 0
t0 = time.time()
for r in range(ROUNDS):
    # vary the sizes so buffers get reallocated (BO cache churn)
    w = SIZE - (r % 7) * 16
    h = SIZE - (r % 5) * 16
    src = os.urandom(w * h * 4)
    k = int.from_bytes(os.urandom(4), "little")
    a = tex(w, h, src)
    b = tex(w, h, None)
    fbo = C.c_uint()
    gl.glGenFramebuffers(1, C.byref(fbo))
    gl.glBindFramebuffer(GL_FRAMEBUFFER, fbo)
    gl.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, b, 0)
    if gl.glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE:
        sys.exit("fbo incomplete")
    gl.glViewport(0, 0, w, h)
    gl.glActiveTexture(0x84C0)
    gl.glBindTexture(GL_TEXTURE_2D, a)
    gl.glUniform1ui(loc_k, C.c_uint(k))
    gl.glDrawArrays(GL_TRIANGLES, 0, 3)
    out = C.create_string_buffer(w * h * 4)
    gl.glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, out)
    got = out.raw
    exp = xor_expected(src, k)
    if got != exp:
        bad_rounds += 1
        nb = sum(1 for i in range(0, len(exp), 64) if got[i:i + 64] != exp[i:i + 64])
        npg = sum(1 for i in range(0, len(exp), 4096) if got[i:i + 4096] != exp[i:i + 4096])
        first = next(i for i in range(len(exp)) if got[i] != exp[i])
        # is the bad data the untouched input (copy skipped / stale)?
        stale = got[first:first + 64] == src[first:first + 64]
        zero = got[first:first + 64] == bytes(64)
        print(f"round {r} {w}x{h}: {nb} bad 64B lines in {npg} pages, first at byte {first} "
              f"(row {first // (w * 4)}){' = input' if stale else ''}{' = zeros' if zero else ''}",
              flush=True)
    gl.glDeleteFramebuffers(1, C.byref(fbo))
    gl.glDeleteTextures(1, C.byref(a))
    gl.glDeleteTextures(1, C.byref(b))
    err = gl.glGetError()
    if err:
        print(f"round {r}: GL error 0x{err:x}", flush=True)

dt = time.time() - t0
print(f"{ROUNDS} rounds, {bad_rounds} bad, {dt:.1f} s ({ROUNDS * SIZE * SIZE * 4 / dt / 1e6:.0f} MB/s round trip)")
sys.exit(1 if bad_rounds else 0)
