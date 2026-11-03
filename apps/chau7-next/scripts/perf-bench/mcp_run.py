#!/usr/bin/env python3
"""Measure real MCP subscriptions on one owned app, with continuously drained frames."""

import argparse
import contextlib
import hashlib
import json
import os
import queue
import shutil
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from native import Sampler, summarize
from run import (
    Mcp,
    available_port_pair,
    child_proxy,
    percentile,
    prepare_home,
    validate_rendering,
)
from safety import ResourceGuard

HERE = Path(__file__).resolve().parent
MAX_FRAME = 8 * 1024 * 1024
MAX_NOTIFICATIONS = 4096


class ObservedMcp(Mcp):
    def __init__(self, *args, **kwargs):
        self.responses = queue.Queue(maxsize=8)
        self.notifications = []
        self.condition = threading.Condition()
        self.rpc_lock = threading.Lock()
        self.reader = None
        self.reader_error = None
        self.deliveries = {}
        self.closing = False
        super().__init__(*args, **kwargs)

    def read_frames(self):
        try:
            while line := self.process.stdout.readline(MAX_FRAME + 1):
                if len(line) > MAX_FRAME or not line.endswith(b"\n"):
                    raise RuntimeError("MCP frame exceeds lab limit or is incomplete")
                value = json.loads(line)
                if "id" in value:
                    self.responses.put_nowait(value)
                    continue
                if value.get("method") != "notifications/chau7.event":
                    raise RuntimeError("unexpected MCP notification")
                params = value["params"]
                identity = params["subscription_id"]
                delivery = params["delivery_seq"]
                if delivery != self.deliveries.get(identity, 0) + 1:
                    raise RuntimeError("subscription delivery sequence skipped or repeated")
                if params["subscription_health"]["dropped_notification_count"]:
                    raise RuntimeError("server dropped notifications")
                self.deliveries[identity] = delivery
                detail = params.get("payload", {}).get("detail", {})
                row = {
                    "received_monotonic_s": time.monotonic(),
                    "subscription_id": identity,
                    "delivery_seq": delivery,
                    "seq": params.get("seq"),
                    "type": params.get("type"),
                    "timer_id": detail.get("timer_id", detail.get("timer", {}).get("id")),
                    "timestamp_millis": params.get("timestamp_millis"),
                }
                with self.condition:
                    if len(self.notifications) >= MAX_NOTIFICATIONS:
                        raise RuntimeError("notification evidence limit reached")
                    self.notifications.append(row)
                    self.condition.notify_all()
            if not self.closing:
                raise RuntimeError("MCP bridge closed unexpectedly")
        except (
            OSError,
            ValueError,
            KeyError,
            TypeError,
            RuntimeError,
            queue.Full,
        ) as error:
            with self.condition:
                self.reader_error = str(error)
                self.condition.notify_all()
            with contextlib.suppress(queue.Full):
                self.responses.put_nowait(error)

    def rpc(self, method, params):
        with self.rpc_lock:
            if self.reader is None:
                self.reader = threading.Thread(target=self.read_frames, daemon=True)
                self.reader.start()
            self.check()
            self.sequence += 1
            self.send(
                {
                    "jsonrpc": "2.0",
                    "id": self.sequence,
                    "method": method,
                    "params": params,
                }
            )
            try:
                value = self.responses.get(timeout=self.timeout)
            except queue.Empty as error:
                raise TimeoutError(f"MCP timeout: {method}") from error
            if isinstance(value, Exception):
                raise value
            if value.get("id") != self.sequence:
                raise RuntimeError("unexpected MCP response id")
            if "error" in value:
                raise RuntimeError(value["error"])
            return value["result"]

    def check(self):
        if self.reader_error:
            raise RuntimeError(self.reader_error)

    def rows(self):
        with self.condition:
            self.check()
            return list(self.notifications)

    def wait_timer(self, timer_id, event_type, started):
        deadline = started + self.timeout
        with self.condition:
            while True:
                self.check()
                for row in self.notifications:
                    if row["timer_id"] == timer_id and row["type"] == event_type:
                        return (row["received_monotonic_s"] - started) * 1000
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("timer change was not delivered to the live subscription")
                self.condition.wait(remaining)

    def close(self):
        self.closing = True
        super().close()
        if self.reader:
            self.reader.join(timeout=5)
            if self.reader.is_alive():
                raise RuntimeError("MCP reader did not exit")


def subscribe(client):
    payload = client.tool("chau7_subscribe", topics=["timer-inventory"], heartbeat_interval_ms=15000)
    if not payload.get("subscription_id"):
        raise RuntimeError(f"subscription failed: {payload.get('error')}")
    return payload["subscription_id"]


