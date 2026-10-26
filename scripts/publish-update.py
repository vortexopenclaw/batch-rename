#!/usr/bin/env python3
"""Explicit publishing step. Remote calls occur only with --publish."""
import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import tempfile


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def publish(bucket, config, asset_key, asset, manifest):
    def command(action, key, path):
        return ['wrangler', 'r2', 'object', action, bucket + '/' + key,
                '--file', str(path), '--remote', '--config', str(config)]

    def read(key, path, missing_ok=False):
        result = subprocess.run(command('get', key, path), capture_output=True, text=True)
        if result.returncode:
            # Authentication, network and ambiguous failures must never authorize a put.
            if missing_ok and re.search(r'(?:\bNoSuchKey\b|The specified key does not exist)', result.stderr + result.stdout):
                return False
            raise RuntimeError('Remote read failed; publication stopped: ' + key)
        if not path.is_file():
            raise RuntimeError('Remote read produced no file: ' + key)
        return True

    with tempfile.TemporaryDirectory(prefix='batch-rename-publish-') as directory:
        remote = pathlib.Path(directory) / 'archive'
        if read(asset_key, remote, missing_ok=True):
            if digest(remote) != digest(asset):
                raise RuntimeError('Immutable release key already contains different bytes')
        else:
            subprocess.run(command('put', asset_key, asset), check=True)
        # Verify the exact object before making the manifest visible, including retries.
        remote.unlink(missing_ok=True)
        read(asset_key, remote)
        if digest(remote) != digest(asset):
            raise RuntimeError('Archive readback mismatch; manifest was not published')
        subprocess.run(command('put', 'batch-rename/manifest.json', manifest), check=True)
        remote.unlink()
        read('batch-rename/manifest.json', remote)
        if digest(remote) != digest(manifest):
            raise RuntimeError('Manifest readback mismatch; inspect publication before retrying')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('release_directory', type=pathlib.Path)
    parser.add_argument('--publish', action='store_true')
    args = parser.parse_args()
    config_path = pathlib.Path('workers/batch-rename/wrangler.json')
    bucket = json.loads(config_path.read_text())['r2_buckets'][0]['bucket_name']
    manifest = args.release_directory / 'manifest.json'
    m = json.loads(manifest.read_text())
    assert m['bundleIdentifier'] == 'com.vortexopenclaw.batch-rename'
    assert re.fullmatch(r'batch-rename/releases/[A-Za-z0-9_-]+\.zip', m['assetKey'])
    asset = args.release_directory / pathlib.PurePosixPath(m['assetKey']).name
    assert digest(asset) == m['sha256']
    assert m.get('signature'), 'Use the signed release manifest'
    assert m['downloadURL'] == json.loads(pathlib.Path('Resources/UpdateConfiguration.json').read_text())['downloadURL']
    subprocess.run(['build/verify-release', str(manifest), str(asset)], check=True)
    if args.publish:
        publish(bucket, config_path, m['assetKey'], asset, manifest)
    else:
        print('Plan: check immutable archive, upload only if missing, verify archive readback, publish and verify manifest. No remote calls made.')


if __name__ == '__main__':
    main()
