extends Node3D

# ==============================================================================
# CUBE ROOT (SPINE)
# Responsibilities:
# 1. Environment initialization (Camera, Lights, Background)
# 2. Procedural spawning of 26 cubies around a (0,0,0) core
# 3. Piece spatial registry management via Vector3i grid coordinates
# 4. View-relative move execution and physical slice rotation tweening
# 5. Master move recording track (timestamped notation & orientation)
# ==============================================================================

const PIECE_SCENE: PackedScene = preload("res://scenes/core/piece.tscn")

# Lookup table: Vector3i grid position (-1 to 1 per axis) -> Node3D piece instance
var pieces: Dictionary = {}

# Animation lock & turn speed
var is_animating: bool = false
@export var turn_duration: float = 0.25

# Telemetry & Master Move Log
var move_log: Array[Dictionary] = []
var session_start_ms: int = 0
var last_move_ms: int = 0

# View-relative orientation frame
# Initial: Front (+Z / Green), Right (+X / Orange), Up (+Y / Yellow)
var orientation_front: Vector3i = Vector3i(0, 0, 1)
var orientation_right: Vector3i = Vector3i(1, 0, 0)

# Viewport rigging
var cam_rig: Node3D
var camera: Camera3D

# ==============================================================================
# LIFECYCLE
# ==============================================================================
@onready var controller_manager: ControllerManager = $ControllerManager

func _ready() -> void:
	setup_viewport_camera_and_light()
	spawn_cube()
	reset_telemetry_clock()
	
	# Pipe controller manager actions directly into the move executor
	controller_manager.move_requested.connect(execute_move)

func reset_telemetry_clock() -> void:
	session_start_ms = Time.get_ticks_msec()
	last_move_ms = session_start_ms
	move_log.clear()

# ==============================================================================
# INPUT ROUTING & MOVE EXECUTION
# ==============================================================================
func _unhandled_input(event: InputEvent) -> void:
	if is_animating:
		return
	
	# Temporary debug keys to test execution and logging immediately
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_R:
				execute_move("move_r_prime" if event.shift_pressed else "move_r")
			KEY_L:
				execute_move("move_l_prime" if event.shift_pressed else "move_l")
			KEY_U:
				execute_move("move_u_prime" if event.shift_pressed else "move_u")
			KEY_D:
				execute_move("move_d_prime" if event.shift_pressed else "move_d")
			KEY_F:
				execute_move("move_f_prime" if event.shift_pressed else "move_f")
			KEY_B:
				execute_move("move_b_prime" if event.shift_pressed else "move_b")
			KEY_M:
				execute_move("move_m_prime" if event.shift_pressed else "move_m")
			KEY_X:
				execute_move("rot_x_prime" if event.shift_pressed else "rot_x")
			KEY_Y:
				execute_move("rot_y_prime" if event.shift_pressed else "rot_y")

func get_orientation_up() -> Vector3i:
	return Vector3i(
		orientation_front.y * orientation_right.z - orientation_front.z * orientation_right.y,
		orientation_front.z * orientation_right.x - orientation_front.x * orientation_right.z,
		orientation_front.x * orientation_right.y - orientation_front.y * orientation_right.x
	)

func execute_move(action_id: String) -> void:
	if is_animating:
		return

	var is_cube_rot: bool = action_id.begins_with("rot_")
	var category: String = "cube_rotation" if is_cube_rot else "face_turn"

	if is_cube_rot:
		_execute_cube_rotation(action_id)
	else:
		_execute_face_turn(action_id)

	_record_move(action_id, category)

func _record_move(token: String, category: String) -> void:
	var now = Time.get_ticks_msec()
	var elapsed = now - session_start_ms
	var delta = now - last_move_ms
	last_move_ms = now

	var record = {
		"move": token,
		"category": category,
		"timestamp_ms": elapsed,
		"delta_ms": delta,
		"orientation_front": orientation_front,
		"orientation_right": orientation_right
	}
	move_log.append(record)
	print("[MOVE LOG] #%d: %s (split: %dms, total: %dms)" % [move_log.size(), token, delta, elapsed])

