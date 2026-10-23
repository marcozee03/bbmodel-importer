@tool
extends RefCounted
## Blockbench animation support for the .bbmodel importer.
##
## Every animated (node, channel) becomes one value track on `position`, `rotation` or
## `scale`. Rotation tracks use the node's own ZYX Euler order, so Blockbench's
## component-wise Euler interpolation is preserved.
##
## Tracks are sampled instead of mapped one-to-one, because Blockbench mixes
## interpolation modes per keyframe, supports pre/post keyframes and Molang
## expressions, and Godot tracks have one interpolation mode per track:
##  * channels that are only linear/step with numeric values get one key per keyframe
##    (exact, compact);
##  * anything else (catmullrom, bezier, Molang) is also sampled on an fps grid.
##
## Assumptions that come from general knowledge of Blockbench, not from the project
## codec source. Verify against a real file (see the animation spec, section 14):
##  * rotation/position values are offsets added to the node's rest pose; scale is a
##    multiplier;
##  * a segment is catmullrom/bezier if EITHER end keyframe says so, and step if the
##    FIRST keyframe says so (see _segment_mode);
##  * a keyframe with two data points is pre/post: first = incoming, last = outgoing;
##  * bezier handle times/values are offsets relative to their keyframe.
##
## Effects (sound/particle/timeline) are stored as an Array in the Animation's
## "bbmodel_effects" metadata for game code to consume.

const CHANNELS: Array[String] = ["position", "rotation", "scale"]
const EFFECTS_KEY := "effects"
const EFFECTS_META := "bbmodel_effects"
const RESET_NAME := "RESET"
const PRE_EPSILON := 1.0 / 1200.0 # gap used for the "incoming" sample of pre/post and step keys
const DEDUPE_EPSILON := 0.0001


class AnimationKey:
	var time := 0.0
	var interpolation := "linear"
	var points: Array[Dictionary] = []
	var left_time := Vector3(-0.1, -0.1, -0.1)
	var left_value := Vector3.ZERO
	var right_time := Vector3(0.1, 0.1, 0.1)
	var right_value := Vector3.ZERO


## Math helpers exposed to Molang expressions (Molang trig works in degrees).
class MolangFns:
	func sin_d(x: float) -> float:
		return sin(deg_to_rad(x))


	func cos_d(x: float) -> float:
		return cos(deg_to_rad(x))


	func tan_d(x: float) -> float:
		return tan(deg_to_rad(x))


	func asin_d(x: float) -> float:
		return rad_to_deg(asin(x))


	func acos_d(x: float) -> float:
		return rad_to_deg(acos(x))


	func atan_d(x: float) -> float:
		return rad_to_deg(atan(x))


	func atan2_d(y: float, x: float) -> float:
		return rad_to_deg(atan2(y, x))


