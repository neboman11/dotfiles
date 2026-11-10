---
name: sudo-window
description: Use whenever an omp job needs local sudo/root access, sudo reports a password is required, or the user asks to grant or revoke agent administrator access. Uses a desktop password prompt once for a shared 15-minute sudo inactivity window; never ask for passwords in chat.
---

# Desktop sudo approval

This machine uses standard sudo with a shared per-user authentication timestamp.
Helper: `~/.local/bin/omp-sudo`.

## Agent workflow

1. Confirm the user's task authorizes the privileged work and identify exact targets. Approval of sudo access does not authorize unrelated or destructive work.
2. Check access without prompting or extending the cache:
   ```bash
   ~/.local/bin/omp-sudo status
   ```
3. If locked, explain why root is needed and request the desktop prompt:
   ```bash
   ~/.local/bin/omp-sudo grant --reason 'Authorized local maintenance'
   ```
   The user enters their password in KDialog, not chat, tool input, environment variables, or a file. Password stdout goes directly from KDialog into sudo's askpass pipe. Never invoke `scripts/askpass` directly; that would expose its stdout.
4. Once approved, use normal noninteractive sudo:
   ```bash
   sudo -n /usr/bin/systemctl status qbt-vpn.service --no-pager
   ```
   Commands work across omp sessions and subagents running as the same Unix user. Do not give every child its own password prompt. Coordinate one grant in the parent.
5. If approval is cancelled or authentication fails, stop privileged work. Do not automatically retry or ask for the password in chat.
6. Verify the actual changed service/behavior. At the end, revoke if no concurrent authorized job still needs the shared window:
   ```bash
   ~/.local/bin/omp-sudo revoke
   ```
   If concurrent jobs still need access, report that the shared window remains open rather than disrupting them silently.

## Security boundary

- All processes under this Unix user can use the shared cache, not only omp. This is not agent isolation.
- Timeout is **15 minutes of sudo inactivity**, not an absolute 15-minute lease. Ordinary `sudo -n` commands refresh it. Do not run keepalive loops.
- `sudo -N -n COMMAND` uses an existing grant without refreshing its timestamp; prefer it for checks and when no extension is wanted.
- `revoke` runs `sudo -K`, removing this user's sudo timestamps. Existing root processes continue; persistent changes made as root are not undone.
- No password storage, permanent `NOPASSWD`, root daemon, or new sudo command permissions. Existing sudo policy still determines allowed commands.
- Full root access can modify this mechanism or sudo policy. Expiration is not containment against an untrusted root process.
- These helpers affect only the local desktop. Remote hosts need their own authorization.
- Omp tool approvals and destructive-action confirmations remain separate; never bypass them.

- Existing `NOPASSWD` exceptions remain usable after revocation. This machine already had a passwordless `qbt-vpn-run.sh` rule; this setup does not create or remove it.
## Installation / recovery

Installed through Skills CLI into `~/.agents/skills/sudo-window/`, linked from
`~/.omp/agent/skills/sudo-window/`. Link the executable helper without granting access:

```bash
mkdir -p ~/.local/bin
ln -sfn ~/.omp/agent/skills/sudo-window/scripts/omp-sudo.py ~/.local/bin/omp-sudo
```

```bash
omp-sudo install    # desktop password prompt; validates and installs timestamp policy
omp-sudo grant --reason 'Authorized local maintenance'
omp-sudo status     # exit 0 available, nonzero locked/error; never refreshes cache
omp-sudo revoke
omp-sudo uninstall  # removes only this helper's timestamp policy; clears timestamps
```

Installation is separate from granting access and clears bootstrap authentication.
Fresh installation therefore needs a setup password prompt, then one grant prompt.
Future jobs need only the grant prompt when no valid cache exists.
Policy: `/etc/sudoers.d/99-omp-sudo-window-<uid>`, owned by root, mode 0440.
Settings: `Defaults:<username> timestamp_type=global, timestamp_timeout=15`.
Uninstall restores normal sudo defaults; user-level helpers can remain for inspection.

Requires `/usr/bin/sudo`, `/usr/bin/visudo`, Python 3, KDialog, and the desktop display/session environment. If no display is available, the user can run `sudo -v` in their own terminal; with the installed global timestamp policy this also unlocks agent shells. Never collect that password yourself.

If a fresh granted cache does not work across processes, inspect effective `sudo -l` defaults and later conflicting sudoers files; do not claim success or weaken permissions.

## Design provenance

Existing askpass workflow reviewed: https://github.com/arimxyer/toolchest/blob/main/plugins/sudo-askpass/skills/sudo-askpass/SKILL.md . This local implementation adds explicit global-cache setup, non-refreshing status, and revocation. It does not install the external plugin.
