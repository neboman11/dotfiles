#!/usr/bin/env python3
"""Find the newest model per provider and tier, write state/models.json, and point the
route-{heavy,medium,light} agents at them (fallback chain: other provider, then current).

Tiers: heavy = opus/sol, medium = sonnet/terra, light = haiku/luna. Fable/Astra excluded.
"""
from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

STRATA = Path.home() / "Desktop/Strata"
HERE = Path(__file__).resolve().parent
AGENTS = Path.home() / ".omp/agent/agents"
TIERS = {"heavy": ("opus", "sol"), "medium": ("sonnet", "terra"), "light": ("haiku", "luna")}
# claude-opus-5-5 / claude-opus-5 (dated ids like claude-opus-4-5-20251101 are aliases, skipped)
CLAUDE = re.compile(r"^claude-(opus|sonnet|haiku)-(\d+)(?:-(\d{1,2}))?$")
# gpt-6.1-sol / gpt-6-luna
GPT = re.compile(r"^gpt-(\d+)(?:\.(\d+))?-(sol|terra|luna)$")
DESCRIPTION = {
    "heavy": "Heavy-tier worker (Opus/Sol class): large, complex, reasoning- or decision-heavy subtasks. Model is chosen per spawn by the model-routing extension.",
    "medium": "Medium-tier worker (Sonnet/Terra class): ordinary multi-step implementation and investigation. Model is chosen per spawn by the model-routing extension; may run on local Strata.",
    "light": "Light-tier worker (Haiku/Luna class): small, mechanical, well-specified subtasks needing little reasoning. Model is chosen per spawn by the model-routing extension; may run on local Strata.",
}
BODY = """You are a delegated worker. Execute the task's Target/Change/Acceptance sections exactly.
Read the referenced files first, reuse existing patterns, keep diffs focused, run the verification
the task names, and report concrete evidence (commands run, results) plus any deviation with its reason.
"""


def newest(rows: list[dict]) -> dict:
    best: dict[str, dict[str, tuple]] = {"anthropic": {}, "openai-codex": {}}
    for r in rows:
        p, i = r.get("provider"), r.get("id", "")
        if p == "anthropic" and (m := CLAUDE.match(i)):
            name, ver = m[1], (int(m[2]), int(m[3] or 0))
        elif p == "openai-codex" and (m := GPT.match(i)):
            name, ver = m[3], (int(m[1]), int(m[2] or 0))
        else:
            continue
        tier = next(t for t, names in TIERS.items() if name in names)
        if tier not in best[p] or ver > best[p][tier][0]:
            best[p][tier] = (ver, f"{p}/{i}")
    out = {p: {t: v[1] for t, v in tiers.items()} for p, tiers in best.items()}
    for p in out:
        missing = set(TIERS) - set(out[p])
        if missing:
            raise SystemExit(f"no {sorted(missing)} model found for {p}")
    # omp lists llama.cpp only while Strata is up; its id is the model_name of the newest Strata config.
    configs = sorted(STRATA.glob("strata-*.json"), key=lambda f: f.stat().st_mtime, reverse=True)
    name = next((json.loads(f.read_text()).get("model_name") for f in configs), None)
    if not name:
        raise SystemExit(f"no Strata config with a model_name in {STRATA}")
    out["strata"] = f"llama.cpp/{name}"
    return out


def write_agent(tier: str, m: dict) -> None:
    chain = [m["openai-codex"][tier], m["anthropic"][tier]] + ([m["strata"]] if tier != "heavy" else [])
    text = (f"---\nname: route-{tier}\ndescription: {DESCRIPTION[tier]}\n"
            f"model: [{', '.join(chain)}]\nthinking-level: medium\n---\n\n{BODY}")
    path = AGENTS / f"route-{tier}.md"
    if not path.exists() or path.read_text() != text:
        path.write_text(text)


def main() -> None:
    raw = subprocess.run(["omp", "models", "--json"], check=True, capture_output=True, text=True, timeout=60).stdout
    data = json.loads(raw)
    m = newest(data["models"] if isinstance(data, dict) else data)
    (HERE / "state").mkdir(exist_ok=True)
    (HERE / "state/models.json").write_text(json.dumps(m, indent=2) + "\n")
    for tier in TIERS:
        write_agent(tier, m)
    print(json.dumps(m, indent=2))


if __name__ == "__main__":
    main()
