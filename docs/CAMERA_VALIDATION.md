# Camera validation

The Student and Teacher apps list cameras reported by the OS or browser before recording. An external USB camera appears only when the platform exposes it. The selected camera is fixed for each clip; changing cameras during an active recording is disabled.

## Check on a physical Android phone

1. Connect the phone, authorize USB debugging, and run `scripts/android-connect` to restore API reverse forwarding for local development.
2. Start the Student and Teacher apps using the public Flutter config described in `docs/INSTALLATION.md`. Sign in with approved test accounts.
3. In Student face enrolment, open the full-screen camera. Check portrait and landscape, the guide and face outline alignment, all five instructions, and the visible cancel action. Cancel once mid-recording and confirm no new clip appears.
4. In an open Teacher session, press **Open camera** and verify the rear camera is selected. Try a different camera, tap the preview to focus, and toggle the torch on a supported camera. Confirm closing the preview switches off the torch.
5. With a consenting group, start a classroom recording and walk or pan slowly. Check that green outlines follow well-framed faces and clear within about a second when analysis stops. Look for dropped preview frames or recording stutter. Confirm the clip saves and plays back even if the live guidance reports it is unavailable.
6. If Android exposes an external camera, repeat selection and playback with it. Confirm camera switching is disabled during a clip and returns after discarding it.

## Check in Chrome or Edge

1. Attach an external webcam. Grant camera permission to the HTTPS app (or loopback development origin); reload after attaching if the browser does not update its device list.
2. In Student enrolment, check that the recorder fits the viewport without swallowing the controls and the outline fits the displayed face. Try both the front and another camera. If the camera arrives sideways, use **Rotate preview** to orient the display. The recorded stream and live face analysis still use the source orientation, so physically orient a sideways webcam before collecting a valid clip. In Teacher session capture, press **Open camera**, frame the room, then press **Start recording**; the preview should remain within its compact card.
3. Check preview, record, playback, **Retake recording** and upload separately for the built-in and external devices. Confirm a retake resumes moving video and no camera change is offered during recording.
4. Deny permission once and unplug the selected camera once; verify the UI gives a recoverable error and another camera can be chosen.

These are hands-on acceptance steps. Flutter tests and browser JavaScript syntax checks do not establish external-camera compatibility on a particular device.

## Continuous scan acceptance

Open Student capture before recording and verify the guide appears upright in portrait and landscape and reacts to a visible face. Start recording and confirm pose progress begins with the server challenge, not the earlier preview.

Open Teacher **Scan classroom** on Android and Chrome. Check rear camera preference, full-screen controls, tracking boxes during a slow pan, green framing only after a stable hold, stale boxes clearing within one second, and one Start/Stop scan. Watch suggestions arrive after each private segment processes; verify previously recognized students stay suggested after later segments, manual choices stay locked, and publication remains explicit. Test network interruption and retry of the same kept part, queue backpressure, and closing after all uploads. Measure live analysis cadence, preview stutter, upload and suggestion delays on a consenting group. Check recorded file orientation and actual decoder compatibility; automated fake-recorder tests do not establish codec acceptance.
