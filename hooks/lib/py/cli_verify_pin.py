"""Re-check the selected binary against tools/cli-sha256 (ADR 0008).

argv: <pin_path> <name> <bin> <fleet_root>
"""
import hashlib
import os
import stat
import sys

pin_path, name, bin_path, fleet_arg = sys.argv[1:]
fleet_root = os.path.realpath(fleet_arg)
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

def fail(msg):
    sys.stderr.write(msg + "\n")
    sys.exit(2)

try:
    real = os.path.realpath(bin_path)
except OSError:
    fail("agent-cli: refusing untrusted executable path for %s" % name)
if is_under_forbidden(real) or not chain_trusted(real, os.getuid()):
    fail("agent-cli: refusing untrusted executable path for %s" % name)

expected = None
try:
    pin_file = open(pin_path, "r")
except OSError:
    fail("agent-cli: cannot read pin file %s" % pin_path)
with pin_file:
    for raw in pin_file:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) == 2 and parts[0] == name:
            expected = parts[1].lower()
            break
if expected is None or len(expected) != 64 or any(c not in "0123456789abcdef" for c in expected):
    fail("agent-cli: no sha256 pin for %s in %s" % (name, pin_path))

digest = hashlib.sha256()
try:
    blob = open(real, "rb")
except OSError:
    fail("agent-cli: refusing untrusted executable path for %s" % name)
with blob:
    while True:
        chunk = blob.read(1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)
actual = digest.hexdigest()
if actual != expected:
    fail(
        "agent-cli: sha256 mismatch for %s: expected %s actual %s\n"
        "If the CLI was upgraded deliberately, re-pin it:\n"
        "  bash %s/tools/pin-clis.sh"
        % (real, expected, actual, fleet_root)
    )
sys.exit(0)