## Minimal Molang evaluator built on Godot's Expression class. Supports arithmetic,
## comparisons, math.* functions and query.anim_time. Unknown variables/queries evaluate
## to 0. The ternary operator is not supported (such expressions evaluate to 0).
class MolangEval:
	const REPLACEMENTS := {
		"math.sin(": "sin_d(",
		"math.cos(": "cos_d(",
		"math.tan(": "tan_d(",
		"math.asin(": "asin_d(",
		"math.acos(": "acos_d(",
		"math.atan2(": "atan2_d(",
		"math.atan(": "atan_d(",
		"math.abs(": "absf(",
		"math.floor(": "floorf(",
		"math.ceil(": "ceilf(",
		"math.round(": "roundf(",
		"math.min(": "minf(",
		"math.max(": "maxf(",
		"math.clamp(": "clampf(",
		"math.lerp(": "lerpf(",
		"math.pow(": "pow(",
		"math.sqrt(": "sqrt(",
		"math.mod(": "fmod(",
		"math.random(": "randf_range(",
		"math.pi": "PI",
		"query.anim_time": "anim_time",
		"q.anim_time": "anim_time",
		"query.life_time": "anim_time",
		"q.life_time": "anim_time",
	}

	var _fns := MolangFns.new()
	var _cache := { } # source -> Expression (or null if it failed to parse)
	var _unknown_refs := RegEx.create_from_string(
		"\\b(?:variable|v|temp|t|context|c|query|q)\\.[a-z_][a-z0-9_.]*"
	)


	func evaluate(source: String, anim_time: float) -> float:
		var expr := _get_expression(source)
		if expr == null:
			return 0.0
		var result: Variant = expr.execute([anim_time], _fns, false)
		if expr.has_execute_failed():
			return 0.0
		if result is float or result is int or result is bool:
			return float(result)
		return 0.0


	func _get_expression(source: String) -> Expression:
		if _cache.has(source):
			return _cache[source]
		var expr := Expression.new()
		var err := expr.parse(_translate(source), PackedStringArray(["anim_time"]))
		if err != OK:
			push_warning(
				"BBModel: unsupported Molang expression '%s' (%s); using 0."
				% [source, expr.get_error_text()]
			)
			_cache[source] = null
			return null
		_cache[source] = expr
		return expr


	func _translate(source: String) -> String:
		var s := source.to_lower().strip_edges()
		for key in REPLACEMENTS:
			s = s.replace(key, REPLACEMENTS[key])
		return _unknown_refs.sub(s, "0", true)


## State shared while building all animations of one model.
class Build:
	var root: Node3D
	var nodes: Dictionary # uuid -> Node3D
	var scale := 1.0 / 16.0
	var fps := 30.0
	var molang := MolangEval.new()
	var reset := Animation.new()
	var reset_paths := { } # NodePath -> true

# --------------------------------------------------------------------------------------
# Public API
# --------------------------------------------------------------------------------------


## Applies Blockbench's pre-5.0 -> 5.0 axis migration in place: position/rotation `x`
## and rotation `y` were stored negated (including Molang and bezier handle values).
static func migrate_pre_5(animations: Array) -> void:
	for anim in animations:
		if not anim is Dictionary:
			continue
		var animators := _dict(anim.get("animators"))
		for animator_id in animators:
			for kf in _arr(_dict(animators[animator_id]).get("keyframes")):
				if not kf is Dictionary:
					continue
				var channel := str(kf.get("channel", ""))
				var flip_x := channel == "position" or channel == "rotation"
				var flip_y := channel == "rotation"
				for dp in _arr(kf.get("data_points")):
					if not dp is Dictionary:
						continue
					if flip_x and dp.has("x"):
						dp["x"] = _invert_molang(dp["x"])
					if flip_y and dp.has("y"):
						dp["y"] = _invert_molang(dp["y"])
				if str(kf.get("interpolation", "")) == "bezier":
					for handle_key in ["bezier_left_value", "bezier_right_value"]:
						var handle: Variant = kf.get(handle_key)
						if handle is Array and handle.size() >= 3:
							if flip_x:
								handle[0] = -handle[0]
							if flip_y:
								handle[1] = -handle[1]


## Builds an AnimationPlayer (child of `root`) holding one Animation per Blockbench
## animation, plus a RESET animation with every animated property's rest value.
## `nodes` maps Blockbench uuids to the Node3Ds the importer built for them.
static func attach_animations(
	root: Node3D,
	nodes: Dictionary,
	animations: Array,
	scale: float,
	fps: float,
) -> AnimationPlayer:
	var build := Build.new()
	build.root = root
	build.nodes = nodes
	build.scale = scale
	build.fps = fps

	var library := AnimationLibrary.new()
	for i in animations.size():
		var data: Variant = animations[i]
		if not data is Dictionary:
			continue
		var anim := _build_animation(build, data)
		var anim_name := _unique_name(
			library,
			_sanitize_name(str(data.get("name", "animation_%d" % i))),
		)
		library.add_animation(anim_name, anim)
	if library.get_animation_list().is_empty():
		return null

	if build.reset.get_track_count() > 0:
		build.reset.length = 0.001
		library.add_animation(RESET_NAME, build.reset)

	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	root.add_child(player, true)
	player.owner = root
	player.add_animation_library("", library)
	# Tracks missing from an animation fall back to RESET instead of keeping stale values.
	player.deterministic = true
	return player

