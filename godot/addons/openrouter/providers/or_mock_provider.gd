class_name ORMockProvider
extends ORProvider
## Replays fixtures so everything runs without a network (tests, CI, offline
## play). Lookup, in each of config.fixture_roots:
##   <use_case>/<inputs._fixture>.json, then <use_case>/<fixture_key>.json,
##   then <use_case>/default.json.
## A fixture is {"content": <object|string>, "usage": {...}} or
## {"sequence": [step, ...]} where a step may be {"error_code": 429} to script
## failures (each call advances one step; the last one repeats).
## Tests can also register fixtures in memory with add().

var _counters: Dictionary = {}
var _memory: Dictionary = {}   # "use_case/name" -> fixture
var calls: Array[Dictionary] = []


func provider_name() -> String:
	return "mock"


## Registers an in-memory fixture (name "default" matches any call).
func add(use_case: String, fixture: Dictionary, fixture_name: String = "default") -> void:
	_memory["%s/%s" % [use_case, fixture_name]] = fixture


func reset() -> void:
	_counters.clear()
	_memory.clear()
	calls.clear()


func send(req: Dictionary) -> Dictionary:
	await get_tree().process_frame
	calls.append(req)
	var uc := str(req.get("use_case", ""))
	var inputs: Dictionary = req.get("inputs", {})
	var names: Array[String] = []
	if inputs.has("_fixture"):
		names.append(str(inputs["_fixture"]))
	names.append(str(req.get("fixture_key", "")))
	names.append("default")
	var fixture: Dictionary = {}
	var fixture_id := ""
	for n: String in names:
		var mk := "%s/%s" % [uc, n]
		if _memory.has(mk):
			fixture = _memory[mk]
			fixture_id = "mem:" + mk
			break
		for root: String in config.fixture_roots:
			var path := "%s/%s/%s.json" % [root, uc, n]
			var v: Variant = ORJson.load_file(path)
			if v is Dictionary:
				fixture = v
				fixture_id = path
				break
		if not fixture.is_empty():
			break
	if fixture.is_empty():
		return {"ok": false, "code": 404, "body": {}, "error": "no fixture for %s" % uc, "latency_ms": 0}
	var step := fixture
	if fixture.has("sequence"):
		var seq: Array = fixture["sequence"]
		var idx: int = int(_counters.get(fixture_id, 0))
		_counters[fixture_id] = idx + 1
		step = seq[mini(idx, seq.size() - 1)]
	if step.has("error_code"):
		return {"ok": false, "code": int(step["error_code"]), "body": {}, "error": "scripted HTTP %d" % int(step["error_code"]), "latency_ms": 1}
	var content: Variant = step.get("content", "")
	var content_text: String = content if content is String else JSON.stringify(content)
	var usage: Dictionary = step.get("usage", {"prompt_tokens": 0, "completion_tokens": 0, "cost": 0.0})
	var body := {"choices": [{"message": {"role": "assistant", "content": content_text}}], "usage": usage, "model": "mock"}
	return {"ok": true, "code": 200, "body": body, "error": "", "latency_ms": 1}
