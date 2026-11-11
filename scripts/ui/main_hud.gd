extends CanvasLayer
class_name MainHUD

@onready var pause_overlay: Control = $PauseOverlay
@onready var top_left: VBoxContainer = $PauseOverlay/MarginContainer/TopLeft
@onready var top_right: VBoxContainer = $PauseOverlay/MarginContainer/TopRight
@onready var bottom_left: VBoxContainer = $PauseOverlay/MarginContainer/BottomLeft
@onready var bottom_right: VBoxContainer = $PauseOverlay/MarginContainer/BottomRight

@export var controller_manager: ControllerManager
@export var mode_manager: ModeManager
@export var cube_root: Node

# Mode Switcher Button (Top Left)
var btn_mode_cycle: Button

# Context Inspector (Bottom Right)
var lbl_desc_title: Label
var lbl_desc_body: Label
var default_desc_title: String = "MODE: LIMITLESS"
var default_desc_body: String = "Free sandbox. Zero timer constraints or penalties. Test moves, experiment with scrambles, and inspect states."

# Sequence Deck References (Bottom Left)
var line_sequence: LineEdit
var slider_scramble_len: HSlider
var input_scramble_seed: LineEdit

# Persistent Speed Multiplier (Top Right)
var slider_speed: HSlider

func _ready() -> void:
	if not cube_root:
		cube_root = get_parent() if get_parent() is CubeRoot else get_tree().root.find_child("CubeRoot", true, false)

	for container in [top_left, top_right, bottom_left, bottom_right]:
		for child in container.get_children():
			container.remove_child(child)
			child.queue_free()

	_build_top_left()
	_build_top_right()
	_build_bottom_right()

	if mode_manager:
		mode_manager.mode_changed.connect(_on_mode_changed)
		var meta = mode_manager.get_current_metadata()
		_on_mode_changed(meta["id"], meta["name"], meta.get("options", []))

	if controller_manager:
		controller_manager.move_requested.connect(_on_controller_action)
		controller_manager.profile_changed.connect(_on_profile_changed)

	if cube_root and slider_speed:
		slider_speed.value = cube_root.anim_multiplier
		# Triggers value_changed to sync the label

	_bind_descriptions_recursive(pause_overlay)
	
	var mat = ShaderMaterial.new()
	var shader = Shader.new()
	shader.code = """
	shader_type canvas_item;
	void fragment() {
		float dist = distance(UV, vec2(0.5, 0.5));
		COLOR = vec4(0.0, 0.0, 0.0, smoothstep(0.2, 0.55, dist) * 0.85);
	}
	"""
	mat.shader = shader
	pause_overlay.material = mat
	pause_overlay.visible = false

func _input(event: InputEvent) -> void:
	if not pause_overlay.visible:
		return

	if event is InputEventJoypadButton and event.pressed and not event.is_echo():
		if event.button_index == JOY_BUTTON_A:
			_click_focused_button()
			get_viewport().set_input_as_handled()
		elif event.button_index == JOY_BUTTON_B:
			_close_menu()
			get_viewport().set_input_as_handled()

func toggle_pause() -> void:
	pause_overlay.visible = not pause_overlay.visible
	if pause_overlay.visible:
		_reset_description()
		if top_left.get_child_count() > 0:
			var first_btn = top_left.get_child(0) as Control
			if first_btn:
				first_btn.grab_focus()
	else:
		var focused = get_viewport().gui_get_focus_owner()
		if focused:
			focused.release_focus()

func _close_menu() -> void:
	if controller_manager:
		controller_manager.move_requested.emit("start")
	else:
		_on_controller_action("start")

func _on_resume_pressed() -> void:
	_close_menu()

func _on_controller_action(action_id: String) -> void:
	if action_id == "start":
		toggle_pause()
	elif action_id == "cancel" and pause_overlay.visible:
		_close_menu()
	elif action_id in ["accept", "confirm", "select", "cross", "a", "primary"] and pause_overlay.visible:
		_click_focused_button()

func _click_focused_button() -> void:
	var focused = get_viewport().gui_get_focus_owner()
	if focused is Button:
		focused.pressed.emit()

