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
var lightmaps: Array[Texture]
var vis_data: BSPVisData

var light_grid_normalize := Vector3.ZERO
var light_grid_offset := Vector3.ZERO
var light_grid_ambient: ImageTexture3D
var light_grid_direct: ImageTexture3D
var light_grid_cartesian: ImageTexture3D

var worldspawn: Dictionary

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
	VISDATA
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
	lightmaps.clear()
	vis_data = null
	light_grid_normalize = Vector3.ZERO
	light_grid_offset = Vector3.ZERO
	light_grid_ambient = null
	light_grid_direct = null
	light_grid_cartesian = null


func split_face_groups(dict: Dictionary) -> Array[Dictionary]:
	var chunks: Array[Dictionary]
	var current_chunk: Dictionary = {}
	var counter := 0
	
	for key in dict.keys():
		current_chunk[key] = dict[key]
		counter += 1

		if counter >= MAX_MESH_SURFACES:
			chunks.append(current_chunk.duplicate())
			current_chunk.clear()
			counter = 0

	if current_chunk.size() > 0:
		chunks.append(current_chunk)

	return chunks


func face_groups(model: BSPModel, face_types: Array[FACE_TYPE]) -> Dictionary:
	var model_faces := {}
	
	for i in range(model.num_faces):
		var face_index = model.face + i
		var face = faces[face_index]

		if !face_types.has(face.type):
			continue
		
		var key: Array
		if options.import_lightmaps:
			key = [face.texture_id, face.lightmap_id]
		else:
			key = [face.texture_id, -1]
		
		if not model_faces.has(key):
			model_faces[key] = []
		model_faces[key].append(face)

	return model_faces


# TODO: I'm being lazy with patches right now, just split them when we hit MAX_MESH_SURFACES
func split_patches(patches: Array) -> Array:
	var result := []
	var i := 0
	
	while i < patches.size():
		result.append(patches.slice(i, MAX_MESH_SURFACES))
		i += MAX_MESH_SURFACES
	
	return result


# Use the maps texture name to perform a lookup in a user-defined
# materials path matching a string
# e.g. "textures/liquids/water_02" becomes
# "res://materials/liquids/water_02.material"
# TODO: this should be able to pull materials for maps in the
# user directory as well (and later maybe from .pk3)
func material_from_path(texture_id: int, lightmap_id: int) -> Material:
	var path_pattern: String = options.materials_path
	var texture_name: String = (textures[texture_id].name)
	var material_path := path_pattern.replace("{texture_name}", texture_name).replace("textures/", "")
	var material: Material

	if FileAccess.file_exists(material_path):
		if options.import_lightmaps and lightmap_id >= 0:
			# need to duplicate to apply lightmaps without affecting original material
			material = load(material_path).duplicate()
		else:
			# go ahead and just reference the material
			material = load(material_path)
	else:
		if options.fallback_materials:
			print("%s not found, creating fallback from texture" % material_path)
			material = material_from_texture(texture_id, lightmap_id)

	# for lightmaps to work we have to make some assumptions,
	# the shader being used must have some uniform like "lightmap_texture"
	# so it will have to be a custom shader, this won't work for StandardMaterial3D.
	if !lightmaps.is_empty() and material is ShaderMaterial and options.import_lightmaps and lightmap_id > 0:
		material.set_shader_parameter("lightmap_texture", lightmaps[lightmap_id])
	return material


