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
