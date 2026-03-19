extends Node
class_name Tech3BSPReader

const LUMP_COUNT = 17 # TODO: Raven BSP's have 18, there's a LIGHTARRAY lump, not sure what it's for yet.
const MAX_MESH_SURFACES = RenderingServer.MAX_MESH_SURFACES
const DEFAULT_LIGHTMAP_SIZE = 128
const DEFAULT_LIGHTMAP_LENGTH = 49152
const POSSIBLE_IMAGE_EXTENSIONS = ["bmp", "dds", "ktx", "exr", "hdr", "jpg", "jpeg", "png", "tga", "svg", "webp"]

var bsp_scene: BSPScene # the final product

static var options: Dictionary # importer options

var bsp_file: FileAccess
var entities: Array[Dictionary]
var textures: Array[BSPTexture]
var planes: Array[Plane]
var nodes: Array[BSPNode]
var leafs: Array[BSPLeaf]
var leaf_faces: Array[int]
var leaf_brushes: Array[int]
var models: Array[BSPModel]
var brushes: Array[BSPBrush]
var brush_sides: Array[BSPBrushSide]
var vertices: Array[BSPVertex]
var indices: Array[int] # meshverts in BSP terms
var effects: Array[BSPEffect] # seems to be only volumetric fog?
var faces: Array[BSPFace]
var external_lightmaps: Array[Texture]
var vis_data: BSPVisData

var light_grid_normalize := Vector3.ZERO
var light_grid_offset := Vector3.ZERO
var light_grid_ambient: ImageTexture3D
var light_grid_direct: ImageTexture3D
var light_grid_cartesian: ImageTexture3D

var worldspawn: Dictionary

var lightmap_atlas: ImageTexture
var lightmap_columns := 0
var lightmap_rows := 0

# using the idtech3 lump names here
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
	MESHVERTS, # indices for vertices in meshes
	EFFECTS,
	FACES,
	LIGHTMAPS,
	LIGHTVOLS, # 3D volumetric light grid for dynamic objects
	VISDATA,
	#whatever Raven thing goes here
}

enum FACE_TYPE {
	NONE = 0,
	POLYGON,
	PATCH,
	MESH,
	BILLBOARD
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
	JUMPPAD = 0x040000,
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


class BSPNode:
	var plane: int
	var front: int
	var back: int
	var bounds_min: Vector3
	var bounds_max: Vector3
	func _init(plane: int, front: int, back: int, bounds_min: Vector3, bounds_max: Vector3) -> void:
		self.plane = Tech3BSPReader.to_signed32(plane)
		self.front = Tech3BSPReader.to_signed32(front)
		self.back = Tech3BSPReader.to_signed32(back)
		self.bounds_min = Tech3BSPReader.tech3_to_gd(bounds_min)
		self.bounds_max = Tech3BSPReader.tech3_to_gd(bounds_max)

class BSPLeaf:
	var cluster: int
	var area: int
	var bounds_min: Vector3
	var bounds_max: Vector3
	var leaf_face: int
	var num_leaf_faces: int
	var leaf_brush: int
	var num_leaf_brushes: int
	func _init(cluster: int, area: int, bounds_min: Vector3, bounds_max: Vector3, leaf_face: int, num_leaf_faces: int, leaf_brush: int, num_leaf_brushes: int) -> void:
		self.cluster = Tech3BSPReader.to_signed32(cluster)
		self.area = Tech3BSPReader.to_signed32(area)
		self.leaf_face = Tech3BSPReader.to_signed32(leaf_face)
		self.num_leaf_faces = Tech3BSPReader.to_signed32(num_leaf_faces)
		self.leaf_brush = Tech3BSPReader.to_signed32(leaf_brush)
		self.num_leaf_brushes = Tech3BSPReader.to_signed32(num_leaf_brushes)
		self.bounds_min = Tech3BSPReader.tech3_to_gd(bounds_min)
		self.bounds_max = Tech3BSPReader.tech3_to_gd(bounds_max)

class BSPModel:
	var bounds_min: Vector3
	var bounds_max: Vector3
	var face: int
	var num_faces: int
	var brush: int
	var num_brushes: int
	func _init(bounds_min: Vector3, bounds_max: Vector3, face: int, num_faces: int, brush: int, num_brushes: int) -> void:
		self.face = Tech3BSPReader.to_signed32(face)
		self.num_faces = Tech3BSPReader.to_signed32(num_faces)
		self.brush = Tech3BSPReader.to_signed32(brush)
		self.num_brushes = Tech3BSPReader.to_signed32(num_brushes)
		self.bounds_min = bounds_min
		self.bounds_max = bounds_max

class BSPBrush:
	var brush_side: int
	var num_brush_sides: int
	var texture_id: int
	func _init(brush_side: int, num_brush_sides: int, texture_id: int) -> void:
		self.brush_side = Tech3BSPReader.to_signed32(brush_side)
		self.num_brush_sides = Tech3BSPReader.to_signed32(num_brush_sides)
		self.texture_id = Tech3BSPReader.to_signed32(texture_id)

class BSPBrushSide:
	var plane: int
	var texture_id: int
	func _init(plane: int, texture_id: int) -> void:
		self.plane = Tech3BSPReader.to_signed32(plane)
		self.texture_id = Tech3BSPReader.to_signed32(texture_id)

class BSPVisData:
	var num_clusters: int
	var bytes_per_cluster: int
	var bit_sets: PackedByteArray
	func _init(num_clusters: int, bytes_per_cluster: int) -> void:
		self.num_clusters = Tech3BSPReader.to_signed32(num_clusters)
		self.bytes_per_cluster = bytes_per_cluster

class BSPVertex:
	var vertex_id: int
	var position: Vector3
	var uv: Vector2
	var uv2: Vector2
	var normal: Vector3
	var color: Color
	func _init(vertex_id: int, position: Vector3, tex_x: float, tex_y: float, lm_x: float, lm_y: float, normal: Vector3, color: PackedByteArray) -> void:
		self.vertex_id = Tech3BSPReader.to_signed32(vertex_id)
		self.position = Tech3BSPReader.tech3_to_gd(position)
		self.normal = Tech3BSPReader.tech3_to_gd(normal, false)
		# TODO: determine if we ALWAYS want this sRGB conversion for vertex colors
		var in_color := Color(color[0] / 255.0, color[1] / 255.0, color[2] / 255.0, color[3] / 255.0)
		self.color = in_color
		#self.color = Color(pow(in_color.r, 2.2), pow(in_color.g, 2.2), pow(in_color.b, 2.2), in_color.a)
		self.uv.x = tex_x
		self.uv.y = tex_y
		self.uv2.x = lm_x
		self.uv2.y = lm_y

class BSPEffect:
	var name: String
	var brush_num: int
	var unknown: int # Always 5, except in q3dm8, which has one effect with -1. (https://www.mralligator.com/q3/)
	func _init(name: String, brush_num: int, unknown: int) -> void:
		self.name = name
		self.brush_num = Tech3BSPReader.to_signed32(brush_num)
		self.unknown = Tech3BSPReader.to_signed32(unknown)

class BSPFace:
	var face_id: int
	var texture_id: int
	var effect: int
	var type: FACE_TYPE
	var start_vert_index: int
	var num_verts: int
	var start_index: int
	var num_indices: int
	var lightmap_id: int
	var lm_corner: Vector2
	var lm_size: Vector2
	var lm_origin: Vector3
	var lm_vecs: PackedVector3Array
	var normal: Vector3
	var size: PackedInt32Array
	func _init(face_id: int, texture_id: int, effect: int, type: int, start_vert_index: int, num_verts: int, start_index: int, num_indices: int, lightmap_id: int, lm_corner: Vector2, lm_size: Vector2, lm_origin: Vector3, lm_vecs: PackedVector3Array, normal: Vector3, size: PackedInt32Array) -> void:
		self.face_id = Tech3BSPReader.to_signed32(face_id)
		self.texture_id = Tech3BSPReader.to_signed32(texture_id)
		self.effect = Tech3BSPReader.to_signed32(effect)
		self.type = type
		self.start_vert_index = Tech3BSPReader.to_signed32(start_vert_index)
		self.num_verts = Tech3BSPReader.to_signed32(num_verts)
		self.start_index = Tech3BSPReader.to_signed32(start_index)
		self.num_indices = Tech3BSPReader.to_signed32(num_indices)
		self.lightmap_id = Tech3BSPReader.to_signed32(lightmap_id)
		self.lm_corner = lm_corner
		self.lm_size = lm_size
		self.lm_origin = Tech3BSPReader.tech3_to_gd(lm_origin)
		self.lm_vecs = lm_vecs
		self.normal = Tech3BSPReader.tech3_to_gd(normal, false)
		self.size = size

class BSPTexture:
	var name: String
	var flags: SURFACE_FLAGS
	var content_flags: CONTENT_FLAGS
	func _init(name: String, flags: SURFACE_FLAGS, content_flags: CONTENT_FLAGS) -> void:
		self.name = name
		self.flags = flags
		self.content_flags = content_flags
	func _to_string() -> String:
		return str("Name: ", name, ", Surface Flags: ", flags, ", Content Flags: ", content_flags, "\n")


# where the magic begins...
static func tech3_to_gd(in_vec: Variant, scale: bool = true) -> Variant:
	var out_vec: Variant
	if (in_vec is Vector3):
		out_vec = Vector3(-in_vec.x, in_vec.z, in_vec.y)
	elif (in_vec is Vector3i):
		out_vec = Vector3i(int(-in_vec.x), int(in_vec.z), int(in_vec.y))
	else:
		push_error("Didn't receive a Vector3 or Vector3i!!!")
		return null

