# shellcheck shell=bash
# Terminal output, logging, questions and waits for the SM-T570 installer.
#
# Everything printed also goes to $LOG_FILE (without colours), so a failed
# run can be read back later. Colours only on a TTY and without NO_COLOR.

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
	C_B=$'\e[1m' C_DIM=$'\e[2m' C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m'
	C_C=$'\e[36m' C_0=$'\e[0m'
else
	C_B='' C_DIM='' C_R='' C_G='' C_Y='' C_C='' C_0=''
fi

: "${YES:=0}" "${YES_WIPE:=0}" "${DRY_RUN:=0}" "${VERBOSE:=0}"
LOG_FILE=${LOG_FILE:-/dev/null}
STEP_N=0

_log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE" 2>/dev/null || true; }
say() { printf '%s\n' "$*"; _log "$*"; }
info() { printf '%s\n' "  $*"; _log "  $*"; }
ok() { printf '%s\n' "  ${C_G}OK${C_0} $*"; _log "  OK $*"; }
warn() { printf '%s\n' "  ${C_Y}WARNING:${C_0} $*" >&2; _log "  WARNING: $*"; }
err() { printf '%s\n' "${C_R}ERROR:${C_0} $*" >&2; _log "ERROR: $*"; }
dbg() { [ "$VERBOSE" = 1 ] && printf '%s\n' "  ${C_DIM}$*${C_0}" >&2; _log "  debug: $*"; return 0; }
die() {
	err "$*"
	[ "$LOG_FILE" = /dev/null ] || printf '%s\n' "Log: $LOG_FILE" >&2
	exit 1
}

# A numbered step: step "Check the tablet"
step() {
	STEP_N=$((STEP_N + 1))
	printf '\n%s\n' "${C_B}${C_C}Step $STEP_N: $*${C_0}"
	_log "== Step $STEP_N: $*"
}

# A framed box, for "What you'll see on the tablet" and similar:
#   box "Title" "line 1" "line 2" ...
box() {
	local t=$1 l w=0
	shift
	for l in "$t" "$@"; do [ "${#l}" -gt "$w" ] && w=${#l}; done
	[ "$w" -gt 74 ] && w=74
	printf '  %s\n' "${C_B}+$(printf '%*s' $((w + 2)) '' | tr ' ' -)+${C_0}"
	printf '  %s %-*s %s\n' "${C_B}|" "$w" "$t" "|${C_0}"
	printf '  %s\n' "${C_B}+$(printf '%*s' $((w + 2)) '' | tr ' ' -)+${C_0}"
	for l in "$@"; do printf '  | %-*s |\n' "$w" "$l"; done
	printf '  +%s+\n' "$(printf '%*s' $((w + 2)) '' | tr ' ' -)"
	_log "[$t] $*"
}
tablet_box() { box "What you'll see on the tablet" "$@"; }
todo_box() { box "Do this now" "$@"; }

# Recovery hints used by many waits
HINT_FORCE_RESTART="Force restart: hold Power + Volume Down for 7-10 s."
HINT_DOWNLOAD="Download mode: force restart, then at once hold Volume Up + Volume Down and plug in the USB cable; press Volume Up at the warning."

# ask_yn "Question?" [y|n]: 0 = yes. --yes answers the default "yes" questions.
ask_yn() {
	local q=$1 def=${2:-y} a hint
	[ "$def" = y ] && hint="[Y/n]" || hint="[y/N]"
	if [ "$YES" = 1 ]; then
		say "  $q $hint $( [ "$def" = y ] && echo yes || echo no) (--yes)"
		[ "$def" = y ]
		return
	fi
	while true; do
		printf '  %s %s ' "${C_B}$q${C_0}" "$hint"
		read -r a < /dev/tty || a=
		a=${a:-$def}
		case $a in
			[Yy]|[Yy][Ee][Ss]) _log "Q: $q -> yes"; return 0 ;;
			[Nn]|[Nn][Oo]) _log "Q: $q -> no"; return 1 ;;
		esac
	done
}

