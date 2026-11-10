# dotfiles

 Linux dotfiles and config files.
 These are configured the way I like them, but they probably aren't configured in the most optimal way.

## Installing

### Basic config (requires emacs & zsh)

 Sets up oh-my-zsh, `.zshrc`, starship, doom emacs (evil disabled), and zellij. Safe to re-run: existing pieces are left alone and replaced files are kept as `<file>.bak.<timestamp>`. Run from a checkout, or standalone (it clones this repo to `~/.local/share/dotfiles`). Machine-specific shell settings go in `~/.zshrc.local`, which `.zshrc` sources if present.

 `upgrade` runs system, Doom Emacs, Oh My Zsh, and global Skills CLI updates in order, stopping on failure. Skills CLI updates remote sources; local/account-synced skill copies refresh through the AI installer.

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

 `ai-setup/setup-ai-tools.sh` installs the agents plus shared tooling (rtk, codegraph, codebase-memory-mcp, Caveman, Headroom, browser-use). All skills use `npx skills`: upstream sources are listed in `ai-setup/bundle/skills.tsv`; `bundle/skills/` contains personal skills and preserved codebase-memory/Superset skill snapshots. The local pack is restored to `~/.local/share/ai-setup/skills` before installation so its lock source survives temporary staging cleanup. omp installs use only the CLI's `universal` target (`~/.agents/skills`) with links in `~/.omp/agent/skills`; no other agent is targeted. Runtime binaries, MCP servers, hooks, commands, and task agents still use their existing installers. Safe to re-run; replaced files are backed up to `~/.ai-setup-backups/`.

 ```sh
 git clone https://github.com/neboman11/dotfiles && cd dotfiles/ai-setup
 ./setup-ai-tools.sh install            # omp only
 ./setup-ai-tools.sh install --all      # or: --omp --claude --codex --opencode --openclaw
 ./setup-ai-tools.sh install --dry-run  # preview
 ```

 Refresh the bundle from the current machine with `./setup-ai-tools.sh export`. It contains no credentials, sessions, runtime state, or personal agent memory; export aborts if anything looks like a secret or mentions the login name. Remote skills update through `npx skills update`; local skill snapshots update by editing `bundle/skills/` and rerunning install. Keep Superset's app skill sync separate: it can overwrite its own shared skill names. The setup does not grant sudo access or install sudoers policy; follow the `sudo-window` skill if you need that capability.

 Account-synced skills are installed through Skills CLI from `~/.claude/skills/synced` when available; their content and account IDs are never bundled. On a fresh machine, sign in and sync that source before rerunning install. omp disables direct Claude/Codex user-skill discovery and the old account-specific custom path, so the Skills CLI copies take precedence without duplicate aliases. The account-synced `deep-research` skill retains its existing precedence over ECC's same-named skill.
