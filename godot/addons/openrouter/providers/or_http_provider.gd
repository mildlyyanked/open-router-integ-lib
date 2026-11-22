class_name ORHttpProvider
extends ORProvider
## Real calls to OpenRouter's chat completions endpoint (or a proxy that
## speaks the same API: set base_url, e.g. your own backend holding the key).

const BASE_URL := "https://openrouter.ai/api/v1"

var base_url: String = BASE_URL


func provider_name() -> String:
	return "openrouter"


func send(req: Dictionary) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = float(req.get("timeout_s", 30))
	add_child(http)
	var t0 := Time.get_ticks_msec()
	var url := str(req.get("url", base_url + "/chat/completions"))
	var err := http.request(url, config.headers(), HTTPClient.METHOD_POST, JSON.stringify(req["body"]))
	if err != OK:
		http.queue_free()
		return {"ok": false, "code": 0, "body": {}, "error": "request error %d" % err, "latency_ms": 0}
	var res: Array = await http.request_completed
	http.queue_free()
	var latency := Time.get_ticks_msec() - t0
	var result := int(res[0])
	var code := int(res[1])
	var bytes: PackedByteArray = res[3]
	var text := bytes.get_string_from_utf8()
	var parsed: Variant = ORJson.parse(text)
	var body: Dictionary = parsed if parsed is Dictionary else {}
	if result != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "code": 0, "body": body, "error": "network result %d" % result, "latency_ms": latency}
	if code != 200:
		var msg := text.left(200)
		if body.get("error") is Dictionary:
			msg = str((body["error"] as Dictionary).get("message", msg))
		return {"ok": false, "code": code, "body": body, "error": "HTTP %d: %s" % [code, msg], "latency_ms": latency}
	# OpenRouter can return 200 with an error object (upstream provider failure).
	if body.get("error") is Dictionary:
		var e: Dictionary = body["error"]
		var ecode := int(e.get("code", 502))
		return {"ok": false, "code": ecode if ecode >= 400 else 502, "body": body, "error": "upstream: %s" % e.get("message", "?"), "latency_ms": latency}
	return {"ok": true, "code": code, "body": body, "error": "", "latency_ms": latency}
