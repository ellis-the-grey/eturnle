extends Node
class_name ControllerManager

signal move_requested(action_id: String)
signal profile_changed(profile_name: String)

@export var config_dir_path: String = "res://configs"

var available_profile_paths: Array[String] = []
var current_profile_index: int = 0
var current_profile_name: String = ""

# Parsed mappings: int (button_index) -> String (action_id)
var button_standard_map: Dictionary = {}
var button_modified_cube_rot_map: Dictionary = {}

# Stick & Trigger configs
var stick_actions: Array[Dictionary] = []   # Array of {action, axis, direction}
var trigger_actions: Array[Dictionary] = [] # Array of {action, axis, threshold}

# Thresholds
var flick_threshold: float = 0.65
var reset_threshold: float = 0.20
var deadzone: float = 0.15

# State tracking
var is_active: bool = true
var modifier_cube_rot_held: bool = false
var modifier_button_index: int = -1

# Prevents multiple triggers while an axis is held past threshold
var axis_latched: Dictionary = {} # int (axis) -> bool

func _ready() -> void:
	scan_and_load_profiles()

# ==============================================================================
# PROFILE DISCOVERY & LOADING
# ==============================================================================
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

	# Reset maps
	button_standard_map.clear()
	button_modified_cube_rot_map.clear()
	stick_actions.clear()
	trigger_actions.clear()
	axis_latched.clear()

	# 1. Profile metadata
	current_profile_name = data.get("profile_name", data.get("name", path.get_file().get_basename()))

	# 2. Stick settings
	var stick_cfg = data.get("stick_settings", {})
	flick_threshold = stick_cfg.get("flick_threshold", 0.65)
	reset_threshold = stick_cfg.get("reset_threshold", 0.20)
	deadzone = stick_cfg.get("deadzone", 0.15)

	# 3. Modifiers
	var mod_cfg = data.get("modifiers", {})
	if mod_cfg.has("rotate_cube_modifier"):
		modifier_button_index = int(mod_cfg["rotate_cube_modifier"].get("index", -1))
	else:
		modifier_button_index = -1

	# 4. Standard Actions
	var std_cfg = data.get("actions_standard", {})
	_parse_action_group(std_cfg, button_standard_map)

	# 5. Modified Cube Rot Actions
	var rot_cfg = data.get("actions_modified_cube_rot", {})
	_parse_action_group(rot_cfg, button_modified_cube_rot_map)

	profile_changed.emit(current_profile_name)
	print("[ControllerManager] Loaded: '%s' | %d buttons, %d stick/triggers" % [
		current_profile_name,
		button_standard_map.size(),
		stick_actions.size() + trigger_actions.size()
	])
	return true

func _parse_action_group(actions_dict: Dictionary, target_btn_map: Dictionary) -> void:
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

func cycle_profile() -> void:
	if available_profile_paths.size() <= 1:
		return
	current_profile_index = (current_profile_index + 1) % available_profile_paths.size()
	load_profile(available_profile_paths[current_profile_index])

# ==============================================================================
# INPUT PROCESSING
# ==============================================================================
func _unhandled_input(event: InputEvent) -> void:
	if not is_active:
		return

	# --- Joypad Buttons ---
	if event is InputEventJoypadButton:
		# Dedicated profile swap (Home / Guide)
		if event.button_index == JOY_BUTTON_GUIDE and event.pressed:
			cycle_profile()
			get_viewport().set_input_as_handled()
			return

		# Modifier Hold State Tracking
		if event.button_index == modifier_button_index:
			modifier_cube_rot_held = event.pressed
			get_viewport().set_input_as_handled()
			return

		# Action Dispatch
		if event.pressed:
			# Check modifier layer first if held
			if modifier_cube_rot_held and button_modified_cube_rot_map.has(event.button_index):
				move_requested.emit(button_modified_cube_rot_map[event.button_index])
				get_viewport().set_input_as_handled()
				return

			if button_standard_map.has(event.button_index):
				move_requested.emit(button_standard_map[event.button_index])
				get_viewport().set_input_as_handled()
				return

	# --- Joypad Motion (Sticks & Analog Triggers) ---
	elif event is InputEventJoypadMotion:
		_handle_joypad_motion(event.axis, event.axis_value)

	# --- Keyboard Fallback ---
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_TAB:
			cycle_profile()
			get_viewport().set_input_as_handled()

func _handle_joypad_motion(axis: int, value: float) -> void:
	# 1. Triggers
	for trig in trigger_actions:
		if trig.axis == axis:
			if value >= trig.threshold:
				if not axis_latched.get(axis, false):
					axis_latched[axis] = true
					move_requested.emit(trig.action)
			elif value < reset_threshold:
				axis_latched[axis] = false
			return

	# 2. Sticks (Flick Detection)
	for stick in stick_actions:
		if stick.axis == axis:
			var aligned_val = value * stick.direction
			var latch_key = axis * 10 + (1 if stick.direction > 0 else -1)

			if aligned_val >= flick_threshold:
				if not axis_latched.get(latch_key, false):
					axis_latched[latch_key] = true
					move_requested.emit(stick.action)
			elif aligned_val < reset_threshold:
				axis_latched[latch_key] = false
