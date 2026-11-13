// Enrolment-only browser camera. Preview frames are analyzed locally and never uploaded.
window.FaceTrackCapture = {
  _stop: null,
  cancel() { window.FaceTrackCapture._stop?.(true); },
  async record(order, onFrame) {
    // The processor validates 10 seconds of encoded video. Leave two seconds
    // for recorder startup and the gap between the final frame and stop.
    const earliestStopMs = 12000;
    const maximumMs = 25000;
    const root = document.createElement('div');
    const previousFocus = document.activeElement;
    root.setAttribute('role', 'dialog');
    root.setAttribute('aria-modal', 'true');
    root.setAttribute('aria-labelledby', 'face-capture-title');
    root.style.cssText = 'position:fixed;inset:0;z-index:10000;background:#f3f7f5;font-family:system-ui,sans-serif;color:#17392f;overflow:auto';
    const card = document.createElement('div');
    card.style.cssText = 'box-sizing:border-box;min-height:100%;max-width:1000px;margin:auto;display:flex;flex-direction:column;justify-content:center;padding:16px max(16px,env(safe-area-inset-right)) max(16px,env(safe-area-inset-bottom)) max(16px,env(safe-area-inset-left))';
    const title = document.createElement('h2');
    title.id = 'face-capture-title';
    title.textContent = 'Record your face';
    title.style.cssText = 'font-size:22px;margin:0 0 12px';
    const stage = document.createElement('div');
    stage.style.cssText = 'position:relative;overflow:hidden;border-radius:18px;background:#23372f;flex:0 1 auto;align-self:center;width:min(100%,680px);height:min(60vh,620px);box-shadow:0 14px 40px #102e2630';
    const frame = document.createElement('div');
    frame.style.cssText = 'position:absolute;inset:0';
    const video = document.createElement('video');
    video.autoplay = true;
    video.muted = true;
    video.playsInline = true;
    video.style.cssText = 'width:100%;height:100%;object-fit:contain;display:block';
    const oval = document.createElement('div');
    oval.style.cssText = 'position:absolute;inset:12% 20%;border:3px solid #e9f7f0;border-radius:50%;pointer-events:none;box-shadow:0 0 0 100vmax #0002';
    frame.append(video, oval);
    stage.append(frame);
    const prompt = document.createElement('div');
    prompt.setAttribute('aria-live', 'polite');
    prompt.style.cssText = 'font-size:22px;font-weight:650;margin:6px 0 2px';
    prompt.textContent = 'Allow camera access';
    const hint = document.createElement('div');
    hint.style.cssText = 'color:#48645a';
    const circles = document.createElement('div');
    circles.style.cssText = 'display:flex;gap:9px;margin:4px 0;flex-wrap:wrap';
    const status = document.createElement('div');
    status.style.cssText = 'font-size:14px;color:#48645a;margin-bottom:12px';
    const stopButton = document.createElement('button');
    stopButton.textContent = 'Cancel recording';
    stopButton.style.cssText = 'position:sticky;bottom:0;flex-shrink:0;border:1px solid #0b6b57;color:#0b6b57;background:white;border-radius:12px;padding:12px 18px;min-height:48px;font:inherit;cursor:pointer';
    const cameraSelect = document.createElement('select');
    cameraSelect.setAttribute('aria-label', 'Camera');
    cameraSelect.style.cssText = 'width:100%;padding:12px;margin:8px 0;border:1px solid #86a59a;border-radius:10px;font:inherit';
    const rotateButton = document.createElement('button');
    rotateButton.textContent = 'Rotate preview';
    rotateButton.style.cssText = 'align-self:flex-start;border:1px solid #86a59a;color:#17392f;background:white;border-radius:10px;padding:8px 12px;margin:8px 0;font:inherit;cursor:pointer';
    const startButton = document.createElement('button');
    startButton.textContent = 'Start recording';
    startButton.disabled = true;
    startButton.style.cssText = 'background:#0b6b57;color:white;border:0;border-radius:12px;padding:12px 18px;min-height:48px;font:inherit;cursor:pointer;margin-right:8px';
    card.append(title, stage, rotateButton, prompt, hint, circles, status, cameraSelect, startButton, stopButton);
    root.append(card);
    document.body.append(root);
    const background = [...document.body.children].filter(element => element !== root)
      .map(element => [element, element.inert]);
    background.forEach(([element]) => { element.inert = true; });
    const handleKeydown = event => {
      if (event.key === 'Escape') { event.preventDefault(); stop(true); return; }
      if (event.key !== 'Tab') return;
      const controls = [...root.querySelectorAll('button:not([disabled]),select:not([disabled])')]
        .filter(element => !element.hidden && element.getClientRects().length);
      if (!controls.length) return;
      const first = controls[0], last = controls[controls.length - 1];
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
    };
    root.addEventListener('keydown', handleKeydown);
    stopButton.focus();

    let stream, recorder, landmarker, interval, started, recordedMs = 0, resolveStopped, resolveStart;
    let latest = { allCaptured: false, completed: [], current: order[0], hint: '' };
    let cancelled = false, stopped = false, lastAnalysis = 0;
    let mirrored = false, lastValid = 0, timed = false, lastVideoTime = -1, previewTurns = 0;
    const fitStage = () => {
      if (!video.videoWidth || !video.videoHeight) return;
      const ratio = previewTurns % 2 ? video.videoHeight / video.videoWidth : video.videoWidth / video.videoHeight;
      const width = Math.min(card.clientWidth - 32, 680, window.innerHeight * .6 * ratio);
      const stageWidth = Math.max(1, width), stageHeight = Math.max(1, width / ratio);
      stage.style.width = `${stageWidth}px`;
      stage.style.height = `${stageHeight}px`;
      const frameWidth = previewTurns % 2 ? stageHeight : stageWidth;
      const frameHeight = previewTurns % 2 ? stageWidth : stageHeight;
      frame.style.width = `${frameWidth}px`;
      frame.style.height = `${frameHeight}px`;
      frame.style.left = `${(stageWidth - frameWidth) / 2}px`;
      frame.style.top = `${(stageHeight - frameHeight) / 2}px`;
      frame.style.transform = `rotate(${previewTurns * 90}deg)`;
      render();
    };
    rotateButton.onclick = () => { previewTurns = (previewTurns + 1) % 4; fitStage(); };
    const updateMirror = () => {
      const facing = stream?.getVideoTracks()[0]?.getSettings().facingMode;
      mirrored = facing === 'user';
      video.style.transform = mirrored ? 'scaleX(-1)' : '';
    };
    const chunks = [];
    const stoppedPromise = new Promise(resolve => { resolveStopped = resolve; });
    const poseChips = order.map(pose => {
      const item = document.createElement('span');
      item.dataset.pose = pose;
      return item;
    });
    circles.append(...poseChips);
    const render = () => {
      const nextPrompt = latest.current ? `Look ${latest.current}` : 'All directions captured';
      if (prompt.textContent !== nextPrompt) prompt.textContent = nextPrompt;
      const nextHint = latest.allCaptured
        ? 'Keep facing the camera until recording stops automatically.'
        : latest.hint || 'Keep only your face in the guide';
      if (hint.textContent !== nextHint) hint.textContent = nextHint;
      poseChips.forEach((item, index) => {
        const pose = order[index];
        const done = latest.completed.includes(pose);
        const state = done ? 'done' : 'pending';
        if (item.dataset.state !== state) {
          item.dataset.state = state;
          item.textContent = `${done ? '✓ ' : '○ '}${pose}`;
          item.style.cssText = `border-radius:20px;padding:7px 10px;font-size:13px;background:${done ? '#d4f3e5' : '#edf2ef'};color:#17392f`;
        }
      });
      oval.style.borderColor = latest.hint === 'Hold still…' || latest.allCaptured ? '#52df9d' : '#e9f7f0';
      const scale = Math.min(frame.clientWidth / video.videoWidth, frame.clientHeight / video.videoHeight);
      if (Number.isFinite(scale) && scale > 0) {
        const width = video.videoWidth * scale, height = video.videoHeight * scale;
        let [left, top, right, bottom] = latest.bounds || [.24, .12, .76, .88];
        if (mirrored) [left, right] = [1 - right, 1 - left];
        oval.style.inset = 'auto';
        oval.style.left = `${(frame.clientWidth - width) / 2 + left * width}px`;
        oval.style.top = `${(frame.clientHeight - height) / 2 + top * height}px`;
        oval.style.width = `${(right - left) * width}px`;
        oval.style.height = `${(bottom - top) * height}px`;
        oval.style.borderRadius = latest.bounds ? '16px' : '50%';
      }
      if (started) status.textContent = `${Math.min(25, Math.floor((performance.now() - started) / 1000))} / 25 seconds · audio off`;
    };
    const stop = (discard = false) => {
      if (stopped) return;
      stopped = true;
      cancelled = discard;
      if (started !== undefined) recordedMs = performance.now() - started;
      resolveStart?.();
      if (recorder?.state === 'recording') recorder.stop();
      else resolveStopped();
    };
    const resize = new ResizeObserver(() => {
      if (started) render();
      else {
        const text = prompt.textContent;
        render();
        prompt.textContent = text;
      }
    });
    resize.observe(stage);
    window.FaceTrackCapture._stop = stop;
    stopButton.onclick = () => stop(true);

    let waitingForGuide = true, guideTimeout;
    const loadGuide = async () => {
      const asset = path => new URL(`vendor/mediapipe/${path}`, document.baseURI).href;
      const vision = await import(asset('vision_bundle.mjs'));
      const files = await vision.FilesetResolver.forVisionTasks(asset('wasm'));
      const detector = await vision.FaceLandmarker.createFromOptions(files, {
        baseOptions: { modelAssetPath: asset('face_landmarker.task') },
        runningMode: 'VIDEO', numFaces: 2, outputFacialTransformationMatrixes: true,
      });
      if (!waitingForGuide || stopped) { detector.close(); return null; }
      return detector;
    };
    let guidePromise, preloadedGuide;

    try {
      stream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: 'user', width: { ideal: 1280 }, height: { ideal: 720 } },
        audio: false,
      });
      if (stopped) return null;
      video.srcObject = stream;
      updateMirror();
      await video.play();
      fitStage();
      guidePromise = loadGuide().then(detector => {
        preloadedGuide = detector;
        return detector;
      }).catch(() => null);
      window.addEventListener('resize', fitStage);
      const devices = (await navigator.mediaDevices.enumerateDevices())
        .filter(device => device.kind === 'videoinput' && device.deviceId);
      for (const [index, device] of devices.entries()) {
        const option = document.createElement('option');
        option.value = device.deviceId;
        option.textContent = device.label || `Camera ${index + 1}`;
        cameraSelect.append(option);
      }
      cameraSelect.hidden = devices.length < 2;
      const activeId = stream.getVideoTracks()[0]?.getSettings().deviceId;
      if (activeId && devices.some(device => device.deviceId === activeId)) cameraSelect.value = activeId;
      cameraSelect.onchange = async () => {
        if (stopped || started) return;
        startButton.disabled = true;
        try {
          const next = await navigator.mediaDevices.getUserMedia({
            video: { deviceId: { exact: cameraSelect.value }, width: { ideal: 1280 }, height: { ideal: 720 } },
            audio: false,
          });
          if (stopped) { next.getTracks().forEach(track => track.stop()); return; }
          stream.getTracks().forEach(track => track.stop());
          stream = next;
          video.srcObject = next;
          updateMirror();
          await video.play();
          fitStage();
        } catch (_) {
          const stillActive = stream?.getVideoTracks()[0]?.getSettings().deviceId;
          if (stillActive && devices.some(device => device.deviceId === stillActive)) cameraSelect.value = stillActive;
          hint.textContent = 'That camera could not open. Choose another camera.';
        } finally {
          startButton.disabled = false;
        }
      };
      if (stopped) return null;
      prompt.textContent = 'Choose a camera, then start recording';
      startButton.disabled = false;
      await new Promise(resolve => { resolveStart = resolve; startButton.onclick = resolve; });
      if (stopped) return null;
      cameraSelect.disabled = true;
      startButton.remove();
      prompt.textContent = 'Preparing face guide…';
      try {
        landmarker = await Promise.race([
          guidePromise,
          stoppedPromise.then(() => null),
          new Promise(resolve => { guideTimeout = setTimeout(() => resolve(null), 8000); }),
        ]);
      } finally {
        waitingForGuide = false;
        clearTimeout(guideTimeout);
      }
      if (stopped) return null;
      const mime = ['video/webm;codecs=vp8', 'video/webm'].find(MediaRecorder.isTypeSupported);
      if (!mime) throw new Error('Browser video recording is unavailable');
      recorder = new MediaRecorder(stream, { mimeType: mime, videoBitsPerSecond: 3500000 });
      recorder.ondataavailable = event => { if (event.data.size) chunks.push(event.data); };
      recorder.onstop = resolveStopped;
      recorder.onerror = () => stop(true);
      const recorderStarted = new Promise(resolve => {
        recorder.onstart = () => {
          started = performance.now();
          resolve();
        };
      });
      recorder.start();
      await Promise.race([recorderStarted, stoppedPromise]);
      if (stopped) return null;
      const canvas = document.createElement('canvas');
      canvas.width = 24; canvas.height = 18;
      const context = canvas.getContext('2d', { willReadFrequently: true });
      render();
      interval = setInterval(() => {
        if (stopped) return;
        const elapsed = performance.now() - started;
        if (elapsed >= maximumMs || (latest.allCaptured && elapsed >= earliestStopMs)) {
          stop();
          return;
        }
        timed = !landmarker || elapsed - lastValid >= 2000;
        if (timed) {
          latest.bounds = null;
          latest.hint = 'Live guidance unavailable. Follow the timed directions.';
          const index = Math.min(order.length - 1, Math.floor(elapsed / 5000));
          latest.current = order[index];
          render();
          if (!landmarker) return;
        }
        if (elapsed - lastAnalysis < 200 || video.readyState < 2 || video.currentTime === lastVideoTime) return;
        lastVideoTime = video.currentTime;
        lastAnalysis = elapsed;
        try {
          const result = landmarker.detectForVideo(video, performance.now());
          const faces = result.faceLandmarks || [];
          let bounds = null, yaw = null, pitch = null, luminance = null;
          if (faces.length === 1) {
            const points = faces[0];
            const xs = points.map(p => p.x), ys = points.map(p => p.y);
            bounds = [Math.max(0, Math.min(...xs)), Math.max(0, Math.min(...ys)),
              Math.min(1, Math.max(...xs)), Math.min(1, Math.max(...ys))];
            const matrix = result.facialTransformationMatrixes?.[0]?.data;
            if (matrix?.length >= 16) {
              yaw = Math.atan2(matrix[2], matrix[10]) * 180 / Math.PI * (mirrored ? 1 : -1);
              pitch = Math.asin(Math.max(-1, Math.min(1, -matrix[6]))) * 180 / Math.PI;
            }
            context.drawImage(video, 0, 0, 24, 18);
            const pixels = context.getImageData(0, 0, 24, 18).data;
            let total = 0;
            for (let i = 0; i < pixels.length; i += 16) total += (pixels[i] + pixels[i + 1] + pixels[i + 2]) / 3;
            luminance = total / (pixels.length / 16);
          }
          lastValid = elapsed;
          timed = false;
          latest = JSON.parse(onFrame(JSON.stringify({ faceCount: faces.length, bounds, yaw, pitch, luminance })));
        } catch (_) {
          timed = true;
          latest.bounds = null;
          latest.hint = 'Live guidance unavailable. Follow the timed directions.';
        }
        render();
      }, 100);
      await stoppedPromise;
      const blob = new Blob(chunks, { type: mime });
      if (cancelled || blob.size === 0 || recordedMs < earliestStopMs) return null;
      return URL.createObjectURL(blob);
    } finally {
      waitingForGuide = false;
      clearTimeout(guideTimeout);
      if (window.FaceTrackCapture._stop === stop) window.FaceTrackCapture._stop = null;
      clearInterval(interval);
      stream?.getTracks().forEach(track => track.stop());
      (landmarker || preloadedGuide)?.close();
      resize.disconnect();
      window.removeEventListener('resize', fitStage);
      root.remove();
      background.forEach(([element, wasInert]) => { element.inert = wasInert; });
      if (previousFocus?.isConnected) previousFocus.focus();
    }
  },
};
