#!/usr/bin/env python3
"""Opt-in local runtime sampling; output only timings and memory, not user content.

Observed-process CPU misses short-lived subprocesses. On macOS, kernel counters
also include reaped children. Neither CPU nor wakeups are battery consumption.
"""
import argparse
import ctypes
import functools
import json
import subprocess
import sys
import time


class ResourceUsage(ctypes.Structure):
    # rusage_info_v1, from the macOS SDK sys/resource.h. Time fields use Mach ticks.
    _fields_ = [('uuid', ctypes.c_ubyte * 16)] + [(name, ctypes.c_uint64) for name in (
        'user', 'system', 'package_wakes', 'interrupt_wakes', 'pageins', 'wired', 'resident',
        'footprint', 'start', 'exit', 'child_user', 'child_system', 'child_package_wakes',
        'child_interrupt_wakes', 'child_pageins', 'child_elapsed')]


class Timebase(ctypes.Structure):
    _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]


@functools.lru_cache(maxsize=1)
def kernel_api():
    lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    clock = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
    info = Timebase()
    if clock.mach_timebase_info(ctypes.byref(info)) != 0 or not info.denom:
        raise RuntimeError('Mach time conversion is unavailable')
    return lib, info.numer / info.denom / 1e9


def kernel_snapshot(rows, roots):
    lib, seconds_per_tick = kernel_api()
    total = dict(cpu=0, app_cpu=0, interrupt_wakes=0, package_wakes=0, footprint_mb=0)
    for pid in rows:
        usage = ResourceUsage()
        if lib.proc_pid_rusage(pid, 1, ctypes.byref(usage)) != 0:
            if pid in roots:
                raise RuntimeError('Cannot read the running application resource counters')
            continue  # A short-lived helper may have exited since the process census.
        own = (usage.user + usage.system) * seconds_per_tick
        total['cpu'] += own + (usage.child_user + usage.child_system) * seconds_per_tick
        if pid in roots:
            total['app_cpu'] += own
        total['interrupt_wakes'] += usage.interrupt_wakes + usage.child_interrupt_wakes
        total['package_wakes'] += usage.package_wakes + usage.child_package_wakes
        total['footprint_mb'] += usage.footprint / 1048576
    return total


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
    roots = {pid for pid, row in initial.items() if row[3] == args.executable}
    kernel_before = kernel_snapshot(initial, roots) if sys.platform == 'darwin' else None
    footprint_peak = kernel_before['footprint_mb'] if kernel_before else 0
    last_cpu = {pid: row[1] for pid, row in initial.items()}
    peak_rss = sum(row[2] for row in initial.values())
    total_cpu = 0.0
    started = time.monotonic()
    for _ in range(args.seconds):
        time.sleep(1)
        current = snapshot(args.executable)
        if {pid for pid, row in current.items() if row[3] == args.executable} != roots:
            parser.error('the application restarted or exited during sampling; repeat the capture')
        if kernel_before:
            kernel_after = kernel_snapshot(current, roots)
            footprint_peak = max(footprint_peak, kernel_after['footprint_mb'])
        for pid, row in current.items():
            total_cpu += max(0, row[1] - last_cpu.get(pid, 0))
            last_cpu[pid] = row[1]
        peak_rss = max(peak_rss, sum(row[2] for row in current.values()))
    elapsed = time.monotonic() - started
    result = dict(duration_seconds=round(elapsed, 3), observed_cpu_seconds=round(total_cpu, 3),
                  average_core_percent=round(total_cpu / elapsed * 100, 2),
                  summed_resident_mb_peak=round(peak_rss, 2), observed_processes=len(last_cpu))
    if kernel_before:
        result.update(kernel_average_core_percent=round((kernel_after['cpu'] - kernel_before['cpu']) / elapsed * 100, 2),
                      app_average_core_percent=round((kernel_after['app_cpu'] - kernel_before['app_cpu']) / elapsed * 100, 2),
                      interrupt_wakes_per_second=round((kernel_after['interrupt_wakes'] - kernel_before['interrupt_wakes']) / elapsed, 2),
                      package_wakes_per_second=round((kernel_after['package_wakes'] - kernel_before['package_wakes']) / elapsed, 2),
                      summed_physical_footprint_mb_peak=round(footprint_peak, 2))
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