# ==============================================================================
# SLICE ROTATION & GRID REMAPPING
# ==============================================================================
func _execute_face_turn(action_id: String) -> void:
	var up = get_orientation_up()
	var axis: Vector3
	var layer_coord: int = 1
	var angle_dir: float = -1.0 # Default clockwise when looking at outer face

	match action_id:
		"move_r":
			axis = Vector3(orientation_right); layer_coord = 1; angle_dir = -1.0
		"move_r_prime":
			axis = Vector3(orientation_right); layer_coord = 1; angle_dir = 1.0
		"move_l":
			axis = Vector3(orientation_right); layer_coord = -1; angle_dir = 1.0
		"move_l_prime":
			axis = Vector3(orientation_right); layer_coord = -1; angle_dir = -1.0
		"move_u":
			axis = Vector3(up); layer_coord = 1; angle_dir = -1.0
		"move_u_prime":
			axis = Vector3(up); layer_coord = 1; angle_dir = 1.0
		"move_d":
			axis = Vector3(up); layer_coord = -1; angle_dir = 1.0
		"move_d_prime":
			axis = Vector3(up); layer_coord = -1; angle_dir = -1.0
		"move_f":
			axis = Vector3(orientation_front); layer_coord = 1; angle_dir = -1.0
		"move_f_prime":
			axis = Vector3(orientation_front); layer_coord = 1; angle_dir = 1.0
		"move_b":
			axis = Vector3(orientation_front); layer_coord = -1; angle_dir = 1.0
		"move_b_prime":
			axis = Vector3(orientation_front); layer_coord = -1; angle_dir = -1.0
		"move_m":
			axis = Vector3(orientation_right); layer_coord = 0; angle_dir = 1.0
		"move_m_prime":
			axis = Vector3(orientation_right); layer_coord = 0; angle_dir = -1.0
		_:
			return

	_rotate_slice(axis, layer_coord, angle_dir * (PI * 0.5))

func _rotate_slice(axis: Vector3, layer_coord: int, angle_rad: float) -> void:
	is_animating = true
	var norm_axis = axis.normalized()
	var int_axis = Vector3i(round(norm_axis.x), round(norm_axis.y), round(norm_axis.z))

	# Gather the 9 pieces in this plane
	var affected_coords: Array[Vector3i] = []
	for coord in pieces.keys():
		if _coord_on_plane(coord, int_axis, layer_coord):
			affected_coords.append(coord)

	# Temporary pivot for clean grouped rotation
	var pivot = Node3D.new()
	add_child(pivot)

	for c in affected_coords:
		var p: Node3D = pieces[c]
		p.reparent(pivot)

	var tween = create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(pivot, "transform", pivot.transform.rotated(norm_axis, angle_rad), turn_duration)

	tween.finished.connect(func():
		var rot_basis = Basis(norm_axis, angle_rad)
		var new_entries: Dictionary = {}

		for c in affected_coords:
			var p: Node3D = pieces[c]
			p.reparent(self)

			# Compute new grid coordinates using rotated vector rounded to nearest integer
			var rotated_pos = rot_basis * Vector3(c)
			var new_coord = Vector3i(round(rotated_pos.x), round(rotated_pos.y), round(rotated_pos.z))

			# Orthonormalize piece transform to eliminate floating point precision drift
			p.transform = p.transform.orthonormalized()
			p.position = Vector3(new_coord)

			pieces.erase(c)
			new_entries[new_coord] = p

		for nc in new_entries.keys():
			pieces[nc] = new_entries[nc]

		pivot.queue_free()
		is_animating = false
	)

func _coord_on_plane(coord: Vector3i, axis: Vector3i, layer: int) -> bool:
	if axis.x != 0:
		return coord.x == layer * axis.x
	if axis.y != 0:
		return coord.y == layer * axis.y
	if axis.z != 0:
		return coord.z == layer * axis.z
	return false

