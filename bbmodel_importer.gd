@tool
extends EditorSceneFormatImporter
## Blockbench (.bbmodel) scene importer for Godot 4.x.
##
## Supported: cube + mesh elements, nested groups (outliner), locators / null objects,
## embedded or sibling-file textures, per-face UVs (with rotation), box UV fallback,
## inflate, visibility / export flags.
## Not supported: animations, armatures, texture animation, Molang.
##
## Conventions: Blockbench and Godot are both right-handed and Y-up, with north = -Z,
## so no axis flip is needed. Blockbench uses 16 units per meter, hence the default
## scale of 1/16. Rotations are Blockbench "ZYX" Euler angles (degrees), which map
## directly onto Node3D.rotation_order = EULER_ORDER_ZYX.

## Two clockwise triangles (Godot's front-face winding) for a quad TL, TR, BR, BL.
const QUAD_TRIANGLES: Array[int] = [0, 1, 2, 0, 2, 3]
const DEFAULT_MATERIAL := -1
const SKIP_FACE := -2


## Per-import state, so the importer instance itself stays stateless.
class Ctx:
	var scale := 1.0 / 16.0
	var nodes: Dictionary[String, Node3D] = { } # uuid -> built node
	var root: Node3D
	var resolution: Vector2 = Vector2(16, 16)
	var elements: Dictionary[String, Dictionary] = { } # uuid -> element Dictionary
	var used: Dictionary[String, bool] = { } # uuid -> true (elements placed via the outliner)
	var materials: Dictionary[int, Material] = { } # texture index (or DEFAULT_MATERIAL) -> Material
	var uv_sizes: Dictionary[int, Vector2] = { } # texture index (or DEFAULT_MATERIAL) -> Vector2
	var tex_ids: Array[String] = []

# --------------------------------------------------------------------------------------
# EditorSceneFormatImporter API
# --------------------------------------------------------------------------------------


func _get_extensions() -> PackedStringArray:
	return PackedStringArray(["bbmodel"])


const BBAnimations := preload("bbmodel_animation.gd")


func _get_import_flags() -> int:
	return IMPORT_SCENE | IMPORT_ANIMATION


func _get_import_options(path: String) -> void:
	if path.is_empty() || path.get_extension() == "bbmodel":
		add_import_option("bbmodel/pixels_per_unit", 16.0)
		add_import_option("bbmodel/nearest_filter", true)
		add_import_option("bbmodel/animation_fps", 30.0)


func version_less(version_a: String, version_b: String) -> bool:
	var major_a: int = version_a.get_slice(".", 0).to_int()
	var minor_a: int = version_a.get_slice(".", 1).to_int()
	var major_b: int = version_b.get_slice(".", 0).to_int()
	var minor_b: int = version_b.get_slice(".", 1).to_int()
	if major_a == major_b:
		return minor_a < minor_b
	else:
		return major_a < major_b


func version_greater(version_a: String, version_b: String) -> bool:
	var major_a: int = version_a.get_slice(".", 0).to_int()
	var minor_a: int = version_a.get_slice(".", 1).to_int()
	var major_b: int = version_b.get_slice(".", 0).to_int()
	var minor_b: int = version_b.get_slice(".", 1).to_int()
	if major_a == major_b:
		return minor_a > minor_b
	else:
		return major_a > major_b


func fix_outliner(list: Array) -> void:
	for child in list:
		if typeof(child) == TYPE_DICTIONARY:
			var dict: Dictionary = child
			fix_outliner(dict["children"])
			if dict.has("rotation"):
				var rotation: Array = dict["rotation"]
				rotation[2] *= -1


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


