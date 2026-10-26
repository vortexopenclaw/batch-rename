export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const prefix = env.ROUTE_PREFIX || '/batch-rename';
    if (!['GET', 'HEAD'].includes(request.method)) return new Response('Method not allowed', { status: 405 });
    if (url.search || ![`${prefix}/manifest.json`, `${prefix}/download`].includes(url.pathname)) return new Response('Not found', { status: 404 });
    const latest = await env.RELEASES.get('batch-rename/manifest.json');
    if (!latest) return new Response('No release', { status: 404 });
    const text = await latest.text();
    if (url.pathname.endsWith('/manifest.json')) return new Response(request.method === 'HEAD' ? null : text, { headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });
    let manifest;
    try { manifest = JSON.parse(text); } catch { return new Response('Invalid release', { status: 503 }); }
    if (!/^batch-rename\/releases\/[A-Za-z0-9_-]+\.zip$/.test(manifest.assetKey)) return new Response('Invalid asset', { status: 503 });
    const asset = await env.RELEASES.get(manifest.assetKey);
    if (!asset) return new Response('No asset', { status: 404 });
    return new Response(request.method === 'HEAD' ? null : asset.body, { headers: { 'Content-Type': 'application/zip', 'Content-Length': String(asset.size), 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' } });
  }
};
