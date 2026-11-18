extends RefCounted
class_name Tech3BSPReader
# IBSP 46 / RBSP converter.
# Handles Q3A/TA, STVEF, OA, Nexuiz/Xonotic, SoF2, JK2, JA
# RtCW should work as well but is not well tested.

const IBSP_LUMP_COUNT := 17
const RBSP_LUMP_COUNT := 18
const IBSP_VERTEX_SIZE := 44
const RBSP_VERTEX_SIZE := 80
const IBSP_FACE_SIZE := 104
const RBSP_FACE_SIZE := 148
const IBSP_BRUSHSIDE_SIZE := 8
const RBSP_BRUSHSIDE_SIZE := 12
const IBSP_GRID_SAMPLE_SIZE := 8
const RBSP_GRID_SAMPLE_SIZE := 30
const RBSP_LS_NONE := 0xFF
const MAX_MESH_SURFACES = RenderingServer.MAX_MESH_SURFACES
const DEFAULT_LIGHTMAP_SIZE = 128
const DEFAULT_LIGHTMAP_LENGTH = 49152
const LIGHTMAP_PAD = 0 # optional padding for lm atlas generation
const LIGHTGRID_PAD = 0 # optional padding for lightgrids (can be useful when styles are enabled and simple entity shader used)
const POSSIBLE_IMAGE_EXTENSIONS = ["tga", "png", "webp", "bmp", "jpg", "jpeg", "dds", "ktx", "exr", "hdr", "svg"]

const LIGHT_IMPORT_NONE := 0
const LIGHT_IMPORT_STYLED := 1
const LIGHT_IMPORT_ALL := 2
const LIGHTGRID_FULL := 0
const LIGHTGRID_AMBIENT := 1
const LIGHTGRID_NONE := 2

# Collision layers for clipping.
const COL_LAYER_WORLD := 1
const COL_LAYER_PLAYER := 2
const COL_LAYER_MONSTER := 4
const COL_LAYER_WEAPON := 8


const _STYLED_LIGHT_SCRIPT := preload("res://addons/tech3bsp/styled_light.gd")

var _bsp_scene: BSPScene # the final product

static var options: Dictionary = {} # importer / runtime options


## Importer defaults used by the editor plugin and Tech3Pk3.load_map().
## Keys match EditorImportPlugin option names. Callers may overlay extras.
static func default_options() -> Dictionary:
	var o := {
		"unit_scale": 32.0,
		"light_brightness_multiplier": 1.0,
		"light_attenuation": 2.0,
		"entity_map": "res://addons/tech3bsp/examples/entities.cfg",
		"print_missing_entities": false,
		"materials_path": "res://materials/{texture_name}.material",
		"assets_path_override": "res://",
		"use_tech3_shaders": true,
		"tech3_shaders_override": "",
		"shaderlist_path": "",
		"save_converted_shaders": false,
		"converted_shaders_path": "res://shaders/tech3/{shader_name}.gdshader",
		"overwrite_converted_shaders": false,
		"import_lightmaps": true,
		"import_lightgrid": 0,
		"import_vertex_colors": true,
		"import_lights": 0,
		"entity_shadow_light": false,
		"shadow_opacity": 1.0,
		"import_billboards": false,
		"import_surface_sprites": true,
		"split_mesh": false,
		"occlusion_culling": false,
		"remove_skies": false,
		"import_skybox": false,
		"patch_detail": 4, # r_subdivisions (world units). Lower = denser.
		"clip_backface_collision": false,
		"import_entities": true,
		"import_models": true,
		"water_scene": null,
		"slime_scene": null,
		"lava_scene": null,
	}
	if ResourceLoader.exists("res://addons/tech3bsp/examples/water_example_template.tscn"):
		o["water_scene"] = load("res://addons/tech3bsp/examples/water_example_template.tscn")
	if ResourceLoader.exists("res://addons/tech3bsp/examples/slime_example_template.tscn"):
		o["slime_scene"] = load("res://addons/tech3bsp/examples/slime_example_template.tscn")
	if ResourceLoader.exists("res://addons/tech3bsp/examples/lava_example_template.tscn"):
		o["lava_scene"] = load("res://addons/tech3bsp/examples/lava_example_template.tscn")
	return o


func _light_import_mode() -> int:
	var v = options.get("import_lights", LIGHT_IMPORT_NONE)
	if v is bool:
		return LIGHT_IMPORT_ALL if v else LIGHT_IMPORT_NONE
	return clampi(int(v), LIGHT_IMPORT_NONE, LIGHT_IMPORT_ALL)


func _lightgrid_mode() -> int:
	var v = options.get("import_lightgrid", LIGHTGRID_FULL)
	if v is bool:
		return LIGHTGRID_FULL if v else LIGHTGRID_NONE
	return clampi(int(v), LIGHTGRID_FULL, LIGHTGRID_NONE)


func _black_grid_tex() -> ImageTexture3D:
	var img := Image.create(1, 1, false, Image.FORMAT_RGB8)
	img.fill(Color.BLACK)
	var tex := ImageTexture3D.new()
	tex.create(Image.FORMAT_RGB8, 1, 1, 1, false, [img])
	return tex


func _wave_func_id(name: String) -> int:
	match name.strip_edges().to_lower():
		"sin":
			return Tech3Noise.WAVE_SIN
		"square":
			return Tech3Noise.WAVE_SQUARE
		"triangle":
			return Tech3Noise.WAVE_TRIANGLE
		"sawtooth":
			return Tech3Noise.WAVE_SAWTOOTH
		"inversesawtooth":
			return Tech3Noise.WAVE_INVERSESAWTOOTH
		"noise":
			return Tech3Noise.WAVE_NOISE
		_:
			return Tech3Noise.WAVE_NOISE


func _parse_style_wave(value: String) -> Dictionary:
	var wave := BSPScene.default_wave()
	var parts := value.strip_edges().split(" ", false)
	if parts.is_empty():
		return wave
	var i := 0
	if parts[0].to_lower() == "wave":
		i = 1
	if i < parts.size():
		wave["func"] = _wave_func_id(parts[i])
		i += 1
	var fields := ["base", "amp", "phase", "freq"]
	for f in fields:
		if i >= parts.size():
			break
		wave[f] = parts[i].to_float()
		i += 1
	return wave


func _style_index_from_worldspawn_key(key: String) -> int:
	var compact := key.to_lower().replace(" ", "")
	# q3map2: _styleNrgbGen "wave sin ..."
	if compact.begins_with("_style") and compact.ends_with("rgbgen"):
		var mid := compact.trim_prefix("_style").trim_suffix("rgbgen")
		if mid.is_valid_int():
			return clampi(mid.to_int(), 0, BSPScene.STYLE_COUNT - 1)
		return -1
	# Raven: ls_N / ls_Nr / ls_Ng / ls_Nb  ("zzzzmmmm" a-z strings)
	if compact.begins_with("ls_"):
		var rest := compact.trim_prefix("ls_")
		if rest.ends_with("r") or rest.ends_with("g") or rest.ends_with("b"):
			rest = rest.substr(0, rest.length() - 1)
		if rest.is_valid_int():
			return clampi(rest.to_int(), 0, BSPScene.STYLE_COUNT - 1)
	return -1


func _apply_worldspawn_style_waves() -> void:
	# One 64-slot table for both formats.
	# Defaults: Quake letter strings on 1-11, switches on 32+.
	# IBSP q3map2 _styleNrgbGen overlays a wave and clears the pattern.
	# Raven ls_N replaces the scalar pattern (all channels).
	# Raven ls_Nr / ls_Ng / ls_Nb replace only that channel; the others
	# keep the slot's scalar pattern (the Quake default, or ls_N).
	# Slot 0 stays weight 1. Unused slots are left alone.
	var table: Array[Dictionary] = BSPScene.default_style_waves()
	if _worldspawn:
		for key in _worldspawn.keys():
			var raw_key := str(key)
			var idx := _style_index_from_worldspawn_key(raw_key)
			if idx <= 0:
				continue
			var compact := raw_key.to_lower().replace(" ", "")
			if compact.begins_with("_style"):
				# Wave is scalar (rgbGen). Drop any letter pattern so the
				# wave path owns the slot.
				table[idx] = _parse_style_wave(str(_worldspawn[key]))
				continue
			var val := str(_worldspawn[key]).strip_edges()
			if val.is_empty():
				continue
			var slot: Dictionary = table[idx] if table[idx] is Dictionary else BSPScene.default_wave()
			# Channel suffix wins over a bare ls_N for that channel only.
			# Bare ls_N replaces the scalar pattern and clears channel
			# overrides so every channel follows the new string.
			if compact.ends_with("r"):
				slot["pattern_r"] = val
				slot["on_pattern_r"] = val
			elif compact.ends_with("g"):
				slot["pattern_g"] = val
				slot["on_pattern_g"] = val
			elif compact.ends_with("b"):
				slot["pattern_b"] = val
				slot["on_pattern_b"] = val
			else:
				# Bare ls_N replaces the scalar pattern only. Channel
				# overrides already written by ls_Nr / ls_Ng / ls_Nb stay.
				# (Dictionary key order is not guaranteed, so don't
				# clear the channel keys here.)
				slot["pattern"] = val
				slot["on_pattern"] = val
			slot["enabled"] = true
			table[idx] = slot
	_bsp_scene.style_waves = table


func _worldspawn_defines_style(index: int) -> bool:
	if index <= 0 or not _worldspawn:
		return false
	for key in _worldspawn.keys():
		if _style_index_from_worldspawn_key(str(key)) == index:
			return true
	return false


func _collect_ibsp_style_ids() -> PackedInt32Array:
	# Map extra IBSP $lightmap stages onto entity style numbers, not
	# channel order. One light with style 2 -> first extra page samples 2.
	var ids: PackedInt32Array = PackedInt32Array()
	if _worldspawn:
		for key in _worldspawn.keys():
			var compact := str(key).to_lower().replace(" ", "")
			if not compact.begins_with("_style"):
				continue
			var idx := _style_index_from_worldspawn_key(str(key))
			if idx > 0 and not ids.has(idx):
				ids.append(idx)
	if ids.is_empty():
		for entity in _entities:
			if String(entity.get("classname", "")) != "light":
				continue
			var idx := _entity_light_style(entity)
			if idx > 0 and idx < BSPScene.STYLE_COUNT and not ids.has(idx):
				ids.append(idx)
	ids.sort()
	return ids


func _bind_ibsp_style_stages() -> void:
	if _is_rbsp or not _shader_library:
		return
	_shader_library.style_stage_ids = _collect_ibsp_style_ids()
	_shader_library.harvested_style_waves.clear()


func _merge_harvested_style_waves() -> void:
	if not _shader_library or not _bsp_scene:
		return
	if _bsp_scene.style_waves.size() < BSPScene.STYLE_COUNT:
		_bsp_scene.style_waves = BSPScene.default_style_waves()
	for idx in _shader_library.harvested_style_waves.keys():
		var slot := int(idx)
		if slot <= 0 or slot >= BSPScene.STYLE_COUNT:
			continue
		if _worldspawn_defines_style(slot):
			continue
		var wave = _shader_library.harvested_style_waves[idx]
		if wave is Dictionary:
			_bsp_scene.style_waves[slot] = wave


func _entity_light_style(entity: Dictionary) -> int:
	if not entity.has("style"):
		return 0
	var raw = entity["style"]
	if raw is int:
		return int(raw)
	return str(raw).to_int()


func _entity_float(entity: Dictionary, key: String, default_value: float = 0.0) -> float:
	if not entity.has(key):
		return default_value
	var raw = entity[key]
	if raw is float or raw is int:
		return float(raw)
	var s := str(raw).strip_edges()
	if s.is_empty():
		return default_value
	return s.to_float()


func _entity_int(entity: Dictionary, key: String, default_value: int = 0) -> int:
	if not entity.has(key):
		return default_value
	var raw = entity[key]
	if raw is int:
		return raw
	if raw is float:
		return int(raw)
	return str(raw).to_int()


# q3map2 CreateEntityLights: _light, else light, else 300; then * scale (0-1).
func _entity_light_intensity(entity: Dictionary) -> float:
	var intensity := _entity_float(entity, "_light", 0.0)
	if intensity == 0.0:
		intensity = _entity_float(entity, "light", 0.0)
	if intensity == 0.0:
		intensity = 300.0
	var scale := _entity_float(entity, "scale", 1.0)
	if scale == 0.0:
		scale = 1.0
	return intensity * scale


# q3map2 ColorNormalize(_color). Values may be 0–1 or 0–255.
# spawnflags 32 (netradiant-custom) keeps an un-normalized color.
func _entity_light_color(entity: Dictionary) -> Color:
	var c := Color.WHITE
	if entity.has("_color"):
		c = entity["_color"]
	elif entity.has("color"):
		c = entity["color"]
	else:
		return c
	if not c is Color:
		return Color.WHITE
	var flags := _entity_int(entity, "spawnflags", 0)
	if flags & 32:
		return c
	var m := maxf(maxf(c.r, c.g), c.b)
	if m <= 0.0:
		return Color.WHITE
	return Color(c.r / m, c.g / m, c.b / m)


func _apply_default_options() -> void:
	var defaults := default_options()
	if options.is_empty():
		options = defaults
		return
	for k in defaults.keys():
		if not options.has(k):
			options[k] = defaults[k]

var _bsp_file: Tech3DataStream

## Stream data from pk3's in the user directory.
class Tech3DataStream:
	var _data: PackedByteArray = PackedByteArray()
	var _pos: int = 0
	var _path: String = ""

	## Load a BSP byte buffer. path is only used for diagnostics and asset roots.
	func open_bytes(data: PackedByteArray, path: String = "memory.bsp") -> void:
		_data = data
		_pos = 0
		_path = path

	## Source path passed to open_bytes() (disk path or pk3://).
	func get_path() -> String:
		return _path

	## Move the read cursor. Clamped to the buffer.
	func seek(p: int) -> void:
		_pos = clampi(p, 0, _data.size())

	## Little-endian u32. Returns 0 at EOF.
	func get_32() -> int:
		if _pos + 4 > _data.size():
			return 0
		var v := _data.decode_u32(_pos)
		_pos += 4
		return v

	## Little-endian f32. Returns 0.0 at EOF.
	func get_float() -> float:
		if _pos + 4 > _data.size():
			return 0.0
		var v := _data.decode_float(_pos)
		_pos += 4
		return v

	## Next n bytes, or whatever remains.
	func get_buffer(n: int) -> PackedByteArray:
		var end := mini(_pos + n, _data.size())
		var sl := _data.slice(_pos, end)
		_pos = end
		return sl

	## Drop the buffer so the raw IBSP bytes can be freed.
	func close() -> void:
		_data = PackedByteArray()
		_pos = 0

	## Next byte as int. Returns 0 at EOF.
	func get_u8() -> int:
		if _pos >= _data.size():
			return 0
		var v := _data.decode_u8(_pos)
		_pos += 1
		return v

var _entities: Array[Dictionary]
var _plane_n: PackedVector3Array
var _plane_d: PackedFloat32Array
var _tex_name: PackedStringArray
var _tex_flags: PackedInt32Array
var _tex_contents: PackedInt32Array
var _model_mins: PackedVector3Array
var _model_maxs: PackedVector3Array
var _model_face: PackedInt32Array
var _model_num_faces: PackedInt32Array
var _model_brush: PackedInt32Array
var _model_num_brushes: PackedInt32Array
var _brush_first_side: PackedInt32Array
var _brush_num_sides: PackedInt32Array
var _brush_tex: PackedInt32Array
var _side_plane: PackedInt32Array
var _side_tex: PackedInt32Array
var _vertex_positions: PackedVector3Array
var _vertex_normals: PackedVector3Array
var _vertex_uvs: PackedVector2Array
var _vertex_uv2s: PackedVector2Array
var _vertex_colors: PackedColorArray
var _indices: PackedInt32Array # meshverts
var _effect_name: PackedStringArray
var _effect_brush: PackedInt32Array
var _fog_volumes: Array = [] # effect-index aligned: {planes, info, brush, tex}
var _face_tex: PackedInt32Array
var _face_type: PackedInt32Array
var _face_first_vert: PackedInt32Array
var _face_num_verts: PackedInt32Array
var _face_first_index: PackedInt32Array
var _face_num_indices: PackedInt32Array
var _face_lm: PackedInt32Array
var _face_lm1: PackedInt32Array
var _face_lm2: PackedInt32Array
var _face_lm3: PackedInt32Array
var _face_styles: PackedInt32Array # s0 | s1<<8 | s2<<16 | s3<<24, 0xFF = none
var _vertex_lm_uv1: PackedVector2Array
var _vertex_lm_uv2: PackedVector2Array
var _vertex_lm_uv3: PackedVector2Array
var _face_lm_off0: PackedVector2Array # lightmapX/Y luxels, slot 0
var _face_lm_off1: PackedVector2Array
var _face_lm_off2: PackedVector2Array
var _face_lm_off3: PackedVector2Array
var _face_lm_origin: PackedVector3Array
var _face_lm_vec0: PackedVector3Array
var _face_normal: PackedVector3Array
var _face_patch_w: PackedInt32Array
var _face_patch_h: PackedInt32Array
var _external_lightmaps: Array[Texture]
var _external_deluxemaps: Array[Texture]
var _deluxe_active: bool = false
var _deluxe_modelspace: bool = true
var _norm_binds := 0
var _gloss_binds := 0
var _want_tangents := false

var _light_grid_normalize := Vector3.ZERO
var _light_grid_offset := Vector3.ZERO
var _light_grid_ambient: ImageTexture3D
var _light_grid_direct: ImageTexture3D
var _light_grid_cartesian: ImageTexture3D
var _light_grid_ambient_1: ImageTexture3D
var _light_grid_ambient_2: ImageTexture3D
var _light_grid_ambient_3: ImageTexture3D
var _light_grid_direct_1: ImageTexture3D
var _light_grid_direct_2: ImageTexture3D
var _light_grid_direct_3: ImageTexture3D
var _light_grid_styles: ImageTexture3D

var _worldspawn: Dictionary
var _tech3_srgb := false

var _lightmap_atlas: ImageTexture
var _deluxe_atlas: ImageTexture
var _lightmap_columns := 0
var _lm_page_slot: PackedInt32Array = PackedInt32Array()
var _lightmap_rows := 0
var _lightmap_cell_size := DEFAULT_LIGHTMAP_SIZE
var _shader_library: Tech3ShaderLibrary
var _directory_map: Dictionary = {} # lowercase stem - actual res:// path
var _drop_portal_skies := false
var _is_rbsp := false

# using the BSP lump names here
# note that the final lump entry is not the Q3Live ads.
enum LUMP_TYPE {
	ENTITIES = 0,
	TEXTURES,
	PLANES,
	NODES,
	LEAFS,
	LEAFFACES,
	LEAFBRUSHES,
	MODELS,
	BRUSHES,
	BRUSHSIDES,
	VERTEXES,
	MESHVERTS, # _indices for vertices in meshes
	EFFECTS,
	FACES,
	LIGHTMAPS,
	LIGHTVOLS, # 3D volumetric light grid for dynamic objects
	VISDATA,
	LIGHTARRAY, # RBSP only: uint16 _indices into unique LIGHTVOLS samples
}

enum FACE_TYPE {
	NONE = 0,
	POLYGON,   # MST_PLANAR
	PATCH,     # MST_PATCH
	MESH,      # MST_TRIANGLE_SOUP
	BILLBOARD, # MST_FLARE
	FOLIAGE    # MST_FOLIAGE (q3map2 RBSP)
}

enum CONTENT_FLAGS {
	SOLID = 0x000001,
	LAVA = 0x000008,
	SLIME = 0x000010,
	WATER = 0x000020,
	FOG = 0x000040,
	AREAPORTAL = 0x008000,
	PLAYERCLIP = 0x010000,
	MONSTERCLIP = 0x020000,

	TELEPORTER = 0x040000,
	JUMPPAD = 0x080000,
	CLUSTERPORTAL = 0x100000,
	BOTSNOTENTER = 0x200000,

	ORIGIN = 0x1000000,

	BODY = 0x2000000,
	CORPSE = 0x4000000,
	DETAILS = 0x8000000,
	STRUCTURAL = 0x10000000,
	TRANSLUCENT = 0x20000000,
	TRIGGER = 0x40000000,
	NODROP = 0x80000000
}

# TODO: q3map2 reads a "custinfoparms.txt" in the "scripts" dir
# for mods to have custom surface flags. Let's support them too!
# obviously end users can also just rewrite this...
enum SURFACE_FLAGS {
	NOFALLDAMAGE = 0x00001,
	SLICK = 0x00002,
	SKY = 0x00004,
	LADDER = 0x00008,
	NOIMPACT = 0x00010,
	NOMARKS = 0x00020,
	FLESH = 0x00040,
	NODRAW = 0x00080,
	HINT = 0x00100,
	SKIP = 0x00200,
	NOLIGHTMAP = 0x00400,
	POINTLIGHT = 0x00800,
	METALSTEPS = 0x01000,
	NOSTEPS = 0x02000,
	NONSOLID = 0x04000,
	LIGHTFILTER = 0x08000,
	ALPHASHADOW = 0x10000,
	NODYNLIGHT = 0x20000
}

# Raven RBSP remaps almost every content/surface bit.
# e.g. CONTENTS_OPAQUE 0x8000 is Q3 AREAPORTAL - do not reuse IBSP masks on RBSP.
enum RBSP_CONTENTS {
	SOLID = 0x00000001,
	LAVA = 0x00000002,
	WATER = 0x00000004,
	FOG = 0x00000008,
	PLAYERCLIP = 0x00000010,
	MONSTERCLIP = 0x00000020,
	BOTCLIP = 0x00000040,
	SHOTCLIP = 0x00000080,
	BODY = 0x00000100,
	CORPSE = 0x00000200,
	TRIGGER = 0x00000400,
	NODROP = 0x00000800,
	TERRAIN = 0x00001000,
	LADDER = 0x00002000,
	ABSEIL = 0x00004000,
	OPAQUE = 0x00008000,
	OUTSIDE = 0x00010000,
	SLIME = 0x00020000,
	LIGHTSABER = 0x00040000,
	TELEPORTER = 0x00080000,
	ITEM = 0x00100000,
	NOSHOT = 0x00200000,
	DETAIL = 0x08000000,
	INSIDE = 0x10000000,
	TRANSLUCENT = 0x80000000
}

enum RBSP_SURFACE {
	SKY = 0x00002000,
	SLICK = 0x00004000,
	METALSTEPS = 0x00008000,
	FORCEFIELD = 0x00010000,
	NODAMAGE = 0x00040000,
	NOIMPACT = 0x00080000,
	NOMARKS = 0x00100000,
	NODRAW = 0x00200000,
	NOSTEPS = 0x00400000,
	NODLIGHT = 0x00800000,
	NOMISCENTS = 0x01000000,
	FORCESIGHT = 0x02000000
}


func _tex_ok(id: int) -> bool:
	return id >= 0 and id < _tex_name.size()


# where the magic begins...
## Map a Quake (X east, Y north, Z up) vector into Godot space.
## Usage: tech3_to_gd(Vector3(x, y, z)) — also accepts Vector3i. scale=true divides by options.unit_scale.
static func tech3_to_gd(in_vec: Variant, scale: bool = true) -> Variant:
	var out_vec: Variant
	if (in_vec is Vector3):
		out_vec = Vector3(-in_vec.x, in_vec.z, in_vec.y)
	elif (in_vec is Vector3i):
		out_vec = Vector3i(int(-in_vec.x), int(in_vec.z), int(in_vec.y))
	else:
		push_error("tech3bsp::tech3_to_gd didn't receive a Vector3 or Vector3i!!!")
		return null

	if (scale):
		out_vec *= (1.0 / options.unit_scale)

	return out_vec


func _assets_path() -> String:
	var override := String(options.get("assets_path_override", ""))
	if not override.is_empty():
		return override
	if _bsp_file:
		return _bsp_file.get_path().get_base_dir().get_base_dir()
	return "res://"


func _map_key_from_path(path: String) -> String:
	var root := _assets_path().replace("\\", "/").trim_suffix("/")
	var stem := path.replace("\\", "/").get_basename()
	if stem.begins_with(root + "/"):
		stem = stem.substr(root.length() + 1)
	elif stem.begins_with("res://"):
		stem = stem.substr(6)
	return stem.to_lower()


func _recurse_directory_map(dir: String) -> void:
	var d := DirAccess.open(dir)
	if !d:
		return
	d.list_dir_begin()
	var file_name := d.get_next()
	while file_name != "":
		if file_name == "." or file_name == ".." or file_name.begins_with("."):
			file_name = d.get_next()
			continue
		var path := dir.path_join(file_name)
		if d.current_is_dir():
			if file_name.to_lower() in ["addons", "godot", ".godot"]:
				file_name = d.get_next()
				continue
			_recurse_directory_map(path)
		elif file_name.get_extension().to_lower() in POSSIBLE_IMAGE_EXTENSIONS:
			var key := _map_key_from_path(path)
			if key != "" and not _directory_map.has(key):
				_directory_map[key] = path
		file_name = d.get_next()
	d.list_dir_end()


func _build_directory_map() -> void:
	_directory_map.clear()
	var roots: PackedStringArray = []
	var assets := _as_project_path(_assets_path())
	if assets != "":
		roots.append(assets)
	if assets != "res://":
		roots.append("res://")
	for root in roots:
		_recurse_directory_map(root)
	print("tech3bsp: indexed %d textures" % _directory_map.size())


func _resolve_image_path(logical: String) -> String:
	var key := logical.replace("\\", "/").get_basename().to_lower()
	if key.begins_with("res://"):
		key = key.substr(6)
	var hit := _directory_map_get(key)
	if hit != "":
		return hit
	# Xonotic (and similar): textures/foo -> dds/textures/foo.dds
	if not key.begins_with("dds/"):
		return _directory_map_get("dds/%s" % key)
	return ""


