@tool
class_name Tech3Pk3
extends RefCounted
# Runtime VFS for PK3 files (zip) from user://.
# Last mount wins on the *same* logical path (and same-stem extension
# fallback: .tga vs .jpg). Basename-only aliases do not cross folders:
# textures/foo/bar.tga must not replace
# textures/baz/bar.tga from an earlier pack.
# Xonotic and friends are the exception: a miss also tries dds/<stem>.dds.

# Packs are community maps and the textures / shaders / sounds they ship.
# Never instantiate Godot scenes or scripts from a pack.
# examples:
#	Tech3Pk3.mount_pk3("user://mods/mymaps.pk3")
#	var scene := Tech3Pk3.load_map("map01")
#	var music := Tech3Pk3.load_sound(scene.worldspawn.get("music", ""), true)
#	var sh := Tech3Pk3.load_shader("shaders/mymap/custom")

const FAMILY_IMAGE := "image"
const FAMILY_SOUND := "sound"
const FAMILY_MAP := "map"
const FAMILY_SHADER := "shader"
const FAMILY_GDSHADER := "gdshader"
const FAMILY_MATERIAL := "material"

const IMAGE_EXTENSIONS: PackedStringArray = [
	"tga", "png", "webp", "bmp", "jpg", "jpeg", "dds", "ktx", "exr", "hdr", "svg"
]
const SOUND_EXTENSIONS: PackedStringArray = ["wav", "ogg", "mp3"]
const MAP_EXTENSIONS: PackedStringArray = ["bsp"]
const SHADER_EXTENSIONS: PackedStringArray = ["shader"]
const GDSHADER_EXTENSIONS: PackedStringArray = ["gdshader", "gdshaderinc"]
const MATERIAL_EXTENSIONS: PackedStringArray = ["material"]
# When an image lookup is given a non-image ext, strip it and search stems.
const IMAGE_STRIP_EXTS: PackedStringArray = [
	"md3", "mdc", "ase", "obj", "mdr", "shader", "bsp"
]
# Packed scenes, scripts, and binary/text Godot resources that can embed
# a script stay out. .gdshader is source text. .material is indexed only.
const BLOCKED_EXTENSIONS: PackedStringArray = [
	"tscn", "scn", "escn", "gd", "gdc", "gdextension", "cs",
	"tres", "res", "godot", "import"
]

static var _stack: Array[Tech3Pk3] = [] # last = highest priority


var path: String = ""
var _zip: ZIPReader
var _index: Dictionary = {} # lowercase exact path -> inner zip path
var _alias: Dictionary = {} # family -> { stem/basename -> inner zip path }
var _files: PackedStringArray = PackedStringArray()
var _symlinks: Dictionary = {}


## Open a user:// zip and push it onto the VFS stack. Last mount wins.
## Usage: Tech3Pk3.mount_pk3("user://mods/mymaps.pk3")
static func mount_pk3(user_path: String) -> Tech3Pk3:
	var p := String(user_path).replace("\\", "/").strip_edges()
	if p.is_empty():
		push_error("tech3_pk3: empty path")
		return null
	if not p.begins_with("user://"):
		push_error("tech3_pk3: only user:// packs are supported (%s)" % p)
		return null
	if not FileAccess.file_exists(p):
		push_error("tech3_pk3: file not found: %s" % p)
		return null
	var pack := Tech3Pk3.new()
	if not pack._open(p):
		return null
	_stack.append(pack)
	_clear_lookup_caches()
	print("tech3_pk3: mounted %s (%d files)" % [p, pack._files.size()])
	return pack


## Remove one pack from the stack and close its ZIPReader.
## Usage: Tech3Pk3.unmount_pk3(pack)
static func unmount_pk3(pack: Tech3Pk3) -> void:
	if !pack:
		return
	_stack.erase(pack)
	pack._close()
	_clear_lookup_caches()


## Close every mounted pack and clear lookup caches.
## Usage: Tech3Pk3.unmount_all()
static func unmount_all() -> void:
	for pack in _stack:
		if pack:
			pack._close()
	_stack.clear()
	_clear_lookup_caches()


## Copy of the current mount stack (lowest priority first).
## Usage: for pack in Tech3Pk3.mounts(): ...
static func mounts() -> Array[Tech3Pk3]:
	return _stack.duplicate()


## Unmount this pack instance from the shared stack.
## Usage: pack.unmount()
func unmount() -> void:
	Tech3Pk3.unmount_pk3(self)


func _open(user_path: String) -> bool:
	_zip = ZIPReader.new()
	var err := _zip.open(user_path)
	if err != OK:
		push_error("tech3_pk3: cannot open %s (%s)" % [user_path, error_string(err)])
		_zip = null
		return false
	path = user_path
	_files = _zip.get_files()
	_symlinks = _scan_symlinks(user_path)
	_rebuild_index()
	return true


func _close() -> void:
	if _zip:
		_zip.close()
	_zip = null
	_index.clear()
	_alias.clear()
	_files = PackedStringArray()


## File extensions indexed for a VFS family (image, sound, map, shader, …).
## Usage: Tech3Pk3.family_extensions(Tech3Pk3.FAMILY_IMAGE)
static func family_extensions(family: String) -> PackedStringArray:
	match family:
		FAMILY_IMAGE:
			return IMAGE_EXTENSIONS
		FAMILY_SOUND:
			return SOUND_EXTENSIONS
		FAMILY_MAP:
			return MAP_EXTENSIONS
		FAMILY_SHADER:
			return SHADER_EXTENSIONS
		FAMILY_GDSHADER:
			return GDSHADER_EXTENSIONS
		FAMILY_MATERIAL:
			return MATERIAL_EXTENSIONS
		_:
			return PackedStringArray()


