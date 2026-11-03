"""Conservative stop conditions for an owned fixture on a shared Mac."""

import ctypes
import os
import re
import subprocess
import time

from native import Sampler, summarize


class ResourceLimit(RuntimeError):
    pass


def host_sample():
    memory = subprocess.check_output(["memory_pressure", "-Q"], text=True, timeout=5)
    swap = subprocess.check_output(["sysctl", "vm.swapusage"], text=True, timeout=5)
    free = re.search(r"memory free percentage: (\d+)%", memory)
    used = re.search(r"used = ([\d.]+)M", swap)
    if not free or not used:
        raise ResourceLimit("host pressure counters unavailable")
    lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    lib.mach_host_self.restype = ctypes.c_uint
    ticks = (ctypes.c_uint * 4)()
    count = ctypes.c_uint(4)
    if lib.host_statistics(lib.mach_host_self(), 3, ctypes.byref(ticks), ctypes.byref(count)):
        raise ResourceLimit("host CPU counters unavailable")
    return {
        "monotonic_s": time.monotonic(),
        "memory_free_percent": int(free[1]),
        "swap_used_mib": float(used[1]),
        "load_average": os.getloadavg(),
        "cpu_ticks": list(ticks),
    }


class ResourceGuard:
    # Safety stops are deliberately wider than performance acceptance budgets.
    # Absolute swap use is not pressure evidence; new growth is.
    limits = {
        "memory_free_min_percent": 25,
        "swap_growth_30s_max_mib": 256,
        "host_cpu_max_percent": 75,
        "host_load_limit_enabled": True,
        "fixture_cpu_max_percent": 35,
        "fixture_interrupt_wakeups_max_per_s": 200,
        "fixture_footprint_max_mib": 384,
        "poll_seconds": 5,
        "sustained_samples": 2,
    }

    def __init__(self, evidence, read_host=host_sample, policy="strict-host"):
        if policy not in ("strict-host", "owned-budget"):
            raise ValueError(f"unknown resource policy: {policy}")
        self.policy = policy
        self.limits = dict(type(self).limits)
        if policy == "owned-budget":
            # Explicit operator-confirmed headroom: bound this fixture instead
            # of rejecting unrelated CPU activity. Keep pressure stops intact.
            self.limits["host_cpu_max_percent"] = None
            self.limits["host_load_limit_enabled"] = False
        self.evidence = evidence
        self.read_host = read_host
        self.sampler = Sampler()
        self.previous = {}
        self.streaks = {}
        self.last_check = float("-inf")

    def check(self, pids=None):
        if time.monotonic() - self.last_check < self.limits["poll_seconds"]:
            return
        row = self.read_host()
        self.last_check = row["monotonic_s"]
        previous_host = self.evidence[-1] if self.evidence else None
        self.evidence.append(row)  # Preserve the triggering sample, too.
        reasons = []
        if row["memory_free_percent"] < self.limits["memory_free_min_percent"]:
            reasons.append("system memory reserve below 25%")
        window = [r for r in self.evidence if row["monotonic_s"] - r["monotonic_s"] <= 30]
        row["swap_growth_30s_mib"] = row["swap_used_mib"] - min(r["swap_used_mib"] for r in window)
        if row["swap_growth_30s_mib"] > self.limits["swap_growth_30s_max_mib"]:
            reasons.append("swap grew over 256 MiB within 30 seconds")
        if self.limits["host_load_limit_enabled"] and row["load_average"][0] > (os.cpu_count() or 1):
            reasons.append("one-minute host load exceeds logical CPU count")
        sustained = {}
        if previous_host:
            deltas = [b - a for a, b in zip(previous_host["cpu_ticks"], row["cpu_ticks"], strict=True)]
            if min(deltas) < 0 or sum(deltas) <= 0:
                raise ResourceLimit("host CPU counters regressed or stopped")
            row["host_cpu_percent"] = 100 * (1 - deltas[2] / sum(deltas))
            maximum = self.limits["host_cpu_max_percent"]
            if maximum is not None:
                sustained["host CPU above 75%"] = row["host_cpu_percent"] > maximum
        current = {role: self.sampler.sample(pid) for role, pid in (pids or {}).items()}
        row["fixture_samples"] = current
        if current:
            row["fixture_footprint_mib"] = sum(s["footprint"] for s in current.values()) / 1024**2
            if row["fixture_footprint_mib"] > self.limits["fixture_footprint_max_mib"]:
                reasons.append("owned fixture footprint above 384 MiB")
            if self.previous.keys() == current.keys():
                summaries = [summarize([self.previous[k], v]) for k, v in current.items()]
                row["fixture_cpu_percent"] = sum(s["cpu_percent"] for s in summaries)
                row["fixture_interrupt_wakeups_per_s"] = sum(s["interrupt_wakeups_per_s"] for s in summaries)
                sustained["fixture CPU above 35% of one core"] = (
                    row["fixture_cpu_percent"] > self.limits["fixture_cpu_max_percent"]
                )
                sustained["fixture wakeups above 200/s"] = (
                    row["fixture_interrupt_wakeups_per_s"] > self.limits["fixture_interrupt_wakeups_max_per_s"]
                )
        self.previous = current
        for reason, exceeded in sustained.items():
            self.streaks[reason] = self.streaks.get(reason, 0) + 1 if exceeded else 0
            if self.streaks[reason] >= self.limits["sustained_samples"]:
                reasons.append(reason)
        if reasons:
            row["stop_reasons"] = reasons
            raise ResourceLimit("; ".join(reasons))

    def wait(self, seconds, pids=None):
        deadline = time.monotonic() + seconds
        while True:
            self.check(pids)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return
            time.sleep(min(1, remaining))