# ==============================================================================
# CONTEXT INSPECTOR (BOTTOM RIGHT)
# ==============================================================================
func _build_bottom_right() -> void:
	bottom_right.custom_minimum_size = Vector2(280, 120)

	lbl_desc_title = Label.new()
	lbl_desc_title.text = default_desc_title
	lbl_desc_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bottom_right.add_child(lbl_desc_title)

	var sep = HSeparator.new()
	bottom_right.add_child(sep)

	lbl_desc_body = Label.new()
	lbl_desc_body.text = default_desc_body
	lbl_desc_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl_desc_body.modulate = Color(0.85, 0.85, 0.85, 1.0)
	bottom_right.add_child(lbl_desc_body)

func set_description(title: String, body: String) -> void:
	if lbl_desc_title:
		lbl_desc_title.text = title.to_upper()
	if lbl_desc_body:
		lbl_desc_body.text = body

func _reset_description() -> void:
	set_description(default_desc_title, default_desc_body)

func _bind_descriptions_recursive(node: Node) -> void:
	if node is Control and node.has_meta("desc_title"):
		if not node.get_meta("_desc_bound", false):
			node.set_meta("_desc_bound", true)
			var t = str(node.get_meta("desc_title"))
			var b = str(node.get_meta("desc_body", ""))
			node.mouse_entered.connect(func(): set_description(t, b))
			node.mouse_exited.connect(_reset_description)
			node.focus_entered.connect(func(): set_description(t, b))
			node.focus_exited.connect(_reset_description)

	for child in node.get_children():
		_bind_descriptions_recursive(child)

# ==============================================================================
# TOP CONTAINERS
# ==============================================================================
func _build_top_left() -> void:
	var btn_resume = Button.new()
	btn_resume.text = "Resume"
	btn_resume.set_meta("desc_title", "Resume")
	btn_resume.set_meta("desc_body", "Exit the pause menu and return immediately to cube manipulation.")
	btn_resume.pressed.connect(_on_resume_pressed)
	top_left.add_child(btn_resume)

	var btn_reset = Button.new()
	btn_reset.text = "Reset Cube"
	btn_reset.set_meta("desc_title", "Reset Cube")
	btn_reset.set_meta("desc_body", "Instantly resets pieces to their solved coordinates and clears history.")
	btn_reset.pressed.connect(func():
		if not cube_root:
			cube_root = get_parent() if get_parent() is CubeRoot else get_tree().root.find_child("CubeRoot", true, false)
		if cube_root and cube_root.has_method("reset_cube"):
			cube_root.reset_cube()
	)
	top_left.add_child(btn_reset)

	btn_mode_cycle = Button.new()
	btn_mode_cycle.text = "Mode: Limitless"
	btn_mode_cycle.set_meta("desc_title", "Cycle Game Mode")
	btn_mode_cycle.set_meta("desc_body", "Switch between training modes (Limitless, Crossle, F2L, OLL, PLL).")
	btn_mode_cycle.pressed.connect(func():
		if mode_manager:
			mode_manager.cycle_mode(1)
	)
	top_left.add_child(btn_mode_cycle)

