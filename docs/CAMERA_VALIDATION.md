# Camera selection validation

The Student and Teacher apps list cameras reported by the OS or browser before recording. An external USB camera appears only when the platform exposes it. The selected camera is fixed for each clip; changing cameras during an active recording is disabled.

## Check on a physical Android phone

1. Connect the phone, authorize USB debugging, and run `scripts/android-connect` to restore API reverse forwarding for local development.
2. Start the Student and Teacher apps using the public Flutter config described in `docs/INSTALLATION.md`. Sign in with approved test accounts.
3. Attach any external camera supported by the phone and Android camera API. Open Student face enrolment and Teacher session capture separately. Confirm the camera selector appears when two or more devices are reported.
4. Select each listed camera before recording. Check that the preview changes, then make a short test clip and play it back before upload. Do not use another person's face without consent.
5. Confirm the selector is disabled during recording and becomes available again after the clip is discarded. Disconnect the external camera and confirm the built-in camera still works.

## Check in Chrome or Edge

1. Attach an external webcam. Grant camera permission to the HTTPS app (or loopback development origin); reload after attaching if the browser does not update its device list.
2. In Student enrolment, choose a camera in the browser capture panel, then press **Start recording**. In Teacher session capture, choose the camera before pressing Record.
3. Check preview, record, playback and upload separately for the built-in and external devices. Confirm no camera change is offered during recording.
4. Deny permission once and unplug the selected camera once; verify the UI gives a recoverable error and another camera can be chosen.

These are hands-on acceptance steps. Flutter tests and browser JavaScript syntax checks do not establish external-camera compatibility on a particular device.
