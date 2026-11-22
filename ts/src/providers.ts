import type { Provider, ProviderRequest, ProviderResult, ChatResponse } from "./types.js";
import { parseJson } from "./json.js";

export const OPENROUTER_BASE_URL = "https://openrouter.ai/api/v1";

export interface HttpProviderOptions {
  /** OpenRouter (default) or your own proxy that speaks the same API. */
  baseUrl?: string;
  /** Sent as Bearer. Omit when calling your own proxy (it holds the key). */
  apiKey?: string | (() => string | undefined | Promise<string | undefined>);
  appTitle?: string;
  appUrl?: string;
  /** Extra headers (e.g. your proxy's session token). */
  headers?: Record<string, string> | (() => Record<string, string> | Promise<Record<string, string>>);
  fetch?: typeof fetch;
}

export async function resolveHeaders(o: HttpProviderOptions): Promise<Record<string, string>> {
  const h: Record<string, string> = { "Content-Type": "application/json" };
  if (o.appUrl) h["HTTP-Referer"] = o.appUrl;
  if (o.appTitle) h["X-Title"] = o.appTitle;
  const key = typeof o.apiKey === "function" ? await o.apiKey() : o.apiKey;
  if (key) h["Authorization"] = `Bearer ${key}`;
  const extra = typeof o.headers === "function" ? await o.headers() : o.headers;
  return { ...h, ...(extra ?? {}) };
}

/** Real calls to /chat/completions. */
export class HttpProvider implements Provider {
  readonly name = "openrouter";
  constructor(readonly opts: HttpProviderOptions = {}) {}

  get baseUrl(): string {
    return (this.opts.baseUrl ?? OPENROUTER_BASE_URL).replace(/\/$/, "");
  }

  async send(req: ProviderRequest): Promise<ProviderResult> {
    const f = this.opts.fetch ?? globalThis.fetch;
    const t0 = Date.now();
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), req.timeoutMs);
    const onAbort = () => ctl.abort();
    req.signal?.addEventListener("abort", onAbort);
    try {
      const res = await f(`${this.baseUrl}/chat/completions`, {
        method: "POST",
        headers: await resolveHeaders(this.opts),
        body: JSON.stringify(req.body),
        signal: ctl.signal,
      });
      const text = await res.text();
      const body = (parseJson(text) ?? {}) as ChatResponse;
      const latencyMs = Date.now() - t0;
      if (!res.ok) {
        return { ok: false, code: res.status, body, error: `HTTP ${res.status}: ${body.error?.message ?? text.slice(0, 200)}`, latencyMs };
      }
      if (body.error) {
        const c = Number(body.error.code ?? 502);
        return { ok: false, code: c >= 400 ? c : 502, body, error: `upstream: ${body.error.message ?? "?"}`, latencyMs };
      }
      return { ok: true, code: res.status, body, error: "", latencyMs };
    } catch (e) {
      const aborted = req.signal?.aborted;
      return { ok: false, code: 0, body: {}, error: aborted ? "aborted" : `network: ${(e as Error).message}`, latencyMs: Date.now() - t0 };
    } finally {
      clearTimeout(timer);
      req.signal?.removeEventListener("abort", onAbort);
    }
  }
}

/**
 * A fixture: { content: object|string, usage? } or { sequence: [step...] }
 * where a step may be { error_code: 429 } to script failures.
 */
export interface Fixture {
  content?: unknown;
  usage?: Record<string, number>;
  error_code?: number;
  sequence?: Fixture[];
}

export interface FixtureStore {
  load(useCase: string, key: string): unknown;
}

/**
 * Offline provider for tests and demos. Lookup order: req.fixture name,
 * fixture key, "default"; first in-memory fixtures (add()), then the store.
 */
export class MockProvider implements Provider {
  readonly name = "mock";
  readonly calls: ProviderRequest[] = [];
  private mem = new Map<string, Fixture>();
  private counters = new Map<string, number>();
  constructor(private store?: FixtureStore) {}

  add(useCase: string, fixture: Fixture, name = "default"): this {
    this.mem.set(`${useCase}/${name}`, fixture);
    return this;
  }

  reset(): void {
    this.mem.clear();
    this.counters.clear();
    this.calls.length = 0;
  }

  async send(req: ProviderRequest): Promise<ProviderResult> {
    await Promise.resolve();
    this.calls.push(req);
    const names = [req.fixture, req.fixtureKey, "default"].filter((n): n is string => !!n);
    let fx: Fixture | undefined;
    let id = "";
    for (const n of names) {
      id = `${req.useCase}/${n}`;
      fx = this.mem.get(id) ?? (this.store?.load(req.useCase, n) as Fixture | undefined);
      if (fx) break;
    }
    if (!fx) return { ok: false, code: 404, body: {}, error: `no fixture for ${req.useCase}`, latencyMs: 0 };
    let step = fx;
    if (fx.sequence) {
      const i = this.counters.get(id) ?? 0;
      this.counters.set(id, i + 1);
      step = fx.sequence[Math.min(i, fx.sequence.length - 1)];
    }
    if (step.error_code) return { ok: false, code: step.error_code, body: {}, error: `scripted HTTP ${step.error_code}`, latencyMs: 1 };
    const content = typeof step.content === "string" ? step.content : JSON.stringify(step.content ?? "");
    const body: ChatResponse = {
      model: "mock",
      choices: [{ message: { role: "assistant", content } }],
      usage: step.usage ?? { prompt_tokens: 0, completion_tokens: 0, cost: 0 },
    };
    return { ok: true, code: 200, body, error: "", latencyMs: 1 };
  }
}

/** Calls an inner provider and saves each success as a fixture for MockProvider. */
export class RecordingProvider implements Provider {
  readonly name = "recording";
  constructor(private inner: Provider, private save: (useCase: string, key: string, fixture: Fixture & Record<string, unknown>) => void | Promise<void>) {}

  async send(req: ProviderRequest): Promise<ProviderResult> {
    const res = await this.inner.send(req);
    if (res.ok) {
      const body = res.body as ChatResponse;
      const content = body.choices?.[0]?.message?.content ?? "";
      const parsed = parseJson(content);
      await this.save(req.useCase, req.fixtureKey, {
        content: parsed ?? content, usage: body.usage as Record<string, number>, model: body.model, recorded: new Date().toISOString(),
      });
    }
    return res;
  }
}
