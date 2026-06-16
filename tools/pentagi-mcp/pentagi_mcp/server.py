"""pentagi-mcp — MCP server exposing pentest tooling for Claude Code / Codex CLI.

Run:        pentagi-mcp                  # stdio transport (Claude Code / Codex)
            pentagi-mcp doctor           # local setup / reachability diagnostics
Env:        PENTAGI_CONTAINER            # docker container name (default: pentagi-sandbox)
            PENTAGI_MCP_DB               # sqlite path (default: ~/.pentagi-mcp/state.db)
            PENTAGI_MCP_TIMEOUT          # per-tool exec timeout in seconds (default: 90)
"""

from __future__ import annotations

import argparse
import json
import sys

from mcp.server.fastmcp import FastMCP

from . import state

mcp = FastMCP("pentagi-mcp")

# Importing `tools` registers every @mcp.tool() with the FastMCP instance above.
# Done after `mcp` is constructed to avoid a circular import.
from . import tools  # noqa: E402,F401


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == "doctor":
        parser = argparse.ArgumentParser(prog="pentagi-mcp doctor")
        parser.add_argument("--target-url", default="https://localhost:8443/")
        parser.add_argument("--connect-host", default="host.docker.internal")
        parser.add_argument("--ensure-sni-proxy", action="store_true")
        args = parser.parse_args(sys.argv[2:])
        print(
            json.dumps(
                tools.doctor(
                    target_url=args.target_url,
                    connect_host=args.connect_host,
                    ensure_sni_proxy=args.ensure_sni_proxy,
                ),
                indent=2,
            )
        )
        return
    state.init()
    try:
        mcp.run()  # stdio transport (default)
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
