/**
 * Chau7 Issues — Cloudflare Worker entry point.
 *
 * Routes:
 *   GET  /              Landing page (HTML)
 *   POST / or /issue    Create a GitHub issue using a device/role-scoped v3 bearer token
 */

import {
  resolveAuthMode,
  verifyCredentialToken,
} from "../../chau7-relay/src/auth.js";
import {
  TOKEN_FUTURE_SKEW_SECONDS,
  TOKEN_TTL_SECONDS,
} from "../../chau7-relay/src/token.js";

const LANDING_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Chau7 Issue Intake</title>
<style>
  body { font-family: -apple-system, system-ui, sans-serif; max-width: 480px; margin: 80px auto; padding: 0 20px; color: #e0e0e0; background: #1a1a1a; }
  h1 { font-size: 1.3em; }
  p { line-height: 1.6; color: #999; }
  a { color: #6ba3f7; }
  code { background: #2a2a2a; padding: 2px 6px; border-radius: 4px; font-size: 0.9em; }
</style>
</head>
<body>
<h1>Chau7 Issue Intake</h1>
<p>This worker accepts validated bug reports from Chau7 and forwards them to a private GitHub intake repository.</p>
<p>If you're a browser, there is nothing interactive for you here. If you're the app, submit a JSON payload to <code>/</code> or <code>/issue</code>.</p>
<p><a href="https://chau7.sh">chau7.sh</a></p>
</body>
</html>`;

const ISSUE_RATE_MAX = 5;
const ISSUE_RATE_WINDOW_MS = 60 * 60 * 1000;
const MAX_TITLE_LENGTH = 256;
const MAX_BODY_LENGTH = 65535;
const MAX_LABELS = 5;
const LABEL_PATTERN = /^[A-Za-z0-9][A-Za-z0-9 _-]{0,49}$/;
const DEVICE_ID_PATTERN = /^[A-Za-z0-9._-]{1,128}$/;
const NONCE_PATTERN = /^[A-Za-z0-9_-]{22}$/;
const RESERVATION_ID_PATTERN = /^[A-Za-z0-9_-]{16,64}$/;
const NONCE_KEY_PREFIX = "issue-token:";
const MAX_TOKEN_LIFETIME_MS =
  (TOKEN_TTL_SECONDS + TOKEN_FUTURE_SKEW_SECONDS + 1) * 1000;

export class IssueRateLimitDO {
  constructor(state) {
    this.state = state;
  }

  async fetch(request) {
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean);

    if (parts[0] === "nonce" && parts[1] === "consume") {
      return this.consumeNonce(request);
    }

    const action = parts[1];
    if (
      parts[0] !== "ratelimit" ||
      (action !== "reserve" && action !== "release")
    ) {
      return new Response("Not Found", { status: 404 });
    }
    if (request.method !== "POST") {
      return new Response("Method Not Allowed", { status: 405 });
    }

    const payload = await readJSON(request);
    if (!isValidRateLimitRequest(payload, action)) {
      return new Response("Invalid rate limit request", { status: 400 });
    }

    const { ip, reservationId } = payload;
    const key = `ratelimit:${ip}`;
    const now = Date.now();

    if (action === "release") {
      await this.state.storage.transaction(async (transaction) => {
        const recent = recentReservations(
          await transaction.get(key),
          now,
          ISSUE_RATE_WINDOW_MS,
        );
        const reservationIndex = recent.findIndex(
          (reservation) => reservation.id === reservationId,
        );
        if (reservationIndex >= 0) {
          recent.splice(reservationIndex, 1);
        }
        await transaction.put(key, recent);
      });
      return new Response("OK", { status: 200 });
    }

    const result = await this.state.storage.transaction(async (transaction) => {
      const recent = recentReservations(
        await transaction.get(key),
        now,
        ISSUE_RATE_WINDOW_MS,
      );
      if (recent.length >= ISSUE_RATE_MAX) {
        await transaction.put(key, recent);
        return "limited";
      }
      recent.push({ id: reservationId, timestamp: now });
      await transaction.put(key, recent);
      return "reserved";
    });

    if (result === "limited") {
      return new Response("Rate limited", { status: 429 });
    }
    return new Response("OK", { status: 200 });
  }

  async consumeNonce(request) {
    if (request.method !== "POST") {
      return new Response("Method Not Allowed", { status: 405 });
    }

    const payload = await readJSON(request);
    const now = Date.now();
    if (
      !isPlainObject(payload) ||
      !NONCE_PATTERN.test(payload.nonce ?? "") ||
      !Number.isSafeInteger(payload.expiresAt) ||
      payload.expiresAt <= now ||
      payload.expiresAt > now + MAX_TOKEN_LIFETIME_MS
    ) {
      return new Response("Invalid nonce request", { status: 400 });
    }

    const key = `${NONCE_KEY_PREFIX}${payload.nonce}`;
    const accepted = await this.state.storage.transaction(
      async (transaction) => {
        const existingExpiry = await transaction.get(key);
        if (Number.isSafeInteger(existingExpiry) && existingExpiry > now) {
          return false;
        }
        await transaction.put(key, payload.expiresAt);
        return true;
      },
    );

    if (!accepted) {
      return new Response("Token already used", { status: 409 });
    }

    const alarmAt = await this.state.storage.getAlarm();
    if (alarmAt === null || alarmAt > payload.expiresAt) {
      await this.state.storage.setAlarm(payload.expiresAt);
    }
    return new Response("OK", { status: 200 });
  }

  async alarm() {
    const now = Date.now();
    const nonces = await this.state.storage.list({ prefix: NONCE_KEY_PREFIX });
    let nextAlarm = Number.POSITIVE_INFINITY;

    for (const [key, expiresAt] of nonces) {
      if (!Number.isSafeInteger(expiresAt) || expiresAt <= now) {
        await this.state.storage.delete(key);
      } else {
        nextAlarm = Math.min(nextAlarm, expiresAt);
      }
    }

    if (Number.isFinite(nextAlarm)) {
      await this.state.storage.setAlarm(nextAlarm);
    }
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean);

    if (parts.length === 0 || (parts.length === 1 && parts[0] === "issue")) {
      if (request.method === "GET") {
        return new Response(LANDING_HTML, {
          status: 200,
          headers: {
            "Content-Type": "text/html; charset=utf-8",
            "Cache-Control": "public, max-age=3600",
          },
        });
      }
      if (request.method === "POST") {
        return handleIssueCreate(request, env);
      }
      return new Response("Method Not Allowed", {
        status: 405,
        headers: { Allow: "GET, POST" },
      });
    }

    return new Response("Not Found", { status: 404 });
  },
};

async function handleIssueCreate(request, env) {
  const authResult = await authenticateIssueRequest(request, env);
  if (authResult.response) {
    return authResult.response;
  }

  if (!env.GITHUB_ISSUE_PAT || !env.GITHUB_ISSUE_REPO) {
    return jsonResponse({ error: "Issue reporting not configured." }, 503);
  }

  if (!/^[a-zA-Z0-9._-]+\/[a-zA-Z0-9._-]+$/.test(env.GITHUB_ISSUE_REPO)) {
    console.error("Invalid GITHUB_ISSUE_REPO format.");
    return jsonResponse({ error: "Issue reporting misconfigured." }, 503);
  }

  let payload;
  try {
    payload = await request.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON body." }, 400);
  }

  const allowedLabels = parseAllowedLabels(env.GITHUB_ISSUE_ALLOWED_LABELS);
  if (allowedLabels === null) {
    console.error("Invalid GITHUB_ISSUE_ALLOWED_LABELS configuration.");
    return jsonResponse({ error: "Issue reporting misconfigured." }, 503);
  }

  const validation = validateIssuePayload(payload, allowedLabels);
  if (!validation.ok) {
    return jsonResponse({ error: validation.error }, 400);
  }

  const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
  const reservationId = crypto.randomUUID();
  const rateLimitBody = JSON.stringify({
    ip,
    max: ISSUE_RATE_MAX,
    windowMs: ISSUE_RATE_WINDOW_MS,
    reservationId,
  });
  const rateLimitId = env.ISSUE_RATE_LIMIT.idFromName(`rate:${ip}`);
  const rateLimitDO = env.ISSUE_RATE_LIMIT.get(rateLimitId);
  const releaseSlot = async () => {
    try {
      await rateLimitDO.fetch(
        new Request("https://internal/ratelimit/release", {
          method: "POST",
          body: rateLimitBody,
        }),
      );
    } catch (error) {
      console.error("Issue rate limit release error:", error);
    }
  };

  let reserveResponse;
  try {
    reserveResponse = await rateLimitDO.fetch(
      new Request("https://internal/ratelimit/reserve", {
        method: "POST",
        body: rateLimitBody,
      }),
    );
  } catch (error) {
    console.error("Issue rate limit error:", error);
    return jsonResponse({ error: "Rate limit check failed. Try again." }, 503);
  }

  if (reserveResponse.status !== 200) {
    const code = reserveResponse.status === 429 ? 429 : 503;
    return jsonResponse(
      {
        error:
          code === 429
            ? "Rate limited. Maximum 5 reports per hour."
            : "Rate limit check failed.",
      },
      code,
    );
  }

  let githubResponse;
  try {
    githubResponse = await fetch(
      `https://api.github.com/repos/${env.GITHUB_ISSUE_REPO}/issues`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${env.GITHUB_ISSUE_PAT}`,
          Accept: "application/vnd.github+json",
          "User-Agent": "chau7-issues",
          "X-GitHub-Api-Version": "2022-11-28",
        },
        body: JSON.stringify(validation.githubPayload),
      },
    );
  } catch (error) {
    await releaseSlot();
    console.error("GitHub API request failed:", error);
    return jsonResponse({ error: "GitHub issue creation failed." }, 502);
  }

  if (!githubResponse.ok) {
    await releaseSlot();
    const errorText = await githubResponse.text();
    console.error(
      `GitHub API error: ${githubResponse.status} ${errorText.slice(0, 500)}`,
    );
    return jsonResponse(
      { error: `GitHub API error (${githubResponse.status}).` },
      502,
    );
  }

  try {
    const githubData = await githubResponse.json();
    return jsonResponse({ ok: true, issue_number: githubData.number ?? 0 });
  } catch (error) {
    // The upstream returned a successful status, so it may already have
    // created the issue. Keep the reservation to avoid allowing duplicate
    // retries to bypass the successful-creation rate limit.
    console.error("GitHub API returned invalid JSON:", error);
    return jsonResponse({ error: "GitHub issue creation failed." }, 502);
  }
}

