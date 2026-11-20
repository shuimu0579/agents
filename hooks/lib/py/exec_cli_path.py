"""ADR 0008: identity check for the pinned CLI wrapper path.

argv: <fleet_root> <path>. Exit 0 only when <path> is the fleet's
tools/agent-cli.sh by filesystem identity (same inode), never by string prefix.
The relative form is refused: a relative path is resolved against whatever
directory the hook process happens to run in, not the event's execution
directory (audit B4).
"""
import os
import stat
import sys

root_arg, path_arg = sys.argv[1], sys.argv[2]
root_real = os.path.realpath(root_arg)
expected = os.path.join(root_real, "tools", "agent-cli.sh")
tools_dir = os.path.join(root_real, "tools")

if not os.path.isabs(path_arg):
    sys.exit(1)
if os.path.islink(root_real) or os.path.islink(tools_dir) or os.path.islink(expected):
    sys.exit(1)
try:
    st = os.lstat(expected)
except OSError:
    sys.exit(1)
if not stat.S_ISREG(st.st_mode) or os.path.realpath(expected) != expected:
    sys.exit(1)
# Reject any symlink component: a symlinked fleet directory can be retargeted
# between the check and the host's exec (audit #4).
current = path_arg
while True:
    if os.path.islink(current):
        sys.exit(1)
    parent = os.path.dirname(current)
    if parent == current:
        break
    current = parent
try:
    if not os.path.samefile(path_arg, expected):
        sys.exit(1)
except OSError:
    sys.exit(1)
sys.exit(0)
