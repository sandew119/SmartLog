# LiDAR Scanner — Device Validation Guide

The scanner was written on Windows, without a Mac or a LiDAR device. The
Swift in this folder has **not been compiled**. Everything that decides a
measurement is in Dart and **is** tested (see the end of this file), so the
device work is about checking three things: that the native pump delivers
frames, that the two pieces of new Swift compile and draw, and that real depth
matches the synthetic depth the tests use.

Target device used for the first field test: **iPhone 13 Pro**.

**When something goes wrong, press and hold the three step pills at the top of
the scan screen.** That opens the scan report — frames received, how many held
a face, which check refused the rest and by how much, how long each frame took,
and the numbers behind every decision about the far end. *Copy* it and send it
back. It says what happened; a description of what it looked like cannot.

---

## What the first field test found (2026-09-21)

An 8 inch girth cylinder was not detected; a real log was measured but the face
took a lot of time and adjusting to find; and at the other end the app said
"that is the face you already scanned". Rendering yard scenes through a noisy
sensor model (`test/support/synthetic_depth.dart`, `SensorModel`) reproduced the
causes — every one of them passed the old clean-depth tests:

- **A log end resting on the ground was found in 0 of 30 frames**, from every
  height and distance. The old finder grew while depth was continuous, and depth
  is continuous from the face straight down onto the ground. The finder is now
  plane-first: it fits a plane to the surface under the aim point and grows
  over what lies *on that plane*.
- **Seven ends in a hexagonal stack were measured as one face of three times the
  girth**, with full confidence. Touching ends are now separated by shape (a
  distance transform and watershed) and the one under the reticle is measured.
- **The 8–10 inch cylinder was refused as "more than one log" or "not flat"** in
  nearly every frame: thresholds tuned on clean depth, tripped by pixel
  quantisation and sensor noise on a face 15 pixels across. The app has no
  notion of "is this a log"; it refused a small end. It now accepts ends down to
  a 4 cm diameter (about 5 inches of girth) and, where it cannot judge, says
  "move closer" instead of refusing.
- **Face girth was reading 3–8% short**, because smeared edge pixels were being
  dropped from the face. The size now comes from the area of the pixels, which
  has no bias, with the outline giving only the shape.
- **"That is the end you already scanned" was the message for every failed
  far-end check** — wrong direction, too close, or off to one side as well as
  the first end again. Each now has its own message, and if the geometry doubts
  an end the user can still tap *Use this end*.

## How the scan works (so you know what to look for)

1. **Cut end.** The user points at one sawn end, or **taps the one they want**.
   The app fits a plane to the surface there, grows over it, and traces the
   outline all the way round. A ribbon is drawn on the end — white while
   looking, amber while measuring, green when the readings agree — with a light
   tick each time another reading agrees. When three agree it says *"Face scan
   complete"*, buzzes, and leaves a green disc and outline on the end.
2. **Walk.** The user walks to the other end. Each frame, the app reads how wide
   the trunk is from the two lines of sight that graze its edges, only while the
   slice is seen roughly side-on. A strip at the bottom draws the girth along
   the log as it is read.
3. **Other end.** Turning to face the far end is enough — the app notices it,
   traces it, says *"Length complete"*. Length is the straight line between the
   two end centres.

Girth along the trunk comes from Cauchy's formula (the perimeter of a convex
outline is pi times its mean width): the end face gives the ratio between
girth and width seen from the side, which turns each trunk width into a girth.
The trunk is then **anchored to the ends**: near each end it should read what
the end reads, so whatever constant bias a side view carries (edge pixels lost;
on a log lying on the ground, the hidden lower silhouette) is scaled out. The
trunk can only *lower* the billed girth, and only when a thin spot is
corroborated and clearly below the thinner end (3%).

## 1. Build

The Xcode target already references `LidarCapability.swift`,
`DepthUnprojector.swift`, `LidarScanView.swift`, `LidarScannerPlugin.swift`
and `DepthAccumulator.swift`. The plugin is registered in `AppDelegate.swift`.

**New Swift since the last build, in `LidarScanView.swift` only** — if the build
fails, it is here:

