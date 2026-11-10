# Camera validation

The Student and Teacher apps list cameras reported by the OS or browser before recording. An external USB camera appears only when the platform exposes it. The selected camera is fixed for each clip; changing cameras during an active recording is disabled.

## Check on a physical Android phone

1. Connect the phone, authorize USB debugging, and run `scripts/android-connect` to restore API reverse forwarding for local development.
2. Start the Student and Teacher apps using the public Flutter config described in `docs/INSTALLATION.md`. Sign in with approved test accounts.
3. In Student face enrolment, open the full-screen camera. Check portrait and landscape, the guide and face outline alignment, all five instructions, and the visible cancel action. Cancel once mid-recording and confirm no new clip appears.
4. In an open Teacher session, press **Open camera** and verify the rear camera is selected. Try a different camera, tap the preview to focus, and toggle the torch on a supported camera. Confirm closing the preview switches off the torch.
5. With a consenting group, start a classroom recording and walk or pan slowly. Check that green outlines follow well-framed faces and clear within about a second when analysis stops. Look for dropped preview frames or recording stutter. Confirm the clip saves and plays back even if the live guidance reports it is unavailable.
6. If Android exposes an external camera, repeat selection and playback with it. Confirm camera switching is disabled during a clip and returns after discarding it.

## Student Android signed release check

Run this check on a physical phone with the signed release APK before distributing changes to camera capture, Flutter or CameraX, ML Kit, or Android release packaging. The Samsung SM-M356B reproduced both failures below. Use it as a reference device when available and record the build commit, device model, Android version, and results in [PROGRESS.md](../PROGRESS.md).

1. Install the signed APK while the camera is idle. Sign in with an approved test account and open **Enrolment** with the phone upright. Check that the front camera image and guide are upright and aligned.
2. Tap **Start recording** without moving the phone. Check that the image stays upright through the transition and while recording. Center your face in good light, verify the guide turns green, and follow the prompts to check that pose progress responds.
3. Review local playback for upright video, then discard the test clip. If timed fallback appears while a face is in view, check the device logs before passing this release check.

### Sideways preview when recording starts

On the Samsung, CameraX StreamSharing changed the preview buffer from 1280×720 to an already rotated 720×1280 when video and analysis ran together. The plugin applied its original sensor rotation again, turning the preview sideways. A Flutter widget test that held the preview rectangle steady could miss this native buffer change. See [Flutter issue #180075](https://github.com/flutter/flutter/issues/180075).

[The shared preview](../packages/capture/lib/src/live_preview.dart) checks the actual CameraX buffer size. If recording supplies a portrait buffer and the surface does not apply its own rotation, it uses the native texture and its aspect ratio for both the image and overlays. The normal plugin path remains the fallback. Keep this condition tied to the native buffer and surface. Recheck both signed APKs on the affected phone before removing the workaround after a CameraX update.

### Live guidance unavailable in release

R8 removed the no-argument constructors of ML Kit registrars loaded through reflection. The release log showed `ComponentDiscovery` failures with `NoSuchMethodException`, followed by `ImageError: Getting Image failed`. Both Android release configurations load the [shared ML Kit keep rules](../packages/capture/android/mlkit-keep.pro). Preserve those rules and both references when changing Android packaging.

After the test, filter Logcat to the Student app process. Run the command while the app is still open.

```sh
student_pid=$(adb shell pidof -s dev.facetrack.student)
adb logcat -d --pid="$student_pid" |
  rg 'Could not instantiate com.google.mlkit|NoSuchMethodException|Getting Image failed|detectFacesImageByteArray|onSuggestedStreamSpecUpdated'
```

On the verified build, ML Kit processed frames before and during recording without the earlier initialization or conversion errors. The user confirmed the upright preview and working live guidance on the Samsung on 10 November 2026. The test covers that device and build. Keep the visual check even when logs show detector calls, since detector activity alone cannot establish correct rendering or pose progress.

## Teacher Android signed release check

Use a signed release APK and a consenting test session on a physical phone after camera, detector, Flutter, CameraX, or Android packaging changes. Teacher reproduced the same native buffer change on the Samsung rear and front cameras, alongside the same ML Kit initialization failures. It uses the shared preview and keep rules described above.

1. Open **Scan classroom**. Use the rear camera in portrait and check that a nearby, well-lit face gets a box before recording starts.
2. Start the scan without moving the phone. Check that the preview stays upright and the box stays aligned, follows slow movement and turns green when the face holds steady in frame. Green indicates framing quality. Recognition suggestions arrive separately after a segment is processed.
3. Keep a face in view across one segment transition, then move it out of frame and verify the box clears. Stop the scan, verify the clip plays upright, and repeat with the front camera and in landscape where supported.
4. Filter Logcat as above using `dev.facetrack.teacher`. Check that ML Kit is called during the recording and that the earlier initialization and frame conversion errors are absent. Record each device and build result in [PROGRESS.md](../PROGRESS.md).

## Check in Chrome or Edge

1. Attach an external webcam. Grant camera permission to the HTTPS app (or loopback development origin); reload after attaching if the browser does not update its device list.
2. In Student enrolment, check that the recorder fits the viewport without swallowing the controls and the outline fits the displayed face. Try both the front and another camera. If the camera arrives sideways, use **Rotate preview** to orient the display. The recorded stream and live face analysis still use the source orientation, so physically orient a sideways webcam before collecting a valid clip. In Teacher session capture, press **Open camera**, frame the room, then press **Start recording**; the preview should remain within its compact card.
3. Check preview, record, playback, **Retake recording** and upload separately for the built-in and external devices. Confirm a retake resumes moving video and no camera change is offered during recording.
4. Deny permission once and unplug the selected camera once; verify the UI gives a recoverable error and another camera can be chosen.

These are hands-on acceptance steps. Flutter tests and browser JavaScript syntax checks do not establish external-camera compatibility on a particular device.

## Continuous scan acceptance

Open Student capture before recording and verify the guide appears upright in portrait and landscape and reacts to a visible face. Start recording and confirm pose progress begins with the server challenge, not the earlier preview.

Open Teacher **Scan classroom** on Android and Chrome. Check rear camera preference, full-screen controls, tracking boxes during a slow pan, green framing only after a stable hold, stale boxes clearing within one second, and one Start/Stop scan. Watch suggestions arrive after each private segment processes; verify previously recognized students stay suggested after later segments, manual choices stay locked, and publication remains explicit. Test network interruption and retry of the same kept part, queue backpressure, and closing after all uploads. Measure live analysis cadence, preview stutter, upload and suggestion delays on a consenting group. Check recorded file orientation and actual decoder compatibility; automated fake-recorder tests do not establish codec acceptance.
