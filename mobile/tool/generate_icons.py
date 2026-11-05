"""Regenerate iOS/Android launcher PNGs from assets/branding/app-icon.png.

Run on macOS: python3 tool/generate_icons.py (uses the built-in sips utility).
"""
import json
from pathlib import Path
import shutil
import struct
import subprocess


def main():
    if not shutil.which('sips'):
        raise SystemExit('This generator requires macOS sips.')
    root = Path(__file__).resolve().parents[1]
    source = root / 'assets/branding/app-icon.png'
    catalog = root / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
    targets = {}
    for entry in json.loads((catalog / 'Contents.json').read_text())['images']:
        size = round(float(entry['size'].split('x')[0]) * float(entry['scale'][:-1]))
        targets[catalog / entry['filename']] = size
    for density, size in {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96,
                          'xxhdpi': 144, 'xxxhdpi': 192}.items():
        targets[root / f'android/app/src/main/res/mipmap-{density}/ic_launcher.png'] = size
    for target, size in targets.items():
        subprocess.run(['sips', '-z', str(size), str(size), str(source),
                        '--out', str(target)], check=True, capture_output=True)
        data = target.read_bytes()
        if data[:8] != b'\x89PNG\r\n\x1a\n' or struct.unpack('>II', data[16:24]) != (size, size):
            raise SystemExit(f'Invalid generated icon: {target}')
    print(f'Generated and verified {len(targets)} launcher icons.')


if __name__ == '__main__':
    main()
