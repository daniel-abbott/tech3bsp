@tool
extends EditorPlugin

var _importer: EditorImportPlugin


func _enable_plugin() -> void:
	# Shader globals live in project.godot (GH-77988). Run setup.gd once.
	pass


func _disable_plugin() -> void:
	pass


func _enter_tree() -> void:
	Tech3Noise.ensure_shader_global()
	_importer = preload("res://addons/tech3bsp/tech3bsp_importer.gd").new()
	add_import_plugin(_importer, true)


func _exit_tree() -> void:
	remove_import_plugin(_importer)
	_importer = null
