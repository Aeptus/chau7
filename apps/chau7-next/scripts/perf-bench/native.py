"""macOS app-PID counters. Child counters are deliberately excluded."""

import ctypes
import time


class Usage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64)
        for name in [
            "user",
            "system",
            "package_wakeups",
            "interrupt_wakeups",
            "pageins",
            "wired",
            "rss",
            "footprint",
            "start",
            "exit",
            "child_user",
            "child_system",
            "child_package",
            "child_interrupt",
            "child_pageins",
            "child_elapsed",
            "read_bytes",
            "write_bytes",
            "qos_default",
            "qos_maintenance",
            "qos_background",
            "qos_utility",
            "qos_legacy",
            "qos_initiated",
            "qos_interactive",
            "billed_system",
            "serviced_system",
            "logical_writes",
            "max_footprint",
            "instructions",
            "cycles",
            "billed_energy",
            "serviced_energy",
            "interval_max_footprint",
            "runnable",
        ]
    ]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


class Sampler:
    def __init__(self):
        self.lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        self.lib.proc_pid_rusage.restype = ctypes.c_int
        system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        tb = Timebase()
        if system.mach_timebase_info(ctypes.byref(tb)) != 0 or not tb.denom:
            raise RuntimeError("mach_timebase_info failed")
        self.seconds_per_tick = tb.numer / tb.denom / 1e9

    def sample(self, pid):
        usage = Usage()
        if self.lib.proc_pid_rusage(pid, 4, ctypes.byref(usage)):
            raise OSError(ctypes.get_errno(), f"proc_pid_rusage({pid})")
        return {
            "pid": pid,
            "monotonic_s": time.monotonic(),
            "start_ticks": usage.start,
            "cpu_s": (usage.user + usage.system) * self.seconds_per_tick,
            **{
                k: getattr(usage, k)
                for k in (
                    "rss",
                    "footprint",
                    "max_footprint",
                    "interrupt_wakeups",
                    "package_wakeups",
                    "pageins",
                    "read_bytes",
                    "write_bytes",
                )
            },
        }


def summarize(samples):
    if len(samples) < 2:
        raise ValueError("at least two samples required")
    first, last = samples[0], samples[-1]
    if any(s["start_ticks"] != first["start_ticks"] or s["pid"] != first["pid"] for s in samples):
        raise ValueError("process identity changed")
    elapsed = last["monotonic_s"] - first["monotonic_s"]
    if elapsed <= 0:
        raise ValueError("invalid sampling duration")
    counters = ("cpu_s", "interrupt_wakeups", "package_wakeups", "pageins", "read_bytes", "write_bytes")
    deltas = {k: last[k] - first[k] for k in counters}
    if any(v < 0 for v in deltas.values()):
        raise ValueError("native counter regressed")
    return {
        "duration_s": elapsed,
        "cpu_percent": deltas["cpu_s"] / elapsed * 100,
        "interrupt_wakeups_per_s": deltas["interrupt_wakeups"] / elapsed,
        "package_wakeups_per_s": deltas["package_wakeups"] / elapsed,
        "rss_peak_bytes": max(s["rss"] for s in samples),
        "footprint_peak_bytes": max(s["footprint"] for s in samples),
        "footprint_final_bytes": last["footprint"],
        "footprint_change_bytes": last["footprint"] - first["footprint"],
        "deltas": deltas,
    }
