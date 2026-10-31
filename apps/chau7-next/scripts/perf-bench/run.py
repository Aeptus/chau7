#!/usr/bin/env python3
"""Run fixed workloads against an owned, isolated macOS app and its helpers."""

import argparse
import hashlib
import json
import os
import platform
import select
import shlex
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request
from pathlib import Path

from native import Sampler, summarize
from safety import ResourceGuard
from threads import ThreadSampler, summarize_threads

HERE = Path(__file__).resolve().parent


class Mcp:
    def __init__(self, bridge, socket_path, log, timeout=15):
        self.process = subprocess.Popen(
            [str(bridge), "--socket", str(socket_path)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=log,
        )
        self.timeout = timeout
        self.sequence = 0
        self.buffer = b""
        self.rpc(
            "initialize",
            {
                "protocolVersion": "2025-11-25",
                "capabilities": {},
                "clientInfo": {"name": "chau7-perf-lab", "version": "2"},
            },
        )
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def send(self, value):
        self.process.stdin.write(json.dumps(value).encode() + b"\n")
        self.process.stdin.flush()

    def rpc(self, method, params):
        self.sequence += 1
        self.send({"jsonrpc": "2.0", "id": self.sequence, "method": method, "params": params})
        deadline = time.monotonic() + self.timeout
        while True:
            while b"\n" not in self.buffer:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                    raise TimeoutError(f"MCP timeout: {method}")
                chunk = os.read(self.process.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError("MCP bridge closed")
                self.buffer += chunk
                if len(self.buffer) > 8 * 1024 * 1024:
                    raise RuntimeError("MCP response exceeds lab limit")
            line, self.buffer = self.buffer.split(b"\n", 1)
            value = json.loads(line)
            if value.get("id") == self.sequence:
                if "error" in value:
                    raise RuntimeError(value["error"])
                return value["result"]

    def tool(self, name, **arguments):
        result = self.rpc("tools/call", {"name": name, "arguments": arguments})
        if result.get("isError"):
            raise RuntimeError(result)
        if "structuredContent" in result:
            return result["structuredContent"]
        return json.loads("".join(c.get("text", "") for c in result.get("content", [])))

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)
        self.process.stdout.close()


def available_port_pair():
    for _ in range(100):
        with socket.socket() as first, socket.socket() as second:
            first.bind(("127.0.0.1", 0))
            port = first.getsockname()[1]
            if port == 65535:
                continue
            try:
                second.bind(("127.0.0.1", port + 1))
            except OSError:
                continue
            return port
    raise RuntimeError("no free port pair")


def prepare_home(home, args, port):
    phase_file = home / "phase"
    phase_file.write_text("idle")
    (home / "progress").mkdir()
    shell = home / "workload.sh"
    command = " ".join(shlex.quote(str(p)) for p in (args.python, HERE / "tui.py"))
    controls = " ".join(shlex.quote(str(p)) for p in (phase_file, home / "progress"))
    shell.write_text(f"#!/bin/sh\nexec {command} {args.hz} 1 2 {controls}\n")
    shell.chmod(0o700)
    seed_channel_configs(
        home,
        f"[general]\nshell = {json.dumps(str(shell))}\n"
        f"[appearance]\nfont_size = {args.font}\n"
        "[next]\nmcp_max_tabs = 50\nmcp_requires_approval = false\n"
        f"api_analytics_enabled = true\napi_analytics_port = {port}\n",
    )
    return phase_file


def seed_channel_configs(home, content):
    # Both channels write only beneath the caller's isolated throwaway home.
    for relative in (".chau7-next", ".chau7/rust-v1"):
        config = home / relative
        config.mkdir(parents=True)
        (config / "config.toml").write_text(content)


def child_proxy(app):
    rows = subprocess.check_output(["ps", "-axo", "pid=,ppid=,comm="], text=True)
    for row in rows.splitlines():
        pid, parent, command = row.strip().split(None, 2)
        if int(parent) == app.pid and Path(command).name == "chau7-proxy":
            return int(pid)
    return None


def percentile(values, fraction):
    if not values:
        return None
    return sorted(values)[min(len(values) - 1, int((len(values) - 1) * fraction))]


def validate_rendering(name, snapshot, expected_count=None):
    if expected_count is not None and len(snapshot["terminals"]) != expected_count:
        raise RuntimeError("terminal surfaces disappeared during the workload")
    watchdog = snapshot["hang_watchdog"]
    if watchdog["stall_count"] or watchdog["render_circuit_breaker_open"]:
        raise RuntimeError("app stalled during the workload")
    selected = [t for t in snapshot["terminals"] if t["selected"] and not t["render_suspended"]]
    if not selected:
        raise RuntimeError("no selected live terminal")
    if name == "terminal":
        painted = snapshot["memory_retention"]["renderer_samples"]
        ages = {row["session_id"]: row["renderer"]["last_paint_age_seconds"] for row in painted}
        for terminal in selected:
            age = ages.get(terminal["session_id"])
            if age is None or age > 1 or not terminal["output"]["sample_count"]:
                raise RuntimeError("output was emitted but the selected terminal stopped painting")


def measure_phase(name, args, pids, mcp, phase_file, port, sampler, phases, guard=None):
    phase_file.write_text("active" if name == "terminal" else "idle")
    if guard:
        guard.wait(args.settle, pids)
    else:
        time.sleep(args.settle)
    before = mcp.tool("chau7_performance_snapshot")
    progress_dir = phase_file.parent / "progress"
    progress_before = {p.stem: json.loads(p.read_text()) for p in progress_dir.glob("*.json")}
    if len(progress_before) != args.tabs + 1:
        raise RuntimeError("not all synthetic terminals started")
    samples = {name: [] for name in pids}
    latencies = []
    thread_sampler = ThreadSampler() if args.threads else None
    thread_samples = []
    host_samples = []
    phases[name] = {
        "capture_state": "incomplete",
        "samples": samples,
        "host_samples": host_samples,
        "thread_samples": thread_samples,
        "first_snapshot": before,
    }
    deadline = time.monotonic() + args.measure
    next_sample = next_request = time.monotonic()
    count = 0
    while True:
        now = time.monotonic()
        if now >= next_sample:
            host_samples.append({"monotonic_s": now, "load_average": os.getloadavg()})
            for role, pid in pids.items():
                samples[role].append(sampler.sample(pid))
            if thread_sampler:
                thread_samples.append(thread_sampler.sample(pids["app"]))
            next_sample = now + args.interval
            if guard:
                guard.check(pids)
        if now >= deadline:
            break
        if name in ("mcp", "proxy") and now >= next_request:
            started = time.monotonic()
            if name == "mcp":
                mcp.tool("chau7_runtime_info")
            else:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/stats", timeout=5) as response:
                    if response.status != 200:
                        raise RuntimeError("proxy request failed")
                    json.load(response)
            latencies.append((time.monotonic() - started) * 1000)
            count += 1
            next_request = started + 1 / (args.mcp_hz if name == "mcp" else args.request_hz)
        time.sleep(
            max(
                0,
                min(
                    next_sample,
                    next_request if name in ("mcp", "proxy") else deadline,
                    deadline,
                )
                - time.monotonic(),
            )
        )
    after = mcp.tool("chau7_performance_snapshot")
    progress_after = {p.stem: json.loads(p.read_text()) for p in progress_dir.glob("*.json")}
    proof = {
        pid: {key: progress_after[pid][key] - worker[key] for key in ("frames", "bytes")}
        for pid, worker in progress_before.items()
    }
    row = {
        "host_samples": host_samples,
        "thread_samples": thread_samples,
        "thread_cpu": summarize_threads(thread_samples) if thread_samples else None,
        "workload_proof": proof,
        "processes": {role: summarize(rows) for role, rows in samples.items()},
        "samples": samples,
        "requests": {
            "count": count,
            "latency_p50_ms": percentile(latencies, 0.5),
            "latency_p95_ms": percentile(latencies, 0.95),
            "latency_max_ms": max(latencies, default=None),
        },
        "first_snapshot": before,
        "last_snapshot": after,
    }

    # Preserve complete phase evidence even when an acceptance check rejects it.
    phases[name] = row
    validate_rendering(name, after, args.tabs + 1)
    if name in ("mcp", "proxy"):
        target = args.measure * (args.mcp_hz if name == "mcp" else args.request_hz)
        if not 0.8 * target <= count <= 1.2 * target:
            raise RuntimeError(f"request workload missed its configured rate: {count} vs {target}")
    for row in proof.values():
        if name == "terminal":
            if not 0.8 * args.measure * args.hz <= row["frames"] <= 1.2 * args.measure * args.hz or row["bytes"] <= 0:
                raise RuntimeError(f"workload missed its configured output rate: {proof}")
        elif row["frames"] != 0 or row["bytes"] != 0:
            raise RuntimeError(f"workload did not match phase {name}: {proof}")
    return phases[name]


def run(args, result, home, log):
    result["resource_safety"] = {"limits": ResourceGuard.limits, "samples": []}
    guard = ResourceGuard(result["resource_safety"]["samples"])
    # Establish stable host pressure before starting any owned application.
    guard.wait(60)
    port = available_port_pair()
    phase_file = prepare_home(home, args, port)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("CHAU7_", "ANTHROPIC_", "OPENAI_"))}
    env.update(CHAU7_NEXT_HOME_ROOT=str(home), CHAU7_NEXT_ISOLATED_TEST_MODE="1")
    app = subprocess.Popen([str(args.binary)], env=env, stdout=log, stderr=log, start_new_session=True)
    mcp = None
    try:
        deadline = time.monotonic() + 60
        while True:
            sockets = list(home.glob(".chau7*/**/mcp.sock"))
            proxy_pid = child_proxy(app)
            if sockets and proxy_pid:
                break
            if app.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError("app exited or owned MCP/proxy did not start; inspect lab log")
            guard.check({"app": app.pid})
            time.sleep(1)
        mcp = Mcp(args.binary.parent / "chau7-next-mcp-bridge", sockets[0], log)
        result["runtime_info"] = mcp.tool("chau7_runtime_info")
        if result["runtime_info"]["process_id"] != app.pid:
            raise RuntimeError("MCP PID differs from owned app")
        for _ in range(args.tabs):
            created = mcp.tool("tab_create", directory=str(home))
            if not isinstance(created, dict) or not created.get("tab_id"):
                raise RuntimeError(f"tab_create failed: {created}")
        result["pids"] = {
            "app": app.pid,
            "mcp_bridge": mcp.process.pid,
            "proxy": proxy_pid,
        }
        # Prime every TUI before timing idle: a terminal that never produced
        # printable output is still showing its animated startup overlay.
        phase_file.write_text("active")
        guard.wait(args.warmup, result["pids"])
        phase_file.write_text("idle")
        result["warmup_snapshot"] = mcp.tool("chau7_performance_snapshot")
        if result["warmup_snapshot"]["startup"]["milestones"]["terminal_ready"] is None:
            raise RuntimeError("terminal startup did not finish during warm-up")
        sampler = Sampler()
        for phase in args.phases.split(","):
            if phase not in ("idle", "terminal", "mcp", "proxy", "recovery"):
                raise ValueError(f"unknown phase: {phase}")
            print(f"measuring {phase}", flush=True)
            result["phases"][phase] = measure_phase(
                phase, args, result["pids"], mcp, phase_file, port, sampler, result["phases"], guard
            )
    finally:
        try:
            if mcp:
                mcp.close()
        finally:
            # Even a broken bridge must not leave the owned app running.
            # Production PIDs are never accepted.
            if app.poll() is None:
                app.terminate()
                app.wait(timeout=15)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("label")
    parser.add_argument("--tabs", type=int, default=0, help="additional hidden tabs; start with one total tab")
    parser.add_argument("--hz", type=float, default=3)
    parser.add_argument(
        "--threads", action="store_true", help="diagnostic thread attribution; keep off for final trials"
    )
    parser.add_argument("--font", type=float, default=12)
    parser.add_argument("--warmup", type=float, default=5)
    parser.add_argument("--settle", type=float, default=10)
    parser.add_argument("--measure", type=float, default=30)
    parser.add_argument("--interval", type=float, default=1)
    parser.add_argument("--request-hz", type=float, default=1)
    parser.add_argument("--mcp-hz", type=float, default=0.5, help="sustainable runtime-info tool limit")
    parser.add_argument("--python", default=os.sys.executable)
    parser.add_argument("--phases", default="idle,terminal,mcp,proxy,recovery")
    parser.add_argument("--results", type=Path, default=Path("perf-results"))
    args = parser.parse_args()
    if (
        args.settle < 0
        or args.warmup < 2
        or args.measure < args.interval
        or min(args.interval, args.request_hz, args.mcp_hz, args.hz) <= 0
        or args.mcp_hz > 2
        or not 0 <= args.tabs < 40
    ):
        parser.error("positive rates and duration >= interval required; tabs must be 0..39")
    if Path(args.label).name != args.label:
        parser.error("label must be a filename")
    args.binary = args.binary.resolve(strict=True)
    args.results.mkdir(parents=True, exist_ok=True)
    destination = args.results / f"{args.label}.json"
    if destination.exists():
        parser.error("result exists; use a new label")
    result = {
        "schema_version": 2,
        "label": args.label,
        "status": "incomplete",
        "host": {
            "platform": platform.platform(),
            "logical_cpus": os.cpu_count(),
            "load_average": os.getloadavg(),
            "started_at_unix_s": time.time(),
        },
        "binary_sha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(),
        "harness_sha256": {
            name: hashlib.sha256((HERE / name).read_bytes()).hexdigest()
            for name in ("run.py", "tui.py", "native.py", "threads.py", "safety.py")
        },
        "helper_sha256": {
            name: hashlib.sha256((args.binary.parent / name).read_bytes()).hexdigest()
            for name in ("chau7-next-mcp-bridge", "chau7-proxy")
        },
        "arguments": {k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
        "phases": {},
    }
    temporary = Path(tempfile.mkdtemp(prefix="c7perf-", dir="/tmp"))
    try:
        with (args.results / f"{args.label}.log").open("w") as log:
            run(args, result, temporary, log)
        result["status"] = "complete"
        shutil.rmtree(temporary)
    except Exception as error:
        result["error"] = str(error)
        result["failed_profile"] = str(temporary)
        raise
    finally:
        destination.write_text(json.dumps(result, indent=2) + "\n")
        print(f"saved {destination}", flush=True)


if __name__ == "__main__":
    main()
