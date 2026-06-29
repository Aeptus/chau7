from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest import mock

from pentagi_mcp import executor, state, tools
from pentagi_mcp.executor import ExecResult, ScopeError, parse_web_scan_output, prepare_web_target


class PentagiMcpLogicTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        state.DB_PATH = Path(self.tmp.name) / "state.db"
        state.init()
        state.create_engagement(
            name="unit",
            authorization_note="tests",
            scope_targets=["localhost", "host.docker.internal"],
            scope_excludes=[],
        )

    def test_prepare_web_target_starts_proxy_for_split_connect_host(self) -> None:
        calls: list[tuple[str, int, str, int]] = []

        def fake_proxy(listen_name: str, listen_port: int, connect_host: str, connect_port: int):
            calls.append((listen_name, listen_port, connect_host, connect_port))
            return {"status": "started", "tag": "fake"}

        with mock.patch.object(executor, "sni_proxy_start", side_effect=fake_proxy):
            target = prepare_web_target(
                "https://localhost:8443/api",
                connect_host="host.docker.internal",
                connect_port=8443,
                tls_sni="localhost",
                http_host="localhost",
            )

        self.assertEqual(target.effective_url, "https://localhost:8443/api")
        self.assertEqual(target.checked_scope, ["localhost", "host.docker.internal"])
        self.assertEqual(calls, [("localhost", 8443, "host.docker.internal", 8443)])

    def test_prepare_web_target_requires_connect_host_scope(self) -> None:
        with self.assertRaises(ScopeError):
            prepare_web_target(
                "https://localhost:8443/",
                connect_host="8.8.8.8",
                connect_port=8443,
                tls_sni="localhost",
            )

    def test_parse_web_scan_output_handles_ferox_and_gobuster(self) -> None:
        parsed = parse_web_scan_output(
            "200      GET       74l      381w     5121c Auto-filtering found 404-like response\n"
            "200      GET       17l       60w     2076c https://localhost:8443/package\n"
            "/admin (Status: 403) [Size: 123]\n"
        )

        self.assertEqual(len(parsed), 2)
        self.assertEqual(parsed[0]["status"], 200)
        self.assertEqual(parsed[0]["url"], "https://localhost:8443/package")
        self.assertEqual(parsed[1]["status"], 403)
        self.assertEqual(parsed[1]["path"], "/admin")

    def test_container_file_write_uses_base64_without_adding_newline(self) -> None:
        seen: dict[str, str] = {}

        def fake_exec(cmd: str, timeout: int | None = None, **_: object) -> ExecResult:
            seen["cmd"] = cmd
            return ExecResult(cmd=cmd, returncode=0, stdout="", stderr="")

        with mock.patch.object(tools, "docker_exec", side_effect=fake_exec):
            result = tools.container_file_write("/tmp/x", "hello\n")

        self.assertEqual(result["returncode"], 0)
        self.assertIn("base64 -d > /tmp/x", seen["cmd"])
        self.assertNotIn("hello", seen["cmd"])

    def test_exploit_search_ranking_filters_author_only_when_title_misses(self) -> None:
        raw = {
            "RESULTS_EXPLOIT": [
                {"Title": "Joomla SQL Injection", "Author": "Caddy Dz", "Path": "/x"},
                {"Title": "Caddy reverse proxy issue", "Author": "Researcher", "Path": "/y"},
            ]
        }

        with mock.patch.object(
            tools,
            "docker_exec",
            return_value=ExecResult(cmd="searchsploit", returncode=0, stdout=__import__("json").dumps(raw), stderr=""),
        ):
            result = tools.exploit_search("Caddy")

        self.assertEqual(result["results"][0]["Title"], "Caddy reverse proxy issue")
        self.assertEqual(result["results"][0]["match_reason"], "title_match")
        self.assertEqual(result["results"][1]["match_reason"], "author_match")


if __name__ == "__main__":
    unittest.main()
