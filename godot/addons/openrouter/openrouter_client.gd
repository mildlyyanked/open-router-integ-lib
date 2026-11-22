class_name OpenRouterClient
extends Node
## Every model call goes through here. Add it as an autoload (e.g. "AI") or
## a child node, then configure() it once with an ORConfig.
##
##   var job := AI.request("npc_dialogue", {"npc": npc.name, "player_line": text},
##       {"fallback": func(_i: Dictionary) -> Variant: return {"reply": "Hm."}})
##   await job.finished
##   show(job.result["reply"])
##
## What you get:
## - named use cases with per-case model / temperature / max tokens / timeout
## - prompt templates + JSON schema per use case (ORPrompts)
## - priority queue with separate foreground/background concurrency
## - retries with exponential backoff on 0/408/429/5xx
## - structured outputs (json_schema when the model supports it), local
##   schema validation + your own validator, and a repair loop that feeds the
##   errors back to the model
## - a deterministic fallback so play never blocks on the network
## - stalled jobs (out of retries) you can retry() or give_up()
## - usage/cost accounting (ORUsage), model catalog (ORModelCatalog), call log
## - mock / recording providers for offline tests and fixtures

signal queue_changed(queued: int, running: int)
signal job_finished(job: ORJob)
signal job_stalled(job: ORJob)

const LOG_CAP := 100

var config: ORConfig = ORConfig.new()
var prompts: ORPrompts
var usage: ORUsage
var models: ORModelCatalog
var call_log: Array[Dictionary] = []
## Tests: force a provider regardless of config.
var provider_override: ORProvider = null

var _queue: Array[ORJob] = []
var _running: Array[ORJob] = []
var _stalled: Array[ORJob] = []
var _providers: Dictionary = {}
var _seq: int = 0


func _init() -> void:
	prompts = ORPrompts.new(config)
	usage = ORUsage.new("")


func _ready() -> void:
	if _providers.is_empty():
		configure(config)


## (Re)binds the config. Safe to call again; queued jobs are kept.
func configure(cfg: ORConfig) -> void:
	config = cfg
	prompts = ORPrompts.new(cfg)
	usage = ORUsage.new(cfg.usage_path)
	for p: Node in _providers.values():
		p.queue_free()
	_providers.clear()
	for p: ORProvider in [ORHttpProvider.new(), ORMockProvider.new(), ORRecordingProvider.new()]:
		p.config = cfg
		add_child(p)
		_providers[p.provider_name()] = p
	if models != null:
		models.queue_free()
	models = ORModelCatalog.new()
	models.config = cfg
	add_child(models)


func provider() -> ORProvider:
	if provider_override != null:
		return provider_override
	return _providers.get(config.provider_name(), _providers["openrouter"])


## The built-in mock provider (to register fixtures in tests).
func mock() -> ORMockProvider:
	return _providers["mock"]


func queued_count() -> int:
	return _queue.size()


func running_count() -> int:
	return _running.size()


func jobs_snapshot() -> Array[ORJob]:
	var out: Array[ORJob] = []
	out.append_array(_running)
	out.append_array(_stalled)
	out.append_array(_queue)
	return out


## Queues a templated call for a named use case.
## opts: priority (ORJob.Priority), validator, fallback, model (override).
func request(use_case: String, inputs: Dictionary, opts: Dictionary = {}) -> ORJob:
	var job := _new_job(use_case, inputs, opts)
	return _enqueue(job)


## Queues a call with explicit messages (no template). Pass opts.schema for
## JSON output, or opts.text_only = true for plain text (result is a String).
func request_messages(use_case: String, messages: Array, opts: Dictionary = {}) -> ORJob:
	var job := _new_job(use_case, {}, opts)
	job.messages = messages.duplicate(true)
	job.schema = opts.get("schema", {})
	job.text_only = bool(opts.get("text_only", job.schema.is_empty()))
	return _enqueue(job)


## Convenience: one plain-text answer, awaited. Returns "" on failure.
func ask_text(prompt: String, system: String = "", use_case: String = "chat") -> String:
	var msgs: Array = []
	if system != "":
		msgs.append({"role": "system", "content": system})
	msgs.append({"role": "user", "content": prompt})
	var job := request_messages(use_case, msgs, {"text_only": true})
	await job.finished
	return str(job.result) if job.ok() and job.result != null else ""


