# Mali-G72 (panfrost, Bifrost v6): no AFBC. This reaches the compositors
# that greetd starts (phoc for phrog and the Phosh session: greetd runs
# session commands through /etc/profile, environment.d does not apply).
# The compositor's choice is the one that matters: Mesa allocates every
# client's window buffers with the first modifier the compositor lists,
# AFBC 32x8, even in clients that have PAN_MESA_DEBUG=noafbc, and v6 cannot
# render those reliably (its 16x16 tiles split the 32x8 superblocks:
# DATA_INVALID_FAULT fragment jobs, stale regions in app windows).
: "${PAN_MESA_DEBUG:=noafbc}"
export PAN_MESA_DEBUG