# ==============================================================================
# FULL CUBE ROTATIONS
# ==============================================================================
# ==============================================================================
# FULL CUBE ROTATIONS
# ==============================================================================
func _execute_cube_rotation(action_id: String) -> void:
	var global_axis: Vector3
	var angle_dir: float = -1.0
	
	match action_id:
		"rot_x":
			global_axis = Vector3.RIGHT; angle_dir = -1.0
		"rot_x_prime":
			global_axis = Vector3.RIGHT; angle_dir = 1.0
		"rot_y":
			global_axis = Vector3.UP; angle_dir = -1.0
		"rot_y_prime":
			global_axis = Vector3.UP; angle_dir = 1.0
		_:
			return

	var angle_rad = angle_dir * (PI * 0.5)
	var rot_basis = Basis(global_axis, angle_rad)

	# Update tracked internal orientation frame
	var new_f = rot_basis * Vector3(orientation_front)
	var new_r = rot_basis * Vector3(orientation_right)
	orientation_front = Vector3i(roundi(new_f.x), roundi(new_f.y), roundi(new_f.z))
	orientation_right = Vector3i(roundi(new_r.x), roundi(new_r.y), roundi(new_r.z))
	
	# Reparent and animate all 26 pieces around the global axis
	is_animating = true
	var pivot = Node3D.new()
	add_child(pivot)

	for p in pieces.values():
		p.reparent(pivot)

	var tween = create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(pivot, "transform", pivot.transform.rotated(global_axis, angle_rad), turn_duration)

	tween.finished.connect(func():
		var new_entries: Dictionary = {}
		for c in pieces.keys():
			var p: Node3D = pieces[c]
			p.reparent(self)

			var rotated_pos = rot_basis * Vector3(c)
			var new_coord = Vector3i(roundi(rotated_pos.x), roundi(rotated_pos.y), roundi(rotated_pos.z))

			p.transform = p.transform.orthonormalized()
			p.position = Vector3(new_coord)
			new_entries[new_coord] = p

		pieces = new_entries
		pivot.queue_free()
		is_animating = false
		
		print("[ORIENTATION] Front: ", orientation_front, " | Right: ", orientation_right, " | Up: ", get_orientation_up())
	)

# ==============================================================================
# PROCEDURAL GENERATION & POSITIONING
# ==============================================================================
func spawn_cube() -> void:
	for p in pieces.values():
		if is_instance_valid(p):
			p.queue_free()
	pieces.clear()

	for x in range(-1, 2):
		for y in range(-1, 2):
			for z in range(-1, 2):
				if x == 0 and y == 0 and z == 0:
					continue
				
				var grid_pos = Vector3i(x, y, z)
				var piece: Node3D = PIECE_SCENE.instantiate()
				piece.add_to_group("pieces")
				add_child(piece)
				piece.position = Vector3(grid_pos)
				update_stickers(piece, grid_pos)
				pieces[grid_pos] = piece

func update_stickers(piece: Node3D, pos: Vector3i) -> void:
	_set_face_vis(piece, "Face_Yellow", pos.y == 1)
	_set_face_vis(piece, "Face_White",  pos.y == -1)
	_set_face_vis(piece, "Face_Green",  pos.z == 1)
	_set_face_vis(piece, "Face_Blue",   pos.z == -1)
	_set_face_vis(piece, "Face_Orange", pos.x == 1)
	_set_face_vis(piece, "Face_Red",    pos.x == -1)

func _set_face_vis(piece: Node3D, face_name: String, show_face: bool) -> void:
	var face: Node = piece.find_child(face_name, true, false)
	if face and face is Node3D:
		(face as Node3D).visible = show_face

# ==============================================================================
# ENVIRONMENT SETUP
# ==============================================================================
func setup_viewport_camera_and_light() -> void:
	cam_rig = Node3D.new()
	cam_rig.name = "CamRig"
	add_child(cam_rig)

	camera = Camera3D.new()
	camera.name = "Camera3D"
	camera.position = Vector3(0.0, 0.0, 4.8)
	camera.current = true
	cam_rig.add_child(camera)

	cam_rig.rotation.y = deg_to_rad(28.0)
	cam_rig.rotation.x = deg_to_rad(-24.0)

	var key_light = DirectionalLight3D.new()
	key_light.position = Vector3(5.0, 7.0, 4.0)
	key_light.light_energy = 0.95
	key_light.shadow_enabled = true
	add_child(key_light)
	key_light.look_at(Vector3.ZERO, Vector3.UP)

	var fill_light = DirectionalLight3D.new()
	fill_light.position = Vector3(-5.0, -3.0, -4.0)
	fill_light.light_energy = 0.4
	fill_light.shadow_enabled = false
	add_child(fill_light)
	fill_light.look_at(Vector3.ZERO, Vector3.UP)

	var env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.11, 0.11, 0.13)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.85, 0.85, 0.9)
	env.ambient_light_energy = 0.22

	var world_env = WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)
