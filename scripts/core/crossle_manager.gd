extends Node
class_name CrossleManager

# ==============================================================================
# CROSSLE MANAGER
# Standalone controller for Crossle game mode with raw solver tree telemetry
# and line-by-line move logging.
# ==============================================================================

signal state_changed(new_state: String)
signal inspection_tick(seconds_left: float)
signal solve_tick(elapsed_seconds: float)
signal crossle_completed(result: Dictionary)

enum State { IDLE, INSPECTING, SOLVING, COMPLETED }
var current_state: State = State.IDLE

@export var cube_root: CubeRoot
@export var inspection_limit: float = 15.0

# Active Challenge Data
var active_seed: int = 0
var active_scramble: Array[String] = []
var target_cross_color: String = ""
var target_front_color: String = ""
var par_moves: int = 0
var par_solution: Array[String] = []

# Live Timers & Counters
var inspection_timer: float = 0.0
var solve_timer: float = 0.0
var last_move_timestamp: float = 0.0
var player_move_count: int = 0
var move_log_lines: Array[String] = []

# Reference Frame Locked at Scramble Time
var frame_down: Vector3i
var frame_front: Vector3i
var frame_right: Vector3i

# Solver Tables & Telemetry
const ALL_MOVES: Array[String] = [
	"U", "U'", "U2", "D", "D'", "D2",
	"R", "R'", "R2", "L", "L'", "L2",
	"F", "F'", "F2", "B", "B'", "B2"
]
const INVERSE_MOVES: Array[String] = [
	"U'", "U", "U2", "D'", "D", "D2",
	"R'", "R", "R2", "L'", "L", "L2",
	"F'", "F", "F2", "B'", "B", "B2"
]
var _edge_trans: Array = []          # [move_idx][edge_state 0..23] -> new_edge_state
var _solved_lookup: Dictionary = {}  # packed_4_edges (int) -> Array[int] (moves from solved)
var tree_stats: Dictionary = {}

func _ready() -> void:
	if not cube_root:
		cube_root = get_parent() as CubeRoot
	
	if cube_root and cube_root.controller_manager:
		if not cube_root.controller_manager.move_requested.is_connected(_on_player_move_requested):
			cube_root.controller_manager.move_requested.connect(_on_player_move_requested)

	_init_solver_tables()

func _process(delta: float) -> void:
	match current_state:
		State.INSPECTING:
			inspection_timer -= delta
			inspection_tick.emit(max(0.0, inspection_timer))
			if inspection_timer <= 0.0:
				_start_solving()

		State.SOLVING:
			solve_timer += delta
			solve_tick.emit(solve_timer)

			if not cube_root.is_animating:
				if _is_cross_solved():
					_complete_crossle()

# ==============================================================================
# 1. SEED OF THE DAY & SCRAMBLE
# ==============================================================================
func get_seed_of_the_day() -> int:
	var dt = Time.get_date_dict_from_system(true) # UTC
	var date_str = "%04d-%02d-%02d" % [dt.year, dt.month, dt.day]
	return abs(date_str.hash())

func generate_scramble_from_seed(seed_val: int, length: int = 20) -> Array[String]:
	var rng = RandomNumberGenerator.new()
	rng.seed = seed_val

	var faces = ["R", "L", "U", "D", "F", "B"]
	var modifiers = ["", "'", "2"]
	var scramble: Array[String] = []
	var last_axis: int = -1

	for i in range(length):
		var face_idx = rng.randi_range(0, 5)
		var axis = floori(face_idx * 0.5)
		while axis == last_axis:
			face_idx = rng.randi_range(0, 5)
			axis = floori(face_idx * 0.5)

		last_axis = axis
		var mod = modifiers[rng.randi_range(0, 2)]
		scramble.append(faces[face_idx] + mod)

	return scramble

# ==============================================================================
# 2. MATCH START & STATE MACHINE
# ==============================================================================
func start_crossle_match(use_daily_seed: bool = true, custom_seed: int = 0) -> void:
	active_seed = get_seed_of_the_day() if use_daily_seed else custom_seed

	# 1. Capture spatial orientation at scramble time
	frame_down = -cube_root.get_orientation_up()
	frame_front = cube_root.orientation_front
	frame_right = cube_root.orientation_right
	target_cross_color = cube_root.color_scheme.get(frame_down, "White")
	target_front_color = cube_root.color_scheme.get(frame_front, "Green")

	# 2. Reset cube and generate scramble
	cube_root.reset_cube()
	active_scramble = generate_scramble_from_seed(active_seed)

	# 3. Calculate Par via Meet-in-the-Middle BFS + record tree telemetry
	var par_result = _solve_par(active_scramble)
	par_moves = par_result["depth"]
	par_solution = par_result["moves"]

	# 4. Apply scramble instantly
	var mapped_moves = _translate_wca_to_cube_actions(active_scramble)
	cube_root.apply_sequence_instant(mapped_moves)

	# 5. Arm Inspection Phase & Reset Logs
	player_move_count = 0
	solve_timer = 0.0
	last_move_timestamp = 0.0
	move_log_lines.clear()
	inspection_timer = inspection_limit
	current_state = State.INSPECTING
	state_changed.emit("INSPECTING")