func _directory_map_get(key: String) -> String:
	if _directory_map.has(key):
		return String(_directory_map[key])
	var assets := _as_project_path(_assets_path()).replace("\\", "/").trim_suffix("/")
	var with_root := key
	if assets != "" and assets != "res://":
		var prefix := assets.substr(6) if assets.begins_with("res://") else assets
		if prefix != "" and key.begins_with(prefix + "/"):
			with_root = key.substr(prefix.length() + 1)
			if _directory_map.has(with_root):
				return String(_directory_map[with_root])
	return ""


func _as_project_path(path: String) -> String:
	var p := path.replace("\\", "/").strip_edges()
	if p == "":
		return "res://"
	if p.begins_with("res://") or p.begins_with("user://"):
		return p
	while p.begins_with("/"):
		p = p.substr(1)
	return "res://" + p


## Parse a space-separated Q3 entity vector string into Vector3.
## Usage: string_to_vector3("128 64 0")
func string_to_vector3(vec3: String) -> Vector3:
	var components = vec3.split_floats(" ", false)
	return Vector3(components[0], components[1], components[2])


## Parse a space-separated Q3 entity vector string into Vector3i.
## Usage: string_to_vector3i("64 64 128")
func string_to_vector3i(vec3i: String) -> Vector3i:
	var components = vec3i.split_floats(" ", false)
	return Vector3i(int(components[0]), int(components[1]), int(components[2]))


## Q3 AngleVectors: pitch/yaw/roll degrees → {forward, right, up} in Quake space.
## Usage: var axes := Tech3BSPReader.tech3_angle_vectors(Vector3(pitch, yaw, roll))
static func tech3_angle_vectors(pitch_yaw_roll: Vector3) -> Dictionary:
	var pr := deg_to_rad(pitch_yaw_roll.x)
	var yr := deg_to_rad(pitch_yaw_roll.y)
	var rr := deg_to_rad(pitch_yaw_roll.z)
	var sy := sin(yr)
	var cy := cos(yr)
	var sp := sin(pr)
	var cp := cos(pr)
	var sr := sin(rr)
	var cr := cos(rr)
	return {
		"forward": Vector3(cp * cy, cp * sy, -sp),
		"right": Vector3(-sr * sp * cy + -cr * -sy, -sr * sp * sy + -cr * cy, -sr * cp),
		"up": Vector3(cr * sp * cy + -sr * -sy, cr * sp * sy + -sr * cy, cr * cp),
	}


## Door / plat move direction from entity angle + angles, in Godot space.
## angle -1 is up, -2 is down. Usage: Tech3BSPReader.tech3_movedir(angle, angles)
static func tech3_movedir(angle: float = 0.0, angles: Vector3 = Vector3.ZERO) -> Vector3:
	if angle == -1.0:
		return Vector3.UP
	if angle == -2.0:
		return Vector3.DOWN
	var pyr := angles
	if is_zero_approx(angles.x) and is_zero_approx(angles.y) and is_zero_approx(angles.z):
		pyr = Vector3(0.0, angle, 0.0)
	elif is_zero_approx(angle) and not angles.is_zero_approx():
		pyr = angles
	else:
		# 'angle' overwrites yaw
		pyr = Vector3(angles.x, angle, angles.z)
	var fwd: Vector3 = tech3_angle_vectors(pyr)["forward"]
	var gd: Vector3 = tech3_to_gd(fwd, false)
	if gd.length_squared() < 0.000001:
		return Vector3(-1.0, 0.0, 0.0)
	return gd.normalized()


## Build a Godot Basis (-Z forward) from Q3 pitch/yaw/roll degrees.
## Usage: node.basis = Tech3BSPReader.tech3_angles_to_basis(angles)
static func tech3_angles_to_basis(angles: Vector3) -> Basis:
	var axes := tech3_angle_vectors(angles)
	var f: Vector3 = tech3_to_gd(axes["forward"], false)
	var u: Vector3 = tech3_to_gd(axes["up"], false)
	if f.length_squared() < 0.000001:
		f = Vector3(-1.0, 0.0, 0.0)
	else:
		f = f.normalized()
	if u.length_squared() < 0.000001:
		u = Vector3.UP
	else:
		u = u.normalized()
	if absf(f.dot(u)) > 0.999:
		u = Vector3.UP if absf(f.dot(Vector3.UP)) < 0.999 else Vector3.FORWARD
	return Basis.looking_at(f, u)


## Yaw-only variant of tech3_angles_to_basis, including Q3 -1 / -2 up / down.
## Usage: node.basis = Tech3BSPReader.tech3_angle_to_basis(angle)
static func tech3_angle_to_basis(angle: float) -> Basis:
	if angle == -1.0:
		return Basis.looking_at(Vector3.UP, Vector3.FORWARD)
	if angle == -2.0:
		return Basis.looking_at(Vector3.DOWN, Vector3.FORWARD)
	return tech3_angles_to_basis(Vector3(0.0, angle, 0.0))


func _entity_orientation(entity: Dictionary) -> Dictionary:
	var has_angle := entity.has("angle")
	var has_angles := entity.has("angles")
	var angle := float(entity.get("angle", 0.0))
	var angles := Vector3.ZERO
	if has_angles and entity["angles"] is Vector3:
		angles = entity["angles"]
	var movedir := Vector3(-1.0, 0.0, 0.0)
	var basis := Basis.IDENTITY
	if has_angle or has_angles:
		movedir = Tech3BSPReader.tech3_movedir(angle if has_angle else 0.0, angles)
		if has_angle and (angle == -1.0 or angle == -2.0):
			basis = Tech3BSPReader.tech3_angle_to_basis(angle)
		elif has_angles and not has_angle:
			basis = Tech3BSPReader.tech3_angles_to_basis(angles)
		else:
			basis = Tech3BSPReader.tech3_angle_to_basis(angle)
	return {"movedir": movedir, "basis": basis, "oriented": has_angle or has_angles}


# q3map2 -deluxe writes deluxeMaps 1 (model/world space) or 2 (tangent).
func _worldspawn_deluxe_mode() -> int:
	if not _worldspawn:
		return 0
	for raw_key in _worldspawn.keys():
		var key := str(raw_key)
		var compact := key.to_lower().replace(" ", "")
		if compact not in ["deluxemaps", "_deluxe", "deluxe"]:
			continue
		var v := str(_worldspawn[key]).strip_edges()
		if v == "2":
			return 2
		if v == "1" or v.to_lower() in ["true", "yes"]:
			return 1
	var blob := ""
	for key in ["_q3map2_cmdline", "message"]:
		if _worldspawn.has(key):
			blob += str(_worldspawn[key]).to_lower() + " "
	if not blob.contains("-deluxe") and not blob.contains("deluxemaps"):
		return 0
	# q3map2 -deluxemode 0 is model space. 1 is tangent space.
	var mode_at := blob.find("-deluxemode")
	if mode_at >= 0:
		var rest := blob.substr(mode_at + 11).strip_edges()
		var n := rest.split(" ")[0]
		if n == "1":
			return 2
	return 1


func _lm_page_index(path: String) -> int:
	var base := path.replace("\\", "/").get_file().get_basename().to_lower()
	if not base.begins_with("lm_"):
		return -1
	var rest := base.substr(3)
	var num := rest.split("_")[0]
	if not num.is_valid_int():
		return -1
	return num.to_int()


func _lm_path_is_deluxe(path: String) -> bool:
	var base := path.replace("\\", "/").get_file().get_basename().to_lower()
	return "_deluxe" in base


func _worldspawn_uses_srgb() -> bool:
	var blob := ""
	for key in ["_q3map2_cmdline", "message"]:
		if _worldspawn.has(key):
			blob += str(_worldspawn[key]) + " "
	var s := blob.to_lower()
	if s.contains("nosrgb"):
		return false
	return s.contains("srgb")

# pre-convert sRGB if detected rather than do it in shaders
func _to_linear(c: Color) -> Color:
	if not _tech3_srgb:
		return c
	return c.srgb_to_linear()


# Baked vertex light uses the lightmap path: byte scale, then the same sRGB decode.
func _vertex_light_color(c: Color) -> Color:
	var scaled := _to_linear(scale_color(Color(c.r * 255.0, c.g * 255.0, c.b * 255.0)))
	scaled.a = c.a
	return scaled


## Apply light_brightness_multiplier (and optional sRGB) to an imported color.
## Usage: omni.light_color = scale_color(entity_color)
func scale_color(color: Color) -> Color:
	var scale := 1.0
	var temp: float
	color = color / 255.0
	
	for i in range(3):
		if color[i] > 1.0:
			temp = 1.0 / color[i]
			if temp < scale:
				scale = temp
		color[i] *= scale
	
	return color


# for those pesky straight up/down spotlights
## Transform looking from origin toward target with a stable up vector.
## Usage: light.transform = look_at_safely(origin, target)
func look_at_safely(origin: Vector3, target: Vector3) -> Transform3D:
	var direction = (target - origin).normalized()
	var up = Vector3.UP

	# Check for colinearity with "up" vector
	if abs(direction.dot(up)) > 0.999:
		up = Vector3.FORWARD

	var basis = Basis().looking_at(direction, up)
	return Transform3D(basis, origin)


# Godot doesn't convert signed ints with "get_32" etc.
## Reinterpret an unsigned 32-bit BSP int as signed (shaderNum, indices).
## Usage: var n := Tech3BSPReader.to_signed32(raw)
static func to_signed32(value: int) -> int:
	if value >= 0x80000000:
		return value - 0x100000000
	return value


## Drop the last parse (arrays, lightgrid textures, scene) so the reader can be reused.
## Usage: reader.clear_data() - read_bsp() already calls this.
func clear_data() -> void:
	_is_rbsp = false
	if _bsp_scene:
		_bsp_scene.free()
	if _bsp_file:
		_bsp_file.close()
		_bsp_file = null
	_entities.clear()
	_plane_n.clear()
	_plane_d.clear()
	_tex_name.clear()
	_tex_flags.clear()
	_tex_contents.clear()
	_model_mins.clear()
	_model_maxs.clear()
	_model_face.clear()
	_model_num_faces.clear()
	_model_brush.clear()
	_model_num_brushes.clear()
	_brush_first_side.clear()
	_brush_num_sides.clear()
	_brush_tex.clear()
	_side_plane.clear()
	_side_tex.clear()
	_vertex_positions.clear()
	_vertex_normals.clear()
	_vertex_uvs.clear()
	_vertex_uv2s.clear()
	_vertex_lm_uv1.clear()
	_vertex_lm_uv2.clear()
	_vertex_lm_uv3.clear()
	_vertex_colors.clear()
	_indices.clear()
	_effect_name.clear()
	_effect_brush.clear()
	_fog_volumes.clear()
	_face_tex.clear()
	_face_type.clear()
	_face_first_vert.clear()
	_face_num_verts.clear()
	_face_first_index.clear()
	_face_num_indices.clear()
	_face_lm.clear()
	_face_lm1.clear()
	_face_lm2.clear()
	_face_lm3.clear()
	_face_styles.clear()
	_face_lm_off0.clear()
	_face_lm_off1.clear()
	_face_lm_off2.clear()
	_face_lm_off3.clear()
	_face_lm_origin.clear()
	_face_lm_vec0.clear()
	_face_normal.clear()
	_face_patch_w.clear()
	_face_patch_h.clear()
	_external_lightmaps.clear()
	_external_deluxemaps.clear()
	_deluxe_active = false
	_directory_map.clear()
	_drop_portal_skies = false
	_light_grid_normalize = Vector3.ZERO
	_light_grid_offset = Vector3.ZERO
	if _light_grid_ambient:
		_light_grid_ambient.free()
	if _light_grid_direct:
		_light_grid_direct.free()
	if _light_grid_cartesian:
		_light_grid_cartesian.free()
	if _light_grid_ambient_1:
		_light_grid_ambient_1.free()
	if _light_grid_ambient_2:
		_light_grid_ambient_2.free()
	if _light_grid_ambient_3:
		_light_grid_ambient_3.free()
	if _light_grid_direct_1:
		_light_grid_direct_1.free()
	if _light_grid_direct_2:
		_light_grid_direct_2.free()
	if _light_grid_direct_3:
		_light_grid_direct_3.free()
	if _light_grid_styles:
		_light_grid_styles.free()


func _release_parse_arrays() -> void:
	_plane_n.clear()
	_plane_d.clear()
	_tex_name.clear()
	_tex_flags.clear()
	_tex_contents.clear()
	_model_mins.clear()
	_model_maxs.clear()
	_model_face.clear()
	_model_num_faces.clear()
	_model_brush.clear()
	_model_num_brushes.clear()
	_brush_first_side.clear()
	_brush_num_sides.clear()
	_brush_tex.clear()
	_side_plane.clear()
	_side_tex.clear()
	_vertex_positions.clear()
	_vertex_normals.clear()
	_vertex_uvs.clear()
	_vertex_uv2s.clear()
	_vertex_lm_uv1.clear()
	_vertex_lm_uv2.clear()
	_vertex_lm_uv3.clear()
	_vertex_colors.clear()
	_indices.clear()
	_effect_name.clear()
	_effect_brush.clear()
	_fog_volumes.clear()
	_face_tex.clear()
	_face_type.clear()
	_face_first_vert.clear()
	_face_num_verts.clear()
	_face_first_index.clear()
	_face_num_indices.clear()
	_face_lm.clear()
	_face_lm1.clear()
	_face_lm2.clear()
	_face_lm3.clear()
	_face_styles.clear()
	_face_lm_off0.clear()
	_face_lm_off1.clear()
	_face_lm_off2.clear()
	_face_lm_off3.clear()
	_face_lm_origin.clear()
	_face_lm_vec0.clear()
	_face_normal.clear()
	_face_patch_w.clear()
	_face_patch_h.clear()
	_entities.clear()
	_directory_map.clear()
	_external_lightmaps.clear()
	_external_deluxemaps.clear()
	_deluxe_active = false
	if _shader_library:
		_shader_library.release_caches()
	_shader_library = null
	_bsp_file = null
	Tech3Pk3.clear_caches()


# Metadata for runtime tracing (footsteps, impacts, friction, etc.)
func _apply_contact_meta(node: Node, tid: int) -> void:
	if node == null or not _tex_ok(tid):
		return
	_ensure_shader_library()
	if !_shader_library:
		return
	var def = _shader_library.get_shader(_tex_name[tid])
	if def == null:
		return
	if def.q3map_material != "":
		node.set_meta("tech3_material", def.q3map_material)
	if def.surfaceparms.size() > 0:
		node.set_meta("surfaceparms", def.surfaceparms)


func _shader_nolightmap(texture_id: int) -> bool:
	if not _tex_ok(texture_id):
		return false
	_ensure_shader_library()
	if !_shader_library:
		return false
	var def = _shader_library.get_shader(_tex_name[texture_id])
	return def != null and def.nolightmap


func _face_lm_slot(fi: int, slot: int) -> int:
	match slot:
		1:
			return _face_lm1[fi] if fi < _face_lm1.size() else -1
		2:
			return _face_lm2[fi] if fi < _face_lm2.size() else -1
		3:
			return _face_lm3[fi] if fi < _face_lm3.size() else -1
		_:
			return _face_lm[fi] if fi < _face_lm.size() else -1


func _face_style_slot(fi: int, slot: int) -> int:
	if fi < 0 or fi >= _face_styles.size():
		return RBSP_LS_NONE
	return (_face_styles[fi] >> (slot * 8)) & 0xFF


func _face_uses_lightmap(fi: int) -> bool:
	if not options.import_lightmaps:
		return false
	if _shader_nolightmap(_face_tex[fi]):
		return false
	var any_page := _face_lm[fi] >= 0 or (fi < _face_lm1.size() and (_face_lm1[fi] >= 0 or _face_lm2[fi] >= 0 or _face_lm3[fi] >= 0))
	if not any_page:
		return false
	# q3map2 bakes vertex colors *and* lightmaps on world faces.
	# Default is lightmaps for brushes/patches.
	# MESH/misc_model is vertex-lit unless q3map2 allocated a chart.
	# JA writes lightmapWidth/Height = 0 on every face.
	return true


func _face_style_attr(fi: int) -> Color:
	return Color(
		float(_face_style_slot(fi, 0)) / 255.0,
		float(_face_style_slot(fi, 1)) / 255.0,
		float(_face_style_slot(fi, 2)) / 255.0,
		float(_face_style_slot(fi, 3)) / 255.0
	)


func _lm_page_uv(uv: Vector2, _fi: int, _slot: int) -> Vector2:
	return uv


func _atlas_or_raw(uv: Vector2, lm_id: int) -> Vector2:
	if lm_id >= 0 and _external_lightmaps.is_empty() and _lightmap_columns:
		return _atlas_uv2(uv, lm_id)
	return uv


func _lm_atlas_uv(uv: Vector2, fi: int, slot: int) -> Vector2:
	return _atlas_or_raw(_lm_page_uv(uv, fi, slot), _face_lm_slot(fi, slot))


func _material_from_path(texture_id: int, lightmap_id: int, use_lm: bool = true) -> Material:
	var path_pattern: String = options.materials_path
	var texture_name: String = _tex_name[texture_id]
	var material: Material
	var actual_material_path := ""

	var candidates: PackedStringArray = [
		_as_project_path(path_pattern.replace("{texture_name}", texture_name)),
	]
	for c in candidates:
		if FileAccess.file_exists(c):
			actual_material_path = c
			break

	var overwrite_saved := bool(options.get("overwrite_converted_shaders", false))
	if actual_material_path != "" and not overwrite_saved:
		var loaded = load(actual_material_path)
		if loaded is Material:
			if use_lm:
				material = loaded.duplicate()
				if not _mat_samples_lightmap(material):
					material = null
			else:
				material = loaded
	if material == null:
		if bool(options.get("use_tech3_shaders", true)):
			material = _material_from_tech3_shader(texture_id, lightmap_id if use_lm else -1)
		if !material:
			material = _material_from_texture(texture_id, lightmap_id if use_lm else -1)

	# for lightmaps to work we have to make some assumptions,
	# the shader being used must have some uniform like "lightmap_texture"
	# so it will have to be a custom shader, this won't work for StandardMaterial3D.
	if material is ShaderMaterial and _mat_samples_lightmap(material):
		if _external_lightmaps.is_empty() and _lightmap_atlas:
			material.set_shader_parameter("lightmap_texture", _lightmap_atlas)
		elif lightmap_id >= 0 and lightmap_id < _external_lightmaps.size():
			material.set_shader_parameter("lightmap_texture", _external_lightmaps[lightmap_id])
	_bind_deluxe(material, lightmap_id)
	return material


func _ensure_shader_library() -> void:
	if _shader_library:
		return
	_shader_library = Tech3ShaderLibrary.new()
	_shader_library.configure_from_options(options, _bsp_file.get_path() if _bsp_file else "")
	_shader_library.directory_map = _directory_map
	_shader_library.load_scripts()


func _deluxe_texture(lightmap_id: int) -> Texture:
	if not _deluxe_active or lightmap_id < 0:
		return null
	if _deluxe_atlas:
		return _deluxe_atlas
	if lightmap_id >= _external_deluxemaps.size():
		return null
	return _external_deluxemaps[lightmap_id]


func _bind_deluxe(material: Material, lightmap_id: int, stem: String = "") -> void:
	if not (material is ShaderMaterial):
		return
	var mat := material as ShaderMaterial
	if _deluxe_active:
		var dx := _deluxe_texture(lightmap_id)
		if dx:
			_set_uniform(mat, "deluxemap_texture", dx)
			_set_uniform(mat, "tech3_deluxe", 1.0)
	if stem == "":
		if mat.has_meta("tech3_shader"):
			var shader_name := str(mat.get_meta("tech3_shader"))
			if shader_name != "":
				stem = shader_name
	if stem == "":
		return
	_bind_deluxe_maps(mat, stem)


func _load_reflect_cube(path: String) -> Cubemap:
	var faces := ["_lf", "_rt", "_dn", "_up", "_ft", "_bk"]
	var images: Array[Image] = []
	for face in faces:
		var tex := Tech3Pk3.resolve_texture(path + face, true)
		if tex == null:
			push_warning("tech3bsp: reflect cube missing %s%s" % [path, face])
			return null
		var img: Image = tex.get_image()
		if img == null:
			return null
		images.append(img)
	var cube := Cubemap.new()
	cube.create_from_images(images)
	return cube


func _companion_from_def(stem: String) -> String:
	if not _shader_library:
		return ""
	var def = _shader_library.get_shader(stem)
	if not def:
		return ""
	for st in def.stages:
		if st.is_lightmap or st.maps.is_empty():
			continue
		var map := str(st.maps[0])
		if map != "" and not map.begins_with("$"):
			return map
	return ""


func _companion_texture(logical: String) -> Texture2D:
	var tex := Tech3Pk3.resolve_texture(logical, true)
	if tex:
		return tex
	var path := _resolve_image_path(logical)
	if path == "":
		return null
	if logical.ends_with("_norm"):
		_ensure_norm_rgtc(path)
		_remember_resource_height(logical, path)
	var loaded = load(path)
	if loaded is Texture2D:
		return loaded
	return null


func _remember_resource_height(logical: String, path: String) -> void:
	if Tech3Pk3.norm_height(logical):
		return
	if path == "" or not FileAccess.file_exists(path):
		return
	var img := Image.new()
	var data := FileAccess.get_file_as_bytes(path)
	var ext := path.get_extension().to_lower()
	var err := ERR_FILE_UNRECOGNIZED
	if ext == "png":
		err = img.load_png_from_buffer(data)
	elif ext in ["jpg", "jpeg"]:
		err = img.load_jpg_from_buffer(data)
	elif ext == "tga":
		err = img.load_tga_from_buffer(data)
	elif ext == "webp":
		err = img.load_webp_from_buffer(data)
	elif ext == "dds":
		err = img.load_dds_from_buffer(data)
	elif ext == "bmp":
		err = img.load_bmp_from_buffer(data)
	if err != OK:
		return
	Tech3Pk3.remember_norm_height(logical, img)


func _ensure_norm_rgtc(path: String) -> void:
	# Godot rewrites a normal map the first time a material uses it.
	# Force RGTC up front so the import does not change later.
	if not path.begins_with("res://") or not FileAccess.file_exists(path + ".import"):
		return
	var cfg := ConfigFile.new()
	if cfg.load(path + ".import") != OK:
		return
	if int(cfg.get_value("params", "compress/normal_map", 2)) == 1:
		return
	cfg.set_value("params", "compress/normal_map", 1)
	cfg.set_value("params", "compress/mode", 2)
	cfg.save(path + ".import")
	if Engine.is_editor_hint() and EditorInterface.get_resource_filesystem():
		EditorInterface.get_resource_filesystem().reimport_files(PackedStringArray([path]))


func _bind_deluxe_maps(mat: ShaderMaterial, stem: String) -> void:
	var norm := _companion_texture(stem + "_norm")
	var bump := _companion_texture(stem + "_bump")
	if !norm and !bump:
		var map_stem := _companion_from_def(stem)
		if map_stem != "" and map_stem != stem:
			norm = _companion_texture(map_stem + "_norm")
			bump = _companion_texture(map_stem + "_bump")
			if norm or bump:
				stem = map_stem
	if norm:
		_set_uniform(mat, "normal_texture", norm)
		_set_uniform(mat, "tech3_has_normal", 1.0)
		_norm_binds += 1

		_set_uniform(mat, "tech3_offset_scale", 0.02)
		_set_uniform(mat, "tech3_offset_bias", 0.0)
		var height := Tech3Pk3.norm_height(stem + "_norm")
		if height:
			_set_uniform(mat, "offset_texture", height)
			_set_uniform(mat, "tech3_has_offset", 1.0)
	elif bump:
		_set_uniform(mat, "normal_texture", bump)
		_set_uniform(mat, "tech3_has_height", 1.0)
		_want_tangents = true
	var gloss := _companion_texture(stem + "_gloss")
	if gloss:
		_set_uniform(mat, "gloss_texture", gloss)
		_set_uniform(mat, "tech3_has_gloss", 1.0)
		_gloss_binds += 1
	var glow := _companion_texture(stem + "_glow")
	if !glow:
		glow = _companion_texture(stem + "_luma")
	if glow:
		_set_uniform(mat, "glow_texture", glow)
		_set_uniform(mat, "tech3_has_glow", 1.0)
	if _shader_library:
		var def = _shader_library.get_shader(stem)
		if def:
			_set_uniform(mat, "tech3_gloss_intensity", def.gloss_intensity)
			_set_uniform(mat, "tech3_gloss_exponent", def.gloss_exponent)
			if def.offset_mode > 0:
				_want_tangents = true
				_set_uniform(mat, "tech3_offset_scale", def.offset_scale * 0.02)
				_set_uniform(mat, "tech3_offset_bias", def.offset_bias)
			if def.reflect_cube != "":
				var cube := _load_reflect_cube(def.reflect_cube)
				if cube:
					_set_uniform(mat, "reflect_cube", cube)
					_set_uniform(mat, "tech3_has_cube", 1.0)
				var mask := Tech3Pk3.resolve_texture(stem + "_reflect", true)
				if !mask:
					var map_stem := _companion_from_def(stem)
					if map_stem != "":
						mask = Tech3Pk3.resolve_texture(map_stem + "_reflect", true)
				if mask:
					_set_uniform(mat, "reflect_mask", mask)
					_set_uniform(mat, "tech3_has_reflect", 1.0)


func _shader_has_uniform(mat: ShaderMaterial, name: String) -> bool:
	var sh: Shader = mat.shader
	if sh == null:
		return false
	for u in sh.get_shader_uniform_list():
		if str(u.get("name", "")) == name:
			return true
	return false


