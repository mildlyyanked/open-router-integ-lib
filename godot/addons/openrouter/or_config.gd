class_name ORConfig
extends RefCounted
## Everything OpenRouterClient needs from the host game. Build one at startup
## and pass it to client.configure(). Fields can be changed later (e.g. when
## the player edits Settings): the client reads them on every call.

## Shown on openrouter.ai activity pages (HTTP-Referer / X-Title headers).
var app_title: String = "Godot game"
var app_url: String = "https://github.com"

## The key. Either set api_key, or set key_source (a Callable returning it,
## e.g. SettingsService.api_key) so the key can change at runtime.
var api_key: String = ""
var key_source: Callable = Callable()

## "openrouter" (real calls), "mock" (fixtures, offline) or "recording"
## (real calls, saved as fixtures). Or set provider_source to a Callable.
var provider: String = "openrouter"
var provider_source: Callable = Callable()

## Named use cases (same shape as a use_cases.json):
##   {"npc_dialogue": {"kind": "text", "priority": "foreground", "model": "openai/gpt-4o-mini",
##     "temperature": 0.8, "max_tokens": 400, "timeout_s": 30, "prompt_version": 1}}
## Missing fields fall back to the defaults below.
var use_cases: Dictionary = {}
var default_text_model: String = "openai/gpt-4o-mini"
var default_image_model: String = "google/gemini-2.5-flash-image"
## Optional (use_case: String) -> String; a non-empty result wins over the
## use case's model (player overrides in Settings).
var model_source: Callable = Callable()
## Optional (key: String, use_case: String) -> Variant for per-use-case
## overrides of temperature / max_tokens / timeout_s (null = no override).
var param_source: Callable = Callable()

## Concurrent calls (foreground = the player is waiting).
var concurrency_foreground: int = 2
var concurrency_background: int = 2
var max_tries: int = 3          # network retries per call (429/5xx/timeouts)
var max_repairs: int = 2        # schema-repair rounds after the first answer
var backoff_base_s: float = 1.0

## Prompts: <prompts_root>/<use_case>/v<N>.md (+ schema.json next to it).
var prompts_root: String = "res://prompts"
## Global {{name}} substitutions for every template (e.g. {"tone": "grim"}).
var template_vars: Dictionary = {}
## Inputs whose key starts with this are user-typed text: wrapped in
## <untrusted_tag> and declared as data, never instructions.
var untrusted_prefix: String = "player_"
var untrusted_tag: String = "player_line"

## Mock / recording fixtures.
var fixture_roots: Array[String] = ["res://tests/fixtures/llm", "user://fixtures/llm"]
var record_dir: String = "user://fixtures/llm"

## Usage log (null path = memory only) and the model list cache.
var usage_path: String = "user://openrouter_usage.json"
var models_cache_path: String = "user://cache/openrouter_models.json"

## Optional (msg: String) -> void, for breadcrumbs (e.g. CrashGuard.crumb).
var log_sink: Callable = Callable()


func key() -> String:
	return str(key_source.call()) if key_source.is_valid() else api_key


func provider_name() -> String:
	return str(provider_source.call()) if provider_source.is_valid() else provider


func use_case(uc: String) -> Dictionary:
	return use_cases.get(uc, {})


func model_for(uc: String) -> String:
	if model_source.is_valid():
		var m := str(model_source.call(uc))
		if m != "":
			return m
	var u := use_case(uc)
	if str(u.get("model", "")) != "":
		return str(u["model"])
	return default_image_model if str(u.get("kind", "text")) == "image" else default_text_model


func param(key_name: String, uc: String, fallback: Variant) -> Variant:
	if param_source.is_valid():
		var v: Variant = param_source.call(key_name, uc)
		if v != null:
			return v
	return use_case(uc).get(key_name, fallback)


func headers() -> PackedStringArray:
	var h := PackedStringArray(["Content-Type: application/json", "HTTP-Referer: " + app_url, "X-Title: " + app_title])
	var k := key()
	if k != "":
		h.append("Authorization: Bearer " + k)
	return h


func crumb(msg: String) -> void:
	if log_sink.is_valid():
		log_sink.call(msg)
