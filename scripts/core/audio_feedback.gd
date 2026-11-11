extends Node
class_name AudioFeedback

const CONFIG_PATH: String = "res://configs/audio_config.json"
const SAMPLE_RATE: int = 48000

var config: Dictionary = {}
var player_pool: Array[AudioStreamPlayer] = []
var pool_size: int = 8
var pool_index: int = 0

func _ready() -> void:
	_load_config()
	for i in range(pool_size):
		var p = AudioStreamPlayer.new()
		add_child(p)
		player_pool.append(p)

func _load_config() -> void:
	if not FileAccess.file_exists(CONFIG_PATH):
		push_warning("audio_config.json not found, loading fallback defaults.")
		config = _get_default_config()
		return
	var file = FileAccess.open(CONFIG_PATH, FileAccess.READ)
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	config = parsed if parsed != null else _get_default_config()

# ==============================================================================
# SPATIAL PROJECTION (STEREO PAN + DEPTH FILTERING)
# ==============================================================================
func _calc_spatial_params(slice_pos: Vector3, cam_rig: Node3D) -> Dictionary:
	if not cam_rig or slice_pos.length_squared() < 0.01:
		return {"pan": 0.0, "cutoff": config.spatial.front_cutoff_hz}

	var cam_basis = cam_rig.global_transform.basis
	var cam_right = cam_basis.x.normalized()
	var cam_forward = -cam_basis.z.normalized()

	# Project slice center onto camera X (pan) and Z (depth)
	var raw_pan = slice_pos.dot(cam_right) * config.spatial.stereo_spread
	var pan = clampf(raw_pan, -1.0, 1.0)

	var depth = slice_pos.dot(cam_forward) # > 0 front, < 0 back
	var t = clampf((depth + 1.0) * 0.5, 0.0, 1.0)
	var cutoff = lerpf(config.spatial.back_cutoff_hz, config.spatial.front_cutoff_hz, t)

	return {"pan": pan, "cutoff": cutoff}

# ==============================================================================
# SYNTHESIS GENERATORS
# ==============================================================================
func play_turn_start(slice_pos: Vector3, duration: float, cam_rig: Node3D) -> void:
	var effective_duration = duration * config.tactile.scrape.duration_factor
	if effective_duration < 0.01:
		return

	var spatial = _calc_spatial_params(slice_pos, cam_rig)
	var num_samples = int(SAMPLE_RATE * effective_duration)
	var left_gain = cos((spatial.pan + 1.0) * PI * 0.25)
	var right_gain = sin((spatial.pan + 1.0) * PI * 0.25)

	# 1-pole Low-Pass coefficient
	var rc = 1.0 / (2.0 * PI * spatial.cutoff)
	var dt = 1.0 / SAMPLE_RATE
	var alpha = dt / (rc + dt)

	var pcm = PackedByteArray()
	pcm.resize(num_samples * 4) # 16-bit stereo = 4 bytes per sample frame

	var prev_sample: float = 0.0
	var gain = config.tactile.scrape.gain * config.master_volume

	for i in range(num_samples):
		var t = float(i) / float(num_samples)
		var env = exp(-t * 5.0) # Fast decay
		var noise = randf_range(-1.0, 1.0)
		prev_sample += alpha * (noise - prev_sample)

		var mono = prev_sample * env * gain
		var sample_l = clampf(mono * left_gain, -1.0, 1.0)
		var sample_r = clampf(mono * right_gain, -1.0, 1.0)

		var val_l = int(sample_l * 32767.0)
		var val_r = int(sample_r * 32767.0)

		var idx = i * 4
		pcm.encode_s16(idx, val_l)
		pcm.encode_s16(idx + 2, val_r)

	_play_stream(_create_wav_stream(pcm))

func play_turn_snap(slice_pos: Vector3, cam_rig: Node3D) -> void:
	var spatial = _calc_spatial_params(slice_pos, cam_rig)
	var duration_sec = config.tactile.snap.duration_ms / 1000.0
	var num_samples = int(SAMPLE_RATE * duration_sec)

	var left_gain = cos((spatial.pan + 1.0) * PI * 0.25)
	var right_gain = sin((spatial.pan + 1.0) * PI * 0.25)

	var pcm = PackedByteArray()
	pcm.resize(num_samples * 4)

	var phase: float = 0.0
	var f_start = config.tactile.snap.thud_freq_start
	var f_end = config.tactile.snap.thud_freq_end
	var click_f = config.tactile.snap.click_freq_hz
	var gain = config.tactile.snap.gain * config.master_volume

	# Pitch jitter (+/- 4%)
	var jitter = randf_range(0.96, 1.04)
	f_start *= jitter
	f_end *= jitter

	for i in range(num_samples):
		var t = float(i) / float(SAMPLE_RATE)
		var progress = float(i) / float(num_samples)

		# Sub thud sweep + high impulse spike in first 3ms
		var freq = lerpf(f_start, f_end, progress)
		phase += freq * (1.0 / SAMPLE_RATE) * TAU
		var thud = sin(phase) * exp(-progress * 9.0)

		var click = 0.0
		if progress < 0.15:
			click = sin(t * click_f * TAU) * exp(-progress * 25.0) * 0.5

		var mono = (thud * 0.7 + click * 0.3) * gain
		var sample_l = clampf(mono * left_gain, -1.0, 1.0)
		var sample_r = clampf(mono * right_gain, -1.0, 1.0)

		var idx = i * 4
		pcm.encode_s16(idx, int(sample_l * 32767.0))
		pcm.encode_s16(idx + 2, int(sample_r * 32767.0))

	_play_stream(_create_wav_stream(pcm))

