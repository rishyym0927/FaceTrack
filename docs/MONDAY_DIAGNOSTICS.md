# Monday diagnostics checklist

Goal: if anything goes wrong in the real class, we can say exactly what happened afterwards. The
logs only exist if they are kept before the next deploy, so the first step after class is to
collect them.

All commands run from the repo root on the Mac. `--vm` means the Azure VM
(`~/.ssh/facetrack_azure`, `azureuser@facetrack.centralindia.cloudapp.azure.com`; set
`FACETRACK_HOST` or `FACETRACK_SSH_KEY` to override). The VM only accepts SSH from the IP that was
last allowed, which `deploy/azure/deploy.sh` re-allows.

## Before Monday

1. **Install the persistent log capture on the VM** (once; safe to repeat; reads logs only and
   never restarts or reconfigures a container). Read `deploy/azure/install_log_capture.sh`, then:

   ```sh
   ssh -i ~/.ssh/facetrack_azure azureuser@facetrack.centralindia.cloudapp.azure.com 'mkdir -p /tmp/ft-logcapture'
   scp -i ~/.ssh/facetrack_azure deploy/azure/log_capture.py deploy/azure/install_log_capture.sh \
       azureuser@facetrack.centralindia.cloudapp.azure.com:/tmp/ft-logcapture/
   ssh -i ~/.ssh/facetrack_azure azureuser@facetrack.centralindia.cloudapp.azure.com \
       'sudo sh /tmp/ft-logcapture/install_log_capture.sh'
   ```

   Check it: `ssh ... 'sudo sh /tmp/ft-logcapture/install_log_capture.sh --status'` shows the
   service `active` and one `.log` file per service in `/var/log/facetrack`, growing. Disk use is
   bounded (rotated daily or at 200 MB, 14 days, compressed: well under 2 GB).
2. **Deploy any pending code first**, then install or re-check the capture (it survives deploys,
   because it lives outside `/opt/facetrack`). Do not deploy on Monday between the class and the
   log collection.
3. **Run a smoke scan** with the same phone and laptop, a few segments, then stop and let the jobs
   finish. Then:

   ```sh
   scripts/session-report --vm latest --out /tmp/smoke-report.md
   ```

   Confirm the report shows: the scan start and stop, every segment and its upload (with seconds
   and Mbps), one job row per segment with a queue wait and a download time, the reasons
   histogram, resource readings, and `Database: queried read-only`. If the app part says "No app
   diagnostics arrived", the phone build is older than the diagnostics or cannot reach the
   server.
4. Apply `scripts/pipeline-logging.patch` (`git apply scripts/pipeline-logging.patch`, then run the
   API and worker tests) so job lines carry the session and capture ids and the claim log shows
   queue wait. The report works without it, using the database for those links.
5. Make sure the phone has a build with the diagnostics (the web apps are rebuilt by
   `deploy/azure/deploy.sh`; an APK needs a new build). Without it the phone leaves no app events.

## During the class

Write down (paper or phone notes):

- Wall-clock time (to the minute) of: scan start on the phone, scan start on the laptop, every
  time you stop or restart a scan, and anything odd (a call arriving, the screen locking, the app
  being switched, the phone moving to another room, Wi-Fi dropping).
- The **session id** (or, if you do not have it, the 8-character reference shown under any error
  in the app, and the class name and time).
- Which device recorded what: phone for segments, laptop webcam for its own scan.
- Anything the teacher reports ("it said upload paused", "the camera froze"). A screenshot of
  an error message with its **Reference:** line is the most useful single thing.
- Do not deploy, restart containers or recreate anything during or right after the class.

## After the class (do this before anything else is deployed)

1. Collect the logs and the report:

   ```sh
   mkdir -p ~/monday && cd <repo>
   scripts/session-report --vm latest --out ~/monday/report.md
   scripts/session-report --vm --since 6h --out ~/monday/all-sessions.md   # the laptop scan is another session
   scripts/logs --vm --all --since 12h > ~/monday/raw-logs.jsonl            # every event line
   scripts/logs --vm --errors --since 12h > ~/monday/errors.jsonl
   ```

   If the capture is installed, also copy the files themselves:

   ```sh
   ssh -i ~/.ssh/facetrack_azure azureuser@facetrack.centralindia.cloudapp.azure.com \
       'sudo tar czf - -C /var/log facetrack' > ~/monday/server-logs.tgz
   ```

