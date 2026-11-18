@tool
class_name BSPScene extends Node3D

# Q3 / JA MAX_LIGHT_STYLES. Texture is 64 wide so index 0-63 map 1:1.
const STYLE_COUNT := 64
const STYLE_TEX_WIDTH := 64
# Default cl_lightstyle strings. 'a' = 0, 'm' = 0.5, 'z' = 1.
# Evaluated at 10 Hz like the idTech client.
const DEFAULT_STYLE_PATTERNS := [
	"m",
	"mmnmmommommnonmmonqnmmo",
	"abcdefghijklmnopqrstuvwxyzyxwvutsrqponmlkjihgfedcba",
	"mmmmmaaaaammmmmaaaaaabcdefgabcdefg",
	"mamamamamama",
	"jklmnopqrstuvwxyzyxwvutsrqponmlkj",
	"nmonqnmomnmomomno",
	"mmmaaaabcdefgmmmmaaaammmaamm",
	"mmmaaammmaaammmabcdefaaaammmmabcdefmmmaaaa",
	"aaaaaaaazzzzzzzz",
	"mmamammmmammamamaaamammma",
	"abcdefghijklmnopqrrqponmlkjihgfedcba",
]
const DEFAULT_STYLE_FUNC := Tech3Noise.WAVE_NOISE
const DEFAULT_STYLE_BASE := 0.5
const DEFAULT_STYLE_AMP := 1.0
const DEFAULT_STYLE_PHASE := 0.0
const DEFAULT_STYLE_FREQ := 5.37
# 0 = never wrap. Set > 0 to fposmod the clock, in seconds.
const DEFAULT_TIME_WRAP := 0.0
const STYLE_SWITCH_MIN := 32
const STYLE_ON := "m"
const STYLE_OFF := "a"

@export var worldspawn := {}

@export var light_grid_ambient: Texture3D = null
@export var light_grid_direct: Texture3D = null
@export var light_grid_cartesian: Texture3D = null
@export var light_grid_ambient_1: Texture3D = null
@export var light_grid_ambient_2: Texture3D = null
@export var light_grid_ambient_3: Texture3D = null
@export var light_grid_direct_1: Texture3D = null
@export var light_grid_direct_2: Texture3D = null
@export var light_grid_direct_3: Texture3D = null
@export var light_grid_styles: Texture3D = null
@export var light_grid_normalize := Vector3.ZERO
@export var light_grid_offset := Vector3.ZERO

# 64 slots shared by RBSP face/grid pages, IBSP q3map2 style stages, and
# styled Omni/Spot. Index 0 is static (weight 1). 1-11 are Quake patterns
# unless worldspawn _styleNrgbGen / ls_N / ls_Nr|g|b overlays them. 12-31
# are static unless a harvested wave owns the slot. 32+ are switches.
# Raven packs three independent a-z patterns per style (configstring
# style*3+ch). pattern / on_pattern are the scalar form (all channels);
# pattern_r/g/b and on_pattern_r/g/b hold a per-channel override when set.
# Each entry: { "func": int, "base": float, "amp": float, "phase": float, "freq": float,
#               "pattern": String, "on_pattern": String,
#               "pattern_r": String, "pattern_g": String, "pattern_b": String,
#               "on_pattern_r": String, "on_pattern_g": String, "on_pattern_b": String }
@export var style_waves: Array[Dictionary] = []
@export var time_wrap: float = DEFAULT_TIME_WRAP

# Frame-delta clock written to the tech3_time shader global.
# Pausing this node (or the tree) freezes materials and styled lights together.
var tech3_time: float = 0.0
var _style_weight_img: Image
var _style_weight_tex: ImageTexture
var _style_tick: int = -1
var _style_has_wave: bool = false
var _style_tex_bound: bool = false


