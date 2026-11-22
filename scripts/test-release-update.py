#!/usr/bin/env python3
"""Offline release metadata regressions; only synthetic bundles are archived."""
import json
import hashlib
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name('release-update.py')
METADATA = pathlib.Path(__file__).with_name('release-metadata.py')
# Synthetic identity; deliberately not the current release so fixtures never go stale.
VERSION, BUILD, TAG = '2.3.4', '17', 'v2.3.4-beta'


class ReleaseMetadataTests(unittest.TestCase):
    def release(self, minimum, version='0.2.0', build='2'):
        with tempfile.TemporaryDirectory(dir=pathlib.Path(os.environ['TMPDIR']).resolve()) as directory:
            root = pathlib.Path(directory)
            app = root / 'Fixture.app'
            (app / 'Contents/Resources').mkdir(parents=True)
            info = dict(CFBundleIdentifier='com.vortexopenclaw.batch-rename', CFBundleShortVersionString=version, CFBundleVersion=build)
            if minimum is not None:
                info['LSMinimumSystemVersion'] = minimum
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
            (app / 'Contents/Resources/UpdateConfiguration.json').write_text(json.dumps(dict(downloadURL='https://example.invalid/download')))
            output = root / 'release'
            result = subprocess.run([sys.executable, str(SCRIPT), str(app), str(output)], capture_output=True, text=True)
            manifest = json.loads((output / 'unsigned.json').read_text()) if (output / 'unsigned.json').exists() else None
            archives = list(output.glob('*.zip'))
            if manifest is not None and result.returncode == 0:
                archive = output / pathlib.PurePosixPath(manifest['assetKey']).name
                self.assertTrue(archive.is_file())
                checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
                self.assertEqual(manifest['sha256'], checksum)
                self.assertTrue(archive.name.endswith('-' + checksum + '.zip'))
            return result, manifest, len(archives)

    def test_derives_and_normalizes_bundle_minimum(self):
        for minimum, expected in [('14.0', '14.0.0'), ('15.2', '15.2.0'), ('15.2.1', '15.2.1')]:
            with self.subTest(minimum=minimum):
                result, manifest, _ = self.release(minimum)
                self.assertEqual(result.returncode, 0, result.stderr)
                assert manifest is not None
                self.assertEqual(manifest['minimumMacOS'], expected)

    def test_rejects_missing_or_malformed_minimum_before_archiving(self):
        for minimum in [None, '', '14', '14.', '14.0.0.1', '14..0', '14.0-beta', ' 14.0', '14.0\n', '１４.０', 14, True]:
            with self.subTest(minimum=minimum):
                result, manifest, count = self.release(minimum)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(manifest)
                self.assertEqual(count, 0)

    def test_rejects_leading_zero_or_malformed_versions_before_archiving(self):
        for version in ['01.2.0', '0.02.0', '0.2.00', '00.2.0', '0.2', '0.2.0.1', '0.2.0-beta', '\uff10.2.0', '']:
            with self.subTest(version=version):
                result, manifest, count = self.release('14.0', version=version)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(manifest)
                self.assertEqual(count, 0)
        for version in ['0.2.0', '10.0.1']:
            with self.subTest(version=version):
                result, manifest, _ = self.release('14.0', version=version)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(manifest['version'], version)

    def test_rejects_non_ascii_or_leading_zero_builds(self):
        for build in ['', '02', '\u0661', '2a']:
            with self.subTest(build=build):
                result, manifest, count = self.release('14.0', build=build)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(manifest)
                self.assertEqual(count, 0)

    def test_rejects_leading_zero_minimum(self):
        result, manifest, count = self.release('14.00')
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(manifest)


