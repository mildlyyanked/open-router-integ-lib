class_name ORUsage
extends RefCounted
## Spend tracking: per-call log (last LOG_CAP), totals for this session /
## each day / all time, split by use case and model. Persisted to
## config.usage_path (empty = memory only).

signal recorded(entry: Dictionary)

const LOG_CAP := 500

var calls: Array[Dictionary] = []
var all_time: Dictionary = {}
var by_day: Dictionary = {}
var session: Dictionary = {}
var path: String = ""
var _session_start_ms: int = 0


func _init(save_path: String = "") -> void:
	path = save_path
	_session_start_ms = Time.get_ticks_msec()
	session = empty_totals()
	all_time = empty_totals()
	var d: Variant = ORJson.load_file(path) if path != "" else null
	if d is Dictionary:
		var dd: Dictionary = d
		all_time = dd.get("all_time", empty_totals())
		by_day = dd.get("by_day", {})
		for c: Dictionary in dd.get("calls", []):
			calls.append(c)


static func empty_totals() -> Dictionary:
	return {"calls": 0, "cost": 0.0, "tokens_in": 0, "tokens_out": 0, "text_calls": 0, "image_calls": 0,
		"errors": 0, "by_use_case": {}, "by_model": {}}


## entry: {use_case, model, kind (text|image), tokens_in, tokens_out, cost, latency_ms, status, retries, provider}
func record(entry: Dictionary) -> void:
	var e := entry.duplicate()
	e["time"] = Time.get_datetime_string_from_system(true)
	e["session_ms"] = Time.get_ticks_msec() - _session_start_ms
	calls.append(e)
	while calls.size() > LOG_CAP:
		calls.pop_front()
	var day := Time.get_date_string_from_system(true)
	if not by_day.has(day):
		by_day[day] = empty_totals()
	for totals: Dictionary in [session, all_time, by_day[day]]:
		_add(totals, e)
	save()
	recorded.emit(e)


func _add(t: Dictionary, e: Dictionary) -> void:
	var cost := float(e.get("cost", 0.0))
	t["calls"] = int(t["calls"]) + 1
	t["cost"] = float(t["cost"]) + cost
	t["tokens_in"] = int(t["tokens_in"]) + int(e.get("tokens_in", 0))
	t["tokens_out"] = int(t["tokens_out"]) + int(e.get("tokens_out", 0))
	var kind_key := "image_calls" if str(e.get("kind", "text")) == "image" else "text_calls"
	t[kind_key] = int(t[kind_key]) + 1
	if str(e.get("status", "ok")) != "ok":
		t["errors"] = int(t["errors"]) + 1
	for group: String in ["by_use_case", "by_model"]:
		var k := str(e.get("use_case" if group == "by_use_case" else "model", "?"))
		var g: Dictionary = t[group]
		var row: Dictionary = g.get(k, {"calls": 0, "cost": 0.0})
		row["calls"] = int(row["calls"]) + 1
		row["cost"] = float(row["cost"]) + cost
		g[k] = row


func today() -> Dictionary:
	return by_day.get(Time.get_date_string_from_system(true), empty_totals())


func calls_per_minute() -> float:
	var now := Time.get_ticks_msec() - _session_start_ms
	var n := 0
	for c: Dictionary in calls:
		if c.has("session_ms") and now - int(c["session_ms"]) <= 60000 and int(c["session_ms"]) <= now:
			n += 1
	return float(n)


func cost_per_hour() -> float:
	var hours := maxf((Time.get_ticks_msec() - _session_start_ms) / 3600000.0, 1.0 / 60.0)
	return float(session["cost"]) / hours


func export_json(to_path: String) -> bool:
	var f := FileAccess.open(to_path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({"exported": Time.get_datetime_string_from_system(true), "all_time": all_time,
		"by_day": by_day, "calls": calls}, "  "))
	return true


func save() -> void:
	if path == "":
		return
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"all_time": all_time, "by_day": by_day, "calls": calls}))
