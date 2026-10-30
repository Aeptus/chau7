import ctypes
import os
import resource
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

from native import Sampler, Usage, summarize


@unittest.skipUnless(sys.platform == "darwin", "macOS native acceptance")
class NativeAcceptance(unittest.TestCase):
    def test_layout_matches_installed_sdk(self):
        source = """#include <sys/resource.h>
#include <stddef.h>
#include <stdio.h>
int main(void) { printf("%zu %zu %zu\\n", sizeof(struct rusage_info_v4),
 offsetof(struct rusage_info_v4, ri_phys_footprint),
 offsetof(struct rusage_info_v4, ri_diskio_byteswritten)); }
"""
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "layout"
            subprocess.run(["clang", "-x", "c", "-", "-o", str(binary)], input=source, text=True, check=True)
            actual = subprocess.check_output([str(binary)], text=True).strip()
        self.assertEqual(actual, f"{ctypes.sizeof(Usage)} {Usage.footprint.offset} {Usage.write_bytes.offset}")

    def test_cpu_units_and_child_exclusion(self):
        sampler = Sampler()
        before = sampler.sample(os.getpid())
        usage_before = resource.getrusage(resource.RUSAGE_SELF)
        start = time.process_time()
        while time.process_time() - start < 0.15:
            pass
        after = sampler.sample(os.getpid())
        usage_after = resource.getrusage(resource.RUSAGE_SELF)
        independent = usage_after.ru_utime + usage_after.ru_stime - usage_before.ru_utime - usage_before.ru_stime
        self.assertAlmostEqual(after["cpu_s"] - before["cpu_s"], independent, delta=0.02)
        child = subprocess.Popen(
            [sys.executable, "-c", "import time; s=time.process_time();\nwhile time.process_time()-s<0.3: pass\n"],
            stdout=subprocess.PIPE,
        )
        parent_start = sampler.sample(os.getpid())
        child.communicate(timeout=15)
        parent_end = sampler.sample(os.getpid())
        self.assertLess(parent_end["cpu_s"] - parent_start["cpu_s"], 0.1)
        self.assertGreater(after["rss"], 0)
        self.assertGreater(after["footprint"], 0)


class SummaryAcceptance(unittest.TestCase):
    def test_rejects_process_reuse_and_counter_regression(self):
        first = dict(
            pid=1,
            start_ticks=1,
            monotonic_s=1,
            cpu_s=1,
            interrupt_wakeups=1,
            package_wakeups=1,
            pageins=1,
            read_bytes=1,
            write_bytes=1,
            rss=10,
            footprint=20,
        )
        last = dict(first, monotonic_s=2, cpu_s=1.25, interrupt_wakeups=3)
        result = summarize([first, last])
        self.assertEqual(result["cpu_percent"], 25)
        self.assertEqual(result["interrupt_wakeups_per_s"], 2)
        for invalid in (dict(last, pid=2), dict(last, start_ticks=2), dict(last, cpu_s=0), dict(last, monotonic_s=1)):
            with self.assertRaises(ValueError):
                summarize([first, invalid])


if __name__ == "__main__":
    unittest.main()
