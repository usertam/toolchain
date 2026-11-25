#!/usr/bin/env python3
# TEST: run a command and say where the time of the machine went meanwhile:
# into the command, into something else, or nowhere. With the lines that
# twrap wrote during it, also which tools of the toolchain waited, and how
# many of them ran at a time.
#
# probe.py <label> <log of the command> <lines of twrap, or -> -- <command>...

import os
import resource
import statistics
import subprocess
import sys
import time
from collections import defaultdict
from pathlib import Path

TICK = os.sysconf('SC_CLK_TCK')
CPUS = sorted(os.sched_getaffinity(0))
VMSTAT = {'pgfault', 'pgmajfault', 'pgpgin', 'pgpgout', 'pswpin', 'pswpout', 'thp_fault_alloc', 'compact_stall',
          'pgscan_direct', 'pgsteal_kswapd', 'workingset_refault_file'}


def lines(path):
    # A process may be gone, and a kernel may be without /proc/pressure
    try:
        return Path(path).read_text(encoding='utf-8').splitlines()
    except OSError:
        return []


def cpu_lines(path):
    for line in lines(path):
        p = line.split()
        if p[0].startswith('cpu') and p[0][3:].isdigit():
            yield p


def snapshot():
    snap = {'stat': defaultdict(float), 'psi': {}, 'counts': {}, 'pids': {}}
    # All the cpus of the machine, also where the command may run on some only
    for p in cpu_lines('/proc/stat'):
        for key, value in zip(('user', 'nice', 'system', 'idle', 'iowait', 'irq', 'softirq', 'steal'), p[1:9]):
            snap['stat'][key] += int(value) / TICK
    for line in lines('/proc/stat'):
        p = line.split()
        if p[0] in {'processes', 'ctxt'}:
            snap['counts'][p[0]] = int(p[1])
    # The time tasks ran and the time they waited for a cpu, in ns
    snap['ran'] = sum(int(p[7]) for p in cpu_lines('/proc/schedstat')) / 1e9
    snap['waited'] = sum(int(p[8]) for p in cpu_lines('/proc/schedstat')) / 1e9
    for what in ('cpu', 'io', 'memory'):
        for line in lines('/proc/pressure/' + what):
            p = line.split()
            snap['psi'][f'{what} {p[0]}'] = int(p[-1].split('=')[1]) / 1e6
    for line in lines('/proc/vmstat'):
        key, value = line.split()
        if key in VMSTAT:
            snap['counts'][key] = int(value)
    for proc in Path('/proc').iterdir():
        text = ''.join(lines(proc / 'stat')) if proc.name.isdigit() else ''
        if text:
            p = text[text.rindex(')') + 2:].split()
            # The name, the user and system time, and the start as what tells two of one pid apart
            snap['pids'][int(proc.name)] = (text[text.index('(') + 1:text.rindex(')')], (int(p[11]) + int(p[12])) / TICK, p[19])
    return snap


def kind(name, out):
    if name != 'clang':
        return name
    ext = Path(out).suffix
    return 'clang -o ' + ('*' + ext if ext else out if out in {'-', '/dev/null'} else 'other')


