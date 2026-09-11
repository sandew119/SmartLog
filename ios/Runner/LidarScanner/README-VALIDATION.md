# LiDAR Scanner — Device Validation Guide

The scanner was written on Windows, without a Mac or a LiDAR device. The
Swift in this folder has **not been compiled**. Everything that decides a
measurement is in Dart and **is** tested (see the end of this file), so the
device work is about checking two things: that the native pump delivers
frames, and that real depth matches the synthetic depth the tests use.

Target device used for the first field test: **iPhone 13 Pro**.

---

## How the scan works (so you know what to look for)

1. **Cut end.** The user points at one sawn end. The app grows a region out
   from the middle of the screen, fits a plane to it, and traces its outline
   all the way round. When several frames agree, it says *"Face scan
   complete"*, buzzes, and puts a green disc on the end.
2. **Walk.** The user walks to the other end. Each frame, the app reads how
   wide the trunk is from the two lines of sight that just graze its edges.
3. **Other end.** Turning to face the far end is enough — the app notices
   it, traces it, says *"Length complete"*. Length is the straight line
   between the two end centres.

Girth along the trunk comes from Cauchy's formula: at the cut end the whole
outline is visible, so its girth ÷ its width (seen from the side) is known,
and that ratio turns each trunk width into a girth. The trunk can only
*lower* the billed girth, and only when a thin spot is corroborated and
clearly below the thinner end.

## 1. Build

The Xcode target already references `LidarCapability.swift`,
`DepthUnprojector.swift`, `LidarScanView.swift`, `LidarScannerPlugin.swift`
and `DepthAccumulator.swift`. The plugin is registered in `AppDelegate.swift`.

- `ScanCoverageAnalyser.swift` has been **deleted**. It was never in the
  Xcode target, yet the old `LidarScanView` called it — on its own that
  would have stopped the build.
- `DepthAccumulator.swift` is no longer used. It is left in the target
  because it compiles on its own and removing it means hand-editing the
  project file. Delete it through Xcode when convenient.
- Deployment target is iOS 13; depth is iOS 14+, so every depth call sits
  behind `#available(iOS 14.0, *)`.

If the build fails in `LidarScanView.swift`, that file is the one to fix —
it is a thin pump and has no logic worth preserving.

## 2. Frames are flowing

Open **Scan Log**. The banner should change within a second from
*"Starting the camera…"* to *"Point at the cut end"*.

- Stuck on *"Starting the camera…"*: Dart is receiving no frames. Check the
  Xcode console for channel errors, and that `start` reaches
  `LidarScanView.handle`.
- Stuck on *"Getting ready…"*: ARKit tracking never became normal. Move the
  phone slowly; show it some texture (ground, bark).

The old scanner sent messages from the ARKit queue instead of the main
thread, which Flutter rejects. The new one sends everything on the main
thread and waits for Dart to acknowledge each frame before sending the
next, so frames are dropped rather than queued.

## 3. Known circle — checks the depth maths

Use something round with a known circumference: a bucket lid, a paint tin,
a plate. Wrap a tape round it.

Stand it up with open space behind it, point at it from about 60 cm, and
let it lock. Compare the girth on screen with the tape. Do this 5 times.

- **Right within ~2%**: the unprojection and the intrinsics rescale are
  correct.
- **Off by the same factor every time**: the intrinsics scaling is wrong.
  Look at `DepthFrame.fromNative`, and check the `imageWidth`/`imageHeight`
  and the decimated `width`/`height` in the payload.
- **Never locks**: read the banner. Each message maps to one rejection in
  `FaceScanner.detect` (see the table below).

## 4. A real log

Tape the girth at both cut ends, and the straight length end to end. Scan
the same log 5 times. Record app vs tape for:

- girth, first end
- girth, other end
- thinnest girth (and where the app says it was)
- length

Acceptance to aim for: **girth within ±2%, length within ±2 cm per metre**.

## 5. Conditions

| Condition | What to check |
|---|---|
| Shade vs direct sun | Sun blinds the IR sensor — does it still lock? |
| Standing off to one side | Should ask to face it straight, then accept after ~3.5 s |
| Log in a stack, ends flush | Should say *"Aim at one log only"*, not report a double girth |
| Log in a stack, ends staggered | Should measure normally |
| Far end buried or rotten | *"Can't scan this end?"* ends the length where the user pointed |
| Very long log (4 m+) | Length drift — compare with tape |

## Banner → cause

| Banner | Rejection | Meaning |
|---|---|---|
| Point at the cut end | `noDepth` / `notFlat` | No usable surface, or the surface is rough/curved |
| Move closer | `tooFar` / `tooSmall` | Beyond 2.5 m, or too few pixels on the end |
| Move back a little | `tooClose` | Inside 25 cm |
| Step back | `runsOffScreen` | The end runs off the edge of the frame |
| That is the side of the log | `pointingAtTheSide` | A long band — the trunk, not the end |
| Face the cut end straight on | `tooAngled` | More than 45° off square |
| Aim at one log only | `moreThanOneLog` | Outline not compact — two ends touching |
| Hold still… | `outlineIncomplete` / settling | Waiting for frames to agree |

## Tuning

Every threshold is a named constant with its reasoning beside it:

- `lib/utils/face_scan.dart` — `FaceScanner`: range, flatness, tilt,
  compactness, outline completeness.
- `lib/utils/log_scan_session.dart` — `LogScanSession`: how many frames
  must agree, how long before an angled face is accepted, far-end matching.
- `lib/utils/log_girth_model.dart` — `TrunkProfiler`, `LogGirthModel`:
  slice sizes, the margin before the trunk can undercut an end.

## What is verified off-device

Run `flutter test`. The scanner's tests render synthetic depth frames of
known scenes and check the answers against geometry worked out
independently:

- `test/face_scan_test.dart` — round, oval, lobed and tilted ends traced
  within 2–4% of their true girth; the trunk, an oversized end, an empty
  scene, a far end and two touching ends all refused with the right reason.
- `test/log_girth_model_test.dart` — round and oval logs, a waist, taper,
  noise that must not undercut an end, and trunk widths read from rendered
  depth within 1.5% on average.
- `test/log_scan_session_test.dart` — a whole scan driven frame by frame:
  locks on, walks, finds the far end, finishes on its own; length within
  2 cm; wrong-end rejection; marking the far end by eye.

**Not verified — needs the device:** that the Swift compiles; that ARKit's
depth, intrinsics and pose behave as the payload assumes; frame rate and
heat on a long scan; accuracy against a tape.
