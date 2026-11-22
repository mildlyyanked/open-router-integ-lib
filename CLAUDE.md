# open-router-integ-lib: notes for agents

This repo is a library with two front ends that share one design:
- `godot/addons/openrouter`: GDScript classes prefixed `OR` / `OpenRouter`;
- `ts/src`: the npm package `@mildlyyanked/openrouter`.

When you change behaviour, change both sides and keep the README in step.

- **Never commit API keys.** Tests use `MockProvider` and fixtures only, with
  no network.
- **TypeScript.** Run `npm test`. It compiles `ts/` with tests into
  `ts/build` and runs `node:test`. The package has zero runtime dependencies,
  so keep it that way. It must work in Node 18+, browsers, Workers, Bun and
  Deno: only use `fetch`, `ReadableStream` and `TextDecoder` outside `node.ts`.
- **Godot.** Run:
  ```
  cd godot && godot --headless --path . -s res://tests/_runner/run_tests.gd
  ```
  Use strict typing; untyped declarations are errors. The addon must not
  reference any autoload or game class. Everything the host provides comes
  in through `ORConfig` (callables for key, provider, model, params and log).
- `tests/_runner` is vendored from android-build-lib. That repo is private
  and this one is public, so CI here can't call its actions.
- **Versioning.** Bump `package.json` `version`, then tag `vX.Y.Z`. Consumers
  install `github:mildlyyanked/open-router-integ-lib#vX.Y.Z` (TS) or re-run
  `scripts/install-godot.sh` (Godot).
- **Migrating a project that has its own copy of this pattern** (e.g. Quest
  Infinite's `services/llm_gateway.gd`): see `docs/MIGRATING.md`.
