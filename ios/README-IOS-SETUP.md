# iOS Setup — one-time steps on the Mac

Everything here is a credential or an Apple-account step that cannot be
committed to the repo. Do these once after cloning, before building to a
device.

## 1. Open the workspace, not the project

```
open ios/Runner.xcworkspace
```

Opening `Runner.xcodeproj` directly will build without the Flutter plugin
package and fail in confusing ways.

## 2. Signing

Select the **Runner** target → **Signing & Capabilities** → set **Team** to
your Apple ID. A free account is fine for installing on your own device.

**Bundle identifier:** leave it as `com.example.smartlog2` if Xcode accepts
it. If Xcode refuses it (someone else has claimed it in your team), you must
change it *and* update Firebase — the Firebase iOS app is registered against
that exact id (`iosBundleId` in `lib/firebase_options.dart`). Changing one
without the other silently breaks authentication. To change both:

```
flutterfire configure
```

…and register the new bundle id as an iOS app in the Firebase console.

## 3. Google Sign-In (optional — email/password works without this)

`GoogleService-Info.plist` is **not in the repo** (it carries project
credentials). Without it, the app still launches and email/password sign-in
works — only the "Sign in with Google" button fails, with a message
explaining why.

To enable it:

1. Firebase console → Project settings → your iOS app →
   **Download GoogleService-Info.plist**.
2. Drag it into `ios/Runner/` in Xcode, **Add to targets: Runner** ticked.
3. Open the plist, copy the `REVERSED_CLIENT_ID` value (it looks like
   `com.googleusercontent.apps.426376339171-abc123…`).
4. Add it to `ios/Runner/Info.plist` as a URL scheme:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>PASTE_YOUR_REVERSED_CLIENT_ID_HERE</string>
    </array>
  </dict>
</array>
```

Without step 4 the Google sign-in sheet opens and then never returns.

## 4. Build

```
flutter pub get
flutter run
```

There is no `Podfile` — this project uses Swift Package Manager, and Flutter
generates what it needs.

## Already done for you

- **Camera permission** — `NSCameraUsageDescription` is in `Info.plist`.
- **LiDAR module in the Xcode project** — the four files under
  `Runner/LidarScanner/` are already referenced by `project.pbxproj` and in
  the Runner target's compile phase, and the plugin is registered in
  `AppDelegate.swift`. Nothing to drag in.
- **Deployment target** — iOS 13.0, with the depth APIs guarded by
  `@available(iOS 14.0, *)`.

If Xcode ever reports the project "cannot be parsed", restore it with
`git checkout ios/Runner.xcodeproj/project.pbxproj` and add the
`LidarScanner` folder to the Runner group manually instead.

## Then: validate the LiDAR

See `Runner/LidarScanner/README-VALIDATION.md`. That Swift has never been
compiled — do the flat-wall check before trusting any measurement.