# TODO: replace all of this with an idTech3 shader parser.
func material_from_texture(texture_id: int, lightmap_id: int) -> Material:
	var material: Material
	var face_texture: Texture2D
	var tex_path: String = (textures[texture_id].name).replace("textures/", options.textures_path)
	
	for ext: String in POSSIBLE_IMAGE_EXTENSIONS:
		var possible_file := "%s.%s" % [tex_path, ext]
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
		if !lightmaps.is_empty() and options.import_lightmaps and lightmap_id >= 0:
			# Doing it as another pass loses us ~500 FPS
			# TODO: make it optional and put that caveat into readme
			#var lightmap_material := ShaderMaterial.new()
			#lightmap_material.shader = load("res://addons/tech3bsp/shaders/lightmap.gdshader")
			#lightmap_material.set_shader_parameter("lightmap_texture", lightmaps[lightmap_id])
			#material.next_pass = lightmap_material
			material.set_shader_parameter("lightmap_texture", lightmaps[lightmap_id])
	
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
				lightmaps.append(ext_lm_image)
				entry = dir.get_next()
		else:
			print("No external or internal lightmaps found, abandoning lightmap import.")
			return

		lightmaps.reverse() # gotta flip the order apparently? TODO: test on more large lightmaps!
		print("external lightmaps: ",  lightmaps.size())
		return
	
	print("internal lightmaps: ", count)
	for i in range(count):
		var lightmap_bytes := bsp_file.get_buffer(DEFAULT_LIGHTMAP_LENGTH)
		var lightmap_colors: Color
		var pixel_size: int = DEFAULT_LIGHTMAP_SIZE
		var base_tex: Image
		# try to autodetect linear vs. sRGB lightmaps
		if worldspawn.has("_q3map2_cmdline") and worldspawn["_q3map2_cmdline"].contains("-nosRGBlight"):
			base_tex = Image.create_empty(pixel_size, pixel_size, false, Image.FORMAT_RGBF) # linear colorspace lightmap
		else:
			base_tex = Image.create_empty(pixel_size, pixel_size, false, Image.FORMAT_RGB8) # sRGB lightmap

		var l = 0
		for y in range(pixel_size):
			for x in range(pixel_size):
				lightmap_colors = scale_color(Color(lightmap_bytes[l], lightmap_bytes[l + 1], lightmap_bytes[l + 2]))
				base_tex.set_pixel(x, y, lightmap_colors)
				l += 3
		
		base_tex.generate_mipmaps()
		# Possible BUG! compress_from_channels resizes the image for some reason
		# in lightmaps this leads to big gross seams
		# and in lightgrids the scale is wrong
		#base_tex.compress_from_channels(Image.COMPRESS_BPTC, Image.USED_CHANNELS_RGB)
		var tex = ImageTexture.create_from_image(base_tex)
		lightmaps.append(tex)
		# TODO: optional internal lightmap image saving?
	#for lm in range(lightmaps.size()):
		#ResourceSaver.save(lightmaps[lm], "res://%s-%d.png" % ["lightmap", lm])


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


func add_brush_collisions(bsp_model: BSPModel, parent: Node) -> void:
	var collision_body: CollisionObject3D
	
	# try to guess if the parent is a physics scene
	if parent is CollisionObject3D:
		collision_body = parent
	else:
		collision_body = StaticBody3D.new()
		parent.add_child(collision_body, true)
		collision_body.owner = bsp_scene
	
	var water_body: Node3D
	var slime_body: Node3D
	var lava_body: Node3D
	
	#static_body.name = "StaticBody3D_BrushColliders"
	
	var collision_brushes: Array[BSPBrush]
	for i in range(bsp_model.num_brushes):
		collision_brushes.append(brushes[bsp_model.brush + i])
	# textures[b.texture_id].name

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


# for patches (bezier curves)
func bezier_basis_3(t: float) -> Array[float]:
	var b0 := (1.0 - t) * (1.0 - t)
	var b1 := 2.0 * t * (1.0 - t)
	var b2 := t * t
	return [b0, b1, b2]

func evaluate_patch(patch: Array, u: float, v: float) -> Vector3:
	var bu := bezier_basis_3(u)
	var bv := bezier_basis_3(v)
	var point := Vector3.ZERO

	for y in range(3):
		for x in range(3):
			var weight := bu[x] * bv[y]
			point += patch[y * 3 + x] * weight
	return point

func evaluate_patch_uvs(patch: Array, u: float, v: float) -> Vector2:
	var bu := bezier_basis_3(u)
	var bv := bezier_basis_3(v)
	var uv := Vector2.ZERO

	for y in range(3):
		for x in range(3):
			var weight := bu[x] * bv[y]
			uv += patch[y * 3 + x] * weight
	return uv

func evaluate_patch_color(patch: Array, u: float, v: float) -> Color:
	#print(patch[0][0] * 0)
	var bu := bezier_basis_3(u)
	var bv := bezier_basis_3(v)
	var result := Color(0, 0, 0, 0)
	for j: int in range(3):
		for i: int in range(3):
			var weight := bu[i] * bv[j]
			var color: Color = patch[j]

			result += color * weight
	return result

