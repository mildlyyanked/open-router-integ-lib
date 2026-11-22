class_name ORProvider
extends Node
## Transport for one chat-completions call. send() is a coroutine returning
## {ok: bool, code: int, body: Dictionary, error: String, latency_ms: int}.
## req: {use_case, inputs, body, timeout_s, fixture_key, url?}

var config: ORConfig


func provider_name() -> String:
	return "base"


func send(_req: Dictionary) -> Dictionary:
	await get_tree().process_frame
	return {"ok": false, "code": 0, "body": {}, "error": "no provider", "latency_ms": 0}
