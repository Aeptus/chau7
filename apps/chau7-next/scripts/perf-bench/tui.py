#!/usr/bin/env python3
"""Synthetic AI-agent TUI: alternate screen, a scrolling transcript, and a
bottom panel (spinner, status, input box) redrawn at a fixed rate, the way
Claude Code / Codex repaint their dynamic region. Deterministic per seed."""

import random
import shutil
import sys
import time

hz = float(sys.argv[1]) if len(sys.argv) > 1 else 12.5
seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
message_every = float(sys.argv[3]) if len(sys.argv) > 3 else 2.0
rng = random.Random(seed)
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


w("\x1b[?1049h\x1b[?25l\x1b[2J")
tick = 0
next_message = time.monotonic()
start = time.monotonic()
try:
    while True:
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
        time.sleep(1.0 / hz)
except KeyboardInterrupt:
    pass
finally:
    w("\x1b[r\x1b[?25h\x1b[?1049l")
    out.flush()
