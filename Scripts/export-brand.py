#!/usr/bin/env python3
"""Export website logo assets and the compiled native macOS iconset."""
from pathlib import Path
from PIL import Image
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
source = Image.open(ROOT / 'Resources/Brand/litezip-logo-source.png').convert('RGBA')
assert source.getextrema()[3][0] == 0, 'The master must have transparent corners.'
master = source.resize((1024, 1024), Image.Resampling.LANCZOS)
master.save(ROOT / 'Resources/Brand/litezip-logo.png')
iconset = ROOT / 'build/brand/AppIcon.iconset'
if iconset.exists():
    shutil.rmtree(iconset)
subprocess.run(['iconutil', '-c', 'iconset', str(ROOT / 'Resources/AppIcon.icns'),
                '-o', str(iconset)], check=True)
assets = ROOT / 'website/dist/assets'
assets.mkdir(parents=True, exist_ok=True)
for size in (32, 64, 180, 256, 512, 1024):
    master.resize((size, size), Image.Resampling.LANCZOS).save(assets / f'logo-{size}.png')
master.save(assets / 'logo.webp', quality=92, method=6)
for theme in ('light', 'dark'):
    image = Image.open(ROOT / f'docs/screenshots/{theme}.png').convert('RGB')
    image.save(assets / f'app-{theme}.webp', quality=90, method=6)
print('Exported transparent website logo, compiled macOS iconset and website assets.')
