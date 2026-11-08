#!/usr/bin/env python3
"""Auto-adjust the libcamera software ISP tone (gamma, contrast) for PipeWire camera apps.

Stock libcamera's AE already adjusts the sensor's exposure and gain (the kernel
writes them), but its target is a raw-histogram midpoint, so on these SmartSens
sensors browsers get a very bright picture. libcamera exposes only Gamma and
Contrast to PipeWire clients, so this closes the loop on those: while some app
(e.g. a browser) streams a camera, a small second PipeWire reader samples the
same picture a few times a second and steers gamma/contrast toward a target
mean brightness.

Limits, measured 2026-11-08 on the front camera:
- gamma below ~1.4 tints the picture magenta (the soft ISP's white balance runs
  red/blue a little high and a low gamma no longer hides it), so gamma stays in
  [GAMMA_MIN, 2.2];
- contrast below ~0.7 looks washed out, so contrast stays in [CONTRAST_MIN, 1.0].
Inside those bounds a bright room cannot get much below ~0.6 mean, but a dark
room is lifted back up to gamma 2.2.

Environment: CAMERA_TARGET (mean brightness, default 0.55), CAMERA_GAMMA_MIN
(1.4), CAMERA_CONTRAST_MIN (0.7).
"""
import json
import os
import signal
import subprocess
import sys
import threading
import time

TARGET = float(os.environ.get("CAMERA_TARGET", "0.55"))
GAMMA_MAX, GAMMA_MIN = 2.2, float(os.environ.get("CAMERA_GAMMA_MIN", "1.4"))
CONTRAST_MAX, CONTRAST_MIN = 1.0, float(os.environ.get("CAMERA_CONTRAST_MIN", "0.7"))
GAMMA_PROP = 16777261          # libcamera controls::Gamma as exposed by spa-libcamera
MONITOR = "camera-tone"        # our PipeWire client's node.name
W, H, FPS = 160, 120, 4
POLL = 2.0                     # seconds between PipeWire graph checks
DEADBAND, GAIN, MAX_STEP = 0.02, 1.5, 0.08
D_DEFAULT = 0.5                # 0 = brightest tone (gamma 2.2), 1 = darkest


def log(msg):
    print(f"camera-tone: {msg}", flush=True)


def tone(d):
    """Map the darkening level d in [0, 1] to (gamma, contrast)."""
    return (GAMMA_MAX - (GAMMA_MAX - GAMMA_MIN) * d,
            CONTRAST_MAX - (CONTRAST_MAX - CONTRAST_MIN) * d)


def set_tone(node_id, d):
    gamma, contrast = tone(d)
    subprocess.run(["pw-cli", "set-param", str(node_id), "Props",
                    f"{{ {GAMMA_PROP}: {gamma:.3f}, contrast: {contrast:.3f} }}"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)


def graph():
    """Return {camera node id: (serial, has_other_consumer)}."""
    try:
        out = subprocess.run(["pw-dump"], capture_output=True, timeout=10).stdout
        objs = json.loads(out or b"[]")
    except (subprocess.TimeoutExpired, json.JSONDecodeError):
        return None
    byid = {o["id"]: o for o in objs}
    props = lambda o: (o.get("info") or {}).get("props") or {}
    cams = {}
    for o in objs:
        p = props(o)
        if o.get("type", "").endswith("Node") and \
                str(p.get("node.name", "")).startswith("libcamera_input"):
            cams[o["id"]] = [p.get("object.serial"), False]
    for o in objs:
        if not o.get("type", "").endswith("Link"):
            continue
        i = o.get("info") or {}
        src, dst = i.get("output-node-id"), i.get("input-node-id")
        if src in cams and props(byid.get(dst, {})).get("node.name") != MONITOR:
            cams[src][1] = True
    return {k: tuple(v) for k, v in cams.items()}


class Monitor:
    """A small PipeWire reader of one camera node; keeps the latest mean brightness."""

    def __init__(self, serial):
        self.mean = None
        self.proc = subprocess.Popen(
            ["gst-launch-1.0", "-q", "pipewiresrc", f"target-object={serial}",
             f"client-name={MONITOR}", "!", "videorate", "drop-only=true", "!",
             f"video/x-raw,framerate={FPS}/1", "!", "videoconvert", "!", "videoscale",
             "!", f"video/x-raw,format=GRAY8,width={W},height={H}", "!",
             "fdsink", "fd=1"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        size = W * H
        while True:
            buf = self.proc.stdout.read(size)
            if not buf or len(buf) < size:
                return
            self.mean = sum(buf) / size / 255.0

    def alive(self):
        return self.proc.poll() is None

    def stop(self):
        if self.alive():
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()


def main():
    monitors = {}            # node id -> Monitor
    level = {}               # node id -> darkening level d
    seen = set()
    running = True

    def stop(*_):
        nonlocal running
        running = False
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    last_graph = 0.0
    while running:
        now = time.monotonic()
        if now - last_graph >= POLL:
            last_graph = now
            cams = graph()
            if cams is not None:
                for nid in cams.keys() - seen:          # new camera node: set the default tone
                    level.setdefault(nid, D_DEFAULT)
                    set_tone(nid, level[nid])
                    log(f"node {nid}: default tone gamma={tone(level[nid])[0]:.2f}")
                seen = set(cams)
                for nid, (serial, used) in cams.items():
                    mon = monitors.get(nid)
                    if used and (mon is None or not mon.alive()):
                        monitors[nid] = Monitor(serial)
                        log(f"node {nid}: an app is using the camera, following its brightness")
                    elif not used and mon is not None:
                        mon.stop()
                        del monitors[nid]
                        g, c = tone(level[nid])
                        log(f"node {nid}: camera idle, keeping gamma={g:.2f} contrast={c:.2f}")
                for nid in list(monitors):
                    if nid not in cams:
                        monitors.pop(nid).stop()

        for nid, mon in monitors.items():
            if mon.mean is None:
                continue
            err = mon.mean - TARGET
            if abs(err) > DEADBAND:
                d = level.get(nid, D_DEFAULT)
                nd = min(1.0, max(0.0, d + max(-MAX_STEP, min(MAX_STEP, GAIN * err))))
                if abs(nd - d) >= 0.01:
                    level[nid] = nd
                    set_tone(nid, nd)
            mon.mean = None
        time.sleep(0.5)

    for mon in monitors.values():
        mon.stop()


if __name__ == "__main__":
    sys.exit(main())
