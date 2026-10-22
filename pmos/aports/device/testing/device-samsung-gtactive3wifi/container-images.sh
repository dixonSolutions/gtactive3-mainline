#!/bin/sh
# Put the container images preinstalled in /usr (OCI layouts, see mkoci.sh)
# into the podman store of the calling user: root's
# (/var/lib/containers/storage, gtactive3wifi-container-images.service) or a
# user's own (~/.local/share/containers, the user unit of the same name), so
# "podman run alpine" works offline from the first boot, rootless and
# rootful. A copy per store is needed: the layers of a rootless store belong
# to the user's subordinate IDs, which differ per user, and /usr is read-only.
#
# Each image version is loaded once; removing it afterwards (podman rmi)
# is respected until a /usr update brings a new version.
set -eu

IMAGES=/usr/lib/gtactive3wifi/container-images
if [ "$(id -u)" = 0 ]; then
	state=/var/lib/gtactive3wifi/container-images
else
	state=${XDG_STATE_HOME:-$HOME/.local/state}/gtactive3wifi/container-images
fi
mkdir -p "$state"

for dir in "$IMAGES"/*/; do
	dir=${dir%/}
	[ -f "$dir/index.json" ] || continue
	id=$(sha256sum "$dir/index.json" | cut -d' ' -f1)
	[ -e "$state/$id" ] && continue
	# the name the image is stored under, then the extra tags
	read -r ref < "$dir/tags"
	podman pull --quiet "oci:$dir:$ref" >/dev/null
	while read -r tag; do
		[ "$tag" = "$ref" ] || podman tag "$ref" "$tag"
	done < "$dir/tags"
	: > "$state/$id"
	echo "${dir##*/}: $(tr '\n' ' ' < "$dir/tags")"
done
