import assert from 'node:assert/strict';
import test from 'node:test';
import {
  TYPE_VIEWER_DECISION,
  TYPE_VIEWER_JOIN,
  TYPE_VIEWER_LEAVE,
  TYPE_VIEWER_OUTPUT,
  TYPE_VIEWER_SHARE,
  MAX_VIEWER_SOCKETS,
  MemoryViewerStore,
  ViewerRouter,
  decodeFrame,
  encodeFrame,
  jsonFrame,
  normalizeShareCode,
  viewerOutputId
} from '../src/viewer.js';

const decoder = new TextDecoder();

class FakeSocket {
  constructor() {
    this.sent = [];
    this.closed = null;
  }
  send(bytes) {
    if (this.closed) throw new Error('closed');
    this.sent.push(bytes);
  }
  close(code, reason) {
    this.closed = { code, reason };
  }
  frames() {
    return this.sent.map((bytes) => decodeFrame(bytes));
  }
  json(index) {
    return JSON.parse(decoder.decode(this.frames()[index].payload));
  }
}

function setup({ macOnline = true } = {}) {
  const toMac = [];
  const store = new MemoryViewerStore();
  const sendToMac = (bytes) => {
    if (!macOnline) return false;
    toMac.push(decodeFrame(bytes));
    return true;
  };
  const router = new ViewerRouter({ sendToMac, store });
  // A router rebuilt from the same store and share code, as the Durable
  // Object does after hibernation.
  const rebuild = () => new ViewerRouter({ sendToMac, store, shareCode: router.shareCode });
  const macJSON = (index) => JSON.parse(decoder.decode(toMac[index].payload));
  return { router, toMac, macJSON, rebuild };
}

function outputFrame(viewerId, inner) {
  const id = new TextEncoder().encode(viewerId);
  const payload = new Uint8Array(1 + id.length + inner.length);
  payload[0] = id.length;
  payload.set(id, 1);
  payload.set(inner, 1 + id.length);
  return encodeFrame(TYPE_VIEWER_OUTPUT, payload, 3);
}

function joined(router, id = 'viewer-1', code = 'abcd1234') {
  const socket = new FakeSocket();
  assert.equal(router.acceptViewer(socket, code), true);
  router.onViewerMessage(
    socket,
    jsonFrame(TYPE_VIEWER_JOIN, { viewer_id: id, name: 'Phone', share_code: 'zzzzzzzz' })
  );
  return socket;
}

test('share codes are 8 lowercase letters or digits', () => {
  assert.equal(normalizeShareCode(' AbCd1234 '), 'abcd1234');
  assert.equal(normalizeShareCode('abc'), null);
  assert.equal(normalizeShareCode('abcd-234'), null);
  assert.equal(normalizeShareCode(undefined), null);
});

test('frames round trip and viewer output carries the viewer id', () => {
  const inner = encodeFrame(0x20, 'hello');
  const frame = decodeFrame(outputFrame('v1', inner));
  assert.equal(frame.type, TYPE_VIEWER_OUTPUT);
  assert.equal(frame.tabId, 3);
  assert.equal(viewerOutputId(frame.payload), 'v1');
  assert.equal(decodeFrame(new Uint8Array(5)), null);
});

test('a viewer is rejected when nothing is shared or the code is wrong', () => {
  const { router } = setup();
  const first = new FakeSocket();
  assert.equal(router.acceptViewer(first, 'abcd1234'), false);
  assert.equal(first.json(0).reason, 'not_sharing');
  assert.ok(first.closed);

  router.setShare('abcd1234');
  const second = new FakeSocket();
  assert.equal(router.acceptViewer(second, 'ffff0000'), false);
  assert.equal(second.json(0).reason, 'invalid_code');
});

test("a join reaches the Mac with the URL's code, and the decision comes back", () => {
  const { router, toMac, macJSON } = setup();
  assert.deepEqual(router.setShare('ABCD1234'), { unregister: null, register: 'abcd1234' });
  const socket = joined(router);
  assert.equal(toMac.length, 1);
  assert.equal(toMac[0].type, TYPE_VIEWER_JOIN);
  assert.deepEqual(macJSON(0), { viewer_id: 'viewer-1', name: 'Phone', share_code: 'abcd1234' });

  // A second join on the same socket is ignored.
  router.onViewerMessage(socket, jsonFrame(TYPE_VIEWER_JOIN, { viewer_id: 'other' }));
  assert.equal(toMac.length, 1);

  const result = router.onMacFrame(
    jsonFrame(TYPE_VIEWER_DECISION, { viewer_id: 'viewer-1', approved: true })
  );
  assert.equal(result.handled, true);
  assert.equal(socket.json(0).approved, true);
  assert.equal(socket.closed, null);

  const inner = encodeFrame(0x20, 'ls\r\n');
  router.onMacFrame(outputFrame('viewer-1', inner));
  assert.equal(socket.frames()[1].type, TYPE_VIEWER_OUTPUT);
  // Output for another viewer is not delivered here.
  router.onMacFrame(outputFrame('someone-else', inner));
  assert.equal(socket.sent.length, 2);
});

test('a denied viewer gets the decision and is closed without a leave', () => {
  const { router, toMac } = setup();
  router.setShare('abcd1234');
  const socket = joined(router);
  router.onMacFrame(
    jsonFrame(TYPE_VIEWER_DECISION, { viewer_id: 'viewer-1', approved: false, reason: 'denied' })
  );
  assert.equal(socket.json(0).reason, 'denied');
  assert.ok(socket.closed);
  router.onViewerClose(socket);
  assert.equal(toMac.length, 1);
});