	if (scale):
		out_vec *= (1.0 / options.unit_scale)

	return out_vec


func string_to_vector3(vec3: String) -> Vector3:
	var components = vec3.split_floats(" ", false)
	return Vector3(components[0], components[1], components[2])


func string_to_vector3i(vec3i: String) -> Vector3i:
	var components = vec3i.split_floats(" ", false)
	return Vector3i(int(components[0]), int(components[1]), int(components[2]))


# for rotated plane metadata in brush collisions
func quantize_normal(normal: Vector3) -> Vector3i:
	const SNAP_STEP = 0.001
	const ZERO_THRESHOLD = 0.02
	
	normal = normal.normalized()
	
	var vector3_snapped := Vector3(
		snapped(normal.x, SNAP_STEP),
		snapped(normal.y, SNAP_STEP),
		snapped(normal.z, SNAP_STEP)
	)
	
	for i in range(3):
		if abs(vector3_snapped[i]) < ZERO_THRESHOLD:
			vector3_snapped[i] = 0.0
	
	return Vector3i(vector3_snapped * 1000)


# FIXME: sort out this madness, entities can use angles either
# as a direction or a rotation, and converting to/from a Basis
# doesn't seem reliable...
# so for now just passing the values straight to the scenes
# and let them sort it out.
#func angles_to_basis(angles: Vector3) -> Basis:
	## Quake angles are degrees, convert to radians
	#var x := deg_to_rad(-angles.x)
	#var y := deg_to_rad(angles.y)
	#var z := deg_to_rad(angles.z)
	#return Basis.from_euler(Vector3(x, y, z))


# FIXME: this is a bit less of a problem, however just going to
# pass the value on through for these as well now, and let the 
# entity scene figure out what it wants to do.
#func angle_to_basis(angle: float) -> Basis:
	#if angle == -1.0:
		## Up
		#return Basis.from_euler(Vector3.UP)
	#elif angle == -2.0:
		## Down
		#return Basis.from_euler(Vector3.DOWN)
	#else:
		## Just yaw
		#return Basis.from_euler(Vector3(0, angle, 0))


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
func look_at_safely(origin: Vector3, target: Vector3) -> Transform3D:
	var direction = (target - origin).normalized()
	var up = Vector3.UP

	# Check for colinearity with "up" vector
	if abs(direction.dot(up)) > 0.999:
		up = Vector3.FORWARD  # Just change what our lights "up" is!

	var basis = Basis().looking_at(direction, up)
	return Transform3D(basis, origin)


# Godot doesn't convert signed ints with "get_32" etc.
static func to_signed32(value: int) -> int:
	if value >= 0x80000000:
		return value - 0x100000000
	return value


# TODO: is this even necessary?
# also is it missing anything...
func clear_data() -> void:
	bsp_scene = null
	bsp_file = null
	entities.clear()
	textures.clear()
	planes.clear()
	nodes.clear()
	leafs.clear()
	leaf_faces.clear()
	leaf_brushes.clear()
	models.clear()
	brushes.clear()
	brush_sides.clear()
	vertices.clear()
	indices.clear()
	effects.clear()
	faces.clear()
	external_lightmaps.clear()
	vis_data = null
	light_grid_normalize = Vector3.ZERO
	light_grid_offset = Vector3.ZERO
	light_grid_ambient = null
	light_grid_direct = null
	light_grid_cartesian = null


# Use the maps texture name to perform a lookup in a user-defined
# materials path matching a string
# e.g. "textures/liquids/water_02" becomes
# "res://materials/liquids/water_02.material"
# TODO: this should be able to pull materials for maps in the
# user directory as well (and later maybe from .pk3)
func material_from_path(texture_id: int, lightmap_id: int) -> Material:
	var path_pattern: String = options.materials_path
	var texture_name: String = (textures[texture_id].name)
	var options_material_path := path_pattern.replace("{texture_name}", texture_name).replace("textures/", "")
	var material: Material
	
	var actual_material_path := ""

	if options_material_path.begins_with("res://") or options_material_path.begins_with("user://"): # path is absolute, just check for the file
		actual_material_path = options_material_path
	else: # path is relative, build a path to check for image formats starting from the BSP's directory
		actual_material_path = "%s/%s" % [bsp_file.get_path().get_base_dir(), options_material_path]

	if FileAccess.file_exists(actual_material_path):
		if options.import_lightmaps and lightmap_id >= 0:
			# need to duplicate to apply lightmaps without affecting original material
			material = load(actual_material_path).duplicate()
		else:
			# go ahead and just reference the material
			material = load(actual_material_path)
	else:
		if options.fallback_materials:
			#print("%s not found, creating fallback from texture" % actual_material_path)
			material = material_from_texture(texture_id, lightmap_id)

	# for lightmaps to work we have to make some assumptions,
	# the shader being used must have some uniform like "lightmap_texture"
	# so it will have to be a custom shader, this won't work for StandardMaterial3D.
	if material is ShaderMaterial and options.import_lightmaps and lightmap_id >= 0:
		if external_lightmaps.is_empty():
			material.set_shader_parameter("lightmap_texture", lightmap_atlas)
		else:
			material.set_shader_parameter("lightmap_texture", external_lightmaps[lightmap_id])
	return material


# TODO: replace all of this with an idTech3 shader parser.
func material_from_texture(texture_id: int, lightmap_id: int) -> Material:
	var material: Material
	var face_texture: Texture2D
	var tex_path: String = (textures[texture_id].name).replace("textures/", options.textures_path + "/" if not options.textures_path.ends_with("/") else options.textures_path)
	
	for ext: String in POSSIBLE_IMAGE_EXTENSIONS:
		var possible_file := ""
		if tex_path.begins_with("res://") or tex_path.begins_with("user://"): # path is absolute, just check for the file
			possible_file = "%s.%s" % [tex_path, ext]
		else: # path is relative, build a path to check for image formats starting from the BSP's directory
			possible_file = "%s/%s.%s" % [bsp_file.get_path().get_base_dir(), tex_path, ext]
		
		if FileAccess.file_exists(possible_file):
			face_texture = load(possible_file)
			break

	if !face_texture:
		push_warning("No matching texture for %s, creating fallback colored material" % tex_path)
		material = ShaderMaterial.new()
		material.shader = load("res://addons/tech3bsp/shaders/example_missing_texture.gdshader")
		material.set_shader_parameter("albedo_color", Color(randf(), randf(), randf(), 1.0))
	else:
		# assume a standard material if we DON'T want vertex colors and DON'T want bsp lightmaps
		# and DIDN'T provide a material path!
		if !options.import_vertex_colors and !options.import_lightmaps:
			material = StandardMaterial3D.new()
			material.albedo_texture = face_texture
			material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
			return material

		material = ShaderMaterial.new()
		if options.import_vertex_colors and !options.import_lightmaps:
			material.shader = load("res://addons/tech3bsp/shaders/example_vertex_lighting.gdshader")
		else:
			if textures[texture_id].content_flags & CONTENT_FLAGS.TRANSLUCENT and not textures[texture_id].content_flags & (CONTENT_FLAGS.WATER | CONTENT_FLAGS.SLIME | CONTENT_FLAGS.LAVA):
				material.shader = load("res://addons/tech3bsp/shaders/example_surface_translucent.gdshader")
			elif textures[texture_id].content_flags & (CONTENT_FLAGS.WATER | CONTENT_FLAGS.SLIME | CONTENT_FLAGS.LAVA):
				material.shader = load("res://addons/tech3bsp/shaders/example_liquid.gdshader")
			else:
				material.shader = load("res://addons/tech3bsp/shaders/example_surface_solid.gdshader")
	
