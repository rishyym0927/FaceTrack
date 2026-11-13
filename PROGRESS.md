# FaceTrack development checkpoint

**Reviewed:** 13 November 2026 (Asia/Kolkata)

## Pending-media recovery and attendance response — 13 November 2026

- Implemented Student web IndexedDB recovery for one private pending enrolment clip and upload checkpoint; Teacher Android now retains queued classroom segments and idempotent upload state per account/institute/session for retry after route or process interruption. Logout, explicit discard, success and 24-hour expiry clean up pending media. The original retention time survives checkpoint updates.
- Both web capture flows now use pinned same-origin MediaPipe runtime and model assets with provenance and licence files. Chrome initialized both models with external hosts blocked; a browser reload recovered and cleared a Student test clip. Student attendance subjects now include enrolled subjects outside the loaded history page; Student history omits biometric similarity and uses per-student JSON extraction without a schema migration.
- Local checks: 65 API, 56 worker, 72 shared, 22 Student, 85 Teacher and 21 capture tests passed; Flutter analysis and API/worker Ruff clean; nine Teacher browser scanner tests passed. Both web and signed arm64 Android builds completed during implementation. A synthetic local 5,000-session × 25-mark JSON extraction check took 17.744 ms with array expansion and 16.519 ms with the selected path query; this is not an end-to-end or production latency claim.
- Pushed `878b8e7` and deployed the API, worker and both web apps to Azure. The deployment script reported healthy API, worker and agent containers and verified both web entry points. Hosted Student and Teacher guidance-model SHA-256 values matched the vendored files; `/health/ready` returned success.
- Built and verified v2-signed Student and Teacher arm64 APKs, version 0.1.1 (build 2002), in `Downloads/FaceTrack-releases` with `878b8e7` in each filename. Installed both in place on the connected Samsung SM-M356B with no active camera client; Android reported success and both apps launched without a sampled fatal exception. Signed camera orientation/guidance, interrupted upload and participant-based end-to-end acceptance still require hands-on checks. Do not infer them from installation or startup.

## Frontend modernization, first verified stage — 13 November 2026

- Implemented shared Notifications navigation and labelled session restoration, Teacher subject-tab deep links and retryable join-request failure, batched Teacher Account statistics, and Student subject join/history and web camera focus/guidance improvements in commits `3be26df`, `e0f2216`, and `0647bfc`.
- Shared 72, Student 21, and Teacher 84 Flutter tests passed. Flutter analysis passed for shared, Student and Teacher. Nine browser scanner tests and Student browser script syntax passed. Both production web builds completed. Physical Android and iPhone camera checks remain pending. The earlier uncommitted Teacher capture-quality edits remain outside these commits.
- Remaining approved plan work: independent error states throughout every list, attendance history and Admin lazy loading, notification query bounds, stage-by-stage responsive and screen-reader walkthroughs, and matched Chrome and Android performance baseline. The versioned consent/manual-attendance wording conflicts with current new-session eligibility and needs an explicit policy decision before revision.

## iPhone TestFlight preparation

- Generated separate Student and Teacher iPhone projects with camera permission strings, distinct app IDs, existing FaceTrack icons and iOS 15.5 deployment targets for the installed ML Kit dependency. Added AVFoundation BGRA frame handling for live guidance and documented [build, signing and TestFlight steps](docs/IOS_TESTFLIGHT.md).
- Flutter analysis passed for both apps and capture. Student 21, Teacher 84 and capture 21 local tests passed. Xcode project and plist syntax and Podfile syntax checked. Both unsigned arm64 release builds compiled with Xcode 27.2 and CocoaPods 1.17.0. Verified bundle IDs and iOS 15.5 minimum in the built apps. On-device acceptance remains pending.
- Next: confirm Apple Developer Program team access, configure signing, create both App Store Connect records, and upload signed archives. Use a consenting tester’s iPhone for physical camera acceptance. This Mac has no valid signing identity and no connected iPhone.

## Performance rollout, first stages

- Azure API `521224b` adds checkout timings to request logs, combines restricted-role probes, batches capture eligibility, recognition input and manual marks, aggregates per-offering attendance in SQL, and serves a compact authorized Teacher work summary. Both Azure web apps use `fa58708`, which uses the summary for Teacher notifications and the home attention card, queues a forced notification refresh behind an older request, and shows Student attendance before supporting details with on-demand older pages. The prior API sources were retained in the private Azure release directory.
- A read-only Mac comparison using six hosted subjects replayed the old API request pattern with two concurrent subject reads. It used 25 requests, 6,245 decoded response bytes and 14.89 seconds in one run. The new summary used one request, 2,833 decoded bytes and a 1.00-second median over three samples. This measures API data retrieval on the same deployment, not complete app startup or browser transfer bytes. Azure confirmed timing logs and readiness. 65 API, 84 Teacher, 21 Student, 72 shared Flutter and 9 browser scanner tests passed. Frozen ML receipt passed 16/16.
- Azure revision `065d635` adds one published-attendance dashboard request per page of up to 25 subjects, includes final report delivery state in the report list when requested, and skips roster reads when an idle session's version is unchanged. Pending recognition still refreshes full details and draft choices stay in the app. Existing API calls retain their original response shapes. API readiness, both web release assets, and base worker and agent health passed after deployment. Local checks passed for 65 API, 84 Teacher, 21 Student, nine browser scanner tests, Flutter analysis for both apps, and the 16-file freeze receipt.
- Remaining: benchmark page and workflow latency on matched Chrome and signed Android staging fixtures. Report revision polling, browser capture/upload overlap, recognition completion batching, and evidence-based index and worker tuning are open. No physical Android or iPhone capture acceptance was run for this release. That web release did not include a native iOS build. The hosted capture flows require WebM recording, which Safari added in iOS 18.4.

## Attendance eligibility and loading — 13 November

