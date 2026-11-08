#!/usr/bin/env python3
"""Check the actual sampler against independent POSIX CPU accounting under a small CPU load."""
import contextlib
import io
import json
import os
from pathlib import Path
import runpy
import sys
import tempfile
import threading


stop = threading.Event()


def workload():
    value = 1
    while not stop.is_set():
        value = (value * 17 + 3) % 1000003


script = Path(__file__).with_name("measure-resources.py")
original_arguments = sys.argv[:]
worker = threading.Thread(target=workload)
try:
    with tempfile.TemporaryDirectory(prefix="personal-counter-test-") as folder:
        output = Path(folder) / "measurement.json"
        sys.argv = [str(script), "--pid", str(os.getpid()), "--duration", "1", "--interval", "0.1",
                    "--output", str(output), "--self-check"]
        worker.start()
        with contextlib.redirect_stdout(io.StringIO()):
            runpy.run_path(str(script), run_name="__main__")
        result = json.loads(output.read_text())
        assert all(sample["cpuCounterValidated"] for sample in result["samples"])
        print(json.dumps({"passed": True, "adjacentPOSIXChecks": len(result["samples"]),
                          "cpuTimebase": result["cpuTimebase"]}, indent=2))
finally:
    stop.set()
    if worker.is_alive():
        worker.join()
    sys.argv = original_arguments
