# LiDAR Scanner — Build & Validation Guide

This module was written **without access to a Mac, Xcode, or a LiDAR
device**. None of the Swift in this folder has ever been compiled or run.
Treat every measurement it produces as unverified until the checks below
pass, in order.

You need: a Mac with Xcode, and an iPhone 12 Pro (or later Pro) / LiDAR
iPad. Non-Pro iPhones have no LiDAR and will correctly report the feature as
unavailable — the app falls back to manual entry and everything else works.

---

## 1. Add the files to the Xcode project

The four `.swift` files here are **not yet referenced by
`Runner.xcodeproj`** — adding them requires four coordinated edits with
freshly generated UUIDs, which is the single most likely place to lose an
hour. Do it through the UI instead:

1. Open `ios/Runner.xcworkspace` (the workspace, not the `.xcodeproj`).
2. Drag the `LidarScanner` folder onto the `Runner` group in the navigator.
3. Tick **Copy items if needed = off**, **Create groups**, and
   **Add to targets: Runner**.
4. Build (⌘B).

If Xcode ever reports the project "cannot be parsed", run
`git checkout ios/Runner.xcodeproj/project.pbxproj` and redo this step.

No Podfile changes are needed — this project uses Swift Package Manager, and
`import ARKit` links the system frameworks automatically.

## 2. Register the plugin

In `ios/Runner/AppDelegate.swift`, alongside `GeneratedPluginRegistrant`:

```swift
if let registrar = registrar(forPlugin: "LidarScannerPlugin") {
    LidarScannerPlugin.register(with: registrar)
}
```

Verify: run the app, open **Scan Log**. On a LiDAR device the screen should
say a depth sensor was found. If it still says "no depth sensor", the plugin
is not registered — nothing further will work until this is right.

## 3. Flat-wall check — **do this before trusting anything else**

This is the milestone that catches the most likely blind-code bug: the
camera convention and the intrinsics scaling in `DepthUnprojector.swift`.
Both can be wrong while still producing a plausible-looking cloud (right
point count, finite values, roughly sane magnitudes) that is
systematically warped.

1. Stand **exactly 1.00 m** from a large flat wall, phone square to it
   (measure with a tape; a metre is not something to eyeball).
2. Capture.
3. Check the returned points:
   - they should form a **plane**, not a bowl or a saddle;
   - every point should be within a couple of centimetres of **1.00 m**
     from the camera;
   - the plane's normal should point back at the phone.

**If the points curve, or the distance is consistently off by a scale
factor, STOP.** The intrinsics scaling is wrong. A scale error here becomes
a squared error in volume, so no log measurement means anything until this
reads true. Re-check `scaleX`/`scaleY` in `DepthUnprojector.unproject`
against the actual `imageResolution` and depth-map dimensions.

## 4. Known cylinder

Get a length of PVC pipe and measure its diameter with calipers.

Scan it square-on at **0.5, 1.0, 1.5, 2.0 and 3.0 m**, ten times at each
distance. Record app value vs. truth.

Produce a table of **bias and standard deviation per distance**. Those
numbers — not guesses — are what the thresholds in
`lib/models/log_measurement.dart` should be set from. They are all gathered
in one block there for exactly this reason.

Proposed acceptance criterion (adjust if you have a trade standard):
**diameter within ±2% or ±5 mm, whichever is larger, at 1 m square-on, 95%
of the time.**

## 5. Off-square angles

Same pipe at **30°, 45° and 60°** off square. This quantifies the penalty
from seeing a narrower arc of the surface, and validates the angular-span
gate (`LogGeometry.minAngularSpanRadians`, currently 110°). If good scans
are being rejected at 45°, the gate is too tight; if bad ones sail through
at 60°, it's too loose.

## 6. A real log

Chalk a line around a log at one section. Measure its girth there with a
tape, convert to diameter, and scan the same marked section. Repeat on
several logs of different species and sizes.

This is where the **trade-convention question** becomes real: the app takes
the **minimum** diameter along the log ("thinnest place"), while classical
Hoppus tables use **mid-length** girth. If the app reads consistently low
against the book, that is this convention difference, not a sensor error.
The full diameter profile is stored with every log, so the convention can be
changed later without re-scanning anything.

## 7. Environment matrix

iPhone LiDAR is infrared. Timber yards are outdoors. Test all of:

| Condition | Why it matters |
|---|---|
| Deep shade | Baseline — best case |
| Direct midday sun | **Biggest commercial risk.** Sunlight swamps the IR return |
| Dry bark vs. wet bark | Wet dark bark absorbs IR badly |
| Pale vs. dark species | Reflectivity changes return strength |
| Single log vs. stacked pile | Tests the radial gate against neighbours |

Record which combinations fail and how they fail. The app already reports a
limiting factor in plain language; make sure the message actually matches
the real cause in each case.

## 8. Send scans back

Every capture should be dumped and returned so they can become permanent
offline regression fixtures. A real point cloud from a real log, replayed on
a Windows machine, is worth far more than any synthetic test — it turns
on-device reality into something testable without a device.

---

## What is already verified (and what isn't)

**Verified on Windows, 100+ passing tests:**
- All geometry — Taubin circle fitting, RANSAC outlier rejection, axis
  refinement, median-smoothed minimum — against synthetic cylinders with
  noise, partial arcs (180°/120°/90°/60°), oblique seed axes, neighbouring
  logs, and taper. See `test/log_geometry_test.dart`.
- Unit conversions, the deduction pipeline, preference storage.
- The channel decoder against missing/mistyped/NaN/truncated payloads —
  written specifically because this native side is unverified. See
  `test/lidar_scanner_service_test.dart`.
- The whole scan screen, driven by a fake measurement source.

**Not verified — needs this device:**
- That the Xcode project builds at all.
- **The camera convention and intrinsics scaling** (step 3 above).
- ARSession lifecycle: permissions, interruption, thermal throttling.
- PlatformView embedding, z-ordering, and gesture arbitration between the
  Flutter overlay and the `UiKitView`.
- Absolute accuracy against a tape measure.
