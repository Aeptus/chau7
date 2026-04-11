import assert from 'node:assert/strict';
import test from 'node:test';
import { isRelaySecretConfigured } from '../src/auth.js';

test('rejects missing relay secrets', () => {
  assert.equal(isRelaySecretConfigured(undefined), false);
  assert.equal(isRelaySecretConfigured(''), false);
  assert.equal(isRelaySecretConfigured('   '), false);
});

test('rejects the shipped placeholder relay secret', () => {
  assert.equal(isRelaySecretConfigured('CHANGE_ME_IN_PRODUCTION'), false);
  assert.equal(isRelaySecretConfigured('  CHANGE_ME_IN_PRODUCTION  '), false);
});

test('accepts a real relay secret', () => {
  assert.equal(isRelaySecretConfigured('my-production-secret'), true);
});
