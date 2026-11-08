extends Node3D

const PIECE_SCENE = preload("res://scenes/piece.tscn")

var pieces: Dictionary = {} # Vector3i -> Node3D
var is_animating: bool = false

# Peek / Inspection Rig
var cam_rig: Node3D
var camera: Camera3D
var is_peeking: bool = false
var target_peek: Vector2 = Vector2.ZERO
var current_peek: Vector2 = Vector2.ZERO

const MAX_PEEK_ANGLE: float = deg_to_rad(75.0) # Maximum peek range (+/-75 deg)
const PEEK_SPEED: float = 14.0                 # Return-to-center spring speed
const MOUSE_SENSITIVITY: float = 0.006

# ==============================================================================
# DEBUG UI & METRICS
# ==============================================================================
var move_count: int = 0
var move_history: Array[String] = []

var move_count_label: Label
var orientation_label: Label
var history_label: Label
var sequence_input: LineEdit

# ==============================================================================
# ETHAN'S CONTROLLER & KEYBOARD BINDINGS
# ==============================================================================
var gamepad_bindings: Dictionary = {
	JOY_BUTTON_RIGHT_SHOULDER: "R",
	JOY_BUTTON_LEFT_SHOULDER:  "L",
	JOY_BUTTON_Y:              "U",
	JOY_BUTTON_A:              "D",
	JOY_BUTTON_B:              "B",
	JOY_BUTTON_X:              "F",
	JOY_BUTTON_DPAD_UP:        "M'",
	JOY_BUTTON_DPAD_DOWN:      "M",
}

var key_bindings: Dictionary = {
	KEY_U: "U", KEY_D: "D", KEY_R: "R",
	KEY_L: "L", KEY_F: "F", KEY_B: "B",
	KEY_M: "M",
	KEY_X: "x", KEY_Y: "y", KEY_Z: "z",
}

# ==============================================================================
# LIFECYCLE & INPUT
# ==============================================================================
func _ready() -> void:
	setup_viewport_camera_and_light()
	spawn_cube()
	setup_debug_ui()

func _process(delta: float) -> void:
	# 1. Analog Joystick Peek (Right or Left stick)
	var stick = Vector2(
		Input.get_joy_axis(0, JOY_AXIS_RIGHT_X),
		Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y)
	)
	if stick.length() < 0.15:
		stick = Vector2(
			Input.get_joy_axis(0, JOY_AXIS_LEFT_X),
			Input.get_joy_axis(0, JOY_AXIS_LEFT_Y)
		)

	if stick.length() > 0.15:
		target_peek.x = clamp(-stick.x * MAX_PEEK_ANGLE, -MAX_PEEK_ANGLE, MAX_PEEK_ANGLE)
		target_peek.y = clamp(-stick.y * MAX_PEEK_ANGLE, -MAX_PEEK_ANGLE, MAX_PEEK_ANGLE)
	elif not is_peeking:
		target_peek = target_peek.move_toward(Vector2.ZERO, delta * PEEK_SPEED * 0.5)

	# 2. Smoothly damp peek toward target
	current_peek = current_peek.lerp(target_peek, delta * PEEK_SPEED)
	
	if cam_rig:
		cam_rig.rotation.y = deg_to_rad(28.0) + current_peek.x
		cam_rig.rotation.x = deg_to_rad(-24.0) + current_peek.y
		
	update_orientation_ui()

func _input(event: InputEvent) -> void:
	if sequence_input and sequence_input.has_focus():
		return

	# Mouse Peek: hold Left or Right click to tilt; release to spring back
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT or event.button_index == MOUSE_BUTTON_RIGHT:
			is_peeking = event.pressed
			if not is_peeking:
				target_peek = Vector2.ZERO

	elif event is InputEventMouseMotion and is_peeking:
		target_peek.x = clamp(target_peek.x - event.relative.x * MOUSE_SENSITIVITY, -MAX_PEEK_ANGLE, MAX_PEEK_ANGLE)
		target_peek.y = clamp(target_peek.y - event.relative.y * MOUSE_SENSITIVITY, -MAX_PEEK_ANGLE, MAX_PEEK_ANGLE)

