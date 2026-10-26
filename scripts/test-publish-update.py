import importlib.util
import pathlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('publisher', pathlib.Path(__file__).with_name('publish-update.py'))
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)

class PublishTests(unittest.TestCase):
    def scenario(self, existing=None, failure=None):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            asset, manifest = root / 'a.zip', root / 'manifest.json'
            asset.write_bytes(b'archive'); manifest.write_bytes(b'manifest')
            objects = {} if existing is None else {'bucket/release.zip': existing}
            puts = []
            gets = []
            def cli(args, **kwargs):
                self.assertEqual(args[:3], ['wrangler', 'r2', 'object'])
                action, key = args[3:5]
                path = pathlib.Path(args[args.index('--file') + 1])
                if action == 'get':
                    gets.append(key)
                    if failure == 'ambiguous-404': return subprocess.CompletedProcess(args, 1, '', 'HTTP 404 unknown endpoint')
                    if failure == 'network': return subprocess.CompletedProcess(args, 1, '', 'network unavailable')
                    if key not in objects: return subprocess.CompletedProcess(args, 1, '', '404 NoSuchKey')
                    data = objects[key]
                    if failure == 'archive-readback' and puts: data = b'corrupt'
                    if failure == 'manifest-readback' and key.endswith('manifest.json'): data = b'corrupt'
                    path.write_bytes(data)
                else:
                    puts.append(key)
                    if failure == 'upload': raise subprocess.CalledProcessError(1, args)
                    objects[key] = path.read_bytes()
                return subprocess.CompletedProcess(args, 0, '', '')
            with patch.object(publisher.subprocess, 'run', side_effect=cli):
                if failure or existing == b'different':
                    with self.assertRaises((RuntimeError, subprocess.CalledProcessError)):
                        publisher.publish('bucket', 'config', 'release.zip', asset, manifest)
                else:
                    publisher.publish('bucket', 'config', 'release.zip', asset, manifest)
            return puts, gets
    def test_new_archive(self): self.assertEqual(self.scenario()[0], ['bucket/release.zip', 'bucket/batch-rename/manifest.json'])
    def test_same_bytes_retry(self): self.assertEqual(self.scenario(b'archive')[0], ['bucket/batch-rename/manifest.json'])
    def test_different_bytes_rejected(self): self.assertEqual(self.scenario(b'different')[0], [])
    def test_unknown_read_failure(self): self.assertEqual(self.scenario(failure='network')[0], [])
    def test_ambiguous_404_rejected(self): self.assertEqual(self.scenario(failure='ambiguous-404')[0], [])
    def test_upload_failure_blocks_manifest(self): self.assertEqual(self.scenario(failure='upload')[0], ['bucket/release.zip'])
    def test_archive_readback_blocks_manifest(self): self.assertEqual(self.scenario(failure='archive-readback')[0], ['bucket/release.zip'])
    def test_manifest_readback_failure(self): self.assertEqual(len(self.scenario(failure='manifest-readback')[0]), 2)

unittest.main()
