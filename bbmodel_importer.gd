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
class Tex:
	var texture: Texture2D
	var material: Material
	var uv_size: Vector2


	func _init(texture: Texture2D, material: Material, uv_size: Vector2) -> void:
		self.texture = texture
		self.material = material
		self.uv_size = uv_size


	static func from_bbtexture(ctx: Ctx, texture: BBTexture) -> Tex:
		var tex := _load_texture_image(ctx, texture)
		var uv_size := texture.uv_size

		var mat_name := texture.name
		if (mat_name.is_empty()):
			mat_name = "texture_%s" % texture.id
		var material = _make_material(
			tex,
			mat_name,
			ctx.nearest,
			texture.render_mode,
			texture.render_sides,
		)
		return Tex.new(tex, material, uv_size)


	static func _make_material(
		tex: Texture2D,
		mat_name: String,
		nearest: bool,
		render_mode: String,
		render_sides: String,
	) -> StandardMaterial3D:
		var mat := StandardMaterial3D.new()
		mat.resource_name = mat_name
		if tex != null:
			mat.albedo_texture = tex
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


	static func _load_texture_image(ctx: Ctx, tex: BBTexture) -> Texture2D:
		# 2. External file next to the .bbmodel.
		assert(
			ctx.texture_extraction != _HandleBinaryImageMode.EXTRACT_TEXTURES,
			"Extract Textures not yet supported",
		)
		if ctx.texture_extraction == _HandleBinaryImageMode.DISCARD_TEXTURES:
			return null
		var local_path = ProjectSettings.localize_path(ctx.base_dir.path_join(tex.relative_path))
		var local_texture := _load_texture_from_path(local_path)
		if local_texture != null:
			return local_texture

		var abs_path: String = ProjectSettings.localize_path(str(tex.path))
		var abs_texture := _load_texture_from_path(abs_path)
		if abs_texture != null:
			return abs_texture

		var embedded_image := tex._get_image()
		if embedded_image != null:
			match ctx.texture_extraction:
				_HandleBinaryImageMode.EXTRACT_TEXTURES:
					if ctx.base_dir.is_empty():
						push_warning(
							"bbmodel: Couldn't extract image because the base and extract paths are empty. It will be loaded directly instead, uncompressed."
						)
					elif ctx.base_dir.begins_with("res://.godot/imported"):
						push_warning(
							"bbmodel: Extract path is in the imported directory. Image will be loaded directly, uncompressed."
						)
					else:
						if embedded_image.resource_name.is_empty():
							push_warning(
								"glTF: Image index '%d' did not have a name. It will be automatically given a name based on its index.",
								tex.get("id"),
							)
							embedded_image.resource_name = tex.get("id")
						var must_write := true
						var must_import := true
						var image_data := embedded_image.get_data()
						var generator_parameters: Dictionary
						var file_path: String

				_HandleBinaryImageMode.EMBED_AS_BASISU:
					var texture := PortableCompressedTexture2D.new()
					texture.resource_name = embedded_image.resource_name
					texture.set_keep_all_compressed_buffers(true)
					texture.create_from_image(
						embedded_image,
						PortableCompressedTexture2D.COMPRESSION_MODE_BASIS_UNIVERSAL,
					)
					return texture
			var img = ImageTexture.new()
			img.resource_name = embedded_image.resource_name
			img.set_image(embedded_image)
			return img
		return null


	static func _load_texture_from_path(path: String) -> Texture2D:
		var localized_path = ProjectSettings.localize_path(ProjectSettings.globalize_path(path))
		if ResourceLoader.exists(localized_path):
			var tex := ResourceLoader.load(localized_path)
			if tex != null:
				return tex
		elif FileAccess.file_exists(localized_path):
			var img := Image.load_from_file(ProjectSettings.globalize_path(path))
			if img != null and not img.is_empty():
				return ImageTexture.create_from_image(img)
		return null


class Ctx:
	var state: BBState
	var scale := 1.0 / 16.0
	var base_dir: String = ""
	var nodes: Dictionary[String, Node3D] = { } # uuid -> built node
	var root: Node3D
	var used: Dictionary[String, bool] = { } # uuid -> true (elements placed via the outliner)
	var textures: Array[Tex] = []
	var nearest: bool
	var default_material: Tex
	var texture_extraction: _HandleBinaryImageMode = _HandleBinaryImageMode.EMBED_AS_BASISU

# --------------------------------------------------------------------------------------
# EditorSceneFormatImporter API
# --------------------------------------------------------------------------------------


func _get_extensions() -> PackedStringArray:
	return PackedStringArray(["bbmodel"])


const BBAnimations := preload("bbmodel_animation.gd")
const BBState := preload("bbstate.gd")
const BBTexture := preload("bbtexture.gd")


func _get_import_flags() -> int:
	return IMPORT_SCENE | IMPORT_ANIMATION


enum _HandleBinaryImageMode {
	DISCARD_TEXTURES,
	EXTRACT_TEXTURES,
	EMBED_AS_BASISU,
	EMBED_AS_UNCOMPRESSED, # If this value changes from 3, ResourceImporterScene::pre_import must be changed as well.
}


func _get_import_options(path: String) -> void:
	if path.is_empty() || path.get_extension() == "bbmodel":
		add_import_option("bbmodel/pixels_per_unit", 16.0)
		add_import_option("bbmodel/nearest_filter", true)
		add_import_option("bbmodel/animation_fps", 30.0)
		add_import_option_advanced(
			TYPE_INT,
			"bbmodel/embedded_image_handling",
			2,
			PROPERTY_HINT_ENUM,
			"Discard All Textures:0,Extract Textures:1,Embed as Basis Universal:2,Embed as Uncompressed:3",
			PROPERTY_USAGE_DEFAULT | PROPERTY_USAGE_UPDATE_ALL_IF_MODIFIED,
		)


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
	var model = BBState.new(parsed)

	var ctx := Ctx.new()
	ctx.state = model
	ctx.scale = 1.0 / float(options.get("bbmodel/pixels_per_unit", 16.0))
	ctx.nearest = options.get("bbmodel/nearest_filter", true)

	ctx.texture_extraction = options["bbmodel/embedded_image_handling"]
	ctx.default_material = Tex.new(
		PlaceholderTexture2D.new(),
		Tex._make_material(null, "default_material", ctx.nearest, "default", "auto"),
		ctx.state.resolution,
	)
	ctx.base_dir = path.get_base_dir()
	_load_textures(ctx, model.textures)

	# Root node.
	var root := Node3D.new()
	var model_name := str(model.resource_name)
	if model_name.is_empty():
		model_name = path.get_file().get_basename()
	root.name = model_name
	ctx.root = root

	# Build hierarchy from the outliner, then add any elements it didn't reference.
	var outliner: Array = model.outliner
	_build_children(ctx, root, outliner, Vector3.ZERO)
	for uuid in ctx.state.elements:
		if not ctx.used.has(uuid):
			_build_element(ctx, root, ctx.state.elements[uuid], Vector3.ZERO)

	if (flags & IMPORT_ANIMATION) != 0 and model.animations.size() > 0:
		var fps := float(options.get("bbmodel/animation_fps", 30.0))
		BBAnimations.attach_animations(root, ctx.nodes, model["animations"], ctx.scale, fps)

	return root

# --------------------------------------------------------------------------------------
# Textures
# --------------------------------------------------------------------------------------


func _load_textures(ctx: Ctx, textures: Array) -> void:
	ctx.textures.resize(textures.size())
	var i := 0
	for texture in textures:
		ctx.textures[i] = Tex.from_bbtexture(ctx, texture)
		# ctx.textures[str(texture["id"]).to_int()] = Tex.from_bbtexture(ctx, texture)
		i += 1

# --------------------------------------------------------------------------------------
# Scene tree construction
# --------------------------------------------------------------------------------------


func _build_children(ctx: Ctx, parent: Node3D, entries: Array, parent_origin: Vector3) -> void:
	for entry in entries:
		if typeof(entry) == TYPE_STRING:
			var el: Variant = ctx.state.elements.get(entry)
			if el == null:
				continue
			ctx.used[entry] = true
			_build_element(ctx, parent, el, parent_origin)
		elif typeof(entry) == TYPE_DICTIONARY:
			_build_group(ctx, parent, entry, parent_origin)


func _build_group(ctx: Ctx, parent: Node3D, group: Dictionary, parent_origin: Vector3) -> void:
	var real_group = ctx.state.groups[group["uuid"]]
	if not real_group.export:
		return
	var origin := _to_vector_3(real_group.origin)
	var node := Node3D.new()
	node.name = real_group.name
	_attach(ctx, parent, node)
	ctx.nodes[group.get("uuid", "")] = node
	_apply_transform(ctx, node, origin - parent_origin, real_group.rotation)
	node.visible = real_group.visibility
	_build_children(ctx, node, group.get("children", []), origin)


