// Local advisory framing only. Detection says nothing about who a face is, so nothing here
// is ever drawn green. Recognition uses private, independently decodable segments on the server.
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
        return { id, box, since, last: now, framed: framed && now - since >= 400 };
      });
      return this.tracks;
    }
  }

  // ---- Live framing for the Flutter scan page --------------------------------------------
  // The Flutter `camera` plugin owns the camera, the preview and the recording. This only
  // reads frames from that preview <video> to find faces and judge the light.
  function deepVideos(root, found = []) {
    for (const node of root.querySelectorAll('*')) {
      if (node.tagName === 'VIDEO') found.push(node);
      if (node.shadowRoot) deepVideos(node.shadowRoot, found);
    }
    return found;
  }
  function liveVideo(v) {
    return Boolean(v && v.isConnected && v.srcObject && v.readyState >= 2 && v.videoWidth > 0 &&
      (v.srcObject.getVideoTracks?.() ?? []).some(t => t.readyState === 'live'));
  }
  function findVideo() {
    const all = deepVideos(document);
    const live = all.filter(liveVideo);
    live.sort((a, b) => b.videoWidth * b.videoHeight - a.videoWidth * a.videoHeight);
    return live[0] || null;
  }
  // The picture is looked up once and kept while it stays live: searching the whole page (and
  // every shadow root) five times a second cost about 9 ms per call on a 10 000-element page.
  let cachedVideo = null;
  function currentVideo() {
    if (!liveVideo(cachedVideo)) cachedVideo = findVideo();
    return cachedVideo;
  }
  // Mean luma 0-255 of an RGBA buffer, sampled sparsely; 'dark' below 55, 'bright' above 205.
  function brightness(data) {
    let sum = 0, n = 0;
    for (let i = 0; i < data.length; i += 16) { sum += .299 * data[i] + .587 * data[i + 1] + .114 * data[i + 2]; n++; }
    return n ? sum / n : 0;
  }
  let detector = null, loading = null, closed = false, lastTime = -1;
  const tracker = new FaceTracker();
  // Overridable clock, so tests need no real time.
  const clock = { now: () => performance.now() };
  // Canvases are made on first use, and only resized when the picture size changes: assigning
  // width/height (even to the same value) reallocates and clears the bitmap.
  let canvas = null, context = null, lightCanvas = null, lightContext = null;
  function surfaces() {
    if (canvas || typeof document === 'undefined') return Boolean(canvas);
    canvas = document.createElement('canvas');
    context = canvas.getContext('2d', { willReadFrequently: true });
    lightCanvas = document.createElement('canvas');
    lightCanvas.width = 32; lightCanvas.height = 18;
    lightContext = lightCanvas.getContext('2d', { willReadFrequently: true });
    return Boolean(context);
  }
  // Light changes slowly: it is measured on a 32x18 copy of the picture, at most once a second
  // (the Dart side smooths it), instead of reading a 640x360 frame back five times a second.
  const LIGHT_EVERY_MS = 1000;
  let light = null, lightAt = -Infinity;
  function measureLight(video, now) {
    if (now - lightAt < LIGHT_EVERY_MS) return light;
    lightAt = now;
    try {
      lightContext.drawImage(video, 0, 0, lightCanvas.width, lightCanvas.height);
      light = Math.round(brightness(lightContext.getImageData(0, 0, lightCanvas.width, lightCanvas.height).data));
    } catch (_) { light = null; }
    return light;
  }
  async function startDetector() {
    closed = false;
    if (detector) return true;
    loading ??= (async () => {
      try {
        const asset = path => new URL(`vendor/mediapipe/${path}`, document.baseURI).href;
        const vision = await import(asset('vision_bundle.mjs'));
        const files = await vision.FilesetResolver.forVisionTasks(asset('wasm'));
        const loaded = await vision.FaceDetector.createFromOptions(files, {
          baseOptions: { modelAssetPath: asset('blaze_face_short_range.tflite') },
          runningMode: 'VIDEO', minDetectionConfidence: .5,
        });
        if (closed) loaded.close(); else detector = loaded;
      } catch (_) { detector = null; }
      loading = null;
      return Boolean(detector);
    })();
    return loading;
  }
  function stopDetector() {
    closed = true; detector?.close(); detector = null; tracker.clear(); lastTime = -1;
    cachedVideo = null; light = null; lightAt = -Infinity;
  }
  // One JSON string: {faces:[{id,x,y,w,h,framed}], light, width, height}, boxes as 0-1 fractions.
  function detect() {
    const video = surfaces() ? currentVideo() : null;
    if (!video) {
      // A camera that was unplugged or taken by another app leaves a picture whose tracks have ended.
      const ended = typeof document !== 'undefined' && deepVideos(document).some(v => {
        const tracks = v.srcObject?.getVideoTracks?.() ?? [];
        return tracks.length > 0 && tracks.every(t => t.readyState === 'ended');
      });
      return JSON.stringify({ video: false, ended });
    }
    const out = { video: true, width: video.videoWidth, height: video.videoHeight, faces: [] };
    const now = clock.now();
    // Nobody sees the boxes in a hidden tab; recording carries on, so only the cheap checks run.
    if (document.hidden) return JSON.stringify({ ...out, light, faces: null, detector: Boolean(detector) });
    out.light = measureLight(video, now);
    if (!detector || video.currentTime === lastTime) return JSON.stringify({ ...out, faces: null, detector: Boolean(detector) });
    lastTime = video.currentTime;
    const ratio = Math.min(1, 640 / video.videoWidth);
    const width = Math.round(video.videoWidth * ratio), height = Math.round(video.videoHeight * ratio);
    if (canvas.width !== width) canvas.width = width;
    if (canvas.height !== height) canvas.height = height;
    context.drawImage(video, 0, 0, width, height);
    try {
      const at = performance.now();
      const found = detector.detectForVideo(canvas, at).detections.map(d => ({
        x: d.boundingBox.originX / ratio, y: d.boundingBox.originY / ratio,
        w: d.boundingBox.width / ratio, h: d.boundingBox.height / ratio,
      }));
      out.faces = tracker.update(found, at, video.videoWidth, video.videoHeight).map(t => ({
        id: t.id, framed: t.framed,
        x: t.box.x / video.videoWidth, y: t.box.y / video.videoHeight,
        w: t.box.w / video.videoWidth, h: t.box.h / video.videoHeight,
      }));
      out.detector = true;
    } catch (_) { tracker.clear(); out.faces = null; out.detector = false; }
    return JSON.stringify(out);
  }
  // A scan holds minutes of unsent video in memory; leaving the page would lose it.
  let guard = null;
  function guardUnload(on) {
    if (on && !guard) { guard = e => { e.preventDefault(); e.returnValue = ''; }; window.addEventListener('beforeunload', guard); }
    else if (!on && guard) { window.removeEventListener('beforeunload', guard); guard = null; }
  }
  // Called when a camera is plugged in or removed. The browser also fires `devicechange` for
  // microphones, headsets and speakers; those must not make the page re-open every camera, so the
  // callback only runs when the list of video inputs differs from the one seen before.
  function onDeviceChange(callback) {
    const target = navigator.mediaDevices;
    if (!target?.addEventListener) return () => {};
    let stopped = false;
    const cameras = async () => {
      try {
        const ids = (await target.enumerateDevices()).filter(d => d.kind === 'videoinput')
          .map(d => d.deviceId || d.groupId || '').sort();
        return `${ids.length}:${ids.join('|')}`;
      } catch (_) { return null; }
    };
    let known = cameras();
    const handler = async () => {
      const before = await known;
      const current = cameras();
      known = current;
      const after = await current;
      if (stopped) return;
      if (before === null || after === null || before !== after) callback();
    };
    target.addEventListener('devicechange', handler);
    return () => { stopped = true; target.removeEventListener('devicechange', handler); };
  }
  // Lets tests supply a stand-in for the MediaPipe detector (the real one needs the browser).
  function useDetector(custom) { detector = custom; closed = false; lastTime = -1; }
  // Drops cached state (tests; and a clean slate after the page is torn down).
  function reset() {
    stopDetector(); canvas = context = lightCanvas = lightContext = null; closed = false;
  }
  globalThis.FaceTrackClassroom = {
    FaceTracker, brightness, findVideo, startDetector, stopDetector, detect, guardUnload, onDeviceChange,
    clock, reset, useDetector,
  };
})();