	# this check is probably unnecessary at this point, but just in case
	if material is ShaderMaterial:
		if options.import_lightmaps and lightmap_id >= 0:
			if external_lightmaps.is_empty():
				material.set_shader_parameter("lightmap_texture", lightmap_atlas)
			else:
				material.set_shader_parameter("lightmap_texture", external_lightmaps[lightmap_id])
		#if !lightmaps.is_empty() and options.import_lightmaps and lightmap_id >= 0:
			# Doing it as another pass loses us ~500 FPS
			# TODO: make it optional and put that caveat into readme
			#var lightmap_material := ShaderMaterial.new()
			#lightmap_material.shader = load("res://addons/tech3bsp/shaders/lightmap.gdshader")
			#lightmap_material.set_shader_parameter("lightmap_texture", lightmaps[lightmap_id])
			#material.next_pass = lightmap_material
			#material.set_shader_parameter("lightmap_texture", lightmaps[lightmap_id])
	
		material.set_shader_parameter("albedo_texture", face_texture)
	
	return material


func parse_lumps() -> Array[Dictionary]:
	var lumps: Array[Dictionary]
	for i in range(LUMP_COUNT):
		var bsp_dir_entry: Dictionary = {
			offset = bsp_file.get_32(),
			length = bsp_file.get_32()
		}
		lumps.append(bsp_dir_entry)
	return lumps


func parse_entities(ent_lump) -> void:
	bsp_file.seek(ent_lump.offset)
	var entities_string := bsp_file.get_buffer(ent_lump.length).get_string_from_ascii()
	var ent_split := entities_string.split("{", false)
	var regex = RegEx.new()
	# TODO: not sure if this will miss any entities, test test test!
	regex.compile('"(?<key>.+)" "(?<value>.+)"')
	#print(entities_string)
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
				"angles": # conversions to Basis
					# FIXME: for now pass the value
					actual_value = string_to_vector3(value)
				"angle": # convert single angle to basis
					# FIXME: for now let's just pass the value
					actual_value = value.to_float()
				"speed": # floats we can pass straight through (I think)
					actual_value = value.to_float()
				"_color", "color": # Colors!
				# TODO: sometimes colors are bytes, should handle that.
					var components := value.split_floats(" ", false) 
					actual_value = Color(components[0], components[1], components[2])
				_: # no idea, let's pass it as a string for now.
					actual_value = value
			#print(key, " : ", actual_value)
			entity[key] = actual_value
		entities.append(entity)
	worldspawn = entities[0]
	print("worldspawn: ", worldspawn)
	print("entities: ", entities.size())


func parse_textures(tex_lump) -> void:
	bsp_file.seek(tex_lump.offset)
	var count: int = tex_lump.length / 72 # name[64], flags, contents
	print("textures: ", count)
	for i in range(count):
		var tex_name = bsp_file.get_buffer(64).get_string_from_ascii()
		var surface_flags = bsp_file.get_32()
		var content_flags = bsp_file.get_32()
		var tex = BSPTexture.new(tex_name, surface_flags, content_flags)
		textures.append(tex)
	#print(textures)


func parse_planes(planes_lump) -> void:
	bsp_file.seek(planes_lump.offset)
	var count: int = planes_lump.length / 16
	print("planes: ", count)
	for i in range(count):
		var plane_x: float = bsp_file.get_float()
		var plane_y: float = bsp_file.get_float()
		var plane_z: float = bsp_file.get_float()
		var dist: float = bsp_file.get_float()
		var plane: Plane = Plane(Tech3BSPReader.tech3_to_gd(Vector3(plane_x, plane_y, plane_z), false), dist * (1.0 / options.unit_scale))
		planes.append(plane)
	#print(planes)


func parse_nodes(nodes_lump) -> void:
	bsp_file.seek(nodes_lump.offset)
	var count: int = nodes_lump.length / 16
	print("nodes: ", count)
	for i in range(count):
		var plane: int = bsp_file.get_32()
		var front: int = bsp_file.get_32()
		var back: int = bsp_file.get_32()
		var bounds_min := Vector3i(bsp_file.get_32(), bsp_file.get_32(), bsp_file.get_32())
		var bounds_max := Vector3i(bsp_file.get_32(), bsp_file.get_32(), bsp_file.get_32())
		var node = BSPNode.new(plane, front, back, bounds_min, bounds_max)
		nodes.append(node)


func parse_leafs(leafs_lump) -> void:
	bsp_file.seek(leafs_lump.offset)
	var count: int = leafs_lump.length / 48
	print("leafs: ", count)
	for i in range(count):
		var cluster: int = bsp_file.get_32()
		var area: int = bsp_file.get_32()
		var mins := Vector3i(bsp_file.get_32(), bsp_file.get_32(), bsp_file.get_32())
		var maxs := Vector3i(bsp_file.get_32(), bsp_file.get_32(), bsp_file.get_32())
		var leaf_face: int = bsp_file.get_32()
		var num_leaffaces: int = bsp_file.get_32()
		var leaf_brush: int = bsp_file.get_32()
		var num_leafbrushes: int = bsp_file.get_32()
		var leaf = BSPLeaf.new(cluster, area, mins, maxs, leaf_face, num_leaffaces, leaf_brush, num_leafbrushes)
		leafs.append(leaf)


func parse_leaf_faces(leaf_faces_lump) -> void:
	bsp_file.seek(leaf_faces_lump.offset)
	var count: int = leaf_faces_lump.length / 4
	print("leaf faces: ", count)
	for i in range(count):
		# face index
		leaf_faces.append(bsp_file.get_32())


func parse_leaf_brushes(leaf_brushes_lump) -> void:
	bsp_file.seek(leaf_brushes_lump.offset)
	var count: int = leaf_brushes_lump.length / 4
	print("leaf brushes: ", count)
	for i in range(count):
		# brush index
		leaf_brushes.append(bsp_file.get_32())


func parse_models(models_lump) -> void:
	bsp_file.seek(models_lump.offset)
	var count: int = models_lump.length / 40
	print("models: ", count)
	for i in range(count):
		var mins := Vector3(bsp_file.get_float(), bsp_file.get_float(), bsp_file.get_float())
		var maxs := Vector3(bsp_file.get_float(), bsp_file.get_float(), bsp_file.get_float())
		var face: int = bsp_file.get_32()
		var num_faces: int = bsp_file.get_32()
		var brush: int = bsp_file.get_32()
		var num_brushes: int = bsp_file.get_32()
		var model = BSPModel.new(mins, maxs, face, num_faces, brush, num_brushes)
		models.append(model)


func parse_brushes(brushes_lump) -> void:
	bsp_file.seek(brushes_lump.offset)
	var count: int = brushes_lump.length / 12
	print("brushes: ", count)
	for i in range(count):
		#brushside, num_brushsides, texture_id
		var brush = BSPBrush.new(bsp_file.get_32(), bsp_file.get_32(), bsp_file.get_32())
		brushes.append(brush)


func parse_brush_sides(brush_sides_lump) -> void:
	bsp_file.seek(brush_sides_lump.offset)
	var count: int = brush_sides_lump.length / 8
	print("brush sides: ", count)
	for i in range(count):
		# plane, texture_id
		var brush_side = BSPBrushSide.new(bsp_file.get_32(), bsp_file.get_32())
		brush_sides.append(brush_side)


func parse_vertices(vertices_lump) -> void:
	bsp_file.seek(vertices_lump.offset)
	var count: int = vertices_lump.length / 44
	print("vertices: ", count)
	for i in range(count):
		var position = Vector3(bsp_file.get_float(), bsp_file.get_float(), bsp_file.get_float())
		var uv_x: float = bsp_file.get_float()
		var uv_y: float = bsp_file.get_float()
		var uv2_x: float = bsp_file.get_float()
		var uv2_y: float = bsp_file.get_float()
		var normal := Vector3(bsp_file.get_float(), bsp_file.get_float(), bsp_file.get_float())
		var color := bsp_file.get_buffer(4)
		var vertex := BSPVertex.new(i, position, uv_x, uv_y, uv2_x, uv2_y, normal, color)
		vertices.append(vertex)


func parse_indices(mesh_verts_lump) -> void:
	bsp_file.seek(mesh_verts_lump.offset)
	var count: int = mesh_verts_lump.length / 4
	print("indices (mesh_verts): ", count)
	for i in range(count):
		# offset
		indices.append(bsp_file.get_32())


func parse_effects(effects_lump) -> void: # fog
	bsp_file.seek(effects_lump.offset)
	var count: int = effects_lump.length / 72
	print("effects (fog): ", count)
	for i in range(count):
		var name = bsp_file.get_buffer(64).get_string_from_ascii()
		var brush: int = bsp_file.get_32()
		var unknown: int = bsp_file.get_32()
		var fog = BSPEffect.new(name, brush, unknown)
		effects.append(fog)


func parse_faces(faces_lump) -> void:
	bsp_file.seek(faces_lump.offset)
	var count: int = faces_lump.length / 104
	print("faces: ", count)
	