def tools(path):
    rows = []
    for line in lines(path):
        p = line.split('\t')
        if len(p) == 6:
            rows.append((float(p[0]), float(p[1]), float(p[2]), float(p[3]), p[4], p[5]))
    if not rows:
        return 0.0, 0.0
    groups = defaultdict(list)
    for row in rows:
        groups[kind(row[4], row[5])].append(row)
    print(f'  {"tool":<18}{"runs":>6}{"wall":>9}{"user":>9}{"sys":>8}{"waited":>8}   waited a run, ms: median, 90%, 99%, most')
    for name, group in sorted(groups.items(), key=lambda kv: -sum(r[1] for r in kv[1])):
        waits = sorted(1000 * (r[1] - r[2] - r[3]) for r in group)
        wall, user, system = (sum(r[i] for r in group) for i in (1, 2, 3))
        print(f'  {name:<18}{len(group):>6}{wall:>9.1f}{user:>9.1f}{system:>8.1f}{wall - user - system:>8.1f}   '
              f'{statistics.median(waits):.1f}, {waits[len(waits) * 9 // 10]:.1f}, {waits[len(waits) * 99 // 100]:.1f}, {waits[-1]:.1f}')
    # How many of them ran at a time: overall, and in each twentieth of the time
    events = sorted([(r[0], 1) for r in rows] + [(r[0] + r[1], -1) for r in rows])
    first, width = events[0][0], (events[-1][0] - events[0][0]) / 20 or 1.0
    level, at, levels, slices = 0, first, defaultdict(float), [0.0] * 20
    for when, step in events:
        levels[level] += when - at
        while at < when:
            i = min(int((at - first) / width), 19)
            end = when if i == 19 else min(when, first + (i + 1) * width)
            if end <= at:
                # On the edge of a twentieth, to the rounding: it is in the next one
                i, end = i + 1, min(when, first + (i + 2) * width)
            slices[i] += level * (end - at)
            at = end
        level, at = level + step, when
    print(f'  seconds with n tools running, of {20 * width:.1f}: ' + ', '.join(f'{n}: {levels[n]:.1f}' for n in sorted(levels)))
    print('  tools running in each twentieth of that time: ' + ' '.join(f'{s / width:.1f}' for s in slices))
    print('  longest: ' + '; '.join(f'{r[4]} {Path(r[5]).name} {r[1]:.1f} (cpu {r[2] + r[3]:.1f})' for r in sorted(rows, key=lambda r: -r[1])[:6]))
    return sum(r[2] for r in rows), sum(r[3] for r in rows)


def main():
    label, log, tsv = sys.argv[1:4]
    cmd = sys.argv[sys.argv.index('--') + 1:]
    before, usage, start = snapshot(), resource.getrusage(resource.RUSAGE_CHILDREN), time.monotonic()
    with Path(log).open('ab') as out:
        rc = subprocess.call(cmd, stdout=out, stderr=subprocess.STDOUT)
    wall, after, done = time.monotonic() - start, snapshot(), resource.getrusage(resource.RUSAGE_CHILDREN)
    user, system = done.ru_utime - usage.ru_utime, done.ru_stime - usage.ru_stime

    stat = {k: after['stat'][k] - before['stat'][k] for k in after['stat']}
    busy = sum(stat[k] for k in ('user', 'nice', 'system', 'irq', 'softirq'))
    print(f'== {label}: rc {rc}, wall {wall:.1f} s on {len(CPUS)} cpus = {wall * len(CPUS):.1f} cpu-s')
    print(f'  the command and its children: user {user:.1f} sys {system:.1f}; not in them: {wall * len(CPUS) - user - system:.1f}')
    print('  the machine, all its cpus: ' + ' '.join(f'{k} {v:.1f}' for k, v in stat.items()) + f'; busy with something else: {busy - user - system:.1f}')
    print(f'  tasks ran {after["ran"] - before["ran"]:.1f} and waited for a cpu {after["waited"] - before["waited"]:.1f}; stalled, s: '
          + ', '.join(f'{k} {after["psi"][k] - before["psi"][k]:.1f}' for k in after['psi']))
    print('  counts: ' + ' '.join(f'{k} {after["counts"][k] - before["counts"][k]}' for k in after['counts']))
    others = []
    for pid, (name, cpu, started) in after['pids'].items():
        was = before['pids'].get(pid)
        same = was is not None and was[2] == started
        if pid != os.getpid():
            others.append((cpu - was[1] if same else cpu, name + ('' if same else ' (new)')))
    print('  cpu time of what is still there: ' + ', '.join(f'{name} {cpu:.1f}' for cpu, name in sorted(others, reverse=True)[:12] if cpu >= 0.1))
    if tsv != '-' and Path(tsv).exists():
        tool_user, tool_system = tools(tsv)
        print(f'  the rest of the command (make, sh, host tools): user {user - tool_user:.1f} sys {system - tool_system:.1f}')
    sys.stdout.flush()
    return rc


if __name__ == '__main__':
    sys.exit(main())
