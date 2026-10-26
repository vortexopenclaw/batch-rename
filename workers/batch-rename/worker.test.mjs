import { test } from 'node:test';
import assert from 'node:assert/strict';
import worker from './worker.mjs';
const manifest = JSON.stringify({ assetKey: 'batch-rename/releases/test.zip' });
const env = { ROUTE_PREFIX: '/batch-rename', RELEASES: { async get(key) { return key === 'batch-rename/manifest.json' ? { text: async () => manifest } : key === 'batch-rename/releases/test.zip' ? { body: 'zip', size: 3 } : null; } } };
test('serves only scoped manifest and archive', async () => {
  for (const [path, status] of [['/batch-rename/manifest.json',200], ['/batch-rename/download',200], ['/offloader/download',404], ['/batch-rename/download?key=secret',404]]) {
    const result = await worker.fetch(new Request('https://example.invalid'+path), env); assert.equal(result.status,status);
  }
  assert.equal((await worker.fetch(new Request('https://example.invalid/batch-rename/download', {method:'POST'}),env)).status,405);
});
test('missing and unsafe release keys fail closed', async () => {
  assert.equal((await worker.fetch(new Request('https://example.invalid/batch-rename/download'), { RELEASES:{get:async()=>null} })).status,404);
  const bad = { RELEASES: {get:async()=>({text:async()=>JSON.stringify({assetKey:'other/secret'})})} };
  assert.equal((await worker.fetch(new Request('https://example.invalid/batch-rename/download'),bad)).status,503);
});
test('HEAD returns headers without bodies and downloads are never cached', async () => {
  for (const path of ['/batch-rename/manifest.json', '/batch-rename/download']) {
    const response = await worker.fetch(new Request('https://example.invalid' + path, { method: 'HEAD' }), env);
    assert.equal(response.status, 200);
    assert.equal(await response.text(), '');
    assert.equal(response.headers.get('Cache-Control'), 'no-store');
  }
});
test('invalid manifest and missing archive cannot serve another object', async () => {
  const calls = [];
  const missing = { RELEASES: { async get(key) {
    calls.push(key);
    return key === 'batch-rename/manifest.json' ? { text: async () => manifest } : null;
  } } };
  assert.equal((await worker.fetch(new Request('https://example.invalid/batch-rename/download'), missing)).status, 404);
  assert.deepEqual(calls, ['batch-rename/manifest.json', 'batch-rename/releases/test.zip']);
  const invalid = { RELEASES: { get: async () => ({ text: async () => '{broken' }) } };
  assert.equal((await worker.fetch(new Request('https://example.invalid/batch-rename/download'), invalid)).status, 503);
});
