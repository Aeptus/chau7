import assert from "node:assert/strict";
import test from "node:test";
import issueWorker, { IssueRateLimitDO } from "../src/worker.js";
import { mintToken } from "../../chau7-relay/src/token.js";

const FIXTURE = "test-only-hmac-material";
const DEVICE_ID = "11111111-2222-3333-4444-555555555555";
const NOW = 1_700_000_000_000;
const RATE_WINDOW_MS = 60 * 60 * 1000;

class MemoryStorage {
  constructor() {
    this.values = new Map();
    this.alarmAt = null;
    this.transactionTail = Promise.resolve();
  }

  async get(key) {
    return this.values.get(key);
  }

  async put(key, value) {
    this.values.set(key, value);
  }

  async delete(key) {
    return this.values.delete(key);
  }

  async list({ prefix = "" } = {}) {
    return new Map(
      [...this.values.entries()].filter(([key]) => key.startsWith(prefix)),
    );
  }

  async getAlarm() {
    return this.alarmAt;
  }

  async setAlarm(timestamp) {
    this.alarmAt = timestamp;
  }

  async transaction(callback) {
    const previous = this.transactionTail;
    let release;
    this.transactionTail = new Promise((resolve) => {
      release = resolve;
    });
    await previous;
    try {
      return await callback(this);
    } finally {
      release();
    }
  }
}

class MemoryNamespace {
  constructor() {
    this.objects = new Map();
    this.names = [];
  }

  idFromName(name) {
    this.names.push(name);
    return name;
  }

  get(id) {
    let object = this.objects.get(id);
    if (!object) {
      const durableObject = new IssueRateLimitDO({
        storage: new MemoryStorage(),
      });
      object = {
        fetch: (request) => durableObject.fetch(request),
        durableObject,
      };
      this.objects.set(id, object);
    }
    return object;
  }
}

function makeEnv() {
  return {
    RELAY_SECRET: FIXTURE,
    GITHUB_ISSUE_PAT: "test-github-pat",
    GITHUB_ISSUE_REPO: "owner/private-issues",
    GITHUB_ISSUE_ALLOWED_LABELS: "bug,question",
    ISSUE_RATE_LIMIT: new MemoryNamespace(),
  };
}

async function issueRequest(payload, options = {}) {
  const deviceId = options.deviceId ?? DEVICE_ID;
  const role = options.role ?? "mac";
  const token =
    options.token ??
    (await mintToken(
      {
        deviceId: options.tokenDeviceId ?? deviceId,
        role: options.tokenRole ?? role,
        scope: options.scope ?? "issues",
        secret: options.secret ?? FIXTURE,
      },
      Math.floor(Date.now() / 1000),
    ));
  const headers = new Headers({
    Authorization: `Bearer ${token}`,
    "X-Chau7-Device-ID": deviceId,
    "X-Chau7-Role": role,
    "CF-Connecting-IP": options.ip ?? "198.51.100.10",
    "Content-Type": "application/json",
  });
  if (options.origin !== undefined) {
    headers.set("Origin", options.origin);
  }
  const body =
    options.rawBody ??
    JSON.stringify(
      Object.hasOwn(options, "payload")
        ? options.payload
        : (payload ?? { title: "A report", body: "Details" }),
    );
  return {
    token,
    request: new Request(options.path ?? "https://issues.test/", {
      method: options.method ?? "POST",
      headers,
      body: options.method === "OPTIONS" ? undefined : body,
    }),
  };
}

function freezeTime(t, initial = NOW) {
  let now = initial;
  t.mock.method(Date, "now", () => now);
  return (next) => {
    now = next;
  };
}

function mockGitHub(t, response = { status: 201, body: { number: 42 } }) {
  const calls = [];
  t.mock.method(globalThis, "fetch", async (url, init) => {
    calls.push({ url: String(url), init });
    return new Response(JSON.stringify(response.body), {
      status: response.status,
    });
  });
  return calls;
}