static func _family_for_ext(ext: String) -> String:
	var e := ext.to_lower()
	if e == "jpeg":
		e = "jpg"
	if e in IMAGE_EXTENSIONS:
		return FAMILY_IMAGE
	if e in SOUND_EXTENSIONS:
		return FAMILY_SOUND
	if e in MAP_EXTENSIONS:
		return FAMILY_MAP
	if e in SHADER_EXTENSIONS:
		return FAMILY_SHADER
	if e in GDSHADER_EXTENSIONS:
		return FAMILY_GDSHADER
	if e in MATERIAL_EXTENSIONS:
		return FAMILY_MATERIAL
	return ""


static func _is_blocked_path(path: String) -> bool:
	var ext := path.replace("\\", "/").get_extension().to_lower()
	return ext in BLOCKED_EXTENSIONS


func _rebuild_index() -> void:
	_index.clear()
	_alias.clear()
	_alias[FAMILY_IMAGE] = {}
	_alias[FAMILY_SOUND] = {}
	_alias[FAMILY_MAP] = {}
	_alias[FAMILY_SHADER] = {}
	_alias[FAMILY_GDSHADER] = {}
	_alias[FAMILY_MATERIAL] = {}
	for inner in _files:
		# Keep the zip's own entry string. ZIPReader.read_file() is exact.
		# Windows-packed PK3s often store backslashes.
		var raw := String(inner)
		var n := raw.replace("\\", "/")
		if n.ends_with("/"):
			continue
		var lower := n.to_lower()
		if _is_blocked_path(lower):
			continue
		_index[lower] = raw
		var fam := _family_for_ext(lower.get_extension())
		if fam == "":
			continue
		# Same-stem aliases for extension-optional lookup
		# (textures/base_door/foo.tga to/from foo.jpg). Basename-only keys are
		# for lookups that have no directory (maps/q3dm1, bare "hum.wav").
		_add_alias(fam, lower.get_basename(), raw)
		if lower.get_base_dir() == "":
			_add_alias(fam, lower.get_file(), raw)
			_add_alias(fam, lower.get_file().get_basename(), raw)


func _add_alias(family: String, key: String, raw: String) -> void:
	if key == "" or not _alias.has(family):
		return
	var bucket: Dictionary = _alias[family]
	if not bucket.has(key):
		bucket[key] = raw


static func _norm(logical: String) -> String:
	var s := logical.replace("\\", "/").strip_edges().to_lower()
	while s.begins_with("/"):
		s = s.substr(1)
	if s.begins_with("res://"):
		s = s.substr(6)
	if s.begins_with("user://"):
		s = s.substr(7)
	return s


func _ext_in_family(path: String, family: String) -> bool:
	if family == "":
		return true
	var ext := path.replace("\\", "/").get_extension().to_lower()
	if ext == "jpeg":
		ext = "jpg"
	return ext in family_extensions(family)


func _stem_for(key: String, family: String) -> String:
	var ext := key.get_extension()
	if ext == "":
		return key
	if ext in family_extensions(family):
		return key.get_basename()
	if family == FAMILY_IMAGE and ext in IMAGE_STRIP_EXTS:
		return key.get_basename()
	return key


func _is_companion_image(path: String) -> bool:
	var stem := path.get_file().get_basename().to_lower()
	return stem.ends_with("_norm") or stem.ends_with("_bump") or stem.ends_with("_gloss") or stem.ends_with("_glow") or stem.ends_with("_reflect") or stem.ends_with("_height")


func _alias_get(family: String, key: String) -> String:
	if family == "" or key == "" or not _alias.has(family):
		return ""
	var bucket: Dictionary = _alias[family]
	if bucket.has(key):
		return String(bucket[key])
	return ""


# Exact path only. Use locate() when the caller omitted an extension.
func _inner_for(logical: String) -> String:
	var key := _norm(logical)
	if key == "" or not _index.has(key):
		return ""
	return String(_index[key])


## Inner zip path for a logical name, optionally restricted to a family.
## Usage: var inner := pack.locate("textures/base_wall/concrete", Tech3Pk3.FAMILY_IMAGE)
func locate(logical: String, family: String = "") -> String:
	var key := _norm(logical)
	if key == "":
		return ""
	if _index.has(key):
		var exact := String(_index[key])
		if family == "" or _ext_in_family(exact, family):
			return exact
	if family == "":
		return ""
	var stem := _stem_for(key, family)
	for e in family_extensions(family):
		var with_ext := "%s.%s" % [stem, e]
		if _index.has(with_ext) and (_is_companion_image(stem) or not _is_companion_image(with_ext)):
			return String(_index[with_ext])

	if family == FAMILY_IMAGE and not stem.begins_with("dds/"):
		var dds_key := "dds/%s.dds" % stem
		if _index.has(dds_key):
			return String(_index[dds_key])

	if key.get_base_dir() != "" or stem.get_base_dir() != "":
		return ""
	var aliased := _alias_get(family, key)
	if aliased != "":
		return aliased
	aliased = _alias_get(family, stem)
	if aliased != "":
		return aliased
	aliased = _alias_get(family, key.get_file())
	if aliased != "":
		return aliased
	return _alias_get(family, stem.get_file())


