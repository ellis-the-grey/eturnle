class_name CubeEnvironment

static func setup(parent: Node3D) -> Dictionary:
	var cam_rig = Node3D.new()
	cam_rig.name = "CamRig"
	parent.add_child(cam_rig)

	var camera = Camera3D.new()
	camera.name = "Camera3D"
	camera.position = Vector3(0.0, 0.0, 4.8)
	camera.current = true
	cam_rig.add_child(camera)

	cam_rig.rotation.y = deg_to_rad(28.0)
	cam_rig.rotation.x = deg_to_rad(-24.0)

	var key_light = DirectionalLight3D.new()
	key_light.position = Vector3(5.0, 7.0, 4.0)
	key_light.light_energy = 0.95
	key_light.shadow_enabled = true
	parent.add_child(key_light)
	key_light.look_at(Vector3.ZERO, Vector3.UP)

	var fill_light = DirectionalLight3D.new()
	fill_light.position = Vector3(-5.0, -3.0, -4.0)
	fill_light.light_energy = 0.4
	fill_light.shadow_enabled = false
	parent.add_child(fill_light)
	fill_light.look_at(Vector3.ZERO, Vector3.UP)

	var env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.11, 0.11, 0.13)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.85, 0.85, 0.9)
	env.ambient_light_energy = 0.22

	var world_env = WorldEnvironment.new()
	world_env.environment = env
	parent.add_child(world_env)

	return {
		"cam_rig": cam_rig,
		"camera": camera
	}
