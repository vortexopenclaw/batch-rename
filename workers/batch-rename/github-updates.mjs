// Public, read-only delivery. Release authenticity is verified by the app.
const REPOSITORY = 'vortexopenclaw/batch-rename';
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const prefix = '/batch-rename';
    if (!['GET', 'HEAD'].includes(request.method)) return new Response('Method not allowed', { status: 405 });
    if (url.search || ![`${prefix}/manifest.json`, `${prefix}/download`].includes(url.pathname)) return new Response('Not found', { status: 404 });
    if (!/^v\d+\.\d+\.\d+(?:-beta)?$/.test(env.RELEASE_TAG || '')) return new Response('No release configured', { status: 503 });
    const root = `https://github.com/${REPOSITORY}/releases/download/${env.RELEASE_TAG}/`;
    const headers = { 'User-Agent': 'Batch-Rename-Updates', 'Accept': 'application/octet-stream' };
    const latest = await fetch(root + 'manifest.json', { headers, redirect: 'follow' });
    if (!latest.ok) return new Response('Release unavailable', { status: 503 });
    const text = await latest.text();
    if (new TextEncoder().encode(text).length > 65536) return new Response('Invalid release', { status: 503 });
    let manifest;
    try { manifest = JSON.parse(text); } catch { return new Response('Invalid release', { status: 503 }); }
    const match = /^batch-rename\/releases\/(batch-rename-[A-Za-z0-9_-]+\.zip)$/.exec(manifest.assetKey || '');
    if (!match || manifest.downloadURL !== `${url.origin}${prefix}/download`) return new Response('Invalid release', { status: 503 });
    const common = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
    if (url.pathname.endsWith('/manifest.json')) return new Response(request.method === 'HEAD' ? null : text, { headers: { ...common, 'Content-Type': 'application/json' } });
    const asset = await fetch(root + match[1], { method: request.method, headers, redirect: 'follow' });
    if (!asset.ok) return new Response('Asset unavailable', { status: 503 });
    const output = { ...common, 'Content-Type': 'application/zip', 'Content-Disposition': `attachment; filename="${match[1]}"` };
    const length = asset.headers.get('Content-Length');
    if (length && /^\d+$/.test(length)) output['Content-Length'] = length;
    return new Response(request.method === 'HEAD' ? null : asset.body, { headers: output });
  }
};
