extends Resource
var name: String = "Group"
var uuid: String
var export: bool = true
var locked: bool = false
var visibility: bool = true
var origin: Vector3
var rotation: Vector3


static func _to_vector_3(v: Variant, default: Vector3 = Vector3(0, 0, 0)) -> Vector3:
	if v is Vector3:
		return v
	if v is Array:
		assert(v.size() == 3)
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return default


func _init(group: Dictionary):
	uuid = group.get("uuid", "")
	name = group.get("name", "Group")
	self.export = group.get("export", true)
	locked = group.get("locked", false)
	visibility = group.get("visibility", true)
	origin = _to_vector_3(group.get("origin"))
	rotation = _to_vector_3(group.get("rotation"))