async function authenticateIssueRequest(request, env) {
  if (request.headers.has("Origin")) {
    return {
      response: jsonResponse(
        { error: "Cross-origin requests are not allowed." },
        403,
      ),
    };
  }

  if (resolveAuthMode(env).mode !== "enforce") {
    console.error(
      "Issue intake rejecting request: relay credential keyring is missing or invalid.",
    );
    return {
      response: jsonResponse(
        { error: "Issue reporting authentication is not configured." },
        503,
      ),
    };
  }

  const deviceId = request.headers.get("X-Chau7-Device-ID") ?? "";
  const role = request.headers.get("X-Chau7-Role") ?? "";
  const authorization = request.headers.get("Authorization") ?? "";
  const match = /^Bearer\s+([^\s]+)$/i.exec(authorization.trim());
  if (
    !DEVICE_ID_PATTERN.test(deviceId) ||
    !["mac", "ios"].includes(role) ||
    !match
  ) {
    return {
      response: jsonResponse(
        { error: "A valid issue-reporting bearer token is required." },
        401,
      ),
    };
  }

  let verification;
  try {
    verification = await verifyCredentialToken(
      match[1],
      { deviceId, role, scope: "issues" },
      env,
    );
  } catch (error) {
    console.error("Issue intake token verification failed:", error);
    return {
      response: jsonResponse(
        { error: "Issue reporting authentication failed." },
        403,
      ),
    };
  }

  if (!verification.ok) {
    const status = verification.reason === "malformed" ? 401 : 403;
    return {
      response: jsonResponse(
        { error: "Invalid or expired issue-reporting token." },
        status,
      ),
    };
  }

  try {
    const nonceId = env.ISSUE_RATE_LIMIT.idFromName(`nonce:${deviceId}`);
    const nonceResponse = await env.ISSUE_RATE_LIMIT.get(nonceId).fetch(
      new Request("https://internal/nonce/consume", {
        method: "POST",
        body: JSON.stringify({
          nonce: verification.nonce,
          // Verification accepts the complete final integer second.
          expiresAt: verification.expiresAt + 1000,
        }),
      }),
    );
    if (nonceResponse.status === 409) {
      return {
        response: jsonResponse(
          { error: "Issue-reporting token already used." },
          403,
        ),
      };
    }
    if (nonceResponse.status !== 200) {
      console.error(
        `Issue token nonce store returned ${nonceResponse.status}.`,
      );
      return {
        response: jsonResponse(
          { error: "Issue reporting authentication failed." },
          503,
        ),
      };
    }
  } catch (error) {
    console.error("Issue token nonce store failed:", error);
    return {
      response: jsonResponse(
        { error: "Issue reporting authentication failed." },
        503,
      ),
    };
  }

  return { response: null, deviceId, role };
}