# --------------------------------------------------------------------------------------
# Building animations
# --------------------------------------------------------------------------------------


static func _build_animation(b: Build, data: Dictionary) -> Animation:
	var anim := Animation.new()
	var snapping := _num(data.get("snapping"), 24.0)
	if snapping > 0.0:
		anim.step = 1.0 / snapping
	# "once" and "hold" both stop at the end; Godot keeps the last pose.
	anim.loop_mode = Animation.LOOP_LINEAR if str(data.get("loop", "once")) == "loop" else Animation.LOOP_NONE

	var max_time := 0.0
	var animators := _dict(data.get("animators"))
	for animator_id in animators:
		var animator := _dict(animators[animator_id])
		var keyframes := _arr(animator.get("keyframes"))
		if str(animator_id) == EFFECTS_KEY:
			_collect_effects(anim, keyframes)
			continue

		var node: Node3D = b.nodes.get(str(animator_id))
		if node == null:
			push_warning(
				"BBModel: animation '%s' targets unknown node '%s'; skipped."
				% [str(data.get("name", "")), str(animator.get("name", animator_id))]
			)
			continue
		for channel in CHANNELS:
			var keys := _channel_keys(keyframes, channel)
			if keys.is_empty():
				continue
			max_time = maxf(max_time, (keys.back() as AnimationKey).time)
			_add_channel_track(b, anim, node, channel, keys)

	anim.length = maxf(maxf(_num(data.get("length"), 0.0), max_time), 0.001)
	return anim


static func _add_channel_track(
	b: Build,
	anim: Animation,
	node: Node3D,
	channel: String,
	keys: Array,
) -> void:
	var path := NodePath("%s:%s" % [b.root.get_path_to(node), channel])
	var track := anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(track, path)
	anim.track_set_interpolation_type(track, Animation.INTERPOLATION_LINEAR)
	anim.value_track_set_update_mode(track, Animation.UPDATE_CONTINUOUS)

	for t in _sample_times(keys, _needs_grid(keys), b.fps):
		var value := _sample(keys, channel, t, b.molang)
		anim.track_insert_key(track, t, _to_godot(node, channel, value, b.scale))

	if not b.reset_paths.has(path):
		b.reset_paths[path] = true
		var reset_track := b.reset.add_track(Animation.TYPE_VALUE)
		b.reset.track_set_path(reset_track, path)
		b.reset.track_insert_key(reset_track, 0.0, _rest_value(node, channel))


static func _collect_effects(anim: Animation, keyframes: Array) -> void:
	var events: Array = []
	for kf in keyframes:
		if not kf is Dictionary:
			continue
		for dp in _arr(kf.get("data_points")):
			if dp is Dictionary:
				var event := {
					"time": _num(kf.get("time"), 0.0),
					"channel": str(kf.get("channel", "")),
				}
				event.merge(dp)
				events.append(event)
	events.sort_custom(
		func(a, b):
			return a["time"] < b["time"],
	)
	if not events.is_empty():
		anim.set_meta(EFFECTS_META, events)


static func _rest_value(node: Node3D, channel: String) -> Vector3:
	match channel:
		"position":
			return node.position
		"rotation":
			return node.rotation
		_:
			return node.scale


## Blockbench value (units / degrees / multiplier) -> Godot property value.
static func _to_godot(node: Node3D, channel: String, v: Vector3, scale: float) -> Vector3:
	match channel:
		"position":
			return node.position + v * scale
		"rotation":
			return node.rotation + Vector3(deg_to_rad(v.x), deg_to_rad(v.y), deg_to_rad(v.z))
		_:
			return node.scale * v

# --------------------------------------------------------------------------------------
# AnimationKeyframes
# --------------------------------------------------------------------------------------