- Deployed `022c020` to Azure for both web apps and the API. New sessions freeze only subject-approved students with compatible approved face enrolments. Older session snapshots and publications retain their original roster. Teacher Students now has separate approved and pending-face lists. Live ADSA responses returned 10 approved and 15 pending from 25 memberships, with `no-store`.
- Azure access-log sample showed approximately 9-second p95 on frequent faculty requests. Removed duplicate home subject-work fan-out, deferred unopened tab lists, replaced per-student session-open queries with a set-based insert, and removed completed-response caching for Student subject enrolments and Teacher attendance summaries. Three post-deploy ADSA calls took 1.27–1.60 seconds from the Mac; no matched page-load benchmark was run.
- 64 API, 84 Teacher, 21 Student and 72 shared-core tests passed, with clean analysis and API lint. Physical Android walkthrough and production attendance publication were not exercised. The consent notice still references a manual-attendance fallback. Confirm and update the participant-facing wording before wider rollout.

## Teacher approved roster filter — 13 November

- Deployed API revision `138d30f` to Azure. The existing active-roster query now requires current subject membership, faculty-approved face enrolment, active consent and compatible stored templates. Unfiltered roster and session attendance are independent of the display filter.
- All 63 API tests passed against local PostgreSQL. Authenticated production pagination returned exactly the 10 eligible ADSA students across four pages, matching a read-only database check. The unfiltered roster returned 25. Both web entry points and API readiness passed. Azure retained the prior API files under the private release staging directory for rollback. Client screen rendering was not independently exercised in this release.

## User and repository documentation — 11 November

- Added a single entry point for hosted web, signed Android installation and role workflows. Updated repository setup, camera validation, Azure worker and report troubleshooting, Android release packaging and the dated pilot budget links.
- Verified the macOS setup script in a fresh checkout, both Compose configurations, Markdown links and anchors, OpenAPI export, the frozen model receipt, browser scanner tests and the three hosted health/page endpoints. Fresh Windows/Linux host installs and another authenticated camera-to-publication walkthrough remain open.

## Teacher capture review cleanup — 11 November

- Removed the successful frame-detection count banner from attendance review. Kept retake guidance for unclear footage and the roster-based attendance totals. All 84 Teacher tests passed and analysis was clean. Installed the signed `FaceTrack-Teacher-review-cleanup.apk` on the Samsung at 19:59 IST with the camera idle. Verified that both installed APKs match the latest signed files by SHA-256.
- Enabled report generation on the existing Azure project worker after two final reports stayed queued. Both jobs succeeded and both report records reached `ready`.

## Guided enrolment and classroom capture — 11 November

- Added the fifth sample Student login, enrolled it in `SAMPLE-101` and verified live sign-in and membership. The test subject has two enrolled students and one active face enrolment. Approve the second sample enrolment with the participant’s consent, then open a new session to freeze the updated roster. The existing open session contains one eligible student.
- The worker reported `CLIP_TOO_SHORT` on a recent hosted enrolment. Android and web now aim for 12–25 seconds against the frozen 10-second encoded minimum. Confirmed Chrome recorded 12.001 seconds with fake camera input and that the worker’s media probe accepted it. Classroom capture explains the two-enrolment requirement before opening the camera and gives specific instructions for known upload failures.
- Enabled classroom recognition on the existing scoped Azure project worker. Verified 21 capture, 21 Student, 84 Teacher, 72 shared-core and nine browser scanner tests, plus clean Flutter analysis in all four Flutter packages. A physical-device recording and an end-to-end scan with two consenting, enrolled participants remain open.
- Pushed `f902ac8` and deployed both web apps on Azure. Served camera scripts matched the commit and API readiness passed. Verified both signed arm64 APKs and installed in place on the Samsung with the camera idle at 19:43 IST. Release APKs are in `Downloads/FaceTrack-releases` with `f902ac8` in their names.

## Android release and pilot budget — 11 November

- Built both production-configured arm64 APKs from `ed19516`, which has the same Android app code as deployed release `052669f`. Verified both signatures and installed in place on the Samsung SM-M356B with the camera idle. Android reported successful updates at 19:07 and 19:08 IST. Both APKs are in `Downloads/FaceTrack-releases` with `052669f` in their names. Signed-in and camera checks remain open for this install.
- Documented the five-month, 100-student funding estimate and verified the Azure VM, disk and IP against the current subscription configuration and Central India retail rates. See [IGDTUW pilot budget](docs/IGDTUW_PILOT_BUDGET.md).

## IGDTUW test accounts — 11 November

- Created a separate hosted IGDTUW institute, Semester 1 (1 August–15 December 2026), one CSE–AI group, room 306 and five offerings. Demo institutes remain active.
- Provisioned 25 roster students and four faculty with separate initial passwords, 125 approved course enrolments and four faculty assignments. Mathematics for AI has no faculty assignment. Verified one Student and one Teacher login through hosted Auth and the production API, each with only the IGDTUW membership. The two additional Student accounts need official enrolment numbers. The MTech roster and the two pending Student accounts received no admin access. Separately, four synthetic accounts were assigned to IGDTUW only, with one Teacher/Admin and three Student roles. Live sign-in and role checks passed for all four.
- Added one synthetic Student login and the `SAMPLE-101` testing subject under IGDTUW, with a separate test group. Verified live Student sign-in, active enrolment, and visibility of the subject and its sample-only roster to the assigned sample Teacher. Credentials are in the private local handoff.
- Resolved the missing profile and worker configuration behind the guided enrolment 503 for the unofficial, non-commercial student research project. Registered the existing frozen model/profile and started an enrolment-only agent and CPU worker on the Azure VM. Verified the model/profile in the Azure runtime and the scoped worker heartbeat. The project pair uses Redis database 4, a separate temporary directory and the private Docker network. The Azure operator's `.facetrack-project-enrolment` directory holds the private configuration and artifacts. Containers restart automatically and use the worker image selected at provisioning, so refresh them when updating the worker and rotate the scoped credential before its 30-day expiry. Next acceptance check is guided capture, upload and processing by a consenting participant.

## Class setup without section labels or faculty employee numbers — 11 November

- Admin creates a class group with term, branch and semester. Faculty creation uses full name and official email, with an initial password only when creating a login. Faculty pickers and account views omit employee numbers. Student enrolment numbers remain required.
- The API supplies stable internal values for omitted legacy fields, preserving existing group labels, identifiers and database constraints. A blank section cell in the existing timetable CSV selects the default group. No migration is needed.
- Verified 63 API tests, 84 Teacher tests, 21 Student tests and 72 shared-core tests. Flutter analysis passed, and the Admin suite was rerun after the final faculty search wording. The OpenAPI snapshot was regenerated. Deployed API and both web apps together from `052669f`. Both sites passed served-artifact verification, public readiness returned HTTP 200, and API/worker/agent were healthy. Changed API modules and the deployed frozen profile matched local checksums. The authenticated Admin form creation walkthrough remains open.

