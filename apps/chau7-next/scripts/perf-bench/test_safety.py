import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from run import measure_phase, run
from safety import ResourceGuard, ResourceLimit


class SafetyAcceptance(unittest.TestCase):
    def host(self, tick, **changes):
        return {
            "monotonic_s": tick,
            "memory_free_percent": 40,
            "swap_used_mib": 12000,
            "load_average": (1, 1, 1),
            "cpu_ticks": [tick, tick, tick * 8, 0],
            **changes,
        }

    def guard(self, rows):
        evidence = []
        guard = ResourceGuard(evidence, read_host=Mock(side_effect=rows))
        guard.sampler = Mock()
        return guard, evidence

    def test_high_existing_swap_is_allowed_but_new_growth_stops_and_is_retained(self):
        guard, evidence = self.guard([self.host(0), self.host(5, swap_used_mib=12257)])
        with patch("safety.time.monotonic", side_effect=[0, 5]):
            guard.check()
            with self.assertRaisesRegex(ResourceLimit, "swap grew"):
                guard.check()
        self.assertEqual(evidence[-1]["swap_growth_30s_mib"], 257)
        self.assertTrue(evidence[-1]["stop_reasons"])

    def test_memory_floor_rejects_before_launch(self):
        guard, evidence = self.guard([self.host(0, memory_free_percent=24)])
        with self.assertRaisesRegex(ResourceLimit, "memory reserve"):
            guard.check()
        self.assertEqual(len(evidence), 1)

    def test_brief_cpu_spike_is_tolerated_sustained_pressure_stops(self):
        rows = [self.host(0), self.host(5), self.host(10), self.host(15)]
        rows[1]["cpu_ticks"] = [50, 0, 5, 0]
        rows[2]["cpu_ticks"] = [100, 0, 10, 0]
        rows[3]["cpu_ticks"] = [150, 0, 15, 0]
        guard, evidence = self.guard(rows)
        with patch("safety.time.monotonic", side_effect=[0, 5, 10]):
            guard.check()
            guard.check()
            with self.assertRaisesRegex(ResourceLimit, "host CPU"):
                guard.check()
        self.assertGreater(evidence[-1]["host_cpu_percent"], 75)

    def test_fixture_cpu_and_wakeup_caps_use_owned_native_deltas(self):
        guard, evidence = self.guard([self.host(t) for t in [0, 5, 10]])

        def sample(pid):
            t = len(evidence) * 5
            return {
                "pid": pid,
                "monotonic_s": t,
                "start_ticks": 1,
                "cpu_s": t,
                "interrupt_wakeups": t * 300,
                "package_wakeups": 0,
                "rss": 1024,
                "footprint": 2048,
                "pageins": 0,
                "read_bytes": 0,
                "write_bytes": 0,
            }

        guard.sampler.sample.side_effect = sample
        with patch("safety.time.monotonic", side_effect=[0, 5, 10]):
            guard.check({"app": 123})
            guard.check({"app": 123})
            with self.assertRaisesRegex(ResourceLimit, "fixture CPU.*fixture wakeups"):
                guard.check({"app": 123})
        self.assertEqual(guard.sampler.sample.call_args.args, (123,))

    def test_native_identity_change_is_a_failure(self):
        guard, evidence = self.guard([self.host(0), self.host(5)])
        first = {"pid": 123, "monotonic_s": 0, "start_ticks": 1, "footprint": 1}
        second = {**first, "start_ticks": 2, "monotonic_s": 5}
        guard.sampler.sample.side_effect = [first, second]
        with patch("safety.time.monotonic", side_effect=[0, 5]):
            guard.check({"app": 123})
            with self.assertRaisesRegex(ValueError, "identity changed"):
                guard.check({"app": 123})

    def test_bridge_cleanup_failure_still_terminates_owned_fixture(self):

        app = Mock(pid=123)
        app.poll.return_value = None
        mcp = Mock()
        mcp.tool.side_effect = [{"process_id": 123}, RuntimeError("snapshot failed")]
        mcp.close.side_effect = RuntimeError("bridge cleanup failed")
        home = Mock()
        home.glob.return_value = [Path("owned.sock")]
        args = SimpleNamespace(binary=Path("/owned/app"), tabs=0, warmup=5)
        with (
            patch("run.ResourceGuard"),
            patch("run.available_port_pair"),
            patch("run.prepare_home"),
            patch("run.child_proxy", return_value=456),
            patch("run.subprocess.Popen", return_value=app),
            patch("run.Mcp", return_value=mcp),
            self.assertRaisesRegex(RuntimeError, "bridge cleanup failed"),
        ):
            run(args, {}, home, Mock())
        app.terminate.assert_called_once()
        app.wait.assert_called_once_with(timeout=15)

    def test_pressure_abort_retains_partial_phase_and_raw_samples(self):

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "progress").mkdir()
            (root / "progress" / "1.json").write_text('{"frames":0,"bytes":0}')
            guard = Mock()
            guard.check.side_effect = ResourceLimit("reserve exhausted")
            mcp = Mock()
            mcp.tool.return_value = {"owned": True}
            sampler = Mock()
            sampler.sample.return_value = {"pid": 123}
            phases = {}
            args = SimpleNamespace(settle=0, tabs=0, threads=False, measure=30, interval=1)
            with self.assertRaisesRegex(ResourceLimit, "reserve exhausted"):
                measure_phase(
                    "idle",
                    args,
                    {"app": 123},
                    mcp,
                    root / "phase",
                    0,
                    sampler,
                    phases,
                    guard,
                )
            self.assertEqual(phases["idle"]["capture_state"], "incomplete")
            self.assertEqual(phases["idle"]["samples"]["app"], [{"pid": 123}])


if __name__ == "__main__":
    unittest.main()