class ReleaseMetadataCheckTests(unittest.TestCase):
    def checkout(self, version=VERSION, build=BUILD, readme=None, release_tag=TAG):
        directory = tempfile.TemporaryDirectory(dir=pathlib.Path(os.environ['TMPDIR']).resolve())
        self.addCleanup(directory.cleanup)
        root = pathlib.Path(directory.name)
        (root / 'Resources').mkdir()
        (root / 'Resources/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='com.vortexopenclaw.batch-rename', CFBundleShortVersionString=version, CFBundleVersion=build)))
        (root / 'README.md').write_text((readme if readme is not None else f'# Batch Rename {version} (build {build})') + '\n\nText.\n')
        (root / 'workers/batch-rename').mkdir(parents=True)
        (root / 'workers/batch-rename/wrangler-github.json').write_text(json.dumps(dict(name='batch-rename-updates', vars=dict(RELEASE_TAG=release_tag))))
        return root

    def run_check(self, *args, stdin=''):
        return subprocess.run([sys.executable, str(METADATA), *args], capture_output=True, text=True, input=stdin)

    def test_readme_title_must_match_info_plist(self):
        self.assertEqual(self.run_check('readme', '--root', str(self.checkout())).returncode, 0)
        for readme in ['# Batch Rename 2.3.3 (build 17)', '# Batch Rename 2.3.4 (build 16)', '# Batch Rename 2.3.4', 'Batch Rename 2.3.4 (build 17)']:
            with self.subTest(readme=readme):
                result = self.run_check('readme', '--root', str(self.checkout(readme=readme)))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('README', result.stderr)

    def test_tag_must_match_info_plist_readme_and_worker_release_tag(self):
        result = self.run_check('tag', TAG, '--root', str(self.checkout()))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.run_check('tag', 'v2.3.4', '--root', str(self.checkout(release_tag='v2.3.4'))).returncode, 0)
        cases = [('v2.3.5-beta', {}), ('v2.3.4-rc', {}), ('2.3.4', {}), ('v02.3.4-beta', {}),
                 (TAG, dict(release_tag='v2.3.3-beta')), (TAG, dict(release_tag='v2.3.4')),
                 (TAG, dict(readme='# Batch Rename 2.3.3 (build 17)'))]
        for tag, options in cases:
            with self.subTest(tag=tag, options=options):
                self.assertNotEqual(self.run_check('tag', tag, '--root', str(self.checkout(**options))).returncode, 0)

    def test_previous_tag_is_highest_other_published_release(self):
        published = '\n'.join(['v0.1.1-beta', 'v0.1.3-beta', 'v0.1.10', 'v0.1.2', 'nightly', 'v01.9.9', TAG]) + '\n'
        result = self.run_check('previous-tag', TAG, stdin=published)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'v0.1.10')
        self.assertNotEqual(self.run_check('previous-tag', TAG, stdin=TAG + '\nnightly\n').returncode, 0)
        self.assertNotEqual(self.run_check('previous-tag', 'v0.1.4-beta', stdin=published).returncode, 0, 'newer release already published')

    def test_previous_identity_reads_published_manifest(self):
        directory = tempfile.TemporaryDirectory(dir=pathlib.Path(os.environ['TMPDIR']).resolve())
        self.addCleanup(directory.cleanup)
        manifest = pathlib.Path(directory.name) / 'manifest.json'
        manifest.write_text(json.dumps(dict(version='0.1.3', build='4', signature='legacy-only manifests are fine')))
        result = self.run_check('previous-identity', str(manifest))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'PREVIOUS_VERSION=0.1.3\nPREVIOUS_BUILD=4\n')
        for bad in [dict(version='0.1', build='4'), dict(version='0.1.3', build='04'), dict(version='0.1.3\nX=1', build='4'), dict(version='0.1.3')]:
            with self.subTest(bad=bad):
                manifest.write_text(json.dumps(bad))
                self.assertNotEqual(self.run_check('previous-identity', str(manifest)).returncode, 0)


class LegacyDeliveryRemovedTests(unittest.TestCase):
    ROOT = pathlib.Path(__file__).resolve().parents[1]
    REMOVED = ['workers/batch-rename/worker.mjs', 'workers/batch-rename/worker.test.mjs', 'scripts/publish-update.py',
               'scripts/test-publish-update.py', 'scripts/configure-updates.py']

    def test_r2_publisher_and_trust_anchor_writer_are_gone(self):
        # configure-updates.py could overwrite the production trust anchor; publish-update.py needed an absent config.
        for path in self.REMOVED:
            self.assertFalse((self.ROOT / path).exists(), path)
        tracked = subprocess.run(['git', 'ls-files'], cwd=self.ROOT, capture_output=True, text=True, check=True).stdout.split()
        for name in tracked:
            if name == 'scripts/test-release-update.py' or not (self.ROOT / name).is_file():
                continue
            text = (self.ROOT / name).read_text(errors='ignore')
            for removed in self.REMOVED:
                self.assertNotIn(pathlib.PurePosixPath(removed).name, text, f'{name} still references {removed}')


if __name__ == '__main__':
    unittest.main()