	for i in range(count):
		var texture_id: int = bsp_file.get_32()
		var effect: int = bsp_file.get_32()
		var type: int = bsp_file.get_32()
		var vertex: int = bsp_file.get_32()
		var num_vertexes: int = bsp_file.get_32()
		var mesh_vert: int = bsp_file.get_32()
		var num_mesh_verts: int = bsp_file.get_32()
		var lm_index: int = bsp_file.get_32()
		var lm_start: Vector2 = Vector2(bsp_file.get_32(), bsp_file.get_32())
		var lm_size: Vector2 = Vector2(bsp_file.get_32(), bsp_file.get_32())
		var lm_origin: Vector3 = Vector3(bsp_file.get_float(), bsp_file.get_float(), bsp_file.get_float())
		var lm_vecs: PackedVector3Array = [Vector3(bsp_file.get_float(), bsp_file.get_float(), bsp_file.get_float()), Vector3(bsp_file.get_float(), bsp_file.get_float(), bsp_file.get_float())]
		var normal: Vector3 = Vector3(bsp_file.get_float(), bsp_file.get_float(), bsp_file.get_float())
		var size: PackedInt32Array = [bsp_file.get_32(), bsp_file.get_32()]
		var face = BSPFace.new(i, texture_id, effect, type, vertex, num_vertexes,mesh_vert, num_mesh_verts, lm_index, lm_start, lm_size, lm_origin, lm_vecs, normal, size)
		faces.append(face)


func parse_lightmaps(lightmap_lump) -> void:
	bsp_file.seek(lightmap_lump.offset)
	var count: int = lightmap_lump.length / DEFAULT_LIGHTMAP_LENGTH
	print("lightmap lump length: ", lightmap_lump.length)
	
	if !count: # maybe we're using external lightmaps?
		# the "traditional" way seems to be to have a folder in the same directory as the BSP
		# which contains the external lightmaps, so let's just check for that.
		var bsp_path := bsp_file.get_path().rstrip(".bsp")
		var dir := DirAccess.open(bsp_path)
		if dir:
			dir.list_dir_begin()
			var entry := dir.get_next()

			while entry != "":
				if not POSSIBLE_IMAGE_EXTENSIONS.has(entry.get_extension()):
					entry = dir.get_next()
					continue
				var ext_lm_image: CompressedTexture2D = load("%s/%s" % [bsp_path, entry])
				external_lightmaps.append(ext_lm_image)
				entry = dir.get_next()
		else:
			print("No external or internal lightmaps found, abandoning lightmap import.")
			return

		external_lightmaps.reverse() # gotta flip the order apparently? TODO: test on more large lightmaps!
		print("external lightmaps: ",  external_lightmaps.size())
		return
	
	print("internal lightmaps: ", count)
	
	lightmap_columns = int(ceil(sqrt(count)))
	lightmap_rows = int(ceil(float(count) / lightmap_columns))
	
	var atlas_width = lightmap_columns * DEFAULT_LIGHTMAP_SIZE
	var atlas_height = lightmap_rows * DEFAULT_LIGHTMAP_SIZE
	
	var lightmap_atlas_image := Image.create_empty(atlas_width, atlas_height, false, Image.FORMAT_RGB8)

	for i in range(count):
		var lightmap_bytes := bsp_file.get_buffer(DEFAULT_LIGHTMAP_LENGTH)
		var lightmap_colors: Color
		var img := Image.create_empty(DEFAULT_LIGHTMAP_SIZE, DEFAULT_LIGHTMAP_SIZE, false, Image.FORMAT_RGB8)
		var l := 0
		
		for y in range(DEFAULT_LIGHTMAP_SIZE):
			for x in range(DEFAULT_LIGHTMAP_SIZE):
				lightmap_colors = scale_color(Color(lightmap_bytes[l], lightmap_bytes[l + 1], lightmap_bytes[l + 2]))
				img.set_pixel(x, y, lightmap_colors)
				l += 3
		
		var col = i % lightmap_columns
		var row = i / lightmap_columns
		var dst := Vector2i(col * DEFAULT_LIGHTMAP_SIZE, row * DEFAULT_LIGHTMAP_SIZE)
		
		lightmap_atlas_image.blit_rect(
			img,
			Rect2i(0, 0, DEFAULT_LIGHTMAP_SIZE, DEFAULT_LIGHTMAP_SIZE),
			dst
		)
		
		#img.generate_mipmaps()
	#lightmap_atlas.compress_from_channels(Image.COMPRESS_BPTC, Image.USED_CHANNELS_RGB)
	lightmap_atlas = ImageTexture.create_from_image(lightmap_atlas_image)


func spherical_to_cartesian(latitude: float, longitude: float) -> Vector3:
	var theta := deg_to_rad(longitude * 360.0 / 255.0)
	var phi := deg_to_rad(latitude * 360.0 / 255.0)

	var x := -cos(theta) * sin(phi)
	var y := cos(phi)
	var z := sin(theta) * sin(phi)

	return Vector3(x, y, z).normalized()


func parse_light_grid(light_grid_lump) -> void:
	bsp_file.seek(light_grid_lump.offset)
	var light_grid := bsp_file.get_buffer(light_grid_lump.length)
	var count = light_grid.size() / 8
	print("light grid: ", count)
	
	if count == 0:
		# no lightgrid here, guess we're done.
		# this will make entities basically be "fullbright" if using a shader that relies on this.
		return
	
	var grid_size := Vector3i(64, 64, 128)
	if worldspawn.has("gridsize"):
		grid_size = worldspawn["gridsize"]
	
	var size := Vector3i(\
		floor(models[0].bounds_max.x / grid_size.x) - ceil(models[0].bounds_min.x / grid_size.x) + 1,\
		floor(models[0].bounds_max.y / grid_size.y) - ceil(models[0].bounds_min.y / grid_size.y) + 1,\
		floor(models[0].bounds_max.z / grid_size.z) - ceil(models[0].bounds_min.z / grid_size.z) + 1)

	var expected_size := size.x * size.y * size.z * 8
	if expected_size != light_grid.size():
		push_error("expected_size: %d does not match light_grid.size(): %d!" % [expected_size, light_grid.size()])
		return
	
	light_grid_offset = tech3_to_gd(models[0].bounds_min)
	light_grid_normalize = (size * grid_size) / options.unit_scale

	var ambient_color_images: Array[Image]
	var direct_color_images: Array[Image]
	var cartesian_images: Array[Image]
	
	var data_ambient: PackedByteArray
	data_ambient.resize(size.x * size.y * 3)
	var data_direct: PackedByteArray
	data_direct.resize(size.x * size.y * 3)
	var data_cart: PackedByteArray
	data_cart.resize(size.x * size.y * 3)

	var ambient_color: Color
	var direct_color: Color
	var color_index := 0
	for z in range(size.z):
		var amb := Image.new()
		var dir := Image.new()
		var cart := Image.new()
		var data_index := 0
		var cart_index := 0
		for y in range(size.y):
			for x in range(size.x):
				var lg_ambient_color := Color(light_grid[color_index], light_grid[color_index + 1], light_grid[color_index + 2])
				ambient_color = scale_color(lg_ambient_color)
				color_index += 3
				
				var lg_directional_color := Color(light_grid[color_index], light_grid[color_index + 1], light_grid[color_index + 2])
				direct_color = scale_color(lg_directional_color)
				color_index += 3
				
				data_ambient[data_index] = ambient_color.r8
				data_direct[data_index] = direct_color.r8
				data_index += 1
				
				data_ambient[data_index] = ambient_color.g8
				data_direct[data_index] = direct_color.g8
				data_index += 1
				
				data_ambient[data_index] = ambient_color.b8
				data_direct[data_index] = direct_color.b8
				data_index += 1
				
				var cartesian_from_spherical := spherical_to_cartesian(light_grid[color_index], light_grid[color_index + 1])
				data_cart[cart_index] = int((cartesian_from_spherical.x * 0.5 + 0.5) * 255.0)
				data_cart[cart_index + 1] = int((cartesian_from_spherical.y * 0.5 + 0.5) * 255.0)
				data_cart[cart_index + 2] = int((cartesian_from_spherical.z * 0.5 + 0.5) * 255.0)
				cart_index += 3
				color_index += 2

