@tool
class_name Tech3ShaderLibrary
extends RefCounted
# idTech 3 shader to Godot ShaderMaterial.

# Pipeline, in order:
#   1. Parse a q3/rbsp script into ShaderDef stages. Keywords are format-agnostic.
#   2. _stage_opcode turns each stage into one opcode.
#   3. _plan_passes folds stages that share dest=accum and splits when dest
#      is the framebuffer. depthFunc equal stays in the pass that wrote depth.
#   4. _analyze_pass decides blend, cutout, and whether light() runs.
#   5. _emit_pass writes one Godot shader. Extra passes are next_pass.
# A $lightmap stage with no atlas is whiteimage. The pass still compiles;
# the importer prints a warning instead of emitting an undeclared sampler.
# map $lightmap with no blendFunc is Q3/JK2/JA replace (white, atlas in
# light()). blend_mul is only an explicit filter $lightmap (dest * lm).
# Resolve: res:// material, converted script, then standard_lightmap/vertex.

const IMAGE_EXTENSIONS: PackedStringArray = [
	"tga", "png", "webp", "bmp", "jpg", "jpeg", "dds", "ktx", "exr", "hdr"
]
const SHADER_EXTENSIONS: PackedStringArray = ["shader", "shader.txt"]
# Q3: scripts/. Raven: shaders/. Scan both in res:// and PK3.
const SHADER_DIR_NAMES: PackedStringArray = ["scripts", "shaders"]

const WAVE_SIN := 0
const WAVE_SQUARE := 1
const WAVE_TRIANGLE := 2
const WAVE_SAWTOOTH := 3
const WAVE_INVERSESAWTOOTH := 4
const WAVE_NOISE := 5

const CULL_BACK := 0
const CULL_FRONT := 1
const CULL_DISABLED := 2

const SORT_OPAQUE := 0
const SORT_ADDITIVE := 1
const SORT_MULTIPLICATIVE := 2
const SORT_BANNER := 3
const SORT_UNDERWATER := 4
const SORT_NEAREST := 5
const SORT_PORTAL := 6

const TCMOD_ROTATE := 0
const TCMOD_SCALE := 1
const TCMOD_SCROLL := 2
const TCMOD_STRETCH := 3
const TCMOD_TRANSFORM := 4
const TCMOD_TURB := 5
const TCMOD_ENTITYTRANSLATE := 6

const ALPHA_NONE := 0
const ALPHA_GT0 := 1
const ALPHA_LT128 := 2
const ALPHA_GE128 := 3
const ALPHA_GE192 := 4 # Raven

const DEPTH_LEQUAL := 0
const DEPTH_EQUAL := 1
const DEPTH_DISABLE := 2 # Raven depthfunc disable

# polygonOffset decals: lift along the face normal, in Quake units.
# Magnitude lerps with camera distance (view-space length)
const POLYGON_OFFSET_NEAR := 0.01
const POLYGON_OFFSET_FAR := 0.5
const POLYGON_OFFSET_NEAR_DIST := 64.0
const POLYGON_OFFSET_FAR_DIST := 1024.0
const SRC_MAP := 0
const SRC_CLAMPMAP := 1
const SRC_ANIMMAP := 2
const SRC_LIGHTMAP := 3
const SRC_WHITEIMAGE := 4

# Resource paths written this import (so EditorImportPlugin can register them)
static var generated_resource_paths: PackedStringArray = []

var shaders: Dictionary = {} # lowercase name -> ShaderDef
var fog_shaders: Dictionary = {}
var _loaded_files: PackedStringArray = []

var _bsp_directory: String = ""
var _assets_path: String = ""
var _shaders_path: String = "scripts/"
var _shaderlist_path: String = ""
var save_converted: bool = false
var _converted_shader_path: String = "res://shaders/tech3/{shader_name}.gdshader"
var _converted_material_path: String = "res://materials/{texture_name}.material"
var _overwrite_converted: bool = false
var _unit_scale: float = 32.0
var _import_lightmaps: bool = true
var _emit_deluxe: bool = false
var deluxe_modelspace: bool = true
var deluxe_active: bool = false
# For DP materials:
# Set by the importer before build_material. Bit 1 norm/bump, 2 gloss, 4 glow.
var companion_flags: int = 0

var _material_cache: Dictionary = {} # cache_key -> ShaderMaterial
var _shader_warnings: Dictionary = {}
var _lm_atlas_ready := false
var _shader_cache: Dictionary = {} # "hash:len" -> Shader
var _shader_cache_hits: int = 0
var _shader_cache_misses: int = 0
var _shader_disk_hits: int = 0
var _sky_cubes: Dictionary = {} # farbox prefix -> Cubemap
var directory_map: Dictionary = {} # lowercase stem -> res:// path
var _tex_cache: Dictionary = {} # cleaned path -> Texture2D
var _has_cache: Dictionary = {} # cleaned path -> bool, no decode
# Entity / worldspawn style numbers for IBSP extra $lightmap stages
# (not 1,2,3 channel order). Harvested waves fill table slots that
# worldspawn did not already define.
var style_stage_ids: PackedInt32Array = PackedInt32Array()
var harvested_style_waves: Dictionary = {} # int -> wave dict


class ShaderDef:
	var name: String = ""
	var surfaceparms: PackedStringArray = []
	var skyparms: PackedStringArray = [] # farbox, cloudheight, nearbox
	var fogparms: PackedFloat32Array = PackedFloat32Array() # r g b distance
	var sun_params: PackedFloat32Array = PackedFloat32Array()
	var deform_vertexes: Array[Dictionary] = []
	var editor_image: String = ""
	var cull: int = CULL_BACK
	var sort: int = SORT_OPAQUE
	var sort_order: float = 3.0
	var billboard: int = 0 # 0 off, 1 autosprite, 2 autosprite2
	var is_sky: bool = false
	var is_fog: bool = false
	var is_trans: bool = false
	var is_lava: bool = false
	var is_water: bool = false
	var is_slime: bool = false
	var nodlight: bool = false
	var nolightmap: bool = false
	var only_vertex_light: bool = false
	var nomipmaps: bool = false
	var polygon_offset: bool = false
	var offset_mode: int = 0 # 0 off, 1 offset, 2 relief
	var offset_scale: float = 1.0 # material multiplier on the 0.02 depth
	var offset_bias: float = 0.0
	var gloss_intensity: float = 1.0
	var gloss_exponent: float = 1.0
	var reflect_distort: float = 0.0
	var reflect_rgba: Vector4 = Vector4.ZERO
	var reflect_cube: String = ""
	var water_on: bool = false
	var water_refract_distort: float = 0.0
	var water_reflect_distort: float = 0.0
	var water_refract_rgb: Vector3 = Vector3.ONE
	var water_reflect_rgb: Vector3 = Vector3.ONE
	var refract_on: bool = false
	var refract_rgb: Vector3 = Vector3.ONE
	var refract_alpha: float = 0.0
	var entity_mergable: bool = false
	var portal: bool = false
	var tech3_surfacelight: float = 0.0
	var tech3_lightimage: String = ""
	var no_tc: bool = false
	var clamp_time: float = 0.0 # Raven: wrap shader clock, 0 = free run
	var q3map_material: String = ""
	var q3map_lightstyle: int = 0
	var light_color: PackedFloat32Array = PackedFloat32Array()
	var stages: Array[StageDef] = []
	# RtCW / ydnar implicit* - used only when no explicit stages exist.
	var rtcw_implicit: String = "" # "" | "map" | "blend" | "mask"
	var rtcw_implicit_image: String = ""


class StageDef:
	var source: int = SRC_MAP
	var maps: PackedStringArray = []
	var anim_fps: float = 0.0
	var clamp_uv: bool = false
	var is_lightmap: bool = false
	# 0 = no table slot (keep rgbGen wave). 1-63 = tech3_style_rgb(N).
	var style_index: int = 0
	var is_whiteimage: bool = false
	var is_blackimage: bool = false
	var is_farbox: bool = false
	var blend: PackedStringArray = [] # empty = replace / opaque
	var rgb_gen: PackedStringArray = []
	var alpha_gen: PackedStringArray = []
	var tc_gen: String = "base" # base | lightmap | environment | vector
	var tc_gen_s: Vector3 = Vector3.ZERO
	var tc_gen_t: Vector3 = Vector3.ZERO
	var tc_mods: Array[Dictionary] = [] # {type:int, values:PackedFloat32Array, wave:int}
	var depth_func: int = DEPTH_LEQUAL
	var depth_write: bool = false
	var alpha_func: int = ALPHA_NONE
	var detail: bool = false
	var glow: bool = false # Raven dynamic-glow / bloom channel
	var anim_oneshot: bool = false # Raven oneshotAnimMap: play once, hold last
	# Extra map/clampmap paths from the same { } block
	# (DP multitexture). Stock Q3 overwrites, expand these into implicit
	# modulate stages after the block closes.
	var extra_maps: PackedStringArray = []
	var extra_clamp: PackedInt32Array = PackedInt32Array()
	# Raven surfaceSprites. Empty type = normal stage.
	var ss_type: String = ""
	var ss_width: float = 0.0
	var ss_height: float = 0.0
	var ss_density: float = 0.0
	var ss_fade_dist: float = 0.0
	var ss_fade_max: float = 0.0
	var ss_var_w: float = 0.0
	var ss_var_h: float = 0.0
	var ss_wind: float = 0.0
	var ss_faceup: bool = false
	var ss_fx_duration: float = 1000.0 # msec, Raven default
	var ss_fx_grow_w: float = 0.0
	var ss_fx_grow_h: float = 0.0
	var ss_fx_alpha_start: float = 1.0
	var ss_fx_alpha_end: float = 0.0
	var ss_fx_weather: bool = false


## Copy importer options onto this library and reset material / shader caches.
## Usage: lib.configure_from_options(Tech3BSPReader.options, bsp_path)
func configure_from_options(options: Dictionary, bsp_file_path: String) -> void:
	Tech3Noise.ensure_shader_global()
	_bsp_directory = bsp_file_path.get_base_dir()
	
	_assets_path = String(options.get("assets_path_override", ""))
	if _assets_path.is_empty():
		_assets_path = _bsp_directory.get_base_dir()

	_shaders_path = String(options.get("tech3_shaders_override", ""))
	if _shaders_path.is_empty():
		_shaders_path = _assets_path.path_join(SHADER_DIR_NAMES[0])
	
	_shaderlist_path = String(options.get("shaderlist_path", ""))
	save_converted = bool(options.get("save_converted_shaders", false))
	_converted_shader_path = String(options.get(
		"converted_shaders_path",
		"res://shaders/tech3/{shader_name}.gdshader"
	))
	_converted_material_path = String(options.get(
		"materials_path",
		"res://materials/{texture_name}.material"
	))
	_overwrite_converted = bool(options.get("overwrite_converted_shaders", false))
	_unit_scale = float(options.get("unit_scale", 32.0))
	_import_lightmaps = bool(options.get("import_lightmaps", true))
	generated_resource_paths = PackedStringArray()
	_material_cache.clear()
	_shader_cache.clear()
	_shader_cache_hits = 0
	_shader_cache_misses = 0
	_shader_disk_hits = 0
	_sky_cubes.clear()
	_tex_cache.clear()
	_has_cache.clear()


## Drop parsed shaders, textures, and generated Shader cache after the scene is built.
## Usage: shader_library.release_caches()
func release_caches() -> void:
	_shader_warnings.clear()
	_material_cache.clear()
	_shader_cache.clear()
	_sky_cubes.clear()
	_tex_cache.clear()
	_has_cache.clear()
	shaders.clear()
	fog_shaders.clear()
	_loaded_files.clear()
	directory_map.clear()


## Parse scripts/*.shader and shaders/*.shader from res:// plus mounted PK3 packs.
## Usage: lib.load_scripts() - call after configure_from_options().
func load_scripts() -> void:
	shaders.clear()
	fog_shaders.clear()
	_loaded_files.clear()
	var files := _discover_shader_files()
	for path in files:
		_parse_file(path)
	_load_pk3_scripts()
	print("tech3bsp_shaders: parsed %d shaders from %d files" % [shaders.size(), _loaded_files.size()])


func _load_pk3_scripts() -> void:
	for prefix in ["scripts/", "shaders/", "maps/"]:
		for inner in Tech3Pk3.list_mounted(prefix):
			var lower := String(inner).to_lower()
			if not (lower.ends_with(".shader") or lower.ends_with(".shader.txt")):
				continue
			var raw := Tech3Pk3.resolve_bytes(inner)
			var text := _text_from_bytes(raw)
			if text == "":
				continue
			_parse_text(text, "pk3://" + inner)
			if not _loaded_files.has("pk3://" + inner):
				_loaded_files.append("pk3://" + inner)


## True if a Q3/Raven shader script was parsed under this name (case-insensitive).
## Usage: if lib.has_shader("textures/base_wall/concrete")
func has_shader(shader_name: String) -> bool:
	return _lookup(shader_name) != null


## Parsed ShaderDef for a texture name, or null if the script has no such shader.
## Usage: var def := lib.get_shader("textures/sfx/jumppad")
func get_shader(shader_name: String) -> ShaderDef:
	return _lookup(shader_name)


## True when this shader must be its own MeshInstance (Godot blend_mix /
## blend_add / no depth write). Opaque chrome/inverse-alpha/filter stages
## stay on a shared ArrayMesh.
## Usage: if lib.needs_isolated_draw_mesh(tex_name)
func needs_isolated_draw_mesh(shader_name: String) -> bool:
	var def := _lookup(shader_name)
	if def == null:
		return false
	if def.portal or def.is_water or def.is_slime:
		return true
	if def.sort == SORT_ADDITIVE or def.sort_order >= 9.0:
		return true
	if def.billboard != 0:
		return true
	if _def_polygon_offset_decal(def):
		return true
	var first: StageDef = null
	for st in def.stages:
		if _stage_is_lighting_lightmap(st) or _stage_is_style_lightmap(st):
			continue
		first = st
		break
	if first == null:
		return def.is_trans
	if _stage_is_alpha_blend(first):
		return true
	if _stage_is_add_blend(first):
		return true
	# surfaceparm trans + coverage blend on the *first* color stage.
	# Later GL_SRC_ALPHA dest/add (shiny door, env sheen) stays opaque.
	if def.is_trans and first.alpha_func == ALPHA_NONE and _stage_uses_src_alpha(first) \
			and not _stage_is_add_blend(first):
		return true
	# FinishShader: first stage not ONE/ZERO is a framebuffer blend even
	# without surfaceparm trans (e.g. JA holograms). $lightmap + FILTER
	# is the opaque world stack - do not isolate.
	if _lighting_lightmap_index(def) < 0:
		if _stage_is_modulate(first) or _stage_is_dstcolor_one(first) \
				or _stage_is_detail(first) or _stage_is_inv_modulate(first):
			return true
	return false


func _def_render_priority(def: ShaderDef) -> int:
	if def.sort == SORT_ADDITIVE or def.sort_order >= 9.0:
		return 9
	if _def_polygon_offset_decal(def):
		return maxi(int(def.sort_order), 4)
	if def.sort_order >= 6.0:
		return int(def.sort_order)
	var first: StageDef = null
	for st in def.stages:
		if _stage_is_lighting_lightmap(st) or _stage_is_style_lightmap(st):
			continue
		first = st
		break
	if first == null:
		return 0
	# FinishShader: first stage blend other than ONE/ZERO -> SS_BLEND.
	if _stage_is_add_blend(first):
		return 9
	if _stage_is_alpha_blend(first):
		return 5
	if first.alpha_func != ALPHA_NONE:
		return 5
	return 0


## ShaderMaterial for a Q3/Raven shader. Splits additive passes onto next_pass.
## Usage: mesh.material_override = lib.build_material(name, lm_id, lm_tex)
func build_material(shader_name: String, lightmap_id: int, lightmap_texture: Texture, deluxe_texture: Texture = null) -> Material:
	var def := _lookup(shader_name)
	if !def:
		return null
	if def.is_fog and def.stages.is_empty():
		return null

	# dp_water is a dedicated on-disk shader.
	if def.water_on:
		var sh: Shader = load("res://addons/tech3bsp/shaders/dp_water.gdshader")
		if sh:
			var wmat := ShaderMaterial.new()
			wmat.shader = sh
			wmat.resource_name = def.name
			wmat.set_meta("tech3_shader", def.name)
			wmat.set_shader_parameter("water_refract_distort", def.water_refract_distort)
			wmat.set_shader_parameter("water_refract_rgb", def.water_refract_rgb)
			if lightmap_texture:
				wmat.set_shader_parameter("lightmap_texture", lightmap_texture)
			# First non-lightmap stage supplies the base map and its scale/scroll.
			for st in def.stages:
				if st.is_lightmap or st.maps.is_empty():
					continue
				var tex := resolve_texture(st.maps[0])
				if tex:
					wmat.set_shader_parameter("albedo_texture", tex)
				var sc := Vector2.ONE
				var scr := Vector2.ZERO
				for m in st.tc_mods:
					var mt: int = int(m.get("type", 0))
					var vals: PackedFloat32Array = m.get("values", PackedFloat32Array())
					if mt == TCMOD_SCALE and vals.size() >= 2:
						sc = Vector2(vals[0], vals[1])
					elif mt == TCMOD_SCROLL and vals.size() >= 2:
						scr = Vector2(vals[0], vals[1])
				wmat.set_shader_parameter("uv_scale", sc)
				wmat.set_shader_parameter("uv_scroll", scr)
				break
			if def.reflect_cube != "":
				var cube := _sky_cubemap_from_prefix(def.reflect_cube)
				if cube:
					wmat.set_shader_parameter("reflect_cube", cube)
					wmat.set_shader_parameter("tech3_has_cube", 1.0)
			return wmat

	# Atlas + $lightmap is one program for paged faces and LIGHTMAP_BY_VERTEX.
	# A face lightmap index without a $lightmap stage is not a lightmap
	# shader (e.g. models/mapobjects/horned: rgbGen vertex, no $lightmap).
	var wants_lm := _lighting_lightmap_index(def) >= 0
	var use_lm := _import_lightmaps and lightmap_texture != null and wants_lm
	if def.nolightmap:
		use_lm = false
	var use_dx := use_lm and (deluxe_texture != null or deluxe_active)
	_emit_deluxe = use_dx
	var cache_key := "%s|lm:%s|dx:%s|c:%s|save:%s" % [def.name.to_lower(), str(use_lm), str(use_dx), str(companion_flags), str(save_converted)]
	if _material_cache.has(cache_key):
		var cached: ShaderMaterial = _material_cache[cache_key]
		# Lightmap atlas is shared; external lightmaps are per-id so duplicate
		if use_lm and lightmap_id >= 0:
			var dup := cached.duplicate() as ShaderMaterial
			_apply_textures(dup, def, lightmap_texture, [], true)
			_bind_pass_deluxe(dup, deluxe_texture)
			return dup
		return cached

	var passes := _order_passes_for_godot(def, _plan_passes(def))
	var mat := _material_from_pass(def, passes[0], use_lm, lightmap_texture, true)
	mat.render_priority = _def_render_priority(def)
	var cursor := mat
	for p in range(1, passes.size()):
		var nxt := _material_from_pass(def, passes[p], use_lm, lightmap_texture, false)
		nxt.render_priority = mat.render_priority + p
		cursor.next_pass = nxt
		cursor = nxt

	if def.billboard != 0:
		# draw flares after world transparents (most of the time)
		mat.render_priority = maxi(mat.render_priority, 12)
	mat.set_meta("tech3_shader", def.name)

	if save_converted:
		_save_converted(def, mat.shader, mat)
	_bind_pass_deluxe(mat, deluxe_texture)

	_material_cache[cache_key] = mat
	return mat


func _pass_has_uniform(mat: ShaderMaterial, name: String) -> bool:
	var sh: Shader = mat.shader
	if sh == null:
		return false
	for u in sh.get_shader_uniform_list():
		if str(u.get("name", "")) == name:
			return true
	return false


func _bind_pass_deluxe(mat: ShaderMaterial, deluxe_texture: Texture) -> void:
	if !mat or deluxe_texture == null:
		return
	var cursor: Material = mat
	while cursor is ShaderMaterial:
		var sm := cursor as ShaderMaterial
		if _pass_has_uniform(sm, "deluxemap_texture"):
			sm.set_shader_parameter("deluxemap_texture", deluxe_texture)
			sm.set_shader_parameter("tech3_deluxe", 1.0)
		if sm.next_pass == null:
			break
		cursor = sm.next_pass


func _material_from_pass(def: ShaderDef, stage_indices: Array, use_lm: bool, lightmap_texture: Texture, first_pass: bool) -> ShaderMaterial:
	var code := _emit_pass(def, stage_indices, use_lm, first_pass)
	var sh := _shared_shader(code)
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.resource_name = def.name if first_pass else "%s_pass" % def.name
	_apply_textures(mat, def, lightmap_texture if use_lm else null, stage_indices, use_lm)
	return mat


func _converted_shader_root() -> String:
	var tmpl := _converted_shader_path.replace("\\", "/")
	var dir := tmpl.get_base_dir()
	if dir == "" or "{shader_name}" in dir:
		dir = "res://shaders/tech3"
	return dir


func _shared_shader(code: String) -> Shader:
	var key := "%s_%d" % [str(code.hash()), code.length()]
	if _shader_cache.has(key):
		_shader_cache_hits += 1
		return _shader_cache[key]
	var path := "%s/_shared/%s.gdshader" % [_converted_shader_root(), key]
	if ResourceLoader.exists(path):
		var loaded = load(path)
		if loaded is Shader and String(loaded.code) == code:
			_shader_disk_hits += 1
			_shader_cache[key] = loaded
			return loaded
	var sh := Shader.new()
	sh.code = code
	sh.resource_name = key
	_shader_cache[key] = sh
	_shader_cache_misses += 1
	if save_converted:
		_save_resource_if_allowed(sh, path)
	return sh


