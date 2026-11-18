extends AnimatableBody3D
# func_door example, should work for most q3 doors
# slides along 'angle' / 'angles'

const SPAWN_START_OPEN := 1

@export var angle: float = 0.0
@export var angles := Vector3.ZERO
@export var speed: float = 400.0
@export var wait: float = 2.0
@export var lip: float = 8.0
@export var team: String = ""
@export var targetname: String = ""
@export var spawnflags: int = 0
@export var health: int = 0

var open := false
var _busy := false
var _closed_pos := Vector3.ZERO
var _open_pos := Vector3.ZERO
var _move := Vector3.ZERO
var _duration := 0.2
var _tween: Tween
var _scale_u := 32.0


func _unit_scale() -> float:
	var opts: Dictionary = Tech3BSPReader.options
	if opts is Dictionary and opts.has("unit_scale"):
		var s := float(opts["unit_scale"])
		if s > 0.0:
			return s
	return 32.0


func _combined_aabb() -> AABB:
	var acc := AABB()
	var any := false
	for child in find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi.mesh == null:
			continue
		var local: AABB = mi.mesh.get_aabb()
		var xf: Transform3D = global_transform.inverse() * mi.global_transform
		for i in 8:
			var p: Vector3 = xf * local.get_endpoint(i)
			if any:
				acc = acc.expand(p)
			else:
				acc = AABB(p, Vector3.ZERO)
				any = true
	return acc


func _ready() -> void:
	_scale_u = _unit_scale()
	sync_to_physics = true
	input_ray_pickable = false
	collision_layer = 1
	collision_mask = 0
	if team != "":
		add_to_group(team)

	var dir := Tech3BSPReader.tech3_movedir(angle, angles)
	var aabb := _combined_aabb()
	if aabb.size.length_squared() < 0.000001:
		push_warning("func_door: no mesh, removing")
		queue_free()
		return

	var spd := speed / _scale_u
	var lip_u := lip / _scale_u
	var dist: float = abs(dir.x) * aabb.size.x + abs(dir.y) * aabb.size.y + abs(dir.z) * aabb.size.z - lip_u
	if dist < 0.0:
		dist = 0.0
	_move = dir * dist
	_duration = dist / maxf(spd, 0.001)
	_closed_pos = position
	_open_pos = _closed_pos + _move
	_setup_trigger(aabb)

	if spawnflags & SPAWN_START_OPEN:
		var tmp := _closed_pos
		_closed_pos = _open_pos
		_open_pos = tmp
		_move = -_move
		position = _closed_pos
		open = true

	# targetname / health: q3 does not spawn a touch trigger
	var area := get_node_or_null("Area3D") as Area3D
	if area and targetname == "" and health <= 0:
		area.body_entered.connect(_body_entered)
	elif area:
		area.monitoring = false


func _setup_trigger(aabb: AABB) -> void:
	var area := get_node_or_null("Area3D") as Area3D
	if area == null:
		return
	area.top_level = true
	area.collision_layer = 0
	area.collision_mask = 2
	area.monitorable = false

	var swell := 60.0 / _scale_u
	var size := aabb.size
	var axis := 0
	if size.y <= size.x and size.y <= size.z:
		axis = 1
	elif size.z <= size.x and size.z <= size.y:
		axis = 2
	size[axis] += swell * 2.0
	var shape := BoxShape3D.new()
	shape.size = size
	var cs := area.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if cs == null:
		cs = CollisionShape3D.new()
		area.add_child(cs)
	cs.shape = shape
	area.global_position = global_transform * aabb.get_center()
	cs.position = Vector3.ZERO


## Slide to the open position. If already open and idle, closes instead (Q3 toggle).
## Usage: door.door_open() or get_tree().call_group(team, "door_open")
func door_open() -> void:
	if open and not _busy:
		door_close()
		return
	_kill_tween()
	_busy = true
	open = true
	_tween = create_tween()
	_tween.tween_property(self, "position", _open_pos, _duration)
	_tween.finished.connect(_on_opened)


## Wait `wait` seconds, then slide back to the closed position. No-op if wait < 0.
## Usage: door.door_close()
func door_close() -> void:
	if wait < 0.0:
		return
	if not open:
		return
	_kill_tween()
	_busy = true
	_tween = create_tween()
	_tween.tween_interval(wait)
	_tween.tween_property(self, "position", _closed_pos, _duration)
	_tween.finished.connect(_on_closed)


func _on_opened() -> void:
	_busy = false
	if wait >= 0.0 and targetname == "" and health <= 0:
		# q3 starts the close clock when the door reaches pos2
		door_close()


func _on_closed() -> void:
	_busy = false
	open = false


func _kill_tween() -> void:
	if _tween:
		_tween.kill()
		_tween = null


func _body_entered(body: Node3D) -> void:
	if body is not CharacterBody3D:
		return

	if team != "":
		get_tree().call_group(team, "door_open")
	else:
		door_open()


## Target / +use hook: close if open, otherwise open.
## Usage: door.use_door(activator)
func use_door(_activator: Node = null) -> void:
	if open:
		door_close()
	else:
		door_open()
