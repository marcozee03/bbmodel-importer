extends Resource

var name: String
var relative_path: String
var path: String
# var folder: String
# var name_space: String
var id: String
var group: String
var size: Vector2
var uv_size: Vector2
# var particle: bool
var file_format: String
var render_mode: String
var render_sides: String
# var wrap_mode: String
# var visible: bool
var uuid: String
var source: String
# var internal: bool


func _init(dict: Dictionary):
	name = dict.get("name", "")
	relative_path = dict.get("relative_path", "")
	relative_path = dict.get("path", "")
	id = dict.get("id", "0")
	group = dict.get("group", "")
	size.x = dict.get("width", 0)
	size.y = dict.get("height", 0)
	uv_size.x = dict.get("uv_width", 0)
	uv_size.y = dict.get("uv_height", 0)
	file_format = dict.get("file_format", "png")
	render_mode = dict.get("render_mode", "default")
	render_sides = dict.get("render_sides", "auto")
	uuid = dict.get("uuid", "")
	source = dict.get("source", "")
	_cached_image = load_mime_image(source)
	_cached_image.resource_name = name
	if _cached_image.resource_name.is_empty():
		_cached_image.resource_name = "texture_%s" % id


var _cached_image: Image


func _get_image() -> Image:
	return _cached_image


static func load_mime_image(source: String) -> Image:
	if not source.begins_with("data:image/"):
		return null
	const slash_index = 10
	var image_type: String = source.substr(slash_index + 1, source.find(";") - slash_index - 1)
	assert(
		image_type == "png" or image_type == "webp" or image_type == "jpeg",
		"Unsupported Image type %s" % image_type,
	)
	var encoding: String = source.substr(
		source.find(";") + 1,
		source.find(",") - source.find(";") - 1,
	)
	if (encoding != "base64"):
		push_warning("Does not support non base64 encodings")
		return null
	var err := OK

	var image: Image = Image.new()
	var bytes := Marshalls.base64_to_raw(source.substr(source.find(",") + 1))
	match image_type:
		"png":
			err = image.load_png_from_buffer(bytes)
		"webp":
			err = image.load_webp_from_buffer(bytes)
		"jpeg":
			err = image.load_jpg_from_buffer(bytes)
		"tga":
			err = image.load_tga_from_buffer(bytes)
	if err == OK and not image.is_empty():
		return image
	return null
