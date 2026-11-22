# open-router-integ-lib

This repo has one OpenRouter integration with two front ends. The pattern
grew up in Quest Infinite (Godot) and our TypeScript apps.

| | Godot 4.5 | TypeScript |
|---|---|---|
| Where | `godot/addons/openrouter` | `ts/src`, used as the npm package `@mildlyyanked/openrouter` |
| Entry point | `OpenRouterClient` (Node, usually an autoload) | `OpenRouterClient` |
| Tests | `godot/tests` (headless) | `ts/test` (`node:test`) |

Both sides behave the same way:

- **Named use cases.** Each one (`npc_dialogue`, `summarize`, …) has its own
  model, temperature, max tokens, timeout, priority and prompt version.
- **Prompt templates on disk.** Each use case has
  `prompts/<use_case>/v<N>.md` and `schema.json`, and shared partials are
  pulled in with `{{shared:name}}`. Godot and TS read the same folder layout.
- **User-typed text is never put in the system prompt.** It goes in the user
  message, wrapped in tags and declared as data, which guards against prompt
  injection. Input keys with the prefix `player_` (Godot) or `user_` (TS) are
  treated this way.
- **Structured output.** Calls use `json_schema` when the model supports it
  and fall back to `json_object` otherwise. The client checks the result
  against the schema locally, then runs your own validator (for game or app
  rules). If either fails, a **repair loop** sends the errors back to the
  model, up to 2 rounds.
- **Retries** with exponential backoff on network errors and HTTP 408, 429
  and 5xx. Other 4xx errors go straight to the fallback.
- **A deterministic fallback**, so the app never blocks on the network.
- **A priority queue** with separate foreground and background concurrency
  limits. "Player is waiting" calls go first.
- **Usage and cost tracking** per session, day and all time, broken down by
  use case and model.
- **Model catalog** (`/models`, cached), with checks for structured-output
  and image-output support.
- **Mock and recording providers.** Record real answers once, then replay
  them in tests and CI without a network.
- **Images** via chat completions with `modalities: ["image","text"]`.
- **TS only:**
  - streaming (`client.stream()`);
  - a **key-holding proxy** (`createOpenRouterProxy`) so browser and mobile
    clients never see the key.
- **Godot only:**
  - `ORKeyStore`, which keeps a player-supplied key encrypted on the device;
  - stalled jobs that you can `retry()` or `give_up()`.

---

## TypeScript

Install it from GitHub. The package builds itself on install.

```bash
npm i github:mildlyyanked/open-router-integ-lib#v0.1.0
```

```ts
import { OpenRouterClient, promptsFromMap } from "@mildlyyanked/openrouter";

const ai = new OpenRouterClient({
  apiKey: process.env.OPENROUTER_API_KEY,          // server side only (or use baseUrl + proxy below)
  appTitle: "Project Sand", appUrl: "https://example.com",
  defaultModel: "openai/gpt-4o-mini",
  useCases: {
    describe_tile: { model: "google/gemini-2.5-flash", temperature: 0.8, maxTokens: 300, priority: "foreground" },
    world_event:   { priority: "background", timeoutMs: 120_000 },
  },
  prompts: promptsFromMap({
    templates: { describe_tile: "Describe the {{material}} tile in one sentence. {{shared:style}}" },
    schemas:   { describe_tile: { type: "object", required: ["text"], properties: { text: { type: "string", maxLength: 200 } } } },
    shared:    { style: "Plain words, no emoji." },
  }),
});

const r = await ai.request<{ text: string }>({
  useCase: "describe_tile",
  inputs: { material: "sand", user_note: userTypedText },   // user_* = untrusted, sent as data
  validate: (d) => (d.text.includes("lorem") ? ["No placeholder text."] : []),
  fallback: () => ({ text: "Sand, warm and shifting." }),
});
r.status;  // "done" | "fallback" | "failed"
r.data;    // typed result
```

Other entry points:
- `ai.ask("…")`: plain text.
- `for await (const d of ai.stream({...}))`: streaming.
- `ai.image(useCase, prompt)`: image generation, returning data URLs.
- `ai.testKey()`: checks the key.
- `ai.usage`: usage and cost totals.
- `new ModelCatalog({ cache: localStorage })`: the model list, cached.

On Node, `import { loadPromptsFromDir, fileFixtures, toNodeHandler } from "@mildlyyanked/openrouter/node"`
loads a `prompts/` folder from disk, which can be the same folder a Godot game
uses.

