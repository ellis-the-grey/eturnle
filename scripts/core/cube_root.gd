extends Node3D

# ==============================================================================
# SKELETON: CUBE ROOT (SPINE)
# Responsibilities:
# 1. Environment initialization (Camera, Lights, Background)
# 2. Procedural spawning of 26 cubies around a (0,0,0) core
# 3. Piece spatial registry management via Vector3i grid coordinates
# 4. Input router hook (stubbed for external controller manager)
# ==============================================================================

# Preload the individual piece scene
const PIECE_SCENE: PackedScene = preload("res://scenes/core/piece.tscn")

# Lookup table: Vector3i grid position (-1 to 1 per axis) -> Node3D piece instance
var pieces: Dictionary = {}

# Animation lock: prevents concurrent rotation execution
var is_animating: bool = false

# Viewport rigging
var cam_rig: Node3D
var camera: Camera3D

# ==============================================================================
# LIFECYCLE
# ==============================================================================
func _ready() -> void:
	# Step 1: Construct the 3D viewing environment
	setup_viewport_camera_and_light()
	
	# Step 2: Instantiate and position pieces in 3D grid space
	spawn_cube()

func _process(_delta: float) -> void:
	# Reserved for active timer/animation tick updates in future steps
	pass

# ==============================================================================
# INPUT ROUTING (PLACEHOLDER)
# ==============================================================================
func _unhandled_input(event: InputEvent) -> void:
	# Guard: Discard all input signals while a slice tween is resolving
	if is_animating:
		return
	
	# PLACEHOLDER: Route controller/keyboard signals to execute_move()
	# This hook will interface directly with controls_default.json / controller_manager
	handle_raw_input(event)

func handle_raw_input(_event: InputEvent) -> void:
	# STUB: To be implemented in next step (reading mapped JSON actions)
	pass

func execute_move(move_str: String) -> void:
	# STUB: To be populated with view-relative rotation logic (rotate_layer / rotate_entire_cube)
	print("Move requested: ", move_str)

# ==============================================================================
# PROCEDURAL GENERATION & POSITIONING
# ==============================================================================
func spawn_cube() -> void:
	# Clean up any residual pieces before spawning fresh
	for p in pieces.values():
		if is_instance_valid(p):
			p.queue_free()
	pieces.clear()

	# Iterate across 3D integer lattice: x ∈ [-1, 1], y ∈ [-1, 1], z ∈ [-1, 1]
	for x in range(-1, 2):
		for y in range(-1, 2):
			for z in range(-1, 2):
				# Skip the internal hidden core piece (0, 0, 0)
				if x == 0 and y == 0 and z == 0:
					continue
				
				var grid_pos = Vector3i(x, y, z)
				var piece: Node3D = PIECE_SCENE.instantiate()
				
				# Tag piece into the tree and group
				piece.add_to_group("pieces")
				add_child(piece)
				
				# Align world position directly to initial integer coordinates
				piece.position = Vector3(grid_pos)
				
				# Configure sticker mesh visibility according to outer boundary normals
				update_stickers(piece, grid_pos)
				
				# Register piece in coordinate lookup table
				pieces[grid_pos] = piece

func update_stickers(piece: Node3D, pos: Vector3i) -> void:
	# Only outer-facing planes are visible; internal faces remain masked
	_set_face_vis(piece, "Face_Yellow", pos.y == 1)   # Top (+Y)
	_set_face_vis(piece, "Face_White",  pos.y == -1)  # Bottom (-Y)
	_set_face_vis(piece, "Face_Green",  pos.z == 1)   # Front (+Z)
	_set_face_vis(piece, "Face_Blue",   pos.z == -1)  # Back (-Z)
	_set_face_vis(piece, "Face_Orange", pos.x == 1)   # Right (+X)
	_set_face_vis(piece, "Face_Red",    pos.x == -1)  # Left (-X)

func _set_face_vis(piece: Node3D, face_name: String, show_face: bool) -> void:
	var face: Node = piece.find_child(face_name, true, false)
	if face and face is Node3D:
		(face as Node3D).visible = show_face

# ==============================================================================
# ENVIRONMENT & RENDERING SETUP
# ==============================================================================
func setup_viewport_camera_and_light() -> void:
	# 1. Camera Mount & Orientation
	cam_rig = Node3D.new()
	cam_rig.name = "CamRig"
	add_child(cam_rig)

	camera = Camera3D.new()
	camera.name = "Camera3D"
	camera.position = Vector3(0.0, 0.0, 4.8)
	camera.current = true
	cam_rig.add_child(camera)

	# Isometric default view angle (displays U, F, R faces simultaneously)
	cam_rig.rotation.y = deg_to_rad(28.0)
	cam_rig.rotation.x = deg_to_rad(-24.0)

	# 2. Key Light (Primary highlights and directional shadows)
	var key_light = DirectionalLight3D.new()
	key_light.position = Vector3(5.0, 7.0, 4.0)
	key_light.light_energy = 0.95
	key_light.shadow_enabled = true
	add_child(key_light)
	key_light.look_at(Vector3.ZERO, Vector3.UP)

	# 3. Fill Light (Softens opposite side shadow contrast)
	var fill_light = DirectionalLight3D.new()
	fill_light.position = Vector3(-5.0, -3.0, -4.0)
	fill_light.light_energy = 0.4
	fill_light.shadow_enabled = false
	add_child(fill_light)
	fill_light.look_at(Vector3.ZERO, Vector3.UP)

	# 4. Environment Background & Ambient Shading
	var env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.11, 0.11, 0.13)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.85, 0.85, 0.9)
	env.ambient_light_energy = 0.22

	var world_env = WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)
