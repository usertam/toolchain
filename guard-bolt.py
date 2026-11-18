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


# Stay in memory and ahead of other processes, to still run when they stall
find_bolt()
stall()
ctypes.CDLL(None).mlockall(3)
os.sched_setscheduler(0, os.SCHED_FIFO, os.sched_param(1))

pid, stalled = None, 0
while Path(f"/proc/{parent}").exists():
    time.sleep(1)
    if not is_bolt(pid):
        pid = find_bolt()
    stalled = stalled + 1 if stall() >= limit else 0
    if stalled >= patience and pid:
        os.kill(pid, signal.SIGKILL)
        print(f"guard: stopped llvm-bolt after {stalled} s of memory stall", flush=True)
        stalled = 0
