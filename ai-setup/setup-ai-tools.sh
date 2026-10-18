#!/usr/bin/env bash
# setup-ai-tools.sh — replicate this workstation's AI agent tooling on another Linux machine.
#
#   On the source machine:   ./setup-ai-tools.sh export [DIR]      # writes ./bundle/ (or DIR)
#   On the new machine:      ./setup-ai-tools.sh install [targets] # tools + configuration
#
# Targets (default: --omp):  --omp --claude --codex --opencode --openclaw --all
# Options:
#   --bundle DIR    bundle to restore (default: bundle/ next to this script)
#   --no-tools      skip installing binaries; only configure
#   --no-config     skip configuration; only install binaries
#   --no-headroom   skip the Headroom proxy (~/.venv) install
#   --dry-run       print what would change without changing anything
#
# Third-party content is installed by its own tooling, never copied from the bundle:
#   skills            `npx skills add` from the sources in bundle/skills.tsv (skills lock)
#   ECC               upstream clone: scripts/sync-ecc-to-codex.sh (Codex), its prompts are
#                     converted to ecc-*.md commands for Claude Code and OpenCode
#   caveman           upstream clone: install.sh (OpenCode, OpenClaw), Claude plugin,
#                     `caveman enable` (proxy routing), `caveman skills install`
#   codebase-memory   `codebase-memory-mcp install` (hooks, MCP, skills, agents)
#   codegraph, rtk    `codegraph install`, `rtk init`
#   browser-use       `browser-use skill`
#   plugins           `claude plugin install`, `codex plugin add`
# The bundle holds only this user's own configuration: settings, MCP servers, curated task
# agents, custom skills, and a personal CLAUDE.md section. Upstream clones live in
# ~/.local/share/ai-setup/ (update them with `git pull` there, then re-run).
#
# Idempotent: every step checks current state first. Files that differ from the bundle are
# backed up to ~/.ai-setup-backups/<timestamp>/ before being replaced. JSON configs are
# deep-merged (bundle keys win, arrays are unioned) and Codex config.toml is merged per table,
# so entries written by the tools above, auth, and trusted projects survive re-runs.
#
# Never exported (the bundle is meant for a public dotfiles repo): credentials/auth files,
# sessions, history, databases, caches, logs, Codex command-approval rules, OpenClaw
# persona/memory files, Claude.ai account-synced skills (Anthropic-licensed), Superset-managed
# files, and local-model configuration (Ollama, Strata). Export fails if anything still looks
# like a credential or contains your login name.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DEFAULT_BUNDLE="$SCRIPT_DIR/bundle"
SRC_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/ai-setup"
HOME_TOKEN='@@HOME@@'
BACKUP_ROOT="$HOME/.ai-setup-backups/$(date +%Y%m%d-%H%M%S)"
DRY=0
STAGE=""

ECC_URL=https://github.com/affaan-m/ECC.git
CAVEMAN_URL=https://github.com/JuliusBrussee/caveman.git
CBM_AGENTS=(codebase-memory codebase-memory-scout codebase-memory-auditor)
# Hook commands owned by installers this script runs (or by the Superset app).
TOOL_HOOK_RE='caveman-proxy.{0,2} native-hook|caveman.{0,2} shrink-hook|cbm-|codebase-memory-mcp.{0,2} hook-augment|codegraph prompt-hook|^rtk hook|SUPERSET_HOME_DIR'
# MCP servers registered by installers this script runs.
TOOL_MCP_RE='^(caveman|codegraph|codebase-memory-mcp)$'

export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
run()  { if ((DRY)); then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }
run_sh() { if ((DRY)); then printf '  [dry-run] %s\n' "$1"; else bash -c "$1"; fi; }
cleanup() { [ -n "$STAGE" ] && rm -rf "$STAGE"; return 0; }
trap cleanup EXIT

SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

# Deep merge: objects recurse, arrays union (append missing elements), scalars from $b win.
JQ_DM='
def dm($a; $b):
  if ($a | type) == "object" and ($b | type) == "object" then
    reduce ($b | keys_unsorted[]) as $k ($a; .[$k] = dm($a[$k]; $b[$k]))
  elif ($a | type) == "array" and ($b | type) == "array" then
    reduce $b[] as $e ($a; if any(.[]; . == $e) then . else . + [$e] end)
  elif $b == null then $a
  else $b end;
