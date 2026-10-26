extends Resource

const BBTexture := preload("bbtexture.gd")
const BBGroup := preload("bbgroup.gd")
var resolution: Vector2
var textures: Array[BBTexture] = []
var groups: Dictionary[String, BBGroup]
var elements: Dictionary[String, Dictionary]
var outliner: Array = []
var animations: Array = []

const BBAnimations := preload("bbmodel_animation.gd")


static func fix_outliner(list: Array) -> void:
	for child in list:
		if typeof(child) == TYPE_DICTIONARY:
			var dict: Dictionary = child
			fix_outliner(dict["children"])
			if dict.has("rotation"):
				var rotation: Array = dict["rotation"]
				rotation[2] *= -1


static func version_less(version_a: String, version_b: String) -> bool:
	var major_a: int = version_a.get_slice(".", 0).to_int()
	var minor_a: int = version_a.get_slice(".", 1).to_int()
	var major_b: int = version_b.get_slice(".", 0).to_int()
	var minor_b: int = version_b.get_slice(".", 1).to_int()
	if major_a == major_b:
		return minor_a < minor_b
	else:
		return major_a < major_b


static func version_greater(version_a: String, version_b: String) -> bool:
	var major_a: int = version_a.get_slice(".", 0).to_int()
	var minor_a: int = version_a.get_slice(".", 1).to_int()
	var major_b: int = version_b.get_slice(".", 0).to_int()
	var minor_b: int = version_b.get_slice(".", 1).to_int()
	if major_a == major_b:
		return minor_a > minor_b
	else:
		return major_a > major_b


func process_compatibility(model: Dictionary) -> Dictionary:
	var meta: Dictionary = model["meta"]
	if not meta.has("model_format"):
		if meta.get("bone_rig", false):
			meta["model_format"] = "bedrock_old"
		else:
			meta["model_format"] = "java_block"

	if model.has("cubes") and !model.has("elements"):
		model["elements"] = model["cubes"]

	if model.has("geometry_name"):
		model["model_identifier"] = model["geometry_name"]

	if (
		not model.get("elements", []).is_empty() and meta["box_uv"]
		and version_less(meta["format_version"], "4.5")
	):
		for element in model["elements"]:
			if not element.get("shade", true):
				element["mirror_uv"] = true

	if model.has("outliner") and version_less(meta["format_version"], "3.2"):
		fix_outliner(model["outliner"])
	#TODO: textures backwards compatibility https://github.com/JannisX11/blockbench/blob/ec0b2827104d0799c153bfb5f867579c0c44652f/js/formats/bbmodel.js#L65
	# if model.has("textures") and version_less(meta["format_version"], "4.10"):
	# 	for texture in model["textures"]:
	# 		if texture.has("relative_path"):
	# 			texture["relative_path"] = "/" + texture["relative_path"]
	if model.has("animations") and version_less(meta["format_version"], "5.0"):
		BBAnimations.migrate_pre_5(model["animations"])
	return model


func _init(dict: Dictionary):
	dict = process_compatibility(dict)
	resource_name = dict.get("name")

	if (dict.has("resolution") && dict["resolution"].has_all(["width", "height"])):
		resolution.x = dict["resolution"]["width"]
		resolution.y = dict["resolution"]["height"]
	else:
		resolution = Vector2(16, 16)

	textures.resize(dict.get("textures", []).size())
	var i := 0
	for texture in dict.get("textures", []):
		textures[i] = BBTexture.new(texture)
		i += 1
	for group in dict.get("groups", []):
		var bbgroup = BBGroup.new(group)
		groups[bbgroup.uuid] = bbgroup
	for element in dict.get("elements"):
		if element is Dictionary:
			elements[str(element["uuid"])] = element

	outliner = dict.get("outliner", [])
	animations = dict.get("animations", [])
