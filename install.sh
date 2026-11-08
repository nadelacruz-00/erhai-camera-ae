#!/usr/bin/env bash
# Install (or --uninstall) erhai-camera-ae for this user.
# No sudo. Never restarts pipewire or wireplumber: the tuning override takes
# effect at their next start, normally the next reboot.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
LIB=$HOME/.local/lib/camera-ae
BIN=$HOME/.local/bin/camera-tone.py
STATE=$HOME/.local/share/camera-ae
IPA=$STATE/ipa/simple
UNITS=$HOME/.config/systemd/user
BACKUP=$STATE/backup

atomic() {  # atomic SRC DST [MODE]
	local tmp="$2.tmp.$$"
	install -m "${3:-644}" "$1" "$tmp"
	mv -f "$tmp" "$2"
}

uninstall() {
	rm -f "$UNITS/pipewire.service.d/camera-ae.conf" \
	      "$UNITS/wireplumber.service.d/camera-ae.conf"
	rmdir "$UNITS/pipewire.service.d" "$UNITS/wireplumber.service.d" 2>/dev/null || true
	rm -rf "$STATE/ipa" "$LIB" "$STATE/installed.txt"
	[ -f "$BACKUP/camera-tone.py" ] && atomic "$BACKUP/camera-tone.py" "$BIN" 755
	[ -f "$BACKUP/camera-gamma.service" ] && \
		atomic "$BACKUP/camera-gamma.service" "$UNITS/camera-gamma.service"
	systemctl --user daemon-reload
	systemctl --user restart camera-gamma.service || true
	echo "uninstalled (legacy gamma steerer restored if it was backed up)."
	echo "Reboot to give libcamera its own auto-exposure back."
}

if [ "${1:-}" = "--uninstall" ]; then
	uninstall
	exit 0
fi

mkdir -p "$LIB" "$IPA" "$UNITS/pipewire.service.d" "$UNITS/wireplumber.service.d" \
         "$BACKUP" "$(dirname "$BIN")"

# Keep the pre-install steerer and unit once, for --uninstall.
if [ ! -f "$BACKUP/camera-tone.py" ] && [ -f "$BIN" ] && ! grep -q camera_ae "$BIN"; then
	cp -p "$BIN" "$BACKUP/camera-tone.py"
fi
if [ ! -f "$BACKUP/camera-gamma.service" ] && [ -f "$UNITS/camera-gamma.service" ] &&
   ! grep -q erhai-camera-ae "$UNITS/camera-gamma.service"; then
	cp -p "$UNITS/camera-gamma.service" "$BACKUP/camera-gamma.service"
fi

# Package: build beside, then swap.
rm -rf "$LIB.new" "$LIB.old"
mkdir -p "$LIB.new"
cp -r "$HERE/camera_ae" "$LIB.new/"
find "$LIB.new" -name __pycache__ -prune -exec rm -rf {} +
mv "$LIB" "$LIB.old"
mv "$LIB.new" "$LIB"
rm -rf "$LIB.old"

for f in sc820cs.yaml sc1320cs.yaml uncalibrated.yaml; do
	atomic "$HERE/tuning/simple.yaml" "$IPA/$f"
done
atomic "$HERE/systemd/pipewire-camera-ae.conf" "$UNITS/pipewire.service.d/camera-ae.conf"
atomic "$HERE/systemd/wireplumber-camera-ae.conf" "$UNITS/wireplumber.service.d/camera-ae.conf"
atomic "$HERE/systemd/camera-gamma.service" "$UNITS/camera-gamma.service"
atomic "$HERE/camera-tone.py" "$BIN" 755

PYTHONPATH="$LIB" python3 -I -c '
import sys; sys.path.insert(0, sys.argv[1])
from camera_ae.doctor import current_record
sys.stdout.write(current_record())' "$LIB" > "$STATE/installed.txt.tmp"
mv -f "$STATE/installed.txt.tmp" "$STATE/installed.txt"

systemctl --user daemon-reload
systemctl --user enable camera-gamma.service >/dev/null
systemctl --user restart camera-gamma.service
echo "installed. Reboot to activate the tuning override"
echo "(pipewire loads it at its next start), then run:"
echo "  PYTHONPATH=$LIB python3 -m camera_ae.doctor"
