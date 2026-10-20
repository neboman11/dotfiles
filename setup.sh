#!/usr/bin/env bash
# Sets up the home directory the way I like it: zsh (oh-my-zsh, plugins, starship, .zshrc),
# doom emacs with evil disabled, zellij for SSH logins, and optionally the AI agent tooling
# in ai-setup/.
#
# Safe to re-run: every step checks what is already in place, and files that would be
# replaced are backed up next to the original as <file>.bak.<timestamp>.
#
# Works from a checkout or standalone (curl ... setup.sh); standalone runs clone the repo to
# ~/.local/share/dotfiles and use the files from there.
set -euo pipefail

REPO_URL=https://github.com/neboman11/dotfiles.git
DOOM_EMACS=true
ZSH_SETUP=true
INSTALL_PACKAGES=false
ENABLE_OMZ_VSCODE=false
ZELLIJ_SETUP=true
AI_TARGETS=""
STAMP=$(date +%Y%m%d-%H%M%S)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

show_help() {
    cat <<'EOF'
Usage: setup.sh [options]

Sets up zsh and doom emacs the way I like it. Safe to re-run.

  -h, -?        Print this help and exit.
  -d            Do not set up doom emacs.
  -z            Do not set up zsh.
  -i            Install missing packages first (requires sudo).
  -v            Enable the vscode oh-my-zsh plugin.
  -m            Do not set up zellij (auto-attach for SSH logins).
  -a TARGETS    Also set up AI agent tooling via ai-setup/setup-ai-tools.sh.
                TARGETS: comma list of omp,claude,codex,opencode,openclaw, or "all".
EOF
}

while getopts "h?dzivma:" opt; do
    case "$opt" in
    h | \?) show_help; exit 0 ;;
    d) DOOM_EMACS=false ;;
    z) ZSH_SETUP=false ;;
    i) INSTALL_PACKAGES=true ;;
    v) ENABLE_OMZ_VSCODE=true ;;
    m) ZELLIJ_SETUP=false ;;
    a) AI_TARGETS=$OPTARG ;;
    esac
done
shift $((OPTIND - 1))

# ── Helpers ──────────────────────────────────────────────────────────────────

# install_file <source> <dest>: copy if different, backing up whatever was there.
install_file() {
    local src=$1 dest=$2
    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then ok "${dest/#$HOME/\~} up to date"; return; fi
    mkdir -p "$(dirname "$dest")"
    if [ -e "$dest" ]; then
        cp -a "$dest" "$dest.bak.$STAMP"
        ok "${dest/#$HOME/\~} updated (previous saved as $(basename "$dest").bak.$STAMP)"
    else
        ok "${dest/#$HOME/\~} installed"
    fi
    cp "$src" "$dest"
}

# git_clone <url> <dir>: shallow clone once; leave existing checkouts alone.
git_clone() {
    if [ -d "$2/.git" ]; then ok "${2/#$HOME/\~} present"; return; fi
    [ -e "$2" ] && die "$2 exists but is not a git checkout; move it aside and re-run"
    git clone -q --depth 1 "$1" "$2"
    ok "cloned $(basename "$1" .git) → ${2/#$HOME/\~}"
}

# Directory holding the repo files (.zshrc, .config/zellij/, ai-setup/).
repo_dir() {
    local here
    here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)
    if [ -n "$here" ] && [ -f "$here/.zshrc" ] && [ -f "$here/.config/zellij/ssh-autoattach.sh" ]; then
        echo "$here"; return
    fi
    local dir="${XDG_DATA_HOME:-$HOME/.local/share}/dotfiles"
    if [ -d "$dir/.git" ]; then
        git -C "$dir" pull -q --ff-only || warn "could not update $dir; using it as-is"
    else
        git clone -q --depth 1 "$REPO_URL" "$dir"
    fi
    echo "$dir"
}

# ── Packages ─────────────────────────────────────────────────────────────────