func _import_scene(path: String, flags: int, options: Dictionary) -> Object:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		push_error(
			"BBModel: could not read '%s' (%s)" % [path, error_string(FileAccess.get_open_error())]
		)
		return null
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("BBModel: '%s' is not a valid .bbmodel (JSON) file." % path)
		return null
	var model: Dictionary = process_compatibility(parsed)

	var ctx := Ctx.new()
	ctx.scale = 1.0 / float(options.get("bbmodel/pixels_per_unit", 16.0))

	ctx.resolution.x = model["resolution"]["width"]
	ctx.resolution.y = model["resolution"]["height"]
	_build_materials(ctx, model.get("textures", []), path.get_base_dir(), options)

	# Index elements by uuid.
	var elements: Array = model.get("elements", [])
	for i in elements.size():
		var el: Variant = elements[i]
		if el is Dictionary:
			var uuid := str(el.get("uuid", "idx_%d" % i))
			ctx.elements[uuid] = el

	# Root node.
	var root := Node3D.new()
	var model_name := str(model.get("name", ""))
	if model_name.is_empty():
		model_name = path.get_file().get_basename()
	root.name = model_name
	ctx.root = root

	# Build hierarchy from the outliner, then add any elements it didn't reference.
	var outliner: Array = model.get("outliner", [])
	_build_children(ctx, root, outliner, Vector3.ZERO)
	for uuid in ctx.elements:
		if not ctx.used.has(uuid):
			_build_element(ctx, root, ctx.elements[uuid], Vector3.ZERO)

	if (flags & IMPORT_ANIMATION) != 0 and model.has("animations"):
		var fps := float(options.get("bbmodel/animation_fps", 30.0))
		BBAnimations.attach_animations(root, ctx.nodes, model["animations"], ctx.scale, fps)

	return root

# --------------------------------------------------------------------------------------
# Textures / materials
# --------------------------------------------------------------------------------------


func _build_materials(ctx: Ctx, textures: Array, base_dir: String, options: Dictionary) -> void:
	var nearest: bool = options.get("bbmodel/nearest_filter", true)

	ctx.materials[DEFAULT_MATERIAL] = _make_material(null, "default", nearest, "default", "auto")
	ctx.uv_sizes[DEFAULT_MATERIAL] = ctx.resolution

	for i in textures.size():
		var tex: Variant = textures[i]
		if not (tex is Dictionary):
			ctx.tex_ids.append("")
			continue
		var render_mode = tex.get("render_mode", "default")
		var render_sides = tex.get("render_sides", "auto")
		ctx.tex_ids.append(str(tex.get("id", tex.get("uuid", i))))

		var img := _load_texture_image(tex, base_dir)
		var uv_size := ctx.resolution
		if tex.has_all(["uv_width", "uv_height"]):
			uv_size = Vector2(float(tex["uv_width"]), float(tex["uv_height"]))
		elif img != null:
			uv_size = Vector2(img.get_size())
		ctx.uv_sizes[i] = uv_size

		if img != null:
			var mat_name := str(tex.get("name", "texture_%d" % i)).get_basename()
			ctx.materials[i] = _make_material(img, mat_name, nearest, render_mode, render_sides)
		else:
			push_warning(
				"BBModel: could not load texture %d ('%s'); using default material."
				% [i, str(tex.get("name", ""))]
			)
			ctx.materials[i] = ctx.materials[DEFAULT_MATERIAL]


func _load_mime_image(source: String) -> Image:
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


func _load_texture_image(tex: Dictionary, base_dir: String) -> Image:
	# 2. External file next to the .bbmodel.
	var candidates: Array[String] = []
	var rel: String = tex.get("relative_path", "")
	if FileAccess.file_exists(base_dir.path_join(rel)):
		var img := Image.load_from_file(base_dir.path_join(rel))
		if img != null and not img.is_empty():
			return img
	var abs_path: String = str(tex.get("path", ""))
	if FileAccess.file_exists(abs_path):
		var img := Image.load_from_file(abs_path)
		if img != null and not img.is_empty():
			return img
	# 1. Embedded data URI.
	var src := str(tex.get("source", ""))
	var embedded_image := _load_mime_image(src)
	if embedded_image != null:
		return embedded_image

	return null


func _make_material(
	img: Image,
	mat_name: String,
	nearest: bool,
	render_mode: String,
	render_sides: String,
) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.resource_name = mat_name
	if img != null:
		mat.albedo_texture = ImageTexture.create_from_image(img)
		match render_mode:
			"default":
				mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
			"emissive":
				mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
				mat.emission_enabled = true
				mat.emission = Color.WHITE
			"additive":
				mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		match render_sides:
			"auto":
				mat.cull_mode = BaseMaterial3D.CULL_BACK
			"front":
				mat.cull_mode = BaseMaterial3D.CULL_BACK
				push_warning("do not currently support emissive textures")
			"double":
				mat.cull_mode = BaseMaterial3D.CULL_DISABLED

		if nearest:
			mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	else:
		mat.albedo_color = Color(0.8, 0.8, 0.8)
	return mat

# --------------------------------------------------------------------------------------
# Scene tree construction
# --------------------------------------------------------------------------------------


