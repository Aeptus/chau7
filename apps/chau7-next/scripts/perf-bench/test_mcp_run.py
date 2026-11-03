"""Validate subscription evidence capture without launching a native fixture."""

import io
import json
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import mcp_run


def notification(sequence, identity="sub_test"):
    return {
        "jsonrpc": "2.0",
        "method": "notifications/chau7.event",
        "params": {
            "subscription_id": identity,
            "delivery_seq": sequence,
            "seq": sequence,
            "type": "timer_registered",
            "payload": {"detail": {"timer": {"id": "owned-timer"}}},
            "subscription_health": {"dropped_notification_count": 0},
        },
    }


def client_with_frames(frames):
    with patch.object(mcp_run.Mcp, "__init__", return_value=None):
        client = mcp_run.ObservedMcp()
    client.process = SimpleNamespace(stdout=io.BytesIO(b"".join(json.dumps(v).encode() + b"\n" for v in frames)))
    client.timeout = 1
    client.closing = True
    return client


class McpCaptureTests(unittest.TestCase):
    def test_drains_interleaved_notifications_and_response_without_rpc_polling(self):
        response = {"jsonrpc": "2.0", "id": 1, "result": {"ok": True}}
        client = client_with_frames([notification(1), response, notification(2)])
        client.read_frames()
        self.assertIsNone(client.reader_error)
        self.assertEqual(client.responses.get_nowait(), response)
        self.assertEqual([r["delivery_seq"] for r in client.rows()], [1, 2])
        self.assertEqual(client.rows()[0]["timer_id"], "owned-timer")
        self.assertGreaterEqual(client.wait_timer("owned-timer", "timer_registered", 0), 0)

    def test_gaps_duplicates_drops_and_evidence_overflow_fail_explicitly(self):
        dropped = notification(1)
        dropped["params"]["subscription_health"]["dropped_notification_count"] = 1
        cases = [
            ([notification(2)], "sequence"),
            ([notification(1), notification(1)], "sequence"),
            ([dropped], "dropped"),
            ([notification(i) for i in range(1, 4)], "limit"),
        ]
        for frames, expected in cases:
            with (
                self.subTest(expected=expected),
                patch.object(mcp_run, "MAX_NOTIFICATIONS", 2),
            ):
                client = client_with_frames(frames)
                client.read_frames()
                self.assertIn(expected, client.reader_error)

    def test_new_subscriptions_restart_delivery_sequence_independently(self):
        client = client_with_frames([notification(1, "a"), notification(1, "b"), notification(2, "a")])
        client.read_frames()
        self.assertIsNone(client.reader_error)
        self.assertEqual(len(client.rows()), 3)

    def test_pressure_rejection_precedes_app_or_bridge_launch(self):
        result = {}
        args = SimpleNamespace(resource_policy="owned-budget")
        with (
            patch.object(mcp_run, "ResourceGuard") as guard,
            patch.object(mcp_run.subprocess, "Popen") as launch,
        ):
            guard.return_value.wait.side_effect = RuntimeError("pressure rejected")
            with self.assertRaisesRegex(RuntimeError, "pressure rejected"):
                mcp_run.run(args, result, None, None)
            launch.assert_not_called()
        self.assertIn("resource_safety", result)


if __name__ == "__main__":
    unittest.main()
