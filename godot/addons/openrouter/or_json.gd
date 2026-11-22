class_name ORJson
extends RefCounted
## JSON helpers: lenient parsing of model output, canonical hashing for
## fixture keys.


static func parse(text: String) -> Variant:
	var json := JSON.new()
	if json.parse(text) != OK:
		return null
	return json.data


static func load_file(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return parse(FileAccess.get_file_as_string(path))


## Removes ```json fences some models wrap around JSON.
static func strip_fences(text: String) -> String:
	var t := text.strip_edges()
	if t.begins_with("```"):
		var first_nl := t.find("\n")
		t = t.substr(first_nl + 1) if first_nl >= 0 else t
		if t.ends_with("```"):
			t = t.substr(0, t.length() - 3)
	return t.strip_edges()


static func canonical(value: Variant) -> String:
	return JSON.stringify(_normalize(value), "", true, true)


static func hash_of(value: Variant) -> String:
	return canonical(value).sha256_text()


static func _normalize(value: Variant) -> Variant:
	match typeof(value):
		TYPE_FLOAT:
			var f: float = value
			if is_finite(f) and f == floorf(f) and absf(f) < 9.0e15:
				return int(f)
			return f
		TYPE_DICTIONARY:
			var out: Dictionary = {}
			var d: Dictionary = value
			for k: Variant in d:
				out[str(k)] = _normalize(d[k])
			return out
		TYPE_ARRAY:
			var out_a: Array = []
			for v: Variant in (value as Array):
				out_a.append(_normalize(v))
			return out_a
	return value
