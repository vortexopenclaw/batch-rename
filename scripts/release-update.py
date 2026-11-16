#!/usr/bin/env python3
"""Create restricted ZIP and unsigned manifest. Signing is a separate stdin-only step."""
import hashlib, json, pathlib, plistlib, re, stat, sys, zipfile
app = pathlib.Path(sys.argv[1]); output = pathlib.Path(sys.argv[2]); output.mkdir(parents=True, exist_ok=True)
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
minimum = info.get('LSMinimumSystemVersion')
if not isinstance(minimum, str) or not re.fullmatch(r'[0-9]+\.[0-9]+(?:\.[0-9]+)?', minimum):
    raise ValueError('Invalid or missing LSMinimumSystemVersion')
parts = [int(part) for part in minimum.split('.')]
if any(part > sys.maxsize for part in parts):
    raise ValueError('Invalid LSMinimumSystemVersion component')
minimum = '.'.join(str(part) for part in parts + ([0] if len(parts) == 2 else []))
config = json.loads((app / 'Contents/Resources/UpdateConfiguration.json').read_text())
version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
assert all(c.isdigit() or c == '.' for c in version) and build.isdigit()
asset = f'batch-rename-{version.replace(".", "_")}-{build}.zip'
with zipfile.ZipFile(output / asset, 'w', compression=zipfile.ZIP_STORED, allowZip64=False) as z:
    for path in sorted(app.rglob('*')):
        assert not path.is_symlink(), f'Symlink unsupported: {path}'
        assert path.is_dir() or path.is_file()
        name = 'Batch Rename.app/' + path.relative_to(app).as_posix() + ('/' if path.is_dir() else '')
        assert name.isascii(), 'Release ZIP names must be ASCII'
        entry = zipfile.ZipInfo(name); entry.create_system = 3
        entry.external_attr = ((stat.S_IFDIR | 0o755) if path.is_dir() else (stat.S_IFREG | (0o755 if path.stat().st_mode & 0o111 else 0o644))) << 16
        z.writestr(entry, b'' if path.is_dir() else path.read_bytes())
manifest = dict(bundleIdentifier=info['CFBundleIdentifier'], version=version, build=build, assetKey='batch-rename/releases/' + asset, downloadURL=config['downloadURL'], sha256=hashlib.sha256((output / asset).read_bytes()).hexdigest(), minimumMacOS=minimum)
# Content-address new archives so concurrent publishers cannot put different
# bytes at one release key using the supported publisher.
addressed_asset = asset.removesuffix('.zip') + '-' + manifest['sha256'] + '.zip'
(output / asset).rename(output / addressed_asset)
manifest['assetKey'] = 'batch-rename/releases/' + addressed_asset
(output / 'unsigned.json').write_text(json.dumps(manifest))