func _ready() -> void:
	_init_style_table()
	Tech3Noise.ensure_shader_global()
	_ensure_style_weight_tex()
	# let's assume the globals are there if we have these values
	if light_grid_ambient and light_grid_direct:
		RenderingServer.global_shader_parameter_set(&"light_grid_ambient", light_grid_ambient)
		RenderingServer.global_shader_parameter_set(&"light_grid_direct", light_grid_direct)
		RenderingServer.global_shader_parameter_set(&"light_grid_cartesian", light_grid_cartesian)
		RenderingServer.global_shader_parameter_set(&"light_grid_ambient_1", light_grid_ambient_1)
		RenderingServer.global_shader_parameter_set(&"light_grid_ambient_2", light_grid_ambient_2)
		RenderingServer.global_shader_parameter_set(&"light_grid_ambient_3", light_grid_ambient_3)
		RenderingServer.global_shader_parameter_set(&"light_grid_direct_1", light_grid_direct_1)
		RenderingServer.global_shader_parameter_set(&"light_grid_direct_2", light_grid_direct_2)
		RenderingServer.global_shader_parameter_set(&"light_grid_direct_3", light_grid_direct_3)
		RenderingServer.global_shader_parameter_set(&"light_grid_styles", light_grid_styles)
		RenderingServer.global_shader_parameter_set(&"light_grid_normalize", light_grid_normalize)
		RenderingServer.global_shader_parameter_set(&"light_grid_offset", light_grid_offset)
	else: # probably not using the lightgrid for this map, let's clear out the globals just in case.
		for key in [
			"light_grid_ambient", "light_grid_direct", "light_grid_cartesian",
			"light_grid_ambient_1", "light_grid_ambient_2", "light_grid_ambient_3",
			"light_grid_direct_1", "light_grid_direct_2", "light_grid_direct_3",
			"light_grid_styles",
		]:
			if ProjectSettings.has_setting("shader_globals/%s" % key):
				RenderingServer.global_shader_parameter_set(StringName(key), null)
		if ProjectSettings.has_setting("shader_globals/light_grid_normalize"):
			RenderingServer.global_shader_parameter_set(&"light_grid_normalize", Vector3.ZERO)
		if ProjectSettings.has_setting("shader_globals/light_grid_offset"):
			RenderingServer.global_shader_parameter_set(&"light_grid_offset", Vector3.ZERO)

	tech3_time = 0.0


func _process(delta: float) -> void:
	if time_wrap > 0.0:
		tech3_time = fposmod(tech3_time + delta, time_wrap)
	else:
		tech3_time += delta
	RenderingServer.global_shader_parameter_set(&"tech3_time", tech3_time)
	_upload_style_weights(false)


func _init_style_table() -> void:
	if style_waves.size() >= STYLE_COUNT:
		return
	style_waves = default_style_waves()


## One style-table slot: wave params plus Quake letter pattern fields.
## Usage: var slot := BSPScene.default_wave(); slot.pattern = "mmnmmomm"
static func default_wave() -> Dictionary:
	return {
		"func": DEFAULT_STYLE_FUNC,
		"base": DEFAULT_STYLE_BASE,
		"amp": DEFAULT_STYLE_AMP,
		"phase": DEFAULT_STYLE_PHASE,
		"freq": DEFAULT_STYLE_FREQ,
		"pattern": "",
		"on_pattern": STYLE_ON,
		"pattern_r": "",
		"pattern_g": "",
		"pattern_b": "",
		"on_pattern_r": "",
		"on_pattern_g": "",
		"on_pattern_b": "",
		"enabled": true,
	}


