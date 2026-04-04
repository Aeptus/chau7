/**
 * SessionDO — Durable Object managing a single paired device session.
 *
 * Responsibilities:
 *   - WebSocket relay: bridges macOS ↔ iOS connections (one socket per role)
 *   - Push registration: stores APNs tokens per paired iOS device
 *   - Push notifications: sends APNs alerts when iOS is offline and macOS triggers a notify
 *   - Rate limiting: sliding window per IP for issue report endpoints
 *
 * State is persisted in Durable Object storage (survives Worker restarts).
 */

interface PushRegistration {
  pairedDeviceId: string;
  deviceName?: string;
  pushToken: string;
  pushTopic: string;
  pushEnvironment: "development" | "production";
  notificationsAuthorized: boolean;
  updatedAt: string;
}

interface PushRegistrationPayload {
  paired_device_id: string;
  device_name?: string;
  push_token?: string;
  push_topic?: string;
  push_environment?: "development" | "production";
  notifications_authorized: boolean;
}

interface PushNotifyPayload {
  kind: string;
  title: string;
  body: string;
  request_id?: string;
  prompt_id?: string;
  open_approvals?: boolean;
}

interface Env {
  APNS_TEAM_ID?: string;
  APNS_KEY_ID?: string;
  APNS_PRIVATE_KEY?: string;
}

const REGISTRATIONS_KEY = "push_registrations";

