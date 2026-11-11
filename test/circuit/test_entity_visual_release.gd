extends GutTest

# 机器人界面「删除实体」的视觉层回归
#
# 现象：右键擦掉一个箱子，画面上另一个箱子/机器人一起消失，但那个格子仍然被占着
#（能挡住新落子，说明数据在、只是不画了）。
#
# 成因在动画层的槽位可见范围：SWAnimBatch.remove_unit 为了 O(1) 删行，把「最后一行」
# 的槽位段搬到被删行，再无条件缩减可见实例数。被删槽位不在末尾时，被搬到末尾槽位的
# 那一台就落到 visible_instance_count 之外 —— 数据在、格子占着、画面消失。
# 机器人走过一格 / 箱子被推过一格之后会常驻动画层（见 detach_render），所以命中概率很高。
#
# 这里走的是真实链路：机器人场景 -> 实体层系统 -> SWEntityVisual -> SWAnimBatch。
#
# 跑法（单文件）：godot --headless --path . -s addons/gut/gut_cmdln.gd
#   -gdir=res://test/circuit -gprefix=test_entity_visual_release -gexit

const SCENE_PATH: String = "res://scene/sw_robot_scene.tscn"
const GRID: Vector2i = SwDefine.GRID_SIZE
#切出机器人场景时落盘的状态文件（与 SWEntityLayerSystem.STATE_PATH 一致）
const STATE_PATH: String = "user://saves/_robot_scene.json"

var scene: Node = null
var sys = null
var vis = null


func before_each() -> void:
	#上个用例释放场景会落盘，不清掉的话 _ready 的恢复会把这批台带进来
	if FileAccess.file_exists(STATE_PATH):
		DirAccess.remove_absolute(STATE_PATH)
	var packed: PackedScene = load(SCENE_PATH)
	assert_not_null(packed, "机器人场景加载失败: " + SCENE_PATH)
	if packed == null:
		return
	scene = packed.instantiate()
	add_child_autofree(scene)
	await wait_frames(3)
	var lm = scene.get_node("SWLayerManager")
	sys = lm.get_layer_system("SWEntityLayer")
	vis = lm.get_node("SWEntityLayer").get_visual()


func after_each() -> void:
	if sys != null and sys.has_method("clear_entities"):
		sys.clear_entities()
	if FileAccess.file_exists(STATE_PATH):
		DirAccess.remove_absolute(STATE_PATH)
	sys = null
	vis = null
	scene = null


# 把某一格的实体挂进动画层（模拟机器人走过 / 被推过的箱子：接管后一直留在动画层）
func _adopt_cell(cell: Vector2i) -> bool:
	var e = sys.get_entity_at(cell * GRID)
	if e == null:
		return false
	sys.detach_render(e)
	return bool(vis.start_move(e, e.grid_pos, e.grid_pos + GRID))


# 缓冲里「真正在画」的实例数（缩放非 0 的段；隐藏段在 advance 开头被清成 0）。
# rng_end < 0 = 扫整块缓冲
func _live_instances(rng_end: int, buf: PackedFloat32Array) -> int:
	var stride: int = SWBuildCompoentRenderable.INSTANCE_STRIDE
	var total: int = buf.size() / stride
	var lim: int = total if rng_end < 0 else mini(rng_end, total)
	var n: int = 0
	for k in lim:
		var o: int = k * stride
		if buf[o] != 0.0 or buf[o + 5] != 0.0:
			n += 1
	return n


func _assert_all_visible(tag: String, cells: Array) -> void:
	#先把待隐藏的槽段清零（advance 开头就干这件事），再比对「可见区里在画的实例数」
	vis.advance(0.0)
	var buf: PackedFloat32Array = vis._batch.get_buffer()
	var vis_n: int = int(vis._batch.get_visible_count())
	var unit_n: int = int(vis.get_unit_count())
	var live_vis: int = _live_instances(vis_n, buf)
	var live_all: int = _live_instances(-1, buf)
	#每台至少占一个实例槽，可见区里的实例数不许比在用台数少
	assert_gte(live_vis, unit_n,
			tag + " 可见区里的实例比在用台数还少: %d/%d" % [live_vis, unit_n])
	#有台被画到可见范围之外 = 数据在、格子占着、画面上消失
	assert_eq(live_vis, live_all,
			tag + " 有台掉出了可见范围: 可见区内 %d / 缓冲内 %d" % [live_vis, live_all])
	for c: Vector2i in cells:
		var e = sys.get_entity_at(c * GRID)
		assert_not_null(e, tag + " 第 %s 格被误删了" % str(c))
		if e == null:
			continue
		assert_true(bool(vis.has_unit(e)), tag + " 第 %s 格被摘出动画层" % str(c))
		assert_true(int(e.anim_row) >= 0 and int(e.anim_row) < int(vis.get_unit_count()),
				tag + " 第 %s 格的动画行号越界: %d" % [str(c), int(e.anim_row)])


func test_delete_middle_and_first_keeps_rest_visible() -> void:
	var cells: Array = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0),
			Vector2i(3, 0), Vector2i(4, 0)]
	for c: Vector2i in cells:
		sys.spawn_box(c * GRID)
		if not _adopt_cell(c):
			assert_true(false, "第 %s 格没能挂进动画层" % str(c))
			return
	assert_eq(int(vis.get_unit_count()), 5, "五台没全部接管")
	_assert_all_visible("接管后", cells)

	#删中间：最后一行会被 swap 到被删行上，它的槽位段留在末尾
	sys.remove_robot_at(Vector2i(2, 0) * GRID)
	assert_eq(int(vis.get_unit_count()), 4, "中间那台没删掉")
	_assert_all_visible("删中间后", [Vector2i(0, 0), Vector2i(1, 0),
			Vector2i(3, 0), Vector2i(4, 0)])

	#再删第一台：整段依次往前搬
	sys.remove_robot_at(Vector2i(0, 0) * GRID)
	assert_eq(int(vis.get_unit_count()), 3, "第一台没删掉")
	_assert_all_visible("删第一台后", [Vector2i(1, 0), Vector2i(3, 0), Vector2i(4, 0)])

	#推一帧，确认缓冲与可见范围同步（隐藏段清零、剩下的台照常推进）
	vis.advance(0.016)
	_assert_all_visible("推进一帧后", [Vector2i(1, 0), Vector2i(3, 0), Vector2i(4, 0)])