## 64-slot table: slot 0 static, 1–11 Quake patterns, 32+ on/off switches.
## Usage: style_waves = BSPScene.default_style_waves()
static func default_style_waves() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	out.resize(STYLE_COUNT)
	out[0] = { "func": 0, "base": 1.0, "amp": 0.0, "phase": 0.0, "freq": 0.0, "pattern": STYLE_ON, "on_pattern": STYLE_ON, "pattern_r": "", "pattern_g": "", "pattern_b": "", "on_pattern_r": "", "on_pattern_g": "", "on_pattern_b": "", "enabled": true }
	for i in range(1, STYLE_COUNT):
		var w: Dictionary = default_wave()
		if i < DEFAULT_STYLE_PATTERNS.size():
			w["pattern"] = DEFAULT_STYLE_PATTERNS[i]
			w["on_pattern"] = DEFAULT_STYLE_PATTERNS[i]
		elif i >= STYLE_SWITCH_MIN:
			w["pattern"] = STYLE_ON
			w["on_pattern"] = STYLE_ON
			w["func"] = 0
			w["amp"] = 0.0
			w["base"] = 1.0
		else:
			# Unused 12-31. Static full bright. A harvested wave or
			# _styleNrgbGen overwrites this and clears the pattern.
			w["pattern"] = "z"
			w["on_pattern"] = "z"
			w["func"] = 0
			w["amp"] = 0.0
			w["base"] = 1.0
		out[i] = w
	return out


func _ensure_style_weight_tex() -> void:
	if _style_weight_img == null:
		# RGB so Raven ls_Nr / ls_Ng / ls_Nb can animate independently.
		# Scalar patterns write the same value into all three channels.
		_style_weight_img = Image.create(STYLE_TEX_WIDTH, 1, false, Image.FORMAT_RGBF)
	if _style_weight_tex == null:
		_style_weight_tex = ImageTexture.create_from_image(_style_weight_img)
	if not ProjectSettings.has_setting("shader_globals/tech3_style_weights"):
		RenderingServer.global_shader_parameter_add(
			&"tech3_style_weights",
			RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D,
			_style_weight_tex
		)
		_style_tex_bound = true
	elif not _style_tex_bound:
		# Bind once so materials are not rebound every frame.
		RenderingServer.global_shader_parameter_set(&"tech3_style_weights", _style_weight_tex)
		_style_tex_bound = true
	_refresh_style_live()
	_upload_style_weights(true)


func _slot_is_live_wave(wave: Dictionary) -> bool:
	# Letter styles tick at 10 Hz. An empty pattern is a wave, and only
	# a harvested / _styleNrgbGen slot has one. Unused 12-31 are "z".
	if wave.is_empty() or not bool(wave.get("enabled", true)):
		return false
	if String(wave.get("pattern", "")) != "":
		return false
	return absf(float(wave.get("amp", 0.0))) > 0.0001 and absf(float(wave.get("freq", 0.0))) > 0.0001


func _refresh_style_live() -> void:
	_style_has_wave = false
	for i in range(1, style_waves.size()):
		var wave = style_waves[i]
		if wave is Dictionary and _slot_is_live_wave(wave):
			_style_has_wave = true
			return


func _upload_style_weights(force: bool = false) -> void:
	if _style_weight_img == null or _style_weight_tex == null:
		return
	var tick := int(floor(tech3_time * 10.0))
	if not force and not _style_has_wave and tick == _style_tick:
		return
	_style_tick = tick
	for i in STYLE_TEX_WIDTH:
		var c := Color.BLACK
		if i == 0:
			c = Color.WHITE
		elif i < 255:
			c = style_weight_rgb(i)
		_style_weight_img.set_pixel(i, 0, c)
	_style_weight_tex.update(_style_weight_img)


func _style_slot(index: int) -> Dictionary:
	_init_style_table()
	if index <= 0 or index >= style_waves.size():
		return {}
	var wave = style_waves[index]
	if wave is Dictionary:
		return wave
	return {}


