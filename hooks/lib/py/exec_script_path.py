"""Fleet test scripts: <fleet_root>/tests/**.sh, excluding hooks/ and scripts/."""
import os
import sys

root = os.path.realpath(sys.argv[1])
real = os.path.realpath(sys.argv[2])
if not os.path.isfile(real):
    sys.exit(1)
if sys.platform == "darwin":
    root = root.casefold()
    real = real.casefold()
tests = os.path.join(root, "tests") + os.sep
hooks = os.path.join(root, "hooks") + os.sep
scripts = os.path.join(root, "scripts") + os.sep
ok = real.startswith(tests) and not real.startswith(hooks) and not real.startswith(scripts) and real.endswith(".sh")
sys.exit(0 if ok else 1)
