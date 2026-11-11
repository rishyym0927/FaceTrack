# FaceTrack Student

The Student app runs on Android and the web. Students sign in with an institute-provisioned account, link an approved identity when prompted, and request access to a subject with a faculty join code. Faculty must approve the request before the student joins the roster.

See the [user guide](../../docs/USER_GUIDE.md) for hosted sign-in and Android installation.

## Run locally

Follow the [installation guide](../../docs/INSTALLATION.md) to start the API and prepare the public Flutter configuration. From `apps/student` on macOS or Linux:

```sh
../../scripts/flutter pub get --enforce-lockfile
../../scripts/flutter run -d chrome --web-hostname localhost --web-port 5301 --dart-define-from-file=../../.local/flutter/development.json
../../scripts/flutter test
```

For local Android use, run `../../scripts/android-connect` after connecting or reconnecting the authorized phone. The app ID is `dev.facetrack.student`. See [Windows setup](../../docs/WINDOWS_SETUP.md) for PowerShell commands and [Azure deployment](../../docs/DEPLOY_AZURE.md#phone-apps-release-build) for signed APKs that use HTTPS. Check the [project checkpoint](../../PROGRESS.md) for physical-device results.

## Face enrolment

1. Open **Enrolment**, read the versioned notice, and decide whether to consent.
2. Select **Record guided video** and follow the five pose prompts with audio off. Let the recorder stop automatically after about 12–25 seconds. The saved video must contain at least 10 seconds. Review the clip and retake it if needed.
3. Select **Upload for processing**. A faculty member reviews identity and poses before the resulting template can be used.
4. If an upload is interrupted, retry the same recording while the reservation is valid. Native pending clips are stored privately and can survive an app restart. Browser clips are temporary. An expired 15-minute reservation requires a fresh recording.
5. Use the consent withdrawal action to revoke templates and queue deletion of private media.

Before distributing a signed release with camera, detector or packaging changes, run the [Student Android release check](../../docs/CAMERA_VALIDATION.md#student-android-signed-release-check).

## Attendance

The **Attendance** tab shows published records first, with trends below. Open an approved subject for its published history, revision notes, and summary. Only assessed published sessions count toward the attendance percentage.

A student can submit a written query for their latest published **Absent** result and see its resolution. Faculty acceptance publishes an immutable correction.