## Replace the on-pattern for a slot (a–z letters). Clears any per-channel
## overrides, so every channel follows this pattern. Applies immediately
## if the slot is on. An empty pattern becomes the full-on string.
## Usage: scene.set_style_pattern(32, "mmmmaaaa")
func set_style_pattern(index: int, pattern: String) -> void:
	var wave := _style_slot(index)
	if wave.is_empty():
		return
	var p := pattern.strip_edges()
	if p.is_empty():
		p = STYLE_ON
	wave["on_pattern"] = p
	# A scalar set replaces every channel (Raven's full-style override).
	wave["on_pattern_r"] = ""
	wave["on_pattern_g"] = ""
	wave["on_pattern_b"] = ""
	if bool(wave.get("enabled", true)):
		wave["pattern"] = p
		wave["pattern_r"] = ""
		wave["pattern_g"] = ""
		wave["pattern_b"] = ""
	style_waves[index] = wave
	_refresh_style_live()
	_upload_style_weights(true)


## Replace any combination of channels on a slot (Raven ls_Nr / ls_Ng / ls_Nb).
## channel is any mix of "r", "g", "b": "r", "rg", "rgb", "b". Order and repeats
## do not matter. An empty pattern clears the override so those channels follow
## the scalar pattern again. Applies immediately if the slot is on.
## Usage: scene.set_style_channel(13, "rg", "zzzzmmmm")
func set_style_channel(index: int, channel: String, pattern: String) -> void:
	var wave := _style_slot(index)
	if wave.is_empty():
		return
	var mask := channel.strip_edges().to_lower()
	var p := pattern.strip_edges()
	var on := bool(wave.get("enabled", true))
	var wrote := false
	for ch in ["r", "g", "b"]:
		if not mask.contains(ch):
			continue
		wave["on_pattern_" + ch] = p
		if on:
			wave["pattern_" + ch] = p
		wrote = true
	if not wrote:
		return
	style_waves[index] = wave
	_refresh_style_live()
	_upload_style_weights(true)


## On-pattern for one channel. Empty means the channel follows the scalar pattern.
## Usage: var p := scene.get_style_channel(13, "r")
func get_style_channel(index: int, channel: String) -> String:
	var wave := _style_slot(index)
	if wave.is_empty():
		return ""
	var ch := channel.strip_edges().to_lower()
	if ch not in ["r", "g", "b"]:
		return ""
	return String(wave.get("on_pattern_" + ch, ""))


## On-pattern string for a slot (the pattern used when the style is enabled).
## Usage: var p := scene.get_style_pattern(2)
func get_style_pattern(index: int) -> String:
	var wave := _style_slot(index)
	if wave.is_empty():
		return STYLE_ON
	return String(wave.get("on_pattern", wave.get("pattern", STYLE_ON)))


## True when the slot is enabled (weight may still animate).
## Usage: if scene.is_style_on(32): ...
func is_style_on(index: int) -> bool:
	if index <= 0:
		return true
	var wave := _style_slot(index)
	if wave.is_empty():
		return true
	return bool(wave.get("enabled", true))


## Enable or disable a slot. Off forces pattern "a" (weight 0).
## Usage: scene.style_set(32, true)
func style_set(index: int, on: bool) -> void:
	var wave := _style_slot(index)
	if wave.is_empty():
		return
	wave["enabled"] = on
	if on:
		var p := String(wave.get("on_pattern", ""))
		wave["pattern"] = p if p != "" else STYLE_ON
		wave["pattern_r"] = String(wave.get("on_pattern_r", ""))
		wave["pattern_g"] = String(wave.get("on_pattern_g", ""))
		wave["pattern_b"] = String(wave.get("on_pattern_b", ""))
	else:
		wave["pattern"] = STYLE_OFF
		wave["pattern_r"] = ""
		wave["pattern_g"] = ""
		wave["pattern_b"] = ""
	style_waves[index] = wave
	_refresh_style_live()
	_upload_style_weights(true)


## Enable a style slot. Usage: scene.style_on(32)
func style_on(index: int) -> void:
	style_set(index, true)


## Disable a style slot. Usage: scene.style_off(32)
func style_off(index: int) -> void:
	style_set(index, false)


## Flip a slot and return the new enabled state.
## Usage: var on := scene.style_toggle(32)
func style_toggle(index: int) -> bool:
	var on := not is_style_on(index)
	style_set(index, on)
	return on


