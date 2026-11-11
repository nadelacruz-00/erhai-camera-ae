# erhai-camera-ae

ErhaiCam's auto-exposure for PipeWire camera apps (Zen and other browsers, GNOME
Snapshot) on the OnePlus Pad 3 ("erhai"). Browsers then get the same
brightness and darkness behaviour as ErhaiCam. Stock libcamera, PipeWire and
ErhaiCam are not modified.

## How it works

1. **A user tuning override turns libcamera's own auto-exposure off for PipeWire apps.**
   - The pipewire daemon, where the camera nodes and their soft-ISP IPA live, starts with `LIBCAMERA_IPA_CONFIG_PATH=~/.local/share/camera-ae/ipa`.
   - That directory holds `simple/{sc820cs,sc1320cs,uncalibrated}.yaml`, which enable only `BlackLevel` and `Awb`. With no `Agc` and no `Adjust`, libcamera never touches exposure again.
   - Gamma stays at the 2.2 default and saturation at 1.0, which are ErhaiCam's own pins.
   - ErhaiCam keeps the system file, because it runs its own libcamera outside PipeWire.
2. **`camera-gamma.service` runs the engine.** While an app streams a camera node, the engine:
   - attaches a passive 320x240 reader to that node;
   - runs ErhaiCam's controller, ported 1:1: target luma 0.45, log-domain steps, highlight guard, and the low-light frame-length ladder;
   - writes integration time, VTS and 4x gain over `/dev/i2c`.
3. **Rear autofocus**, ported from ErhaiCam. The `cn3927` voice-coil lens is driven through its kernel subdev (`V4L2_CID_FOCUS_ABSOLUTE`) with ErhaiCam's Tenengrad contrast sweep:
   - a coarse pass over `0, 128 … 896, 1023`, then ±64 around the best position;
   - a lock, with a 5 s hold;
   - then monitoring: a refocus after 4 checks below 55 % of the locked sharpness.

   While it sweeps, the frame stays at its base length and the low-light ladder waits. The front camera is fixed-focus.
4. **The engine checks that it is the only writer.** On every analysed frame it reads the exposure register back. If something else changed it (for example libcamera's AGC is back after an upgrade), it turns AE off and logs a warning.

Differences from ErhaiCam:

- It doesn't freeze exposure while recording (browsers don't signal it).
- There is no tap-to-focus; AF scores the centre 60 % of a 320x240 frame.
- It measures the soft-ISP output, not ErhaiCam's WB-corrected preview.
- It samples the whole frame.
- It starts from the last settled exposure for that camera (kept in `~/.local/state/camera-ae/remembered.json`), otherwise at the exposure ceiling like ErhaiCam. It never starts from the kernel's cached controls, which another client may have left stale (exposure 1 was seen).
- Like ErhaiCam, every stream starts at the base frame length: a remembered long frame from the low-light ladder is not restored (the exposure is clamped to the base ceiling), so a new session does not start at low fps. The ladder goes up again by itself if the scene is still dark.
- It writes exposure before VTS when the frame shortens.
- It sets 4x gain at session start.

## Install

```sh
./install.sh            # copies everything, restarts camera-gamma.service only
# reboot (pipewire must restart with the override; nothing here restarts it)
PYTHONPATH=~/.local/lib/camera-ae python3 -m camera_ae.doctor
```

Until that reboot the engine logs `tuning override not active ... AE off` and
writes nothing; libcamera's own auto-exposure stays in charge.

## Important: exposure freezes without the engine

Once the override is active, libcamera no longer adjusts exposure. When the
engine is stopped, crashed, or switched off with `CAMERA_AE=off`, browser
camera exposure stays at whatever it was. The journal says `exposure frozen`
whenever that happens.

- Switch it off: `systemctl --user edit camera-gamma.service`, add
  `Environment=CAMERA_AE=off`, then `systemctl --user restart camera-gamma.service`.
- Full rollback: `./install.sh --uninstall`, then reboot. This removes both
  drop-ins and the tuning files, restores the old gamma steerer, and gives
  libcamera's (bright) auto-exposure back.

## Tuning

`CAMERA_AF=off` turns autofocus off; the lens then stays where it is.

