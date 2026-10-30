#!/usr/bin/env python3
"""Run interleaved baseline/candidate trials and enforce the comparison gate."""

import argparse
import json
import subprocess
import sys
from pathlib import Path

from compare import compare, load_runs
from run import HERE


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--results", type=Path, required=True, help="new directory for this iteration")
    parser.add_argument("--repeats", type=int, default=2)
    parser.add_argument("--measure", type=float, default=30)
    parser.add_argument("--settle", type=float, default=5)
    parser.add_argument("--tabs", type=int, default=3)
    args = parser.parse_args()
    if args.repeats < 2:
        parser.error("at least two repeats required")
    args.results.mkdir(parents=True, exist_ok=False)
    groups = {"baseline": [], "candidate": []}
    for repeat in range(args.repeats):
        order = ("baseline", "candidate") if repeat % 2 == 0 else ("candidate", "baseline")
        for kind in order:
            label = f"{kind}-{repeat + 1}"
            subprocess.run(
                [
                    sys.executable,
                    str(HERE / "run.py"),
                    str(getattr(args, kind)),
                    label,
                    "--results",
                    str(args.results),
                    "--tabs",
                    str(args.tabs),
                    "--measure",
                    str(args.measure),
                    "--settle",
                    str(args.settle),
                ],
                check=True,
            )
            groups[kind].append(args.results / f"{label}.json")
    report = compare(load_runs(groups["baseline"]), load_runs(groups["candidate"]))
    (args.results / "comparison.json").write_text(json.dumps(report, indent=2) + "\n")
    print("accepted" if report["accepted"] else "needs another iteration", flush=True)
    for finding in report["findings"]:
        print(finding)
    raise SystemExit(0 if report["accepted"] else 1)


if __name__ == "__main__":
    main()
