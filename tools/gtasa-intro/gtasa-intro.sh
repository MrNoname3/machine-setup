#!/bin/sh
# gtasa-intro.sh — play GTA San Andreas's intro videos under Proton.
#
#   gtasa-intro.sh %command%                        Steam launch option
#   gtasa-intro.sh apply|revert|status GAME_DIR COMPATDATA
#
# GAME_DIR holds gta-sa.exe, COMPATDATA is steamapps/compatdata/12120.
set -eu

# The Steam release (3.0) skips the intro at 32-bit colour depth; this byte is
# the depth it compares against, and 0 never matches.
EXE_OFFSET=3643388 # 0x3797fc
EXE_ORIG=15e3cfedba9a841df67d8194e7249afb493b0e10d6138fb8ebab2c136e543efb
EXE_PATCHED=9b894b1676921052066991e0ee2499123864cc44d83f0cab040e64bd1f3da247

# Wine's VideoRendererDefault hands out VMR7, which draws nothing over a
# wined3d window; at MERIT_DO_NOT_USE the graph takes the GDI Video Renderer.
FILTER='\Instance\\{6BC1CFFA-8FC1-4261-AC22-CFB4CC38DB50}]'
MERIT_WINE=01,00,80,00
MERIT_OFF=00,00,20,00

warn() { echo "gtasa-intro: $*" >&2; }

exe_set() { # exe on|off
	case $2:$(sha256sum < "$1" | cut -d' ' -f1) in
	on:"$EXE_ORIG") printf '\000' ;;
	off:"$EXE_PATCHED") printf '\040' ;;
	on:"$EXE_PATCHED" | off:"$EXE_ORIG") return 0 ;;
	*) warn "unknown gta-sa.exe build, left as it is"; return 0 ;;
	esac | dd of="$1" bs=1 seek="$EXE_OFFSET" conv=notrunc status=none
}

exe_status() {
	case $(sha256sum < "$1" | cut -d' ' -f1) in
	"$EXE_ORIG") echo "exe: original (intro skipped)" ;;
	"$EXE_PATCHED") echo "exe: patched (intro plays)" ;;
	*) echo "exe: unknown build" ;;
	esac
}

# Rewrites the merit (bytes 5-8 of FilterData) in both registry views.
reg_set() { # system.reg merit
	[ -f "$1" ] || { warn "no $1 yet; run the game once"; return 0; }
	key=$FILTER merit=$2 awk '
		/^\[/ { in_key = index($0, ENVIRON["key"]) > 0 }
		in_key && /^"FilterData"=hex:02,00,00,00,/ {
			$0 = substr($0, 1, 29) ENVIRON["merit"] substr($0, 41)
		}
		{ print }' "$1" > "$1.gtasa-intro"
	if cmp -s "$1" "$1.gtasa-intro"; then
		rm "$1.gtasa-intro"
	else
		mv "$1.gtasa-intro" "$1"
	fi
}

reg_status() {
	key=$FILTER awk '
		/^\[/ { in_key = index($0, ENVIRON["key"]) > 0 }
		in_key && /^"FilterData"=hex:/ { print "registry: merit " substr($0, 30, 11) }' "$1"
}

run() { # mode game_dir compatdata
	exe=$2/gta-sa.exe reg=$3/pfx/system.reg
	[ -f "$exe" ] || { warn "no $exe"; return 1; }
	case $1 in
	apply) exe_set "$exe" on; reg_set "$reg" "$MERIT_OFF" ;;
	revert) exe_set "$exe" off; reg_set "$reg" "$MERIT_WINE" ;;
	status) exe_status "$exe"; [ ! -f "$reg" ] || reg_status "$reg" ;;
	esac
}

case ${1:-} in
apply | revert | status)
	[ $# -eq 3 ] || { warn "usage: $0 apply|revert|status GAME_DIR COMPATDATA"; exit 2; }
	# Wine writes its registry back on exit, over any change made meanwhile.
	if [ "$1" != status ] && pgrep -x gta-sa.exe > /dev/null; then
		warn "the game is running; quit it first"
		exit 1
	fi
	run "$@"
	;;
"")
	warn "usage: $0 %command% (as a Steam launch option)"
	exit 2
	;;
*)
	for arg; do
		case $arg in
		*/gta-sa.exe)
			run apply "$(dirname "$arg")" "${STEAM_COMPAT_DATA_PATH:?}" || true
			break
			;;
		esac
	done
	exec "$@"
	;;
esac