func _set_uniform(mat: ShaderMaterial, name: String, value) -> void:
	if _shader_has_uniform(mat, name):
		mat.set_shader_parameter(name, value)


func _mat_samples_lightmap(mat: Material) -> bool:
	if not (mat is ShaderMaterial):
		return false
	var sh: Shader = (mat as ShaderMaterial).shader
	if sh == null:
		return false
	for u in sh.get_shader_uniform_list():
		if String(u.get("name", "")) == "lightmap_texture":
			return true
	return false


func _material_from_tech3_shader(texture_id: int, lightmap_id: int) -> Material:
	_ensure_shader_library()
	var texture_name: String = _tex_name[texture_id]
	if not _shader_library.has_shader(texture_name):
		return null
	var lm_tex: Texture = null
	if options.import_lightmaps:
		if not _external_lightmaps.is_empty() and lightmap_id >= 0 and lightmap_id < _external_lightmaps.size():
			lm_tex = _external_lightmaps[lightmap_id]
		elif _lightmap_atlas:
			lm_tex = _lightmap_atlas
	var dx := _deluxe_texture(lightmap_id)
	_shader_library.deluxe_modelspace = _deluxe_modelspace
	_shader_library.deluxe_active = _deluxe_active
	_shader_library.companion_flags = _companion_flags(texture_name)
	var material := _shader_library.build_material(texture_name, lightmap_id, lm_tex, dx)
	if material is FogMaterial:
		return material
	if material is ShaderMaterial and lm_tex:
		material.set_shader_parameter("lightmap_texture", lm_tex)
	_bind_deluxe(material, lightmap_id)
	return material


func _companion_flags(stem: String) -> int:
	var flags := 0
	var stems: PackedStringArray = []
	if stem != "":
		stems.append(stem)
	var map_stem := _companion_from_def(stem)
	if map_stem != "" and map_stem != stem:
		stems.append(map_stem)

	for s in stems:
		if _companion_texture(s + "_norm"):
			flags |= 1
		if _companion_texture(s + "_bump"):
			flags |= 8
		if _companion_texture(s + "_gloss"):
			flags |= 2
		if _companion_texture(s + "_glow") or _companion_texture(s + "_luma"):
			flags |= 4
		if _companion_texture(s + "_reflect"):
			flags |= 16
	return flags


func _face_wants_deluxe(shader_name: String, lightmap_id: int) -> bool:
	# Deluxe on-disk shaders sample the lightmap page. No page, no deluxe program.
	if not options.import_lightmaps or lightmap_id < 0:
		return false
	if _deluxe_texture(lightmap_id) != null:
		return true
	return _companion_flags(shader_name) != 0


func _default_shader(lightmap_id: int, shader_name: String = "") -> Shader:
	if _face_wants_deluxe(shader_name, lightmap_id):
		return load("res://addons/tech3bsp/shaders/deluxe_lightmap.gdshader") if _deluxe_modelspace else load("res://addons/tech3bsp/shaders/deluxe_lightmap_tangent.gdshader")
	if options.import_lightmaps and lightmap_id >= 0:
		return load("res://addons/tech3bsp/shaders/standard_lightmap.gdshader")
	return load("res://addons/tech3bsp/shaders/standard_vertex.gdshader")


# grab companion textures for DP materials (better Xonotic support)
func _fill_standard_companions(material: StandardMaterial3D, stem: String) -> void:
	var norm := _companion_texture(stem + "_norm")
	var bump := _companion_texture(stem + "_bump")
	var gloss := _companion_texture(stem + "_gloss")
	var glow := _companion_texture(stem + "_glow")
	if !glow:
		glow = _companion_texture(stem + "_luma")
	if !norm and !bump and !gloss and !glow:
		var map_stem := _companion_from_def(stem)
		if map_stem != "" and map_stem != stem:
			stem = map_stem
			norm = _companion_texture(stem + "_norm")
			bump = _companion_texture(stem + "_bump")
			gloss = _companion_texture(stem + "_gloss")
			glow = _companion_texture(stem + "_glow")
	if norm:
		material.normal_enabled = true
		material.normal_texture = norm
	elif bump:
		material.heightmap_enabled = true
		material.heightmap_texture = bump
	if gloss:
		material.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
		material.roughness_texture = gloss
		material.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	else:
		material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	if glow:
		material.emission_enabled = true
		material.emission_texture = glow


func _material_from_texture(texture_id: int, lightmap_id: int) -> Material:
	var material: Material
	var face_texture: Texture2D
	var shader_name: String = _tex_name[texture_id].replace("\\", "/")
	var pack_tex := Tech3Pk3.resolve_texture(shader_name)
	if pack_tex:
		face_texture = pack_tex
	var mapped := _resolve_image_path(shader_name)
	if !face_texture and mapped != "":
		var res = load(mapped)
		if res is Texture2D:
			face_texture = res
	if !face_texture:
		# Exact lump name relative to the assets root. dds/ is the Xonotic copy.
		var stems: PackedStringArray = [_as_project_path(_assets_path()).path_join(shader_name)]
		if not shader_name.to_lower().begins_with("dds/"):
			stems.append(_as_project_path(_assets_path()).path_join("dds").path_join(shader_name))
			stems.append("res://".path_join("dds").path_join(shader_name))
		for stem in stems:
			var found := false
			for ext: String in POSSIBLE_IMAGE_EXTENSIONS:
				var possible_file := "%s.%s" % [stem, ext]
				if FileAccess.file_exists(possible_file):
					face_texture = load(possible_file)
					found = true
					break
			if found:
				break

	if !face_texture:
		material = ShaderMaterial.new()
		material.shader = _default_shader(lightmap_id, shader_name)
		material.set_shader_parameter("albedo_color", Color(randf(), randf(), randf(), 1.0))
	else:
		if !options.import_vertex_colors and !options.import_lightmaps:
			material = StandardMaterial3D.new()
			material.albedo_texture = face_texture
			_fill_standard_companions(material, shader_name)
			return material

		material = ShaderMaterial.new()
		material.shader = _default_shader(lightmap_id, shader_name)
	
	# this check is probably unnecessary at this point, but just in case
	if material is ShaderMaterial:
		if options.import_lightmaps and lightmap_id >= 0:
			if _external_lightmaps.is_empty():
				material.set_shader_parameter("lightmap_texture", _lightmap_atlas)
			elif lightmap_id < _external_lightmaps.size():
				material.set_shader_parameter("lightmap_texture", _external_lightmaps[lightmap_id])
		_bind_deluxe(material, lightmap_id, shader_name)
		material.set_shader_parameter("albedo_texture", face_texture)
	
	return material


func _parse_lumps(count: int = IBSP_LUMP_COUNT) -> Array[Dictionary]:
	var lumps: Array[Dictionary]
	for i in range(count):
		var bsp_dir_entry: Dictionary = {
			offset = _bsp_file.get_32(),
			length = _bsp_file.get_32()
		}
		lumps.append(bsp_dir_entry)
	return lumps


func _parse_entities(ent_lump) -> void:
	_bsp_file.seek(ent_lump.offset)
	var entities_string := _bsp_file.get_buffer(ent_lump.length).get_string_from_ascii()
	var ent_split := entities_string.split("{", false)
	var regex = RegEx.new()
	regex.compile('"(?<key>.+)" "(?<value>.+)"')
	for e: String in ent_split:
		var entity := {}
		e = e.rstrip("}\n")
		var ent := regex.search_all(e)
		for kv: RegExMatch in ent:
			var key := kv.get_string("key")
			var value := kv.get_string("value")
			var actual_value: Variant

			match key:
				"origin": # Vector3's which needs conversion
					var vec3 := string_to_vector3(value)
					actual_value = tech3_to_gd(vec3)
				"gridsize": # Vector3i's
					var vec3i := string_to_vector3i(value)
					actual_value = vec3i
				"angles":
					actual_value = string_to_vector3(value)
				"angle":
					actual_value = value.to_float()
				"speed", "gravity", "lip", "wait":
					actual_value = value.to_float()
				"spawnflags", "health", "dmg", "style":
					actual_value = value.to_int()
				"_color", "color":
					var components := value.split_floats(" ", false)
					for i in components.size():
						if components[i] > 1.0:
							components[i] /= 255
					actual_value = Color(components[0], components[1], components[2])
				_: # no idea, let's pass it as a string for now.
					actual_value = value
			entity[key] = actual_value
		var orient := _entity_orientation(entity)
		if orient["oriented"]:
			entity["movedir"] = orient["movedir"]
			entity["gd_angles"] = (orient["basis"] as Basis).get_euler() * 180.0 / PI
		_entities.append(entity)
	_worldspawn = _entities[0]
	_tech3_srgb = _worldspawn_uses_srgb()
	print("tech3bsp: worldspawn: ", _worldspawn)
	print("tech3bsp: entities: ", _entities.size())


## Collect targetshadername / targetshadernewname pairs and apply the
## ones that fire on map load (trigger_always, or no targetname).
## Other pairs stay available via BSPScene.remap_shader.
func _apply_shader_remaps() -> void:
	if _bsp_scene == null:
		return
	var pairs: Array[Dictionary] = []
	for entity in _entities:
		var old_name := str(entity.get("targetshadername", "")).strip_edges()
		var new_name := str(entity.get("targetshadernewname", "")).strip_edges()
		if old_name.is_empty() or new_name.is_empty():
			continue
		var pair := {
			"old": old_name,
			"new": new_name,
			"classname": str(entity.get("classname", "")),
			"targetname": str(entity.get("targetname", "")),
		}
		pairs.append(pair)
		var cls: String = str(pair["classname"])
		var tn: String = str(pair["targetname"])
		if cls == "trigger_always" or tn.is_empty():
			var n := _bsp_scene.remap_shader(old_name, new_name)
			if n > 0:
				print("tech3bsp: remapped '%s' -> '%s' (%d surfaces)" % [old_name, new_name, n])
	if not pairs.is_empty():
		_bsp_scene.set_meta("tech3_shader_remaps", pairs)


func _parse_textures(tex_lump) -> void:
	_bsp_file.seek(tex_lump.offset)
	var count: int = tex_lump.length / 72 # name[64], flags, contents
	print("tech3bsp: textures: ", count)
	_tex_name.resize(count)
	_tex_flags.resize(count)
	_tex_contents.resize(count)
	for i in range(count):
		_tex_name[i] = _bsp_file.get_buffer(64).get_string_from_ascii()
		_tex_flags[i] = _bsp_file.get_32()
		_tex_contents[i] = _bsp_file.get_32()


func _parse_planes(planes_lump) -> void:
	_bsp_file.seek(planes_lump.offset)
	var count: int = planes_lump.length / 16
	print("tech3bsp: planes: ", count)
	_plane_n.resize(count)
	_plane_d.resize(count)
	var inv_scale: float = 1.0 / options.unit_scale
	for i in range(count):
		var plane_x: float = _bsp_file.get_float()
		var plane_y: float = _bsp_file.get_float()
		var plane_z: float = _bsp_file.get_float()
		var dist: float = _bsp_file.get_float()
		_plane_n[i] = Tech3BSPReader.tech3_to_gd(Vector3(plane_x, plane_y, plane_z), false)
		_plane_d[i] = dist * inv_scale


func _parse_models(models_lump) -> void:
	_bsp_file.seek(models_lump.offset)
	var count: int = models_lump.length / 40
	print("tech3bsp: models: ", count)
	_model_mins.resize(count)
	_model_maxs.resize(count)
	_model_face.resize(count)
	_model_num_faces.resize(count)
	_model_brush.resize(count)
	_model_num_brushes.resize(count)
	for i in range(count):
		_model_mins[i] = Vector3(_bsp_file.get_float(), _bsp_file.get_float(), _bsp_file.get_float())
		_model_maxs[i] = Vector3(_bsp_file.get_float(), _bsp_file.get_float(), _bsp_file.get_float())
		_model_face[i] = Tech3BSPReader.to_signed32(_bsp_file.get_32())
		_model_num_faces[i] = Tech3BSPReader.to_signed32(_bsp_file.get_32())
		_model_brush[i] = Tech3BSPReader.to_signed32(_bsp_file.get_32())
		_model_num_brushes[i] = Tech3BSPReader.to_signed32(_bsp_file.get_32())


func _parse_brushes(brushes_lump) -> void:
	_bsp_file.seek(brushes_lump.offset)
	var count: int = brushes_lump.length / 12
	print("tech3bsp: brushes: ", count)
	_brush_first_side.resize(count)
	_brush_num_sides.resize(count)
	_brush_tex.resize(count)
	for i in range(count):
		_brush_first_side[i] = Tech3BSPReader.to_signed32(_bsp_file.get_32())
		_brush_num_sides[i] = Tech3BSPReader.to_signed32(_bsp_file.get_32())
		_brush_tex[i] = Tech3BSPReader.to_signed32(_bsp_file.get_32())


func _parse_brush_sides(brush_sides_lump) -> void:
	_bsp_file.seek(brush_sides_lump.offset)
	var rec := RBSP_BRUSHSIDE_SIZE if _is_rbsp else IBSP_BRUSHSIDE_SIZE
	var count: int = brush_sides_lump.length / rec
	print("tech3bsp: brush sides: ", count)
	_side_plane.resize(count)
	_side_tex.resize(count)
	for i in range(count):
		_side_plane[i] = Tech3BSPReader.to_signed32(_bsp_file.get_32())
		_side_tex[i] = Tech3BSPReader.to_signed32(_bsp_file.get_32())
		if _is_rbsp:
			_bsp_file.get_32() # drawSurfNum, unused for clip / draw


func _parse_vertices(vertices_lump) -> void:
	_bsp_file.seek(vertices_lump.offset)
	var rec := RBSP_VERTEX_SIZE if _is_rbsp else IBSP_VERTEX_SIZE
	var count: int = vertices_lump.length / rec
	print("tech3bsp: vertices: ", count)
	_vertex_positions.resize(count)
	_vertex_normals.resize(count)
	_vertex_uvs.resize(count)
	_vertex_uv2s.resize(count)
	_vertex_lm_uv1.resize(count)
	_vertex_lm_uv2.resize(count)
	_vertex_lm_uv3.resize(count)
	_vertex_colors.resize(count)
	for i in range(count):
		var position := Vector3(_bsp_file.get_float(), _bsp_file.get_float(), _bsp_file.get_float())
		var uv_x: float = _bsp_file.get_float()
		var uv_y: float = _bsp_file.get_float()
		var uv2_x: float = _bsp_file.get_float()
		var uv2_y: float = _bsp_file.get_float()
		var lm1 := Vector2.ZERO
		var lm2 := Vector2.ZERO
		var lm3 := Vector2.ZERO
		if _is_rbsp:
			lm1 = Vector2(_bsp_file.get_float(), _bsp_file.get_float())
			lm2 = Vector2(_bsp_file.get_float(), _bsp_file.get_float())
			lm3 = Vector2(_bsp_file.get_float(), _bsp_file.get_float())
		var normal := Vector3(_bsp_file.get_float(), _bsp_file.get_float(), _bsp_file.get_float())
		var cr := float(_bsp_file.get_u8()) / 255.0
		var cg := float(_bsp_file.get_u8()) / 255.0
		var cb := float(_bsp_file.get_u8()) / 255.0
		var ca := float(_bsp_file.get_u8()) / 255.0
		if _is_rbsp:
			_bsp_file.get_buffer(12) # color[1..3][4]
		_vertex_positions[i] = Tech3BSPReader.tech3_to_gd(position)
		_vertex_normals[i] = Tech3BSPReader.tech3_to_gd(normal, false)
		_vertex_uvs[i] = Vector2(uv_x, uv_y)
		_vertex_uv2s[i] = Vector2(uv2_x, uv2_y)
		_vertex_lm_uv1[i] = lm1
		_vertex_lm_uv2[i] = lm2
		_vertex_lm_uv3[i] = lm3
		_vertex_colors[i] = Color(cr, cg, cb, ca)


func _parse_indices(mesh_verts_lump) -> void:
	_bsp_file.seek(mesh_verts_lump.offset)
	var count: int = mesh_verts_lump.length / 4
	print("tech3bsp: indices (mesh_verts): ", count)
	_indices.resize(count)
	for i in range(count):
		_indices[i] = _bsp_file.get_32()


func _parse_effects(effects_lump) -> void: # fog
	_bsp_file.seek(effects_lump.offset)
	var count: int = effects_lump.length / 72
	print("tech3bsp: effects (fog): ", count)
	_effect_name.resize(count)
	_effect_brush.resize(count)
	for i in range(count):
		_effect_name[i] = _bsp_file.get_buffer(64).get_string_from_ascii()
		_effect_brush[i] = Tech3BSPReader.to_signed32(_bsp_file.get_32())
		_bsp_file.get_32() # visibleSide


func _parse_faces(faces_lump) -> void:
	_bsp_file.seek(faces_lump.offset)
	var rec := RBSP_FACE_SIZE if _is_rbsp else IBSP_FACE_SIZE
	var count: int = faces_lump.length / rec
	print("tech3bsp: faces: ", count)
	_face_tex.resize(count)
	_face_type.resize(count)
	_face_first_vert.resize(count)
	_face_num_verts.resize(count)
	_face_first_index.resize(count)
	_face_num_indices.resize(count)
	_face_lm.resize(count)
	_face_lm1.resize(count)
	_face_lm2.resize(count)
	_face_lm3.resize(count)
	_face_styles.resize(count)
	_face_lm_off0.resize(count)
	_face_lm_off1.resize(count)
	_face_lm_off2.resize(count)
	_face_lm_off3.resize(count)
	_face_lm_origin.resize(count)
	_face_lm_vec0.resize(count)
	_face_normal.resize(count)
	_face_patch_w.resize(count)
	_face_patch_h.resize(count)
	for i in range(count):
		_face_tex[i] = Tech3BSPReader.to_signed32(_bsp_file.get_32())
		_bsp_file.get_32() # face.effect, fog is the effects lump
		_face_type[i] = _bsp_file.get_32()
		_face_first_vert[i] = Tech3BSPReader.to_signed32(_bsp_file.get_32())
		_face_num_verts[i] = Tech3BSPReader.to_signed32(_bsp_file.get_32())
		_face_first_index[i] = Tech3BSPReader.to_signed32(_bsp_file.get_32())
		_face_num_indices[i] = Tech3BSPReader.to_signed32(_bsp_file.get_32())
		if _is_rbsp:
			var lm_styles := _bsp_file.get_buffer(4)
			var vert_styles := _bsp_file.get_buffer(4)
			var n0 := Tech3BSPReader.to_signed32(_bsp_file.get_32())
			var n1 := Tech3BSPReader.to_signed32(_bsp_file.get_32())
			var n2 := Tech3BSPReader.to_signed32(_bsp_file.get_32())
			var n3 := Tech3BSPReader.to_signed32(_bsp_file.get_32())
			var x0 := float(Tech3BSPReader.to_signed32(_bsp_file.get_32()))
			var x1 := float(Tech3BSPReader.to_signed32(_bsp_file.get_32()))
			var x2 := float(Tech3BSPReader.to_signed32(_bsp_file.get_32()))
			var x3 := float(Tech3BSPReader.to_signed32(_bsp_file.get_32()))
			var y0 := float(Tech3BSPReader.to_signed32(_bsp_file.get_32()))
			var y1 := float(Tech3BSPReader.to_signed32(_bsp_file.get_32()))
			var y2 := float(Tech3BSPReader.to_signed32(_bsp_file.get_32()))
			var y3 := float(Tech3BSPReader.to_signed32(_bsp_file.get_32()))
			_face_lm_off0[i] = Vector2(x0, y0)
			_face_lm_off1[i] = Vector2(x1, y1)
			_face_lm_off2[i] = Vector2(x2, y2)
			_face_lm_off3[i] = Vector2(x3, y3)
			# RBSP : LIGHTMAP_BY_VERTEX uses vertexStyles
			var use_vstyles := n0 < 0
			var src_styles: PackedByteArray = vert_styles if use_vstyles else lm_styles
			var s0 := src_styles[0] if src_styles.size() > 0 else RBSP_LS_NONE
			var s1 := src_styles[1] if src_styles.size() > 1 else RBSP_LS_NONE
			var s2 := src_styles[2] if src_styles.size() > 2 else RBSP_LS_NONE
			var s3 := src_styles[3] if src_styles.size() > 3 else RBSP_LS_NONE
			if not use_vstyles:
				if s0 == RBSP_LS_NONE:
					n0 = -1
				if s1 == RBSP_LS_NONE:
					n1 = -1
				if s2 == RBSP_LS_NONE:
					n2 = -1
				if s3 == RBSP_LS_NONE:
					n3 = -1
			_face_lm[i] = n0
			_face_lm1[i] = n1
			_face_lm2[i] = n2
			_face_lm3[i] = n3
			_face_styles[i] = s0 | (s1 << 8) | (s2 << 16) | (s3 << 24)
		else:
			_face_lm[i] = Tech3BSPReader.to_signed32(_bsp_file.get_32())
			var lx := float(Tech3BSPReader.to_signed32(_bsp_file.get_32()))
			var ly := float(Tech3BSPReader.to_signed32(_bsp_file.get_32()))
			_face_lm_off0[i] = Vector2(lx, ly)
			_face_lm_off1[i] = Vector2.ZERO
			_face_lm_off2[i] = Vector2.ZERO
			_face_lm_off3[i] = Vector2.ZERO
			_face_lm1[i] = -1
			_face_lm2[i] = -1
			_face_lm3[i] = -1
			_face_styles[i] = 0 | (RBSP_LS_NONE << 8) | (RBSP_LS_NONE << 16) | (RBSP_LS_NONE << 24)
		_bsp_file.get_32()
		_bsp_file.get_32()  # lightmapWidth / lightmapHeight
		_face_lm_origin[i] = Tech3BSPReader.tech3_to_gd(Vector3(_bsp_file.get_float(), _bsp_file.get_float(), _bsp_file.get_float()))
		_face_lm_vec0[i] = Vector3(_bsp_file.get_float(), _bsp_file.get_float(), _bsp_file.get_float())
		_bsp_file.get_float()
		_bsp_file.get_float()
		_bsp_file.get_float() # unused second lm vec
		_face_normal[i] = Tech3BSPReader.tech3_to_gd(Vector3(_bsp_file.get_float(), _bsp_file.get_float(), _bsp_file.get_float()), false)
		_face_patch_w[i] = _bsp_file.get_32()
		_face_patch_h[i] = _bsp_file.get_32()


func _lightmap_maybe_srgb(tex: Texture) -> Texture:
	if not _tech3_srgb or !tex:
		return tex
	var src: Image = tex.get_image() if tex is Texture2D else null
	if !src:
		return tex
	src = src.duplicate()
	if src.is_compressed():
		src.decompress()
	src.convert(Image.FORMAT_RGBA8)
	for y in src.get_height():
		for x in src.get_width():
			src.set_pixel(x, y, src.get_pixel(x, y).srgb_to_linear())
	return ImageTexture.create_from_image(src)


func _map_stem_from_source() -> String:
	var p := ""
	if _bsp_file:
		p = _bsp_file.get_path().replace("\\", "/")
	if p.begins_with("pk3://"):
		p = p.substr(6)
	if p.begins_with("res://"):
		p = p.substr(6)
	if p.to_lower().ends_with(".bsp"):
		p = p.substr(0, p.length() - 4)
	return p


func _load_external_lightmaps() -> void:
	_external_lightmaps.clear()
	_external_deluxemaps.clear()
	_deluxe_active = false
	if not options.import_lightmaps:
		return
	var paths := _collect_external_lm_paths()
	if paths.is_empty():
		return
	var color: Dictionary = {}
	var deluxe: Dictionary = {}
	var max_i := -1
	for f in paths:
		var idx := _lm_page_index(f)
		if idx < 0:
			continue
		var tex := _load_external_lm_texture(f)
		if !tex:
			continue
		max_i = maxi(max_i, idx)
		if _lm_path_is_deluxe(f):
			deluxe[idx] = tex
		elif not color.has(idx):
			color[idx] = tex
	if color.is_empty() or max_i < 0:
		return
	var mode := _worldspawn_deluxe_mode()
	# Suffix files win. Interleaved odd lm_NNNN is the DarkPlaces fallback
	# and only when worldspawn / -deluxe said this compile has deluxe.
	# A face or Raven style slot that points at the odd page owns it as
	# color. Styled external pages are real lightmaps, not direction maps.
	if deluxe.is_empty() and mode != 0:
		# netradiant-custom writes deluxe only for style 0, as the next page.
		# lm_0000 color, lm_0001 deluxe. A styled page stays color and has no deluxe.
		var primaries: Array[int] = []
		for i in _face_lm.size():
			var page := int(_face_lm[i])
			if page >= 0 and page not in primaries:
				primaries.append(page)
		if primaries.is_empty():
			for idx in color.keys():
				var i := int(idx)
				if (i & 1) == 0:
					primaries.append(i)
		for page in primaries:
			var partner := page + 1
			if color.has(partner) and not color.has(page):
				continue
			if not color.has(partner) or deluxe.has(page) or _lm_page_is_color(partner):
				continue
			deluxe[page] = color[partner]
			color.erase(partner)
	elif not deluxe.is_empty() and mode == 0:
		mode = 1
	_external_lightmaps.resize(max_i + 1)
	_external_deluxemaps.resize(max_i + 1)
	for idx in color.keys():
		_external_lightmaps[int(idx)] = color[idx]
	var paired := 0
	for idx in deluxe.keys():
		var i := int(idx)
		if i < 0 or i >= _external_deluxemaps.size():
			continue
		var page: Texture = deluxe[idx] if mode == 2 else _deluxe_to_tangent_space(deluxe[idx], i, true)
		_external_deluxemaps[i] = page
		paired += 1
	_deluxe_active = paired > 0
	_deluxe_modelspace = mode != 2
	if _deluxe_active:
		var kind := "tangent" if mode == 2 else "model"
		print("tech3bsp: deluxemaps: ", paired, " (", kind, " space)")
		if mode == 2:
			push_warning("tech3bsp: tangentspace deluxemaps are decoded in the shader")
	_norm_binds = 0
	_gloss_binds = 0
	_want_tangents = false


