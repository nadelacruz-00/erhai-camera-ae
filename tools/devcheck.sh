#!/usr/bin/env bash
# Task 4 device checks in one go:  tools/devcheck.sh
# Output also goes to devcheck.log in the repo (git-ignored).
# Never restarts pipewire or wireplumber; restarts camera-gamma.service only.
set -u
cd "$(dirname "$0")/.."
LOG=$PWD/devcheck.log
export PYTHONPATH=$HOME/.local/lib/camera-ae
exec > >(tee "$LOG") 2>&1

cams() {
	pw-dump -N | python3 -c '
import json, sys
for o in json.load(sys.stdin):
    p = (o.get("info") or {}).get("props") or {}
    if o.get("type") == "PipeWire:Interface:Node" and p.get("node.name", "").startswith("libcamera_input"):
        print(p["node.name"])'
}

restore_ae() {
	systemctl --user unset-environment CAMERA_AE
	systemctl --user restart camera-gamma.service
}

echo "== $(date '+%F %T') devcheck"
if [ -z "$(cams)" ]; then
	echo "NO CAMERA NODES in PipeWire: the boot-time PipeWire restart (erhai-camera-acl)"
	echo "ran while a camera was busy. Fix: close ErhaiCam/camera apps, then either"
	echo "  reboot and open no camera app for the first minute, or"
	echo "  systemctl --user restart wireplumber   (some ADSP-audio risk)"
	echo "and run tools/devcheck.sh again."
	exit 1
fi
if pgrep -x erhai-cam >/dev/null; then
	echo "ErhaiCam is running: close it first (it holds the camera)."
	exit 1
fi

echo; echo "== doctor"
python3 -m camera_ae.doctor

echo; echo "== check 1: ownership through PipeWire (engine off)"
systemctl --user set-environment CAMERA_AE=off
systemctl --user restart camera-gamma.service
trap restore_ae EXIT
tools/standin.sh front 14 > /tmp/devcheck-standin.$$ &
SPID=$!
sleep 4
python3 -m camera_ae.sensor front read
python3 -m camera_ae.sensor front write-exposure 401
sleep 5
echo "after 5 s (must say exposure=401):"
python3 -m camera_ae.sensor front read
python3 -m camera_ae.sensor front gain
wait "$SPID" 2>/dev/null
echo "stand-in with the engine OFF (t luma hi lo fps rg bg):"
tail -n 4 /tmp/devcheck-standin.$$
rm -f /tmp/devcheck-standin.$$
restore_ae
trap - EXIT
sleep 2

for cam in front rear; do
	echo; echo "== check 2: $cam with the engine ON (luma should settle at 0.45 +- 0.06)"
	tools/standin.sh "$cam" 20
	python3 -m camera_ae.sensor "$cam" read 2>/dev/null || true
	sleep 2
done

echo; echo "== engine journal (last 25 lines)"
journalctl --user -u camera-gamma.service -n 25 --no-pager -o cat
echo; echo "== done: log saved to $LOG"
