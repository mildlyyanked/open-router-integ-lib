extends SceneTree
## Headless test runner.
##   godot --headless --path . -s res://addons/build_lib/testing/run_tests.gd [-- --filter=substr --dirs=res://tests]
## Finds every test_*.gd under the test dirs (recursively, default res://tests),
## runs each test_* method of each TestCase subclass, and exits 1 on any failure.
## A script error raised while a test runs fails that test (a runtime error
## otherwise just aborts the function and the test would look green).
## On GitHub Actions a results table is written to the job summary.

const DEFAULT_DIRS := ["res://tests"]  # vendored from android-build-lib


class ErrorCounter extends Logger:
	var count: int = 0
	var last: String = ""
	var _m := Mutex.new()

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _bt: Array[ScriptBacktrace]) -> void:
		if error_type != ERROR_TYPE_SCRIPT:
			return
		_m.lock()
		count += 1
		last = "%s (%s:%d %s)" % [rationale if rationale != "" else code, file.get_file(), line, function]
		_m.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

var _errors := ErrorCounter.new()


func _initialize() -> void:
	_run.call_deferred()


static func find_tests(dir: String) -> Array[String]:
	var out: Array[String] = []
	if not DirAccess.dir_exists_absolute(dir):
		return out
	var files: Array = Array(DirAccess.get_files_at(dir))
	files.sort()
	for f: String in files:
		if f.begins_with("test_") and f.ends_with(".gd"):
			out.append(dir.path_join(f))
	var dirs: Array = Array(DirAccess.get_directories_at(dir))
	dirs.sort()
	for d: String in dirs:
		if not d.begins_with("."):
			out.append_array(find_tests(dir.path_join(d)))
	return out


func _run() -> void:
	OS.add_logger(_errors)
	var filter := ""
	var dirs: Array = DEFAULT_DIRS.duplicate()
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--filter="):
			filter = a.substr(9)
		elif a.begins_with("--dirs="):
			dirs = Array(a.substr(7).split(",", false))
	var total := 0
	var failed := 0
	var rows: Array[String] = []
	var t0 := Time.get_ticks_msec()
	var paths: Array[String] = []
	for dir: String in dirs:
		paths.append_array(find_tests(dir))
	if paths.is_empty():
		print("No test_*.gd files under %s" % ", ".join(PackedStringArray(dirs)))
	for path in paths:
		var f := path.get_file()
		var script: GDScript = load(path)
		if script == null or not script.can_instantiate():
			print("  FAIL %s: failed to load" % path)
			rows.append("| %s | failed to load |" % path)
			failed += 1
			continue
		for method: Dictionary in script.get_script_method_list():
			var mname := str(method["name"])
			if not mname.begins_with("test_"):
				continue
			if filter != "" and not (path + ":" + mname).contains(filter):
				continue
			var tc: TestCase = script.new()
			tc.tree = self
			tc.current_test = "%s:%s" % [f, mname]
			var errs_before := _errors.count
			tc.before_each()
			await tc.call(mname)
			tc.after_each()
			if _errors.count > errs_before:
				tc.failures.append("%s: script error during the test: %s" % [tc.current_test, _errors.last])
			total += 1
			if tc.failures.is_empty():
				print("  ok   %s" % tc.current_test)
			else:
				failed += 1
				print("  FAIL %s" % tc.current_test)
				for msg: String in tc.failures:
					print("         " + msg)
					rows.append("| %s | %s |" % [tc.current_test, msg.replace("|", "\\|").left(300)])
	var ms := Time.get_ticks_msec() - t0
	print("\n%d tests, %d failed (%d ms)" % [total, failed, ms])
	_write_summary(total, failed, ms, rows)
	quit(1 if failed > 0 or total == 0 and filter == "" and not paths.is_empty() else 0)


func _write_summary(total: int, failed: int, ms: int, rows: Array[String]) -> void:
	var path := OS.get_environment("GITHUB_STEP_SUMMARY")
	if path == "":
		return
	var f := FileAccess.open(path, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	var text := "### Godot tests: %s %d passed, %d failed (%.1f s)\n" % ["✅" if failed == 0 else "❌", total - failed, failed, ms / 1000.0]
	if not rows.is_empty():
		text += "\n| Test | Failure |\n|---|---|\n" + "\n".join(PackedStringArray(rows)) + "\n"
	f.store_string(text + "\n")
	f.close()