## Current 0–1 RGB weight for a style index this frame.
## Scalar patterns write the same value into every channel. A Raven
## ls_Nr / ls_Ng / ls_Nb override replaces only that channel; the others
## keep the slot's scalar pattern (or 1.0 when the slot has no pattern).
## Usage: var c := scene.style_weight_rgb(style_index)
func style_weight_rgb(index: int) -> Color:
	var w := style_weight(index)
	if index <= 0 or index >= 255:
		return Color(w, w, w, 1.0)
	_init_style_table()
	if index >= style_waves.size():
		return Color(w, w, w, 1.0)
	var wave: Dictionary = style_waves[index]
	if not bool(wave.get("enabled", true)):
		return Color.BLACK
	var r := _channel_weight(wave, "pattern_r", w)
	var g := _channel_weight(wave, "pattern_g", w)
	var b := _channel_weight(wave, "pattern_b", w)
	return Color(r, g, b, 1.0)


## Weight for one channel. An empty per-channel pattern falls back to the
## scalar weight for the slot (the Quake default or a full ls_N override).
func _channel_weight(wave: Dictionary, key: String, fallback: float) -> float:
	var pat := String(wave.get(key, ""))
	if pat == "":
		return fallback
	return _letter_weight(pat)


## a-z letter to 0-1. 'a' = 0, 'm' = 0.48, 'z' = 1.
## (c - 'a') / ('z' - 'a').
func _letter_weight(pattern: String) -> float:
	var n := pattern.length()
	if n <= 0:
		return 1.0
	var ch := pattern.unicode_at(int(floor(tech3_time * 10.0)) % n)
	return clampf(float(ch - 97) / 25.0, 0.0, 1.0)


## Current 0–1 scalar weight for a style index this frame (patterns at
## 10 Hz, else wave). Ignores per-channel overrides; use style_weight_rgb
## for those. Index 0 is always 1. Off is 0. Index >= 255 is 0.
## Usage: light.light_energy = base * scene.style_weight(style_index)
func style_weight(index: int) -> float:
	if index <= 0:
		return 1.0
	if index >= 255:
		return 0.0
	_init_style_table()
	if index >= style_waves.size():
		return 1.0
	var wave: Dictionary = style_waves[index]
	if not bool(wave.get("enabled", true)):
		return 0.0
	var pattern := String(wave.get("pattern", ""))
	if pattern != "":
		return _letter_weight(pattern)
	return clampf(Tech3Noise.wave(
		int(wave.get("func", DEFAULT_STYLE_FUNC)),
		tech3_time,
		float(wave.get("base", DEFAULT_STYLE_BASE)),
		float(wave.get("amp", DEFAULT_STYLE_AMP)),
		float(wave.get("phase", DEFAULT_STYLE_PHASE)),
		float(wave.get("freq", DEFAULT_STYLE_FREQ))
	), 0.0, 1.0)


## Raven surface sprite / weather control (JK2 / JA / SoF2).
## Multiplies the per-stage ss_wind from the shader script. Direction zero
## keeps the material's ss_wind_dir (default +X). Applies immediately.
## Usage: scene.set_ss_wind(0.5, Vector3(1, 0, 0.3))
func set_ss_wind(strength: float, direction: Vector3 = Vector3.ZERO) -> void:
	RenderingServer.global_shader_parameter_set(&"tech3_ss_wind_scale", strength)
	RenderingServer.global_shader_parameter_set(&"tech3_ss_wind_dir", direction)


## Current wind scale (1 = shader-script strength).
## Usage: var s := scene.get_ss_wind_scale()
func get_ss_wind_scale() -> float:
	return float(RenderingServer.global_shader_parameter_get(&"tech3_ss_wind_scale"))


## Current wind direction override (zero = use per-material).
## Usage: var d := scene.get_ss_wind_dir()
func get_ss_wind_dir() -> Vector3:
	return RenderingServer.global_shader_parameter_get(&"tech3_ss_wind_dir")


