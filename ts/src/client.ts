import type { ChatBody, ChatMessage, ChatResponse, JobResult, JsonSchema, Priority, Provider, ProviderResult, UseCaseConfig, Usage } from "./types.js";
import { HttpProvider, OPENROUTER_BASE_URL, resolveHeaders, type HttpProviderOptions } from "./providers.js";
import { buildMessages, type PromptSource, type RenderOptions } from "./prompts.js";
import { validate, wireSchema } from "./schema.js";
import { hashKey, parseJson } from "./json.js";
import { UsageTracker } from "./usage.js";
import { ModelCatalog } from "./models.js";
import { parseSSE } from "./stream.js";

export interface ClientOptions extends HttpProviderOptions, RenderOptions {
  /** Defaults to HttpProvider with the http options above. Pass a MockProvider in tests. */
  provider?: Provider;
  useCases?: Record<string, UseCaseConfig>;
  defaultModel?: string;
  defaultImageModel?: string;
  /** Player/user overrides: return a model id to use for a use case, or undefined. */
  modelFor?: (useCase: string) => string | undefined;
  prompts?: PromptSource;
  concurrency?: { foreground?: number; background?: number };
  maxTries?: number;
  maxRepairs?: number;
  backoffMs?: number;
  /** Used to choose json_schema vs json_object when a model lacks structured outputs. */
  models?: ModelCatalog;
  usage?: UsageTracker;
  log?: (msg: string) => void;
}

export interface RequestOptions<T> {
  useCase: string;
  /** Template inputs (with a PromptSource) ... */
  inputs?: Record<string, unknown>;
  /** ... or explicit messages. */
  messages?: ChatMessage[];
  /** JSON schema of the answer (defaults to the PromptSource's schema). Omit both for plain text. */
  schema?: JsonSchema;
  /** Extra checks on the parsed answer (game/app state); errors are sent back for repair. Plug zod etc. in here. */
  validate?: (data: T) => string[] | Promise<string[]>;
  /** Deterministic content used when the model can't deliver, so the app never blocks. */
  fallback?: (inputs: Record<string, unknown>) => T;
  priority?: Priority;
  model?: string;
  temperature?: number;
  maxTokens?: number;
  timeoutMs?: number;
  /** Mock fixture name. */
  fixture?: string;
  /** Force plain text even if a schema is known. */
  textOnly?: boolean;
  /** Extra OpenRouter body fields (provider routing, reasoning, plugins...). */
  extra?: Record<string, unknown>;
  signal?: AbortSignal;
}

const PRIORITY_RANK: Record<Priority, number> = { interaction: 0, dialogue: 1, foreground: 2, background: 3 };

interface Waiting {
  rank: number;
  seq: number;
  start: () => void;
}

/**
 * OpenRouter client: named use cases, prompt templates, structured output
 * with validation + repair, retries with backoff, priority queue with
 * foreground/background concurrency, fallbacks, usage accounting.
 */
export class OpenRouterClient {
  readonly provider: Provider;
  readonly usage: UsageTracker;
  readonly models?: ModelCatalog;
  private waiting: Waiting[] = [];
  private running = { fg: 0, bg: 0 };
  private seq = 0;

  constructor(readonly opts: ClientOptions = {}) {
    this.provider = opts.provider ?? new HttpProvider(opts);
    this.usage = opts.usage ?? new UsageTracker();
    this.models = opts.models;
  }

  get queued(): number {
    return this.waiting.length;
  }

  get active(): number {
    return this.running.fg + this.running.bg;
  }

  useCase(name: string): UseCaseConfig {
    return this.opts.useCases?.[name] ?? {};
  }

  modelFor(useCase: string): string {
    const uc = this.useCase(useCase);
    return this.opts.modelFor?.(useCase) || uc.model || (uc.kind === "image" ? this.opts.defaultImageModel ?? "google/gemini-2.5-flash-image" : this.opts.defaultModel ?? "openai/gpt-4o-mini");
  }

