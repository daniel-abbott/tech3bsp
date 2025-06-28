@tool
extends EditorPlugin

var tech3bsp_importer


func _enable_plugin() -> void:
	pass


func _disable_plugin() -> void:
	# Remove autoloads here.
	pass


func _enter_tree() -> void:
	tech3bsp_importer = preload("res://addons/tech3bsp/tech3bsp_importer.gd").new()
	add_import_plugin(tech3bsp_importer, true)


func _exit_tree() -> void:
	remove_import_plugin(tech3bsp_importer)
	tech3bsp_importer = null