- `showOutline` / `clearOutline` — build an `SCNGeometry` triangle strip from
  vertices Dart sends, using `SCNGeometrySource(vertices:)` and
  `SCNGeometryElement(data:primitiveType:primitiveCount:bytesPerIndex:)`.
- `viewToImage` — asks `ARFrame.displayTransform(for:viewportSize:)` where a tap
  lands in the camera image. Uses `UIWindowScene.interfaceOrientation` (iOS 13).
- `floats(_:)` — reads a `FlutterStandardTypedData` into `[Float]`.

If the build fails there, delete those three cases from `handle` and the
functions above them: the scan still works without the ribbon and the tap (Dart
ignores a native side that does not answer), and `test/log_scanner_screen_test.dart`
pins exactly what Dart sends.

- Deployment target is iOS 13; depth is iOS 14+, so every depth call sits
  behind `#available(iOS 14.0, *)`.
- `DepthAccumulator.swift` is no longer used. Delete it through Xcode when
  convenient.

## 2. Frames are flowing

Open **Scan Log**. The banner should change within a second from
*"Starting the camera…"* to *"Point at the cut end"*.

- Stuck on *"Starting the camera…"*: Dart is receiving no frames. Check the
  Xcode console for channel errors, and that `start` reaches
  `LidarScanView.handle`.
- Stuck on *"Getting ready…"*: ARKit tracking never became normal. Move the
  phone slowly; show it some texture (ground, bark).

The report's *Frames* section says how many arrived, at what rate, and how long
each took to process. Expect roughly ten a second; processing should be well
under 100 ms (the timing tests put it at 15–30 ms in a debug-speed build).

## 3. The ribbon and the tap

Point at a log end. **A ribbon should appear on the end within a moment** and
follow it as the phone moves, turning white → amber → green. If nothing is
drawn, `showOutline` is not reaching SceneKit (check the console).

**Tap a different end.** A small white ring should appear on it, the banner hint
should read *"Measuring the end you tapped"*, and the app should lock onto that
end rather than the middle of the screen. If the ring lands somewhere else than
where you tapped, `viewToImage` is mapping wrongly — try it in landscape too.

## 4. Known circle — checks the depth maths

Use something round with a known circumference: a bucket lid, a paint tin,
a plate. Wrap a tape round it.

Stand it up with open space behind it, point at it from about 60 cm, and
let it lock. Compare the girth on screen with the tape. Do this 5 times. Then
again with something small (an 8 inch girth pipe or tin, held 35–50 cm away).

- **Right within ~2%**: the unprojection and the intrinsics rescale are
  correct.
- **Off by the same factor every time**: the intrinsics scaling is wrong.
  Look at `DepthFrame.fromNative`, and check the `imageWidth`/`imageHeight`
  and the decimated `width`/`height` in the payload.
- **Reads short by the same few millimetres of radius whatever the size**: edge
  handling — see `FaceScanner._smearBandPixels`. A real depth map may not smear
  edges the way the test sensor model does; this is where that shows.
- **Never locks**: read the banner, or the report. Each message maps to one
  rejection in `FaceScanner.detect` (see the table below), and the report says
  which check fired and by how much.

## 5. A real log

Tape the girth at both cut ends, and the straight length end to end. Scan
the same log 5 times. Record app vs tape for:

- girth, first end
- girth, other end
- thinnest girth (and where the app says it was)
- length

Acceptance to aim for: **girth within ±2%, length within ±2 cm per metre**.
Try it **lying on the ground**, **on a bearer**, and **in a stack** — the ground
and the stack are what the finder was rebuilt for.

## 6. Conditions

| Condition | What to check |
|---|---|
| Shade vs direct sun | Sun blinds the IR sensor — does it still lock? |
| Standing off to one side | Locks at once up to ~55° off square; asks for straighter beyond, then accepts a steady reading after 1.5 s |
| End lying on the ground | Should lock like any other — this was 0 of 30 before |
| Log in a stack, ends flush | Should measure the end you aim at or tap, not the group |
| Log in a stack, ends staggered | Should measure normally |
| Far end buried or rotten | *"Can't scan this end?"* ends the length where the user pointed |
| Far end another log's end, off to one side | Says so, and *Use this end* still works |
| Very long log (4 m+) | Length drift — compare with tape |
| Wide radial crack across an end | Known limit: a crack 2+ pixels wide that runs rim to pith can split a face into halves and read half the girth |