func _build_children(ctx: Ctx, parent: Node3D, entries: Array, parent_origin: Vector3) -> void:
	for entry in entries:
		if typeof(entry) == TYPE_STRING:
			var el: Variant = ctx.elements.get(entry)
			if el == null:
				continue
			ctx.used[entry] = true
			_build_element(ctx, parent, el, parent_origin)
		elif typeof(entry) == TYPE_DICTIONARY:
			_build_group(ctx, parent, entry, parent_origin)


func _build_group(ctx: Ctx, parent: Node3D, group: Dictionary, parent_origin: Vector3) -> void:
	if group.get("export", true) == false:
		return
	var origin := _to_vector_3(group.get("origin"))
	var node := Node3D.new()
	node.name = str(group.get("name", "Group"))
	_attach(ctx, parent, node)
	ctx.nodes[str(group.get("uuid", ""))] = node
	_apply_transform(ctx, node, origin - parent_origin, _to_vector_3(group.get("rotation")))
	node.visible = bool(group.get("visibility", true))
	_build_children(ctx, node, group.get("children", []), origin)


func _build_element(ctx: Ctx, parent: Node3D, el: Dictionary, parent_origin: Vector3) -> void:
	if el.get("export", true) == false:
		return
	var type := str(el.get("type", "cube"))
	var el_name := str(el.get("name", type))

	match type:
		"cube", "mesh":
			var origin := _to_vector_3(el.get("origin"))
			var mesh: Mesh
			if type == "cube":
				mesh = _build_cube_mesh(ctx, el, origin, el_name)
			else:
				mesh = _build_mesh_element(ctx, el, el_name)
			if mesh == null:
				return
			var node := MeshInstance3D.new()
			node.name = el_name
			node.mesh = mesh
			_attach(ctx, parent, node)
			_apply_transform(ctx, node, origin - parent_origin, _to_vector_3(el.get("rotation")))
			node.visible = bool(el.get("visibility", true))
		"locator", "null_object":
			var pos := _to_vector_3(el.get("position"))
			var marker: Node3D = Marker3D.new() if type == "locator" else Node3D.new()
			marker.name = el_name
			_attach(ctx, parent, marker)
			_apply_transform(ctx, marker, pos - parent_origin, _to_vector_3(el.get("rotation")))
		_:
			push_warning(
				"BBModel: skipping unsupported element type '%s' ('%s')." % [type, el_name]
			)


func _attach(ctx: Ctx, parent: Node3D, node: Node3D) -> void:
	parent.add_child(node, true)
	node.owner = ctx.root


func _apply_transform(ctx: Ctx, node: Node3D, offset: Vector3, rot_deg: Vector3) -> void:
	node.position = offset * ctx.scale
	node.rotation_order = EULER_ORDER_ZYX
	node.rotation_degrees = rot_deg

# --------------------------------------------------------------------------------------
# Cube geometry
# --------------------------------------------------------------------------------------


