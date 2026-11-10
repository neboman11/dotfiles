#!/usr/bin/python3
"""Desktop-approved, user-wide sudo authentication; never handle passwords here."""

import argparse
import os
from pathlib import Path
import pwd
import re
import subprocess
import sys
import tempfile

SUDO = "/usr/bin/sudo"
VISUDO = "/usr/bin/visudo"
SCRIPT = Path(__file__).resolve()
ASKPASS = SCRIPT.with_name("askpass")
HEADER = "# Managed by omp sudo-window; authentication cache only, no NOPASSWD.\n"


def run(*args: str, **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(args, check=False, **kwargs)


def install_root(remove: bool) -> int:
    """Install only a per-user timestamp policy after sudo authenticates its caller."""
    if os.geteuid() != 0 or not os.environ.get("SUDO_UID", "").isdigit():
        raise RuntimeError("Run 'omp-sudo install' or 'omp-sudo uninstall' as your normal user.")
    uid = int(os.environ["SUDO_UID"])
    if uid == 0:
        raise RuntimeError("A non-root sudo caller is required.")
    user = pwd.getpwuid(uid).pw_name
    if not re.fullmatch(r"[a-z_][a-z0-9_-]*\$?", user):
        raise RuntimeError("Unsupported sudoers username.")
    directory = Path("/etc/sudoers.d")
    target = directory / f"99-omp-sudo-window-{uid}"
    previous = None
    if target.is_symlink():
        raise RuntimeError(f"Refusing symlink: {target}")
    if target.exists():
        previous = target.read_text()
        if not previous.startswith(HEADER):
            raise RuntimeError(f"Refusing to replace unmanaged policy: {target}")
    if remove:
        if previous is not None:
            target.unlink()
        print(f"Removed timestamp policy for {user}; normal sudo defaults restored.")
        return 0
    if run(VISUDO, "-c").returncode:
        raise RuntimeError("Existing sudoers configuration is invalid; no changes made.")
    content = HEADER + f"Defaults:{user} timestamp_type=global, timestamp_timeout=15\n"
    with tempfile.NamedTemporaryFile(mode="w", dir=directory, prefix=".omp-", delete=False) as staged:
        staged_path = Path(staged.name)
        staged.write(content)
        staged.flush()
        os.fchmod(staged.fileno(), 0o440)
        os.fsync(staged.fileno())
    try:
        if run(VISUDO, "-cf", str(staged_path)).returncode:
            raise RuntimeError("Timestamp policy failed sudoers validation.")
        os.replace(staged_path, target)
        if run(VISUDO, "-c").returncode:
            if previous is None:
                target.unlink()
            else:
                target.write_text(previous)
                target.chmod(0o440)
            raise RuntimeError("Combined sudoers validation failed; previous policy restored.")
    finally:
        staged_path.unlink(missing_ok=True)
    print(f"Installed {target}: shared sudo cache, 15-minute inactivity timeout.")
    print("This changes authentication caching only; existing sudo permissions still apply.")
    return 0


def authenticate(*args: str, reason: str) -> int:
    if not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        raise RuntimeError("No desktop display. Run 'sudo -v' in your own terminal instead.")
    environment = os.environ.copy()
    environment["SUDO_ASKPASS"] = str(ASKPASS)
    environment["OMP_SUDO_REASON"] = reason
    # The askpass helper may be called repeatedly by sudo after a wrong password.
    # A non-secret, per-invocation marker permits only one actual desktop dialog.
    with tempfile.TemporaryDirectory(prefix="omp-sudo-") as attempt:
        environment["OMP_SUDO_ATTEMPT_DIR"] = attempt
        return run(SUDO, "-A", "-p", "OMP sudo approval: ", *args, env=environment).returncode


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("install", "grant", "status", "revoke", "uninstall", "install-root", "uninstall-root"))
    parser.add_argument("--reason", default="Privileged local system administration")
    args = parser.parse_args()
    if args.action in ("install-root", "uninstall-root"):
        return install_root(args.action == "uninstall-root")
    if os.geteuid() == 0:
        raise RuntimeError("Run this command as your normal desktop user, not through sudo.")
    if args.action == "status":
        # -N does not update the timestamp, so observing status cannot keep access alive.
        result = run(SUDO, "-N", "-n", "/usr/bin/true", stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print("Sudo available without password." if result.returncode == 0 else "Sudo locked (or not permitted).")
        return result.returncode
    if args.action == "revoke":
        result = run(SUDO, "-K")
        if result.returncode == 0:
            print("Sudo timestamps removed. Already-running root processes are unaffected.")
        return result.returncode
    if args.action in ("install", "uninstall"):
        action = args.action + "-root"
        try:
            result = authenticate("/usr/bin/python3", "-I", str(SCRIPT), action,
                                  reason=f"{args.action.title()} user-wide 15-minute sudo authentication cache")
        finally:
            # Clear bootstrap authentication even if the privileged operation fails.
            revoked = run(SUDO, "-K").returncode
            if revoked:
                print("WARNING: bootstrap sudo timestamps could not be removed.", file=sys.stderr)
        return result or revoked
    result = authenticate("-v", reason=args.reason)
    if result != 0:
        print("Sudo approval failed or was cancelled. Stop; do not retry automatically.", file=sys.stderr)
        return result
    # A new parent with no controlling terminal rules out ppid/tty-only caching.
    probe = "import subprocess,sys; sys.exit(subprocess.call(['/usr/bin/sudo','-N','-n','/usr/bin/id','-u']))"
    result = run("/usr/bin/python3", "-I", "-c", probe, start_new_session=True)
    environment = os.environ.copy()
    environment["LC_ALL"] = "C"
    policy = run(SUDO, "-N", "-n", "-l", env=environment, capture_output=True, text=True)
    types = re.findall(r"\btimestamp_type\s*=\s*(\w+)", policy.stdout)
    timeouts = re.findall(r"\btimestamp_timeout\s*=\s*(-?\d+(?:\.\d+)?)", policy.stdout)
    if (result.returncode or policy.returncode or not types or types[-1] != "global"
            or not timeouts or float(timeouts[-1]) != 15):
        run(SUDO, "-K")
        print("Shared 15-minute sudo policy not effective. Run 'omp-sudo install'; inspect 'sudo -l' for conflicts.",
              file=sys.stderr)
        return 1
    print("Sudo authenticated across independent processes; existing command permissions unchanged.")
    print("Timeout: 15 minutes of sudo inactivity. Revoke: omp-sudo revoke")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError) as error:
        print(f"omp-sudo: {error}", file=sys.stderr)
        sys.exit(1)