func _build_top_right() -> void:
	top_right.custom_minimum_size = Vector2(260, 0)

	var btn_cycle_profile = Button.new()
	btn_cycle_profile.text = "Swap Input Scheme"
	btn_cycle_profile.set_meta("desc_title", "Input Scheme")
	btn_cycle_profile.set_meta("desc_body", "Cycle through discovered controls_*.json input mapping profiles.")
	btn_cycle_profile.pressed.connect(func():
		if controller_manager:
			controller_manager.cycle_profile()
	)
	top_right.add_child(btn_cycle_profile)

	# Turn Duration Multiplier Row (0.0x - 5.0x)
	var row_speed = HBoxContainer.new()
	row_speed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_right.add_child(row_speed)

	var base_dur: float = cube_root.turn_duration if cube_root else 0.25
	var lbl_speed = Label.new()
	lbl_speed.text = "Mult: 1.00x (%d ms)" % roundi(base_dur * 1000.0)
	lbl_speed.custom_minimum_size.x = 145
	row_speed.add_child(lbl_speed)

	slider_speed = HSlider.new()
	slider_speed.min_value = 0.0
	slider_speed.max_value = 5.0
	slider_speed.step = 0.25
	slider_speed.value = 1.0
	slider_speed.custom_minimum_size.x = 100
	slider_speed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider_speed.set_meta("desc_title", "Turn Duration Multiplier")
	slider_speed.set_meta("desc_body", "Scales turn animation time (0.0x to 5.0x in 0.25 steps). At 0.0x, moves flush instantly in 0 ms.")
	slider_speed.value_changed.connect(func(v: float):
		var cur_base = cube_root.turn_duration if cube_root else 0.25
		var ms = roundi(v * cur_base * 1000.0)
		lbl_speed.text = "Mult: %.2fx (%d ms)" % [v, ms]
		if cube_root:
			cube_root.anim_multiplier = v
	)
	row_speed.add_child(slider_speed)

	var btn_invert_y = Button.new()
	btn_invert_y.text = "Invert Y: OFF"
	btn_invert_y.set_meta("desc_title", "Invert Look Y")
	btn_invert_y.set_meta("desc_body", "Inverts camera pitch motion when holding the camera peek modifier.")
	btn_invert_y.pressed.connect(func():
		var turning_on = (btn_invert_y.text == "Invert Y: OFF")
		btn_invert_y.text = "Invert Y: ON" if turning_on else "Invert Y: OFF"
		if cube_root:
			cube_root.invert_peek_y = turning_on
	)
	top_right.add_child(btn_invert_y)

	var btn_fullscreen = Button.new()
	btn_fullscreen.text = "Fullscreen"
	btn_fullscreen.set_meta("desc_title", "Toggle Display")
	btn_fullscreen.set_meta("desc_body", "Switches between borderless fullscreen and windowed desktop display.")
	btn_fullscreen.pressed.connect(func():
		var is_full = DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
		DisplayServer.window_set_mode(
			DisplayServer.WINDOW_MODE_WINDOWED if is_full else DisplayServer.WINDOW_MODE_FULLSCREEN
		)
	)
	top_right.add_child(btn_fullscreen)

	var btn_quit = Button.new()
	btn_quit.text = "Quit"
	btn_quit.set_meta("desc_title", "Quit Application")
	btn_quit.set_meta("desc_body", "Immediately exit to desktop.")
	btn_quit.pressed.connect(func():
		get_tree().quit()
	)
	top_right.add_child(btn_quit)

# ==============================================================================
# MODE-SPECIFIC BUILDER (BOTTOM LEFT)
# ==============================================================================
func _on_mode_changed(_id: String, display_name: String, options: Array) -> void:
	if btn_mode_cycle:
		btn_mode_cycle.text = "Mode: %s" % display_name

	default_desc_title = "MODE: %s" % display_name
	_reset_description()

	for child in bottom_left.get_children():
		bottom_left.remove_child(child)
		child.queue_free()

	bottom_left.custom_minimum_size = Vector2(340, 0)

	var meta = mode_manager.get_current_metadata() if mode_manager else {}
	var modules: Array = meta.get("modules", [])

	if modules.is_empty():
		_build_generic_mode_deck(display_name, options)
	else:
		for mod in modules:
			match mod:
				"move_counter":
					_mount_move_counter()
				"sequence_deck":
					_mount_sequence_deck()

	_bind_descriptions_recursive(bottom_left)

func _mount_move_counter() -> void:
	var row = HBoxContainer.new()
	bottom_left.add_child(row)

	var btn_count = Button.new()
	btn_count.text = "Start Count"
	btn_count.set_meta("desc_title", "Start Move Count")
	btn_count.set_meta("desc_body", "Arms solve counter. Tally begins on first turn.")
	row.add_child(btn_count)

	var chk_rot = CheckBox.new()
	chk_rot.text = "+ Rotations"
	chk_rot.set_meta("desc_title", "Count Rotations")
	chk_rot.set_meta("desc_body", "Include whole-cube rotations (x, y) toward move count.")
	row.add_child(chk_rot)

	var lbl = Label.new()
	lbl.text = "Moves: 0"
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(lbl)