func _unhandled_input(event: InputEvent) -> void:
	if is_animating:
		return

	# Arrow keys trigger counted x and y whole-cube rotations
	if event is InputEventKey and event.is_pressed() and not event.is_echo():
		match event.keycode:
			KEY_LEFT:
				execute_move("y'")
				return
			KEY_RIGHT:
				execute_move("y")
				return
			KEY_UP:
				execute_move("x")
				return
			KEY_DOWN:
				execute_move("x'")
				return

		if key_bindings.has(event.keycode):
			var move: String = key_bindings[event.keycode]
			if event.shift_pressed:
				move += "'"
			execute_move(move)

	elif event is InputEventJoypadButton and event.is_pressed():
		# 1. R2 Held: D-Pad acts like Arrow Keys for counted whole-cube x/y turns
		if Input.get_joy_axis(event.device, JOY_AXIS_TRIGGER_RIGHT) > 0.5:
			match event.button_index:
				JOY_BUTTON_DPAD_LEFT:
					execute_move("y'")
					return
				JOY_BUTTON_DPAD_RIGHT:
					execute_move("y")
					return
				JOY_BUTTON_DPAD_UP:
					execute_move("x")
					return
				JOY_BUTTON_DPAD_DOWN:
					execute_move("x'")
					return

		# 2. Standard layer turns (L2 held turns it into a Prime move)
		var btn = event.button_index
		if gamepad_bindings.has(btn):
			var move: String = gamepad_bindings[btn]
			if Input.get_joy_axis(event.device, JOY_AXIS_TRIGGER_LEFT) > 0.5 and not move.ends_with("'"):
				move += "'"
			execute_move(move)

# ==============================================================================
# MOVE EXECUTION & ROTATION LOGIC
# ==============================================================================
func execute_move(move_str: String) -> void:
	if is_animating or move_str.is_empty():
		return
		
	var raw_char = move_str.left(1)
	var face_char = raw_char.to_upper()
	var modifier = move_str.substr(1)
	
	var axes = get_view_relative_axes()
	
	# Whole-cube rotations (x, y, z)
	if face_char in ["X", "Y", "Z"]:
		move_count += 1
		move_history.append(face_char.to_lower() + modifier)
		update_history_ui()
		
		var rot_axis: Vector3 = Vector3.ZERO
		if face_char == "X":
			rot_axis = Vector3(axes["R"]).normalized()
		elif face_char == "Y":
			rot_axis = Vector3(axes["U"]).normalized()
		elif face_char == "Z":
			rot_axis = Vector3(axes["F"]).normalized()
			
		var angle_rad: float = -PI / 2.0
		if modifier == "'":
			angle_rad = PI / 2.0
		elif modifier == "2":
			angle_rad = PI
			
		rotate_entire_cube(rot_axis, angle_rad)
		return

	if not axes.has(face_char):
		return
		
	# Outer and slice layer moves
	move_count += 1
	move_history.append(move_str)
	update_history_ui()

	var normal: Vector3i = axes[face_char]
	var slice_index: int = 1
	var angle_rad: float = -PI / 2.0

	if face_char == "M":
		normal = axes["R"]
		slice_index = 0
		angle_rad = PI / 2.0
	
	if modifier == "'":
		angle_rad = -angle_rad
	elif modifier == "2":
		angle_rad = PI
		
	rotate_layer(normal, slice_index, angle_rad)

func rotate_layer(normal: Vector3i, slice_index: int, angle_rad: float) -> void:
	is_animating = true
	
	var layer_pieces: Array[Node3D] = []
	for grid_pos in pieces.keys():
		if int(Vector3(grid_pos).dot(Vector3(normal))) == slice_index:
			layer_pieces.append(pieces[grid_pos])
	
	if layer_pieces.is_empty():
		is_animating = false
		return
		
	var pivot = Node3D.new()
	add_child(pivot)
	for p in layer_pieces:
		p.reparent(pivot)
		
	var rot_axis = Vector3(normal).normalized()
	var tween = create_tween()
	tween.tween_property(pivot, "transform", pivot.transform.rotated(rot_axis, angle_rad), 0.15)\
		.set_trans(Tween.TRANS_QUAD)\
		.set_ease(Tween.EASE_OUT)
	
	await tween.finished
	
	for p in layer_pieces:
		p.reparent(self)
		p.position = Vector3(round(p.position.x), round(p.position.y), round(p.position.z))
		p.transform.basis = p.transform.basis.orthonormalized()
	
	pivot.queue_free()
	_rebuild_piece_index()
	is_animating = false

func rotate_entire_cube(axis: Vector3, angle_rad: float) -> void:
	is_animating = true
	
	var pivot = Node3D.new()
	add_child(pivot)
	for p in pieces.values():
		p.reparent(pivot)
		
	var tween = create_tween()
	tween.tween_property(pivot, "transform", pivot.transform.rotated(axis, angle_rad), 0.18)\
		.set_trans(Tween.TRANS_QUAD)\
		.set_ease(Tween.EASE_OUT)
	
	await tween.finished
	
	for p in pieces.values():
		p.reparent(self)
		p.position = Vector3(round(p.position.x), round(p.position.y), round(p.position.z))
		p.transform.basis = p.transform.basis.orthonormalized()
		
	pivot.queue_free()
	_rebuild_piece_index()
	is_animating = false

func _rebuild_piece_index() -> void:
	pieces.clear()
	for p in get_tree().get_nodes_in_group("pieces"):
		var grid_pos = Vector3i(
			round(p.position.x),
			round(p.position.y),
			round(p.position.z)
		)
		pieces[grid_pos] = p

# ==============================================================================
# VIEW-RELATIVE ORIENTATION
# ==============================================================================
func get_view_relative_axes() -> Dictionary:
	var cam_forward: Vector3 = Vector3(-0.4, -0.4, -0.82).normalized()
	var cam_up: Vector3 = Vector3(-0.2, 0.9, -0.4).normalized()
	
	var directions = [
		Vector3i.UP, Vector3i.DOWN,
		Vector3i.FORWARD, Vector3i.BACK,
		Vector3i.RIGHT, Vector3i.LEFT
	]
	
	var best_f = Vector3i.ZERO
	var max_f_dot = -999.0
	for d in directions:
		var d_dot = Vector3(d).dot(-cam_forward)
		if d_dot > max_f_dot:
			max_f_dot = d_dot
			best_f = d
			
	var best_u = Vector3i.ZERO
	var max_u_dot = -999.0
	for d in directions:
		if d == best_f or d == -best_f:
			continue
		var d_dot = Vector3(d).dot(cam_up)
		if d_dot > max_u_dot:
			max_u_dot = d_dot
			best_u = d
			
	var right_vec = Vector3(best_u).cross(Vector3(best_f))
	var best_r = Vector3i(round(right_vec.x), round(right_vec.y), round(right_vec.z))
	
	return {
		"F": best_f,
		"B": -best_f,
		"U": best_u,
		"D": -best_u,
		"R": best_r,
		"L": -best_r,
		"M": best_r
	}

# ==============================================================================
# DEBUG UI SYSTEM
# ==============================================================================
func setup_debug_ui() -> void:
	var canvas = CanvasLayer.new()
	add_child(canvas)
	
	var panel = PanelContainer.new()
	panel.position = Vector2(16, 16)
	panel.custom_minimum_size = Vector2(300, 0)
	canvas.add_child(panel)
	
	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	margin.add_theme_constant_override("margin_right", 10)
	panel.add_child(margin)
	
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)
	
	# 1. Orientation Readout
	orientation_label = Label.new()
	orientation_label.add_theme_font_size_override("font_size", 14)
	vbox.add_child(orientation_label)
	
	# 2. Move Counter
	move_count_label = Label.new()
	move_count_label.text = "Moves: 0"
	move_count_label.add_theme_font_size_override("font_size", 16)
	vbox.add_child(move_count_label)
	
	# 3. Move History Log
	history_label = Label.new()
	history_label.text = "History: [None]"
	history_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	history_label.custom_minimum_size = Vector2(280, 44)
	history_label.add_theme_font_size_override("font_size", 12)
	history_label.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
	vbox.add_child(history_label)
	
	# 4. Paste/Write Sequence Input
	var seq_row = HBoxContainer.new()
	sequence_input = LineEdit.new()
	sequence_input.placeholder_text = "e.g. R U R' U' or x y2"
	sequence_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sequence_input.text_submitted.connect(func(_t): run_sequence_from_input())
	seq_row.add_child(sequence_input)
	
	var run_btn = Button.new()
	run_btn.text = "Run"
	run_btn.pressed.connect(run_sequence_from_input)
	seq_row.add_child(run_btn)
	vbox.add_child(seq_row)
	
	# 5. Scramble & Reset Buttons
	var btn_row = HBoxContainer.new()
	
	var scramble_btn = Button.new()
	scramble_btn.text = "Scramble"
	scramble_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scramble_btn.pressed.connect(scramble_cube)
	btn_row.add_child(scramble_btn)
	
	var reset_btn = Button.new()
	reset_btn.text = "Reset Cube"
	reset_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reset_btn.pressed.connect(reset_cube)
	btn_row.add_child(reset_btn)
	
	vbox.add_child(btn_row)
	update_orientation_ui()

