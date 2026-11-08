#!/usr/bin/env python3
"""Measure the actual process footprint (including compressed memory) and CPU deltas on macOS."""
import argparse
import ctypes
import json
import os
import resource
import statistics
import time
from pathlib import Path


class Usage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in [
        "user", "system", "idle_wakeups", "interrupt_wakeups", "pageins", "wired", "resident", "footprint",
        "start", "exit", "child_user", "child_system", "child_idle_wakeups", "child_interrupt_wakeups",
        "child_pageins", "child_elapsed", "disk_read", "disk_write",
    ]]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


parser = argparse.ArgumentParser()
parser.add_argument("--pid", type=int, required=True)
parser.add_argument("--duration", type=int, default=60)
parser.add_argument("--interval", type=float, default=2)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--self-check", action="store_true")
args = parser.parse_args()
if args.self_check and args.pid != os.getpid():
    raise SystemExit("Counter self-check requires measuring this process")
lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
lib.proc_pid_rusage.restype = ctypes.c_int
system = ctypes.CDLL("/usr/lib/libSystem.dylib")
timebase = Timebase()
if system.mach_timebase_info(ctypes.byref(timebase)) != 0 or not timebase.denom:
    raise SystemExit("Mach CPU timebase is unavailable")
ticks_to_ns = timebase.numer / timebase.denom
samples = []
start = time.monotonic()
previous = None
while True:
    elapsed = time.monotonic() - start
    usage = Usage()
    posix_before = resource.getrusage(resource.RUSAGE_SELF) if args.self_check else None
    if lib.proc_pid_rusage(args.pid, 2, ctypes.byref(usage)) != 0:
        raise SystemExit("Target process exited or resource counters are unavailable")
    posix_after = resource.getrusage(resource.RUSAGE_SELF) if args.self_check else None
    current = (time.monotonic(), (usage.user + usage.system) * ticks_to_ns)
    if posix_before is not None:
        lower = posix_before.ru_utime + posix_before.ru_stime
        upper = posix_after.ru_utime + posix_after.ru_stime
        # POSIX reports microsecond-resolution CPU time; compare adjacent reads, not work done later.
        assert lower - 0.001 <= current[1] / 1e9 <= upper + 0.001, (lower, current[1] / 1e9, upper)
    cpu = None if previous is None else 100 * (current[1] - previous[1]) / 1e9 / (current[0] - previous[0])
    samples.append({"elapsed": round(elapsed, 3), "footprintMiB": usage.footprint / 2**20,
                    "residentMiB": usage.resident / 2**20, "cpuPercentOneCore": cpu,
                    "cpuSeconds": (usage.user + usage.system) * ticks_to_ns / 1e9,
                    "diskReadBytes": usage.disk_read, "diskWriteBytes": usage.disk_write,
                    "cpuCounterValidated": args.self_check})
    previous = current
    if elapsed >= args.duration:
        break
    time.sleep(min(args.interval, args.duration - elapsed))
cpu_values = [s["cpuPercentOneCore"] for s in samples if s["cpuPercentOneCore"] is not None]
summary = {"pid": args.pid, "durationSeconds": samples[-1]["elapsed"], "samples": len(samples),
           "footprintStartMiB": samples[0]["footprintMiB"], "footprintEndMiB": samples[-1]["footprintMiB"],
           "footprintPeakMiB": max(s["footprintMiB"] for s in samples),
           "cpuMeanPercentOneCore": statistics.mean(cpu_values), "cpuPeakPercentOneCore": max(cpu_values),
           "cpuSeconds": samples[-1]["cpuSeconds"] - samples[0]["cpuSeconds"],
           "diskWriteBytes": samples[-1]["diskWriteBytes"] - samples[0]["diskWriteBytes"]}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps({"summary": summary, "samples": samples,
                                  "cpuTimebase": {"numer": timebase.numer, "denom": timebase.denom}}, indent=2) + "\n")
print(json.dumps(summary, indent=2), flush=True)
