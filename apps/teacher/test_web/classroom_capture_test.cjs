const test = require('node:test');
const assert = require('node:assert/strict');
require('../web/classroom_capture.js');
const { FaceTracker, brightness, guardUnload, onDeviceChange } = globalThis.FaceTrackClassroom;
const box = { x: 50, y: 50, w: 120, h: 140 };

test('a face counts as framed after a continuous 400ms hold, and leaving view resets it', () => {
  const tracker = new FaceTracker();
  const a = tracker.update([box], 0, 640, 480)[0];
  assert.equal(a.framed, false);
  assert.equal(tracker.update([{ ...box, x: 55 }], 200, 640, 480)[0].id, a.id);
  assert.equal(tracker.update([box], 400, 640, 480)[0].framed, true);
  tracker.update([], 600, 640, 480);
  const next = tracker.update([box], 800, 640, 480)[0];
  assert.notEqual(next.id, a.id); assert.equal(next.framed, false);
});

test('small and edge faces are never framed; boxes expire within one second', () => {
  const tracker = new FaceTracker();
  tracker.update([{ ...box, w: 80 }, { ...box, x: 0 }], 0, 640, 480);
  assert.ok(tracker.update([{ ...box, w: 80 }, { ...box, x: 0 }], 500, 640, 480).every(t => !t.framed));
  tracker.expire(1499); assert.equal(tracker.tracks.length, 2);
  tracker.expire(1500); assert.equal(tracker.tracks.length, 0);
});

test('association assigns one temporary ID to only one visible face', () => {
  const tracker = new FaceTracker();
  tracker.update([box], 0, 640, 480);
  const faces = tracker.update([box, { ...box, x: 80 }], 200, 640, 480);
  assert.notEqual(faces[0].id, faces[1].id);
});

test('nothing is ever marked green: detection does not say who a face is', () => {
  const tracker = new FaceTracker();
  const track = tracker.update([box], 0, 640, 480)[0];
  assert.equal('green' in track, false);
});

test('brightness is the mean luma of the picture', () => {
  const pixels = value => new Uint8ClampedArray(64 * 4).fill(value);
  assert.equal(Math.round(brightness(pixels(0))), 0);
  assert.equal(Math.round(brightness(pixels(255))), 255);
  const dark = brightness(pixels(30)), normal = brightness(pixels(120)), bright = brightness(pixels(230));
  assert.ok(dark < 55 && normal > 55 && normal < 205 && bright > 205);
});

test('the tab-close warning is added once and removed again', () => {
  const added = [], removed = [];
  globalThis.window = { addEventListener: (n, f) => added.push([n, f]), removeEventListener: (n, f) => removed.push([n, f]) };
  guardUnload(true); guardUnload(true);
  assert.equal(added.length, 1); assert.equal(added[0][0], 'beforeunload');
  const event = { preventDefault() { this.stopped = true; } };
  added[0][1](event);
  assert.equal(event.stopped, true); assert.equal(event.returnValue, '');
  guardUnload(false); guardUnload(false);
  assert.equal(removed.length, 1); assert.equal(removed[0][1], added[0][1]);
  delete globalThis.window;
});

const flush = () => new Promise(resolve => setImmediate(resolve));
function fakeDevices(initial) {
  let list = initial;
  const listeners = new Map();
  Object.defineProperty(globalThis, 'navigator', { configurable: true, value: { mediaDevices: {
    addEventListener: (n, f) => listeners.set(n, f), removeEventListener: n => listeners.delete(n),
    enumerateDevices: async () => list,
  } } });
  return { listeners, set: next => { list = next; }, fire: async () => { listeners.get('devicechange')(); await flush(); await flush(); } };
}
const cam = id => ({ kind: 'videoinput', deviceId: id });
const mic = id => ({ kind: 'audioinput', deviceId: id });

test('plugging a camera in or out calls back, and the watcher can be stopped', async () => {
  const devices = fakeDevices([cam('a')]);
  let calls = 0;
  const stop = onDeviceChange(() => calls++);
  devices.set([cam('a'), cam('b')]); await devices.fire();
  assert.equal(calls, 1);
  devices.set([cam('b')]); await devices.fire();
  assert.equal(calls, 2);
  stop();
  assert.equal(devices.listeners.has('devicechange'), false);
});

