const test = require('node:test');
const assert = require('node:assert/strict');
require('../web/classroom_capture.js');
const { FaceTracker, recordPart } = globalThis.FaceTrackClassroom;
const box = { x: 50, y: 50, w: 120, h: 140 };
test('stable face needs a continuous 400ms hold, and leaving view resets it', () => {
  const tracker = new FaceTracker();
  const a = tracker.update([box], 0, 640, 480)[0];
  assert.equal(a.green, false);
  assert.equal(tracker.update([{ ...box, x: 55 }], 200, 640, 480)[0].id, a.id);
  assert.equal(tracker.update([box], 400, 640, 480)[0].green, true);
  tracker.update([], 600, 640, 480);
  const next = tracker.update([box], 800, 640, 480)[0];
  assert.notEqual(next.id, a.id); assert.equal(next.green, false);
});
test('small/edge faces stay neutral; boxes expire within one second', () => {
  const tracker = new FaceTracker();
  tracker.update([{ ...box, w: 80 }, { ...box, x: 0 }], 0, 640, 480);
  assert.ok(tracker.update([{ ...box, w: 80 }, { ...box, x: 0 }], 500, 640, 480).every(t => !t.green));
  tracker.expire(1499); assert.equal(tracker.tracks.length, 2);
  tracker.expire(1500); assert.equal(tracker.tracks.length, 0);
});
test('association assigns one temporary ID to only one visible face', () => {
  const tracker = new FaceTracker();
  tracker.update([box], 0, 640, 480);
  const faces = tracker.update([box, { ...box, x: 80 }], 200, 640, 480);
  assert.notEqual(faces[0].id, faces[1].id);
});
class FakeRecorder {
  static instances = [];
  static isTypeSupported(type) { return type.startsWith('video/webm'); }
  constructor(stream) { this.stream = stream; this.state = 'inactive'; FakeRecorder.instances.push(this); }
  start() { this.state = 'recording'; }
  stop() { this.state = 'inactive'; this.ondataavailable({ data: new Blob(['WEBM_HEADER', 'FRAME']) }); this.onstop(); }
}
test('each part creates a fresh recorder on the same stream and is independently headed', async () => {
  globalThis.MediaRecorder = FakeRecorder;
  const stream = {};
  const first = await recordPart(stream, () => {}, 1);
  const second = await recordPart(stream, () => {}, 1);
  assert.equal(FakeRecorder.instances.length, 2);
  assert.ok(FakeRecorder.instances.every(r => r.stream === stream));
  assert.equal(await first.text(), 'WEBM_HEADERFRAME');
  assert.equal(await second.text(), 'WEBM_HEADERFRAME');
});
test('external cancellation settles the current part without stopping the shared stream', async () => {
  globalThis.MediaRecorder = FakeRecorder;
  let current;
  const part = recordPart({}, recorder => { current = recorder; }, 12000);
  current.stop();
  assert.ok((await part).size > 0);
});

test('stopping a scan releases the camera before an in-flight upload finishes', async () => {
  const api = globalThis.FaceTrackClassroom;
  const nodes = new Map();
  let removed = false;
  const root = {
    setAttribute() {}, addEventListener() {},
    remove() { removed = true; },
    querySelector(selector) {
      if (!nodes.has(selector)) nodes.set(selector, {
        style: {}, focus() {}, play: async () => {},
        getContext: () => ({ clearRect() {} }),
      });
      return nodes.get(selector);
    },
  };
  const track = {
    stopped: false,
    getSettings: () => ({ facingMode: 'environment' }),
    stop() { this.stopped = true; },
  };
  const stream = { getVideoTracks: () => [track], getTracks: () => [track] };
  const restore = {};
  for (const [key, value] of Object.entries({
    document: {
      createElement: (tag) => tag === 'div' ? root : root.querySelector(tag),
      body: { append() {} },
      addEventListener() {}, removeEventListener() {},
    },
    window: { addEventListener() {}, removeEventListener() {} },
    ResizeObserver: class { observe() {} disconnect() {} },
    navigator: { mediaDevices: {
      getUserMedia: async () => stream,
      enumerateDevices: async () => [],
    } },
  })) {
    restore[key] = Object.getOwnPropertyDescriptor(globalThis, key);
    Object.defineProperty(globalThis, key, { configurable: true, value });
  }
  globalThis.MediaRecorder = FakeRecorder;
  let finishUpload, startedUpload;
  const uploadStarted = new Promise(resolve => { startedUpload = resolve; });
  const upload = new Promise(resolve => { finishUpload = resolve; });
  const scan = api.scan(async () => { startedUpload(); await upload; }, () => {});
  try {
    await new Promise(resolve => setImmediate(resolve));
    root.querySelector('.start').onclick();
    await new Promise(resolve => setImmediate(resolve));
    FakeRecorder.instances.at(-1).stop();
    await uploadStarted;
    root.querySelector('.stop').onclick();
    assert.equal(track.stopped, true);
    assert.equal(root.querySelector('video').srcObject, null);
    assert.equal(root.querySelector('.stage').hidden, true);
    assert.equal(removed, false);
  } finally {
    finishUpload();
    await scan;
    for (const [key, descriptor] of Object.entries(restore)) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor);
      else delete globalThis[key];
    }
  }
  assert.equal(removed, true);
});