install_packages() {
    log "Packages"
    local pm entry cmd pkg
    local -a want missing=()
    # command:package pairs; only packages whose command is missing get installed, so an
    # existing emacs/emacs-wayland is never swapped for emacs-nox.
    if have pacman; then
        pm=pacman
        want=(git:git curl:curl zsh:zsh emacs:emacs-nox fzf:fzf tmux:tmux zellij:zellij bpytop:bpytop rg:ripgrep fd:fd starship:starship)
    elif have apt-get; then
        pm=apt
        want=(git:git curl:curl zsh:zsh emacs:emacs-nox fzf:fzf tmux:tmux bpytop:bpytop rg:ripgrep fdfind:fd-find)
    elif have dnf; then
        pm=dnf
        want=(git:git curl:curl zsh:zsh emacs:emacs-nox fzf:fzf tmux:tmux zellij:zellij bpytop:bpytop rg:ripgrep fd:fd-find)
    else
        die "no supported package manager (pacman, apt, dnf)"
    fi
    for entry in "${want[@]}"; do
        cmd=${entry%%:*} pkg=${entry#*:}
        have "$cmd" || missing+=("$pkg")
    done
    if ((${#missing[@]} == 0)); then
        ok "all packages present"
    else
        echo "  installing: ${missing[*]}"
        case $pm in
        pacman) $SUDO pacman -S --needed --noconfirm "${missing[@]}" ;;
        apt) $SUDO apt-get update -q && $SUDO apt-get install -y "${missing[@]}" ;;
        dnf) $SUDO dnf install -y "${missing[@]}" ;;
        esac
        ok "installed: ${missing[*]}"
    fi
}

# ── zsh ──────────────────────────────────────────────────────────────────────

setup_zsh() {
    log "zsh"
    have zsh || die "zsh is not installed (re-run with -i)"

    # .zshrc pins ZSH=$HOME/.oh-my-zsh with the default custom dir; ignore any inherited
    # ZSH/ZSH_CUSTOM from the calling shell.
    local omz="$HOME/.oh-my-zsh"
    if [ -d "$omz" ]; then
        ok "oh-my-zsh present"
    else
        ZSH=$omz sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" \
            --unattended --keep-zshrc >/dev/null 2>&1 || die "oh-my-zsh install failed"
        ok "oh-my-zsh installed"
    fi

    local zshrc
    zshrc=$(mktemp)
    cp "$REPO/.zshrc" "$zshrc"
    [ "$ENABLE_OMZ_VSCODE" = true ] && sed -i 's/^\(\s*\)#vscode$/\1vscode/' "$zshrc"
    install_file "$zshrc" "$HOME/.zshrc"
    rm -f "$zshrc"

    git_clone https://github.com/zsh-users/zsh-autosuggestions.git "$omz/custom/plugins/zsh-autosuggestions"

    if have starship; then
        ok "starship present"
    else
        mkdir -p "$HOME/.local/bin"
        curl -fsSL https://starship.rs/install.sh | sh -s -- --yes --bin-dir "$HOME/.local/bin" >/dev/null
        ok "starship installed to ~/.local/bin"
    fi
    if [ -f "$HOME/.config/starship.toml" ]; then
        ok "~/.config/starship.toml present (kept)"
    else
        mkdir -p "$HOME/.config"
        PATH="$HOME/.local/bin:$PATH" starship preset tokyo-night -o "$HOME/.config/starship.toml"
        ok "starship tokyo-night preset written"
    fi

    local zsh_path login_shell
    zsh_path=$(command -v zsh)
    login_shell=$(getent passwd "$USER" | cut -d: -f7)
    if [ "$login_shell" = "$zsh_path" ] || [ "$(basename "$login_shell")" = zsh ]; then
        ok "login shell is zsh"
    elif chsh -s "$zsh_path"; then
        ok "login shell changed to zsh (takes effect at next login)"
    else
        warn "could not change login shell; run: chsh -s $zsh_path"
    fi
}

# ── doom emacs ───────────────────────────────────────────────────────────────

setup_doom() {
    log "doom emacs"
    have emacs || die "emacs is not installed (re-run with -i)"
    local doom="$HOME/.config/emacs/bin/doom"

    # ~/.emacs.d takes precedence over ~/.config/emacs; move it aside instead of deleting it.
    if [ -e "$HOME/.emacs.d" ]; then
        mv "$HOME/.emacs.d" "$HOME/.emacs.d.bak.$STAMP"
        warn "moved ~/.emacs.d to ~/.emacs.d.bak.$STAMP (it would shadow doom)"
    fi

    git_clone https://github.com/doomemacs/doomemacs "$HOME/.config/emacs"

    # Create the private config first (no packages yet) so evil is never built.
    if [ -f "$HOME/.config/doom/init.el" ]; then
        ok "doom private config present"
    else
        "$doom" install --force --no-install
        ok "doom private config created"
    fi

    # Default to emacs keybindings: comment out the evil module.
    local need_sync=false
    if grep -q '^\s*(evil +everywhere)' "$HOME/.config/doom/init.el"; then
        sed -i 's/^\(\s*\)(evil +everywhere)/\1;;(evil +everywhere)/' "$HOME/.config/doom/init.el"
        ok "evil disabled"
        need_sync=true
    else
        ok "evil already disabled"
    fi
    # Packages missing (fresh install or an interrupted earlier run) also need a sync.
    [ -d "$HOME/.config/emacs/.local/straight/repos" ] || need_sync=true
    if [ "$need_sync" = true ]; then
        "$doom" sync
        ok "doom packages synced"
    else
        ok "doom packages present"
    fi
}

# ── zellij ───────────────────────────────────────────────────────────────────

PROFILE_HOOK='if [ -f "$HOME/.config/zellij/ssh-autoattach.sh" ]; then . "$HOME/.config/zellij/ssh-autoattach.sh"; fi'

# hook_profile <file>: drop any byobu launcher (bare, or wrapped in an SSH_CONNECTION if),
# then make sure the zellij hook is sourced at the end.
hook_profile() {
    local file=$1 tmp
    tmp=$(mktemp)
    [ -f "$file" ] && awk '
        /byobu-launch/ { if (held != "") { held = ""; skipfi = 1 }; next }
        skipfi && /^[[:space:]]*fi[[:space:]]*$/ { skipfi = 0; next }
        { skipfi = 0 }
        held != "" { print held; held = "" }
        /^[[:space:]]*if .*SSH_CONNECTION.*then[[:space:]]*$/ { held = $0; next }
        { print }
        END { if (held != "") print held }
    ' "$file" >"$tmp"
    grep -qxF "$PROFILE_HOOK" "$tmp" || printf '%s\n' "$PROFILE_HOOK" >>"$tmp"
    install_file "$tmp" "$file"
    rm -f "$tmp"
}

setup_zellij() {
    log "zellij"
    if have zellij || [ -x "$HOME/.local/bin/zellij" ]; then
        ok "zellij present"
    else
        local arch
        case $(uname -m) in
        x86_64 | amd64) arch=x86_64 ;;
        aarch64 | arm64) arch=aarch64 ;;
        *) die "no zellij release binary for $(uname -m); install zellij and re-run" ;;
        esac
        mkdir -p "$HOME/.local/bin"
        curl -fsSL "https://github.com/zellij-org/zellij/releases/latest/download/zellij-$arch-unknown-linux-musl.tar.gz" |
            tar -xz -C "$HOME/.local/bin" zellij
        ok "zellij installed to ~/.local/bin"
    fi
    install_file "$REPO/.config/zellij/ssh-autoattach.sh" "$HOME/.config/zellij/ssh-autoattach.sh"
    # Login shells read .zprofile (zsh), .bash_profile or .profile (bash), .profile (sh).
    hook_profile "$HOME/.zprofile"
    hook_profile "$HOME/.profile"
    [ -f "$HOME/.bash_profile" ] && hook_profile "$HOME/.bash_profile"
    ok "SSH logins attach to zellij session \"main\""
}

# ── AI agent tooling ─────────────────────────────────────────────────────────

setup_ai() {
    local -a args=() t
    local IFS=,
    for t in $AI_TARGETS; do
        case $t in
        all | omp | claude | codex | opencode | openclaw) args+=("--$t") ;;
        *) die "unknown AI target: $t" ;;
        esac
    done
    unset IFS
    log "AI agent tooling (${AI_TARGETS})"
    "$REPO/ai-setup/setup-ai-tools.sh" install "${args[@]}"
}

# ── Main ─────────────────────────────────────────────────────────────────────

[ "$INSTALL_PACKAGES" = true ] && install_packages
have git || die "git is not installed (re-run with -i)"
have curl || die "curl is not installed (re-run with -i)"
REPO=$(repo_dir)

[ "$ZSH_SETUP" = true ] && setup_zsh
[ "$DOOM_EMACS" = true ] && setup_doom
[ "$ZELLIJ_SETUP" = true ] && setup_zellij
[ -n "$AI_TARGETS" ] && setup_ai

log "Done."
