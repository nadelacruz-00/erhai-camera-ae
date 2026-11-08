#!/usr/bin/env bash
# Live rear-camera mirror test: tools/mirror-test.sh
# Keep the rear camera streaming (Zen test page -> Rear) and hold some
# printed text in front of it. This toggles the sensor's horizontal-mirror
# bit (0x3221: 0x66 = mirror on, the driver default; 0x60 = mirror off) and
# asks which one reads correctly. Temporary: the driver rewrites 0x3221 at
# the next stream start.
set -eu
export PYTHONPATH=$HOME/.local/lib/camera-ae
set_reg() {
	python3 -c "
from camera_ae.sensor import open_sensor
s = open_sensor('rear'); s.write(0x3221, bytes([$1]))
print('  0x3221 =', hex(s.read(0x3221, 1)[0]))"
}
echo "Start the rear camera (Zen: camtest.html -> Rear), hold up some text."
read -r -p "Press Enter when the rear camera is streaming... " _
echo "A: mirror ON (driver default)"; set_reg 0x66
read -r -p "Look at the text, then press Enter... " _
echo "B: mirror OFF"; set_reg 0x60
read -r -p "Look at the text, then press Enter... " _
read -r -p "Which read correctly (not backwards)? [A/B] " ans
echo "answer: $ans" | tee "$(dirname "$0")/../mirror-test.log"
