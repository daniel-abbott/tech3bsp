# This script will add the necessary shader globals for entities
# to use the lightgrid (assuming they have matching global uniforms).
# Also now for styled lights to work with dynamic lights!

# Run with "File -> Run" or "Ctrl+Shift+X"

# Gotta do it in ProjectSettings instead of RenderingServer for now.
# https://github.com/godotengine/godot/issues/77988
@tool
extends EditorScript


var shader_globals := {
		"light_grid_ambient": {
			"type": "sampler3D",
			"value": ""
		},
		"light_grid_direct": {
			"type": "sampler3D",
			"value": ""
		},
		"light_grid_cartesian": {
			"type": "sampler3D",
			"value": ""
		},
		"light_grid_ambient_1": {
			"type": "sampler3D",
			"value": ""
		},
		"light_grid_ambient_2": {
			"type": "sampler3D",
			"value": ""
		},
		"light_grid_ambient_3": {
			"type": "sampler3D",
			"value": ""
		},
		"light_grid_direct_1": {
			"type": "sampler3D",
			"value": ""
		},
		"light_grid_direct_2": {
			"type": "sampler3D",
			"value": ""
		},
		"light_grid_direct_3": {
			"type": "sampler3D",
			"value": ""
		},
		"light_grid_styles": {
			"type": "sampler3D",
			"value": ""
		},
		"light_grid_normalize": {
			"type": "vec3",
			"value": Vector3.ZERO
		},
		"light_grid_offset": {
			"type": "vec3",
			"value": Vector3.ZERO
		},
		"tech3_time": {
			"type": "float",
			"value": 0.0
		},
		"tech3_noise": {
			"type": "sampler2D",
			"value": ""
		},
		"tech3_style_weights": {
			"type": "sampler2D",
			"value": ""
		},
		"tech3_ss_wind_scale": {
			"type": "float",
			"value": 1.0
		},
		"tech3_ss_wind_dir": {
			"type": "vec3",
			"value": Vector3.ZERO
		},
	}


func _run() -> void:
	for key: String in shader_globals:
		var full_key := "shader_globals/%s" % key

		if not ProjectSettings.has_setting(full_key):
			ProjectSettings.set_setting(full_key, shader_globals[key])

	ProjectSettings.save()
	EditorInterface.restart_editor()
