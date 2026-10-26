import test from 'node:test';
import assert from 'node:assert/strict';
import worker from './github-updates.mjs';
const origin = 'https://batch-rename-updates.vortexradar.workers.dev';
const env = { RELEASE_TAG: 'v0.1.1-beta' };
const manifest = { assetKey: 'batch-rename/releases/batch-rename-0_1_1-2.zip', downloadURL: origin + '/batch-rename/download', signature: 'fixture' };
test('public GitHub delivery proxies signed manifest and archive without client redirects', async () => {
 const original = globalThis.fetch;
 const calls = [];
 globalThis.fetch = async (url, options) => { calls.push([url, options]); return url.endsWith('manifest.json') ? new Response(JSON.stringify(manifest)) : new Response('zip-bytes'); };
 try {
  const response = await worker.fetch(new Request(origin + '/batch-rename/manifest.json'), env);
  assert.equal(response.status, 200); assert.deepEqual(await response.json(), manifest);
  const archive = await worker.fetch(new Request(origin + '/batch-rename/download'), env);
  assert.equal(await archive.text(), 'zip-bytes'); assert.equal(archive.headers.get('Cache-Control'), 'no-store');
  assert.ok(calls.every(([url]) => url.startsWith('https://github.com/vortexopenclaw/batch-rename/releases/download/v0.1.1-beta/')));
 } finally { globalThis.fetch = original; }
});
test('unsafe tag, route, method and asset key are rejected', async () => {
 assert.equal((await worker.fetch(new Request(origin + '/batch-rename/download'), { RELEASE_TAG: '../other' })).status, 503);
 assert.equal((await worker.fetch(new Request(origin + '/other'), env)).status, 404);
 assert.equal((await worker.fetch(new Request(origin + '/batch-rename/download', { method: 'POST' }), env)).status, 405);
 const original = globalThis.fetch;
 globalThis.fetch = async () => new Response(JSON.stringify({ ...manifest, assetKey: '../secret.zip' }));
 try { assert.equal((await worker.fetch(new Request(origin + '/batch-rename/download'), env)).status, 503); }
 finally { globalThis.fetch = original; }
});
test('upstream failures remain closed', async () => {
 const original = globalThis.fetch; globalThis.fetch = async () => new Response('missing', { status: 404 });
 try { assert.equal((await worker.fetch(new Request(origin + '/batch-rename/manifest.json'), env)).status, 503); }
 finally { globalThis.fetch = original; }
});