func _build_cube_mesh(ctx: Ctx, el: Dictionary, origin: Vector3, mesh_name: String) -> Mesh:
	const FACE_NAMES: Array[String] = ["north", "east", "south", "west", "up", "down"]
	const FACE_NORMALS := {
		"north": Vector3(0, 0, -1),
		"east": Vector3(1, 0, 0),
		"south": Vector3(0, 0, 1),
		"west": Vector3(-1, 0, 0),
		"up": Vector3(0, 1, 0),
		"down": Vector3(0, -1, 0),
	}
	var raw_from := _to_vector_3(el.get("from"))
	var raw_to := _to_vector_3(el.get("to"))
	var inflate := float(el.get("inflate", 0.0))
	var from := raw_from - Vector3.ONE * inflate
	var to := raw_to + Vector3.ONE * inflate

	var faces: Dictionary = el.get("faces", { })
	var box_rects := { }
	if el.get("box_uv", false):
		var uv_off: Variant = el.get("uv_offset")
		var offset := Vector2.ZERO
		if uv_off is Array and uv_off.size() >= 2:
			offset = Vector2(float(uv_off[0]), float(uv_off[1]))
		box_rects = _box_uv_rects(offset, raw_to - raw_from)

	# Corners are listed TL, TR, BR, BL as seen from outside the face.
	var corners := {
		"north": [
			Vector3(to.x, to.y, from.z),
			Vector3(from.x, to.y, from.z),
			Vector3(from.x, from.y, from.z),
			Vector3(to.x, from.y, from.z),
		],
		"east": [
			Vector3(to.x, to.y, to.z),
			Vector3(to.x, to.y, from.z),
			Vector3(to.x, from.y, from.z),
			Vector3(to.x, from.y, to.z),
		],
		"south": [
			Vector3(from.x, to.y, to.z),
			Vector3(to.x, to.y, to.z),
			Vector3(to.x, from.y, to.z),
			Vector3(from.x, from.y, to.z),
		],
		"west": [
			Vector3(from.x, to.y, from.z),
			Vector3(from.x, to.y, to.z),
			Vector3(from.x, from.y, to.z),
			Vector3(from.x, from.y, from.z),
		],
		"up": [
			Vector3(from.x, to.y, from.z),
			Vector3(to.x, to.y, from.z),
			Vector3(to.x, to.y, to.z),
			Vector3(from.x, to.y, to.z),
		],
		"down": [
			Vector3(from.x, from.y, to.z),
			Vector3(to.x, from.y, to.z),
			Vector3(to.x, from.y, from.z),
			Vector3(from.x, from.y, from.z),
		],
	}

	var surfaces := { }
	for face_name in FACE_NAMES:
		if typeof(faces.get(face_name)) != TYPE_DICTIONARY:
			continue
		var face: Dictionary = faces[face_name]
		var key := _material_key(ctx, face)
		if key == SKIP_FACE:
			continue

		var raw_uv: Variant = face.get("uv")
		var rect: Array = raw_uv if raw_uv is Array else []
		if rect.size() < 4:
			rect = box_rects.get(face_name, [0, 0, 0, 0])
		var uvs := _face_uvs(rect, int(face.get("rotation", 0)), _uv_size(ctx, key))
		var pts: Array = corners[face_name]
		_add_quad(_get_surface(surfaces, key), pts, uvs, FACE_NORMALS[face_name], origin, ctx.scale)

	return _commit(ctx, surfaces, mesh_name)


## Standard Minecraft-style box UV layout, only used if a face has no stored UV.
func _box_uv_rects(offset: Vector2, size: Vector3) -> Dictionary:
	var w := floorf(absf(size.x))
	var h := floorf(absf(size.y))
	var d := floorf(absf(size.z))
	var x := offset.x
	var y := offset.y
	return {
		"up": [x + d, y, x + d + w, y + d],
		"down": [x + d + w, y + d, x + d + 2.0 * w, y],
		"east": [x, y + d, x + d, y + d + h],
		"north": [x + d, y + d, x + d + w, y + d + h],
		"west": [x + d + w, y + d, x + 2.0 * d + w, y + d + h],
		"south": [x + 2.0 * d + w, y + d, x + 2.0 * d + 2.0 * w, y + d + h],
	}


func _face_uvs(rect: Array, rot_deg: int, uv_size: Vector2) -> Array[Vector2]:
	var x1 := float(rect[0])
	var y1 := float(rect[1])
	var x2 := float(rect[2])
	var y2 := float(rect[3])
	var base: Array[Vector2] = [Vector2(x1, y1), Vector2(x2, y1), Vector2(x2, y2), Vector2(x1, y2)]
	# Blockbench face rotation turns the texture clockwise in 90 degree steps.
	var steps := posmod(roundi(rot_deg / 90.0), 4)
	var out: Array[Vector2] = []
	for i in 4:
		out.append(base[posmod(i - steps, 4)] / uv_size)
	return out


func _add_quad(
	st: SurfaceTool,
	c: Array,
	uv: Array[Vector2],
	normal: Vector3,
	origin: Vector3,
	scale: float,
) -> void:
	for i in QUAD_TRIANGLES:
		var p: Vector3 = c[i]
		st.set_normal(normal)
		st.set_uv(uv[i])
		st.add_vertex((p - origin) * scale)

# --------------------------------------------------------------------------------------
# Mesh-type elements
# --------------------------------------------------------------------------------------