func tessellate_patch(patch: Array, divisions: int) -> PackedVector3Array:
	var verts: PackedVector3Array

	for iy in range(divisions):
		var v0 := iy / float(divisions)
		var v1 := (iy + 1) / float(divisions)
		for ix in range(divisions):
			var u0 := ix / float(divisions)
			var u1 := (ix + 1) / float(divisions)

			# Quad corners
			var p00 := evaluate_patch(patch, u0, v0)
			var p10 := evaluate_patch(patch, u1, v0)
			var p01 := evaluate_patch(patch, u0, v1)
			var p11 := evaluate_patch(patch, u1, v1)

			# Two triangles per quad
			verts.append_array([p00, p11, p10])  # Triangle 1
			verts.append_array([p00, p01, p11])  # Triangle 2

	return verts

# TODO: maybe... could just write one and return a Variant
# then it can handle Vector3 and Vector2 and Color
# instead of 3 separate functions... maybe...
func tessellate_patch_uvs(patch: Array, divisions: int) -> PackedVector2Array:
	var uvs: PackedVector2Array

	for iy in range(divisions):
		var v0 := iy / float(divisions)
		var v1 := (iy + 1) / float(divisions)
		for ix in range(divisions):
			var u0 := ix / float(divisions)
			var u1 := (ix + 1) / float(divisions)

			var uv00 := evaluate_patch_uvs(patch, u0, v0)
			var uv10 := evaluate_patch_uvs(patch, u1, v0)
			var uv01 := evaluate_patch_uvs(patch, u0, v1)
			var uv11 := evaluate_patch_uvs(patch, u1, v1)

			uvs.append_array([uv00, uv11, uv10])
			uvs.append_array([uv00, uv01, uv11])

	return uvs


func tessellate_patch_colors(patch: Array, divisions: int) -> PackedColorArray:
	var colors: PackedColorArray

	for iy in range(divisions):
		var v0 := iy / float(divisions)
		var v1 := (iy + 1) / float(divisions)
		for ix in range(divisions):
			var u0 := ix / float(divisions)
			var u1 := (ix + 1) / float(divisions)

			var c00 := evaluate_patch_color(patch, u0, v0)
			var c10 := evaluate_patch_color(patch, u1, v0)
			var c01 := evaluate_patch_color(patch, u0, v1)
			var c11 := evaluate_patch_color(patch, u1, v1)

			colors.append_array([c00, c11, c10])
			colors.append_array([c00, c01, c11])

	return colors

# TODO (maybe): rewrite all of the above into this unified function
#func tessellate_patch_unified(patch: Dictionary) -> Dictionary:
	#var bez_basis_3 = func(t: float) -> Array[float]:
		#var omt = 1.0 - t
		#return [omt * omt, 2.0 * t * omt, t * t]
	#
	#var eval = func()
	#
	#print(patch)
	#var result: Dictionary
	#return result