2. Check the report's first lines: `Log lines read` and the time range must cover the class. If
   it says the logs hold no lines for the class, the capture was not running; say so (do not
   guess).
3. Send me: `report.md`, `all-sessions.md`, `raw-logs.jsonl`, your notes (times, reference code,
   screenshots), and the phone model and Android version (this is the one thing the app does not
   report). The files contain no names, emails, enrolment numbers or scores of named students; the
   raw logs contain ids and counts only. Still, do not post them publicly.

## What each finding means

| Finding | What it means | What to check or do |
|---|---|---|
| No app diagnostics arrived | The phone or laptop sent no events | Old app build, no connection, or the app was killed; compare with the server's `upload-complete` lines |
| Scan started but never stopped | The app did not end the scan cleanly | Closed, crashed, or lost network before stop; the last segments may be unsent on the phone |
| N recorded, only M uploaded | Segments are still on the device | Reopen the app on the same phone; they resume. Do not clear app data |
| Upload retries / upload FAILED | Phone to server link dropped | Wi-Fi vs cellular (`network` in the clients line), distance to the access point; failed segments are missing from attendance |
| Uploads take as long as a segment | Link too slow for the bitrate | Segments pile up and finish after the class; use a better link |
| Camera failure / interrupted / paused | No video was recorded for that period | Reason code: `NotReadableError` (another app has the camera), `NotAllowedError` (permission), `hidden`/`paused` (screen off or app in the background), `recording_lost` |
| Job waited N s in the queue | Worker busy or down | Backlog and CPU lines; 2 workers by design; check `agent_notice` |
| Slow download from storage | VM to Supabase Storage link was slow | Flag for the next class; not recognition quality |
| Faces rejected (small / blur / edge / landmarks / brightness) | The camera view was poor | small: too far or wide; blur: motion or focus; edge: students at the frame border; landmarks: faces turned or covered; brightness: lighting |
| NO face detected / fewer than 2 frames | The video had no usable faces | Camera pointing away, covered, file damaged |
| not_seen (many) | Students never appeared clearly in any segment | Coverage, distance, or enrolment photo mismatch |
| look_alike | Two roster members look alike to the model | Needs human review; never auto-accept |
| weak_match / seen_too_briefly | Face found but evidence too thin | Lighting and angle; the student passed quickly |
| Job FAILED / lease lost | Processing broke or was taken over | Code and stage in the finding; retried jobs show `starts` above 1 |
| database error / pool saturated | The hosted database (Tokyo) was slow or busy | Slow requests and `db wait` in the report |
| App-side failures with no server trace | Request died between app and API | Proxy, network, or the server restarting; compare times with deploys |
| CPU 90 % / memory low / disk low | VM resource trouble | Resource section; burst credits on B-series VMs |
| Logs hold no lines for the class | Logs were deleted (container recreated before collection) or capture not running | `scripts/logs --vm --resources`; confirm the capture service is active |

The report states what the data shows. If a finding is missing, that is not proof it did not
happen: check the coverage line at the top and the database section.

## Teacher review effort

When the database is reachable, each session's report ends its recognition section with one line saying how much the teacher changed what the system proposed: students removed from the proposed-present list, students added that were not proposed, and the changed share. With `--since 7d` and no target, the report also ends with an "Across N session(s)" roll-up of the same figures.

This is a review-effort figure, not an accuracy rate. The system's original proposal is overwritten when the teacher decides, so the report infers the change by comparing the recorded reason (`recognized`, `not_recognized`, `limited_capture`) with the final status. Rows with no teacher decision yet are counted separately. Students without a face enrolment who were marked by hand are listed apart. The figure has counts only; no student is identified.
