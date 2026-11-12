extends Node
class_name ControllerManager

# ==============================================================================
# CONTROLLER MANAGER
# Responsibilities:
# 1. Translate hardware signals (Keyboard, Gamepad, Mouse) into abstract move tokens.
# 2. Manage dynamic JSON control profile discovery, loading, and cycling.
# 3. Handle camera orbit/peek modes with deadband filtering and motion scaling.
# 4. Debounce analog stick flicks and triggers to prevent double-input spam.
# ==============================================================================

# Fired when any input maps to a recognized cube manipulation or system action
signal move_requested(action_id: String)

# Fired when the active control profile is changed or cycled
signal profile_changed(profile_name: String)

# Camera orbit signals dispatched while free-look is active
signal camera_peek_updated(stick_x: float, stick_y: float, delta: float)
signal camera_peek_ended()

# ------------------------------------------------------------------------------
# Free-Look & Camera State Variables
# ------------------------------------------------------------------------------
# Tracks whether the camera was orbiting on the previous frame
var was_peeking: bool = false

# Tracks whether free-look was initiated via mouse rather than gamepad
var is_mouse_peeking: bool = false

# Timestamp (in milliseconds) when free-look ended, used to debounce stick snaps
var peek_exit_time: int = 0

# Cooldown window to prevent accidental flick execution when releasing camera stick
@export var peek_cooldown_ms: int = 200

# Sensitivity multiplier applied to raw mouse motion deltas during free-look
@export var mouse_peek_sensitivity: float = 0.05

# ------------------------------------------------------------------------------
# Profile Configuration & File Paths
# ------------------------------------------------------------------------------
# Directory where runtime control profile JSON files reside
@export var config_dir_path: String = "res://configs"

# List of absolute file paths to all discovered JSON profiles
var available_profile_paths: Array[String] = []

# Index pointer of the currently active profile in available_profile_paths
var current_profile_index: int = 0

# Human-readable display name of the loaded profile
var current_profile_name: String = ""

# ------------------------------------------------------------------------------
# Hardware Action Lookup Tables
# ------------------------------------------------------------------------------
# Gamepad button index (int) -> move action name (String) in default state
var button_standard_map: Dictionary = {}

# Gamepad button index (int) -> move action name (String) when rotation modifier is held
var button_modified_cube_rot_map: Dictionary = {}

# Keyboard composite key "keycode:location" (String) -> action name (String)
var key_standard_map: Dictionary = {}

# Keyboard composite key "keycode:location" (String) -> action name (String) under modifier
var key_modified_cube_rot_map: Dictionary = {}

# List of directional configurations for analog stick flick actions
var stick_actions: Array[Dictionary] = []   # Elements: {action: String, axis: int, direction: float}

# List of threshold configurations for analog trigger actions
var trigger_actions: Array[Dictionary] = [] # Elements: {action: String, axis: int, threshold: float}

# ------------------------------------------------------------------------------
# Analog Filtering & Hysteresis Thresholds
# ------------------------------------------------------------------------------
# Normalized deflection (0.0 to 1.0) required to register a stick flick
var flick_threshold: float = 0.9

# Return deflection threshold required before a stick axis is allowed to fire again
var reset_threshold: float = 0.2

# Central deadband ignored on analog axes to filter out physical stick drift
var deadzone: float = 0.175

# ------------------------------------------------------------------------------
# Input Runtime State Flags
# ------------------------------------------------------------------------------
# Master switch; if false, all incoming controller signals are ignored
var is_active: bool = true

# The device ID of the primary connected gamepad
var active_joy_id: int = 0

# True if the user is currently holding down the cube-rotation modifier clutch
var modifier_cube_rot_held: bool = false

# Assigned gamepad button index that acts as the cube-rotation modifier clutch (-1 if unbound)
var modifier_button_index: int = -1

# Assigned keyboard keycode that acts as the cube-rotation modifier clutch (-1 if unbound)
var modifier_key_code: int = -1

# Specific physical key location (Left vs Right modifier key, 0 = any)
var modifier_key_location: int = 0

# Gamepad button index assigned to camera peek mode (-1 if unbound)
var camera_peek_joy_index: int = -1

# Mouse button index assigned to camera peek mode (-1 if unbound)
var camera_peek_mouse_button: int = -1

# Debounce state tracker to prevent repeated trigger signals while an axis stays deflected
var axis_latched: Dictionary = {} # Axis unique key (int) -> is_held (bool)


func _ready() -> void:
	# Listen for controller connect/disconnect events to handle OS device ID re-indexing
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	var connected = Input.get_connected_joypads()
	if not connected.is_empty():
		active_joy_id = connected[0]

	scan_and_load_profiles()


# Updates active gamepad ID when devices are plugged in or disconnected
func _on_joy_connection_changed(device: int, connected: bool) -> void:
	if connected:
		active_joy_id = device
		print("[ControllerManager] Joypad connected: %d (%s)" % [device, Input.get_joy_name(device)])
	elif device == active_joy_id:
		var remaining = Input.get_connected_joypads()
		active_joy_id = remaining[0] if not remaining.is_empty() else 0


# Polled every frame to handle analog stick reading for continuous camera orbit
func _process(delta: float) -> void:
	if not is_active or is_mouse_peeking:
		return

	# Evaluate if the player is holding the joypad camera peek button (e.g., L3)
	var is_joy_peeking = (camera_peek_joy_index != -1 and Input.is_joy_button_pressed(active_joy_id, camera_peek_joy_index))

	if is_joy_peeking:
		var right_x = Input.get_joy_axis(active_joy_id, JOY_AXIS_RIGHT_X)
		var right_y = Input.get_joy_axis(active_joy_id, JOY_AXIS_RIGHT_Y)

		# Apply deadband filtering to eliminate thumbstick drift
		if abs(right_x) < deadzone: right_x = 0.0
		if abs(right_y) < deadzone: right_y = 0.0

		camera_peek_updated.emit(right_x, right_y, delta)

		if not was_peeking:
			was_peeking = true
		return
	else:
		# If button was released this frame, notify listeners to tween camera back
		if was_peeking and not is_mouse_peeking:
			was_peeking = false
			peek_exit_time = Time.get_ticks_msec()
			camera_peek_ended.emit()


# Scans config folder for JSON files, sets default profile first, and loads it
func scan_and_load_profiles() -> void:
	available_profile_paths.clear()

	var dir = DirAccess.open(config_dir_path)
	if not dir:
		printerr("[ControllerManager] Could not open directory: ", config_dir_path)
		return

	dir.list_dir_begin()
	var filename = dir.get_next()
	var default_path: String = ""
	var other_paths: Array[String] = []

	while filename != "":
		if not dir.current_is_dir() and filename.begins_with("controls_") and filename.ends_with(".json"):
			var full_path = config_dir_path.path_join(filename)
			if filename == "controls_default.json":
				default_path = full_path
			else:
				other_paths.append(full_path)
		filename = dir.get_next()
	dir.list_dir_end()

	other_paths.sort()
	if default_path != "":
		available_profile_paths.append(default_path)
	available_profile_paths.append_array(other_paths)

	if available_profile_paths.is_empty():
		printerr("[ControllerManager] No 'controls_*.json' profiles found in: ", config_dir_path)
		return

	current_profile_index = 0
	load_profile(available_profile_paths[current_profile_index])


