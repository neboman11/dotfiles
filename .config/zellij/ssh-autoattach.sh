# Sourced from the login profiles by setup.sh: attaches interactive SSH logins to the
# shared zellij session "main", creating it on first use, so every device lands in the
# same session. Detaching or quitting cleanly ends the login; if zellij fails you get a
# plain shell instead of being locked out. Non-interactive ssh (scp, rsync, ssh host cmd)
# and shells already inside zellij are left alone.
if [ -n "$SSH_CONNECTION" ] && [ -z "$ZELLIJ" ] && [ -t 0 ] && [ -t 1 ]; then
    if command -v zellij >/dev/null 2>&1; then
        zellij attach --create main && exit
    elif [ -x "$HOME/.local/bin/zellij" ]; then
        "$HOME/.local/bin/zellij" attach --create main && exit
    fi
fi