test("GET serves the landing page without CORS headers", async () => {
  const response = await issueWorker.fetch(
    new Request("https://issues.test/"),
    makeEnv(),
  );
  assert.equal(response.status, 200);
  assert.match(await response.text(), /Chau7 Issue Intake/);
  assert.equal(response.headers.has("Access-Control-Allow-Origin"), false);
});

test("issue creation requires an authenticated bearer token", async (t) => {
  freezeTime(t);
  const calls = mockGitHub(t);
  const response = await issueWorker.fetch(
    new Request("https://issues.test/", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ title: "A report", body: "Details" }),
    }),
    makeEnv(),
  );
  assert.equal(response.status, 401);
  assert.equal(calls.length, 0);
  assert.equal(response.headers.has("Access-Control-Allow-Origin"), false);
});

test("rejects cross-origin posts and browser preflights", async (t) => {
  freezeTime(t);
  const calls = mockGitHub(t);
  const env = makeEnv();
  const post = await issueRequest(undefined, {
    origin: "https://attacker.test",
  });
  const postResponse = await issueWorker.fetch(post.request, env);
  assert.equal(postResponse.status, 403);

  const preflight = new Request("https://issues.test/issue", {
    method: "OPTIONS",
    headers: {
      Origin: "https://attacker.test",
      "Access-Control-Request-Method": "POST",
      "Access-Control-Request-Headers": "authorization,content-type",
    },
  });
  const preflightResponse = await issueWorker.fetch(preflight, env);
  assert.equal(preflightResponse.status, 405);
  assert.equal(
    preflightResponse.headers.has("Access-Control-Allow-Origin"),
    false,
  );
  assert.equal(calls.length, 0);
});

test("a valid v2 issues token creates an issue and forwards only validated fields", async (t) => {
  freezeTime(t);
  const calls = mockGitHub(t);
  const env = makeEnv();
  const { request } = await issueRequest({
    title: "  A report  ",
    body: "  Details  ",
    labels: ["bug", "question", "bug"],
    unexpected: "ignored",
  });

  const response = await issueWorker.fetch(request, env);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true, issue_number: 42 });
  assert.equal(calls.length, 1);
  assert.equal(
    calls[0].url,
    "https://api.github.com/repos/owner/private-issues/issues",
  );
  assert.deepEqual(JSON.parse(calls[0].init.body), {
    title: "A report",
    body: "Details",
    labels: ["bug", "question"],
  });
  assert.equal(calls[0].init.headers.Authorization, "Bearer test-github-pat");
  assert.ok(env.ISSUE_RATE_LIMIT.names.includes(`rate:198.51.100.10`));
  assert.ok(env.ISSUE_RATE_LIMIT.names.includes(`nonce:${DEVICE_ID}`));
});

test("the v2 nonce is single use", async (t) => {
  freezeTime(t);
  const calls = mockGitHub(t);
  const env = makeEnv();
  const signed = await issueRequest();
  const first = await issueWorker.fetch(signed.request, env);
  assert.equal(first.status, 200);

  const replay = await issueRequest(undefined, { token: signed.token });
  const second = await issueWorker.fetch(replay.request, env);
  assert.equal(second.status, 403);
  assert.equal(calls.length, 1);
});

test("rejects tokens for other scopes, identities, roles, and secrets", async (t) => {
  freezeTime(t);
  const calls = mockGitHub(t);
  const cases = [
    { scope: "connect" },
    { tokenDeviceId: "other-device" },
    { tokenRole: "ios" },
    { secret: "wrong-secret" },
  ];
  for (const options of cases) {
    const { request } = await issueRequest(undefined, options);
    const response = await issueWorker.fetch(request, makeEnv());
    assert.equal(response.status, 403);
  }
  assert.equal(calls.length, 0);
});

