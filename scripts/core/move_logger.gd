extends Node
class_name MoveLogger

var move_log: Array[Dictionary] = []
var session_start_ms: int = 0
var last_move_ms: int = 0

func reset_clock() -> void:
	session_start_ms = Time.get_ticks_msec()
	last_move_ms = session_start_ms
	move_log.clear()

func record_move(token: String, category: String, wca_notation: String, front_color: String, right_color: String) -> void:
	var now = Time.get_ticks_msec()
	var elapsed = now - session_start_ms
	var delta = now - last_move_ms
	last_move_ms = now

	var record = {
		"raw_action": token,
		"wca_notation": wca_notation,
		"category": category,
		"timestamp_ms": elapsed,
		"delta_ms": delta,
		"front_color": front_color,
		"right_color": right_color
	}
	move_log.append(record)
	print("[MOVE LOG] #%d: %s -> WCA: %s | F: %s, R: %s (split: %dms, total: %dms)" % [
		move_log.size(),
		token,
		wca_notation,
		front_color,
		right_color,
		delta,
		elapsed
	])