## One-line cache stats printed after import.
## Usage: print(lib.shader_reuse_summary())
func shader_reuse_summary() -> String:
	var total := _shader_cache_hits + _shader_cache_misses
	var unique := _shader_cache.size()
	return "tech3bsp_shaders: %d unique Shader(s) from %d pass(es) (%d reused, %d from disk)" % [
		unique, total, _shader_cache_hits, _shader_disk_hits
	]


func _read_text_file(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var fa := FileAccess.open(path, FileAccess.READ)
	if !fa:
		push_warning("tech3bsp_shaders: cannot open %s" % path)
		return ""
	var raw: PackedByteArray = fa.get_buffer(fa.get_length())
	fa.close()
	return _text_from_bytes(raw)


func _text_from_bytes(raw: PackedByteArray) -> String:
	if raw.is_empty():
		return ""
	if _bytes_are_utf8(raw):
		return raw.get_string_from_utf8()

	# thanks for having comments in Swedish, rustgrad...
	var out := ""
	for b in raw:
		out += char(int(b) & 0xFF)
	return out


func _bytes_are_utf8(raw: PackedByteArray) -> bool:
	var i := 0
	var n := raw.size()
	while i < n:
		var c := int(raw[i])
		if c < 0x80:
			i += 1
			continue
		var extra := 0
		if c >= 0xC2 and c <= 0xDF:
			extra = 1
		elif c >= 0xE0 and c <= 0xEF:
			extra = 2
		elif c >= 0xF0 and c <= 0xF4:
			extra = 3
		else:
			return false
		if i + extra >= n:
			return false
		for k in range(1, extra + 1):
			if (int(raw[i + k]) & 0xC0) != 0x80:
				return false
		i += extra + 1
	return true


func _parse_file(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	var text := _read_text_file(path)
	if text == "":
		return
	_parse_text(text, path)
	if not _loaded_files.has(path):
		_loaded_files.append(path)


func _parse_text(text: String, source_name: String = "") -> void:
	var tokens := _tokenize(text)
	var i := 0
	var n := tokens.size()
	while i < n:
		var tok: String = tokens[i]
		if tok == "{" or tok == "}":
			i += 1
			continue
		var shader_name := tok
		i += 1
		if i >= n or tokens[i] != "{":
			# stray token
			continue
		i += 1
		var def := ShaderDef.new()
		def.name = shader_name
		i = _parse_block(tokens, i, def)
		_register(def)

# ---
# Discovery
# ---

func _discover_shader_files() -> PackedStringArray:
	var found: PackedStringArray = []
	var roots: PackedStringArray = []

	for raw in [
		_shaders_path,
		_assets_path.path_join("scripts"),
		_assets_path.path_join("shaders"),
		_assets_path.path_join("maps"),
		"res://addons/tech3bsp/scripts",
		"res://addons/tech3bsp/shaders",
	]:
		var r := _normalize_dir(String(raw))
		if r != "" and not roots.has(r):
			roots.append(r)

	var list_file := _shaderlist_path
	if list_file == "":
		for root in roots:
			var candidate := root.path_join("shaderlist.txt")
			if FileAccess.file_exists(candidate):
				list_file = candidate
				break

	if list_file != "" and FileAccess.file_exists(list_file):
		var listed := _read_shaderlist(list_file)
		var list_dir := list_file.get_base_dir()
		for base in listed:
			var resolved := _resolve_listed_shader(base, list_dir, roots)
			if resolved != "":
				found.append(resolved)
			else:
				push_warning("tech3bsp_shaders: shaderlist entry not found: %s" % base)

	for root in roots:
		_collect_shader_files(root, found)
	return found


func _read_shaderlist(path: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var text := _read_text_file(path)
	if text == "":
		return out
	for raw_line in text.split("\n"):
		var line := raw_line.strip_edges()
		if line == "" or line.begins_with("//") or line.begins_with("#"):
			continue
		out.append(line.get_file().get_basename())
	return out


func _resolve_listed_shader(base: String, list_dir: String, roots: PackedStringArray) -> String:
	var names: PackedStringArray = [base]
	if not base.ends_with(".shader"):
		names.append(base + ".shader")
	for root in [list_dir] + Array(roots):
		for name in names:
			var p := String(root).path_join(name)
			if FileAccess.file_exists(p):
				return p
	return ""


func _collect_shader_files(dir_path: String, into: PackedStringArray) -> void:
	var da := DirAccess.open(dir_path)
	if !da:
		return
	da.list_dir_begin()
	var fname := da.get_next()
	while fname != "":
		if fname.begins_with("."):
			fname = da.get_next()
			continue
		var full := dir_path.path_join(fname)
		if da.current_is_dir():
			_collect_shader_files(full, into)
		else:
			var ext := fname.get_extension().to_lower()
			if ext == "shader" or fname.to_lower().ends_with(".shader.txt"):
				if not into.has(full):
					into.append(full)
		fname = da.get_next()
	da.list_dir_end()


func _normalize_dir(path: String) -> String:
	var p := path.strip_edges()
	if p == "":
		return ""
	if p.ends_with("/"):
		p = p.left(p.length() - 1)
	return p


# ---
# Tokenizer / parser
# ---

func _tokenize(text: String) -> PackedStringArray:
	var tokens: PackedStringArray = []
	var i := 0
	var n := text.length()
	while i < n:
		var ch := text.unicode_at(i)
		# whitespace
		if ch == 32 or ch == 9 or ch == 10 or ch == 13:
			i += 1
			continue
		# // comment
		if ch == 47 and i + 1 < n and text.unicode_at(i + 1) == 47:
			while i < n and text.unicode_at(i) != 10:
				i += 1
			continue
		# /* comment */
		if ch == 47 and i + 1 < n and text.unicode_at(i + 1) == 42:
			i += 2
			while i + 1 < n and not (text.unicode_at(i) == 42 and text.unicode_at(i + 1) == 47):
				i += 1
			i += 2
			continue
		if ch == 123 or ch == 125: # { }
			tokens.append(char(ch))
			i += 1
			continue
		if ch == 40 or ch == 41: # ( ) kept as tokens so rgbGen const parses cleanly
			tokens.append(char(ch))
			i += 1
			continue
		var start := i
		while i < n:
			var c := text.unicode_at(i)
			if c == 32 or c == 9 or c == 10 or c == 13 or c == 123 or c == 125 or c == 40 or c == 41:
				break
			if c == 47 and i + 1 < n and (text.unicode_at(i + 1) == 47 or text.unicode_at(i + 1) == 42):
				break
			i += 1
		if i > start:
			tokens.append(text.substr(start, i - start))
	return tokens


func _parse_block(tokens: PackedStringArray, i: int, def: ShaderDef) -> int:
	var n := tokens.size()
	while i < n:
		var tok: String = tokens[i]
		if tok == "}":
			return i + 1
		if tok == "{":
			var stage := StageDef.new()
			i = _parse_stage(tokens, i + 1, stage)
			for st in _expand_multimap_stage(stage):
				if st.maps.size() > 0 or st.is_lightmap or st.is_whiteimage:
					def.stages.append(st)
			continue
		var key := tok.to_lower()
		i += 1
		var args: PackedStringArray = []
		while i < n and tokens[i] != "{" and tokens[i] != "}":
			if _is_global_keyword(tokens[i]) and args.size() >= maxi(_global_arg_count(key), 0):
				break
			args.append(tokens[i])
			i += 1
		_apply_global(def, key, args)
	return i


func _parse_stage(tokens: PackedStringArray, i: int, stage: StageDef) -> int:
	var n := tokens.size()
	while i < n:
		var tok: String = tokens[i]
		if tok == "}":
			return i + 1
		if tok == "{":
			# nested = skip
			i += 1
			continue
		var key := tok.to_lower()
		i += 1
		var args: PackedStringArray = []
		while i < n and tokens[i] != "{" and tokens[i] != "}" and not _is_stage_keyword(tokens[i]):
			args.append(tokens[i])
			i += 1
		_apply_stage(stage, key, args)
	return i


func _is_global_keyword(token: String) -> bool:
	match token.to_lower():
		"surfaceparm", "cull", "skyparms", "fogparms", "deformvertexes", \
		"sort", "nopicmip", "nomipmaps", "nomipmap", "polygonoffset", "portal", \
		"tesssize", "qer_editorimage", "qer_trans", "qer_nocarve", \
		"q3map_surfacelight", "q3map_lightimage", "q3map_sun", "q3map_sunext", "sun", \
		"q3map_lightsubdivide", "q3map_backshader", "q3map_globaltexture", \
		"q3map_lightmapfilterradius", "q3map_lightmapsamplesize", "q3map_shadeangle", \
		"q3map_clipmodel", "q3map_forcemeta", "q3map_novertexshadows", \
		"q3map_notjunc", "q3map_nofog", "q3map_bouncescale", \
		"q3map_nolightmap", "q3map_onlyvertexlighting", \
		"q3map_lightmapbrightness", "q3map_material", "entitymergable", \
		"q3map_flare", "q3map_lightimage", \
		"nofog", "noglfog", "nonsolid", "trans", \
		"clamptime", "notc", "material", "lightcolor", \
		"q3map_lightrgb", "q3map_lightstyle", \
		"q3map_stylemarker", "q3map_stylemarker2", "light", \
		"allowcompress", "nocompress", "distancecull", \
		"implicitmap", "implicitblend", "implicitmask", \
			"dpoffsetmapping", "dpglossintensitymod", "dpglossintensity", \
			"dpglossexponentmod", "dp_reflect", "dpreflectcube", "dp_water", "dp_refract":
			return true
		_:
			return false


func _global_arg_count(key: String) -> int:
	match key:
		"nopicmip", "nomipmaps", "nomipmap", "polygonoffset", "portal", \
		"qer_nocarve", "entitymergable", "nofog", "noglfog", "notc", \
		"q3map_globaltexture", \
		"q3map_clipmodel", "q3map_forcemeta", "q3map_novertexshadows", \
		"q3map_notjunc", "q3map_nofog", "q3map_nolightmap", "q3map_onlyvertexlighting", \
		"q3map_stylemarker", "q3map_stylemarker2", \
		"allowcompress", "nocompress":
			return 0
		"surfaceparm", "cull", "sort", "tesssize", "qer_editorimage", "qer_trans", \
		"q3map_surfacelight", "q3map_lightimage", "q3map_lightsubdivide", \
		"q3map_backshader", "q3map_lightmapsamplesize", "q3map_shadeangle", \
		"q3map_material", "material", "q3map_bouncescale", "q3map_lightmapbrightness", \
		"q3map_flare", "clamptime", "q3map_lightstyle", "light", \
		"implicitmap", "implicitblend", "implicitmask":
			return 1
		"distancecull":
			return 3
		"lightcolor", "q3map_lightrgb":
			return 3
		"fogparms":
			return 4
		"skyparms":
			return 3
		"q3map_sun", "q3map_sunext", "sun":
			return 6
		_:
			return -1 # unknown


func _is_stage_keyword(token: String) -> bool:
	match token.to_lower():
		"map", "clampmap", "animmap", "clampanimmap", "oneshotanimmap", \
		"mapcomp", "mapnocomp", "map16", "map32", \
		"videomap", "blendfunc", "rgbgen", "alphagen", \
		"tcgen", "tcmod", "depthfunc", "depthwrite", "alphafunc", "detail", \
		"glow", "surfacesprites", "ssfademax", "ssfadescale", "ssvariance", \
		"sswind", "ssfaceup", "ssfxduration", "ssfxgrow", "ssfxalpharange", \
		"ssfxweather", "ssweather", "sshangdown", "sswindidle":
			return true
		_:
			return false


func _apply_global(def: ShaderDef, key: String, args: PackedStringArray) -> void:
	match key:
		"surfaceparm":
			if args.is_empty():
				return
			var parm := args[0].to_lower()
			if not def.surfaceparms.has(parm):
				def.surfaceparms.append(parm)
			match parm:
				"trans", "nonopaque":
					if not def.is_lava:
						def.is_trans = true
				"sky":
					def.is_sky = true
				"fog":
					def.is_fog = true
				"lava":
					def.is_lava = true
					def.is_trans = false
				"water":
					def.is_water = true
					def.is_trans = true
				"slime":
					def.is_slime = true
					def.is_trans = true
				"nodlight":
					def.nodlight = true
				"nolightmap":
					def.nolightmap = true
					def.nodlight = true
				"nonsolid":
					pass
		"cull":
			# ParseShader:
			#   none | twosided | disable -> CT_TWO_SIDED (cull_disabled)
			#   back | backside | backsided -> CT_BACK_SIDED (cull_front)
			#   missing / front / unknown stay CT_FRONT_SIDED (cull_back)
			var v := (args[0] if args.size() > 0 else "").to_lower()
			if v in ["none", "twosided", "disable"]:
				def.cull = CULL_DISABLED
			elif v in ["back", "backside", "backsided"]:
				def.cull = CULL_FRONT
			else:
				def.cull = CULL_BACK
		"skyparms":
			def.is_sky = true
			def.skyparms = PackedStringArray()
			for a in args:
				def.skyparms.append(_strip_ext(a))
			while def.skyparms.size() < 3:
				def.skyparms.append("-")
			if def.skyparms[0].to_lower() in ["full", "half"]:
				def.skyparms[0] = "-"
		"fogparms":
			def.fogparms = PackedFloat32Array()
			for a in args:
				if a == "(" or a == ")":
					continue
				def.fogparms.append(_to_float(a))
			# allow 0-1 float or 0-255 byte colors
			if def.fogparms.size() >= 3 and def.fogparms[0] > 1.0:
				def.fogparms[0] /= 255.0
				def.fogparms[1] /= 255.0
				def.fogparms[2] /= 255.0
		"dpoffsetmapping":
			var mode := args[0].to_lower() if args.size() > 0 else "normal"
			if mode in ["off", "none", "disable"]:
				def.offset_mode = 0
			elif mode == "relief":
				def.offset_mode = 2
			else:
				def.offset_mode = 1
			if args.size() > 1 and args[1] != "-":
				def.offset_scale = _to_float(args[1])
			if args.size() > 2:
				var how := args[2].to_lower()
				if how == "bias" and args.size() > 3:
					def.offset_bias = _to_float(args[3])
				elif how == "match" and args.size() > 3:
					def.offset_bias = 1.0 - _to_float(args[3])
				elif how == "match8" and args.size() > 3:
					def.offset_bias = 1.0 - _to_float(args[3]) / 255.0
				elif how == "match16" and args.size() > 3:
					def.offset_bias = 1.0 - _to_float(args[3]) / 65535.0
				else:
					def.offset_bias = _to_float(args[2])
		"dpglossintensitymod", "dpglossintensity":
			if args.size() > 0:
				def.gloss_intensity = _to_float(args[0])
		"dpglossexponentmod":
			if args.size() > 0:
				def.gloss_exponent = _to_float(args[0])
		"dp_reflect":
			def.reflect_distort = _to_float(args[0]) if args.size() > 0 else 0.0
			var r := _to_float(args[1]) if args.size() > 1 else 1.0
			var g := _to_float(args[2]) if args.size() > 2 else 1.0
			var b := _to_float(args[3]) if args.size() > 3 else 1.0
			var a := _to_float(args[4]) if args.size() > 4 else 1.0
			def.reflect_rgba = Vector4(r, g, b, a)
		"dpreflectcube":
			if args.size() > 0:
				def.reflect_cube = args[0]
		"dp_water":
			# args 0/1 (reflect min/max) and 10 (alpha) are DP fresnel
			# bounds. The emitted reflect uses distort + rgb only.
			def.water_on = true
			def.water_refract_distort = _to_float(args[2]) if args.size() > 2 else 1.0
			def.water_reflect_distort = _to_float(args[3]) if args.size() > 3 else 1.0
			def.water_refract_rgb = Vector3(_to_float(args[4]) if args.size() > 4 else 1.0, _to_float(args[5]) if args.size() > 5 else 1.0, _to_float(args[6]) if args.size() > 6 else 1.0)
			def.water_reflect_rgb = Vector3(_to_float(args[7]) if args.size() > 7 else 1.0, _to_float(args[8]) if args.size() > 8 else 1.0, _to_float(args[9]) if args.size() > 9 else 1.0)
		"dp_refract":
			def.refract_on = true
			def.refract_rgb = Vector3(_to_float(args[0]) if args.size() > 0 else 1.0, _to_float(args[1]) if args.size() > 1 else 1.0, _to_float(args[2]) if args.size() > 2 else 1.0)
			def.refract_alpha = _to_float(args[3]) if args.size() > 3 else 1.0
		"deformvertexes":
			if args.is_empty():
				return
			var kind := args[0].to_lower()
			if kind == "autosprite":
				def.billboard = 1
			elif kind == "autosprite2":
				def.billboard = 2
			elif kind == "projectionshadow":
				pass
			else:
				var vals := PackedFloat32Array()
				var rest := 1
				var wave := WAVE_SIN
				if kind == "wave" and args.size() > 2:
					wave = _wave_func(args[2])
				elif kind == "move" and args.size() > 4:
					wave = _wave_func(args[4])
				for k in range(rest, args.size()):
					if _is_wave_name(args[k]):
						continue
					vals.append(_to_float(args[k]))

				def.deform_vertexes.append({
					"kind": kind,
					"wave": wave,
					"values": vals,
				})
		"sort":
			if args.is_empty():
				return
			var s := args[0].to_lower()
			match s:
				"additive", "add":
					def.sort = SORT_ADDITIVE
					def.sort_order = 9.0
				"seethrough":
					# Raven SS_SEE_THROUGH (alpha-test / thin cover), not additive.
					def.sort = SORT_BANNER
					def.sort_order = 5.0
					def.is_trans = true
				"decal":
					def.sort_order = 4.0
					def.polygon_offset = true
				"banner":
					def.sort = SORT_BANNER
					def.sort_order = 6.0
				"inside":
					def.sort_order = 7.0
				"mid_inside":
					def.sort_order = 8.0
				"middle":
					def.sort_order = 9.0
				"mid_outside":
					def.sort_order = 10.0
				"outside":
					def.sort_order = 11.0
				"underwater":
					def.sort = SORT_UNDERWATER
					def.sort_order = 8.0
				"nearest":
					def.sort = SORT_NEAREST
					def.sort_order = 16.0
				"portal":
					def.sort = SORT_PORTAL
					def.sort_order = 1.0
				"sky":
					def.sort_order = 2.0
				"opaque":
					def.sort = SORT_OPAQUE
					def.sort_order = 3.0
				_:
					if s.is_valid_float():
						def.sort_order = _to_float(s)
		"nopicmip":
			pass # q3map picmip hint, Godot import does not downsample
		"nomipmaps", "nomipmap":
			def.nomipmaps = true
		"polygonoffset":
			def.polygon_offset = true
		"entitymergable":
			def.entity_mergable = true
		"portal":
			def.portal = true
			def.sort = SORT_PORTAL
		"tesssize":
			pass # q3map curve tessellation is baked into the BSP
		"qer_editorimage":
			if args.size() > 0:
				def.editor_image = _strip_ext(args[0])
		"q3map_nolightmap":
			def.nolightmap = true
		"q3map_onlyvertexlighting":
			def.nolightmap = true
			def.only_vertex_light = true
		"q3map_surfacelight":
			if args.size() > 0:
				def.tech3_surfacelight = _to_float(args[0])
		"q3map_lightimage":
			if args.size() > 0:
				def.tech3_lightimage = _strip_ext(args[0])
		"q3map_sun", "q3map_sunext", "sun":
			def.sun_params = PackedFloat32Array()
			for a in args:
				def.sun_params.append(_to_float(a))
		"notc":
			def.no_tc = true
		"clamptime":
			if args.size() > 0:
				def.clamp_time = maxf(_to_float(args[0]), 0.0)
		"q3map_material", "material":
			if args.size() > 0:
				def.q3map_material = args[0]
		"lightcolor", "q3map_lightrgb":
			def.light_color = PackedFloat32Array()
			for a in args:
				if a == "(" or a == ")":
					continue
				def.light_color.append(_to_float(a))
		"q3map_lightstyle":
			if args.size() > 0:
				def.q3map_lightstyle = clampi(int(args[0].to_int()), 0, 63)
		"implicitmap", "implicitblend", "implicitmask":
			# ydnar / RtCW: default stage when the shader has no { } passes.
			# Explicit stages win, implicit only fills an empty shader.
			match key:
				"implicitblend":
					def.rtcw_implicit = "blend"
				"implicitmask":
					def.rtcw_implicit = "mask"
				_:
					def.rtcw_implicit = "map"
			if args.size() > 0:
				def.rtcw_implicit_image = args[0]
			else:
				def.rtcw_implicit_image = "-"
		_:
			pass


func _apply_stage(stage: StageDef, key: String, args: PackedStringArray) -> void:
	match key:
		"map":
			if args.is_empty():
				return
			_stage_add_map(stage, args[0], false)
		"mapcomp", "mapnocomp", "map16", "map32":
			# RtCW compression / bit-depth map variants. Same as map when
			# the stage is empty, ignored if a real map is already bound.
			if args.is_empty() or _stage_has_bundle(stage):
				return
			_stage_add_map(stage, args[0], false)
		"clampmap":
			if args.is_empty():
				return
			_stage_add_map(stage, args[0], true)
		"animmap":
			_stage_set_anim(stage, args, false, false)
		"clampanimmap":
			_stage_set_anim(stage, args, true, false)
		"oneshotanimmap":
			_stage_set_anim(stage, args, false, true)
		"videomap":
			# TODO: Video player stage. Treat as a still map until a video path exists.
			if args.is_empty():
				return
			_stage_add_map(stage, args[0], true)
		"blendfunc":
			var cleaned: PackedStringArray = []
			for a in args:
				cleaned.append(a.to_upper())
			if cleaned.size() == 1:
				match cleaned[0]:
					"ADD", "GL_ADD":
						stage.blend = PackedStringArray(["GL_ONE", "GL_ONE"])
					"FILTER":
						stage.blend = PackedStringArray(["GL_DST_COLOR", "GL_ZERO"])
					"BLEND":
						stage.blend = PackedStringArray(["GL_SRC_ALPHA", "GL_ONE_MINUS_SRC_ALPHA"])
					_:
						stage.blend = cleaned
			else:
				stage.blend = cleaned
		"rgbgen":
			stage.rgb_gen = _upper_args(args)
		"alphagen":
			stage.alpha_gen = _upper_args(args)
		"tcgen":
			if args.is_empty():
				return
			var t := args[0].to_lower()
			if t == "environment":
				stage.tc_gen = "environment"
			elif t == "lightmap":
				stage.tc_gen = "lightmap"
			elif t == "vector":
				stage.tc_gen = "vector"
				var nums: PackedFloat32Array = PackedFloat32Array()
				for a in args:
					if a == "(" or a == ")" or not _is_number(a):
						continue
					nums.append(_to_float(a))
				if nums.size() >= 6:
					stage.tc_gen_s = Vector3(nums[0], nums[1], nums[2])
					stage.tc_gen_t = Vector3(nums[3], nums[4], nums[5])
			else:
				stage.tc_gen = "base"
		"tcmod":
			if args.is_empty():
				return
			var kind := args[0].to_lower()
			var mod_type := TCMOD_SCROLL
			var mod_wave := WAVE_SIN
			match kind:
				"rotate":
					mod_type = TCMOD_ROTATE
				"scale":
					mod_type = TCMOD_SCALE
				"scroll":
					mod_type = TCMOD_SCROLL
				"stretch":
					mod_type = TCMOD_STRETCH
					if args.size() > 1:
						mod_wave = _wave_func(args[1])
				"transform":
					mod_type = TCMOD_TRANSFORM
				"turb":
					mod_type = TCMOD_TURB
				"entitytranslate":
					mod_type = TCMOD_ENTITYTRANSLATE
				_:
					return
			var vals := PackedFloat32Array()
			for k in range(1, args.size()):
				if mod_type != TCMOD_TURB and _is_wave_name(args[k]):
					continue
				vals.append(_to_float(args[k]))
				if mod_type == TCMOD_TURB and vals.size() >= 4:
					break
			stage.tc_mods.append({
				"type": mod_type,
				"wave": mod_wave,
				"values": vals,
			})
		"depthfunc":
			if args.is_empty():
				stage.depth_func = DEPTH_LEQUAL
			else:
				match args[0].to_lower():
					"equal":
						stage.depth_func = DEPTH_EQUAL
					"disable", "always", "none":
						stage.depth_func = DEPTH_DISABLE
					_:
						stage.depth_func = DEPTH_LEQUAL
		"depthwrite":
			stage.depth_write = true
		"alphafunc":
			if args.is_empty():
				return
			match args[0].to_upper():
				"GT0":
					stage.alpha_func = ALPHA_GT0
				"LT128":
					stage.alpha_func = ALPHA_LT128
				"GE128":
					stage.alpha_func = ALPHA_GE128
				"GE192":
					stage.alpha_func = ALPHA_GE192
		"detail":
			stage.detail = true
		"glow":
			stage.glow = true
		"surfacesprites":
			if args.size() >= 5:
				stage.ss_type = args[0].to_lower()
				stage.ss_width = _to_float(args[1])
				stage.ss_height = _to_float(args[2])
				stage.ss_density = _to_float(args[3])
				stage.ss_fade_dist = _to_float(args[4])
		"ssfademax":
			if args.size() > 0:
				stage.ss_fade_max = _to_float(args[0])
		"ssfadescale":
			pass # recognized so the token is not a map path; fade uses ssfademax
		"ssvariance":
			if args.size() >= 2:
				stage.ss_var_w = _to_float(args[0])
				stage.ss_var_h = _to_float(args[1])
		"sswind":
			if args.size() > 0:
				stage.ss_wind = _to_float(args[0])
		"ssfaceup":
			stage.ss_faceup = true
		"ssfxduration":
			if args.size() > 0:
				stage.ss_fx_duration = maxf(_to_float(args[0]), 1.0)
		"ssfxgrow":
			if args.size() >= 2:
				stage.ss_fx_grow_w = _to_float(args[0])
				stage.ss_fx_grow_h = _to_float(args[1])
		"ssfxalpharange":
			if args.size() >= 2:
				stage.ss_fx_alpha_start = _to_float(args[0])
				stage.ss_fx_alpha_end = _to_float(args[1])
		"ssfxweather", "ssweather":
			stage.ss_fx_weather = true


func _classify_map(stage: StageDef, raw: String) -> void:
	var u := raw.to_upper()
	if u.contains("$LIGHTMAP"):
		stage.is_lightmap = true
		stage.source = SRC_LIGHTMAP

		if stage.tc_gen == "base":
			stage.tc_gen = "lightmap"
	elif u.contains("$WHITEIMAGE") or u.contains("$WHITE"):
		stage.is_whiteimage = true
		stage.source = SRC_WHITEIMAGE
	elif u.contains("$BLACKIMAGE") or u.contains("$BLACK"):
		stage.is_blackimage = true
		stage.source = SRC_WHITEIMAGE


func _stage_has_bundle(stage: StageDef) -> bool:
	return stage.maps.size() > 0 or stage.is_lightmap or stage.is_whiteimage or stage.is_blackimage


func _stage_set_anim(stage: StageDef, args: PackedStringArray, clamp_uv: bool, oneshot: bool) -> void:
	if args.size() < 2:
		return
	stage.source = SRC_ANIMMAP
	stage.anim_fps = _to_float(args[0])
	stage.clamp_uv = clamp_uv
	stage.anim_oneshot = oneshot
	stage.maps = PackedStringArray()
	for k in range(1, args.size()):
		stage.maps.append(_strip_ext(args[k]))


func _stage_add_map(stage: StageDef, raw: String, clamp_uv: bool) -> void:
	# DP - A second map/clampmap in the same stage is a multitexture bundle
	# not an overwrite and not an animMap frame.
	if stage.source == SRC_ANIMMAP:
		return
	if _stage_has_bundle(stage):
		stage.extra_maps.append(_strip_ext(raw))
		stage.extra_clamp.append(1 if clamp_uv else 0)
		return
	stage.source = SRC_CLAMPMAP if clamp_uv else SRC_MAP
	stage.clamp_uv = clamp_uv
	stage.maps = PackedStringArray([_strip_ext(raw)])
	_classify_map(stage, raw)


func _stage_clone_bundle(template: StageDef, raw: String, clamp_uv: bool) -> StageDef:
	var st := StageDef.new()
	st.source = SRC_CLAMPMAP if clamp_uv else SRC_MAP
	st.clamp_uv = clamp_uv
	st.maps = PackedStringArray([_strip_ext(raw)])
	st.blend = template.blend.duplicate()
	st.rgb_gen = template.rgb_gen.duplicate()
	st.alpha_gen = template.alpha_gen.duplicate()
	st.alpha_func = template.alpha_func
	st.detail = template.detail
	st.glow = template.glow
	st.anim_oneshot = template.anim_oneshot
	st.depth_func = template.depth_func
	st.depth_write = template.depth_write
	st.tc_mods = template.tc_mods.duplicate()
	st.tc_gen = template.tc_gen
	st.tc_gen_s = template.tc_gen_s
	st.tc_gen_t = template.tc_gen_t
	_classify_map(st, raw)
	# Extra bundles keep their own texcoords. $lightmap forces lightmap UVs
	# a following color map must not inherit that.
	if not st.is_lightmap and template.is_lightmap:
		st.tc_gen = "base"
	return st


func _expand_multimap_stage(stage: StageDef) -> Array[StageDef]:
	var out: Array[StageDef] = []
	if stage.extra_maps.is_empty():
		out.append(stage)
		return out

	# Split one DP stage into Q3-style passes:
	#   map $lightmap
	#   map textures/foo
	#   alphafunc GT0
	# becomes a lighting $lightmap plus a color map that modulates it.
	# GL default texenv is MODULATE, so extras with no blendFunc filter.
	var first := stage
	var extras: PackedStringArray = stage.extra_maps
	var extra_clamp: PackedInt32Array = stage.extra_clamp
	var orig_blend := stage.blend.duplicate()
	var orig_tc_mods: Array[Dictionary] = stage.tc_mods.duplicate()
	var orig_alpha_func := stage.alpha_func
	first.extra_maps = PackedStringArray()
	first.extra_clamp = PackedInt32Array()

	var first_is_light := first.is_lightmap
	if first_is_light:
		# Alpha test and tcMod belong on the color bundle, not $lightmap.
		first.alpha_func = ALPHA_NONE
		first.tc_mods = []
		first.blend = PackedStringArray()

	out.append(first)
	var last_color: StageDef = first if not first_is_light else null
	for i in extras.size():
		var clamp_uv := extra_clamp.size() > i and extra_clamp[i] != 0
		var st: StageDef = _stage_clone_bundle(stage, extras[i], clamp_uv)
		if first_is_light and not st.is_lightmap:
			st.tc_mods = orig_tc_mods.duplicate()
			st.alpha_func = orig_alpha_func
		# Inner combine is GL_MODULATE. An explicit stage blendFunc is
		# restored onto the last color bundle below (FB blend).
		st.blend = PackedStringArray(["GL_DST_COLOR", "GL_ZERO"])
		if not st.is_lightmap:
			last_color = st
		out.append(st)

	# Stage blendFunc applies to the combined result vs the framebuffer.
	# Intermediate color extras stay filter, the last color bundle keeps
	# the original blend.
	if last_color != null and orig_blend.size() > 0 and last_color != first:
		last_color.blend = orig_blend
	return out


func _upper_args(args: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for a in args:
		if a == "(" or a == ")":
			continue
		out.append(a.to_upper())
	return out


func _register(def: ShaderDef) -> void:
	# implicit sky stage when only skyparms farbox is given
	if def.is_sky and def.skyparms.size() > 0 and def.skyparms[0] != "-" \
			and def.stages.is_empty():
		var st := StageDef.new()
		st.is_farbox = true
		st.maps = PackedStringArray([def.skyparms[0]])
		def.stages.append(st)
	# RtCW / ydnar implicitMap|Blend|Mask. Only when no explicit stages.
	if def.stages.is_empty() and def.rtcw_implicit != "":
		var img := def.rtcw_implicit_image.strip_edges()
		if img == "" or img == "-":
			img = def.name
		var st := StageDef.new()
		_stage_add_map(st, img, false)
		match def.rtcw_implicit:
			"blend":
				st.blend = PackedStringArray(["GL_SRC_ALPHA", "GL_ONE_MINUS_SRC_ALPHA"])
				def.is_trans = true
				if def.cull == CULL_BACK:
					def.cull = CULL_DISABLED
			"mask":
				st.alpha_func = ALPHA_GE128
				if def.cull == CULL_BACK:
					def.cull = CULL_DISABLED
		def.stages.append(st)
	var key := _norm_name(def.name)
	if def.is_fog and def.stages.is_empty():
		fog_shaders[key] = def
	else:
		shaders[key] = def
		if def.is_fog:
			fog_shaders[key] = def


func _lookup(shader_name: String) -> ShaderDef:
	var key := _norm_name(shader_name)
	if shaders.has(key):
		return shaders[key]
	if fog_shaders.has(key):
		return fog_shaders[key]
	return null


func _norm_name(n: String) -> String:
	return _strip_ext(n).replace("\\", "/").to_lower()


func _stage_maps_lightimage(def: ShaderDef, st: StageDef) -> bool:
	if def.tech3_lightimage == "":
		return false
	var want := _norm_name(def.tech3_lightimage)
	for m in st.maps:
		if _norm_name(m) == want:
			return true
	return false


# ---
# Godot shader generation
# ---

func _stage_is_style_lightmap(st: StageDef) -> bool:
	# q3map2 -styles: extra animated lightmap pages.
	#   map $lightmap | maps/<map>/lm_NNNN.tga
	#   blendFunc GL_SRC_ALPHA GL_ONE
	#   rgbGen wave <func> ...
	#   tcGen lightmap
	if st.tc_gen != "lightmap":
		return false
	var style_blend := st.blend.size() >= 2 and st.blend[0] == "GL_SRC_ALPHA" and st.blend[1] == "GL_ONE"
	var style_wave := st.rgb_gen.size() > 0 and st.rgb_gen[0] == "WAVE"
	var style_file := false
	for m in st.maps:
		var n := m.replace("\\", "/").to_lower().get_file()
		if n.begins_with("lm_") or n.begins_with("lm000"):
			style_file = true
			break
	if style_file:
		return true
	if st.is_lightmap and (style_blend or style_wave):
		# primary $lightmap is identity + no blend. A later $lightmap with
		# wave / src-alpha add is a style page (sometimes tcMod-offset)
		return style_blend or style_wave
	return style_blend and style_wave


func _assign_style_stage_indices(def: ShaderDef) -> void:
	# Extra IBSP pages are lightmap *channels*. The table slot is the
	# entity style (2 in a one-light test map), from style_stage_ids.
	# q3map_lightstyle on a single-stage shader wins. rgbGen wave is
	# harvested into that slot so the Omni uses the same curve.
	var n := 0
	for st in def.stages:
		st.style_index = 0
		if not _stage_is_style_lightmap(st):
			continue
		if n < style_stage_ids.size():
			st.style_index = int(style_stage_ids[n])
		else:
			st.style_index = n + 1
		n += 1
		_harvest_style_wave(st)
	if def.q3map_lightstyle > 0 and n == 1:
		for st in def.stages:
			if _stage_is_style_lightmap(st):
				st.style_index = def.q3map_lightstyle
				_harvest_style_wave(st)
				break


func _harvest_style_wave(st: StageDef) -> void:
	if st.style_index <= 0 or harvested_style_waves.has(st.style_index):
		return
	var rgb := st.rgb_gen
	if rgb.size() < 6 or rgb[0] != "WAVE":
		return
	harvested_style_waves[st.style_index] = {
		"func": _wave_func(rgb[1]),
		"base": _to_float(rgb[2]),
		"amp": _to_float(rgb[3]),
		"phase": _to_float(rgb[4]),
		"freq": _to_float(rgb[5]),
		"pattern": "",
		"on_pattern": "",
		"enabled": true,
	}


func _stage_uses_table_style(st: StageDef) -> bool:
	return _stage_is_style_lightmap(st) and st.style_index > 0


func _stage_is_lighting_lightmap(st: StageDef) -> bool:
	if _stage_is_style_lightmap(st):
		return false
	return st.is_lightmap and st.tc_gen in ["base", "lightmap"]


func _stage_is_lm_replace(st: StageDef) -> bool:
	if not st.is_lightmap:
		return false
	if st.blend.is_empty():
		return false
	return st.blend.size() >= 2 and st.blend[0] == "GL_ONE" and st.blend[1] == "GL_ZERO"


func _pass_solo_lightmap_filters(stage_indices: Array, def: ShaderDef) -> bool:
	# A pass with no color stage filters the framebuffer only when a
	# $lightmap says so (blendFunc filter / GL_DST_COLOR GL_ZERO, inv
	# filter, detail, boost). No blendFunc is GLS_DEFAULT replace:
	# JK2 textures/colors/white2, opaque white, atlas in light().
	for idx in stage_indices:
		var st: StageDef = def.stages[idx]
		if not st.is_lightmap or _stage_is_style_lightmap(st):
			continue
		if _stage_is_modulate(st) or _stage_is_inv_modulate(st) or _stage_is_detail_modulate(st) or _stage_is_dstcolor_one(st):
			return true
	return false


func _stage_is_diffuse_after_lm_replace(def: ShaderDef, idx: int) -> bool:
	var st: StageDef = def.stages[idx]
	if not _stage_is_modulate(st) or st.depth_func != DEPTH_EQUAL:
		return false
	if st.maps.is_empty():
		return false
	var saw_lm_replace := false
	var first_color_map := ""
	for i in idx:
		var prev: StageDef = def.stages[i]
		if _stage_is_lm_replace(prev):
			saw_lm_replace = true
		elif not prev.is_lightmap and first_color_map == "" and prev.maps.size() > 0:
			first_color_map = prev.maps[0]
	return saw_lm_replace and st.maps[0] == first_color_map


func _stage_is_detail(st: StageDef) -> bool:
	# blendFunc detail / GL_DST_COLOR GL_SRC_COLOR only.
	# The stage keyword `detail` is r_detailTextures, not a blend.
	return _stage_is_detail_modulate(st)


func _stage_is_detail_modulate(st: StageDef) -> bool:
	return st.blend.size() >= 2 and st.blend[0] == "GL_DST_COLOR" and st.blend[1] == "GL_SRC_COLOR"


func _stage_blend_family(st: StageDef) -> String:
	match _stage_opcode(st):
		"LM_LIGHT", "LM_STYLE", "LM_COLOR", "LM_REPLACE":
			return "lightmap"
		"DETAIL":
			return "detail"
		"BOOST", "FILTER":
			return "modulate"
		"INVFIL":
			return "modulate_inv"
		"ADD":
			return "add"
		"BLEND", "MASK":
			return "blend"
		_:
			return "opaque"


# Q3/Raven stage: one opcode. Planner and emit both key off this.
func _stage_opcode(st: StageDef) -> String:
	if st.ss_type != "":
		return "SPRITE"
	if _stage_is_style_lightmap(st):
		return "LM_STYLE"
	if _stage_is_lighting_lightmap(st):
		return "LM_LIGHT"
	if _stage_is_lm_replace(st):
		return "LM_REPLACE"
	if st.is_lightmap:
		return "LM_COLOR"
	if _stage_is_add_blend(st):
		return "ADD"
	if _stage_is_alpha_blend(st):
		return "BLEND"
	if _stage_uses_src_alpha_as_dest(st):
		return "MASK"
	if _stage_is_detail(st) or _stage_is_detail_modulate(st):
		return "DETAIL"
	if _stage_is_dstcolor_one(st):
		return "BOOST"
	if _stage_is_inv_modulate(st):
		return "INVFIL"
	if _stage_is_modulate(st):
		return "FILTER"
	if st.blend.is_empty():
		return "REPLACE"
	if st.blend.size() >= 2 and st.blend[0] == "GL_ONE" and st.blend[1] == "GL_ZERO":
		return "REPLACE"
	return "GENERIC"


# Plan passes: fold dest=accum, split dest=framebuffer.
# depthFunc equal never leaves the pass that wrote depth.
# surfaceSprites are not color stages.

func _plan_passes(def: ShaderDef) -> Array:
	var passes: Array = []
	var current: Array = []
	var wrote_depth := false
	for i in def.stages.size():
		var st: StageDef = def.stages[i]
		if st.ss_type != "":
			continue
		if current.is_empty():
			current = [i]
			wrote_depth = _stage_writes_depth(st)
			continue
		if _plan_must_split(def, current, i, wrote_depth):
			passes.append(current)
			current = [i]
			wrote_depth = _stage_writes_depth(st)
			continue
		current.append(i)
		if _stage_writes_depth(st):
			wrote_depth = true
	if current.size() > 0:
		passes.append(current)
	if passes.is_empty():
		passes.append([])
	return passes


func _stage_writes_depth(st: StageDef) -> bool:
	return st.alpha_func != ALPHA_NONE or st.depth_write


func _pass_has_cutout(def: ShaderDef, indices: Array) -> bool:
	for j in indices:
		if def.stages[j].alpha_func != ALPHA_NONE:
			return true
	return false


func _stage_is_fb_filter(st: StageDef) -> bool:
	if _stage_is_style_lightmap(st):
		return false
	return _stage_is_modulate(st) or _stage_is_detail(st) or _stage_is_dstcolor_one(st) \
			or _stage_is_inv_modulate(st)


func _plan_must_split(def: ShaderDef, current: Array, idx: int, wrote_depth: bool) -> bool:
	var st: StageDef = def.stages[idx]
	if st.depth_func == DEPTH_EQUAL and wrote_depth:
		return false
	var op := _stage_opcode(st)
	# dest is the framebuffer after a cover / modulate / add pass.
	if op == "ADD" and _pass_starts_translucent(def, current):
		return true
	if op == "ADD" and _pass_starts_fb_modulate(def, current):
		return true
	if _pass_first_opcode(def, current) == "ADD" and op != "ADD":
		if _stage_is_lighting_lightmap(st) and _stage_is_modulate(st):
			# Glass: first color is ADD, dest is still the scene.
			# fold so light() hits the overlay only (not dest*lm).
			# Water: a prior FILTER already wrote dest = scene*tex.
			# Q3 then does dest*lm on that composite, next_pass blend_mul.
			return _def_has_fb_modulate_before(def, current)
		return true
	# do not split FILTER $lightmap after an alpha-blend stack.
	# A next_pass blend_mul of the atlas darkens the floor through the
	# water. Fold dest*lm into the color pass.
	if _stage_is_fb_filter(st) and _pass_has_cutout(def, current):
		if _stage_is_lighting_lightmap(st):
			return false
		return true
	return false


func _def_has_fb_modulate_before(def: ShaderDef, current: Array) -> bool:
	if current.is_empty():
		return false
	var start := int(current[0])
	for i in start:
		var op := _stage_opcode(def.stages[i])
		if op in ["FILTER", "BOOST", "DETAIL", "INVFIL", "BLEND"]:
			return true
	return false


func _pass_first_opcode(def: ShaderDef, current: Array) -> String:
	for j in current:
		var op := _stage_opcode(def.stages[j])
		if op.begins_with("LM_"):
			continue
		return op
	return ""


func _pass_starts_fb_modulate(def: ShaderDef, current: Array) -> bool:
	return _pass_first_opcode(def, current) in ["FILTER", "BOOST", "DETAIL", "INVFIL"]


func _pass_starts_translucent(def: ShaderDef, current: Array) -> bool:
	for j in current:
		var st: StageDef = def.stages[j]
		if _stage_is_lighting_lightmap(st) or _stage_is_style_lightmap(st):
			continue
		if _stage_is_alpha_blend(st):
			return true
		if st.alpha_func != ALPHA_NONE:
			return false
		if _stage_uses_src_alpha(st) and not _stage_is_add_blend(st):
			return true
		return false
	return false


func _lighting_lightmap_index(def: ShaderDef) -> int:
	for i in def.stages.size():
		if _stage_is_lighting_lightmap(def.stages[i]):
			return i
	return -1


func _add_before_lightmap(def: ShaderDef, idx: int) -> bool:
	var lm_i := _lighting_lightmap_index(def)
	return lm_i >= 0 and idx < lm_i


func _def_any_cutout_index(def: ShaderDef) -> int:
	# Any alphatest stage, including later ones (grate over additive glow).
	for i in def.stages.size():
		var st: StageDef = def.stages[i]
		if _stage_is_lighting_lightmap(st) or _stage_is_style_lightmap(st):
			continue
		if st.alpha_func != ALPHA_NONE:
			return i
	return -1


func _def_has_any_cutout(def: ShaderDef) -> bool:
	return _def_any_cutout_index(def) >= 0


func _def_color_stage_count(def: ShaderDef) -> int:
	var n := 0
	for st in def.stages:
		if _stage_is_lighting_lightmap(st) or _stage_is_style_lightmap(st):
			continue
		n += 1
	return n


func _def_has_equal_depth_lightmap(def: ShaderDef) -> bool:
	for st in def.stages:
		if st.is_lightmap and st.depth_func == DEPTH_EQUAL:
			return true
	return false


func _def_polygon_offset_decal(def: ShaderDef) -> bool:
	if not def.polygon_offset:
		return false
	if def.surfaceparms.has("nonsolid"):
		return true
	if def.sort_order > 3.0 and def.sort_order < 9.0:
		return true
	if _def_cutout_index(def) >= 0 or _def_has_equal_depth_lightmap(def):
		return true
	if def.entity_mergable:
		return true
	if def.name.replace("\\", "/").to_lower().contains("/decals/"):
		return true
	if _lighting_lightmap_index(def) >= 0:
		# Lightmapped + nodamage is a Q3 jumppad. nomarks without
		# nodamage is a coplanar light/decal (e.g. RtCW red panel)
		if def.surfaceparms.has("nodamage"):
			return false
		if def.surfaceparms.has("nomarks"):
			return true
		return false
	return _def_color_stage_count(def) <= 1


func _pass_polygon_offset_bias(def: ShaderDef, additive: bool, translucent: bool, depth_write: bool) -> bool:
	# Decal / blend polygonOffset: view-space pull, no DEPTH write.
	# Opaque first pass keeps a real depth write.
	if not def.polygon_offset:
		return false
	if _def_polygon_offset_decal(def) or additive or translucent:
		return true
	return not depth_write


func _def_cutout_index(def: ShaderDef) -> int:
	# Only the first color stage can discard the fragment. Later alphaFunc
	# (q3map terrain blend, etc.) just skips that layer.
	for i in def.stages.size():
		var st: StageDef = def.stages[i]
		if _stage_is_lighting_lightmap(st) or _stage_is_style_lightmap(st):
			continue
		if st.alpha_func != ALPHA_NONE:
			return i
		return -1
	return -1


func _alpha_func_pass_expr(st: StageDef, idx: int) -> String:
	match st.alpha_func:
		ALPHA_GT0:
			return "stage_%d.a > 0.0" % idx
		ALPHA_LT128:
			return "stage_%d.a < 0.5" % idx
		ALPHA_GE128:
			return "stage_%d.a >= 0.5" % idx
		ALPHA_GE192:
			return "stage_%d.a >= 0.753" % idx
		_:
			return "true"


func _pass_family(def: ShaderDef, stage_indices: Array) -> String:
	for i in stage_indices:
		var st: StageDef = def.stages[i]
		if st.is_lightmap or _stage_is_style_lightmap(st):
			continue
		return _stage_blend_family(st)
	return "opaque"


func _order_passes_for_godot(def: ShaderDef, passes: Array) -> Array:
	# Opaque / cutout first so next_pass ADD composites into holes.
	if passes.size() <= 1 or not _def_has_any_cutout(def):
		return passes
	var base: Array = []
	var adds: Array = []
	var rest: Array = []
	for p in passes:
		match _pass_family(def, p):
			"add":
				adds.append(p)
			"modulate", "modulate_inv":
				rest.append(p)
			_:
				base.append(p)
	if base.is_empty():
		return adds + rest
	return base + adds + rest


func _gen_is_noise(gen: PackedStringArray) -> bool:
	return gen.size() > 1 and _wave_func(gen[1]) == WAVE_NOISE


func _pass_needs_wave(def: ShaderDef, stage_indices: Array) -> bool:
	for d0 in def.deform_vertexes:
		if String(d0.get("kind", "")) in ["wave", "move"]:
			return true
	for idx in stage_indices:
		var st: StageDef = def.stages[idx]
		if st.rgb_gen.size() > 0 and st.rgb_gen[0] == "WAVE" and not _stage_uses_table_style(st):
			return true
		if st.alpha_gen.size() > 0 and st.alpha_gen[0] == "WAVE":
			return true
		for m in st.tc_mods:
			if int(m["type"]) == TCMOD_STRETCH:
				return true
	if _companion_has_stretch(def):
		return true
	return false


func _pass_needs_noise_lookup(def: ShaderDef, stage_indices: Array) -> bool:
	for d0 in def.deform_vertexes:
		if String(d0.get("kind", "")) in ["wave", "move"] and int(d0.get("wave", WAVE_SIN)) == WAVE_NOISE:
			return true
	for idx in stage_indices:
		var st: StageDef = def.stages[idx]
		if st.rgb_gen.size() > 0 and st.rgb_gen[0] == "WAVE" and not _stage_uses_table_style(st) and _gen_is_noise(st.rgb_gen):
			return true
		if st.alpha_gen.size() > 0 and st.alpha_gen[0] == "WAVE" and _gen_is_noise(st.alpha_gen):
			return true
		for m in st.tc_mods:
			if int(m["type"]) == TCMOD_STRETCH and int(m.get("wave", WAVE_SIN)) == WAVE_NOISE:
				return true
	var cst := _companion_stage(def)
	if cst != null:
		for m2 in cst.tc_mods:
			if int(m2["type"]) == TCMOD_STRETCH and int(m2.get("wave", WAVE_SIN)) == WAVE_NOISE:
				return true
	return false


func _pass_vertex_uses_time(def: ShaderDef, stage_indices: Array) -> bool:
	for d0 in def.deform_vertexes:
		if String(d0.get("kind", "")) in ["wave", "move", "bulge", "normal"]:
			return true
	for idx in stage_indices:
		if not _stage_uses_interpolated_uv(def.stages[idx]):
			continue
		for m in def.stages[idx].tc_mods:
			var mt := int(m["type"])
			if mt == TCMOD_ROTATE or mt == TCMOD_SCROLL or mt == TCMOD_TURB or mt == TCMOD_STRETCH:
				return true
	return false


func _pass_needs_tech3_time(def: ShaderDef, stage_indices: Array) -> bool:
	# tech3_wave's clock is tech3_time. rgbGen/alphaGen wave and tcMod
	# stretch do not show up in the rotate/scroll/turb scan below.
	if _pass_needs_wave(def, stage_indices) or _pass_needs_noise_lookup(def, stage_indices):
		return true
	for d0 in def.deform_vertexes:
		if String(d0.get("kind", "")) in ["bulge", "normal", "autosprite", "move", "wave"]:
			return true
	for idx in stage_indices:
		var st: StageDef = def.stages[idx]
		if st.source == SRC_ANIMMAP or (st.maps.size() > 1 and st.anim_fps > 0.0):
			return true
		for m in st.tc_mods:
			var mt := int(m["type"])
			if mt == TCMOD_ROTATE or mt == TCMOD_SCROLL or mt == TCMOD_TURB:
				return true
	return false


func _analyze_pass(def: ShaderDef, stage_indices: Array, use_lm: bool, first_pass: bool) -> Dictionary:
	var p := {
		"first_color": null,
		"first_op": "",
		"has_lm": false,
		"needs_env": false,
		"needs_rotate": false,
		"additive": def.sort == SORT_ADDITIVE,
		"multiplicative": def.sort == SORT_MULTIPLICATIVE,
		"modulate_invert": false,
		"unshaded": def.nodlight or def.is_sky or def.portal,
		"translucent": false,
		"cutout": false,
		"later_alpha": false,
		"preserve_accum_alpha": false,
		"lm_remain": "",
		"under_idx": -1,
		"cover_idx": -1,
		"cover_count": 0,
		"fold_add": false,
		"depth_write": false,
		"vertex_lit": false,
	}
	for idx in stage_indices:
		var st: StageDef = def.stages[idx]
		for m in st.tc_mods:
			if int(m["type"]) == TCMOD_ROTATE:
				p.needs_rotate = true
		var op := _stage_opcode(st)
		if op in ["LM_LIGHT", "LM_STYLE"]:
			p.has_lm = true
			continue
		if st.is_lightmap:
			p.has_lm = true
		if p.first_color == null:
			p.first_color = st
			p.first_op = op
		if st.tc_gen == "environment":
			p.needs_env = true

	var first: StageDef = p.first_color
	match p.first_op:
		"ADD":
			p.additive = true
		"INVFIL":
			p.multiplicative = true
			p.modulate_invert = true
			p.unshaded = true
		"FILTER":
			if not first_pass or (not use_lm and not p.has_lm):
				p.multiplicative = true
				p.unshaded = true
		"DETAIL":
			p.multiplicative = true
			p.unshaded = true
		"BOOST":
			p.multiplicative = true
			p.unshaded = not use_lm and not p.has_lm
			if def.is_trans or def.is_water or def.is_slime:
				p.translucent = true
		"LM_LIGHT", "LM_REPLACE":
			if first == null and _pass_solo_lightmap_filters(stage_indices, def):
				p.multiplicative = true
				p.unshaded = true
	# Split FILTER $lightmap is dest * lm. No blendFunc is replace.
	if first == null and p.has_lm and _pass_solo_lightmap_filters(stage_indices, def):
		p.multiplicative = true
		p.unshaded = true

	p.cutout = first != null and first.alpha_func != ALPHA_NONE
	if p.cutout and p.first_op != "ADD":
		p.additive = false
	if p.first_op == "BLEND":
		p.translucent = true
	elif first != null and def.is_trans and _stage_uses_src_alpha(first) and not p.cutout and not p.additive:
		p.translucent = true
	if (def.is_water or def.is_slime) and p.first_op == "BLEND":
		p.translucent = true

	var seen_color := false
	for idx_a in stage_indices:
		var sta: StageDef = def.stages[idx_a]
		var opa := _stage_opcode(sta)
		if _stage_uses_dst_alpha_factor(sta):
			p.preserve_accum_alpha = true
		if opa == "LM_LIGHT":
			p.lm_remain = _lm_dest_remainder_factor(sta)
			continue
		if opa == "LM_STYLE":
			continue
		if p.under_idx < 0:
			p.under_idx = idx_a
		if opa == "BLEND" or opa == "MASK":
			p.cover_idx = idx_a
			p.cover_count += 1
		if not seen_color:
			seen_color = true
			continue
		if opa == "BLEND" or opa == "MASK":
			p.later_alpha = true
		if sta.alpha_func != ALPHA_NONE:
			p.later_alpha = true

	p.fold_add = first != null and p.first_op != "ADD" and p.first_op != "BLEND" \
			and not p.cutout and not p.later_alpha
	if first != null and (first.depth_write or p.cutout):
		p.depth_write = true
	elif first_pass and not p.translucent and not p.additive:
		p.depth_write = true
	if p.additive and not p.cutout:
		p.depth_write = false
	if p.additive and not p.cutout and _def_has_any_cutout(def):
		p.depth_write = false
	if def.sort_order >= 9.0 and not p.cutout:
		p.depth_write = false

	if not use_lm:
		for idx_v in stage_indices:
			var st_v: StageDef = def.stages[idx_v]
			if st_v.rgb_gen.size() > 0 and st_v.rgb_gen[0] in [
				"VERTEX", "EXACTVERTEX", "LIGHTINGDIFFUSE", "LIGHTINGDIFFUSEENTITY"
			]:
				p.vertex_lit = true
				break
	# A $lightmap stage with no page is whiteimage, not vertex light.
	if (p.has_lm and use_lm) or def.only_vertex_light:
			p.vertex_lit = true
	if use_lm and p.has_lm:
		p.vertex_lit = true

	# light() only if THIS pass has LM_LIGHT. use_lm is def-wide; an ADD
	# pass that split its FILTER must not also multiply the atlas.
	if p.has_lm and use_lm and not def.nolightmap and not p.translucent \
			and not ((p.additive or p.multiplicative) and not first_pass):
		p.unshaded = false
	elif (p.additive or p.multiplicative) and not first_pass:
		p.unshaded = true
	elif not p.has_lm and first != null and first.rgb_gen.size() > 0 and first.rgb_gen[0] == "IDENTITY":
		p.unshaded = true
	if p.vertex_lit and not def.nodlight and not def.is_sky and not p.translucent:
		p.unshaded = false
	if def.nolightmap and not p.vertex_lit:
		p.unshaded = true
	if def.is_sky or def.nodlight:
		p.unshaded = true
	if p.translucent and not p.additive:
		p.unshaded = true
	return p


func _emit_pass_render_modes(def: ShaderDef, stage_indices: Array, p: Dictionary) -> PackedStringArray:
	var modes: PackedStringArray = []
	if p.additive:
		modes.append("blend_add")
	elif p.multiplicative:
		modes.append("blend_mul")
	else:
		modes.append("blend_mix")
	# polygonOffset is a bias. Explicit depthwrite / alphatest still writes.
	if _pass_polygon_offset_bias(def, p.additive, p.translucent, p.depth_write) and not p.cutout and not p.depth_write:
		modes.append("depth_draw_never")
	elif p.additive and not p.cutout and _def_has_any_cutout(def):
		modes.append("depth_draw_never")
	elif p.cutout or (p.depth_write and p.translucent):
		modes.append("depth_draw_always")
		if p.translucent:
			modes.append("depth_prepass_alpha")
	elif p.depth_write:
		modes.append("depth_draw_opaque")
	elif p.translucent or p.additive or p.multiplicative:
		modes.append("depth_draw_never")
	else:
		modes.append("depth_draw_opaque")
	if def.is_sky:
		modes.append("cull_back")
	else:
		match def.cull:
			CULL_FRONT:
				modes.append("cull_front")
			CULL_DISABLED:
				modes.append("cull_disabled")
			_:
				modes.append("cull_back")
	modes.append("diffuse_lambert")

	if not _emit_deluxe and not _wants_gloss(def):
		modes.append("specular_disabled")
	if p.unshaded:
		modes.append("unshaded")
	var alpha_cover := false
	for st_f in def.stages:
		if _stage_opcode(st_f) == "BLEND":
			alpha_cover = true
			break

	if (p.additive or p.multiplicative) and !def.is_water:
		modes.append("fog_disabled")
	for idx_df in stage_indices:
		if def.stages[idx_df].depth_func == DEPTH_DISABLE:
			modes.append("depth_test_disabled")
			break
	return modes


func _emit_pass(def: ShaderDef, stage_indices: Array, use_lm: bool, first_pass: bool) -> String:
	# Lower one planned pass: opcodes to Godot. Missing engine features
	# (depth_func_equal, 8-bit dest blend, a glow buffer) are lowerings
	# of those opcodes, not per-shader exceptions.
	_assign_style_stage_indices(def)
	var p := _analyze_pass(def, stage_indices, use_lm, first_pass)
	var first_color: StageDef = p.first_color
	var has_lightmap_stage: bool = p.has_lm
	var needs_env: bool = p.needs_env
	var comp_st_early := _companion_stage(def)
	var companion_needs_env := comp_st_early != null and comp_st_early.tc_gen == "environment"
	# Flags: 1 norm, 2 gloss, 4 glow, 8 bump, 16 reflect. Norm wins over bump.
	var want_normal := def.offset_mode > 0 or (companion_flags & 1) != 0
	var want_height := (companion_flags & 8) != 0 and (companion_flags & 1) == 0
	var want_gloss := _wants_gloss(def)
	var want_glow := (companion_flags & 4) != 0
	var want_reflect := def.reflect_cube != "" or (companion_flags & 16) != 0
	var want_deluxe_samplers: bool = _emit_deluxe and not p.unshaded
	var want_comp_uv := want_normal or want_height or want_gloss or want_glow or want_reflect
	var want_eye := def.offset_mode > 0 or want_height
	var needs_rotate: bool = p.needs_rotate or (want_comp_uv and _companion_needs_rotate(def))
	var additive: bool = p.additive
	var multiplicative: bool = p.multiplicative
	var modulate_invert: bool = p.modulate_invert
	var unshaded: bool = p.unshaded
	var translucent: bool = p.translucent
	var cutout: bool = p.cutout
	var later_alpha: bool = p.later_alpha
	var preserve_accum_alpha: bool = p.preserve_accum_alpha
	var lm_remain: String = p.lm_remain
	var cover_idx: int = p.cover_idx
	var cover_count: int = p.cover_count
	var fold_add: bool = p.fold_add
	var depth_write: bool = p.depth_write
	var vertex_lit: bool = p.vertex_lit
	var modes := _emit_pass_render_modes(def, stage_indices, p)
	var need_time := _pass_needs_tech3_time(def, stage_indices)
	var need_wave := _pass_needs_wave(def, stage_indices)
	var need_noise := _pass_needs_noise_lookup(def, stage_indices)
	if want_comp_uv and _companion_needs_time(def):
		need_time = true
	if need_wave or need_noise:
		need_time = true
	var code := "shader_type spatial;\n"
	# BOOST is dest*(1+src). Sample the framebuffer and replace
	# blend_mul + ALBEDO > 1 is Forward+ only.
	if p.first_op == "BOOST" and p.multiplicative:
		var rest: PackedStringArray = []
		for m in modes:
			if m != "blend_mul" and m != "blend_add" and m != "blend_mix":
				rest.append(m)
		var tail := ", " + ", ".join(rest) if rest.size() > 0 else ""
		code += "render_mode blend_mix%s;\n" % tail
	else:
		code += "render_mode %s;\n" % ", ".join(modes)
	if need_time:
		code += "#define TECH3_TIME\n"
	if need_wave:
		code += "#define TECH3_WAVE\n"
	if need_noise:
		code += "#define NOISE_LOOKUP\n"
	code += "#include \"res://addons/tech3bsp/shaders/options.gdshaderinc\"\n\n"
	if (p.first_op == "BOOST" and p.multiplicative) or def.reflect_rgba.w > 0.0 or def.refract_on:
		code += "uniform sampler2D t3_fb : hint_screen_texture, filter_linear, repeat_disable;\n"
	if needs_env or companion_needs_env:
		code += _emit_env_uv_helper()
	if def.billboard == 2:
		code += "instance uniform vec3 sprite_axis = vec3(0.0, 1.0, 0.0);\n"
	if _sky_farbox(def) != "":
		code += "uniform samplerCube sky_cubemap : source_color, filter_linear;\n"

	var samples_lm_atlas := false
	var has_style_stage := false
	for idx in stage_indices:
		var st_lm: StageDef = def.stages[idx]
		if _stage_is_style_lightmap(st_lm):
			has_style_stage = true
			samples_lm_atlas = true
			break
		if st_lm.is_lightmap and st_lm.tc_gen not in ["base", "lightmap"]:
			samples_lm_atlas = true
			break
	var needs_lightmap_uniform := (use_lm and not unshaded) or samples_lm_atlas or (use_lm and has_lightmap_stage)
	_lm_atlas_ready = needs_lightmap_uniform and use_lm
	var declared: Dictionary = {}
	if needs_lightmap_uniform:
		code += "uniform sampler2D lightmap_texture : hint_default_white, filter_linear, repeat_disable;\n"
		declared["lightmap_texture"] = true
	var tex_filter := "filter_linear" if def.nomipmaps else "TEXTURE_FILTER"
	# Deluxe samplers only on the pass that runs light(). Companion samplers
	# only when this shader has the keyword or the importer found the file.
	if want_deluxe_samplers:
		code += "uniform sampler2D deluxemap_texture : hint_default_white, filter_linear, repeat_disable;\n"
		code += "uniform float tech3_deluxe = 0.0;\n"
	# Model-space deluxe and offset mapping both read the tangent frame.
	if want_deluxe_samplers or want_eye:
		code += "varying vec3 v_tangent;\n"
		code += "varying vec3 v_binormal;\n"
	if want_normal or want_height or want_gloss or want_glow or want_reflect:
		if want_normal or want_height:
			code += "uniform sampler2D normal_texture : hint_normal, %s, repeat_enable;\n" % tex_filter
		if want_normal:
			code += "uniform float tech3_has_normal = 0.0;\n"
		if def.offset_mode > 0:
			code += "uniform sampler2D offset_texture : hint_default_white, %s, repeat_enable;\n" % tex_filter
			code += "uniform float tech3_has_offset = 0.0;\n"
		if want_height:
			code += "uniform float tech3_has_height = 0.0;\n"
		if want_gloss:
			code += "uniform sampler2D gloss_texture : hint_default_black, %s, repeat_enable;\n" % tex_filter
			code += "uniform float tech3_has_gloss = 0.0;\n"
			code += "uniform float tech3_gloss_intensity = 1.0;\n"
			code += "uniform float tech3_gloss_exponent = 1.0;\n"
		if want_glow:
			code += "uniform sampler2D glow_texture : hint_default_black, %s, repeat_enable;\n" % tex_filter
			code += "uniform float tech3_has_glow = 0.0;\n"
		if want_reflect:
			code += "uniform samplerCube reflect_cube : source_color, filter_linear_mipmap;\n"
			code += "uniform sampler2D reflect_mask : hint_default_white, %s, repeat_enable;\n" % tex_filter
			code += "uniform float tech3_has_reflect = 0.0;\n"
			code += "uniform float tech3_has_cube = 0.0;\n"
		if want_eye:
			code += "varying vec3 v_eye_ts;\n"
	if want_comp_uv:
		code += "varying vec2 t3_comp_uv;\n"
	var need_style_table := (use_lm and not unshaded) or has_style_stage or (use_lm and has_lightmap_stage)
	if need_style_table:
		code += "global uniform sampler2D tech3_style_weights : hint_default_white, filter_nearest, repeat_disable;\n"
	var need_lm_varyings := use_lm and (not unshaded or has_lightmap_stage)
	if need_lm_varyings:
		code += "varying vec4 lm_uv_a;\n"
		code += "varying vec4 lm_uv_b;\n"
		code += "varying vec4 lm_styles;\n"
		code += "varying vec4 lm_cell;\n"
	elif samples_lm_atlas:
		code += "varying vec4 lm_cell;\n"
	var uniform_indices: Array = stage_indices.duplicate()
	if has_style_stage or (additive and _def_has_any_cutout(def)):
		var cuni := _def_any_cutout_index(def)
		if cuni >= 0 and not uniform_indices.has(cuni):
			uniform_indices.append(cuni)
	for idx in uniform_indices:
		var st: StageDef = def.stages[idx]
		if st.is_lightmap or st.is_whiteimage or st.is_blackimage or st.is_farbox:
			continue
		if st.maps.size() > 0 and _named_color_glsl(st.maps[0]) != "" and not has_texture(st.maps[0]):
			continue
		if st.source == SRC_ANIMMAP:
			for f in st.maps.size():
				if not has_texture(st.maps[f]):
					continue
				var uname := "tex_stage_%d_frame_%d" % [idx, f]
				if declared.has(uname):
					continue
				code += "uniform sampler2D %s : source_color, %s, %s;\n" % [
					uname, tex_filter, "repeat_disable" if st.clamp_uv else "repeat_enable"
				]
				declared[uname] = true
			# Frame calc always references these, even when no frame resolved
			# (missing glow maps still emit the oneshot/anim index).
			# Instance uniform so one entity can override without touching
			# every surface that shares the material (Raven RF_SETANIMINDEX).
			if st.maps.size() > 0:
				code += "uniform float stage_%d_anim_fps = %s;\n" % [idx, _ff(st.anim_fps)]
				if not declared.has("anim_frame_override"):
					code += "instance uniform int anim_frame_override = -1;\n"
					declared["anim_frame_override"] = true
		else:
			for mi in st.maps.size():
				if not has_texture(st.maps[mi]):
					continue
				var uname2 := _stage_sampler_name(idx, mi)
				if declared.has(uname2):
					continue
				if _stage_is_style_lightmap(st):
					code += "uniform sampler2D %s : hint_default_white, filter_linear, %s;\n" % [
						uname2, "repeat_disable" if st.clamp_uv else "repeat_enable"
					]
				else:
					code += "uniform sampler2D %s : source_color, %s, %s;\n" % [
						uname2, tex_filter, "repeat_disable" if st.clamp_uv else "repeat_enable"
					]
				declared[uname2] = true

	if vertex_lit and not unshaded:
		code += "\nvarying vec4 vert_color;\n" # can't use COLOR in the light() stage

	var vs_uv_indices: Array = []
	if not def.is_sky:
		for idx_uv in uniform_indices:
			if _stage_uses_interpolated_uv(def.stages[idx_uv]):
				if not vs_uv_indices.has(idx_uv):
					vs_uv_indices.append(idx_uv)
				code += "varying vec2 v_uv_%d;\n" % idx_uv

	if needs_rotate:
		code += "\nvec2 tech3_rotate(vec2 uv, vec2 pivot, float angle) {\n"
		code += "float s = sin(angle);\n	float c = cos(angle);\n"
		code += "uv -= pivot;\n	uv = vec2(uv.x * c - uv.y * s, uv.x * s + uv.y * c);\n"
		code += "return uv + pivot;\n}\n"

	if need_style_table:
		code += _emit_style_weight_helper()

	# Vertex
	code += "varying vec3 v_geom_n;\n"
	code += "\nvoid vertex() {\n"
	code += "v_geom_n = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);\n"
	if need_time and def.clamp_time > 0.0 and (_pass_vertex_uses_time(def, stage_indices) or (want_comp_uv and _companion_needs_time(def))):
		code += "float t3t = mod(tech3_time, %s);\n" % _ff(def.clamp_time)
	if need_lm_varyings:
		code += "lm_uv_a = CUSTOM1;\n"
		code += "lm_uv_b = CUSTOM2;\n"
		code += "lm_styles = CUSTOM3;\n"
		code += "lm_cell = CUSTOM0;\n"
		if want_deluxe_samplers or want_eye:
			code += "if (dot(TANGENT, TANGENT) > 0.25) {\n"
			code += "v_tangent = normalize((MODEL_MATRIX * vec4(TANGENT, 0.0)).xyz);\n"
			code += "v_binormal = normalize((MODEL_MATRIX * vec4(BINORMAL, 0.0)).xyz);\n"
			code += "} else {\n"
			code += "v_tangent = vec3(1.0, 0.0, 0.0);\n"
			code += "v_binormal = vec3(0.0, 0.0, 1.0);\n"
			code += "}\n"
		if want_eye:
			code += "vec3 eye_w = INV_VIEW_MATRIX[3].xyz - (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;\n"
			code += "v_eye_ts = vec3(dot(eye_w, v_tangent), dot(eye_w, v_binormal), dot(eye_w, v_geom_n));\n"
	elif samples_lm_atlas:
		code += "lm_cell = CUSTOM0;\n"
	if not need_lm_varyings and want_eye:
		code += "if (dot(TANGENT, TANGENT) > 0.25) {\n"
		code += "v_tangent = normalize((MODEL_MATRIX * vec4(TANGENT, 0.0)).xyz);\n"
		code += "v_binormal = normalize((MODEL_MATRIX * vec4(BINORMAL, 0.0)).xyz);\n"
		code += "} else {\n"
		code += "v_tangent = vec3(1.0, 0.0, 0.0);\n"
		code += "v_binormal = vec3(0.0, 0.0, 1.0);\n"
		code += "}\n"
		code += "vec3 eye_w = INV_VIEW_MATRIX[3].xyz - (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;\n"
		code += "v_eye_ts = vec3(dot(eye_w, v_tangent), dot(eye_w, v_binormal), dot(eye_w, v_geom_n));\n"
	if vertex_lit and not unshaded:
		code += "vert_color = COLOR;\n"
	var scale := 1.0 / maxf(_unit_scale, 0.0001)
	if def.billboard == 1:
		# Clip-space billboard. POSITION replaces VERTEX, so move/wave
		# after this must offset ss_w (world), not VERTEX.
		code += "{\n"
		code += "vec3 ss_o = MODEL_MATRIX[3].xyz;\n"
		code += "float ss_sx = length(MODEL_MATRIX[0].xyz);\n"
		code += "float ss_sy = length(MODEL_MATRIX[1].xyz);\n"
		code += "vec3 ss_r = normalize(INV_VIEW_MATRIX[0].xyz);\n"
		code += "vec3 ss_u = normalize(INV_VIEW_MATRIX[1].xyz);\n"
		code += "vec3 ss_w = ss_o + ss_r * VERTEX.x * ss_sx + ss_u * VERTEX.y * ss_sy;\n"
		code += _emit_deform_moves_glsl(def, scale, "ss_w")
		code += "POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(ss_w, 1.0);\n"
		code += "}\n"
	elif def.billboard == 2:
		# autosprite2 - pivot on sprite_axis (torches and beams)
		code += "vec3 spr_axis = sprite_axis;\n"
		code += "if (dot(spr_axis, spr_axis) < 0.000001) { spr_axis = vec3(0.0, 1.0, 0.0); }\n"
		code += "spr_axis = normalize(spr_axis);\n"
		code += "vec3 spr_fwd = -INV_VIEW_MATRIX[2].xyz;\n"
		code += "vec3 spr_minor = cross(spr_axis, spr_fwd);\n"
		code += "if (dot(spr_minor, spr_minor) < 0.000001) { spr_minor = vec3(0.0, 1.0, 0.0); }\n"
		code += "spr_minor = normalize(spr_minor);\n"
		code += "vec3 spr_n = normalize(cross(spr_axis, spr_minor));\n"
		code += "vec3 spr_o = MODEL_MATRIX[3].xyz;\n"
		code += _emit_deform_moves_glsl(def, scale, "spr_o")
		code += "vec3 spr_w = spr_o + spr_axis * VERTEX.x + spr_minor * VERTEX.y;\n"
		code += "POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(spr_w, 1.0);\n"
		code += "NORMAL = spr_n;\n"

	for di in def.deform_vertexes.size():
		var d: Dictionary = def.deform_vertexes[di]
		var kind := String(d.get("kind", ""))
		var vals: PackedFloat32Array = d.get("values", PackedFloat32Array())
		var wave: int = int(d.get("wave", WAVE_SIN))
		if kind == "wave" and vals.size() >= 5:
			# values: div, base, amp, phase, freq  (func stored separately)
			# phase is (qx+qy+qz)/div in *unscaled* units
			var div := vals[0]
			var inv_div := (_unit_scale / div) if div > 0.0 else 0.01
			code += "{\n"
			code += "vec3 wp_%d = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;\n" % di
			code += "float off_%d = (wp_%d.x + wp_%d.y + wp_%d.z) * %s;\n" % [di, di, di, di, _ff(inv_div)]
			code += "float w_%d = tech3_wave(%d, %s, %s, %s, %s + off_%d, %s);\n" % [
				di, wave, _clk(def), _ff(vals[1] * scale), _ff(vals[2] * scale), _ff(vals[3]), di, _ff(vals[4])
			]
			code += "VERTEX += NORMAL * w_%d;\n" % di
			code += "}\n"
		elif kind == "move" and vals.size() >= 7:
			if def.billboard != 0:
				continue
			var mx := -vals[0] * scale
			var my := vals[2] * scale
			var mz := vals[1] * scale
			code += "VERTEX += vec3(%s, %s, %s) * tech3_wave(%d, %s, %s, %s, %s, %s);\n" % [
				_ff(mx), _ff(my), _ff(mz), wave, _clk(def), _ff(vals[3]), _ff(vals[4]), _ff(vals[5]), _ff(vals[6])
			]
		elif kind == "bulge" and vals.size() >= 3:
			code += "VERTEX += NORMAL * sin(UV.x * %s + %s * %s) * %s;\n" % [
				_ff(vals[0]), _clk(def), _ff(vals[2]), _ff(vals[1] * scale)
			]
		elif kind == "normal" and vals.size() >= 2:
			code += "VERTEX += NORMAL * sin(%s * %s) * %s;\n" % [_clk(def), _ff(vals[1]), _ff(vals[0] * scale)]

	if vs_uv_indices.size() > 0:
		var need_wp := false
		var need_env_vs := false
		for idx_uv2 in vs_uv_indices:
			var st_uv: StageDef = def.stages[idx_uv2]
			if st_uv.tc_gen == "environment":
				need_env_vs = true
			if st_uv.tc_gen == "vector":
				need_wp = true
			for m_uv in st_uv.tc_mods:
				if int(m_uv["type"]) == TCMOD_TURB:
					need_wp = true
		if need_wp or need_env_vs:
			code += "vec3 world_p = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;\n"
		if need_env_vs:
			code += "#if TECH3_ENV_PER_PIXEL\n"
			code += "#else\n"
			code += "vec3 world_n = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);\n"
			code += "vec2 env_uv = tech3_env_uv(world_p, world_n, INV_VIEW_MATRIX[3].xyz);\n"
			code += "#endif\n"
		for idx_uv3 in vs_uv_indices:
			var st_uv3: StageDef = def.stages[idx_uv3]
			if st_uv3.tc_gen == "environment":
				code += "#if TECH3_ENV_PER_PIXEL\n"
				code += "v_uv_%d = UV;\n" % idx_uv3
				code += "#else\n"
				code += "v_uv_%d = env_uv;\n" % idx_uv3
				code += _emit_tcmods(def, st_uv3, idx_uv3, "v_uv_%d" % idx_uv3)
				code += "#endif\n"
			else:
				code += "v_uv_%d = %s;\n" % [idx_uv3, _emit_uv(def, st_uv3, idx_uv3)]
				code += _emit_tcmods(def, st_uv3, idx_uv3, "v_uv_%d" % idx_uv3)

	if _pass_polygon_offset_bias(def, additive, translucent, depth_write):
		var us := maxf(_unit_scale, 0.0001)
		code += "{\n"
		code += "float po_dist = length((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);\n"
		code += "float po_t = smoothstep(%s, %s, po_dist);\n" % [
			_ff(POLYGON_OFFSET_NEAR_DIST / us), _ff(POLYGON_OFFSET_FAR_DIST / us)
		]
		code += "VERTEX += NORMAL * mix(%s, %s, po_t);\n" % [
			_ff(POLYGON_OFFSET_NEAR / us), _ff(POLYGON_OFFSET_FAR / us)
		]
		code += "}\n"

	if want_comp_uv:
		code += "{\n"
		var comp_st := _companion_stage(def)
		if comp_st != null and comp_st.tc_gen == "environment":
			# Companion maps (_norm/_glow/etc.) follow the color stage UV.
			# env_uv is only declared above for stages in vs_uv_indices
			# declare it here when the companion stage itself is environment.
			code += "vec3 world_p = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;\n"
			code += "vec3 world_n = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);\n"
			code += "vec2 env_uv = tech3_env_uv(world_p, world_n, INV_VIEW_MATRIX[3].xyz);\n"
		elif _companion_has_turb(def):
			code += "vec3 world_p = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;\n"
		code += _emit_companion_uv(def).replace("vec2 t3_comp_uv", "t3_comp_uv")
		code += "}\n"

	code += "}\n\n"
	code = code.replace("void vertex() {\n}\n\n", "")

# Fragment
	code += "void fragment() {\n"
	if def.offset_mode > 0 or want_height:
		code += "vec2 t3_off = vec2(0.0);\n"
	if def.offset_mode > 0:
		code += "#if OFFSET_MAPPING\n"
		code += "if (tech3_has_offset > 0.5) {\n"
		code += "t3_off = tech3_parallax(offset_texture, t3_comp_uv, v_eye_ts, %s, %s, dFdx(t3_comp_uv), dFdy(t3_comp_uv));\n" % [_ff(def.offset_scale * 0.02), _ff(def.offset_bias)]
		code += "}\n"
		code += "#endif\n"
	if want_height:
		code += "if (tech3_has_height > 0.5 && length(TANGENT) > 0.5) {\n"
		code += "vec2 texel = 1.0 / vec2(textureSize(normal_texture, 0));\n"
		code += "float h = texture(normal_texture, t3_comp_uv).r;\n"
		code += "float hx = texture(normal_texture, t3_comp_uv + vec2(texel.x, 0.0)).r;\n"
		code += "float hy = texture(normal_texture, t3_comp_uv + vec2(0.0, texel.y)).r;\n"
		code += "vec3 hn = normalize(vec3((h - hx) * 4.0, (h - hy) * 4.0, 1.0));\n"
		code += "NORMAL = normalize(TANGENT * hn.x + BINORMAL * hn.y + NORMAL * hn.z);\n"
		code += "#if OFFSET_MAPPING\n"
		code += "t3_off = normalize(v_eye_ts).xy * vec2(-1.0, 1.0) * 0.004 * (0.5 - h);\n"
		code += "#endif\n"
		code += "}\n"
	if want_normal:
		code += "if (tech3_has_normal > 0.5) {\n"
		code += "vec3 tn = texture(normal_texture, %s).rgb * 2.0 - 1.0;\n" % ("t3_comp_uv + t3_off" if def.offset_mode > 0 or want_height else "t3_comp_uv")
		code += "tn.z = sqrt(max(1.0 - dot(tn.xy, tn.xy), 0.0));\n"
		code += "if (length(TANGENT) > 0.5) NORMAL = normalize(TANGENT * tn.x + BINORMAL * tn.y + NORMAL * tn.z);\n"
		code += "}\n"
	if want_gloss:
		var g_uv := "t3_comp_uv + t3_off" if def.offset_mode > 0 or want_height else "t3_comp_uv"
		code += "float t3_gloss = tech3_gloss_intensity;\n"
		code += "if (tech3_has_gloss > 0.5) t3_gloss *= texture(gloss_texture, %s).r;\n" % g_uv
		code += "SPECULAR = clamp(t3_gloss, 0.0, 1.0);\n"
		code += "ROUGHNESS = clamp((1.0 - SPECULAR) / max(tech3_gloss_exponent, 1.0), 0.04, 1.0);\n"
	if need_time and def.clamp_time > 0.0:
		code += "float t3t = mod(tech3_time, %s);\n" % _ff(def.clamp_time)
	code += "vec4 accum = vec4(0.0, 0.0, 0.0, 1.0);\n"
	code += "vec4 black = vec4(0.0);\n"
	code += "vec4 white = vec4(1.0);\n"

	if def.is_sky:
		code += "vec3 sky_world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;\n"
		code += "vec3 sky_dir = normalize(sky_world - INV_VIEW_MATRIX[3].xyz);\n"
		var need_sky_uv := false
		for idx_sk in stage_indices:
			var st_sk: StageDef = def.stages[idx_sk]
			if st_sk.is_farbox:
				continue
			if st_sk.maps.size() > 0 or st_sk.is_whiteimage:
				need_sky_uv = true
				break
		if need_sky_uv:
			code += _emit_tech3_sky_uv(def)
		if _sky_farbox(def) != "":
			code += "accum = texture(sky_cubemap, sky_dir);\n"

	if needs_env:
		code += "#if TECH3_ENV_PER_PIXEL\n"
		code += "vec3 world_n = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);\n"
		code += "vec3 world_p_env = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;\n"
		code += "vec2 env_uv = tech3_env_uv(world_p_env, world_n, INV_VIEW_MATRIX[3].xyz);\n"
		code += "#endif\n"

	var frag_needs_world_pos := false
	for idx_wp in stage_indices:
		var st_wp: StageDef = def.stages[idx_wp]
		if _stage_uses_interpolated_uv(st_wp) and st_wp.tc_gen != "environment":
			continue
		if st_wp.tc_gen == "vector":
			frag_needs_world_pos = true
		for m_wp in st_wp.tc_mods:
			if int(m_wp["type"]) == TCMOD_TURB:
				frag_needs_world_pos = true
	if frag_needs_world_pos:
		code += "vec3 world_p = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;\n"

	var first_color_stage := true
	var has_folded_add_pre := false
	var has_folded_add_post := false
	var has_folded_mod := false
	var has_style_lm := false
	var seen_base := false
	
	for idx0 in stage_indices:
		var st0: StageDef = def.stages[idx0]
		if _stage_is_lighting_lightmap(st0):
			continue
		if _stage_is_style_lightmap(st0):
			has_style_lm = true
			continue
		if not seen_base:
			seen_base = true
			continue
		# Pull ADD off a non-ADD base so light() can hit the replace.
		# An ADD-first pass (flame saw + invsaw crossfade) stays in accum.
		if fold_add and _stage_is_add_blend(st0) and not later_alpha:
			if _add_before_lightmap(def, idx0):
				has_folded_add_pre = true
			else:
				has_folded_add_post = true
		elif fold_add and _stage_is_modulate(st0):
			has_folded_mod = true
	if has_folded_add_pre:
		code += "vec3 add_lit = vec3(0.0);\n"
	if has_folded_add_post:
		code += "vec3 add_glow = vec3(0.0);\n"
	if has_folded_mod:
		code += "vec3 fold_mul = vec3(1.0);\n"
	if has_style_lm:
		code += "vec3 style_lm = vec3(0.0);\n"
	
	for si in stage_indices.size():
		var idx: int = stage_indices[si]
		var st: StageDef = def.stages[idx]
		if st.is_farbox:
			continue
		var op := _stage_opcode(st)
		if op == "LM_LIGHT":
			if first_color == null:
				if multiplicative:
					if not _lm_atlas_ready:
						_warn_shader(def.name, "$lightmap has no atlas; filter pass is white")
						code += "accum = vec4(1.0);\n"
					else:
						# Solo FILTER $lightmap pass: dest * lm against the framebuffer.
						code += "{\n"
						code += _emit_lm_sum_glsl()
						code += "accum = vec4(lm_sum, 1.0);\n"
						code += "}\n"
				else:
					# No blendFunc: GLS_DEFAULT replace. Diffuse is white;
					# light() samples the atlas. No atlas is whiteimage.
					if not _lm_atlas_ready:
						_warn_shader(def.name, "$lightmap has no atlas; stage is white")
					code += "accum = vec4(1.0);\n"
			elif unshaded:
				# nolightmap / no atlas: $lightmap is whiteimage, filter is a no-op.
				if use_lm:
					code += "{\n"
					code += _emit_lm_sum_glsl()
					code += "accum.rgb *= lm_sum;\n"
					code += "}\n"
				# Shaded pass: LM_LIGHT stays in light().
			continue
		if _stage_is_diffuse_after_lm_replace(def, idx):
			# Sequence LM_REPLACE then FILTER of the same diffuse: light()
			# already did dest*lm. Sampling the map again squares RGB.
			continue
		if op == "LM_STYLE":
			code += _emit_style_sample(def, st, idx)
			code += _emit_stage_gen(def, st, idx, use_lm, true, def.is_sky)
			code += "style_lm += stage_%d.rgb * stage_%d.a;\n" % [idx, idx]
			continue
		code += _emit_stage_sample(def, st, idx)
		code += _emit_stage_gen(def, st, idx, use_lm, additive or unshaded, def.is_sky)
		var keep_under := (not first_color_stage) and st.alpha_func != ALPHA_NONE
		if keep_under:
			# Later alphaFunc skips this layer only.
			code += _emit_alpha_keep_under(st, idx)
			code += _emit_stage_blend(st, idx, false, not translucent and not additive, preserve_accum_alpha)
			code += "}\n"
		else:
			code += _emit_alpha_func(st, idx)
			if (has_folded_add_pre or has_folded_add_post) and not first_color_stage and op == "ADD":
				# ADD is src * srcFactor. Fold off accum so $lightmap in
				# light() hits the base; post-lm ADD is EMISSION.
				var src_f := "1.0"
				if st.blend.size() > 0:
					src_f = _blend_factor_rgb(st.blend[0], idx)
				if _add_before_lightmap(def, idx):
					code += "add_lit += stage_%d.rgb * (%s);\n" % [idx, src_f]
				else:
					code += "add_glow += stage_%d.rgb * (%s);\n" % [idx, src_f]
			elif not first_color_stage and op == "DETAIL":
				code += "accum.rgb *= stage_%d.rgb * 2.0;\n" % idx
			elif has_folded_mod and not first_color_stage and op == "FILTER":
				code += "fold_mul *= stage_%d.rgb;\n" % idx
				has_folded_mod = true
			else:
				code += _emit_stage_blend(st, idx, first_color_stage, not translucent and not additive, preserve_accum_alpha)
		if st.glow:
			# Raven glow: extra bloom buffer. Skip if this ADD already went to add_glow / add_lit.
			var folded_glow := (has_folded_add_pre or has_folded_add_post) \
					and not first_color_stage and op == "ADD"
			if not folded_glow:
				code += "EMISSION += stage_%d.rgb * stage_%d.a;\n" % [idx, idx]
		first_color_stage = false
	if has_folded_mod:
		code += "accum.rgb *= fold_mul;\n"
		if has_folded_add_pre:
			code += "add_lit *= fold_mul;\n"
		if has_folded_add_post:
			code += "add_glow *= fold_mul;\n"

	if multiplicative and not modulate_invert:
		code += "accum = max(accum, black);\n"
	else:
		code += "accum = clamp(accum, black, white);\n"

	code += "vec3 albedo = accum.rgb;\n"
	if first_color != null and _stage_is_detail_modulate(first_color) and multiplicative:
		code += "albedo *= 2.0;\n"
	# GL_DST_COLOR GL_ONE = dest * src + dest = dest * (1 + src).
	# blend_mul of src alone was dest*src.
	elif first_color != null and _stage_is_dstcolor_one(first_color) and multiplicative:
		code += "ALBEDO = textureLod(t3_fb, SCREEN_UV, 0.0).rgb * albedo;\n"

	if first_color == null or not (_stage_is_dstcolor_one(first_color) and multiplicative):
		if multiplicative and modulate_invert:
			code += "ALBEDO = vec3(1.0) - albedo;\n"
		else:
			code += "ALBEDO = albedo;\n"
			if def.reflect_rgba.w > 0.0:
				code += "vec2 ruv = SCREEN_UV + (NORMAL.xy) * %s;\n" % _ff(def.reflect_distort)
				code += "vec3 refl = textureLod(t3_fb, ruv, 0.0).rgb * vec3(%s, %s, %s);\n" % [_ff(def.reflect_rgba.x), _ff(def.reflect_rgba.y), _ff(def.reflect_rgba.z)]
				code += "ALBEDO = mix(ALBEDO, refl, %s);\n" % _ff(def.reflect_rgba.w)
			if def.refract_on:
				code += "vec2 water_n = NORMAL.xy;\n"
				code += "vec2 safe_uv = SCREEN_UV;\n"
				code += "vec2 refr_uv = clamp(safe_uv + water_n * 0.08, vec2(0.001), vec2(0.999));\n"
				code += "vec3 refr = textureLod(t3_fb, refr_uv, 0.0).rgb * vec3(%s, %s, %s);\n" % [_ff(def.refract_rgb.x), _ff(def.refract_rgb.y), _ff(def.refract_rgb.z)]
				code += "ALBEDO = mix(ALBEDO, refr, %s);\n" % _ff(def.refract_alpha)
			if def.reflect_cube != "":
				code += "vec3 cube_n = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);\n"
				code += "vec3 cube_v = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);\n"
				code += "vec3 cube_r = reflect(-cube_v, cube_n);\n"
				code += "cube_r = vec3(-cube_r.x, cube_r.z, cube_r.y);\n"
				code += "if (tech3_has_cube > 0.5 && tech3_has_reflect > 0.5) {\n"
				code += "float cube_m = texture(reflect_mask, %s).r;\n" % _off_uv(def)
				code += "ALBEDO += texture(reflect_cube, cube_r).rgb * clamp(cube_m, 0.0, 1.0);\n"
				code += "}\n"
			if want_glow:
				code += "if (tech3_has_glow > 0.5) EMISSION += texture(glow_texture, %s).rgb;\n" % ("t3_comp_uv + t3_off" if def.offset_mode > 0 or want_height else "t3_comp_uv")
	# ADD is dest+src. Unshaded blend_add composites ALBEDO only
	# Pure additive (no lightmap) still needs the emission write.
	# Additive-before-$lightmap (e.g. glass) stays in ALBEDO so
	# light() multiplies it by the lightmap, matching Q3.
	if additive and not unshaded and not use_lm:
		code += "EMISSION += albedo;\n"
	# Split ADD + later GE128: this ADD pass is dest+src.
	if additive and not cutout:
		var hole_i := _def_any_cutout_index(def)
		if hole_i >= 0:
			var hst: StageDef = def.stages[hole_i]
			if not stage_indices.has(hole_i):
				code += _emit_stage_sample(def, hst, hole_i)
				code += _emit_stage_gen(def, hst, hole_i, use_lm, true, def.is_sky)
			code += "if (%s) {\n" % _alpha_func_pass_expr(hst, hole_i)
			code += "ALBEDO = vec3(0.0);\n"
			code += "EMISSION = vec3(0.0);\n"
			code += "}\n"
	# Q3 add-before-$lightmap is filtered by the lightmap to ALBEDO.
	# Add-after-$lightmap (or no lm) is a fullbright overlay to EMISSION.
	if has_folded_add_pre:
		code += "ALBEDO += add_lit;\n"
	# $lightmap GL_DST_COLOR * lm is light(). Extra dest factor is
	# dest * dstFactor. GL_ONE_MINUS_DST_ALPHA is dest*(1-dest.a) in the
	# 8-bit Q3 framebuffer. Emitting ALBEDO*(1-a) as Godot EMISSION
	# veils coverage maps. Holes already show the
	# under-stage through the blend. Skip dest-alpha extras.
	if lm_remain != "" and use_lm and not unshaded:
		if lm_remain == "(1.0 - accum.a)" or lm_remain == "accum.a":
			pass
		else:
			code += "EMISSION += ALBEDO * %s;\n" % lm_remain
	if has_folded_add_post:
		if unshaded:
			code += "ALBEDO += add_glow;\n"
		else:
			code += "EMISSION += add_glow;\n"
	if has_style_lm:
		# (base_lm + style_lm * tech3_style_rgb(N) * alpha) * albedo.
		# ALBEDO * DIFFUSE_LIGHT + EMISSION.
		# depthFunc equal (q3map_styleMarker2): only where alphatest wrote depth.
		# Godot has no depth_func_equal; mask by the cutout stage instead.
		var cidx := _def_cutout_index(def)
		if cidx >= 0:
			var cst: StageDef = def.stages[cidx]
			if not stage_indices.has(cidx):
				code += _emit_stage_sample(def, cst, cidx)
				code += _emit_stage_gen(def, cst, cidx, use_lm, true, def.is_sky)
			code += "if (!(%s)) { style_lm = vec3(0.0); }\n" % _alpha_func_pass_expr(cst, cidx)
		code += "style_lm = max(style_lm, vec3(0.0));\n"
		if unshaded:
			code += "ALBEDO += albedo * style_lm;\n"
		else:
			code += "EMISSION += ALBEDO * style_lm;\n"
	# q3map_lightimage is a q3map2 bake hint. Runtime EMISSION only when
	# that map is an under-stage punched through a later alpha cover
	# Never ALBEDO * surfacelight (makes some surfaces fullbright)
	var li_idx := -1
	if first_pass and not additive and def.tech3_lightimage != "" and def.tech3_surfacelight > 0.0:
		for idx_li in stage_indices:
			if _stage_maps_lightimage(def, def.stages[idx_li]):
				if not _stage_is_add_blend(def.stages[idx_li]):
					li_idx = idx_li
				break
	if li_idx >= 0 and cover_idx >= 0 and cover_idx != li_idx and cover_count >= 1:
		code += "EMISSION += stage_%d.rgb * (1.0 - stage_%d.a);\n" % [li_idx, cover_idx]

	if translucent:
		if p.first_op == "BOOST":
			code += "ALPHA = 1.0;\n"
		else:
			code += "ALPHA = accum.a;\n"

	code += "}\n"

	if (use_lm or vertex_lit) and not unshaded:
		code += "\nvoid light() {\n"
		code += "vec3 geom_l = normalize((VIEW_MATRIX * vec4(v_geom_n, 0.0)).xyz);\n"
		code += "bool tech3_lm_pass = LIGHT_IS_DIRECTIONAL && LIGHT_COLOR == vec3(0.0);\n"
		code += "if (tech3_lm_pass) {\n"
		if use_lm and _lm_atlas_ready:
			code += _emit_lm_sum_glsl()
			code += _emit_deluxe_modulate_glsl(def)
			if vertex_lit:
				code += "if (lm_cell.z + lm_cell.w < 0.000001) {\n"
				code += "DIFFUSE_LIGHT = vert_color.rgb * tech3_style_rgb(lm_styles.r * 255.0) * ATTENUATION;\n"
				code += "} else {\n"
				code += "DIFFUSE_LIGHT = lm_sum * ATTENUATION;\n"
				code += "}\n"
			else:
				code += "DIFFUSE_LIGHT = lm_sum * ATTENUATION;\n"
		elif vertex_lit:
			code += "DIFFUSE_LIGHT = vert_color.rgb * ATTENUATION;\n"
		code += "} else {\n"
		if def.cull == CULL_DISABLED:
			code += "DIFFUSE_LIGHT += abs(dot(NORMAL, LIGHT)) * ATTENUATION * LIGHT_COLOR;\n"
		else:
			code += "if (dot(geom_l, LIGHT) > 0.0) {\n"
			code += "DIFFUSE_LIGHT += max(dot(NORMAL, LIGHT), 0.0) * ATTENUATION * LIGHT_COLOR;\n"
			if want_gloss:
				code += _emit_gloss_spec_glsl(def)
			code += "}\n"
		code += "}\n"
		code += "}\n"

	return _format_glsl(code)


func _format_glsl(src: String) -> String:
	# Re-indent generated GLSL so function bodies and blocks use tabs.
	# Preprocessor lines stay at column 0. Brace depth drives the indent.
	var out := ""
	var depth := 0
	var lines := src.split("\n")
	for raw in lines:
		var line := raw.strip_edges()
		if line == "":
			out += "\n"
			continue
		if line.begins_with("#"):
			out += line + "\n"
			continue
		var close_first := line.begins_with("}")
		var d := depth
		if close_first:
			d = maxi(depth - 1, 0)
		var indent := ""
		for _i in d:
			indent += "\t"
		out += indent + line + "\n"
		# Update depth after the line is written.
		var opens := line.count("{")
		var closes := line.count("}")
		depth = maxi(depth + opens - closes, 0)
	return out


func _emit_deform_moves_glsl(def: ShaderDef, scale: float, dest_var: String) -> String:
	var code := ""
	for di in def.deform_vertexes.size():
		var d: Dictionary = def.deform_vertexes[di]
		if String(d.get("kind", "")) != "move":
			continue
		var vals: PackedFloat32Array = d.get("values", PackedFloat32Array())
		if vals.size() < 7:
			continue
		var wave: int = int(d.get("wave", WAVE_SIN))
		var mx := -vals[0] * scale
		var my := vals[2] * scale
		var mz := vals[1] * scale
		code += "%s += vec3(%s, %s, %s) * tech3_wave(%d, %s, %s, %s, %s, %s);\n" % [
			dest_var, _ff(mx), _ff(my), _ff(mz), wave, _clk(def),
			_ff(vals[3]), _ff(vals[4]), _ff(vals[5]), _ff(vals[6])
		]
	return code


func _emit_style_weight_helper() -> String:
	# Raven multiplies lightmap / stage RGB by the style's RGB weight.
	# A scalar style writes the same value into every channel.
	var code := "\nvec3 tech3_style_rgb(float s255) {\n"
	code += "if (s255 > 254.5) {\n"
	code += "return vec3(0.0);\n"
	code += "}\n"
	code += "if (s255 < 0.5) {\n"
	code += "return vec3(1.0);\n"
	code += "}\n"
	code += "return texture(tech3_style_weights, vec2((s255 + 0.5) / 64.0, 0.5)).rgb;\n"
	code += "}\n"
	return code


func _warn_shader(shader_name: String, message: String) -> void:
	var line := "%s: %s" % [shader_name, message]
	if _shader_warnings.has(line):
		return
	_shader_warnings[line] = true
	push_warning("tech3bsp_shaders: " + line)
	print("tech3bsp_shaders: ", line)


# Four style pages. Only call this after the atlas uniform and lm_* varyings exist.
func _wants_gloss(def: ShaderDef) -> bool:
	return def.gloss_intensity != 1.0 or def.gloss_exponent != 1.0 or (companion_flags & 2) != 0


func _emit_deluxe_modulate_glsl(def: ShaderDef) -> String:
	if not _emit_deluxe:
		return ""

	var code := ""
	
	if deluxe_modelspace:
		code += "vec3 l_w = normalize(texture(deluxemap_texture, uv_lm0).rgb * 2.0 - 1.0);\n"
		code += "vec3 n_w = normalize(v_geom_n);\n"
		code += "vec3 t_w = v_tangent;\n"
		code += "vec3 b_w = v_binormal;\n"
		code += "vec3 l_ts = normalize(vec3(dot(l_w, t_w), dot(l_w, b_w), dot(l_w, n_w)));\n"
		code += "vec3 lm_base = lm_sum * (1.0 / max(0.25, l_ts.z));\n"
	else:
		code += "vec3 dx = texture(deluxemap_texture, uv_lm0).rgb * 2.0 - 1.0;\n"
		code += "vec3 n_gd = normalize(v_geom_n);\n"
		code += "vec3 n_q3 = vec3(-n_gd.x, n_gd.z, n_gd.y);\n"
		code += "float flat_z = step(abs(n_q3.x) + abs(n_q3.y), 0.0001);\n"
		code += "vec3 t_axis = normalize(cross(n_q3, vec3(0.0, 0.0, 1.0)) + flat_z * vec3(1.0, 0.0, 0.0));\n"
		code += "vec3 b_axis = normalize(cross(t_axis, n_q3));\n"
		code += "float flip_t = step(0.0, n_q3.x) + step(n_q3.y, 0.0) + step(n_q3.z, 0.0);\n"
		code += "t_axis = mix(t_axis, -t_axis, step(0.5, flip_t));\n"
		code += "vec3 l_q3 = normalize(t_axis * dx.x + b_axis * dx.y + n_q3 * dx.z);\n"
		code += "vec3 l_w = -normalize(vec3(-l_q3.x, l_q3.z, l_q3.y));\n"
		code += "float baked = max(dot(n_gd, l_w), 0.0);\n"
		code += "vec3 lm_base = lm_sum * (1.0 / max(0.25, baked));\n"
	code += "vec3 l_view = normalize((VIEW_MATRIX * vec4(l_w, 0.0)).xyz);\n"
	code += "float ndotl = max(dot(normalize(NORMAL), l_view), 0.0);\n"
	code += "lm_sum = clamp(lm_base * max(ndotl, 0.35), 0.0, 4.0);\n"
	
	if _wants_gloss(def):
		code += _light_gloss_uv(def)
		code += "float gloss = texture(gloss_texture, %s).r * tech3_gloss_intensity;\n" % _gloss_uv(def)
		code += "vec3 spec_h = normalize(l_view + VIEW);\n"
		var exp := "16.0" if deluxe_modelspace else "8.0"
		code += "float spec = pow(max(dot(normalize(NORMAL), spec_h), 0.0), %s * tech3_gloss_exponent);\n" % exp
		code += "SPECULAR_LIGHT += spec * gloss * lm_base * ATTENUATION;\n"
	
	return code



func _light_gloss_uv(def: ShaderDef) -> String:
	if def.offset_mode <= 0:
		return ""
	return "vec2 v_eye_off = vec2(0.0);\n#if OFFSET_MAPPING\nif (tech3_has_offset > 0.5) v_eye_off = tech3_parallax(offset_texture, t3_comp_uv, v_eye_ts, %s, %s, dFdx(t3_comp_uv), dFdy(t3_comp_uv));\n#endif\n" % [_ff(def.offset_scale * 0.02), _ff(def.offset_bias)]


func _companion_stage(def: ShaderDef) -> StageDef:
	for st in def.stages:
		if st.is_lightmap or st.is_whiteimage or st.is_blackimage or st.maps.is_empty():
			continue
		var map := str(st.maps[0])
		if map != "" and not map.begins_with("$"):
			return st
	return null


func _emit_companion_uv(def: ShaderDef) -> String:
	var st := _companion_stage(def)
	if st == null:
		return "vec2 t3_comp_uv = UV;\n"
	var idx := def.stages.find(st)
	var code := "vec2 t3_comp_uv = %s;\n" % _emit_uv(def, st, idx)
	code += _emit_tcmods(def, st, idx, "t3_comp_uv")
	return code


func _companion_needs_time(def: ShaderDef) -> bool:
	var st := _companion_stage(def)
	if st == null:
		return false
	for m in st.tc_mods:
		var mt := int(m["type"])
		if mt == TCMOD_ROTATE or mt == TCMOD_SCROLL or mt == TCMOD_TURB or mt == TCMOD_STRETCH:
			return true
	return false


func _companion_needs_rotate(def: ShaderDef) -> bool:
	var st := _companion_stage(def)
	if st == null:
		return false
	for m in st.tc_mods:
		if int(m["type"]) == TCMOD_ROTATE:
			return true
	return false


func _companion_has_turb(def: ShaderDef) -> bool:
	var st := _companion_stage(def)
	if st == null:
		return false
	for m in st.tc_mods:
		if int(m["type"]) == TCMOD_TURB:
			return true
	return false


func _companion_has_stretch(def: ShaderDef) -> bool:
	var st := _companion_stage(def)
	if st == null:
		return false
	for m in st.tc_mods:
		if int(m["type"]) == TCMOD_STRETCH:
			return true
	return false


func _uv_offset_on(def: ShaderDef) -> bool:
	# _norm alpha offset, or a _bump height map when no _norm
	return def.offset_mode > 0 or ((companion_flags & 8) != 0 and (companion_flags & 1) == 0)


func _off_uv(def: ShaderDef) -> String:
	return "t3_comp_uv + t3_off" if _uv_offset_on(def) else "t3_comp_uv"


func _gloss_uv(def: ShaderDef) -> String:
	if def.offset_mode <= 0:
		return "t3_comp_uv"
	return "t3_comp_uv + v_eye_off"


func _emit_gloss_spec_glsl(def: ShaderDef) -> String:
	var code := "if (tech3_has_gloss > 0.5) {\n"
	code += _light_gloss_uv(def)
	code += "float gloss = texture(gloss_texture, %s).r * tech3_gloss_intensity;\n" % _gloss_uv(def)

	code += "vec3 h = normalize(LIGHT + VIEW);\n"
	code += "SPECULAR_LIGHT += pow(max(dot(NORMAL, h), 0.0), 32.0 * tech3_gloss_exponent) * gloss * ATTENUATION * LIGHT_COLOR;\n"
	code += "}\n"
	return code


func _emit_lm_sum_glsl() -> String:
	var code := "vec2 uv_lm0 = lm_cell.xy + UV2 * lm_cell.zw;\n"
	code += "vec3 lm_sum = texture(lightmap_texture, uv_lm0).rgb * tech3_style_rgb(lm_styles.r * 255.0);\n"
	code += "lm_sum += texture(lightmap_texture, lm_uv_a.xy).rgb * tech3_style_rgb(lm_styles.g * 255.0);\n"
	code += "lm_sum += texture(lightmap_texture, lm_uv_a.zw).rgb * tech3_style_rgb(lm_styles.b * 255.0);\n"
	code += "lm_sum += texture(lightmap_texture, lm_uv_b.xy).rgb * tech3_style_rgb(lm_styles.a * 255.0);\n"
	return code


func _emit_style_sample(def: ShaderDef, st: StageDef, idx: int) -> String:
	# UV2 is 0-1 on the 128 page. lm_cell places that page in the atlas.
	var code := "vec2 uv_%d = UV2;\n" % idx
	code += _emit_tcmods(def, st, idx)
	var explicit := st.maps.size() > 0 and not st.is_lightmap and has_texture(st.maps[0])
	if explicit:
		code += "vec4 stage_%d = texture(%s, uv_%d);\n" % [idx, _stage_sampler_name(idx, 0), idx]
	elif st.is_lightmap and not _lm_atlas_ready:
		_warn_shader(def.name, "$lightmap has no atlas; style stage is black")
		code += "vec4 stage_%d = vec4(0.0);\n" % idx
	elif st.is_lightmap:
		# $lightmap + tcMod offset: same image as style 0. Re-atlas only
		# when the offset stays inside the page. Stacked 0.5-V pages stay
		# in unwrapped UV (external 128×256 files).
		code += "vec2 slm_%d = uv_%d;\n" % [idx, idx]
		code += "if ((lm_cell.z < 0.999 || lm_cell.w < 0.999) && uv_%d.x >= 0.0 && uv_%d.x <= 1.0 && uv_%d.y >= 0.0 && uv_%d.y <= 1.0) {\n" % [idx, idx, idx, idx]
		code += "slm_%d = lm_cell.xy + uv_%d * lm_cell.zw;\n" % [idx, idx]
		code += "}\n"
		code += "vec4 stage_%d = texture(lightmap_texture, slm_%d);\n" % [idx, idx]
	else:
		code += "vec4 stage_%d = vec4(0.0);\n" % idx
	return code


func _emit_env_uv_helper() -> String:
	var code := "vec2 tech3_env_uv(vec3 world_p, vec3 world_n, vec3 camera_pos) {\n"
	code += "vec3 world_viewer = normalize(camera_pos - world_p);\n"
	code += "vec3 world_r = world_n * (2.0 * dot(world_n, world_viewer)) - world_viewer;\n"
	code += "return vec2(0.5 + world_r.z * 0.5, 0.5 - world_r.y * 0.5);\n"
	code += "}\n\n"
	return code


func _stage_uses_interpolated_uv(st: StageDef) -> bool:
	if st.is_farbox:
		return false
	if st.tc_gen == "environment" or st.tc_gen == "vector":
		return true
	if st.is_lightmap or _stage_is_style_lightmap(st):
		return false
	return not st.tc_mods.is_empty()


func _emit_stage_sample(def: ShaderDef, st: StageDef, idx: int) -> String:
	var interpolated := (not def.is_sky) and _stage_uses_interpolated_uv(st)
	var code := ""
	if interpolated and st.tc_gen == "environment":
		code += "#if TECH3_ENV_PER_PIXEL\n"
		code += "vec2 uv_%d = env_uv;\n" % idx
		code += _emit_tcmods(def, st, idx)
		code += "#else\n"
		code += "vec2 uv_%d = v_uv_%d;\n" % [idx, idx]
		code += "#endif\n"
	elif interpolated:
		code += "vec2 uv_%d = v_uv_%d%s;\n" % [idx, idx, " + t3_off" if _uv_offset_on(def) and not st.is_lightmap else ""]
	else:
		var off := ""
		if _uv_offset_on(def) and not st.is_lightmap:
			off = " + t3_off"
		code += "vec2 uv_%d = %s%s;\n" % [idx, _emit_uv(def, st, idx), off]
		code += _emit_tcmods(def, st, idx)
	if st.is_lightmap and not _lm_atlas_ready:
		_warn_shader(def.name, "$lightmap has no atlas; stage is white")
		code += "vec4 stage_%d = vec4(1.0);\n" % idx
	elif st.is_lightmap:
		if st.tc_gen not in ["base", "lightmap"]:
			code += "vec2 lm_uv_%d = lm_cell.xy + fract(uv_%d) * lm_cell.zw;\n" % [idx, idx]
			code += "vec4 stage_%d = texture(lightmap_texture, lm_uv_%d);\n" % [idx, idx]
		else:
			code += "vec4 stage_%d = texture(lightmap_texture, uv_%d);\n" % [idx, idx]
	elif st.is_whiteimage:
		code += "vec4 stage_%d = vec4(1.0);\n" % idx
	elif st.is_blackimage:
		code += "vec4 stage_%d = vec4(0.0, 0.0, 0.0, 1.0);\n" % idx
	elif st.maps.size() > 0 and _named_color_glsl(st.maps[0]) != "" and not has_texture(st.maps[0]):
		code += "vec4 stage_%d = %s;\n" % [idx, _named_color_glsl(st.maps[0])]
	elif st.source == SRC_ANIMMAP and st.maps.size() > 0:
		var nframes := st.maps.size()
		if st.anim_oneshot:
			code += "int fr_%d = anim_frame_override >= 0 ? min(anim_frame_override, %d) : int(min(%s * stage_%d_anim_fps, float(%d)));\n" % [
				idx, maxi(nframes - 1, 0), _clk(def), idx, maxi(nframes - 1, 0)
			]
		else:
			code += "int fr_%d = anim_frame_override >= 0 ? (anim_frame_override %% %d) : int(mod(%s * stage_%d_anim_fps, float(%d)));\n" % [
				idx, nframes, _clk(def), idx, nframes
			]
		if not has_texture(st.maps[0]):
			code += "vec4 stage_%d = vec4(1.0);\n" % idx
		else:
			code += "vec4 stage_%d = texture(tex_stage_%d_frame_0, uv_%d);\n" % [idx, idx, idx]
		for f in range(1, st.maps.size()):
			if not has_texture(st.maps[f]):
				code += "if (fr_%d == %d) { stage_%d = vec4(1.0); }\n" % [idx, f, idx]
			else:
				code += "if (fr_%d == %d) { stage_%d = texture(tex_stage_%d_frame_%d, uv_%d); }\n" % [
					idx, f, idx, idx, f, idx
				]
	elif st.maps.size() > 0 and has_texture(st.maps[0]):
		code += "vec4 stage_%d = texture(%s, uv_%d);\n" % [idx, _stage_sampler_name(idx, 0), idx]
	else:
		code += "vec4 stage_%d = vec4(1.0);\n" % idx
	return code


func _emit_uv(def: ShaderDef, st: StageDef, idx: int) -> String:
	if def.is_sky:
		return "sky_uv"
	match st.tc_gen:
		"lightmap":
			return "UV2"
		"environment":
			return "env_uv"
		"vector":
			return "vec2(dot(world_p, vec3(%s, %s, %s)), dot(world_p, vec3(%s, %s, %s)))" % [
				_ff(-st.tc_gen_s.x), _ff(st.tc_gen_s.z), _ff(st.tc_gen_s.y),
				_ff(-st.tc_gen_t.x), _ff(st.tc_gen_t.z), _ff(st.tc_gen_t.y)
			]
		_:
			if st.is_lightmap:
				return "UV2"
			return "UV"


func _emit_tech3_sky_uv(def: ShaderDef) -> String:
	var height := 512.0
	if def.skyparms.size() > 1 and _is_number(def.skyparms[1]):
		height = maxf(_to_float(def.skyparms[1]), 1.0)
	var sc := maxf(_unit_scale, 0.0001)
	var r := 4096.0 / sc
	var h := height / sc
	var code := ""
	code += "vec3 tech3d = vec3(-sky_dir.x, sky_dir.z, sky_dir.y);\n"
	code += "float sky_r = %s;\n" % _ff(r)
	code += "float sky_h = %s;\n" % _ff(h)
	code += "float sky_d2 = max(dot(tech3d, tech3d), 0.0001);\n"
	code += "float sky_inner = tech3d.z * tech3d.z * sky_r * sky_r + sky_d2 * sky_h * (2.0 * sky_r + sky_h);\n"
	code += "float sky_p = (1.0 / (2.0 * sky_d2)) * (-2.0 * tech3d.z * sky_r + 2.0 * sqrt(max(sky_inner, 0.0)));\n"
	code += "vec3 sky_hit = tech3d * sky_p;\n"
	code += "sky_hit.z += sky_r;\n"
	code += "sky_hit = normalize(sky_hit);\n"
	code += "vec2 sky_uv = vec2(acos(clamp(sky_hit.x, -1.0, 1.0)), acos(clamp(sky_hit.y, -1.0, 1.0)));\n"
	return code


func _emit_tcmods(def: ShaderDef, st: StageDef, idx: int, uv_var: String = "") -> String:
	if def.no_tc:
		return ""
	var uv := uv_var if uv_var != "" else ("uv_%d" % idx)
	var code := ""
	for m in st.tc_mods:
		var t: int = int(m["type"])
		var v: PackedFloat32Array = m["values"]
		match t:
			TCMOD_ROTATE:
				# q3 degs = -degsPerSecond * shaderTime
				var deg := v[0] if v.size() > 0 else 0.0
				code += "%s = tech3_rotate(%s, vec2(0.5), radians(%s) * -%s);\n" % [uv, uv, _ff(deg), _clk(def)]
			TCMOD_SCALE:
				var sx := v[0] if v.size() > 0 else 1.0
				var sy := v[1] if v.size() > 1 else 1.0
				code += "%s *= vec2(%s, %s);\n" % [uv, _ff(sx), _ff(sy)]
			TCMOD_SCROLL:
				var ss := v[0] if v.size() > 0 else 0.0
				var stt := v[1] if v.size() > 1 else 0.0
				code += "%s += vec2(%s, %s) * %s;\n" % [uv, _ff(ss), _ff(stt), _clk(def)]
			TCMOD_STRETCH:
				var base := v[0] if v.size() > 0 else 1.0
				var amp := v[1] if v.size() > 1 else 0.0
				var phase := v[2] if v.size() > 2 else 0.0
				var freq := v[3] if v.size() > 3 else 1.0
				var wave: int = int(m.get("wave", WAVE_SIN))
				code += "{\n		float str_%d = 1.0 / max(tech3_wave(%d, %s, %s, %s, %s, %s), 0.001);\n" % [
					idx, wave, _clk(def), _ff(base), _ff(amp), _ff(phase), _ff(freq)
				]
				code += "%s = %s * str_%d - vec2(0.5) * str_%d + vec2(0.5);\n	}\n" % [uv, uv, idx, idx]
			TCMOD_TRANSFORM:
				if v.size() >= 6:
					code += "%s = vec2(%s.x * %s + %s.y * %s + %s, %s.x * %s + %s.y * %s + %s);\n" % [
						uv,
						uv, _ff(v[0]), uv, _ff(v[2]), _ff(v[4]),
						uv, _ff(v[1]), uv, _ff(v[3]), _ff(v[5])
					]
			TCMOD_TURB:
				var amp2 := v[1] if v.size() > 1 else (v[0] if v.size() > 0 else 0.0)
				var phase2 := v[2] if v.size() > 2 else 0.0
				var freq2 := v[3] if v.size() > 3 else 1.0
				var us := maxf(_unit_scale, 0.0001)
				code += "{\n"
				code += "float now_%d = %s + %s * %s;\n" % [idx, _ff(phase2), _clk(def), _ff(freq2)]
				code += "vec3 tech3p_%d = vec3(-world_p.x, world_p.z, world_p.y) * %s;\n" % [idx, _ff(us)]
				code += "float k_%d = 0.0009765625;\n" % idx
				code += "%s.x += sin(((tech3p_%d.x + tech3p_%d.z) * k_%d + now_%d) * 6.28318530718) * %s;\n" % [
					uv, idx, idx, idx, idx, _ff(amp2)
				]
				code += "%s.y += sin((tech3p_%d.y * k_%d + now_%d) * 6.28318530718) * %s;\n" % [
					uv, idx, idx, idx, _ff(amp2)
				]
				code += "}\n"
			TCMOD_ENTITYTRANSLATE:
				# Q3/Raven: scroll UVs by entity origin. World brushes sit at
				# identity so this is a no-op there; models pick up NODE origin.
				code += "%s += vec2(MODEL_MATRIX[3].x, MODEL_MATRIX[3].z) * 0.002;\n" % uv
	return code


func _emit_stage_gen(def: ShaderDef, st: StageDef, idx: int, use_lm: bool = false, tint_vertex_in_frag: bool = false, for_sky: bool = false) -> String:
	var code := ""
	var rgb := st.rgb_gen
	if _stage_uses_table_style(st):
		code += "stage_%d.rgb *= tech3_style_rgb(%s);\n" % [idx, _ff(float(st.style_index))]
	elif rgb.size() == 0:
		pass
	elif rgb[0] == "WAVE" and rgb.size() >= 6:
		code += "stage_%d.rgb *= clamp(tech3_wave(%d, %s, %s, %s, %s, %s), 0.0, 1.0);\n" % [
			idx, _wave_func(rgb[1]), _clk(def), _ff(_to_float(rgb[2])), _ff(_to_float(rgb[3])),
			_ff(_to_float(rgb[4])), _ff(_to_float(rgb[5]))
		]
	elif rgb[0] == "VERTEX" or rgb[0] == "EXACTVERTEX":
		if use_lm or tint_vertex_in_frag:
			code += "stage_%d.rgb *= COLOR.rgb;\n" % idx
	elif rgb[0] == "CONST" and rgb.size() >= 4:
		code += "stage_%d.rgb *= vec3(%s, %s, %s);\n" % [
			idx, _ff(_to_float(rgb[1])), _ff(_to_float(rgb[2])), _ff(_to_float(rgb[3]))
		]
	elif rgb[0] == "ENTITY" or rgb[0] == "LIGHTINGDIFFUSE" or rgb[0] == "LIGHTINGDIFFUSEENTITY":
		code += "stage_%d.rgb *= COLOR.rgb;\n" % idx
	elif rgb[0] == "ONEMINUSENTITY" or rgb[0] == "ONEMINUSVERTEX":
		code += "stage_%d.rgb *= (vec3(1.0) - COLOR.rgb);\n" % idx
	elif rgb[0] == "IDENTITYLIGHTING":
		pass

	var ag := st.alpha_gen
	if ag.size() == 0:
		pass
	elif ag[0] == "WAVE" and ag.size() >= 6:
		code += "stage_%d.a *= tech3_wave(%d, %s, %s, %s, %s, %s);\n" % [
			idx, _wave_func(ag[1]), _clk(def), _ff(_to_float(ag[2])), _ff(_to_float(ag[3])),
			_ff(_to_float(ag[4])), _ff(_to_float(ag[5]))
		]
	elif ag[0] == "VERTEX" or ag[0] == "ENTITY":
		# q3 vertex color alpha modulates the texture (GL_MODULATE)
		code += "stage_%d.a *= COLOR.a;\n" % idx
	elif ag[0] == "ONEMINUSVERTEX" or ag[0] == "ONEMINUSENTITY":
		code += "stage_%d.a *= (1.0 - COLOR.a);\n" % idx
	elif ag[0] == "CONST" and ag.size() >= 2:
		# AGEN_CONST is the GL vertex alpha, texture env still modulates.
		code += "stage_%d.a *= %s;\n" % [idx, _ff(_to_float(ag[1]))]
	elif ag[0] == "PORTAL" and ag.size() >= 2:
		var rng := _to_float(ag[1]) * (1.0 / maxf(_unit_scale, 0.0001))
		code += "stage_%d.a *= clamp(length(VERTEX) / max(%s, 0.001), 0.0, 1.0);\n" % [idx, _ff(rng)]
	elif ag[0] == "DOT":
		code += "stage_%d.a *= clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);\n" % idx
	elif ag[0] == "ONEMINUSDOT":
		code += "stage_%d.a *= (1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0));\n" % idx
	elif ag[0] == "LIGHTINGSPECULAR":
		# Specular lives in alpha in Q3. Replacing alpha with 1 paints the
		# whole card. Keep the map alpha and modulate it by the spec term.
		code += "{\n"
		code += "vec3 spec_n = normalize(NORMAL);\n"
		code += "vec3 spec_v = normalize(VIEW);\n"
		code += "float spec_%d = pow(max(dot(spec_n, spec_v), 0.0), 16.0);\n" % idx
		code += "float tex_a_%d = stage_%d.a;\n" % [idx, idx]
		code += "stage_%d.rgb += stage_%d.rgb * spec_%d * 0.5;\n" % [idx, idx, idx]
		code += "stage_%d.a = tex_a_%d * spec_%d;\n" % [idx, idx, idx]
		code += "}\n"
	return code


func _emit_alpha_keep_under(st: StageDef, idx: int) -> String:
	match st.alpha_func:
		ALPHA_GT0:
			return "	if (stage_%d.a != 0.0) {\n" % idx
		ALPHA_LT128:
			return "	if (stage_%d.a < 0.5) {\n" % idx
		ALPHA_GE128:
			return "	if (stage_%d.a >= 0.5) {\n" % idx
		ALPHA_GE192:
			return "	if (stage_%d.a >= 0.753) {\n" % idx
		_:
			return ""


func _emit_alpha_func(st: StageDef, idx: int) -> String:
	match st.alpha_func:
		ALPHA_GT0:
			return "	if (stage_%d.a == 0.0) { discard; }\n" % idx
		ALPHA_LT128:
			return "	if (stage_%d.a >= 0.5) { discard; }\n" % idx
		ALPHA_GE128:
			return "	if (stage_%d.a < 0.5) { discard; }\n" % idx
		ALPHA_GE192:
			return "	if (stage_%d.a < 0.753) { discard; }\n" % idx
		_:
			return ""


func _emit_stage_blend(st: StageDef, idx: int, is_first: bool, opaque_out: bool, preserve_alpha: bool = false) -> String:
	var force_a_one := opaque_out and not preserve_alpha
	var rgb_only := "	accum.a = 1.0;\n" if force_a_one else ""
	if st.blend.is_empty():
		if force_a_one or not (_stage_is_alpha_blend(st) or _stage_uses_src_alpha_as_dest(st) \
				or st.alpha_func != ALPHA_NONE):
			return "	accum = vec4(stage_%d.rgb, 1.0);\n" % idx
		return "	accum = stage_%d;\n" % idx
	var src := st.blend[0] if st.blend.size() > 0 else "GL_ONE"
	var dst := st.blend[1] if st.blend.size() > 1 else "GL_ZERO"

	if is_first and _stage_is_dstcolor_one(st):
		return "	accum = vec4(1.0 + stage_%d.rgb, 1.0);\n" % idx
	if is_first:
		# First draw against empty dest. ADD still uses srcFactor
		# (flame: GL_SRC_ALPHA GL_ONE * alphaGen sawtooth).
		if _stage_is_add_blend(st):
			var src_first := "1.0"
			if st.blend.size() > 0:
				src_first = _blend_factor_rgb(src, idx)
			# Water keeps the stage alpha (alphaGen vertex)
			var a_first := "stage_%d.a" % idx if st.alpha_gen.size() > 0 else "1.0"
			return "	accum = vec4(stage_%d.rgb * (%s), %s);\n" % [idx, src_first, a_first]
		# Opaque replace seeds dest.a = 1. Undermaps often have
		# unused TGA a=0, keeping that makes ONE_MINUS_DST_ALPHA emit
		# ALBEDO*(1-a) across the whole quad (white veil + grey holes).
		if _stage_is_alpha_blend(st) or _stage_uses_src_alpha_as_dest(st) \
				or st.alpha_func != ALPHA_NONE:
			return "	accum = stage_%d;\n" % idx
		return "	accum = vec4(stage_%d.rgb, 1.0);\n" % idx
	var csrc := _blend_factor_rgb(src, idx)
	var cdst := _blend_factor_rgb(dst, idx)
	var code := "accum.rgb = stage_%d.rgb * (%s) + accum.rgb * (%s);\n" % [idx, csrc, cdst]
	# Later dest-color / filter stages run against the framebuffer in Q3.
	# Folded into one pass they must not rewrite coverage - GL_DST_COLOR GL_ONE
	# with a=1 turns a 0.5 water surface into ALPHA 1.
	var keep_alpha := _stage_is_dstcolor_one(st) or _stage_is_modulate(st) \
			or _stage_is_inv_modulate(st) or _stage_is_detail(st) \
			or _stage_is_add_blend(st)
	if force_a_one:
		code += rgb_only
	elif not keep_alpha:
		var asrc := _blend_factor_a(src, idx)
		var adst := _blend_factor_a(dst, idx)
		code += "accum.a = stage_%d.a * (%s) + accum.a * (%s);\n" % [idx, asrc, adst]
	return code


func _blend_factor_rgb(factor: String, idx: int) -> String:
	match factor:
		"GL_ONE":
			return "1.0"
		"GL_ZERO":
			return "0.0"
		"GL_DST_COLOR":
			return "accum.rgb"
		"GL_ONE_MINUS_DST_COLOR":
			return "(1.0 - accum.rgb)"
		"GL_SRC_COLOR":
			return "stage_%d.rgb" % idx
		"GL_ONE_MINUS_SRC_COLOR":
			return "(1.0 - stage_%d.rgb)" % idx
		"GL_SRC_ALPHA":
			return "stage_%d.a" % idx
		"GL_ONE_MINUS_SRC_ALPHA":
			return "(1.0 - stage_%d.a)" % idx
		"GL_DST_ALPHA":
			return "accum.a"
		"GL_ONE_MINUS_DST_ALPHA":
			return "(1.0 - accum.a)"
		"GL_SRC_ALPHA_SATURATE":
			return "min(stage_%d.a, 1.0 - accum.a)" % idx
		_:
			return "1.0"


func _blend_factor_a(factor: String, idx: int) -> String:
	match factor:
		"GL_ONE":
			return "1.0"
		"GL_ZERO":
			return "0.0"
		"GL_DST_COLOR", "GL_DST_ALPHA":
			return "accum.a"
		"GL_ONE_MINUS_DST_COLOR", "GL_ONE_MINUS_DST_ALPHA":
			return "(1.0 - accum.a)"
		"GL_SRC_COLOR", "GL_SRC_ALPHA":
			return "stage_%d.a" % idx
		"GL_ONE_MINUS_SRC_COLOR", "GL_ONE_MINUS_SRC_ALPHA":
			return "(1.0 - stage_%d.a)" % idx
		"GL_SRC_ALPHA_SATURATE":
			return "1.0"
		_:
			return "1.0"


func _stage_is_inv_modulate(st: StageDef) -> bool:
	return st.blend.size() >= 2 and st.blend[0] == "GL_ZERO" and st.blend[1] == "GL_ONE_MINUS_SRC_COLOR"


func _stage_is_modulate(st: StageDef) -> bool:
	if st.blend.size() < 2:
		return false
	# dest * src. After an add this must be its own blend_mul pass
	# $lightmap + filter still joins the opaque group in _plan_passes
	if st.blend[0] == "GL_ZERO" and st.blend[1] == "GL_SRC_COLOR":
		return true
	if st.blend[0] == "GL_DST_COLOR" and st.blend[1] == "GL_ZERO":
		return true
	return false


func _stage_is_dstcolor_one(st: StageDef) -> bool:
	return st.blend.size() >= 2 and st.blend[0] == "GL_DST_COLOR" and st.blend[1] == "GL_ONE"


func _stage_is_add_blend(st: StageDef) -> bool:
	if st.blend.size() == 1:
		return st.blend[0] == "GL_ONE" or st.blend[0] == "ADD"
	if st.blend.size() < 2:
		return false
	# dest * src + dest * 1 is not additive.
	if _stage_is_dstcolor_one(st):
		return false
	# GL_ONE GL_ONE_MINUS_SRC_COLOR: src + dest*(1-src). Black RGB is
	# invisible (JA autosprite lights). Treat as additive so we don't
	# blend_mix a solid black quad.
	if st.blend[0] == "GL_ONE" and st.blend[1] == "GL_ONE_MINUS_SRC_COLOR":
		return true
	# dest GL_ONE is Q3 additive only when src does not read the dest
	# (particles, glows, GL_SRC_ALPHA GL_ONE). GL_ONE_MINUS_DST_ALPHA GL_ONE
	# is masked chrome: src * (1 - dst.a) + dst. Folding that into add_lit
	# paints the env over the whole mesh.
	if st.blend[1] != "GL_ONE":
		return false
	match st.blend[0]:
		"GL_ONE", "GL_SRC_ALPHA", "GL_SRC_COLOR", \
		"GL_ONE_MINUS_SRC_ALPHA", "GL_ONE_MINUS_SRC_COLOR":
			return true
		_:
			return false


func _stage_is_alpha_blend(st: StageDef) -> bool:
	if st.blend.size() < 2:
		return false
	return st.blend[0] == "GL_SRC_ALPHA" and st.blend[1] == "GL_ONE_MINUS_SRC_ALPHA"


func _stage_uses_src_alpha_as_dest(st: StageDef) -> bool:
	# dest * src.a (JK2 control_ff_on: GL_ONE GL_SRC_ALPHA) or dest * (1-src.a).
	# Prior filter/add is the screen fx, this stage's alpha is the hole mask.
	if st.blend.size() < 2:
		return false
	return st.blend[1] == "GL_SRC_ALPHA" or st.blend[1] == "GL_ONE_MINUS_SRC_ALPHA"


func _stage_uses_src_alpha(st: StageDef) -> bool:
	for f in st.blend:
		if f == "GL_SRC_ALPHA" or f == "GL_ONE_MINUS_SRC_ALPHA":
			return true
	return st.alpha_func != ALPHA_NONE


func _stage_uses_dst_alpha_factor(st: StageDef) -> bool:
	# GL_DST_ALPHA / GL_ONE_MINUS_DST_ALPHA read the previous stage's alpha
	# (e.g. chapthroatooz lightmap: DST_COLOR * lm + dest * (1 - dest.a)).
	for f in st.blend:
		if f == "GL_DST_ALPHA" or f == "GL_ONE_MINUS_DST_ALPHA":
			return true
	return false


func _lm_dest_remainder_factor(st: StageDef) -> String:
	# light() already does dest * lm when src is GL_DST_COLOR. The dest
	# factor is the extra term dest * dstFactor that filter (ZERO) has not.
	if st.blend.size() < 2:
		return ""
	if st.blend[0] != "GL_DST_COLOR":
		return ""
	match st.blend[1]:
		"GL_ZERO":
			return ""
		"GL_ONE":
			return "1.0"
		"GL_ONE_MINUS_DST_ALPHA":
			return "(1.0 - accum.a)"
		"GL_DST_ALPHA":
			return "accum.a"
		"GL_ONE_MINUS_DST_COLOR":
			return "(1.0 - accum.rgb)"
		"GL_DST_COLOR":
			return "accum.rgb"
		_:
			return ""


func _stage_sampler_name(stage_idx: int, map_idx: int) -> String:
	if map_idx == 0:
		return "tex_stage_%d" % stage_idx
	return "tex_stage_%d_%d" % [stage_idx, map_idx]


# ---
# Texture binding / saving
# ---

func _apply_textures(mat: ShaderMaterial, def: ShaderDef, lightmap_texture: Texture, stage_indices: Array = [], use_lm: bool = false) -> void:
	var indices: Array = stage_indices if stage_indices.size() > 0 else range(def.stages.size())
	var need_cutout := false
	for ii in indices:
		if _stage_is_style_lightmap(def.stages[ii]) or _stage_is_add_blend(def.stages[ii]):
			need_cutout = true
			break
	if need_cutout:
		var ci := _def_any_cutout_index(def)
		if ci >= 0 and not indices.has(ci):
			indices.append(ci)
	var cube := _sky_cubemap(def)
	if cube:
		mat.set_shader_parameter("sky_cubemap", cube)
	if use_lm and lightmap_texture:
		mat.set_shader_parameter("lightmap_texture", lightmap_texture)

	for i in indices:
		var st: StageDef = def.stages[i]
		if st.is_lightmap or st.is_whiteimage or st.is_blackimage or st.is_farbox:
			continue
		if st.maps.size() > 0 and _named_color_glsl(st.maps[0]) != "" and not has_texture(st.maps[0]):
			continue
		if st.source == SRC_ANIMMAP:
			for f in st.maps.size():
				var fr := resolve_texture(st.maps[f])
				if fr:
					mat.set_shader_parameter("tex_stage_%d_frame_%d" % [i, f], fr)
			continue
		if st.maps.is_empty():
			continue
		var tex := resolve_texture(st.maps[0])
		if tex:
			mat.set_shader_parameter(_stage_sampler_name(i, 0), tex)

	if def.editor_image != "" and def.stages.is_empty():
		mat.set_shader_parameter("tex_stage_0", resolve_texture(def.editor_image))


func _sky_farbox(def: ShaderDef) -> String:
	if !def or not def.is_sky or def.skyparms.is_empty():
		return ""
	var fb := String(def.skyparms[0]).strip_edges()
	if fb == "" or fb == "-":
		return ""
	return fb


func _sky_cubemap_from_prefix(prefix: String) -> Cubemap:
	if prefix == "":
		return null
	if _sky_cubes.has(prefix):
		return _sky_cubes[prefix]
	var clean := prefix.replace("\\", "/")
	for ext in IMAGE_EXTENSIONS:
		var dot := ".%s" % ext
		if clean.to_lower().ends_with(dot):
			clean = clean.substr(0, clean.length() - dot.length())
			break
	var base := clean.get_file()
	var stems: PackedStringArray = [clean]
	if not clean.begins_with("env/"):
		stems.append("env/%s" % base)
	var sides := [
		["ft", "front"],
		["bk", "back"],
		["lf", "left"],
		["rt", "right"],
		["up", "up"],
		["dn", "down"],
	]
	var faces: Array[Texture2D] = []
	for pair in sides:
		var tex: Texture2D = null
		for stem in stems:
			for suf in pair:
				tex = resolve_texture("%s_%s" % [stem, suf])
				if !tex:
					tex = resolve_texture("%s%s" % [stem, suf])
				if tex:
					break
			if tex:
				break
		faces.append(tex)
	var loaded := 0
	for t in faces:
		if t:
			loaded += 1
	if loaded == 0:
		_sky_cubes[prefix] = null
		return null
	var order := [2, 3, 4, 5, 1, 0]
	var size := 128
	for t in faces:
		if t:
			size = maxi(size, t.get_width())
	var imgs: Array[Image] = []
	for oi in order:
		var img: Image = null
		if oi < faces.size() and faces[oi]:
			img = faces[oi].get_image()
			if img and img.is_compressed():
				img.decompress()
			if img:
				img = img.duplicate()
				if img.has_mipmaps():
					img.clear_mipmaps()
				if img.get_width() != size or img.get_height() != size:
					img.resize(size, size)
				if img.get_format() != Image.FORMAT_RGBA8:
					img.convert(Image.FORMAT_RGBA8)
				img.flip_x()
				if oi == 4:
					img.rotate_90(CLOCKWISE)
				elif oi == 5:
					img.rotate_90(CLOCKWISE)
					img.rotate_180()
		if !img:
			img = Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
			img.fill(Color(0, 0, 0))
		elif img.has_mipmaps():
			img.clear_mipmaps()
		imgs.append(img)
	var cube := Cubemap.new()
	cube.create_from_images(imgs)
	_sky_cubes[prefix] = cube
	return cube


func _sky_cubemap(def: ShaderDef) -> Cubemap:
	var fb := _sky_farbox(def)
	if fb == "":
		return null
	if _sky_cubes.has(fb):
		return _sky_cubes[fb]
	var prefix := fb.replace("\\", "/")
	for ext in IMAGE_EXTENSIONS:
		var dot := ".%s" % ext
		if prefix.to_lower().ends_with(dot):
			prefix = prefix.substr(0, prefix.length() - dot.length())
			break
	var base := prefix.get_file()
	var stems: PackedStringArray = [prefix]
	if not prefix.begins_with("env/"):
		stems.append("env/%s" % base)
	var sides := [
		["ft", "front"],
		["bk", "back"],
		["lf", "left"],
		["rt", "right"],
		["up", "up"],
		["dn", "down"],
	]
	var faces: Array[Texture2D] = []
	for pair in sides:
		var tex: Texture2D = null
		for stem in stems:
			for suf in pair:
				tex = resolve_texture("%s_%s" % [stem, suf])
				if !tex:
					tex = resolve_texture("%s%s" % [stem, suf])
				if tex:
					break
			if tex:
				break
		faces.append(tex)
	var loaded := 0
	for t in faces:
		if t:
			loaded += 1
	if loaded == 0:
		_sky_cubes[fb] = null
		return null

	var order := [2, 3, 4, 5, 1, 0] # lf rt up dn bk ft (+X -X +Y -Y +Z -Z)
	var size := 128
	for t in faces:
		if t:
			size = maxi(size, t.get_width())
	var imgs: Array[Image] = []
	for oi in order:
		var img: Image = null
		if oi < faces.size() and faces[oi]:
			img = faces[oi].get_image()
			if img and img.is_compressed():
				img.decompress()
			if img:
				img = img.duplicate()
				if img.has_mipmaps():
					img.clear_mipmaps()
				if img.get_width() != size or img.get_height() != size:
					img.resize(size, size)
				if img.get_format() != Image.FORMAT_RGBA8:
					img.convert(Image.FORMAT_RGBA8)
				# q3 env faces are mirrored vs Godot cubemap sampling
				img.flip_x()
				# after L/R swap, +Y/-Y (up/dn) sit 90deg off
				if oi == 4:
					img.rotate_90(CLOCKWISE)
				elif oi == 5:
					img.rotate_90(CLOCKWISE)
					img.rotate_180()
		if !img:
			img = Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
			img.fill(Color(0, 0, 0))
		elif img.has_mipmaps():
			img.clear_mipmaps()
		imgs.append(img)
	var cube := Cubemap.new()
	cube.create_from_images(imgs)
	_sky_cubes[fb] = cube
	return cube


func _named_color_glsl(map_path: String) -> String:
	# gfx/colors/*.tga and $blackimage / $whiteimage - 1×1 stubs.
	var cleaned := _strip_ext(map_path).replace("\\", "/").to_lower()
	if cleaned.begins_with("$"):
		return ""
	var base := cleaned.get_file()

	if not (cleaned.contains("gfx/colors") or cleaned.contains("/colors/")):
		return ""
	match base:
		"black":
			return "vec4(0.0, 0.0, 0.0, 1.0)"
		"white":
			return "vec4(1.0, 1.0, 1.0, 1.0)"
		"red":
			return "vec4(1.0, 0.0, 0.0, 1.0)"
		"green":
			return "vec4(0.0, 1.0, 0.0, 1.0)"
		"blue":
			return "vec4(0.0, 0.0, 1.0, 1.0)"
		"yellow":
			return "vec4(1.0, 1.0, 0.0, 1.0)"
		"cyan":
			return "vec4(0.0, 1.0, 1.0, 1.0)"
		"magenta":
			return "vec4(1.0, 0.0, 1.0, 1.0)"
		_:
			return ""


func _directory_map_lookup(cleaned: String) -> String:
	var hit := _directory_map_lookup_once(cleaned)
	if hit != "":
		return hit
	var key := cleaned.replace("\\", "/").to_lower()
	if key.begins_with("res://"):
		key = key.substr(6)
	# Xonotic / DP compressed copy. Same-folder hit above still wins.
	if key.begins_with("dds/"):
		return ""
	return _directory_map_lookup_once("dds/%s" % key)


func _directory_map_lookup_once(cleaned: String) -> String:
	if directory_map.is_empty():
		return ""
	var key := cleaned.replace("\\", "/").to_lower()
	if key.begins_with("res://"):
		key = key.substr(6)
	if directory_map.has(key):
		return String(directory_map[key])
	var assets := String(_assets_path).replace("\\", "/").trim_suffix("/")
	if assets.begins_with("res://"):
		assets = assets.substr(6)
	if assets != "" and key.begins_with(assets + "/"):
		var rel := key.substr(assets.length() + 1)
		if directory_map.has(rel):
			return String(directory_map[rel])
	return ""


func _texture_lookup_key(map_path: String) -> String:
	return _strip_ext(map_path).replace("\\", "/")


## True if the map path exists in res:// (directory_map) or a mounted PK3.
## Does not decode image bytes. Usage: lib.has_texture(stage.maps[0])
func has_texture(map_path: String) -> bool:
	var cleaned := _texture_lookup_key(map_path)
	if cleaned == "" or cleaned.begins_with("$"):
		return false
	if _tex_cache.has(cleaned):
		return _tex_cache[cleaned] != null
	if _has_cache.has(cleaned):
		return bool(_has_cache[cleaned])
	var found := Tech3Pk3.has_texture(cleaned)
	if not found:
		var mapped := _directory_map_lookup(cleaned)
		if mapped != "" and (ResourceLoader.exists(mapped) or FileAccess.file_exists(mapped)):
			found = true
	if not found:
		var seen: Dictionary = {}
		for stem in _image_search_stems(cleaned):
			var mapped2 := _directory_map_lookup(stem)
			if mapped2 != "" and (ResourceLoader.exists(mapped2) or FileAccess.file_exists(mapped2)):
				found = true
				break
			for ext in IMAGE_EXTENSIONS:
				for candidate in ["%s.%s" % [stem, ext], "%s.%s" % [stem.to_lower(), ext]]:
					if seen.has(candidate):
						continue
					seen[candidate] = true
					if FileAccess.file_exists(candidate) or ResourceLoader.exists(candidate):
						found = true
						break
				if found:
					break
			if found:
				break
	_has_cache[cleaned] = found
	return found


## Load a Texture2D for a shader map path from res:// or the PK3 VFS.
## Usage: mat.set_shader_parameter(uname, lib.resolve_texture(path))
func resolve_texture(map_path: String) -> Texture2D:
	var cleaned := _texture_lookup_key(map_path)
	if cleaned == "" or cleaned.begins_with("$"):
		return null
	if _tex_cache.has(cleaned):
		return _tex_cache[cleaned]

	var pack_tex := Tech3Pk3.resolve_texture(cleaned)
	if pack_tex:
		return _remember_texture(cleaned, pack_tex)
	var mapped := _directory_map_lookup(cleaned)
	if mapped != "":
		var mapped_res = load(mapped)
		if mapped_res is Texture2D:
			return _remember_texture(cleaned, mapped_res)

	var seen: Dictionary = {}
	for stem: String in _image_search_stems(cleaned):
		mapped = _directory_map_lookup(stem)
		if mapped != "":
			var mapped_res2 = load(mapped)
			if mapped_res2 is Texture2D:
				return _remember_texture(cleaned, mapped_res2)
		for ext in IMAGE_EXTENSIONS:
			for candidate in ["%s.%s" % [stem, ext], "%s.%s" % [stem.to_lower(), ext]]:
				if seen.has(candidate):
					continue
				seen[candidate] = true
				if FileAccess.file_exists(candidate):
					var res = load(candidate)
					if res is Texture2D:
						return _remember_texture(cleaned, res)
	return _remember_texture(cleaned, null)


func _remember_texture(cleaned: String, tex: Texture2D) -> Texture2D:
	_tex_cache[cleaned] = tex
	_has_cache[cleaned] = tex != null
	return tex


# Same-folder stems first, then dds/<stem> (Xonotic / DP). tga/png/jpg win.
func _image_search_stems(cleaned: String) -> PackedStringArray:
	var stems: PackedStringArray = []
	var bases: PackedStringArray = [cleaned]
	var rel := cleaned.replace("\\", "/").trim_prefix("/")
	if not rel.to_lower().begins_with("dds/"):
		bases.append("dds/%s" % rel)
	for base in bases:
		for prefix in _texture_prefixes():
			var stem: String = base if prefix == "" else prefix.path_join(base)
			if not stems.has(stem):
				stems.append(stem)
		if not stems.has(base):
			stems.append(base)
	return stems


func _texture_prefixes() -> PackedStringArray:
	var out: PackedStringArray = []
	for p in [_assets_path, "res://"]:
		var n := String(p).replace("\\", "/").strip_edges()
		if n.ends_with("/"):
			n = n.left(n.length() - 1)
		if n == "res:/":
			n = "res://"
		if n != "" and not out.has(n):
			out.append(n)
	return out


func _save_converted(def: ShaderDef, shader: Shader, mat: ShaderMaterial) -> void:
	var s_path := _expand_save_path(_converted_shader_path, def.name)
	var m_path := _expand_save_path(_converted_material_path, def.name)
	_ensure_dir(s_path.get_base_dir())
	_ensure_dir(m_path.get_base_dir())
	_save_resource_if_allowed(shader, s_path)
	_save_resource_if_allowed(mat, m_path)


func _save_resource_if_allowed(res: Resource, path: String) -> void:
	if FileAccess.file_exists(path) and not _overwrite_converted:
		return
	_ensure_dir(path.get_base_dir())
	var err := ResourceSaver.save(res, path)
	if err != OK:
		push_warning("tech3bsp_shaders: failed to save %s (%s)" % [path, error_string(err)])
		return
	res.take_over_path(path)
	if not generated_resource_paths.has(path):
		generated_resource_paths.append(path)


func _expand_save_path(pattern: String, shader_name: String) -> String:
	var safe := shader_name.replace("\\", "/").lstrip("/")
	var p := pattern.replace("{shader_name}", safe).replace("{texture_name}", safe)
	if not (p.begins_with("res://") or p.begins_with("user://") or p.begins_with("/")):
		p = "res://" + p.lstrip("/")
	return p


func _ensure_dir(path: String) -> void:
	if path == "" or DirAccess.dir_exists_absolute(path):
		return
	DirAccess.make_dir_recursive_absolute(path)


# ---
# Helpers
# ---

func _strip_ext(p: String) -> String:
	var s := p.strip_edges().replace("\\", "/")
	var ext := s.get_extension().to_lower()
	if ext in IMAGE_EXTENSIONS:
		return s.get_basename()
	return s


func _to_float(s: String) -> float:
	return s.strip_edges().to_float()


func _is_number(s: String) -> bool:
	var t := s.strip_edges()
	if t.is_valid_float():
		return true
	if t.begins_with("-") and t.substr(1).is_valid_float():
		return true
	return false


func _is_wave_name(s: String) -> bool:
	match s.to_lower():
		"sin", "sine", "square", "triangle", "sawtooth", "inversesawtooth", "noise":
			return true
		_:
			return false


func _wave_func(name: String) -> int:
	match name.to_lower():
		"square":
			return WAVE_SQUARE
		"triangle":
			return WAVE_TRIANGLE
		"sawtooth":
			return WAVE_SAWTOOTH
		"inversesawtooth", "inverse":
			return WAVE_INVERSESAWTOOTH
		"noise", "random":
			return WAVE_NOISE
		_:
			return WAVE_SIN


func _ff(v: float) -> String:
	return "%.6f" % v


func _clk(def: ShaderDef) -> String:
	return "t3t" if def.clamp_time > 0.0 else "tech3_time"