def unsubscribe(client, identity):
    payload = client.tool("chau7_unsubscribe", subscription_id=identity)
    if payload.get("ok") is not True:
        raise RuntimeError("unsubscribe failed")
    return payload


def phase(name, args, pids, observer, controller, guard, result, home):
    guard.wait(args.settle, pids)
    before = observer.tool("chau7_performance_snapshot")
    samples = {role: [] for role in pids}
    row = {
        "capture_state": "incomplete",
        "samples": samples,
        "events": [],
        "rpc_ms": [],
        "before": before,
    }
    result["phases"][name] = row
    validate_rendering(name, before, 1)
    if before["startup"]["milestones"]["terminal_ready"] is None:
        raise RuntimeError("synthetic terminal startup did not finish")
    progress_dir = home / "progress"
    progress_before = {p.stem: json.loads(p.read_text()) for p in progress_dir.glob("*.json")}
    row["workload_before"] = progress_before
    if len(progress_before) != 1:
        raise RuntimeError("expected one synthetic terminal generator")
    sampler = Sampler()
    initial = len(observer.rows())
    deadline = time.monotonic() + args.measure
    next_sample = next_action = time.monotonic()
    active = None
    while time.monotonic() < deadline:
        guard.check(pids)
        observer.check()
        controller.check()
        now = time.monotonic()
        if now >= next_sample:
            for role, pid in pids.items():
                samples[role].append(sampler.sample(pid))
            next_sample = now + 1
        if name == "changes" and now >= next_action:
            started = time.monotonic()
            if active is None:
                active = subscribe(controller)
                event_type = "timer_registered"
            else:
                unsubscribe(controller, active)
                event_type = "timer_updated"
            elapsed = (time.monotonic() - started) * 1000
            timer_id = f"mcp.subscription.{active}"
            row["events"].append(
                {
                    "type": event_type,
                    "rpc_ms": elapsed,
                    "notification_ms": observer.wait_timer(timer_id, event_type, started),
                }
            )
            if event_type == "timer_updated":
                active = None
            next_action = now + 2
        elif name == "tools" and now >= next_action:
            started = time.monotonic()
            observer.tool("chau7_runtime_info")
            row["rpc_ms"].append((time.monotonic() - started) * 1000)
            next_action = now + 2
        time.sleep(
            max(
                0,
                min(
                    next_sample,
                    next_action if name in ("changes", "tools") else deadline,
                    deadline,
                )
                - time.monotonic(),
            )
        )
    if active:
        unsubscribe(controller, active)
    for role, pid in pids.items():
        samples[role].append(sampler.sample(pid))
    after = observer.tool("chau7_performance_snapshot")
    validate_rendering(name, after, 1)
    row["after"] = after
    progress_after = {p.stem: json.loads(p.read_text()) for p in progress_dir.glob("*.json")}
    row["workload_after"] = progress_after
    if progress_after.keys() != progress_before.keys():
        raise RuntimeError("synthetic terminal generator changed during capture")
    row["workload_proof"] = {
        pid: {key: progress_after[pid][key] - worker[key] for key in ("frames", "bytes")}
        for pid, worker in progress_before.items()
    }
    if any(delta for worker in row["workload_proof"].values() for delta in worker.values()):
        raise RuntimeError("terminal output continued during the MCP-only workload")
    row["notifications"] = observer.rows()[initial:]
    row["processes"] = {role: summarize(values) for role, values in samples.items()}
    row["rpc_p95_ms"] = percentile(row["rpc_ms"], 0.95)
    row["notification_p95_ms"] = percentile([e["notification_ms"] for e in row["events"]], 0.95)
    if name in ("subscribed_idle", "tools") and not any(n["type"] == "heartbeat" for n in row["notifications"]):
        raise RuntimeError("subscription heartbeat missing")
    if name == "changes" and len(row["events"]) < args.measure / 2 * 0.8:
        raise RuntimeError("controlled subscription churn missed its configured rate")
    row["capture_state"] = "complete"
    print(f"{args.label}: {name} complete", flush=True)


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def run(args, result, home, log):
    evidence = []
    guard = ResourceGuard(evidence, policy=args.resource_policy)
    result["resource_safety"] = {
        "policy": guard.policy,
        "limits": guard.limits,
        "samples": evidence,
    }
    guard.wait(60)
    phase_file = prepare_home(home, args, available_port_pair())
    env = {k: v for k, v in os.environ.items() if not k.startswith(("CHAU7_", "ANTHROPIC_", "OPENAI_"))}
    env.update(CHAU7_NEXT_HOME_ROOT=str(home), CHAU7_NEXT_ISOLATED_TEST_MODE="1")
    app = subprocess.Popen([str(args.binary)], env=env, stdout=log, stderr=log, start_new_session=True)
    clients = []
    pids = {"app": app.pid}
    result["pids"] = pids
    try:
        deadline = time.monotonic() + 60
        while True:
            sockets = list(home.glob(".chau7*/**/mcp.sock"))
            proxy = child_proxy(app)
            if sockets and proxy:
                pids["proxy"] = proxy
                break
            guard.check(pids)
            if app.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError("owned app/MCP/proxy startup failed")
            time.sleep(1)
        for role in ("observer_bridge", "controller_bridge"):
            client = ObservedMcp(args.binary.parent / "chau7-next-mcp-bridge", sockets[0], log)
            clients.append(client)
            pids[role] = client.process.pid
        observer, controller = clients
        result["runtime_info"] = observer.tool("chau7_runtime_info")
        if result["runtime_info"]["process_id"] != app.pid:
            raise RuntimeError("MCP connected to a different process")
        phase_file.write_text("active")
        guard.wait(5, pids)
        phase_file.write_text("idle")
        phase("unsubscribed_idle", args, pids, observer, controller, guard, result, home)
        identity = subscribe(observer)
        result["subscription_id"] = identity
        for name in ("subscribed_idle", "changes", "tools"):
            phase(name, args, pids, observer, controller, guard, result, home)
        started = time.monotonic()
        result["unsubscribe"] = unsubscribe(observer, identity)
        result["unsubscribe_ms"] = (time.monotonic() - started) * 1000
        stopped = len(observer.rows())
        phase("recovery", args, pids, observer, controller, guard, result, home)
        if len(observer.rows()) != stopped:
            raise RuntimeError("notification arrived after completed unsubscribe")
    finally:
        cleanup_errors = []
        for client in reversed(clients):
            try:
                client.close()
            except (
                OSError,
                ValueError,
                RuntimeError,
                subprocess.SubprocessError,
            ) as error:
                cleanup_errors.append(str(error))
        if app.poll() is None:
            app.terminate()
        try:
            app.wait(timeout=15)
        finally:
            deadline = time.monotonic() + 6
            while any(alive(pid) for pid in pids.values()) and time.monotonic() < deadline:
                time.sleep(0.2)
            result["owned_cleanup"] = {role: {"pid": pid, "exited": not alive(pid)} for role, pid in pids.items()}
            result["cleanup_errors"] = cleanup_errors
        if cleanup_errors or not all(r["exited"] for r in result["owned_cleanup"].values()):
            raise RuntimeError("owned fixture cleanup incomplete")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("label")
    parser.add_argument("--results", required=True, type=Path)
    parser.add_argument("--measure", type=float, default=20)
    parser.add_argument("--settle", type=float, default=3)
    parser.add_argument(
        "--resource-policy",
        choices=("strict-host", "owned-budget"),
        default="strict-host",
    )
    args = parser.parse_args()
    if args.measure < 20 or args.settle < 0 or Path(args.label).name != args.label:
        parser.error("measure must be >=20 seconds; settle >=0; label must be a filename")
    args.binary = args.binary.resolve(strict=True)
    args.python, args.hz, args.font = os.sys.executable, 3, 12
    args.results.mkdir(parents=True, exist_ok=True)
    destination = args.results / f"{args.label}.json"
    if destination.exists():
        parser.error("result exists; choose a fresh label")
    result = {
        "schema_version": 1,
        "label": args.label,
        "status": "incomplete",
        "phases": {},
        "arguments": {k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
        "binary_sha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(),
        "helper_sha256": {
            name: hashlib.sha256((args.binary.parent / name).read_bytes()).hexdigest()
            for name in ("chau7-next-mcp-bridge", "chau7-proxy")
        },
        "harness_sha256": {
            name: hashlib.sha256((HERE / name).read_bytes()).hexdigest()
            for name in (
                "mcp_run.py",
                "run.py",
                "tui.py",
                "native.py",
                "threads.py",
                "safety.py",
            )
        },
    }
    home = Path(tempfile.mkdtemp(prefix="c7mcp-", dir="/tmp"))
    try:
        with (args.results / f"{args.label}.log").open("w") as log:
            run(args, result, home, log)
        result["status"] = "complete"
        shutil.rmtree(home)
    except Exception as error:
        result["error"] = str(error)
        result["failed_profile"] = str(home)
        raise
    finally:
        destination.write_text(json.dumps(result, indent=2) + "\n")
        print(f"saved {destination}", flush=True)


if __name__ == "__main__":
    main()
