#!/usr/bin/env python3
"""Passive diagnostics and receipt-verified symbolication of a running Chau7."""

import argparse
import bisect
import hashlib
import json
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from native import Sampler, summarize
from run import Mcp
from safety import host_sample

MAX_BYTES = 32 * 1024 * 1024


def read_bounded(path):
    with Path(path).open("rb") as stream:
        value = stream.read(MAX_BYTES + 1)
    if len(value) > MAX_BYTES:
        raise ValueError(f"diagnostic input exceeds {MAX_BYTES} bytes: {path}")
    return value


def save(path, value):
    # Retain a complete, parseable partial result if a later collection fails.
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(value, indent=2) + "\n")
    tmp.replace(path)


def attempt(result, key, operation):
    try:
        result[key] = operation()
        return result[key]
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        result.setdefault("errors", []).append({"operation": key, "error": str(error)})
        return None


def heartbeat(directory, pid):
    value = json.loads(read_bounded(directory / "main-thread-heartbeat.json"))
    if value["parent_pid"] != pid:
        raise ValueError("heartbeat belongs to another app process")
    return value


def retain_hangs(directory, output, pid, launch_id):
    kept = []
    # Retention is bounded independently of how much historical evidence exists.
    candidates = sorted(directory.glob(f"hang-*-pid-{pid}.json"), reverse=True)[:20]
    for path in candidates:
        metadata = json.loads(read_bounded(path))
        before = metadata.get("heartbeat_before_capture", {})
        if before.get("launch_id") != launch_id:
            continue
        sample = path.with_suffix(".sample.txt")
        (output / path.name).write_bytes(read_bounded(path))
        if sample.exists():
            (output / sample.name).write_bytes(read_bounded(sample))
        kept.append(path.name)
    return kept


def capture(args):
    output = Path(tempfile.mkdtemp(prefix="chau7-diagnostics-", dir=args.output_parent))
    output.chmod(0o700)
    result = {"schema_version": 1, "kind": "passive_live_diagnostic", "status": "collecting"}
    result_path = output / "capture.json"
    mcp = sample = None
    sample_log = None
    try:
        mcp = attempt(
            result,
            "bridge",
            lambda: Mcp(args.app / "Contents/MacOS/chau7-next-mcp-bridge", args.socket, subprocess.DEVNULL, timeout=3),
        )
        # A bridge instance is not JSON; only its diagnostics are persisted.
        result.pop("bridge", None)
        runtime = attempt(result, "runtime_before", lambda: mcp.tool("chau7_runtime_info")) if mcp else None
        pid = args.pid or (runtime or {}).get("process_id")
        if not isinstance(pid, int) or pid <= 0:
            raise ValueError("runtime unavailable; supply the verified running app --pid")
        if runtime and runtime.get("process_id") != pid:
            raise ValueError("--pid does not match connected Chau7 runtime")
        result["pid"] = pid
        sampler = Sampler()
        samples = [sampler.sample(pid)]
        result["samples"] = samples
        launch = attempt(result, "heartbeat_before", lambda: heartbeat(args.hangs, pid))
        if launch:
            attempt(result, "retained_hangs_before", lambda: retain_hangs(args.hangs, output, pid, launch["launch_id"]))
        if mcp:
            attempt(result, "performance_before", lambda: mcp.tool("chau7_performance_snapshot"))
        attempt(result, "host_before", host_sample)
        if args.stack_seconds:
            sample_log = (output / "sample.stderr").open("wb")
            sample = subprocess.Popen(
                ["/usr/bin/sample", str(pid), str(args.stack_seconds), "10", "-file", str(output / "live.sample.txt")],
                stdout=subprocess.DEVNULL,
                stderr=sample_log,
            )
        save(result_path, result)
        deadline = time.monotonic() + args.seconds
        with (output / "native.jsonl").open("w") as stream:
            while time.monotonic() < deadline:
                time.sleep(min(args.interval, max(0, deadline - time.monotonic())))
                row = sampler.sample(pid)
                if row["start_ticks"] != samples[0]["start_ticks"]:
                    raise ValueError("app process identity changed during capture")
                samples.append(row)
                observed = {"native": row}
                attempt(observed, "heartbeat", lambda: heartbeat(args.hangs, pid))
                stream.write(json.dumps(observed) + "\n")
                stream.flush()
        result["native_summary"] = summarize(samples)
        attempt(result, "host_after", host_sample)
        if mcp:
            attempt(result, "performance_after", lambda: mcp.tool("chau7_performance_snapshot"))
            after = attempt(result, "runtime_after", lambda: mcp.tool("chau7_runtime_info"))
            if after and (after.get("process_id"), after.get("launch_time")) != (
                (runtime or {}).get("process_id"),
                (runtime or {}).get("launch_time"),
            ):
                raise ValueError("Chau7 runtime identity changed during capture")
        if launch:
            after = heartbeat(args.hangs, pid)
            if after["launch_id"] != launch["launch_id"]:
                raise ValueError("heartbeat launch identity changed during capture")
            result["heartbeat_after"] = after
            attempt(result, "retained_hangs_after", lambda: retain_hangs(args.hangs, output, pid, launch["launch_id"]))
        result["status"] = "complete" if not result.get("errors") else "partial"
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        result["status"] = "partial"
        result.setdefault("errors", []).append({"operation": "capture", "error": str(error)})
    finally:
        if sample is not None:
            try:
                result["sample_exit_code"] = sample.wait(timeout=10)
            except subprocess.TimeoutExpired:
                # This is our sampler helper, never the target application.
                sample.kill()
                sample.wait()
                result["sample_error"] = "native sampler timed out"
                result["status"] = "partial"
            if result.get("sample_exit_code") != 0:
                result["status"] = "partial"
        if sample_log:
            sample_log.close()
        if mcp:
            attempt(result, "bridge_cleanup", mcp.close)
        if result.get("errors"):
            result["status"] = "partial"
        save(result_path, result)
    print(result_path)
    return 0 if result["status"] == "complete" else 1


