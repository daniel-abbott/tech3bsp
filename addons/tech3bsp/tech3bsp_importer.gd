@tool
extends EditorImportPlugin
class_name Tech3BSPImporter

enum Presets { DEFAULT }


func _get_importer_name() -> String:
	return &"tech3bsp"


func _get_visible_name() -> String:
	return &"idTech 3 BSP"


func _get_recognized_extensions() -> PackedStringArray:
	return [&"bsp"]


func _get_priority() -> float:
	return 1.0


func _get_resource_type() -> String:
	return &"PackedScene"


func _can_import_threaded() -> bool:
	return false


func _get_save_extension() -> String:
	return &"scn"


func _get_import_order() -> int:
	return 0


func _get_import_options(path: String, preset_index: int) -> Array[Dictionary]:
	var entity_map := ConfigFile.new()
	match preset_index:
		_:
			return [
				{
					"name":"unit_scale",
					"default_value": 32.0
				},
				{
					"name":"light_brightness_multiplier",
					"default_value": 1.0
				},
				{
					"name":"light_attenuation",
					"default_value": 1.0
				},
				{
					"name":"entity_map",
					"default_value": "res://addons/tech3bsp/examples/entities.cfg",
				},
				{
					"name":"print_missing_entities",
					"default_value":true
				},
				{
					"name":"materials_path",
					"default_value":"res://materials/{texture_name}.material",
				},
				{
					"name":"textures_path",
					"default_value":"res://textures/"
				},
				{
					"name":"fallback_materials",
					"default_value":true
				},
				{
					"name":"water_scene",
					"default_value":load("res://addons/tech3bsp/examples/water_example_template.tscn"),
					"property_hint":PROPERTY_HINT_RESOURCE_TYPE,
					"hint_string":"PackedScene"
				},
				{
					"name":"slime_scene",
					"default_value":load("res://addons/tech3bsp/examples/slime_example_template.tscn"),
					"property_hint":PROPERTY_HINT_RESOURCE_TYPE,
					"hint_string":"PackedScene"
				},
				{
					"name":"lava_scene",
					"default_value":load("res://addons/tech3bsp/examples/lava_example_template.tscn"),
					"property_hint":PROPERTY_HINT_RESOURCE_TYPE,
					"hint_string":"PackedScene"
				},
				{
					"name":"import_lightmaps",
					"default_value":true
				},
				{
					"name":"import_lightgrid",
					"default_value":true
				},
				{
					"name":"import_vertex_colors",
					"default_value":true
				},
				{
					"name":"import_lights",
					"default_value":false
				},
				{
					"name":"entity_shadow_light",
					"default_value":false
				},
				{
					"name":"import_billboards",
					"default_value":false
				},
				{
					"name":"split_mesh",
					"default_value":false
				},
				{
					"name":"occlusion_culling",
					"default_value":false
				},
				{
					"name":"remove_skies",
					"default_value": false
				},
				{
					"name":"patch_detail",
					"default_value":4
				},
			]


# TODO: some conditional options maybe
func _get_option_visibility(path: String, option_name: StringName, options: Dictionary) -> bool:
	return true


func _get_preset_count() -> int:
	return Presets.size()


func _get_preset_name(preset_index: int) -> String:
	match preset_index:
		Presets.DEFAULT:
			return &"Default"
		_:
			return &"Unknown"


func _import(source_file: String, save_path: String, options: Dictionary, platform_variants: Array[String], gen_files: Array[String]) -> Error:
	var tech3bsp_reader := Tech3BSPReader.new()
	tech3bsp_reader.options = options
	var tech3bsp_scene := tech3bsp_reader.read_bsp(source_file)
	if (!tech3bsp_scene):
		return ERR_FILE_CANT_OPEN
	var ps := PackedScene.new()
	var err := ps.pack(tech3bsp_scene)
	if (err):
		printerr(&"Failed to pack scene: ", error_string(err))
		return err

	print(save_path)
	var rs := ResourceSaver.save(ps, "%s.%s" % [save_path, _get_save_extension()])
	tech3bsp_reader.free()
	return OK