'
JQ_STRIP_HOOKS='
def strip_tool_hooks($re):
  if .hooks then
    .hooks |= (with_entries(.value |= map(select([.hooks[]?.command // ""] | any(test($re)) | not)))
               | with_entries(select(.value | length > 0)))
    | if .hooks == {} then del(.hooks) else . end
  else . end;
'

# ensure_repo <name> <url>: shallow clone into $SRC_ROOT once; never auto-updates.
ensure_repo() {
  local dir="$SRC_ROOT/$1"
  if [ -d "$dir/.git" ]; then ok "$1 source present ($(git -C "$dir" rev-parse --short HEAD))"; return; fi
  run mkdir -p "$SRC_ROOT"
  run git clone -q --depth 1 "$2" "$dir"
}

# ─────────────────────────────────────────────────────────────────────────────
# Export (source machine)
# ─────────────────────────────────────────────────────────────────────────────

TAR_EXCLUDES=(
  --exclude=node_modules --exclude=.git --exclude=__pycache__
  --exclude='*.bak' --exclude='*.bak.*' --exclude='*.backup-*' --exclude='*.headroom-backup'
  --exclude='*.db' --exclude='*.db-*' --exclude='*.sqlite' --exclude='*.sqlite-*' --exclude='*.lock'
)

# stage_copy <component> <path relative to $HOME>...  (missing paths are skipped)
stage_copy() {
  local comp=$1; shift
  local p dest="$STAGE/$comp/home"
  mkdir -p "$dest"
  for p in "$@"; do
    [ -e "$HOME/$p" ] || [ -L "$HOME/$p" ] || continue
    tar -C "$HOME" -cf - "${TAR_EXCLUDES[@]}" "$p" | tar -C "$dest" -xf -
  done
}

# Codex config.toml minus machine-local tables (trusted projects, hook trust, TUI state),
# tables owned by installers (caveman, codegraph, codebase-memory-mcp, codex plugins), and
# all comments (tool block markers). Top-level keys only, no comments, so merges are stable.
codex_toml_sanitize() {
  awk '
    /^# >>> caveman:native-root/ { inroot = 1; next }
    /^# <<< caveman:native-root/ { inroot = 0; next }
    inroot || /^#/ { next }
    /^\[/ { drop = ($0 ~ /^\[(projects[.]|hooks\.state[].]|tui[].]|notice[].]|marketplaces[.]|plugins[.]|model_providers\.caveman[].]|mcp_servers\.(caveman|codegraph|codebase-memory-mcp)[].])/) }
    drop { next }
    { print }
  ' "$1" | cat -s | sed '/./,$!d'
}

# Enabled Codex plugins with their marketplace source: "<plugin@market>\t<source>".
codex_plugins_list() {
  awk '
    /^\[/ { sec = $0; next }
    sec ~ /^\[marketplaces\./ && /^source *=/ {
      m = sec; sub(/^\[marketplaces\./, "", m); sub(/\]$/, "", m)
      s = $0; sub(/^source *= *"/, "", s); sub(/"$/, "", s); src[m] = s
    }
    sec ~ /^\[plugins\."/ && /^enabled *= *true/ {
      p = sec; sub(/^\[plugins\."/, "", p); sub(/"\]$/, "", p); ids[p] = 1
    }
    END { for (p in ids) { split(p, a, "@"); print p "\t" src[a[2]] } }
  ' "$1"
}

# Personal part of ~/.claude/CLAUDE.md: drop blocks that rtk/codegraph/codebase-memory-mcp
# inject (they re-inject them on install).
claude_md_user_section() {
  awk '
    /^@RTK\.md$/ { next }
    /<!-- CODEGRAPH_START -->/ { skip = 1 }
    /<!-- codebase-memory-mcp:start -->/ { skip = 1 }
    /<!-- ai-setup:(begin|end) -->/ { next }
    !skip { print }
    /<!-- CODEGRAPH_END -->/ || /<!-- codebase-memory-mcp:end -->/ { skip = 0 }
  ' "$1" | cat -s | sed '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
}

drop_cbm_agents() {
  local dir=$1 ext=$2 n
  for n in "${CBM_AGENTS[@]}"; do rm -f "$dir/$n.$ext"; done
}

cmd_export() {
  local out=${1:-$DEFAULT_BUNDLE}
  have jq || die "jq is required"
  STAGE=$(mktemp -d)
  log "Staging configuration from $HOME"

  # Skills: third-party ones are reinstalled from their sources; only custom skills ship.
  local lock="$HOME/.agents/.skill-lock.json" custom=() d n
  [ -f "$lock" ] &&
    jq -r '.skills | to_entries | group_by(.value.source)[]
           | "\(.[0].value.source)\t\(map(.key) | join(","))"' "$lock" >"$STAGE/skills.tsv"
  for d in "$HOME"/.agents/skills/*/; do
    n=$(basename "$d")
    case $n in browser-use | codebase-memory | superset*) continue ;; esac  # tool/app-installed
    [ -f "$lock" ] && jq -e --arg n "$n" '.skills | has($n)' "$lock" >/dev/null && continue
    custom+=("$n")
  done
  for n in "${custom[@]}"; do stage_copy core ".agents/skills/$n"; done
  stage_copy core .config/rtk
  mkdir -p "$STAGE/core"
  [ -f "$HOME/.claude/CLAUDE.md" ] && claude_md_user_section "$HOME/.claude/CLAUDE.md" >"$STAGE/core/CLAUDE.user.md"

  # omp: settings and curated task agents. models.yml is owned by `headroom wrap omp`.
  stage_copy omp .omp/agent/config.yml .omp/agent/agents .omp/agent/AGENTS.md
  drop_cbm_agents "$STAGE/omp/home/.omp/agent/agents" md
  mkdir -p "$STAGE/omp/merge"
  if [ -f "$HOME/.omp/agent/mcp.json" ]; then
    cp "$HOME/.omp/agent/mcp.json" "$STAGE/omp/merge/mcp.json"
  elif [ -f "$HOME/.claude.json" ]; then
    # omp has no installer integrations; give it the full server list Claude Code has.
    jq '{mcpServers: (.mcpServers // {}
          | if .serena then .serena.args |= map(if . == "claude-code" then "agent" else . end) else . end)}' \
      "$HOME/.claude.json" >"$STAGE/omp/merge/mcp.json"
  fi

  # claude: curated agents, custom-skill links, settings, user MCP servers, plugin list.
  stage_copy claude .claude/agents
  drop_cbm_agents "$STAGE/claude/home/.claude/agents" md
  for n in "${custom[@]}"; do stage_copy claude ".claude/skills/$n"; done
  mkdir -p "$STAGE/claude/merge"
  [ -f "$HOME/.claude/settings.json" ] &&
    jq --arg re "$TOOL_HOOK_RE" "$JQ_STRIP_HOOKS
        strip_tool_hooks(\$re)
        | if .env then .env |= (with_entries(select((.value | tostring | test(\":8787\")) | not))
                                | del(._CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL)) else . end
        | if .permissions.allow then .permissions.allow |= map(select(startswith(\"mcp__codegraph__\") | not)) else . end" \
      "$HOME/.claude/settings.json" >"$STAGE/claude/merge/settings.json"
  [ -f "$HOME/.claude.json" ] &&
    jq --arg re "$TOOL_MCP_RE" '{mcpServers: ((.mcpServers // {}) | with_entries(select(.key | test($re) | not)))}' \
      "$HOME/.claude.json" >"$STAGE/claude/merge/claude.json"
  local pdir="$HOME/.claude/plugins"
  [ -f "$pdir/installed_plugins.json" ] &&
    jq -n --slurpfile i "$pdir/installed_plugins.json" --slurpfile k "$pdir/known_marketplaces.json" '{
        plugins: ($i[0].plugins | keys),
        marketplaces: ($k[0] | with_entries(.value = (.value.source as $s
          | if $s.source == "github" then $s.repo else ($s.url // $s.path // empty) end)))
      }' >"$STAGE/claude/plugins.json"

  # codex: curated agents (minus those ECC's sync and codebase-memory-mcp install), config.
  ensure_repo ECC "$ECC_URL"
  stage_copy codex .codex/agents
  drop_cbm_agents "$STAGE/codex/home/.codex/agents" toml
  local f
  for f in "$STAGE"/codex/home/.codex/agents/*.toml; do
    [ -f "$SRC_ROOT/ECC/.codex/agents/$(basename "$f")" ] && rm -f "$f"   # ECC sync ships these
  done
  if [ -f "$HOME/.codex/config.toml" ]; then
    codex_toml_sanitize "$HOME/.codex/config.toml" >"$STAGE/codex/config.toml"
    codex_plugins_list "$HOME/.codex/config.toml" >"$STAGE/codex/plugins.tsv"
  fi

  # opencode: curated agents, TUI settings, config (Strata = local model server → dropped).
  stage_copy opencode .config/opencode/agents .config/opencode/tui.json
  drop_cbm_agents "$STAGE/opencode/home/.config/opencode/agents" md
  mkdir -p "$STAGE/opencode/merge"
  [ -f "$HOME/.config/opencode/opencode.json" ] &&
    jq --arg re "$TOOL_MCP_RE" 'del(.provider.strata)
        | if ((.model // "") | startswith("strata/")) then del(.model) else . end
        | if .provider == {} then del(.provider) else . end
        | if .mcp then .mcp |= with_entries(select(.key | test($re) | not)) else . end
        | if .plugin then .plugin |= map(select(test("plugins/caveman") | not)) else . end' \
      "$HOME/.config/opencode/opencode.json" >"$STAGE/opencode/merge/opencode.json"

  # openclaw: agent/tool/skill settings only. Gateway auth, channels (Signal), secrets,
  # workspace persona/memory files, and Ollama/Strata providers + memory search stay behind.
  mkdir -p "$STAGE/openclaw/merge"
  [ -f "$HOME/.openclaw/openclaw.json" ] &&
    jq --arg re "$TOOL_MCP_RE" '{agents, mcp, skills, hooks, session, messages, browser,
         tools: (.tools | if . then del(.elevated) else . end),
         commands: (.commands | if . then del(.ownerAllowFrom) else . end),
         plugins: (.plugins | if . then del(.entries.ollama) else . end)}
        | if .mcp.servers then .mcp.servers |= with_entries(select(.key | test($re) | not)) else . end
        | if .agents.defaults.models then
            .agents.defaults.models |= with_entries(select(.key | test("^(ollama|strata)/") | not))
          else . end
        | with_entries(select(.value != null))
        | walk(if type == "object" then with_entries(select(
            ((.key | test("token|secret|password|api.?key"; "i")) and (.value | type == "string")) | not))
          elif type == "array" then map(select(type != "string" or (test("^(ollama|strata)/") | not)))
          else . end)' \
      "$HOME/.openclaw/openclaw.json" >"$STAGE/openclaw/merge/openclaw.json"

  # Portable paths; drop empty component dirs.
  { grep -rlIZ -- "$HOME" "$STAGE" 2>/dev/null || true; } | xargs -0 -r sed -i "s|$HOME|$HOME_TOKEN|g"
  find "$STAGE" -type d -empty -delete

  {
    echo "exported: $(date -Is)"
    for t in omp claude codex opencode openclaw rtk codegraph codebase-memory-mcp caveman headroom; do
      have "$t" && printf '%s: %s\n' "$t" "$("$t" --version 2>/dev/null | head -1 || true)"
    done
  } >"$STAGE/manifest.txt"

  # Privacy tripwire: refuse to ship anything that looks like a live credential, or that
  # still mentions the login name (private hostnames, paths outside $HOME, real name).
  local hits
  hits=$(grep -rnIE 'sk-ant-[A-Za-z0-9_-]{20,}|sk-(proj-)?[A-Za-z0-9]{32,}|gh[pousr]_[A-Za-z0-9]{30,}|xox[abp]-[A-Za-z0-9-]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY' \
    "$STAGE" 2>/dev/null | cut -c1-200 || true)
  hits+=$(grep -rniIF -- "$USER" "$STAGE" 2>/dev/null | cut -c1-200 || true)
  [ -z "$hits" ] || die "possible private data found in bundle; remove it and re-run:
$hits"

  # Replace the previous export wholesale so removed files disappear from the repo too.
  rm -rf "$out"
  mkdir -p "$out"
  cp -a "$STAGE/." "$out/"
  ok "bundle written: $out ($(du -sh "$out" | cut -f1), $(find "$out" \( -type f -o -type l \) | wc -l) files)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Install: packages and binaries
# ─────────────────────────────────────────────────────────────────────────────

PM=none AUR="" APT_UPDATED=0
detect_platform() {
  [ "$(uname -s)" = Linux ] || die "only Linux is supported"
  case "$(uname -m)" in
    x86_64)  ARCHN=x64;   RTK_TRIPLE=x86_64-unknown-linux-musl ;;
    aarch64) ARCHN=arm64; RTK_TRIPLE=aarch64-unknown-linux-gnu ;;
    *) die "unsupported architecture $(uname -m)" ;;
  esac
  if have pacman; then PM=pacman; elif have apt-get; then PM=apt; elif have dnf; then PM=dnf; fi
  local h
  for h in paru yay; do have "$h" && { AUR=$h; break; }; done
  return 0
}

pm_install() {
  case $PM in
    pacman) run $SUDO pacman -S --needed --noconfirm "$@" ;;
    apt)
      ((APT_UPDATED)) || { run $SUDO apt-get update; APT_UPDATED=1; }
      run $SUDO apt-get install -y "$@" ;;
    dnf) run $SUDO dnf install -y "$@" ;;
    *) warn "no supported package manager; install manually: $*"; return 1 ;;
  esac
}

# arch_pkg <name>: installed → ok; official repo → pacman; else AUR helper. Fails on non-Arch.
arch_pkg() {
  [ "$PM" = pacman ] || return 1
  pacman -Qq "$1" >/dev/null 2>&1 && return 0
  if pacman -Si "$1" >/dev/null 2>&1; then run $SUDO pacman -S --needed --noconfirm "$1"; return; fi
  [ -n "$AUR" ] || return 1
  run "$AUR" -S --needed --noconfirm "$1"
}

npm_g() { run npm install -g --prefix "$HOME/.local" "$@"; }

# install_release_bin <binary> <tar.gz url>: extract and place the named binary in ~/.local/bin.
install_release_bin() {
  local bin=$1 url=$2 tmp f
  if ((DRY)); then printf '  [dry-run] fetch %s → ~/.local/bin/%s\n' "$url" "$bin"; return; fi
  tmp=$(mktemp -d)
  curl -fsSL "$url" | tar -xz -C "$tmp"
  f=$(find "$tmp" -type f -name "$bin" | head -1)
  [ -n "$f" ] || { rm -rf "$tmp"; die "$bin not found in $url"; }
  install -Dm755 "$f" "$HOME/.local/bin/$bin"
  rm -rf "$tmp"
}

install_base() {
  log "Base dependencies"
  local -a missing=() pair
  local entry cmd pkg
  case $PM in
    pacman) pair=(git:git curl:curl jq:jq tar:tar unzip:unzip node:nodejs npm:npm bun:bun uv:uv gh:github-cli python3:python) ;;
    apt)    pair=(git:git curl:curl jq:jq tar:tar unzip:unzip node:nodejs npm:npm python3:python3 gh:gh) ;;
    dnf)    pair=(git:git curl:curl jq:jq tar:tar unzip:unzip node:nodejs npm:npm python3:python3 gh:gh) ;;
    *)      pair=() ;;
  esac
  for entry in "${pair[@]}"; do
    cmd=${entry%%:*} pkg=${entry#*:}
    have "$cmd" || missing+=("$pkg")
  done
  if ((${#missing[@]})); then pm_install "${missing[@]}" || warn "some base packages failed: ${missing[*]}"; fi
  have bun || run_sh 'curl -fsSL https://bun.sh/install | bash'
  have uv  || run_sh 'curl -LsSf https://astral.sh/uv/install.sh | sh'
  # chrome-devtools-mcp (all agents) and the OpenClaw browser use a local Chromium.
  if ! have chromium && ! have google-chrome-stable && ! have google-chrome; then
    arch_pkg chromium || warn "install Chromium or Chrome for chrome-devtools-mcp"
  fi
  for cmd in git curl jq npm bun uv; do have "$cmd" || ((DRY)) || die "$cmd still missing"; done
  ok "base tools present"
}

install_rtk() {
  have rtk && { ok "rtk present"; return; }
  arch_pkg rtk-bin ||
    install_release_bin rtk "https://github.com/rtk-ai/rtk/releases/latest/download/rtk-$RTK_TRIPLE.tar.gz"
}

install_codegraph() {
  have codegraph && { ok "codegraph present"; return; }
  arch_pkg codegraph-bin && return
  local url="https://github.com/colbymchenry/codegraph/releases/latest/download/codegraph-linux-$ARCHN.tar.gz"
  if ((DRY)); then printf '  [dry-run] fetch %s → ~/.local/lib/codegraph\n' "$url"; return; fi
  local tmp root
  tmp=$(mktemp -d)
  curl -fsSL "$url" | tar -xz -C "$tmp"
  root=$(dirname "$(find "$tmp" -type f -path '*/lib/dist/bin/codegraph.js' | head -1)")
  root=${root%/lib/dist/bin}
  [ -x "$root/node" ] || { rm -rf "$tmp"; die "unexpected codegraph archive layout"; }
  rm -rf "$HOME/.local/lib/codegraph"
  mkdir -p "$HOME/.local/lib/codegraph" "$HOME/.local/bin"
  cp -a "$root/node" "$root/lib" "$HOME/.local/lib/codegraph/"
  printf '#!/bin/sh\nexec "%s/node" "%s/lib/dist/bin/codegraph.js" "$@"\n' \
    "$HOME/.local/lib/codegraph" "$HOME/.local/lib/codegraph" >"$HOME/.local/bin/codegraph"
  chmod 755 "$HOME/.local/bin/codegraph"
  rm -rf "$tmp"
}

install_cbm() {
  have codebase-memory-mcp && { ok "codebase-memory-mcp present"; return; }
  # CBM's activation transaction rejects group/world-writable install directories.
  # Existing ~/.local/bin directories and a permissive umask can both cause this.
  run mkdir -p "$HOME/.local/bin"
  run chmod go-w "$HOME/.local/bin"
  # Binary only; agent integration runs later via `codebase-memory-mcp install`.
  run_sh 'curl -fsSL https://raw.githubusercontent.com/DeusData/codebase-memory-mcp/main/install.sh | bash -s -- --skip-config'
}

install_caveman() {
  # Caveman hooks reference ~/.local/lib/node_modules/@caveman-ai/cli: pin npm prefix to ~/.local.
  if [ -d "$HOME/.local/lib/node_modules/@caveman-ai/cli" ]; then ok "caveman CLI present"
  else npm_g @caveman-ai/cli; fi
  if [ -x "$HOME/.caveman/bin/caveman-proxy" ] && [ -x "$HOME/.caveman/bin/caveman-mcp" ]; then
    ok "caveman runtime present"
  else
    run caveman setup --install </dev/null
  fi
}

install_headroom() {
  # MCP configs reference ~/.venv/bin/headroom. Extras: proxy (for `headroom wrap omp`) + mcp.
  if [ -x "$HOME/.venv/bin/headroom" ]; then ok "headroom present"; return; fi
  [ -x "$HOME/.venv/bin/python" ] || run uv venv "$HOME/.venv" --python 3.13
  run uv pip install --python "$HOME/.venv/bin/python" 'headroom-ai[proxy,mcp,code]'
}

install_browser_use() {
  have browser-use && { ok "browser-use present"; return; }
  run uv tool install browser-use
}

install_omp() {
  have omp && { ok "omp present ($(omp --version 2>/dev/null | head -1))"; return; }
  run bun install -g @oh-my-pi/pi-coding-agent
}
install_claude() {
  have claude && { ok "claude present"; return; }
  arch_pkg claude-code || run_sh 'curl -fsSL https://claude.ai/install.sh | bash'
}
install_codex() {
  have codex && { ok "codex present"; return; }
  arch_pkg openai-codex || npm_g @openai/codex
}
install_opencode() {
  have opencode && { ok "opencode present"; return; }
  arch_pkg opencode-bin ||
    install_release_bin opencode "https://github.com/anomalyco/opencode/releases/latest/download/opencode-linux-$ARCHN.tar.gz"
}
install_openclaw() {
  have openclaw && { ok "openclaw present"; return; }
  arch_pkg openclaw || npm_g openclaw
}

ensure_path_rc() {
  local rc login_shell=${SHELL:-} block_start='# >>> ai-setup >>>'
  # This script runs in Bash; SHELL identifies the user's login shell.
  case ${login_shell##*/} in
    zsh) rc="${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash) rc="$HOME/.bashrc" ;;
    *) warn "add ~/.local/bin and ~/.bun/bin to your shell's PATH manually"; return 0 ;;
  esac
  [ -f "$rc" ] || return 0
  grep -qF "$block_start" "$rc" && return 0
  grep -q '\.local/bin' "$rc" && grep -q '\.bun/bin' "$rc" && return 0
  if ((DRY)); then printf '  [dry-run] add PATH block to %s\n' "$rc"; return 0; fi
  [ -w "$rc" ] || { warn "cannot update PATH in $rc (not writable); add ~/.local/bin and ~/.bun/bin manually"; return 0; }
  printf '\n%s\nexport PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"\n# <<< ai-setup <<<\n' "$block_start" >>"$rc"
  ok "PATH block added to $rc"
}

# ─────────────────────────────────────────────────────────────────────────────
# Install: file helpers
# ─────────────────────────────────────────────────────────────────────────────

backup() {
  local p=$1 rel=${1#"$HOME"/}
  mkdir -p "$BACKUP_ROOT/$(dirname "$rel")"
  cp -a "$p" "$BACKUP_ROOT/$rel"
}

# sync_tree <component>: copy bundle files into $HOME, replacing only what differs.
sync_tree() {
  local src="$STAGE/$1/home" n=0 f rel dst want
  [ -d "$src" ] || return 0
  while IFS= read -r -d '' f; do
    rel=${f#"$src"/} dst="$HOME/$rel"
    if [ -L "$f" ]; then
      want=$(readlink "$f")
      [ -L "$dst" ] && [ "$(readlink "$dst")" = "$want" ] && continue
    else
      [ -f "$dst" ] && [ ! -L "$dst" ] && cmp -s "$f" "$dst" && continue
    fi
    n=$((n + 1))
    if ((DRY)); then printf '  [dry-run] %s ~/%s\n' "$([ -e "$dst" ] && echo update || echo create)" "$rel"; continue; fi
    if [ -e "$dst" ] || [ -L "$dst" ]; then backup "$dst"; rm -rf "$dst"; fi
    mkdir -p "$(dirname "$dst")"
    if [ -L "$f" ]; then ln -s "$want" "$dst"; else cp -p "$f" "$dst"; fi
  done < <(find "$src" -mindepth 1 \( -type f -o -type l \) -print0)
  ok "$1: $n file(s) written"
}

CHANGED=0
# write_if_changed <target> <new content file> <label> [quiet]
write_if_changed() {
  local target=$1 new=$2 label=$3 quiet=${4:-}
  [ -f "$target" ] && cmp -s "$new" "$target" && return 0
  CHANGED=$((CHANGED + 1))
  if ((DRY)); then [ -n "$quiet" ] || printf '  [dry-run] write %s\n' "$label"; return; fi
  [ -f "$target" ] && backup "$target"
  mkdir -p "$(dirname "$target")"
  cat "$new" >"$target"
  [ -n "$quiet" ] || ok "$label updated"
}

# json_merge <target> <fragment>: deep merge, fragment wins, arrays unioned.
json_merge() {
  local target=$1 frag=$2 out label=${1/#$HOME/\~}
  [ -f "$frag" ] || return 0
  out=$(mktemp)
  if [ ! -f "$target" ]; then
    cp "$frag" "$out"
  elif ! jq -e . "$target" >/dev/null 2>&1; then
    warn "$label is not valid JSON; leaving it alone"; rm -f "$out"; return
  else
    jq -s "$JQ_DM dm(.[0]; .[1])" "$target" "$frag" >"$out"
  fi
  if [ -f "$target" ] && [ "$(jq -S . "$target")" = "$(jq -S . "$out")" ]; then
    ok "$label unchanged"
  else
    write_if_changed "$target" "$out" "$label"
  fi
  rm -f "$out"
}

# Merge the bundle's Codex config.toml per table: bundle top-level keys and tables replace
# same-named ones; every other table (trusted projects, hook trust, caveman routing, MCP
# servers added by installers) is kept as-is.
codex_toml_merge() {
  local target="$HOME/.codex/config.toml" bundle="$STAGE/codex/config.toml" out
  [ -f "$bundle" ] || return 0
  out=$(mktemp)
  if [ -f "$target" ]; then
    awk -v B="$bundle" '
      function key(l) { sub(/[ \t]*=.*/, "", l); return l }
      BEGIN {
        cur = ""
        while ((getline l < B) > 0) {
          if (l ~ /^\[/) { cur = l; order[++nsec] = l; bsec[l] = l; continue }
          if (cur == "") { if (l ~ /^[A-Za-z0-9_."-]+[ \t]*=/) { btopk[key(l)] = 1; btop = btop l "\n" } continue }
          bsec[cur] = bsec[cur] "\n" l
        }
        cur = ""
      }
      /^\[/ {
        if (!toped) { printf "%s", btop; toped = 1 }
        cur = $0; skip = (cur in bsec)
        if (!skip) print
        next
      }
      cur == "" { if ($0 ~ /^[A-Za-z0-9_."-]+[ \t]*=/ && (key($0) in btopk)) next; print; next }
      skip { if ($0 ~ /^#/) print; next }
      { print }
      END {
        if (!toped) printf "%s", btop
        for (i = 1; i <= nsec; i++) printf "\n%s\n", bsec[order[i]]
      }
    ' "$target" | cat -s >"$out"
  else
    cp "$bundle" "$out"
  fi
  write_if_changed "$target" "$out" "~/.codex/config.toml"
  rm -f "$out"
}

# Personal CLAUDE.md section, kept inside its own markers next to the tool-managed blocks.
claude_md_block() {
  local src="$STAGE/core/CLAUDE.user.md" target="$HOME/.claude/CLAUDE.md" out
  [ -f "$src" ] || return 0
  out=$(mktemp)
  {
    if [ -f "$target" ]; then
      awk '/<!-- ai-setup:begin -->/ { skip = 1 } !skip { print } /<!-- ai-setup:end -->/ { skip = 0 }' "$target" |
        sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
      echo
    fi
    echo '<!-- ai-setup:begin -->'
    cat "$src"
    echo '<!-- ai-setup:end -->'
  } | sed '/./,$!d' >"$out"
  write_if_changed "$target" "$out" "~/.claude/CLAUDE.md"
  rm -f "$out"
}

# copy_if_changed <src> <dst>
copy_if_changed() { write_if_changed "$2" "$1" "${2/#$HOME/\~}"; }

# ─────────────────────────────────────────────────────────────────────────────
# Install: third-party content via its own installers
# ─────────────────────────────────────────────────────────────────────────────

install_skills() {
  local spec="$STAGE/skills.tsv" src names missing gone n
  [ -f "$spec" ] || return 0
  local agents=(-a universal)
  ((T_CLAUDE)) && agents+=(-a claude-code)
  while IFS=$'\t' read -r src names; do
    missing=()
    for n in ${names//,/ }; do [ -d "$HOME/.agents/skills/$n" ] || missing+=(--skill "$n"); done
    ((${#missing[@]})) || continue
    run npx -y skills add "$src" -g -y "${missing[@]}" "${agents[@]}" </dev/null >/dev/null 2>&1 || true
    ((DRY)) && continue
    # Skills renamed or removed upstream since export are reported, not fatal.
    gone=()
    for n in ${names//,/ }; do [ -d "$HOME/.agents/skills/$n" ] || gone+=("$n"); done
    ((${#gone[@]})) && warn "$src no longer publishes: ${gone[*]} (re-export to refresh skills.tsv)"
  done <"$spec"
  ok "skills from $(wc -l <"$spec") sources installed (npx skills)"
}

install_browser_use_skill() {
  have browser-use || return 0
  local tmp dirs=("$HOME/.agents/skills/browser-use") d
  ((T_CLAUDE)) && dirs+=("$HOME/.claude/skills/browser-use")
  ((T_OPENCODE)) && dirs+=("$HOME/.config/opencode/skills/browser-use")
  ((T_OPENCLAW)) && dirs+=("$HOME/.openclaw/skills/browser-use")
  tmp=$(mktemp)
  browser-use skill >"$tmp" 2>/dev/null || { warn "browser-use skill failed"; rm -f "$tmp"; return; }
  for d in "${dirs[@]}"; do copy_if_changed "$tmp" "$d/SKILL.md"; done
  rm -f "$tmp"
}

# codebase-memory-mcp configures every detected agent (hooks, MCP, skill, agents, plugin).
integrate_cbm() {
  have codebase-memory-mcp || return 0
  local need=0
  ((T_CLAUDE)) && [ ! -f "$HOME/.claude/agents/codebase-memory.md" ] && need=1
  ((T_CODEX)) && [ ! -f "$HOME/.codex/agents/codebase-memory.toml" ] && need=1
  ((T_OPENCODE)) && [ ! -f "$HOME/.config/opencode/plugins/cbm-augment.ts" ] && need=1
  ((T_OPENCLAW)) && ! grep -qs codebase-memory-mcp "$HOME/.openclaw/openclaw.json" && need=1
  if ((need)); then
    run codebase-memory-mcp install -y </dev/null >/dev/null 2>&1 || warn "codebase-memory-mcp install reported an error"
    ok "codebase-memory-mcp integrations installed"
  else ok "codebase-memory-mcp integrations present"; fi
  # omp is not an installer target: render its Claude-format agents in a scratch home.
  if ((T_OMP)) && [ ! -f "$HOME/.omp/agent/agents/codebase-memory.md" ]; then
    if ((DRY)); then echo "  [dry-run] codebase-memory-mcp agents → ~/.omp/agent/agents"; return; fi
    local tmp n
    tmp=$(mktemp -d); mkdir -p "$tmp/.claude"
    HOME=$tmp codebase-memory-mcp install -y </dev/null >/dev/null 2>&1 || true
    for n in "${CBM_AGENTS[@]}"; do
      [ -f "$tmp/.claude/agents/$n.md" ] && copy_if_changed "$tmp/.claude/agents/$n.md" "$HOME/.omp/agent/agents/$n.md"
    done
    rm -rf "$tmp"
  fi
}

integrate_codegraph() {
  have codegraph || return 0
  local need=0
  ((T_CLAUDE)) && ! grep -qs '"codegraph"' "$HOME/.claude.json" && need=1
  ((T_CODEX)) && ! grep -qs '^\[mcp_servers.codegraph\]' "$HOME/.codex/config.toml" && need=1
  ((T_OPENCODE)) && ! grep -qs '"codegraph"' "$HOME"/.config/opencode/opencode.json* && need=1
  if ((need)); then
    if run codegraph install --yes </dev/null >/dev/null 2>&1; then ok "codegraph integrations installed"
    else warn "codegraph install failed"; fi
  else ok "codegraph integrations present"; fi
}

integrate_rtk() {
  ((T_CLAUDE)) && have rtk || return 0
  if grep -qs 'rtk hook' "$HOME/.claude/settings.json"; then ok "rtk hook present"; return; fi
  if run rtk init -g --auto-patch </dev/null >/dev/null 2>&1; then ok "rtk hook installed"
  else warn "rtk init failed"; fi
}

integrate_caveman() {
  local only=()
  ((T_OPENCODE)) && only+=(--only opencode)
  ((T_OPENCLAW)) && only+=(--only openclaw)
  # OpenCode plugin/commands/agents and the OpenClaw workspace skill; Claude Code gets the
  # caveman plugin from the plugin list, Codex its skills from skills.tsv.
  if ((${#only[@]})); then
    if run bash "$SRC_ROOT/caveman/install.sh" --non-interactive "${only[@]}" </dev/null >/dev/null 2>&1; then
      ok "caveman installed for ${only[*]//--only /}"
    else warn "caveman installer failed"; fi
  fi
  have caveman || return 0
  if ((T_CLAUDE)); then run caveman enable claude 2>&1 | tail -1 || true; fi
  if ((T_CODEX)); then run caveman enable codex 2>&1 | tail -1 || true; fi
  if ((T_CLAUDE)) && [ ! -f "$HOME/.claude/skills/caveman-learn/SKILL.md" ]; then
    run caveman skills install caveman-learn --user --no-pixel </dev/null >/dev/null || warn "caveman-learn skill failed"
  fi
}

# ECC prompt → Claude Code / OpenCode command (description from the prompt's own heading).
ecc_command() {
  local p=$1 quote=$2 n h
  n=$(basename "$p" .md); n=${n#ecc-}
  h=$(grep '^# ' "$p" | grep -v '^# ECC Command Prompt:' | head -1 | sed 's/^# //' || true)
  [ -n "$h" ] || h="ECC $n workflow"
  if ((quote)); then printf -- '---\ndescription: "%s"\n---\n\n' "$h"
  else printf -- '---\ndescription: %s\n---\n\n' "$h"; fi
  cat "$p"
  grep -q '\$ARGUMENTS' "$p" || printf '\n$ARGUMENTS\n'
}

integrate_ecc() {
  local dir="$SRC_ROOT/ECC" rev stamp="$HOME/.codex/.ai-setup-ecc-rev"
  ((DRY)) && [ ! -d "$dir" ] && { echo "  [dry-run] ECC sync + command generation"; return; }
  [ -d "$dir/node_modules/@iarna/toml" ] ||
    (cd "$dir" && run npm ci --ignore-scripts --no-audit --no-fund >/dev/null) || die "npm ci in $dir failed"
  rev=$(git -C "$dir" rev-parse HEAD)
  if ((T_CODEX)); then
    if [ "$(cat "$stamp" 2>/dev/null)" = "$rev" ]; then ok "ECC synced to Codex ($(git -C "$dir" rev-parse --short HEAD))"
    elif { ((DRY)) || { mkdir -p "$HOME/.codex" && touch "$HOME/.codex/config.toml"; }; } &&
      run bash "$dir/scripts/sync-ecc-to-codex.sh" </dev/null >/dev/null 2>&1; then
      ((DRY)) || echo "$rev" >"$stamp"
      ok "ECC synced to Codex"
    else warn "ECC Codex sync failed"; fi
  fi
  ((T_CLAUDE || T_OPENCODE)) || return 0
  ((DRY)) && { echo "  [dry-run] generate ecc-*.md commands"; return; }
  # Generate the Codex prompts in a scratch home (no global git config side effects).
  local tmp p b out
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.codex" && touch "$tmp/.codex/config.toml"
  HOME=$tmp CODEX_HOME=$tmp/.codex ECC_FORCE_GLOBAL_HOOKS=1 \
    bash "$dir/scripts/sync-ecc-to-codex.sh" </dev/null >/dev/null 2>&1 ||
    { warn "ECC prompt generation failed"; rm -rf "$tmp"; return; }
  out=$(mktemp)
  local before=$CHANGED
  # Some prompts reference sibling prompts by absolute path: point them at the real ~/.codex.
  { grep -rlZF -- "$tmp/.codex" "$tmp/.codex/prompts" || true; } | xargs -0 -r sed -i "s|$tmp/.codex|$HOME/.codex|g"
  for p in "$tmp"/.codex/prompts/ecc-*.md; do
    b=$(basename "$p")
    if ((T_CLAUDE)); then ecc_command "$p" 1 >"$out"; write_if_changed "$HOME/.claude/commands/$b" "$out" "$b" quiet; fi
    if ((T_OPENCODE)); then ecc_command "$p" 0 >"$out"; write_if_changed "$HOME/.config/opencode/commands/$b" "$out" "$b" quiet; fi
  done
  rm -rf "$tmp" "$out"
  ok "ECC commands: $((CHANGED - before)) written for Claude Code/OpenCode"
}

# Point statusLine at the installed caveman plugin's script (cache path contains a hash).
claude_fix_statusline() {
  local frag=$1 cmd path found tmp
  cmd=$(jq -r '.statusLine.command // empty' "$frag")
  [ -n "$cmd" ] || return 0
  path=$(grep -oE '/[^"]*caveman-statusline\.sh' <<<"$cmd" || true)
  [ -z "$path" ] || [ -f "$path" ] && return 0
  found=$(find "$HOME/.claude/plugins/cache" -name caveman-statusline.sh -path '*caveman*' 2>/dev/null | sort | tail -1 || true)
  tmp=$(mktemp)
  if [ -n "$found" ]; then
    jq --arg c "bash \"$found\"" '.statusLine.command = $c' "$frag" >"$tmp"
  else
    jq 'del(.statusLine)' "$frag" >"$tmp"
  fi
  mv "$tmp" "$frag"
}

restore_claude_plugins() {
  local spec="$STAGE/claude/plugins.json" dir="$HOME/.claude/plugins" name src id
  [ -f "$spec" ] && have claude || return 0
  while IFS=$'\t' read -r name src; do
    if [ -f "$dir/known_marketplaces.json" ] && jq -e --arg n "$name" 'has($n)' "$dir/known_marketplaces.json" >/dev/null; then continue; fi
    run claude plugin marketplace add "$src" >/dev/null 2>&1 || warn "marketplace $name ($src) failed"
  done < <(jq -r '.marketplaces | to_entries[] | "\(.key)\t\(.value)"' "$spec")
  while IFS= read -r id; do
    if [ -f "$dir/installed_plugins.json" ] && jq -e --arg i "$id" '.plugins | has($i)' "$dir/installed_plugins.json" >/dev/null; then continue; fi
    run claude plugin install "$id" >/dev/null 2>&1 || warn "plugin $id failed"
  done < <(jq -r '.plugins[]' "$spec")
  ok "claude plugins installed (enable/disable state comes from settings.json)"
}

restore_codex_plugins() {
  local spec="$STAGE/codex/plugins.tsv" id src
  [ -s "$spec" ] && have codex || return 0
  while IFS=$'\t' read -r id src; do
    [ -d "$HOME/.codex/plugins/cache/${id#*@}/${id%@*}" ] && continue
    [ -n "$src" ] && { run codex plugin marketplace add "$src" >/dev/null 2>&1 || true; }
    run codex plugin add "$id" >/dev/null 2>&1 || warn "codex plugin $id failed"
  done <"$spec"
  ok "codex plugins present"
}

# ─────────────────────────────────────────────────────────────────────────────
# Install: configuration
# ─────────────────────────────────────────────────────────────────────────────

configure() {
  local bundle=$1
  [ -f "$bundle/manifest.txt" ] || { warn "no bundle at $bundle — skipping configuration (run 'export' on the source machine)"; return; }
  STAGE=$(mktemp -d)
  cp -a "$bundle/." "$STAGE/"
  { grep -rlIZ -- "$HOME_TOKEN" "$STAGE" 2>/dev/null || true; } | xargs -0 -r sed -i "s|$HOME_TOKEN|$HOME|g"

  log "Third-party content (installed by upstream tooling)"
  # Installers only wire agents whose config file already exists (codegraph would otherwise
  # skip Codex and write a competing opencode.jsonc on a fresh machine).
  if ! ((DRY)); then
    ((T_CODEX)) && [ ! -f "$HOME/.codex/config.toml" ] && mkdir -p "$HOME/.codex" && : >"$HOME/.codex/config.toml"
    ((T_OPENCODE)) && [ ! -f "$HOME/.config/opencode/opencode.json" ] && mkdir -p "$HOME/.config/opencode" &&
      echo '{"$schema": "https://opencode.ai/config.json"}' >"$HOME/.config/opencode/opencode.json"
  fi
  ((T_CLAUDE || T_CODEX || T_OPENCODE)) && ensure_repo ECC "$ECC_URL"
  ((T_CLAUDE || T_CODEX || T_OPENCODE || T_OPENCLAW)) && ensure_repo caveman "$CAVEMAN_URL"
  install_skills
  install_browser_use_skill
  ((T_CLAUDE)) && restore_claude_plugins
  integrate_rtk
  integrate_codegraph
  integrate_cbm
  ((T_CLAUDE || T_CODEX || T_OPENCODE || T_OPENCLAW)) && integrate_caveman
  ((T_CLAUDE || T_CODEX || T_OPENCODE)) && integrate_ecc
  ((T_CODEX)) && restore_codex_plugins
  ((CHANGED)) || ok "generated files unchanged"

  log "Personal configuration from $(basename "$bundle") ($(head -1 "$STAGE/manifest.txt" 2>/dev/null))"
  sync_tree core
  claude_md_block
  if ((T_OMP)); then
    sync_tree omp
    json_merge "$HOME/.omp/agent/mcp.json" "$STAGE/omp/merge/mcp.json"
  fi
  if ((T_CLAUDE)); then
    sync_tree claude
    claude_fix_statusline "$STAGE/claude/merge/settings.json"
    json_merge "$HOME/.claude/settings.json" "$STAGE/claude/merge/settings.json"
    json_merge "$HOME/.claude.json" "$STAGE/claude/merge/claude.json"
  fi
  if ((T_CODEX)); then
    sync_tree codex
    codex_toml_merge
  fi
  if ((T_OPENCODE)); then
    sync_tree opencode
    json_merge "$HOME/.config/opencode/opencode.json" "$STAGE/opencode/merge/opencode.json"
    if [ -f "$HOME/.config/opencode/package.json" ]; then
      (cd "$HOME/.config/opencode" && run bun install --silent) || warn "bun install in ~/.config/opencode failed"
    fi
  fi
  if ((T_OPENCLAW)); then
    if [ -f "$HOME/.openclaw/openclaw.json" ]; then
      json_merge "$HOME/.openclaw/openclaw.json" "$STAGE/openclaw/merge/openclaw.json"
    else
      warn "~/.openclaw/openclaw.json missing: run 'openclaw onboard --install-daemon', then re-run this script with --openclaw"
    fi
  fi

  [ -d "$BACKUP_ROOT" ] && ok "replaced files backed up under $BACKUP_ROOT"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Install entry point
# ─────────────────────────────────────────────────────────────────────────────

T_OMP=0 T_CLAUDE=0 T_CODEX=0 T_OPENCODE=0 T_OPENCLAW=0
cmd_install() {
  local bundle=$DEFAULT_BUNDLE tools=1 config=1 headroom=1 any=0
  while (($#)); do
    case $1 in
      --omp) T_OMP=1 any=1 ;;
      --claude) T_CLAUDE=1 any=1 ;;
      --codex) T_CODEX=1 any=1 ;;
      --opencode) T_OPENCODE=1 any=1 ;;
      --openclaw) T_OPENCLAW=1 any=1 ;;
      --all) T_OMP=1 T_CLAUDE=1 T_CODEX=1 T_OPENCODE=1 T_OPENCLAW=1 any=1 ;;
      --bundle) bundle=${2:?--bundle needs a directory}; shift ;;
      --no-tools) tools=0 ;;
      --no-config) config=0 ;;
      --no-headroom) headroom=0 ;;
      --dry-run) DRY=1 ;;
      -h | --help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  ((any)) || T_OMP=1
  detect_platform

  if ((tools)); then
    log "Preparing tool directories"
    run mkdir -p "$HOME/.local/bin"
    install_base
    log "Shared agent tooling"
    install_rtk
    install_codegraph
    install_cbm
    install_caveman
    ((headroom)) && install_headroom
    install_browser_use
    log "Agents"
    ((T_OMP)) && install_omp
    ((T_CLAUDE)) && install_claude
    ((T_CODEX)) && install_codex
    ((T_OPENCODE)) && install_opencode
    ((T_OPENCLAW)) && install_openclaw
    ensure_path_rc
  fi

  if ((config)); then
    have jq || ((DRY)) || die "jq is required for configuration"
    configure "$bundle"
  fi

  log "Done. Remaining manual steps (credentials are never copied):"
  ((T_OMP)) && echo "  omp       run 'omp' then /login; 'headroom wrap omp' to route through the Headroom proxy"
  ((T_CLAUDE)) && echo "  claude    run 'claude' and log in"
  ((T_CODEX)) && echo "  codex     run 'codex login'; approve hooks via /hooks on first start"
  ((T_OPENCODE)) && echo "  opencode  run 'opencode auth login'"
  ((T_OPENCLAW)) && echo "  openclaw  run 'openclaw onboard --install-daemon' (gateway token, Signal, Brave key)"
  echo "  optional  'caveman login', 'gh auth login'; open a new shell to pick up PATH"
}

usage() { sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

case ${1:-} in
  export) shift; cmd_export "${1:-}" ;;
  install) shift; cmd_install "$@" ;;
  -h | --help | help | "") usage ;;
  *) die "unknown command: $1 (use export | install)" ;;
esac