## True if this pack contains the exact normalized path (any family).
## Usage: if pack.has("maps/q3dm1.bsp")
func has(logical: String) -> bool:
	return _inner_for(logical) != ""


## True if this pack contains the logical path in the given family.
## Usage: pack.has_file("music/fla", Tech3Pk3.FAMILY_SOUND)
func has_file(logical: String, family: String = "") -> bool:
	return locate(logical, family) != ""


## Raw bytes for an exact path in this pack, or empty if missing.
## Usage: var data := pack.read_bytes("maps/q3dm1.bsp")
func read_bytes(logical: String) -> PackedByteArray:
	return read_entry(_inner_for(logical))


## Raw bytes resolved through family aliases (extension-optional lookup).
## Usage: pack.read_family("sound/world/hum", Tech3Pk3.FAMILY_SOUND)
func read_family(logical: String, family: String) -> PackedByteArray:
	return read_entry(locate(logical, family))


## Read a zip entry by its exact inner path (the string locate() returns).
## Usage: pack.read_entry(inner)
func read_entry(inner: String) -> PackedByteArray:
	return _read_entry(inner, 8)


func _read_entry(inner: String, hops: int) -> PackedByteArray:
	if inner == "" or !_zip:
		return PackedByteArray()
	if _is_blocked_path(inner):
		push_error("tech3_pk3: refused Godot scene/script '%s' in %s" % [inner, path])
		return PackedByteArray()
	var data := _zip.read_file(inner)
	var key := inner.replace("\\", "/").to_lower()

	if not _symlinks.has(key) and not _payload_is_link(key, data):
		return data
	if hops <= 0:
		push_warning("tech3_pk3: symlink '%s' in %s nested too deep" % [inner, path])
		return PackedByteArray()
	var target := _resolve_symlink(key, data.get_string_from_ascii())
	if target == "":
		push_warning("tech3_pk3: symlink '%s' in %s has an empty target" % [inner, path])
		return PackedByteArray()
	var linked := _inner_for(target)
	if linked == "":
		push_warning("tech3_pk3: symlink '%s' -> '%s' missing in %s" % [inner, target, path])
		return PackedByteArray()
	return _read_entry(linked, hops - 1)


# Special in-zip symlink handling (Xonotic / DP)
func _scan_symlinks(user_path: String) -> Dictionary:
	var out := {}
	var f := FileAccess.open(user_path, FileAccess.READ)
	if !f:
		return out
	var size := f.get_length()
	var tail := mini(size, 65536 + 22)
	f.seek(size - tail)
	var end := f.get_buffer(tail)
	var found := -1
	for i in range(end.size() - 22, -1, -1):
		if end[i] == 0x50 and end[i + 1] == 0x4b and end[i + 2] == 0x05 and end[i + 3] == 0x06:
			found = i
			break
	if found < 0:
		return out
	var cd_off := end.decode_u32(found + 16)
	var cd_size := end.decode_u32(found + 12)
	if cd_off < 0 or cd_size <= 0 or cd_off + cd_size > size:
		return out
	f.seek(cd_off)
	var cd := f.get_buffer(cd_size)
	var pos := 0
	while pos + 46 <= cd.size():
		if cd[pos] != 0x50 or cd[pos + 1] != 0x4b or cd[pos + 2] != 0x01 or cd[pos + 3] != 0x02:
			break
		var made_by := cd.decode_u16(pos + 4)
		var name_len := cd.decode_u16(pos + 28)
		var extra_len := cd.decode_u16(pos + 30)
		var comment_len := cd.decode_u16(pos + 32)
		var attr := cd.decode_u32(pos + 38)
		var host := made_by >> 8
		if host in [2, 3, 16] and ((attr >> 16) & 0xF000) == 0xA000 and pos + 46 + name_len <= cd.size():
			var name := cd.slice(pos + 46, pos + 46 + name_len).get_string_from_utf8().replace("\\", "/").to_lower()
			if name != "":
				out[name] = true
		pos += 46 + name_len + extra_len + comment_len
	return out


func _payload_is_link(key: String, data: PackedByteArray) -> bool:
	var ext := key.get_extension()
	if ext not in ["dds", "tga", "png", "jpg", "jpeg", "bmp", "webp"]:
		return false
	if data.is_empty() or data.size() > 240:
		return false
	if data.size() >= 4 and data[0] == 0x44 and data[1] == 0x44 and data[2] == 0x53:
		return false
	# PNG is 89 50 4E 47. Symlink bodies are ASCII paths.
	for b in data:
		var c := int(b)
		if c == 0 or c >= 0x80:
			return false
	var text := data.get_string_from_ascii().strip_edges()
	if text == "" or "\n" in text or " " in text:
		return false
	return text.begins_with("../") or text.begins_with("./") or "/" in text


func _resolve_symlink(link_key: String, raw_target: String) -> String:
	var target := raw_target.strip_edges().replace("\\", "/")
	if target == "" or target.begins_with("/") or ":/" in target:
		return ""
	var base := link_key.get_base_dir()
	while target.begins_with("../"):
		target = target.substr(3)
		base = base.get_base_dir()
	if target.begins_with("./"):
		target = target.substr(2)
	if "/" in target and target.begins_with("../"):
		return ""
	if base == "":
		return target
	return base.path_join(target)


