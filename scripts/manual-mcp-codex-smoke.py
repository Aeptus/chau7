#!/usr/bin/env python3
import json
import os
import socket
import sys
import time
from pathlib import Path

SOCKET_PATH = Path.home() / ".chau7" / "mcp.sock"
DEFAULT_DIRECTORY = "/Users/christophehenner/Downloads/Repositories/Chau7"
DEFAULT_CODEX_COMMAND = "codex --model gpt-5.3-codex"
DEFAULT_INPUT = "Are you ready"
DEFAULT_WAIT_FOR_RESPONSE_SECONDS = 20.0


class MCPClient:
    def __init__(self, socket_path: str, timeout: float = 20.0):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect(socket_path)
        self.file = self.sock.makefile("rwb", buffering=0)
        self.next_id = 1

    def close(self) -> None:
        try:
            self.file.close()
        finally:
            self.sock.close()

    def request(self, method: str, params: dict | None = None, *, expect_response: bool = True):
        request_id = self.next_id
        self.next_id += 1
        payload = {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
            "params": params or {},
        }
        self.file.write((json.dumps(payload) + "\n").encode("utf-8"))
        self.file.flush()
        if not expect_response:
            return None
        while True:
            raw = self.file.readline()
            if not raw:
                raise RuntimeError(f"connection closed while waiting for {method}")
            message = json.loads(raw.decode("utf-8"))
            if message.get("id") == request_id:
                if "error" in message:
                    raise RuntimeError(f"{method} failed: {message['error']}")
                return message.get("result")

    def initialize(self) -> None:
        self.request(
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "manual-mcp-codex-smoke", "version": "1.0"},
            },
        )
        self.request("notifications/initialized", expect_response=False)

    def call_tool(self, name: str, arguments: dict):
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        if not isinstance(result, dict):
            raise RuntimeError(f"unexpected tools/call result for {name}: {result!r}")
        content = result.get("content")
        if not isinstance(content, list) or not content:
            raise RuntimeError(f"missing tool content for {name}: {result!r}")
        text = content[0].get("text")
        if not isinstance(text, str):
            raise RuntimeError(f"missing tool text for {name}: {content[0]!r}")
        return json.loads(text)


def main() -> int:
    socket_path = os.environ.get("CHAU7_MCP_SOCKET", str(SOCKET_PATH))
    directory = os.environ.get("CHAU7_SMOKE_DIR", DEFAULT_DIRECTORY)
    codex_command = os.environ.get("CHAU7_SMOKE_CODEX_COMMAND", DEFAULT_CODEX_COMMAND)
    input_text = os.environ.get("CHAU7_SMOKE_INPUT", DEFAULT_INPUT)
    wait_for_response_s = float(
        os.environ.get("CHAU7_SMOKE_WAIT_FOR_RESPONSE_SECONDS", DEFAULT_WAIT_FOR_RESPONSE_SECONDS)
    )

    client = MCPClient(socket_path)
    try:
        client.initialize()

        print("1. Creating tab...")
        created = client.call_tool("tab_create", {"directory": directory})
        tab_id = created.get("tab_id")
        if not isinstance(tab_id, str) or not tab_id:
            raise RuntimeError(f"tab_create returned no tab_id: {created!r}")
        print(json.dumps(created, indent=2, sort_keys=True))

        print("2. Waiting 2 seconds...")
        time.sleep(2)

        print("3. Starting Codex...")
        exec_result = client.call_tool("tab_exec", {"tab_id": tab_id, "command": codex_command})
        print(json.dumps(exec_result, indent=2, sort_keys=True))

        print("4. Waiting 5 seconds...")
        time.sleep(5)

        print("5. Sending input...")
        send_result = client.call_tool("tab_send_input", {"tab_id": tab_id, "input": input_text})
        print(json.dumps(send_result, indent=2, sort_keys=True))

        print("6. Submitting prompt...")
        submit_result = client.call_tool("tab_submit_prompt", {"tab_id": tab_id})
        print(json.dumps(submit_result, indent=2, sort_keys=True))

        print("7. Capturing initial output...")
        initial_output = client.call_tool(
            "tab_output",
            {"tab_id": tab_id, "lines": 120, "source": "buffer", "wait_for_stable_ms": 1000},
        )
        initial_text = initial_output.get("output", "")
        print(json.dumps(initial_output, indent=2, sort_keys=True))

        print(f"8. Waiting for output change for up to {wait_for_response_s:.0f}s...")
        deadline = time.time() + wait_for_response_s
        latest_output = initial_output
        while time.time() < deadline:
            time.sleep(1)
            latest_output = client.call_tool(
                "tab_output",
                {"tab_id": tab_id, "lines": 120, "source": "buffer", "wait_for_stable_ms": 500},
            )
            latest_text = latest_output.get("output", "")
            if latest_text != initial_text:
                print("Output changed:")
                print(json.dumps(latest_output, indent=2, sort_keys=True))
                break
        else:
            print("No output change detected within timeout.")
            print(json.dumps(latest_output, indent=2, sort_keys=True))

        print("Done.")
        return 0
    finally:
        client.close()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
