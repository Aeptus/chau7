/**
 * Chau7 Relay — Cloudflare Worker entry point.
 *
 * Routes:
 *   GET  /              Landing page (HTML)
 *   WS   /connect/:id   WebSocket relay between macOS and iOS clients
 *   POST /push/:topic/:deviceId  Forward push notification to a paired device
 *
 * Authentication: HMAC-SHA256 bearer tokens with 5-minute window.
 */
import { SessionDO } from './session';
import { isRelaySecretConfigured } from './auth.js';

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

interface Env {
  SESSION: DurableObjectNamespace;
  RELAY_SECRET?: string;
  APNS_TEAM_ID?: string;
  APNS_KEY_ID?: string;
  APNS_PRIVATE_KEY?: string;
}

/**
 * Verify an HMAC-SHA256 token. Format: "{unix_timestamp}.{base64url_signature}".
 * Payload signed: "{deviceId}:{role}:{timestamp}". Tokens expire after 300 seconds.
 */
async function verifyToken(
  token: string,
  deviceId: string,
  role: string,
  secret: string
): Promise<boolean> {
  const parts = token.split('.');
  if (parts.length !== 2) return false;
  const [timestamp, signature] = parts;
  const ts = parseInt(timestamp, 10);
  if (isNaN(ts)) return false;
  const age = Math.abs(Date.now() / 1000 - ts);
  if (age > 300) return false;

  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  const message = `${deviceId}:${role}:${timestamp}`;
  const mac = await crypto.subtle.sign('HMAC', key, encoder.encode(message));
  const expected = btoa(String.fromCharCode(...new Uint8Array(mac)))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
  return expected === signature;
}

function extractBearerToken(request: Request): string | null {
  const header = request.headers.get('Authorization') ?? '';
  if (!header.startsWith('Bearer ')) {
    return null;
  }
  return header.slice('Bearer '.length).trim() || null;
}

async function authenticateRequest(
  request: Request,
  env: Env,
  deviceId: string,
  role: string
): Promise<Response | null> {
  if (!isRelaySecretConfigured(env.RELAY_SECRET)) {
    return new Response('Relay secret not configured', { status: 503 });
  }
  const token = extractBearerToken(request) ?? new URL(request.url).searchParams.get('token');
  if (!token) {
    return new Response('Missing token', { status: 401 });
  }
  const valid = await verifyToken(token, deviceId, role, env.RELAY_SECRET!);
  if (!valid) {
    return new Response('Invalid token', { status: 403 });
  }
  return null;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const parts = url.pathname.split('/').filter(Boolean);

    if (parts.length === 0) {
      if (request.method === 'GET') {
        return new Response(LANDING_HTML, {
          status: 200,
          headers: { 'Content-Type': 'text/html; charset=utf-8' }
        });
      }
      return new Response('Method Not Allowed', { status: 405 });
    }

    if (parts.length < 2) {
      return new Response('Not Found', { status: 404 });
    }

    const action = parts[0];

    if (action === 'connect') {
      const deviceId = parts[1];
      if (!deviceId) {
        return new Response('Missing device id', { status: 400 });
      }
      const role = url.searchParams.get('role');
      if (role !== 'mac' && role !== 'ios') {
        return new Response('Missing role', { status: 400 });
      }
      const authFailure = await authenticateRequest(request, env, deviceId, role);
      if (authFailure) {
        return authFailure;
      }
      const id = env.SESSION.idFromName(deviceId);
      const stub = env.SESSION.get(id);
      return stub.fetch(request);
    }

    if (action === 'push' && parts.length === 3) {
      const targetDeviceID = parts[2];
      const authFailure = await authenticateRequest(request, env, targetDeviceID, 'mac');
      if (authFailure) {
        return authFailure;
      }
      const id = env.SESSION.idFromName(targetDeviceID);
      const stub = env.SESSION.get(id);
      return stub.fetch(request);
    }

    return new Response('Not Found', { status: 404 });
  }
};
