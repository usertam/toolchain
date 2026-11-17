#!/usr/bin/env python3
# TEST: not for main. Instruments clang several times over before the BOLT
# stage, to see how much memory and swap llvm-bolt takes, how long the runner
# stalls for it, and what zswap, a memory limit, one malloc arena or one thread
# change about that. Each result is a notice, to outlive a lost runner.

import hashlib
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

BUILD = Path(sys.argv[1])
ZSWAP = Path('/sys/module/zswap/parameters')
CGROUP = Path('/sys/fs/cgroup/probe-bolt')
TIMEOUT = 900
# zswap, memory.high, environment and arguments of each run
RUNS = [
    ('Y', 'max', {}, []),
    ('Y', 'max', {}, []),
    ('N', '13G', {}, []),
    ('N', 'max', {}, []),
    ('N', 'max', {}, []),
    ('N', 'max', {}, []),
    ('N', 'max', {}, []),
    ('N', 'max', {}, []),
    ('N', 'max', {'MALLOC_ARENA_MAX': '1'}, []),
    ('N', 'max', {}, ['--thread-count=1']),
]


def sudo(*cmd, value=''):
    subprocess.run(
        ['sudo', *cmd],
        check=False,
        input=value,
        stdout=subprocess.DEVNULL,
        text=True,
    )


# Resident and swapped out memory of a process, in KiB
def footprint(pid):
    try:
        status = Path('/proc', str(pid), 'status').read_text(encoding='utf-8')
        return sum(
            int(line.split()[1])
            for line in status.splitlines()
            if line.startswith(('VmRSS', 'VmSwap'))
        )
    except (OSError, ValueError, IndexError):
        return 0


# Swap in use on the whole runner, in KiB
def swap_used():
    try:
        meminfo = Path('/proc/meminfo').read_text(encoding='utf-8')
        stat = dict(line.split()[:2] for line in meminfo.splitlines())
        return int(stat['SwapTotal:']) - int(stat['SwapFree:'])
    except (OSError, ValueError, KeyError):
        return 0


# Pages swapped in and out so far, to disk and to zswap
def swapped():
    try:
        vmstat = Path('/proc/vmstat').read_text(encoding='utf-8')
        stat = dict(line.split() for line in vmstat.splitlines())
    except (OSError, ValueError):
        stat = {}
    return [int(stat.get(key, 0)) for key in ('pswpin', 'pswpout', 'zswpin', 'zswpout')]


# Microseconds that some and that all tasks have stalled on memory so far
def stalled():
    try:
        pressure = Path('/proc/pressure/memory').read_text(encoding='utf-8')
        return [int(line.rsplit('=', 1)[1]) for line in pressure.splitlines()]
    except (OSError, ValueError, IndexError):
        return [0, 0]


# How often the memory limit was hit, and the peak memory and swap under it
def limited():
    try:
        events = dict(
            line.split()
            for line in (CGROUP / 'memory.events').read_text(encoding='utf-8').splitlines()
        )
        peaks = [
            int((CGROUP / name).read_text(encoding='utf-8')) >> 20
            for name in ('memory.peak', 'memory.swap.peak')
        ]
    except (OSError, ValueError):
        return 'none'
    return f"{events.get('high')}/{peaks[0]}M/{peaks[1]}M"


def sha256(path):
    digest = hashlib.sha256()
    try:
        with path.open('rb') as file:
            while chunk := file.read(1 << 20):
                digest.update(chunk)
    except OSError:
        return 'none'
    return digest.hexdigest()[:12]


def instrument(enabled, high, env, args, out):
    sudo('tee', ZSWAP / 'enabled', value=enabled)
    if high != 'max':
        sudo('mkdir', '-p', CGROUP)
        sudo('tee', CGROUP / 'memory.high', value=high)
    cmd = [
        BUILD / 'bootstrap/bin/llvm-bolt',
        '--instrument',
        *args,
        f"--instrumentation-file={out / 'clang.fdata'}",
        '-o',
        out / 'clang.inst',
        BUILD / 'final/bin/clang-24',
    ]
    pages, stall, idle, start = swapped(), stalled(), swap_used(), time.monotonic()
    pid = os.posix_spawn(cmd[0], cmd, {**os.environ, **env})
    if high != 'max':
        sudo('tee', CGROUP / 'cgroup.procs', value=str(pid))
    peak = swap = gap = 0
    last = time.monotonic()
    while True:
        done, status, usage = os.wait4(pid, os.WNOHANG)
        if done:
            break
        # The longest that this loop was kept from running, as the runner would be
        now = time.monotonic()
        gap, last = max(gap, now - last), now
        peak = max(peak, footprint(pid))
        swap = max(swap, swap_used())
        if now - start > TIMEOUT:
            os.kill(pid, signal.SIGKILL)
        time.sleep(0.5)
    wall = time.monotonic() - start
    pages = [(after - before) >> 8 for before, after in zip(pages, swapped())]
    stall = [(after - before) / 1e6 for before, after in zip(stall, stalled())]
    print(
        f"::notice::probe: zswap={enabled} high={high} env={env} args={args} status={status}",
        f"wall={wall:.0f}s gap={gap:.1f}s peak={peak >> 10}M maxrss={usage.ru_maxrss >> 10}M",
        f"swap={idle >> 10}/{swap >> 10}M majflt={usage.ru_majflt}",
        f"stall={stall[0]:.1f}/{stall[1]:.1f}s pswp={pages[0]}/{pages[1]}M",
        f"zswp={pages[2]}/{pages[3]}M limit={limited()} sha256={sha256(out / 'clang.inst')}",
        flush=True,
    )
    if high != 'max':
        sudo('rmdir', CGROUP)


subprocess.run(['grep', '-r', '.', ZSWAP], check=False)
try:
    with tempfile.TemporaryDirectory(dir=BUILD) as tmp:
        for run in RUNS:
            instrument(*run, Path(tmp))
finally:
    sudo('tee', ZSWAP / 'enabled', value='Y')
