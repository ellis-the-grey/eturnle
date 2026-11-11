class_name ScrambleGenerator
extends RefCounted

const FACES: Array[String] = ["U", "D", "L", "R", "F", "B"]
const MODIFIERS: Array[String] = ["", "'", "2"]

# Face -> Axis index: 0 = Y (U/D), 1 = X (L/R), 2 = Z (F/B)
const FACE_AXIS: Dictionary = {
	"U": 0, "D": 0,
	"L": 1, "R": 1,
	"F": 2, "B": 2
}

static func generate(length: int = 20, seed_val: Variant = null) -> String:
	var rng = RandomNumberGenerator.new()
	if seed_val != null and str(seed_val).strip_edges() != "":
		rng.seed = hash(str(seed_val))
	else:
		rng.randomize()

	var scramble_tokens: Array[String] = []
	var last_face: String = ""
	var second_last_face: String = ""

	while scramble_tokens.size() < length:
		var face = FACES[rng.randi_range(0, FACES.size() - 1)]

		# Rule 1: No consecutive turns on the same face (e.g., R R')
		if face == last_face:
			continue

		# Rule 2: No redundant sandwich turns on the same axis (e.g., R L R)
		if second_last_face != "" and FACE_AXIS[face] == FACE_AXIS[last_face] and FACE_AXIS[face] == FACE_AXIS[second_last_face]:
			continue

		var mod = MODIFIERS[rng.randi_range(0, MODIFIERS.size() - 1)]
		scramble_tokens.append(face + mod)

		second_last_face = last_face
		last_face = face

	return " ".join(scramble_tokens)
