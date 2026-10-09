#!/usr/bin/env python3
"""Opt-in local runtime sampling; output only timings and memory, not user content.

Short-lived subprocesses between samples are not measured. RSS is summed resident
memory, not private footprint or energy consumption.
"""
import argparse
import json
import subprocess
import time


def cpu_seconds(value):
    parts = value.split(':')
    return sum(float(part) * 60 ** index for index, part in enumerate(reversed(parts)))


def snapshot(executable):
    output = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,time=,rss=,comm='], text=True)
    rows = {}
    for line in output.splitlines():
        fields = line.split(None, 4)
        if len(fields) == 5:
            pid, parent, cpu, rss, command = fields
            rows[int(pid)] = (int(parent), cpu_seconds(cpu), int(rss) / 1024, command)
    owned = {pid for pid, row in rows.items() if row[3] == executable}
    previous = set()
    while previous != owned:
        previous = owned.copy()
        owned.update(pid for pid, row in rows.items() if row[0] in owned)
    return {pid: rows[pid] for pid in owned}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--executable', required=True)
    parser.add_argument('--seconds', type=int, default=30)
    args = parser.parse_args()
    if not 1 <= args.seconds <= 60:
        parser.error('sample duration must be between 1 and 60 seconds')
    initial = snapshot(args.executable)
    if not initial:
        parser.error('target application is not running')
    last_cpu = {pid: row[1] for pid, row in initial.items()}
    peak_rss = sum(row[2] for row in initial.values())
    total_cpu = 0.0
    started = time.monotonic()
    for _ in range(args.seconds):
        time.sleep(1)
        current = snapshot(args.executable)
        for pid, row in current.items():
            total_cpu += max(0, row[1] - last_cpu.get(pid, 0))
            last_cpu[pid] = row[1]
        peak_rss = max(peak_rss, sum(row[2] for row in current.values()))
    elapsed = time.monotonic() - started
    print(json.dumps(dict(duration_seconds=round(elapsed, 3), observed_cpu_seconds=round(total_cpu, 3),
                          average_core_percent=round(total_cpu / elapsed * 100, 2),
                          summed_resident_mb_peak=round(peak_rss, 2), observed_processes=len(last_cpu)), indent=2))


if __name__ == '__main__':
    main()