# beziers and whatnot - handles both mesh and collision
# TODO: fuse vertices?
func add_patches(bsp_model: BSPModel, parent: Node) -> void:
	var patch_faces := face_groups(bsp_model, [FACE_TYPE.PATCH])
	# I doubt we'll ever have a patch with more than 256 faces... but just in case
	var patch_chunks := split_face_groups(patch_faces)
	
	if patch_chunks.is_empty() or patch_faces.is_empty():
		return
	
	for patch_chunk in patch_chunks:
		# since the mesh is generated in the inner loop we aren't actually using chunks right now
		# going to leave it alone unless I ever actually see a situation where a patch with >256 faces exists.
		for patch_group: Array in patch_chunk:
			var mesh := ArrayMesh.new()
			var texture_id: int = patch_group[0]
			var lightmap_id: int = patch_group[1]
			var surface_flags: SURFACE_FLAGS = textures[texture_id].flags
			var content_flags: CONTENT_FLAGS = textures[texture_id].content_flags

			# Pretty sure we can just jump out if it's a fog patch
			# Godot fog volumes can't have arbitary shapes
			# ... well, they sort of can with density textures...
			# ugh... TODO
			if content_flags & CONTENT_FLAGS.FOG:
				continue

			var collision_faces: PackedVector3Array

			var metadata := {
					"texture_name" : textures[texture_id].name,
					"flags" : surface_flags,
					"content_flags" : content_flags
			}

			var surface_tool := SurfaceTool.new()
			var material := material_from_path(texture_id, lightmap_id)
			var patches: Array[Dictionary]
			
			for face: BSPFace in patch_faces[patch_group]:
				for m in range((face.size[1] - 1) / 2):
					var j := 2 * m
					for n in range((face.size[0] - 1) / 2):
						var i := 2 * n
						var patch := {
							"verts": [],
							"uvs": [],
							"uv2s": [],
							"colors": []
						}
						for dy in range(3):
							for dx in range(3):
								var vx := i + dx
								var vy := j + dy
								var bsp_vertex := vertices[face.start_vert_index + (vy * face.size[0] + vx)]

								patch["verts"].append(bsp_vertex.position)
								patch["uvs"].append(bsp_vertex.uv)
								patch["uv2s"].append(bsp_vertex.uv2)
								patch["colors"].append(bsp_vertex.color)
						patches.append(patch)

			# HACK: patches should have verts, etc. deduped to reduce potential surfaces
			# this is just a workaround to avoid error.
			# e.g. https://lvlworld.com/review/id:2091
			# FIXME: WRATH maps have sooooo many patches...
			var patch_splits := split_patches(patches)

			for patch_split: Array in patch_splits:
				for patch: Dictionary in patch_split:
					#tessellate_patch_unified(patch)
					var uvs := tessellate_patch_uvs(patch.uvs, options.patch_detail)
					var uv2s := tessellate_patch_uvs(patch.uv2s, options.patch_detail)
					var colors := tessellate_patch_colors(patch.colors, options.patch_detail)
					var geometry := tessellate_patch(patch.verts, options.patch_detail)
					collision_faces.append_array(geometry)

					surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
					for i in range(geometry.size()):
						surface_tool.set_uv(uvs[i])
						surface_tool.set_uv2(uv2s[i])
						if options.import_vertex_colors:
							if !options.import_lightmaps or lightmap_id < 0:
								surface_tool.set_color(colors[i])
						surface_tool.add_vertex(geometry[i])

					surface_tool.index()
					surface_tool.generate_normals()
					surface_tool.generate_tangents()
					surface_tool.set_material(material)
					surface_tool.commit(mesh)
					surface_tool.clear()

				# patches can be used for collisions only (OpenArena does this)
				# however since we're generating them from triangle meshes, we still need the MESH
				# but not necessarily the mesh INSTANCE... so just don't make one
				if not surface_flags & (SURFACE_FLAGS.NODRAW | SURFACE_FLAGS.HINT | SURFACE_FLAGS.SKIP):
					var mesh_instance := MeshInstance3D.new()
					#mesh_instance.name = "MeshInstance3D_%s_patch" % textures[texture_id].name
					mesh_instance.mesh = mesh
					parent.add_child(mesh_instance, true)
					mesh_instance.owner = bsp_scene
				
				# move along if there aren't any collisions to generate.
				if surface_flags & SURFACE_FLAGS.NONSOLID and not content_flags & (CONTENT_FLAGS.WATER | CONTENT_FLAGS.SLIME | CONTENT_FLAGS.LAVA):
					continue
				
				var collision_parent # can be a liquid scene
				var concave_polygon_shape := ConcavePolygonShape3D.new()
				var collision_shape := CollisionShape3D.new()
				collision_shape.shape = concave_polygon_shape
				concave_polygon_shape.set_faces(collision_faces)
				
				if content_flags & CONTENT_FLAGS.WATER:
					collision_parent = options.water_scene.instantiate()
				elif content_flags & CONTENT_FLAGS.SLIME:
					collision_parent = options.slime_scene.instantiate()
				elif content_flags & CONTENT_FLAGS.LAVA:
					collision_parent = options.lava_scene.instantiate()
				else:
					if parent is CollisionObject3D:
						collision_parent = parent
					else:
						collision_parent = StaticBody3D.new()

				if collision_parent != parent:
					parent.add_child(collision_parent, true)
				collision_parent.add_child(collision_shape, true)
				collision_parent.owner = bsp_scene
				collision_shape.owner = bsp_scene
				collision_shape.set_meta("patch", metadata)


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

			add_brush_meshes(models[model_index], entity_scene)
			add_brush_collisions(models[model_index], entity_scene)
			# entities can have patches, apparently.
			add_patches(models[model_index], entity_scene)


