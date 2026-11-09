class_name MainHUD
extends CanvasLayer

# Central event router for all UI submodules
# Handles decoupling: cube_root/engine emits signals -> MainHUD updates components

@onready var debug_panel: Control = $DebugPanel
@onready var controller_overlay: Control = $ControllerOverlay
@onready var dialog_layer: Control = $DialogLayer
@onready var audio_feedback: Node = $AudioFeedback

func _ready() -> void:
	pass
