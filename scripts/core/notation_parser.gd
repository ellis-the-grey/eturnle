class_name NotationParser
extends RefCounted

static func parse(sequence: String) -> Array[String]:
	var raw_tokens = sequence.strip_edges().split(" ", false)
	var actions: Array[String] = []

	for raw in raw_tokens:
		var token = raw.strip_edges()
		if token.is_empty():
			continue

		var base_face = token[0].to_upper()
		var modifier = token.substr(1)

		var action_base = ""
		match base_face:
			"R": action_base = "move_r"
			"L": action_base = "move_l"
			"U": action_base = "move_u"
			"D": action_base = "move_d"
			"F": action_base = "move_f"
			"B": action_base = "move_b"
			"M": action_base = "move_m"
			"X": action_base = "rot_x"
			"Y": action_base = "rot_y"
			_: continue

		match modifier:
			"":
				actions.append(action_base)
			"'":
				actions.append(action_base + "_prime")
			"2":
				actions.append(action_base)
				actions.append(action_base)
			"2'":
				actions.append(action_base + "_prime")
				actions.append(action_base + "_prime")

	return actions