static func _channel_keys(keyframes: Array, channel: String) -> Array:
	var out: Array = []
	for kf in keyframes:
		if kf is Dictionary and str(kf.get("channel", "")) == channel:
			var key := _parse_key(kf)
			if key != null:
				out.append(key)
	out.sort_custom(
		func(a: AnimationKey, b: AnimationKey) -> bool:
			return a.time < b.time,
	)
	return out


static func _parse_key(kf: Dictionary) -> AnimationKey:
	var key := AnimationKey.new()
	key.time = _num(kf.get("time"), 0.0)
	key.interpolation = str(kf.get("interpolation", "linear"))
	for p in _arr(kf.get("data_points")):
		if p is Dictionary:
			key.points.append(p)
	if key.points.is_empty():
		return null
	key.left_time = _vec3(kf.get("bezier_left_time"), key.left_time)
	key.left_value = _vec3(kf.get("bezier_left_value"), key.left_value)
	key.right_time = _vec3(kf.get("bezier_right_time"), key.right_time)
	key.right_value = _vec3(kf.get("bezier_right_value"), key.right_value)
	return key


## Value of a keyframe. Pre/post keyframes have two data points: the first applies to the
## segment arriving at the key, the last to the segment leaving it.
static func _key_value(
	k: AnimationKey,
	channel: String,
	t: float,
	outgoing: bool,
	molang: MolangEval,
) -> Vector3:
	var point: Dictionary = k.points[k.points.size() - 1] if outgoing else k.points[0]
	var default := 1.0 if channel == "scale" else 0.0
	return Vector3(
		_axis(point.get("x"), t, default, molang),
		_axis(point.get("y"), t, default, molang),
		_axis(point.get("z"), t, default, molang),
	)


static func _axis(v: Variant, t: float, default: float, molang: MolangEval) -> float:
	if v is float or v is int:
		return float(v)
	if v is String:
		var s := String(v).strip_edges()
		if s.is_empty():
			return default
		if s.is_valid_float():
			return s.to_float()
		return molang.evaluate(s, t)
	return default

# --------------------------------------------------------------------------------------
# Sampling
# --------------------------------------------------------------------------------------


## Does this channel need sampling on an fps grid (smooth modes or Molang)?
static func _needs_grid(keys: Array) -> bool:
	for k in keys:
		if k.interpolation == "catmullrom" or k.interpolation == "bezier":
			return true
		for p in k.points:
			for axis in ["x", "y", "z"]:
				var v: Variant = p.get(axis)
				if v is String:
					var s := String(v).strip_edges()
					if not s.is_empty() and not s.is_valid_float():
						return true
	return false


static func _sample_times(keys: Array, needs_grid: bool, fps: float) -> Array[float]:
	var times: Array[float] = []
	var n := keys.size()
	for i in n:
		var k: AnimationKey = keys[i]
		times.append(maxf(k.time, 0.0))
		# Pre/post keyframes need a second sample just before them for the incoming value.
		if i > 0 and k.points.size() > 1:
			var prev: AnimationKey = keys[i - 1]
			if k.time - PRE_EPSILON > prev.time:
				times.append(k.time - PRE_EPSILON)
		# Step segments hold their value until just before the next keyframe.
		if k.interpolation == "step" and i + 1 < n:
			var next: AnimationKey = keys[i + 1]
			if next.time - PRE_EPSILON > k.time:
				times.append(next.time - PRE_EPSILON)

	if needs_grid and fps > 0.0:
		var first: AnimationKey = keys[0]
		var last: AnimationKey = keys[n - 1]
		for frame in range(ceili(first.time * fps), ceili(last.time * fps)):
			times.append(frame / fps)

	times.sort()
	var out: Array[float] = []
	for t in times:
		if out.is_empty() or t - out.back() > DEDUPE_EPSILON:
			out.append(t)
	return out


## Segment interpolation mode. Assumption: smooth modes apply if either end asks for them,
## step is decided by the keyframe the segment starts from.
static func _segment_mode(a: AnimationKey, b: AnimationKey) -> String:
	if a.interpolation == "step":
		return "step"
	if a.interpolation == "catmullrom" or b.interpolation == "catmullrom":
		return "catmullrom"
	if a.interpolation == "bezier" or b.interpolation == "bezier":
		return "bezier"
	return "linear"