func play_cube_rotation(duration: float) -> void:
	var num_samples = int(SAMPLE_RATE * (config.tactile.rotation.duration_ms / 1000.0))
	var pcm = PackedByteArray()
	pcm.resize(num_samples * 4)

	var phase: float = 0.0
	var f_start = config.tactile.rotation.freq_start
	var f_end = config.tactile.rotation.freq_end
	var gain = config.tactile.rotation.gain * config.master_volume

	for i in range(num_samples):
		var progress = float(i) / float(num_samples)
		var freq = lerpf(f_start, f_end, progress)
		phase += freq * (1.0 / SAMPLE_RATE) * TAU
		var sine_val = sin(phase)
		var noise = randf_range(-0.15, 0.15)
		var env = sin(progress * PI) # Parabolic swell and release

		var mono = (sine_val * 0.8 + noise * 0.2) * env * gain
		var s_val = int(clampf(mono, -1.0, 1.0) * 32767.0)

		var idx = i * 4
		pcm.encode_s16(idx, s_val)
		pcm.encode_s16(idx + 2, s_val)

	_play_stream(_create_wav_stream(pcm))

func play_ui_tick() -> void:
	var num_samples = int(SAMPLE_RATE * (config.ui.tick.duration_ms / 1000.0))
	var pcm = PackedByteArray()
	pcm.resize(num_samples * 4)

	var freq = config.ui.tick.freq_hz
	var gain = config.ui.tick.gain * config.master_volume

	for i in range(num_samples):
		var t = float(i) / float(SAMPLE_RATE)
		var progress = float(i) / float(num_samples)
		var wave = 1.0 if fmod(t * freq, 1.0) < 0.5 else -1.0
		var mono = wave * exp(-progress * 12.0) * gain
		var s_val = int(clampf(mono, -1.0, 1.0) * 32767.0)
		var idx = i * 4
		pcm.encode_s16(idx, s_val)
		pcm.encode_s16(idx + 2, s_val)

	_play_stream(_create_wav_stream(pcm))

func play_ui_accept() -> void:
	var step_samples = int(SAMPLE_RATE * (config.ui.accept.step_ms / 1000.0))
	var total_samples = step_samples * 2
	var pcm = PackedByteArray()
	pcm.resize(total_samples * 4)

	var gain = config.ui.accept.gain * config.master_volume

	for i in range(total_samples):
		var is_second_tone = i >= step_samples
		var freq = config.ui.accept.tone_2_hz if is_second_tone else config.ui.accept.tone_1_hz
		var tone_progress = float(i % step_samples) / float(step_samples)
		var t = float(i) / float(SAMPLE_RATE)

		var mono = sin(t * freq * TAU) * exp(-tone_progress * 4.0) * gain
		var s_val = int(clampf(mono, -1.0, 1.0) * 32767.0)
		var idx = i * 4
		pcm.encode_s16(idx, s_val)
		pcm.encode_s16(idx + 2, s_val)

	_play_stream(_create_wav_stream(pcm))

# ==============================================================================
# HELPERS
# ==============================================================================
func _create_wav_stream(pcm: PackedByteArray) -> AudioStreamWAV:
	var wav = AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SAMPLE_RATE
	wav.stereo = true
	wav.data = pcm
	return wav

func _play_stream(stream: AudioStream) -> void:
	var p = player_pool[pool_index]
	p.stream = stream
	p.play()
	pool_index = (pool_index + 1) % pool_size

func _get_default_config() -> Dictionary:
	return {
		"master_volume": 0.8,
		"spatial": {"stereo_spread": 0.8, "front_cutoff_hz": 12000.0, "back_cutoff_hz": 2800.0},
		"tactile": {
			"scrape": {"gain": 0.45, "duration_factor": 0.35, "cutoff_hz": 1800.0},
			"snap": {"gain": 0.85, "click_freq_hz": 3000.0, "thud_freq_start": 160.0, "thud_freq_end": 45.0, "duration_ms": 22.0},
			"rotation": {"gain": 0.55, "freq_start": 65.0, "freq_end": 40.0, "duration_ms": 120.0}
		},
		"ui": {
			"tick": {"gain": 0.35, "freq_hz": 1600.0, "duration_ms": 4.0},
			"accept": {"gain": 0.5, "tone_1_hz": 659.25, "tone_2_hz": 880.0, "step_ms": 18.0}
		}
	}
