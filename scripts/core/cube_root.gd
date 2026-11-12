extends Node3D
class_name CubeRoot

# ==============================================================================
# CUBE ROOT (SPINE)
# Core Responsibilities:
# 1. Piece spatial registry & lifecycle (tracking cubies in 3D grid space).
# 2. View-relative screen-locked slice execution (resolves dynamic orientations).
# 3. Dynamic orientation frame & color mapping for deterministic WCA notation.
# 4. Camera rig orbit handling for free-look inspection.
# 5. Pause menu overlay state management.
# 6. FIFO move buffer & animation time scaling (supports instant 0x speed-of-light).
# 7. In-place solved state reset.
# 8. Real-time procedural audio event triggers.
# ==============================================================================

# Prefab scene used to instantiate individual cubie nodes
const PIECE_SCENE: PackedScene = preload("res://scenes/core/piece.tscn")

# Dictionary mapping 3D integer coordinates Vector3i(x, y, z) -> Node3D cubie instance
var pieces: Dictionary = {}

# Mutual exclusion lock: prevents queue from popping moves while a tween is active
var is_animating: bool = false

# Base duration (in seconds) for a standard 90-degree slice turn
@export var turn_duration: float = 0.25

# Multiplier for animation playback speed (set to 0.0 for instant execution)
@export var anim_multiplier: float = 1.0

# FIFO queue of move token strings awaiting execution
var move_queue: Array[String] = []

# Cube color definition mapping initial world normal vectors to sticker color names
var color_scheme: Dictionary = {
	Vector3i(0, 0, 1): "Green",
	Vector3i(0, 0, -1): "Blue",
	Vector3i(1, 0, 0): "Red",
	Vector3i(-1, 0, 0): "Orange",
	Vector3i(0, 1, 0): "Yellow",
	Vector3i(0, -1, 0): "White"
}

# Dynamic orientation frame tracking which face is currently pointing toward camera
var orientation_front: Vector3i = Vector3i(0, 0, 1)

# Dynamic orientation frame tracking which face is currently pointing right on screen
var orientation_right: Vector3i = Vector3i(1, 0, 0)

# Scene references
@onready var controller_manager: ControllerManager = $ControllerManager
@onready var pause_overlay: Control = $MainHUD/PauseOverlay
var move_logger: MoveLogger
var audio_feedback: AudioFeedback

# Global game pause state flag
var is_paused: bool = false

# ------------------------------------------------------------------------------
# Free-Look Camera Rig Settings
# ------------------------------------------------------------------------------
# Reference to the spatial rig holding the camera
var cam_rig: Node3D

# Active tween used to smoothly snap camera back to default angle upon releasing look
var peek_tween: Tween

@export_group("Free Look (Camera Orbit)")
# Angular orbit speed when navigating with the thumbstick
@export var peek_speed: float = 384.0

# Duration of the smooth camera return snap when releasing the trigger/button
@export var peek_snap_duration: float = 0.15

# Maximum yaw orbit angle in degrees
@export var absolute_yaw_limit: float = 128.0

# Maximum pitch orbit angle in degrees
@export var absolute_pitch_limit: float = 128.0

# Axis inversion flags
@export var invert_peek_x: bool = true
@export var invert_peek_y: bool = true

# Default camera orientation angles to snap back to
var base_cam_yaw: float = 0.0
var base_cam_pitch: float = 0.0


func _ready() -> void:
	# Initialize scene lighting, camera rig, and environment
	var env_data = CubeEnvironment.setup(self)
	cam_rig = env_data["cam_rig"]

	base_cam_yaw = rad_to_deg(cam_rig.rotation.y)
	base_cam_pitch = rad_to_deg(cam_rig.rotation.x)

	# Initialize move logging subsystem
	if has_node("MoveLogger"):
		move_logger = $MoveLogger
	else:
		move_logger = MoveLogger.new()
		move_logger.name = "MoveLogger"
		add_child(move_logger)

	# Initialize dynamic audio feedback subsystem
	if has_node("AudioFeedback"):
		audio_feedback = $AudioFeedback
	else:
		audio_feedback = AudioFeedback.new()
		audio_feedback.name = "AudioFeedback"
		add_child(audio_feedback)

	# Instantiate cubies and reset session timers
	spawn_cube()
	move_logger.reset_clock()

	# Connect signals from controller manager
	controller_manager.move_requested.connect(execute_move)
	controller_manager.camera_peek_updated.connect(_on_free_look_updated)
	controller_manager.camera_peek_ended.connect(_on_free_look_ended)

	if pause_overlay:
		pause_overlay.visible = false


