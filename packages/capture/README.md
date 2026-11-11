# Shared guided capture

This package provides native camera setup, preview and overlays, recording, playback, private pending-clip storage, and signed resumable uploads. The product apps coordinate consent, review and attendance with the API.

- **Student Android** uses `GuidedCamera(enrollmentGuidance: true)` and ML Kit for the server-issued five-pose challenge. Native recordings can be retained in private app storage while the student retries an upload.
- **Student web** uses one browser stream for preview, local MediaPipe pose guidance and WebM recording. The recording lasts 10–25 seconds. If live guidance is unavailable, timed prompts let the student finish a clip for faculty review. Browser clips do not survive page closure.
- **Teacher Android** uses the shared camera and an ML Kit face analyzer for live framing. The app pauses recording under upload backpressure. **Teacher web** uses `classroom_capture.js` for MediaPipe framing and a record/upload loop. Both support continuous classroom scans with audio off. The single-clip recorder remains available from the session.
- **Upload** uses `ResumableUpload` for signed TUS requests to the verified Storage origin. The browser or app sends the publishable key and object-scoped upload signature. Resume URLs are checked against the expected origin and path. If a prior transfer may have finished, the app can confirm it before retrying the transfer.

Both web apps load the pinned MediaPipe Tasks Vision 0.10.35 runtime from jsDelivr and versioned models from Google's public model host. Live detection runs locally. If those dependencies fail to load, users can still record. Bundling and integrity pinning remain deployment hardening work.

The shared Android preview detects pre-rotated recording buffers, and both release builds include the [ML Kit keep rules](android/mlkit-keep.pro). See [camera validation](../../docs/CAMERA_VALIDATION.md) for failure signatures and the physical tests required after camera, detector or packaging changes.

From `packages/capture`, run `../../scripts/flutter test` for synthetic guidance, recovery and transport tests. The opt-in `tool/probe_upload.dart` diagnostic requires `FACETRACK_PROBE_FILE` pointing to an ignored private JSON file with a disposable grant and publishable key. Run `../../scripts/flutter test tool/probe_upload.dart`, then remove the disposable object and grant. The probe does not submit video to the face worker.
