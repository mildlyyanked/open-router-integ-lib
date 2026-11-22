class_name ORJob
extends RefCounted
## One named-use-case model call, tracked from queue to result.
## `await job.finished` (or check job.is_done()) then read job.result.

signal finished(job: ORJob)

## Lower runs first. INTERACTION/DIALOGUE/FOREGROUND share the foreground pool.
enum Priority { INTERACTION = 0, DIALOGUE = 1, FOREGROUND = 2, BACKGROUND = 3 }

var id: String = ""
var use_case: String = ""
var inputs: Dictionary = {}
var priority: int = Priority.FOREGROUND
## queued | running | done | fallback | failed | needs_retry
var status: String = "queued"
var attempts: int = 0
var repairs: int = 0
var model: String = ""
var prompt_version: int = 1
var result: Variant = null
var raw: String = ""
var errors: Array[String] = []
var created_ms: int = 0
var started_ms: int = 0
var ended_ms: int = 0
## (parsed) -> Array of extra error strings (game-state checks); fed to repair.
var validator: Callable = Callable()
## (inputs) -> Variant deterministic content used when the model can't deliver.
var fallback: Callable = Callable()
## Set instead of a prompt template: explicit messages (and optional schema).
var messages: Array = []
var schema: Dictionary = {}
## Plain-text call: no JSON parsing/validation; result is the text.
var text_only: bool = false


func is_foreground() -> bool:
	return priority <= Priority.FOREGROUND


func is_done() -> bool:
	return status in ["done", "fallback", "failed"]


func ok() -> bool:
	return status == "done" or status == "fallback"


func elapsed_ms() -> int:
	if started_ms == 0:
		return 0
	return (ended_ms if ended_ms > 0 else Time.get_ticks_msec()) - started_ms


## Enough to re-issue the job after a load (callables are re-bound by the owner).
func descriptor() -> Dictionary:
	return {"id": id, "use_case": use_case, "inputs": inputs.duplicate(true), "priority": priority}