test('a headset or microphone changing does not count as a camera change', async () => {
  const devices = fakeDevices([cam('a'), mic('m1')]);
  let calls = 0;
  onDeviceChange(() => calls++);
  devices.set([cam('a'), mic('m1'), mic('headset')]); await devices.fire();
  devices.set([cam('a')]); await devices.fire();
  assert.equal(calls, 0);
  devices.set([cam('a'), cam('usb')]); await devices.fire();
  assert.equal(calls, 1);
  await devices.fire(); // same list again: nothing new
  assert.equal(calls, 1);
});

test('when the device list cannot be read the page still hears about the change', async () => {
  const devices = fakeDevices([cam('a')]);
  globalThis.navigator.mediaDevices.enumerateDevices = async () => { throw new Error('blocked'); };
  let calls = 0;
  onDeviceChange(() => calls++);
  await devices.fire();
  assert.equal(calls, 1);
});

// ---- detect(): what it costs on each 200 ms tick ------------------------------------------
function fakePage({ hidden = false } = {}) {
  const log = { scans: 0, canvases: [], draws: 0, detections: 0 };
  const video = {
    tagName: 'VIDEO', isConnected: true, readyState: 4, videoWidth: 1280, videoHeight: 720, currentTime: 0,
    track: { readyState: 'live' },
    get srcObject() { return { getVideoTracks: () => [this.track] }; },
  };
  const document = {
    hidden,
    baseURI: 'http://localhost/',
    querySelectorAll() { log.scans++; return [video]; },
    createElement() {
      const canvas = { widthSets: 0, _w: 300, _h: 150, getContext: () => ({
        drawImage: () => { log.draws++; },
        getImageData: () => ({ data: new Uint8ClampedArray(32 * 18 * 4).fill(120) }),
      }) };
      Object.defineProperty(canvas, 'width', { get() { return this._w; }, set(v) { this.widthSets++; this._w = v; } });
      Object.defineProperty(canvas, 'height', { get() { return this._h; }, set(v) { this._h = v; } });
      log.canvases.push(canvas);
      return canvas;
    },
  };
  const detector = { detectForVideo: () => { log.detections++; return { detections: [
    { boundingBox: { originX: 100, originY: 100, width: 80, height: 90 } }] }; }, close() {} };
  return { document, video, detector, log };
}
function withPage(options, body) {
  const page = fakePage(options);
  const F = globalThis.FaceTrackClassroom;
  globalThis.document = page.document;
  let now = 0;
  F.reset(); F.clock.now = () => now; F.useDetector(page.detector);
  try { body(page, F, ms => { now += ms; page.video.currentTime += ms / 1000; }); }
  finally { F.reset(); delete globalThis.document; }
}

test('the preview picture is searched for once while it stays live', () => withPage({}, (page, F, tick) => {
  for (let i = 0; i < 10; i++) { tick(200); assert.equal(JSON.parse(F.detect()).video, true); }
  assert.equal(page.log.scans, 1);
  assert.equal(page.log.detections, 10);
  // The camera goes away: the picture is searched for again and reported as ended.
  page.video.track.readyState = 'ended'; page.video.isConnected = false;
  const gone = JSON.parse(F.detect());
  assert.equal(gone.video, false);
  assert.ok(page.log.scans >= 2);
}));

test('the detection canvas is only resized when the picture size changes', () => withPage({}, (page, F, tick) => {
  for (let i = 0; i < 10; i++) { tick(200); F.detect(); }
  const [main] = page.log.canvases;
  assert.equal(main.widthSets, 1);
  assert.equal(main.width, 640);
  assert.equal(main.height, 360);
  page.video.videoWidth = 640; page.video.videoHeight = 480; tick(200); F.detect();
  assert.equal(main.widthSets, 1, 'a 640 wide picture needs no change of width');
  assert.equal(main.height, 480);
}));

test('light is measured about once a second and the last value is repeated in between', () => withPage({}, (page, F, tick) => {
  const lights = [];
  for (let i = 0; i < 10; i++) { tick(200); lights.push(JSON.parse(F.detect()).light); }
  assert.ok(lights.every(v => v === 120));
  // The first call measures; so does the call a full second later; nothing in between does.
  assert.equal(page.log.draws - page.log.detections, 2, 'two light draws in two seconds, besides one detection draw per call');
}));

test('a hidden tab skips face detection but keeps reporting the picture', () => withPage({ hidden: true }, (page, F, tick) => {
  tick(200);
  const out = JSON.parse(F.detect());
  assert.equal(out.video, true);
  assert.equal(out.faces, null);
  assert.equal(page.log.detections, 0);
  assert.equal(page.log.draws, 0);
}));
