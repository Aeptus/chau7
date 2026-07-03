/**
 * APNs payload construction and response interpretation.
 *
 * Pure functions — no network, no Worker globals — so the (security-relevant)
 * "should we delete this push registration?" decision is unit-tested.
 */

/**
 * APNs `reason` values that mean the device token is permanently invalid and
 * the registration should be removed. A 410 (Unregistered) always means remove,
 * regardless of body. Other 4xx responses (e.g. PayloadTooLarge, BadMessageId,
 * TooManyRequests, BadCertificate, InternalServerError) are transient or
 * caller errors and must NOT evict a healthy device token.
 */
export const REMOVABLE_REASONS = Object.freeze(
  new Set(['Unregistered', 'BadDeviceToken', 'DeviceTokenNotForTopic', 'TopicDisallowed'])
);

/**
 * Decide whether an APNs response means the registration is dead.
 * @param {number} status  HTTP status from APNs.
 * @param {string|undefined} reason  Parsed `reason` from the APNs JSON body.
 */
export function shouldRemoveRegistration(status, reason) {
  if (status === 410) {
    return true;
  }
  if (status === 400 && typeof reason === 'string' && REMOVABLE_REASONS.has(reason)) {
    return true;
  }
  return false;
}

/** Extract APNs `reason` from a response body string. Returns undefined if absent. */
export function parseApnsReason(bodyText) {
  if (typeof bodyText !== 'string' || bodyText.length === 0) {
    return undefined;
  }
  try {
    const parsed = JSON.parse(bodyText);
    return typeof parsed?.reason === 'string' ? parsed.reason : undefined;
  } catch {
    return undefined;
  }
}

/**
 * Build the APNs JSON payload for an alert notification.
 *
 * This is an alert (user-visible) push, so it intentionally does NOT set
 * `content-available: 1` — that flag marks a silent/background push, which APNs
 * throttles and expects at priority 5, and combining it with a priority-10
 * alert is contradictory and can be dropped.
 */
export function buildApnsPayload(notify) {
  const alert = { title: notify.title, body: notify.body };
  if (notify.subtitle) {
    alert.subtitle = notify.subtitle;
  }
  const aps = {
    alert,
    sound: 'default',
    'interruption-level': 'time-sensitive',
    'relevance-score': 1
  };
  // Group a tab's alerts into one lock-screen stack instead of separate banners.
  if (notify.thread_id) {
    aps['thread-id'] = notify.thread_id;
  }
  // Category IDs registered by the iOS app (RemoteNotificationID): gives
  // pushed approvals the same lock-screen Allow/Deny actions local
  // notifications already have. The response plumbing (userInfo request_id →
  // approvalNotificationResponse → queued ApprovalCoordinator send) predates
  // this and works for remote payloads unchanged.
  const category = APNS_CATEGORY_BY_KIND[notify.kind];
  if (category) {
    aps.category = category;
  }
  return {
    aps,
    kind: notify.kind,
    request_id: notify.request_id,
    prompt_id: notify.prompt_id,
    open_approvals: notify.open_approvals ?? true
  };
}

/** iOS UNNotificationCategory identifiers, keyed by push kind. */
export const APNS_CATEGORY_BY_KIND = Object.freeze({
  approval: 'MCP_APPROVAL',
  interactive_prompt: 'INTERACTIVE_PROMPT'
});

/**
 * Stable collapse identifier for a push: newer alerts for the same approval /
 * prompt / identity replace older ones instead of stacking, and APNs
 * store-and-forward keeps only the latest for an offline device. APNs caps
 * the header at 64 bytes.
 */
export function apnsCollapseID(notify) {
  const raw = notify.request_id || notify.prompt_id || notify.identity_key || '';
  if (!raw) {
    return undefined;
  }
  return raw.slice(0, 64);
}
