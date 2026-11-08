#!/usr/bin/env python3
"""Export only public rate tables from CodexBar's existing offline pricing cache."""
import json
from pathlib import Path

source = Path.home() / "Library/Caches/CodexBar/model-pricing/models-dev-v1.json"
target = Path(__file__).resolve().parents[1] / "Sources/PersonalCore/Resources/pricing.json"
artifact = json.loads(source.read_text())
models = {}


def rates(raw):
    return {key: raw[field] for key, field in [
        ("input", "input"), ("output", "output"), ("cacheRead", "cache_read"), ("cacheWrite", "cache_write")
    ] if isinstance(raw.get(field), (float, int))}


for provider, native in [("claude", "anthropic"), ("codex", "openai")]:
    for name, model in artifact["catalog"]["providers"][native]["models"].items():
        cost = model.get("cost") or {}
        entry = rates(cost)
        if "input" not in entry or "output" not in entry:
            continue
        tiers = []
        for tier in cost.get("tiers") or []:
            gate = tier.get("tier") or {}
            if gate.get("type") == "context" and isinstance(gate.get("size"), int):
                tiers.append({**entry, **rates(tier), "threshold": gate["size"]})
        if tiers:
            entry["tiers"] = sorted(tiers, key=lambda item: item["threshold"])
        models[f"{provider}:{name}"] = entry
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(json.dumps({"fetchedAt": artifact["fetchedAt"], "models": models}, indent=2, sort_keys=True) + "\n")
print(f"Exported {len(models)} public model rates to {target}")
