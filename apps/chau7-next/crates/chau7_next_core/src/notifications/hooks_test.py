import json
import os
import pathlib
import subprocess
import tempfile
import unittest

SRC = pathlib.Path(os.environ["NEXT_TEST_SOURCE"])
TAB = "550e8400-e29b-41d4-a716-446655440000"


class Hooks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="next-hooks-fixture-")
        self.root = pathlib.Path(self.tmp.name)
        self.log = self.root / "owned" / "events.jsonl"
        self.projects = self.root / "provider" / "projects"
        self.overlay = self.root / "overlay.json"
        self.env = dict(
            os.environ,
            TERM_PROGRAM="Chau7Next",
            CHAU7_NEXT_TAB_ID=TAB,
            CHAU7_NEXT_PROJECT="/repo",
            CHAU7_TAB_ID="",
            CODEX_HOME=str(self.root / "codex"),
        )
        self.env.pop("CLAUDE_CONFIG_DIR", None)
        self.codex = self.script("codex_notify.py")
        self.claude = self.script("claude_hook.py")
        self.wrapper = self.script("claude_wrapper.py")

    def tearDown(self):
        self.tmp.cleanup()

    def script(self, name):
        source = (
            (SRC / name)
            .read_text()
            .replace('"__CHAU7_NEXT_EVENTS_FILE__"', json.dumps(str(self.log)))
            .replace('"__CHAU7_NEXT_CLAUDE_PROJECTS__"', json.dumps(str(self.projects)))
            .replace('"__CHAU7_NEXT_OVERLAY__"', json.dumps(str(self.overlay)))
        )
        out = self.root / name
        out.write_text(source)
        out.chmod(0o700)
        return out

    def run_py(self, script, *args, input=None, env=None):
        return subprocess.run(
            ["python3", str(script), *args],
            input=input,
            text=True,
            capture_output=True,
            check=False,
            env=env or self.env,
            timeout=10,
        )

    def events(self):
        return (
            [json.loads(s) for s in self.log.read_text().splitlines()]
            if self.log.exists()
            else []
        )

    def test_actual_codex_shim_captures_with_proxy_disabled_and_tls_fallback(self):
        own = self.root / "owned-bin"
        real = self.root / "real-bin"
        own.mkdir()
        real.mkdir()
        executable = self.fake()
        (real / "codex").write_bytes(executable.read_bytes())
        (real / "codex").chmod(0o700)
        wrapper = own / "codex"
        wrapper.write_text((SRC.parent / "codex_proxy_wrapper.sh").read_text())
        wrapper.chmod(0o700)
        helper = own / "chau7-next-codex-notify"
        helper.write_bytes(self.codex.read_bytes())
        helper.chmod(0o700)
        env = dict(self.env, PATH=str(own) + ":" + str(real) + ":" + os.environ["PATH"])
        for endpoint in ["", "http://untrusted:8000", "https://127.0.0.1:18091"]:
            env["CHAU7_NEXT_OPENAI_PROXY_BASE_URL"] = endpoint
            env["CHAU7_NEXT_CODEX_CA_CERTIFICATE"] = ""
            result = subprocess.run(
                [str(wrapper), "--model", "m", "literal prompt"],
                env=env,
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            args = json.loads(result.stdout)["args"]
            self.assertTrue(args[1].startswith("notify="))
            self.assertEqual(args[-3:], ["--model", "m", "literal prompt"])
        helper.unlink()
        result = subprocess.run(
            [str(wrapper), "literal prompt"],
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        self.assertEqual(json.loads(result.stdout)["args"], ["literal prompt"])

    def test_actual_claude_shim_preserves_literal_args_and_clears_legacy_stamp(self):
        own = self.root / "claude-owned-bin"
        real = self.root / "claude-real-bin"
        own.mkdir()
        real.mkdir()
        executable = self.fake()
        (real / "claude").write_bytes(executable.read_bytes())
        (real / "claude").chmod(0o700)
        wrapper = own / "claude"
        wrapper.write_text((SRC / "claude_wrapper.sh").read_text())
        wrapper.chmod(0o700)
        (own / "chau7-next-claude-wrapper.py").write_bytes(self.wrapper.read_bytes())
        self.overlay.write_text('{"hooks":{"Stop":[]}}')
        env = dict(
            self.env,
            PATH=str(own) + ":" + str(real) + ":" + os.environ["PATH"],
            CHAU7_TAB_ID="legacy-restamped",
        )
        result = subprocess.run(
            [str(wrapper), "--settings", '{"model":"custom"}', "literal $(prompt)"],
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data["legacy"], "")
        self.assertEqual(json.loads(data["args"][1])["model"], "custom")
        self.assertEqual(data["args"][-1], "literal $(prompt)")

    def test_claude_all_current_swift_hooks(self):
        mapping = {
            "UserPromptSubmit": "user_prompt",
            "PreToolUse": "tool_start",
            "PostToolUse": "tool_complete",
            "PostToolUseFailure": "tool_failed",
            "PermissionRequest": "permission_request",
            "Notification": "notification",
            "Stop": "response_complete",
            "StopFailure": "response_failed",
            "SubagentStop": "tool_complete",
            "SessionStart": "session_start",
            "SessionEnd": "session_end",
            "Elicitation": "elicitation",
        }
        for hook, kind in mapping.items():
            result = self.run_py(
                self.claude,
                input=json.dumps(
                    {
                        "hook_event_name": hook,
                        "session_id": "claude-session",
                        "transcript_path": str(self.projects / "project" / "run.jsonl"),
                        "cwd": "/repo",
                        "message": "detail",
                    }
                ),
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual(self.events()[-1]["type"], kind)
            self.assertEqual(self.events()[-1]["hook"], hook)
            self.assertEqual(self.events()[-1]["tabID"], TAB)

    def test_claude_non_next_and_invalid_identity_are_noops(self):
        for changes in [
            {"TERM_PROGRAM": "iTerm.app"},
            {"CHAU7_NEXT_TAB_ID": ""},
            {"CHAU7_NEXT_TAB_ID": "bad"},
        ]:
            env = dict(self.env, **changes)
            self.assertEqual(
                self.run_py(self.claude, input="{}", env=env).returncode, 0
            )
        self.assertFalse(self.log.exists())

    def test_foreign_transcript_and_component_neighbor_rejected(self):
        for path in [
            self.root / "codex" / "run.jsonl",
            self.projects.with_name("projects-other") / "run.jsonl",
        ]:
            self.assertEqual(
                self.run_py(
                    self.claude,
                    input=json.dumps(
                        {"hook_event_name": "Stop", "transcript_path": str(path)}
                    ),
                ).returncode,
                0,
            )
        self.assertFalse(self.log.exists())

    def test_custom_claude_config_projects(self):
        custom = self.root / "custom-claude"
        env = dict(self.env, CLAUDE_CONFIG_DIR=str(custom))
        self.run_py(
            self.claude,
            input=json.dumps(
                {
                    "hook_event_name": "Stop",
                    "transcript_path": str(custom / "projects" / "repo" / "run.jsonl"),
                }
            ),
            env=env,
        )
        self.assertEqual(len(self.events()), 1)

    def test_structured_input_bounded_and_allowlisted(self):
        payload = {
            "hook_event_name": "PreToolUse",
            "tool_name": "AskUserQuestion",
            "tool_input": {"questions": [{"text": "q", "options": ["a", "b"]}]},
        }
        self.run_py(self.claude, input=json.dumps(payload))
        self.assertEqual(self.events()[-1]["toolInput"], payload["tool_input"])
        payload["tool_input"] = {"huge": "a" * 20000}
        self.run_py(self.claude, input=json.dumps(payload))
        self.assertNotIn("toolInput", self.events()[-1])
        payload["tool_name"] = "Bash"
        payload["tool_input"] = {"command": "echo ok"}
        self.run_py(self.claude, input=json.dumps(payload))
        self.assertNotIn("toolInput", self.events()[-1])

    def test_invalid_input_and_write_error_never_block(self):
        self.assertEqual(self.run_py(self.claude, input="bad").returncode, 0)
        self.log.parent.mkdir()
        self.log.mkdir()
        self.assertEqual(self.run_py(self.claude, input="{}").returncode, 0)

    def test_permission_notification(self):
        self.run_py(
            self.claude,
            input=json.dumps(
                {"hook_event_name": "Notification", "message": "Waiting for APPROVAL"}
            ),
        )
        self.assertEqual(self.events()[0]["type"], "permission_request")

    def test_codex_current_payload_types_aliases_raw_evidence(self):
        for kind, subtype in [
            ("agent-turn-complete", None),
            ("approval-requested", "permission_prompt"),
            ("user-input-requested", "idle_prompt"),
            ("custom-type", None),
        ]:
            raw = json.dumps(
                {
                    "type": kind,
                    "thread_id": "thread-id",
                    "turn-id": "turn-3",
                    "last_assistant_message": "done detail",
                }
            )
            self.assertEqual(self.run_py(self.codex, raw).returncode, 0)
            event = self.events()[-1]
            self.assertEqual(event["rawType"], kind)
            self.assertEqual(event["sessionID"], "thread-id")
            self.assertEqual(event["turnID"], "turn-3")
            self.assertEqual(event["message"], "done detail")
            self.assertEqual(event.get("notificationType"), subtype)
            self.assertEqual(event["reliability"], "authoritative")

    def test_codex_foreign_session_no_writes(self):
        self.assertEqual(
            self.run_py(
                self.codex, "{}", env=dict(self.env, TERM_PROGRAM="Other")
            ).returncode,
            0,
        )
        self.assertFalse(self.log.exists())

    def test_codex_literal_chain_no_shell_and_bad_hook_nonblocking(self):
        resultfile = self.root / "chain.json"
        script = self.root / "chain.py"
        script.write_text(
            'import json,sys\nopen(sys.argv[1],"w").write(json.dumps(sys.argv[2:]))\n'
        )
        malicious = "$(touch " + str(self.root / "unexpected") + ")"
        raw = json.dumps({"type": "agent-turn-complete"})
        env = dict(
            self.env,
            CHAU7_NEXT_CODEX_NOTIFY_CHAIN=json.dumps(
                ["python3", str(script), str(resultfile), malicious]
            ),
        )
        self.assertEqual(self.run_py(self.codex, raw, env=env).returncode, 0)
        self.assertEqual(json.loads(resultfile.read_text()), [malicious, raw])
        self.assertFalse((self.root / "unexpected").exists())
        env = dict(self.env, CHAU7_NEXT_CODEX_NOTIFY_CHAIN='["/missing/hook"]')
        self.assertEqual(self.run_py(self.codex, raw, env=env).returncode, 0)

    def fake(self):
        p = self.root / "real-cli"
        p.write_text(
            '#!/usr/bin/env python3\nimport json,os,sys\nprint(json.dumps({"args":sys.argv[1:],"chain":os.environ.get("CHAU7_NEXT_CODEX_NOTIFY_CHAIN"),"legacy":os.environ.get("CHAU7_TAB_ID")}))\n'
        )
        p.chmod(0o700)
        return p

    def test_codex_wrap_preserves_config_bytes_and_explicit_notify_argv(self):
        config = pathlib.Path(self.env["CODEX_HOME"]) / "config.toml"
        config.parent.mkdir()
        config.write_text(
            'notify = ["third-party", "literal arg"]\n[tui]\nother = true\n'
        )
        before = config.read_bytes()
        result = self.run_py(
            self.codex,
            "--wrap",
            str(self.fake()),
            "--model",
            "m",
            "-c",
            'notify=["custom", "$(echo secret)"]',
            "--",
            "--settings",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(json.loads(data["chain"]), ["custom", "$(echo secret)"])
        self.assertEqual(data["legacy"], "")
        self.assertEqual(config.read_bytes(), before)
        self.assertEqual(data["args"][-4:], ["--model", "m", "--", "--settings"])

    def test_codex_indirect_swift_notify_chain_uses_owned_log_only(self):
        swift_log = self.root / "swift-events.jsonl"
        swift_log.write_text("existing Swift bytes\n")
        swift_before = swift_log.read_bytes()
        inherited_log = self.env.get("CHAU7_AI_EVENTS_LOG")
        indirect = self.root / "custom-notify.py"
        indirect.write_text(
            'import os,sys\nwith open(os.environ["CHAU7_AI_EVENTS_LOG"],"a") as f: f.write(sys.argv[-1]+"\\n")\n'
        )
        real = self.root / "real-notifying-cli"
        real.write_text(
            "#!/usr/bin/env python3\nimport json,os,subprocess,sys\n"
            'helper=json.loads(sys.argv[2].split("=",1)[1])[0]\n'
            'subprocess.run([helper,json.dumps({"type":"agent-turn-complete"})],check=True)\n'
        )
        real.chmod(0o700)
        result = self.run_py(
            self.codex,
            "--wrap",
            str(real),
            "-c",
            "notify=" + json.dumps(["python3", str(indirect)]),
            env=dict(self.env, CHAU7_AI_EVENTS_LOG=str(swift_log)),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(swift_log.read_bytes(), swift_before)
        self.assertEqual(len(self.events()), 2)
        self.assertEqual(self.events()[0]["tabID"], TAB)
        self.assertEqual(self.events()[1]["type"], "agent-turn-complete")
        self.assertEqual(self.env.get("CHAU7_AI_EVENTS_LOG"), inherited_log)

    def test_codex_wrap_suppresses_exact_swift_helper_command(self):
        result = self.run_py(
            self.codex,
            "--wrap",
            str(self.fake()),
            "-c",
            'notify=["python3", "/legacy/chau7-codex-notify"]',
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(json.loads(result.stdout)["chain"]), [])

    def test_codex_array_parser_handles_literal_unicode_comments_multiline(self):
        import runpy

        api = runpy.run_path(str(self.codex))
        parse = api["read_array"]
        self.assertEqual(
            parse(
                '[\n "a#b", # comment\n \'C:\\folder\\file\', "\\u00e9", "\\U0001F600",\n]'
            ),
            ["a#b", "C:\\folder\\file", "é", "😀"],
        )
        self.assertEqual(
            parse("[\"\"\"\nhello\\\n  world\"\"\", '''raw\ntext''']"),
            ["helloworld", "raw\ntext"],
        )
        for invalid in ["[123]", '["a" "b"]', '["a"', '["\\q"]']:
            self.assertRaises(ValueError, parse, invalid)

    def test_claude_wrapper_merges_explicit_settings_and_hook_arrays(self):
        self.overlay.write_text(
            json.dumps({"hooks": {"Stop": [{"hooks": [{"command": "owned-helper"}]}]}})
        )
        settings = self.root / "user.json"
        settings.write_text(
            json.dumps(
                {
                    "permissions": {"deny": ["Bash(rm *)"]},
                    "hooks": {"Stop": [{"hooks": [{"command": "third-party"}]}]},
                    "model": "custom",
                }
            )
        )
        before = settings.read_bytes()
        result = self.run_py(
            self.wrapper,
            str(self.fake()),
            "--settings",
            str(settings),
            "-p",
            "literal prompt",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads(result.stdout)["args"]
        merged = json.loads(args[1])
        self.assertEqual(merged["model"], "custom")
        self.assertEqual(merged["permissions"]["deny"], ["Bash(rm *)"])
        self.assertEqual(len(merged["hooks"]["Stop"]), 2)
        self.assertEqual(args[2:], ["-p", "literal prompt"])
        self.assertEqual(settings.read_bytes(), before)

    def test_claude_wrapper_inline_and_equals_and_admin_passthrough(self):
        self.overlay.write_text('{"hooks":{"Stop":[]}}')
        result = self.run_py(
            self.wrapper, str(self.fake()), '--settings={"model":"inline"}', "prompt"
        )
        self.assertEqual(
            json.loads(json.loads(result.stdout)["args"][1])["model"], "inline"
        )
        for args in [
            ("auth", "status"),
            ("--version",),
            ("--bare", "-p", "query"),
            ("--safe-mode",),
        ]:
            result = self.run_py(self.wrapper, str(self.fake()), *args)
            self.assertEqual(json.loads(result.stdout)["args"], list(args))

    def test_claude_wrapper_invalid_explicit_settings_fails_without_replacing(self):
        self.overlay.write_text('{"hooks":{}}')
        result = self.run_py(self.wrapper, str(self.fake()), "--settings", "{bad}")
        self.assertEqual(result.returncode, 2)
        self.assertFalse(result.stdout)


if __name__ == "__main__":
    unittest.main()