## Every indexed inner path in this pack, optionally filtered by prefix.
## Usage: pack.list("textures/")
func list(prefix: String = "") -> PackedStringArray:
	var pfx := _norm(prefix)
	var out := PackedStringArray()
	for inner in _files:
		var n := String(inner).replace("\\", "/").to_lower()
		if _is_blocked_path(n):
			continue
		if pfx == "" or n.begins_with(pfx):
			out.append(String(inner).replace("\\", "/"))
	return out


## Inner paths in one family, optionally filtered by prefix.
## Usage: pack.list_family(Tech3Pk3.FAMILY_MAP, "maps/")
func list_family(family: String, prefix: String = "") -> PackedStringArray:
	var pfx := _norm(prefix)
	var out := PackedStringArray()
	for inner in _files:
		var n := String(inner).replace("\\", "/").to_lower()
		if _is_blocked_path(n):
			continue
		if pfx != "" and not n.begins_with(pfx):
			continue
		if family != "" and not _ext_in_family(n, family):
			continue
		out.append(String(inner).replace("\\", "/"))
	return out


## BSP paths in this pack (maps/ plus loose .bsp files).
## Usage: for m in pack.list_maps(): ...
func list_maps() -> PackedStringArray:
	var out := PackedStringArray()
	for inner in list_family(FAMILY_MAP):
		var n := inner.to_lower()
		if n.begins_with("maps/") or n.get_file() == n:
			out.append(inner)
	return out


## Sound paths in this pack, optionally filtered by prefix.
## Usage: pack.list_sounds("music/")
func list_sounds(prefix: String = "") -> PackedStringArray:
	return list_family(FAMILY_SOUND, prefix)


## Unique map names across all mounts; last pack wins. Optional res:// scan.
## Usage: Tech3Pk3.list_all_maps(true)
static func list_all_maps(include_project: bool = false) -> PackedStringArray:
	var seen: Dictionary = {}
	var out := PackedStringArray()
	for i in range(_stack.size() - 1, -1, -1):
		var pack: Tech3Pk3 = _stack[i]
		for m in pack.list_maps():
			var key := _norm(m)
			if seen.has(key) or seen.has(key.get_basename()):
				continue
			seen[key] = true
			seen[key.get_basename()] = true
			seen[key.get_file()] = true
			out.append(m)
	# TODO: test this, might not pick up properly on exports!
	if include_project:
		for folder in ["res://maps", "res://"]:
			if not DirAccess.dir_exists_absolute(folder):
				continue
			var d := DirAccess.open(folder)
			if !d:
				continue
			for f in d.get_files():
				var lower := f.to_lower()
				if not (lower.ends_with(".bsp") or lower.ends_with(".tscn")):
					continue
				var logical := "maps/" + f.get_basename() + ".bsp"
				var key := _norm(logical)
				if seen.has(key) or seen.has(key.get_basename()):
					continue
				seen[key] = true
				out.append(folder.path_join(f))
	return out


## Read bytes from the highest-priority pack that has this logical path.
## Usage: Tech3Pk3.resolve_bytes("scripts/base.shader", Tech3Pk3.FAMILY_SHADER)
static func resolve_bytes(logical: String, family: String = "") -> PackedByteArray:
	var key := _norm(logical)
	if key == "" or key.begins_with("$"):
		return PackedByteArray()
	for i in range(_stack.size() - 1, -1, -1):
		var pack: Tech3Pk3 = _stack[i]
		var inner := pack.locate(key, family) if family != "" else pack._inner_for(key)
		if inner == "":
			continue
		var data := pack.read_entry(inner)
		if data.size() > 0:
			return data
	return PackedByteArray()


## True if any mounted pack has this logical path in the family.
## Usage: Tech3Pk3.resolve_has(name, Tech3Pk3.FAMILY_IMAGE)
static func resolve_has(logical: String, family: String = "") -> bool:
	var key := _norm(logical)
	if key == "" or key.begins_with("$"):
		return false
	for i in range(_stack.size() - 1, -1, -1):
		var pack: Tech3Pk3 = _stack[i]
		if family == "":
			if pack.has(key):
				return true
		elif pack.locate(key, family) != "":
			return true
	return false


## Winning pack's inner zip path for a logical name, or empty.
## Usage: Tech3Pk3.resolve_inner(name, family)
static func resolve_inner(logical: String, family: String = "") -> String:
	var key := _norm(logical)
	if key == "" or key.begins_with("$"):
		return ""
	for i in range(_stack.size() - 1, -1, -1):
		var pack: Tech3Pk3 = _stack[i]
		var inner := pack.locate(key, family) if family != "" else pack._inner_for(key)
		if inner != "":
			return inner
	return ""


## Union of inner paths across mounts (last pack wins on duplicates).
## Usage: Tech3Pk3.list_mounted("scripts/", Tech3Pk3.FAMILY_SHADER)
static func list_mounted(prefix: String = "", family: String = "") -> PackedStringArray:
	var seen: Dictionary = {}
	var out := PackedStringArray()
	for i in range(_stack.size() - 1, -1, -1):
		var pack: Tech3Pk3 = _stack[i]
		var files: PackedStringArray = pack.list_family(family, prefix) if family != "" else pack.list(prefix)
		for f in files:
			var k := _norm(f)
			if seen.has(k):
				continue
			seen[k] = true
			out.append(f)
	return out