def symbolicate(sample_text, receipt, symbols):
    record = receipt.get("rustSymbols") or {}
    if record.get("format") != "apple-nm":
        raise ValueError("receipt has no Apple nm symbol map; use atos with its matching dSYM")
    if hashlib.sha256(symbols).hexdigest() != record.get("sha256"):
        raise ValueError("symbol map hash does not match build receipt")
    exe = re.escape(receipt["appExecutable"])
    images = re.findall(
        r"^\s*0x[\da-f]+.*\+?" + exe + r" \([^\n]*<([\da-f-]+)>[^\n]*$", sample_text, re.MULTILINE | re.IGNORECASE
    )
    if len(images) != 1 or images[0].replace("-", "").lower() != record["uuid"].replace("-", "").lower():
        raise ValueError("sample Mach-O UUID does not match symbol receipt")
    entries = []
    image_base = None
    for line in symbols.decode().splitlines():
        match = re.match(r"^([\da-fA-F]+)\s+[tT]\s+(.+)$", line)
        if match:
            address, name = int(match[1], 16), match[2]
            if name == "__mh_execute_header":
                image_base = address
            else:
                entries.append((address, name))
    if image_base is None or not entries:
        raise ValueError("symbol map lacks image base or text symbols")
    entries.sort()
    addresses = [address for address, _ in entries]
    count = 0
    pattern = re.compile(r"\?\?\?  \(in " + exe + r"\)  load address 0x[\da-f]+ \+ 0x([\da-f]+)", re.IGNORECASE)

    def replace(match):
        nonlocal count
        address = image_base + int(match[1], 16)
        index = bisect.bisect_right(addresses, address) - 1
        if index < 0:
            return match[0]
        start, name = entries[index]
        count += 1
        return f"{match[0]} => {name} + {address - start} [nearest text symbol]"

    return pattern.sub(replace, sample_text), count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    live = commands.add_parser("capture", help="observe the existing app without input or restart")
    live.add_argument("--app", type=Path, default=Path("/Applications/Chau7.app"))
    live.add_argument("--socket", type=Path, default=Path.home() / ".chau7/rust-v1/mcp.sock")
    live.add_argument("--hangs", type=Path, default=Path.home() / ".chau7/rust-v1/reports/hangs")
    live.add_argument("--pid", type=int)
    live.add_argument("--seconds", type=float, default=15)
    live.add_argument("--interval", type=float, default=1)
    live.add_argument("--stack-seconds", type=int, default=1)
    live.add_argument("--output-parent", type=Path, default=Path(tempfile.gettempdir()))
    sym = commands.add_parser("symbolicate", help="annotate stripped frames using a verified build receipt")
    sym.add_argument("sample", type=Path)
    sym.add_argument("--receipt", type=Path, required=True)
    sym.add_argument("--symbols", type=Path, help="override a relocated receipt symbol-map path")
    sym.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "capture":
        if sys.platform != "darwin":
            parser.error("native capture requires macOS")
        if not (0 < args.seconds <= 60 and 0.25 <= args.interval <= args.seconds and 0 <= args.stack_seconds <= 5):
            parser.error("capture requires 0 < seconds <= 60, 0.25 <= interval <= seconds, 0 <= stack-seconds <= 5")
        return capture(args)
    receipt = json.loads(read_bounded(args.receipt))
    path = args.symbols or Path((receipt.get("rustSymbols") or {}).get("path", ""))
    text, count = symbolicate(read_bounded(args.sample).decode(), receipt, read_bounded(path))
    with args.output.open("x") as stream:
        stream.write(text)
    print(f"Annotated {count} frames: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
