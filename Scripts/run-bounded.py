#!/usr/bin/env python3
"""Run a CI phase with progress, a deadline, and process-group cancellation."""
import argparse
import os
import signal
import subprocess
import time


def run(command, timeout, label, heartbeat=30, grace=10):
    print(f"Starting {label} (timeout {timeout:g}s)", flush=True)
    process = subprocess.Popen(command, start_new_session=True)
    started = time.monotonic()
    next_report = started + heartbeat
    stopped_at = None
    cancelled = None
    expired = False

    def send(sig):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            pass

    def cancel(sig, _frame):
        nonlocal cancelled, stopped_at
        cancelled = sig
        if stopped_at is None:
            stopped_at = time.monotonic()
            send(signal.SIGTERM)

    previous = {sig: signal.signal(sig, cancel) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        while True:
            now = time.monotonic()
            status = process.poll()
            if status is not None:
                # A shell may exit before its children. Do not leave those
                # processes behind when this phase was cancelled or timed out.
                if expired or cancelled:
                    send(signal.SIGKILL)
                if cancelled:
                    return 128 + cancelled
                if expired:
                    return 124
                return status if status >= 0 else 128 - status
            if stopped_at is None and now - started >= timeout:
                expired = True
                stopped_at = now
                print(f"ERROR: {label} exceeded {timeout:g}s; stopping its process group.", flush=True)
                send(signal.SIGTERM)
            elif stopped_at is not None and now - stopped_at >= grace:
                send(signal.SIGKILL)
            if now >= next_report:
                print(f"{label}: still running after {int(now - started)}s", flush=True)
                next_report = now + heartbeat
            time.sleep(0.1)
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not args.command or args.timeout <= 0:
        parser.error("a command and positive timeout are required")
    raise SystemExit(run(args.command, args.timeout, args.label))


if __name__ == "__main__":
    main()