# Instantiates the 26 cubies in standard 3x3 layout and populates the pieces map
func spawn_cube() -> void:
	for p in pieces.values():
		if is_instance_valid(p):
			p.queue_free()
	pieces.clear()
	pieces = CubeSpawner.spawn(self, PIECE_SCENE)


# Clears the buffer, resets orientation tracking, and respawns the cube in solved state
func reset_cube() -> void:
	move_queue.clear()
	is_animating = false
	orientation_front = Vector3i(0, 0, 1)
	orientation_right = Vector3i(1, 0, 0)

	if cam_rig:
		cam_rig.rotation = Vector3(deg_to_rad(base_cam_pitch), deg_to_rad(base_cam_yaw), 0.0)

	spawn_cube()
	if move_logger:
		move_logger.reset_clock()


# Appends a single move token to the execution buffer
func queue_move(action_id: String) -> void:
	move_queue.append(action_id)
	_process_queue()


# Appends an array of move tokens to the execution buffer
func queue_sequence(actions: Array[String]) -> void:
	move_queue.append_array(actions)
	_process_queue()


# Flushes an entire sequence instantly with zero animation delay
func apply_sequence_instant(actions: Array[String]) -> void:
	for act in actions:
		_record_move(act)
		_apply_move_direct(act)
	if move_logger:
		move_logger.reset_clock()


# Pops and executes buffered moves one-by-one or immediately if speed-of-light is active
func _process_queue() -> void:
	if is_animating or move_queue.is_empty():
		return

	var effective_time: float = turn_duration * anim_multiplier

	# Speed of light mode: bypass tweens and mutate matrices directly in a single frame
	if effective_time <= 0.0001:
		while not move_queue.is_empty():
			var act = move_queue.pop_front()
			_record_move(act)
			_apply_move_direct(act)
		return

	# Animated mode: pop single action and dispatch to appropriate tween function
	var action_id = move_queue.pop_front()
	_record_move(action_id)

	if action_id.begins_with("rot_"):
		_execute_cube_rotation(action_id, effective_time)
	else:
		_execute_face_turn(action_id, effective_time)


# Formats move tokens and writes execution metrics to the logger
func _record_move(action_id: String) -> void:
	if not move_logger:
		return
	var is_cube_rot: bool = action_id.begins_with("rot_")
	var category: String = "cube_rotation" if is_cube_rot else "face_turn"
	var wca_token: String = resolve_wca_notation(action_id)
	move_logger.record_move(action_id, category, wca_token, get_front_color(), get_right_color())


# ------------------------------------------------------------------------------
# Camera Rig Orbit (Free-Look) Handlers
# ------------------------------------------------------------------------------
func _on_free_look_updated(stick_x: float, stick_y: float, delta: float) -> void:
	if is_paused:
		return

	if peek_tween and peek_tween.is_running():
		peek_tween.kill()

	var mult_x = -1.0 if invert_peek_x else 1.0
	var mult_y = -1.0 if invert_peek_y else 1.0

	var current_yaw = rad_to_deg(cam_rig.rotation.y)
	var current_pitch = rad_to_deg(cam_rig.rotation.x)

	current_yaw += stick_x * peek_speed * delta * mult_x
	current_pitch += stick_y * peek_speed * delta * mult_y

	# Enforce hard limits so the camera cannot flip upside down
	current_yaw = clamp(current_yaw, -absolute_yaw_limit, absolute_yaw_limit)
	current_pitch = clamp(current_pitch, -absolute_pitch_limit, absolute_pitch_limit)

	cam_rig.rotation.y = deg_to_rad(current_yaw)
	cam_rig.rotation.x = deg_to_rad(current_pitch)
	cam_rig.rotation.z = 0.0


# Tweens camera back to default isometric viewing perspective upon releasing free-look
func _on_free_look_ended() -> void:
	if peek_tween and peek_tween.is_running():
		peek_tween.kill()

	peek_tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	peek_tween.tween_property(
		cam_rig, 
		"rotation", 
		Vector3(deg_to_rad(base_cam_pitch), deg_to_rad(base_cam_yaw), 0.0), 
		peek_snap_duration
	)


# Toggles visibility of the pause menu overlay and pauses puzzle interaction
func toggle_pause_menu() -> void:
	is_paused = !is_paused
	if pause_overlay:
		pause_overlay.visible = is_paused

	if is_paused and controller_manager.was_peeking:
		_on_free_look_ended()


