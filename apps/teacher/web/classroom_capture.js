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
  function findVideo() {
    const all = deepVideos(document);
    const live = all.filter(v => v.srcObject && v.readyState >= 2 && v.videoWidth > 0 &&
      (v.srcObject.getVideoTracks?.() ?? []).some(t => t.readyState === 'live'));
    live.sort((a, b) => b.videoWidth * b.videoHeight - a.videoWidth * a.videoHeight);
    return live[0] || null;
  }
  // Mean luma 0-255 of an RGBA buffer, sampled sparsely; 'dark' below 55, 'bright' above 205.
  function brightness(data) {
    let sum = 0, n = 0;
    for (let i = 0; i < data.length; i += 16) { sum += .299 * data[i] + .587 * data[i + 1] + .114 * data[i + 2]; n++; }
    return n ? sum / n : 0;
  }
  let detector = null, loading = null, closed = false, lastTime = -1;
  const tracker = new FaceTracker();
  const canvas = typeof document === 'undefined' ? null : document.createElement('canvas');
  const context = canvas?.getContext('2d', { willReadFrequently: true });
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
  function stopDetector() { closed = true; detector?.close(); detector = null; tracker.clear(); lastTime = -1; }
  // One JSON string: {faces:[{id,x,y,w,h,framed}], light, width, height}, boxes as 0-1 fractions.
  function detect() {
    const video = findVideo();
    if (!video || !context) {
      // A camera that was unplugged or taken by another app leaves a picture whose tracks have ended.
      const ended = deepVideos(document).some(v => {
        const tracks = v.srcObject?.getVideoTracks?.() ?? [];
        return tracks.length > 0 && tracks.every(t => t.readyState === 'ended');
      });
      return JSON.stringify({ video: false, ended });
    }
    const ratio = Math.min(1, 640 / video.videoWidth);
    canvas.width = Math.round(video.videoWidth * ratio); canvas.height = Math.round(video.videoHeight * ratio);
    context.drawImage(video, 0, 0, canvas.width, canvas.height);
    const out = { video: true, width: video.videoWidth, height: video.videoHeight, faces: [] };
    try { out.light = Math.round(brightness(context.getImageData(0, 0, canvas.width, canvas.height).data)); } catch (_) {}
    if (!detector || video.currentTime === lastTime) return JSON.stringify({ ...out, faces: null, detector: Boolean(detector) });
    lastTime = video.currentTime;
    try {
      const now = performance.now();
      const found = detector.detectForVideo(canvas, now).detections.map(d => ({
        x: d.boundingBox.originX / ratio, y: d.boundingBox.originY / ratio,
        w: d.boundingBox.width / ratio, h: d.boundingBox.height / ratio,
      }));
      out.faces = tracker.update(found, now, video.videoWidth, video.videoHeight).map(t => ({
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
  // Called when a camera is plugged in or removed.
  function onDeviceChange(callback) {
    const target = navigator.mediaDevices;
    if (!target?.addEventListener) return () => {};
    const handler = () => callback();
    target.addEventListener('devicechange', handler);
    return () => target.removeEventListener('devicechange', handler);
  }
  globalThis.FaceTrackClassroom = {
    FaceTracker, brightness, findVideo, startDetector, stopDetector, detect, guardUnload, onDeviceChange,
  };
})();