## Documentation review — 11 November

- Consolidated setup around the installation guide, with platform, upgrade, camera and Azure runbooks for their specific workflows. Updated the API and worker references, product attendance rules and verified deployment status. Generated OpenAPI matched the checked-in contract. Relative links and heading anchors, Compose configuration, deployment activation tests and browser scanner tests passed.
- Documentation only. Authenticated device, classroom and staging rollback acceptance remain tracked below.

## Azure audit release — 11 November

- Pushed and deployed `d77202a` to Azure, including the remaining verified UI cleanup. Both web builds passed served HTML and JavaScript checksum checks. Public readiness, Student and Teacher returned HTTP 200. API, Redis, worker and agent were healthy, and both changed API modules matched the release.
- Live authenticated camera-to-publication and physical Android checks remain open.

## Audit fixes — 11 November

- Student attendance clears prior data and filters after access denial and exposes retries for temporary failures. Subject history loads all dispute pages independently. The overview labels a capped history. Teacher pending-work counts show partial failures and reject stale refresh responses.
- Timetable import rechecks faculty access and reservation ownership and purpose after Storage verification. Attendance history uses a stable session ordering with legacy cursor compatibility. All new publication revisions require binary marks. Existing legacy snapshots are retained, and a correction that would copy nonbinary marks returns `REVIEW_REQUIRED`.
- Classroom scan teardown releases the browser camera and cleans queued Android clips. Interrupted transfers try to confirm an existing upload first. Expired or invalid clips offer discard and camera errors offer restart.
- Web deploy stages both apps behind one release pointer and rolls back on smoke-check failure. Verified with three local deployment tests including incomplete transfer, HTTP serving and simulated post-switch failure. Azure staging rollback was not exercised. See the release entry above for production verification.
- Verified clean Flutter analysis across app core, capture, Student and Teacher. Passed 72 app core, 21 capture, 21 Student, 83 Teacher, 9 browser scanner, 62 API and 56 worker tests. API integration uses local PostgreSQL and mocked Auth HTTP. Both production-configured web builds and signed arm64 APKs passed. Chrome rendered 12 routes at 390 and 1440 px using fixture accounts and intercepted API data. APKs are in Downloads/FaceTrack-releases with audit-fixes-2026-11-11 in their names.
- Next live checks are an authenticated Android and Chrome walkthrough with a consenting recording, retry, review, publish and Student history, plus deployment rollback on a staging host. The phone was disconnected.

## Android and web UI cleanup — 11 November

| Screen or workflow | UI decision |
| --- | --- |
| Sign-in, account claim, institute selection, connection and restricted access | Use one scrollable form and compact role label. Keep field guidance, errors, retry, institute choices and access recovery. |
| Account and notifications | Show profile details once. Keep institute switching, sign-out, notification filters, unread state and refresh. Hide the idle notification summary on subject lists. |
| Student subjects and join dialog | Put Join subject above the subject list. Keep pending and declined states, join-code validation, refresh and the Attendance tab. |
| Student attendance and subject history | Put published records above expandable trends or summaries. Keep filters, attendance corrections, faculty notes, and query and resolution actions. |
| Student enrolment and camera | Keep consent, current state, pose progress, stop, cancel, clip playback, retry and withdrawal. Remove the duplicate workflow strip and camera sheet decoration. Keep timed guidance feedback and upload errors. |
| Teacher subjects and dashboard | Use a compact subject heading and preserve pending-work links, the Sessions tab, its upcoming list and secondary analytics. Keep join codes, roster approvals and enrolment review. |
| Teacher sessions, recording, review and published results | Remove repeated headings and the extra create action on empty lists. Keep open/close, capture guidance, upload progress and retry, binary decisions, manual overrides and Publish. |
| Timetable, reports, disputes and Admin | Put CSV selection first and collapse format help. Keep validation and confirmation. Keep report versions, downloads and retry, query reasons and resolution controls, and Admin forms and permissions. Open the Admin tour only on request. |

- Verified Flutter analysis for shared app core, Student and Teacher. Flutter tests passed (72 shared, 20 Student, 79 Teacher), including layout checks at 200% text, route guards, scan stop and upload retry, and attendance defaults. Local PostgreSQL API tests with mocked Auth HTTP passed (41 attendance, biometric and foundation tests), including join approval, unseen students and publication history.
- Built both production-configured Flutter web releases and verified signatures on both arm64 release APKs. Headless Chrome at 390 and 1440 px verified protected routes redirect to sign-in and rendered 12 main routes across both roles with synthetic Auth and API fixtures. Physical Android was disconnected. A live authenticated walkthrough with consenting camera capture and exhaustive dialog/state checks remain open. No production rollout was performed for this UI change.

## Session workflow and binary attendance — 10 November

- Follow-up requires single-click publication after successful processing. Review now defaults matches to Present and all other roster members to Absent, retains teacher edits, and publishes directly from the review button. This follow-up is local.

- Both signed APKs were installed in place on the connected Samsung SM-M356B while the camera was idle. Android confirmed Student at 21:54 and Teacher at 21:55 IST. The matching API and worker changes still await deployment and a live walkthrough.

- Teacher sessions now separate capture, review and publication. Stop scan finalizes a valid current segment or discards a tail under 10 seconds, releases the camera, and keeps pending uploads in a dedicated progress and retry view. The same separation applies to the browser scanner. Student pages bring published records above optional trends and show Present and Absent only.
- The full frozen approved roster gets draft Absent after usable footage for anyone without a corroborated match, including unseen students and those without a matchable template. Limited or failed later segments preserve previous evidence. With no usable footage teachers choose the marks manually. Finalize requires a binary mark for every roster row and no pending recognition. Older immutable publications and the attendance denominator policy are preserved.
- Verified locally with Teacher 79, Student 20, API 58, worker 56 and browser 6 tests. The focused local PostgreSQL scenario covers private capture acceptance, synthetic recognition, an unseen approved student without a template, a later limited clip, teacher publication and both students' own history. Android and browser stop tests cover camera release while uploads remain. Both Flutter analyses were clean and both release web builds and signed arm64 APKs passed. Changes are local. Next check is a consenting real capture on Android and Chrome using the updated API and worker, followed by teacher review and both student accounts. See [camera validation](docs/CAMERA_VALIDATION.md#continuous-scan-acceptance).

