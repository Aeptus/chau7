import assert from 'node:assert/strict';
import test from 'node:test';
import { TokenBucket, RateLimiter } from '../src/ratelimit.js';

test('allows up to capacity in a burst, then throttles', () => {
  const bucket = new TokenBucket(5, 1);
  let t = 1000;
  for (let i = 0; i < 5; i++) {
    assert.equal(bucket.tryRemove(t), true, `burst token ${i}`);
  }
  assert.equal(bucket.tryRemove(t), false, 'sixth is throttled');
});

test('refills over time', () => {
  const bucket = new TokenBucket(2, 1); // 1 token/sec
  let t = 0;
  assert.equal(bucket.tryRemove(t), true);
  assert.equal(bucket.tryRemove(t), true);
  assert.equal(bucket.tryRemove(t), false);
  t += 1000; // one second -> one token
  assert.equal(bucket.tryRemove(t), true);
  assert.equal(bucket.tryRemove(t), false);
});

test('does not exceed capacity when refilling', () => {
  const bucket = new TokenBucket(3, 100);
  let t = 0;
  assert.equal(bucket.tryRemove(t), true);
  t += 100000; // huge gap
  // capacity is 3, so only 3 immediate allows even after a long idle
  assert.equal(bucket.tryRemove(t), true);
  assert.equal(bucket.tryRemove(t), true);
  assert.equal(bucket.tryRemove(t), true);
  assert.equal(bucket.tryRemove(t), false);
});

test('RateLimiter isolates buckets per route', () => {
  const limiter = new RateLimiter({
    connect: { capacity: 1, refillPerSecond: 0 },
    pending: { capacity: 1, refillPerSecond: 0 }
  });
  assert.equal(limiter.allow('connect', 0), true);
  assert.equal(limiter.allow('connect', 0), false);
  // different route still has its own budget
  assert.equal(limiter.allow('pending', 0), true);
});

test('RateLimiter allows unknown routes (no configured limit)', () => {
  const limiter = new RateLimiter({});
  assert.equal(limiter.allow('whatever', 0), true);
});
