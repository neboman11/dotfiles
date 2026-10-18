#!/usr/bin/env bash
# Exercise the real install function without downloading tools or changing ~/.local/bin.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

(
  set -- --help
  source "$ROOT/setup-ai-tools.sh" >/dev/null
  trap - EXIT

  # Redirect filesystem commands to the fixture; keep run's dry-run behavior.
  eval "$(declare -f run | sed '1s/run/original_run/')"
  run() {
    local arg args=()
    for arg in "$@"; do
      if [ "$arg" = "$HOME/.local/bin" ]; then arg="$TEST_ROOT/bin"; fi
      args+=("$arg")
    done
    original_run "${args[@]}"
  }
  have() { return 1; }
  run_sh() {
    if ((DRY)); then return 0; fi
    # Match the upstream installer's refusal of a writable install directory.
    local mode
    mode=$(stat -c %a "$TEST_ROOT/bin")
    if (( (8#$mode & 8#022) != 0 )); then
      echo 'FAIL: installer received a group/world-writable directory' >&2
      return 1
    fi
    touch "$TEST_ROOT/installed"
  }

  mkdir "$TEST_ROOT/bin"
  chmod 777 "$TEST_ROOT/bin"
  DRY=1
  install_cbm
  [ "$(stat -c %a "$TEST_ROOT/bin")" = 777 ]
  [ ! -e "$TEST_ROOT/installed" ]

  DRY=0
  install_cbm
  [ -f "$TEST_ROOT/installed" ]
  [ "$(stat -c %a "$TEST_ROOT/bin")" = 755 ]

  # Fresh installs also work, including under a group-writable umask.
  rmdir "$TEST_ROOT/bin"
  umask 002
  install_cbm
  [ "$(stat -c %a "$TEST_ROOT/bin")" = 755 ]
)
echo 'PASS: CBM install directory permissions and dry-run behavior'
