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


if __name__ == '__main__':
    unittest.main()
