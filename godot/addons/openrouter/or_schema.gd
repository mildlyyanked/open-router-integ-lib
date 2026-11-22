class_name ORSchema
extends RefCounted
## Minimal JSON Schema validator for LLM outputs (the subset structured
## outputs use): type, properties, required, additionalProperties:false,
## enum, items, minItems/maxItems, minimum/maximum, minLength/maxLength.
## Returns a list of human-readable errors; empty means valid. These errors
## are fed back to the model in the repair loop.


static func validate(value: Variant, schema: Dictionary, path: String = "$") -> Array[String]:
	var errors: Array[String] = []
	_check(value, schema, path, errors)
	return errors


static func _type_ok(value: Variant, t: String) -> bool:
	match t:
		"object":
			return typeof(value) == TYPE_DICTIONARY
		"array":
			return typeof(value) == TYPE_ARRAY
		"string":
			return typeof(value) == TYPE_STRING
		"boolean":
			return typeof(value) == TYPE_BOOL
		"null":
			return value == null
		"number":
			return typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT
		"integer":
			if typeof(value) == TYPE_INT:
				return true
			if typeof(value) == TYPE_FLOAT:
				var f: float = value
				return f == floorf(f)
			return false
	return false


static func _check(value: Variant, schema: Dictionary, path: String, errors: Array[String]) -> void:
	if schema.has("type"):
		var types: Array = []
		if typeof(schema["type"]) == TYPE_ARRAY:
			types = schema["type"]
		else:
			types = [schema["type"]]
		var any_ok := false
		for t: Variant in types:
			if _type_ok(value, str(t)):
				any_ok = true
				break
		if not any_ok:
			errors.append("%s: expected type %s" % [path, "/".join(PackedStringArray(types.map(func(x: Variant) -> String: return str(x))))])
			return
	if schema.has("enum"):
		var options: Array = schema["enum"]
		var found := false
		for o: Variant in options:
			if typeof(o) == typeof(value) and o == value:
				found = true
			elif (typeof(o) == TYPE_INT or typeof(o) == TYPE_FLOAT) and (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and float(o) == float(value):
				found = true
		if not found:
			errors.append("%s: value %s is not one of %s" % [path, JSON.stringify(value), JSON.stringify(options)])
	match typeof(value):
		TYPE_DICTIONARY:
			var d: Dictionary = value
			var props: Dictionary = schema.get("properties", {})
			var required: Array = schema.get("required", [])
			for r: Variant in required:
				if not d.has(str(r)):
					errors.append("%s: missing required field '%s'" % [path, r])
			if schema.get("additionalProperties", true) == false:
				for k: Variant in d:
					if not props.has(str(k)):
						errors.append("%s: unexpected field '%s'" % [path, k])
			for k: Variant in props:
				if d.has(k):
					var sub: Dictionary = props[k]
					_check(d[k], sub, "%s.%s" % [path, k], errors)
		TYPE_ARRAY:
			var a: Array = value
			if schema.has("minItems") and a.size() < int(schema["minItems"]):
				errors.append("%s: needs at least %d items" % [path, int(schema["minItems"])])
			if schema.has("maxItems") and a.size() > int(schema["maxItems"]):
				errors.append("%s: allows at most %d items" % [path, int(schema["maxItems"])])
			if schema.has("items"):
				var item_schema: Dictionary = schema["items"]
				for i in a.size():
					_check(a[i], item_schema, "%s[%d]" % [path, i], errors)
		TYPE_STRING:
			var s: String = value
			if schema.has("minLength") and s.length() < int(schema["minLength"]):
				errors.append("%s: shorter than %d characters" % [path, int(schema["minLength"])])
			if schema.has("maxLength") and s.length() > int(schema["maxLength"]):
				errors.append("%s: longer than %d characters" % [path, int(schema["maxLength"])])
		TYPE_INT, TYPE_FLOAT:
			var n: float = float(value)
			if schema.has("minimum") and n < float(schema["minimum"]):
				errors.append("%s: below minimum %s" % [path, schema["minimum"]])
			if schema.has("maximum") and n > float(schema["maximum"]):
				errors.append("%s: above maximum %s" % [path, schema["maximum"]])


## Strict structured-output modes reject some keywords (string lengths).
## They are stripped from what is sent; local validation still enforces them.
static func wire(v: Variant) -> Variant:
	if v is Dictionary:
		var out: Dictionary = {}
		for k: String in v:
			if k in ["maxLength", "minLength"]:
				continue
			out[k] = wire(v[k])
		return out
	if v is Array:
		return (v as Array).map(func(x: Variant) -> Variant: return wire(x))
	return v
