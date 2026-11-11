extends GutTest

# 视觉层动画批处理的槽位不变量（GD 版与原生 SWAnimBatch 共用一套断言）
#
# 背景：remove_unit(r) 为了 O(1) 删行，会把「最后一行」搬到 r（槽位指针一起搬），
# 并把被删行原来的槽位段清零、归还 spare 池。可见实例数必须覆盖所有仍在用的槽位段：
# 早期实现直接 inst_total -= parts，当被删槽位不在末尾时，被 swap 到末尾槽位的
# 那一台就掉出 visible_instance_count 之外 —— 数据还在、格子还占着，但画面上
# 成片消失（机器人/被推过的箱子最容易命中，因为它们常驻动画层）。
#
# 跑法（单文件）：godot --headless --path . -s addons/gut/gut_cmdln.gd
#   -gdir=res://test/circuit -gprefix=test_entity_anim_batch -gexit

const STRIDE: int = 16
const BATCH_NATIVE: String = "SWAnimBatch"
const BATCH_GD = preload("res://scene/entity/sw_anim_batch_gd.gd")


# 两套实现都要过同一组断言：原生没编译好时只剩 GD 一路
func _variants() -> Array:
	var out: Array = []
	if ClassDB.class_exists(BATCH_NATIVE):
		var b = ClassDB.instantiate(BATCH_NATIVE)
		b.setup(SwDefine.GRID_SIZE)
		out.append(["native", b])
	var g = BATCH_GD.new()
	g.setup(SwDefine.GRID_SIZE)
	out.append(["gd", g])
	return out


# 单部件模板：格心原点、无旋转、tint 全白、net_id=-1（只关心位置）
func _tpl(cell_x: float, cell_y: float) -> PackedFloat32Array:
	var gx: float = float(SwDefine.GRID_SIZE.x)
	var gy: float = float(SwDefine.GRID_SIZE.y)
	var t := PackedFloat32Array()
	t.resize(STRIDE)
	t[0] = 1.0
	t[5] = 1.0
	t[3] = cell_x * gx + gx * 0.5
	t[7] = cell_y * gy + gy * 0.5
	t[11] = 1.0
	t[13] = -1.0
	return t


# 当前「可见实例范围」里出现的格心世界坐标
func _visible_origins(b) -> Array:
	var buf: PackedFloat32Array = b.get_buffer()
	var vis: int = int(b.get_visible_count())
	var out: Array = []
	for k in vis:
		var o: int = k * STRIDE
		if o + STRIDE > buf.size():
			break
		out.append(Vector2(buf[o + 3], buf[o + 7]))
	return out


func _center(cell_x: float, cell_y: float) -> Vector2:
	var gx: float = float(SwDefine.GRID_SIZE.x)
	var gy: float = float(SwDefine.GRID_SIZE.y)
	return Vector2(cell_x * gx + gx * 0.5, cell_y * gy + gy * 0.5)


# 删中间行：被 swap 到末尾槽位的那台必须仍然可见
func test_remove_middle_keeps_swapped_row_visible() -> void:
	for v in _variants():
		var tag: String = v[0]
		var b = v[1]
		var gx: float = float(SwDefine.GRID_SIZE.x)
		b.add_unit(_tpl(0, 0), 0.0, 0.0)
		b.add_unit(_tpl(1, 0), gx, 0.0)
		b.add_unit(_tpl(2, 0), gx * 2.0, 0.0)
		b.remove_unit(1)
		assert_eq(int(b.get_unit_count()), 2, tag + " 行数没减")
		var origins: Array = _visible_origins(b)
		assert_true(origins.has(_center(0, 0)), tag + " 第一台看不见了: " + str(origins))
		assert_true(origins.has(_center(2, 0)),
				tag + " 被 swap 到末尾槽位的第三台掉出可见范围（删一个消失一个）: " + str(origins))


# 删末尾行：可见实例数要收缩，之后新增的台要能复用该空洞并可见
func test_remove_tail_shrinks_then_reuses_slot() -> void:
	for v in _variants():
		var tag: String = v[0]
		var b = v[1]
		var gx: float = float(SwDefine.GRID_SIZE.x)
		b.add_unit(_tpl(0, 0), 0.0, 0.0)
		b.add_unit(_tpl(1, 0), gx, 0.0)
		b.remove_unit(1)
		assert_eq(int(b.get_visible_count()), 1, tag + " 删末尾没收缩可见实例数")
		var r: int = int(b.add_unit(_tpl(3, 0), gx * 3.0, 0.0))
		assert_eq(r, 1, tag + " 新行号不对")
		var origins: Array = _visible_origins(b)
		assert_true(origins.has(_center(0, 0)), tag + " 原有台看不见了: " + str(origins))
		assert_true(origins.has(_center(3, 0)), tag + " 复用空洞后的新台不可见: " + str(origins))


# 删中间行后新增：空洞复用不能让任何一台掉出可见范围
func test_add_after_middle_remove_keeps_all_visible() -> void:
	for v in _variants():
		var tag: String = v[0]
		var b = v[1]
		var gx: float = float(SwDefine.GRID_SIZE.x)
		b.add_unit(_tpl(0, 0), 0.0, 0.0)
		b.add_unit(_tpl(1, 0), gx, 0.0)
		b.add_unit(_tpl(2, 0), gx * 2.0, 0.0)
		b.remove_unit(0)
		b.add_unit(_tpl(4, 0), gx * 4.0, 0.0)
		var origins: Array = _visible_origins(b)
		assert_true(origins.has(_center(1, 0)), tag + " 第二台看不见了: " + str(origins))
		assert_true(origins.has(_center(2, 0)), tag + " 第三台看不见了: " + str(origins))
		assert_true(origins.has(_center(4, 0)), tag + " 新加的第四台看不见: " + str(origins))


# 正在动画中的台被 swap 到被删行后必须继续推进，不能停在半路
func test_swapped_row_keeps_animating() -> void:
	for v in _variants():
		var tag: String = v[0]
		var b = v[1]
		var gx: float = float(SwDefine.GRID_SIZE.x)
		b.add_unit(_tpl(0, 0), 0.0, 0.0)      # 行 0：站着不动的箱子
		b.add_unit(_tpl(5, 0), gx * 5.0, 0.0) # 行 1：正在滑的机器人
		b.set_move(1, Vector2(gx * 6.0, 0.0), 0.2)
		b.advance(0.02)
		# 删掉静止的行 0，行 1 被搬到行 0（此时它还在滑）
		b.remove_unit(0)
		# 不再调用 set_move：推进登记应该跟着行一起搬过来
		b.advance(0.2)
		var p: Vector2 = b.get_pos(0)
		assert_almost_eq(p.x, gx * 6.0, 0.5,
				tag + " 被 swap 的台中停在半路（推进登记丢了）: " + str(p))


# 删台不能把「下一台新建拿到的模板」错位成上一台留下的旧模板
func test_add_after_remove_uses_new_template() -> void:
	for v in _variants():
		var tag: String = v[0]
		var b = v[1]
		var gx: float = float(SwDefine.GRID_SIZE.x)
		b.add_unit(_tpl(0, 0), 0.0, 0.0)
		b.add_unit(_tpl(1, 0), gx, 0.0)
		b.add_unit(_tpl(2, 0), gx * 2.0, 0.0)
		b.remove_unit(1)
		b.add_unit(_tpl(7, 0), gx * 7.0, 0.0)
		var origins: Array = _visible_origins(b)
		assert_true(origins.has(_center(7, 0)),
				tag + " 新建的台画在别人的模板位置上（模板表没跟着缩容）: " + str(origins))
