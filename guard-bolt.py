#!/usr/bin/env python3
# TEST: stop llvm-bolt when the runner has stalled on memory for too long, for
# the stage to fail with its log before the runner is lost with it
#
# guard-bolt.py <pid to live as long as> <full avg10 to call a stall> <seconds>

import ctypes
import os
import signal
import sys
import time
from pathlib import Path

parent, limit, patience = int(sys.argv[1]), float(sys.argv[2]), int(sys.argv[3])


def is_bolt(pid):
    try:
        return Path(f"/proc/{pid}/comm").read_text(encoding='utf-8') == 'llvm-bolt\n'
    except OSError:
        return False


def find_bolt():
    return next(
        (int(item.name) for item in Path('/proc').glob('[0-9]*') if is_bolt(item.name)), None
    )


def stall():
    # The second line is the share of time in which every task was stalled
    pressure = Path('/proc/pressure/memory').read_text(encoding='utf-8')
    return float(pressure.split('avg10=')[2].split()[0])


def state():
    # What is left of memory and swap, and how much went in and out of swap
    text = Path('/proc/meminfo').read_text(encoding='utf-8')
    text += Path('/proc/vmstat').read_text(encoding='utf-8')
    stat = {line.split()[0].rstrip(':'): int(line.split()[1]) for line in text.splitlines()}
    return (
        f"mem={stat['MemAvailable'] >> 10}M swapfree={stat['SwapFree'] >> 10}M"
        f" pswp={stat['pswpin'] >> 8}/{stat['pswpout'] >> 8}M"
    )


# Stay in memory and ahead of other processes, to still run when they stall
find_bolt()
stall()
state()
ctypes.CDLL(None).mlockall(3)
os.sched_setscheduler(0, os.SCHED_FIFO, os.sched_param(1))

pid, stalled = None, 0
while Path(f"/proc/{parent}").exists():
    time.sleep(1)
    if not is_bolt(pid):
        pid = find_bolt()
    stalled = stalled + 1 if stall() >= limit else 0
    if stalled % 5 == 1:
        print(
            f"guard: {time.strftime('%T', time.gmtime())} stalled {stalled} s {state()}", flush=True
        )
    if stalled >= patience and pid:
        os.kill(pid, signal.SIGKILL)
        print(f"::error::guard: stopped llvm-bolt after {stalled} s of memory stall", flush=True)
        stalled = 0
