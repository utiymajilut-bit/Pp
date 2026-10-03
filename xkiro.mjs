const XKIRO_BASE = "https://api.xkiro.com/v1";

export default async (req) => {
  const key = process.env.XKIRO_API_KEY;
  if (!key) {
    return new Response(JSON.stringify({
      error: { message: "Server belum dikonfigurasi: XKIRO_API_KEY belum diatur di Netlify." }
    }), { status: 500, headers: { "Content-Type": "application/json" } });
  }

  const url = new URL(req.url);
  const path = url.pathname.replace(/^\/api\/xkiro/, "");
  const target = XKIRO_BASE + (path || "/") + (url.search || "");

  const headers = new Headers();
  headers.set("Authorization", `Bearer ${key}`);
  if (req.headers.get("content-type")) headers.set("Content-Type", req.headers.get("content-type"));
  headers.set("Accept", "application/json");

  try {
    const upstream = await fetch(target, {
      method: req.method,
      headers,
      body: req.method === "GET" || req.method === "HEAD" ? undefined : await req.arrayBuffer(),
    });

    const responseHeaders = new Headers();
    const contentType = upstream.headers.get("content-type");
    if (contentType) responseHeaders.set("Content-Type", contentType);
    responseHeaders.set("Cache-Control", "no-store");

    return new Response(upstream.body, {
      status: upstream.status,
      headers: responseHeaders,
    });
  } catch (error) {
    return new Response(JSON.stringify({
      error: { message: `Gagal menghubungi xKiro: ${error?.message || "network error"}` }
    }), { status: 502, headers: { "Content-Type": "application/json" } });
  }
};

export const config = { path: "/api/xkiro/*" };
