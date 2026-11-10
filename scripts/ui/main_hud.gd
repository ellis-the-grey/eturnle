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

# Debug Labels (Bottom Right)
var lbl_fps: Label
var lbl_mode: Label
var lbl_profile: Label
var lbl_device: Label

# Mode Switcher Button (Top Left)
var btn_mode_cycle: Button

func _ready() -> void:
	# Clear out editor test labels
	for container in [top_left, top_right, bottom_left, bottom_right]:
		for child in container.get_children():
			container.remove_child(child)
			child.queue_free()

	_build_top_left()
	_build_top_right()
	_build_bottom_right()

	# Connect external systems
	if mode_manager:
		mode_manager.mode_changed.connect(_on_mode_changed)
		var meta = mode_manager.get_current_metadata()
		_on_mode_changed(meta["id"], meta["name"], meta["options"])

	if controller_manager:
		controller_manager.move_requested.connect(_on_controller_action)
		controller_manager.profile_changed.connect(_on_profile_changed)
		if lbl_profile:
			lbl_profile.text = "Profile: %s" % controller_manager.current_profile_name

	_rebuild_focus_graph()

	# Start with the pause overlay hidden
	pause_overlay.visible = false

func _process(_delta: float) -> void:
	if lbl_fps and pause_overlay.visible:
		lbl_fps.text = "FPS: %d" % Engine.get_frames_per_second()

func _input(event: InputEvent) -> void:
	if not pause_overlay.visible:
		return

	# Hardware-level joypad intercept for menu navigation
	if event is InputEventJoypadButton and event.pressed and not event.is_echo():
		if event.button_index == JOY_BUTTON_A:
			_click_focused_button()
			get_viewport().set_input_as_handled()
		elif event.button_index == JOY_BUTTON_B:
			toggle_pause()
			get_viewport().set_input_as_handled()

func toggle_pause() -> void:
	pause_overlay.visible = not pause_overlay.visible
	if pause_overlay.visible:
		if top_left.get_child_count() > 0:
			var first_btn = top_left.get_child(0) as Control
			if first_btn:
				first_btn.grab_focus()

func _on_resume_pressed() -> void:
	if controller_manager:
		controller_manager.move_requested.emit("start")
	else:
		_on_controller_action("start")

func _on_controller_action(action_id: String) -> void:
	if action_id == "start":
		toggle_pause()
	elif action_id == "cancel" and pause_overlay.visible:
		toggle_pause()
	elif action_id in ["accept", "confirm", "select", "cross", "a", "primary"] and pause_overlay.visible:
		_click_focused_button()

func _click_focused_button() -> void:
	var focused = get_viewport().gui_get_focus_owner()
	if focused is Button:
		focused.pressed.emit()

# ==============================================================================
# CONTAINER BUILDERS
# ==============================================================================
func _build_top_left() -> void:
	var btn_resume = Button.new()
	btn_resume.text = "Resume"
	btn_resume.pressed.connect(_on_resume_pressed)
	top_left.add_child(btn_resume)

	var btn_reset = Button.new()
	btn_reset.text = "Reset Cube"
	btn_reset.pressed.connect(func():
		if cube_root and cube_root.has_method("reset_cube"):
			cube_root.reset_cube()
	)
	top_left.add_child(btn_reset)

	btn_mode_cycle = Button.new()
	btn_mode_cycle.text = "Mode: Limitless"
	btn_mode_cycle.pressed.connect(func():
		if mode_manager:
			mode_manager.cycle_mode(1)
	)
	top_left.add_child(btn_mode_cycle)