# ------------------------------------------------------------------------------
# Orientation & WCA Notation Resolution
# ------------------------------------------------------------------------------
# Calculates the current dynamic UP normal via vector cross product: UP = FRONT x RIGHT
func get_orientation_up() -> Vector3i:
	return Vector3i(
		orientation_front.y * orientation_right.z - orientation_front.z * orientation_right.y,
		orientation_front.z * orientation_right.x - orientation_front.x * orientation_right.z,
		orientation_front.x * orientation_right.y - orientation_front.y * orientation_right.x
	)


func get_front_color() -> String:
	return color_scheme.get(orientation_front, "Unknown")


func get_right_color() -> String:
	return color_scheme.get(orientation_right, "Unknown")


func get_up_color() -> String:
	return color_scheme.get(get_orientation_up(), "Unknown")


# Maps screen-relative action strings into standard WCA notation (e.g., "move_r" -> "R" or "F'")
func resolve_wca_notation(action_id: String) -> String:
	var up = get_orientation_up()
	
	match action_id:
		"rot_x": return "x"
		"rot_x_prime": return "x'"
		"rot_y": return "y"
		"rot_y_prime": return "y'"
		"move_m": return "M"
		"move_m_prime": return "M'"
		_: pass

	var screen_axis: Vector3i = Vector3i.ZERO
	var is_prime: bool = action_id.ends_with("_prime")

	if action_id.begins_with("move_r"): screen_axis = Vector3i(1, 0, 0)
	elif action_id.begins_with("move_l"): screen_axis = Vector3i(-1, 0, 0)
	elif action_id.begins_with("move_u"): screen_axis = Vector3i(0, 1, 0)
	elif action_id.begins_with("move_d"): screen_axis = Vector3i(0, -1, 0)
	elif action_id.begins_with("move_f"): screen_axis = Vector3i(0, 0, 1)
	elif action_id.begins_with("move_b"): screen_axis = Vector3i(0, 0, -1)

	var base_letter: String = "?"
	if screen_axis == orientation_front: base_letter = "F"
	elif screen_axis == -orientation_front: base_letter = "B"
	elif screen_axis == orientation_right: base_letter = "R"
	elif screen_axis == -orientation_right: base_letter = "L"
	elif screen_axis == up: base_letter = "U"
	elif screen_axis == -up: base_letter = "D"

	return base_letter + ("'" if is_prime else "")


# ------------------------------------------------------------------------------
# Input Routing
# ------------------------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			toggle_pause_menu()


# Primary entry point for incoming controller manager move actions
func execute_move(action_id: String) -> void:
	if action_id == "start":
		toggle_pause_menu()
		return

	if action_id == "cancel" and is_paused:
		toggle_pause_menu()
		return

	if is_paused:
		return

	queue_move(action_id)


# ------------------------------------------------------------------------------
# Mathematical Slicing & Direct Updates
# ------------------------------------------------------------------------------
# Resolves an action string to its dynamic 3D rotational parameters
func _resolve_turn_params(action_id: String) -> Dictionary:
	var axis: Vector3 = Vector3.ZERO
	var layer_coord: int = 1
	var angle_dir: float = -1.0

	match action_id:
		"move_r":       axis = Vector3.RIGHT; layer_coord =  1; angle_dir = -1.0
		"move_r_prime": axis = Vector3.RIGHT; layer_coord =  1; angle_dir =  1.0
		"move_l":       axis = Vector3.RIGHT; layer_coord = -1; angle_dir =  1.0
		"move_l_prime": axis = Vector3.RIGHT; layer_coord = -1; angle_dir = -1.0
		"move_u":       axis = Vector3.UP;    layer_coord =  1; angle_dir = -1.0
		"move_u_prime": axis = Vector3.UP;    layer_coord =  1; angle_dir =  1.0
		"move_d":       axis = Vector3.UP;    layer_coord = -1; angle_dir =  1.0
		"move_d_prime": axis = Vector3.UP;    layer_coord = -1; angle_dir = -1.0
		"move_f":       axis = Vector3.BACK;  layer_coord =  1; angle_dir = -1.0
		"move_f_prime": axis = Vector3.BACK;  layer_coord =  1; angle_dir =  1.0
		"move_b":       axis = Vector3.BACK;  layer_coord = -1; angle_dir =  1.0
		"move_b_prime": axis = Vector3.BACK;  layer_coord = -1; angle_dir = -1.0
		"move_m":       axis = Vector3.RIGHT; layer_coord =  0; angle_dir =  1.0
		"move_m_prime": axis = Vector3.RIGHT; layer_coord =  0; angle_dir = -1.0
		_: return {}

	return {
		"axis": axis,
		"layer_coord": layer_coord,
		"angle_rad": angle_dir * (PI * 0.5)
	}


