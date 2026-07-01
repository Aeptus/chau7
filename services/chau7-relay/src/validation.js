/**
 * Request-body limits, safe JSON parsing, and payload sanitizers.
 *
 * Every external write path runs through here so that:
 *   - bodies are size-capped before they can blow the 128 KB Durable Object
 *     value limit or exhaust memory,
 *   - malformed JSON yields a clean 400 instead of an unhandled 500,
 *   - persisted/forwarded fields are bounded in count and length, so a client
 *     cannot grow relay state without limit or smuggle oversized strings into
 *     an APNs payload.
 *
 * Pure functions (except `readJsonBody`, which only needs `request.text()` and
 * `request.headers.get()`), so everything here is unit-testable.
 */

/** Max accepted JSON request body. Well under the 128 KB DO value ceiling. */
export const MAX_BODY_BYTES = 64 * 1024;

/** Caps for the pending-state snapshot. */
export const MAX_APPROVALS = 50;
export const MAX_INTERACTIVE_PROMPTS = 50;
export const MAX_PROMPT_OPTIONS = 12;

/** Per-field string caps (characters). Oversized strings are truncated. */
const FIELD_CAPS = {
  short: 256,
  medium: 1024,
  long: 4096
};

/** Push-notification field caps. APNs rejects payloads over ~4 KB total. */
export const PUSH_CAPS = {
  title: 256,
  subtitle: 256,
  body: 1024,
  kind: 64,
  id: 128
};

function clampString(value, max) {
  if (typeof value !== 'string') {
    return undefined;
  }
  return value.length > max ? value.slice(0, max) : value;
}

function clampRequiredString(value, max) {
  const clamped = clampString(value, max);
  return clamped ?? '';
}

/**
 * Read a JSON body with a hard byte cap and graceful error handling.
 *
 * @returns {Promise<{ok: true, value: unknown} | {ok: false, status: number, message: string}>}
 */
export async function readJsonBody(request, maxBytes = MAX_BODY_BYTES) {
  const declared = request.headers.get('Content-Length');
  if (declared) {
    const length = Number(declared);
    if (Number.isFinite(length) && length > maxBytes) {
      return { ok: false, status: 413, message: 'Payload too large' };
    }
  }
  let text;
  try {
    text = await request.text();
  } catch {
    return { ok: false, status: 400, message: 'Unreadable body' };
  }
  // `Content-Length` can be absent (chunked) or lie; enforce on the real bytes.
  if (text.length > maxBytes) {
    return { ok: false, status: 413, message: 'Payload too large' };
  }
  if (text.length === 0) {
    return { ok: false, status: 400, message: 'Empty body' };
  }
  try {
    return { ok: true, value: JSON.parse(text) };
  } catch {
    return { ok: false, status: 400, message: 'Invalid JSON' };
  }
}

function sanitizeApproval(input) {
  if (!input || typeof input !== 'object') {
    return null;
  }
  const requestId = clampString(input.request_id, FIELD_CAPS.short);
  if (!requestId) {
    return null;
  }
  const out = {
    request_id: requestId,
    command: clampRequiredString(input.command, FIELD_CAPS.long),
    flagged_command: clampRequiredString(input.flagged_command, FIELD_CAPS.long),
    timestamp: clampRequiredString(input.timestamp, FIELD_CAPS.short)
  };
  for (const field of [
    'tab_title',
    'tool_name',
    'project_name',
    'branch_name',
    'current_directory',
    'recent_command',
    'context_note',
    'session_id'
  ]) {
    const value = clampString(input[field], FIELD_CAPS.medium);
    if (value !== undefined) {
      out[field] = value;
    }
  }
  return out;
}

function sanitizePromptOption(input) {
  if (!input || typeof input !== 'object') {
    return null;
  }
  const id = clampString(input.id, FIELD_CAPS.short);
  if (!id) {
    return null;
  }
  const option = {
    id,
    label: clampRequiredString(input.label, FIELD_CAPS.short),
    response: clampRequiredString(input.response, FIELD_CAPS.medium)
  };
  if (typeof input.is_destructive === 'boolean') {
    option.is_destructive = input.is_destructive;
  }
  return option;
}

