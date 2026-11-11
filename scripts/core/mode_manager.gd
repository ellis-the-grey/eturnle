extends Node
class_name ModeManager

signal mode_changed(mode_id: String, display_name: String, options: Array)

enum GameMode {
	LIMITLESS,
	CROSSLE,
	BABYS_FIRST_F2L,
	CUSTOM
}

var current_mode: GameMode = GameMode.LIMITLESS

const MODE_METADATA = {
	GameMode.LIMITLESS: {
		"id": "limitless",
		"name": "Limitless",
		"modules": ["move_counter", "sequence_deck"]
	},
	GameMode.CROSSLE: {
		"id": "crossle",
		"name": "Crossle",
		"modules": ["move_counter"]
	},
	GameMode.BABYS_FIRST_F2L: {
		"id": "babys_first_f2l",
		"name": "Baby's First F2L Pair",
		"modules": ["sequence_deck"]
	},
	GameMode.CUSTOM: {
		"id": "custom",
		"name": "Custom",
		"modules": ["sequence_deck"]
	}
}

func _ready() -> void:
	set_mode(GameMode.LIMITLESS)

func cycle_mode(direction: int = 1) -> void:
	var total_modes = GameMode.size()
	var next_idx = (int(current_mode) + direction) % total_modes
	if next_idx < 0:
		next_idx += total_modes
	set_mode(next_idx as GameMode)

func set_mode(mode: GameMode) -> void:
	current_mode = mode
	var meta = MODE_METADATA[current_mode]
	mode_changed.emit(meta["id"], meta["name"], meta.get("options", []))

func get_current_metadata() -> Dictionary:
	return MODE_METADATA[current_mode]
