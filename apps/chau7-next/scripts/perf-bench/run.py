#!/usr/bin/env python3
"""Measure one Chau7 build under a fixed AI-TUI workload, in an isolated
instance that never touches the installed app.

    run.py <binary> <label> [--tabs N] [--hz H] [--settle S] [--measure S]
                             [--font PT] [--sample S] [--results DIR]

The instance gets its own home root (CHAU7_NEXT_HOME_ROOT, isolated test mode,
own MCP socket). Its shell is the synthetic TUI (tui.py), so every tab, the
selected launch tab included, runs the workload without MCP control or
approval prompts. Two performance snapshots, `--measure` seconds apart, are
saved to <results>/<label>.json; compare runs with summary.py. `--sample`
also records a macOS `sample` of the process (use a diagnostic build for
symbols: BUILD_MODE=diagnostic, see scripts/build-mode.sh).
"""

import argparse
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent


class Mcp:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect(str(path))
        self.f = self.s.makefile("rwb")
        self.id = 0
        self.rpc(
            "initialize",
            {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "perf-driver", "version": "1"},
            },
        )
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def send(self, msg):
        self.f.write((json.dumps(msg) + "\n").encode())
        self.f.flush()

    def rpc(self, method, params):
        self.id += 1
        self.send({"jsonrpc": "2.0", "id": self.id, "method": method, "params": params})
        while True:
            line = self.f.readline()
            if not line:
                raise RuntimeError("MCP connection closed")
            msg = json.loads(line)
            if msg.get("id") == self.id:
                if "error" in msg:
                    raise RuntimeError(msg["error"])
                return msg["result"]

    def tool(self, name, **arguments):
        result = self.rpc("tools/call", {"name": name, "arguments": arguments})
        text = "".join(c.get("text", "") for c in result.get("content", []))
        try:
            return json.loads(text)
        except ValueError:
            return text


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("binary")
    p.add_argument("label")
    p.add_argument("--tabs", type=int, default=12, help="extra (hidden) tabs")
    p.add_argument("--hz", type=float, default=12.5, help="TUI panel redraws per second")
    p.add_argument("--settle", type=float, default=15)
    p.add_argument("--measure", type=float, default=60)
    p.add_argument("--font", type=float, default=6, help="smaller fonts give larger grids")
    p.add_argument("--sample", type=float, default=0, help="seconds of /usr/bin/sample")
    p.add_argument("--results", type=Path, default=Path.cwd() / "perf-results")
    return p.parse_args()


def prepare_home(args):
    # Unix socket paths must stay under 104 bytes: keep the home root short.
    home = Path("/tmp") / f"c7bench-{args.label}"
    shutil.rmtree(home, ignore_errors=True)
    (home / ".chau7-next").mkdir(parents=True)
    shell = home / "tui-shell.sh"
    shell.write_text(f'#!/bin/sh\nexec /usr/bin/python3 "{HERE / "tui.py"}" "${{CHAU7_PERF_HZ:-12.5}}" $$\n')
    shell.chmod(0o755)
    (home / ".chau7-next" / "config.toml").write_text(
        f'[general]\nshell = "{shell}"\n\n'
        f"[appearance]\nfont_size = {args.font}\n\n"
        "[next]\nmcp_max_tabs = 50\nmcp_requires_approval = false\n"
    )
    return home


def stop(app):
    if app.poll() is None:
        os.killpg(app.pid, signal.SIGTERM)
        try:
            app.wait(15)
        except subprocess.TimeoutExpired:
            os.killpg(app.pid, signal.SIGKILL)


def measure(args, app, home, log_name):
    sock_path = home / ".chau7-next" / "mcp.sock"
    deadline = time.time() + 60
    while not sock_path.exists():
        if app.poll() is not None or time.time() > deadline:
            raise SystemExit(f"app exited or no MCP socket; see {log_name}")
        time.sleep(0.5)
    time.sleep(3)
    mcp = Mcp(sock_path)
    info = mcp.tool("chau7_runtime_info")
    for _ in range(args.tabs):
        created = mcp.tool("tab_create", directory=str(home))
        if not (isinstance(created, dict) and created.get("tab_id")):
            raise SystemExit(f"tab_create failed: {created}")
        time.sleep(0.5)
    time.sleep(args.settle)
    first = mcp.tool("chau7_performance_snapshot")
    started = time.time()
    if args.sample:
        subprocess.run(
            [
                "/usr/bin/sample",
                str(app.pid),
                str(int(args.sample)),
                "-mayDie",
                "-file",
                str(args.results / f"{args.label}.sample.txt"),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    time.sleep(max(0.0, args.measure - (time.time() - started)))
    last = mcp.tool("chau7_performance_snapshot")
    return {
        "label": args.label,
        "binary": args.binary,
        "tabs": args.tabs,
        "hz": args.hz,
        "measure_s": time.time() - started,
        "runtime_info": info,
        "first": first,
        "last": last,
    }


def main():
    args = parse_args()
    home = prepare_home(args)
    args.results.mkdir(parents=True, exist_ok=True)
    env = dict(
        os.environ,
        CHAU7_NEXT_HOME_ROOT=str(home),
        CHAU7_NEXT_ISOLATED_TEST_MODE="1",
        CHAU7_PERF_HZ=str(args.hz),
    )
    log_path = args.results / f"{args.label}.stderr.log"
    # `timeout` sends SIGTERM: turn it into an exception so the instance is stopped.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))
    with open(log_path, "w") as log:
        app = subprocess.Popen(
            [args.binary],
            env=env,
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        try:
            out = measure(args, app, home, log_path)
            (args.results / f"{args.label}.json").write_text(json.dumps(out))
            print(f"saved {args.results / (args.label + '.json')}")
        finally:
            stop(app)
            shutil.rmtree(home, ignore_errors=True)


if __name__ == "__main__":
    main()