# Reads and parses a JSON profile, updating all internal input action lookup tables
func load_profile(path: String) -> bool:
	if not FileAccess.file_exists(path):
		printerr("[ControllerManager] File not found: ", path)
		return false

	var file = FileAccess.open(path, FileAccess.READ)
	var content = file.get_as_text()
	var json = JSON.new()
	if json.parse(content) != OK:
		printerr("[ControllerManager] JSON parse error: ", json.get_error_message())
		return false

	var data = json.data
	if not data is Dictionary:
		return false

	# Clear previous bindings to avoid lingering mappings from another preset
	button_standard_map.clear()
	button_modified_cube_rot_map.clear()
	key_standard_map.clear()
	key_modified_cube_rot_map.clear()
	stick_actions.clear()
	trigger_actions.clear()
	axis_latched.clear()

	modifier_cube_rot_held = false
	modifier_button_index = -1
	modifier_key_code = -1
	modifier_key_location = 0

	camera_peek_joy_index = -1
	camera_peek_mouse_button = -1

	if is_mouse_peeking:
		is_mouse_peeking = false
		was_peeking = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	# Extract profile metadata
	current_profile_name = data.get("profile_name", data.get("name", path.get_file().get_basename()))

	# Parse analog deadzone and flick engagement thresholds
	var stick_cfg = data.get("stick_settings", {})
	flick_threshold = stick_cfg.get("flick_threshold", 0.65)
	reset_threshold = stick_cfg.get("reset_threshold", 0.20)
	deadzone = stick_cfg.get("deadzone", 0.15)

	# Parse clutch/modifier button definitions
	var mod_cfg = data.get("modifiers", {})
	if mod_cfg.has("rotate_cube_modifier"):
		var r_mod = mod_cfg["rotate_cube_modifier"]
		if r_mod is Dictionary:
			match r_mod.get("type", ""):
				"button":
					modifier_button_index = int(r_mod.get("index", -1))
				"key":
					modifier_key_code = OS.find_keycode_from_string(r_mod.get("name", ""))
					modifier_key_location = int(r_mod.get("location", 0))

	if mod_cfg.has("camera_peek_modifier"):
		var c_mod = mod_cfg["camera_peek_modifier"]
		if c_mod is Dictionary:
			match c_mod.get("type", ""):
				"button":
					camera_peek_joy_index = int(c_mod.get("index", -1))
				"mouse_button":
					camera_peek_mouse_button = int(c_mod.get("index", -1))

	# Populate standard and modifier-clutched action dictionaries
	_parse_action_group(data.get("actions_standard", {}), button_standard_map, key_standard_map)
	_parse_action_group(data.get("actions_modified_cube_rot", {}), button_modified_cube_rot_map, key_modified_cube_rot_map)

	profile_changed.emit(current_profile_name)
	print("[ControllerManager] Loaded: '%s' | Buttons: %d, Keys: %d, Stick/Trig: %d" % [
		current_profile_name,
		button_standard_map.size(),
		key_standard_map.size(),
		stick_actions.size() + trigger_actions.size()
	])
	return true


# Iterates through an action block from JSON and binds entries to internal maps
func _parse_action_group(actions_dict: Dictionary, target_btn_map: Dictionary, target_key_map: Dictionary) -> void:
	for action_name in actions_dict.keys():
		var entry = actions_dict[action_name]
		if not entry is Dictionary:
			continue

		var entry_type = entry.get("type", "")
		match entry_type:
			"button":
				var btn_idx = int(entry.get("index", -1))
				if btn_idx >= 0:
					target_btn_map[btn_idx] = action_name
			"key":
				var code = OS.find_keycode_from_string(entry.get("name", ""))
				var loc = int(entry.get("location", 0))
				if code != KEY_NONE:
					target_key_map["%d:%d" % [code, loc]] = action_name
			"stick":
				stick_actions.append({
					"action": action_name,
					"axis": int(entry.get("axis", -1)),
					"direction": float(entry.get("direction", 1.0))
				})
			"trigger":
				trigger_actions.append({
					"action": action_name,
					"axis": int(entry.get("axis", -1)),
					"threshold": float(entry.get("threshold", 0.5))
				})


# Advances to the next available control profile in circular order
func cycle_profile() -> void:
	if available_profile_paths.size() <= 1:
		return
	current_profile_index = (current_profile_index + 1) % available_profile_paths.size()
	load_profile(available_profile_paths[current_profile_index])


