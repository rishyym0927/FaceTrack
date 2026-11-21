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

test('plugging a camera in or out calls back, and the watcher can be stopped', () => {
  const listeners = new Map();
  Object.defineProperty(globalThis, 'navigator', { configurable: true, value: { mediaDevices: {
    addEventListener: (n, f) => listeners.set(n, f), removeEventListener: n => listeners.delete(n),
  } } });
  let calls = 0;
  const stop = onDeviceChange(() => calls++);
  listeners.get('devicechange')(); listeners.get('devicechange')();
  assert.equal(calls, 2);
  stop();
  assert.equal(listeners.has('devicechange'), false);
});
