#!/usr/bin/env python3
"""Compare saved runs: summary.py results/a.json results/b.json ..."""

import json
import sys

STAGES = [
    ("work", "window_frame", "workspace_render"),
    ("work", "terminal_view", "view_build"),
    ("work", "terminal_painter", "prepaint_snapshot"),
    ("work", "terminal_painter", "grid_paint"),
    ("work", "terminal_painter", "row_pass"),
    ("work", "terminal_painter", "row_prepare"),
    ("work", "terminal_painter", "gpu_text_submit"),
    ("work", "terminal_painter", "shape_line"),
    ("work", "session_refresh", "output_processing"),
    ("work", "session_refresh", "get_grid"),
    ("work", "session_refresh", "get_grid_shape"),
    ("work", "session_refresh", "deferred_grid_copy"),
    ("latency", "output_dispatch", "event_dispatch_wait"),
    ("latency", "output_dispatch", "event_dispatch_congestion"),
]
# Top-level main-thread stages (not nested in each other) for a busy estimate.
TOP = {
    "workspace_render",
    "view_build",
    "prepaint_snapshot",
    "grid_paint",
    "output_processing",
}


def agg(entries, kind, caller, op):
    out = {}
    for e in entries:
        if (e["kind"], e["caller"], e["operation"]) != (kind, caller, op):
            continue
        w = e.get("last_60s")
        if not w:
            continue
        a = out.setdefault(e["visibility"], {"n": 0, "ms": 0.0, "max": 0.0, "items": 0, "p95": None})
        a["n"] += w["sample_count"]
        a["ms"] += w["total_ms"]
        a["items"] += w["total_items"]
        a["max"] = max(a["max"], w["max_ms"])
        a["p95"] = w.get("p95_ms")
    return out


def summarize(path):
    with open(path) as handle:
        run = json.load(handle)
    if run.get("schema_version") == 2:
        if run["status"] != "complete":
            raise ValueError(f"incomplete run: {path}")
        rows = {}
        for phase, data in run["phases"].items():
            for role, measurements in data["processes"].items():
                for metric in ("cpu_percent", "interrupt_wakeups_per_s", "footprint_peak_bytes", "rss_peak_bytes"):
                    value = measurements[metric]
                    unit = ""
                    if metric.endswith("_bytes"):
                        value /= 1048576
                        unit = " MiB"
                    rows[f"{phase}/{role}/{metric}"] = f"{value:.3f}{unit}"
            requests = data["requests"]
            if requests["count"]:
                rows[f"{phase}/requests"] = str(requests["count"])
                rows[f"{phase}/latency_p95_ms"] = f"{requests['latency_p95_ms']:.3f}"
        return run["label"], rows
    first, last = run["first"], run["last"]
    wall = run["measure_s"]
    cpu = (last["process"]["cpu_time_seconds"] - first["process"]["cpu_time_seconds"]) / wall * 100
    entries = last["work_profile"]["entries"]
    rows = {
        "cpu % (1 core)": f"{cpu:.1f}",
        "rss MB": f"{last['process']['resident_bytes'] / 1e6:.0f}",
        "main timer delay max ms": f"{last['main_thread']['max_timer_delay_ms']:.0f}",
        "stalls": str(last["hang_watchdog"]["stall_count"]),
    }
    sel = [t for t in last.get("terminals", []) if t.get("selected")]
    if sel:
        m = sel[0]["memory"]
        rows["visible grid"] = f"{m['grid_cols']}x{m['grid_rows']}"
    busy = 0.0
    for kind, caller, op in STAGES:
        for vis, a in sorted(agg(entries, kind, caller, op).items()):
            if op in TOP:
                busy += a["ms"]
            avg = a["ms"] / a["n"] if a["n"] else 0
            extra = f" items/sample={a['items'] / a['n']:.1f}" if op in ("row_prepare", "row_pass") and a["n"] else ""
            p95 = f" p95={a['p95']:.1f}" if a["p95"] is not None else ""
            rows[f"{op} [{vis}]"] = f"n={a['n']} total={a['ms']:.0f}ms avg={avg:.2f}{p95} max={a['max']:.0f}{extra}"
    rows["main busy (top-level, ms/60s)"] = f"{busy:.0f}"
    batches = sum(a["n"] for a in agg(entries, "work", "session_refresh", "output_processing").values())
    frames = sum(a["n"] for a in agg(entries, "work", "window_frame", "workspace_render").values())
    cpu_ms = cpu / 100 * wall * 1000
    if batches:
        rows["output batches/60s"] = f"{batches}"
        rows["CPU ms per output batch"] = f"{cpu_ms / batches:.2f}"
        rows["main busy ms per batch"] = f"{busy / batches:.3f}"
        if frames:
            rows["window frames per batch"] = f"{frames / batches:.3f}"
    return run["label"], rows


runs = [summarize(p) for p in sys.argv[1:]]
keys = []
for _, rows in runs:
    for k in rows:
        if k not in keys:
            keys.append(k)
for label, rows in runs:
    print(f"\n=== {label} ===")
    for k in keys:
        if k in rows:
            print(f"  {k:42} {rows[k]}")