## Teacher Android camera repair — 10 November

- The user's Samsung SM-M356B reproduced sideways Teacher preview and missing tracking boxes. Teacher logs showed CameraX switching from 1280×720 to 720×1280 at recording start with both rear and front cameras, plus missing ML Kit registrar constructors and repeated image conversion failures.
- Both apps now share the guarded recording texture and ML Kit keep rules. A regression test exercises the Teacher rear preview switching to a portrait buffer and verifies that the box fits the displayed texture. Capture 21, Teacher 81 and Student 20 tests passed. Analysis was clean in all three. Both signed arm64 APKs built and their R8 maps retain the three missing constructors.
- Commit `fd1395f` was pushed. The corrected Teacher APK installed on the Samsung at 21:31 IST with the camera idle. The first test logged 62 detector calls across preview and recording, with zero repeats of the earlier initialization or frame conversion errors. Visual confirmation of tracking and upright preview, plus front camera, landscape and playback coverage, remains open. See the [Teacher camera release check](docs/CAMERA_VALIDATION.md#teacher-android-signed-release-check).

## Student Android camera diagnosis and repair — 10 November

- Physical Samsung SM-M356B retest disproved the previous preview change. CameraX logs show the preview switching from 1280×720 to an already rotated 720×1280 buffer when recording starts, matching Flutter issue #180075. Student Android now checks the native preview size and bypasses the plugin's extra transform only for that pre-rotated buffer on a surface that does not handle rotation itself.
- The signed release also logged missing reflective ML Kit registrar constructors and repeated image conversion failures. Keep rules preserve those constructors. The signed Student APK from `1efb093` verified and installed in place while the camera was idle. The phone logged 47 face detector calls across preview and recording, with zero repeats of the earlier initialization or image conversion errors. The user confirmed that the preview stayed upright and live guidance worked on the Samsung SM-M356B on 10 November.
- Capture 20 and Student 20 tests passed, analysis clean in both, and the Student web release built. The [signed APK regression check](docs/CAMERA_VALIDATION.md#student-android-signed-release-check) is required before distributing relevant Android changes. Phase 3B recovery and other device coverage remain open.

## Earlier Student camera attempt — 10 November

- Commit `006d700` aligned the active pose chip with the timed prompt and kept the Flutter preview rectangle in portrait. Both web apps deployed from that commit and returned HTTP 200. The installed APK still showed a sideways camera image and unavailable live guidance on the Samsung. Those failures required the native buffer and release packaging fixes in `1efb093`.

## Camera follow-up — 10 November

- In-progress review found that native classroom preview analysis did not resume after each recorded segment, so green framing could disappear while uploads paused the scan. It now resumes while the camera remains open. Student's face guide now turns green when one face is framed and sufficiently lit, including before recording, rather than waiting for a completed pose hold. Teacher scan controls distinguish an active 15-second segment, a queued-upload pause, and finishing. The teacher still explicitly ends the continuous scan with Stop; Student recording automatically ends at 25 seconds or after all verified poses and 10 seconds.
- Capture 19, Student 20, Teacher 81 tests passed. Student and Teacher Flutter analysis found no issues. Both release web apps and both signed arm64 APKs built. Commit `c241808` was pushed; web-only deployment completed and Student, Teacher and API readiness returned HTTP 200. Both APKs installed successfully on the connected phone after confirming zero active camera clients, and both packages are present. Live guidance, orientation, recording and moving-classroom tracking still need a consenting on-device and authenticated browser check; automated builds cannot prove camera behavior.

## Continuous classroom scan — 10 November

- One Start/Stop scan now uses automatically recorded, private 12-second browser or up-to-15-second Android segments. Local live face boxes follow visible faces; green means well framed. Teacher sees enrolled-student suggestions only after each segment is uploaded and processed; no temporary track ID is treated as an identity, and publication remains a teacher action. At most two Android segments wait including the active upload; a full queue pauses capture. Browser keeps the preview alive during its single-segment upload. Retry retains the same media and upload mutation/resume state. A 429 capture quota waits and retries for up to two minutes. Native segment boundaries have brief gaps, and recognition results have processing delay.
- CameraX preview now uses the camera plugin's built-in orientation from opening, removing a second sensor rotation. Student native capture uses the root full-screen route. Local face framing starts on camera open, while challenge pose completion starts only with recording. Browser classroom scan uses its own full-screen responsive preview and one camera stream for local detection and independently recorded WebM segments.
- Verified locally: API 58 tests, Capture 17, Student 20, Teacher 81, browser tracking 5; Flutter analysis clean; both web and signed arm64 APK builds succeeded; frozen ML receipt 16/16; diff whitespace clean. Physical orientation, real browser codec and live tracking under motion, recognition latency, and authenticated end-to-end scans remain open. The connected phone's camera was idle before installation check.
- Final repository review: Capture (17), Student (20) and Teacher (81) suites and both product web builds passed again with Flutter 3.47.7; the browser tracker suite passed (5) and the diff is whitespace-clean. The API suite could not be rerun from the restricted review shell because its managed local PostgreSQL socket denied the connection before fixtures started (4 non-database tests passed; 54 setup errors). Re-run that suite on the normal Mac host before making a new backend claim.

## Camera guidance update — 9 November

- Camera follow-up: Student Android now passes local detected face bounds into the fitted preview and colors a well-framed face box green; the state clears when frame analysis stalls. The prior app omitted those bounds, while the browser drew them. Teacher Retake releases the stopped controller and opens a fresh camera, avoiding a frozen last frame. Teacher web preview is capped at 720 × 420; Student browser capture follows its source aspect within 680 px / 60 vh. Both browser views offer a rotate-preview control. That control changes the display only; it does not rotate the recorded stream or ML input. Physical source rotation is still needed if a webcam itself emits sideways frames. Capture 16/16, Student 20/20, Teacher 78/78; all three Flutter analyses, JavaScript syntax, two release web builds and both signed arm64 APK builds passed. ML freeze 16/16. Commit `1b38ce0` was pushed and both web apps deployed; the live Student camera script and Teacher JS bundle matched the local build hashes, both HTTPS pages returned 200 and API readiness returned 200. Both signed APKs installed in place on the connected phone while the camera was idle, and both packages are present. Live authenticated browser and consenting phone-camera acceptance remain open.
- The user reported the corrected Android preview orientation looked good, but the front guide did not turn green. The Student oval now stays visible and turns green during a verified hold. Android live guidance resumes when usable observations return after a timeout. Capture tests passed 15/15 and the signed Student update installed while the camera was idle. The on-device green-oval check is pending.

- Student enrolment now uses a full-screen capture view on Android and web. After a user-reported 90° regression with `CameraPreview`, Android uses the earlier sensor-based texture rotation and fits the face outline to the displayed rectangle. Seven focused tests passed. Both corrected signed arm64 builds installed successfully on the phone while the camera was idle. Physical confirmation of the corrected preview is pending. The browser computes its overlay from the fitted video size. Both use timed prompts when local analysis stalls and keep unverified poses incomplete.
- Teacher capture separates preview from recording, prefers the rear camera, and provides camera switching before capture plus tap-to-focus and torch where supported. Android classroom tracking samples at most five frames per second. Green indicates a tracked face has been fully in frame at 100 × 100 analysis pixels or larger for 400 ms. Stale outlines clear within one second. Recording continues when live analysis is unavailable. Teacher web keeps the browser recorder.
- Capture 15/15, Student 20/20 and Teacher 78/78 tests passed, along with Flutter analysis and JavaScript syntax checks. The frozen ML receipt passed 16/16. Both release web builds succeeded locally. Both verified signed arm64 APKs were installed in place on the connected phone while FaceTrack and its cameras were inactive. Physical Student portrait/landscape guidance, Chrome camera capture, and a consenting moving-classroom test with cadence and stutter measurement remain open. The steps are in `docs/CAMERA_VALIDATION.md`.

## Simple frontend caching — 9 November

- Implemented the approved 30-second, 100-entry memory cache for class/academic lists and attendance summaries. Account/institute/query keys, duplicate request sharing, explicit refresh bypass, write/account invalidation and late-result fencing are covered by six focused cache tests. Live biometric/media/session operations remain uncached. Faculty dashboard keeps its existing content on refresh and starts after the subject list's first load; overlapping subject-work requests share transport.
- Verification so far: shared Flutter suite 70 passed before two additional cache tests (all six focused cache tests then passed), Student 20 passed, Teacher 78 passed; analysis clean. Caddy now explicitly requires public static-file revalidation while API no-store is unchanged. Before deployment, anonymous full JS transfers were Student 3,229,268 bytes / 1.299 s and Teacher 3,636,412 bytes / 1.240 s in one local HTTP sample each; these are file transfers, not signed-in screen timings. After deployment, the equivalent samples were Student 3,233,336 bytes / 1.168 s and Teacher 3,640,864 bytes / 1.179 s. Both current validators returned 304 with zero body bytes, and the prior validators returned the new bundles with 200. Normal browser reloads reached both sign-in screens. The API readiness check returned 200 with no-store. Both signed arm64 release APKs were installed in place on the connected phone while FaceTrack was inactive and no camera clients were active. Signed-in timing, Android repeated navigation timing and full physical-device acceptance remain open.

## 9 November Android release install

- The user uninstalled the old development-signed Student and Teacher apps. New arm64 release APKs were built with the public Azure production config and the existing private release key, then installed on the connected Samsung SM-M356B. Both packages report versionCode 2001, launch to running processes, and the HTTPS API readiness endpoint returned 200. The USB connection briefly dropped during the first install but reconnected; both final packages are present. Release APKs are at `apps/student/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` and `apps/teacher/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`. USB debugging is not needed for normal use or direct APK installation; login, camera capture and end-to-end attendance still require user acceptance on the phone.

## 9 November client console report

- User supplied aggregate `.json` and `.txt` reports from the hosted client Model Test Console (generated 08:26 UTC). All six first scored scenarios passed with zero false-presence suggestions, zero misses and the same result across three runs per clip; no rejected recordings were reported. Per-run processing ranged about 4.2–11.2 seconds; whole scenario checks took 19.8–37.8 seconds including repeats and overhead, not upload/UX latency. The report's model pin was healthy but its separate freeze receipt checked 0 files. Final enrolled count was 2, while two scenario records show a roster of 3, consistent with a volunteer being removed after those runs; the aggregate alone cannot establish the sequence or independently verify consent/ground truth. This is controlled console evidence, not the previously tracked independent held-out 1/6 acceptance or classroom accuracy.

## 8 November audit and integration checkpoint

- **9 November client console review/deployment:** Compared Student web/Android enrolment with the client console. Console now shares the FaceTrack theme, has guided progress and clearer result explanations, lets clients choose an enumerated camera before recording and play back a clip before submission. It retains timed pose prompts; unlike Student enrolment, it does not analyze preview poses live. Backend now isolates concurrent upload temp files, holds the scoring lock until results are stored, and never reuses volunteer IDs while a session's history remains. Teacher Flutter 78 passed and analyze clean; worker 56 passed and Ruff clean. The `client-01` HTTPS page and backend were updated with zero volunteers present; authenticated page/status returned 200, anonymous page 401, model pin healthy and product readiness 200. No real client camera/volunteer acceptance was performed.
- A separate HTTPS Model Test Console workspace was provisioned as `client-01` on the Azure VM. It has its own container, named data volume and HTTP Basic login; credentials are stored only in ignored `.local/clients/client-01.txt`. Anonymous page, API and script requests returned 401; authenticated page/API returned 200; the model pin check passed and the workspace has zero volunteers. Product readiness remained 200. No real client recording or consent has been completed. Commercial/institute model rights remain unverified, so do not distribute the login for those uses.
- The Model Test Console web build and loopback-only container were installed on the Azure VM. An SSH tunnel from the Mac returned a healthy status and served the page; the public `/console/` path returned 404. `scripts/console-azure` starts/opens the private tunnel and has a stop command. VM pin check passed but the separate 16-file freeze receipt is absent on the VM; real volunteer scenarios remain unrun. See `docs/MODEL_TEST_CONSOLE.md`.
- Commit `5d126b7` was deployed to the Azure VM on 8 November: Teacher and Student web builds succeeded; API, Redis, worker and agent are healthy; public `/health/ready`, `/teacher/` and `/student/` return 200. The audited Caddyfile was validated and reloaded, and its web security headers were observed. This verifies service availability, not an authenticated end-to-end flow.
- Follow-up camera review found no camera selector in either app. A new pre-recording selector is implemented for Student/Teacher, including external devices when enumerated by the OS/browser. Commit `19285fc` was pushed; both web apps were rebuilt and uploaded on 8 November, and live URLs returned 200 with the Student camera script observed. The Android app was not rebuilt or installed. Switching during an active recording remains unsupported and disabled to preserve one clip; physical external-camera acceptance is open. Student attendance advice and zero-assessment status were corrected with a regression test.
- Independent ML review on the Mac: frozen receipt 16/16, pinned model executes with CPU ONNX, root suite 42 passed/1 expected xfail. Real held-out scenarios remain 1/6; model rights for institute use remain unverified. See `docs/MODEL_TEST_CONSOLE.md` for the six-scenario procedure.
- Security review found an admin Auth email-collision path that could reset and link an existing account. The uncommitted fix refuses existing accounts, cleans up newly created accounts after a link failure, and adds a regression test. Biometric review cursors are now scoped to the authorized offering.
- Faculty attendance sorting now exposes accessible labels and direction. Azure deployment waits for backend readiness before replacing live web assets; Caddy adds basic security headers.
- Local checks: API 57 passed after security fixes; worker 54 passed; root ML 42 passed, 1 expected xfail; shared Flutter 66 passed, capture 8 passed, Student 19 passed, Teacher 76 passed; teacher analyze, Ruff, shell syntax, diff whitespace, and ML freeze receipt passed. These are local checks, not hosted or physical-device acceptance.
- Existing uncommitted feature work was preserved. Authenticated web/Android walkthrough, full Azure deployment rehearsal, real recognition scenarios, biometric recovery, and institute gates below remain open.

**Architecture:** [`MASTER_DESIGN.md`](MASTER_DESIGN.md)

**Setup:** [`docs/INSTALLATION.md`](docs/INSTALLATION.md)

**Milestones:** [`ROADMAP.md`](ROADMAP.md)

## Current state

The demo runs **online on one Azure VM** (27 October 2026, see [docs/DEPLOY_AZURE.md](docs/DEPLOY_AZURE.md)):

- Supabase hosts Auth, PostgreSQL and private Storage.
- The VM (Central India, B2as_v2) runs FastAPI, Redis, one Celery CPU worker and the outbound agent in Docker, with Caddy HTTPS in front, and serves both web apps at `https://facetrack.centralindia.cloudapp.azure.com/teacher/` and `/student/`.
- Verified: HTTPS health ready, both web apps load, the model and profile load in the VM worker, the agent is authorized and polling. **Not yet verified: a signed-in end-to-end enrolment and recognition run through the VM.**
- Only one processing backend may run at a time; the Mac's worker and agent are stopped. Local development still works on ports 5300/5301 against the local API, and Android debug APKs pointing at the VM are built (not installed).

macOS Apple Silicon is the verified demo host. The canonical Docker stack supports the same local services on Windows/Linux; both Compose configurations validate and the API/worker images build, but physical Windows/Linux acceptance remains pending. Institute deployment (model rights, monitoring, backups) remains a later gate.

Schema head is **`0008_admin`**, with **37 forced-RLS business tables**. The running API's `/health/ready` passes against the hosted development project, which checks exactly that head and table count.

## Implemented and verified

### Terminology, faculty dashboard and administration (27 October 2026)

- Both apps use the institute's wording from the CSE timetable: Subject, Section, Semester term, Faculty, ordinal semesters ("3rd Semester"), "Odd Semester 2026". Labels only; routes, API, roles and CSV columns are unchanged.
- Faculty home dashboard: overall attendance, semester filter and semester-wise bars, sortable subject-wise statistics with drill-down, distribution chart, below-75% attention list, semester CSV export. Built in the app from the existing summary endpoint.
- Admin tab: setup checklist with the next step and jump-to-form, statistics, login-account and by-semester charts, institute-wide attendance, guided forms with institute examples, lists of existing records, searchable faculty/student directories, role grant by person picker.
- Verified by widget tests at 360/768/1440 px with 200% text. **Not yet seen in an authenticated browser or on the phone**; the running 5300/5301 dev servers were not reloaded with these changes.
- Theory/Lab and lab batches (A1, B1) from the timetable are not modelled.
- Sign-in page redesigned for both apps (split branded layout on wide screens, compact header on phones).
- Home pages simplified for both apps: greeting banner with the main actions, a "Needs your attention" card (top three notifications), compact tappable subject rows; the faculty attendance overview follows the subject list. Widget-tested only; not yet seen signed in.
- Bug fixes (31 October): session lists, student attendance history and query lists are newest-first (they were in random UUID order); a failed capture upload now shows its reason inside the capture panel and keeps the clip for retry; after processing, the capture panel explains frame quality (e.g. "Only 1 of 12 faces were clear enough") with retake tips, and Unassessed rows say why (no approved face enrolment / too few clear frames); the worker agent says "Worker credential rejected or expired" instead of "waiting" on 401/403; `deploy/azure/deploy.sh` starts a deallocated VM, allows SSH from the current IP and replaces the code tree cleanly. API, worker and Flutter tests pass; not yet seen signed in.
- Attendance UX and list fixes (31 October, later): **three final states** (Present, Absent, Unassessed). The API rejects new late/excused decisions and corrections (422); older late/excused rows show as Present/Unassessed in both apps and in worker reports; no migration. The home "Needs your attention" card now lists unread updates too, so it never says "nothing needs your attention" while the bell shows a count, and it has "Mark all read". New Student **Attendance** tab: overall ring, Present/Absent/Unassessed, classes needed to reach 75% or that can be missed, per-subject bars, last-6-months chart, subject/period/status filters, records by month. Richer **Account** page for both apps: profile header, details with copy, role-specific stats (Student: subjects, attendance, face enrolment; Faculty: subjects, classes, students, below-75%) and recent activity. More API lists are in a stable order (subjects by code, roster by enrolment number, own enrolments newest first, enrolment review oldest first, terms/courses/sections); admin directories now page past 200 with a cursor; a correction between pages no longer stops student history from loading, and history is ordered by class date. API (56), worker (38) and Flutter app_core/student/teacher tests and analysis pass. **Not yet seen signed in in a browser or on the phone; not deployed.**
- Admin console redesign (31 October): gradient header with a setup-progress ring and **Take the tour**; side menu (tabs on phones) for Overview, Academic setup, People, Access; Overview with a next-step card, a setup timeline, quick actions, statistics and charts; academic setup as four step cards whose Add stays locked (with the reason) until its prerequisite exists; People as Faculty/Students directories with search and a Needs-login filter; Access as two explained cards. Forms open in dialogs (full screen on phones), show errors inside the form and close on success; temporary passwords are hidden with a show/hide toggle (the create form showed them in clear text). ⓘ tips explain each term. A guided tour (11 steps, spotlight overlay, Back/Next/Skip, arrow keys and Esc) starts on an admin's first visit (per account, per device) and can be replayed. Directories now load every page. API unchanged. Widget-tested at 360/768/1440 px with 200% text, tour included; **not yet seen signed in**.
- Page transitions (31 October): one motion system for both apps. Tabs fade through each other; a subject or session page slides in from the right and back reverses it; reduced-motion shows pages instantly; the same transition on every platform (web had the host OS slide). Subject pages are nested under the list (URL unchanged), so going back keeps the list's state and scroll instead of reloading it, and the back buttons return to wherever the page was opened from (e.g. Attendance). Widget-tested; not yet seen on a phone.
- UX review fixes (31 October): a branded loading screen in both web apps while the app downloads (and the missing viewport tag, so it fits phones); pull-to-refresh on Subjects, Attendance, subject history, notifications, the faculty home and subject page, and Admin (not the session page, where it would drop unsaved decisions); student history says "Corrected by faculty" instead of "Publication revision N"; faculty subject tabs show counts of sessions to review, join requests, face reviews and open queries. Tests pass; loading screen checked in a phone-sized browser; signed-in screens not yet seen.
- Faculty subject page redesign (31 October): banner with subject code, section and term chips, live counts (students, sessions, to review) and Join code; a "Needs you" strip whose chips jump to the right tab; icon tabs with counts (Sessions, Students, Face reviews, Queries, Overview; join requests now sit at the top of Students); sessions grouped into Needs your action / Upcoming / Published / Cancelled with filters, a calendar tile, time range, room and a status pill, with the main action on each card; timetable import opens in a dialog. Pages opened from a list now show their own URL (a refresh lands on the same page). Widget-tested at 360 and 1280 px; not yet seen signed in.
- Faculty session page and home (31 October): the session page has a banner with the subject, date, time range, room, section and state; a step tracker (Open → Record → Close → Review → Publish) with one sentence for the current step; spaced panels and an icon for the capture state; a bar pinned to the bottom while reviewing with live Present/Absent/Unassessed/To check counts and Save/Publish; a publish confirmation that states the counts; "Published · corrected N times" instead of revision numbers; and a Reports heading. Faculty home subject cards show what is waiting (sessions to review, join requests, face reviews, open queries), "All caught up" or the next class (first 20 subjects, like the bell). Widget-tested at 360/768/1280 px with 200% text; not yet seen signed in.
- Review screens, reports, enrolment and notifications (31 October): Face reviews and Queries use review cards (initials, review-by deadline in red when under 24 h, frame counts, the identity and five-pose checklist; for queries the class date, "Published as Absent" and the student's reason in a quote box). Session reports are cards: final or draft, version, when created, Download PDF / CSV, email state in plain words. Student face enrolment shows an icon for each state and groups Discard and Withdraw consent under "Manage your enrolment", each with an explanation. Notifications group updates by Current / Today / Yesterday / This week / Earlier, swipe marks a notice read, and opening one returns to the list on back. Tests pass; not yet seen signed in.
- The hosted worker credential expires on **22 November 2026**; reissuing it is an owner action.
- Recording coach in the capture panel: pre-recording checklist and "Recognised so far: N of M students with face enrolment" after each processed clip.
- Signed release APKs (arm64: Teacher about 22 MB, Student about 34 MB, pointing at the Azure API) built from `origin/main`; signature verified with apksigner. Not installed on a phone yet.
- Not done: admin password reset (safe cross-institute checks need a new SECURITY DEFINER function, i.e. a migration, which was declined on 31 October).
- In-app notifications (bell with unread badge, `/notifications` panel) for students (enrolment decisions, face-enrolment state, newly published attendance, below-75% subjects, resolved queries), faculty (join requests, face reviews, open queries, sessions to review and publish, long-open sessions) and admins (setup and missing logins). Derived on the device from existing endpoints; no server-side store, push or email. Read state is per account on each device. Faculty checks cover the first 20 subjects. Unit- and widget-tested only; not yet seen signed in.

### Accounts and classes

- Approved student/teacher identities, memberships and teacher assignments
- Student identity claim, join-code request and teacher approval
- Tenant/object authorization, encrypted join codes, idempotency and rate limits
- Student/Teacher web and Android class flows
- Session restoration/logout, invalid-code recovery and Teacher web keyboard/screen-reader navigation

### Biometric enrolment

- Versioned consent and guided Android/Chrome capture
- Private signed Supabase upload and durable local processing
- Encrypted 512D templates pinned to model/profile versions
- Teacher identity/pose review before activation
- Two consenting approved class members currently have active templates
- One complete real happy path is verified; a second active student was user-confirmed
- Android upright preview/playback and correct left/right pose guidance are user-confirmed. The Samsung recording regression was separately retested and closed with signed build `1efb093`.

Recovery/lifecycle acceptance remains open for interrupted upload, worker restart, rejection, replacement, withdrawal, expiry and all capture edge cases.

### Sessions and attendance

- Manual/scheduled sessions, frozen roster and private classroom capture
- Roster-scoped recognition suggestions and evidence-coded drafts
- `proposed_absent` is shown as **Not recognized**. Since 27 October (client request) the Teacher review pre-fills these rows as a draft **Absent** that the teacher can change; it becomes final only when the teacher publishes. Widget/unit-tested only, not yet seen signed in
- Failed/limited processing and missing templates remain Unassessed
- Explicit teacher decisions, immutable publication revisions and corrections
- Student own published history
- Student Absent-attendance query and assigned-teacher accept/reject flow, locally tested

One real low-light two-person capture sampled 12 frames, produced 23 detections and 14 quality rejects, and suggested one of two enrolled students. The teacher explicitly confirmed both students Present and published revision 1. Raw capture media was deleted. Worker pipeline time was **356.505 ms**, excluding upload, queue, network, UI and cold start; it is not an end-to-end response measurement.

### Timetable and reports

- Bounded 14-column CSV upload, validation preview and selected-day materialization
- Room, faculty, class and overlap checks; repeated import is idempotent
- One real Monday scheduled session was user-confirmed
- Draft/final CSV and PDF report jobs from immutable snapshots
- Private 60-second authorized downloads; final CSV/PDF contents user-confirmed
- Email delivery code exists but is disabled because no permitted Resend sender is configured

### ML and evaluation

- Frozen SCRFD-500M + ArcFace-trained MobileFaceNet baseline, CPU ONNX Runtime
- Bounded video decoding, face quality checks, alignment, normalized embeddings, exact NumPy roster matching and temporal corroboration
- Freeze receipt verifies 16 source/model/profile/template/lock files
- Six calibration scenarios passed; independent real held-out acceptance remains **1 of 6**
- Isolated research package covers detector-only CLAHE, contrast/yaw candidates, two-scale SCRFD and per-crop alignment rejection without modifying production files
- DigiFace 60-scene synthetic benchmark: baseline 22/60 present suggestions and zero wrong-present marks; two-scale 24/60 and zero wrong-present marks; CLAHE unchanged; contrast filter worse
- Synthetic steady walk-around, class of 70 cooperative students plus 15 absent roster members and 3 intruders, frozen model unchanged, 10 runs each (`experiments/ml_accuracy/run_phone_walk.py --steady --face-cap 180 --frames 210`): each student in view about 4 s in total (`--dwell 4`) gave 91.4% recognised (84–97%); about 4 s on each side (`--dwell 8`) gave 96.6% (93–99%); zero false presences, intruder matches or confusions. Result files are in ignored `.local/experiments/phonewalk-4s/`. This is synthetic DigiFace data, not classroom accuracy.
- Synthetic results are not classroom accuracy. No >95% accuracy, liveness, ≤2-second end-to-end response or 20-class capacity claim is established.

The loopback Model Test Console lets a nontechnical tester enrol consenting volunteers and run six scenarios. Its automated tests and synthetic smoke pass; real-camera volunteer and Windows acceptance are pending.

## Verification on 27 October 2026

| Check | Result |
|---|---|
| API PostgreSQL suite | **54 passed** |
| API Ruff | Passed |
| Worker suite | **37 passed** |
| Worker Ruff | Passed |
| Root ML/contract suite | **42 passed, 1 expected frozen-baseline limitation** |
| ML freeze receipt | **16/16 unchanged** |
| Shared Flutter (`app_core`) | Analyze clean; **54 passed** (incl. sign-in, notification and home layouts at 360/768/1440 px, 200% text) |
| Capture Flutter | Analyze clean; **8 passed** |
| Student Flutter | Analyze clean; **14 passed** |
| Teacher Flutter | Analyze clean; **55 passed** |
| OpenAPI contract | Regenerated; includes the admin and attendance-summary endpoints |
| Running API | `/health/live` and `/health/ready` return 200 |
| Hosted database | `public.alembic_version` read directly: `0008_admin` |
| Teacher web build | `flutter build web` with the configured public file succeeds |
| Upgrade-guide model check | `load_manifest` + `load_profile` print "model and profile OK" natively and inside the worker image |
| Not re-run today | Student web build, Android APK builds, Docker image rebuilds, PowerShell syntax (no `pwsh` on the Mac), physical-device and authenticated visual checks |

The configuration audit also removed whole-file API environment injection from Compose. The mounted API `.env` still supplies declared runtime settings through Pydantic, and explicit operator tools can read `MIGRATION_DATABASE_URL`; the running API process no longer receives that owner URL as an exported environment variable.

The root suite's expected failure records the frozen baseline's degenerate-landmark alignment behavior. The isolated candidate fixes this per crop, but the production freeze is unchanged.

## Current blockers and next actions

1. Run the Model Test Console with 2–3 consenting adults on the demo camera; preserve its aggregate `.txt` and `.json` reports.
2. Complete the five missing independent real scenarios: one enrolled person absent, unknown alone, known plus unknown, varied distance/position, and no face.
3. Exercise attendance-query accept/reject on authenticated web and Android using safe controlled records.
4. Complete biometric lifecycle/recovery checks and a full restart rehearsal.
5. Perform a physical Windows x64 run; record Docker, camera, web and worker results. Repeat on Linux only if it will be demonstrated.
6. Configure/test Resend only after a permitted sender exists.
7. Keep the existing detector/profile for the presentation. Adopt no research candidate until real held-out accuracy, latency, rights and reliability gates pass.
8. Sign in as faculty and as an admin, and check the new dashboard and Admin tab on web and on the phone before relying on them in a presentation.
9. Later: inspect the latest release web bundles and APKs on an idle phone (carried over from the 25 October review).
10. Later, before institute scale: benchmark recognition input, which fetches templates one roster member at a time (`services/api/app/recognition_jobs.py`), before batching it.

## Setup and privacy notes

- The public repository cannot run real inference by itself. Private `.env`, model, profile and demo credentials must be provisioned or securely transferred.
- Do not regenerate the existing worker token on routine startup; it is scoped and time-limited.
- Never commit credentials, tokens, recordings, embeddings, templates, ONNX files or participant-level results.
- Raw-media cleanup and job reconciliation require a running agent. Inspect backlog after restart.
- Public signup/recovery, native desktop, production inference capacity, backups/restore acceptance, model deployment rights and institute-scale load testing remain later work.

## Frozen prototype evidence

Private manifest `.local/spike/models/buffalo_sc/manifest.json`, profile `.local/spike/profiles/frozen-phase1b-v1.json`, templates `.local/spike/experiments/calibration-v3` and receipt `.local/spike/held-out-freeze-v2.json` remain outside Git. One fresh both-known Test clip passed three fresh-process repeats without changing the receipt. Five independent scenarios remain. Never tune on those held-out clips.
