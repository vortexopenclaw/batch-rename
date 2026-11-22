#!/usr/bin/env python3
"""Offline release metadata checks for CI. Never contacts the network; CI pipes `gh` output in.

  readme [--root DIR]               README title equals Info.plist version and build
  tag TAG [--root DIR]              tag, Info.plist, README, and Worker RELEASE_TAG agree
  previous-tag TAG                  highest other published tag from stdin (one per line)
  previous-identity MANIFEST        PREVIOUS_VERSION/PREVIOUS_BUILD lines for $GITHUB_ENV
"""
import argparse
import json
import pathlib
import plistlib
import re
import sys

# [0-9], not \d: Python's \d matches non-ASCII digits. No leading zeros, like UpdatePolicy.version.
COMPONENT = r'(?:0|[1-9][0-9]*)'
VERSION = COMPONENT + r'\.' + COMPONENT + r'\.' + COMPONENT
TAG = re.compile(r'v(' + VERSION + r')(?:-beta)?')
BUILD = re.compile(r'[1-9][0-9]*')


def fail(message):
    print('release-metadata: ' + message, file=sys.stderr)
    raise SystemExit(1)


def parsed(version):
    return tuple(int(part) for part in version.split('.'))


def bundle(root):
    info = plistlib.loads((root / 'Resources/Info.plist').read_bytes())
    version, build = info.get('CFBundleShortVersionString'), info.get('CFBundleVersion')
    if not isinstance(version, str) or not re.fullmatch(VERSION, version) or not isinstance(build, str) or not BUILD.fullmatch(build):
        fail('Info.plist version/build are malformed')
    if info.get('CFBundleIdentifier') != 'com.vortexopenclaw.batch-rename':
        fail('unexpected CFBundleIdentifier')
    return version, build


def check_readme(root):
    version, build = bundle(root)
    lines = (root / 'README.md').read_text(encoding='utf-8').splitlines()
    expected = f'# Batch Rename {version} (build {build})'
    if not lines or lines[0] != expected:
        fail(f'README title must be {expected!r}, found {(lines[0] if lines else "")!r}')


def check_tag(root, tag):
    match = TAG.fullmatch(tag)
    if not match:
        fail(f'tag {tag!r} must be vX.Y.Z or vX.Y.Z-beta without leading zeros')
    version, _ = bundle(root)
    if match.group(1) != version:
        fail(f'tag {tag} does not match Info.plist version {version}')
    worker = json.loads((root / 'workers/batch-rename/wrangler-github.json').read_text())
    pinned = worker.get('vars', {}).get('RELEASE_TAG')
    if pinned != tag:
        fail(f'wrangler-github.json RELEASE_TAG {pinned!r} must equal the tag being released {tag!r}')
    check_readme(root)


def previous_tag(tag, published):
    current = TAG.fullmatch(tag)
    if not current:
        fail(f'invalid tag {tag!r}')
    candidates = [(parsed(m.group(1)), name) for name in published if name != tag and (m := TAG.fullmatch(name))]
    if not candidates:
        fail('no previous published release found')
    version, name = max(candidates)
    if version >= parsed(current.group(1)):
        fail(f'published release {name} is not older than {tag}')
    return name


def previous_identity(path):
    manifest = json.loads(pathlib.Path(path).read_text())
    version, build = manifest.get('version'), manifest.get('build')
    if not isinstance(version, str) or not re.fullmatch(VERSION, version) or not isinstance(build, str) or not BUILD.fullmatch(build):
        fail('previous manifest has malformed version/build')
    return f'PREVIOUS_VERSION={version}\nPREVIOUS_BUILD={build}\n'


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest='command', required=True)
    readme = commands.add_parser('readme')
    readme.add_argument('--root', type=pathlib.Path, default=pathlib.Path('.'))
    tag = commands.add_parser('tag')
    tag.add_argument('tag')
    tag.add_argument('--root', type=pathlib.Path, default=pathlib.Path('.'))
    commands.add_parser('previous-tag').add_argument('tag')
    commands.add_parser('previous-identity').add_argument('manifest')
    args = parser.parse_args()
    if args.command == 'readme':
        check_readme(args.root)
    elif args.command == 'tag':
        check_tag(args.root, args.tag)
    elif args.command == 'previous-tag':
        print(previous_tag(args.tag, [line.strip() for line in sys.stdin if line.strip()]))
    else:
        sys.stdout.write(previous_identity(args.manifest))


if __name__ == '__main__':
    main()