# Applies an instantaneous matrix permutation without animation
func _apply_move_direct(action_id: String) -> void:
	if action_id.begins_with("rot_"):
		var global_axis: Vector3
		var angle_dir: float = -1.0
		match action_id:
			"rot_x":       global_axis = Vector3.RIGHT; angle_dir = -1.0
			"rot_x_prime": global_axis = Vector3.RIGHT; angle_dir =  1.0
			"rot_y":       global_axis = Vector3.UP;    angle_dir =  1.0
			"rot_y_prime": global_axis = Vector3.UP;    angle_dir = -1.0
			_: return

		var angle_rad = angle_dir * (PI * 0.5)
		var rot_basis = Basis(global_axis, angle_rad)
		var new_f = rot_basis * Vector3(orientation_front)
		var new_r = rot_basis * Vector3(orientation_right)
		orientation_front = Vector3i(roundi(new_f.x), roundi(new_f.y), roundi(new_f.z))
		orientation_right = Vector3i(roundi(new_r.x), roundi(new_r.y), roundi(new_r.z))

		var new_entries: Dictionary = {}
		for c in pieces.keys():
			var p: Node3D = pieces[c]
			var rotated_pos = rot_basis * Vector3(c)
			var new_coord = Vector3i(roundi(rotated_pos.x), roundi(rotated_pos.y), roundi(rotated_pos.z))
			p.transform.basis = _snap_basis(rot_basis * p.transform.basis)
			p.position = Vector3(new_coord)
			new_entries[new_coord] = p
		pieces = new_entries

	else:
		var params = _resolve_turn_params(action_id)
		if params.is_empty():
			return

		var norm_axis: Vector3 = params["axis"].normalized()
		var int_axis = Vector3i(roundi(norm_axis.x), roundi(norm_axis.y), roundi(norm_axis.z))
		var layer_coord: int = params["layer_coord"]
		var rot_basis = Basis(norm_axis, params["angle_rad"])

		var affected_coords: Array[Vector3i] = []
		for coord in pieces.keys():
			if _coord_on_plane(coord, int_axis, layer_coord):
				affected_coords.append(coord)

		var new_entries: Dictionary = {}
		for c in affected_coords:
			var p: Node3D = pieces[c]
			var rotated_pos = rot_basis * Vector3(c)
			var new_coord = Vector3i(roundi(rotated_pos.x), roundi(rotated_pos.y), roundi(rotated_pos.z))
			p.transform.basis = _snap_basis(rot_basis * p.transform.basis)
			p.position = Vector3(new_coord)
			pieces.erase(c)
			new_entries[new_coord] = p

		for nc in new_entries.keys():
			pieces[nc] = new_entries[nc]


# ------------------------------------------------------------------------------
# Animated Execution (In-Place, Zero Reparenting)
# ------------------------------------------------------------------------------
# Animates a single slice turn using tween_method on cubie transforms directly
func _execute_face_turn(action_id: String, duration: float) -> void:
	var params = _resolve_turn_params(action_id)
	if params.is_empty():
		return

	is_animating = true
	var norm_axis: Vector3 = params["axis"].normalized()
	var int_axis = Vector3i(roundi(norm_axis.x), roundi(norm_axis.y), roundi(norm_axis.z))
	var layer_coord: int = params["layer_coord"]
	var angle_rad: float = params["angle_rad"]
	var slice_pos: Vector3 = norm_axis * float(layer_coord)

	if audio_feedback:
		audio_feedback.play_turn_start(slice_pos, duration, cam_rig)

	# 1. Query the 9 cubies resting on the target plane
	var affected_coords: Array[Vector3i] = []
	for coord in pieces.keys():
		if _coord_on_plane(coord, int_axis, layer_coord):
			affected_coords.append(coord)

	var rot_basis = Basis(norm_axis, angle_rad)
	var start_positions: Dictionary = {}
	var start_bases: Dictionary = {}

	# 2. Snapshot base transforms
	for c in affected_coords:
		var p: Node3D = pieces[c]
		start_positions[c] = p.position
		start_bases[c] = p.transform.basis

	# 3. Animate smoothly in-place without node reparenting
	var tween = create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_method(
		func(t: float):
			var step_rot = Basis(norm_axis, angle_rad * t)
			for c in affected_coords:
				var p: Node3D = pieces[c]
				p.position = step_rot * start_positions[c]
				p.transform.basis = step_rot * start_bases[c],
		0.0,
		1.0,
		duration
	)

	# 4. Snap transforms to integer coordinates on completion
	tween.finished.connect(func():
		var new_entries: Dictionary = {}

		for c in affected_coords:
			var p: Node3D = pieces[c]
			var rotated_pos = rot_basis * Vector3(c)
			var new_coord = Vector3i(roundi(rotated_pos.x), roundi(rotated_pos.y), roundi(rotated_pos.z))

			p.transform.basis = _snap_basis(rot_basis * start_bases[c])
			p.position = Vector3(new_coord)

			pieces.erase(c)
			new_entries[new_coord] = p

		for nc in new_entries.keys():
			pieces[nc] = new_entries[nc]

		if audio_feedback:
			audio_feedback.play_turn_snap(slice_pos, cam_rig)

		is_animating = false
		_process_queue()
	)


