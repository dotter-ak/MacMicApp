"""Package and verify the Release app built by package-release.sh. macOS only."""
import hashlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


def run(*args):
    subprocess.run(args, check=True)


def package(root):
    config = {}
    for line in (root / "Config/App.xcconfig").read_text().splitlines():
        if " = " in line:
            key, value = line.split(" = ", 1)
            config[key.strip()] = value.strip()
    product = config["PRODUCT_NAME"]
    version = config["MARKETING_VERSION"]
    architecture = config["ARCHS"]
    app = root / ".local/build/Release" / f"{product}.app"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    expected = {
        "CFBundleName": product,
        "CFBundleExecutable": product,
        "CFBundleIdentifier": config["PRODUCT_BUNDLE_IDENTIFIER"],
        "CFBundleShortVersionString": version,
        "CFBundleVersion": config["CURRENT_PROJECT_VERSION"],
        "LSMinimumSystemVersion": config["MACOSX_DEPLOYMENT_TARGET"],
    }
    if any(info.get(key) != value for key, value in expected.items()):
        raise RuntimeError("The Release app does not match App.xcconfig. Rebuild before packaging.")
    binary = app / "Contents/MacOS" / product
    archs = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split()
    if archs != [architecture]:
        raise RuntimeError(f"Unexpected executable architectures: {archs}")
    run("codesign", "--verify", "--strict", str(app))
    dist = root / ".local/build/Distribution"
    dist.mkdir(parents=True, exist_ok=True)
    name = f"{product}-{version}-macOS-{architecture}.zip"
    with tempfile.TemporaryDirectory(prefix=".package-", dir=dist) as temporary:
        stage = Path(temporary)
        payload = stage / "payload"
        payload.mkdir()
        run("ditto", "--norsrc", "--noextattr", str(app), str(payload / app.name))
        shutil.copyfile(root / "LICENSE", payload / "LICENSE")
        archive = stage / name
        run("ditto", "-c", "-k", "--norsrc", "--noextattr", str(payload), str(archive))
        with zipfile.ZipFile(archive) as zipped:
            if zipped.testzip() is not None:
                raise RuntimeError("ZIP integrity verification failed.")
            packaged_info = plistlib.loads(zipped.read(f"{app.name}/Contents/Info.plist"))
            if packaged_info != info or zipped.read("LICENSE") != (root / "LICENSE").read_bytes():
                raise RuntimeError("ZIP metadata or license does not match the Release payload.")
        extracted = stage / "extracted"
        run("ditto", "-x", "-k", str(archive), str(extracted))
        run("codesign", "--verify", "--strict", str(extracted / app.name))
        checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
        checksum_file = stage / f"{name}.sha256"
        checksum_file.write_text(f"{checksum}  {name}\n")
        destination = dist / name
        if destination.exists():
            previous_hash = hashlib.sha256(destination.read_bytes()).hexdigest()
            if previous_hash != checksum:
                previous = dist / "previous"
                previous.mkdir(exist_ok=True)
                backup = previous / f"{destination.stem}-{previous_hash[:12]}.zip"
                if not backup.exists():
                    shutil.copyfile(destination, backup)
        # Publish only the verified payload. Keep the previous ZIP recoverable.
        archive.replace(destination)
        checksum_file.replace(dist / checksum_file.name)
        print(f"Packaged {version} ({info['CFBundleVersion']}): {destination}")
        print(f"SHA256: {checksum}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Run scripts/package-release.sh from the project checkout.")
    package(Path(sys.argv[1]).resolve())
