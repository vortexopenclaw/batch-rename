#!/usr/bin/env python3
"""Create restricted ZIP and unsigned manifest. Signing is a separate stdin-only step."""
import hashlib, json, pathlib, plistlib, stat, sys, zipfile
app = pathlib.Path(sys.argv[1]); output = pathlib.Path(sys.argv[2]); output.mkdir(parents=True, exist_ok=True)
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
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
manifest = dict(bundleIdentifier=info['CFBundleIdentifier'], version=version, build=build, assetKey='batch-rename/releases/' + asset, downloadURL=config['downloadURL'], sha256=hashlib.sha256((output / asset).read_bytes()).hexdigest(), minimumMacOS='14.0.0')
(output / 'unsigned.json').write_text(json.dumps(manifest))
