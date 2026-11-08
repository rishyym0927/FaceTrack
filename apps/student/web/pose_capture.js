// Enrolment-only browser camera. Preview frames are analyzed locally and never uploaded.
window.FaceTrackCapture = {
  _stop: null,
  cancel() { window.FaceTrackCapture._stop?.(true); },
  async record(order, onFrame) {
    const root = document.createElement('div');
    root.style.cssText = 'position:fixed;inset:0;z-index:10000;background:#f3f7f5;display:flex;align-items:center;justify-content:center;padding:16px;font-family:system-ui,sans-serif;color:#17392f';
    const card = document.createElement('div');
    card.style.cssText = 'width:min(100%,520px);background:white;border:1px solid #d5e2dc;border-radius:22px;padding:20px;box-shadow:0 12px 40px #17392f22';
    const title = document.createElement('h2');
    title.textContent = 'Record your face';
    title.style.cssText = 'font-size:22px;margin:0 0 12px';
    const stage = document.createElement('div');
    stage.style.cssText = 'position:relative;overflow:hidden;border-radius:16px;background:#23372f;aspect-ratio:4/3';
    const video = document.createElement('video');
    video.autoplay = true;
    video.muted = true;
    video.playsInline = true;
    video.style.cssText = 'width:100%;height:100%;object-fit:contain;transform:scaleX(-1)';
    const oval = document.createElement('div');
    oval.style.cssText = 'position:absolute;inset:12% 20%;border:3px solid #e9f7f0;border-radius:50%;pointer-events:none;box-shadow:0 0 0 100vmax #0002';
    stage.append(video, oval);
    const prompt = document.createElement('div');
    prompt.setAttribute('aria-live', 'polite');
    prompt.style.cssText = 'font-size:22px;font-weight:650;margin:16px 0 4px';
    prompt.textContent = 'Allow camera access';
    const hint = document.createElement('div');
    hint.setAttribute('aria-live', 'polite');
    hint.style.cssText = 'min-height:44px;color:#48645a';
    const circles = document.createElement('div');
    circles.style.cssText = 'display:flex;gap:9px;margin:12px 0 16px;flex-wrap:wrap';
    const status = document.createElement('div');
    status.style.cssText = 'font-size:14px;color:#48645a;margin-bottom:12px';
    const stopButton = document.createElement('button');
    stopButton.textContent = 'Stop and retry';
    stopButton.style.cssText = 'border:1px solid #0b6b57;color:#0b6b57;background:white;border-radius:12px;padding:12px 18px;min-height:48px;font:inherit;cursor:pointer';
    const cameraSelect = document.createElement('select');
    cameraSelect.setAttribute('aria-label', 'Camera');
    cameraSelect.style.cssText = 'width:100%;padding:12px;margin:8px 0;border:1px solid #86a59a;border-radius:10px;font:inherit';
    const startButton = document.createElement('button');
    startButton.textContent = 'Start recording';
    startButton.style.cssText = 'background:#0b6b57;color:white;border:0;border-radius:12px;padding:12px 18px;min-height:48px;font:inherit;cursor:pointer;margin-right:8px';
    card.append(title, stage, prompt, hint, circles, status, cameraSelect, startButton, stopButton);
    root.append(card);
    document.body.append(root);

    let stream, recorder, landmarker, interval, started, resolveStopped, resolveStart;
    let latest = { allCaptured: false, completed: [], current: order[0], hint: '' };
    let cancelled = false, stopped = false, lastAnalysis = 0;
    const chunks = [];
    const stoppedPromise = new Promise(resolve => { resolveStopped = resolve; });
    const render = () => {
      prompt.textContent = latest.current ? `Look ${latest.current}` : 'All directions captured';
      hint.textContent = latest.hint || 'Keep only your face in the guide';
      circles.replaceChildren(...order.map(pose => {
        const item = document.createElement('span');
        const done = latest.completed.includes(pose);
        item.textContent = `${done ? '✓ ' : '○ '}${pose}`;
        item.style.cssText = `border-radius:20px;padding:7px 10px;font-size:13px;background:${done ? '#d4f3e5' : '#edf2ef'};color:#17392f`;
        return item;
      }));
      oval.style.borderColor = latest.hint === 'Hold still…' || latest.allCaptured ? '#52df9d' : '#e9f7f0';
      if (latest.bounds) {
        const [left, top, right, bottom] = latest.bounds;
        oval.style.inset = `${top * 100}% ${left * 100}% ${(1 - bottom) * 100}% ${(1 - right) * 100}%`;
        oval.style.borderRadius = '16px';
      } else {
        oval.style.inset = '12% 20%';
        oval.style.borderRadius = '50%';
      }
      if (started) status.textContent = `${Math.min(25, Math.floor((performance.now() - started) / 1000))} / 25 seconds · audio off`;
    };
    const stop = (discard = false) => {
      if (stopped) return;
      stopped = true;
      cancelled = discard;
      resolveStart?.();
      if (recorder?.state === 'recording') recorder.stop();
      else resolveStopped();
    };
    window.FaceTrackCapture._stop = stop;
    stopButton.onclick = () => stop(true);

    try {
      stream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: 'user', width: { ideal: 1280 }, height: { ideal: 720 } },
        audio: false,
      });
      video.srcObject = stream;
      await video.play();
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
          await video.play();
        } catch (_) {
          const stillActive = stream?.getVideoTracks()[0]?.getSettings().deviceId;
          if (stillActive && devices.some(device => device.deviceId === stillActive)) cameraSelect.value = stillActive;
          hint.textContent = 'That camera could not open. Choose another camera.';
        } finally {
          startButton.disabled = false;
        }
      };
      prompt.textContent = 'Choose a camera, then start recording';
      await new Promise(resolve => { resolveStart = resolve; startButton.onclick = resolve; });
      if (stopped) return null;
      cameraSelect.disabled = true;
      startButton.remove();
      // Match the video content's ratio so normalized landmarks align with
      // the visible outline instead of the letterboxed stage.
      if (video.videoWidth && video.videoHeight) {
        stage.style.aspectRatio = `${video.videoWidth}/${video.videoHeight}`;
      }
      prompt.textContent = 'Preparing face guide…';
      try {
        const vision = await import('https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.35/vision_bundle.mjs');
        const files = await vision.FilesetResolver.forVisionTasks('https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.35/wasm');
        landmarker = await vision.FaceLandmarker.createFromOptions(files, {
          baseOptions: { modelAssetPath: 'https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task' },
          runningMode: 'VIDEO', numFaces: 2, outputFacialTransformationMatrixes: true,
        });
      } catch (_) {
        latest.hint = 'Live guidance unavailable; follow each prompt and review your video';
      }
      if (stopped) return null;
      const mime = ['video/webm;codecs=vp8', 'video/webm'].find(MediaRecorder.isTypeSupported);
      if (!mime) throw new Error('Browser video recording is unavailable');
      recorder = new MediaRecorder(stream, { mimeType: mime, videoBitsPerSecond: 3500000 });
      recorder.ondataavailable = event => { if (event.data.size) chunks.push(event.data); };
      recorder.onstop = resolveStopped;
      recorder.onerror = () => stop(true);
      recorder.start();
      started = performance.now();
      const canvas = document.createElement('canvas');
      canvas.width = 24; canvas.height = 18;
      const context = canvas.getContext('2d', { willReadFrequently: true });
      render();
      interval = setInterval(() => {
        if (stopped) return;
        const elapsed = performance.now() - started;
        if (elapsed >= 25000 || (latest.allCaptured && elapsed >= 10000)) {
          stop();
          return;
        }
        if (!landmarker) {
          const index = Math.min(order.length - 1, Math.floor(elapsed / 5000));
          latest.current = order[index];
          render();
          return;
        }
        if (elapsed - lastAnalysis < 170 || video.readyState < 2) return;
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
              yaw = Math.atan2(matrix[2], matrix[10]) * 180 / Math.PI;
              pitch = Math.asin(Math.max(-1, Math.min(1, -matrix[6]))) * 180 / Math.PI;
            }
            context.drawImage(video, 0, 0, 24, 18);
            const pixels = context.getImageData(0, 0, 24, 18).data;
            let total = 0;
            for (let i = 0; i < pixels.length; i += 16) total += (pixels[i] + pixels[i + 1] + pixels[i + 2]) / 3;
            luminance = total / (pixels.length / 16);
          }
          latest = JSON.parse(onFrame(JSON.stringify({ faceCount: faces.length, bounds, yaw, pitch, luminance })));
        } catch (_) {
          latest.hint = 'Live guidance unavailable; follow the prompts and review your video';
        }
        render();
      }, 100);
      await stoppedPromise;
      const blob = new Blob(chunks, { type: mime });
      if (cancelled || blob.size === 0 || performance.now() - started < 10000) return null;
      return URL.createObjectURL(blob);
    } finally {
      window.FaceTrackCapture._stop = null;
      clearInterval(interval);
      stream?.getTracks().forEach(track => track.stop());
      landmarker?.close();
      root.remove();
    }
  },
};
