import io
import json
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import proxy_run
from safety import ResourceLimit


class ProxyCollectorAcceptance(unittest.TestCase):
    def test_pressure_rejection_precedes_any_server_or_process(self):
        result = {}
        with (
            patch("proxy_run.ResourceGuard") as factory,
            patch("proxy_run.ThreadingHTTPServer") as server,
        ):
            guard = factory.return_value
            guard.policy = "owned-budget"
            guard.limits = {"swap_growth_30s_max_mib": 256}
            guard.wait.side_effect = ResourceLimit("swap grew")
            with self.assertRaisesRegex(ResourceLimit, "swap grew"):
                proxy_run.run(
                    SimpleNamespace(resource_policy="owned-budget"),
                    result,
                    Path("/unused"),
                    io.StringIO(),
                )
            server.assert_not_called()
            guard.wait.assert_called_once_with(60)
            self.assertEqual(result["resource_safety"]["policy"], "owned-budget")
            self.assertIs(result["resource_safety"]["samples"], factory.call_args.args[0])

    def test_large_stream_has_complete_frames_and_authoritative_usage(self):
        chunks = proxy_run.stream_chunks(65536)
        self.assertEqual(len(chunks), 19)
        for chunk in chunks:
            self.assertTrue(chunk.endswith(b"\n\n"))
            data = next(line[6:] for line in chunk.splitlines() if line.startswith(b"data: "))
            event = json.loads(data)
            if event["type"] == "content_block_delta":
                self.assertEqual(len(event["delta"]["text"]), 65536)
        self.assertGreater(sum(map(len, chunks)), 1024**2)
        self.assertEqual(json.loads(chunks[-2].split(b"data: ")[1])["usage"]["output_tokens"], 32)
