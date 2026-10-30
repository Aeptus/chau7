#!/usr/bin/env python3
"""Measure an opt-in proxy fixture forwarding real SSE to a local fake provider."""

import argparse
import hashlib
import http.client
import json
import os
import select
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from native import Sampler, summarize
from run import percentile

CHUNKS = [
    b'event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":32,"output_tokens":0}}}\n\n'
]
CHUNKS += [
    b'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"measured text "}}\n\n'
] * 16
CHUNKS += [
    b'event: message_delta\ndata: {"type":"message_delta","usage":{"output_tokens":32}}\n\n',
    b'event: message_stop\ndata: {"type":"message_stop"}\n\n',
]


class Provider(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    disable_nagle_algorithm = True

    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(sum(map(len, CHUNKS))))
        self.end_headers()
        for chunk in CHUNKS:
            self.wfile.write(chunk)
            self.wfile.flush()
            time.sleep(0.005)

    def log_message(self, *_):
        pass


def request(connection):
    body = json.dumps(
        {
            "model": "claude-perflab",
            "stream": True,
            "max_tokens": 32,
            "messages": [{"role": "user", "content": "synthetic local workload"}],
        }
    )
    started = time.monotonic()
    connection.request(
        "POST",
        "/v1/messages",
        body,
        headers={
            "Content-Type": "application/json",
            "anthropic-version": "2023-06-01",
            "X-Chau7-Tab": "perflab",
            "X-Chau7-Session": "perflab",
        },
    )
    response = connection.getresponse()
    first = response.read(1)
    first_ms = (time.monotonic() - started) * 1000
    rest = response.read()
    if response.status != 200 or first + rest != b"".join(CHUNKS):
        raise RuntimeError("proxy did not preserve the complete SSE stream")
    return first_ms, (time.monotonic() - started) * 1000


def run(args, result, directory, log):
    upstream = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    worker = threading.Thread(target=upstream.serve_forever, daemon=True)
    worker.start()
    env = {k: v for k, v in os.environ.items() if not k.startswith("CHAU7_")}
    env.update(
        CHAU7_PERF_FIXTURE="1",
        CHAU7_PERF_UPSTREAM=f"http://127.0.0.1:{upstream.server_port}",
        CHAU7_DB_PATH=str(directory / "proxy.db"),
    )
    proxy = subprocess.Popen(
        [str(args.binary), "-test.run", "^TestProxyPerformanceFixture$", "-test.timeout", "30m"],
        env=env,
        stdout=subprocess.PIPE,
        stderr=log,
    )
    connection = None
    try:
        deadline = time.monotonic() + 20
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([proxy.stdout], [], [], remaining)[0]:
                raise TimeoutError("proxy fixture startup")
            line = proxy.stdout.readline()
            if not line:
                raise RuntimeError("proxy fixture exited")
            if line.startswith(b'{"perflab_proxy"'):
                info = json.loads(line)
                break
        if info["pid"] != proxy.pid:
            raise RuntimeError("fixture PID mismatch")
        result["pid"] = proxy.pid
        connection = http.client.HTTPConnection(info["perflab_proxy"], timeout=5)
        request(connection)
        # Allow the initial task candidate and provider warm-up to finish.
        time.sleep(6)
        sampler = Sampler()
        for phase in ("idle", "streaming", "recovery"):
            print(f"{args.label}: measuring {phase}", flush=True)
            time.sleep(args.settle)
            samples, first_bytes, completions = [], [], []
            next_sample = next_request = time.monotonic()
            deadline = next_sample + args.measure
            while True:
                now = time.monotonic()
                if now >= next_sample:
                    samples.append(sampler.sample(proxy.pid))
                    next_sample = now + 1
                if now >= deadline:
                    break
                if phase == "streaming" and now >= next_request:
                    first_ms, full_ms = request(connection)
                    first_bytes.append(first_ms)
                    completions.append(full_ms)
                    next_request = now + 1 / args.request_hz
                time.sleep(
                    max(
                        0,
                        min(next_sample, next_request if phase == "streaming" else deadline, deadline)
                        - time.monotonic(),
                    )
                )
            result["phases"][phase] = {
                "process": summarize(samples),
                "samples": samples,
                "requests": len(first_bytes),
                "first_byte_p95_ms": percentile(first_bytes, 0.95),
                "completion_p95_ms": percentile(completions, 0.95),
            }
            if (
                phase == "streaming"
                and not 0.8 * args.measure * args.request_hz <= len(first_bytes) <= 1.2 * args.measure * args.request_hz
            ):
                raise RuntimeError("streaming workload missed its configured request rate")
    finally:
        if connection:
            connection.close()
        if proxy.poll() is None:
            proxy.terminate()
        proxy.wait(timeout=10)
        proxy.stdout.close()
        upstream.shutdown()
        upstream.server_close()
        worker.join(timeout=5)
    if proxy.returncode != 0:
        raise RuntimeError(f"proxy fixture shutdown failed: {proxy.returncode}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("label")
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--measure", type=float, default=30)
    parser.add_argument("--settle", type=float, default=5)
    parser.add_argument("--request-hz", type=float, default=2)
    args = parser.parse_args()
    if args.measure < 2 or args.settle < 0 or not 0 < args.request_hz <= 5 or Path(args.label).name != args.label:
        parser.error("invalid duration, rate or label")
    args.binary = args.binary.resolve(strict=True)
    args.results.mkdir(parents=True, exist_ok=True)
    destination = args.results / f"{args.label}.json"
    if destination.exists():
        parser.error("result exists")
    result = {
        "schema_version": 1,
        "label": args.label,
        "status": "incomplete",
        "phases": {},
        "binary_sha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(),
        "arguments": {k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
        "load_average": os.getloadavg(),
        "started_at_unix_s": time.time(),
    }
    try:
        with (
            tempfile.TemporaryDirectory(prefix="c7proxy-", dir="/tmp") as directory,
            (args.results / f"{args.label}.log").open("w") as log,
        ):
            run(args, result, Path(directory), log)
        result["status"] = "complete"
    except Exception as error:
        result["error"] = str(error)
        raise
    finally:
        destination.write_text(json.dumps(result, indent=2) + "\n")
        print(f"saved {destination}", flush=True)


if __name__ == "__main__":
    main()