func _on_player_move_requested(action_id: String) -> void:
	if action_id == "start" or action_id == "cancel":
		return

	if current_state == State.INSPECTING:
		if action_id.begins_with("rot_"):
			var inspect_elapsed = inspection_limit - inspection_timer
			move_log_lines.append("INSP | @%.3fs | %s" % [inspect_elapsed, action_id])
			return
		_start_solving()

	if current_state == State.SOLVING:
		var split = solve_timer - last_move_timestamp
		last_move_timestamp = solve_timer
		if action_id.begins_with("rot_"):
			move_log_lines.append("ROT  | @%.3fs (+%.3fs) | %s" % [solve_timer, split, action_id])
		else:
			player_move_count += 1
			move_log_lines.append("#%02d  | @%.3fs (+%.3fs) | %s" % [player_move_count, solve_timer, split, action_id])

func _start_solving() -> void:
	current_state = State.SOLVING
	state_changed.emit("SOLVING")

func _complete_crossle() -> void:
	current_state = State.COMPLETED
	state_changed.emit("COMPLETED")

	var delta = player_move_count - par_moves
	var golf_term = "Par"
	if delta <= -2: golf_term = "Eagle"
	elif delta == -1: golf_term = "Birdie"
	elif delta == 0: golf_term = "Par"
	elif delta == 1: golf_term = "Bogey"
	elif delta == 2: golf_term = "Double Bogey"
	else: golf_term = "+%d" % delta

	var result = {
		"seed": active_seed,
		"target_color": target_cross_color,
		"time": solve_timer,
		"moves": player_move_count,
		"par": par_moves,
		"par_solution": par_solution,
		"score_delta": delta,
		"rating": golf_term,
		"tree_stats": tree_stats,
		"full_log_dump": build_full_log_dump(golf_term, delta)
	}
	crossle_completed.emit(result)

func build_full_log_dump(rating: String = "", delta: int = 0) -> String:
	var lines: Array[String] = []
	lines.append("=== CROSSLE TELEMETRY DUMP ===")
	lines.append("Seed: %d | Target: %s Cross (%s Front)" % [active_seed, target_cross_color, target_front_color])
	lines.append("Scramble: %s" % " ".join(active_scramble))
	lines.append("Result: %s (%+d) | Moves: %d / Par: %d | Time: %.3fs" % [rating, delta, player_move_count, par_moves, solve_timer])
	lines.append("Optimal Par Path: %s" % " ".join(par_solution))
	lines.append("")
	lines.append("--- SOLVER TREE STATS ---")
	lines.append("BWD Tree (Depth 0-4): %d states stored | %d edges checked | %d us (%.1f ns/edge)" % [
		tree_stats.get("bwd_states", 0),
		tree_stats.get("bwd_edges", 0),
		tree_stats.get("bwd_us", 0),
		tree_stats.get("bwd_ns_per_edge", 0.0)
	])
	lines.append("FWD Tree (Depth 0-%d): %d states visited | %d edges checked | %d us (%.1f ns/edge)" % [
		tree_stats.get("fwd_depth", 0),
		tree_stats.get("fwd_states", 0),
		tree_stats.get("fwd_edges", 0),
		tree_stats.get("fwd_us", 0),
		tree_stats.get("fwd_ns_per_edge", 0.0)
	])
	lines.append("Combined Lookup: %d total edges | %d us total (%.1f ns avg/check)" % [
		tree_stats.get("total_edges", 0),
		tree_stats.get("total_us", 0),
		tree_stats.get("avg_ns_per_edge", 0.0)
	])
	lines.append("")
	lines.append("--- MOVE LOG (%d lines) ---" % move_log_lines.size())
	lines.append_array(move_log_lines)
	return "\n".join(lines)

