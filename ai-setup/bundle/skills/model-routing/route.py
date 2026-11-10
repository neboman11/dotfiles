#!/usr/bin/env python3
"""Pick the provider/model for a subagent of a given tier from live usage.

Rules (single source of truth; the model-routing extension calls this too):
  1. Providers other than the current one go first: usable unless a window is exhausted.
  2. The current provider is usable while every window is below HANDOFF (85%).
  3. Otherwise light/medium work goes to local Strata; heavy work pauses until a reset.
Fable/Astra tier models are never chosen.

Usage: route.py --tier heavy|medium|light [--current PROVIDER] [--json]
Exit codes: 0 spawn, 3 start Strata first (light/medium), 4 pause (nothing usable).
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
STATE = HERE / "state"
MODELS = STATE / "models.json"
USAGE_CACHE = STATE / "usage.json"
HANDOFF = 0.85
USAGE_TTL_S = 60
MODELS_TTL_S = 12 * 3600
STRATA_HEALTH = "http://127.0.0.1:8080/health"
CLOUD = ("anthropic", "openai-codex")
AGENT = {"heavy": "route-heavy", "medium": "route-medium", "light": "route-light"}


def models() -> dict:
    if not MODELS.exists() or time.time() - MODELS.stat().st_mtime > MODELS_TTL_S:
        subprocess.run([sys.executable, str(HERE / "sync-models.py")], check=True, capture_output=True, timeout=60)
    return json.loads(MODELS.read_text())


def usage() -> dict:
    if USAGE_CACHE.exists() and time.time() - USAGE_CACHE.stat().st_mtime < USAGE_TTL_S:
        return json.loads(USAGE_CACHE.read_text())
    out = subprocess.run(["omp", "usage", "--json"], check=True, capture_output=True, text=True, timeout=30).stdout
    data = json.loads(out)
    STATE.mkdir(exist_ok=True)
    USAGE_CACHE.write_text(json.dumps(data))
    return data


def provider_state(data: dict) -> dict[str, dict]:
    """Per provider, the best account: lowest peak window usage."""
    best: dict[str, dict] = {}
    for report in data.get("reports", []):
        p = report.get("provider")
        if p not in CLOUD:
            continue
        peak, exhausted, resets = 0.0, bool((report.get("metadata") or {}).get("limitReached")), []
        for lim in report.get("limits", []):
            used = (lim.get("amount") or {}).get("usedFraction")
            used = 0.0 if used is None else float(used)
            peak = max(peak, used)
            if lim.get("status") == "exhausted" or used >= 1.0:
                exhausted = True
            if used >= HANDOFF and (lim.get("window") or {}).get("resetsAt"):
                resets.append(lim["window"]["resetsAt"])
        cur = {"peak": round(peak, 3), "exhausted": exhausted, "resetsAt": max(resets) if exhausted and resets else min(resets, default=None)}
        if p not in best or (cur["exhausted"], cur["peak"]) < (best[p]["exhausted"], best[p]["peak"]):
            best[p] = cur
    return best


def strata_up() -> bool:
    try:
        with urllib.request.urlopen(STRATA_HEALTH, timeout=3) as r:
            return bool(json.load(r).get("loaded"))
    except Exception:
        return False


def decide(tier: str, current: str | None) -> dict:
    m, states = models(), provider_state(usage())
    others = [p for p in CLOUD if p != current and p in states]
    for p in others:
        if not states[p]["exhausted"]:
            return {"action": "spawn", "provider": p, "model": m[p][tier],
                    "reason": f"{p} first (other provider, peak {states[p]['peak']:.0%})"}
    if current in states and states[current]["peak"] < HANDOFF and not states[current]["exhausted"]:
        return {"action": "spawn", "provider": current, "model": m[current][tier],
                "reason": f"others exhausted; {current} at {states[current]['peak']:.0%} < {HANDOFF:.0%}"}
    resets = [s["resetsAt"] for s in states.values() if s["resetsAt"]]
    if tier == "heavy":
        when = time.strftime("%Y-%m-%d %H:%M", time.localtime(min(resets) / 1000)) if resets else "unknown"
        return {"action": "pause", "provider": None, "model": None, "resetsAt": min(resets, default=None),
                "reason": f"heavy work never goes to Strata; every provider is limited. Earliest reset {when}"}
    up = strata_up()
    return {"action": "spawn" if up else "start-strata", "provider": "strata", "model": m["strata"],
            "reason": "cloud providers limited; using local Strata" + ("" if up else " (not running: run strata.sh start)")}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tier", choices=list(AGENT), required=True)
    ap.add_argument("--current", help="provider of the session model (e.g. anthropic)")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    d = decide(a.tier, a.current)
    d.update(tier=a.tier, agent=AGENT[a.tier])
    print(json.dumps(d) if a.json else f"{d['action']}: {d['agent']} -> {d['model']} ({d['reason']})")
    return {"spawn": 0, "start-strata": 3, "pause": 4}[d["action"]]


if __name__ == "__main__":
    sys.exit(main())
