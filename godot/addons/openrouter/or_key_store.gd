class_name ORKeyStore
extends RefCounted
## Keeps the player's OpenRouter key on the device, encrypted with a
## device-derived pass. This is obfuscation against casual file browsing, not
## real security: a shipped game cannot hide a secret from its own player.
## Never ship your own key in a build; let players bring theirs, or route
## calls through a backend that holds it (see the TypeScript proxy).

const DEFAULT_PATH := "user://openrouter_key.dat"


static func save_key(key: String, app_salt: String, path: String = DEFAULT_PATH) -> bool:
	var f := FileAccess.open_encrypted_with_pass(path, FileAccess.WRITE, _pass(app_salt))
	if f == null:
		return false
	f.store_string(key.strip_edges())
	return true


static func read_key(app_salt: String, path: String = DEFAULT_PATH) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open_encrypted_with_pass(path, FileAccess.READ, _pass(app_salt))
	return f.get_as_text() if f else ""


static func clear_key(path: String = DEFAULT_PATH) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


## "sk-or•••••••a1b2" for display.
static func mask(key: String) -> String:
	if key.length() <= 8:
		return "•".repeat(key.length())
	return key.substr(0, 5) + "•".repeat(6) + key.substr(key.length() - 4)


static func _pass(app_salt: String) -> String:
	return (app_salt + ":" + OS.get_unique_id()).sha256_text()