  /** Structured (schema) or plain-text call, queued by priority. Never throws for model/network failures: check result.status. */
  async request<T = unknown>(o: RequestOptions<T>): Promise<JobResult<T>> {
    const uc = this.useCase(o.useCase);
    const priority = o.priority ?? uc.priority ?? "foreground";
    await this.acquire(priority);
    try {
      return await this.run(o, uc);
    } finally {
      this.release(priority);
    }
  }

  /** Plain text answer ("" if it failed). */
  async ask(prompt: string, o: Partial<RequestOptions<string>> & { system?: string } = {}): Promise<string> {
    const messages: ChatMessage[] = [];
    if (o.system) messages.push({ role: "system", content: o.system });
    messages.push({ role: "user", content: prompt });
    const r = await this.request<string>({ useCase: "chat", ...o, messages, textOnly: true });
    return typeof r.data === "string" ? r.data : "";
  }

  /** Streams text deltas (only through HttpProvider). Not queued or repaired. */
  async *stream(o: Omit<RequestOptions<string>, "schema" | "validate" | "fallback">): AsyncGenerator<string, Usage | undefined> {
    const http = this.provider instanceof HttpProvider ? this.provider : new HttpProvider(this.opts);
    const messages = o.messages ?? this.messagesFor(o.useCase, o.inputs ?? {}, this.useCase(o.useCase));
    if (!messages) throw new Error(`no prompt for ${o.useCase}`);
    const body = { ...this.baseBody(o, this.useCase(o.useCase), messages), stream: true };
    const f = this.opts.fetch ?? globalThis.fetch;
    const res = await f(`${http.baseUrl}/chat/completions`, { method: "POST", headers: await resolveHeaders(http.opts), body: JSON.stringify(body), signal: o.signal });
    if (!res.ok || !res.body) throw new Error(`stream: HTTP ${res.status} ${await res.text().catch(() => "")}`);
    let usage: Usage | undefined;
    for await (const ev of parseSSE(res.body)) {
      if (ev === "[DONE]") break;
      const chunk = parseJson(ev) as { choices?: Array<{ delta?: { content?: string } }>; usage?: Usage; error?: { message?: string } } | undefined;
      if (chunk?.error) throw new Error(`stream: ${chunk.error.message}`);
      if (chunk?.usage) usage = chunk.usage;
      const d = chunk?.choices?.[0]?.delta?.content;
      if (d) yield d;
    }
    this.record(o.useCase, String(body.model), "text", { ok: true, code: 200, body: { usage } as Record<string, unknown>, error: "", latencyMs: 0 }, 0);
    return usage;
  }

  /** Image generation via chat completions with image output. Returns data URLs. */
  async image(useCase: string, prompt: string, o: { model?: string; signal?: AbortSignal; extra?: Record<string, unknown> } = {}): Promise<{ ok: boolean; images: string[]; error: string; cost: number }> {
    const model = o.model ?? this.modelFor(useCase);
    const body: ChatBody = { model, modalities: ["image", "text"], messages: [{ role: "user", content: prompt }], usage: { include: true }, ...(o.extra ?? {}) };
    const res = await this.provider.send({ useCase, body, timeoutMs: this.useCase(useCase).timeoutMs ?? 90_000, fixtureKey: hashKey({ useCase, prompt }), signal: o.signal });
    this.record(useCase, model, "image", res, 0);
    const msg = (res.body as ChatResponse).choices?.[0]?.message;
    const images = (msg?.images ?? []).map((i) => i.image_url.url);
    return { ok: res.ok && images.length > 0, images, error: res.ok ? (images.length ? "" : "no image in response") : res.error, cost: Number((res.body as ChatResponse).usage?.cost ?? 0) };
  }

