class_name Piece
extends Node3D

# Discrete grid coordinate in {-1, 0, 1}^3
@export var grid_pos: Vector3i = Vector3i.ZERO

@onready var face_yellow: MeshInstance3D = $Face_Yellow
@onready var face_white: MeshInstance3D = $Face_White
@onready var face_green: MeshInstance3D = $Face_Green
@onready var face_blue: MeshInstance3D = $Face_Blue
@onready var face_red: MeshInstance3D = $Face_Red
@onready var face_orange: MeshInstance3D = $Face_Orange

func setup_stickers(initial_pos: Vector3i) -> void:
	grid_pos = initial_pos
	position = Vector3(initial_pos)
	
	# Only keep stickers visible if they face the outside of the 3x3x3 grid
	# (Orange Right +X, Red Left -X, Yellow Up +Y, White Down -Y, Green Front +Z, Blue Back -Z)
	face_yellow.visible = (initial_pos.y == 1)
	face_white.visible  = (initial_pos.y == -1)
	face_green.visible  = (initial_pos.z == 1)
	face_blue.visible   = (initial_pos.z == -1)
	face_orange.visible = (initial_pos.x == 1)
	face_red.visible    = (initial_pos.x == -1)