		amb.set_data(size.x, size.y, false, Image.FORMAT_RGB8, data_ambient)
		dir.set_data(size.x, size.y, false, Image.FORMAT_RGB8, data_direct)
		cart.set_data(size.x, size.y, false, Image.FORMAT_RGB8, data_cart)
		# FIXME: compress_from_channels ALSO resizes the image... why?
		# is it a BUG?
		#amb.compress_from_channels(Image.COMPRESS_BPTC, Image.USED_CHANNELS_RGBA)
		#dir.compress_from_channels(Image.COMPRESS_BPTC, Image.USED_CHANNELS_RGBA)
		ambient_color_images.append(amb)
		direct_color_images.append(dir)
		cartesian_images.append(cart)
		
	var ambient_tex := ImageTexture3D.new()
	ambient_tex.create(Image.FORMAT_RGB8, size.x, size.y, size.z, false, ambient_color_images)
	#ResourceSaver.save(ambient_tex, "res://test_ambient.res")
	var direct_tex := ImageTexture3D.new()
	direct_tex.create(Image.FORMAT_RGB8, size.x, size.y, size.z, false, direct_color_images)
	#ResourceSaver.save(directional_tex, "res://test_directional.res")
	var cartesian_tex := ImageTexture3D.new()
	cartesian_tex.create(Image.FORMAT_RGB8, size.x, size.y, size.z, false, cartesian_images)
	
	light_grid_ambient = ambient_tex
	light_grid_direct = direct_tex
	light_grid_cartesian = cartesian_tex


# TODO: should we ever try to use this for anything?
func parse_vis_data(vis_data_lump) -> void:
	bsp_file.seek(vis_data_lump.offset)
	if (vis_data_lump.length > 0):
		vis_data = BSPVisData.new(bsp_file.get_32(), bsp_file.get_32())
		vis_data.bit_sets = bsp_file.get_buffer(vis_data.num_clusters * vis_data.bytes_per_cluster)
	print("vis clusters: ", vis_data.num_clusters)
	print("vis data size: ", vis_data.bit_sets.size())


# Many brushes end up being axis-aligned
# so let's generate BoxShapes for those!
# TODO: could try to also create rotated boxes, probably not needed though
func try_box_from_convex_points(points: PackedVector3Array) -> Dictionary:
	if points.size() != 8:
		return {}  # can't be a box unless exactly 8 points

	const EPSILON: float = 0.001 # TODO: tighten this?
	
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

	# box ahoy!
	var box := BoxShape3D.new()
	box.size = aabb.size.abs()
	var center = aabb.position + aabb.size * 0.5

	# return a dictionary because we'll need to set the transform of the actual collisionbody later
	return {
		"shape": box,
		"transform": Transform3D(Basis(), center)
	}


# TODO: these HAVE to be axis-aligned since they just use the fog box shape, rotating the node after is a b... ig pain.
func build_fog_volume(points: PackedVector3Array, texture_id: int) -> FogVolume:
	var material := material_from_path(texture_id, -1)
	if material is not FogMaterial:
		push_warning("Fog volume requires a FogMaterial! Creating a placeholder.")
		material = FogMaterial.new()
	var center := Vector3.ZERO
	for p in points:
		center += p
	center /= points.size()
	
	var aabb := AABB()
	
	for p in points:
		aabb = aabb.expand(p - center)
	
	var basis := Basis.IDENTITY
	
	var size = aabb.size
	
	var fog := FogVolume.new()
	fog.material = material
	fog.shape = RenderingServer.FOG_VOLUME_SHAPE_BOX
	fog.size = size
	fog.transform = Transform3D(basis, center)
	
	return fog


func add_collisions(bsp_model: BSPModel, parent: Node) -> void:
	var collision_body: CollisionObject3D

	var collision_brushes: Array[BSPBrush] # brushes
	var collision_patches := {}#PackedVector3Array() # patches as vertices
	
	# TODO: maybe we can get away with reducing this...
	var patch_collision_subdivisions: float = options.patch_detail
	var stride := patch_collision_subdivisions + 1
	
	var water_body: Node3D
	var slime_body: Node3D
	var lava_body: Node3D
	
	# try to guess if the parent is a physics scene
	if parent is CollisionObject3D:
		collision_body = parent
	else:
		collision_body = StaticBody3D.new()
		parent.add_child(collision_body, true)
		collision_body.owner = bsp_scene

	# get brushes for this model
	for i in range(bsp_model.brush, bsp_model.brush + bsp_model.num_brushes):
		collision_brushes.append(brushes[i])

	# get patches for this model (if any)
	# first, de-dup surfaces (because we want one shape per surface)
	#for f in range(bsp_model.face, bsp_model.face + bsp_model.num_faces):
		#var face := faces[f]
		#
		#if not collision_patches.has(face.texture_id):
			#collision_patches[face.texture_id] = face
	#
	#for face: BSPFace in collision_patches:
		#if face.type & FACE_TYPE.PATCH:
			#var width := face.size[0]
			#var height := face.size[1]
			#
			#for py in range(0, height - 1, 2):
				#for px in range(0, width - 1, 2):
					#var ctrl := []
					#var grid := []
					#
					#for j in range(3):
						#for i in range(3):
							#var idx := face.start_vert_index + (py + j) * width + (px + i)
							#ctrl.append(vertices[idx])
							#
					#for y in range(patch_collision_subdivisions + 1):
						#var ty := float(y) / patch_collision_subdivisions
						#var row := []
						#
						#for x in range(patch_collision_subdivisions + 1):
							#var tx := float(x) / patch_collision_subdivisions
							#
							#var r0 = bezier3(ctrl[0].position, ctrl[1].position, ctrl[2].position, tx)
							#var r1 = bezier3(ctrl[3].position, ctrl[4].position, ctrl[5].position, tx)
							#var r2 = bezier3(ctrl[6].position, ctrl[7].position, ctrl[8].position, tx)
#
							#var pos = bezier3(r0, r1, r2, ty)
#
							#row.append(pos)
#
						#grid.append(row)
						#
					#for y in range(patch_collision_subdivisions):
						#for x in range(patch_collision_subdivisions):
							#var v0: Vector3 = grid[y][x]
							#var v1: Vector3 = grid[y][x + 1]
							#var v2: Vector3 = grid[y + 1][x]
							#var v3: Vector3 = grid[y + 1][x + 1]
#
							## triangle 1
							#collision_patches.append_array([v0, v2, v1])
#
							## triangle 2
							#collision_patches.append_array([v1, v2, v3])

	# now make the collision geometry
	# TODO: clean this up, just a copy/paste from the old method
	for brush: BSPBrush in collision_brushes:
		var texture_id: int = brush.texture_id
		var content_flags: int = textures[texture_id].content_flags
		var surface_flags: int = textures[texture_id].flags
		var collision_parent = collision_body

		if not content_flags & (CONTENT_FLAGS.SOLID | CONTENT_FLAGS.PLAYERCLIP | CONTENT_FLAGS.MONSTERCLIP | CONTENT_FLAGS.WATER | CONTENT_FLAGS.SLIME | CONTENT_FLAGS.LAVA | CONTENT_FLAGS.FOG):
			continue
		# TODO: handle per-SURFACE collision flags as well... going to require a totally different approach than computing from planes, may not be worth level of effort.
		# thankfully most of those are just visual.
		
		if content_flags & CONTENT_FLAGS.WATER:
			if !water_body:
				water_body = options.water_scene.instantiate()
				parent.add_child(water_body, true)
				water_body.owner = bsp_scene
			collision_parent = water_body
		if content_flags & CONTENT_FLAGS.SLIME:
			if !slime_body:
				slime_body = options.slime_scene.instantiate()
				parent.add_child(slime_body, true)
				slime_body.owner = bsp_scene
			collision_parent = slime_body
		if content_flags & CONTENT_FLAGS.LAVA:
			if !lava_body:
				lava_body = options.lava_scene.instantiate()
				parent.add_child(lava_body, true)
				lava_body.owner = bsp_scene
			collision_parent = lava_body

		# TODO: idtech3 shader files can take precedence, so for example:
		# NONSOLID might not actually mean non-solid in a collision sense,
		# because the shader says it actually is solid. Cool...

		var metadata := []
		var collision_shapes := []
		var bp: Array[Plane] # brush planes
		# since we lose surface_flags and such as Godot
		# has no way to store per-face stuff
		var plane_metadata := {}
		for i in range(brush.brush_side, (brush.brush_side + brush.num_brush_sides)):
			var plane_index := brush_sides[i].plane
			var plane := planes[plane_index]
			var plane_normal := quantize_normal(plane.normal)
			bp.append(plane)
			# quantized normal will be used as the key
			# can be checked with quantized normal lookup
			# for collisions and raycasts!
			# TODO: make this optional
			plane_metadata[plane_normal] = {
				# should this be the texture_id instead?
				"texture_name" : textures[brush_sides[i].texture_id].name,
				"flags" : surface_flags,
				"content_flags" : content_flags
			}
			metadata.append(plane_metadata)

		var points := Geometry3D.compute_convex_mesh_points(bp)
		
		# special handling for fog, since it's really more of a volume like a collision rather than a mesh.
		# putting it here so we can use verts for the shape
		if content_flags & CONTENT_FLAGS.FOG:
			var fog_child := build_fog_volume(points, texture_id)
			parent.add_child(fog_child)
			fog_child.owner = bsp_scene
			continue
		var try_box := try_box_from_convex_points(points)

		if try_box:
			collision_shapes.append(try_box)
		else:
			var collision := ConvexPolygonShape3D.new()
			collision.points = points
			collision_shapes.append(collision)

		for i in range(collision_shapes.size()):
			var collision_shape := CollisionShape3D.new()
			collision_parent.add_child(collision_shape, true)
			if collision_shapes[i] is ConvexPolygonShape3D:
				collision_shape.shape = collision_shapes[i]
				collision_shape.name = "ConvexPolygonShape3D"
			else:
				collision_shape.shape = collision_shapes[i].shape
				collision_shape.transform = collision_shapes[i].transform
				collision_shape.name = "BoxShape3D"
			collision_shape.owner = bsp_scene
			collision_shape.set_meta("planes", metadata[i])

	#if not collision_patches.is_empty():
		#for p in collision_patches:
			#var concave_polygon_shape := ConcavePolygonShape3D.new()
			#var collider := CollisionShape3D.new()
			#
			#concave_polygon_shape.set_faces(p)
			#collider.shape = concave_polygon_shape
			#
			#collision_body.add_child(collider, true)
			#collider.owner = bsp_scene


# get all the entities that aren't lights or worldspawn and...
# put them in the scene!
# ... if they're found in the entity map, that is.
# using an ConfigFile here because it's readily reusable
# TODO: also provide an entities directory option?
func add_entities() -> void:
	var entity_map := ConfigFile.new()
	var err := entity_map.load(options.entity_map)
	if err != OK:
		push_error("Failed to load entity map: %s" % error_string(err))
		return
	if !entity_map.has_section("entities"):
		push_error("Entity map is missing [entities] section, abandoning entity import.")
		return
	#print(entity_map.get_section_keys("entities"))
	for entity in entities:
		var entity_class: String = entity["classname"]
		# TODO: do we actually want to import info_null? The whole point is that it's null at runtime...
		# also lights are handled elsewhere.
		if entity_class == "worldspawn" or entity_class == "light" or entity_class == "info_null":
			continue
		if !entity_map.has_section_key("entities", entity_class):
			if options.print_missing_entities:
				push_warning("%s not found in entity map, skipping." % entity_class)
			continue
		# probably will never hit this, still worth checking.
		if !entity_map.get_value("entities", entity_class):
			# throws its own error.
			continue
		# finally...
		var entity_path: String = entity_map.get_value("entities", entity_class)
		print("Loading entity: %s from scene path: %s" % [entity_class, entity_path])
		if !FileAccess.file_exists(entity_path):
			push_error("Failed to load entity %s! Please verify path: %s" % [entity_class, entity_path])
			continue

		var entity_scene: Node3D = load(entity_path).instantiate()
		#print(entity)
		# most idtech3 brush entities seem to expect Vector3.ZERO
		# for example doors use this and then move on global
		# coordinates rather than relative.
		# the exception is when "origin" shaders are used.
		var origin := Vector3.ZERO
		# jitspoe's importer directly sets angle, angles, etc. to
		# rotate an entity, however idTech3 entities might use these
		# as directions instead of rotations
		# so anything other than "origin" should be handled
		# per entity.
		if entity.has("origin"):
			origin = entity["origin"]
			
		for key in entity.keys():
			var dest_value = entity_scene.get(key)
			if dest_value != null:
				#print("Entity %s: %s" % [key, entity[key]])
				# TODO: type checking maybe
				entity_scene.set(key, entity[key])
				#print("Destination value '%s': %s" % [key, entity_scene.get(key)])
				#entity_scene[key] = entity[key]
			#print(entity_scene.get(key))
		
		bsp_scene.add_child(entity_scene, true)
		entity_scene.transform.origin = origin
		entity_scene.owner = bsp_scene
		
		if entity.has("model") and entity["model"][0] == '*':
			# this entity has a brush model (door, lift, trigger, etc)
			var model_index: int = entity["model"].substr(1).to_int()

			add_bsp_model(models[model_index], entity_scene)
			add_collisions(models[model_index], entity_scene)
			#add_brush_collisions(models[model_index], entity_scene)


### New patch functions ###

# unified bezier processer
func bezier3(a: Variant, b: Variant, c: Variant, t: float) -> Variant:
	var it: float = 1.0 - t
	return a * (it * it) + b * (2.0 * it * t) + c * (t * t)


func bezier3_vertex(a: BSPVertex, b: BSPVertex, c: BSPVertex, t: float) -> BSPVertex:
	# HACK: not really meant to be instantiated like this, can't overload constructors though -_(^_^)_-
	var v := BSPVertex.new(-1, Vector3.ZERO, 0, 0, 0, 0, Vector3.UP, PackedByteArray([255, 255, 255, 255]))
	
	v.position = bezier3(a.position, b.position, c.position, t)
	v.normal = bezier3(a.normal, b.normal, c.normal, t).normalized()
	v.uv = bezier3(a.uv, b.uv, c.uv, t)
	v.uv2 = bezier3(a.uv2, b.uv2, c.uv2, t)
	v.color = a.color.lerp(b.color, t).lerp(c.color, t * t) # close enough
	
	return v


func tessellate_patch_face(face: BSPFace, surface: Dictionary, vertex_color: bool, subdivisions: int) -> void:
	var st: SurfaceTool = surface.st
	
	var width := face.size[0]
	var height := face.size[1]
	
	for py in range(0, height - 1, 2):
		for px in range(0, width - 1, 2):
			var ctrl := []
			var grid := []
			
			for j in range(3):
				for i in range(3):
					var idx := face.start_vert_index + (py + j) * width + (px + i)
					ctrl.append(vertices[idx])
			
			for y in range(subdivisions + 1):
				var ty := float(y) / float(subdivisions)
				var row := []
				
				for x in range(subdivisions + 1):
					var tx := float(x) / float(subdivisions)
					
					var r0 = bezier3_vertex(ctrl[0], ctrl[1], ctrl[2], tx)
					var r1 = bezier3_vertex(ctrl[3], ctrl[4], ctrl[5], tx)
					var r2 = bezier3_vertex(ctrl[6], ctrl[7], ctrl[8], tx)
					
					var vtx = bezier3_vertex(r0, r1, r2, ty)
					
					if options.import_lightmaps and external_lightmaps.is_empty():
						var lm_col := face.lightmap_id % lightmap_columns
						var lm_row := face.lightmap_id / lightmap_columns
						vtx.uv2.x = (vtx.uv2.x + lm_col) / lightmap_columns
						vtx.uv2.y = (vtx.uv2.y + lm_row) / lightmap_rows
					
					row.append(vtx)
				
				grid.append(row)

			var base: int = surface.vertex_count
			var stride := subdivisions + 1
			
			for y in range(subdivisions + 1):
				for x in range(subdivisions + 1):
					var vtx: BSPVertex = grid[y][x]
					add_vertex_to_surface(st, vtx, vtx.uv2, vertex_color)
					surface.vertex_count += 1
			
			for y in range(subdivisions):
				for x in range(subdivisions):
					var i0 = base + y * stride + x
					var i1 = i0 + 1
					var i2 = i0 + stride
					var i3 = i2 + 1

					st.add_index(i0)
					st.add_index(i2)
					st.add_index(i1)

					st.add_index(i1)
					st.add_index(i2)
					st.add_index(i3)


func add_vertex_to_surface(st: SurfaceTool, v: BSPVertex, uv2: Vector2, vertex_color := false):
	st.set_normal(v.normal)
	st.set_uv(v.uv)
	st.set_uv2(uv2)

	if vertex_color:
		st.set_color(v.color)

