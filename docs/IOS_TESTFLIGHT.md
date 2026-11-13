# FaceTrack iPhone beta

The Student and Teacher iOS projects use the hosted HTTPS API and have separate bundle IDs.

| App | Bundle ID |
|---|---|
| FaceTrack Student | `dev.facetrack.student` |
| FaceTrack Teacher | `dev.facetrack.teacher` |

## Prepare the Mac

1. Install and open [Xcode](https://apps.apple.com/app/xcode/id497799835). Complete first-launch setup and install the iOS SDK. Select the full Xcode installation in Xcode → Settings → Locations → Command Line Tools. Check the current [Apple upload requirements](https://developer.apple.com/news/upcoming-requirements/).
2. Install CocoaPods and confirm `xcodebuild -version`, `pod --version` and `scripts/flutter doctor -v` from the repository root.
3. In Xcode → Settings → Accounts, sign in with an account on the Apple Developer Program team that owns the apps. Register both bundle IDs and create matching iOS app records in [App Store Connect](https://appstoreconnect.apple.com/).
4. Open each `ios/Runner.xcworkspace`, select Runner → Signing & Capabilities, enable automatic signing and select the team. Keep signing credentials outside Git.

## Archive and test

Run from the repository root. Set a higher build number for every subsequent upload of the same version. The production configuration uses the public Flutter values from the [Azure guide](DEPLOY_AZURE.md#updating).

```sh
for app in student teacher; do
  (
    cd "apps/$app" &&
      ../../scripts/flutter pub get --enforce-lockfile &&
      ../../scripts/flutter build ipa --release --build-number=1 \
        --dart-define-from-file=../../.local/flutter/production.json
  ) || exit 1
done
```

Use Xcode Organizer to upload each archive in `build/ios/archive/`. Start with internal TestFlight testing on a physical iPhone. Check:

- Both apps can sign in, restore the session after restart and sign out independently.
- Student enrolment opens upright, guides all poses or clearly falls back to timed prompts, stops automatically, plays back and uploads for review.
- Teacher capture opens upright, shows framing where available, stops cleanly, retries interrupted uploads and reaches attendance review.
- Denying camera access provides recovery guidance. Backgrounding or cancelling releases the camera. Use consenting participants and verify that private media remains protected.

After internal validation, add the builds to an external group and submit for TestFlight review. Provide App Review with working test access through App Store Connect. After approval, share an email invitation or a TestFlight link with the client. [Apple’s external testing instructions](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers)
