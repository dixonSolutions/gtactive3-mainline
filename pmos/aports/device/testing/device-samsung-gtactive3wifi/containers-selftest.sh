#!/bin/sh
# Offline self-test of podman with the preinstalled Alpine image, for the
# calling user: run it as root (rootful) and as the normal user (rootless,
# from that user's session, e.g. "systemd-run --user --machine=USER@ --wait
# --pipe /usr/libexec/gtactive3wifi/containers-selftest" as root).
# Prints one line per check; the exit status is the number of failures.
set -u

DIR=/usr/lib/gtactive3wifi/container-images/alpine
read -r IMAGE < "$DIR/tags"
fail=0
err=$(mktemp)
trap 'rm -f "$err"' EXIT
ok() { echo "PASS $*"; }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }
# stdout of a container; its stderr is shown only when a check fails
run() { podman run --rm --pull=never "$@" 2>"$err"; }

who=$(id -un)
echo "user $who (uid $(id -u)), $(podman --version)"

if [ "$(id -u)" != 0 ]; then
	for f in subuid subgid; do
		if grep -q "^$who:" /etc/$f; then
			ok "/etc/$f: $(grep "^$who:" /etc/$f)"
		else
			bad "/etc/$f has no range for $who (usermod --add-${f}s)"
		fi
	done
fi

info=$(podman info --format '{{.Store.GraphDriverName}} cgroups-{{.Host.CgroupsVersion}} {{.Host.OCIRuntime.Name}} {{.Host.NetworkBackend}} rootless={{.Host.Security.Rootless}}' 2>&1)
case "$info" in
overlay\ cgroups-v2\ *) ok "podman info: $info" ;;
*) bad "podman info: $info" ;;
esac

# the user unit / system service may still be loading it right after login
podman image exists "$IMAGE" || /usr/libexec/gtactive3wifi/container-images >/dev/null
if podman image exists "$IMAGE"; then
	ok "preinstalled $IMAGE"
else
	bad "$IMAGE is not in the store"
fi

want=$(cat "$DIR/alpine-release")
for net in none default; do
	got=$(run --network="$net" "$IMAGE" cat /etc/alpine-release)
	if [ "$got" = "$want" ]; then
		ok "run --network=$net: alpine $got"
	else
		bad "run --network=$net: $got $(tail -n 3 "$err")"
	fi
done

# copy-up of a file owned by another user in the image (rootless: needs the
# subordinate IDs), and the container's view of its user
got=$(run --network=none "$IMAGE" \
	sh -c 'echo test >> /etc/shadow && id -u && stat -c %g /etc/shadow' | tr '\n' ' ')
if [ "$got" = "0 42 " ]; then
	ok "copy-up of /etc/shadow (root:shadow)"
else
	bad "copy-up: $got $(tail -n 3 "$err")"
fi

exit "$fail"
