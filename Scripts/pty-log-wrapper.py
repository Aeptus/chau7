#!/usr/bin/env python3
import os
import sys
import pty
import tty
import termios
import select
import signal
import fcntl
import struct
import time


def usage():
    sys.stderr.write(
        "Usage: pty-log-wrapper.py --log <path> -- <command> [args...]\n"
    )


def open_meta_log(path):
    if not path:
        return None
    log_dir = os.path.dirname(os.path.abspath(path))
    if log_dir:
        os.makedirs(log_dir, exist_ok=True)
    return open(path, "a", encoding="utf-8")


def get_winsize(fd):
    try:
        data = fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\x00" * 8)
        return struct.unpack("hhhh", data)
    except Exception:
        return None


def set_winsize(fd, winsize):
    if winsize is None:
        return
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("hhhh", *winsize))
    except Exception:
        pass


def main():
    args = sys.argv[1:]
    log_path = None
    cmd = None
    meta_log_path = os.environ.get("CHAU7_PTY_META_LOG")
    meta_log = open_meta_log(meta_log_path)
    start_time = time.time()

    def log(msg):
        ts = time.strftime("%H:%M:%S")
        line = f"{ts} | PTY   | {msg}\n"
        sys.stderr.write(line)
        sys.stderr.flush()
        if meta_log:
            meta_log.write(line)
            meta_log.flush()

    i = 0
    while i < len(args):
        if args[i] == "--log" and i + 1 < len(args):
            log_path = args[i + 1]
            i += 2
        elif args[i] == "--":
            cmd = args[i + 1 :]
            break
        else:
            usage()
            return 2

    if not log_path or not cmd:
        usage()
        return 2

    log_dir = os.path.dirname(os.path.abspath(log_path))
    if log_dir:
        os.makedirs(log_dir, exist_ok=True)

    log_fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)

    log(f"Command: {' '.join(cmd)}")
    log(f"TTY log: {log_path}")

    master_fd, slave_fd = pty.openpty()

    pid = os.fork()
    if pid == 0:
        os.setsid()
        os.close(master_fd)
        os.dup2(slave_fd, 0)
        os.dup2(slave_fd, 1)
        os.dup2(slave_fd, 2)
        if slave_fd > 2:
            os.close(slave_fd)
        try:
            os.execvp(cmd[0], cmd)
        except Exception:
            os._exit(127)

    os.close(slave_fd)

    stdin_fd = sys.stdin.fileno()
    stdout_fd = sys.stdout.fileno()
    old_term = None
    if os.isatty(stdin_fd):
        old_term = termios.tcgetattr(stdin_fd)
        tty.setraw(stdin_fd)

    winsize = get_winsize(stdin_fd)
    set_winsize(master_fd, winsize)

    def on_winch(signum, frame):
        size = get_winsize(stdin_fd)
        set_winsize(master_fd, size)

    signal.signal(signal.SIGWINCH, on_winch)

    input_buffer = bytearray()

    def flush_input_buffer():
        nonlocal input_buffer
        if not input_buffer:
            return
        try:
            text = input_buffer.decode("utf-8", errors="replace")
        except Exception:
            text = ""
        input_buffer = bytearray()
        if text:
            line = "[INPUT] " + text.replace("\n", " ").replace("\r", " ")
            os.write(log_fd, (line + "\n").encode("utf-8"))

    exit_code = 0
    try:
        while True:
            rlist, _, _ = select.select([master_fd, stdin_fd], [], [])
            if master_fd in rlist:
                try:
                    data = os.read(master_fd, 4096)
                except OSError:
                    break
                if not data:
                    break
                os.write(stdout_fd, data)
                os.write(log_fd, data)
            if stdin_fd in rlist:
                try:
                    data = os.read(stdin_fd, 4096)
                except OSError:
                    data = b""
                if not data:
                    break
                os.write(master_fd, data)

                # Capture user input lines for logging.
                input_buffer.extend(data)
                if b"\n" in data or b"\r" in data:
                    flush_input_buffer()
    except KeyboardInterrupt:
        try:
            os.kill(pid, signal.SIGINT)
        except Exception:
            pass
    finally:
        flush_input_buffer()
        if old_term is not None:
            termios.tcsetattr(stdin_fd, termios.TCSADRAIN, old_term)
        os.close(master_fd)
        os.close(log_fd)

        try:
            _, status = os.waitpid(pid, 0)
            if os.WIFEXITED(status):
                exit_code = os.WEXITSTATUS(status)
            elif os.WIFSIGNALED(status):
                exit_code = 128 + os.WTERMSIG(status)
        except Exception:
            exit_code = 1

    elapsed = time.time() - start_time
    log(f"Exit code: {exit_code}")
    log(f"Duration: {elapsed:.2f}s")
    if meta_log:
        meta_log.close()

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
