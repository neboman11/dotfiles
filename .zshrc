# If you come from bash you might have to change your $PATH.
# export PATH=$HOME/bin:/usr/local/bin:$PATH

# Path to your oh-my-zsh installation.
export ZSH="$HOME/.oh-my-zsh"

# Set name of the theme to load --- if set to "random", it will
# load a random theme each time oh-my-zsh is loaded, in which case,
# to know which specific one was loaded, run: echo $RANDOM_THEME
# See https://github.com/ohmyzsh/ohmyzsh/wiki/Themes
# Acceptable-ish themes
# dallas fino-time half-life jonathan bullet-train xiong-chiamiov-plus passion headline

# Set list of themes to pick from when loading at random
# Setting this variable when ZSH_THEME=random will cause zsh to load
# a theme from this variable instead of looking in $ZSH/themes/
# If set to an empty array, this variable will have no effect.
# ZSH_THEME_RANDOM_CANDIDATES=( "robbyrussell" "agnoster" )

# Uncomment the following line to use case-sensitive completion.
# CASE_SENSITIVE="true"

# Uncomment the following line to use hyphen-insensitive completion.
# Case-sensitive completion must be off. _ and - will be interchangeable.
# HYPHEN_INSENSITIVE="true"

# Uncomment one of the following lines to change the auto-update behavior
# zstyle ':omz:update' mode disabled  # disable automatic updates
# zstyle ':omz:update' mode auto      # update automatically without asking
# zstyle ':omz:update' mode reminder  # just remind me to update when it's time

# Uncomment the following line to change how often to auto-update (in days).
# zstyle ':omz:update' frequency 13

# Uncomment the following line if pasting URLs and other text is messed up.
# DISABLE_MAGIC_FUNCTIONS="true"

# Uncomment the following line to disable colors in ls.
# DISABLE_LS_COLORS="true"

# Uncomment the following line to disable auto-setting terminal title.
# DISABLE_AUTO_TITLE="true"

# Uncomment the following line to enable command auto-correction.
# ENABLE_CORRECTION="true"

# Uncomment the following line to display red dots whilst waiting for completion.
# You can also set it to another string to have that shown instead of the default red dots.
# e.g. COMPLETION_WAITING_DOTS="%F{yellow}waiting...%f"
# Caution: this setting can cause issues with multiline prompts in zsh < 5.7.1 (see #5765)
# COMPLETION_WAITING_DOTS="true"

# Uncomment the following line if you want to disable marking untracked files
# under VCS as dirty. This makes repository status check for large repositories
# much, much faster.
# DISABLE_UNTRACKED_FILES_DIRTY="true"

# Uncomment the following line if you want to change the command execution time
# stamp shown in the history command output.
# You can set one of the optional three formats:
# "mm/dd/yyyy"|"dd.mm.yyyy"|"yyyy-mm-dd"
# or set a custom format using the strftime function format specifications,
# see 'man strftime' for details.
# HIST_STAMPS="mm/dd/yyyy"

# Would you like to use another custom folder than $ZSH/custom?
# ZSH_CUSTOM=/path/to/new-custom-folder

# vscode command - used by the vscode plugin
VSCODE=code

# Which plugins would you like to load?
# Standard plugins can be found in $ZSH/plugins/
# Custom plugins may be added to $ZSH_CUSTOM/plugins/
# Example format: plugins=(rails git textmate ruby lighthouse)
# Add wisely, as too many plugins slow down shell startup.
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
    #vscode
    zsh-interactive-cd
    zsh-autosuggestions
    )

# Some terminal apps (e.g. Superset's embedded terminal) spawn shells with a
# stripped env that omits XDG_RUNTIME_DIR/DBUS_SESSION_BUS_ADDRESS/DISPLAY/
# WAYLAND_DISPLAY, even though the graphical session has them. Without
# DBUS_SESSION_BUS_ADDRESS, notify-send (used by the bgnotify plugin) tries to
# autolaunch D-Bus via X11 and fails with "Cannot autolaunch D-Bus without X11
# $DISPLAY". Backfill: XDG_RUNTIME_DIR/the bus socket path are standard
# (/run/user/<uid>) so they don't need a working bus to find; once those are
# set, systemd --user can be queried for the rest of the real session env.
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

# GPG pinentry needs the current terminal to prompt over SSH (curses) instead
# of the cached one from a previous session/GUI login; refresh it every shell
# so `git commit` picks the right prompt (GUI locally, terminal over SSH)
# without any manual step (see ~/.gnupg/gpg-agent.conf pinentry-program).
export GPG_TTY=$(tty)
command -v gpg-connect-agent >/dev/null && gpg-connect-agent updatestartuptty /bye >/dev/null 2>&1

source $ZSH/oh-my-zsh.sh

# User configuration

# export MANPATH="/usr/local/man:$MANPATH"

# You may need to manually set your language environment
# export LANG=en_US.UTF-8
export LANGUAGE=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# Preferred editor for local and remote sessions
if [[ -n $SSH_CONNECTION ]]; then
  export EDITOR='nano'
else
  export EDITOR='emacs'
fi

# Compilation flags
# export ARCHFLAGS="-arch x86_64"

# Set personal aliases, overriding those provided by oh-my-zsh libs,
# plugins, and themes. Aliases can be placed here, though oh-my-zsh
# users are encouraged to define aliases within the ZSH_CUSTOM folder.
# For a full list of active aliases, run `alias`.
#
# Example aliases
# alias zshconfig="mate ~/.zshrc"
# alias ohmyzsh="mate ~/.oh-my-zsh"
alias sourceenv="set -a && source .env && set +a"
alias upgrade="yay -Syu --devel --sudoloop && doom upgrade && omz update"

export XZ_DEFAULTS="-T0"
if [ -e $HOME/.nix-profile/etc/profile.d/nix.sh ]; then . $HOME/.nix-profile/etc/profile.d/nix.sh; fi # added by Nix installer
export PATH="$PATH:$HOME/.dotnet/tools"
export GOPATH="$HOME/go"
export PATH="$PATH:$HOME/go/bin"
export PATH="$HOME/.local/bin:$PATH"
export PATH="$PATH:$HOME/.config/emacs/bin"
export PATH="$HOME/.bun/bin:$PATH"
export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"

# Use podman socket for docker compatibility
[[ -S "/run/user/$(id -u)/podman/podman.sock" ]] && export DOCKER_HOST="unix:///run/user/$(id -u)/podman/podman.sock"

# Claude Code
export CLAUDE_CODE_SUBAGENT_MODEL=opus

eval "$(starship init zsh)"

# Completions for tools that may not be installed everywhere
command -v velero >/dev/null && source <(velero completion zsh)
[[ -r "$HOME/.openclaw/completions/openclaw.zsh" ]] && source "$HOME/.openclaw/completions/openclaw.zsh"

# Machine-specific settings (not tracked in dotfiles)
[[ -r "$HOME/.zshrc.local" ]] && source "$HOME/.zshrc.local"