func _build_top_right() -> void:
	var btn_cycle_profile = Button.new()
	btn_cycle_profile.text = "Swap Input Scheme"
	btn_cycle_profile.pressed.connect(func():
		if controller_manager:
			controller_manager.cycle_profile()
	)
	top_right.add_child(btn_cycle_profile)

	var btn_invert_y = Button.new()
	btn_invert_y.text = "Invert Y: OFF"
	btn_invert_y.pressed.connect(func():
		btn_invert_y.text = "Invert Y: ON" if btn_invert_y.text == "Invert Y: OFF" else "Invert Y: OFF"
	)
	top_right.add_child(btn_invert_y)

	var btn_fullscreen = Button.new()
	btn_fullscreen.text = "Fullscreen"
	btn_fullscreen.pressed.connect(func():
		var is_full = DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
		DisplayServer.window_set_mode(
			DisplayServer.WINDOW_MODE_WINDOWED if is_full else DisplayServer.WINDOW_MODE_FULLSCREEN
		)
	)
	top_right.add_child(btn_fullscreen)

	var btn_quit = Button.new()
	btn_quit.text = "Quit"
	btn_quit.pressed.connect(func():
		get_tree().quit()
	)
	top_right.add_child(btn_quit)

func _build_bottom_right() -> void:
	lbl_fps = Label.new()
	lbl_fps.text = "FPS: 60"
	bottom_right.add_child(lbl_fps)

	lbl_mode = Label.new()
	lbl_mode.text = "Mode: Limitless"
	bottom_right.add_child(lbl_mode)

	lbl_profile = Label.new()
	lbl_profile.text = "Profile: -"
	bottom_right.add_child(lbl_profile)

	lbl_device = Label.new()
	lbl_device.text = "Device: Joypad/Keyboard"
	bottom_right.add_child(lbl_device)

# ==============================================================================
# MODE-SPECIFIC BUILDER (Bottom Left)
# ==============================================================================
func _on_mode_changed(_id: String, display_name: String, options: Array) -> void:
	if btn_mode_cycle:
		btn_mode_cycle.text = "Mode: %s" % display_name
	if lbl_mode:
		lbl_mode.text = "Mode: %s" % display_name

	for child in bottom_left.get_children():
		bottom_left.remove_child(child)
		child.queue_free()

	for opt in options:
		var btn = Button.new()
		btn.text = opt.get("label", "Option")
		var opt_id = opt.get("id", "")
		btn.pressed.connect(func():
			print("[Mode Option Clicked] Mode: %s | ID: %s" % [display_name, opt_id])
		)
		bottom_left.add_child(btn)

	_rebuild_focus_graph()

func _on_profile_changed(new_name: String) -> void:
	if lbl_profile:
		lbl_profile.text = "Profile: %s" % new_name

# ==============================================================================
# FOCUS NAVIGATION GRAPH
# ==============================================================================
func _rebuild_focus_graph() -> void:
	var tl_buttons: Array[Node] = top_left.get_children().filter(func(c): return c is Button)
	var tr_buttons: Array[Node] = top_right.get_children().filter(func(c): return c is Button)
	var bl_buttons: Array[Node] = bottom_left.get_children().filter(func(c): return c is Button)

	# 1. TopLeft <--> TopRight horizontal cross-overs
	for i in range(tl_buttons.size()):
		var target_idx = mini(i, tr_buttons.size() - 1)
		if target_idx >= 0:
			(tl_buttons[i] as Button).focus_neighbor_right = tr_buttons[target_idx].get_path()

	for i in range(tr_buttons.size()):
		var target_idx = mini(i, tl_buttons.size() - 1)
		if target_idx >= 0:
			(tr_buttons[i] as Button).focus_neighbor_left = tl_buttons[target_idx].get_path()

	# 2. TopLeft bottom button <--> BottomLeft top button vertical handoff
	if tl_buttons.size() > 0 and bl_buttons.size() > 0:
		var last_tl = tl_buttons[-1] as Button
		var first_bl = bl_buttons[0] as Button

		last_tl.focus_neighbor_bottom = first_bl.get_path()
		first_bl.focus_neighbor_top = last_tl.get_path()

	# 3. BottomLeft buttons escape right over to TopRight
	if tr_buttons.size() > 0:
		for i in range(bl_buttons.size()):
			var target_idx = mini(i, tr_buttons.size() - 1)
			(bl_buttons[i] as Button).focus_neighbor_right = tr_buttons[target_idx].get_path()