## Show or hide surface sprites by type, anywhere under this scene.
## kind is "flattened", "vertical", "oriented", "effect", "weather", or "all".
## Nodes are named ss_<type>_... by the importer.
## Usage: scene.set_ss_visible("weather", false)
func set_ss_visible(kind: String, visible: bool) -> void:
	var k := kind.strip_edges().to_lower()
	var prefix := "ss_" if k == "all" or k.is_empty() else "ss_" + k
	var stack: Array[Node] = [self]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MultiMeshInstance3D and String(n.name).begins_with(prefix):
			n.visible = visible
		for c in n.get_children():
			stack.append(c)


## All surface-sprite MultiMeshInstance3D nodes under this scene.
## Usage: for n in scene.get_ss_nodes(): ...
func get_ss_nodes() -> Array[MultiMeshInstance3D]:
	var out: Array[MultiMeshInstance3D] = []
	var stack: Array[Node] = [self]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MultiMeshInstance3D and String(n.name).begins_with("ss_"):
			out.append(n as MultiMeshInstance3D)
		for c in n.get_children():
			stack.append(c)
	return out


## Force the frame of every animMap / oneshotAnimMap stage on surfaces
## whose tech3_shader meta matches shader_name (case-insensitive).
## Global by shader name: every MeshInstance3D using that shader gets the
## same instance uniform. Not a remap - remap_shader swaps the material.
## oneshot clamps to last frame, looping wraps. frame < 0 restores
## time-based playback.
## Usage: scene.set_shader_frame("textures/foo/bar", 2)
func set_shader_frame(shader_name: String, frame: int) -> int:
	var key := shader_name.strip_edges().to_lower()
	var n := 0
	for mi in _iter_mesh_instances():
		if not (mi is MeshInstance3D):
			continue
		if not _instance_uses_shader(mi as MeshInstance3D, key):
			continue
		(mi as MeshInstance3D).set_instance_shader_parameter("anim_frame_override", frame)
		n += 1
	return n


## Current anim_frame_override on the first surface using shader_name,
## or -1 if the shader is not in the scene or still on time-based playback.
## Usage: var frame := scene.get_shader_frame("textures/foo/bar")
func get_shader_frame(shader_name: String) -> int:
	var key := shader_name.strip_edges().to_lower()
	for mi in _iter_mesh_instances():
		if not (mi is MeshInstance3D):
			continue
		if not _instance_uses_shader(mi as MeshInstance3D, key):
			continue
		return _instance_anim_frame(mi as MeshInstance3D)
	return -1


## Flip every surface using shader_name between frame 0 and frame 1.
## Time-based (-1) is treated as "not on frame 0", so the first toggle
## lands on 0. Returns the frame it landed on, or -1 if not found.
## Usage: scene.toggle_shader_frame("textures/wedge/w_door_onoff")
func toggle_shader_frame(shader_name: String) -> int:
	var cur := get_shader_frame(shader_name)
	var nxt := 0 if cur != 0 else 1
	if set_shader_frame(shader_name, nxt) == 0:
		return -1
	return nxt


## Force the frame on one entity. node may be the MeshInstance3D itself
## or any parent; every MeshInstance3D under it is written. This is the
## Raven RF_SETANIMINDEX + skinNum path: other entities sharing the
## shader are left alone. frame < 0 restores time-based playback.
## Usage: scene.set_node_shader_frame($Door1, 1)
func set_node_shader_frame(node: Node, frame: int) -> int:
	if node == null:
		return 0
	var n := 0
	for mi in _mesh_instances_under(node):
		mi.set_instance_shader_parameter("anim_frame_override", frame)
		n += 1
	return n


## Current anim_frame_override on the first MeshInstance3D under node,
## or -1 if none or still on time-based playback.
## Usage: var frame := scene.get_node_shader_frame($Door1)
func get_node_shader_frame(node: Node) -> int:
	if node == null:
		return -1
	var meshes := _mesh_instances_under(node)
	if meshes.is_empty():
		return -1
	return _instance_anim_frame(meshes[0])


