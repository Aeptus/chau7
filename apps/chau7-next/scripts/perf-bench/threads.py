"""Optional libproc thread CPU attribution; counters are already nanoseconds."""

import ctypes
import time


class ThreadUsage(ctypes.Structure):
    _fields_ = (
        [(name, ctypes.c_uint64) for name in ("user", "system")]
        + [
            (name, ctypes.c_int32)
            for name in ("cpu_usage", "policy", "run_state", "flags", "sleep_time", "curpri", "priority", "maxpriority")
        ]
        + [("name", ctypes.c_char * 64)]
    )


class ThreadSampler:
    def __init__(self):
        self.lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        self.lib.proc_pidinfo.restype = ctypes.c_int

    def sample(self, pid):
        handles = (ctypes.c_uint64 * 4096)()
        size = self.lib.proc_pidinfo(pid, 6, 0, handles, ctypes.sizeof(handles))
        if size <= 0 or size >= ctypes.sizeof(handles) or size % 8:
            raise RuntimeError("thread inventory unavailable or truncated")
        rows = {}
        for handle in handles[: size // 8]:
            usage = ThreadUsage()
            count = self.lib.proc_pidinfo(pid, 5, handle, ctypes.byref(usage), ctypes.sizeof(usage))
            # A thread may exit between listing and reading; never invent zero CPU.
            if count != ctypes.sizeof(usage):
                continue
            rows[str(handle)] = {
                "name": usage.name.decode(errors="replace"),
                "cpu_s": (usage.user + usage.system) / 1e9,
            }
        return {"monotonic_s": time.monotonic(), "threads": rows}


def summarize_threads(samples):
    first, last = samples[0], samples[-1]
    elapsed = last["monotonic_s"] - first["monotonic_s"]
    result = []
    for handle, row in first["threads"].items():
        observed = [sample["threads"].get(handle) for sample in samples]
        if any(value is None or value["name"] != row["name"] for value in observed):
            continue
        counters = [value["cpu_s"] for value in observed]
        if any(right < left for left, right in zip(counters, counters[1:], strict=False)):
            continue
        cpu = (counters[-1] - counters[0]) / elapsed * 100
        if cpu <= 105:
            result.append({"opaque_handle": handle, "name": row["name"], "cpu_percent": cpu})
    return sorted(result, key=lambda row: row["cpu_percent"], reverse=True)
