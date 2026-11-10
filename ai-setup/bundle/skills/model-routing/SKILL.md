---
name: model-routing
description: Use before delegating work to subagents. Picks the subagent tier (heavy/medium/light), spreads load across Anthropic and OpenAI Codex by live usage, hands light/medium work to local Strata near limits, and manages Strata's lifecycle.
---

# Model routing for subagents

Delegate reasonably sized chunks of work to subagents so token use spreads across providers.
The `model-routing` extension picks each spawn's model from live `omp usage`; your job is the
**tier** and the **Strata lifecycle**.

## 1. Pick the tier → agent

| Agent | Use for | Models (newest of each) |
|---|---|---|
| `route-heavy` | Large or complex work; real reasoning, design or decisions; anything whose mistakes are costly | Opus / Sol |
| `route-medium` | Ordinary multi-step implementation, investigation, tests | Sonnet / Terra |
| `route-light` | Small, mechanical, fully specified work that needs little thinking | Haiku / Luna |

Pick the lowest tier that will do the job well; when unsure, go one tier up. Never use the
Fable/Astra tier. All tiers run at medium thinking. Specialised agents (`reviewer`, `scout`, ...)
keep their own models; prefer `route-*` for implementation chunks.

## 2. What the extension does on each `route-*` spawn

1. The provider **other** than this session's goes first, unless its usage limit is reached.
2. Then this session's provider, while both its 5-hour and 7-day windows are under **85%**.
3. Then: light/medium → local Strata. Heavy → the spawn is **refused with the reset time**.

Preview a decision: `python3 ~/.omp/agent/skills/model-routing/route.py --tier medium --current anthropic`
(exit 0 spawn, 3 start Strata first, 4 pause).

## 3. When a spawn is refused

- **"Run strata.sh start"**: start Strata, then retry the same spawn:
  `~/.omp/agent/skills/model-routing/strata.sh start` (takes ~30 s to a few min; default context
  262144 (the model's trained maximum) and 3072 MiB VRAM reserve; it halves the context to fit
  free RAM, never below 65536).
- **Not enough RAM** (exit 2): it lists the largest processes. You may free memory used by the
  current work (your own finished background jobs, emulators, dev servers, builds you started).
  **Never kill anything else**; if that is not enough, tell the user and stop.
- **"Pause until …"** (heavy work, every provider limited): don't downgrade heavy work to a lower
  tier or Strata. Split off any light/medium parts and route those; otherwise stop and tell the
  user the reset time.

## 4. Stop Strata when done

Once no Strata-routed subagent is still running, run
`~/.omp/agent/skills/model-routing/strata.sh stop`. It stops only a Strata this skill started and
refuses while a request is in flight (retry later). The extension also stops it at session exit.
`strata.sh status` shows whether it is up and who started it.

## 5. New models

`route.py` refreshes the model list every 12 h. After a provider ships a new model, run
`python3 ~/.omp/agent/skills/model-routing/sync-models.py`: it rewrites `state/models.json` and
the `route-*` agent files (their fallback chains) to the newest model of each tier.
