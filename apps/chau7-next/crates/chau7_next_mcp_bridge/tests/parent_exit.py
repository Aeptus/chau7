"""The bridge must notice owner exit even while another process retains its pipes."""

import contextlib
import os
import signal
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

with tempfile.TemporaryDirectory(prefix="mcp-parent-", dir="/tmp") as tmp:
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(str(Path(tmp) / "mcp.sock"))
    listener.listen(1)
    listener.settimeout(5)
    parent_code = """
import signal, subprocess, sys
child = subprocess.Popen(sys.argv[1:], stdin=sys.stdin, stdout=sys.stdout)
print(child.pid, file=sys.stderr, flush=True)
signal.pause()
"""
    parent = subprocess.Popen(
        [sys.executable, "-c", parent_code, sys.argv[1], "--socket", listener.getsockname()],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    bridge_pid = int(parent.stderr.readline())
    try:
        connection, _ = listener.accept()
        with connection:
            parent.kill()
            parent.wait(timeout=5)
            # Both client pipes stay open here. Only the parent's exit is an event.
            connection.settimeout(1)
            assert connection.recv(1) == b"", "bridge retained its socket after owner exit"
    finally:
        if parent.poll() is None:
            parent.kill()
        parent.wait(timeout=5)
        for pipe in (parent.stdin, parent.stdout, parent.stderr):
            pipe.close()
        with contextlib.suppress(ProcessLookupError):
            os.kill(bridge_pid, signal.SIGKILL)
        listener.close()
