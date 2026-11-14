"""Reserve one build number and serialize a build (including nested packaging)."""
import fcntl
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile


BUILD_NUMBER = re.compile(r"^CURRENT_PROJECT_VERSION[ \t]*=[ \t]*([0-9]+)[ \t]*$", re.MULTILINE)


def reserve(root):
    config = root / "Config/App.xcconfig"
    contents = config.read_text()
    matches = list(BUILD_NUMBER.finditer(contents))
    if len(matches) != 1:
        raise ValueError("App.xcconfig must contain one integer CURRENT_PROJECT_VERSION.")
    match = matches[0]
    number = str(int(match.group(1)) + 1)
    updated = contents[:match.start(1)] + number + contents[match.end(1):]
    # Replace atomically so interrupted writes cannot leave a partial config.
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=config.parent, delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(updated)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.chmod(stat.S_IMODE(config.stat().st_mode))
        temporary.replace(config)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return number


def run(root, command):
    root = root.resolve()
    local = root / ".local"
    local.mkdir(exist_ok=True)
    # Keep this file in place: unlinking a locked file would allow a second lock.
    with (local / "build-number.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        number = reserve(root)
        environment = dict(os.environ, MACMIC_BUILD_NUMBER=number, MACMIC_BUILD_ROOT=str(root))
        print(f"Building with build number {number}", flush=True)
        # A failed build consumes its number; never reuse an identity that may
        # already have been written into a binary. Hold the lock through packaging.
        return subprocess.run(command, env=environment).returncode


if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit("Usage: build-number.py PROJECT_ROOT COMMAND [ARG ...]")
    try:
        result = run(Path(sys.argv[1]), sys.argv[2:])
    except (OSError, ValueError) as error:
        raise SystemExit(str(error))
    raise SystemExit(result if result >= 0 else 128 - result)