### Keep the key on your server

The proxy below works in Next.js route handlers, Workers, Bun, Deno, Hono,
or Node/Express through `toNodeHandler`.

```ts
// app/api/ai/[...path]/route.ts (Next.js)
import { createOpenRouterProxy } from "@mildlyyanked/openrouter";
const handler = createOpenRouterProxy({
  apiKey: process.env.OPENROUTER_API_KEY!,
  allowedModels: ["openai/*", "google/gemini-2.5-flash"],
  maxTokens: 2000,
  authorize: async (req) => !!(await getSession(req)),
  onUsage: async (req, usage, model) => { /* bill / rate-limit per user */ },
});
export { handler as GET, handler as POST };

// browser
const ai = new OpenRouterClient({ baseUrl: "/api/ai", useCases, prompts });
```

### Tests without a network

```ts
import { MockProvider } from "@mildlyyanked/openrouter";
const mock = new MockProvider()
  .add("describe_tile", { content: { text: "Sand." } })
  .add("describe_tile", { sequence: [{ error_code: 429 }, { content: { text: "ok" } }] }, "flaky");
const ai = new OpenRouterClient({ provider: mock, prompts, backoffMs: 1 });
await ai.request({ useCase: "describe_tile", inputs: {}, fixture: "flaky" });
```

To capture real answers as fixtures, wrap the HTTP provider in a recorder:
`new RecordingProvider(new HttpProvider({ apiKey }), fileFixtures("test/fixtures/llm").save)`.

---

## Godot

```bash
scripts/install-godot.sh /path/to/game     # copies godot/addons/openrouter
```

Add the client as an autoload with `AI="*res://addons/openrouter/openrouter_client.gd"`,
then configure it once at startup:

```gdscript
var cfg := ORConfig.new()
cfg.app_title = "My Game"
cfg.key_source = func() -> String: return ORKeyStore.read_key("my-game")   # player brings their key
cfg.provider = "openrouter"            # "mock" offline / in tests, "recording" to capture fixtures
cfg.use_cases = JSON.parse_string(FileAccess.get_file_as_string("res://config/use_cases.json"))
cfg.template_vars = {"tone": "classic"}
cfg.log_sink = CrashGuard.crumb        # optional breadcrumbs (android-build-lib)
AI.configure(cfg)
```

```gdscript
var job := AI.request("npc_dialogue", {"npc_name": npc.name, "player_line": typed},
	{"priority": ORJob.Priority.DIALOGUE,
	 "validator": func(d: Variant) -> Array: return [] if d["reply"].length() < 300 else ["Too long."],
	 "fallback": func(_i: Dictionary) -> Variant: return {"reply": npc.template_line()}})
await job.finished
say(job.result["reply"])
```

Other entry points:
- `AI.ask_text(prompt)`: plain text.
- `AI.request_messages(use_case, messages, {"schema": {...}})`: explicit
  messages instead of a template.
- `AI.request_image(use_case, prompt)`: image generation.
- `AI.test_key()`: checks the key.
- `AI.usage`: usage and cost totals (`ORUsage`).
- `AI.models`: the model list (`ORModelCatalog`).
- `AI.call_log`: the last 100 calls with their messages and raw output, for a
  debug screen.
- `job_stalled`: a signal for jobs that ran out of retries. Offer the player
  *Retry* (`AI.retry(job)`) or *Continue offline* (`AI.give_up(job)`).

Mock fixtures live in `res://tests/fixtures/llm/<use_case>/<name|fixture_key|default>.json`.
The `"recording"` provider writes them to `user://fixtures/llm` as you play.

---

## Prompt folder layout

The Godot and TS sides use the same layout:

```
prompts/
  _shared/style.md                 {{shared:style}}
  npc_dialogue/v1.md               system prompt; {{input_key}}, {{var}} placeholders
  npc_dialogue/schema.json         answer schema (strict-mode friendly: additionalProperties:false, all required)
```

Bump the prompt to `v2.md` and set `prompt_version: 2` (or `promptVersion`)
instead of editing a prompt in place. This keeps recorded fixtures valid and
lets you compare the two versions.

## Development

```bash
npm install && npm test                                       # TypeScript
cd godot && godot --headless --path . -s res://tests/_runner/run_tests.gd   # Godot
```

CI (`.github/workflows/ci.yml`) runs both on every push: Node 18 and 22, and
Godot 4.5.1. Releases are tags (`v0.1.0`, …), and consumers pin the tag they
install.
