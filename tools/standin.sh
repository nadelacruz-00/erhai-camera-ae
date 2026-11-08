#!/usr/bin/env bash
# A stand-in camera app: tools/standin.sh <front|rear> [seconds]
# Streams the node through PipeWire (like a browser would) and prints
# "t luma hi lo fps rg bg" once a second.
set -eu
case "${1:-}" in
	front) suffix=camera-sensor_10 ;;
	rear) suffix=camera-sensor_36 ;;
	*) echo "usage: $0 <front|rear> [seconds]" >&2; exit 2 ;;
esac
secs=${2:-20}
LIB=${CAMERA_AE_LIB:-$HOME/.local/lib/camera-ae}
serial=$(pw-dump -N | SUFFIX=$suffix python3 -c '
import json, os, sys
for o in json.load(sys.stdin):
    p = (o.get("info") or {}).get("props") or {}
    if o.get("type") == "PipeWire:Interface:Node" and p.get("node.name", "").endswith(os.environ["SUFFIX"]):
        print(p["object.serial"]); break')
[ -n "$serial" ] || { echo "no $1 camera node in PipeWire" >&2; exit 1; }
timeout "$secs" gst-launch-1.0 -q pipewiresrc target-object="$serial" client-name=zen-standin \
	! videoscale method=nearest-neighbour add-borders=false ! videoconvert \
	! video/x-raw,format=BGRx,width=320,height=240 \
	! queue leaky=downstream max-size-buffers=1 ! fdsink fd=1 \
	| PYTHONPATH="$LIB" python3 -m camera_ae.stats
