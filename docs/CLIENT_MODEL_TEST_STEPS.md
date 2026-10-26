# Model test: step-by-step for the tester (Windows)

This takes about 1 hour the first time (most of it is Docker installing and recording). You do not need to be technical. You need a Windows 10/11 computer with a webcam, and 3 adult volunteers who agree to be recorded for this test.

Stop and message Rishi if anything below does not match what you see. Do not try to fix it yourself.

## A. One-time setup (about 30 minutes)

1. **Install Docker Desktop** from docker.com and start it. Wait until it says **Running** (bottom-left). Restart the computer if it asks.
2. **Get the project.** Open https://github.com/rishyym0927/FaceTrack, press the green **Code** button, then **Download ZIP**. Unzip it so you have a folder `C:\FaceTrack` that contains `README.md`, `scripts` and `docs`.
3. **Get the test page.** Open https://github.com/rishyym0927/FaceTrack/releases/tag/console-v1 and download `facetrack-console-web.zip`. Make a folder `C:\FaceTrack\.local\console-web` and unzip the file **into it**, so that `C:\FaceTrack\.local\console-web\index.html` exists. (If you cannot see `.local`, create it: it is a normal folder whose name starts with a dot.)
4. **Add the model files Rishi sent you privately.** Put them here exactly:

   ```text
   C:\FaceTrack\.local\spike\models\buffalo_sc\        (the whole folder Rishi sent)
   C:\FaceTrack\.local\spike\profiles\frozen-phase1b-v1.json
   ```

   Never upload these files anywhere. Never put them on GitHub.

## B. Start the test page (about 5 to 10 minutes the first time)

1. Open **PowerShell** (Start menu, type PowerShell).
2. Type these two lines, pressing Enter after each:

   ```powershell
   cd C:\FaceTrack
   .\scripts\windows\start-console.ps1
   ```

   If Windows says scripts are blocked, type `Set-ExecutionPolicy -Scope Process Bypass` and Enter, then run the second line again.
3. Wait. The first time it builds for several minutes. When it says **Model test page is ready**, your browser (Chrome or Edge) opens `http://127.0.0.1:8010`.
4. Under **1. System check** you should see a green message that the model and settings are unchanged. If it says **Stop and contact the project owner**, stop and message Rishi.

## C. Do the test (about 30 minutes)

Set up first: sit near a window or lamp **in front of** the volunteers (light on their faces, not behind them), camera at eye level, faces about arm's length from the camera, glasses off if they cause glare.

1. **2. Volunteers.** For each of 3 volunteers: type a first name or nickname, tick the consent box, press record, and follow the on-screen head-turn prompts for about 15 seconds. Watch the clip, tick the supervisor box, press **Save this volunteer**.
2. **3. The six test recordings.** For each, read the card, tick who is really visible, press **Start this recording**, record 10 seconds, then press **Check this recording**. Do them in order. The **first** attempt for each is the official result, so do each properly the first time. Use **Record again** only if the page rejects a recording (for example, too short).
3. **4. Results.** When all six are done, read the verdict at the top.

## D. Send the results to Rishi

1. Press **Download report + summary**. Two files download: `facetrack-model-test-report.txt` and `facetrack-model-test.json`.
2. Send **both** files to Rishi. They contain counts only, with no names, faces or videos.
3. Press **Delete all test data** on the page. This removes the volunteers' face data from the computer.
4. In PowerShell run `.\scripts\windows\stop-console.ps1`, then you can close Docker Desktop.

## If something goes wrong

- **Page does not open:** make sure Docker says Running, then run `.\scripts\windows\start-console.ps1` again.
- **Camera blocked:** click the camera icon in the address bar and choose Allow, then reload the page.
- **Anything with an error message:** take a screenshot and send it to Rishi.

## What this test is and is not

It checks the face model with a few volunteers in one room on this camera and lighting. It is not a guarantee of classroom accuracy.
