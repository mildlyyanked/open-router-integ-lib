class_name TestCase
extends RefCounted
## Base class for headless tests run by addons/build_lib/testing/run_tests.gd.
## Methods named test_* run in file order; failures are collected, not thrown.
## A test may `await` (it gets `tree` for timers and frames).

var failures: Array[String] = []
var current_test: String = ""
var tree: SceneTree


func before_each() -> void:
	pass


func after_each() -> void:
	pass


func fail(msg: String) -> void:
	failures.append("%s: %s" % [current_test, msg])


func assert_true(cond: bool, msg: String = "expected true") -> void:
	if not cond:
		fail(msg)


func assert_false(cond: bool, msg: String = "expected false") -> void:
	if cond:
		fail(msg)


func assert_eq(actual: Variant, expected: Variant, msg: String = "") -> void:
	if typeof(actual) != typeof(expected) and not (_is_num(actual) and _is_num(expected)):
		fail("%s expected %s (%s), got %s (%s)" % [msg, var_to_str(expected), type_string(typeof(expected)), var_to_str(actual), type_string(typeof(actual))])
	elif actual != expected:
		fail("%s expected %s, got %s" % [msg, var_to_str(expected), var_to_str(actual)])


func assert_ne(actual: Variant, other: Variant, msg: String = "") -> void:
	if actual == other:
		fail("%s did not expect %s" % [msg, var_to_str(other)])


func assert_gt(a: float, b: float, msg: String = "") -> void:
	if not a > b:
		fail("%s expected %s > %s" % [msg, a, b])


func assert_between(v: float, lo: float, hi: float, msg: String = "") -> void:
	if v < lo or v > hi:
		fail("%s expected %s in [%s, %s]" % [msg, v, lo, hi])


func assert_has(container: Variant, item: Variant, msg: String = "") -> void:
	var ok := false
	if container is Array:
		ok = (container as Array).has(item)
	elif container is Dictionary:
		ok = (container as Dictionary).has(item)
	elif container is String:
		ok = (container as String).contains(str(item))
	if not ok:
		fail("%s expected %s to contain %s" % [msg, var_to_str(container), var_to_str(item)])


## Waits n frames (for code that defers work).
func frames(n: int = 1) -> void:
	for i in n:
		await tree.process_frame


func _is_num(v: Variant) -> bool:
	return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT
