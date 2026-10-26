@tool
extends EditorPlugin

const BBModelImporter = preload("res://addons/bbmodel-importer/bbmodel_importer.gd")

var _importer: EditorSceneFormatImporter


func _enter_tree() -> void:
	_importer = BBModelImporter.new()
	add_scene_format_importer_plugin(_importer)


func _exit_tree() -> void:
	if _importer:
		remove_scene_format_importer_plugin(_importer)
		_importer = null
