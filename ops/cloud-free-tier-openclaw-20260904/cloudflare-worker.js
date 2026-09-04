export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/health") {
      return Response.json({ ok: true, service: "openclaw-edge", mode: "cloudflare-free-frontdoor" });
    }
    if (url.pathname === "/") {
      return Response.json({ ok: true, service: "openclaw-edge", next: "/health" });
    }
    return new Response("Not Found", { status: 404 });
  }
};