func _new_job(use_case: String, inputs: Dictionary, opts: Dictionary) -> ORJob:
	var uc := config.use_case(use_case)
	var job := ORJob.new()
	_seq += 1
	job.id = "job_%d" % _seq
	job.use_case = use_case
	job.inputs = inputs.duplicate(true)
	var default_prio := ORJob.Priority.BACKGROUND if str(uc.get("priority", "foreground")) == "background" else ORJob.Priority.FOREGROUND
	job.priority = int(opts.get("priority", default_prio))
	job.prompt_version = int(uc.get("prompt_version", 1))
	job.validator = opts.get("validator", Callable())
	job.fallback = opts.get("fallback", Callable())
	job.model = str(opts.get("model", ""))
	job.created_ms = Time.get_ticks_msec()
	return job


func _enqueue(job: ORJob) -> ORJob:
	_queue.append(job)
	_pump.call_deferred()
	queue_changed.emit(_queue.size(), _running.size())
	return job


## Re-runs a job that ran out of network retries.
func retry(job: ORJob) -> void:
	if _stalled.has(job):
		_stalled.erase(job)
		job.status = "queued"
		job.attempts = 0
		_queue.push_front(job)
		_pump.call_deferred()


## Gives up on a stalled job and uses its fallback.
func give_up(job: ORJob) -> void:
	if _stalled.has(job):
		_stalled.erase(job)
		_finish_with_fallback(job, "network")


## Unfinished jobs, for saving and re-issuing after a load.
func pending_descriptors() -> Array:
	var out: Array = []
	for j: ORJob in jobs_snapshot():
		if not j.is_done():
			out.append(j.descriptor())
	return out


func _pump() -> void:
	_queue.sort_custom(func(a: ORJob, b: ORJob) -> bool:
		if a.priority != b.priority:
			return a.priority < b.priority
		return a.created_ms < b.created_ms)
	var i := 0
	while i < _queue.size():
		var job := _queue[i]
		var fg_running := _running.filter(func(j: ORJob) -> bool: return j.is_foreground()).size()
		var bg_running := _running.size() - fg_running
		var can := (job.is_foreground() and fg_running < config.concurrency_foreground) or (not job.is_foreground() and bg_running < config.concurrency_background)
		if can:
			_queue.remove_at(i)
			_running.append(job)
			_run(job)
		else:
			i += 1
	queue_changed.emit(_queue.size(), _running.size())


func _run(job: ORJob) -> void:
	job.status = "running"
	config.crumb("llm start %s %s" % [job.id, job.use_case])
	job.started_ms = Time.get_ticks_msec()
	if job.model == "":
		job.model = config.model_for(job.use_case)
	var schema := job.schema
	var messages: Array = job.messages
	if messages.is_empty():
		if not prompts.has_prompt(job.use_case, job.prompt_version):
			job.errors.append("no prompt template for %s v%d" % [job.use_case, job.prompt_version])
			_finish_with_fallback(job, "no_prompt")
			return
		schema = prompts.schema(job.use_case)
		messages = prompts.build_messages(job.use_case, job.prompt_version, job.inputs)
	for repair_round in config.max_repairs + 1:
		var body := build_body(job, messages, schema)
		var res: Dictionary = await _send_with_retries(job, body)
		if not bool(res["ok"]):
			job.errors.append(str(res["error"]))
			var code := int(res["code"])
			_log(job, messages, res, null, [str(res["error"])])
			# Permanent client errors (bad request, model not found...) go
			# straight to the fallback; auth/rate/timeouts stall for a retry.
			if code >= 400 and code < 500 and code not in [401, 402, 403, 408, 429] and job.fallback.is_valid():
				_finish_with_fallback(job, "http %d" % code)
				return
			job.status = "needs_retry"
			_running.erase(job)
			_stalled.append(job)
			job_stalled.emit(job)
			_pump.call_deferred()
			return
		var content := extract_content(res["body"])
		job.raw = content
		if job.text_only:
			_log(job, messages, res, content, [])
			job.result = content
			_complete(job, "done")
			return
		var parsed: Variant = ORJson.parse(ORJson.strip_fences(content))
		var errors: Array[String] = []
		if parsed == null:
			errors.append("Output was not valid JSON.")
		else:
			errors = ORSchema.validate(parsed, schema)
			if errors.is_empty() and job.validator.is_valid():
				for e: Variant in job.validator.call(parsed):
					errors.append(str(e))
		_log(job, messages, res, parsed, errors)
		if errors.is_empty():
			job.result = parsed
			_complete(job, "done")
			return
		job.errors = errors
		if repair_round < config.max_repairs:
			job.repairs += 1
			messages = messages.duplicate()
			messages.append({"role": "assistant", "content": content})
			messages.append({"role": "user", "content": "Your output had these problems:\n- " + "\n- ".join(PackedStringArray(errors)) + "\nReturn only corrected JSON matching the schema."})
	_finish_with_fallback(job, "invalid")


