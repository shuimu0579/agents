"""Resolve a vendor CLI to a trusted physical path (ADR 0008, audit B2).

argv: <fleet_root> <name> <PATH> <HOME>
"""
import os
import stat
import sys

fleet_root = os.path.realpath(sys.argv[1])
name = sys.argv[2]
raw_path = sys.argv[3]
home = sys.argv[4]

search_dirs = []
for entry in raw_path.split(os.pathsep):
    if entry and os.path.isabs(entry):
        search_dirs.append(entry)
for std_dir in (
    "/opt/homebrew/bin",
    "/usr/local/bin",
    os.path.join(home, ".local", "bin") if home else "",
    "/usr/bin",
    "/bin",
):
    if std_dir and os.path.isabs(std_dir) and std_dir not in search_dirs:
        search_dirs.append(std_dir)

forbidden_prefixes = (
    fleet_root,
    "/tmp",
    "/private/tmp",
    "/var/tmp",
    "/private/var/tmp",
)

def is_under_forbidden(p):
    for pref in forbidden_prefixes:
        if p == pref or p.startswith(pref + os.sep):
            return True
    return False

def chain_trusted(real, uid):
    """File plus every ancestor through the first root-owned directory."""
    try:
        st = os.stat(real)
    except OSError:
        return False
    if not stat.S_ISREG(st.st_mode):
        return False
    if st.st_mode & stat.S_IWOTH:
        return False
    if st.st_uid not in (uid, 0):
        return False
    current = os.path.dirname(real)
    for _ in range(64):
        try:
            dst = os.stat(current)
        except OSError:
            return False
        if not stat.S_ISDIR(dst.st_mode):
            return False
        if dst.st_mode & stat.S_IWOTH:
            return False
        if dst.st_uid not in (uid, 0):
            return False
        if dst.st_uid == 0:
            return True
        parent = os.path.dirname(current)
        if parent == current:
            return False
        current = parent
    return False

uid = os.getuid()
for directory in search_dirs:
    candidate = os.path.join(directory, name)
    if not os.path.exists(candidate) and not os.path.islink(candidate):
        continue
    if not os.access(candidate, os.X_OK):
        continue
    real = os.path.realpath(candidate)
    if is_under_forbidden(os.path.abspath(candidate)) or is_under_forbidden(real):
        sys.exit(126)
    if not chain_trusted(real, uid):
        sys.exit(126)
    print(real)
    sys.exit(0)

sys.exit(127)
