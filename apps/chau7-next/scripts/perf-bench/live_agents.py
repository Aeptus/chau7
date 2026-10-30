#!/usr/bin/env python3
"""One-shot, user-authorized live issue work; observational, never an A/B score."""

import argparse
import hashlib
import json
import os
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from native import Sampler, summarize
from run import Mcp, available_port_pair, child_proxy


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("tasks", type=Path, help="five task groups covering six issues")
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--seconds", type=int, default=600)
    args = parser.parse_args()
    tasks = json.loads(args.tasks.read_text())
    if len(tasks) != 5 or sum(len(t["issues"]) for t in tasks) != 6:
        parser.error("exactly five task groups covering six issues are required")
    args.binary = args.binary.resolve(strict=True)
    args.results.mkdir(parents=True, exist_ok=False)
    home = Path(tempfile.mkdtemp(prefix="c7-live-agents-", dir="/tmp"))
    # CLI credentials/configuration remain under the real user HOME. Only the
    # transcript reader follows this discovery link; it reads existing logs.
    sessions = home / ".codex" / "sessions"
    sessions.parent.mkdir()
    sessions.symlink_to(Path.home() / ".codex" / "sessions", target_is_directory=True)
    port = available_port_pair()
    for relative in (".chau7-next", ".chau7/rust-v1"):
        config = home / relative
        config.mkdir(parents=True)
        (config / "config.toml").write_text(
            '[general]\nshell = "/bin/zsh"\n'
            "[next]\nmcp_max_tabs = 10\nmcp_requires_approval = false\n"
            f"api_analytics_enabled = true\napi_analytics_port = {port}\n"
        )
    result = {
        "status": "incomplete",
        "kind": "observational-live-issue-work",
        "profile": str(home),
        "started_at_unix_s": time.time(),
        "binary_sha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(),
        "script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "tasks": tasks,
        "launches": [],
        "tool_requests": [],
        "requested_model": "gpt-6-luna",
        "requested_reasoning_effort": "max",
        "samples": [],
        "snapshots": [],
    }
    stop = threading.Event()
    app = mcp = collector = None
    pids = {}
    sampler_errors = []

    def tool(name, **arguments):
        started = time.monotonic()
        succeeded = False
        try:
            value = mcp.tool(name, **arguments)
            succeeded = True
            return value
        finally:
            result["tool_requests"].append(
                {
                    "name": name,
                    "unix_s": time.time(),
                    "succeeded": succeeded,
                    "latency_ms": (time.monotonic() - started) * 1000,
                }
            )

    def sample():
        sampler = Sampler()
        while not stop.is_set():
            row = {
                "monotonic_s": time.monotonic(),
                "unix_s": time.time(),
                "load_average": os.getloadavg(),
                "processes": {},
            }
            for role, pid in list(pids.items()):
                try:
                    row["processes"][role] = sampler.sample(pid)
                except OSError as error:
                    sampler_errors.append({"role": role, "error": str(error)})
            result["samples"].append(row)
            stop.wait(1)

    try:
        with (args.results / "app.log").open("w") as log:
            env = {k: v for k, v in os.environ.items() if not k.startswith("CHAU7_")}
            env.update(CHAU7_NEXT_HOME_ROOT=str(home), CHAU7_NEXT_ISOLATED_TEST_MODE="1")
            app = subprocess.Popen([str(args.binary)], env=env, stdout=log, stderr=log, start_new_session=True)
            deadline = time.monotonic() + 60
            while True:
                sockets = list(home.glob(".chau7*/**/mcp.sock"))
                proxy = child_proxy(app)
                if sockets and proxy:
                    break
                if app.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError("owned app/MCP/proxy startup failed")
                time.sleep(0.25)
            mcp = Mcp(args.binary.parent / "chau7-next-mcp-bridge", sockets[0], log, timeout=120)
            result["runtime_info"] = tool("chau7_runtime_info")
            if result["runtime_info"]["process_id"] != app.pid:
                raise RuntimeError("MCP is not attached to the owned fixture")
            pids.update(app=app.pid, mcp_bridge=mcp.process.pid, proxy=proxy)
            result["pids"] = pids
            collector = threading.Thread(target=sample, daemon=True)
            collector.start()
            result["snapshots"].append(
                {"phase": "before-launch", "unix_s": time.time(), "performance": tool("chau7_performance_snapshot")}
            )
            command = "codex -m gpt-6-luna -c 'model_reasoning_effort=\"max\"' --search --approve-for-me"
            for index, task in enumerate(tasks):
                print(f"launching Luna Max {index + 1}/5", flush=True)
                launch = tool(
                    "agent_launch",
                    directory=task["directory"],
                    count=1,
                    agent_command=command,
                    prompt=task["prompt"],
                    ready_timeout_ms=60000,
                )
                result["launches"].append({"index": index, "unix_s": time.time(), "result": launch})
                save(args.results / "capture.json", result)
                if launch.get("launched") != 1:
                    raise RuntimeError(f"agent {index + 1} dispatch failed; see retained launch result")
                tab_id = launch["agents"][0]["tab_id"]
                tool("tab_rename", tab_id=tab_id, title=f"Perf Luna {index + 1}")
            result["all_launched_at_unix_s"] = time.time()
            deadline = time.monotonic() + args.seconds
            while True:
                result["snapshots"].append(
                    {
                        "phase": "live",
                        "unix_s": time.time(),
                        "tabs": tool("tab_list"),
                        "performance": tool("chau7_performance_snapshot"),
                        "events": tool("chau7_runtime_events", limit=100),
                    }
                )
                save(args.results / "capture.json", result)
                print(f"sampled live agents: {len(result['samples'])} native samples", flush=True)
                if time.monotonic() >= deadline:
                    break
                stop.wait(min(30, max(0, deadline - time.monotonic())))
            for launch in result["launches"]:
                tab_id = launch["result"]["agents"][0]["tab_id"]
                save(args.results / f"agent-{launch['index'] + 1}-status.json", tool("tab_status", tab_id=tab_id))
                # Owned tails stay private. Source/task contents are not exported
                # in the compact numerical evidence.
                save(
                    args.results / f"agent-{launch['index'] + 1}-tail.json",
                    tool("tab_output", tab_id=tab_id, source="pty_log", lines=40),
                )
            result["status"] = "captured"
    except Exception as error:
        result["error"] = str(error)
        raise
    finally:
        stop.set()
        if collector:
            collector.join(timeout=5)
        result["sampler_errors"] = sampler_errors
        result["processes"] = {}
        for role in pids:
            rows = [s["processes"][role] for s in result["samples"] if role in s["processes"]]
            if len(rows) > 1:
                result["processes"][role] = summarize(rows)
        save(args.results / "capture.json", result)
        if mcp:
            mcp.close()
        # The fixture/profile are deliberately retained for agent completion and
        # diagnosis. The orchestrator must close only its owned tabs/app after
        # verifying turn completion; it must never terminate in-flight issue work.
        if app:
            print(f"owned fixture retained: pid={app.pid} profile={home}", flush=True)


if __name__ == "__main__":
    main()
