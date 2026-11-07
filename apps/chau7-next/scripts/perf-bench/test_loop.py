import copy
import json
import os
import pty
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from compare import improvement_finding, load_runs, signature, validate_target
from run import HERE, measure_phase, next_input_wakeup, validate_input_probe, validate_rendering


class WorkloadAcceptance(unittest.TestCase):
    def test_actual_worker_obeys_idle_active_recovery_controls(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            control = root / "phase"
            control.write_text("idle")
            child = subprocess.Popen(
                [
                    sys.executable,
                    str(HERE / "tui.py"),
                    "20",
                    "1",
                    "2",
                    str(control),
                    str(root),
                ],
                stdout=subprocess.DEVNULL,
            )
            try:
                path = root / f"{child.pid}.json"

                def progress_after(stamp):
                    deadline = time.monotonic() + 10
                    while time.monotonic() < deadline:
                        if path.exists():
                            row = json.loads(path.read_text())
                            if row["monotonic_s"] > stamp:
                                return row
                        if child.poll() is not None:
                            self.fail("worker exited")
                        time.sleep(0.02)
                    self.fail("worker stopped reporting progress")

                idle = progress_after(0)
                self.assertEqual(idle["frames"], 0)
                control.write_text("active")
                active = progress_after(idle["monotonic_s"])
                self.assertGreater(active["frames"], 0)
                self.assertGreater(active["bytes"], idle["bytes"])
                control.write_text("idle")
                recovered = progress_after(active["monotonic_s"])
                later = progress_after(recovered["monotonic_s"])
                self.assertEqual(later["frames"], recovered["frames"])
                self.assertEqual(later["bytes"], recovered["bytes"])
            finally:
                child.terminate()
                child.wait(timeout=5)

    def test_input_wakeup_stops_polling_when_grace_period_starts(self):
        self.assertEqual(next_input_wakeup(8, 10, 7, True), 8)
        self.assertEqual(next_input_wakeup(8, 10, 9, True), 10)
        self.assertEqual(next_input_wakeup(9, 10, 7, True), 10)
        self.assertEqual(next_input_wakeup(8, 10, 7, False), 10)

    def test_input_proof_rejects_lost_or_missing_input(self):
        validate_input_probe({"sent": 10, "received": 10}, 10)
        for probe in (
            {"sent": 10, "received": 9},
            {"sent": 0, "received": 0},
            {"sent": 2, "received": 2},
            {"sent": 12, "received": 12},
        ):
            with self.assertRaises(RuntimeError):
                validate_input_probe(probe, 10)

    def test_opt_in_worker_confirms_input_from_pty(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            control = root / "phase"
            control.write_text("active")
            master, slave = pty.openpty()
            child = subprocess.Popen(
                [sys.executable, str(HERE / "tui.py"), "3", "1", "2", str(control), str(root), "--input-probe"],
                stdin=slave,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
            os.close(slave)
            try:
                path = root / f"{child.pid}.json"
                deadline = time.monotonic() + 10
                while not path.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(path.exists(), "worker never became ready")
                os.write(master, b"x")
                while time.monotonic() < deadline:
                    if json.loads(path.read_text())["input_bytes"] == 1:
                        break
                    if child.poll() is not None:
                        self.fail("worker exited before receiving input")
                    time.sleep(0.02)
                else:
                    self.fail("worker did not confirm input")
            finally:
                child.terminate()
                child.wait(timeout=5)
                child.stderr.close()
                os.close(master)

    def test_rejected_phase_keeps_raw_capture(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "progress").mkdir()
            (root / "progress" / "1.json").write_text('{"frames":0,"bytes":0}')
            control = root / "phase"
            phases = {}
            snapshot = {"terminals": [{}], "hang_watchdog": {"stall_count": 1, "render_circuit_breaker_open": False}}
            args = SimpleNamespace(settle=0, tabs=0, threads=False, measure=0, interval=1)
            sampler = Mock()
            sampler.sample.return_value = {"pid": 1}
            mcp = Mock()
            mcp.tool.return_value = snapshot
            with (
                patch("run.summarize", return_value={"cpu_percent": 0}),
                patch("run.os.getloadavg", return_value=(3, 2, 1)),
                self.assertRaisesRegex(RuntimeError, "app stalled"),
            ):
                measure_phase("terminal", args, {"app": 1}, mcp, control, 0, sampler, phases)
            self.assertEqual(phases["terminal"]["samples"]["app"], [{"pid": 1}])
            self.assertEqual(phases["terminal"]["last_snapshot"], snapshot)
            self.assertEqual(phases["terminal"]["host_samples"][0]["load_average"], (3, 2, 1))
            self.assertGreater(phases["terminal"]["host_samples"][0]["monotonic_s"], 0)
            self.assertEqual(phases["terminal"]["workload_proof"], {"1": {"frames": 0, "bytes": 0}})

    def test_stopped_renderer_and_hang_cannot_pass_as_low_cpu(self):
        healthy = {
            "hang_watchdog": {"stall_count": 0, "render_circuit_breaker_open": False},
            "terminals": [
                {
                    "selected": True,
                    "render_suspended": False,
                    "session_id": 1,
                    "output": {"sample_count": 120},
                }
            ],
            "memory_retention": {"renderer_samples": [{"session_id": 1, "renderer": {"last_paint_age_seconds": 0.02}}]},
        }
        validate_rendering("terminal", healthy)
        with self.assertRaisesRegex(RuntimeError, "surfaces disappeared"):
            validate_rendering("terminal", healthy, expected_count=4)
        frozen = copy.deepcopy(healthy)
        frozen["memory_retention"]["renderer_samples"][0]["renderer"]["last_paint_age_seconds"] = 30
        with self.assertRaises(RuntimeError):
            validate_rendering("terminal", frozen)
        unhealthy = copy.deepcopy(healthy)
        unhealthy["hang_watchdog"]["stall_count"] = 1
        with self.assertRaises(RuntimeError):
            validate_rendering("idle", unhealthy)


class ComparisonAcceptance(unittest.TestCase):
    def test_target_is_checked_before_starting_trials(self):
        self.assertEqual(validate_target("terminal/app/cpu_percent"), ["terminal", "app", "cpu_percent"])
        for target in ("unknown/app/cpu_percent", "idle/app/not_a_metric", "idle/not_a_role/cpu_percent"):
            with self.assertRaises(ValueError):
                validate_target(target)

    def test_predeclared_target_requires_separated_improving_repeats(self):
        rows = {"terminal": {"app": {"cpu_percent": {"baseline_range": [2.0, 3.0], "candidate_range": [1.0, 1.9]}}}}
        self.assertIsNone(improvement_finding(rows, "terminal/app/cpu_percent"))
        rows["terminal"]["app"]["cpu_percent"]["candidate_range"] = [1.0, 2.0]
        self.assertIn("no repeatable improvement", improvement_finding(rows, "terminal/app/cpu_percent"))
        rows["terminal"]["app"]["cpu_percent"]["candidate_range"] = [3.1, 4.0]
        self.assertIn("no repeatable improvement", improvement_finding(rows, "terminal/app/cpu_percent"))
        with self.assertRaises(ValueError):
            improvement_finding(rows, "terminal/app/not-a-metric")
        with self.assertRaises(ValueError):
            improvement_finding(rows, "bad-target")

    def test_incomplete_or_mixed_binaries_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = [Path(directory) / str(n) for n in range(2)]
            row = {
                "schema_version": 2,
                "status": "incomplete",
                "phases": {},
                "binary_sha256": "a",
                "helper_sha256": {},
            }
            for path in paths:
                path.write_text(json.dumps(row))
            with self.assertRaises(ValueError):
                load_runs(paths)
            row["status"] = "complete"
            paths[0].write_text(json.dumps(row))
            row["binary_sha256"] = "b"
            paths[1].write_text(json.dumps(row))
            with self.assertRaises(ValueError):
                load_runs(paths)

    def test_changed_workload_and_geometry_change_signature(self):
        row = {
            "arguments": {"tabs": 3, "binary": "baseline"},
            "host": {"platform": "mac", "logical_cpus": 10},
            "phases": {
                "idle": {
                    "last_snapshot": {
                        "terminals": [
                            {
                                "selected": True,
                                "memory": {"grid_cols": 80, "grid_rows": 24},
                            }
                        ]
                    }
                }
            },
        }
        candidate = copy.deepcopy(row)
        candidate["arguments"]["binary"] = "candidate"
        self.assertEqual(signature(row), signature(candidate))
        candidate["arguments"]["tabs"] = 0
        self.assertNotEqual(signature(row), signature(candidate))
        candidate = copy.deepcopy(row)
        candidate["phases"]["idle"]["last_snapshot"]["terminals"][0]["memory"]["grid_rows"] = 48
        self.assertNotEqual(signature(row), signature(candidate))


if __name__ == "__main__":
    unittest.main()
