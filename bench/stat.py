#!/usr/bin/env python3
# TEST: the timing and the arithmetic of run.sh. The toolchains are the words
# of $NAMES, each under $BENCH/tc; they take turns in an order that changes
# every round, and a result is the ratio of the last to the first in a round.
#
# stat.py time <label> <state> <turns> -- <program in bin> <argument>...
# stat.py run <name> <round> <tsv> -- <command>...
# stat.py kernel <tsv>
# stat.py maps -- <program in bin> <argument>...

import math
import os
import random
import statistics
import sys
import time
from pathlib import Path

BASE = Path(os.environ['BENCH'])
NAMES = os.environ['NAMES'].split()
TAG = os.environ.get('TAG', 'result')
WARMUP = 2


def spawn(argv):
    start = time.perf_counter()
    pid = os.posix_spawnp(argv[0], argv, os.environ)
    _, status, usage = os.wait4(pid, 0)
    return status, time.perf_counter() - start, usage


def program(name, cmd):
    return [str(BASE / 'tc' / name / 'bin' / cmd[0]), *cmd[1:]]


def ratio_ci(a, b):
    # Geometric mean of the per-round ratios b/a, with a 95% bootstrap interval
    logs = [math.log(y / x) for x, y in zip(a, b)]
    rng = random.SystemRandom()
    means = sorted(statistics.fmean(rng.choices(logs, k=len(logs))) for _ in range(10000))
    return tuple(math.exp(v) for v in (statistics.fmean(logs), means[249], means[9749]))


def side(values, unit):
    sd = statistics.stdev(values) if len(values) > 1 else 0.0
    return f"{statistics.fmean(values):.4g} ± {sd:.2g} {unit}"


def report(measure, state, rows, metrics):
    # rows: one dict per round, name -> tuple of metrics. The lines that start
    # with TAG are for a program to read, the others for a person
    first, last = NAMES[0], NAMES[-1]
    for idx, (label, unit) in enumerate(metrics):
        cols = {name: [row[name][idx] for row in rows] for name in NAMES}
        mid, lo, hi = ratio_ci(cols[first], cols[last])
        print(
            f"  {label:5}",
            ' | '.join(f"{name} {side(cols[name], unit)}" for name in NAMES),
            f"| {last} / {first}: {mid:.4f} [{lo:.4f}, {hi:.4f}] ({(mid - 1) * 100:+.2f}%)",
        )
        fields = (
            *(TAG, measure, state, label, len(rows)),
            *(statistics.fmean(cols[first]), statistics.fmean(cols[last]), mid, lo, hi),
            ' '.join(f"{y / x:.5f}" for x, y in zip(cols[first], cols[last])),
        )
        print('\t'.join(map(str, fields)), flush=True)


def time_cmd(label, state, turns, cmd):
    def run(name):
        argv = program(name, cmd)
        status, wall, usage = spawn(argv)
        if status:
            sys.exit(f"{argv[0]} exited with status {status}")
        return wall, usage.ru_utime + usage.ru_stime, usage.ru_maxrss / 1024

    for _ in range(WARMUP):
        for name in NAMES:
            run(name)

    rows = []
    for turn in range(turns):
        order = [NAMES[(i ^ turn) % len(NAMES)] for i in range(len(NAMES))]
        rows.append({name: run(name) for name in order})

    print(f"-- {label}, {state}: {' '.join(cmd)} ({turns} turns)")
    report(label, state, rows, (('wall', 's'), ('cpu', 's'), ('rss', 'MiB')))


def run_cmd(name, rnd, tsv, cmd):
    status, wall, usage = spawn(cmd)
    if status:
        sys.exit(f"{cmd[0]} exited with status {status}")
    fields = (name, rnd, wall, usage.ru_utime, usage.ru_stime, usage.ru_maxrss / 1024)
    with Path(tsv).open('a', encoding='utf-8') as file:
        file.write('\t'.join(f"{v:.2f}" if isinstance(v, float) else v for v in fields) + '\n')


def kernel(tsv):
    # name, round, wall, user, sys, maxrss; round 0 is the warm-up
    rounds = {}
    for line in Path(tsv).read_text(encoding='utf-8').splitlines()[1:]:
        name, rnd, wall, user, system, _rss = line.split('\t')
        if rnd != '0':
            rounds.setdefault(rnd, {})[name] = (float(wall), float(user), float(system))
    rows = [row for _, row in sorted(rounds.items(), key=lambda kv: int(kv[0]))]
    report('kernel', 'seq', rows, (('wall', 's'), ('user', 's'), ('sys', 's')))


def maps(cmd):
    # How much of a running clang is in memory, and how much of that in huge pages
    for name in NAMES:
        pid = os.posix_spawn(program(name, cmd)[0], program(name, cmd), os.environ)
        time.sleep(2)
        try:
            lines = Path(f"/proc/{pid}/smaps_rollup").read_text(encoding='utf-8').splitlines()
        except OSError as err:
            lines = [f"Rss: unknown, {err}"]
        keep = ('Rss:', 'AnonHugePages:', 'FilePmdMapped:')
        print(f"  {name}:", ', '.join(' '.join(ln.split()) for ln in lines if ln.startswith(keep)))
        os.waitpid(pid, 0)


mode, args, command = sys.argv[1], sys.argv[2:], []
if '--' in args:
    args, command = args[: args.index('--')], args[args.index('--') + 1 :]
if mode == 'time':
    time_cmd(args[0], args[1], int(args[2]), command)
elif mode == 'run':
    run_cmd(args[0], args[1], args[2], command)
elif mode == 'kernel':
    kernel(args[0])
elif mode == 'maps':
    maps(command)
else:
    sys.exit(f"unknown mode {mode}")