test("fails closed when the relay secret is missing or a placeholder", async (t) => {
  freezeTime(t);
  const calls = mockGitHub(t);
  for (const secret of [undefined, "CHANGE_ME_IN_PRODUCTION"]) {
    const env = makeEnv();
    env.RELAY_SECRET = secret;
    const { request } = await issueRequest();
    const response = await issueWorker.fetch(request, env);
    assert.equal(response.status, 503);
  }
  assert.equal(calls.length, 0);
});

test("maps rate limiter rejection and failure to 429 and 503", async (t) => {
  freezeTime(t);
  const calls = mockGitHub(t);
  for (const [limiterStatus, expectedStatus] of [
    [429, 429],
    [500, 503],
  ]) {
    const env = makeEnv();
    const namespace = env.ISSUE_RATE_LIMIT;
    env.ISSUE_RATE_LIMIT = {
      idFromName: (name) => namespace.idFromName(name),
      get: (id) => {
        if (String(id).startsWith("nonce:")) {
          return namespace.get(id);
        }
        return {
          fetch: async () =>
            new Response("Unavailable", { status: limiterStatus }),
        };
      },
    };
    const { request } = await issueRequest();
    const response = await issueWorker.fetch(request, env);
    assert.equal(response.status, expectedStatus);
  }

  const env = makeEnv();
  const namespace = env.ISSUE_RATE_LIMIT;
  env.ISSUE_RATE_LIMIT = {
    idFromName: (name) => namespace.idFromName(name),
    get: (id) => {
      if (String(id).startsWith("nonce:")) {
        return namespace.get(id);
      }
      return {
        fetch: async () => {
          throw new Error("DO unavailable");
        },
      };
    },
  };
  const { request } = await issueRequest();
  assert.equal((await issueWorker.fetch(request, env)).status, 503);
  assert.equal(calls.length, 0);
});

test("validates JSON, title, body, labels, and repository before GitHub calls", async (t) => {
  freezeTime(t);
  const calls = mockGitHub(t);
  const invalidBodies = [
    { rawBody: "{" },
    { payload: null },
    { payload: { body: "Details" } },
    { payload: { title: "   ", body: "Details" } },
    { payload: { title: "x".repeat(257), body: "Details" } },
    { payload: { title: "A report", body: "x".repeat(65536) } },
    { payload: { title: "A report", body: "Details", labels: "bug" } },
    {
      payload: {
        title: "A report",
        body: "Details",
        labels: Array(6).fill("bug"),
      },
    },
    { payload: { title: "A report", body: "Details", labels: ["new-label"] } },
    { payload: { title: "A report", body: "Details", labels: ["bug!"] } },
  ];

  for (const invalid of invalidBodies) {
    const { request } = await issueRequest(invalid.payload, invalid);
    const response = await issueWorker.fetch(request, makeEnv());
    assert.equal(response.status, 400);
  }

  const badRepoEnv = makeEnv();
  badRepoEnv.GITHUB_ISSUE_REPO = "owner/repo/path";
  const badRepoRequest = await issueRequest();
  assert.equal(
    (await issueWorker.fetch(badRepoRequest.request, badRepoEnv)).status,
    503,
  );
  assert.equal(calls.length, 0);
});

test("rejects invalid Durable Object limits instead of disabling the cap", async (t) => {
  freezeTime(t);
  const storage = new MemoryStorage();
  const durableObject = new IssueRateLimitDO({ storage });
  const response = await durableObject.fetch(
    new Request("https://internal/ratelimit/reserve", {
      method: "POST",
      body: JSON.stringify({
        ip: "198.51.100.10",
        windowMs: RATE_WINDOW_MS,
        reservationId: "reservation-000001",
      }),
    }),
  );
  assert.equal(response.status, 400);
  assert.equal(await storage.get("ratelimit:198.51.100.10"), undefined);
});

