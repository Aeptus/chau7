import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { sanitizePendingState } from '../src/validation.js';

const fixture = JSON.parse(
  readFileSync(
    new URL('../../chau7-remote/docs/fixtures/pending_state.json', import.meta.url),
    'utf8'
  )
);
test('pending sanitizer preserves the shared Swift and Go fixture fields', () => {
  const actual = sanitizePendingState(fixture);
  assert.equal(actual.session_epoch, fixture.session_epoch);
  assert.equal(actual.state_version, fixture.state_version);
  for (const field of Object.keys(fixture.approvals[0]))
    assert.deepEqual(actual.approvals[0][field], fixture.approvals[0][field], field);
  for (const field of Object.keys(fixture.interactive_prompts[0]))
    assert.deepEqual(
      actual.interactive_prompts[0][field],
      fixture.interactive_prompts[0][field],
      field
    );
});

test('pending sanitizer drops malformed prompt targeting instead of making it unscoped', () => {
  for (const change of [
    { pane_id: 'not-a-uuid' },
    { multi_select: 'true' },
    { tab_id: -1 },
    { tab_id: 1.5 },
    { tab_id: 0x100000000 },
    { detected_at: '2026-01-01' },
    { detected_at: Infinity }
  ]) {
    const result = sanitizePendingState({
      ...fixture,
      interactive_prompts: [{ ...fixture.interactive_prompts[0], ...change }]
    });
    assert.deepEqual(result.interactive_prompts, []);
  }
});

test('pending sanitizer keeps bounded known metadata and drops arbitrary fields', () => {
  const result = sanitizePendingState({
    ...fixture,
    secret: 'never persist',
    approvals: [
      { ...fixture.approvals[0], extra: { huge: 'unknown' }, push_body: 'x'.repeat(5000) }
    ]
  });
  assert.equal(result.secret, undefined);
  assert.equal(result.approvals[0].extra, undefined);
  assert.equal(result.approvals[0].push_body.length, 1024);
  assert.equal(
    result.interactive_prompts[0].detected_at,
    fixture.interactive_prompts[0].detected_at
  );
});
