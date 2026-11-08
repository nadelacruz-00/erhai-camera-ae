#!/usr/bin/env bash
# Task 4 device checks that need you: low light, bright scene, tint/fog gate,
# stop mid-stream, Snapshot switching and Zen.  tools/devcheck2.sh
# It prompts before each step; output also goes to devcheck2.log.
# Never restarts pipewire or wireplumber; restarts camera-gamma.service only.
set -u
cd "$(dirname "$0")/.."
REPO=$PWD
LOG=$REPO/devcheck2.log
TMP=$(mktemp -d)
export PYTHONPATH=$HOME/.local/lib/camera-ae
FRONT=/base/soc@0/geniqup@8c0000/i2c@884000/camera-sensor@10
exec > >(tee "$LOG") 2>&1
T0=$(date '+%F %T')

ask() { echo; echo ">>> $1"; read -r -p "    press Enter when ready... " _ </dev/tty; }
journal() { journalctl --user -u camera-gamma.service --since "$1" --no-pager -o cat; }
gate() {  # gate STANDIN_FILE ERHAICAM_FILE
	python3 - "$1" "$2" <<'EOF'
import re, sys
rows = [l.split() for l in open(sys.argv[1]) if len(l.split()) == 7]
last = rows[-5:]
rg = sum(float(r[5]) for r in last) / len(last)
bg = sum(float(r[6]) for r in last) / len(last)
lo = sum(float(r[3]) for r in last) / len(last)
luma = sum(float(r[1]) for r in last) / len(last)
ec = [float(m.group(1)) for m in re.finditer(r'lo=([0-9.e-]+)', open(sys.argv[2]).read())][-10:]
eclo = sum(ec) / len(ec) if ec else float('nan')
ok = 0.90 <= rg <= 1.10 and 0.90 <= bg <= 1.10 and lo - eclo <= 0.01
print(f'dim scene: luma {luma:.3f}  R/G {rg:.3f}  B/G {bg:.3f}  lo {lo:.4f}  '
      f'ErhaiCam lo {eclo:.4f}')
print('TINT/FOG GATE:', 'PASS' if ok else 'FAIL (do not keep; report)')
EOF
}

if pgrep -x erhai-cam >/dev/null; then echo "close ErhaiCam first"; exit 1; fi
systemctl --user is-active --quiet camera-gamma.service || systemctl --user start camera-gamma.service

# 1. Low light (ladder up), tint/fog gate
ask "STEP 1: make the room DIM (lights off or low; do NOT cover the lens). Point the FRONT camera at the room and keep the tablet still."
S1=$(date '+%F %T')
tools/standin.sh front 30 > "$TMP/dim.txt"
tail -n 6 "$TMP/dim.txt"
echo "ladder lines:"; journal "$S1" | grep -E 'frame [0-9]+ lines' || echo "  (none: scene not dark enough for the ladder)"
sleep 2
timeout 30 erhai-cam --no-af --camera "$FRONT" --ae-probe 15 2>/dev/null > "$TMP/ec.txt"
echo "ErhaiCam (same scene):"; grep 'ae luma=' "$TMP/ec.txt" | tail -n 3
gate "$TMP/dim.txt" "$TMP/ec.txt"

# 2. Stop mid-stream while laddered
ask "STEP 2: keep it DIM and still (stop-mid-stream test, 25 s)."
tools/standin.sh front 25 > /dev/null &
SPID=$!
sleep 15
echo "before stop: $(python3 -m camera_ae.sensor front read)"
systemctl --user stop camera-gamma.service
sleep 1
echo "after stop (VTS must be 3128): $(python3 -m camera_ae.sensor front read)"
systemctl --user start camera-gamma.service
wait "$SPID" 2>/dev/null

# 3. Bright scene (ladder down)
ask "STEP 3: point the FRONT camera at a BRIGHT lamp or window (it can stay dim in the room)."
S3=$(date '+%F %T')
tools/standin.sh front 25 | tail -n 4
echo "frame lines:"; journal "$S3" | grep -E 'frame [0-9]+ lines' || echo "  (none: frame was already at default 3128)"

# 4. Snapshot switching
ask "STEP 4: lights back to normal. Open GNOME Snapshot, switch front <-> rear 3 times (each should show a picture within 2 s), close Snapshot."
echo "(Snapshot step done)"

# 5. Zen
ask "STEP 5: in Zen open file://$REPO/tools/camtest.html . Click Front, then 1280x720, 640x480, Switch camera, Switch camera again, Reload page, Front, Rear. Compare brightness with ErhaiCam by eye. Close the tab."
S5=$(date '+%F %T')
read -r -p "    did Zen look like ErhaiCam (front and rear)? [y/n/notes] " ZEN </dev/tty
echo "user sign-off: $ZEN"

echo; echo "== engine journal since $T0 (start/stop/frame/warnings)"
journal "$T0" | grep -vE '^(Started|Stopped|Stopping)' | tail -n 60
echo; echo "== foreign / re-attach lines (must be no 'foreign'):"
journal "$T0" | grep -E 'foreign|re-attaching|exposure frozen' || echo "  none"
rm -rf "$TMP"
echo; echo "== done: log saved to $LOG"