  /** Checks the key (GET /key). */
  async testKey(): Promise<{ ok: boolean; message: string; data?: Record<string, unknown> }> {
    const f = this.opts.fetch ?? globalThis.fetch;
    const base = (this.opts.baseUrl ?? OPENROUTER_BASE_URL).replace(/\/$/, "");
    try {
      const res = await f(`${base}/key`, { headers: await resolveHeaders(this.opts) });
      const body = (await res.json().catch(() => ({}))) as { data?: Record<string, unknown> };
      return res.ok ? { ok: true, message: `Key OK ${body.data?.label ?? ""}`.trim(), data: body.data } : { ok: false, message: `HTTP ${res.status}` };
    } catch (e) {
      return { ok: false, message: (e as Error).message };
    }
  }

  // --- internals -------------------------------------------------------------

  private acquire(p: Priority): Promise<void> {
    const fg = PRIORITY_RANK[p] <= PRIORITY_RANK.foreground;
    return new Promise((resolve) => {
      this.waiting.push({ rank: PRIORITY_RANK[p], seq: this.seq++, start: () => { fg ? this.running.fg++ : this.running.bg++; resolve(); } });
      this.pump();
    });
  }

  private release(p: Priority): void {
    if (PRIORITY_RANK[p] <= PRIORITY_RANK.foreground) this.running.fg--;
    else this.running.bg--;
    this.pump();
  }

  private pump(): void {
    const fgCap = this.opts.concurrency?.foreground ?? 2;
    const bgCap = this.opts.concurrency?.background ?? 2;
    this.waiting.sort((a, b) => a.rank - b.rank || a.seq - b.seq);
    for (let i = 0; i < this.waiting.length; ) {
      const w = this.waiting[i];
      const fg = w.rank <= PRIORITY_RANK.foreground;
      if ((fg && this.running.fg < fgCap) || (!fg && this.running.bg < bgCap)) {
        this.waiting.splice(i, 1);
        w.start();
      } else i++;
    }
  }

  private messagesFor(useCase: string, inputs: Record<string, unknown>, uc: UseCaseConfig): ChatMessage[] | undefined {
    if (!this.opts.prompts) return undefined;
    return buildMessages(this.opts.prompts, useCase, uc.promptVersion ?? 1, inputs, this.opts);
  }

  private baseBody<T>(o: RequestOptions<T>, uc: UseCaseConfig, messages: ChatMessage[]): ChatBody {
    const body: ChatBody = { model: o.model ?? this.modelFor(o.useCase), messages, usage: { include: true }, ...(o.extra ?? {}) };
    const temperature = o.temperature ?? uc.temperature;
    if (temperature !== undefined) body.temperature = temperature;
    const maxTokens = o.maxTokens ?? uc.maxTokens;
    if (maxTokens) body.max_tokens = maxTokens;
    return body;
  }

