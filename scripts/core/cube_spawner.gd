class_name CubeSpawner

static func spawn(parent: Node3D, piece_scene: PackedScene) -> Dictionary:
	var pieces: Dictionary = {}
	for x in range(-1, 2):
		for y in range(-1, 2):
			for z in range(-1, 2):
				if x == 0 and y == 0 and z == 0:
					continue
				
				var grid_pos = Vector3i(x, y, z)
				var piece: Node3D = piece_scene.instantiate()
				piece.add_to_group("pieces")
				parent.add_child(piece)
				piece.position = Vector3(grid_pos)
				update_stickers(piece, grid_pos)
				pieces[grid_pos] = piece
	return pieces

static func update_stickers(piece: Node3D, pos: Vector3i) -> void:
	_set_face_vis(piece, "Face_Yellow", pos.y == 1)
	_set_face_vis(piece, "Face_White",  pos.y == -1)
	_set_face_vis(piece, "Face_Green",  pos.z == 1)
	_set_face_vis(piece, "Face_Blue",   pos.z == -1)
	_set_face_vis(piece, "Face_Orange", pos.x == 1)
	_set_face_vis(piece, "Face_Red",    pos.x == -1)

static func _set_face_vis(piece: Node3D, face_name: String, show_face: bool) -> void:
	var face: Node = piece.find_child(face_name, true, false)
	if face and face is Node3D:
		(face as Node3D).visible = show_face