test("rate limiting enforces five successes, exact window expiry, and release IDs", async (t) => {
  const advanceTime = freezeTime(t);
  const storage = new MemoryStorage();
  const durableObject = new IssueRateLimitDO({ storage });
  const requestFor = (action, reservationId) =>
    durableObject.fetch(
      new Request(`https://internal/ratelimit/${action}`, {
        method: "POST",
        body: JSON.stringify({
          ip: "198.51.100.10",
          max: 5,
          windowMs: RATE_WINDOW_MS,
          reservationId,
        }),
      }),
    );

  const ids = Array.from(
    { length: 6 },
    (_, index) => `reservation-${index}-id`,
  );
  for (let index = 0; index < 5; index += 1) {
    assert.equal((await requestFor("reserve", ids[index])).status, 200);
  }
  assert.equal((await requestFor("reserve", ids[5])).status, 429);

  // Release the first failed external request's exact reservation.
  assert.equal((await requestFor("release", ids[0])).status, 200);
  assert.equal((await requestFor("reserve", ids[5])).status, 200);
  assert.equal((await requestFor("reserve", "reservation-7-id")).status, 429);

  advanceTime(NOW + RATE_WINDOW_MS);
  assert.equal((await requestFor("reserve", "reservation-8-id")).status, 200);
});

test("parallel reservations cannot exceed the per-IP limit", async (t) => {
  freezeTime(t);
  const durableObject = new IssueRateLimitDO({ storage: new MemoryStorage() });
  const responses = await Promise.all(
    Array.from({ length: 8 }, (_, index) =>
      durableObject.fetch(
        new Request("https://internal/ratelimit/reserve", {
          method: "POST",
          body: JSON.stringify({
            ip: "198.51.100.20",
            max: 5,
            windowMs: RATE_WINDOW_MS,
            reservationId: `parallel-reservation-${index}`,
          }),
        }),
      ),
    ),
  );
  assert.equal(
    responses.filter((response) => response.status === 200).length,
    5,
  );
  assert.equal(
    responses.filter((response) => response.status === 429).length,
    3,
  );
});

test("failed GitHub calls release only their own reserved slot", async (t) => {
  freezeTime(t);
  t.mock.method(
    globalThis,
    "fetch",
    async () => new Response("Invalid label", { status: 422 }),
  );
  const env = makeEnv();
  const { request } = await issueRequest();
  const response = await issueWorker.fetch(request, env);
  assert.equal(response.status, 502);

  const rateObject = env.ISSUE_RATE_LIMIT.objects.get("rate:198.51.100.10");
  assert.deepEqual(
    await rateObject.durableObject.state.storage.get("ratelimit:198.51.100.10"),
    [],
  );
});

test("keeps the rate slot when GitHub succeeds but returns unreadable JSON", async (t) => {
  freezeTime(t);
  t.mock.method(
    globalThis,
    "fetch",
    async () => new Response("not json", { status: 201 }),
  );
  const env = makeEnv();
  const { request } = await issueRequest();

  const response = await issueWorker.fetch(request, env);

  assert.equal(response.status, 502);
  const rateObject = env.ISSUE_RATE_LIMIT.objects.get("rate:198.51.100.10");
  const reservations = await rateObject.durableObject.state.storage.get(
    "ratelimit:198.51.100.10",
  );
  assert.equal(reservations.length, 1);
});

test("nonce Durable Object rejects replay and expires stored nonces", async (t) => {
  const advanceTime = freezeTime(t);
  const storage = new MemoryStorage();
  const durableObject = new IssueRateLimitDO({ storage });
  const nonce = "AAAAAAAAAAAAAAAAAAAAAA";
  const consume = () =>
    durableObject.fetch(
      new Request("https://internal/nonce/consume", {
        method: "POST",
        body: JSON.stringify({ nonce, expiresAt: NOW + 1000 }),
      }),
    );

  assert.equal((await consume()).status, 200);
  assert.equal((await consume()).status, 409);
  advanceTime(NOW + 1001);
  await durableObject.alarm();
  assert.equal(await storage.get(`issue-token:${nonce}`), undefined);
});
