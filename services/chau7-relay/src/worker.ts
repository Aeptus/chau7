import { SessionDO } from "./session";
import { isRelaySecretConfigured } from "./auth.js";

export { SessionDO };

interface Env {
  SESSION: DurableObjectNamespace;
  RELAY_SECRET?: string;
  APNS_TEAM_ID?: string;
  APNS_KEY_ID?: string;
  APNS_PRIVATE_KEY?: string;
  GITHUB_ISSUE_PAT?: string;
  GITHUB_ISSUE_REPO?: string; // e.g. "owner/repo"
}

async function verifyToken(
  token: string,
  deviceId: string,
  role: string,
  secret: string
): Promise<boolean> {
  const parts = token.split(".");
  if (parts.length !== 2) return false;
  const [timestamp, signature] = parts;
  const ts = parseInt(timestamp, 10);
  if (isNaN(ts)) return false;
  const age = Math.abs(Date.now() / 1000 - ts);
  if (age > 300) return false;

  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const message = `${deviceId}:${role}:${timestamp}`;
  const mac = await crypto.subtle.sign("HMAC", key, encoder.encode(message));
  const expected = btoa(String.fromCharCode(...new Uint8Array(mac)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
  return expected === signature;
}

function extractBearerToken(request: Request): string | null {
  const header = request.headers.get("Authorization") ?? "";
  if (!header.startsWith("Bearer ")) {
    return null;
  }
  return header.slice("Bearer ".length).trim() || null;
}

async function authenticateRequest(
  request: Request,
  env: Env,
  deviceId: string,
  role: string
): Promise<Response | null> {
  if (!isRelaySecretConfigured(env.RELAY_SECRET)) {
    return new Response("Relay secret not configured", { status: 503 });
  }
  const token = extractBearerToken(request) ?? new URL(request.url).searchParams.get("token");
  if (!token) {
    return new Response("Missing token", { status: 401 });
  }
  const valid = await verifyToken(token, deviceId, role, env.RELAY_SECRET);
  if (!valid) {
    return new Response("Invalid token", { status: 403 });
  }
  return null;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean);
    if (parts.length < 2) {
      return new Response("Not Found", { status: 404 });
    }

    const action = parts[0];

    if (action === "connect") {
      const deviceId = parts[1];
      if (!deviceId) {
        return new Response("Missing device id", { status: 400 });
      }
      const role = url.searchParams.get("role");
      if (role !== "mac" && role !== "ios") {
        return new Response("Missing role", { status: 400 });
      }
      const authFailure = await authenticateRequest(request, env, deviceId, role);
      if (authFailure) {
        return authFailure;
      }
      const id = env.SESSION.idFromName(deviceId);
      const stub = env.SESSION.get(id);
      return stub.fetch(request);
    }

    if (action === "push" && parts.length === 3) {
      const targetDeviceID = parts[2];
      const authFailure = await authenticateRequest(request, env, targetDeviceID, "mac");
      if (authFailure) {
        return authFailure;
      }
      const id = env.SESSION.idFromName(targetDeviceID);
      const stub = env.SESSION.get(id);
      return stub.fetch(request);
    }

    // POST /issue — create a GitHub issue via server-side PAT.
    // No auth required (public endpoint), rate-limited by IP.
    if (action === "issue") {
      if (request.method === "OPTIONS") {
        return new Response(null, {
          status: 204,
          headers: {
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type",
            "Access-Control-Max-Age": "86400",
          },
        });
      }
      if (request.method === "POST") {
        return handleIssueCreate(request, env);
      }
    }

    return new Response("Not Found", { status: 404 });
  }
};

// MARK: - Issue Reporting

const ISSUE_RATE_MAX = 5;
const ISSUE_RATE_WINDOW_MS = 60 * 60 * 1000; // 1 hour

async function handleIssueCreate(
  request: Request,
  env: Env
): Promise<Response> {
  // Validate secrets
  if (!env.GITHUB_ISSUE_PAT || !env.GITHUB_ISSUE_REPO) {
    return jsonResponse(
      { error: "Issue reporting not configured on this relay." },
      503
    );
  }

  // Sanitize repo path — must be "owner/repo" format
  const repo = env.GITHUB_ISSUE_REPO;
  if (!/^[a-zA-Z0-9._-]+\/[a-zA-Z0-9._-]+$/.test(repo)) {
    console.error(`Invalid GITHUB_ISSUE_REPO format: ${repo}`);
    return jsonResponse({ error: "Issue reporting misconfigured." }, 503);
  }

  // Rate limit by IP using Durable Object storage (survives Worker restarts)
  const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
  const rateLimitId = env.SESSION.idFromName("issue-ratelimit");
  const rateLimitDO = env.SESSION.get(rateLimitId);
  let rlCheck: Response;
  try {
    rlCheck = await rateLimitDO.fetch(
      new Request("https://internal/ratelimit/check", {
        method: "POST",
        body: JSON.stringify({ ip, max: ISSUE_RATE_MAX, windowMs: ISSUE_RATE_WINDOW_MS }),
      })
    );
  } catch (e) {
    console.error("Rate limit DO error:", e);
    return jsonResponse({ error: "Rate limit check failed. Try again." }, 503);
  }
  if (rlCheck.status !== 200) {
    const code = rlCheck.status === 429 ? 429 : 503;
    return jsonResponse(
      { error: code === 429 ? "Rate limited. Maximum 5 reports per hour." : "Rate limit check failed." },
      code
    );
  }

  // Parse and validate body
  let body: { title?: string; body?: string; labels?: string[] };
  try {
    body = await request.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON body." }, 400);
  }

  const title = typeof body.title === "string" ? body.title.trim() : "";
  const issueBody = typeof body.body === "string" ? body.body.trim() : "";

  if (!title || !issueBody) {
    return jsonResponse(
      { error: "Both 'title' and 'body' are required and must be non-empty." },
      400
    );
  }

  if (title.length > 256) {
    return jsonResponse(
      { error: `Title too long (${title.length} chars, max 256).` },
      400
    );
  }

  if (issueBody.length > 65535) {
    return jsonResponse(
      { error: `Body too long (${issueBody.length} chars, max 65535).` },
      400
    );
  }

  // Validate labels if provided
  const labels = Array.isArray(body.labels)
    ? body.labels.filter((l): l is string => typeof l === "string").slice(0, 5)
    : [];

  // Create GitHub issue
  const ghBody: Record<string, unknown> = { title, body: issueBody };
  if (labels.length > 0) {
    ghBody.labels = labels;
  }

  const ghResponse = await fetch(
    `https://api.github.com/repos/${env.GITHUB_ISSUE_REPO}/issues`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.GITHUB_ISSUE_PAT}`,
        Accept: "application/vnd.github+json",
        "User-Agent": "chau7-relay",
        "X-GitHub-Api-Version": "2022-11-28",
      },
      body: JSON.stringify(ghBody),
    }
  );

  if (!ghResponse.ok) {
    const errText = await ghResponse.text();
    console.error(
      `GitHub API error: ${ghResponse.status} ${errText.slice(0, 500)}`
    );
    return jsonResponse(
      { error: `GitHub API error (${ghResponse.status}).` },
      502
    );
  }

  const ghData = (await ghResponse.json()) as { number?: number };

  return jsonResponse({
    ok: true,
    issue_number: ghData.number ?? 0,
  });
}

function jsonResponse(data: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type",
    },
  });
}