func update_orientation_ui() -> void:
	if not orientation_label:
		return
	var axes = get_view_relative_axes()
	var f_color = get_color_name_for_normal(axes["F"])
	var u_color = get_color_name_for_normal(axes["U"])
	var r_color = get_color_name_for_normal(axes["R"])
	orientation_label.text = "Front: %s | Up: %s | Right: %s" % [f_color, u_color, r_color]

func update_history_ui() -> void:
	if move_count_label:
		move_count_label.text = "Moves: %d" % move_count
	if history_label:
		var display_str = " ".join(move_history)
		if display_str.is_empty():
			history_label.text = "History: [None]"
		else:
			history_label.text = "History: " + display_str

func get_color_name_for_normal(norm: Vector3i) -> String:
	match norm:
		Vector3i(0, 1, 0):  return "Yellow"
		Vector3i(0, -1, 0): return "White"
		Vector3i(0, 0, 1):  return "Green"
		Vector3i(0, 0, -1): return "Blue"
		Vector3i(1, 0, 0):  return "Orange"
		Vector3i(-1, 0, 0): return "Red"
		_:                  return "?"

# ==============================================================================
# RESET, SEQUENCE & SCRAMBLE
# ==============================================================================
func reset_cube() -> void:
	if is_animating:
		return
	
	for p in pieces.values():
		p.queue_free()
	pieces.clear()
	
	move_count = 0
	move_history.clear()
	update_history_ui()
	
	spawn_cube()

func run_sequence_from_input() -> void:
	if sequence_input:
		var raw_text = sequence_input.text.strip_edges()
		if not raw_text.is_empty():
			sequence_input.text = ""
			execute_sequence(raw_text)

func execute_sequence(seq: String) -> void:
	var tokens = seq.split(" ", false)
	for move in tokens:
		while is_animating:
			await get_tree().process_frame
		execute_move(move)

func scramble_cube() -> void:
	if is_animating:
		return
	var possible_faces = ["U", "D", "R", "L", "F", "B"]
	var modifiers = ["", "'", "2"]
	var scramble_moves: Array[String] = []
	var last_face = ""
	
	for i in range(20):
		var face = possible_faces.pick_random()
		while face == last_face:
			face = possible_faces.pick_random()
		last_face = face
		var mod = modifiers.pick_random()
		scramble_moves.append(face + mod)
		
	execute_sequence(" ".join(scramble_moves))

# ==============================================================================
# SPAWN & VIEWPORT SETUP
# ==============================================================================
func spawn_cube() -> void:
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
	var face = piece.find_child(face_name, true, false)
	if face:
		face.visible = show_face

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
	key_light.look_at(Vector3.ZERO, Vector3.UP)
	key_light.light_energy = 0.95
	key_light.shadow_enabled = true
	add_child(key_light)

	var fill_light = DirectionalLight3D.new()
	fill_light.position = Vector3(-5.0, -3.0, -4.0)
	fill_light.look_at(Vector3.ZERO, Vector3.UP)
	fill_light.light_energy = 0.4
	fill_light.shadow_enabled = false
	add_child(fill_light)

	var env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.11, 0.11, 0.13)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.85, 0.85, 0.9)
	env.ambient_light_energy = 0.22

	var world_env = WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)