# choose "Title" DEFAULT "option 1" "option 2" ...: prints the chosen number
# (1-based). Non-interactive: DEFAULT, or $GTA3_CHOICE if set.
choose() {
	local t=$1 def=$2 i=1 a o
	shift 2
	if [ "$YES" = 1 ]; then
		a=${GTA3_CHOICE:-$def}
		_log "choose: $t -> $a (auto)"
		echo "$a"
		return
	fi
	{
		printf '\n  %s\n' "${C_B}$t${C_0}"
		for o in "$@"; do printf '    %d) %s\n' "$i" "$o"; i=$((i + 1)); done
	} > /dev/tty
	while true; do
		printf '  Choice [%s]: ' "$def" > /dev/tty
		read -r a < /dev/tty || a=
		a=${a:-$def}
		case $a in
			''|*[!0-9]*) ;;
			*) if [ "$a" -ge 1 ] && [ "$a" -le $# ]; then _log "choose: $t -> $a"; echo "$a"; return; fi ;;
		esac
	done
}

# confirm_typed WORD "what happens": the user must type WORD. Never implied by
# --yes; non-interactive runs need --yes-wipe as well.
confirm_typed() {
	local w=$1 a
	shift
	box "This cannot be undone" "$@"
	if [ "$YES" = 1 ]; then
		[ "$YES_WIPE" = 1 ] || die "this step needs a typed confirmation ($w); non-interactive runs need --yes-wipe"
		_log "typed confirmation $w -> auto (--yes-wipe)"
		return 0
	fi
	printf '  Type %s to continue, anything else stops: ' "${C_B}${C_R}$w${C_0}"
	read -r a < /dev/tty || a=
	[ "$a" = "$w" ] || die "not confirmed, nothing was changed"
	_log "typed confirmation $w"
}

# act "description" CMD ARGS...: run a command that changes something (the
# tablet, the host); --dry-run only prints it.
act() {
	local d=$1
	shift
	if [ "$DRY_RUN" = 1 ]; then
		printf '  %s %s\n' "${C_Y}[dry-run]${C_0}" "$d: $*"
		_log "[dry-run] $d: $*"
		return 0
	fi
	_log "run: $d: $*"
	"$@"
}

# True when --dry-run skipped a step whose result the next step needs.
dry() { [ "$DRY_RUN" = 1 ]; }

# wait_for "what we wait for" "how to recover" TIMEOUT CHECK [ARGS...]
# Polls CHECK every 2 s (GTA3_POLL to change). On timeout it asks whether to
# keep waiting (interactive) or fails (non-interactive).
wait_for() {
	local what=$1 how=$2 tmo=$3 t0 now poll=${GTA3_POLL:-2}
	shift 3
	# the test suite shortens every wait (GTA3_TIMEOUT_PCT)
	tmo=$(( tmo * ${GTA3_TIMEOUT_PCT:-100} / 100 ))
	[ "$tmo" -ge 1 ] || tmo=1
	if dry; then
		printf '  %s\n' "${C_Y}[dry-run]${C_0} would wait for: $what"
		return 0
	fi
	say "  ${C_DIM}Waiting for: $what (up to $((tmo / 60)) min $((tmo % 60)) s; Ctrl+C stops the installer)${C_0}"
	[ -n "$how" ] && say "  ${C_DIM}If nothing happens: $how${C_0}"
	t0=$(date +%s)
	while true; do
		if "$@"; then
			_log "waited for: $what ($(( $(date +%s) - t0 )) s)"
			return 0
		fi
		now=$(date +%s)
		if [ $((now - t0)) -ge "$tmo" ]; then
			if [ "$YES" = 1 ] || ! ask_yn "Still waiting for: $what. Keep waiting?" y; then
				err "timed out waiting for: $what"
				return 1
			fi
			t0=$(date +%s)
		fi
		if [ -t 1 ] && [ "$YES" != 1 ]; then
			printf '\r  ... %ds ' $((now - t0))
		fi
		sleep "$poll"
	done
}

human_bytes() {
	awk -v b="$1" 'BEGIN { split("B KiB MiB GiB TiB", u); i = 1
		while (b >= 1024 && i < 5) { b /= 1024; i++ }
		printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i] }'
}
