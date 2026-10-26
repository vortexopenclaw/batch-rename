#!/usr/bin/env python3
"""Write public configuration only. Never loads authentication or signing material."""
import argparse, base64, json, pathlib, urllib.parse
p = argparse.ArgumentParser()
p.add_argument('--origin', required=True)
p.add_argument('--route', default='/batch-rename')
p.add_argument('--public-key', required=True, help='Base64 Ed25519 PUBLIC key (32 bytes)')
p.add_argument('--bucket', required=True, help='Dedicated Batch Rename R2 bucket name')
a = p.parse_args()
u = urllib.parse.urlsplit(a.origin)
assert u.scheme == 'https' and u.hostname and not u.username and not u.password and u.path in ('', '/') and not u.query and not u.fragment
assert len(base64.b64decode(a.public_key, validate=True)) == 32
assert a.route.startswith('/') and all(x and all(c.isalnum() or c in '-_' for c in x) for x in a.route[1:].split('/'))
assert a.bucket and all(c.isalnum() or c == '-' for c in a.bucket)
config = dict(manifestURL=a.origin.rstrip('/') + a.route + '/manifest.json', downloadURL=a.origin.rstrip('/') + a.route + '/download', publicKey=a.public_key)
pathlib.Path('Resources/UpdateConfiguration.json').write_text(json.dumps(config, indent=2) + '\n')
worker = dict(name='batch-rename-updates', main='worker.mjs', compatibility_date='2026-01-01', workers_dev=True, vars=dict(ROUTE_PREFIX=a.route), r2_buckets=[dict(binding='RELEASES', bucket_name=a.bucket)])
pathlib.Path('workers/batch-rename/wrangler.json').write_text(json.dumps(worker, indent=2) + '\n')
print('Wrote public app and Worker configuration. Nothing deployed; no credentials accessed.')