# magic, then extension, then TRUEVISION-XFILE footer.
static func _guess_image_kind(data: PackedByteArray, hint_ext: String = "") -> String:
	if data.size() >= 8 and data[0] == 0x89 and data[1] == 0x50 and data[2] == 0x4E and data[3] == 0x47:
		return "png"
	if data.size() >= 2 and data[0] == 0xFF and data[1] == 0xD8:
		return "jpg"
	if data.size() >= 12 and data[0] == 0x52 and data[1] == 0x49 and data[2] == 0x46 and data[3] == 0x46 \
			and data[8] == 0x57 and data[9] == 0x45 and data[10] == 0x42 and data[11] == 0x50:
		return "webp"
	if data.size() >= 2 and data[0] == 0x42 and data[1] == 0x4D:
		return "bmp"
	# "DDS" Xonotic / DP compressed textures. Extension alone is not enough.
	if _dds_can_load(data):
		return "dds"
	var ext := hint_ext.to_lower()
	if ext == "jpeg":
		ext = "jpg"
	if ext in ["tga", "png", "jpg", "webp", "bmp", "dds"]:
		return ext
	if data.size() >= 26:
		var footer := "TRUEVISION-XFILE."
		var ok := true
		for i in 17:
			if data[data.size() - 18 + i] != footer.unicode_at(i):
				ok = false
				break
		if ok:
			return "tga"
	return ""


# dwPitchOrLinearSize is not the entry size. Xonotic writers put the whole
# mip chain there, sometimes including the header, so 128 + that field is
# larger than the zip entry on files DarkPlaces loads. Size the top mip from
# the dimensions and fourCC instead, and only refuse a buffer that cannot
# hold that mip. Godot still prints if we hand it a short DDS.
static func _dds_fourcc(data: PackedByteArray) -> String:
	if data.size() < 88:
		return ""
	return char(data[84]) + char(data[85]) + char(data[86]) + char(data[87])


static func _dds_top_mip_bytes(data: PackedByteArray) -> int:
	var w := int(data.decode_u32(16))
	var h := int(data.decode_u32(12))
	var pf_flags := int(data.decode_u32(80))
	var four := _dds_fourcc(data)
	var block := 0
	if four in ["DXT1", "ATI1", "BC4U", "BC4S"]:
		block = 8
	elif four in ["DXT3", "DXT5", "ATI2", "BC5U", "BC5S", "BC7U", "DX10"]:
		block = 16
	if block > 0:
		return maxi(1, (w + 3) >> 2) * maxi(1, (h + 3) >> 2) * block
	if (pf_flags & 0x40) != 0:
		var bits := int(data.decode_u32(88))
		if bits == 0:
			bits = 32
		return w * h * maxi(1, bits >> 3)
	return 0


static func _dds_can_load(data: PackedByteArray) -> bool:
	if data.size() < 128:
		return false
	if data[0] != 0x44 or data[1] != 0x44 or data[2] != 0x53 or data[3] != 0x20:
		return false
	var w := int(data.decode_u32(16))
	var h := int(data.decode_u32(12))
	if w == 0 or h == 0 or w > 16384 or h > 16384:
		return false
	var top := _dds_top_mip_bytes(data)
	if top > 0 and 128 + top > data.size():
		return false
	return true


# Bytes to ImageTexture. TGA is Image.load_tga_from_buffer, DDS is
# Image.load_dds_from_buffer. Compressed DDS is decompressed to RGBA8 so
# source_color sampling matches TGA/PNG (no second sRGB decode).
static func _image_to_texture(img: Image) -> Texture2D:
	if img == null or img.get_width() < 1:
		return null
	# Godot's DDS loader keeps the chain, but decompress() and convert()
	# both drop it.
	if img.is_compressed():
		var derr := img.decompress()
		if derr != OK:
			push_warning("tech3_pk3: compressed image decompress failed (%s); uploading as-is" % error_string(derr))
			return ImageTexture.create_from_image(img)
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	if img.has_mipmaps():
		img.clear_mipmaps()
	if img.generate_mipmaps() != OK:
		push_warning("tech3_pk3: generate_mipmaps failed")
	return ImageTexture.create_from_image(img)


## Decode TGA/JPG/PNG/BMP/WEBP/DDS bytes into an ImageTexture (no cache).
## Usage: Tech3Pk3.texture_from_bytes(data, logical)
static func texture_from_bytes(data: PackedByteArray, logical: String) -> Texture2D:
	if data.is_empty():
		return null
	var hint := logical.replace("\\", "/").get_extension().to_lower()
	if hint != "" and hint not in IMAGE_EXTENSIONS:
		return null
	# Godot's own loader prints "Failed to load TFA" or "Not a PNG file"
	# since sometimes JPGs, etc. have the wrong extensions in pk3s
	# we have to guess.
	var kind := _guess_image_kind(data, hint)
	if kind == "jpeg":
		kind = "jpg"
	if kind == "":
		return null
	var img := Image.new()
	var err := ERR_INVALID_DATA
	match kind:
		"png":
			if data.size() < 8 or data[0] != 0x89:
				return null
			err = img.load_png_from_buffer(data)
		"jpg":
			if data.size() < 2 or data[0] != 0xFF or data[1] != 0xD8:
				return null
			err = img.load_jpg_from_buffer(data)
		"bmp":
			if data.size() < 2 or data[0] != 0x42 or data[1] != 0x4D:
				return null
			err = img.load_bmp_from_buffer(data)
		"webp":
			if data.size() < 12 or data[0] != 0x52:
				return null
			err = img.load_webp_from_buffer(data)
		"tga":
			err = img.load_tga_from_buffer(data)
		"dds":
			if not _dds_can_load(data):
				return null
			err = img.load_dds_from_buffer(data)
		_:
			return null
	if err == OK and img.get_width() > 0:
		return _image_to_texture(img)
	return null