# ==============================================================================
# 3. LIVE CENTER-TRACKED LINEAR ALGEBRA CROSS DETECTION
# ==============================================================================
func _is_cross_solved() -> bool:
	var dirs: Array[Vector3i] = [
		Vector3i.UP, Vector3i.DOWN,
		Vector3i.LEFT, Vector3i.RIGHT,
		Vector3i.FORWARD, Vector3i.BACK
	]

	var d_vec := Vector3i.ZERO
	for dir in dirs:
		if not cube_root.pieces.has(dir):
			continue
		var c_piece: Node3D = cube_root.pieces[dir]
		var c_inv = c_piece.transform.basis.transposed()
		var orig_dir = Vector3i((c_inv * Vector3(dir)).round())
		if cube_root.color_scheme.get(orig_dir, "") == target_cross_color:
			d_vec = dir
			break

	if d_vec == Vector3i.ZERO:
		return false

	for lat_vec in dirs:
		if lat_vec == d_vec or lat_vec == -d_vec:
			continue

		var coord = d_vec + lat_vec
		if not cube_root.pieces.has(coord) or not cube_root.pieces.has(lat_vec):
			return false

		var flank_center: Node3D = cube_root.pieces[lat_vec]
		var fc_inv = flank_center.transform.basis.transposed()
		var expected_lat_color = cube_root.color_scheme.get(Vector3i((fc_inv * Vector3(lat_vec)).round()), "")

		var edge: Node3D = cube_root.pieces[coord]
		var e_inv = edge.transform.basis.transposed()
		var orig_down = Vector3i((e_inv * Vector3(d_vec)).round())
		var orig_lat = Vector3i((e_inv * Vector3(lat_vec)).round())

		if cube_root.color_scheme.get(orig_down, "") != target_cross_color:
			return false
		if cube_root.color_scheme.get(orig_lat, "") != expected_lat_color:
			return false

	return true

# ==============================================================================
# 4. MEET-IN-THE-MIDDLE 4-EDGE PAR SOLVER
# ==============================================================================
func _init_solver_tables() -> void:
	var t0 = Time.get_ticks_usec()
	var bwd_edges_checked: int = 0

	var raw_cycles = {
		"U": {"edges": [4, 5, 6, 7], "flip": 0},
		"D": {"edges": [0, 1, 2, 3], "flip": 0},
		"R": {"edges": [1, 8, 5, 11], "flip": 0},
		"L": {"edges": [3, 10, 7, 9], "flip": 0},
		"F": {"edges": [0, 9, 6, 8], "flip": 1},
		"B": {"edges": [2, 11, 4, 10], "flip": 1}
	}

	_edge_trans.resize(18)
	for m_idx in range(18):
		var m_str = ALL_MOVES[m_idx]
		var face = m_str[0]
		var turns = 2 if m_str.ends_with("2") else (3 if m_str.ends_with("'") else 1)
		var cycle: Array = raw_cycles[face]["edges"]
		var flip: int = raw_cycles[face]["flip"]

		var table: Array[int] = []
		table.resize(24)
		for s in range(24):
			var pos = s >> 1
			var ori = s & 1
			for _t in range(turns):
				var idx = cycle.find(pos)
				if idx != -1:
					pos = cycle[(idx + 1) % 4]
					ori ^= flip
			table[s] = (pos << 1) | ori
		_edge_trans[m_idx] = table

	_solved_lookup.clear()
	var start_key = _pack_edges(0, 2, 4, 6)
	_solved_lookup[start_key] = []

	var frontier: Array = [[0, 2, 4, 6, []]]
	for _depth in range(4):
		var next_frontier: Array = []
		for item in frontier:
			var e0: int = item[0]
			var e1: int = item[1]
			var e2: int = item[2]
			var e3: int = item[3]
			var path: Array = item[4]
			var last_face: int = -1 if path.is_empty() else floori(path[-1] / 3.0)

			for m_idx in range(18):
				if floori(m_idx / 3.0) == last_face:
					continue
				bwd_edges_checked += 1
				var t = _edge_trans[m_idx]
				var ne0 = t[e0]
				var ne1 = t[e1]
				var ne2 = t[e2]
				var ne3 = t[e3]
				var key = _pack_edges(ne0, ne1, ne2, ne3)
				if not _solved_lookup.has(key):
					var new_path = path.duplicate()
					new_path.append(m_idx)
					_solved_lookup[key] = new_path
					next_frontier.append([ne0, ne1, ne2, ne3, new_path])
		frontier = next_frontier

	var bwd_us = max(1, Time.get_ticks_usec() - t0)
	tree_stats["bwd_states"] = _solved_lookup.size()
	tree_stats["bwd_edges"] = bwd_edges_checked
	tree_stats["bwd_us"] = bwd_us
	tree_stats["bwd_ns_per_edge"] = (bwd_us * 1000.0) / float(max(1, bwd_edges_checked))