`CAMERA_AE_TARGET` (default 0.45, clamped to 0.2-0.7) sets the target luma.
Add it with `systemctl --user edit camera-gamma.service`, as above.

## Tools

- `PYTHONPATH=~/.local/lib/camera-ae python3 -m camera_ae.doctor` checks:
  - the service is running;
  - the override is active in pipewire, and which tuning file libcamera picked this boot;
  - the tuning files;
  - I2C access and chip IDs;
  - libcamera upgrade drift.
- `PYTHONPATH=~/.local/lib/camera-ae python3 -m camera_ae.sensor <front|rear> [read|vts|gain|chip|write-exposure N]`
  reads or writes the sensor registers. The sensor only answers while it is streaming.
- `tools/standin.sh <front|rear> [seconds]` is a stand-in camera app. It prints
  `t luma hi lo fps rg bg` once a second.

## After a libcamera upgrade

The engine warns at start if `libcamera0.7`, `libcamera-ipa` or the system
`uncalibrated.yaml` changed since install. Then:

1. Run `doctor`.
2. Run the ownership check:
   1. Restart the engine with `CAMERA_AE=off`.
   2. Run `tools/standin.sh front`.
   3. Run `… sensor front write-exposure 401`, wait 5 s, then `… sensor front read`. It must still read 401.
   4. Remove `CAMERA_AE=off` and restart the engine.

## Device verification (2026-11-08)

Measured on the device with `tools/devcheck.sh` and `tools/devcheck2.sh`.

- **`doctor`:** OK. pipewire runs with the override, and libcamera's tuning lookup picked our file.
- **Ownership:** with the engine off, a manual exposure write of 401 was still 401 after 5 s, so libcamera no longer writes exposure.
- **Front:** went from luma 0.74 (the stale driver default 3120/3128) to 0.44-0.47 within about 5 s, at 25 fps. On the same scene, ErhaiCam settled at exposure 779-801 against the engine's 807, both at 4x gain, with luma 0.437 against 0.444.
- **Rear:** luma 0.46 against ErhaiCam's 0.466. Exposure was 2104 against 1471; the two pipelines frame the 13 MP sensor differently, but the brightness matches. B/G is about 0.82, so the rear is slightly warm.
- **Low light:** in a dim room the ladder went to `frame 6256 lines`, and pointing at a bright scene brought it back to `frame 3128`.
- **Switching** (Snapshot, and the Zen test page with resolution changes, reloads and in-page switches): clean start/stop with no `foreign` and no `exposure frozen` lines. Each new stream starts from the last settled exposure.
- **User sign-off:** Zen matches ErhaiCam.
- **Boot race (not caused by this):** if a camera app is open while erhai-camera-acl restarts PipeWire about 40 s after login, PipeWire comes back with no camera nodes (`Failed to setup link 'msm_csiphy5' -> 'msm_csid0': Device or resource busy`). Fix it with a reboot (open no camera app for the first minute) or with `systemctl --user restart wireplumber`.

## Zen: full-frame default size

The sensors are 4:3. When a site doesn't request a size, Zen picks one adaptively and gets a cropped 16:9 picture. The profile's `user.js` sets 1600x1200, the full frame and ErhaiCam's choice:

```
user_pref("media.navigator.video.default_width", 1600);
user_pref("media.navigator.video.default_height", 1200);
```

Restart Zen after changing it. Sites that ask for 16:9 themselves (many video-call sites ask for 1280x720) still get a crop.

## Retire this

Delete this engine (`./install.sh --uninstall`, then reboot) once libcamera's
soft-ISP AGC gets a tunable target, or erhai ships tuned sensor files.

## Credits and licence

- **ErhaiCam** is by **TheMojoMan**. This project ports ErhaiCam's auto-exposure controller (`ae_step`), its frame statistics (`sample_gray`/`stats_cpu`) and its autofocus loop, constants included, from `erhai-cam.cpp`. It only works because of his camera work on the OnePlus Pad 3.
- ErhaiCam's autofocus algorithm itself comes from **CFM880**'s nabu-camera project (`nabu-autofocus`).
- ErhaiCam is GPL-2.0-only. As a derived work, this project is too (see `LICENSE`).

## Tests

`python3 -m unittest discover -s tests`
