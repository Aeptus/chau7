import assert from 'node:assert/strict';
import test from 'node:test';
import { relayRuntimeInfo, RELAY_RUNTIME_SCHEMA_VERSION } from '../src/runtime.js';

test('relay runtime info exposes independent deployment identity', () => {
  assert.deepEqual(
    relayRuntimeInfo({ id: 'deploy-123', tag: 'production', timestamp: '2026-08-14T12:00:00Z' }),
    {
      component: 'chau7-relay',
      status: 'ok',
      runtime_schema_version: RELAY_RUNTIME_SCHEMA_VERSION,
      deployment_id: 'deploy-123',
      deployment_tag: 'production',
      deployment_timestamp: '2026-08-14T12:00:00Z'
    }
  );
});

test('relay runtime info remains queryable without version metadata', () => {
  assert.equal(relayRuntimeInfo(undefined).deployment_id, 'unknown');
});
