# FaceTrack Teacher

The Teacher app runs on Android and the web. Faculty manage assigned subjects, approve join requests, review face enrolment, take attendance, publish results and download private reports. The API checks active memberships and assignments. Accounts with an active admin membership also see **Admin**.

## Run locally

Follow the [installation guide](../../docs/INSTALLATION.md) to start the API and prepare the public Flutter configuration. From `apps/teacher` on macOS or Linux:

```sh
../../scripts/flutter pub get --enforce-lockfile
../../scripts/flutter run -d chrome --web-hostname localhost --web-port 5300 --dart-define-from-file=../../.local/flutter/development.json
../../scripts/flutter test
node --test test_web/classroom_capture_test.cjs
```

For local Android use, run `../../scripts/android-connect` after connecting or reconnecting the authorized phone. The app ID is `dev.facetrack.teacher`. See [Windows setup](../../docs/WINDOWS_SETUP.md) for PowerShell commands and [Azure deployment](../../docs/DEPLOY_AZURE.md#phone-apps-release-build) for signed APKs that use HTTPS. Check the [project checkpoint](../../PROGRESS.md) for physical-device results.

## Faculty workflows

- **Subjects** links to assigned subjects, pending work, attendance summaries and the faculty dashboard. The dashboard uses published, assessed sessions and offers semester-level CSV export.
- **Face enrolments** shows eligible students awaiting review. Open the private video, verify identity and all five poses, and approve with both confirmations or reject with a reason. Refresh on version conflict. Expired footage requires fresh enrolment.
- **Sessions** creates a manual session or opens **Import timetable**. Use **Download CSV template**, add any missing room code, and use **Choose CSV** to validate the file. The CSV must be at most 1 MiB. Review the rows and confirm a matching date in the term. The import creates sessions for that day and retains the weekly rules. See [timetable architecture](../../MASTER_DESIGN.md#10-timetable-integration) for revision and overlap rules.
- **Attendance queries** lists open queries for assigned subjects. Rejection requires a reason. Acceptance creates a new corrected publication and report.
- **Reports** offers CSV and PDF downloads through short-lived private links after closing or publishing a session. Email requires a configured, permitted Resend sender.

## Capture and publish

1. Open the session to freeze its approved roster. Select **Scan classroom**, then **Start scan** with only consenting participants in view. The scanner captures short segments with audio off. Green boxes indicate good framing. Recognition suggestions appear after processing.
2. Select **Stop scan** to release the camera and finish any uploads. Retry an interrupted upload from the recovery screen. If the reservation has expired, discard the unsent segment and record again while the session is open or continue to manual review.
3. Select **Go to review**. A usable capture defaults matched students to **Present** and other approved roster members to **Absent**, including those outside the footage. Without usable footage, select a mark for each student manually.
4. Review or change the marks, then select **Publish attendance**. Published results are immutable. A later correction requires a reason and creates another revision.

Use the [Teacher signed Android check](../../docs/CAMERA_VALIDATION.md#teacher-android-signed-release-check) and [continuous scan acceptance](../../docs/CAMERA_VALIDATION.md#continuous-scan-acceptance) for release testing.

## Administration

Use **Overview** for the setup checklist and institute statistics. **Academic setup** manages terms, subjects, class groups and allocations. **People** manages faculty, students and their logins. **Access** assigns faculty and manages roles. Select **Take the tour** to see the guided walkthrough.

## Preserved local camera spike

Product sign-in is the default entry point. The separate prototype saves local recordings and sidecars.

```sh
../../scripts/flutter run -d chrome -t lib/main_spike.dart --web-hostname localhost --web-port 5302
../../scripts/flutter build web -t lib/main_spike.dart --output build/spike
```

New class groups require a term, branch and semester. Faculty records use full name and official email. A password is needed only when creating a login.
