extends Node
class_name MoveLogger

var move_log: Array[Dictionary] = []
var session_start_ms: int = 0
var last_move_ms: int = 0

func reset_clock() -> void:
	session_start_ms = Time.get_ticks_msec()
	last_move_ms = session_start_ms
	move_log.clear()

func record_move(token: String, category: String, front: Vector3i, right: Vector3i) -> void:
	var now = Time.get_ticks_msec()
	var elapsed = now - session_start_ms
	var delta = now - last_move_ms
	last_move_ms = now

	var record = {
		"move": token,
		"category": category,
		"timestamp_ms": elapsed,
		"delta_ms": delta,
		"orientation_front": front,
		"orientation_right": right
	}
	move_log.append(record)
	print("[MOVE LOG] #%d: %s (split: %dms, total: %dms)" % [move_log.size(), token, delta, elapsed])
