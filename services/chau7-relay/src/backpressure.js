export const BACKPRESSURE_SOFT_BYTES = 4 * 1024 * 1024;
export const BACKPRESSURE_HARD_BYTES = 16 * 1024 * 1024;
export const TERMINAL_GRID_SNAPSHOT_FRAME_TYPE = 0x23;

/** @param {ArrayBuffer | string} message */
export function isReplaceableGridFrame(message) {
  if (typeof message === 'string' || message.byteLength < 2) {
    return false;
  }
  return new Uint8Array(message, 0, 2)[1] === TERMINAL_GRID_SNAPSHOT_FRAME_TYPE;
}

/**
 * @param {number} bufferedBytes
 * @param {ArrayBuffer | string} message
 * @returns {'send' | 'drop-grid' | 'close'}
 */
export function relayBackpressureAction(bufferedBytes, message) {
  if (bufferedBytes > BACKPRESSURE_HARD_BYTES) {
    return 'close';
  }
  if (bufferedBytes > BACKPRESSURE_SOFT_BYTES && isReplaceableGridFrame(message)) {
    return 'drop-grid';
  }
  return 'send';
}

/** Phone-to-relay frame reporting how many bytes the phone has taken in. */
export const RELAY_ACK_FRAME_TYPE = 0x65;
const FRAME_HEADER_BYTES = 20;

/**
 * The running byte total from a RELAY_ACK frame (8 bytes, little endian, after
 * the 20-byte header), or null when the message is not one.
 * @param {ArrayBuffer | string} message
 */
export function relayAckTotal(message) {
  if (typeof message === 'string' || message.byteLength !== FRAME_HEADER_BYTES + 8) {
    return null;
  }
  const view = new DataView(message);
  if (view.getUint8(1) !== RELAY_ACK_FRAME_TYPE) return null;
  const total = view.getBigUint64(FRAME_HEADER_BYTES, true);
  return total > BigInt(Number.MAX_SAFE_INTEGER) ? null : Number(total);
}

/**
 * Bytes sent to one phone that it has not yet reported taking in. The Workers
 * runtime does not expose a socket's send queue, so this is the only measure
 * of a receiver falling behind. A phone that never acknowledges (an older app)
 * is never measured, and so never shed.
 *
 * The counters live in memory. After the Durable Object hibernates they start
 * again from zero, and the next acknowledgement re-bases them.
 */
export class ReceiveWindow {
  sent = 0;
  /** The phone's running total that corresponds to `sent === 0`. */
  base = null;
  acked = 0;

  /** @param {number} bytes */
  recordSend(bytes) {
    this.sent += bytes;
  }

  /** @param {number} total the phone's running count of bytes taken in */
  recordAck(total) {
    const acked = this.base === null ? null : total - this.base;
    if (acked === null || acked < this.acked || acked > this.sent) {
      // First report on this instance, or one that cannot be matched to what
      // was sent since it woke: treat everything sent so far as taken in.
      this.base = total - this.sent;
      this.acked = this.sent;
      return;
    }
    this.acked = acked;
  }

  /** Unacknowledged bytes; 0 until the phone has acknowledged at least once. */
  get outstanding() {
    return this.base === null ? 0 : this.sent - this.acked;
  }
}
