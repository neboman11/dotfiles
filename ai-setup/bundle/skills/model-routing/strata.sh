#!/usr/bin/env bash
# Start/stop/inspect local Strata for model routing.
#   strata.sh start [CONTEXT] [RESERVE_MIB]   default 262144 3072; context shrinks to fit free RAM (floor 65536)
#   strata.sh stop [--force]                  stops Strata only if this script started it; refuses while busy
#   strata.sh status
# A plain `./setup.sh` start ignores --context (only setup applies it), so this launches the server
# directly with a copy of the newest Strata config whose --max-context / --vram-reserve-mib are set.
set -euo pipefail

STRATA="$HOME/Desktop/Strata"
STATE="$(cd "$(dirname "$0")" && pwd)/state"
PIDFILE="$STATE/strata.pgid"
URL="http://127.0.0.1:8080"
MODEL_RAM_GIB=37         # measured: MemAvailable fell ~40 GiB on a 256K-context start (KV ~3.4 GiB of that)
KV_KIB_PER_TOKEN=14      # int8 KV cache: ~13.7 KB per context token
MARGIN_GIB=3             # headroom for the rest of the system
MIN_CONTEXT=65536

mkdir -p "$STATE"

healthy() { curl -fsS -m 3 "$URL/health" 2>/dev/null | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("loaded") else 1)' 2>/dev/null; }
busy() { curl -fsS -m 3 "$URL/status" 2>/dev/null | python3 -c 'import json,sys; s=json.load(sys.stdin); sys.exit(0 if s.get("busy") or s.get("queued") else 1)' 2>/dev/null; }
avail_gib() { awk '/MemAvailable/ {printf "%d", $2/1048576}' /proc/meminfo; }
need_gib() { echo $(( MODEL_RAM_GIB + MARGIN_GIB + $1 * KV_KIB_PER_TOKEN / 1048576 )); }

status() {
  if healthy; then
    curl -fsS -m 3 "$URL/health"; echo
    [[ -f "$PIDFILE" ]] && echo "started by model-routing (pgid $(cat "$PIDFILE"))" || echo "started outside model-routing"
  else
    echo "strata: down"
  fi
  echo "RAM available: $(avail_gib) GiB"
}

start() {
  local ctx="${1:-262144}" reserve="${2:-3072}"
  if healthy; then echo "strata: already running"; status; return 0; fi
  if ss -ltn 2>/dev/null | grep -q ':8080 '; then echo "port 8080 is taken by something that is not a healthy Strata" >&2; return 1; fi
  while (( ctx > MIN_CONTEXT )) && (( $(avail_gib) < $(need_gib "$ctx") )); do ctx=$(( ctx / 2 )); done
  if (( $(avail_gib) < $(need_gib "$ctx") )); then
    echo "not enough RAM: $(avail_gib) GiB available, $(need_gib "$ctx") GiB needed at context $ctx." >&2
    echo "Largest memory users (free only what belongs to the current work; never kill anything else):" >&2
    ps -eo pid,rss,args --sort=-rss | awk 'NR>1 && NR<=11 {printf "  %7s %6d MiB  %.110s\n", $1, $2/1024, substr($0, index($0,$3))}' >&2
    return 2
  fi
  local cfg; cfg=$(ls -t "$STRATA"/strata-*.json | head -1)
  python3 - "$cfg" "$STATE/strata-run.json" "$ctx" "$reserve" <<'EOF'
import json, sys
src, dst, ctx, reserve = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
cfg = json.load(open(src, encoding="utf-8-sig"))
a = cfg["args"]
for flag, val in (("--max-context", ctx), ("--vram-reserve-mib", reserve)):
    if flag in a[:-1]:
        a[a.index(flag) + 1] = val
    else:
        a += [flag, val]
json.dump(cfg, open(dst, "w"), indent=2)
EOF
  echo "starting Strata: context $ctx, VRAM reserve $reserve MiB (from $(basename "$cfg"))"
  ( cd "$STRATA" && exec setsid "$STRATA/.venv/bin/python" serve/server.py --engine strata \
      --config "$STATE/strata-run.json" --port 8080 >"$STATE/strata.log" 2>&1 ) &
  local pid=$!
  echo "$pid" >"$PIDFILE"     # setsid makes the server its own group leader: pgid == pid
  for _ in $(seq 1 120); do
    if healthy; then echo "strata: ready"; status; return 0; fi
    if ! kill -0 "$pid" 2>/dev/null; then echo "strata exited during startup; log: $STATE/strata.log" >&2; tail -20 "$STATE/strata.log" >&2; rm -f "$PIDFILE"; return 1; fi
    sleep 5
  done
  echo "strata did not become healthy in 10 min; stopping it" >&2
  stop --force; return 1
}

stop() {
  if [[ ! -f "$PIDFILE" ]]; then echo "strata: not started by model-routing; leaving it alone"; return 0; fi
  local pgid; pgid=$(cat "$PIDFILE")
  if ! ps -o args= -p "$pgid" 2>/dev/null | grep -q "serve/server.py.*$STATE/strata-run.json"; then
    echo "strata: recorded process $pgid is gone or not ours; clearing the record"; rm -f "$PIDFILE"; return 0
  fi
  if [[ "${1:-}" != "--force" ]] && busy; then echo "strata: busy with a request; not stopping" >&2; return 3; fi
  kill -TERM -- "-$pgid" 2>/dev/null || true
  for _ in $(seq 1 30); do kill -0 -- "-$pgid" 2>/dev/null || break; sleep 1; done
  kill -KILL -- "-$pgid" 2>/dev/null || true
  rm -f "$PIDFILE"
  echo "strata: stopped"
}

case "${1:-status}" in
  start) shift; start "$@" ;;
  stop) shift; stop "$@" ;;
  status) status ;;
  *) echo "usage: $0 start [CONTEXT] [RESERVE_MIB] | stop [--force] | status" >&2; exit 64 ;;
esac
