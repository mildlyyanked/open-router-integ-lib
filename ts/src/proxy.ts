import { OPENROUTER_BASE_URL } from "./providers.js";

export interface ProxyOptions {
  /** Server-side key (e.g. process.env.OPENROUTER_API_KEY). Never sent to clients. */
  apiKey: string | (() => string | Promise<string>);
  appTitle?: string;
  appUrl?: string;
  /** Reject requests for other models (exact ids or "vendor/*"). */
  allowedModels?: string[];
  /** Clamp max_tokens. */
  maxTokens?: number;
  /** Return false (or a Response) to reject: check your session/auth here. */
  authorize?: (req: Request) => boolean | Response | Promise<boolean | Response>;
  /** Called with each non-streaming response's usage (cost accounting per user, etc.). */
  onUsage?: (req: Request, usage: Record<string, unknown>, model: string) => void | Promise<void>;
  /** CORS origin to allow ("*" or a specific origin). Omit for same-origin only. */
  corsOrigin?: string;
  upstream?: string;
  fetch?: typeof fetch;
}

/**
 * A backend endpoint that forwards OpenRouter calls with the server's key, so
 * browser/mobile clients never hold it. Web-standard (Request -> Response):
 * works in Next.js route handlers, Cloudflare Workers, Deno, Bun, Hono, and
 * Node via toNodeHandler(). Point the client at it with baseUrl.
 *
 * Routes (matched by path suffix): POST /chat/completions (streaming passes
 * through), GET /models.
 */
export function createOpenRouterProxy(o: ProxyOptions): (req: Request) => Promise<Response> {
  const upstream = (o.upstream ?? OPENROUTER_BASE_URL).replace(/\/$/, "");
  const cors: Record<string, string> = o.corsOrigin
    ? { "Access-Control-Allow-Origin": o.corsOrigin, "Access-Control-Allow-Headers": "Content-Type, Authorization", "Access-Control-Allow-Methods": "GET, POST, OPTIONS" }
    : {};
  const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...cors } });
  const modelAllowed = (m: string) => !o.allowedModels || o.allowedModels.some((a) => (a.endsWith("/*") ? m.startsWith(a.slice(0, -1)) : a === m));

  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
    if (o.authorize) {
      const ok = await o.authorize(req);
      if (ok instanceof Response) return ok;
      if (!ok) return json(401, { error: { code: 401, message: "unauthorized" } });
    }
    const f = o.fetch ?? globalThis.fetch;
    const key = typeof o.apiKey === "function" ? await o.apiKey() : o.apiKey;
    const headers: Record<string, string> = { Authorization: `Bearer ${key}`, "Content-Type": "application/json" };
    if (o.appTitle) headers["X-Title"] = o.appTitle;
    if (o.appUrl) headers["HTTP-Referer"] = o.appUrl;
    const path = new URL(req.url).pathname;

    if (req.method === "GET" && path.endsWith("/models")) {
      const r = await f(`${upstream}/models`, { headers });
      return new Response(r.body, { status: r.status, headers: { "Content-Type": "application/json", ...cors } });
    }
    if (req.method !== "POST" || !path.endsWith("/chat/completions")) return json(404, { error: { code: 404, message: "not found" } });

    let body: Record<string, unknown>;
    try {
      body = (await req.json()) as Record<string, unknown>;
    } catch {
      return json(400, { error: { code: 400, message: "invalid JSON" } });
    }
    const model = String(body.model ?? "");
    if (!modelAllowed(model)) return json(403, { error: { code: 403, message: `model not allowed: ${model}` } });
    if (o.maxTokens && (!body.max_tokens || Number(body.max_tokens) > o.maxTokens)) body.max_tokens = o.maxTokens;

    const r = await f(`${upstream}/chat/completions`, { method: "POST", headers, body: JSON.stringify(body), signal: req.signal });
    if (body.stream) {
      return new Response(r.body, { status: r.status, headers: { "Content-Type": r.headers.get("Content-Type") ?? "text/event-stream", "Cache-Control": "no-cache", ...cors } });
    }
    const text = await r.text();
    if (o.onUsage && r.ok) {
      try {
        const parsed = JSON.parse(text) as { usage?: Record<string, unknown> };
        if (parsed.usage) await o.onUsage(req, parsed.usage, model);
      } catch { /* not JSON */ }
    }
    return new Response(text, { status: r.status, headers: { "Content-Type": "application/json", ...cors } });
  };
}