func add_brush_meshes(bsp_model: BSPModel, parent: Node) -> void:
	var brush_faces := face_groups(bsp_model, [FACE_TYPE.POLYGON, FACE_TYPE.MESH])
	# just in case we end up with more than 256 surfaces, or whatever MAX_MESH_SURFACES is.
	# if we're splitting the mesh anyway this basically shouldn't matter
	var brush_chunks := split_face_groups(brush_faces)

	if brush_chunks.is_empty() or brush_faces.is_empty():
		return

	var big_meshes: Array[ArrayMesh]

	var split_mesh := false
	# bmodels are already kind of "split" anyway since they aren't part of the static world.
	if parent == bsp_scene and options.split_mesh:
		# TODO: somehow use vis data for split or use a grid.
		# the problem with vis data is that leafs can be as granular
		# as a single quad (maybe even a single triangle) which does not
		# play nice with Godot...
		# so for now just split surfaces into individual meshes here.
		split_mesh = true

	for brush_chunk in brush_chunks:
		var big_mesh := ArrayMesh.new()
		for brush_face: Array in brush_chunk:
			var texture_id: int = brush_face[0]
			var lightmap_id: int = brush_face[1]
			var surface_flags: SURFACE_FLAGS = textures[texture_id].flags
			var content_flags: CONTENT_FLAGS = textures[texture_id].content_flags
			var translucent := false
			var sky := false

			# TODO: shaders can maybe override these flags, so these are not reliable
			if surface_flags & (SURFACE_FLAGS.NODRAW | SURFACE_FLAGS.HINT | SURFACE_FLAGS.SKIP):
				continue
			if options.remove_skies:
				if surface_flags & SURFACE_FLAGS.SKY:
					continue
			if !options.remove_skies and surface_flags & SURFACE_FLAGS.SKY:
				sky = true


			if content_flags & CONTENT_FLAGS.FOG:
				# handled in collision generation instead
				# TODO: compatibility fallback fog effect?
				continue

			# TODO: idtech3 shaders can overwrite this stuff...
			if content_flags & CONTENT_FLAGS.TRANSLUCENT:# and not textures[texture_id].content_flags & (CONTENT_FLAGS.LAVA | CONTENT_FLAGS.SLIME | CONTENT_FLAGS.WATER | CONTENT_FLAGS.FOG):
				translucent = true

			var surface_tool := SurfaceTool.new()
			var material := material_from_path(texture_id, lightmap_id)

			surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
			surface_tool.set_material(material)
			var offset := 0

			for face: BSPFace in brush_faces[brush_face]:
				for v in range(face.start_vert_index, face.start_vert_index + face.num_verts):
					surface_tool.set_normal(vertices[v].normal)
					surface_tool.set_uv(vertices[v].uv)
					surface_tool.set_uv2(vertices[v].uv2)
					if options.import_vertex_colors:
						if !options.import_lightmaps or lightmap_id < 0:
							surface_tool.set_color(vertices[v].color)
					surface_tool.add_vertex(vertices[v].position)

				for i in range(face.start_index, face.start_index + face.num_indices):
					surface_tool.add_index(indices[i] + offset)

				offset += face.num_verts
			# give each transparent face its own mesh for sorting purposes.
			# FIXME: this isn't always giving individual faces, probably
			# due to the grouping. Fine for water and stuff, unless that water
			# has multiple visible sides :/
			if translucent or sky:
				var translucent_mesh := surface_tool.commit()
				var translucent_mesh_instance := MeshInstance3D.new()
				translucent_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				#transparent_mesh_instance.name = "MeshInstance3D_%s_transparent" % textures[texture_id].name
				translucent_mesh_instance.mesh = translucent_mesh
				parent.add_child(translucent_mesh_instance, true)
				translucent_mesh_instance.owner = bsp_scene
				continue
			if split_mesh:
				var small_mesh := surface_tool.commit()
				var mesh_instance := MeshInstance3D.new()
				
				surface_tool.clear()
				#mesh_instance.name = "MeshInstance3D_%s" % textures[texture_id].name
				mesh_instance.mesh = small_mesh
				if options.import_lights:
					mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
				if !options.import_lightmaps:
					var texel_size: float = (1.0 / options.unit_scale) * 4.0
					small_mesh.lightmap_unwrap(bsp_scene.transform, texel_size)
				
				parent.add_child(mesh_instance, true)
				mesh_instance.owner = bsp_scene
				if options.occlusion_culling:
					var occluder_instance := OccluderInstance3D.new()
					occluder_instance.occluder = generate_occlusion_geometry(small_mesh)
					parent.add_child(occluder_instance, true)
					occluder_instance.owner = bsp_scene
			else:
				surface_tool.commit(big_mesh)
				surface_tool.clear()
		big_meshes.append(big_mesh)
		
	if !split_mesh:
		# since meshes have a maximum surface size of "RenderingServer.MAX_MESH_SURFACES" we still need to split meshes along that.
		# otherwise it's error city and incomplete mesharrays
		for big_mesh: ArrayMesh in big_meshes:
			var mesh_instance := MeshInstance3D.new()
			#mesh_instance.name = "MeshInstance3D_BrushGeometry"
			mesh_instance.mesh = big_mesh
			if options.import_lights:
				mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
			parent.add_child(mesh_instance, true)
			mesh_instance.owner = bsp_scene
			if options.occlusion_culling:
				var occluder_instance := OccluderInstance3D.new()
				occluder_instance.occluder = generate_occlusion_geometry(big_mesh)
				parent.add_child(occluder_instance, true)
				occluder_instance.owner = bsp_scene