func _lm_page_is_color(page: int) -> bool:
	if page < 0:
		return false
	for i in _face_lm.size():
		if _face_lm[i] == page:
			return true
		if i < _face_lm1.size() and (_face_lm1[i] == page or _face_lm2[i] == page or _face_lm3[i] == page):
			return true
	return false


func _collect_external_lm_paths() -> PackedStringArray:
	var stem := _map_stem_from_source()
	var out := PackedStringArray()
	if stem == "":
		return out
	var seen: Dictionary = {}
	var scoped: Array = [
		[Tech3Pk3.list_mounted(stem + "/"), ""],
	]
	if not stem.to_lower().begins_with("dds/"):
		scoped.append([Tech3Pk3.list_mounted("dds/" + stem + "/"), ""])
	# maps/lm_<map>_#### when the sibling folder not used
	scoped.append([Tech3Pk3.list_mounted(stem.get_base_dir() + "/"), stem.get_file().to_lower()])
	for pair in scoped:
		var files: PackedStringArray = pair[0]
		var prefix := String(pair[1])
		for f in files:
			var fl := String(f).to_lower()
			if prefix != "" and not fl.get_file().begins_with(prefix):
				continue
			if _lm_page_index(fl) < 0:
				continue
			if fl.get_extension() not in POSSIBLE_IMAGE_EXTENSIONS:
				continue
			if seen.has(fl):
				continue
			seen[fl] = true
			out.append(String(f))
		if not out.is_empty():
			break
	if not out.is_empty():
		return out
	var disk_folders: PackedStringArray = PackedStringArray()
	if _bsp_file:
		var src := _bsp_file.get_path().replace("\\", "/")
		if not src.begins_with("pk3://"):
			disk_folders.append(src.get_basename())
		disk_folders.append("res://" + stem)
		disk_folders.append(_as_project_path(stem))
		if not stem.to_lower().begins_with("dds/"):
			disk_folders.append("res://dds/" + stem)
			disk_folders.append(_as_project_path("dds/" + stem))
	for folder in disk_folders:
		var dir := DirAccess.open(folder)
		if !dir:
			continue
		for file in dir.get_files():
			if _lm_page_index(file) < 0:
				continue
			if not POSSIBLE_IMAGE_EXTENSIONS.has(String(file).get_extension().to_lower()):
				continue
			var full := folder.path_join(String(file))
			var key := full.to_lower()
			if seen.has(key):
				continue
			seen[key] = true
			out.append(full)
		if not out.is_empty():
			break
	return out


func _deluxe_to_tangent_space(tex: Texture, page: int, from_model: bool) -> Texture:
	# Both formats are stored as a Godot world direction. Tangentspace input
	# is decoded with q3map2's normal-only frame first.
	var img: Image = tex.get_image()
	if img == null:
		return tex
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var n_img: Image = null
	if not from_model:
		var w := img.get_width()
		var h := img.get_height()
		n_img = Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
		n_img.fill(Color(0.5, 1.0, 0.5))
		var unused_t := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
		var unused_b := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
		_raster_page_tbn(n_img, unused_t, unused_b, page)
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			var dx := Vector3(c.r * 2.0 - 1.0, c.g * 2.0 - 1.0, c.b * 2.0 - 1.0)
			var l_q3: Vector3 = dx
			if not from_model:
				var n := _luxel_vec(n_img.get_pixel(x, y))
				l_q3 = _q3_tangent_to_world(dx, Tech3BSPReader.tech3_to_gd(n, false))
			var l_gd := Tech3BSPReader.tech3_to_gd(l_q3, false)
			if l_gd.length_squared() < 0.0001:
				l_gd = Vector3(0.0, 1.0, 0.0)
			l_gd = l_gd.normalized()
			img.set_pixel(x, y, Color(l_gd.x * 0.5 + 0.5, l_gd.y * 0.5 + 0.5, l_gd.z * 0.5 + 0.5, c.a))
	return ImageTexture.create_from_image(img)


func _luxel_vec(c: Color) -> Vector3:
	var v := Vector3(c.r * 2.0 - 1.0, c.g * 2.0 - 1.0, c.b * 2.0 - 1.0)
	if v.length_squared() < 0.0001:
		return Vector3(0.0, 1.0, 0.0)
	return v.normalized()


func _q3_tangent_to_world(dx: Vector3, n: Vector3) -> Vector3:
	var t: Vector3
	var b: Vector3
	if absf(n.x) < 0.0001 and absf(n.y) < 0.0001:
		t = Vector3(1.0, 0.0, 0.0) if n.z > 0.0 else Vector3(-1.0, 0.0, 0.0)
		b = Vector3(0.0, 1.0, 0.0)
	else:
		t = n.cross(Vector3(0.0, 0.0, 1.0)).normalized()
		b = t.cross(n).normalized()
	t = (t - n * t.dot(n)).normalized()
	b = (b - n * b.dot(n)).normalized()
	if n.x > 0.0 or n.y < 0.0 or n.z < 0.0:
		t = -t
	var l := t * dx.x + b * dx.y + n * dx.z
	if l.length_squared() < 0.0001:
		return n
	return l.normalized()


func _raster_page_tbn(n_img: Image, t_img: Image, b_img: Image, page: int) -> void:
	for fi in _face_lm.size():
		if int(_face_lm[fi]) != page:
			continue
		var fv := int(_face_first_vert[fi])
		var ni := int(_face_num_indices[fi])
		var first_i := int(_face_first_index[fi])
		if ni < 3 or first_i < 0:
			continue
		var tri_count := int(ni / 3)
		for ti in tri_count:
			var base := first_i + ti * 3
			if base + 2 >= _indices.size():
				break
			var i0 := fv + int(_indices[base])
			var i1 := fv + int(_indices[base + 1])
			var i2 := fv + int(_indices[base + 2])
			if i0 < 0 or i1 < 0 or i2 < 0:
				continue
			if i2 >= _vertex_normals.size() or i2 >= _vertex_uv2s.size() or i2 >= _vertex_positions.size() or i2 >= _vertex_uvs.size():
				continue
			var n := (_vertex_normals[i0] + _vertex_normals[i1] + _vertex_normals[i2]).normalized()
			var tbn := _tri_tbn(_vertex_positions[i0], _vertex_positions[i1], _vertex_positions[i2], _vertex_uvs[i0], _vertex_uvs[i1], _vertex_uvs[i2], n)
			_raster_tri_vec(n_img, _vertex_uv2s[i0], _vertex_uv2s[i1], _vertex_uv2s[i2], n)
			_raster_tri_vec(t_img, _vertex_uv2s[i0], _vertex_uv2s[i1], _vertex_uv2s[i2], tbn[0])
			_raster_tri_vec(b_img, _vertex_uv2s[i0], _vertex_uv2s[i1], _vertex_uv2s[i2], tbn[1])


func _tri_tbn(p0: Vector3, p1: Vector3, p2: Vector3, uv0: Vector2, uv1: Vector2, uv2: Vector2, n: Vector3) -> Array:
	var e1 := p1 - p0
	var e2 := p2 - p0
	var d1 := uv1 - uv0
	var d2 := uv2 - uv0
	var denom := d1.x * d2.y - d2.x * d1.y
	var t := Vector3(1.0, 0.0, 0.0)
	var b := Vector3(0.0, 0.0, 1.0)
	if absf(denom) > 0.0000001:
		var f := 1.0 / denom
		t = (e1 * d2.y - e2 * d1.y) * f
		b = (e2 * d1.x - e1 * d2.x) * f
	t = (t - n * t.dot(n))
	if t.length_squared() < 0.0001:
		t = n.cross(Vector3(0.0, 1.0, 0.0))
		if t.length_squared() < 0.0001:
			t = Vector3(1.0, 0.0, 0.0)
	t = t.normalized()
	b = n.cross(t)
	if b.dot(b) < 0.0:
		b = -b
	# Match Godot BINORMAL = cross(N, T) * TANGENT.w
	# UV-derived bitangent sign is the handedness.
	if b.dot((e2 * d1.x - e1 * d2.x)) < 0.0:
		b = -b
	return [t, b.normalized()]


func _raster_tri_vec(img: Image, uv0: Vector2, uv1: Vector2, uv2: Vector2, v: Vector3) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var p0 := Vector2(uv0.x * w, uv0.y * h)
	var p1 := Vector2(uv1.x * w, uv1.y * h)
	var p2 := Vector2(uv2.x * w, uv2.y * h)
	var min_x := clampi(int(minf(p0.x, minf(p1.x, p2.x))), 0, w - 1)
	var max_x := clampi(int(maxf(p0.x, maxf(p1.x, p2.x))) + 1, 0, w)
	var min_y := clampi(int(minf(p0.y, minf(p1.y, p2.y))), 0, h - 1)
	var max_y := clampi(int(maxf(p0.y, maxf(p1.y, p2.y))) + 1, 0, h)
	var denom := (p1.y - p2.y) * (p0.x - p2.x) + (p2.x - p1.x) * (p0.y - p2.y)
	if absf(denom) < 0.0001:
		return
	var col := Color(v.x * 0.5 + 0.5, v.y * 0.5 + 0.5, v.z * 0.5 + 0.5)
	for y in range(min_y, max_y):
		for x in range(min_x, max_x):
			var pt := Vector2(x + 0.5, y + 0.5)
			var a := ((p1.y - p2.y) * (pt.x - p2.x) + (p2.x - p1.x) * (pt.y - p2.y)) / denom
			var b := ((p2.y - p0.y) * (pt.x - p2.x) + (p0.x - p2.x) * (pt.y - p2.y)) / denom
			var c := 1.0 - a - b
			if a >= -0.001 and b >= -0.001 and c >= -0.001:
				img.set_pixel(x, y, col)


func _load_external_lm_texture(path: String) -> Texture:
	var tex: Texture = null
	if path.begins_with("res://") or path.begins_with("user://"):
		var loaded = load(path)
		if loaded is Texture:
			tex = loaded
	if !tex:
		tex = Tech3Pk3.resolve_texture(path)
	if !tex:
		return null
	# Direction pages are linear 0-1 encodings. Don't sRGB-decode
	if _lm_path_is_deluxe(path):
		return tex
	return _lightmap_maybe_srgb(tex)


func _internal_page_is_deluxe(page: int) -> bool:
	if page <= 0:
		return false
	var color_page := page - 1
	var used_color := false
	for i in _face_lm.size():
		if int(_face_lm[i]) == color_page:
			used_color = true
			break
	if not used_color and (color_page & 1) != 0:
		return false
	if not used_color and _face_lm.is_empty() and (page & 1) == 1:
		return true
	return used_color and not _lm_page_is_color(page)


func _parse_lightmaps(lightmap_lump) -> void:
	if not options.import_lightmaps:
		_deluxe_active = false
		_external_deluxemaps.clear()
		return
	_bsp_file.seek(lightmap_lump.offset)
	var count: int = lightmap_lump.length / DEFAULT_LIGHTMAP_LENGTH
	print("tech3bsp: lightmap lump length: ", lightmap_lump.length)
	
	if !count: # maybe we're using external lightmaps?
		_load_external_lightmaps()
		if _external_lightmaps.is_empty():
			print("tech3bsp: No external or internal lightmaps found, abandoning lightmap import.")
			return
		print("tech3bsp: external lightmaps: ", _external_lightmaps.size())
		return
	
	print("tech3bsp: internal lightmaps: ", count)
	var mode := _worldspawn_deluxe_mode()
	var from_model := mode != 2
	var split_deluxe := mode != 0 and count >= 2
	if split_deluxe:
		_deluxe_modelspace = from_model
		_deluxe_active = true
	_lm_page_slot.resize(count)
	_lm_page_slot.fill(-1)
	var packed := 0
	for i in range(count):
		if split_deluxe and _internal_page_is_deluxe(i):
			continue
		_lm_page_slot[i] = packed
		packed += 1
	if packed <= 0:
		packed = count
	_lightmap_columns = int(ceil(sqrt(packed)))
	_lightmap_rows = int(ceil(float(packed) / float(_lightmap_columns)))
	_lightmap_cell_size = DEFAULT_LIGHTMAP_SIZE + LIGHTMAP_PAD * 2
	
	var atlas_width := _lightmap_columns * _lightmap_cell_size
	var atlas_height := _lightmap_rows * _lightmap_cell_size
	
	var lightmap_atlas_image := Image.create_empty(atlas_width, atlas_height, false, Image.FORMAT_RGB8)
	var deluxe_atlas_image: Image = null
	if split_deluxe:
		deluxe_atlas_image = Image.create_empty(atlas_width, atlas_height, false, Image.FORMAT_RGB8)

	for i in range(count):
		var lightmap_bytes := _bsp_file.get_buffer(DEFAULT_LIGHTMAP_LENGTH)
		var is_deluxe := split_deluxe and _internal_page_is_deluxe(i)
		var img := Image.create_empty(DEFAULT_LIGHTMAP_SIZE, DEFAULT_LIGHTMAP_SIZE, false, Image.FORMAT_RGB8)
		var l := 0
		
		for y in range(DEFAULT_LIGHTMAP_SIZE):
			for x in range(DEFAULT_LIGHTMAP_SIZE):
				var raw := Color(lightmap_bytes[l] / 255.0, lightmap_bytes[l + 1] / 255.0, lightmap_bytes[l + 2] / 255.0)
				if is_deluxe:
					img.set_pixel(x, y, raw)
				else:
					img.set_pixel(x, y, _to_linear(scale_color(Color(lightmap_bytes[l], lightmap_bytes[l + 1], lightmap_bytes[l + 2]))))
				l += 3
		
		if is_deluxe and from_model:
			var color_page := i - 1 if i > 0 else 0
			var turned := _deluxe_to_tangent_space(ImageTexture.create_from_image(img), color_page, true)
			img = turned.get_image()
			if img.get_format() != Image.FORMAT_RGB8:
				img.convert(Image.FORMAT_RGB8)
		var padding := _pad_lightmap_page(img)
		var page_i := i - 1 if is_deluxe else i
		if page_i >= 0 and page_i < _lm_page_slot.size() and _lm_page_slot[page_i] >= 0:
			page_i = _lm_page_slot[page_i]
		var col := page_i % _lightmap_columns
		var row := int(page_i / _lightmap_columns)
		var dst := Vector2i(col * _lightmap_cell_size, row * _lightmap_cell_size)
		var target: Image = deluxe_atlas_image if is_deluxe else lightmap_atlas_image
		target.blit_rect(
			padding,
			Rect2i(0, 0, _lightmap_cell_size, _lightmap_cell_size),
			dst
		)
		
		_lightmap_atlas = ImageTexture.create_from_image(lightmap_atlas_image)
	if deluxe_atlas_image:
		_deluxe_atlas = ImageTexture.create_from_image(deluxe_atlas_image)
		var kind := "tangent" if not from_model else "model"
		print("tech3bsp: internal deluxemaps: ", int(count / 2), " (", kind, " space)")
		if not from_model:
			push_warning("tech3bsp: tangentspace deluxemaps are decoded in the shader")


func _pad_lightmap_page(img: Image) -> Image:
	var pad := LIGHTMAP_PAD
	if pad <= 0:
		return img
	var inner := DEFAULT_LIGHTMAP_SIZE
	var side := inner + pad * 2
	var out := Image.create_empty(side, side, false, Image.FORMAT_RGB8)
	for y in side:
		for x in side:
			var sx := clampi(x - pad, 0, inner - 1)
			var sy := clampi(y - pad, 0, inner - 1)
			out.set_pixel(x, y, img.get_pixel(sx, sy))
	return out


func _lm_cell_custom(lightmap_id: int) -> Color:
	# Atlas cell as (offset.x, offset.y, scale.x, scale.y) for env/$lightmap
	if not _external_lightmaps.is_empty():
		if lightmap_id >= 0 and lightmap_id < _external_lightmaps.size():
			return Color(0, 0, 1, 1)
		return Color(0, 0, 0, 0)
	if lightmap_id < 0 or _lightmap_columns <= 0 or _lightmap_rows <= 0:
		return Color(0, 0, 0, 0)
	var slot := lightmap_id
	if lightmap_id < _lm_page_slot.size() and _lm_page_slot[lightmap_id] >= 0:
		slot = _lm_page_slot[lightmap_id]
	var col := slot % _lightmap_columns
	var row := int(slot / _lightmap_columns)
	var cell := float(_lightmap_cell_size)
	var inner := float(DEFAULT_LIGHTMAP_SIZE)
	var pad := float(LIGHTMAP_PAD)
	var aw := float(_lightmap_columns * _lightmap_cell_size)
	var ah := float(_lightmap_rows * _lightmap_cell_size)
	return Color(
		(float(col) * cell + pad) / aw,
		(float(row) * cell + pad) / ah,
		inner / aw,
		inner / ah
	)


func _atlas_uv2(local_uv: Vector2, lightmap_id: int) -> Vector2:
	if lightmap_id < 0 or _lightmap_columns <= 0 or _lightmap_rows <= 0:
		return local_uv
	var slot := lightmap_id
	if lightmap_id < _lm_page_slot.size() and _lm_page_slot[lightmap_id] >= 0:
		slot = _lm_page_slot[lightmap_id]
	var col := slot % _lightmap_columns
	var row := int(slot / _lightmap_columns)
	var cell := float(_lightmap_cell_size)
	var inner := float(DEFAULT_LIGHTMAP_SIZE)
	var pad := float(LIGHTMAP_PAD)
	var aw := float(_lightmap_columns * _lightmap_cell_size)
	var ah := float(_lightmap_rows * _lightmap_cell_size)
	return Vector2(
		(float(col) * cell + pad + local_uv.x * inner) / aw,
		(float(row) * cell + pad + local_uv.y * inner) / ah
	)


func _spherical_to_cartesian(latitude: float, longitude: float) -> Vector3:
	var theta := deg_to_rad(longitude * 360.0 / 255.0)
	var phi := deg_to_rad(latitude * 360.0 / 255.0)
	var dir := Vector3(-cos(theta) * sin(phi), cos(phi), sin(theta) * sin(phi))
	if dir.length_squared() < 0.0001:
		return Vector3.UP
	return dir.normalized()


func _expand_rbsp_lightgrid(grid_lump: Dictionary, array_lump: Dictionary, cell_count: int) -> Dictionary:
	var unique_len: int = int(grid_lump.get("length", 0))
	var array_len: int = int(array_lump.get("length", 0))
	var empty_slots: Array[PackedByteArray] = []
	var empty := {
		"slots": empty_slots,
		"styles": PackedByteArray(),
	}
	if cell_count <= 0 or unique_len < RBSP_GRID_SAMPLE_SIZE or array_len < cell_count * 2:
		push_error("tech3bsp: RBSP lightgrid/lightarray size mismatch (cells=%d grid=%d array=%d)" % [cell_count, unique_len, array_len])
		return empty
	_bsp_file.seek(int(grid_lump.offset))
	var unique := _bsp_file.get_buffer(unique_len)
	var nunique := unique.size() / RBSP_GRID_SAMPLE_SIZE
	_bsp_file.seek(int(array_lump.offset))
	var arr := _bsp_file.get_buffer(cell_count * 2)
	var slots: Array[PackedByteArray] = []
	for _k in 4:
		var dense := PackedByteArray()
		dense.resize(cell_count * IBSP_GRID_SAMPLE_SIZE)
		slots.append(dense)
	var styles := PackedByteArray()
	styles.resize(cell_count * 4)
	styles.fill(RBSP_LS_NONE)
	for i in range(cell_count):
		var idx := arr.decode_u16(i * 2)
		if idx >= nunique:
			continue
		var s := idx * RBSP_GRID_SAMPLE_SIZE
		var o := i * IBSP_GRID_SAMPLE_SIZE
		var lat := unique[s + 28]
		var lng := unique[s + 29]
		for k in 4:
			var sk := unique[s + 24 + k]
			styles[i * 4 + k] = sk
			if sk == RBSP_LS_NONE:
				continue
			var d: PackedByteArray = slots[k]
			d[o] = unique[s + k * 3]
			d[o + 1] = unique[s + k * 3 + 1]
			d[o + 2] = unique[s + k * 3 + 2]
			d[o + 3] = unique[s + 12 + k * 3]
			d[o + 4] = unique[s + 12 + k * 3 + 1]
			d[o + 5] = unique[s + 12 + k * 3 + 2]
			d[o + 6] = lat
			d[o + 7] = lng
	return { "slots": slots, "styles": styles }


func _grid_rgb_volumes(light_grid: PackedByteArray, size: Vector3i, tex_w: int, tex_h: int, tex_d: int) -> Array:
	var amb_imgs: Array[Image] = []
	var dir_imgs: Array[Image] = []
	var slice_len := tex_w * tex_h * 3
	for tw in range(tex_d):
		var iy := tw
		var data_ambient := PackedByteArray()
		var data_direct := PackedByteArray()
		data_ambient.resize(slice_len)
		data_direct.resize(slice_len)
		var pi := 0
		for ty in range(tex_h):
			var iz := ty
			for tx in range(tex_w):
				var ix: int = tex_w - 1 - tx
				var cell: int = ((iz * size.y + iy) * size.x + ix) * 8
				if cell + 5 >= light_grid.size():
					pi += 3
					continue
				var ambient_color := _to_linear(scale_color(Color(
					light_grid[cell], light_grid[cell + 1], light_grid[cell + 2])))
				var direct_color := _to_linear(scale_color(Color(
					light_grid[cell + 3], light_grid[cell + 4], light_grid[cell + 5])))
				data_ambient[pi] = ambient_color.r8
				data_direct[pi] = direct_color.r8
				data_ambient[pi + 1] = ambient_color.g8
				data_direct[pi + 1] = direct_color.g8
				data_ambient[pi + 2] = ambient_color.b8
				data_direct[pi + 2] = direct_color.b8
				pi += 3
		var amb := Image.new()
		var dir := Image.new()
		amb.set_data(tex_w, tex_h, false, Image.FORMAT_RGB8, data_ambient)
		dir.set_data(tex_w, tex_h, false, Image.FORMAT_RGB8, data_direct)
		amb_imgs.append(amb)
		dir_imgs.append(dir)
	return [amb_imgs, dir_imgs]


func _grid_style_volume(style_bytes: PackedByteArray, size: Vector3i, tex_w: int, tex_h: int, tex_d: int) -> Array[Image]:
	var imgs: Array[Image] = []
	var slice_len := tex_w * tex_h * 4
	for tw in range(tex_d):
		var iy := tw
		var data := PackedByteArray()
		data.resize(slice_len)
		data.fill(RBSP_LS_NONE)
		var pi := 0
		for ty in range(tex_h):
			var iz := ty
			for tx in range(tex_w):
				var ix: int = tex_w - 1 - tx
				var cell: int = ((iz * size.y + iy) * size.x + ix) * 4
				if cell + 3 < style_bytes.size():
					data[pi] = style_bytes[cell]
					data[pi + 1] = style_bytes[cell + 1]
					data[pi + 2] = style_bytes[cell + 2]
					data[pi + 3] = style_bytes[cell + 3]
				pi += 4
		var img := Image.new()
		img.set_data(tex_w, tex_h, false, Image.FORMAT_RGBA8, data)
		imgs.append(img)
	return imgs


func _grid_slice_empty(amb: Array[Image], x: int, y: int, z: int) -> bool:
	var c: Color = amb[z].get_pixel(x, y)
	return (c.r + c.g + c.b) < 0.004


func _grid_copy_rgb(src: Array[Image], dst: Array[Image], x: int, y: int, z: int, sx: int, sy: int, sz: int) -> void:
	dst[z].set_pixel(x, y, src[sz].get_pixel(sx, sy))


func _dilate_lightgrid(amb: Array[Image], dirn: Array[Image], cart: Array[Image], extra_amb: Array, extra_dir: Array, styles: Array[Image], tex_w: int, tex_h: int, tex_d: int) -> void:
	if LIGHTGRID_PAD <= 0 or amb.is_empty():
		return
	var offs: Array[Vector3i] = [
		Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
		Vector3i(0, 1, 0), Vector3i(0, -1, 0),
		Vector3i(0, 0, 1), Vector3i(0, 0, -1),
	]
	for _step in range(LIGHTGRID_PAD):
		var donors: Array = []
		donors.resize(tex_w * tex_h * tex_d)
		for z in tex_d:
			for y in tex_h:
				for x in tex_w:
					if not _grid_slice_empty(amb, x, y, z):
						continue
					var found := Vector3i(-1, -1, -1)
					for o in offs:
						var nx: int = x + o.x
						var ny: int = y + o.y
						var nz: int = z + o.z
						if nx < 0 or ny < 0 or nz < 0 or nx >= tex_w or ny >= tex_h or nz >= tex_d:
							continue
						if not _grid_slice_empty(amb, nx, ny, nz):
							found = Vector3i(nx, ny, nz)
							break
					if found.x >= 0:
						donors[x + y * tex_w + z * tex_w * tex_h] = found
		for z in tex_d:
			for y in tex_h:
				for x in tex_w:
					var d = donors[x + y * tex_w + z * tex_w * tex_h]
					if d == null:
						continue
					var sx: int = d.x
					var sy: int = d.y
					var sz: int = d.z
					_grid_copy_rgb(amb, amb, x, y, z, sx, sy, sz)
					_grid_copy_rgb(dirn, dirn, x, y, z, sx, sy, sz)
					_grid_copy_rgb(cart, cart, x, y, z, sx, sy, sz)
					if styles.size() == amb.size():
						styles[z].set_pixel(x, y, styles[sz].get_pixel(sx, sy))
					for k in extra_amb.size():
						var ea: Array = extra_amb[k]
						var ed: Array = extra_dir[k] if k < extra_dir.size() else []
						if ea is Array and ea.size() == amb.size():
							_grid_copy_rgb(ea, ea, x, y, z, sx, sy, sz)
						if ed is Array and ed.size() == amb.size():
							_grid_copy_rgb(ed, ed, x, y, z, sx, sy, sz)


