import { SessionDO } from "./session";

export { SessionDO };

interface Env {
  SESSION: DurableObjectNamespace;
  RELAY_SECRET: string;
  APNS_TEAM_ID?: string;
  APNS_KEY_ID?: string;
  APNS_PRIVATE_KEY?: string;
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
  if (!env.RELAY_SECRET || env.RELAY_SECRET === "CHANGE_ME_IN_PRODUCTION") {
    return null;
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

    return new Response("Not Found", { status: 404 });
  }
};
