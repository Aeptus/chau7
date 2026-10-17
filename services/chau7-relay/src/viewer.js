// Read-only viewers (docs/remote-control/VIEWER-PROTOCOL.md).
//
// The Mac's agent registers a share code with VIEWER_SHARE (0x60). A viewer
// connects to /view/<code> without a relay credential, sends VIEWER_JOIN
// (0x61) with its id and name, and the relay passes the join to the agent
// with the code taken from the URL. The agent answers with VIEWER_DECISION
// (0x62), VIEWER_LEAVE (0x63) and, for approved viewers, VIEWER_OUTPUT
// (0x64), which the relay routes to the viewer by viewer_id. A viewer can
// only join and leave: everything else it sends is dropped. Viewer frames
// are never forwarded to the paired phone.
//
// This module holds the routing so it can be tested without Workers. The
// Durable Object (session.ts) gives it a store of viewer sockets (backed by
// hibernatable WebSocket attachments, so the routing survives eviction) and
// a way to reach the Mac's socket. Only Chau7 Next shares; the Swift app
// never sends VIEWER_SHARE, so for it nothing here is ever reached.

export const HEADER_SIZE = 20;
export const TYPE_VIEWER_SHARE = 0x60;
export const TYPE_VIEWER_JOIN = 0x61;
export const TYPE_VIEWER_DECISION = 0x62;
export const TYPE_VIEWER_LEAVE = 0x63;
export const TYPE_VIEWER_OUTPUT = 0x64;