# Dispatches incoming hardware events to actions or camera modes
func _unhandled_input(event: InputEvent) -> void:
	if not is_active:
		return

	# Handle mouse free-look activation and cursor capture
	if event is InputEventMouseButton and camera_peek_mouse_button != -1 and event.button_index == camera_peek_mouse_button:
		is_mouse_peeking = event.pressed
		if is_mouse_peeking:
			was_peeking = true
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		else:
			was_peeking = false
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			peek_exit_time = Time.get_ticks_msec()
			camera_peek_ended.emit()
		get_viewport().set_input_as_handled()
		return

	# Stream mouse motion to camera rig if mouse free-look is engaged
	if event is InputEventMouseMotion and is_mouse_peeking:
		var delta = get_process_delta_time()
		camera_peek_updated.emit(event.relative.x * mouse_peek_sensitivity, event.relative.y * mouse_peek_sensitivity, delta)
		get_viewport().set_input_as_handled()
		return

	# Suppress normal puzzle actions while in camera peek mode
	if was_peeking:
		return

	# --- Keyboard Handling ---
	if event is InputEventKey:
		# Track rotation modifier key press/release (e.g., Left Shift)
		if modifier_key_code != -1 and event.keycode == modifier_key_code:
			if modifier_key_location == 0 or event.location == modifier_key_location:
				modifier_cube_rot_held = event.pressed
				get_viewport().set_input_as_handled()
				return

		# Route discrete key presses (ignoring auto-repeat echo events)
		if event.pressed and not event.echo:
			var specific_key = "%d:%d" % [event.keycode, event.location]
			var generic_key = "%d:0" % event.keycode

			var active_map = key_modified_cube_rot_map if modifier_cube_rot_held else key_standard_map
			var action = active_map.get(specific_key, active_map.get(generic_key, ""))

			if action != "":
				move_requested.emit(action)
				get_viewport().set_input_as_handled()
				return

			# Dedicated fallback: Tab cycles profiles
			if event.keycode == KEY_TAB:
				cycle_profile()
				get_viewport().set_input_as_handled()
				return

	# --- Gamepad Buttons ---
	if event is InputEventJoypadButton:
		active_joy_id = event.device

		# Intercept Start/Options to trigger pause menu
		if (event.button_index == JOY_BUTTON_START or event.button_index == 6) and event.pressed:
			move_requested.emit("start")
			get_viewport().set_input_as_handled()
			return

		# Dedicated profile swap (Home / Guide button)
		if event.button_index == JOY_BUTTON_GUIDE and event.pressed:
			cycle_profile()
			get_viewport().set_input_as_handled()
			return

		# Track clutch modifier press/release
		if event.button_index == modifier_button_index:
			modifier_cube_rot_held = event.pressed
			get_viewport().set_input_as_handled()
			return

		# Route discrete button down event (ignoring button release)
		if event.pressed:
			var map = button_modified_cube_rot_map if modifier_cube_rot_held else button_standard_map
			if map.has(event.button_index):
				move_requested.emit(map[event.button_index])
				get_viewport().set_input_as_handled()
				return

	# --- Gamepad Analog Motion (Sticks & Triggers) ---
	elif event is InputEventJoypadMotion:
		active_joy_id = event.device
		_handle_joypad_motion(event.axis, event.axis_value)


# Evaluates analog stick deflections against flick thresholds and hysteresis gates
func _handle_joypad_motion(axis: int, value: float) -> void:
	# 1. Analog Triggers
	for trig in trigger_actions:
		if trig.axis == axis:
			if value >= trig.threshold:
				if not axis_latched.get(axis, false):
					axis_latched[axis] = true
					move_requested.emit(trig.action)
			elif value < reset_threshold:
				axis_latched[axis] = false
			return

	# 2. Thumbstick Flicks
	for stick in stick_actions:
		if stick.axis == axis:
			var aligned_val = value * stick.direction
			var latch_key = axis * 10 + (1 if stick.direction > 0 else -1)

			if aligned_val >= flick_threshold:
				if not axis_latched.get(latch_key, false):
					axis_latched[latch_key] = true
					
					# Prevent ghost flick registration right after releasing camera look
					if Time.get_ticks_msec() - peek_exit_time >= peek_cooldown_ms:
						move_requested.emit(stick.action)

			elif aligned_val < reset_threshold:
				axis_latched[latch_key] = false
