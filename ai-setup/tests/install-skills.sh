#!/usr/bin/env bash
# Exercise local Skills CLI ownership, omp precedence, dry runs, and failed installs.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
export npm_config_cache="${npm_config_cache:-$HOME/.npm}"
trap 'rm -rf "$TEST_ROOT"' EXIT
(
  set -- --help
  source "$ROOT/setup-ai-tools.sh" >/dev/null
  trap - EXIT
  export HOME="$TEST_ROOT/home"
  SRC_ROOT="$HOME/.local/share/ai-setup"
  BACKUP_ROOT="$HOME/backups"
  STAGE="$TEST_ROOT/bundle"
  T_OMP=1
  mkdir -p "$STAGE/skills/example" "$HOME/.agents/skills/example" "$HOME/.omp/agent/skills/example/state"
  printf '%s\n' '---' 'name: example' 'description: Local migration fixture.' '---' 'New instructions.' >"$STAGE/skills/example/SKILL.md"
  printf './skills\texample\n' >"$STAGE/skills.tsv"
  echo 'Untracked instructions.' >"$HOME/.agents/skills/example/SKILL.md"
  echo 'Old omp instructions.' >"$HOME/.omp/agent/skills/example/SKILL.md"
  echo 'Retain runtime state.' >"$HOME/.omp/agent/skills/example/state/cache"

  DRY=1
  install_skills
  [ ! -e "$HOME/.agents/.skill-lock.json" ]
  [ ! -e "$SRC_ROOT/skills" ]
  [ ! -L "$HOME/.omp/agent/skills/example" ]

  DRY=0
  install_skills
  cmp "$STAGE/skills/example/SKILL.md" "$HOME/.omp/agent/skills/example/SKILL.md"
  [ "$(readlink "$HOME/.omp/agent/skills/example")" = "$HOME/.agents/skills/example" ]
  [ "$(cat "$HOME/.omp/agent/skills/example/state/cache")" = 'Retain runtime state.' ]
  [ "$(cat "$BACKUP_ROOT/.agents/skills/example/SKILL.md")" = 'Untracked instructions.' ]
  jq -e --arg src "$SRC_ROOT/skills" '.skills.example | .sourceType == "local" and .source == $src' "$HOME/.agents/.skill-lock.json" >/dev/null
  lock_before=$(sha256sum "$HOME/.agents/.skill-lock.json")
  install_skills
  [ "$(sha256sum "$HOME/.agents/.skill-lock.json")" = "$lock_before" ]
  [ ! -d "$HOME/.claude" ] && [ ! -d "$HOME/.codex" ] && [ ! -d "$HOME/.pi" ]

  printf '\nRevised local instructions.\n' >>"$STAGE/skills/example/SKILL.md"
  install_skills
  cmp "$STAGE/skills/example/SKILL.md" "$HOME/.omp/agent/skills/example/SKILL.md"
  [ "$(cat "$HOME/.omp/agent/skills/example/state/cache")" = 'Retain runtime state.' ]

  # Account-owned instructions remain a local source, never public bundle content.
  printf '~/.claude/skills/synced\tprivate-example\n' >>"$STAGE/skills.tsv"
  install_skills
  [ ! -e "$HOME/.agents/skills/private-example" ]
  mkdir -p "$HOME/.claude/skills/synced/account-id/private-example"
  printf '%s\n' '---' 'name: private-example' 'description: Private account fixture.' '---' 'PRIVATE ACCOUNT CONTENT' >"$HOME/.claude/skills/synced/account-id/private-example/SKILL.md"
  install_skills
  cmp "$HOME/.claude/skills/synced/account-id/private-example/SKILL.md" "$HOME/.omp/agent/skills/private-example/SKILL.md"
  printf '\nUpdated private instructions.\n' >>"$HOME/.claude/skills/synced/account-id/private-example/SKILL.md"
  install_skills
  cmp "$HOME/.claude/skills/synced/account-id/private-example/SKILL.md" "$HOME/.omp/agent/skills/private-example/SKILL.md"
  mkdir -p "$TEST_ROOT/external/extra"
  printf '%s\n' '---' 'name: extra' 'description: Independent local source.' '---' 'Extra instructions.' >"$TEST_ROOT/external/extra/SKILL.md"
  npx -y skills add "$TEST_ROOT/external" --skill extra -g -a universal -y </dev/null
  (
    export USER=nonexistent-export-user
    have() { [ "$1" = jq ]; }
    ensure_repo() { mkdir -p "$SRC_ROOT/$1"; }
    trap cleanup EXIT
    cmd_export "$TEST_ROOT/export"
  )
  cmp "$STAGE/skills/example/SKILL.md" "$TEST_ROOT/export/skills/example/SKILL.md"
  cmp "$TEST_ROOT/external/extra/SKILL.md" "$TEST_ROOT/export/skills/extra/SKILL.md"
  [ ! -e "$TEST_ROOT/export/skills/example/state" ]
  [ ! -e "$TEST_ROOT/export/skills/private-example" ]
  ! grep -Rq 'PRIVATE ACCOUNT CONTENT\|account-id' "$TEST_ROOT/export"
  grep -Fq '~/.claude/skills/synced' "$TEST_ROOT/export/skills.tsv"

  # Explicit legacy target still gets discoverable links; omp-only never selects it.
  T_CLAUDE=1
  install_skills
  cmp "$STAGE/skills/example/SKILL.md" "$HOME/.claude/skills/example/SKILL.md"
  T_CLAUDE=0

  # Existing standalone copies must not keep shadowing the migrated omp version.
  rm "$HOME/.claude/skills/example"
  mkdir "$HOME/.claude/skills/example"
  echo 'Stale standalone instructions.' >"$HOME/.claude/skills/example/SKILL.md"
  mkdir -p "$HOME/.codex/skills/example"
  echo 'Stale Codex instructions.' >"$HOME/.codex/skills/example/SKILL.md"
  install_skills
  [ -L "$HOME/.claude/skills/example" ]
  cmp "$STAGE/skills/example/SKILL.md" "$HOME/.claude/skills/example/SKILL.md"
  [ -L "$HOME/.codex/skills/example" ]
  cmp "$STAGE/skills/example/SKILL.md" "$HOME/.codex/skills/example/SKILL.md"

  # An existing folder must not make an unavailable source look successful.
  printf './missing\texample\n' >"$STAGE/skills.tsv"
  if (install_skills) >"$TEST_ROOT/failure.log" 2>&1; then
    echo 'FAIL: unavailable source reported success' >&2
    exit 1
  fi
)
echo 'PASS: skill ownership, target isolation, state, idempotence, private export, dry-run, and failures'