	st.add_vertex(v.position)


func generate_surface(s: Dictionary, texture_id: int, lightmap_id: int, transparent := false) -> Dictionary:
	if not s.has(texture_id):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.set_material(material_from_path(texture_id, lightmap_id))
		s[texture_id] = {
			"st": st,
			"vertex_count": 0,
			"transparent": transparent
		}
	return s[texture_id]


func create_bsp_mesh(mesh: ArrayMesh, parent: Node) -> void:
	if !mesh or mesh.get_surface_count() == 0:
		return
	
	if !options.import_lightmaps:
		var texel_size: float = (1.0 / options.unit_scale) * 4.0
		mesh.lightmap_unwrap(bsp_scene.transform, texel_size)
	
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	parent.add_child(mi, true)
	mi.owner = bsp_scene


func add_bsp_model(bsp_model: BSPModel, parent: Node) -> void:
	var surfaces := {}
	#var transparent_surfaces := {}

	for f in range(bsp_model.face, bsp_model.face + bsp_model.num_faces):
		var face := faces[f]

		var texture_id := face.texture_id
		var lightmap_id := face.lightmap_id
		var vertex_color := false if options.import_lightmaps or lightmap_id >= 0 else true
		
		var surface_flags := textures[texture_id].flags
		var content_flags := textures[texture_id].content_flags
		
		if surface_flags & (SURFACE_FLAGS.NODRAW | SURFACE_FLAGS.HINT | SURFACE_FLAGS.SKIP):
			continue
		if options.remove_skies and surface_flags & SURFACE_FLAGS.SKY:
			continue
		if content_flags & CONTENT_FLAGS.FOG:
			continue
		
		var surface: Dictionary
		
		if content_flags & (CONTENT_FLAGS.LAVA | CONTENT_FLAGS.SLIME | CONTENT_FLAGS.WATER | CONTENT_FLAGS.TRANSLUCENT):
			surface = generate_surface(surfaces, texture_id, lightmap_id, true)
		else:
			surface = generate_surface(surfaces, texture_id, lightmap_id)
		
		var st: SurfaceTool = surface.st
		var offset: int = surface.vertex_count
		
		match face.type:
			FACE_TYPE.POLYGON, FACE_TYPE.MESH:
				for v in range(face.start_vert_index, face.start_vert_index + face.num_verts):
					var vertex := vertices[v]
					var uv2 := vertex.uv2
					
					if options.import_lightmaps and external_lightmaps.is_empty():
						var lm_col := face.lightmap_id % lightmap_columns
						var lm_row := face.lightmap_id / lightmap_columns
						uv2.x = (uv2.x + lm_col) / lightmap_columns
						uv2.y = (uv2.y + lm_row) / lightmap_rows
					
					add_vertex_to_surface(st, vertex, uv2, vertex_color)
					surface.vertex_count += 1

				for i in range(face.start_index, face.start_index + face.num_indices):
					st.add_index(indices[i] + offset)

			FACE_TYPE.PATCH:
				tessellate_patch_face(face, surface, vertex_color, options.patch_detail)

	var current_mesh := ArrayMesh.new()
	
	for id in surfaces:
		var st: SurfaceTool = surfaces[id].st
		var transparent: bool = surfaces[id].transparent

		#st.index()
		st.optimize_indices_for_cache()
		#st.generate_normals()
		#st.generate_tangents()
		
		# SPLIT MODE: right now, just one mesh per surface
		if options.split_mesh or surfaces[id].transparent:
			var mesh := st.commit()
			st.clear()
			
			create_bsp_mesh(mesh, parent)
			continue
			
		# BATCH MODE: one mesh per MAX_MESH_SURFACES
		if current_mesh.get_surface_count() >= RenderingServer.MAX_MESH_SURFACES:
			create_bsp_mesh(current_mesh, parent)
			current_mesh = ArrayMesh.new()

		st.commit(current_mesh)
		st.clear()

	create_bsp_mesh(current_mesh, parent)

### Transparent surfaces mesh section (for proper sorting) ###
	#for id in transparent_surfaces:
		#var st: SurfaceTool = transparent_surfaces[id].st
		#
		##st.index()
		#st.optimize_indices_for_cache()
		##st.generate_normals()
		##st.generate_tangents()
		#
		## transparent meshes are always split by surface for sorting
		#var mesh := st.commit()
		#st.clear()
		#
		#create_bsp_mesh(mesh, parent)


# if you're experimenting with Q3A maps, they do come with light ents
# however their radii are super tiny, not sure why.
# anything you compile with q3map2 should have the correct scale though.
func add_lights() -> void:
	# for pointing targeted spotlights correctly
	var light_targets: Dictionary
	# TODO: make this more efficient than two loops...
	for entity: Dictionary in entities:
		if entity.classname != "light" and entity.has("targetname") and entity.has("origin"):
			light_targets[entity.targetname] = entity.origin
	for entity: Dictionary in entities:
		if entity.classname == "light":
			var light_node: Light3D
			var light_value := 300.0 # idtech3 default
			var light_color := Color.WHITE
			var light_range := 1.0

			# q3map2 only seems to respect "_color" for lights though
			if entity.has("_color") or entity.has("color"):
				light_color = entity._color if entity.has("_color") else entity.color
			if entity.has("light"):
				light_value = entity.light.to_float()

			if entity.has("_sun") and !options.entity_shadow_light:
				light_node = DirectionalLight3D.new()
				#light_node.look_at_from_position(entity.origin, light_targets[entity.target])
				light_node.global_transform = look_at_safely(entity.origin, light_targets[entity.target])
			elif entity.has("target") and !entity.has("_sun"): # this is a spotlight for sure
				light_node = SpotLight3D.new()
				if entity.has("radius"):
					light_node.spot_angle = entity.radius.to_float() * (1.0 / options.unit_scale)
				if light_targets.has(entity.target):
					light_node.global_transform = look_at_safely(entity.origin, light_targets[entity.target])
				light_node.spot_range = light_value * (1.0 / options.unit_scale)
				light_node.spot_attenuation = options.light_attenuation
				if options.light_attenuation > 0.0:
					light_node.light_energy *= 1.5
			else:
				light_node = OmniLight3D.new()
				light_node.omni_range = light_value * (1.0 / options.unit_scale)
				light_node.omni_attenuation = options.light_attenuation
				#if options.light_attenuation > 0.0:
					#light_node.omni_range *= 3.0
					#light_node.light_energy *= 1.5

			light_node.light_volumetric_fog_energy = 0.0
			if entity.has("fog_energy"):
				light_node.light_volumetric_fog_energy = entity["fog_energy"].to_float()


			light_node.position = entity.origin
			#light_node.light_energy = light_value * options.light_brightness_scale
			light_node.light_energy = light_value * (options.light_brightness_multiplier / 300.0)
			light_node.light_color = light_color
			light_node.shadow_enabled = true # make some kind of option or ent key read?
			# light_node.light_bake_mode = Light3D.BAKE_STATIC # maybe?
			if options.import_lightmaps or (worldspawn.has("_q3map2_cmdline") and worldspawn["_q3map2_cmdline"].contains("-bounceonly")):
				# light everything EXCEPT the map on layer 1
				light_node.light_cull_mask = 4294967294