func build_body(job: ORJob, messages: Array, schema: Dictionary) -> Dictionary:
	var body := {
		"model": job.model,
		"messages": messages,
		"temperature": float(config.param("temperature", job.use_case, 0.7)),
		"usage": {"include": true},
	}
	var max_tokens := int(config.param("max_tokens", job.use_case, 0))
	if max_tokens > 0:
		body["max_tokens"] = max_tokens
	if not job.text_only and not schema.is_empty():
		if models.models.is_empty() or models.supports_structured(job.model):
			body["response_format"] = {"type": "json_schema", "json_schema": {"name": job.use_case, "strict": true, "schema": ORSchema.wire(schema)}}
		else:
			body["response_format"] = {"type": "json_object"}
	elif not job.text_only:
		body["response_format"] = {"type": "json_object"}
	return body


func _send_with_retries(job: ORJob, body: Dictionary) -> Dictionary:
	var res: Dictionary = {}
	for attempt in config.max_tries:
		job.attempts += 1
		var req := {
			"use_case": job.use_case, "inputs": job.inputs, "body": body,
			"timeout_s": int(config.param("timeout_s", job.use_case, 30)),
			"fixture_key": ORPrompts.fixture_key(job.use_case, job.prompt_version, job.inputs if job.messages.is_empty() else {"messages": job.messages}),
		}
		res = await provider().send(req)
		_record_usage(job, res, attempt)
		if bool(res["ok"]):
			return res
		var code := int(res["code"])
		var retryable := code == 0 or code == 408 or code == 429 or code >= 500
		if not retryable or attempt == config.max_tries - 1:
			break
		await get_tree().create_timer(config.backoff_base_s * pow(2.0, attempt)).timeout
	return res


func _record_usage(job: ORJob, res: Dictionary, retries: int) -> void:
	var body: Dictionary = res.get("body", {})
	var u: Dictionary = body.get("usage", {}) if body.get("usage") is Dictionary else {}
	usage.record({
		"use_case": job.use_case, "model": job.model, "kind": "text",
		"tokens_in": int(u.get("prompt_tokens", 0)), "tokens_out": int(u.get("completion_tokens", 0)),
		"cost": float(u.get("cost", 0.0)), "latency_ms": int(res.get("latency_ms", 0)),
		"status": "ok" if bool(res["ok"]) else "error %d" % int(res["code"]), "retries": retries,
		"provider": provider().provider_name(),
	})


static func extract_content(body: Dictionary) -> String:
	var choices: Array = body.get("choices", [])
	if choices.is_empty():
		return ""
	var msg: Dictionary = (choices[0] as Dictionary).get("message", {})
	return str(msg.get("content", ""))


func _finish_with_fallback(job: ORJob, reason: String) -> void:
	if job.fallback.is_valid():
		job.result = job.fallback.call(job.inputs)
		job.errors.append("fallback used (%s)" % reason)
		_complete(job, "fallback")
	else:
		_complete(job, "failed")