/** Most viewer sockets one shared session keeps (joined or not). */
export const MAX_VIEWER_SOCKETS = 20;
const MAX_VIEWER_ID_LENGTH = 255;
const MAX_NAME_LENGTH = 100;

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** A share code: 8 lowercase letters or digits (the app's link). */
export function normalizeShareCode(code) {
  if (typeof code !== 'string') {
    return null;
  }
  const normalized = code.trim().toLowerCase();
  return /^[a-z0-9]{8}$/.test(normalized) ? normalized : null;
}

/** Bytes of a WebSocket message (ArrayBuffer or view); null for text. */
export function toBytes(data) {
  if (data instanceof ArrayBuffer) {
    return new Uint8Array(data);
  }
  if (ArrayBuffer.isView(data)) {
    return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
  }
  return null;
}

/** True for a frame of the viewer range (0x60 to 0x64). */
export function isViewerFrame(data) {
  const bytes = toBytes(data);
  return (
    bytes !== null &&
    bytes.length >= 2 &&
    bytes[1] >= TYPE_VIEWER_SHARE &&
    bytes[1] <= TYPE_VIEWER_OUTPUT
  );
}

/** Decodes a frame header; null when the bytes are not a whole frame. */
export function decodeFrame(bytes) {
  if (!bytes || bytes.length < HEADER_SIZE || bytes[0] !== 1) {
    return null;
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const length = view.getUint32(16, true);
  if (bytes.length < HEADER_SIZE + length) {
    return null;
  }
  return {
    type: bytes[1],
    flags: bytes[2],
    tabId: view.getUint32(4, true),
    payload: bytes.subarray(HEADER_SIZE, HEADER_SIZE + length)
  };
}

/** Encodes a cleartext frame (version 1, seq 0). */
export function encodeFrame(type, payload, tabId = 0) {
  const body = typeof payload === 'string' ? encoder.encode(payload) : payload;
  const bytes = new Uint8Array(HEADER_SIZE + body.length);
  const view = new DataView(bytes.buffer);
  bytes[0] = 1;
  bytes[1] = type;
  view.setUint32(4, tabId, true);
  view.setUint32(16, body.length, true);
  bytes.set(body, HEADER_SIZE);
  return bytes;
}

export function jsonFrame(type, value) {
  return encodeFrame(type, JSON.stringify(value));
}

function parseJSON(payload) {
  try {
    const value = JSON.parse(decoder.decode(payload));
    return value && typeof value === 'object' ? value : null;
  } catch {
    return null;
  }
}

/** Viewer id of a VIEWER_OUTPUT payload (`id_len | id | inner frame`). */
export function viewerOutputId(payload) {
  if (payload.length < 1) {
    return null;
  }
  const length = payload[0];
  if (length === 0 || payload.length < 1 + length) {
    return null;
  }
  return decoder.decode(payload.subarray(1, 1 + length));
}

function validViewerId(id) {
  return (
    typeof id === 'string' &&
    id.trim().length > 0 &&
    encoder.encode(id).length <= MAX_VIEWER_ID_LENGTH
  );
}

function safeSend(socket, bytes) {
  try {
    socket.send(bytes);
  } catch {
    // Ignore send errors.
  }
}

function safeClose(socket, code, reason) {
  try {
    socket.close(code, reason);
  } catch {
    // Ignore close errors.
  }
}

/**
 * Viewer sockets kept in memory (tests). The Durable Object uses the same
 * interface over hibernatable WebSocket attachments.
 *
 * An entry is `{ code, viewerId, closed }`: `viewerId` is null until the
 * viewer joins, `closed` marks a socket the router already let go of (a
 * closing socket can still be listed for a moment).
 */
export class MemoryViewerStore {
  constructor() {
    this.entries = new Map();
  }
  list() {
    return [...this.entries.keys()];
  }
  get(socket) {
    return this.entries.get(socket) ?? null;
  }
  set(socket, entry) {
    this.entries.set(socket, entry);
  }
}

export class ViewerRouter {
  /**
   * @param {{
   *   sendToMac: (bytes: Uint8Array) => boolean,
   *   store: { list(): any[], get(socket: any): any, set(socket: any, entry: any): void },
   *   shareCode?: string | null
   * }} host `sendToMac` sends to the Mac's agent (false when no Mac is
   *   connected); `store` holds the viewer sockets; `shareCode` is the code
   *   the agent registered, as persisted by the caller.
   */
  constructor({ sendToMac, store, shareCode = null }) {
    this.sendToMac = sendToMac;
    this.store = store;
    this.shareCode = normalizeShareCode(shareCode);
  }

  /** Live viewer sockets with their entries. */
  live() {
    const result = [];
    for (const socket of this.store.list()) {
      const entry = this.store.get(socket);
      if (entry && !entry.closed) {
        result.push([socket, entry]);
      }
    }
    return result;
  }

  socketFor(viewerId) {
    const found = this.live().find(([, entry]) => entry.viewerId === viewerId);
    return found ? found[0] : undefined;
  }

  /**
   * VIEWER_SHARE from the agent. Returns the codes the registry must drop
   * and add. Viewers of an old code are closed (the agent already sent them
   * a decision or a leave).
   */
  setShare(code) {
    const next = normalizeShareCode(code);
    const previous = this.shareCode;
    if (next === previous) {
      return { unregister: null, register: next };
    }
    this.shareCode = next;
    for (const [socket, entry] of this.live()) {
      if (entry.code !== next) {
        this.dropSocket(socket, 1000, 'Share ended');
      }
    }
    return { unregister: previous, register: next };
  }

  /**
   * A viewer opened /view/<code>. Rejected at once (decision then close)
   * when the code is not the shared one or there are too many viewer
   * sockets. On success the caller keeps the socket and the entry is stored.
   */
  acceptViewer(socket, code) {
    const normalized = normalizeShareCode(code);
    const reject = (reason) => {
      safeSend(socket, jsonFrame(TYPE_VIEWER_DECISION, { viewer_id: '', approved: false, reason }));
      safeClose(socket, 1008, reason);
      return false;
    };
    if (!normalized || normalized !== this.shareCode) {
      return reject(this.shareCode ? 'invalid_code' : 'not_sharing');
    }
    if (this.live().length >= MAX_VIEWER_SOCKETS) {
      return reject('max_viewers');
    }
    this.store.set(socket, { code: normalized, viewerId: null, closed: false });
    return true;
  }

  /** A message from a viewer: only VIEWER_JOIN (once) and VIEWER_LEAVE. */
  onViewerMessage(socket, data) {
    const entry = this.store.get(socket);
    const frame = decodeFrame(toBytes(data));
    if (!entry || entry.closed || !frame || frame.flags !== 0) {
      return;
    }
    if (frame.type === TYPE_VIEWER_JOIN && entry.viewerId === null) {
      const join = parseJSON(frame.payload);
      const id = join && validViewerId(join.viewer_id) ? join.viewer_id.trim() : null;
      if (!id) {
        return;
      }
      if (this.socketFor(id) !== undefined) {
        safeSend(
          socket,
          jsonFrame(TYPE_VIEWER_DECISION, {
            viewer_id: id,
            approved: false,
            reason: 'viewer_id_in_use'
          })
        );
        this.dropSocket(socket, 1008, 'viewer_id_in_use');
        return;
      }
      const name = typeof join.name === 'string' ? join.name.slice(0, MAX_NAME_LENGTH) : '';
      this.store.set(socket, { ...entry, viewerId: id });
      const sent = this.sendToMac(
        jsonFrame(TYPE_VIEWER_JOIN, { viewer_id: id, name, share_code: entry.code })
      );
      if (!sent) {
        safeSend(
          socket,
          jsonFrame(TYPE_VIEWER_DECISION, {
            viewer_id: id,
            approved: false,
            reason: 'host_offline'
          })
        );
        this.dropSocket(socket, 1011, 'host_offline');
      }
      return;
    }
    if (frame.type === TYPE_VIEWER_LEAVE && entry.viewerId !== null) {
      this.dropSocket(socket, 1000, 'Viewer left');
    }
  }

  /** A viewer socket closed: tell the agent if it had joined. */
  onViewerClose(socket) {
    const entry = this.store.get(socket);
    if (!entry || entry.closed) {
      return;
    }
    this.store.set(socket, { ...entry, closed: true });
    if (entry.viewerId !== null) {
      this.sendToMac(jsonFrame(TYPE_VIEWER_LEAVE, { viewer_id: entry.viewerId }));
    }
  }

  /**
   * A frame from the Mac. `handled` is true for a viewer frame (handled
   * here, never forwarded to the phone). VIEWER_SHARE is applied by the
   * caller through setShare, so it comes back as `share` with the code.
   */
  onMacFrame(data) {
    const frame = decodeFrame(toBytes(data));
    if (!frame || frame.type < TYPE_VIEWER_SHARE || frame.type > TYPE_VIEWER_OUTPUT) {
      return { handled: isViewerFrame(data) };
    }
    if (frame.type === TYPE_VIEWER_SHARE) {
      const share = parseJSON(frame.payload);
      return { handled: true, share: share ? (share.share_code ?? null) : null };
    }
    if (frame.type === TYPE_VIEWER_OUTPUT) {
      const id = viewerOutputId(frame.payload);
      const socket = id === null ? undefined : this.socketFor(id);
      if (socket) {
        safeSend(socket, toBytes(data));
      }
      return { handled: true };
    }
    if (frame.type === TYPE_VIEWER_DECISION || frame.type === TYPE_VIEWER_LEAVE) {
      const message = parseJSON(frame.payload);
      const id = message && typeof message.viewer_id === 'string' ? message.viewer_id : null;
      const socket = id === null ? undefined : this.socketFor(id);
      if (!socket) {
        return { handled: true };
      }
      safeSend(socket, toBytes(data));
      const ends = frame.type === TYPE_VIEWER_LEAVE || message.approved !== true;
      if (ends) {
        // The agent already forgot this viewer: close without a leave back.
        const entry = this.store.get(socket);
        this.store.set(socket, { ...entry, closed: true });
        safeClose(
          socket,
          1000,
          frame.type === TYPE_VIEWER_LEAVE ? 'Disconnected by host' : 'Denied'
        );
      }
      return { handled: true };
    }
    // VIEWER_JOIN never comes from the Mac.
    return { handled: true };
  }

  /**
   * The Mac's connection went away: every viewing ends (the agent forgets
   * its viewers too). Unless `keepShare` (another Mac connection already
   * replaced this one), the share ends as well. Returns the code to drop
   * from the registry, or null.
   */
  macDisconnected({ keepShare = false } = {}) {
    for (const [socket, entry] of this.live()) {
      if (entry.viewerId !== null) {
        safeSend(socket, jsonFrame(TYPE_VIEWER_LEAVE, { viewer_id: entry.viewerId }));
      }
      this.store.set(socket, { ...entry, closed: true });
      safeClose(socket, 1001, 'Host disconnected');
    }
    if (keepShare) {
      return null;
    }
    const code = this.shareCode;
    this.shareCode = null;
    return code;
  }

  dropSocket(socket, code, reason) {
    this.onViewerClose(socket);
    safeClose(socket, code, reason);
  }
}

/** Name of the Durable Object that records which device shares `code`. */
export function shareRegistryName(code) {
  return `share:${code}`;
}