  private async run<T>(o: RequestOptions<T>, uc: UseCaseConfig): Promise<JobResult<T>> {
    const inputs = o.inputs ?? {};
    const out: JobResult<T> = { status: "failed", data: undefined, raw: "", errors: [], attempts: 0, repairs: 0, model: o.model ?? this.modelFor(o.useCase), usage: {}, networkFailure: false };
    let messages = o.messages ?? this.messagesFor(o.useCase, inputs, uc);
    if (!messages) {
      out.errors.push(`no prompt template for ${o.useCase}`);
      return this.fallback(o, out, "no_prompt");
    }
    const schema = o.textOnly ? undefined : o.schema ?? (o.messages ? undefined : (this.opts.prompts?.schema?.(o.useCase) as JsonSchema | undefined));
    const textOnly = o.textOnly || !schema;
    const fixtureKey = hashKey({ useCase: o.useCase, v: uc.promptVersion ?? 1, inputs: o.messages ? { messages: o.messages } : stripPrivate(inputs) });
    const maxRepairs = this.opts.maxRepairs ?? 2;
    this.opts.log?.(`llm start ${o.useCase}`);
    for (let round = 0; round <= maxRepairs; round++) {
      const body = this.baseBody(o, uc, messages);
      if (schema) {
        body.response_format = !this.models || this.models.models.length === 0 || this.models.supportsStructured(body.model)
          ? { type: "json_schema", json_schema: { name: o.useCase, strict: true, schema: wireSchema(schema) } }
          : { type: "json_object" };
      }
      const res = await this.sendWithRetries(o, body, fixtureKey, out);
      if (!res.ok) {
        out.errors.push(res.error);
        const permanent = res.code >= 400 && res.code < 500 && ![401, 402, 403, 408, 429].includes(res.code);
        out.networkFailure = !permanent;
        return this.fallback(o, out, `http ${res.code}`);
      }
      const cr = res.body as ChatResponse;
      out.usage = cr.usage ?? {};
      const content = cr.choices?.[0]?.message?.content ?? "";
      out.raw = content;
      if (textOnly) {
        out.status = "done";
        out.data = content as T;
        return out;
      }
      const parsed = parseJson(content);
      let errors: string[] = parsed === undefined ? ["Output was not valid JSON."] : validate(parsed, schema);
      if (errors.length === 0 && o.validate) errors = await o.validate(parsed as T);
      if (errors.length === 0) {
        out.status = "done";
        out.data = parsed as T;
        out.errors = [];
        this.opts.log?.(`llm end ${o.useCase} done`);
        return out;
      }
      out.errors = errors;
      if (round < maxRepairs) {
        out.repairs++;
        messages = [...messages, { role: "assistant", content }, { role: "user", content: `Your output had these problems:\n- ${errors.join("\n- ")}\nReturn only corrected JSON matching the schema.` }];
      }
    }
    return this.fallback(o, out, "invalid");
  }

  private async sendWithRetries<T>(o: RequestOptions<T>, body: ChatBody, fixtureKey: string, out: JobResult<T>): Promise<ProviderResult> {
    const tries = this.opts.maxTries ?? 3;
    let res: ProviderResult = { ok: false, code: 0, body: {}, error: "not sent", latencyMs: 0 };
    for (let attempt = 0; attempt < tries; attempt++) {
      out.attempts++;
      res = await this.provider.send({ useCase: o.useCase, body, timeoutMs: o.timeoutMs ?? this.useCase(o.useCase).timeoutMs ?? 30_000, fixtureKey, fixture: o.fixture, signal: o.signal });
      this.record(o.useCase, body.model, "text", res, attempt);
      if (res.ok || o.signal?.aborted) return res;
      const retryable = res.code === 0 || res.code === 408 || res.code === 429 || res.code >= 500;
      if (!retryable || attempt === tries - 1) break;
      await sleep((this.opts.backoffMs ?? 1000) * 2 ** attempt);
    }
    return res;
  }

  private fallback<T>(o: RequestOptions<T>, out: JobResult<T>, reason: string): JobResult<T> {
    if (o.fallback) {
      out.data = o.fallback(o.inputs ?? {});
      out.status = "fallback";
      out.errors.push(`fallback used (${reason})`);
    } else out.status = "failed";
    this.opts.log?.(`llm end ${o.useCase} ${out.status}`);
    return out;
  }

  private record(useCase: string, model: string, kind: "text" | "image", res: ProviderResult, retries: number): void {
    const u = ((res.body as ChatResponse)?.usage ?? {}) as Usage;
    this.usage.record({
      useCase, model, kind, tokensIn: u.prompt_tokens ?? 0, tokensOut: u.completion_tokens ?? 0, cost: Number(u.cost ?? 0),
      latencyMs: res.latencyMs, status: res.ok ? "ok" : `error ${res.code}`, retries, provider: this.provider.name, time: new Date().toISOString(),
    });
  }
}

function stripPrivate(inputs: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(inputs).filter(([k]) => !k.startsWith("_")));
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