func _parse_light_grid(light_grid_lump, light_array_lump = {}) -> void:
	var grid_size := Vector3i(64, 64, 128)
	if _worldspawn.has("gridsize"):
		grid_size = _worldspawn["gridsize"]
	
	var size := Vector3i(\
		floor(_model_maxs[0].x / grid_size.x) - ceil(_model_mins[0].x / grid_size.x) + 1,\
		floor(_model_maxs[0].y / grid_size.y) - ceil(_model_mins[0].y / grid_size.y) + 1,\
		floor(_model_maxs[0].z / grid_size.z) - ceil(_model_mins[0].z / grid_size.z) + 1)

	var cell_count := size.x * size.y * size.z
	var slots: Array[PackedByteArray] = []
	var style_bytes := PackedByteArray()
	if _is_rbsp:
		var expanded: Dictionary = _expand_rbsp_lightgrid(light_grid_lump, light_array_lump, cell_count)
		var empty_slots: Array[PackedByteArray] = []
		slots = expanded.get("slots", empty_slots)
		style_bytes = expanded.get("styles", PackedByteArray())
	else:
		_bsp_file.seek(light_grid_lump.offset)
		var light_grid := _bsp_file.get_buffer(light_grid_lump.length)
		slots = [light_grid]
		style_bytes.resize(cell_count * 4)
		style_bytes.fill(RBSP_LS_NONE)
		for i in cell_count:
			style_bytes[i * 4] = 0
	if slots.is_empty() or (slots[0] as PackedByteArray).is_empty():
		return
	var light_grid: PackedByteArray = slots[0]
	var count = light_grid.size() / IBSP_GRID_SAMPLE_SIZE
	print("tech3bsp: light grid: ", count, " (RBSP 4-style)" if _is_rbsp else "")
	
	if count == 0:
		# no lightgrid here, guess we're done.
		# this will make _entities basically be "fullbright" if using a shader that relies on this.
		return

	var expected_size := cell_count * IBSP_GRID_SAMPLE_SIZE
	if expected_size != light_grid.size():
		push_error("tech3bsp: expected_size: %d does not match light_grid.size(): %d!" % [expected_size, light_grid.size()])
		return

	# stanp the origin up to the grid instead of using raw mins
	var origin_tech33 := Vector3(
		grid_size.x * ceil(_model_mins[0].x / float(grid_size.x)),
		grid_size.y * ceil(_model_mins[0].y / float(grid_size.y)),
		grid_size.z * ceil(_model_mins[0].z / float(grid_size.z))
	)
	var ext_tech3 := Vector3(size.x * grid_size.x, size.y * grid_size.y, size.z * grid_size.z)
	var corner_a: Vector3 = tech3_to_gd(origin_tech33)
	var corner_b: Vector3 = tech3_to_gd(origin_tech33 + ext_tech3)
	# Godot-space AABB so the entity shader can sample with (world - offset) / size
	var grid_min := Vector3(minf(corner_a.x, corner_b.x), minf(corner_a.y, corner_b.y), minf(corner_a.z, corner_b.z))
	var grid_max := Vector3(maxf(corner_a.x, corner_b.x), maxf(corner_a.y, corner_b.y), maxf(corner_a.z, corner_b.z))
	
	_light_grid_normalize = grid_max - grid_min

	var cell_gd: Vector3 = tech3_to_gd(Vector3(grid_size.x, grid_size.y, grid_size.z)).abs()
	_light_grid_offset = Vector3(
		grid_min.x + cell_gd.x * 0.5,
		grid_min.y - cell_gd.y * 0.5,
		grid_min.z - cell_gd.z * 0.5
	)

	var tex_w: int = size.x
	var tex_h: int = size.z
	var tex_d: int = size.y
	var ambient_color_images: Array[Image]
	var direct_color_images: Array[Image]
	var cartesian_images: Array[Image]
	var slice_len := tex_w * tex_h * 3

	for tw in range(tex_d):
		var iy := tw
		var data_ambient := PackedByteArray()
		var data_direct := PackedByteArray()
		var data_cart := PackedByteArray()
		
		data_ambient.resize(slice_len)
		data_direct.resize(slice_len)
		data_cart.resize(slice_len)
		
		var pi := 0
		
		for ty in range(tex_h):
			var iz := ty
			
			for tx in range(tex_w):
				var ix: int = tex_w - 1 - tx
				var cell: int = ((iz * size.y + iy) * size.x + ix) * 8
				var ambient_color := _to_linear(scale_color(Color(
					light_grid[cell], light_grid[cell + 1], light_grid[cell + 2])))
				var direct_color := _to_linear(scale_color(Color(
					light_grid[cell + 3], light_grid[cell + 4], light_grid[cell + 5])))
				
				data_ambient[pi] = ambient_color.r8
				data_direct[pi] = direct_color.r8
				data_ambient[pi + 1] = ambient_color.g8
				data_direct[pi + 1] = direct_color.g8
				data_ambient[pi + 2] = ambient_color.b8
				data_direct[pi + 2] = direct_color.b8
				
				var cart: Vector3 = _spherical_to_cartesian(light_grid[cell + 6], light_grid[cell + 7])
				
				data_cart[pi] = int((cart.x * 0.5 + 0.5) * 255.0)
				data_cart[pi + 1] = int((cart.y * 0.5 + 0.5) * 255.0)
				data_cart[pi + 2] = int((cart.z * 0.5 + 0.5) * 255.0)
				pi += 3
		
		var amb := Image.new()
		var dir := Image.new()
		var cart_img := Image.new()
		
		amb.set_data(tex_w, tex_h, false, Image.FORMAT_RGB8, data_ambient)
		dir.set_data(tex_w, tex_h, false, Image.FORMAT_RGB8, data_direct)
		cart_img.set_data(tex_w, tex_h, false, Image.FORMAT_RGB8, data_cart)
		ambient_color_images.append(amb)
		direct_color_images.append(dir)
		cartesian_images.append(cart_img)

	var extra_amb_imgs: Array = []
	var extra_dir_imgs: Array = []
	for k in range(1, 4):
		var slot_bytes: PackedByteArray = slots[k] if k < slots.size() else PackedByteArray()
		if slot_bytes.size() != expected_size:
			slot_bytes = PackedByteArray()
			slot_bytes.resize(expected_size)
		var pair: Array = _grid_rgb_volumes(slot_bytes, size, tex_w, tex_h, tex_d)
		extra_amb_imgs.append(pair[0])
		extra_dir_imgs.append(pair[1])
	var style_imgs: Array[Image] = _grid_style_volume(style_bytes, size, tex_w, tex_h, tex_d)
	_dilate_lightgrid(
		ambient_color_images, direct_color_images, cartesian_images,
		extra_amb_imgs, extra_dir_imgs, style_imgs,
		tex_w, tex_h, tex_d
	)
	var ambient_tex := ImageTexture3D.new()
	var direct_tex := ImageTexture3D.new()
	var cartesian_tex := ImageTexture3D.new()
	ambient_tex.create(Image.FORMAT_RGB8, tex_w, tex_h, tex_d, false, ambient_color_images)
	direct_tex.create(Image.FORMAT_RGB8, tex_w, tex_h, tex_d, false, direct_color_images)
	cartesian_tex.create(Image.FORMAT_RGB8, tex_w, tex_h, tex_d, false, cartesian_images)
	_light_grid_ambient = ambient_tex
	_light_grid_direct = direct_tex
	_light_grid_cartesian = cartesian_tex
	var extra_amb: Array[ImageTexture3D] = [null, null, null]
	var extra_dir: Array[ImageTexture3D] = [null, null, null]
	for k in range(3):
		var at := ImageTexture3D.new()
		var dt := ImageTexture3D.new()
		at.create(Image.FORMAT_RGB8, tex_w, tex_h, tex_d, false, extra_amb_imgs[k])
		dt.create(Image.FORMAT_RGB8, tex_w, tex_h, tex_d, false, extra_dir_imgs[k])
		extra_amb[k] = at
		extra_dir[k] = dt
	_light_grid_ambient_1 = extra_amb[0]
	_light_grid_ambient_2 = extra_amb[1]
	_light_grid_ambient_3 = extra_amb[2]
	_light_grid_direct_1 = extra_dir[0]
	_light_grid_direct_2 = extra_dir[1]
	_light_grid_direct_3 = extra_dir[2]
	var style_tex := ImageTexture3D.new()
	style_tex.create(Image.FORMAT_RGBA8, tex_w, tex_h, tex_d, false, style_imgs)
	_light_grid_styles = style_tex


# Many brushes end up being axis-aligned, generate a BoxShape
func _try_box_from_convex_points(points: PackedVector3Array) -> Dictionary:
	if points.size() != 8:
		return {}  # can't be a box unless exactly 8 points

	const EPSILON: float = 0.001
	
	var aabb := AABB()
	aabb.position = points[0]
	aabb.size = Vector3.ZERO

	for p in points:
		aabb = aabb.expand(p)

	var expected_corners := []
	for x in [0, 1]:
		for y in [0, 1]:
			for z in [0, 1]:
				var corner = aabb.position + Vector3(x, y, z) * aabb.size
				expected_corners.append(corner)

	for p in points:
		var matched := false
		for c in expected_corners:
			if p.distance_to(c) <= EPSILON:
				matched = true
				break
		if not matched:
			return {}  # point doesn't match any AABB corner, not a box

	var box := BoxShape3D.new()
	box.size = aabb.size.abs()
	var center = aabb.position + aabb.size * 0.5

	# return a dictionary because we'll need to set the transform of the actual collisionbody later
	return {
		"shape": box,
		"transform": Transform3D(Basis(), center)
	}


func _fog_parms_for_tex(tid: int) -> PackedFloat32Array:
	var out := PackedFloat32Array([0.5, 0.5, 0.5, 1024.0])
	_ensure_shader_library()
	if !_shader_library or not _tex_ok(tid):
		return out
	var def = _shader_library.get_shader(_tex_name[tid])
	if def == null or def.fogparms.size() < 3:
		return out
	out[0] = def.fogparms[0]
	out[1] = def.fogparms[1]
	out[2] = def.fogparms[2]
	if def.fogparms.size() >= 4:
		out[3] = maxf(def.fogparms[3], 1.0)
	return out


func _prepare_fog_volumes() -> void:
	_fog_volumes.clear()
	var us := maxf(float(options.get("unit_scale", 32.0)), 0.0001)
	_fog_volumes.resize(_effect_brush.size())
	for ei in _effect_brush.size():
		var bnum: int = _effect_brush[ei]
		var empty := {"planes": [], "info": Vector4.ZERO}
		if bnum < 0 or bnum >= _brush_first_side.size():
			_fog_volumes[ei] = empty
			continue
		var tex_id := _brush_tex[bnum]
		if _effect_name[ei] != "":
			var named := _texture_id_by_name(_effect_name[ei])
			if named >= 0:
				tex_id = named
		var bp := _brush_planes(bnum)
		if bp.size() < 4:
			_fog_volumes[ei] = empty
			continue
		var parms := _fog_parms_for_tex(tex_id)
		var depth := maxf(parms[3] / us, 0.0001)
		_fog_volumes[ei] = {
			"planes": bp,
			"info": Vector4(parms[0], parms[1], parms[2], depth),
		}


func _is_weapon_clip_name(texture_name: String) -> bool:
	var n := texture_name.to_lower()
	# botclip: ignore for now; wire as its own collision bucket later
	return n.contains("weapclip") or n.contains("weaponclip") or n.contains("missileclip")


func _cf_solid() -> int:
	return CONTENT_FLAGS.SOLID # same bit on IBSP and RBSP


func _cf_lava() -> int:
	return RBSP_CONTENTS.LAVA if _is_rbsp else CONTENT_FLAGS.LAVA


func _cf_slime() -> int:
	return RBSP_CONTENTS.SLIME if _is_rbsp else CONTENT_FLAGS.SLIME


func _cf_water() -> int:
	return RBSP_CONTENTS.WATER if _is_rbsp else CONTENT_FLAGS.WATER


func _cf_fog() -> int:
	return RBSP_CONTENTS.FOG if _is_rbsp else CONTENT_FLAGS.FOG


func _cf_playerclip() -> int:
	return RBSP_CONTENTS.PLAYERCLIP if _is_rbsp else CONTENT_FLAGS.PLAYERCLIP


func _cf_monsterclip() -> int:
	return RBSP_CONTENTS.MONSTERCLIP if _is_rbsp else CONTENT_FLAGS.MONSTERCLIP


func _cf_trigger() -> int:
	return RBSP_CONTENTS.TRIGGER if _is_rbsp else CONTENT_FLAGS.TRIGGER


func _cf_shotclip() -> int:
	return RBSP_CONTENTS.SHOTCLIP if _is_rbsp else 0


func _cf_translucent() -> int:
	return RBSP_CONTENTS.TRANSLUCENT if _is_rbsp else CONTENT_FLAGS.TRANSLUCENT


func _clip_skip_contents() -> int:
	# Raven OPAQUE is 0x8000 (Q3 AREAPORTAL).
	if _is_rbsp:
		return 0
	return CONTENT_FLAGS.ORIGIN | CONTENT_FLAGS.AREAPORTAL | CONTENT_FLAGS.CLUSTERPORTAL


func _clip_skip_surf() -> int:
	if _is_rbsp:
		return RBSP_SURFACE.SKY
	return SURFACE_FLAGS.HINT | SURFACE_FLAGS.SKIP | SURFACE_FLAGS.SKY


func _sf_nodraw() -> int:
	return RBSP_SURFACE.NODRAW if _is_rbsp else SURFACE_FLAGS.NODRAW


func _sf_sky() -> int:
	return RBSP_SURFACE.SKY if _is_rbsp else SURFACE_FLAGS.SKY


func _skip_drawsurf(texture_id: int) -> bool:
	if not _tex_ok(texture_id):
		return true
	var flags: int = _tex_flags[texture_id]
	if flags & _sf_nodraw():
		return true
	# Raven has no HINT/SKIP. Q3 0x100/0x200 false-hits material bits.
	if not _is_rbsp and flags & (SURFACE_FLAGS.HINT | SURFACE_FLAGS.SKIP):
		return true
	if flags & _sf_sky() and (options.remove_skies or _drop_portal_skies):
		return true
	# Volume-only fog has no drawsurf. A stage (death-fog clouds) stays a face.
	if _tex_contents[texture_id] & _cf_fog() and not _texture_fog_has_surface(texture_id):
		return true
	return false


func _hull_contents() -> int:
	var bits := _cf_solid() | _cf_playerclip() | _cf_monsterclip()
	if _is_rbsp:
		bits |= RBSP_CONTENTS.SHOTCLIP
	return bits


func _is_volume_contents(cf: int) -> bool:
	if cf & _cf_fog():
		return true
	if cf & _cf_trigger():
		return true
	if cf & (_cf_water() | _cf_slime() | _cf_lava()) and not (cf & _cf_solid()):
		return true
	return false


# Q3 infoParms OR bits; lava+water+fog on one shader is common
func _liquid_bucket(cf: int) -> String:
	if cf & _cf_lava():
		return "lava"
	if cf & _cf_slime():
		return "slime"
	if cf & _cf_water():
		return "water"
	return ""


# Fog hulls with no stages are volume-only (q3map2 effects lump)
# Fog + stages still emit drawsurfs in the engine
func _texture_fog_has_surface(tid: int) -> bool:
	if not _tex_ok(tid):
		return false
	if _tex_contents[tid] & (_cf_lava() | _cf_slime() | _cf_water()):
		return true
	_ensure_shader_library()
	if !_shader_library:
		return false
	var def = _shader_library.get_shader(_tex_name[tid])
	return def != null and def.stages.size() > 0


func _is_clip_contents(cf: int, flags: int) -> bool:
	if flags & _clip_skip_surf():
		return false
	if cf & _clip_skip_contents():
		return false
	if _is_volume_contents(cf):
		return false
	return (cf & _hull_contents()) != 0


func _brush_side_texture(bi: int, prefer_volume := true) -> int:
	var best: int = _brush_tex[bi] if _tex_ok(_brush_tex[bi]) else -1
	var best_rank := 99
	var rank := {
		"lava": 0, "slime": 1, "water": 2, "fog": 3, "trigger": 4,
		"playerclip": 5, "monsterclip": 6, "weaponclip": 7
	}
	if best >= 0:
		best_rank = int(rank.get(_content_bucket(best), 99))
	for i in range(_brush_first_side[bi], _brush_first_side[bi] + _brush_num_sides[bi]):
		if i < 0 or i >= _side_tex.size():
			continue
		var sid: int = _side_tex[i]
		if not _tex_ok(sid):
			continue
		if not prefer_volume:
			if best < 0:
				best = sid
			continue
		var r: int = int(rank.get(_content_bucket(sid), 99))
		if r < best_rank:
			best = sid
			best_rank = r
	return best


func _content_bucket(tid: int) -> String:
	if not _tex_ok(tid):
		return "solid"
	var cf: int = _tex_contents[tid]
	var liquid := _liquid_bucket(cf)
	if liquid != "":
		return liquid
	if cf & _cf_fog():
		return "fog"
	if cf & _cf_trigger():
		return "trigger"
	if _is_weapon_clip_name(_tex_name[tid]) or (_is_rbsp and cf & _cf_shotclip()):
		return "weaponclip"
	if cf & _cf_playerclip() and cf & _cf_monsterclip():
		return "solid"
	if cf & _cf_playerclip():
		return "playerclip"
	if cf & _cf_monsterclip():
		return "monsterclip"
	return "solid"


func _order_coplanar(points: PackedVector3Array, normal: Vector3) -> PackedVector3Array:
	if points.size() < 3:
		return points
	var n := normal.normalized()
	var tangent := n.cross(Vector3.UP)
	if tangent.length_squared() < 0.0001:
		tangent = n.cross(Vector3.RIGHT)
	tangent = tangent.normalized()
	var bitan := n.cross(tangent)
	var c := Vector3.ZERO
	for p in points:
		c += p
	c /= float(points.size())
	var keyed: Array = []
	for p in points:
		var d := p - c
		keyed.append([atan2(d.dot(bitan), d.dot(tangent)), p])
	keyed.sort_custom(func(a, b): return a[0] > b[0])
	var out := PackedVector3Array()
	for k in keyed:
		out.append(k[1])
	return out


func _solid_volume_from_brush(bi: int) -> Dictionary:
	var points := _fog_points_from_brush(bi)
	if points.size() < 4:
		return {}
	var as_box := _try_box_from_convex_points(points)
	if not as_box.is_empty():
		return as_box
	var convex := ConvexPolygonShape3D.new()
	convex.points = points
	return {
		"shape": convex,
		"transform": Transform3D.IDENTITY
	}


func _plane_from_side_index(plane_index: int) -> Plane:
	var n := _plane_n.size()
	if plane_index >= 0 and plane_index < n:
		return Plane(_plane_n[plane_index], _plane_d[plane_index])
	# some compilers store a flipped plane as ~index.
	var flipped := ~plane_index
	if flipped >= 0 and flipped < n:
		return Plane(-_plane_n[flipped], -_plane_d[flipped])
	return Plane()


func _brush_planes(bi: int) -> Array[Plane]:
	var bp: Array[Plane] = []
	for i in range(_brush_first_side[bi], _brush_first_side[bi] + _brush_num_sides[bi]):
		if i < 0 or i >= _side_plane.size():
			continue
		var pl := _plane_from_side_index(_side_plane[i])
		if pl.normal == Vector3.ZERO:
			continue
		bp.append(pl)
	return bp


func _on_plane_epsilon() -> float:
	var scale := maxf(float(options.get("unit_scale", 32.0)), 1.0)
	return maxf(0.002, 0.125 / scale)


func _snap_clip_vert(v: Vector3) -> Vector3:
	# Collapse micro-slivers before Jolt cooks the mesh. 
	# 0.0005 Godot units is 0.016 qu at unit_scale 32.
	const SNAP := 0.0005
	return Vector3(snappedf(v.x, SNAP), snappedf(v.y, SNAP), snappedf(v.z, SNAP))


func _tri_is_usable(a: Vector3, b: Vector3, c: Vector3) -> bool:
	# Jolt MeshShape drops degenerates then errors if none remain.
	# LengthSq threshold is well above Jolt's ~1e-12 cook epsilon.
	if a.is_equal_approx(b) or b.is_equal_approx(c) or c.is_equal_approx(a):
		return false
	return (b - a).cross(c - a).length_squared() > 1e-8


