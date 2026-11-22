import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker from './github-updates.mjs';
// Synthetic release identity, independent of whichever release is current.
const RELEASE_TAG = 'v2.3.4-beta';
const ASSET = 'batch-rename-2_3_4-17-' + 'a'.repeat(64) + '.zip';
const origin = 'https://batch-rename-updates.vortexradar.workers.dev';
const env = { RELEASE_TAG };
const manifest = { assetKey: 'batch-rename/releases/' + ASSET, downloadURL: origin + '/batch-rename/download', signature: 'fixture', envelope: { payload: 'fixture', signature: 'fixture' } };
test('malformed metadata is rejected on both routes without archive access', async () => {
 const original = globalThis.fetch;
 try {
  for (const text of ['{broken', 'null', '[]', 'true', '42', '"release"', '{}', JSON.stringify({ ...manifest, assetKey: [manifest.assetKey] }), JSON.stringify({ ...manifest, downloadURL: null })]) {
   for (const route of ['manifest.json', 'download']) for (const method of ['GET', 'HEAD']) {
    const calls = [];
    globalThis.fetch = async url => { calls.push(url); return new Response(text); };
    const response = await worker.fetch(new Request(origin + '/batch-rename/' + route, { method }), env);
    assert.equal(response.status, 503, `${method} ${route}: ${text}`);
    assert.equal(calls.length, 1);
   }
  }
 } finally { globalThis.fetch = original; }
});
test('public GitHub delivery proxies signed manifest and archive without client redirects', async () => {
 const original = globalThis.fetch;
 const calls = [];
 globalThis.fetch = async (url, options) => { calls.push([url, options]); return url.endsWith('manifest.json') ? new Response(JSON.stringify(manifest)) : new Response('zip-bytes'); };
 try {
  const response = await worker.fetch(new Request(origin + '/batch-rename/manifest.json'), env);
  assert.equal(response.status, 200); assert.deepEqual(await response.json(), manifest);
  const archive = await worker.fetch(new Request(origin + '/batch-rename/download'), env);
  assert.equal(await archive.text(), 'zip-bytes'); assert.equal(archive.headers.get('Cache-Control'), 'no-store');
  assert.ok(calls.every(([url]) => url.startsWith(`https://github.com/vortexopenclaw/batch-rename/releases/download/${RELEASE_TAG}/`)));
  assert.ok(calls.at(-1)[0].endsWith('/' + ASSET));
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
test('pinned production RELEASE_TAG is a tag the Worker serves', async () => {
 const pinned = JSON.parse(readFileSync(new URL('./wrangler-github.json', import.meta.url), 'utf8')).vars.RELEASE_TAG;
 const original = globalThis.fetch; const calls = [];
 globalThis.fetch = async url => { calls.push(url); return new Response(JSON.stringify(manifest)); };
 try {
  assert.equal((await worker.fetch(new Request(origin + '/batch-rename/manifest.json'), { RELEASE_TAG: pinned })).status, 200);
  assert.deepEqual(calls, [`https://github.com/vortexopenclaw/batch-rename/releases/download/${pinned}/manifest.json`]);
 } finally { globalThis.fetch = original; }
});