# Animates a whole-cube orientation reorientation around screen X or Y axes
func _execute_cube_rotation(action_id: String, duration: float) -> void:
	var global_axis: Vector3
	var angle_dir: float = -1.0
	
	match action_id:
		"rot_x":       global_axis = Vector3.RIGHT; angle_dir = -1.0
		"rot_x_prime": global_axis = Vector3.RIGHT; angle_dir =  1.0
		"rot_y":       global_axis = Vector3.UP;    angle_dir =  1.0
		"rot_y_prime": global_axis = Vector3.UP;    angle_dir = -1.0
		_: return

	var angle_rad = angle_dir * (PI * 0.5)
	is_animating = true

	if audio_feedback:
		audio_feedback.play_cube_rotation(duration)

	var rot_basis = Basis(global_axis, angle_rad)
	var start_positions: Dictionary = {}
	var start_bases: Dictionary = {}

	# Snapshot all pieces
	for c in pieces.keys():
		var p: Node3D = pieces[c]
		start_positions[c] = p.position
		start_bases[c] = p.transform.basis

	# Animate all pieces in-place
	var tween = create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_method(
		func(t: float):
			var step_rot = Basis(global_axis, angle_rad * t)
			for c in pieces.keys():
				var p: Node3D = pieces[c]
				p.position = step_rot * start_positions[c]
				p.transform.basis = step_rot * start_bases[c],
		0.0,
		1.0,
		duration
	)

	# Update dynamic orientation markers and snap pieces to grid on finish
	tween.finished.connect(func():
		var new_f = rot_basis * Vector3(orientation_front)
		var new_r = rot_basis * Vector3(orientation_right)
		orientation_front = Vector3i(roundi(new_f.x), roundi(new_f.y), roundi(new_f.z))
		orientation_right = Vector3i(roundi(new_r.x), roundi(new_r.y), roundi(new_r.z))

		var new_entries: Dictionary = {}
		for c in pieces.keys():
			var p: Node3D = pieces[c]
			var rotated_pos = rot_basis * Vector3(c)
			var new_coord = Vector3i(roundi(rotated_pos.x), roundi(rotated_pos.y), roundi(rotated_pos.z))

			p.transform.basis = _snap_basis(rot_basis * start_bases[c])
			p.position = Vector3(new_coord)
			new_entries[new_coord] = p

		pieces = new_entries
		is_animating = false
		_process_queue()
	)


# Helper: Returns true if a grid coordinate lies on the specified slice plane
func _coord_on_plane(coord: Vector3i, axis: Vector3i, layer: int) -> bool:
	if axis.x != 0: return coord.x == layer * axis.x
	if axis.y != 0: return coord.y == layer * axis.y
	if axis.z != 0: return coord.z == layer * axis.z
	return false


# Helper: Rounds Basis vectors to nearest integer cardinals {-1, 0, 1} to prevent drift
func _snap_basis(b: Basis) -> Basis:
	var x = Vector3(round(b.x.x), round(b.x.y), round(b.x.z))
	var y = Vector3(round(b.y.x), round(b.y.y), round(b.y.z))
	var z = Vector3(round(b.z.x), round(b.z.y), round(b.z.z))
	return Basis(x, y, z).orthonormalized()