static func _image_reject_reason(data: PackedByteArray, logical: String) -> String:
	var hint := logical.replace("\\", "/").get_extension().to_lower()
	if data.is_empty():
		return "empty entry"
	if hint == "dds" or (data.size() >= 4 and data[0] == 0x44 and data[1] == 0x44 and data[2] == 0x53 and data[3] == 0x20):
		if data.size() < 128 or data[0] != 0x44:
			return "not a DDS image (%d bytes)" % data.size()
		var claimed := int(data.decode_u32(20))
		var top := _dds_top_mip_bytes(data)
		return "DDS %s %dx%d top mip %d bytes, entry %d, header linear field %d" % [
			_dds_fourcc(data), int(data.decode_u32(16)), int(data.decode_u32(12)), top, data.size(), claimed
		]
	var kind := _guess_image_kind(data, hint)
	if kind == "":
		return "unrecognized image (%d bytes, .%s)" % [data.size(), hint]
	return "%s decoder rejected it (%d bytes)" % [kind, data.size()]


static var _tex_cache: Dictionary = {} # norm key -> Texture2D
static var _height_cache: Dictionary = {} # _norm key -> alpha sidecar
static var _snd_cache: Dictionary = {} # "key|loop" -> AudioStream


## Alpha peeled off a _norm before RGTC. Empty if that normal had no height.
static func norm_height(logical: String) -> Texture2D:
	var key := _norm(logical)
	if _height_cache.has(key):
		return _height_cache[key]
	return null


static func remember_norm_height(logical: String, img: Image) -> Texture2D:
	var key := _norm(logical)
	_store_norm_height(key, img)
	return norm_height(logical)


static func _store_norm_height(key: String, img: Image) -> void:
	if img == null or img.get_width() < 1:
		_height_cache[key] = null
		return
	if img.is_compressed():
		img.decompress()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	var src := img.get_data()
	var dst := PackedByteArray()
	dst.resize(w * h)
	var vary := false
	var first := src[3] if src.size() >= 4 else 255
	for i in w * h:
		var a := src[i * 4 + 3]
		dst[i] = a
		if a != first:
			vary = true
	if not vary:
		_height_cache[key] = null
		return
	var height := Image.create_from_data(w, h, false, Image.FORMAT_R8, dst)
	if height.generate_mipmaps() != OK:
		pass
	_height_cache[key] = ImageTexture.create_from_image(height)


static func _compress_norm(img: Image) -> Image:
	if img.is_compressed():
		img.decompress()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	img.normal_map_to_xy()
	var packed := img.duplicate()
	if packed.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_NORMAL) == OK:
		return packed
	if packed.compress_from_channels(Image.COMPRESS_S3TC, Image.USED_CHANNELS_RG) == OK:
		return packed
	return img
static var _gdshader_cache: Dictionary = {}
static var _has_cache: Dictionary = {}


static func _found_key(family: String, key: String) -> String:
	return "%s|%s" % [family, key]


static func _clear_lookup_caches() -> void:
	_tex_cache.clear()
	_snd_cache.clear()
	_gdshader_cache.clear()
	_has_cache.clear()


## Drop decoded texture / sound / shader caches. Called after each map build.
## Usage: Tech3Pk3.clear_caches()
static func clear_caches() -> void:
	_clear_lookup_caches()


static func _cached_has(family: String, logical: String) -> bool:
	var key := _norm(logical)
	if key == "" or key.begins_with("$"):
		return false
	var ck := _found_key(family, key)
	if family == FAMILY_IMAGE and _tex_cache.has(key):
		return _tex_cache[key] != null
	if _has_cache.has(ck):
		return bool(_has_cache[ck])
	var found := resolve_has(key, family)
	_has_cache[ck] = found
	return found


## Zip-index probe only - does not decode image bytes.
## Usage: if Tech3Pk3.has_texture(map_path)
static func has_texture(logical: String) -> bool:
	return _cached_has(FAMILY_IMAGE, logical)


## Zip-index probe for a sound path across mounts.
## Usage: Tech3Pk3.has_sound(name)
static func has_sound(logical: String) -> bool:
	return _cached_has(FAMILY_SOUND, logical)


## Sound-family resolve_bytes() helper.
## Usage: Tech3Pk3.resolve_sound_bytes(name)
static func resolve_sound_bytes(logical: String) -> PackedByteArray:
	return resolve_bytes(logical, FAMILY_SOUND)


static func _guess_sound_kind(data: PackedByteArray, hint_ext: String = "") -> String:
	if data.size() >= 12:
		# RIFF....WAVE
		if data[0] == 0x52 and data[1] == 0x49 and data[2] == 0x46 and data[3] == 0x46 \
				and data[8] == 0x57 and data[9] == 0x41 and data[10] == 0x56 and data[11] == 0x45:
			return "wav"
		# OggS
		if data[0] == 0x4F and data[1] == 0x67 and data[2] == 0x67 and data[3] == 0x53:
			return "ogg"
	if data.size() >= 3:
		# ID3 tag or MPEG frame sync
		if data[0] == 0x49 and data[1] == 0x44 and data[2] == 0x33:
			return "mp3"
		if data[0] == 0xFF and (data[1] & 0xE0) == 0xE0:
			return "mp3"
	var ext := hint_ext.to_lower()
	if ext == "jpeg":
		ext = "jpg"
	if ext in SOUND_EXTENSIONS:
		return ext
	return ""


