# pentagi-mcp

MCP server that lets Claude Code / Codex drive pentest tools inside a PentAGI-style sandbox container.

The server runs on stdio and executes tools with `docker exec` against `PENTAGI_CONTAINER` (`pentagi-sandbox` by default).

## Install

```bash
python3 -m venv ~/.local/share/pentagi-mcp-venv
~/.local/share/pentagi-mcp-venv/bin/python -m pip install -e tools/pentagi-mcp
ln -sf ~/.local/share/pentagi-mcp-venv/bin/pentagi-mcp ~/.local/bin/pentagi-mcp
```

## Preflight

Run diagnostics before wiring/restarting an MCP client:

```bash
PENTAGI_CONTAINER=pentagi-sandbox pentagi-mcp doctor \
  --target-url https://localhost:8443/ \
  --connect-host host.docker.internal
```

For repeatable local setup from the Chau7 repo root:

```bash
TARGET_URL=https://localhost:8443/ ./scripts/pentagi-mcp-local-preflight --sni-proxy
```

## Local HTTPS Targets

Docker containers cannot reach a host-local service through container `127.0.0.1`. On Docker Desktop, use `host.docker.internal` for the TCP path.

Some HTTPS services only accept TLS SNI `localhost`. Web tools support split target arguments:

- `target_url`: logical URL to scan.
- `connect_host`: TCP endpoint reachable from the sandbox.
- `connect_port`: TCP port reachable from the sandbox.
- `tls_sni`: TLS SNI hostname the service expects.
- `http_host`: HTTP `Host` header, when different from the URL host.

Example:

```json
{
  "target_url": "https://localhost:8443/",
  "connect_host": "host.docker.internal",
  "connect_port": 8443,
  "tls_sni": "localhost",
  "http_host": "localhost"
}
```

The server starts a tagged sandbox-local `socat` proxy when needed and exposes `sni_proxy_ls` / `sni_proxy_kill` for inspection and cleanup.

## Scan Profiles

`scan_web` and `scan_vulns` accept `profile`:

- `quick`: default; designed to finish under common MCP client call limits.
- `normal`: larger but still bounded.
- `deep`: opt-in for clients with longer tool-call limits.

Every scanner returns timeout metadata. Timeouts should return loudly with `timed_out: true` and a non-zero return code instead of hanging the MCP client.

## Evidence Safety

`container_exec` decodes binary output with replacement instead of crashing and reports `binary_detected`. Use `encoding="base64"` when exact binary bytes are needed.

`container_file_write` writes exact content via base64 decoding inside the sandbox; it does not add heredoc trailing newlines.