static func _sample(keys: Array, channel: String, t: float, molang: MolangEval) -> Vector3:
	var n := keys.size()
	var first: AnimationKey = keys[0]
	var last: AnimationKey = keys[n - 1]
	if t < first.time:
		return _key_value(first, channel, t, false, molang)
	if t >= last.time:
		return _key_value(last, channel, t, true, molang)

	# first.time <= t < last.time: find the segment [a, b] with a.time <= t < b.time.
	var idx := 0
	for i in n - 1:
		if (keys[i + 1] as AnimationKey).time > t:
			idx = i
			break
	var a: AnimationKey = keys[idx]
	var b: AnimationKey = keys[idx + 1]
	var va := _key_value(a, channel, t, true, molang)
	var vb := _key_value(b, channel, t, false, molang)
	var span := b.time - a.time
	var alpha := (t - a.time) / span if span > 0.0 else 1.0

	match _segment_mode(a, b):
		"step":
			return va
		"catmullrom":
			var before := _key_value(keys[idx - 1], channel, t, true, molang) if idx > 0 else va
			var after := _key_value(keys[idx + 2], channel, t, false, molang) if idx + 2 < n else vb
			return va.cubic_interpolate(vb, before, after, alpha)
		"bezier":
			return _bezier(a, b, va, vb, t)
		_:
			return va.lerp(vb, alpha)


## Cubic Bezier per axis, in (time, value) space, using each key's handles.
static func _bezier(
	a: AnimationKey,
	b: AnimationKey,
	va: Vector3,
	vb: Vector3,
	t: float,
) -> Vector3:
	var out := Vector3.ZERO
	for axis in 3:
		var t0 := a.time
		var t3 := b.time
		# Clamping the handle times keeps x(u) monotonic so the bisection below is valid.
		var t1 := clampf(t0 + a.right_time[axis], t0, t3)
		var t2 := clampf(t3 + b.left_time[axis], t0, t3)
		var y0: float = va[axis]
		var y1: float = y0 + a.right_value[axis]
		var y3: float = vb[axis]
		var y2: float = y3 + b.left_value[axis]

		var lo := 0.0
		var hi := 1.0
		for _i in 24:
			var mid := (lo + hi) * 0.5
			if _bezier_point(t0, t1, t2, t3, mid) < t:
				lo = mid
			else:
				hi = mid
		out[axis] = _bezier_point(y0, y1, y2, y3, (lo + hi) * 0.5)
	return out


static func _bezier_point(p0: float, p1: float, p2: float, p3: float, u: float) -> float:
	var inv := 1.0 - u
	return inv * inv * inv * p0 + 3.0 * inv * inv * u * p1 + 3.0 * inv * u * u * p2 + u * u * u * p3

# --------------------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------------------


static func _invert_molang(v: Variant) -> Variant:
	if v is float or v is int:
		return -v
	if v is String:
		var s := String(v).strip_edges()
		if s.is_empty():
			return v
		if s.is_valid_float():
			return -s.to_float()
		return "-(%s)" % s
	return v


static func _sanitize_name(n: String) -> String:
	# AnimationLibrary rejects these characters in animation names.
	var out := n
	for ch in ["/", ":", ",", "["]:
		out = out.replace(ch, "_")
	return out if not out.is_empty() else "animation"


static func _unique_name(library: AnimationLibrary, base: String) -> String:
	var candidate := base
	var n := 2
	while candidate == RESET_NAME or library.has_animation(candidate):
		candidate = "%s_%d" % [base, n]
		n += 1
	return candidate


static func _num(v: Variant, default: float) -> float:
	return float(v) if v is float or v is int else default


static func _dict(v: Variant) -> Dictionary:
	return v if v is Dictionary else { }


static func _arr(v: Variant) -> Array:
	return v if v is Array else []


static func _vec3(v: Variant, default: Vector3) -> Vector3:
	if v is Array and v.size() >= 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return default