func _complete(job: ORJob, status: String) -> void:
	job.status = status
	config.crumb("llm end %s %s" % [job.id, status])
	job.ended_ms = Time.get_ticks_msec()
	_running.erase(job)
	job.finished.emit(job)
	job_finished.emit(job)
	_pump.call_deferred()


func _log(job: ORJob, messages: Array, res: Dictionary, parsed: Variant, errors: Array[String]) -> void:
	call_log.append({
		"job": job.id, "use_case": job.use_case, "model": job.model, "provider": provider().provider_name(),
		"time": Time.get_datetime_string_from_system(true), "messages": messages.duplicate(true),
		"raw": job.raw, "parsed": parsed, "errors": errors.duplicate(), "attempts": job.attempts,
		"repairs": job.repairs, "http": int(res.get("code", 0)),
	})
	while call_log.size() > LOG_CAP:
		call_log.pop_front()


## Checks the key against /key (Settings → "Test key"). {ok, message, data}
func test_key() -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = 20
	add_child(http)
	var err := http.request(ORHttpProvider.BASE_URL + "/key", config.headers())
	if err != OK:
		http.queue_free()
		return {"ok": false, "message": "Request error %d" % err, "data": {}}
	var res: Array = await http.request_completed
	http.queue_free()
	var code := int(res[1])
	var bytes: PackedByteArray = res[3]
	var parsed: Variant = ORJson.parse(bytes.get_string_from_utf8())
	var data: Dictionary = (parsed as Dictionary).get("data", {}) if parsed is Dictionary else {}
	if code == 200:
		return {"ok": true, "message": "Key OK %s" % str(data.get("label", "")), "data": data}
	return {"ok": false, "message": "HTTP %d" % code, "data": data}


## Image generation through chat completions with image output. Returns
## {ok, image (Image or null), error, cost}. The mock provider returns a
## flat placeholder.
func request_image(use_case: String, prompt: String) -> Dictionary:
	var model := config.model_for(use_case)
	var t0 := Time.get_ticks_msec()
	if config.provider_name() == "mock":
		await get_tree().process_frame
		var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
		img.fill(Color.from_hsv(float(absi(prompt.hash()) % 360) / 360.0, 0.4, 0.8))
		return {"ok": true, "image": img, "error": "", "cost": 0.0}
	var body := {"model": model, "modalities": ["image", "text"], "messages": [{"role": "user", "content": prompt}], "usage": {"include": true}}
	var res: Dictionary = await (_providers["openrouter"] as ORProvider).send({"use_case": use_case, "body": body,
		"timeout_s": int(config.param("timeout_s", use_case, 90))})
	var out := {"ok": false, "image": null, "error": str(res.get("error", "")), "cost": 0.0}
	var rb: Dictionary = res.get("body", {})
	var u: Dictionary = rb.get("usage", {}) if rb.get("usage") is Dictionary else {}
	out["cost"] = float(u.get("cost", 0.0))
	if bool(res["ok"]):
		var img2 := decode_image(rb)
		out["ok"] = img2 != null
		out["image"] = img2
		if img2 == null:
			out["error"] = "no image in response"
	usage.record({"use_case": use_case, "model": model, "kind": "image", "cost": out["cost"],
		"latency_ms": Time.get_ticks_msec() - t0, "status": "ok" if bool(out["ok"]) else "error", "provider": "openrouter"})
	return out


## Pulls the first data-URL image out of a chat completion.
static func decode_image(body: Dictionary) -> Image:
	var choices: Array = body.get("choices", [])
	if choices.is_empty():
		return null
	var msg: Dictionary = (choices[0] as Dictionary).get("message", {})
	for im: Variant in msg.get("images", []):
		if not (im is Dictionary):
			continue
		var url := str(((im as Dictionary).get("image_url", {}) as Dictionary).get("url", ""))
		var comma := url.find(",")
		if not url.begins_with("data:image/") or comma < 0:
			continue
		var bytes := Marshalls.base64_to_raw(url.substr(comma + 1))
		var img := Image.new()
		var err := img.load_png_from_buffer(bytes) if url.begins_with("data:image/png") else img.load_jpg_from_buffer(bytes)
		if err != OK:
			err = img.load_webp_from_buffer(bytes)
		if err == OK:
			return img
	return null
