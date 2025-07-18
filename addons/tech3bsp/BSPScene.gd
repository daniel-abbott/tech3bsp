class_name BSPScene extends Node3D


@export var worldspawn := {}

@export var light_grid_ambient: Texture3D = null
@export var light_grid_direct: Texture3D = null
@export var light_grid_cartesian: Texture3D = null
@export var light_grid_normalize := Vector3.ZERO
@export var light_grid_offset := Vector3.ZERO


func _ready() -> void:
	# let's assume the globals are there if we have these values
	if light_grid_ambient and light_grid_direct:
		RenderingServer.global_shader_parameter_set(&"light_grid_ambient", light_grid_ambient)
		RenderingServer.global_shader_parameter_set(&"light_grid_direct", light_grid_direct)
		RenderingServer.global_shader_parameter_set(&"light_grid_cartesian", light_grid_cartesian)
		RenderingServer.global_shader_parameter_set(&"light_grid_normalize", light_grid_normalize)
		RenderingServer.global_shader_parameter_set(&"light_grid_offset", light_grid_offset)
	else: # probably not using the lightgrid for this map, let's clear out the globals just in case.
		if ProjectSettings.has_setting("shader_globals/light_grid_ambient"):
			RenderingServer.global_shader_parameter_set(&"light_grid_ambient", null)
		if ProjectSettings.has_setting("shader_globals/light_grid_direct"):
			RenderingServer.global_shader_parameter_set(&"light_grid_direct", null)
		if ProjectSettings.has_setting("shader_globals/light_grid_cartesian"):
			RenderingServer.global_shader_parameter_set(&"light_grid_cartesian", null)
		if ProjectSettings.has_setting("shader_globals/light_grid_normalize"):
			RenderingServer.global_shader_parameter_set(&"light_grid_normalize", Vector3.ZERO)
		if ProjectSettings.has_setting("shader_globals/light_grid_offset"):
			RenderingServer.global_shader_parameter_set(&"light_grid_offset", Vector3.ZERO)
	#print(worldspawn)
