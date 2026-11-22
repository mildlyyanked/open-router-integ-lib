export type Role = "system" | "user" | "assistant" | "tool";

export interface ChatMessage {
  role: Role;
  content: string | Array<Record<string, unknown>>;
  name?: string;
}

/** Minimal JSON Schema shape (the subset structured outputs use). */
export interface JsonSchema {
  type?: string | string[];
  properties?: Record<string, JsonSchema>;
  required?: string[];
  additionalProperties?: boolean | JsonSchema;
  items?: JsonSchema;
  enum?: unknown[];
  minItems?: number;
  maxItems?: number;
  minLength?: number;
  maxLength?: number;
  minimum?: number;
  maximum?: number;
  description?: string;
  [k: string]: unknown;
}

export interface Usage {
  prompt_tokens?: number;
  completion_tokens?: number;
  total_tokens?: number;
  cost?: number;
}

/** OpenRouter chat completions request body (the fields we use; extras pass through). */
export interface ChatBody {
  model: string;
  messages: ChatMessage[];
  temperature?: number;
  max_tokens?: number;
  response_format?: Record<string, unknown>;
  stream?: boolean;
  modalities?: string[];
  usage?: { include: boolean };
  [k: string]: unknown;
}

export interface ChatResponse {
  id?: string;
  model?: string;
  choices: Array<{ message: { role: string; content: string | null; images?: Array<{ image_url: { url: string } }> }; finish_reason?: string }>;
  usage?: Usage;
  error?: { code?: number; message?: string };
}

/** What a provider returns for one HTTP attempt. */
export interface ProviderResult {
  ok: boolean;
  /** HTTP status; 0 = network failure / timeout. */
  code: number;
  body: ChatResponse | Record<string, unknown>;
  error: string;
  latencyMs: number;
}

export interface ProviderRequest {
  useCase: string;
  body: ChatBody;
  timeoutMs: number;
  /** Stable key for fixtures (mock/recording). */
  fixtureKey: string;
  /** Mock fixture override (like inputs._fixture in Godot). */
  fixture?: string;
  signal?: AbortSignal;
}

export interface Provider {
  readonly name: string;
  send(req: ProviderRequest): Promise<ProviderResult>;
}

export type Priority = "interaction" | "dialogue" | "foreground" | "background";

export interface UseCaseConfig {
  model?: string;
  kind?: "text" | "image";
  priority?: Priority;
  temperature?: number;
  maxTokens?: number;
  timeoutMs?: number;
  promptVersion?: number;
  [k: string]: unknown;
}

export interface UsageEntry {
  useCase: string;
  model: string;
  kind: "text" | "image";
  tokensIn: number;
  tokensOut: number;
  cost: number;
  latencyMs: number;
  status: string;
  retries: number;
  provider: string;
  time: string;
}

export type JobStatus = "done" | "fallback" | "failed";

export interface JobResult<T> {
  status: JobStatus;
  /** Parsed (and validated) output, the fallback's value, or undefined when failed. */
  data: T | undefined;
  raw: string;
  errors: string[];
  attempts: number;
  repairs: number;
  model: string;
  usage: Usage;
  /** True if the request ran out of network retries (auth / rate limit / offline). */
  networkFailure: boolean;
}