			bsp_scene.add_child(light_node, true)
			light_node.owner = bsp_scene


# this adds a directional light which will provide a flat
# illumination to the entire level (assuming the shader is similar to
# one of the example shaders), not cast shadows from the world on
# vis 1, and cast shadows from meshes on other visibility layers.
# this seems like a more desirable approach to me than just
# putting the lightmap onto the EMISSION channel.
# though EMISSION and no lights at all is a bit more performant...
# but no decals!
# TODO: maybe make a backup shader for when this isn't desired?
func add_world_light() -> void:
	var directional_light := DirectionalLight3D.new()
	#directional_light.rotation_degrees = Vector3(-80.0, 45.0, 0)
	directional_light.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	if options.import_lightmaps:
		#directional_light.shadow_caster_mask = 4294967294
		#directional_light.light_cull_mask = 1
		#directional_light.shadow_opacity = 0.75
		directional_light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		directional_light.directional_shadow_max_distance = 50.0
	# with the current shader, we still need either a directional light
	# or an ambient color, and directional light at least respects
	# culling and visibility layers...
	if options.entity_shadow_light:
		directional_light.shadow_enabled = true
	bsp_scene.add_child(directional_light, true)
	directional_light.owner = bsp_scene
	# if there's a "_sun" light, let's use its direction
	# ... maybe... can look terrible for some light angles
	#for entity: Dictionary in entities:
		#if entity.has("_sun"):
			#for e: Dictionary in entities:
				#if e.has("targetname") and e["targetname"] == entity["target"]:
					#directional_light.look_at_from_position(entity["origin"], e["origin"])


# TODO: I don't know if billboards are automatically sprites (like flares)
# so maybe some need to be built like mesh geometry?
# TODO: using a MultiMesh3D means you can't cull per flare
# FIXME: not sure how flares are actually set up in idtech3
# so consider this a placeholder.
# TODO: can entities have billboards? if so, scrap the multimesh approach.
#func add_billboards(bsp_model: BSPModel, parent: Node) -> void:
	#var billboard_faces := face_groups(bsp_model, [FACE_TYPE.BILLBOARD])
	#if billboard_faces.is_empty():
		#return
#
	#for billboard_group: Array in billboard_faces:
		#var texture_id: int = billboard_group[0]
		#var multi_mesh_instance := MultiMeshInstance3D.new()
		#multi_mesh_instance.name = "MultiMeshInstance3D_Billboards_%d" % texture_id
		#var multi_mesh := MultiMesh.new()
		#var mesh := QuadMesh.new()
		#var material := StandardMaterial3D.new()
		#multi_mesh_instance.multimesh = multi_mesh
		#material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		#material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		#mesh.material = material
		#multi_mesh.mesh = mesh
		#multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
		#multi_mesh.instance_count = billboard_faces[billboard_group].size()
		#var i := 0
		#for billboard: BSPFace in billboard_faces[billboard_group]:
			#var transform := Transform3D.IDENTITY
			#transform.origin = billboard.lm_origin
			#multi_mesh.set_instance_transform(i, transform)
			#i += 1
	#
		#parent.add_child(multi_mesh_instance, true)
		#multi_mesh_instance.owner = bsp_scene
	#for i in billboards.size():
		#print("Billboard Texture: ", textures[billboards[i].texture_id].name)
		#var test := MeshInstance3D.new()
		#var quad := QuadMesh.new()
		#var material := StandardMaterial3D.new()
		#material.albedo_color = Color.WHITE
		#material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		#material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		#quad.material = material
		#test.mesh = quad
		#var position = billboards[i].lm_origin
		#bsp_scene.add_child(test)
		#test.owner = bsp_scene
		#test.position = position
#	print(billboards.size())

func add_occluder() -> void:
	var ws: BSPModel = models[0]

	var occluder_vertices := PackedVector3Array()
	var occluder_indices := PackedInt32Array()

	const SUBDIVISIONS = 2 # fixed value for occluders from patches
	var stride := SUBDIVISIONS + 1
	var offset := 0

	for f in range(ws.face, ws.face + ws.num_faces):
		var face: BSPFace = faces[f]

		if face.type & FACE_TYPE.BILLBOARD:
			continue

		if textures[face.texture_id].flags & (SURFACE_FLAGS.NODRAW | SURFACE_FLAGS.SKIP | SURFACE_FLAGS.HINT):
			continue

		if textures[face.texture_id].content_flags & (CONTENT_FLAGS.TRANSLUCENT | CONTENT_FLAGS.WATER | CONTENT_FLAGS.SLIME | CONTENT_FLAGS.LAVA | CONTENT_FLAGS.FOG):
			continue

		if textures[face.texture_id].flags & SURFACE_FLAGS.SKY and options.remove_skies:
			continue

		if face.type & FACE_TYPE.PATCH:
			var previous_size := occluder_vertices.size()

			var width := face.size[0]
			var height := face.size[1]

			for py in range(0, height - 1, 2):
				for px in range(0, width - 1, 2):
					var ctrl := []
					var grid := []
					
					var base := occluder_vertices.size()

					for j in range(3):
						for i in range(3):
							var idx := face.start_vert_index + (py + j) * width + (px + i)
							ctrl.append(vertices[idx].position)

					### Occluder vertices
					for y in range(SUBDIVISIONS + 1):
						var ty := float(y) / SUBDIVISIONS
						for x in range(SUBDIVISIONS + 1):
							var tx := float(x) / SUBDIVISIONS
							
							var r0 = bezier3(ctrl[0], ctrl[1], ctrl[2], tx)
							var r1 = bezier3(ctrl[3], ctrl[4], ctrl[5], tx)
							var r2 = bezier3(ctrl[6], ctrl[7], ctrl[8], tx)
							
							var pos = bezier3(r0, r1, r2, ty)
							
							occluder_vertices.append(pos)

					### Occluder indices
					for y in range(SUBDIVISIONS):
						for x in range(SUBDIVISIONS):
							var i0 := base + y * stride + x
							var i1 := i0 + 1
							var i2 := i0 + stride
							var i3 := i2 + 1

							occluder_indices.append_array([
								i0, i1, i3,
								i0, i3, i2
							])

			offset += occluder_vertices.size() - previous_size
		else:
			for v in range(face.start_vert_index, face.start_vert_index + face.num_verts):
				occluder_vertices.append(vertices[v].position)

			for i in range(face.start_index, face.start_index + face.num_indices):
				occluder_indices.append(indices[i] + offset)

			offset += face.num_verts

	var occluder := ArrayOccluder3D.new()
	occluder.set_arrays(occluder_vertices, occluder_indices)

	var instance := OccluderInstance3D.new()
	instance.occluder = occluder

	bsp_scene.add_child(instance, true)
	instance.owner = bsp_scene


func read_bsp(source_file: String) -> Node3D:
	clear_data() # not sure this is needed
	bsp_file = FileAccess.open(source_file, FileAccess.READ)

	# TODO: move this out so we can use separate classes, etc.
	# for RBSP, etc.
	var header := {
		magic = bsp_file.get_buffer(4).get_string_from_ascii(),
		version = bsp_file.get_32(),
		directory = parse_lumps()
	}
	
	# TODO: support other idtech3 game map formats (especially JK/JA)	
	if (header.magic != "IBSP"):# and header.magic != "RBSP"):
		push_error("Not a supported BSP file!")
		bsp_file.close()
		return null
	else:
		var version_string: String
		match header.version:
			46: version_string = "Quake 3 Arena"
			47: version_string = "Return to Castle Wolfenstein"
			_: version_string = "Unknown map version!"
		print("%s, version: %d - %s" % [header.magic, header.version, version_string])
	
	bsp_scene = BSPScene.new()
	
	parse_entities(header.directory[LUMP_TYPE.ENTITIES])
	parse_textures(header.directory[LUMP_TYPE.TEXTURES])
	parse_planes(header.directory[LUMP_TYPE.PLANES])
	#parse_nodes(header.directory[LUMP_TYPE.NODES])
	#parse_leafs(header.directory[LUMP_TYPE.LEAFS])
	#parse_leaf_faces(header.directory[LUMP_TYPE.LEAFFACES])
	#parse_leaf_brushes(header.directory[LUMP_TYPE.LEAFBRUSHES])
	parse_models(header.directory[LUMP_TYPE.MODELS])
	parse_brushes(header.directory[LUMP_TYPE.BRUSHES])
	parse_brush_sides(header.directory[LUMP_TYPE.BRUSHSIDES])
	parse_vertices(header.directory[LUMP_TYPE.VERTEXES])
	parse_indices(header.directory[LUMP_TYPE.MESHVERTS])
	# strictly speaking, not doing anything with the "effects" lump
	# gives us a count of potential fogs though
	parse_effects(header.directory[LUMP_TYPE.EFFECTS])
	parse_faces(header.directory[LUMP_TYPE.FACES])
	if options.import_lightmaps:
		parse_lightmaps(header.directory[LUMP_TYPE.LIGHTMAPS])
	if options.import_lightgrid:
		parse_light_grid(header.directory[LUMP_TYPE.LIGHTVOLS])
	#parse_vis_data(header.directory[LUMP_TYPE.VISDATA])

	bsp_scene.worldspawn = worldspawn
	
	if options.import_lightgrid:
		bsp_scene.light_grid_ambient = light_grid_ambient
		bsp_scene.light_grid_direct = light_grid_direct
		bsp_scene.light_grid_cartesian = light_grid_cartesian
		bsp_scene.light_grid_normalize = light_grid_normalize
		bsp_scene.light_grid_offset = light_grid_offset

	if options.occlusion_culling:
		add_occluder()

	add_bsp_model(models[0], bsp_scene)
	add_collisions(models[0], bsp_scene)
	#add_brush_collisions(models[0], bsp_scene)
	add_entities()
	if options.import_lights:
		add_lights()
	#if options.import_billboards:
		#add_billboards(models[0], bsp_scene)
	if options.import_lightmaps:
		add_world_light()
	
	bsp_scene.name = source_file.get_file().get_basename()

	bsp_file.close()
	return bsp_scene