func _pack_edges(e0: int, e1: int, e2: int, e3: int) -> int:
	return e0 + e1 * 24 + e2 * 576 + e3 * 13824

func _solve_par(scramble: Array[String]) -> Dictionary:
	if _edge_trans.is_empty():
		_init_solver_tables()

	var t0 = Time.get_ticks_usec()
	var fwd_edges_checked: int = 0
	var fwd_depth_reached: int = 0

	var e0 = 0
	var e1 = 2
	var e2 = 4
	var e3 = 6

	for m_str in scramble:
		var m_idx = ALL_MOVES.find(m_str)
		if m_idx != -1:
			var t = _edge_trans[m_idx]
			e0 = t[e0]
			e1 = t[e1]
			e2 = t[e2]
			e3 = t[e3]

	var init_key = _pack_edges(e0, e1, e2, e3)
	if _solved_lookup.has(init_key):
		var res0 = _format_solution([], _solved_lookup[init_key])
		_record_fwd_stats(t0, 1, 1, 0, res0["depth"])
		return res0

	var visited: Dictionary = {init_key: true}
	var frontier: Array = [[e0, e1, e2, e3, []]]

	for depth_step in range(4):
		fwd_depth_reached = depth_step + 1
		var next_frontier: Array = []
		for item in frontier:
			var ce0: int = item[0]
			var ce1: int = item[1]
			var ce2: int = item[2]
			var ce3: int = item[3]
			var path: Array = item[4]
			var last_face: int = -1 if path.is_empty() else floori(path[-1] / 3.0)

			for m_idx in range(18):
				if floori(m_idx / 3.0) == last_face:
					continue
				fwd_edges_checked += 1
				var t = _edge_trans[m_idx]
				var ne0 = t[ce0]
				var ne1 = t[ce1]
				var ne2 = t[ce2]
				var ne3 = t[ce3]
				var key = _pack_edges(ne0, ne1, ne2, ne3)

				if _solved_lookup.has(key):
					var fwd_path = path.duplicate()
					fwd_path.append(m_idx)
					var res = _format_solution(fwd_path, _solved_lookup[key])
					_record_fwd_stats(t0, visited.size(), fwd_edges_checked, fwd_depth_reached, res["depth"])
					return res

				if not visited.has(key):
					visited[key] = true
					var new_path = path.duplicate()
					new_path.append(m_idx)
					next_frontier.append([ne0, ne1, ne2, ne3, new_path])
		frontier = next_frontier

	_record_fwd_stats(t0, visited.size(), fwd_edges_checked, 4, 8)
	return {"depth": 8, "moves": []}

func _record_fwd_stats(t0: int, states_count: int, edges_count: int, depth_reached: int, total_par: int) -> void:
	var fwd_us = max(1, Time.get_ticks_usec() - t0)
	var bwd_us: int = tree_stats.get("bwd_us", 0)
	var bwd_edges: int = tree_stats.get("bwd_edges", 0)
	var total_edges = bwd_edges + edges_count
	var total_us = bwd_us + fwd_us

	tree_stats["fwd_states"] = states_count
	tree_stats["fwd_edges"] = edges_count
	tree_stats["fwd_depth"] = depth_reached
	tree_stats["fwd_us"] = fwd_us
	tree_stats["fwd_ns_per_edge"] = (fwd_us * 1000.0) / float(max(1, edges_count))
	tree_stats["total_edges"] = total_edges
	tree_stats["total_us"] = total_us
	tree_stats["avg_ns_per_edge"] = (total_us * 1000.0) / float(max(1, total_edges))
	tree_stats["par_depth"] = total_par

func _format_solution(fwd_indices: Array, bwd_indices: Array) -> Dictionary:
	var moves: Array[String] = []
	for m_idx in fwd_indices:
		moves.append(ALL_MOVES[m_idx])
	for i in range(bwd_indices.size() - 1, -1, -1):
		moves.append(INVERSE_MOVES[bwd_indices[i]])
	return {"depth": moves.size(), "moves": moves}

func _translate_wca_to_cube_actions(tokens: Array[String]) -> Array[String]:
	var actions: Array[String] = []
	for t in tokens:
		var face = t[0].to_lower()
		var is_double = t.ends_with("2")
		var is_prime = t.ends_with("'")
		var base = "move_" + face

		if is_double:
			actions.append(base)
			actions.append(base)
		elif is_prime:
			actions.append(base + "_prime")
		else:
			actions.append(base)
	return actions
