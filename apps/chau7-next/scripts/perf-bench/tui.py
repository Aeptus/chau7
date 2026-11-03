#!/usr/bin/env python3
"""Synthetic AI-agent TUI: alternate screen, a scrolling transcript, and a
bottom panel (spinner, status, input box) redrawn at a fixed rate, the way
Claude Code / Codex repaint their dynamic region. Deterministic per seed."""

import ctypes
import json
import os
import random
import shutil
import sys
import time
from pathlib import Path

hz = float(sys.argv[1]) if len(sys.argv) > 1 else 12.5
seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
message_every = float(sys.argv[3]) if len(sys.argv) > 3 else 2.0
rng = random.Random(seed)
phase_file = Path(sys.argv[4]) if len(sys.argv) > 4 else None
progress_dir = Path(sys.argv[5]) if len(sys.argv) > 5 else None
# Keep only the external load generator at a known QoS; app/helper QoS is unchanged.
if sys.platform == "darwin":
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    libc.pthread_set_qos_class_self_np.argtypes = (ctypes.c_uint, ctypes.c_int)
    error = libc.pthread_set_qos_class_self_np(0x19, 0)  # QOS_CLASS_USER_INITIATED
    if error:
        raise OSError(error, "could not set workload generator QoS")
counters = {"bytes": 0}
words = [
    "terminal",
    "render",
    "budget",
    "grid",
    "cell",
    "row",
    "cache",
    "glyph",
    "shape",
    "frame",
    "latency",
    "output",
    "batch",
    "hidden",
    "visible",
    "session",
    "refresh",
    "paint",
    "quad",
    "text",
    "run",
]
spinner = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
out = sys.stdout


def size():
    s = shutil.get_terminal_size((80, 24))
    return max(s.columns, 40), max(s.lines, 16)


def w(text):
    out.write(text)
    counters["bytes"] += len(text.encode())


def progress():
    if progress_dir:
        path = progress_dir / f"{os.getpid()}.json"
        temporary = path.with_suffix(".tmp")
        temporary.write_text(
            json.dumps(
                {"pid": os.getpid(), "frames": tick, "bytes": counters["bytes"], "monotonic_s": time.monotonic()}
            )
        )
        temporary.replace(path)


w("\x1b[?1049h\x1b[?25l\x1b[2J")
tick = 0
next_message = time.monotonic()
next_progress = 0
start = time.monotonic()
next_frame = start
try:
    while True:
        now = time.monotonic()
        if now >= next_progress:
            progress()
            next_progress = now + 0.5
        if phase_file and phase_file.read_text() != "active":
            time.sleep(0.1)
            next_frame = time.monotonic()
            continue
        cols, rows = size()
        panel = 6
        body_bottom = rows - panel
        # Scrolling transcript region above the panel.
        w(f"\x1b[1;{body_bottom}r")
        now = time.monotonic()
        if now >= next_message:
            next_message = now + message_every
            w(f"\x1b[{body_bottom};1H")
            for _ in range(3):
                line = " ".join(rng.choice(words) for _ in range(cols // 7))
                color = 31 + rng.randrange(6)
                w(f"\n\x1b[{color}m●\x1b[0m {line[: cols - 3]}")
        w("\x1b[r")
        # Bottom panel: rewritten every tick, like an Ink re-render.
        elapsed = now - start
        status = f" {spinner[tick % len(spinner)]} Working… ({elapsed:5.1f}s · ↑ {tick * 7} tokens · esc to interrupt)"
        box = "─" * (cols - 2)
        w(f"\x1b[{body_bottom + 1};1H\x1b[2K\x1b[38;5;208m{status[:cols]}\x1b[0m")
        w(f"\x1b[{body_bottom + 2};1H\x1b[2K╭{box}╮")
        w(f"\x1b[{body_bottom + 3};1H\x1b[2K│ > {' ' * (cols - 6)}│")
        w(f"\x1b[{body_bottom + 4};1H\x1b[2K╰{box}╯")
        w(f"\x1b[{body_bottom + 5};1H\x1b[2K\x1b[2m  ? for shortcuts{' ' * (cols - 40)}seed {seed} tick {tick}\x1b[0m")
        out.flush()
        tick += 1
        next_frame += 1.0 / hz
        now = time.monotonic()
        if now > next_frame + 1.0 / hz:
            # Do not disguise a stalled generator with a burst of catch-up frames.
            next_frame = now
        time.sleep(max(0, next_frame - now))
except KeyboardInterrupt:
    pass
finally:
    w("\x1b[r\x1b[?25h\x1b[?1049l")
    out.flush()