func _mount_sequence_deck() -> void:
	var row_cfg = HBoxContainer.new()
	bottom_left.add_child(row_cfg)

	var lbl_len = Label.new()
	lbl_len.text = "Len: 20"
	row_cfg.add_child(lbl_len)

	slider_scramble_len = HSlider.new()
	slider_scramble_len.min_value = 5
	slider_scramble_len.max_value = 30
	slider_scramble_len.step = 1
	slider_scramble_len.value = 20
	slider_scramble_len.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider_scramble_len.set_meta("desc_title", "Scramble Length")
	slider_scramble_len.set_meta("desc_body", "Number of moves to generate (5 to 30, standard is 20).")
	slider_scramble_len.value_changed.connect(func(v: float):
		lbl_len.text = "Len: %d" % int(v)
	)
	row_cfg.add_child(slider_scramble_len)

	input_scramble_seed = LineEdit.new()
	input_scramble_seed.placeholder_text = "Seed (opt)"
	input_scramble_seed.max_length = 16
	input_scramble_seed.custom_minimum_size.x = 90
	input_scramble_seed.set_meta("desc_title", "Random Seed")
	input_scramble_seed.set_meta("desc_body", "Deterministic seed for reproducible scrambles. Leave blank for random.")
	row_cfg.add_child(input_scramble_seed)

	line_sequence = LineEdit.new()
	line_sequence.placeholder_text = "Paste or generate algorithm..."
	line_sequence.max_length = 160
	line_sequence.clear_button_enabled = true
	line_sequence.set_meta("desc_title", "Move Sequence")
	line_sequence.set_meta("desc_body", "Staged moves in standard notation.")
	bottom_left.add_child(line_sequence)

	var row_actions = HBoxContainer.new()
	bottom_left.add_child(row_actions)

	var btn_gen = Button.new()
	btn_gen.text = "Generate"
	btn_gen.set_meta("desc_title", "Generate Scramble")
	btn_gen.set_meta("desc_body", "Rolls a valid WCA sequence using the specified length and seed.")
	btn_gen.pressed.connect(func():
		var length = int(slider_scramble_len.value)
		var seed_val = input_scramble_seed.text
		line_sequence.text = ScrambleGenerator.generate(length, seed_val)
	)
	row_actions.add_child(btn_gen)

	var btn_copy = Button.new()
	btn_copy.text = "Copy"
	btn_copy.set_meta("desc_title", "Copy Sequence")
	btn_copy.set_meta("desc_body", "Copy current move sequence to system clipboard.")
	btn_copy.pressed.connect(func():
		if not line_sequence.text.is_empty():
			DisplayServer.clipboard_set(line_sequence.text)
	)
	row_actions.add_child(btn_copy)

	var btn_paste = Button.new()
	btn_paste.text = "Paste"
	btn_paste.set_meta("desc_title", "Paste Sequence")
	btn_paste.set_meta("desc_body", "Paste text from system clipboard into the sequence box.")
	btn_paste.pressed.connect(func():
		line_sequence.text = DisplayServer.clipboard_get()
	)
	row_actions.add_child(btn_paste)

	var btn_clear = Button.new()
	btn_clear.text = "Clear"
	btn_clear.set_meta("desc_title", "Clear Sequence")
	btn_clear.set_meta("desc_body", "Wipes the current staged move sequence.")
	btn_clear.pressed.connect(func():
		line_sequence.text = ""
	)
	row_actions.add_child(btn_clear)

	var btn_apply = Button.new()
	btn_apply.text = "Apply"
	btn_apply.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_apply.set_meta("desc_title", "Apply Moves")
	btn_apply.set_meta("desc_body", "Pushes staged sequence into the move buffer.")
	btn_apply.pressed.connect(_on_apply_moves_pressed)
	row_actions.add_child(btn_apply)

func _on_apply_moves_pressed() -> void:
	if not line_sequence or line_sequence.text.is_empty() or not cube_root:
		return

	var actions = NotationParser.parse(line_sequence.text)
	if cube_root.has_method("queue_sequence"):
		cube_root.queue_sequence(actions)
	else:
		for act in actions:
			cube_root.execute_move(act)

func _build_generic_mode_deck(display_name: String, options: Array) -> void:
	for opt in options:
		var btn = Button.new()
		btn.text = opt.get("label", "Option")
		btn.set_meta("desc_title", opt.get("label", "Option"))
		btn.set_meta("desc_body", opt.get("description", "Mode specific action."))
		var opt_id = opt.get("id", "")
		btn.pressed.connect(func():
			print("[Mode Option Clicked] Mode: %s | ID: %s" % [display_name, opt_id])
		)
		bottom_left.add_child(btn)

func _on_profile_changed(_new_name: String) -> void:
	pass