static func _apply_sound_loop(stream: AudioStream, loop: bool) -> void:
	if stream == null:
		return
	if stream is AudioStreamWAV:
		(stream as AudioStreamWAV).loop_mode = \
			AudioStreamWAV.LOOP_FORWARD if loop else AudioStreamWAV.LOOP_DISABLED
	elif stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = loop
	elif stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = loop


## Decode WAV/OGG/MP3 bytes into an AudioStream. loop sets the format's loop flag.
## Usage: Tech3Pk3.sound_from_bytes(data, logical, true)
static func sound_from_bytes(data: PackedByteArray, logical: String = "", loop: bool = false) -> AudioStream:
	if data.is_empty():
		return null
	var hint := logical.replace("\\", "/").get_extension().to_lower()
	var kind := _guess_sound_kind(data, hint)
	if kind == "":
		return null
	var stream: AudioStream = null
	match kind:
		"wav":
			stream = AudioStreamWAV.load_from_buffer(data)
		"ogg":
			stream = AudioStreamOggVorbis.load_from_buffer(data)
		"mp3":
			stream = AudioStreamMP3.load_from_buffer(data)
			if stream == null:
				var mp3 := AudioStreamMP3.new()
				mp3.data = data
				stream = mp3
	if stream == null:
		return null
	_apply_sound_loop(stream, loop)
	return stream


static func _sound_candidates(sound_name: String) -> PackedStringArray:
	var logical := sound_name.replace("\\", "/").strip_edges()
	var out := PackedStringArray()
	if logical == "":
		return out
	out.append(logical)
	var lower := logical.to_lower()
	var has_sound_ext := lower.get_extension() in SOUND_EXTENSIONS
	if not has_sound_ext:
		for e in SOUND_EXTENSIONS:
			out.append(logical + "." + e)
	if not lower.begins_with("sound/") and not lower.begins_with("music/"):
		var leaf := logical.get_file()
		out.append("sound/" + logical)
		out.append("music/" + logical)
		if leaf != logical:
			out.append("sound/" + leaf)
			out.append("music/" + leaf)
		if not has_sound_ext:
			for e in SOUND_EXTENSIONS:
				out.append("sound/" + leaf + "." + e)
				out.append("music/" + leaf + "." + e)
	return out


# Pack-only. Does not load res:// streams and does not spawn players.
## Find and decode a sound from mounted packs. Does not touch res://.
## Usage: var music := Tech3Pk3.load_sound(worldspawn.get("music", ""), true)
static func load_sound(sound_name: String, loop: bool = false) -> AudioStream:
	var cands := _sound_candidates(sound_name)
	if cands.is_empty():
		push_error("tech3_pk3: empty sound name")
		return null
	for cand in cands:
		var key := _norm(cand)
		var ck := "%s|%s" % [key, "1" if loop else "0"]
		if _snd_cache.has(ck):
			var hit = _snd_cache[ck]
			if hit != null:
				return hit as AudioStream
			continue
		for i in range(_stack.size() - 1, -1, -1):
			var pack: Tech3Pk3 = _stack[i]
			var inner := pack.locate(key, FAMILY_SOUND)
			if inner == "":
				continue
			var data := pack.read_entry(inner)
			if data.is_empty():
				continue
			var stream := sound_from_bytes(data, inner, loop)
			if stream:
				_snd_cache[ck] = stream
				_has_cache[_found_key(FAMILY_SOUND, key)] = true
				return stream
			push_warning("tech3_pk3: could not decode sound '%s' (%d bytes) in %s" % [
				inner, data.size(), pack.path
			])
		_snd_cache[ck] = null
	push_error("tech3_pk3: no sound '%s' in mounted packs" % sound_name)
	return null


## Zip-index probe for a .gdshader / .gdshaderinc.
## Usage: Tech3Pk3.has_gdshader(name)
static func has_gdshader(logical: String) -> bool:
	return _cached_has(FAMILY_GDSHADER, logical)


## Zip-index probe for a .material. Do not ResourceLoader.load pack materials.
## Usage: Tech3Pk3.has_material(name)
static func has_material(logical: String) -> bool:
	return _cached_has(FAMILY_MATERIAL, logical)


## Build a Shader from pack .gdshader text. Includes resolve against res://.
## Usage: var sh := Tech3Pk3.load_shader("shaders/mymap/custom")
static func load_shader(shader_name: String) -> Shader:
	var logical := shader_name.replace("\\", "/").strip_edges()
	if logical == "":
		push_error("tech3_pk3: empty shader name")
		return null
	var key := _norm(logical)
	if _gdshader_cache.has(key):
		return _gdshader_cache[key] as Shader
	var cands := PackedStringArray([logical])
	if key.get_extension() not in GDSHADER_EXTENSIONS:
		cands.append(logical + ".gdshader")
		cands.append(logical + ".gdshaderinc")
	for cand in cands:
		var data := resolve_bytes(cand, FAMILY_GDSHADER)
		if data.is_empty():
			continue
		var code := data.get_string_from_utf8()
		if code.strip_edges() == "":
			continue
		var sh := Shader.new()
		sh.code = code
		_gdshader_cache[key] = sh
		_has_cache[_found_key(FAMILY_GDSHADER, _norm(cand))] = true
		return sh
	_gdshader_cache[key] = null
	push_error("tech3_pk3: no .gdshader '%s' in mounted packs" % shader_name)
	return null


