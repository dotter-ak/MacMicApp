#!/usr/bin/env python3
"""Stamp Apple's compiled icon, or install a verified resource bundle before signing."""
import hashlib
import json
import plistlib
import shutil
import sys
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_digest(root):
    result = hashlib.sha256()
    for path in sorted(root.rglob('*')):
        if path.is_file() and path.name != '.DS_Store':
            result.update(path.relative_to(root).as_posix().encode() + b'\0')
            result.update(path.read_bytes())
    return result.hexdigest()


def validate_bundle(bundle):
    assert (bundle / 'Assets.car').stat().st_size > 0, 'Missing native Assets.car'
    info = plistlib.loads((bundle / 'icon-info.plist').read_bytes())
    assert info.get('CFBundleIconName') == 'AppIcon', 'Unexpected app icon name'
    return info


def main():
    mode, source, bundle, *rest = sys.argv[1:]
    source, bundle = Path(source), Path(bundle)
    info = validate_bundle(bundle)
    if mode == 'stamp':
        manifest = {'source_sha256': source_digest(source), 'files': {
            p.name: digest(p) for p in sorted(bundle.iterdir())
            if p.is_file() and p.name != 'manifest.json'}}
        (bundle / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    elif mode == 'install':
        manifest = json.loads((bundle / 'manifest.json').read_text())
        assert manifest['source_sha256'] == source_digest(source), 'Icon sources changed; compile again'
        assert {'Assets.car', 'icon-info.plist'} <= manifest['files'].keys()
        for name, expected in manifest['files'].items():
            assert Path(name).name == name and not (bundle / name).is_symlink()
            assert digest(bundle / name) == expected, f'Corrupt resource: {name}'
        app = Path(rest[0])
        plist_path = app / 'Contents/Info.plist'
        app_info = plistlib.loads(plist_path.read_bytes())
        resources = app / 'Contents/Resources'
        resources.mkdir(parents=True, exist_ok=True)
        for name in manifest['files']:
            if name.endswith(('.car', '.icns')):
                shutil.copy2(bundle / name, resources / name)
        for key in ('CFBundleIconName', 'CFBundleIconFile', 'CFBundleIcons'):
            if key in info:
                app_info[key] = info[key]
        plist_path.write_bytes(plistlib.dumps(app_info))
    else:
        raise ValueError('Expected stamp or install')


if __name__ == '__main__':
    main()