#
			# if the user is NOT importing lightmaps and NOT splitting the mesh
			# let's make it possible to use Godot's lightmapper.
			if !options.import_lightmaps and !split_mesh:
				var texel_size: float = (1.0 / options.unit_scale) * 4.0
				big_mesh.lightmap_unwrap(bsp_scene.transform, texel_size)


# TODO: needs to not incorporate transparent and detail geometry, etc.
# maybe we do this during the mesh construction phase to skip some geometry?
func generate_occlusion_geometry(mesh: Mesh) -> ArrayOccluder3D:
		var occluder_vertices: PackedVector3Array
		var occluder_indices: PackedInt32Array
		for i in range(mesh.get_surface_count()):
			var offset := occluder_vertices.size()
			var arrays := mesh.surface_get_arrays(i)
			occluder_vertices.append_array(arrays[ArrayMesh.ARRAY_VERTEX])
			if arrays[ArrayMesh.ARRAY_INDEX] == null:
				occluder_indices.append_array(range(offset, offset + arrays[ArrayMesh.ARRAY_VERTEX].size()))
			else:
				for index in arrays[ArrayMesh.ARRAY_INDEX]:
					occluder_indices.append(index + offset)
		var array_occluder := ArrayOccluder3D.new()
		array_occluder.set_arrays(occluder_vertices, occluder_indices)
		return array_occluder


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
func add_billboards(bsp_model: BSPModel, parent: Node) -> void:
	var billboard_faces := face_groups(bsp_model, [FACE_TYPE.BILLBOARD])
	if billboard_faces.is_empty():
		return

	for billboard_group: Array in billboard_faces:
		var texture_id: int = billboard_group[0]
		var multi_mesh_instance := MultiMeshInstance3D.new()
		multi_mesh_instance.name = "MultiMeshInstance3D_Billboards_%d" % texture_id
		var multi_mesh := MultiMesh.new()
		var mesh := QuadMesh.new()
		var material := StandardMaterial3D.new()
		multi_mesh_instance.multimesh = multi_mesh
		material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mesh.material = material
		multi_mesh.mesh = mesh
		multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
		multi_mesh.instance_count = billboard_faces[billboard_group].size()
		var i := 0
		for billboard: BSPFace in billboard_faces[billboard_group]:
			var transform := Transform3D.IDENTITY
			transform.origin = billboard.lm_origin
			multi_mesh.set_instance_transform(i, transform)
			i += 1
	
		parent.add_child(multi_mesh_instance, true)
		multi_mesh_instance.owner = bsp_scene
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

	add_brush_meshes(models[0], bsp_scene)
	add_brush_collisions(models[0], bsp_scene)
	add_patches(models[0], bsp_scene)
	add_entities()
	if options.import_lights:
		add_lights()
	if options.import_billboards:
		add_billboards(models[0], bsp_scene)
	if options.import_lightmaps:
		add_world_light()
	
	bsp_scene.name = source_file.get_file().get_basename()

	bsp_file.close()
	return bsp_scene
