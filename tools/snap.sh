#!/usr/bin/env bash
# Save one raw PipeWire frame (no browser involved): tools/snap.sh <front|rear> [out.png]
# Streams ~6 s (so exposure has settled) and keeps the last frame.
set -eu
case "${1:-}" in front) suf=camera-sensor_10 ;; rear) suf=camera-sensor_36 ;;
	*) echo "usage: $0 <front|rear> [out.png]" >&2; exit 2 ;; esac
out=${2:-$(dirname "$0")/../$1-raw.png}
serial=$(pw-dump -N | SUF=$suf python3 -c '
import json, os, sys
for o in json.load(sys.stdin):
    p = (o.get("info") or {}).get("props") or {}
    if o.get("type") == "PipeWire:Interface:Node" and p.get("node.name", "").endswith(os.environ["SUF"]):
        print(p["object.serial"]); break')
tmp=$(mktemp -d)
timeout 7 gst-launch-1.0 -q pipewiresrc target-object="$serial" client-name=snap \
	! videoconvert ! videoscale ! video/x-raw,width=960,height=720 \
	! videorate ! video/x-raw,framerate=2/1 ! pngenc \
	! multifilesink location="$tmp/f%03d.png" >/dev/null 2>&1 || true
last=$(ls "$tmp"/*.png | tail -n 1)
cp "$last" "$out"; rm -rf "$tmp"
echo "saved $out"