test('a viewer can only join and leave; anything else is dropped', () => {
  const { router, toMac, macJSON } = setup();
  router.setShare('abcd1234');
  const socket = joined(router);
  router.onViewerMessage(socket, encodeFrame(0x21, 'rm -rf /\r'));
  router.onViewerMessage(
    socket,
    jsonFrame(TYPE_VIEWER_DECISION, { viewer_id: 'viewer-1', approved: true })
  );
  router.onViewerMessage(socket, 'text message');
  assert.equal(toMac.length, 1);

  router.onViewerMessage(socket, jsonFrame(TYPE_VIEWER_LEAVE, { viewer_id: 'spoofed' }));
  assert.equal(toMac.length, 2);
  assert.equal(toMac[1].type, TYPE_VIEWER_LEAVE);
  assert.deepEqual(macJSON(1), { viewer_id: 'viewer-1' });
  assert.ok(socket.closed);
});

test('closing a joined viewer tells the Mac; closing before joining does not', () => {
  const { router, toMac } = setup();
  router.setShare('abcd1234');
  const silent = new FakeSocket();
  router.acceptViewer(silent, 'abcd1234');
  router.onViewerClose(silent);
  assert.equal(toMac.length, 0);

  const socket = joined(router);
  router.onViewerClose(socket);
  assert.equal(toMac.length, 2);
  assert.equal(toMac[1].type, TYPE_VIEWER_LEAVE);
});

test('a viewer id already connected is refused', () => {
  const { router, toMac } = setup();
  router.setShare('abcd1234');
  const first = joined(router);
  const second = joined(router);
  assert.equal(second.json(0).reason, 'viewer_id_in_use');
  assert.ok(second.closed);
  assert.equal(first.closed, null);
  assert.equal(toMac.length, 1);
});

test('a join while the Mac is away is answered with host_offline', () => {
  const { router } = setup({ macOnline: false });
  router.setShare('abcd1234');
  const socket = joined(router);
  assert.equal(socket.json(0).reason, 'host_offline');
  assert.ok(socket.closed);
});

test('the Mac leaving a viewer, a new code and a disconnect end viewings', () => {
  const { router } = setup();
  router.setShare('abcd1234');
  const revoked = joined(router, 'a');
  router.onMacFrame(jsonFrame(TYPE_VIEWER_LEAVE, { viewer_id: 'a' }));
  assert.equal(revoked.frames()[0].type, TYPE_VIEWER_LEAVE);
  assert.ok(revoked.closed);

  const old = joined(router, 'b');
  assert.deepEqual(router.setShare('ffff0000'), { unregister: 'abcd1234', register: 'ffff0000' });
  assert.ok(old.closed);

  const current = joined(router, 'c', 'ffff0000');
  assert.equal(router.macDisconnected(), 'ffff0000');
  assert.equal(current.frames()[0].type, TYPE_VIEWER_LEAVE);
  assert.ok(current.closed);
  assert.equal(router.shareCode, null);
});

test('viewer frames from the Mac never reach the phone; other frames do', () => {
  const { router } = setup();
  assert.equal(router.onMacFrame(encodeFrame(0x20, 'x')).handled, false);
  const share = router.onMacFrame(
    jsonFrame(TYPE_VIEWER_SHARE, { share_code: 'abcd1234', max_viewers: 5 })
  );
  assert.deepEqual(share, { handled: true, share: 'abcd1234' });
  const stop = router.onMacFrame(
    jsonFrame(TYPE_VIEWER_SHARE, { share_code: null, max_viewers: 5 })
  );
  assert.deepEqual(stop, { handled: true, share: null });
  assert.equal(router.onMacFrame(jsonFrame(TYPE_VIEWER_JOIN, {})).handled, true);
});

test('the number of viewer sockets is capped', () => {
  const { router } = setup();
  router.setShare('abcd1234');
  for (let i = 0; i < MAX_VIEWER_SOCKETS; i += 1) {
    assert.equal(router.acceptViewer(new FakeSocket(), 'abcd1234'), true);
  }
  const extra = new FakeSocket();
  assert.equal(router.acceptViewer(extra, 'abcd1234'), false);
  assert.equal(extra.json(0).reason, 'max_viewers');
});

test('routing survives a router rebuilt from the stored sockets', () => {
  const { router, rebuild } = setup();
  router.setShare('abcd1234');
  const socket = joined(router);
  const after = rebuild();
  after.onMacFrame(jsonFrame(TYPE_VIEWER_DECISION, { viewer_id: 'viewer-1', approved: true }));
  assert.equal(socket.json(0).approved, true);
  after.onMacFrame(outputFrame('viewer-1', encodeFrame(0x20, 'x')));
  assert.equal(socket.frames()[1].type, TYPE_VIEWER_OUTPUT);
});

test('a replaced Mac connection ends viewings but keeps the share', () => {
  const { router } = setup();
  router.setShare('abcd1234');
  const socket = joined(router);
  assert.equal(router.macDisconnected({ keepShare: true }), null);
  assert.ok(socket.closed);
  assert.equal(router.shareCode, 'abcd1234');
});

test('malformed frames of the viewer range are dropped, not forwarded', () => {
  const { router } = setup();
  const bytes = encodeFrame(TYPE_VIEWER_OUTPUT, new Uint8Array(0));
  assert.equal(router.onMacFrame(bytes.subarray(0, 10)).handled, true);
});
