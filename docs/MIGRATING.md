# Migrating an existing integration

## Quest Infinite-style Godot gateway → addon

| Old (per project) | Addon |
|---|---|
| `LLMGateway` autoload (`services/llm_gateway.gd`) | `OpenRouterClient` autoload (keep the name `LLMGateway` if you like) |
| `LLMJob` | `ORJob`, with the same fields, `Priority` enum and `finished` signal |
| `OpenRouterProvider` / `MockProvider` / `RecordingProvider` | `ORHttpProvider` / `ORMockProvider` / `ORRecordingProvider` |
| `PromptLibrary` | `ORPrompts` |
| `JsonSchema.validate` | `ORSchema.validate` |
| `ModelCatalog` autoload | `AI.models` (`ORModelCatalog`) |
| `UsageTracker` autoload | `AI.usage` (`ORUsage`) |
| `SettingsService.api_key()` / `model_for()` / `per_use_case()` | `ORConfig.key_source` / `model_source` / `param_source` callables |
| `CrashGuard.crumb` in the gateway | `ORConfig.log_sink` |
| `{{tone_bible}}`, `{{style_guide}}` | `{{shared:tone_bible}}`, `{{shared:style_guide}}` (or put the text in `template_vars`) |
| `{{tone}}` | `template_vars["tone"]` |

The config wiring for Quest Infinite would look like this:

```gdscript
var cfg := ORConfig.new()
cfg.app_title = "Quest Infinite"
cfg.use_cases = SettingsService.use_cases
cfg.key_source = SettingsService.api_key
cfg.provider_source = SettingsService.provider
cfg.model_source = SettingsService.model_for
cfg.param_source = func(k: String, uc: String) -> Variant: return SettingsService.per_use_case(k, uc)
cfg.template_vars = {"tone": SettingsService.get_value("tone")}
cfg.usage_path = "user://usage.json"           # keep existing totals
cfg.models_cache_path = "user://cache/models.json"
cfg.log_sink = CrashGuard.crumb
LLMGateway.configure(cfg)
```

Notes on the parts that differ:
- **Use-case fields.** `use_cases.json` keeps working as it is. The addon
  reads `priority`, `prompt_version`, `temperature`, `max_tokens`,
  `timeout_s` and `model`.
- **Fixture keys** hash the same inputs (`use_case`, `prompt_version`, and
  the inputs without `_` keys) the same way, so recorded fixtures stay valid.
- **Errors.** HTTP 402 (out of credits) now stalls the job like 401 and 403,
  instead of falling back. OpenRouter's "200 with an error object" is
  treated as a retryable upstream failure.

## A TypeScript app with its own fetch wrapper

1. Replace the hand-rolled `fetch("https://openrouter.ai/api/v1/chat/completions")`
   calls with `ai.request({ useCase, messages, schema })`, or with
   `ai.ask()` for plain text.
2. Move system prompts into `promptsFromMap({...})`, or into a `prompts/`
   folder read with `loadPromptsFromDir`, and pass `inputs`.
3. Replace ad-hoc `JSON.parse` + try/catch with a `schema`, plus `validate`
   for app rules. To use zod, pass
   `validate: (d) => { const r = S.safeParse(d); return r.success ? [] : r.error.issues.map(i => i.path.join(".") + ": " + i.message) }`.
4. If the key is in the browser today, move it into
   `createOpenRouterProxy` on the server and point the client at it with
   `baseUrl`.