func Billboard(ctx: Ctx, element: Dictionary) -> Node3D:
	assert(element.get("type", "") == "billboard")
	var billboard: Sprite3D = Sprite3D.new()

	var uv := _to_vector_4(element["faces"]["front"]["uv"])
	var region = Rect2(Vector2(uv.x, uv.y), Vector2(uv.z, uv.w) - Vector2(uv.x, uv.y))
	billboard.region_enabled = true
	billboard.region_rect = region
	billboard.pixel_size = ctx.scale
	billboard.position = _to_vector_3(element.get("position"))
	billboard.name = element.get("name", "billboard")
	match element["facing_mode"]:
		"lookat_y", "rotate_y":
			billboard.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
		"rotate", "lookat":
			billboard.billboard = BaseMaterial3D.BILLBOARD_ENABLED

	if ctx.nearest:
		billboard.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	var mat: Tex
	var key = element["faces"]["front"]["texture"]
	match key:
		true, null:
			billboard.texture = ctx.default_material.texture
		false: # skip face
			pass
		_:
			billboard.texture = ctx.textures[key].texture
	return billboard


func _build_element(ctx: Ctx, parent: Node3D, el: Dictionary, parent_origin: Vector3) -> void:
	if el.get("export", true) == false:
		return
	var type := str(el.get("type", "cube"))
	var el_name := str(el.get("name", type))

	match type:
		"cube", "mesh":
			var origin := _to_vector_3(el.get("origin"))
			var mesh: ImporterMesh
			if type == "cube":
				mesh = _build_cube_mesh(ctx, el, origin, el_name)
			else:
				mesh = _build_mesh_element(ctx, el, el_name)
			if mesh == null:
				return
			var node := ImporterMeshInstance3D.new()
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
		"billboard":
			var billboard := Billboard(ctx, el)
			_attach(ctx, parent, billboard)
			_apply_transform(ctx, billboard, billboard.position - parent_origin, Vector3(0, 0, 0))
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


func _build_cube_mesh(ctx: Ctx, el: Dictionary, origin: Vector3, mesh_name: String) -> ImporterMesh:
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
		var mat: Tex
		var key = faces.get("texture", null)
		match key:
			true, null:
				mat = ctx.default_material
			false: # skip face
				continue
			_:
				mat = ctx.textures[str(key).to_int()]

		var raw_uv: Variant = face.get("uv")
		var rect: Array = raw_uv if raw_uv is Array else []
		if rect.size() < 4:
			rect = box_rects.get(face_name, [0, 0, 0, 0])
		var uvs := _face_uvs(rect, int(face.get("rotation", 0)), mat.uv_size)
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


func _build_mesh_element(ctx: Ctx, el: Dictionary, mesh_name: String) -> ImporterMesh:
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
		var key = face.get("texture", null)
		var mat: Tex
		match key:
			true, null:
				mat = ctx.default_material
			false: # skip face
				continue
			_:
				mat = ctx.textures[str(key).to_int()]

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

		var uv_dict: Dictionary = face.get("uv", { }) if face.get("uv") is Dictionary else { }
		var st := _get_surface(surfaces, key)
		for i in range(1, ids.size() - 1):
			for id in [ids[0], ids[i], ids[i + 1]]:
				var uv_arr: Variant = uv_dict.get(id)
				var uv := Vector2.ZERO
				if uv_arr is Array and uv_arr.size() >= 2:
					uv = Vector2(float(uv_arr[0]), float(uv_arr[1])) / mat.uv_size
				var p: Vector3 = pos[id]
				st.set_normal(normal)
				st.set_uv(uv)
				st.add_vertex(p * ctx.scale)
		if (el["shading"] == "smooth"):
			st.generate_normals()
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


static func _get_surface(surfaces: Dictionary, key: int) -> SurfaceTool:
	if not surfaces.has(key):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		surfaces[key] = st
	return surfaces[key]


static func _commit(ctx: Ctx, surfaces: Dictionary, mesh_name: String) -> ImporterMesh:
	if surfaces.is_empty():
		return null
	var mesh := ArrayMesh.new()
	mesh.resource_name = mesh_name
	var keys: Array = surfaces.keys()
	keys.sort()
	for key in keys:
		var st: SurfaceTool = surfaces[key]
		st.set_material(ctx.textures[key].material)
		st.index()
		st.commit(mesh)
	return ImporterMesh.from_mesh(mesh)


static func _to_vector_3(v: Variant, default: Vector3 = Vector3(0, 0, 0)) -> Vector3:
	if v is Vector3:
		return v
	if v is Array:
		assert(v.size() == 3)
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return default


static func _to_vector_4(v: Variant, default: Vector4 = Vector4(0, 0, 0, 0)) -> Vector4:
	if v is Vector4:
		return v
	if v is Array:
		assert(v.size() == 4)
		return Vector4(float(v[0]), float(v[1]), float(v[2]), float(v[3]))
	return default


static func to_vector_2(v: Variant, default: Vector2 = Vector2(0, 0)) -> Vector2:
	if v is Vector2:
		return v
	if v is Array:
		assert(v.size() == 2)
		return Vector2(float(v[0]), float(v[1]))
	return default
