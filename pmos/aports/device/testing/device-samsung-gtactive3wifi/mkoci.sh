#!/bin/sh
# Make a single-layer OCI image layout (a directory podman can load) from a
# root file system tarball, without a registry or a container runtime: the
# tarball (e.g. Alpine's minirootfs, the same file the docker.io/library/
# alpine image is built from) becomes the layer as it is.
#
# Usage: mkoci.sh ROOTFS.tar.gz OUTDIR REF CREATED ARCH
#   REF      image name stored in the index (org.opencontainers.image.ref.name)
#   CREATED  RFC 3339 time of the rootfs release, so the output is reproducible
#   ARCH     OCI architecture (arm64, amd64, ...)
set -eu

[ $# -eq 5 ] || { echo "usage: $0 ROOTFS.tar.gz OUTDIR REF CREATED ARCH" >&2; exit 1; }
rootfs=$1 out=$2 ref=$3 created=$4 arch=$5

sha() { sha256sum "$1" | cut -d' ' -f1; }
size() { wc -c < "$1" | tr -d ' '; }
# store a blob under its digest; sets $digest and $bytes
blob() {
	digest=$(sha "$1")
	bytes=$(size "$1")
	cp "$1" "$out/blobs/sha256/$digest"
}

mkdir -p "$out/blobs/sha256"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

diff_id=$(gzip -dc "$rootfs" | sha256sum | cut -d' ' -f1)
blob "$rootfs"
layer=$digest layer_size=$bytes

case "$arch" in
arm64) platform='"architecture":"arm64","os":"linux","variant":"v8"' ;;
*) platform="\"architecture\":\"$arch\",\"os\":\"linux\"" ;;
esac

# The same configuration as the docker.io/library/alpine images
printf '{"created":"%s",%s,"config":{"Env":["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],"Cmd":["/bin/sh"]},"rootfs":{"type":"layers","diff_ids":["sha256:%s"]},"history":[{"created":"%s","created_by":"ADD %s /"}]}' \
	"$created" "$platform" "$diff_id" "$created" "${rootfs##*/}" > "$tmp/config"
blob "$tmp/config"
config=$digest config_size=$bytes

printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"sha256:%s","size":%s},"layers":[{"mediaType":"application/vnd.oci.image.layer.v1.tar+gzip","digest":"sha256:%s","size":%s}]}' \
	"$config" "$config_size" "$layer" "$layer_size" > "$tmp/manifest"
blob "$tmp/manifest"
manifest=$digest manifest_size=$bytes

printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:%s","size":%s,"platform":{%s},"annotations":{"org.opencontainers.image.ref.name":"%s"}}]}' \
	"$manifest" "$manifest_size" "$platform" "$ref" > "$out/index.json"
printf '{"imageLayoutVersion":"1.0.0"}' > "$out/oci-layout"