## Banner → cause

| Banner | Rejection | Meaning |
|---|---|---|
| Point at the cut end | `noDepth` / `notFlat` | No usable surface, or the surface is curved or a wall-sized flat |
| Move closer | `tooFar` / `tooSmall` | Beyond 2.5 m, or too few pixels on the end |
| Move back a little | `tooClose` | Inside 25 cm |
| Step back | `runsOffScreen` | The end runs off the edge of the frame |
| That is the side of the log | `pointingAtTheSide` | A long band — the trunk, not the end |
| Face the cut end straight on | `tooAngled` | More than 62° off square |
| Good — now face it straight on | (a face, but > 55° tilt) | Waiting up to 1.5 s, then takes it anyway |
| Aim at one log only | `moreThanOneLog` | Shape not compact even after separating touching ends |
| Hold still… | `outlineIncomplete` / settling | Waiting for readings to agree |
| That is the end you already scanned | far end `sameEnd` | The first end again (centre within 20 cm of it) |
| That end faces the same way as the first | far end `facingTheSameWay` | Normals not opposite — go round the log |
| That is very close to the first end | far end `tooClose` | Under 15 cm along the log |
| That end is off to one side of the log | far end `offTheLine` | Another log's end — *Use this end* overrides |

## Tuning

Every threshold is a named constant with its reasoning beside it:

- `lib/utils/face_scan.dart` — `FaceScanner`: range, curvature, tilt, size,
  compactness, outline completeness.
- `lib/utils/face_segmentation.dart` — `FaceSegmentation`: plane tolerance, seed
  patches, the watershed's split rule, how thin a strip must be to be removed.
- `lib/utils/log_scan_session.dart` — `LogScanSession`: how many readings must
  agree, the square-on limit and patience, far-end matching.
- `lib/utils/log_girth_model.dart` — `TrunkProfiler`, `LogGirthModel`:
  slice sizes, how oblique a slice may be, end-anchoring, the waist margin.

The noise model behind the tests is `SensorModel` in
`test/support/synthetic_depth.dart`. If real depth turns out quieter or
smoother than it, tighten it there and the tests will say what breaks.

## What is verified off-device

Run `flutter test`. The scanner's tests render synthetic depth frames of
known scenes — most of them through a noisy sensor model — and check the
answers against geometry worked out independently:

- `test/face_scan_test.dart` — clean round, oval, lobed and tilted ends traced
  within 2–4% of their true girth; the trunk, an oversized end, an empty scene
  and a far end refused with the right reason.
- `test/face_yard_test.dart` — the yard: ends on the ground, in stacks (including
  the seven-end hexagon), small objects, the sides of trunks from 8 cm to 50 cm
  radius, tilts to 60°, a crack under the reticle, and the splitter itself.
- `test/log_girth_model_test.dart` — round and oval logs, a waist, taper,
  noise that must not undercut an end, and trunk widths read from rendered
  depth.
- `test/log_scan_session_test.dart` — a whole scan driven frame by frame, every
  far-end verdict, the "use this end" override, lock speed, tap-to-aim, the
  report.
- `test/log_scan_noisy_test.dart` — a whole scan through depth noise and a
  drifting pose: uniform, tapered and waisted logs, length within 0.3%, ends
  within 0.7%, no false undercut on a uniform log.
- `test/log_scanner_screen_test.dart` — the real screen, with the platform view
  stood in for: what it draws, says, and returns, and what a tap does.
- `test/outline_and_tap_test.dart` — the ribbon geometry, and a native side that
  answers a tap with nonsense.

**Not verified — needs the device:** that the Swift compiles and the ribbon
draws; that `viewToImage` maps a tap correctly; that ARKit's depth, intrinsics
and pose behave as the payload assumes; how real depth edges compare with the
smeared edges the sensor model uses; the ARKit depth source (`smoothedSceneDepth`
is filtered over time, which may smear edges while the phone moves — `sceneDepth`
is the alternative if edges look ghosted); frame rate and heat on a long scan;
and accuracy against a tape.
