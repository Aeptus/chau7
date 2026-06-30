/**
 * Chau7 Relay — Cloudflare Worker entry point.
 *
 * Routes:
 *   GET  /                          Landing page (HTML)
 *   WS   /connect/:id?role=mac|ios  WebSocket relay between macOS and iOS clients
 *   POST /push/register/:deviceId   Register an iOS device for APNs push (role=mac)
 *   POST /push/notify/:deviceId     Forward a push notification (role=mac)
 *   GET  /pending/:deviceId         Read the pending approvals/prompts snapshot (role=ios)
 *   POST /pending/:deviceId         Replace the pending approvals/prompts snapshot (role=mac)
 *
 * Authentication: scoped, single-use HMAC-SHA256 bearer tokens (see token.js).
 * Tokens are accepted ONLY from the `Authorization: Bearer` header. The Worker
 * fails CLOSED — if RELAY_SECRET is unset and open mode was not explicitly
 * requested, authenticated routes return 503.
 */
import { SessionDO } from './session';
import { resolveAuthMode } from './auth.js';
import { verifyToken } from './token.js';

export { SessionDO };

const LANDING_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Chau7 Relay</title>
<style>
  body { font-family: -apple-system, system-ui, sans-serif; max-width: 480px; margin: 80px auto; padding: 0 20px; color: #e0e0e0; background: #1a1a1a; }
  h1 { font-size: 1.3em; }
  p { line-height: 1.6; color: #999; }
  a { color: #6ba3f7; }
  code { background: #2a2a2a; padding: 2px 6px; border-radius: 4px; font-size: 0.9em; }
</style>
</head>
<body>
<h1>Chau7 Relay</h1>
<p>This worker carries encrypted remote-control traffic between Chau7 on macOS and Chau7 Remote on iPhone.</p>
<p>If you're a browser, there is nothing interactive for you here. If you're a paired Chau7 client, connect over WebSocket at <code>/connect/&lt;deviceId&gt;?role=mac|ios</code>.</p>
<p><a href="https://chau7.sh">chau7.sh</a></p>
</body>
</html>`;

type Scope = 'connect' | 'push' | 'pending';
type Role = 'mac' | 'ios';

interface Env {
  SESSION: DurableObjectNamespace;
  RELAY_SECRET?: string;
  RELAY_ALLOW_UNAUTHENTICATED?: string;
}

/** Logged at most once per isolate so an open-mode deployment is visible without spamming logs. */
let openModeWarned = false;

function extractBearerToken(request: Request): string | null {
  const header = request.headers.get('Authorization') ?? '';
  if (!header.startsWith('Bearer ')) {
    return null;
  }
  return header.slice('Bearer '.length).trim() || null;
}

function methodNotAllowed(allow: string): Response {
  return new Response('Method Not Allowed', { status: 405, headers: { Allow: allow } });
}

/**
 * Authenticate a request for the given (deviceId, role, scope). Returns null on
 * success, or a Response describing the failure.
 */
async function authenticateRequest(
  request: Request,
  env: Env,
  deviceId: string,
  role: Role,
  scope: Scope
): Promise<Response | null> {
  const auth = resolveAuthMode(env);

  if (auth.mode === 'misconfigured') {
    console.error('Relay rejecting request: RELAY_SECRET is not configured (failing closed).');
    return new Response('Relay not configured', { status: 503 });
  }

  if (auth.mode === 'open') {
    if (!openModeWarned) {
      openModeWarned = true;
      console.warn(
        'Relay running UNAUTHENTICATED (RELAY_ALLOW_UNAUTHENTICATED=true). Set RELAY_SECRET to require auth.'
      );
    }
    return null;
  }

  const token = extractBearerToken(request);
  if (!token) {
    return new Response('Missing token', { status: 401 });
  }
  const result = await verifyToken(token, { deviceId, role, scope, secret: auth.secret! });
  if (!result.ok) {
    const status = result.reason === 'malformed' ? 401 : 403;
    return new Response('Invalid token', { status });
  }
  return null;
}

/** Forward a request to the SessionDO addressed by deviceId. */
function forwardToSession(env: Env, deviceId: string, request: Request): Promise<Response> {
  const id = env.SESSION.idFromName(deviceId);
  return env.SESSION.get(id).fetch(request);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const parts = url.pathname.split('/').filter(Boolean);

    if (parts.length === 0) {
      if (request.method === 'GET') {
        return new Response(LANDING_HTML, {
          status: 200,
          headers: {
            'Content-Type': 'text/html; charset=utf-8',
            'Cache-Control': 'public, max-age=3600'
          }
        });
      }
      return methodNotAllowed('GET');
    }

    const action = parts[0];

    if (action === 'connect' && parts.length === 2) {
      const deviceId = parts[1];
      if (!deviceId) {
        return new Response('Missing device id', { status: 400 });
      }
      const role = url.searchParams.get('role');
      if (role !== 'mac' && role !== 'ios') {
        return new Response('Missing role', { status: 400 });
      }
      const authFailure = await authenticateRequest(request, env, deviceId, role, 'connect');
      if (authFailure) {
        return authFailure;
      }
      return forwardToSession(env, deviceId, request);
    }

    if (action === 'push' && parts.length === 3) {
      const operation = parts[1];
      if (operation !== 'register' && operation !== 'notify') {
        return new Response('Not Found', { status: 404 });
      }
      if (request.method !== 'POST') {
        return methodNotAllowed('POST');
      }
      const targetDeviceID = parts[2];
      const authFailure = await authenticateRequest(request, env, targetDeviceID, 'mac', 'push');
      if (authFailure) {
        return authFailure;
      }
      return forwardToSession(env, targetDeviceID, request);
    }

    if (action === 'pending' && parts.length === 2) {
      const targetDeviceID = parts[1];
      if (request.method !== 'GET' && request.method !== 'POST') {
        return methodNotAllowed('GET, POST');
      }
      const role: Role = request.method === 'GET' ? 'ios' : 'mac';
      const authFailure = await authenticateRequest(request, env, targetDeviceID, role, 'pending');
      if (authFailure) {
        return authFailure;
      }
      return forwardToSession(env, targetDeviceID, request);
    }

    return new Response('Not Found', { status: 404 });
  }
};
