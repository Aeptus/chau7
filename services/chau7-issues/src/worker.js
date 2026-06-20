/**
 * Chau7 Issues — Cloudflare Worker entry point.
 *
 * Routes:
 *   GET  /              Landing page (HTML)
 *   POST / or /issue    Create a GitHub issue via the private intake repo
 *   OPTIONS / or /issue CORS preflight for issue creation
 */

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

export class IssueRateLimitDO {
  constructor(state) {
    this.state = state;
  }

  async fetch(request) {
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean);
    const action = parts[1];
    if (
      request.method !== "POST" ||
      parts[0] !== "ratelimit" ||
      (action !== "check" && action !== "commit")
    ) {
      return new Response("Not Found", { status: 404 });
    }

    const { ip, max, windowMs } = await request.json();
    const key = `ratelimit:${ip}`;
    const now = Date.now();
    const stored = (await this.state.storage.get(key)) ?? [];
    const recent = stored.filter((timestamp) => now - timestamp < windowMs);

    // `check` is a read-only gate; `commit` records a successful creation.
    // Counting only successful creations means malformed payloads and transient
    // GitHub failures no longer burn the caller's hourly quota.
    if (action === "check") {
      return recent.length >= max
        ? new Response("Rate limited", { status: 429 })
        : new Response("OK", { status: 200 });
    }

    recent.push(now);
    await this.state.storage.put(key, recent);
    return new Response("OK", { status: 200 });
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
          headers: { "Content-Type": "text/html; charset=utf-8" },
        });
      }
      if (request.method === "OPTIONS") {
        return corsResponse(null, 204);
      }
      if (request.method === "POST") {
        return handleIssueCreate(request, env);
      }
      return new Response("Method Not Allowed", { status: 405 });
    }

    return new Response("Not Found", { status: 404 });
  },
};

async function handleIssueCreate(request, env) {
  if (!env.GITHUB_ISSUE_PAT || !env.GITHUB_ISSUE_REPO) {
    return corsResponse({ error: "Issue reporting not configured." }, 503);
  }

  if (!/^[a-zA-Z0-9._-]+\/[a-zA-Z0-9._-]+$/.test(env.GITHUB_ISSUE_REPO)) {
    console.error(`Invalid GITHUB_ISSUE_REPO format: ${env.GITHUB_ISSUE_REPO}`);
    return corsResponse({ error: "Issue reporting misconfigured." }, 503);
  }

  const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
  const rateLimitId = env.ISSUE_RATE_LIMIT.idFromName("issue-ratelimit");
  const rateLimitDO = env.ISSUE_RATE_LIMIT.get(rateLimitId);
  let rateLimitResponse;
  try {
    rateLimitResponse = await rateLimitDO.fetch(
      new Request("https://internal/ratelimit/check", {
        method: "POST",
        body: JSON.stringify({
          ip,
          max: ISSUE_RATE_MAX,
          windowMs: ISSUE_RATE_WINDOW_MS,
        }),
      }),
    );
  } catch (error) {
    console.error("Issue rate limit error:", error);
    return corsResponse({ error: "Rate limit check failed. Try again." }, 503);
  }

  if (rateLimitResponse.status !== 200) {
    const code = rateLimitResponse.status === 429 ? 429 : 503;
    return corsResponse(
      {
        error:
          code === 429
            ? "Rate limited. Maximum 5 reports per hour."
            : "Rate limit check failed.",
      },
      code,
    );
  }

  let payload;
  try {
    payload = await request.json();
  } catch {
    return corsResponse({ error: "Invalid JSON body." }, 400);
  }

  const title = typeof payload.title === "string" ? payload.title.trim() : "";
  const body = typeof payload.body === "string" ? payload.body.trim() : "";
  if (!title || !body) {
    return corsResponse(
      { error: "Both 'title' and 'body' are required and must be non-empty." },
      400,
    );
  }
  if (title.length > 256) {
    return corsResponse(
      { error: `Title too long (${title.length} chars, max 256).` },
      400,
    );
  }
  if (body.length > 65535) {
    return corsResponse(
      { error: `Body too long (${body.length} chars, max 65535).` },
      400,
    );
  }

  const labels = Array.isArray(payload.labels)
    ? payload.labels.filter((label) => typeof label === "string").slice(0, 5)
    : [];

  const githubPayload = { title, body };
  if (labels.length > 0) {
    githubPayload.labels = labels;
  }

  const githubResponse = await fetch(
    `https://api.github.com/repos/${env.GITHUB_ISSUE_REPO}/issues`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.GITHUB_ISSUE_PAT}`,
        Accept: "application/vnd.github+json",
        "User-Agent": "chau7-issues",
        "X-GitHub-Api-Version": "2022-11-28",
      },
      body: JSON.stringify(githubPayload),
    },
  );

  if (!githubResponse.ok) {
    const errorText = await githubResponse.text();
    console.error(
      `GitHub API error: ${githubResponse.status} ${errorText.slice(0, 500)}`,
    );
    return corsResponse(
      { error: `GitHub API error (${githubResponse.status}).` },
      502,
    );
  }

  const githubData = await githubResponse.json();

  // Count only successful creations against the hourly limit (the check above is
  // read-only). Recording the slot must not fail the issue that was just created.
  try {
    await rateLimitDO.fetch(
      new Request("https://internal/ratelimit/commit", {
        method: "POST",
        body: JSON.stringify({
          ip,
          max: ISSUE_RATE_MAX,
          windowMs: ISSUE_RATE_WINDOW_MS,
        }),
      }),
    );
  } catch (error) {
    console.error("Issue rate limit commit error:", error);
  }

  return corsResponse({ ok: true, issue_number: githubData.number ?? 0 });
}

function corsResponse(data, status = 200) {
  return new Response(data == null ? null : JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type",
      "Access-Control-Max-Age": "86400",
    },
  });
}
