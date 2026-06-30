/**
 * In-memory token-bucket rate limiter, scoped per Durable Object instance
 * (i.e. per device). Because a request flood keeps the DO resident in memory,
 * the in-memory buckets remain effective against abuse; they reset only on
 * eviction, which by definition happens only when the device is idle and there
 * is nothing to throttle. This avoids per-request storage writes (efficiency)
 * while still bounding APNs spam, connect churn, and pending-state writes.
 *
 * `now` is injectable for deterministic tests.
 */

export class TokenBucket {
  /**
   * @param {number} capacity  Maximum burst.
   * @param {number} refillPerSecond  Sustained rate.
   */
  constructor(capacity, refillPerSecond) {
    this.capacity = capacity;
    this.refillPerSecond = refillPerSecond;
    this.tokens = capacity;
    this.last = null;
  }

  /** Attempt to consume one token. Returns true if allowed. */
  tryRemove(now) {
    if (this.last === null) {
      this.last = now;
    }
    const elapsed = Math.max(0, (now - this.last) / 1000);
    this.tokens = Math.min(this.capacity, this.tokens + elapsed * this.refillPerSecond);
    this.last = now;
    if (this.tokens >= 1) {
      this.tokens -= 1;
      return true;
    }
    return false;
  }
}

/**
 * Per-route limits. Generous for a single paired device's normal traffic,
 * tight enough to blunt automated abuse.
 */
export const RATE_LIMITS = Object.freeze({
  connect: { capacity: 15, refillPerSecond: 0.5 }, // ~30/min sustained, burst 15
  push: { capacity: 20, refillPerSecond: 1 }, // ~60/min sustained, burst 20
  pending: { capacity: 40, refillPerSecond: 2 } // ~120/min sustained, burst 40
});

/**
 * Registry of buckets keyed by route. Construct once per DO instance.
 */
export class RateLimiter {
  constructor(limits = RATE_LIMITS) {
    this.buckets = new Map();
    this.limits = limits;
  }

  /** @returns {boolean} true if the request is allowed. */
  allow(route, now) {
    const config = this.limits[route];
    if (!config) {
      return true;
    }
    let bucket = this.buckets.get(route);
    if (!bucket) {
      bucket = new TokenBucket(config.capacity, config.refillPerSecond);
      this.buckets.set(route, bucket);
    }
    return bucket.tryRemove(now);
  }
}
