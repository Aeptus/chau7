import ctypes
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

from threads import ThreadSampler, ThreadUsage


@unittest.skipUnless(sys.platform == "darwin", "macOS thread counters")
class ThreadAcceptance(unittest.TestCase):
    def test_thread_abi_matches_sdk(self):
        source = """#include <sys/types.h>
#include <sys/proc_info.h>
#include <stddef.h>
#include <stdio.h>
int main(void) { printf("%zu %zu\\n", sizeof(struct proc_threadinfo),
 offsetof(struct proc_threadinfo, pth_name)); }
"""
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "layout"
            subprocess.run(["clang", "-x", "c", "-", "-o", str(binary)], input=source, text=True, check=True)
            actual = subprocess.check_output([str(binary)], text=True).strip()
        self.assertEqual(actual, f"{ctypes.sizeof(ThreadUsage)} {ThreadUsage.name.offset}")

    def test_thread_cpu_is_nanoseconds_and_opaque_handle_lookup_works(self):
        ready, start, finished, release = (threading.Event() for _ in range(4))
        measured = []

        def work():
            lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
            lib.pthread_setname_np(b"perflab-unit")
            ready.set()
            start.wait(timeout=10)
            before = time.thread_time()
            while time.thread_time() - before < 0.15:
                pass
            measured.append(time.thread_time() - before)
            finished.set()
            release.wait(timeout=10)

        child = threading.Thread(target=work)
        child.start()
        try:
            self.assertTrue(ready.wait(timeout=10))
            sampler = ThreadSampler()
            before = sampler.sample(os.getpid())["threads"]
            start.set()
            self.assertTrue(finished.wait(timeout=10))
            after = sampler.sample(os.getpid())["threads"]
            handle = next(k for k, row in before.items() if row["name"] == "perflab-unit")
            self.assertEqual(after[handle]["name"], "perflab-unit")
            self.assertAlmostEqual(after[handle]["cpu_s"] - before[handle]["cpu_s"], measured[0], delta=0.02)
        finally:
            start.set()
            release.set()
            child.join(timeout=10)


if __name__ == "__main__":
    unittest.main()