function validateIssuePayload(payload, allowedLabels) {
  if (!isPlainObject(payload)) {
    return { ok: false, error: "The request body must be a JSON object." };
  }

  const title = typeof payload.title === "string" ? payload.title.trim() : "";
  const body = typeof payload.body === "string" ? payload.body.trim() : "";
  if (!title || !body) {
    return {
      ok: false,
      error: "Both 'title' and 'body' are required and must be non-empty.",
    };
  }
  if (title.length > MAX_TITLE_LENGTH) {
    return {
      ok: false,
      error: `Title too long (${title.length} chars, max ${MAX_TITLE_LENGTH}).`,
    };
  }
  if (body.length > MAX_BODY_LENGTH) {
    return {
      ok: false,
      error: `Body too long (${body.length} chars, max ${MAX_BODY_LENGTH}).`,
    };
  }

  const labels = [];
  if (payload.labels !== undefined) {
    if (!Array.isArray(payload.labels) || payload.labels.length > MAX_LABELS) {
      return {
        ok: false,
        error: `Labels must be an array with at most ${MAX_LABELS} entries.`,
      };
    }
    for (const rawLabel of payload.labels) {
      if (typeof rawLabel !== "string") {
        return { ok: false, error: "Each issue label must be a string." };
      }
      const label = rawLabel.trim();
      if (!LABEL_PATTERN.test(label) || !allowedLabels.has(label)) {
        return {
          ok: false,
          error: "One or more issue labels are not allowed.",
        };
      }
      if (!labels.includes(label)) {
        labels.push(label);
      }
    }
  }

  const githubPayload = { title, body };
  if (labels.length > 0) {
    githubPayload.labels = labels;
  }
  return { ok: true, githubPayload };
}

