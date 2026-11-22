class_name ORModelCatalog
extends Node
## OpenRouter's model list (for Settings dropdowns and capability checks),
## cached on disk for TTL_S.

signal refreshed(ok: bool, message: String)

const TTL_S := 86400

var config: ORConfig
var url: String = ORHttpProvider.BASE_URL + "/models"
var models: Array[Dictionary] = []
var fetched_at: int = 0
var _http: HTTPRequest


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 30
	add_child(_http)
	_load_cache()


func _load_cache() -> void:
	var d: Variant = ORJson.load_file(config.models_cache_path) if config.models_cache_path != "" else null
	if d is Dictionary:
		var dd: Dictionary = d
		fetched_at = int(dd.get("fetched_at", 0))
		set_models(dd.get("data", []))


func set_models(list: Array) -> void:
	models.clear()
	for m: Variant in list:
		if m is Dictionary:
			models.append(m)


func is_stale() -> bool:
	return models.is_empty() or Time.get_unix_time_from_system() - fetched_at > TTL_S


func refresh_if_stale() -> void:
	if is_stale():
		refresh()


func refresh() -> void:
	if _http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		return
	var err := _http.request(url, config.headers())
	if err != OK:
		refreshed.emit(false, "Request failed (%d)" % err)
		return
	var res: Array = await _http.request_completed
	var code := int(res[1])
	var body: PackedByteArray = res[3]
	if code != 200:
		refreshed.emit(false, "HTTP %d" % code)
		return
	var parsed: Variant = ORJson.parse(body.get_string_from_utf8())
	if not (parsed is Dictionary):
		refreshed.emit(false, "Bad response")
		return
	set_models((parsed as Dictionary).get("data", []))
	fetched_at = int(Time.get_unix_time_from_system())
	if config.models_cache_path != "":
		DirAccess.make_dir_recursive_absolute(config.models_cache_path.get_base_dir())
		var f := FileAccess.open(config.models_cache_path, FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify({"fetched_at": fetched_at, "data": models}))
	refreshed.emit(true, "%d models" % models.size())


func find(model_id: String) -> Dictionary:
	for m: Dictionary in models:
		if str(m.get("id", "")) == model_id:
			return m
	return {}


func supports_structured(model_id: String) -> bool:
	var params: Array = find(model_id).get("supported_parameters", [])
	return params.has("structured_outputs")


static func outputs_image(m: Dictionary) -> bool:
	var arch: Dictionary = m.get("architecture", {})
	var outs: Array = arch.get("output_modalities", [])
	return outs.has("image")


## Models usable for a kind: "text" needs structured outputs, "image" needs
## image output, "any" is everything. Sorted by id.
func models_for(kind: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for m: Dictionary in models:
		var params: Array = m.get("supported_parameters", [])
		if kind == "any" or (kind == "image" and outputs_image(m)) or (kind == "text" and params.has("structured_outputs")):
			out.append(m)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["id"]) < str(b["id"]))
	return out


## "$0.15/$0.60 per 1M" or "$0.040/img".
static func price_label(m: Dictionary, kind: String = "text") -> String:
	var p: Dictionary = m.get("pricing", {})
	if kind == "image":
		var per_image := float(p.get("image", 0.0))
		if per_image > 0.0:
			return "$%.3f/img" % per_image
		return "$%.2f/1M out" % (float(p.get("completion", 0.0)) * 1e6)
	return "$%.2f/$%.2f per 1M" % [float(p.get("prompt", 0.0)) * 1e6, float(p.get("completion", 0.0)) * 1e6]
