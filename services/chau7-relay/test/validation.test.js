import assert from 'node:assert/strict';
import test from 'node:test';
import {
  readJsonBody,
  sanitizePendingState,
  validatePushNotify,
  validatePushRegister,
  MAX_APPROVALS,
  MAX_INTERACTIVE_PROMPTS,
  MAX_PROMPT_OPTIONS,
  MAX_BODY_BYTES,
  PUSH_CAPS
} from '../src/validation.js';

function fakeRequest(text, headers = {}) {
  return {
    headers: { get: (name) => headers[name] ?? headers[name.toLowerCase()] ?? null },
    text: async () => text
  };
}

test('readJsonBody parses valid JSON', async () => {
  const result = await readJsonBody(fakeRequest('{"a":1}'));
  assert.deepEqual(result, { ok: true, value: { a: 1 } });
});

test('readJsonBody rejects invalid JSON with 400', async () => {
  const result = await readJsonBody(fakeRequest('{not json'));
  assert.equal(result.ok, false);
  assert.equal(result.status, 400);
});

test('readJsonBody rejects empty body with 400', async () => {
  const result = await readJsonBody(fakeRequest(''));
  assert.equal(result.ok, false);
  assert.equal(result.status, 400);
});

test('readJsonBody rejects oversized body via Content-Length with 413', async () => {
  const result = await readJsonBody(
    fakeRequest('{}', { 'Content-Length': String(MAX_BODY_BYTES + 1) })
  );
  assert.equal(result.ok, false);
  assert.equal(result.status, 413);
});

test('readJsonBody rejects oversized body even when Content-Length lies', async () => {
  const huge = '"' + 'x'.repeat(MAX_BODY_BYTES + 10) + '"';
  const result = await readJsonBody(fakeRequest(huge, { 'Content-Length': '5' }));
  assert.equal(result.ok, false);
  assert.equal(result.status, 413);
});

test('sanitizePendingState bounds array counts', () => {
  const approvals = Array.from({ length: MAX_APPROVALS + 20 }, (_, i) => ({
    request_id: `r${i}`,
    command: 'ls'
  }));
  const prompts = Array.from({ length: MAX_INTERACTIVE_PROMPTS + 20 }, (_, i) => ({ id: `p${i}` }));
  const result = sanitizePendingState({ approvals, interactive_prompts: prompts });
  assert.equal(result.approvals.length, MAX_APPROVALS);
  assert.equal(result.interactive_prompts.length, MAX_INTERACTIVE_PROMPTS);
});

test('sanitizePendingState drops entries without ids', () => {
  const result = sanitizePendingState({
    approvals: [{ command: 'no id' }, { request_id: 'ok', command: 'ls' }],
    interactive_prompts: [{ tab_title: 'no id' }, { id: 'ok' }]
  });
  assert.equal(result.approvals.length, 1);
  assert.equal(result.approvals[0].request_id, 'ok');
  assert.equal(result.interactive_prompts.length, 1);
});

test('sanitizePendingState truncates oversized strings', () => {
  const result = sanitizePendingState({
    approvals: [{ request_id: 'r', command: 'x'.repeat(99999) }],
    interactive_prompts: []
  });
  assert.ok(result.approvals[0].command.length <= 4096);
});

test('sanitizePendingState bounds prompt options', () => {
  const result = sanitizePendingState({
    approvals: [],
    interactive_prompts: [
      {
        id: 'p',
        options: Array.from({ length: MAX_PROMPT_OPTIONS + 5 }, (_, i) => ({
          id: `o${i}`,
          label: 'L',
          response: 'R'
        }))
      }
    ]
  });
  assert.equal(result.interactive_prompts[0].options.length, MAX_PROMPT_OPTIONS);
});

test('sanitizePendingState tolerates garbage input', () => {
  assert.deepEqual(sanitizePendingState(null), { approvals: [], interactive_prompts: [] });
  assert.deepEqual(sanitizePendingState('nope'), { approvals: [], interactive_prompts: [] });
  assert.deepEqual(sanitizePendingState({ approvals: 'x', interactive_prompts: 5 }), {
    approvals: [],
    interactive_prompts: []
  });
});

test('validatePushNotify requires title and body', () => {
  assert.equal(validatePushNotify({ title: 'hi' }).ok, false);
  assert.equal(validatePushNotify({ body: 'hi' }).ok, false);
  assert.equal(validatePushNotify({}).ok, false);
});

test('validatePushNotify clamps oversized fields', () => {
  const result = validatePushNotify({
    title: 'T'.repeat(9999),
    body: 'B'.repeat(9999),
    kind: 'K'.repeat(9999)
  });
  assert.equal(result.ok, true);
  assert.ok(result.value.title.length <= PUSH_CAPS.title);
  assert.ok(result.value.body.length <= PUSH_CAPS.body);
  assert.ok(result.value.kind.length <= PUSH_CAPS.kind);
});

test('validatePushNotify defaults open_approvals to true', () => {
  assert.equal(validatePushNotify({ title: 't', body: 'b' }).value.open_approvals, true);
  assert.equal(
    validatePushNotify({ title: 't', body: 'b', open_approvals: false }).value.open_approvals,
    false
  );
});

test('validatePushRegister requires paired_device_id', () => {
  assert.equal(validatePushRegister({}).ok, false);
  assert.equal(validatePushRegister({ paired_device_id: 'd' }).ok, true);
});

test('validatePushRegister normalizes environment and auth flag', () => {
  const ok = validatePushRegister({
    paired_device_id: 'd',
    push_environment: 'production',
    notifications_authorized: true
  });
  assert.equal(ok.value.push_environment, 'production');
  assert.equal(ok.value.notifications_authorized, true);

  const bad = validatePushRegister({
    paired_device_id: 'd',
    push_environment: 'staging',
    notifications_authorized: 'yes'
  });
  assert.equal(bad.value.push_environment, undefined);
  assert.equal(bad.value.notifications_authorized, false);
});
