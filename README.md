# dotfiles

 Linux dotfiles and config files.
 These are configured the way I like them, but they probably aren't configured in the most optimal way.

## Installing

### Basic config (requires emacs & zsh)

 Sets up oh-my-zsh, `.zshrc`, starship, doom emacs (evil disabled), and zellij. Safe to re-run: existing pieces are left alone and replaced files are kept as `<file>.bak.<timestamp>`. Run from a checkout, or standalone (it clones this repo to `~/.local/share/dotfiles`). Machine-specific shell settings go in `~/.zshrc.local`, which `.zshrc` sources if present.

 Interactive SSH logins attach to a shared zellij session named `main` (created on first login), so a session survives dropped connections and can be picked up from any device. Detach with `Ctrl-o d`; detaching or quitting ends the SSH login. Non-interactive ssh (`scp`, `rsync`, `ssh host cmd`) is unaffected, and if zellij fails to start you get a plain shell. The hook lives in `~/.config/zellij/ssh-autoattach.sh` and is sourced from `~/.zprofile`, `~/.profile`, and `~/.bash_profile`; setup also removes old byobu launchers from those files. If zellij isn't installed, setup puts the upstream release binary in `~/.local/bin`.

 ```sh
 curl https://raw.githubusercontent.com/neboman11/dotfiles/master/setup.sh -o setup.sh && chmod +x setup.sh && ./setup.sh
 ```

### Config and install packages

 ```sh
 curl https://raw.githubusercontent.com/neboman11/dotfiles/master/setup.sh -o setup.sh && chmod +x setup.sh && ./setup.sh -i
 ```

 Options: `-d` skip doom emacs, `-z` skip zsh, `-m` skip zellij, `-v` enable the oh-my-zsh vscode plugin, `-i` install missing packages (pacman/apt/dnf), `-a TARGETS` also run the AI tooling setup below (`-a omp`, `-a omp,claude`, `-a all`).

### AI agent tooling (omp, Claude Code, Codex, OpenCode, OpenClaw)

 `ai-setup/setup-ai-tools.sh` installs the agents plus shared tooling (rtk, codegraph, codebase-memory-mcp, Caveman, Headroom, browser-use). Third-party skills, commands, agents, and hooks come from their own installers (`npx skills`, ECC's Codex sync, Caveman's installer, Claude/Codex plugins, `codebase-memory-mcp install`, `codegraph install`, `rtk init`); `ai-setup/bundle/` holds only personal configuration: settings, MCP servers, curated task agents, custom skills, and a CLAUDE.md section. Safe to re-run; replaced files are backed up to `~/.ai-setup-backups/`.

 ```sh
 git clone https://github.com/neboman11/dotfiles && cd dotfiles/ai-setup
 ./setup-ai-tools.sh install            # omp only
 ./setup-ai-tools.sh install --all      # or: --omp --claude --codex --opencode --openclaw
 ./setup-ai-tools.sh install --dry-run  # preview
 ```

 Refresh the bundle from the current machine with `./setup-ai-tools.sh export`. It contains no third-party content, credentials, sessions, or personal agent memory; export aborts if anything looks like a secret or mentions the login name.
