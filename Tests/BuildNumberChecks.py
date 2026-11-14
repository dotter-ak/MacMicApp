import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
HELPER = PROJECT / "scripts/lib/build-number.py"


class BuildNumberChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        (self.root / "Config").mkdir()
        self.config = self.root / "Config/App.xcconfig"
        self.config.write_text("MARKETING_VERSION = 0.1.0\nCURRENT_PROJECT_VERSION = 8\nARCHS = arm64\n")
        self.config.chmod(0o644)

    def command(self, code):
        return [sys.executable, str(HELPER), str(self.root), sys.executable, "-c", code]

    def run_build(self, code):
        return subprocess.run(self.command(code), text=True, capture_output=True)

    def test_successive_builds_receive_persisted_numbers(self):
        for number in (9, 10):
            result = self.run_build("import os; print('number=' + os.environ['MACMIC_BUILD_NUMBER'])")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"number={number}", result.stdout)
            self.assertIn(f"CURRENT_PROJECT_VERSION = {number}\n", self.config.read_text())
        self.assertIn("MARKETING_VERSION = 0.1.0\n", self.config.read_text())
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o644)

    def test_failure_keeps_its_number_and_exit_status(self):
        result = self.run_build("raise SystemExit(7)")
        self.assertEqual(result.returncode, 7)
        self.assertIn("CURRENT_PROJECT_VERSION = 9\n", self.config.read_text())
        self.assertEqual(self.run_build("pass").returncode, 0)
        self.assertIn("CURRENT_PROJECT_VERSION = 10\n", self.config.read_text())

    def test_concurrent_builds_keep_one_number_until_completion(self):
        code = """
import os, time
from pathlib import Path
config = Path(os.environ['MACMIC_BUILD_ROOT']) / 'Config/App.xcconfig'
expected = 'CURRENT_PROJECT_VERSION = ' + os.environ['MACMIC_BUILD_NUMBER'] + '\\n'
assert expected in config.read_text()
time.sleep(0.15)
assert expected in config.read_text(), 'Another build changed the number mid-build'
"""
        processes = [subprocess.Popen(self.command(code), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                     for _ in range(2)]
        outputs = []
        for process in processes:
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, stderr)
            outputs.append(stdout)
        self.assertEqual({output.strip() for output in outputs},
                         {"Building with build number 9", "Building with build number 10"})

    def test_invalid_configuration_does_not_launch_build(self):
        for contents in ("CURRENT_PROJECT_VERSION = bad\n", "", "CURRENT_PROJECT_VERSION = 8\nCURRENT_PROJECT_VERSION = 9\n"):
            self.config.write_text(contents)
            result = self.run_build("print('BUILD STARTED')")
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("BUILD STARTED", result.stdout)
            self.assertEqual(self.config.read_text(), contents)

    def test_native_script_passes_reserved_number_to_xcode(self):
        scripts = self.root / "scripts"
        (scripts / "lib").mkdir(parents=True)
        shutil.copy2(HELPER, scripts / "lib/build-number.py")
        shutil.copy2(PROJECT / "scripts/build-native.sh", scripts / "build-native.sh")
        binaries = self.root / "bin"
        binaries.mkdir()
        for name, body in {
            "xcrun": "exit 0\n",
            "xcodebuild": 'printf "%s\\n" "$@" > "$CAPTURE_ARGS"\n',
        }.items():
            path = binaries / name
            path.write_text("#!/bin/bash\n" + body)
            path.chmod(0o755)
        arguments = self.root / "arguments"
        environment = dict(os.environ, PATH=f"{binaries}:{os.environ['PATH']}", CAPTURE_ARGS=str(arguments))
        environment.pop("MACMIC_BUILD_ROOT", None)
        environment.pop("MACMIC_BUILD_NUMBER", None)
        linked_root = self.root / "linked-checkout"
        linked_root.symlink_to(self.root, target_is_directory=True)
        result = subprocess.run(["bash", str(linked_root / "scripts/build-native.sh"), "Release"],
                                env=environment, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("CURRENT_PROJECT_VERSION=9\n", arguments.read_text())
        self.assertIn("CURRENT_PROJECT_VERSION = 9\n", self.config.read_text())


if __name__ == "__main__":
    unittest.main()
