export class SessionDO {
  private macSocket?: WebSocket;
  private iosSocket?: WebSocket;

  async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("Expected WebSocket", { status: 426 });
    }

    const url = new URL(request.url);
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
}
