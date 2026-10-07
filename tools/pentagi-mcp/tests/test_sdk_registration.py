from __future__ import annotations

import asyncio
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

from pentagi_mcp import server, state


class SdkRegistrationTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        self.previous_path = state.DB_PATH
        self.tmp = tempfile.TemporaryDirectory()
        state.DB_PATH = Path(self.tmp.name) / "state.db"
        state.init()

    def tearDown(self) -> None:
        state.DB_PATH = self.previous_path
        self.tmp.cleanup()

    async def test_real_sdk_registers_tools_and_preserves_argument_schema(self) -> None:
        tools = await server.mcp.list_tools()
        names = [tool.name for tool in tools]
        self.assertEqual(len(names), len(set(names)))
        self.assertIn("engagement_create", names)
        self.assertIn("engagement_list", names)
        self.assertGreater(len(names), 20)
        create = next(tool for tool in tools if tool.name == "engagement_create")
        self.assertIn("name", create.input_schema["properties"])
        self.assertIn("name", create.input_schema["required"])

    async def test_real_sdk_invokes_registered_state_tool_without_network(self) -> None:
        result = await server.mcp.call_tool("engagement_list", {"include_closed": False})
        self.assertFalse(result.is_error)
        self.assertEqual(result.structured_content, {"result": []})
        state.create_engagement(
            name="sdk-test",
            authorization_note="unit tests",
            scope_targets=["localhost"],
            scope_excludes=[],
        )
        details = await server.mcp.call_tool("engagement_get", {})
        self.assertFalse(details.is_error)
        self.assertEqual(details.structured_content["name"], "sdk-test")
        self.assertIn("sdk-test", details.content[0].text)

    async def test_stdio_entrypoint_accepts_legacy_client_and_serves_tools(
        self,
    ) -> None:
        environment = dict(os.environ)
        environment["PENTAGI_MCP_DB"] = str(Path(self.tmp.name) / "stdio.db")
        process = await asyncio.create_subprocess_exec(
            sys.executable,
            "-c",
            "from pentagi_mcp.server import main; main()",
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=environment,
        )

        async def send(message: dict) -> None:
            process.stdin.write((json.dumps(message) + "\n").encode())
            await process.stdin.drain()

        async def response(identifier: int) -> dict:
            while True:
                line = await asyncio.wait_for(process.stdout.readline(), timeout=5)
                self.assertTrue(line, "stdio server exited before replying")
                parsed = json.loads(line)
                if parsed.get("id") == identifier:
                    return parsed

        try:
            await send(
                {
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "initialize",
                    "params": {
                        "protocolVersion": "2025-06-18",
                        "capabilities": {},
                        "clientInfo": {"name": "regression", "version": "1"},
                    },
                }
            )
            initialized = await response(1)
            self.assertNotIn("error", initialized)
            self.assertEqual(initialized["result"]["protocolVersion"], "2025-06-18")
            await send({"jsonrpc": "2.0", "method": "notifications/initialized"})
            await send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
            listed = await response(2)
            self.assertIn("engagement_list", [tool["name"] for tool in listed["result"]["tools"]])
            await send(
                {
                    "jsonrpc": "2.0",
                    "id": 3,
                    "method": "tools/call",
                    "params": {
                        "name": "engagement_list",
                        "arguments": {"include_closed": False},
                    },
                }
            )
            called = await response(3)
            self.assertNotIn("error", called)
            self.assertFalse(called["result"].get("isError", False))
            self.assertEqual(called["result"]["structuredContent"], {"result": []})
        finally:
            if process.returncode is None:
                process.terminate()
            await asyncio.wait_for(process.wait(), timeout=5)
