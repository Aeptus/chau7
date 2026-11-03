import copy
import json
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from compare import load_runs, signature
from run import HERE, measure_phase, validate_rendering


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