func _sanitize_collision_faces(faces: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	var i := 0
	while i + 2 < faces.size():
		var a := _snap_clip_vert(faces[i])
		var b := _snap_clip_vert(faces[i + 1])
		var c := _snap_clip_vert(faces[i + 2])
		i += 3
		if _tri_is_usable(a, b, c):
			out.append(a)
			out.append(b)
			out.append(c)
	return out


func _append_oriented_tri(out: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3, front: Vector3) -> void:
	var cr := (b - a).cross(c - a)
	if not _tri_is_usable(a, b, c):
		return
	# Jolt MeshShape front face is CCW.
	# Match `front` so mixed rings/patches cannot flip a whole polygon from one skinny first triangle.
	if cr.dot(front) < 0.0:
		out.append(a)
		out.append(c)
		out.append(b)
	else:
		out.append(a)
		out.append(b)
		out.append(c)


func _append_plane_tris(out: PackedVector3Array, points: PackedVector3Array, pl: Plane, eps: float) -> void:
	var on_plane := PackedVector3Array()
	for p in points:
		if absf(pl.distance_to(p)) <= eps:
			on_plane.append(p)
	if on_plane.size() < 3:
		return
	on_plane = _order_coplanar(on_plane, pl.normal)
	for t in range(1, on_plane.size() - 1):
		_append_oriented_tri(out, on_plane[0], on_plane[t], on_plane[t + 1], -pl.normal)


func _texture_slug(texture_name: String) -> String:
	var s := texture_name.replace("\\", "/")
	if s.begins_with("textures/"):
		s = s.substr(9)
	s = s.replace("/", "_").replace(" ", "_")
	if s.is_empty():
		s = "unnamed"
	return s.validate_node_name()


func _clip_group_key(tid: int, bucket: String) -> String:
	if not _tex_ok(tid):
		return ""
	return "%s\t%s" % [_tex_name[tid].replace("\\", "/").to_lower(), bucket]


func _hull_append(hulls: Dictionary, bucket: String, tid: int, faces: PackedVector3Array) -> void:
	if faces.is_empty() or not _tex_ok(tid):
		return
	if bucket == "" or bucket in ["fog", "water", "slime", "lava", "trigger"]:
		bucket = "solid"
	var key := _clip_group_key(tid, bucket)
	if key == "":
		return
	if not hulls.has(key):
		hulls[key] = {
			"faces": PackedVector3Array(),
			"tid": tid,
			"bucket": bucket,
		}
	var acc: PackedVector3Array = hulls[key]["faces"]
	acc.append_array(faces)
	hulls[key]["faces"] = acc


func _brush_to_faces(bi: int) -> PackedVector3Array:
	var bp := _brush_planes(bi)
	if bp.size() < 4:
		return PackedVector3Array()
	var points := Geometry3D.compute_convex_mesh_points(bp)
	if points.size() < 4:
		return PackedVector3Array()
	var eps := _on_plane_epsilon()
	var faces := PackedVector3Array()
	for pl in bp:
		_append_plane_tris(faces, points, pl, eps)
	return faces


func _brush_faces_by_side_texture(bi: int) -> Dictionary:
	var out := {}
	var bp := _brush_planes(bi)
	if bp.size() < 4:
		return out
	var points := Geometry3D.compute_convex_mesh_points(bp)
	if points.size() < 4:
		return out
	var eps := _on_plane_epsilon()
	for i in range(_brush_first_side[bi], _brush_first_side[bi] + _brush_num_sides[bi]):
		if i < 0 or i >= _side_plane.size():
			continue
		var pl := _plane_from_side_index(_side_plane[i])
		if pl.normal == Vector3.ZERO:
			continue
		var tid: int = _side_tex[i]
		if not _tex_ok(tid):
			tid = _brush_tex[bi]
		if not _tex_ok(tid):
			continue
		var acc: PackedVector3Array = out.get(tid, PackedVector3Array())
		_append_plane_tris(acc, points, pl, eps)
		out[tid] = acc
	return out


func _texture_id_by_name(shader_name: String) -> int:
	var key := shader_name.replace("\\", "/").to_lower()
	if key.get_extension() != "":
		key = key.get_basename()
	for i in _tex_name.size():
		if _tex_name[i].replace("\\", "/").to_lower() == key:
			return i
	return -1


func _fog_points_from_brush(bi: int) -> PackedVector3Array:
	var bp := _brush_planes(bi)
	if bp.size() < 4:
		return PackedVector3Array()
	return Geometry3D.compute_convex_mesh_points(bp)
func _fog_skin_uv(p: Vector3, n: Vector3) -> Vector2:
	var q := p * maxf(float(options.get("unit_scale", 32.0)), 1.0)
	if absf(n.y) >= absf(n.x) and absf(n.y) >= absf(n.z):
		return Vector2(q.x, q.z) / 64.0
	if absf(n.x) >= absf(n.z):
		return Vector2(q.z, q.y) / 64.0
	return Vector2(q.x, q.y) / 64.0


func _add_fog_skin(parent: Node, bnum: int, tid: int) -> bool:
	# Cloud stages on a fog shader are the hull skin. Liquids already draw.
	if bnum < 0 or not _tex_ok(tid):
		return false
	if _tex_contents[tid] & (_cf_water() | _cf_slime() | _cf_lava()):
		return false
	if not _texture_fog_has_surface(tid):
		return false
	var faces := _brush_to_faces(bnum)
	if faces.size() < 3:
		return false
	var mat := _material_from_path(tid, -1, false)
	if mat == null:
		return false
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var i := 0
	while i + 2 < faces.size():
		var a: Vector3 = faces[i]
		var b: Vector3 = faces[i + 1]
		var c: Vector3 = faces[i + 2]
		i += 3
		var n := (b - a).cross(c - a)
		if n.length_squared() <= 1e-10:
			continue
		n = n.normalized()
		st.set_normal(n)
		st.set_uv(_fog_skin_uv(a, n))
		st.add_vertex(a)
		st.set_normal(n)
		st.set_uv(_fog_skin_uv(b, n))
		st.add_vertex(b)
		st.set_normal(n)
		st.set_uv(_fog_skin_uv(c, n))
		st.add_vertex(c)
	st.index()
	var mesh := st.commit()
	if mesh == null or mesh.get_surface_count() == 0:
		return false
	if mat is ShaderMaterial:
		(mat as ShaderMaterial).render_priority = 126
	mesh.surface_set_material(0, mat)
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	inst.name = "FogSkin"
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_add_to_bsp_scene(inst, true, parent)
	return true


func _add_fog_volumes(parent: Node) -> void:
	if _fog_volumes.is_empty():
		_prepare_fog_volumes()
	var sh := load("res://addons/tech3bsp/shaders/q3_fog_fullscreen.gdshader") as Shader
	if sh == null:
		return
	var infos := PackedVector4Array()
	infos.resize(32)
	var counts := PackedFloat32Array()
	counts.resize(32)
	var packed := PackedVector4Array()
	packed.resize(512)
	var mins := PackedVector4Array()
	mins.resize(32)
	var maxs := PackedVector4Array()
	maxs.resize(32)
	var nvol := 0
	for ei in _fog_volumes.size():
		if nvol >= 32:
			break
		var vol: Dictionary = _fog_volumes[ei]
		var info: Vector4 = vol["info"]
		if info.w <= 0.0:
			continue
		infos[nvol] = info
		var nplanes := 0
		for pl in vol.get("planes", []):
			if nplanes >= 16:
				break
			var plane := pl as Plane
			if plane.normal == Vector3.ZERO:
				continue
			packed[nvol * 16 + nplanes] = Vector4(plane.normal.x, plane.normal.y, plane.normal.z, plane.d)
			nplanes += 1
		if nplanes < 4:
			continue
		var box_pts := Geometry3D.compute_convex_mesh_points(vol.get("planes", []))
		var bmin := Vector3(1.0e9, 1.0e9, 1.0e9)
		var bmax := Vector3(-1.0e9, -1.0e9, -1.0e9)
		for pt in box_pts:
			bmin = bmin.min(pt)
			bmax = bmax.max(pt)
		if box_pts.is_empty():
			continue
		mins[nvol] = Vector4(bmin.x, bmin.y, bmin.z, 0.0)
		maxs[nvol] = Vector4(bmax.x, bmax.y, bmax.z, 0.0)
		counts[nvol] = float(nplanes)
		nvol += 1
	if nvol == 0:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_uv(Vector2(-1.0, -1.0))
	st.add_vertex(Vector3(-4096.0, -4096.0, 0.0))
	st.set_uv(Vector2(3.0, -1.0))
	st.add_vertex(Vector3(4096.0, -4096.0, 0.0))
	st.set_uv(Vector2(-1.0, 3.0))
	st.add_vertex(Vector3(-4096.0, 4096.0, 0.0))
	st.index()
	var mesh := st.commit()
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.render_priority = 120
	mat.set_shader_parameter("t3_fs_info", infos)
	mat.set_shader_parameter("t3_fs_nplanes", counts)
	mat.set_shader_parameter("t3_fs_planes", packed)
	mat.set_shader_parameter("t3_fs_mins", mins)
	mat.set_shader_parameter("t3_fs_maxs", maxs)
	mat.set_shader_parameter("t3_fs_count", nvol)
	mesh.surface_set_material(0, mat)
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	inst.name = "FogPass"
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	inst.extra_cull_margin = 100000.0
	inst.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_add_to_bsp_scene(inst, true, parent)
	print("tech3bsp: q3 fog pass: ", nvol, " volume(s)")
	var skins := 0
	for ei in _fog_volumes.size():
		var vol: Dictionary = _fog_volumes[ei]
		if (vol["info"] as Vector4).w <= 0.0:
			continue
		if _add_fog_skin(parent, int(vol.get("brush", -1)), int(vol.get("tex", -1))):
			skins += 1
	if skins > 0:
		print("tech3bsp: q3 fog skins: ", skins)


func _tex_is_clip_hull(tid: int) -> bool:
	if not _tex_ok(tid):
		return false
	# Q3 has no weaponclip content bit. Name is only a layer bucket.
	if _is_weapon_clip_name(_tex_name[tid]):
		if _tex_flags[tid] & _clip_skip_surf():
			return false
		if _tex_contents[tid] & _clip_skip_contents():
			return false
		return true
	return _is_clip_contents(_tex_contents[tid], _tex_flags[tid])


func _brush_clip_tid(bi: int) -> int:
	if _tex_ok(_brush_tex[bi]):
		return _brush_tex[bi]
	return _brush_side_texture(bi, false)


func _tessellate_patch_collision(fi: int, subdivisions: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	var grid := _subdivide_patch_to_grid(fi, maxf(float(subdivisions) * 2.0, 2.0))
	var gw: int = int(grid.get("width", 0))
	var gh: int = int(grid.get("height", 0))
	var ctrl: Array = grid.get("ctrl", [])
	if gw < 2 or gh < 2 or ctrl.is_empty():
		return out
	for y in range(gh - 1):
		for x in range(gw - 1):
			var va: Dictionary = ctrl[y][x]
			var vb: Dictionary = ctrl[y][x + 1]
			var vc: Dictionary = ctrl[y + 1][x]
			var vd: Dictionary = ctrl[y + 1][x + 1]
			var a: Vector3 = va["p"]
			var b: Vector3 = vb["p"]
			var c: Vector3 = vc["p"]
			var d: Vector3 = vd["p"]
			var na: Vector3 = va["n"]
			var nb: Vector3 = vb["n"]
			var nc: Vector3 = vc["n"]
			var nd: Vector3 = vd["n"]
			var n_abd: Vector3 = na + nb + nd
			if n_abd.length_squared() < 0.0001:
				n_abd = (b - a).cross(d - a)
			var n_adc: Vector3 = na + nd + nc
			if n_adc.length_squared() < 0.0001:
				n_adc = (d - a).cross(c - a)
			_append_oriented_tri(out, a, b, d, -n_abd)
			_append_oriented_tri(out, a, d, c, -n_adc)
	return out


func _clip_layer_for_bucket(bucket: String) -> int:
	match bucket:
		"playerclip":
			return COL_LAYER_PLAYER
		"monsterclip":
			return COL_LAYER_MONSTER
		"weaponclip":
			return COL_LAYER_WEAPON
		_:
			return COL_LAYER_WORLD


func _emit_clip_body(faces: PackedVector3Array, bucket: String, parent: Node, body_name: String, tid: int) -> void:
	var tris := _sanitize_collision_faces(faces)
	if tris.size() < 3:
		return
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(tris)
	shape.backface_collision = bool(options.get("clip_backface_collision", false))
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.name = "Shape"
	if parent is CollisionObject3D:
		cs.name = body_name
		_add_to_bsp_scene(cs, true, parent)
		return
	var body := StaticBody3D.new()
	body.name = body_name
	body.collision_layer = _clip_layer_for_bucket(bucket)
	body.collision_mask = 0
	if _tex_ok(tid):
		body.set_meta("texture_name", _tex_name[tid])
		body.set_meta("flags", _tex_flags[tid])
		body.set_meta("content_flags", _tex_contents[tid])
		_apply_contact_meta(body, tid)
	_add_to_bsp_scene(body)
	_add_to_bsp_scene(cs, true, body)


# Generate Godot equiv of a clip hull.
# Faces grouped by brush side texture name and collision layer.
# e.g. a brush with three textures would become three StaticBody3D's
func _add_collisions(mi: int, parent: Node) -> void:
	var hulls := {}
	var brush_volumes: Array = []
	var patch_collision_subdivisions: int = maxi(2, int(options.patch_detail))

	for b in range(_model_brush[mi], _model_brush[mi] + _model_num_brushes[mi]):
		var vol_tid := _brush_side_texture(b)
		if vol_tid >= 0:
			var vol_bucket := _content_bucket(vol_tid)
			if vol_bucket == "fog":
				continue
			if vol_bucket in ["water", "slime", "lava", "trigger"]:
				var vol_shape := _solid_volume_from_brush(b)
				if vol_shape.is_empty():
					continue
				vol_shape["bucket"] = vol_bucket
				vol_shape["texture_id"] = _brush_tex[b]
				vol_shape["texture_name"] = _tex_name[vol_tid]
				vol_shape["flags"] = _tex_flags[vol_tid]
				vol_shape["content_flags"] = _tex_contents[vol_tid]
				brush_volumes.append(vol_shape)
				continue
		var clip_tid := _brush_clip_tid(b)
		if not _tex_is_clip_hull(clip_tid):
			continue
		var clip_bucket := _content_bucket(clip_tid)
		var by_side := _brush_faces_by_side_texture(b)
		if by_side.is_empty():
			_hull_append(hulls, clip_bucket, clip_tid, _brush_to_faces(b))
			continue
		for sid in by_side.keys():
			_hull_append(hulls, clip_bucket, int(sid), by_side[sid])

	for f in range(_model_face[mi], _model_face[mi] + _model_num_faces[mi]):
		if _face_type[f] != FACE_TYPE.PATCH:
			continue
		var ptid: int = _face_tex[f]
		if not _tex_is_clip_hull(ptid):
			continue
		_hull_append(hulls, _content_bucket(ptid), ptid, _tessellate_patch_collision(f, patch_collision_subdivisions))

	var names := {
		"solid": "WC",
		"playerclip": "PC",
		"monsterclip": "MC",
		"weaponclip": "WeapC",
	}
	for key in hulls.keys():
		var group: Dictionary = hulls[key]
		var tid: int = int(group["tid"])
		if not _tex_ok(tid):
			continue
		var bucket: String = String(group["bucket"])
		var prefix: String = names.get(bucket, "WC")
		var body_name := "%s_%s" % [prefix, _texture_slug(_tex_name[tid])]
		_emit_clip_body(group["faces"], bucket, parent, body_name, tid)

	var water_body: Node3D
	var slime_body: Node3D
	var lava_body: Node3D
	var trigger_body: Node3D
	for vol in brush_volumes:
		var vbucket: String = vol["bucket"]
		var collision_parent_v: Node
		if parent is CollisionObject3D:
			collision_parent_v = parent
		elif vbucket == "water":
			if !water_body and options.get("water_scene"):
				water_body = options.water_scene.instantiate()
				_add_to_bsp_scene(water_body, true)
			if !water_body:
				water_body = Area3D.new()
				water_body.name = "Water"
				_add_to_bsp_scene(water_body, true)
			collision_parent_v = water_body
		elif vbucket == "slime":
			if !slime_body and options.get("slime_scene"):
				slime_body = options.slime_scene.instantiate()
				_add_to_bsp_scene(slime_body, true)
			if !slime_body:
				slime_body = Area3D.new()
				slime_body.name = "Slime"
				_add_to_bsp_scene(slime_body, true)
			collision_parent_v = slime_body
		elif vbucket == "lava":
			if !lava_body and options.get("lava_scene"):
				lava_body = options.lava_scene.instantiate()
				_add_to_bsp_scene(lava_body, true)
			if !lava_body:
				lava_body = Area3D.new()
				lava_body.name = "Lava"
				_add_to_bsp_scene(lava_body, true)
			collision_parent_v = lava_body
		elif vbucket == "trigger":
			if !trigger_body:
				trigger_body = Area3D.new()
				trigger_body.name = "Triggers"
				_add_to_bsp_scene(trigger_body, true)
			collision_parent_v = trigger_body
		else:
			continue
		if !collision_parent_v:
			continue
		var cs := CollisionShape3D.new()
		cs.shape = vol["shape"]
		cs.transform = vol["transform"]
		cs.name = String(vol["texture_name"]).get_file()
		_add_to_bsp_scene(cs, true, collision_parent_v)


# get all the _entities that aren't lights or _worldspawn and...
# put them in the scene!
# ... if they're found in the entity map, that is.
# using an ConfigFile here because it's readily reusable
# TODO: also provide an _entities directory option?
func _add_entities() -> void:
	var entity_map := ConfigFile.new()
	var err := entity_map.load(options.entity_map)
	if err != OK:
		push_error("tech3bsp: Failed to load entity map: %s" % error_string(err))
		return
	if !entity_map.has_section("entities"):
		push_error("tech3bsp: Entity map is missing [entities] section, abandoning entity import.")
		return
	for entity in _entities:
		var entity_class: String = String(entity.get("classname", ""))
		# Lights are handled elsewhere. info_null is a Radiant target and has no runtime node.
		if entity_class.is_empty() or entity_class == "worldspawn" or entity_class == "light" or entity_class == "info_null":
			continue
		if !entity_map.has_section_key("entities", entity_class):
			if options.print_missing_entities:
				push_warning("tech3bsp: %s not found in entity map, skipping." % entity_class)
			continue
		# probably will never hit this, still worth checking.
		if !entity_map.get_value("entities", entity_class):
			# throws its own error.
			continue

		var entity_path: String = entity_map.get_value("entities", entity_class)
		if !FileAccess.file_exists(entity_path):
			push_error("tech3bsp: Failed to load entity %s! Please verify path: %s" % [entity_class, entity_path])
			continue

		var entity_scene: Node3D = load(entity_path).instantiate()
		# most brush _entities seem to expect Vector3.ZERO
		# for example doors use this and then move on global
		# coordinates rather than relative.
		# the exception is when "origin" shaders are used.
		var origin := Vector3.ZERO
		# angle / angles stay as written in the map (scripts that care
		# about -1/-2 still get them). Godot-space extras:
		#   movedir   – unit slide/aim vector
		#   gd_angles – Euler degrees for Node3D.rotation_degrees
		# Brush models are already in world space, rotating those would
		# spin the mesh. Point _entities get a basis applied.
		if entity.has("origin"):
			origin = entity["origin"]

		for key in entity.keys():
			var dest_value = entity_scene.get(key)
			if dest_value != null:
				entity_scene.set(key, entity[key])

		_add_to_bsp_scene(entity_scene, true)
		entity_scene.transform.origin = origin

		var has_brush := entity.has("model") and String(entity["model"]).begins_with("*")
		var orient := _entity_orientation(entity)
		if orient["oriented"] and not has_brush:
			var b: Basis = orient["basis"]
			entity_scene.global_transform = Transform3D(b, origin)

		if has_brush:
			var model_index: int = entity["model"].substr(1).to_int()
			_add_bsp_model(model_index, entity_scene)
			_add_collisions(model_index, entity_scene)


### New patch functions ###
# unified bezier processer
func _bezier3(a: Variant, b: Variant, c: Variant, t: float) -> Variant:
	var it: float = 1.0 - t
	return a * (it * it) + b * (2.0 * it * t) + c * (t * t)


const PATCH_GRID_MAX := 65


func _patch_ctrl_vert(idx: int) -> Dictionary:
	return {
		"p": _vertex_positions[idx],
		"n": _vertex_normals[idx],
		"uv": _vertex_uvs[idx],
		"uv2": _vertex_uv2s[idx],
		"lm1": _vertex_lm_uv1[idx] if idx < _vertex_lm_uv1.size() else Vector2.ZERO,
		"lm2": _vertex_lm_uv2[idx] if idx < _vertex_lm_uv2.size() else Vector2.ZERO,
		"lm3": _vertex_lm_uv3[idx] if idx < _vertex_lm_uv3.size() else Vector2.ZERO,
		"c": _vertex_colors[idx],
	}


func _lerp_patch_vert(a: Dictionary, b: Dictionary) -> Dictionary:
	return {
		"p": (a["p"] as Vector3).lerp(b["p"] as Vector3, 0.5),
		"n": (a["n"] as Vector3).lerp(b["n"] as Vector3, 0.5),
		"uv": (a["uv"] as Vector2).lerp(b["uv"] as Vector2, 0.5),
		"uv2": (a["uv2"] as Vector2).lerp(b["uv2"] as Vector2, 0.5),
		"lm1": (a["lm1"] as Vector2).lerp(b["lm1"] as Vector2, 0.5),
		"lm2": (a["lm2"] as Vector2).lerp(b["lm2"] as Vector2, 0.5),
		"lm3": (a["lm3"] as Vector2).lerp(b["lm3"] as Vector2, 0.5),
		"c": (a["c"] as Color).lerp(b["c"] as Color, 0.5),
	}


func _transpose_patch_ctrl(ctrl: Array, width: int, height: int) -> Array:
	var out: Array = []
	out.resize(width)
	for i in width:
		var row: Array = []
		row.resize(height)
		for j in height:
			row[j] = (ctrl[j][i] as Dictionary).duplicate()
		out[i] = row
	return out


func _put_patch_points_on_curve(ctrl: Array, width: int, height: int) -> void:
	for i in width:
		var j := 1
		while j < height:
			if j + 1 >= height:
				break
			var prev := _lerp_patch_vert(ctrl[j][i], ctrl[j + 1][i])
			var next := _lerp_patch_vert(ctrl[j][i], ctrl[j - 1][i])
			ctrl[j][i] = _lerp_patch_vert(prev, next)
			j += 2
	for j in height:
		var i := 1
		while i < width:
			if i + 1 >= width:
				break
			var prev := _lerp_patch_vert(ctrl[j][i], ctrl[j][i + 1])
			var next := _lerp_patch_vert(ctrl[j][i], ctrl[j][i - 1])
			ctrl[j][i] = _lerp_patch_vert(prev, next)
			i += 2


# R_SubdividePatchToGrid. patch_detail is r_subdivisions in Q3 units.
func _subdivide_patch_to_grid(fi: int, r_subdiv: float) -> Dictionary:
	var empty := { "width": 0, "height": 0, "ctrl": [] }
	var width := _face_patch_w[fi]
	var height := _face_patch_h[fi]
	if width < 3 or height < 3:
		return empty
	var first := _face_first_vert[fi]
	if first < 0 or first + width * height > _vertex_positions.size():
		return empty
	var us := maxf(float(options.unit_scale), 0.0001)
	var thresh := maxf(r_subdiv, 0.1) / us
	var ctrl: Array = []
	for j in height:
		var row: Array = []
		for i in width:
			row.append(_patch_ctrl_vert(first + j * width + i))
		ctrl.append(row)
	var error_table: Array = []
	error_table.append([])
	error_table.append([])
	error_table[0].resize(PATCH_GRID_MAX)
	error_table[1].resize(PATCH_GRID_MAX)
	for dir in 2:
		for e in PATCH_GRID_MAX:
			error_table[dir][e] = 0.0
		var consecutive := 0
		var j := 0
		var guard := 0
		while guard < 4096:
			guard += 1
			if width < 3:
				break
			j = j % (width - 1)
			var max_len := 0.0
			for i in height:
				var a: Vector3 = ctrl[i][j]["p"]
				var b: Vector3 = ctrl[i][j + 1]["p"]
				var c: Vector3 = ctrl[i][j + 2]["p"]
				var mid: Vector3 = (a + b * 2.0 + c) * 0.25
				var off: Vector3 = mid - a
				var along: Vector3 = c - a
				var alen := along.length()
				if alen > 0.0001:
					along /= alen
					off -= along * off.dot(along)
				var len := off.length_squared()
				if len > max_len:
					max_len = len
			max_len = sqrt(max_len)
			if max_len < 0.1 / us:
				error_table[dir][j + 1] = 999.0
				consecutive += 1
				if consecutive >= width:
					break
				j += 2
				continue
			if width + 2 > PATCH_GRID_MAX:
				error_table[dir][j + 1] = 1.0 / maxf(max_len, 0.0001)
				break
			if max_len <= thresh:
				error_table[dir][j + 1] = 1.0 / maxf(max_len, 0.0001)
				consecutive += 1
				if consecutive >= width:
					break
				j += 2
				continue
			error_table[dir][j + 2] = 1.0 / maxf(max_len, 0.0001)
			consecutive = 0
			width += 2
			for i in height:
				var prev := _lerp_patch_vert(ctrl[i][j], ctrl[i][j + 1])
				var next := _lerp_patch_vert(ctrl[i][j + 1], ctrl[i][j + 2])
				var midv := _lerp_patch_vert(prev, next)
				ctrl[i].resize(width)
				var k := width - 1
				while k > j + 3:
					ctrl[i][k] = (ctrl[i][k - 2] as Dictionary).duplicate()
					k -= 1
				ctrl[i][j + 1] = prev
				ctrl[i][j + 2] = midv
				ctrl[i][j + 3] = next
			j += 2
		ctrl = _transpose_patch_ctrl(ctrl, width, height)
		var tmp := width
		width = height
		height = tmp
	_put_patch_points_on_curve(ctrl, width, height)
	var i := 1
	while i < width - 1:
		if float(error_table[0][i]) != 999.0:
			i += 1
			continue
		for j in range(i + 1, width):
			for k in height:
				ctrl[k][j - 1] = (ctrl[k][j] as Dictionary).duplicate()
			error_table[0][j - 1] = error_table[0][j]
		width -= 1
	i = 1
	while i < height - 1:
		if float(error_table[1][i]) != 999.0:
			i += 1
			continue
		for j in range(i + 1, height):
			for k in width:
				ctrl[j - 1][k] = (ctrl[j][k] as Dictionary).duplicate()
			error_table[1][j - 1] = error_table[1][j]
		height -= 1
	return { "width": width, "height": height, "ctrl": ctrl }


func _patch_border_pts(grid: Dictionary, side: int) -> Array:
	var w: int = int(grid.get("width", 0))
	var h: int = int(grid.get("height", 0))
	var ctrl: Array = grid.get("ctrl", [])
	var pts: Array = []
	if w < 2 or h < 2 or ctrl.is_empty():
		return pts
	match side:
		0:
			for x in w:
				pts.append((ctrl[0][x] as Dictionary)["p"])
		1:
			for x in w:
				pts.append((ctrl[h - 1][x] as Dictionary)["p"])
		2:
			for y in h:
				pts.append((ctrl[y][0] as Dictionary)["p"])
		_:
			for y in h:
				pts.append((ctrl[y][w - 1] as Dictionary)["p"])
	return pts


func _patch_pt_key(p: Vector3, q: float) -> String:
	return "%d:%d:%d" % [roundi(p.x / q), roundi(p.y / q), roundi(p.z / q)]


func _patch_edge_key(a: Vector3, b: Vector3, q: float) -> String:
	var ka := _patch_pt_key(a, q)
	var kb := _patch_pt_key(b, q)
	if ka < kb:
		return ka + "|" + kb
	return kb + "|" + ka


func _insert_patch_column(grid: Dictionary, after: int) -> void:
	var w: int = int(grid["width"])
	var h: int = int(grid["height"])
	if after < 0 or after >= w - 1 or w + 1 > PATCH_GRID_MAX:
		return
	var ctrl: Array = grid["ctrl"]
	for y in h:
		var mid := _lerp_patch_vert(ctrl[y][after], ctrl[y][after + 1])
		(ctrl[y] as Array).insert(after + 1, mid)
	grid["width"] = w + 1


func _insert_patch_row(grid: Dictionary, after: int) -> void:
	var w: int = int(grid["width"])
	var h: int = int(grid["height"])
	if after < 0 or after >= h - 1 or h + 1 > PATCH_GRID_MAX:
		return
	var ctrl: Array = grid["ctrl"]
	var row: Array = []
	for x in w:
		row.append(_lerp_patch_vert(ctrl[after][x], ctrl[after + 1][x]))
	ctrl.insert(after + 1, row)
	grid["height"] = h + 1


func _insert_missing_on_patch_border(grid: Dictionary, side: int, other: Array, snap: float) -> bool:
	var changed := false
	var guard := 0
	while guard < 64:
		guard += 1
		var mine := _patch_border_pts(grid, side)
		if mine.size() < 2 or other.size() < 2:
			return changed
		var inserted := false
		for op in other:
			var p: Vector3 = op
			var best_d := snap
			var best_seg := -1
			for i in range(mine.size() - 1):
				var a: Vector3 = mine[i]
				var b: Vector3 = mine[i + 1]
				if p.distance_to(a) <= snap or p.distance_to(b) <= snap:
					best_seg = -1
					break
				var ab: Vector3 = b - a
				var ab2 := ab.length_squared()
				if ab2 < 0.0000001:
					continue
				var t := clampf((p - a).dot(ab) / ab2, 0.0, 1.0)
				if t <= 0.02 or t >= 0.98:
					continue
				var d := p.distance_to(a + ab * t)
				if d < best_d:
					best_d = d
					best_seg = i
			if best_seg < 0:
				continue
			if side <= 1:
				_insert_patch_column(grid, best_seg)
			else:
				_insert_patch_row(grid, best_seg)
			changed = true
			inserted = true
			break
		if not inserted:
			break
	return changed


func _snap_patch_borders(ga: Dictionary, sa: int, gb: Dictionary, sb: int, snap: float) -> void:
	var pa := _patch_border_pts(ga, sa)
	var pb := _patch_border_pts(gb, sb)
	if pa.size() < 2 or pb.size() < 2:
		return
	var ca: Array = ga["ctrl"]
	var cb: Array = gb["ctrl"]
	var wa: int = int(ga["width"])
	var ha: int = int(ga["height"])
	var wb: int = int(gb["width"])
	var hb: int = int(gb["height"])
	for i in pa.size():
		var p: Vector3 = pa[i]
		var best := 0
		var best_d := p.distance_squared_to(pb[0])
		for j in range(1, pb.size()):
			var d := p.distance_squared_to(pb[j])
			if d < best_d:
				best_d = d
				best = j
		if best_d > snap * snap:
			continue
		var mid: Vector3 = (p + pb[best]) * 0.5
		match sa:
			0:
				(ca[0][i] as Dictionary)["p"] = mid
			1:
				(ca[ha - 1][i] as Dictionary)["p"] = mid
			2:
				(ca[i][0] as Dictionary)["p"] = mid
			_:
				(ca[i][wa - 1] as Dictionary)["p"] = mid
		match sb:
			0:
				(cb[0][best] as Dictionary)["p"] = mid
			1:
				(cb[hb - 1][best] as Dictionary)["p"] = mid
			2:
				(cb[best][0] as Dictionary)["p"] = mid
			_:
				(cb[best][wb - 1] as Dictionary)["p"] = mid


func _stitch_patch_grids(jobs: Array) -> void:
	if jobs.size() < 2:
		return
	var us := maxf(float(options.unit_scale), 0.0001)
	var quant := 2.0 / us
	var snap := 1.5 / us
	var buckets: Dictionary = {}
	for ji in jobs.size():
		var grid: Dictionary = jobs[ji]["grid"]
		for side in 4:
			var pts := _patch_border_pts(grid, side)
			if pts.size() < 2:
				continue
			var key := _patch_edge_key(pts[0], pts[pts.size() - 1], quant)
			if not buckets.has(key):
				buckets[key] = []
			(buckets[key] as Array).append({ "j": ji, "side": side })
	for key in buckets.keys():
		var group: Array = buckets[key]
		if group.size() < 2:
			continue
		for _pass in 8:
			var grew := false
			for a in range(group.size()):
				for b in range(a + 1, group.size()):
					var ja: Dictionary = jobs[group[a]["j"]]["grid"]
					var jb: Dictionary = jobs[group[b]["j"]]["grid"]
					var sa: int = int(group[a]["side"])
					var sb: int = int(group[b]["side"])
					var pa := _patch_border_pts(ja, sa)
					var pb := _patch_border_pts(jb, sb)
					grew = _insert_missing_on_patch_border(jb, sb, pa, snap) or grew
					grew = _insert_missing_on_patch_border(ja, sa, pb, snap) or grew
			if not grew:
				break
		for a in range(group.size()):
			for b in range(a + 1, group.size()):
				_snap_patch_borders(
					jobs[group[a]["j"]]["grid"], int(group[a]["side"]),
					jobs[group[b]["j"]]["grid"], int(group[b]["side"]),
					snap * 2.0
				)

func _emit_patch_grid(fi: int, surface: Dictionary, vertex_color: bool, grid: Dictionary) -> void:
	var st: SurfaceTool = surface.st
	var gw: int = int(grid.get("width", 0))
	var gh: int = int(grid.get("height", 0))
	var ctrl: Array = grid.get("ctrl", [])
	if gw < 2 or gh < 2 or ctrl.is_empty():
		return
	var base: int = surface.vertex_count
	for y in gh:
		for x in gw:
			var v: Dictionary = ctrl[y][x]
			var nn: Vector3 = v["n"]
			if nn.length_squared() > 0.0001:
				nn = nn.normalized()
			else:
				nn = Vector3.UP
			_add_vertex_to_surface(
				st, v["p"], nn, v["uv"],
				_lm_page_uv(v["uv2"], fi, 0),
				v["c"], vertex_color, _face_lm[fi],
				_lm_atlas_uv(v["lm1"], fi, 1),
				_lm_atlas_uv(v["lm2"], fi, 2),
				_lm_atlas_uv(v["lm3"], fi, 3),
				_face_style_attr(fi)
			)
			surface.vertex_count += 1

	for y in range(gh - 1):
		for x in range(gw - 1):
			var v2 := base + y * gw + x
			var v1 := v2 + 1
			var v3 := v2 + gw
			var v4 := v3 + 1
			st.add_index(v2)
			st.add_index(v3)
			st.add_index(v1)
			st.add_index(v1)
			st.add_index(v3)
			st.add_index(v4)


func _add_vertex_to_surface(st: SurfaceTool, pos: Vector3, normal: Vector3, uv: Vector2, uv2: Vector2, color: Color, vertex_color := false, lightmap_id: int = -1, lm1: Vector2 = Vector2.ZERO, lm2: Vector2 = Vector2.ZERO, lm3: Vector2 = Vector2.ZERO, styles: Color = Color(0, 1, 1, 1)) -> void:
	st.set_normal(normal)
	st.set_uv(uv)
	st.set_uv2(uv2)
	st.set_custom(0, _lm_cell_custom(lightmap_id if lightmap_id >= 0 else -1))
	st.set_custom(1, Color(lm1.x, lm1.y, lm2.x, lm2.y))
	st.set_custom(2, Color(lm3.x, lm3.y, 0.0, 0.0))
	st.set_custom(3, styles)
	if options.import_vertex_colors:
		st.set_color(_vertex_light_color(color) if vertex_color else Color(1, 1, 1, 1))
	st.add_vertex(pos)


func _texture_billboard_mode(texture_id: int) -> int:
	if !_shader_library or texture_id < 0 or texture_id >= _tex_name.size():
		return 0
	var def = _shader_library.get_shader(_tex_name[texture_id])
	if !def:
		return 0
	return int(def.billboard)


func _autosprite2_unique_pts(pts: Array) -> Array:
	var out: Array = []
	for p in pts:
		var dup := false
		for q in out:
			if p.distance_squared_to(q) < 0.0001:
				dup = true
				break
		if not dup:
			out.append(p)
	return out


func _autosprite2_axes(pts: Array) -> Dictionary:
	pts = _autosprite2_unique_pts(pts)
	var major := Vector3.UP
	var n: int = pts.size()
	if n >= 4:
		var best_a := 1e12
		var best_b := 1e12
		var mid_a := Vector3.ZERO
		var mid_b := Vector3.ZERO
		for i in n:
			for j in range(i + 1, n):
				var d: float = pts[i].distance_squared_to(pts[j])
				var mid: Vector3 = (pts[i] + pts[j]) * 0.5
				if d < best_a:
					best_b = best_a
					mid_b = mid_a
					best_a = d
					mid_a = mid
				elif d < best_b:
					best_b = d
					mid_b = mid
		major = mid_b - mid_a
	elif n >= 2:
		var farthest := 0.0
		for i in n:
			for j in range(i + 1, n):
				var d: float = pts[i].distance_squared_to(pts[j])
				if d > farthest:
					farthest = d
					major = pts[j] - pts[i]
	if major.length_squared() < 0.0000001:
		major = Vector3.UP
	major = major.normalized()
	var face_n := Vector3.ZERO
	for i in pts.size():
		var a: Vector3 = pts[i]
		var b: Vector3 = pts[(i + 1) % pts.size()]
		face_n += Vector3(
			(a.y - b.y) * (a.z + b.z),
			(a.z - b.z) * (a.x + b.x),
			(a.x - b.x) * (a.y + b.y)
		)
	if face_n.length_squared() < 0.0000001 and pts.size() >= 3:
		face_n = (pts[1] - pts[0]).cross(pts[2] - pts[0])
	if face_n.length_squared() < 0.0000001:
		face_n = Vector3.UP
	else:
		face_n = face_n.normalized()

	var minor: Vector3 = face_n.cross(major)
	if minor.length_squared() < 0.0000001:
		minor = Vector3.UP.cross(major)
	if minor.length_squared() < 0.0000001:
		minor = Vector3.RIGHT.cross(major)
	minor = minor.normalized()
	return { "major": major, "minor": minor }


func _add_autosprite_face(fi: int, parent: Node, vertex_color: bool) -> void:
	# AutospriteDeform: independent quads, 4 verts each, own midpoint.
	if _face_num_verts[fi] < 3:
		return
	var first := _face_first_vert[fi]
	var nvert := _face_num_verts[fi]
	var mode := _texture_billboard_mode(_face_tex[fi])
	var mat := _material_from_path(_face_tex[fi], _face_lm[fi], _face_uses_lightmap(fi))
	var groups: Array = []
	if (nvert & 3) == 0:
		var g := 0
		while g < nvert:
			groups.append([first + g, first + g + 1, first + g + 2, first + g + 3])
			g += 4
	else:
		var all: Array = []
		for v in range(first, first + nvert):
			all.append(v)
		groups.append(all)
	for grp in groups:
		var centroid := Vector3.ZERO
		var pts: Array = []
		for vi in grp:
			centroid += _vertex_positions[vi]
			pts.append(_vertex_positions[vi])
		centroid /= float(grp.size())
		var axes := _autosprite2_axes(pts)
		var right: Vector3 = axes["major"]
		var up: Vector3 = axes["minor"]
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.set_custom_format(0, SurfaceTool.CUSTOM_RGBA_FLOAT)
		st.set_material(mat)
		var lm_c := _lm_cell_custom(_face_lm[fi] if _face_lm[fi] >= 0 else -1)
		if mode != 2 and grp.size() >= 4:
			var radius := 0.0
			for vi in grp:
				radius = maxf(radius, _vertex_positions[vi].distance_to(centroid))
			radius *= 0.70710678
			if radius < 0.0001:
				continue
			var corners: Array = [
				[Vector3(-radius, -radius, 0.0), Vector2(0, 1)],
				[Vector3(radius, -radius, 0.0), Vector2(1, 1)],
				[Vector3(radius, radius, 0.0), Vector2(1, 0)],
				[Vector3(-radius, radius, 0.0), Vector2(0, 0)],
			]
			for c in corners:
				st.set_normal(Vector3(0, 0, 1))
				st.set_uv(c[1])
				st.set_custom(0, lm_c)
				st.add_vertex(c[0])
		else:
			var verts_data: Array = []
			for vi in grp:
				var off: Vector3 = _vertex_positions[vi] - centroid
				var local := Vector3(off.dot(right), off.dot(up), 0.0)
				var col := Color(1, 1, 1, 1)
				if options.import_vertex_colors:
					col = _vertex_light_color(_vertex_colors[vi]) if vertex_color else Color(1, 1, 1, 1)
				verts_data.append({
					"local": local,
					"uv": _vertex_uvs[vi],
					"uv2": _lm_page_uv(_vertex_uv2s[vi], fi, 0),
					"color": col,
				})
			# For autosprite2, original vertex order often produces a crossed
			# triangulation with the fixed indices (Pac-Man).
			# Slot the four projected points into the same corner order the
			# square autosprite uses so 0,2,1 / 0,3,2 cover the full quad.
			if mode == 2 and verts_data.size() == 4:
				var ordered: Array = [null, null, null, null]
				var conflict := false
				for d in verts_data:
					var lx: float = d["local"].x
					var ly: float = d["local"].y
					var slot := 0
					if lx >= 0.0 and ly < 0.0:
						slot = 1
					elif lx >= 0.0 and ly >= 0.0:
						slot = 2
					elif lx < 0.0 and ly >= 0.0:
						slot = 3
					if ordered[slot] != null:
						conflict = true
						break
					ordered[slot] = d
				if not conflict and ordered[0] != null and ordered[1] != null and ordered[2] != null and ordered[3] != null:
					verts_data = ordered
			for d in verts_data:
				st.set_normal(Vector3(0, 0, 1))
				st.set_uv(d["uv"])
				st.set_uv2(d["uv2"])
				st.set_custom(0, lm_c)
				if options.import_vertex_colors:
					st.set_color(d["color"])
				st.add_vertex(d["local"])

		if grp.size() >= 4:
			st.add_index(0)
			st.add_index(2)
			st.add_index(1)
			st.add_index(0)
			st.add_index(3)
			st.add_index(2)
		else:
			st.index()
		var mesh := st.commit()
		if !mesh or mesh.get_surface_count() == 0:
			continue
		var inst := MeshInstance3D.new()
		inst.mesh = mesh
		inst.position = centroid
		inst.extra_cull_margin = 16.0
		if mode == 2:
			var zn: Vector3 = right.cross(up)
			if zn.length_squared() < 0.0000001:
				zn = Vector3.FORWARD
			else:
				zn = zn.normalized()
			inst.basis = Basis(right, up, zn)
			inst.set_instance_shader_parameter("sprite_axis", right)
		_add_to_bsp_scene(inst, true, parent)


func _texture_needs_own_mesh(texture_id: int) -> bool:
	if texture_id < 0 or texture_id >= _tex_name.size():
		return false
	var cf: int = _tex_contents[texture_id]
	if cf & (_cf_lava() | _cf_slime() | _cf_water() | _cf_translucent()):
		return true
	_ensure_shader_library()
	if !_shader_library:
		return false
	return _shader_library.needs_isolated_draw_mesh(_tex_name[texture_id])


func _generate_surface(s: Dictionary, texture_id: int, lightmap_id: int, transparent := false, use_lm := true) -> Dictionary:
	# One bucket per texture. LIGHTMAP_BY_VERTEX faces write lm_cell.
	# zw=0 and light() already falls back to COLOR (standard_lightmap + converted).
	# Splitting lm|vx duplicated models[0] in JA (same shader, two programs).
	var key := str(texture_id)
	if use_lm and not _external_lightmaps.is_empty() and lightmap_id >= 0:
		key += "|%s" % lightmap_id
	if not s.has(key):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.set_custom_format(0, SurfaceTool.CUSTOM_RGBA_FLOAT)
		st.set_custom_format(1, SurfaceTool.CUSTOM_RGBA_FLOAT)
		st.set_custom_format(2, SurfaceTool.CUSTOM_RGBA_FLOAT)
		st.set_custom_format(3, SurfaceTool.CUSTOM_RGBA_FLOAT)
		var mat := _material_from_path(texture_id, lightmap_id, use_lm)
		if mat and mat.resource_name == "":
			mat.resource_name = _tex_name[texture_id] if _tex_ok(texture_id) else key
		st.set_material(mat)
		s[key] = {
			"st": st,
			"vertex_count": 0,
			"transparent": transparent,
			"material": mat,
		}
	return s[key]


func _bind_committed_material(mesh: ArrayMesh, surface_index: int, mat: Material) -> void:
	if mesh == null or surface_index < 0 or surface_index >= mesh.get_surface_count():
		return
	if mesh.surface_get_material(surface_index) == null and mat:
		mesh.surface_set_material(surface_index, mat)


func _create_bsp_mesh_instance(mesh: ArrayMesh, parent: Node) -> void:
	if !mesh or mesh.get_surface_count() == 0:
		return
	
	if !options.import_lightmaps:
		var texel_size: float = (1.0 / options.unit_scale) * 4.0
		mesh.lightmap_unwrap(_bsp_scene.transform, texel_size)
	
	var mi := MeshInstance3D.new()
	mi.mesh = mesh

	_add_to_bsp_scene(mi, true, parent)


const SS_MAX_INSTANCES := 16384


func _ss_alpha_cut(stage) -> float:
	match int(stage.alpha_func):
		3: # ALPHA_GE128
			return 0.5
		4: # ALPHA_GE192
			return 192.0 / 255.0
		1: # ALPHA_GT0
			return 0.01
		_:
			return 0.5


func _ss_stage_additive(stage) -> bool:
	var b: PackedStringArray = stage.blend
	if b.size() >= 2 and String(b[1]) == "GL_ONE":
		return String(b[0]) != "GL_DST_COLOR"
	if b.size() == 1 and String(b[0]) in ["GL_ONE", "ADD"]:
		return true
	return false


func _ss_sprite_material(stage) -> Material:
	var add := _ss_stage_additive(stage)
	var path := "res://addons/tech3bsp/shaders/surface_sprite_add.gdshader" if add \
		else "res://addons/tech3bsp/shaders/surface_sprite.gdshader"
	var sh := load(path) as Shader
	var mat := ShaderMaterial.new()
	mat.shader = sh
	var tex: Texture2D = null
	if _shader_library and stage.maps.size() > 0:
		tex = _shader_library.resolve_texture(stage.maps[0])
	if tex:
		mat.set_shader_parameter("albedo_tex", tex)
	mat.set_shader_parameter("alpha_test", _ss_alpha_cut(stage))
	var kind := String(stage.ss_type)
	var bb := 0
	match kind:
		"vertical":
			bb = 1
		"oriented", "effect", "weather":
			bb = 0 if bool(stage.ss_faceup) else 2
	mat.set_shader_parameter("billboard_y", bb)
	if kind == "effect" or kind == "weather" or bool(stage.ss_fx_weather):
		var dur_ms: float = maxf(float(stage.ss_fx_duration), 1.0)
		mat.set_shader_parameter("fx_duration", dur_ms / 1000.0)
		mat.set_shader_parameter("fx_grow", Vector2(float(stage.ss_fx_grow_w), float(stage.ss_fx_grow_h)))
		mat.set_shader_parameter("fx_alpha", Vector2(float(stage.ss_fx_alpha_start), float(stage.ss_fx_alpha_end)))
		var fadeinout: bool = float(stage.ss_fx_alpha_end) < 0.05 and stage.ss_width >= 0.1 and stage.ss_height >= 0.1
		mat.set_shader_parameter("fx_fadeinout", 1 if fadeinout else 0)
	var us := maxf(float(options.unit_scale), 0.0001)
	if stage.ss_fade_max > 32.0:
		mat.set_shader_parameter("fade_start", stage.ss_fade_dist / us)
		mat.set_shader_parameter("fade_end", stage.ss_fade_max / us)
	if stage.ss_wind > 0.0:
		mat.set_shader_parameter("ss_wind", float(stage.ss_wind))
	return mat


func _ss_unit_quad(centered: bool = false) -> ArrayMesh:
	# Grounded cards: y 0..1 (grow from the surface). Faceup rings: y -0.5..0.5
	# so ssFXGrow expands around the scatter point (RB_EffectSurfaceSprite).
	var y0 := -0.5 if centered else 0.0
	var y1 := 0.5 if centered else 1.0
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := Vector3(0, 0, 1)
	st.set_normal(n)
	st.set_uv(Vector2(0, 1))
	st.add_vertex(Vector3(-0.5, y0, 0))
	st.set_normal(n)
	st.set_uv(Vector2(1, 1))
	st.add_vertex(Vector3(0.5, y0, 0))
	st.set_normal(n)
	st.set_uv(Vector2(1, 0))
	st.add_vertex(Vector3(0.5, y1, 0))
	st.set_normal(n)
	st.set_uv(Vector2(0, 1))
	st.add_vertex(Vector3(-0.5, y0, 0))
	st.set_normal(n)
	st.set_uv(Vector2(1, 0))
	st.add_vertex(Vector3(0.5, y1, 0))
	st.set_normal(n)
	st.set_uv(Vector2(0, 0))
	st.add_vertex(Vector3(-0.5, y1, 0))
	return st.commit()


func _ss_face_tris(fi: int) -> Array:
	var tris: Array = []
	if _face_type[fi] == FACE_TYPE.PATCH:
		var grid := _subdivide_patch_to_grid(fi, float(options.patch_detail) * 2.0)
		var gw: int = int(grid.get("width", 0))
		var gh: int = int(grid.get("height", 0))
		var ctrl: Array = grid.get("ctrl", [])
		if gw < 2 or gh < 2:
			return tris
		for y in range(gh - 1):
			for x in range(gw - 1):
				var a: Vector3 = ctrl[y][x]["p"]
				var b: Vector3 = ctrl[y][x + 1]["p"]
				var c: Vector3 = ctrl[y + 1][x]["p"]
				var d: Vector3 = ctrl[y + 1][x + 1]["p"]
				var ca: Color = ctrl[y][x]["c"]
				var cb: Color = ctrl[y][x + 1]["c"]
				var cc: Color = ctrl[y + 1][x]["c"]
				var cd: Color = ctrl[y + 1][x + 1]["c"]
				tris.append([a, b, d, ca, cb, cd])
				tris.append([a, d, c, ca, cd, cc])
		return tris
	var fv := _face_first_vert[fi]
	var ni := _face_num_indices[fi]
	if ni >= 3:
		for i in range(_face_first_index[fi], _face_first_index[fi] + ni, 3):
			if i + 2 >= _indices.size():
				break
			var i0 := fv + _indices[i]
			var i1 := fv + _indices[i + 1]
			var i2 := fv + _indices[i + 2]
			if i0 < 0 or i1 < 0 or i2 < 0:
				continue
			if i0 >= _vertex_positions.size() or i1 >= _vertex_positions.size() or i2 >= _vertex_positions.size():
				continue
			tris.append([
				_vertex_positions[i0], _vertex_positions[i1], _vertex_positions[i2],
				_vertex_colors[i0], _vertex_colors[i1], _vertex_colors[i2]
			])
	return tris


func _ss_scatter_flattened(tris: Array, stage, us: float) -> Array:
	var out: Array = []
	var density: float = maxf(stage.ss_density, 1.0)
	var w0: float = stage.ss_width / us
	var h0: float = stage.ss_height / us
	for t in tris:
		var a: Vector3 = t[0]
		var b: Vector3 = t[1]
		var c: Vector3 = t[2]
		var ca: Color = t[3]
		var cb: Color = t[4]
		var cc: Color = t[5]
		var d2 := Vector2(b.x - a.x, b.z - a.z)
		var d3 := Vector2(c.x - a.x, c.z - a.z)
		var area_gd := absf(d3.x * d2.y - d3.y * d2.x)
		var area_q3 := area_gd * us * us
		if area_q3 <= 1.0:
			continue
		var step := density / sqrt(area_q3)
		if step <= 0.0001:
			continue
		var seed := int(absf(a.x + a.z + b.x + c.z) * 1000.0) & 0x7fffffff
		var rng := RandomNumberGenerator.new()
		rng.seed = seed
		var posi := 0.0
		while posi < 1.0:
			var posj := 0.0
			while posj < 1.0 - posi:
				var fa := posi + rng.randf() * step
				var fb := posj + rng.randf() * step
				posj += step
				if fa > 1.0 or fb > 1.0 - fa:
					continue
				var fc := 1.0 - fa - fb
				var p: Vector3 = a * fa + b * fb + c * fc
				var col: Color = ca * fa + cb * fb + cc * fc
				var wv: float = w0 * (1.0 + stage.ss_var_w * rng.randf())
				var hv: float = h0 * (1.0 + stage.ss_var_h * rng.randf())
				if rng.randf() > 0.5:
					wv = -wv

				var q3x := p.x * us
				var yaw := deg_to_rad(q3x)
				out.append({ "p": p, "yaw": yaw, "w": wv, "h": hv, "c": col, "phase": rng.randf() })
				if out.size() >= SS_MAX_INSTANCES:
					return out
			posi += step
	return out


func _add_flattened_surface_sprites(mi: int, parent: Node) -> void:
	if !_shader_library:
		return
	var batches: Dictionary = {}
	for fi in range(_model_face[mi], _model_face[mi] + _model_num_faces[mi]):
		if _face_type[fi] == FACE_TYPE.BILLBOARD or _face_type[fi] == FACE_TYPE.NONE:
			continue
		var tid := _face_tex[fi]
		if tid < 0 or tid >= _tex_name.size():
			continue
		var def = _shader_library.get_shader(_tex_name[tid])
		if def == null:
			continue
		for st in def.stages:
			if st.ss_type != "flattened" and st.ss_type != "vertical" and st.ss_type != "oriented" \
					and st.ss_type != "effect" and st.ss_type != "weather":
				continue
			if st.maps.is_empty():
				continue
			var key := "%s|%s|%s" % [_tex_name[tid], st.maps[0], st.ss_type]
			if not batches.has(key):
				batches[key] = { "stage": st, "tris": [] }
			var packed: Array = batches[key]["tris"]
			packed.append_array(_ss_face_tris(fi))
	if batches.is_empty():
		return
	var us := maxf(float(options.unit_scale), 0.0001)
	var quad_ground := _ss_unit_quad(false)
	var quad_center := _ss_unit_quad(true)
	for key in batches.keys():
		var batch: Dictionary = batches[key]
		var stage = batch["stage"]
		var insts := _ss_scatter_flattened(batch["tris"], stage, us)
		if insts.is_empty():
			continue
		var kind := String(stage.ss_type)
		var faceup := bool(stage.ss_faceup)
		var fx := kind == "effect" or kind == "weather"
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = fx
		mm.mesh = quad_center if faceup and kind != "vertical" else quad_ground
		mm.instance_count = insts.size()
		for i in insts.size():
			var it: Dictionary = insts[i]
			var xf := Transform3D.IDENTITY
			if kind == "flattened" or (faceup and kind != "vertical"):
				xf = xf.rotated_local(Vector3.UP, float(it["yaw"]))
			if faceup and kind != "vertical":
				xf = xf.rotated_local(Vector3.RIGHT, -PI * 0.5)
			var hv: float = maxf(absf(float(it["h"])), 0.001)
			if kind == "vertical" and faceup:
				hv = -hv
			xf = xf.scaled_local(Vector3(absf(float(it["w"])), hv, 1.0))
			xf.origin = it["p"]
			mm.set_instance_transform(i, xf)
			mm.set_instance_color(i, it["c"])
			if fx:
				mm.set_instance_custom_data(i, Color(float(it.get("phase", 0.0)), 0.0, 0.0, 0.0))
		var n := MultiMeshInstance3D.new()
		n.name = "ss_%s_%s" % [stage.ss_type, String(key).get_file()]
		n.multimesh = mm
		n.material_override = _ss_sprite_material(stage)
		n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_add_to_bsp_scene(n, true, parent)


func _add_bsp_model(mi: int, parent: Node) -> void:
	var surfaces := {}
	var patch_jobs: Array = []

	for fi in range(_model_face[mi], _model_face[mi] + _model_num_faces[mi]):
		if _face_type[fi] == FACE_TYPE.BILLBOARD or _face_type[fi] == FACE_TYPE.NONE:
			continue

		var texture_id := _face_tex[fi]
		var lightmap_id := _face_lm[fi]
		var vertex_color := true # some shader blending requires this be true

		if _skip_drawsurf(texture_id):
			continue

		if _texture_billboard_mode(texture_id) != 0 and (_face_type[fi] == FACE_TYPE.POLYGON or _face_type[fi] == FACE_TYPE.MESH or _face_type[fi] == FACE_TYPE.FOLIAGE or _face_type[fi] == FACE_TYPE.PATCH):
			_add_autosprite_face(fi, parent, vertex_color)
			continue
		
		var surface: Dictionary
		# Material wants the atlas whenever this shader isn't nolightmap.
		# Per-face page vs LIGHTMAP_BY_VERTEX is stored on the vertex (CUSTOM0).
		var use_lm: bool = bool(options.import_lightmaps) and not _shader_nolightmap(texture_id)
		var mat_lm_id: int = lightmap_id if lightmap_id >= 0 else 0
		
		var transparent := _texture_needs_own_mesh(texture_id)
		surface = _generate_surface(surfaces, texture_id, mat_lm_id, transparent, use_lm)
		
		var st: SurfaceTool = surface.st
		var offset: int = surface.vertex_count
		
		match _face_type[fi]:
			FACE_TYPE.POLYGON, FACE_TYPE.MESH, FACE_TYPE.FOLIAGE:
				for v in range(_face_first_vert[fi], _face_first_vert[fi] + _face_num_verts[fi]):
					var uv2 := _lm_page_uv(_vertex_uv2s[v], fi, 0)
					var u1 := _lm_atlas_uv(_vertex_lm_uv1[v] if v < _vertex_lm_uv1.size() else Vector2.ZERO, fi, 1)
					var u2 := _lm_atlas_uv(_vertex_lm_uv2[v] if v < _vertex_lm_uv2.size() else Vector2.ZERO, fi, 2)
					var u3 := _lm_atlas_uv(_vertex_lm_uv3[v] if v < _vertex_lm_uv3.size() else Vector2.ZERO, fi, 3)
					_add_vertex_to_surface(st, _vertex_positions[v], _vertex_normals[v], _vertex_uvs[v], uv2, _vertex_colors[v], vertex_color, _face_lm[fi], u1, u2, u3, _face_style_attr(fi))
					surface.vertex_count += 1

				for i in range(_face_first_index[fi], _face_first_index[fi] + _face_num_indices[fi]):
					st.add_index(_indices[i] + offset)

			FACE_TYPE.PATCH:
				patch_jobs.append({
					"fi": fi,
					"surface": surface,
					"vertex_color": vertex_color,
					"grid": _subdivide_patch_to_grid(fi, float(options.patch_detail)),
				})

	_stitch_patch_grids(patch_jobs)
	for job in patch_jobs:
		_emit_patch_grid(int(job["fi"]), job["surface"], bool(job["vertex_color"]), job["grid"])

	var current_mesh := ArrayMesh.new()
	# One mesh per fog number for this model
	for id in surfaces:
		var transparent: bool = surfaces[id].transparent
		var st: SurfaceTool = surfaces[id].st
		st.index()
		st.optimize_indices_for_cache()
		# IBSP stores no tangents. One call covers both commit paths.
		if _deluxe_active or _want_tangents:
			# TODO: sometimes tangent generation is screwy, investigate
			st.generate_tangents()
		if options.split_mesh or surfaces[id].transparent:
			var mesh := st.commit()
			st.clear()
			if mesh and mesh.get_surface_count() > 0:
				_bind_committed_material(mesh, mesh.get_surface_count() - 1, surfaces[id].get("material", null) as Material)
				_create_bsp_mesh_instance(mesh, parent)
			continue
		if current_mesh.get_surface_count() >= RenderingServer.MAX_MESH_SURFACES:
			_create_bsp_mesh_instance(current_mesh, parent)
			current_mesh = ArrayMesh.new()
		var before_sc := current_mesh.get_surface_count()
		st.commit(current_mesh)
		st.clear()
		if current_mesh.get_surface_count() > before_sc:
			_bind_committed_material(current_mesh, current_mesh.get_surface_count() - 1, surfaces[id].get("material", null) as Material)
	_create_bsp_mesh_instance(current_mesh, parent)
	if bool(options.get("import_surface_sprites", true)):
		_add_flattened_surface_sprites(mi, parent)


# Entity lights share BSPScene.style_weight with world materials.
# RBSP faces / lightgrid store style ids in CUSTOM3 and the styles volume.
# IBSP extra q3map2 $lightmap stages sample the same slot N.
# Styled Omni/Spot is the entity adapter (cull mask skips layer 1 when
# lightmaps exist so the bake is not lit twice).
# IBSP world flicker needs those extra style pages, otherwise only
# _entities flicker.
# mapping:
#   intensity "light"/"_light" * "scale" (default 300)
#   energy    = intensity / 300 * brightness_multiplier
#   range     = intensity / unit_scale   (bsp units to Godot)
func _add_lights() -> void:
	var mode := _light_import_mode()
	if mode == LIGHT_IMPORT_NONE:
		return
	var light_targets: Dictionary
	# TODO: make this more efficient than two loops...
	for entity: Dictionary in _entities:
		if String(entity.get("classname", "")) != "light" and entity.has("targetname") and entity.has("origin"):
			light_targets[entity.targetname] = entity.origin
	var inv_scale: float = 1.0 / options.unit_scale
	for entity: Dictionary in _entities:
		if String(entity.get("classname", "")) != "light":
			continue
		var style_id := _entity_light_style(entity)
		if mode == LIGHT_IMPORT_STYLED and style_id <= 0:
			continue
		var light_value := _entity_light_intensity(entity)
		var light_color := _entity_light_color(entity)
		var spawnflags := _entity_int(entity, "spawnflags", 0)
		# spawnflags 1 = LIGHT_ATTEN_LINEAR
		var atten: float = float(options.light_attenuation)
		if spawnflags & 1:
			atten = minf(atten, 1.0)
		var range_gd: float = maxf(light_value * inv_scale, 0.001)
		var energy: float = light_value * (options.light_brightness_multiplier / 300.0)
		var light_node: Light3D
		var is_sun := _entity_float(entity, "_sun", 0.0) != 0.0
		var target_name := str(entity.get("target", ""))
		var has_target := target_name != "" and light_targets.has(target_name)

		# if a spotlight has _sun let's use it to angle the directional light
		# useful if entity shadows are on. Only care about the first one
		# and ignore additional _sun's
		if is_sun:
			if options.import_lightmaps:
				continue
			light_node = DirectionalLight3D.new()
			if has_target:
				light_node.global_transform = look_at_safely(entity.origin, light_targets[target_name])
		elif target_name != "" and not is_sun:
			light_node = SpotLight3D.new()

			var cone_radius_tech3 := _entity_float(entity, "radius", 64.0)
			if cone_radius_tech3 <= 0.0:
				cone_radius_tech3 = 64.0
			
			var dist_tech3 := 64.0
			
			if has_target:
				var dest: Vector3 = light_targets[target_name]
				light_node.global_transform = look_at_safely(entity.origin, dest)
				var dist_gd: float = entity.origin.distance_to(dest)
				dist_tech3 = maxf(dist_gd / inv_scale, 1.0)

			light_node.spot_angle = rad_to_deg(atan((cone_radius_tech3 + 16.0) / dist_tech3))
			light_node.spot_range = range_gd
			light_node.spot_attenuation = atten
		else:
			light_node = OmniLight3D.new()
			light_node.omni_range = range_gd
			light_node.omni_attenuation = atten

		light_node.light_volumetric_fog_energy = _entity_float(entity, "fog_energy", 0.0) # not official but neat
		light_node.position = entity.origin
		light_node.light_energy = energy
		light_node.light_color = light_color
		light_node.shadow_enabled = true # TODO: make some kind of option or ent key read?
		light_node.light_bake_mode = Light3D.BAKE_STATIC # maybe?
		if options.import_lightmaps or (_worldspawn.has("_q3map2_cmdline") and _worldspawn["_q3map2_cmdline"].contains("-bounceonly")):
			# light everything EXCEPT the map on layer 1
			light_node.light_cull_mask = 4294967294

		if style_id >= 1 and style_id < BSPScene.STYLE_COUNT:
			light_node.set_script(_STYLED_LIGHT_SCRIPT)
			light_node.set("style_index", style_id)
			light_node.set("base_energy", energy)
			light_node.set("base_color", light_color)
			# Bake the current style weight (including ls_Nr / ls_Ng / ls_Nb)
			# so the light starts with the right tint before the first tick.
			if _bsp_scene:
				var sw: Color = _bsp_scene.style_weight_rgb(style_id)
				light_node.light_color = Color(
					light_color.r * sw.r,
					light_color.g * sw.g,
					light_color.b * sw.b
				)
		var light_name := str(entity.get("targetname", "")).strip_edges()
		if light_name != "":
			light_node.name = light_name
		# Raven START_OFF is the third spawnflag (4).
		if style_id >= BSPScene.STYLE_SWITCH_MIN and (spawnflags & 4):
			if _bsp_scene:
				_bsp_scene.style_off(style_id)

		_add_to_bsp_scene(light_node, true)


# Black directional so lightmapped world stays on the lightmap path
# (shaders match LIGHT_COLOR == 0) while dynamics on vis 2+ still cast
# onto the BSP. World itself does not cast.
func _add_world_light() -> void:
	var directional_light := DirectionalLight3D.new()
	# Lightmap pass: black, energy 0. Shaders match LIGHT_COLOR == vec3(0).
	# -90 on X is straight down (90 points up). A little off vertical so
	# entity shadows fall beside the feet instead of straight under them.
	directional_light.rotation_degrees = Vector3(-78.0, 24.0, 0.0)
	directional_light.light_color = Color(0.0, 0.0, 0.0)
	directional_light.light_energy = 0.0
	directional_light.light_volumetric_fog_energy = 0.0
	directional_light.light_indirect_energy = 0.0
	if options.import_lightmaps:
		directional_light.directional_shadow_max_distance = 50.0
	# with the current shader, we still need either a directional light
	# or an ambient color, and directional light at least respects
	# culling and visibility layers...
	if options.entity_shadow_light:
		directional_light.shadow_enabled = true
		directional_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
		directional_light.directional_shadow_blend_splits = true
		# vis layer 1 is BSP, receive shadows but don't cast (lightmaps
		# already baked that). Dynamics on 2+ cast onto the world.
		directional_light.shadow_caster_mask = 4294967294
		directional_light.shadow_opacity = clampf(float(options.get("shadow_opacity", 1.0)), 0.0, 1.0)
	else:
		directional_light.shadow_enabled = false
		directional_light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	_add_to_bsp_scene(directional_light, true)


# TODO: This may be slow with lots of flares, should test more
# or find a way to do it with MultiMeshes
# TODO: make a better default flare texture...
func _add_billboards(mi: int, parent: Node) -> void:
	var billboards := {}
	var flare_scene: PackedScene = load("res://addons/tech3bsp/examples/billboard_example.tscn")
	
	var set_billboard := func(texture_id: int) -> Dictionary:
		return {
			"texture_id": texture_id,
			"color": Color.WHITE,
			"positions": PackedVector3Array()
		}

	for fi in range(_model_face[mi], _model_face[mi] + _model_num_faces[mi]):
		if _face_type[fi] != FACE_TYPE.BILLBOARD:
			continue
		
		var texture_id := _face_tex[fi]
		
		# maps compiled with "-skyfix" will create 6 special BILLBOARD
		# type faces to work around an old graphics driver bug. I'm pretty sure
		# we can just ignore them completely...
		var texture_name := _tex_name[texture_id]
		
		if texture_name.begins_with("half_"):
			continue
		
		# the flare color seems to be stored in lm_vecs, so weird
		var flare_color: Vector3 = _face_lm_vec0[fi]

		var color := Color(flare_color.x, flare_color.y, flare_color.z)

		var key := str(texture_id, "|", color)

		if not billboards.has(key):
			billboards[key] = set_billboard.call(texture_id)
		
		billboards[key].color = color
		billboards[key].positions.append(_face_lm_origin[fi])

	for b: Dictionary in billboards.values():
		for p in b.positions:
			var flare: MeshInstance3D = flare_scene.instantiate()
			flare.color = b.color
			_add_to_bsp_scene(flare, true, parent)
			flare.position = p


# FIXME: *some* transparent surfaces still end up with occluders.
# need to locate all instances where alpha is used and skip those.
func _add_occluder() -> void:
	var occluder_vertices := PackedVector3Array()
	var occluder_indices := PackedInt32Array()

	const SUBDIVISIONS = 2 # fixed value for occluders from patches
	var stride := SUBDIVISIONS + 1
	var offset := 0

	for fi in range(_model_face[0], _model_face[0] + _model_num_faces[0]):
		if _face_type[fi] == FACE_TYPE.BILLBOARD or _face_type[fi] == FACE_TYPE.NONE:
			continue

		if _skip_drawsurf(_face_tex[fi]):
			continue

		var occ_cf: int = _tex_contents[_face_tex[fi]] if _tex_ok(_face_tex[fi]) else 0
		if occ_cf & (_cf_translucent() | _cf_water() | _cf_slime() | _cf_lava() | _cf_fog()):
			continue

		if _face_type[fi] == FACE_TYPE.PATCH:
			var previous_size := occluder_vertices.size()

			var width := _face_patch_w[fi]
			var height := _face_patch_h[fi]

			for py in range(0, height - 1, 2):
				for px in range(0, width - 1, 2):
					var ctrl := []
					var grid := []
					
					var base := occluder_vertices.size()

					for j in range(3):
						for i in range(3):
							var idx := _face_first_vert[fi] + (py + j) * width + (px + i)
							ctrl.append(_vertex_positions[idx])

					# Occluder vertices
					for y in range(SUBDIVISIONS + 1):
						var ty := float(y) / SUBDIVISIONS
						for x in range(SUBDIVISIONS + 1):
							var tx := float(x) / SUBDIVISIONS
							
							var r0 = _bezier3(ctrl[0], ctrl[1], ctrl[2], tx)
							var r1 = _bezier3(ctrl[3], ctrl[4], ctrl[5], tx)
							var r2 = _bezier3(ctrl[6], ctrl[7], ctrl[8], tx)
							
							var pos = _bezier3(r0, r1, r2, ty)
							
							occluder_vertices.append(pos)

					# Occluder _indices
					for y in range(SUBDIVISIONS):
						for x in range(SUBDIVISIONS):
							var i0 := base + y * stride + x
							var i1 := i0 + 1
							var i2 := i0 + stride
							var i3 := i2 + 1

							occluder_indices.append_array([
								i0, i3, i1,
								i0, i2, i3
							])

			offset += occluder_vertices.size() - previous_size
		else:
			for v in range(_face_first_vert[fi], _face_first_vert[fi] + _face_num_verts[fi]):
				occluder_vertices.append(_vertex_positions[v])

			for i in range(_face_first_index[fi], _face_first_index[fi] + _face_num_indices[fi]):
				occluder_indices.append(_indices[i] + offset)

			offset += _face_num_verts[fi]

	var occluder := ArrayOccluder3D.new()
	occluder.set_arrays(occluder_vertices, occluder_indices)

	var instance := OccluderInstance3D.new()
	instance.occluder = occluder

	_add_to_bsp_scene(instance, true)


func _map_has_sky_surfaces() -> bool:
	for i in _tex_flags.size():
		if _tex_flags[i] & _sf_sky():
			return true
	return false


func _find_sky_shader_def():
	_ensure_shader_library()
	if !_shader_library:
		return null
	var seen: Dictionary = {}
	for fi in _face_tex.size():
		if _face_tex[fi] < 0 or _face_tex[fi] >= _tex_name.size():
			continue
		var tname: String = _tex_name[_face_tex[fi]]
		if seen.has(tname):
			continue
		seen[tname] = true
		var def = _shader_library.get_shader(tname)
		if def and def.is_sky:
			return def
	for i in _tex_flags.size():
		if _tex_flags[i] & _sf_sky():
			var def = _shader_library.get_shader(_tex_name[i])
			if def:
				return def
	return null


func _worldspawn_flag(key: String) -> bool:
	if not _worldspawn:
		return false
	var raw := ""
	if _worldspawn.has(key):
		raw = str(_worldspawn[key])
	else:
		for k in _worldspawn.keys():
			if str(k).strip_edges().to_lower() == key:
				raw = str(_worldspawn[k])
				break
	var v := raw.strip_edges().to_lower()
	return v in ["1", "true", "yes", "on"]


func _prepare_skybox() -> void:
	# Author choice. has_skybox on worldspawn overrides the import option.
	# True drops SURF_SKY and wraps the map in the sky shader box.
	# False draws the sky faces as ordinary surfaces.
	# TODO: offer the option to apply sky as a Godot sky?
	# requires a WorldEnvironment though.
	var enabled := bool(options.get("import_skybox", false))
	if _worldspawn_flag("has_skybox"):
		enabled = true
	_drop_portal_skies = enabled
	if enabled:
		print("tech3bsp: import skybox, dropping portal SKY faces")
	elif _map_has_sky_surfaces():
		print("tech3bsp: drawing SKY faces")


func _xform_to_scene_root(n: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var cur: Node = n
	while cur and cur != _bsp_scene:
		if cur is Node3D:
			xf = cur.transform * xf
		cur = cur.get_parent()
	if _bsp_scene is Node3D:
		xf = _bsp_scene.transform * xf
	return xf


func _visual_aabb(n: Node, into: Dictionary) -> void:
	if n is VisualInstance3D:
		var local: AABB = n.get_aabb()
		var xf := _xform_to_scene_root(n)
		for i in 8:
			var w: Vector3 = xf * local.get_endpoint(i)
			if into["ok"]:
				into["aabb"] = into["aabb"].expand(w)
			else:
				into["aabb"] = AABB(w, Vector3.ZERO)
				into["ok"] = true
	for c in n.get_children():
		_visual_aabb(c, into)


func _scene_aabb(root: Node) -> AABB:
	var into := { "aabb": AABB(), "ok": false }
	_visual_aabb(root, into)
	if into["ok"]:
		return into["aabb"]
	if _model_mins.is_empty():
		return AABB(Vector3(-16, -16, -16), Vector3(32, 32, 32))
	var a: Vector3 = tech3_to_gd(_model_mins[0])
	var b: Vector3 = tech3_to_gd(_model_maxs[0])
	return AABB(a, Vector3.ZERO).expand(b)


func _add_sky_box() -> void:
	if not _drop_portal_skies:
		return
	_ensure_shader_library()
	var def = _find_sky_shader_def()
	if !def or !_shader_library:
		return
	var mat := _shader_library.build_material(def.name, -1, null)
	if not mat is ShaderMaterial:
		return
	var aabb := _scene_aabb(_bsp_scene).grow(1.0)
	var box := BoxMesh.new()
	box.size = aabb.size
	box.flip_faces = true
	var mi := MeshInstance3D.new()
	mi.name = "SkyBox"
	mi.mesh = box
	mi.position = aabb.get_center()
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = aabb.size.length()
	_add_to_bsp_scene(mi)
	print("tech3bsp: sky box from '%s'" % def.name)


func _add_to_bsp_scene(child: Node, force_readable_name := true, parent: Node = _bsp_scene) -> void:
	parent.add_child(child, force_readable_name)
	child.owner = _bsp_scene


## Load an IBSP/RBSP file from disk and return a BSPScene (or null on failure).
## Usage: var scene := Tech3BSPReader.new(); Tech3BSPReader.options = opts; scene = reader.read_bsp(path)
func read_bsp(source_file: String) -> Node3D:
	var fa := FileAccess.open(source_file, FileAccess.READ)
	if !fa:
		push_error("tech3bsp: cannot open %s" % source_file)
		return null
	var data := fa.get_buffer(fa.get_length())
	fa.close()
	return read_bsp_bytes(data, source_file)


## Same as read_bsp() but from an in-memory buffer (PK3 maps).
## Usage: reader.read_bsp_bytes(bytes, "pk3://maps/q3dm1.bsp")
func read_bsp_bytes(data: PackedByteArray, source_name: String = "memory.bsp") -> Node3D:
	clear_data()
	_apply_default_options()
	_bsp_file = Tech3DataStream.new()
	_bsp_file.open_bytes(data, source_name)
	_build_directory_map()
	if bool(options.get("use_tech3_shaders", true)):
		_ensure_shader_library()

	var magic := _bsp_file.get_buffer(4).get_string_from_ascii()
	var version := _bsp_file.get_32()
	_is_rbsp = magic == "RBSP"
	if magic != "IBSP" and magic != "RBSP":
		push_error("tech3bsp: %s is not a supported BSP file!" % magic)
		_bsp_file.close()
		return null
	if _is_rbsp and version != 1:
		push_warning("tech3bsp: RBSP version %d (expected 1), reading anyway" % version)
	var header := {
		magic = magic,
		version = version,
		directory = _parse_lumps(RBSP_LUMP_COUNT if _is_rbsp else IBSP_LUMP_COUNT)
	}
	var version_string: String
	if _is_rbsp:
		version_string = "SoF2/JK2/JA"
	else:
		match header.version:
			46: version_string = "Q3A/TA/STVEF"
			47: version_string = "RtCW"
			_: version_string = "Unknown BSP version!"
	print("tech3bsp: %s, version: %d - %s" % [header.magic, header.version, version_string])
	
	_bsp_scene = BSPScene.new()
	
	_parse_entities(header.directory[LUMP_TYPE.ENTITIES])
	_parse_textures(header.directory[LUMP_TYPE.TEXTURES])
	_parse_planes(header.directory[LUMP_TYPE.PLANES])
	_parse_models(header.directory[LUMP_TYPE.MODELS])
	_parse_brushes(header.directory[LUMP_TYPE.BRUSHES])
	_parse_brush_sides(header.directory[LUMP_TYPE.BRUSHSIDES])
	_parse_vertices(header.directory[LUMP_TYPE.VERTEXES])
	_parse_indices(header.directory[LUMP_TYPE.MESHVERTS])
	_parse_effects(header.directory[LUMP_TYPE.EFFECTS])
	_parse_faces(header.directory[LUMP_TYPE.FACES])
	if options.import_lightmaps:
		_parse_lightmaps(header.directory[LUMP_TYPE.LIGHTMAPS])
	var lg_mode := _lightgrid_mode()
	if lg_mode != LIGHTGRID_NONE:
		var array_lump := {}
		if _is_rbsp and header.directory.size() > LUMP_TYPE.LIGHTARRAY:
			array_lump = header.directory[LUMP_TYPE.LIGHTARRAY]
		_parse_light_grid(header.directory[LUMP_TYPE.LIGHTVOLS], array_lump)

	# Lumps are in packed arrays now; drop the raw IBSP bytes before meshing.
	_bsp_file.close()
	data = PackedByteArray()

	_bsp_scene.worldspawn = _worldspawn
	_apply_worldspawn_style_waves()
	_bind_ibsp_style_stages()

	if lg_mode != LIGHTGRID_NONE:
		_bsp_scene.light_grid_ambient = _light_grid_ambient
		_bsp_scene.light_grid_ambient_1 = _light_grid_ambient_1
		_bsp_scene.light_grid_ambient_2 = _light_grid_ambient_2
		_bsp_scene.light_grid_ambient_3 = _light_grid_ambient_3
		_bsp_scene.light_grid_styles = _light_grid_styles
		_bsp_scene.light_grid_normalize = _light_grid_normalize
		_bsp_scene.light_grid_offset = _light_grid_offset
		if lg_mode == LIGHTGRID_FULL:
			_bsp_scene.light_grid_direct = _light_grid_direct
			_bsp_scene.light_grid_cartesian = _light_grid_cartesian
			_bsp_scene.light_grid_direct_1 = _light_grid_direct_1
			_bsp_scene.light_grid_direct_2 = _light_grid_direct_2
			_bsp_scene.light_grid_direct_3 = _light_grid_direct_3
		else:
			# Ambient only. Black dummies keep the entity shaders compiling
			# and produce zero directional contribution.
			var black := _black_grid_tex()
			_bsp_scene.light_grid_direct = black
			_bsp_scene.light_grid_cartesian = black
			_bsp_scene.light_grid_direct_1 = black
			_bsp_scene.light_grid_direct_2 = black
			_bsp_scene.light_grid_direct_3 = black

	if options.occlusion_culling:
		_add_occluder()

	_prepare_skybox()

	_prepare_fog_volumes()
	_add_bsp_model(0, _bsp_scene)
	_apply_shader_remaps()
	_add_fog_volumes(_bsp_scene)
	_add_collisions(0, _bsp_scene)
	if bool(options.get("import_entities", true)):
		_add_entities()
	_merge_harvested_style_waves()
	if _light_import_mode() != LIGHT_IMPORT_NONE:
		_add_lights()
	if options.import_billboards:
		_add_billboards(0, _bsp_scene)
	if options.import_lightmaps:
		_add_world_light()
	_add_sky_box()
	
	_bsp_scene.name = source_name.get_file().get_basename()

	if _shader_library:
		print(_shader_library.shader_reuse_summary())

	_release_parse_arrays()
	if _deluxe_active:
		print("tech3bsp: normal maps ", _norm_binds, ", gloss maps ", _gloss_binds)
	return _bsp_scene
