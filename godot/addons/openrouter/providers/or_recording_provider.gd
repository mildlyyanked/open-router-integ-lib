class_name ORRecordingProvider
extends ORProvider
## Calls OpenRouter for real and saves each successful answer as a mock
## fixture: <config.record_dir>/<use_case>/<fixture_key>.json. Play a session
## with this, copy the files into res://tests/fixtures/llm, and the mock
## provider replays them.

var _inner: ORHttpProvider


func _ready() -> void:
	_inner = ORHttpProvider.new()
	_inner.config = config
	add_child(_inner)


func provider_name() -> String:
	return "recording"


func send(req: Dictionary) -> Dictionary:
	var res: Dictionary = await _inner.send(req)
	if bool(res["ok"]):
		var body: Dictionary = res["body"]
		var choices: Array = body.get("choices", [])
		if not choices.is_empty():
			var content := str((choices[0] as Dictionary).get("message", {}).get("content", ""))
			var parsed: Variant = ORJson.parse(ORJson.strip_fences(content))
			var dir := "%s/%s" % [config.record_dir, req.get("use_case", "unknown")]
			DirAccess.make_dir_recursive_absolute(dir)
			var f := FileAccess.open("%s/%s.json" % [dir, req.get("fixture_key", "x")], FileAccess.WRITE)
			if f:
				f.store_string(JSON.stringify({"content": parsed if parsed != null else content, "usage": body.get("usage", {}),
					"model": body.get("model", ""), "recorded": Time.get_datetime_string_from_system(true)}, "  "))
	return res
