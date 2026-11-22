extends SceneTree
## Loads every .gd under res:// and reports parse/compile failures, so a broken
## script nobody's tests touch still fails CI.
##   godot --headless --path . -s res://addons/build_lib/testing/check_scripts.gd [-- --skip=res://tools,res://addons/foo]
## Hidden folders (.godot, .git...) are always skipped.


func _initialize() -> void:
	var skip: Array = []
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--skip="):
			skip = Array(a.substr(7).split(",", false))
	var bad := 0
	var n := 0
	for path: String in walk("res://", skip):
		n += 1
		var s: Variant = load(path)
		if s == null or not (s as GDScript).can_instantiate():
			print("BROKEN: ", path)
			bad += 1
	print("%d scripts checked, %d broken" % [n, bad])
	quit(1 if bad > 0 else 0)


static func walk(dir: String, skip: Array = []) -> Array[String]:
	var out: Array[String] = []
	if skip.has(dir.trim_suffix("/")):
		return out
	for f: String in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for d: String in DirAccess.get_directories_at(dir):
		if d.begins_with("."):
			continue
		out.append_array(walk(dir.path_join(d), skip))
	return out
