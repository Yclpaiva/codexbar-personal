#!/usr/bin/env python3
"""Compare the real native reader with independent SQL totals and Decimal request pricing."""
import argparse
import datetime as dt
from decimal import Decimal
import json
from pathlib import Path
import sqlite3
import subprocess
import time


parser = argparse.ArgumentParser()
parser.add_argument("--quotas", action="store_true", help="Also query real accounts through the existing kit launcher")
parser.add_argument("--output", type=Path, default=Path(".build/evidence/integration-reference.json"))
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
prices = json.loads((root / "Sources/PersonalCore/Resources/pricing.json").read_text())["models"]
since = (dt.datetime.now().date() - dt.timedelta(days=29)).isoformat()
until = dt.datetime.now().date().isoformat()
database_uri = (Path.home() / ".local/share/cpa-usage/usage.db").as_uri() + "?mode=ro"


def reference():
    requests = tokens = failed = unpriced = 0
    cost = Decimal(0)
    with sqlite3.connect(database_uri, uri=True) as database:
        rows = database.execute("""
            SELECT provider,model,input,output,cache_read,cache_write,reasoning,failed
            FROM events WHERE day>=? AND day<=?
        """, (since, until))
        for provider, model, input_tokens, output, read, write, reasoning, failure in rows:
            requests += 1
            failed += failure
            tokens += input_tokens + output + (read + write if provider == "claude" else 0)
            price = prices.get(provider + ":" + model)
            if price is None:
                unpriced += 1
                continue
            context = input_tokens + (read + write if provider == "claude" else 0)
            for tier in sorted(price.get("tiers", []), key=lambda item: item["threshold"]):
                if context > tier["threshold"]:
                    price = tier
            uncached = input_tokens - read - write if provider == "codex" else input_tokens
            classes = [(uncached, "input"), (output, "output"), (read, "cacheRead"), (write, "cacheWrite")]
            cost += sum(Decimal(count) * Decimal(str(price.get(key, price["input"])))
                        for count, key in classes) / 1000000
    return dict(requests=requests, tokens=tokens, failed=failed, unpricedRequests=unpriced, costUSD=float(cost))


before = reference()
started = time.monotonic()
command = [str(root / ".build/release/CodexBarPersonal"), "--history"]
if args.quotas:
    command = [str(Path.home() / "Projects/agent-kit/scripts/with-env")] + command + ["--probe"]
run = subprocess.run(command, capture_output=True, text=True, check=True, timeout=120)
result = json.loads(run.stdout)
native = result["history"]
after = reference()
checks = {key: before[key] - 1e-7 <= native[key] <= after[key] + 1e-7
          for key in ["requests", "tokens", "costUSD", "unpricedRequests"]}
assert all(checks.values()), (before, native, after)
assert result.get("failedAccounts", 0) == 0
evidence = {"checkedAt": dt.datetime.now().astimezone().isoformat(), "checks": checks,
            "before": before, "native": result, "after": after,
            "cliWallSeconds": time.monotonic() - started,
            "method": "Independent SQL and Decimal pricing bracket the live append-only collector while the native CLI runs."}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(evidence, indent=2) + "\n")
print(json.dumps({"checks": checks, "failedAccounts": result.get("failedAccounts"),
                  "requests": native["requests"], "unpricedRequests": native["unpricedRequests"]}, indent=2))
