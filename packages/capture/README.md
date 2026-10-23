# Shared guided capture

Student enrolment uses `GuidedCamera` for a front-first server-issued 15-second pose sequence with audio disabled, `PendingClips` for private recoverable native recordings, platform playback, and `ResumableUpload` for signed TUS transfer. This package does not grant identities, activate templates or determine attendance.

Native recordings are copied into app-private storage and deleted on completion/cancellation/logout/expiry; web blobs are temporary and do not survive page closure. TUS sends only the publishable API key and object-scoped upload signature to the verified direct Storage endpoint. Resume URLs are checked against that origin/path; no user JWT or server Storage secret enters this transport. Progress/checkpoints support interruption recovery without overwriting an existing object.

Run `../../scripts/flutter test` from this package for the three synthetic transport tests. `tool/probe_upload.dart` is an explicitly opt-in live synthetic transport diagnostic; it requires `FACETRACK_PROBE_FILE` pointing to an ignored private JSON file with a disposable grant/key. Run with `flutter test tool/probe_upload.dart`, then delete the disposable object and grant. It is not part of routine tests and never submits synthetic video to the face worker.
