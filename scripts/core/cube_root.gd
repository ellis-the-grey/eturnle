extends Node3D
class_name CubeRoot

# ==============================================================================
# CUBE ROOT (SPINE)
# Core Responsibilities:
# 1. Piece spatial registry & lifecycle
# 2. View-relative coordinate orientation frame
# 3. Kinematic slice tweens and whole-cube pivots
# ==============================================================================

const PIECE_SCENE: PackedScene = preload("res://scenes/core/piece.tscn")

var pieces: Dictionary = {}
var is_animating: bool = false
@export var turn_duration: float = 0.25

# View-relative orientation frame
var orientation_front: Vector3i = Vector3i(0, 0, 1)
var orientation_right: Vector3i = Vector3i(1, 0, 0)

@onready var controller_manager: ControllerManager = $ControllerManager
var move_logger: MoveLogger

func _ready() -> void:
	CubeEnvironment.setup(self)

	# Fetch existing child node or create instance dynamically
	if has_node("MoveLogger"):
		move_logger = $MoveLogger
	else:
		move_logger = MoveLogger.new()
		move_logger.name = "MoveLogger"
		add_child(move_logger)

	spawn_cube()
	move_logger.reset_clock()
	controller_manager.move_requested.connect(execute_move)

func spawn_cube() -> void:
	for p in pieces.values():
		if is_instance_valid(p):
			p.queue_free()
	pieces.clear()
	pieces = CubeSpawner.spawn(self, PIECE_SCENE)

# ==============================================================================
# INPUT ROUTING & EXECUTION
# ==============================================================================
func _unhandled_input(event: InputEvent) -> void:
	if is_animating:
		return
	
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_R: execute_move("move_r_prime" if event.shift_pressed else "move_r")
			KEY_L: execute_move("move_l_prime" if event.shift_pressed else "move_l")
			KEY_U: execute_move("move_u_prime" if event.shift_pressed else "move_u")
			KEY_D: execute_move("move_d_prime" if event.shift_pressed else "move_d")
			KEY_F: execute_move("move_f_prime" if event.shift_pressed else "move_f")
			KEY_B: execute_move("move_b_prime" if event.shift_pressed else "move_b")
			KEY_M: execute_move("move_m_prime" if event.shift_pressed else "move_m")
			KEY_X: execute_move("rot_x_prime" if event.shift_pressed else "rot_x")
			KEY_Y: execute_move("rot_y_prime" if event.shift_pressed else "rot_y")

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

	move_logger.record_move(action_id, category, orientation_front, orientation_right)

# ==============================================================================
# SLICE ROTATION & GRID REMAPPING
# ==============================================================================
func _execute_face_turn(action_id: String) -> void:
	var up = get_orientation_up()
	var axis: Vector3
	var layer_coord: int = 1
	var angle_dir: float = -1.0

	match action_id:
		"move_r":       axis = Vector3(orientation_right); layer_coord =  1; angle_dir = -1.0
		"move_r_prime": axis = Vector3(orientation_right); layer_coord =  1; angle_dir =  1.0
		"move_l":       axis = Vector3(orientation_right); layer_coord = -1; angle_dir =  1.0
		"move_l_prime": axis = Vector3(orientation_right); layer_coord = -1; angle_dir = -1.0
		"move_u":       axis = Vector3(up);                layer_coord =  1; angle_dir = -1.0
		"move_u_prime": axis = Vector3(up);                layer_coord =  1; angle_dir =  1.0
		"move_d":       axis = Vector3(up);                layer_coord = -1; angle_dir =  1.0
		"move_d_prime": axis = Vector3(up);                layer_coord = -1; angle_dir = -1.0
		"move_f":       axis = Vector3(orientation_front); layer_coord =  1; angle_dir = -1.0
		"move_f_prime": axis = Vector3(orientation_front); layer_coord =  1; angle_dir =  1.0
		"move_b":       axis = Vector3(orientation_front); layer_coord = -1; angle_dir =  1.0
		"move_b_prime": axis = Vector3(orientation_front); layer_coord = -1; angle_dir = -1.0
		"move_m":       axis = Vector3(orientation_right); layer_coord =  0; angle_dir =  1.0
		"move_m_prime": axis = Vector3(orientation_right); layer_coord =  0; angle_dir = -1.0
		_: return

	_rotate_slice(axis, layer_coord, angle_dir * (PI * 0.5))

func _rotate_slice(axis: Vector3, layer_coord: int, angle_rad: float) -> void:
	is_animating = true
	var norm_axis = axis.normalized()
	var int_axis = Vector3i(round(norm_axis.x), round(norm_axis.y), round(norm_axis.z))

	var affected_coords: Array[Vector3i] = []
	for coord in pieces.keys():
		if _coord_on_plane(coord, int_axis, layer_coord):
			affected_coords.append(coord)

	var pivot = Node3D.new()
	add_child(pivot)

	for c in affected_coords:
		pieces[c].reparent(pivot)

	var tween = create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(pivot, "transform", pivot.transform.rotated(norm_axis, angle_rad), turn_duration)

	tween.finished.connect(func():
		var rot_basis = Basis(norm_axis, angle_rad)
		var new_entries: Dictionary = {}

		for c in affected_coords:
			var p: Node3D = pieces[c]
			p.reparent(self)

			var rotated_pos = rot_basis * Vector3(c)
			var new_coord = Vector3i(round(rotated_pos.x), round(rotated_pos.y), round(rotated_pos.z))

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
	if axis.x != 0: return coord.x == layer * axis.x
	if axis.y != 0: return coord.y == layer * axis.y
	if axis.z != 0: return coord.z == layer * axis.z
	return false

# ==============================================================================
# FULL CUBE ROTATIONS
# ==============================================================================
func _execute_cube_rotation(action_id: String) -> void:
	var global_axis: Vector3
	var angle_dir: float = -1.0
	
	match action_id:
		"rot_x":       global_axis = Vector3.RIGHT; angle_dir = -1.0
		"rot_x_prime": global_axis = Vector3.RIGHT; angle_dir =  1.0
		"rot_y":       global_axis = Vector3.UP;    angle_dir = -1.0
		"rot_y_prime": global_axis = Vector3.UP;    angle_dir =  1.0
		_: return

	var angle_rad = angle_dir * (PI * 0.5)
	var rot_basis = Basis(global_axis, angle_rad)

	var new_f = rot_basis * Vector3(orientation_front)
	var new_r = rot_basis * Vector3(orientation_right)
	orientation_front = Vector3i(roundi(new_f.x), roundi(new_f.y), roundi(new_f.z))
	orientation_right = Vector3i(roundi(new_r.x), roundi(new_r.y), roundi(new_r.z))
	
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
	)