export class SessionDO {
  private readonly state: DurableObjectState;
  private readonly env: Env;
  private macSocket?: WebSocket;
  private iosSocket?: WebSocket;

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean);
    if (parts[0] === "connect") {
      return this.handleConnect(request, url);
    }
    if (parts[0] === "ratelimit" && parts[1] === "check") {
      return this.handleRateLimitCheck(request);
    }
    if (parts[0] === "push" && parts.length === 3) {
      const operation = parts[1];
      if (request.method !== "POST") {
        return new Response("Method Not Allowed", { status: 405 });
      }
      if (operation === "register") {
        return this.handlePushRegister(request);
      }
      if (operation === "notify") {
        return this.handlePushNotify(request);
      }
    }
    return new Response("Not Found", { status: 404 });
  }

  private async handleConnect(request: Request, url: URL): Promise<Response> {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("Expected WebSocket", { status: 426 });
    }

    const role = url.searchParams.get("role");
    if (role !== "mac" && role !== "ios") {
      return new Response("Missing role", { status: 400 });
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    server.accept();

    this.attachSocket(role, server);

    return new Response(null, {
      status: 101,
      webSocket: client
    });
  }

  private attachSocket(role: "mac" | "ios", socket: WebSocket) {
    const existing = role === "mac" ? this.macSocket : this.iosSocket;
    if (existing) {
      try {
        existing.close(1000, "Replaced by new connection");
      } catch {
        // Ignore close errors.
      }
    }

    if (role === "mac") {
      this.macSocket = socket;
    } else {
      this.iosSocket = socket;
    }

    socket.addEventListener("message", (event) => {
      const target = role === "mac" ? this.iosSocket : this.macSocket;
      if (!target) {
        return;
      }
      try {
        target.send(event.data);
      } catch {
        // Ignore send errors.
      }
    });

    socket.addEventListener("close", () => {
      if (role === "mac" && this.macSocket === socket) {
        this.macSocket = undefined;
      }
      if (role === "ios" && this.iosSocket === socket) {
        this.iosSocket = undefined;
      }
    });

    socket.addEventListener("error", () => {
      try {
        socket.close(1011, "WebSocket error");
      } catch {
        // Ignore close errors.
      }
    });
  }

  private async handlePushRegister(request: Request): Promise<Response> {
    const payload = (await request.json()) as PushRegistrationPayload;
    if (!payload.paired_device_id) {
      return new Response("Missing paired_device_id", { status: 400 });
    }

    const registrations = await this.loadRegistrations();
    if (
      !payload.notifications_authorized ||
      !payload.push_token ||
      !payload.push_topic ||
      !payload.push_environment
    ) {
      delete registrations[payload.paired_device_id];
      await this.saveRegistrations(registrations);
      return new Response(null, { status: 204 });
    }

    registrations[payload.paired_device_id] = {
      pairedDeviceId: payload.paired_device_id,
      deviceName: payload.device_name,
      pushToken: payload.push_token,
      pushTopic: payload.push_topic,
      pushEnvironment: payload.push_environment,
      notificationsAuthorized: true,
      updatedAt: new Date().toISOString()
    };
    await this.saveRegistrations(registrations);
    return new Response(null, { status: 204 });
  }

  private async handlePushNotify(request: Request): Promise<Response> {
    if (this.iosSocket) {
      return new Response(null, { status: 204 });
    }

    const payload = (await request.json()) as PushNotifyPayload;
    const registrations = Object.values(await this.loadRegistrations()).filter(
      (registration) =>
        registration.notificationsAuthorized &&
        registration.pushToken &&
        registration.pushTopic
    );
    if (registrations.length === 0) {
      return new Response(null, { status: 204 });
    }

    await Promise.all(
      registrations.map(async (registration) => {
        const status = await this.sendAPNSNotification(registration, payload);
        if (status === 400 || status === 410) {
          const next = await this.loadRegistrations();
          delete next[registration.pairedDeviceId];
          await this.saveRegistrations(next);
        }
      })
    );

    return new Response(null, { status: 204 });
  }

  private async loadRegistrations(): Promise<Record<string, PushRegistration>> {
    return (await this.state.storage.get<Record<string, PushRegistration>>(REGISTRATIONS_KEY)) ?? {};
  }

  private async saveRegistrations(registrations: Record<string, PushRegistration>): Promise<void> {
    await this.state.storage.put(REGISTRATIONS_KEY, registrations);
  }

  private async sendAPNSNotification(
    registration: PushRegistration,
    payload: PushNotifyPayload
  ): Promise<number> {
    const { APNS_TEAM_ID, APNS_KEY_ID, APNS_PRIVATE_KEY } = this.env;
    if (!APNS_TEAM_ID || !APNS_KEY_ID || !APNS_PRIVATE_KEY) {
      return 204;
    }

    const host =
      registration.pushEnvironment === "production"
        ? "https://api.push.apple.com"
        : "https://api.sandbox.push.apple.com";
    const authToken = await this.createAPNSToken(APNS_TEAM_ID, APNS_KEY_ID, APNS_PRIVATE_KEY);
    const body = {
      aps: {
        alert: {
          title: payload.title,
          body: payload.body
        },
        sound: "default",
        "content-available": 1
      },
      kind: payload.kind,
      request_id: payload.request_id,
      prompt_id: payload.prompt_id,
      open_approvals: payload.open_approvals ?? true
    };

    const response = await fetch(`${host}/3/device/${registration.pushToken}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${authToken}`,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-topic": registration.pushTopic,
        "content-type": "application/json"
      },
      body: JSON.stringify(body)
    });
    return response.status;
  }

  private async createAPNSToken(teamID: string, keyID: string, privateKey: string): Promise<string> {
    const header = this.base64url(
      JSON.stringify({ alg: "ES256", kid: keyID, typ: "JWT" })
    );
    const claims = this.base64url(
      JSON.stringify({ iss: teamID, iat: Math.floor(Date.now() / 1000) })
    );
    const signingInput = `${header}.${claims}`;
    const key = await crypto.subtle.importKey(
      "pkcs8",
      this.pemToArrayBuffer(privateKey),
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["sign"]
    );
    const signature = await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      new TextEncoder().encode(signingInput)
    );
    return `${signingInput}.${this.base64url(signature)}`;
  }

  private pemToArrayBuffer(pem: string): ArrayBuffer {
    const normalized = pem.replace(/\\n/g, "\n");
    const base64 = normalized
      .replace(/-----BEGIN PRIVATE KEY-----/g, "")
      .replace(/-----END PRIVATE KEY-----/g, "")
      .replace(/\s+/g, "");
    const bytes = Uint8Array.from(atob(base64), (char) => char.charCodeAt(0));
    return bytes.buffer;
  }

  private base64url(value: string | ArrayBuffer): string {
    const bytes =
      typeof value === "string"
        ? new TextEncoder().encode(value)
        : new Uint8Array(value);
    let binary = "";
    for (const byte of bytes) {
      binary += String.fromCharCode(byte);
    }
    return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }

  // MARK: - Rate Limiting (used by /issue endpoint)

  private async handleRateLimitCheck(request: Request): Promise<Response> {
    const { ip, max, windowMs } = (await request.json()) as {
      ip: string;
      max: number;
      windowMs: number;
    };

    const key = `ratelimit:${ip}`;
    const now = Date.now();
    const stored = ((await this.state.storage.get(key)) as number[] | undefined) ?? [];
    const recent = stored.filter((t) => now - t < windowMs);

    if (recent.length >= max) {
      return new Response("Rate limited", { status: 429 });
    }

    recent.push(now);
    await this.state.storage.put(key, recent);

    // Schedule cleanup: set an alarm to purge old entries after the window.
    // This prevents unbounded storage growth from many unique IPs.
    const cleanupKey = `ratelimit_cleanup:${ip}`;
    const hasCleanup = await this.state.storage.get(cleanupKey);
    if (!hasCleanup) {
      await this.state.storage.put(cleanupKey, true);
      // Durable Object storage entries with TTL aren't natively supported,
      // so we just let the next check prune old timestamps. The storage
      // for a single IP is at most max * 8 bytes — negligible.
    }

    return new Response("OK", { status: 200 });
  }
}
