export ZSH="$HOME/.oh-my-zsh"

# Set before loading Oh My Zsh so its vscode plugin uses VS Code.
VSCODE=code

# Load plugins after restoring desktop-session variables used by bgnotify.
plugins=(
    git
    history-substring-search
    aliases
    ansible
    archlinux
    bgnotify
    colored-man-pages
    colorize
    command-not-found
    common-aliases
    copybuffer
    copyfile
    cp
    dircycle
    dirhistory
    docker
    docker-compose
    dotenv
    dotnet
    extract
    fasd
    flutter
    frontend-search
    fzf
    git-auto-fetch
    git-extras
    git-flow-avh
    globalias
    golang
    httpie
    ipfs
    jsontools
    profiles
    python
    rsync
    rust
    safe-paste
    sudo
    systemadmin
    systemd
    timer
    tmux
    universalarchive
    urltools
    vagrant
    zsh-interactive-cd
    zsh-autosuggestions
    )

# Embedded terminals may omit desktop variables; restore them for notifications.
# Only fill missing values so SSH and explicitly selected displays are preserved.
[[ -z "$XDG_RUNTIME_DIR" ]] && export XDG_RUNTIME_DIR="/run/user/$(id -u)"
[[ -z "$DBUS_SESSION_BUS_ADDRESS" && -S "$XDG_RUNTIME_DIR/bus" ]] && export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
if [[ -z "$DISPLAY" || -z "$WAYLAND_DISPLAY" ]] && command -v systemctl >/dev/null; then
  for var in DISPLAY WAYLAND_DISPLAY; do
    if [[ -z "${(P)var}" ]]; then
      value=$(systemctl --user show-environment 2>/dev/null | sed -n "s/^${var}=//p")
      [[ -n "$value" ]] && export "$var=$value"
    fi
  done
fi

# Refresh GPG's terminal so SSH commits use the current pinentry prompt.
export GPG_TTY=$(tty)
command -v gpg-connect-agent >/dev/null && gpg-connect-agent updatestartuptty /bye >/dev/null 2>&1

source $ZSH/oh-my-zsh.sh

export LANGUAGE=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# Use a terminal editor over SSH, Emacs locally.
if [[ -n $SSH_CONNECTION ]]; then
  export EDITOR='nano'
else
  export EDITOR='emacs'
fi

alias sourceenv="set -a && source .env && set +a"
# Upgrade system, editor, shell, and remote global skills; stop on failure.
# Local and account-synced skill copies refresh through the dotfiles installer.
alias upgrade="yay -Syu --devel --sudoloop && doom upgrade && omz update && npx --yes skills update --global --yes"

export XZ_DEFAULTS="-T0"
if [ -e $HOME/.nix-profile/etc/profile.d/nix.sh ]; then . $HOME/.nix-profile/etc/profile.d/nix.sh; fi
export PATH="$PATH:$HOME/.dotnet/tools"
export GOPATH="$HOME/go"
export PATH="$PATH:$HOME/go/bin"
export PATH="$HOME/.local/bin:$PATH"
export PATH="$PATH:$HOME/.config/emacs/bin"
export PATH="$HOME/.bun/bin:$PATH"
export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"

# Route Docker clients to Podman only when its user socket exists.
[[ -S "/run/user/$(id -u)/podman/podman.sock" ]] && export DOCKER_HOST="unix:///run/user/$(id -u)/podman/podman.sock"

export CLAUDE_CODE_SUBAGENT_MODEL=opus

eval "$(starship init zsh)"

# Optional tools must not break startup on machines where they are absent.
command -v velero >/dev/null && source <(velero completion zsh)
[[ -r "$HOME/.openclaw/completions/openclaw.zsh" ]] && source "$HOME/.openclaw/completions/openclaw.zsh"

# Keep machine-specific overrides out of version control; load them last.
[[ -r "$HOME/.zshrc.local" ]] && source "$HOME/.zshrc.local"