func _build_mesh_element(ctx: Ctx, el: Dictionary, mesh_name: String) -> Mesh:
	var verts: Dictionary = el.get("vertices", { })
	var faces: Dictionary = el.get("faces", { })

	# Mesh vertices are stored relative to the element origin already.
	var pos := { }
	for id in verts:
		pos[id] = _to_vector_3(verts[id])

	var surfaces := { }
	for fid in faces:
		if typeof(faces[fid]) != TYPE_DICTIONARY:
			continue
		var face: Dictionary = faces[fid]
		var key := _material_key(ctx, face)
		if key == SKIP_FACE:
			continue

		var raw_ids: Array = face.get("vertices", [])
		var ids: Array = raw_ids.filter(
			func(id):
				return pos.has(id),
		)
		if ids.size() < 3:
			continue
		ids = _sort_vertices(ids, pos)

		# Blockbench / three.js use CCW front faces; Godot uses CW, so flip afterwards.
		var a: Vector3 = pos[ids[0]]
		var b: Vector3 = pos[ids[1]]
		var c: Vector3 = pos[ids[2]]
		var normal := (b - a).cross(c - a).normalized()
		ids.reverse()

		var uv_size := _uv_size(ctx, key)
		var uv_dict: Dictionary = face.get("uv", { }) if face.get("uv") is Dictionary else { }
		var st := _get_surface(surfaces, key)
		for i in range(1, ids.size() - 1):
			for id in [ids[0], ids[i], ids[i + 1]]:
				var uv_arr: Variant = uv_dict.get(id)
				var uv := Vector2.ZERO
				if uv_arr is Array and uv_arr.size() >= 2:
					uv = Vector2(float(uv_arr[0]), float(uv_arr[1])) / uv_size
				var p: Vector3 = pos[id]
				st.set_normal(normal)
				st.set_uv(uv)
				st.add_vertex(p * ctx.scale)

	return _commit(ctx, surfaces, mesh_name)


## Orders a face's vertices counter-clockwise around its centroid (quads can be stored
## in arbitrary order). The winding direction is taken from the first three vertices.
func _sort_vertices(ids: Array, pos: Dictionary) -> Array:
	if ids.size() < 4:
		return ids.duplicate()
	var a: Vector3 = pos[ids[0]]
	var b: Vector3 = pos[ids[1]]
	var c: Vector3 = pos[ids[2]]
	var normal := (b - a).cross(c - a).normalized()

	var center := Vector3.ZERO
	for id in ids:
		var p: Vector3 = pos[id]
		center += p
	center /= float(ids.size())

	var axis_u := (a - center).normalized()
	var axis_v := normal.cross(axis_u)
	var entries: Array = []
	for id in ids:
		var q: Vector3 = pos[id]
		var d := q - center
		entries.append([atan2(d.dot(axis_v), d.dot(axis_u)), id])
	entries.sort_custom(
		func(x, y):
			return x[0] < y[0],
	)
	return entries.map(
		func(e):
			return e[1],
	)

# --------------------------------------------------------------------------------------
# Shared helpers
# --------------------------------------------------------------------------------------


func _material_key(ctx: Ctx, face: Dictionary) -> int:
	if not face.has("texture"):
		return DEFAULT_MATERIAL
	var t: Variant = face["texture"]
	if t == null:
		return DEFAULT_MATERIAL
	if typeof(t) == TYPE_BOOL:
		return DEFAULT_MATERIAL if t else SKIP_FACE # `false` = face disabled in Blockbench
	if typeof(t) == TYPE_STRING:
		var idx := ctx.tex_ids.find(t)
		return idx if idx != -1 else DEFAULT_MATERIAL
	var i := int(t)
	return i if ctx.materials.has(i) else DEFAULT_MATERIAL


func _uv_size(ctx: Ctx, key: int) -> Vector2:
	var s: Vector2 = ctx.uv_sizes.get(key, ctx.resolution)
	return Vector2(maxf(s.x, 1.0), maxf(s.y, 1.0))


func _get_surface(surfaces: Dictionary, key: int) -> SurfaceTool:
	if not surfaces.has(key):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		surfaces[key] = st
	return surfaces[key]


func _commit(ctx: Ctx, surfaces: Dictionary, mesh_name: String) -> Mesh:
	if surfaces.is_empty():
		return null
	var mesh := ArrayMesh.new()
	mesh.resource_name = mesh_name
	var keys: Array = surfaces.keys()
	keys.sort()
	for key in keys:
		var st: SurfaceTool = surfaces[key]
		st.set_material(ctx.materials[key])
		st.commit(mesh)
	return mesh


func _to_vector_3(v: Variant, default: Vector3 = Vector3(0, 0, 0)) -> Vector3:
	if v is Vector3:
		return v
	if v is Array:
		assert(v.size() == 3)
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return default
