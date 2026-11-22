import { OPENROUTER_BASE_URL, resolveHeaders, type HttpProviderOptions } from "./providers.js";

export interface ModelInfo {
  id: string;
  name?: string;
  context_length?: number;
  pricing?: { prompt?: string | number; completion?: string | number; image?: string | number };
  supported_parameters?: string[];
  architecture?: { input_modalities?: string[]; output_modalities?: string[] };
  [k: string]: unknown;
}

export interface CacheAdapter {
  get(key: string): string | null | undefined | Promise<string | null | undefined>;
  set(key: string, value: string): void | Promise<void>;
}

/** OpenRouter's model list with a TTL cache (memory by default; pass localStorage or a KV adapter). */
export class ModelCatalog {
  models: ModelInfo[] = [];
  fetchedAt = 0;
  constructor(private opts: HttpProviderOptions & { ttlMs?: number; cache?: CacheAdapter; cacheKey?: string } = {}) {}

  get stale(): boolean {
    return this.models.length === 0 || Date.now() - this.fetchedAt > (this.opts.ttlMs ?? 86_400_000);
  }

  async load(force = false): Promise<ModelInfo[]> {
    const key = this.opts.cacheKey ?? "openrouter:models";
    if (!force && this.models.length === 0 && this.opts.cache) {
      const raw = await this.opts.cache.get(key);
      if (raw) {
        try {
          const c = JSON.parse(raw) as { fetchedAt: number; data: ModelInfo[] };
          this.models = c.data;
          this.fetchedAt = c.fetchedAt;
        } catch { /* ignore a corrupt cache */ }
      }
    }
    if (!force && !this.stale) return this.models;
    const f = this.opts.fetch ?? globalThis.fetch;
    const base = (this.opts.baseUrl ?? OPENROUTER_BASE_URL).replace(/\/$/, "");
    const res = await f(`${base}/models`, { headers: await resolveHeaders(this.opts) });
    if (!res.ok) throw new Error(`models: HTTP ${res.status}`);
    const body = (await res.json()) as { data: ModelInfo[] };
    this.models = body.data ?? [];
    this.fetchedAt = Date.now();
    await this.opts.cache?.set(key, JSON.stringify({ fetchedAt: this.fetchedAt, data: this.models }));
    return this.models;
  }

  find(id: string): ModelInfo | undefined {
    return this.models.find((m) => m.id === id);
  }

  supportsStructured(id: string): boolean {
    return !!this.find(id)?.supported_parameters?.includes("structured_outputs");
  }

  /** "text" = structured outputs, "image" = image output, "any" = all. Sorted by id. */
  modelsFor(kind: "text" | "image" | "any"): ModelInfo[] {
    return this.models
      .filter((m) => kind === "any" || (kind === "image" ? !!m.architecture?.output_modalities?.includes("image") : !!m.supported_parameters?.includes("structured_outputs")))
      .sort((a, b) => a.id.localeCompare(b.id));
  }

  static priceLabel(m: ModelInfo, kind: "text" | "image" = "text"): string {
    const p = m.pricing ?? {};
    if (kind === "image" && Number(p.image ?? 0) > 0) return `$${Number(p.image).toFixed(3)}/img`;
    return `$${(Number(p.prompt ?? 0) * 1e6).toFixed(2)}/$${(Number(p.completion ?? 0) * 1e6).toFixed(2)} per 1M`;
  }
}