function parseAllowedLabels(value) {
  if (value === undefined || value === "") {
    return new Set();
  }
  if (typeof value !== "string") {
    return null;
  }
  const labels = value.split(",").map((label) => label.trim());
  if (
    labels.some((label) => !LABEL_PATTERN.test(label)) ||
    new Set(labels).size !== labels.length
  ) {
    return null;
  }
  return new Set(labels);
}

function isValidRateLimitRequest(payload, action) {
  return (
    isPlainObject(payload) &&
    typeof payload.ip === "string" &&
    payload.ip.length > 0 &&
    payload.ip.length <= 128 &&
    !/[\u0000-\u0020\u007f]/.test(payload.ip) &&
    payload.max === ISSUE_RATE_MAX &&
    payload.windowMs === ISSUE_RATE_WINDOW_MS &&
    RESERVATION_ID_PATTERN.test(payload.reservationId ?? "") &&
    (action === "reserve" || action === "release")
  );
}

function recentReservations(stored, now, windowMs) {
  if (!Array.isArray(stored)) {
    return [];
  }
  return stored
    .map((reservation) => {
      if (Number.isSafeInteger(reservation)) {
        return { id: null, timestamp: reservation };
      }
      if (
        isPlainObject(reservation) &&
        Number.isSafeInteger(reservation.timestamp) &&
        (reservation.id === null || typeof reservation.id === "string")
      ) {
        return { id: reservation.id, timestamp: reservation.timestamp };
      }
      return null;
    })
    .filter(
      (reservation) =>
        reservation !== null &&
        reservation.timestamp <= now &&
        now - reservation.timestamp < windowMs,
    );
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

async function readJSON(request) {
  try {
    return await request.json();
  } catch {
    return null;
  }
}

function jsonResponse(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
    },
  });
}
