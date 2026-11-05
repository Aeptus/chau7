import hashlib
import json
import os
import select
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from diagnose import capture, retain_hangs, symbolicate
from run import BRIDGE_CLOSE_TIMEOUT, Mcp


class SymbolicationTests(unittest.TestCase):
    symbols = b"0000000100000000 T __mh_execute_header\n0000000100000100 t _font_catalog\n0000000100000200 t _next\n"
    sample = """    + 60 ???  (in Chau7)  load address 0x104000000 + 0x120  [0x104000120]
Binary Images:
       0x104000000 - 0x104010000 +Chau7 (0.6 - 1) <12345678-1234-1234-1234-123456789ABC> /Applications/Chau7.app/Contents/MacOS/Chau7
"""

    def receipt(self):
        return {
            "appExecutable": "Chau7",
            "rustSymbols": {
                "format": "apple-nm",
                "uuid": "12345678-1234-1234-1234-123456789abc",
                "sha256": hashlib.sha256(self.symbols).hexdigest(),
            },
        }

    def test_uses_unslid_image_address_and_preserves_original_stack(self):
        text, count = symbolicate(self.sample, self.receipt(), self.symbols)
        self.assertEqual(count, 1)
        self.assertIn("=> _font_catalog + 32 [nearest text symbol]", text)
        self.assertIn("[0x104000120]", text)

    def test_rejects_wrong_build_or_modified_symbols(self):
        receipt = self.receipt()
        receipt["rustSymbols"]["uuid"] = "wrong-build"
        with self.assertRaisesRegex(ValueError, "UUID"):
            symbolicate(self.sample, receipt, self.symbols)
        with self.assertRaisesRegex(ValueError, "hash"):
            symbolicate(self.sample, self.receipt(), self.symbols + b"\n")

    def test_rejects_missing_image_and_duplicate_image(self):
        for sample in (self.sample.split("Binary Images:")[0], self.sample + self.sample):
            with self.assertRaisesRegex(ValueError, "UUID"):
                symbolicate(sample, self.receipt(), self.symbols)


class CaptureTests(unittest.TestCase):
    def test_failed_handshake_reaps_only_its_bridge(self):
        process = Mock()
        with (
            patch("run.subprocess.Popen", return_value=process),
            patch.object(Mcp, "rpc", side_effect=TimeoutError("blocked")),
            self.assertRaises(TimeoutError),
        ):
            Mcp("owned-bridge", "socket", None)
        process.kill.assert_called_once_with()
        process.wait.assert_called_once_with(timeout=BRIDGE_CLOSE_TIMEOUT)
        process.stdin.close.assert_called_once_with()
        process.stdout.close.assert_called_once_with()

    @unittest.skipUnless(os.name == "posix", "requires POSIX signals")
    def test_close_reaps_a_real_bridge_that_ignores_eof_and_termination(self):
        client = object.__new__(Mcp)
        client.process = subprocess.Popen(
            [
                sys.executable,
                "-c",
                (
                    "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                    "print('ready',flush=True); time.sleep(60)"
                ),
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        try:
            self.assertTrue(select.select([client.process.stdout], [], [], 5)[0])
            self.assertEqual(client.process.stdout.readline(), b"ready\n")
            with patch("run.BRIDGE_CLOSE_TIMEOUT", 0.1):
                client.close()
                client.close()
            self.assertIsNotNone(client.process.poll())
            self.assertTrue(client.process.stdin.closed)
            self.assertTrue(client.process.stdout.closed)
        finally:
            if client.process.poll() is None:
                client.process.kill()
                client.process.wait(timeout=5)
            client.process.stdin.close()
            client.process.stdout.close()

    def test_interruption_retains_partial_evidence_and_closes_bridge(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            args = SimpleNamespace(
                output_parent=root,
                app=root,
                socket=root / "s",
                hangs=root,
                pid=42,
                seconds=1,
                interval=0.1,
                stack_seconds=0,
            )
            sampler = Mock()
            sampler.sample.return_value = {"pid": 42, "start_ticks": 1}
            bridge = Mock()
            bridge.close.return_value = None
            bridge.tool.return_value = {"process_id": 42, "launch_time": 10}
            with (
                patch("diagnose.Mcp", return_value=bridge),
                patch("diagnose.Sampler", return_value=sampler),
                patch("diagnose.host_sample", return_value={}),
                patch("diagnose.time.sleep", side_effect=KeyboardInterrupt),
            ):
                self.assertEqual(capture(args), 130)
            data = json.loads(next(root.glob("*/capture.json")).read_text())
            self.assertEqual(data["status"], "partial")
            self.assertEqual(len(data["samples"]), 1)
            self.assertIn("interrupted", str(data["errors"]))
            bridge.close.assert_called_once_with()

    def test_retains_only_matching_launch(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            output = root / "out"
            output.mkdir()
            for n, launch in enumerate(["old", "current"]):
                path = root / f"hang-{n}-pid-42.json"
                path.write_text(json.dumps({"heartbeat_before_capture": {"launch_id": launch}}))
                path.with_suffix(".sample.txt").write_text("stack")
            self.assertEqual(retain_hangs(root, output, 42, "current"), ["hang-1-pid-42.json"])
            self.assertEqual(len(list(output.iterdir())), 2)

    def test_mcp_failure_preserves_native_samples_and_partial_status(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            args = SimpleNamespace(
                output_parent=root,
                app=root,
                socket=root / "s",
                hangs=root,
                pid=42,
                seconds=0.002,
                interval=0.001,
                stack_seconds=0,
            )
            sampler = Mock()
            sampler.sample.return_value = {"pid": 42, "start_ticks": 1}
            with (
                patch("diagnose.Mcp", side_effect=TimeoutError("main thread stalled")),
                patch("diagnose.Sampler", return_value=sampler),
                patch("diagnose.summarize", return_value={"cpu_percent": 5}),
                patch("diagnose.host_sample", return_value={"load_average": [1, 1, 1]}),
            ):
                self.assertEqual(capture(args), 1)
            report = next(root.glob("*/capture.json"))
            data = json.loads(report.read_text())
            self.assertEqual(data["status"], "partial")
            self.assertGreaterEqual(len(data["samples"]), 2)
            self.assertEqual(data["native_summary"]["cpu_percent"], 5)
            self.assertIn("main thread stalled", str(data["errors"]))
            self.assertEqual(report.parent.stat().st_mode & 0o777, 0o700)


if __name__ == "__main__":
    unittest.main()