## Flip every MeshInstance3D under node between frame 0 and frame 1,
## based on the first mesh's current frame. Time-based (-1) lands on 0.
## Returns the frame it landed on, or -1 if node has no mesh.
## Usage: scene.toggle_node_shader_frame($Door1)
func toggle_node_shader_frame(node: Node) -> int:
	if node == null:
		return -1
	var cur := get_node_shader_frame(node)
	var nxt := 0 if cur != 0 else 1
	if set_node_shader_frame(node, nxt) == 0:
		return -1
	return nxt


func _instance_anim_frame(mi: MeshInstance3D) -> int:
	var frame: Variant = mi.get_instance_shader_parameter("anim_frame_override")
	if frame == null:
		return -1
	return int(frame)


func _instance_uses_shader(mi: MeshInstance3D, key: String) -> bool:
	if mi.material_override is ShaderMaterial and _material_shader_key(mi.material_override) == key:
		return true
	var mesh: Mesh = mi.mesh
	if mesh == null:
		return false
	for si in mesh.get_surface_count():
		var m: Material = mesh.surface_get_material(si)
		if m is ShaderMaterial and _material_shader_key(m) == key:
			return true
	return false


func _mesh_instances_under(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			out.append(n as MeshInstance3D)
		for c in n.get_children():
			stack.append(c)
	return out


## Remap every surface using old_name onto the material already built for
## new_name. Same effect as the entity keys targetshadername /
## targetshadernewname. Returns the number of surfaces updated, or 0 if
## no material for new_name exists in the scene.
## Usage: scene.remap_shader("textures/foo/old", "textures/bar/new")
func remap_shader(old_name: String, new_name: String) -> int:
	var old_key := old_name.strip_edges().to_lower()
	var new_key := new_name.strip_edges().to_lower()
	var new_mat: Material = null
	for mat in _iter_shader_materials():
		if _material_shader_key(mat) == new_key:
			new_mat = mat
			break
	if new_mat == null:
		push_warning("BSPScene.remap_shader: no material for '%s'" % new_name)
		return 0
	var n := 0
	for mi in _iter_mesh_instances():
		if mi is MeshInstance3D:
			var mesh: Mesh = (mi as MeshInstance3D).mesh
			if mesh == null:
				continue
			for si in mesh.get_surface_count():
				var surf_mat: Material = mesh.surface_get_material(si)
				if surf_mat is ShaderMaterial and _material_shader_key(surf_mat) == old_key:
					mesh.surface_set_material(si, new_mat)
					n += 1
		if mi.material_override is ShaderMaterial and _material_shader_key(mi.material_override) == old_key:
			mi.material_override = new_mat
			n += 1
	return n


func _material_shader_key(mat: Material) -> String:
	if mat == null or not mat.has_meta("tech3_shader"):
		return ""
	return str(mat.get_meta("tech3_shader")).strip_edges().to_lower()


func _iter_shader_materials() -> Array[ShaderMaterial]:
	var out: Array[ShaderMaterial] = []
	var seen := {}
	for mi in _iter_mesh_instances():
		if mi is MeshInstance3D:
			var mesh: Mesh = (mi as MeshInstance3D).mesh
			if mesh:
				for si in mesh.get_surface_count():
					var m: Material = mesh.surface_get_material(si)
					if m is ShaderMaterial and not seen.has(m):
						seen[m] = true
						out.append(m)
		if mi.material_override is ShaderMaterial and not seen.has(mi.material_override):
			seen[mi.material_override] = true
			out.append(mi.material_override)
	return out


func _iter_mesh_instances() -> Array[GeometryInstance3D]:
	var out: Array[GeometryInstance3D] = []
	var stack: Array[Node] = [self]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D or n is MultiMeshInstance3D:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out