## Decode and cache a Texture2D from the winning pack.
## Usage: var tex := Tech3Pk3.resolve_texture(map_path)
static func resolve_texture(logical: String, quiet: bool = false) -> Texture2D:
	var key := _norm(logical)
	if key == "" or key.begins_with("$"):
		return null
	if _tex_cache.has(key):
		return _tex_cache[key]
	for i in range(_stack.size() - 1, -1, -1):
		var pack: Tech3Pk3 = _stack[i]
		var inner := pack.locate(key, FAMILY_IMAGE)
		if inner != "" and pack._is_companion_image(inner) and not pack._is_companion_image(key):
			inner = ""
		if inner == "":
			var dds_key := "dds/%s.dds" % key.get_basename() if key.get_extension() != "" else "dds/%s.dds" % key
			if pack._index.has(dds_key):
				inner = dds_key
		if inner == "":
			continue
		var data := pack.read_entry(inner)
		if data.is_empty():
			continue
		var tex := texture_from_bytes(data, inner)
		if tex:
			if key.get_basename().ends_with("_norm"):
				var src := tex.get_image()
				if src:
					_store_norm_height(key, src)
					var packed := _compress_norm(src)
					if packed != null and packed.is_compressed():
						tex = ImageTexture.create_from_image(packed)
			_tex_cache[key] = tex
			_has_cache[_found_key(FAMILY_IMAGE, key)] = true
			return tex
		push_warning("tech3_pk3: texture not loadable '%s' (%s) in %s" % [
			inner, _image_reject_reason(data, inner), pack.path
		])
		_tex_cache[key] = null
	_has_cache[_found_key(FAMILY_IMAGE, key)] = false
	return null


## Parse a BSP stored in this pack and return a BSPScene.
## Usage: pack.load_bsp("maps/q3dm1.bsp", extra_options)
func load_bsp(map_name: String, extra_options: Dictionary = {}) -> Node3D:
	var logical := map_name.replace("\\", "/").strip_edges()
	if logical == "":
		push_error("tech3_pk3: empty map name")
		return null
	if not logical.to_lower().ends_with(".bsp"):
		if has(logical + ".bsp"):
			logical += ".bsp"
		elif has("maps/" + logical.get_file() + ".bsp"):
			logical = "maps/" + logical.get_file() + ".bsp"
	if not has(logical):
		push_error("tech3_pk3: no BSP '%s' in %s" % [map_name, path])
		return null
	var data := read_bytes(logical)
	if data.is_empty():
		push_error("tech3_pk3: empty BSP '%s'" % logical)
		return null
	var opts := Tech3BSPReader.default_options()
	for k in extra_options.keys():
		opts[k] = extra_options[k]
	var reader := Tech3BSPReader.new()
	Tech3BSPReader.options = opts
	var scene := reader.read_bsp_bytes(data, "pk3://" + logical)
	Tech3Pk3.clear_caches()
	return scene


static func _map_candidates(map_name: String) -> PackedStringArray:
	var logical := map_name.replace("\\", "/").strip_edges()
	var out := PackedStringArray()
	if logical == "":
		return out
	out.append(logical)
	if not logical.to_lower().ends_with(".bsp"):
		out.append(logical + ".bsp")
		out.append("maps/" + logical.get_file() + ".bsp")
	elif not logical.to_lower().begins_with("maps/"):
		out.append("maps/" + logical.get_file())
	return out


# pk3 BSPs override same-named project maps (for mods)
## Load a map by name: mounted PK3 first, then res:// .tscn / .bsp.
## Usage: var scene := Tech3Pk3.load_map("q3dm1")
static func load_map(map_name: String, extra_options: Dictionary = {}) -> Node3D:
	var cands := _map_candidates(map_name)
	for i in range(_stack.size() - 1, -1, -1):
		var pack: Tech3Pk3 = _stack[i]
		for c in cands:
			if pack.has(c):
				return pack.load_bsp(c, extra_options)
	for c in cands:
		var stem := c.get_basename() if c.to_lower().ends_with(".bsp") else c
		for res_path in [
			"res://%s.tscn" % stem,
			"res://maps/%s.tscn" % stem.get_file(),
			"res://%s.bsp" % stem,
			"res://maps/%s.bsp" % stem.get_file(),
		]:
			if ResourceLoader.exists(res_path) and res_path.ends_with(".tscn"):
				var ps = load(res_path)
				if ps is PackedScene:
					return ps.instantiate()
			elif FileAccess.file_exists(res_path) and res_path.ends_with(".bsp"):
				var reader := Tech3BSPReader.new()
				Tech3BSPReader.options = Tech3BSPReader.default_options()
				for k in extra_options.keys():
					Tech3BSPReader.options[k] = extra_options[k]
				var scene := reader.read_bsp(res_path)
				Tech3Pk3.clear_caches()
				return scene
	push_error("tech3_pk3: no map '%s' in mounted packs or res://" % map_name)
	return null
