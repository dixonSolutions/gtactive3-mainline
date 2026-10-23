# shellcheck shell=bash
# The shared USB debug tool (exynos-linux/usb-debug): root console over USB,
# the tab CLI, udev and network setup on this PC. Where it comes from and
# whether to ask are in config.toml [debug_tool] (scripts/config).
#
# OPT_DEBUG_TOOLS: "" = as config.toml says (ask, default yes), 1 = install
# without asking (--debug-tools), 0 = skip (--no-debug-tools). The
# environment can preset it (GTA3_DEBUG_TOOLS, e.g. 0 in the installer tests)
# and point at another install script (GTA3_DEBUG_TOOL_SETUP).

dt_cfg() { "$GTA3_REPO/scripts/config" get "debug_tool.$1"; }

debug_tool_install() {
	local setup version f device
	setup=${GTA3_DEBUG_TOOL_SETUP:-$(dt_cfg setup)} version=$(dt_cfg version)
	device=$("$GTA3_REPO/scripts/config" get device.id)
	f=$CACHE_DIR/usb-debug-install.sh
	info "USB debug tool from $(dt_cfg remote)${version:+ ($version)}"
	if dry; then
		info "(dry run) would download $setup and run it with --yes --device=$device"
		return 0
	fi
	curl -fsSL --retry 3 -o "$f.part" "$setup" && mv "$f.part" "$f" ||
		{ warn "could not download $setup: the USB debug tool is not installed (./setup.sh debug-tools retries)"; return 1; }
	sh "$f" --yes --device="$device" ${version:+--version="$version"} ||
		{ warn "the USB debug tool's installer failed (log above); ./setup.sh debug-tools retries"; return 1; }
	state_set DEBUG_TOOL installed
	ok "USB debug tool installed"
}

# Offer it once per PC (remembered in the state), or as the user asked
debug_tool_offer() {
	local ask
	case ${OPT_DEBUG_TOOLS:-${GTA3_DEBUG_TOOLS:-}} in
		0) return 0 ;;
		1) debug_tool_install || true; return 0 ;;
	esac
	[ "$(state_get DEBUG_TOOL)" = installed ] && return 0
	[ "$(state_get DEBUG_TOOL)" = declined ] && return 0
	ask=$(dt_cfg ask)
	if [ "$ask" = false ] || ask_yn "Install the USB debug tool (root console over USB, the tab command) on this PC?" y; then
		debug_tool_install || true
	else
		state_set DEBUG_TOOL declined
		info "skipped; ./setup.sh debug-tools installs it later"
	fi
}
