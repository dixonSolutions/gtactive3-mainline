#!/bin/sh
# Once per user: IBus Typing Booster defaults and the preinstalled GNOME
# Shell extensions for the Galaxy Tab Active3.
# The engine's schema is relocatable, so a gschema override cannot set it.
# Runs at the first login after this package is installed and never again,
# so the user's own changes stay.
stamp=${XDG_STATE_HOME:-$HOME/.local/state}/gtactive3wifi/typing-booster-defaults
[ -e "$stamp" ] && exit 0
s=org.freedesktop.ibus.engine.typing-booster:/org/freedesktop/ibus/engine/typing-booster/
gsettings set $s dictionary 'en_US'
gsettings set $s inputmethod 'NoIME'
gsettings set $s inlinecompletion 1      # complete the word inline
gsettings set $s autoselectcandidate 1   # pick the candidate when very likely
gsettings set $s recordmode 0            # learn from everything typed
gsettings set $s autocapitalize true
gsettings set $s mincharcomplete 1
# make it the active input source (also for users created before the default)
gsettings set org.gnome.desktop.input-sources sources "[('ibus', 'typing-booster'), ('xkb', 'us')]"
# preinstalled extensions on, also when the user already has a list
gsettings set org.gnome.shell disable-user-extensions false
cur=$(gsettings get org.gnome.shell enabled-extensions)
for u in blur-my-shell@aunetx touchup@mityax; do
	case "$cur" in
	*"'$u'"*) ;;
	"@as []"|"[]") cur="['$u']" ;;
	*) cur="${cur%]}, '$u']" ;;
	esac
done
gsettings set org.gnome.shell enabled-extensions "$cur"
mkdir -p "${stamp%/*}" && : > "$stamp"
