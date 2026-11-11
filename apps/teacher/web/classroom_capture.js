// Local advisory framing only. Recognition uses private, independently decodable segments.
(() => {
  class FaceTracker {
    constructor() { this.tracks = []; this.nextId = 1; }
    clear() { this.tracks = []; }
    expire(now) { this.tracks = this.tracks.filter(track => now - track.last < 1000); }
    update(boxes, now, width, height) {
      const previous = this.tracks.filter(t => now - t.last < 1000);
      const used = new Set();
      this.tracks = boxes.map(box => {
        let best = null, score = .25;
        for (const track of previous) {
          if (used.has(track.id)) continue;
          const [a, b] = [box, track.box];
          const intersection = Math.max(0, Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x)) *
            Math.max(0, Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y));
          const overlap = intersection / (a.w * a.h + b.w * b.h - intersection || 1);
          if (overlap > score) { best = track; score = overlap; }
        }
        const id = best?.id ?? this.nextId++;
        used.add(id);
        const framed = box.w >= 100 && box.h >= 100 && box.x > 0 && box.y > 0 &&
          box.x + box.w < width && box.y + box.h < height;
        const since = framed ? (best?.since ?? now) : null;
        return { id, box, since, last: now, green: framed && now - since >= 400 };
      });
      return this.tracks;
    }
  }
  // Each part has its own WebM header; MediaRecorder timeslices alone are not
  // independently decodable video files.
  function recordPart(stream, onRecorder, duration = 12000) {
    return new Promise((resolve, reject) => {
      const mime = ['video/webm;codecs=vp8', 'video/webm'].find(type => MediaRecorder.isTypeSupported(type));
      if (!mime) { reject(new Error('This browser cannot record WebM. Use Chrome or Edge.')); return; }
      const chunks = [];
      const recorder = new MediaRecorder(stream, { mimeType: mime, videoBitsPerSecond: 2500000 });
      let timer;
      recorder.ondataavailable = event => { if (event.data.size) chunks.push(event.data); };
      recorder.onerror = () => { clearTimeout(timer); reject(new Error('Camera recording was interrupted.')); };
      recorder.onstop = () => { clearTimeout(timer); resolve(new Blob(chunks, { type: mime })); };
      onRecorder(recorder);
      recorder.start();
      timer = setTimeout(() => { if (recorder.state === 'recording') recorder.stop(); }, duration);
    });
  }
  let active;
  const api = {
    FaceTracker, recordPart,
    cancel() { active?.cancel({ discard: true }); },
    status(message) { if (active) active.result.textContent = message; },
    async scan(onSegment, onStarted) {
      if (active) throw new Error('A classroom camera is already open.');
      const root = document.createElement('div');
      root.className = 'ft-camera';
      root.setAttribute('role', 'dialog');
      root.setAttribute('aria-modal', 'true');
      root.setAttribute('aria-label', 'Classroom scanner');
      root.innerHTML = `<style>
.ft-camera{position:fixed;inset:0;z-index:10000;background:#071b18;color:white;font:16px system-ui;display:flex;flex-direction:column;padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left);box-sizing:border-box}
.ft-camera *{box-sizing:border-box}.ft-camera header,.ft-camera footer{padding:14px 18px;background:#102e28}.ft-camera header{display:flex;align-items:center;justify-content:space-between;gap:16px}.ft-camera h2{font-size:20px;margin:0}.ft-camera .stage{position:relative;flex:1;min-height:100px;overflow:hidden;background:#071b18;margin:0 auto;width:100%;max-width:1100px}.ft-camera video,.ft-camera canvas.overlay{position:absolute;width:100%;height:100%;object-fit:contain}.ft-camera canvas.overlay{pointer-events:none}.ft-camera footer{display:flex;flex-direction:column;gap:10px;max-height:45%;overflow:auto}.ft-camera .controls{display:flex;flex-wrap:wrap;gap:10px;align-items:center;justify-content:center}.ft-camera button,.ft-camera select{font:inherit;min-height:48px;padding:10px 16px;border:1px solid #8caea2;border-radius:14px;background:#173d33;color:white;cursor:pointer}.ft-camera button.primary{background:#b9f3d3;color:#0b3428;border:0;font-weight:700}.ft-camera button:disabled{opacity:.55;cursor:default}.ft-camera p{margin:0;text-align:center}.ft-camera .hint{color:#c2d9d0;font-size:14px}.ft-camera select{max-width:min(100%,340px)}.ft-camera button:focus-visible,.ft-camera select:focus-visible{outline:3px solid #f8d979;outline-offset:2px}@media(min-width:800px){.ft-camera{inset:24px;border-radius:20px;overflow:hidden;box-shadow:0 0 0 30px #071b18cc}.ft-camera .stage{max-height:70vh}}@media(prefers-reduced-motion:no-preference){.ft-camera{animation:ftCameraEnter .15s ease-out}@keyframes ftCameraEnter{from{opacity:0}to{opacity:1}}}
</style><header><h2>Scan your classroom</h2><button class="close" aria-label="Close camera">Close</button></header><div class="stage"><video autoplay muted playsinline></video><canvas class="overlay"></canvas></div><footer><p class="guidance" role="status">Opening camera…</p><p class="result" aria-live="polite"></p><p class="hint">Move slowly. Green boxes mean well framed. Recognition suggestions appear as each part is processed.</p><div class="controls"><select aria-label="Camera"></select><button class="torch" hidden>Turn torch on</button><button class="primary start" disabled>Start scan</button><button class="stop" hidden>Stop scan</button><button class="retry" hidden>Retry upload</button></div></footer>`;
      document.body.append(root);
      const video = root.querySelector('video'), overlay = root.querySelector('.overlay');
      const stage = root.querySelector('.stage'), guidance = root.querySelector('.guidance');
      const result = root.querySelector('.result'), start = root.querySelector('.start');
      const stop = root.querySelector('.stop'), close = root.querySelector('.close');
      const select = root.querySelector('select'), torch = root.querySelector('.torch'), retry = root.querySelector('.retry');
      const priorFocus = document.activeElement;
      close.focus();
      let stream, detector, recorder, detectorTimer, expiryTimer, retryResolve;
      let cancelled = false, finishing = false, scanning = false, mirrored = false, torchOn = false;
      let pendingPart = false;
      let segmentStartedAt = 0, shortTail = false;
      let lastVideoTime = -1, lastDetection = 0, detectorBusy = false, detectorClosed = false;
      const tracker = new FaceTracker(), analysis = document.createElement('canvas');
      const analysisContext = analysis.getContext('2d', { willReadFrequently: true });
      let wake, abortUpload;
      const ready = new Promise(resolve => { wake = resolve; });
      const clearOverlay = () => overlay.getContext('2d').clearRect(0, 0, overlay.width, overlay.height);
      const releaseStream = async () => {
        torchOn = false;
        stream?.getTracks().forEach(t => t.stop());
        stream = null;
        video.srcObject = null;
      };
      const closePreview = async () => {
        detectorClosed = true;
        clearInterval(detectorTimer); clearInterval(expiryTimer);
        detector?.close();
        detector = null;
        stage.hidden = true;
        select.hidden = true; torch.hidden = true; stop.hidden = true;
        root.querySelector('.hint').hidden = true;
        close.disabled = !retryResolve;
        guidance.textContent = 'Camera closed';
        root.setAttribute('aria-label', 'Classroom upload');
        root.querySelector('h2').textContent = 'Classroom upload';
        await releaseStream();
      };
      const finish = () => {
        if (finishing) return;
        finishing = true;
        stop.disabled = true;
        if (recorder?.state === 'recording') {
          shortTail = performance.now() - segmentStartedAt < 10000;
          recorder.stop();
        } else {
          void closePreview();
        }
      };
      const cancel = ({ discard = false } = {}) => {
        // Lifecycle interruption must not silently delete a failed upload.
        // Keep its bounded in-memory blob and retry UI until explicit discard.
        if (pendingPart && !discard) {
          finish();
          return;
        }
        cancelled = true; finishing = true; wake(); abortUpload?.(); retryResolve?.(false);
        if (recorder?.state === 'recording') recorder.stop();
      };
      active = { cancel, result };
      close.onclick = () => {
        if (!scanning) cancel();
        else if (!finishing) finish();
        else if (retryResolve && window.confirm('Discard this unsent segment? Uploaded segments stay in the session.')) cancel({ discard: true });
      };
      const keydown = event => {
        if (event.key === 'Escape') { event.preventDefault(); close.click(); }
        if (event.key === 'Tab') {
          const controls = [...root.querySelectorAll('button,select')].filter(e => !e.hidden && !e.disabled);
          const first = controls[0], last = controls.at(-1);
          if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
          else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
        }
      };
      root.addEventListener('keydown', keydown);
      const hidden = () => { if (document.hidden) cancel(); };
      document.addEventListener('visibilitychange', hidden);
      const beforeUnload = event => {
        if (pendingPart) { event.preventDefault(); event.returnValue = ''; }
      };
      window.addEventListener('beforeunload', beforeUnload);
      const draw = () => {
        overlay.width = stage.clientWidth; overlay.height = stage.clientHeight;
        const context = overlay.getContext('2d');
        if (!video.videoWidth || performance.now() - lastDetection >= 1000) return;
        const scale = Math.min(overlay.width / video.videoWidth, overlay.height / video.videoHeight);
        const left = (overlay.width - video.videoWidth * scale) / 2, top = (overlay.height - video.videoHeight * scale) / 2;
        context.lineWidth = 3;
        for (const track of tracker.tracks) {
          const b = track.box;
          context.strokeStyle = track.green ? '#52df9d' : '#e8f3ee';
          context.strokeRect(left + (mirrored ? video.videoWidth - b.x - b.w : b.x) * scale, top + b.y * scale, b.w * scale, b.h * scale);
        }
      };
      const resize = new ResizeObserver(draw); resize.observe(stage);
      const openCamera = async deviceId => {
        await releaseStream();
        tracker.clear(); clearOverlay();
        stream = await navigator.mediaDevices.getUserMedia({ video: {
          ...(deviceId ? { deviceId: { exact: deviceId } } : { facingMode: { ideal: 'environment' } }),
          width: { ideal: 1280 }, height: { ideal: 720 }, frameRate: { ideal: 24, max: 30 },
        }, audio: false });
        if (cancelled) { await releaseStream(); return; }
        video.srcObject = stream; await video.play();
        const track = stream.getVideoTracks()[0];
        mirrored = track.getSettings().facingMode === 'user';
        video.style.transform = mirrored ? 'scaleX(-1)' : '';
        torch.hidden = !track.getCapabilities?.().torch;
        torch.textContent = 'Turn torch on';
        track.onended = () => { guidance.textContent = 'Camera disconnected. Reopen the camera to continue.'; cancel(); };
        lastVideoTime = -1;
      };
      const loadDetector = async () => {
        try {
          const vision = await import('https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.35/vision_bundle.mjs');
          const files = await vision.FilesetResolver.forVisionTasks('https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.35/wasm');
          const loaded = await vision.FaceDetector.createFromOptions(files, {
            baseOptions: { modelAssetPath: 'https://storage.googleapis.com/mediapipe-models/face_detector/blaze_face_short_range/float16/1/blaze_face_short_range.tflite' },
            runningMode: 'VIDEO', minDetectionConfidence: .5,
          });
          if (cancelled || detectorClosed) loaded.close(); else detector = loaded;
        } catch (_) { if (!cancelled && !finishing) guidance.textContent = 'Live framing unavailable. You can still scan and review recognition results.'; }
      };
      try {
        await openCamera(); if (cancelled) return;
        const devices = (await navigator.mediaDevices.enumerateDevices()).filter(d => d.kind === 'videoinput' && d.deviceId);
        if (cancelled) return;
        devices.forEach((device, index) => { const option = document.createElement('option'); option.value = device.deviceId; option.textContent = device.label || `Camera ${index + 1}`; select.append(option); });
        select.value = stream.getVideoTracks()[0].getSettings().deviceId || select.value;
        select.hidden = devices.length < 2;
        select.onchange = async () => {
          start.disabled = true; select.disabled = true;
          try { await openCamera(select.value); guidance.textContent = 'Frame the room, then start your scan.'; }
          catch (_) { guidance.textContent = 'Camera unavailable. Select another camera or close and retry.'; }
          finally { select.disabled = false; start.disabled = !stream?.active; }
        };
        torch.onclick = async () => {
          try { await stream.getVideoTracks()[0].applyConstraints({ advanced: [{ torch: !torchOn }] }); torchOn = !torchOn; torch.textContent = torchOn ? 'Turn torch off' : 'Turn torch on'; }
          catch (_) { result.textContent = 'Torch unavailable on this camera. Scanning can continue.'; }
        };
        guidance.textContent = 'Frame the room, then start your scan.';
        void loadDetector();
        detectorTimer = setInterval(() => {
          if (cancelled || detectorBusy || !detector || video.readyState < 2 || lastVideoTime === video.currentTime) return;
          detectorBusy = true; lastVideoTime = video.currentTime;
          try {
            const ratio = Math.min(1, 640 / video.videoWidth);
            analysis.width = Math.round(video.videoWidth * ratio); analysis.height = Math.round(video.videoHeight * ratio);
            analysisContext.drawImage(video, 0, 0, analysis.width, analysis.height);
            const now = performance.now();
            const detection = detector.detectForVideo(analysis, now);
            tracker.update(detection.detections.map(d => ({ x: d.boundingBox.originX / ratio, y: d.boundingBox.originY / ratio, w: d.boundingBox.width / ratio, h: d.boundingBox.height / ratio })), now, video.videoWidth, video.videoHeight);
            lastDetection = now; draw();
            guidance.textContent = tracker.tracks.length ? `${tracker.tracks.length} faces in view · move slowly` : 'No faces in view. Aim toward the class.';
          } catch (_) { tracker.clear(); clearOverlay(); guidance.textContent = 'Live framing unavailable. Scanning can continue.'; }
          finally { detectorBusy = false; }
        }, 200);
        expiryTimer = setInterval(() => {
          tracker.expire(performance.now());
          if (performance.now() - lastDetection >= 1000) clearOverlay();
        }, 200);
        start.disabled = false;
        start.onclick = wake;
        stop.onclick = finish;
        await ready; if (cancelled) return;
        scanning = true; start.hidden = true; select.disabled = true; stop.hidden = false; onStarted();
        let submitted = 0;
        while (!cancelled && !finishing) {
          result.textContent = 'Scanning · audio off';
          const blob = await recordPart(stream, value => {
            recorder = value;
            segmentStartedAt = performance.now();
          });
          recorder = null;
          if (finishing) await closePreview();
          if (cancelled) break;
          if (shortTail) break;
          if (!blob.size || blob.size > 25 * 1024 * 1024) throw new Error('This part could not be saved. Try again with a lower camera resolution.');
          const url = URL.createObjectURL(blob);
          pendingPart = true;
          try {
            let uploaded = false;
            while (!uploaded && !cancelled) {
              let terminalMessage;
              try {
                result.textContent = 'Uploading recording…';
                const cancelledUpload = new Promise(resolve => { abortUpload = resolve; });
                terminalMessage = await Promise.race([onSegment(url), cancelledUpload]);
                if (cancelled) break;
                if (!terminalMessage) {
                  uploaded = true;
                  submitted++;
                  continue;
                }
              } catch (_) {
                if (cancelled) break;
              } finally {
                abortUpload = null;
              }
              finish();
              await closePreview();
              if (cancelled) break;
              result.textContent = terminalMessage ||
                'Upload failed. This part is kept here; retry before closing.';
              close.disabled = false;
              retry.hidden = Boolean(terminalMessage);
              if (terminalMessage) close.focus(); else retry.focus();
              const again = await new Promise(resolve => { retryResolve = resolve; retry.onclick = () => resolve(true); });
              retry.hidden = true; retryResolve = null;
              close.disabled = true;
              if (!again) break;
            }
          } finally { pendingPart = false; URL.revokeObjectURL(url); }
        }
        if (shortTail && submitted === 0) {
          result.textContent = 'No clip was saved. Record at least 10 seconds per segment.';
          close.disabled = false; close.textContent = 'Back to session'; close.focus();
          if (!cancelled) await new Promise(resolve => { wake = resolve; close.onclick = resolve; });
        }
      } finally {
        detectorClosed = true; cancelled = true;
        clearInterval(detectorTimer); clearInterval(expiryTimer);
        if (recorder?.state === 'recording') recorder.stop();
        await releaseStream(); detector?.close(); resize.disconnect();
        document.removeEventListener('visibilitychange', hidden);
        window.removeEventListener('beforeunload', beforeUnload);
        root.remove(); priorFocus?.focus();
        active = null;
      }
    },
  };
  globalThis.FaceTrackClassroom = api;
})();
