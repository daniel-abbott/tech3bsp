# This script will add the necessary shader globals for entities
# to use the lightgrid (assuming they have matching global uniforms).
# You can ignore/delete this if you don't care about the lightgrid.
# Otherwise run with "File -> Run" or "Ctrl+Shift+X"

# Gotta do it wil ProjectSettings instead of RenderingServer for now.
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
	"light_grid_normalize": {
		"type": "vec3",
		"value": Vector3.ZERO
	},
	"light_grid_offset": {
		"type": "vec3",
		"value": Vector3.ZERO
	}
}


func _run() -> void:
	for key: String in shader_globals:
		var full_key := "shader_globals/%s" % key

		if not ProjectSettings.has_setting(full_key):
			ProjectSettings.set_setting(full_key, shader_globals[key])

	ProjectSettings.save()
	EditorInterface.restart_editor()
