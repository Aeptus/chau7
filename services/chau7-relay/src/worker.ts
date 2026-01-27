import { SessionDO } from "./session";

export { SessionDO };

interface Env {
  SESSION: DurableObjectNamespace;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (!url.pathname.startsWith("/connect/")) {
      return new Response("Not Found", { status: 404 });
    }

    const parts = url.pathname.split("/");
    const deviceId = parts[2];
    if (!deviceId) {
      return new Response("Missing device id", { status: 400 });
    }

    const id = env.SESSION.idFromName(deviceId);
    const stub = env.SESSION.get(id);
    return stub.fetch(request);
  }
};