function sanitizeInteractivePrompt(input) {
  if (!input || typeof input !== 'object') {
    return null;
  }
  const id = clampString(input.id, FIELD_CAPS.short);
  if (!id) {
    return null;
  }
  const out = {
    id,
    tab_id: Number.isFinite(input.tab_id) ? input.tab_id : 0,
    tab_title: clampRequiredString(input.tab_title, FIELD_CAPS.short),
    tool_name: clampRequiredString(input.tool_name, FIELD_CAPS.short),
    prompt: clampRequiredString(input.prompt, FIELD_CAPS.long),
    detected_at: clampRequiredString(input.detected_at, FIELD_CAPS.short),
    options: Array.isArray(input.options)
      ? input.options
          .slice(0, MAX_PROMPT_OPTIONS)
          .map(sanitizePromptOption)
          .filter((option) => option !== null)
      : []
  };
  for (const field of ['project_name', 'branch_name', 'current_directory', 'detail']) {
    const value = clampString(input[field], FIELD_CAPS.medium);
    if (value !== undefined) {
      out[field] = value;
    }
  }
  return out;
}

/**
 * Normalize an untrusted pending-state payload into the bounded shape the relay
 * persists. Never throws; drops anything malformed or over the caps.
 */
export function sanitizePendingState(payload) {
  const source = payload && typeof payload === 'object' ? payload : {};
  const approvals = Array.isArray(source.approvals)
    ? source.approvals
        .slice(0, MAX_APPROVALS)
        .map(sanitizeApproval)
        .filter((a) => a !== null)
    : [];
  const interactive_prompts = Array.isArray(source.interactive_prompts)
    ? source.interactive_prompts
        .slice(0, MAX_INTERACTIVE_PROMPTS)
        .map(sanitizeInteractivePrompt)
        .filter((p) => p !== null)
    : [];
  return { approvals, interactive_prompts };
}

/**
 * @typedef {object} RegisterValue
 * @property {string} paired_device_id
 * @property {string} [device_name]
 * @property {string} [push_token]
 * @property {string} [push_topic]
 * @property {'development'|'production'} [push_environment]
 * @property {boolean} notifications_authorized
 */

/**
 * Validate and bound a push-register payload.
 * @returns {{ok: true, value: RegisterValue} | {ok: false, message: string}}
 */
export function validatePushRegister(payload) {
  if (!payload || typeof payload !== 'object') {
    return { ok: false, message: 'Invalid payload' };
  }
  const pairedDeviceId = clampString(payload.paired_device_id, PUSH_CAPS.id);
  if (!pairedDeviceId) {
    return { ok: false, message: 'Missing paired_device_id' };
  }
  const environment =
    payload.push_environment === 'production' || payload.push_environment === 'development'
      ? payload.push_environment
      : undefined;
  return {
    ok: true,
    value: {
      paired_device_id: pairedDeviceId,
      device_name: clampString(payload.device_name, PUSH_CAPS.id),
      push_token: clampString(payload.push_token, FIELD_CAPS.medium),
      push_topic: clampString(payload.push_topic, PUSH_CAPS.id),
      push_environment: environment,
      notifications_authorized: payload.notifications_authorized === true
    }
  };
}

/**
 * @typedef {object} NotifyValue
 * @property {string} kind
 * @property {string} title
 * @property {string} body
 * @property {boolean} open_approvals
 * @property {string} [request_id]
 * @property {string} [prompt_id]
 */

/**
 * Validate and bound a push-notify payload before it is sent to APNs.
 * @returns {{ok: true, value: NotifyValue} | {ok: false, message: string}}
 */
export function validatePushNotify(payload) {
  if (!payload || typeof payload !== 'object') {
    return { ok: false, message: 'Invalid payload' };
  }
  const title = clampString(payload.title, PUSH_CAPS.title);
  const body = clampString(payload.body, PUSH_CAPS.body);
  if (!title || !body) {
    return { ok: false, message: 'Missing title or body' };
  }
  const value = {
    kind: clampRequiredString(payload.kind, PUSH_CAPS.kind) || 'generic',
    title,
    body,
    open_approvals: payload.open_approvals !== false
  };
  const subtitle = clampString(payload.subtitle, PUSH_CAPS.subtitle);
  if (subtitle) {
    value.subtitle = subtitle;
  }
  const requestId = clampString(payload.request_id, PUSH_CAPS.id);
  if (requestId) {
    value.request_id = requestId;
  }
  const promptId = clampString(payload.prompt_id, PUSH_CAPS.id);
  if (promptId) {
    value.prompt_id = promptId;
  }
  const threadId = clampString(payload.thread_id, PUSH_CAPS.id);
  if (threadId) {
    value.thread_id = threadId;
  }
  return { ok: true, value };
}
