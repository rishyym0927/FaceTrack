# Camera validation

The Student and Teacher apps list cameras reported by the OS or browser before recording. An external USB camera appears only when the platform exposes it. Choose the camera before recording. For a classroom scan, the selection remains fixed through all its segments.

## Check on a physical Android phone

1. Connect the phone, authorize USB debugging, and run `scripts/android-connect` to restore API reverse forwarding for local development.
2. Start the Student and Teacher apps using the public Flutter config described in `docs/INSTALLATION.md`. Sign in with approved test accounts.
3. In Student face enrolment, open the full-screen camera. Check portrait and landscape, the guide and face outline alignment, all five instructions, and the visible cancel action. Cancel once mid-recording and confirm no new clip appears.
4. In an open Teacher session, expand **Record a single clip**, select **Open camera**, and verify the rear camera is selected. Try a different camera, tap the preview to focus, and toggle the torch on a supported camera. Confirm closing the preview switches off the torch.
5. With a consenting group, start a classroom recording and walk or pan slowly. Check that green outlines follow well-framed faces and clear within about a second when analysis stops. Look for dropped preview frames or recording stutter. Confirm the recording can proceed if live guidance is unavailable. Use **Record a single clip** to verify local playback.
6. If Android exposes an external camera, repeat selection and playback with it. Confirm camera switching is disabled during a clip and returns after discarding it.

## Student Android signed release check

Run this check on a physical phone with the signed release APK before distributing changes to camera capture, Flutter or CameraX, ML Kit, or Android release packaging. The Samsung SM-M356B reproduced both failures below. Use it as a reference device when available and record the build commit, device model, Android version, and results in [PROGRESS.md](../PROGRESS.md).

1. Install the signed APK while the camera is idle. Sign in with an approved test account and open **Enrolment** with the phone upright. Check that the front camera image and guide are upright and aligned.
2. Tap **Start guided recording** without moving the phone. Check that the image stays upright through the transition and while recording. Center your face in good light, verify the guide turns green, and follow the prompts to check that pose progress responds.
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

1. Open **Scan classroom**. Use the rear camera in portrait. Check whether a nearby, well-lit face gets a framing box before recording, then confirm guidance during the scan.
2. Tap **Start scan** without moving the phone. Check that the preview stays upright and the box stays aligned, follows slow movement and turns green when the face holds steady in frame. Green indicates framing quality. Recognition suggestions arrive separately after a segment is processed.
3. Keep a face in view across one segment transition, then move it out of frame and verify the box clears. Tap **Stop scan** while a segment is uploading. The preview and camera indicator should close promptly while upload progress remains visible. Check upright playback using **Record a single clip**, then repeat the scan with the front camera and in landscape where supported.
4. Filter Logcat as above using `dev.facetrack.teacher`. Check that ML Kit is called during the recording and that the earlier initialization and frame conversion errors are absent. Record each device and build result in [PROGRESS.md](../PROGRESS.md).

## Check in Chrome or Edge

1. Attach an external webcam and grant camera permission on the HTTPS app or loopback development origin. Reload if the browser does not update its device list.
2. In Student **Enrolment**, select **Record guided video**. Check that the recorder fits the viewport, the controls remain visible, and the outline fits the face. Try the built-in and external cameras. **Rotate preview** changes only the display. Physically orient a sideways webcam before collecting a valid clip.
3. In Teacher **Sessions**, test **Scan classroom** and the optional single-clip recorder separately. The scan opens a dedicated preview. The single-clip path uses a compact preview card. Check preview, recording and playback with each available camera, and verify **Retake recording** resumes moving video in the single-clip recorder.
4. Deny camera permission, then retry after granting it. Unplug the selected camera and confirm the app gives a recoverable error or closes the camera cleanly. Reopen with another camera. Confirm that the selector is unavailable during recording.

## Continuous scan acceptance

Use a disposable class session and consenting test accounts. Repeat on Android and Chrome and record the device, browser, build commit, and result in the [project checkpoint](../PROGRESS.md).

1. In Student enrolment, verify the guide is upright in portrait and landscape and reacts to a visible face. Start recording and confirm the server challenge begins independently of the earlier preview.
2. In Teacher, open **Scan classroom** and verify rear camera preference, the framing overlay while panning slowly, and that stale boxes clear within about one second. Verify that green boxes appear after a stable hold. Record preview stutter, upload delay and time to recognition suggestions.
3. Stop during a segment upload. Confirm the camera closes and progress remains visible. Check that a final segment under 10 seconds is discarded. On Android, confirm recording pauses when the upload queue fills. In Chrome, confirm each recorded part uploads before the next begins. Use the single-clip recorder to check orientation and playback. For scan segments, confirm that the worker decodes the clip successfully.
4. Interrupt the network during transfer and retry the same retained part. Verify that the app can confirm a completed transfer without duplicating it. If the reservation expires, confirm the UI offers discard instead of an unusable retry. In a disposable session, verify camera and pending-clip cleanup on route exit or logout during upload and retry.
5. Leave one approved participant outside the camera view. After usable footage processes, confirm a matched participant starts as draft **Present** and the unseen participant as draft **Absent**. Verify that later segments preserve prior matches and teacher edits. Review the marks and publish explicitly. In Student, check that each participant sees only their own result.
6. Repeat with no usable footage and confirm that publishing requires a manual **Present** or **Absent** for every roster member.

Flutter widget tests and the [browser scanner tests](../apps/teacher/test_web/classroom_capture_test.cjs) use synthetic inputs. Device checks establish whether camera permissions, overlays, recording and playback work on the tested hardware.
