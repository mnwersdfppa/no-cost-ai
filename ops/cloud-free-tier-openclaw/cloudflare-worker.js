export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === '/health') return new Response('ok');
    const primary = env.ORACLE_OPENCLAW_URL;
    const fallback = env.SUPABASE_CONTINUITY_URL;
    const target = primary || fallback;
    if (!target) return new Response('no upstream', { status: 503 });
    const upstream = new URL(url.pathname + url.search, target);
    const headers = new Headers(request.headers);
    headers.set('x-openclaw-edge', 'cloudflare');
    try {
      const r = await fetch(upstream, { method: request.method, headers, body: ['GET','HEAD'].includes(request.method) ? undefined : request.body, redirect: 'manual' });
      if (r.ok || !fallback || target === fallback) return r;
    } catch (_) {}
    const fb = new URL(url.pathname + url.search, fallback);
    return fetch(fb, { method: request.method, headers, body: ['GET','HEAD'].includes(request.method) ? undefined : request.body, redirect: 'manual' });
  }
};
