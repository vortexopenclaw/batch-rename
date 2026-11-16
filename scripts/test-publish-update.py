import importlib.util
import hashlib
import pathlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('publisher', pathlib.Path(__file__).with_name('publish-update.py'))
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)
ASSET_KEY = 'release-' + hashlib.sha256(b'archive').hexdigest() + '.zip'

class PublishTests(unittest.TestCase):
    def scenario(self, existing=None, failure=None):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            asset, manifest = root / 'a.zip', root / 'manifest.json'
            asset.write_bytes(b'archive'); manifest.write_bytes(b'manifest')
            objects = {} if existing is None else {'bucket/' + ASSET_KEY: existing}
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
                        publisher.publish('bucket', 'config', ASSET_KEY, asset, manifest)
                else:
                    publisher.publish('bucket', 'config', ASSET_KEY, asset, manifest)
            return puts, gets
    def test_concurrent_different_archive_cannot_claim_same_key(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            a, b, manifest = root / 'a.zip', root / 'b.zip', root / 'manifest.json'
            a.write_bytes(b'archive A'); b.write_bytes(b'archive B'); manifest.write_bytes(b'manifest')
            key = 'release-' + publisher.digest(a) + '.zip'
            objects, attempted_other, puts = {}, False, []
            def cli(args, **kwargs):
                nonlocal attempted_other
                action, name = args[3:5]
                path = pathlib.Path(args[args.index('--file') + 1])
                if action == 'get':
                    if name == 'bucket/' + key and not attempted_other:
                        attempted_other = True
                        # Interleave a competing publisher in the GET/PUT window.
                        # Its different content must be rejected before any remote write.
                        with self.assertRaises(RuntimeError):
                            publisher.publish('bucket', 'config', key, b, manifest)
                    if name not in objects:
                        return subprocess.CompletedProcess(args, 1, '', 'NoSuchKey')
                    path.write_bytes(objects[name])
                else:
                    puts.append(name)
                    objects[name] = path.read_bytes()
                return subprocess.CompletedProcess(args, 0, '', '')
            with patch.object(publisher.subprocess, 'run', side_effect=cli):
                publisher.publish('bucket', 'config', key, a, manifest)
            self.assertEqual(objects['bucket/' + key], b'archive A')
            self.assertEqual(puts, ['bucket/' + key, 'bucket/batch-rename/manifest.json'])

    def test_missing_legacy_key_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            a, manifest = root / 'a.zip', root / 'manifest.json'
            a.write_bytes(b'archive'); manifest.write_bytes(b'manifest')
            with patch.object(publisher.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'NoSuchKey')) as cli:
                with self.assertRaises(RuntimeError):
                    publisher.publish('bucket', 'config', 'legacy.zip', a, manifest)
                self.assertTrue(all(call.args[0][3] == 'get' for call in cli.call_args_list))

    def test_new_archive(self): self.assertEqual(self.scenario()[0], ['bucket/' + ASSET_KEY, 'bucket/batch-rename/manifest.json'])
    def test_same_bytes_retry(self): self.assertEqual(self.scenario(b'archive')[0], ['bucket/batch-rename/manifest.json'])
    def test_different_bytes_rejected(self): self.assertEqual(self.scenario(b'different')[0], [])
    def test_unknown_read_failure(self): self.assertEqual(self.scenario(failure='network')[0], [])
    def test_ambiguous_404_rejected(self): self.assertEqual(self.scenario(failure='ambiguous-404')[0], [])
    def test_upload_failure_blocks_manifest(self): self.assertEqual(self.scenario(failure='upload')[0], ['bucket/' + ASSET_KEY])
    def test_archive_readback_blocks_manifest(self): self.assertEqual(self.scenario(failure='archive-readback')[0], ['bucket/' + ASSET_KEY])
    def test_manifest_readback_failure(self): self.assertEqual(len(self.scenario(failure='manifest-readback')[0]), 2)

unittest.main()
