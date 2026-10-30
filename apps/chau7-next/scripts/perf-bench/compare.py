#!/usr/bin/env python3
"""Compare repeated, compatible performance runs and enforce explicit budgets."""

import argparse
import json
import statistics
from pathlib import Path

from run import validate_rendering

METRICS = ("cpu_percent", "interrupt_wakeups_per_s", "footprint_peak_bytes")


def load_runs(paths):
    runs = [json.loads(path.read_text()) for path in paths]
    if len(runs) < 2:
        raise ValueError("at least two repeat runs per build are required")
    for run in runs:
        if run["status"] != "complete" or run["schema_version"] != 2:
            raise ValueError("only complete v2 runs can be compared")
        for phase, row in run["phases"].items():
            validate_rendering(phase, row["last_snapshot"], run["arguments"]["tabs"] + 1)
    if len({run["binary_sha256"] for run in runs}) != 1:
        raise ValueError("a repeat group contains different app binaries")
    if any(run["helper_sha256"] != runs[0]["helper_sha256"] for run in runs):
        raise ValueError("a repeat group contains different helper binaries")
    return runs


def signature(run):
    args = {k: v for k, v in run["arguments"].items() if k not in ("binary", "label", "results", "python")}
    grids = {
        phase: sorted(
            (t["memory"]["grid_cols"], t["memory"]["grid_rows"], t["selected"])
            for t in row["last_snapshot"]["terminals"]
        )
        for phase, row in run["phases"].items()
    }
    return args, grids, run["host"]["platform"], run["host"]["logical_cpus"], run.get("harness_sha256")


def compare(baselines, candidates):
    expected = signature(baselines[0])
    if any(signature(run) != expected for run in baselines + candidates):
        raise ValueError("workload, terminal geometry or host differs between runs")
    findings = []
    rows = {}
    for phase in baselines[0]["phases"]:
        rows[phase] = {}
        for role in ("app", "mcp_bridge", "proxy"):
            rows[phase][role] = {}
            for metric in METRICS:
                left = [r["phases"][phase]["processes"][role][metric] for r in baselines]
                right = [r["phases"][phase]["processes"][role][metric] for r in candidates]
                before, after = statistics.median(left), statistics.median(right)
                rows[phase][role][metric] = {
                    "baseline_median": before,
                    "candidate_median": after,
                    "baseline_range": [min(left), max(left)],
                    "candidate_range": [min(right), max(right)],
                    "change_percent": (after / before - 1) * 100 if before else None,
                }
                noise = {
                    "cpu_percent": {"app": 0.2, "mcp_bridge": 0.03, "proxy": 0.05}[role],
                    "interrupt_wakeups_per_s": {
                        "app": 5,
                        "mcp_bridge": 0.5,
                        "proxy": 1,
                    }[role],
                    "footprint_peak_bytes": 2 * 1024**2,
                }[metric]
                tolerance = 1.05 if metric == "footprint_peak_bytes" else 1.10
                if after > before * tolerance + noise:
                    findings.append(f"regression: {phase}/{role}/{metric}")
        # Budgets apply to every repeat, not just a favorable median.
        for run in candidates:
            processes = run["phases"][phase]["processes"]
            if phase in ("idle", "recovery"):
                for role, cpu, wakes in (
                    ("app", 1, 60),
                    ("mcp_bridge", 0.1, 1),
                    ("proxy", 0.1, 5),
                ):
                    if processes[role]["cpu_percent"] >= cpu:
                        findings.append(f"budget: {run['label']}/{phase}/{role}/cpu >= {cpu}%")
                    if processes[role]["interrupt_wakeups_per_s"] >= wakes:
                        findings.append(f"budget: {run['label']}/{phase}/{role}/wakeups >= {wakes}/s")
            if phase == "terminal" and processes["app"]["cpu_percent"] >= 10:
                findings.append(f"budget: {run['label']}/terminal/app/cpu >= 10%")
            if run["arguments"]["tabs"] == 3 and processes["app"]["footprint_peak_bytes"] >= 192 * 1024**2:
                findings.append(f"budget: {run['label']}/{phase}/app/footprint >= 192 MiB")
            requests = run["phases"][phase]["requests"]
            if phase in ("mcp", "proxy") and (not requests["count"] or requests["latency_p95_ms"] >= 10):
                findings.append(f"budget: {run['label']}/{phase}/p95 >= 10 ms or no requests")
    return {
        "accepted": not findings,
        "findings": findings,
        "baseline_labels": [r["label"] for r in baselines],
        "candidate_labels": [r["label"] for r in candidates],
        "baseline_sha256": baselines[0]["binary_sha256"],
        "candidate_sha256": candidates[0]["binary_sha256"],
        "metrics": rows,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, nargs="+", required=True)
    parser.add_argument("--candidate", type=Path, nargs="+", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = compare(load_runs(args.baseline), load_runs(args.candidate))
    with args.output.open("x") as output:
        json.dump(report, output, indent=2)
        output.write("\n")
    print("accepted" if report["accepted"] else "needs another iteration")
    for finding in report["findings"]:
        print(finding)
    raise SystemExit(0 if report["accepted"] else 1)


if __name__ == "__main__":
    main()
