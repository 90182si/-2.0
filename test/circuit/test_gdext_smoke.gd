extends GutTest
# GDExtension 加载与基础正确性自测。
#   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/circuit/test_gdext_smoke.gd -gselect=test_gdext_smoke -gexit
#
# ⚠ 原生路径当前默认关闭（SWExprBuilder.enable_native = false），原因见 SPEC-06 §4：
#   存在偶发段错误（约 40%），尚未定位。本用例因此改为「检测到扩展则跑一次最小验证，
#   失败/崩溃不影响主流程」的形态；主流程不走原生求值。
#
# 注意：本用例不在 GUT 全量里跑原生压力循环 —— 那正是会触发崩溃的用法。
# 想验证原生实现请单独跑 gdext_probe.gd（它明确标注为诊断工具）。

const LOG_PATH := "res://_gdext.txt"
var _lines: Array[String] = []

func _w(m: String) -> void:
	_lines.append(m)

# 万级机器人动画层（SWAnimBatch）的最小验证：
# 只管「能不能实例化 + 一次批量起滑 + 插值与缓冲确实变了」，不跑压力循环。
# 这层一旦失配（接口名/参数个数对不上）会让 slice 巡检的实体直接卡住不动，
# 所以即使没有原生也把「类存在」写进日志，方便现场判断走的是哪条路
func test_gdext_anim_batch() -> void:
	var has_class := ClassDB.class_exists("SWAnimBatch")
	_w("ClassDB.class_exists(SWAnimBatch) = %s" % str(has_class))
	if not has_class:
		_dump()
		pass_test("SWAnimBatch 未构建，回退 GDScript 版")
		return
	var b = ClassDB.instantiate("SWAnimBatch")
	assert_not_null(b, "无法实例化 SWAnimBatch")
	if b == null:
		_dump()
		return
	add_child_autofree(_RefHolder.new(b))
	b.setup(Vector2i(32, 32))
	# 一个部件、16 float 的实例数据：[3]/[7] 是该部件的原点 xy
	var tpl := PackedFloat32Array()
	tpl.resize(16)
	tpl[3] = 100.0
	tpl[7] = 200.0
	var r: int = b.add_unit(tpl, 100.0, 200.0)
	assert_eq(r, 0, "首行行号应为 0")
	assert_eq(b.get_unit_count(), 1, "行数")
	assert_eq(b.get_visible_count(), 1, "可见实例数")
	# 批量起滑：往右一格（132, 200），时长 0.16s
	b.start_moves(PackedInt32Array([0]), PackedFloat32Array([132.0, 200.0]), 0.16)
	assert_true(b.is_busy(0), "起滑后应处于忙碌")
	b.advance(0.08)
	assert_almost_eq(b.get_pos(0).x, 116.0, 2.0, "半程应落在起终点之间")
	b.advance(0.2)
	assert_false(b.is_busy(0), "走完应不再忙")
	assert_almost_eq(b.get_pos(0).x, 132.0, 0.01, "走完应正好落在终点")
	# 缓冲里的原点 x 也必须是终点（纯平移只改 [3]/[7]）
	var buf: PackedFloat32Array = b.get_buffer()
	assert_almost_eq(buf[3], 132.0, 0.01, "实例缓冲原点未跟上")
	assert_almost_eq(buf[7], 200.0, 0.01, "实例缓冲原点未跟上（y）")
	b.remove_unit(0)
	assert_eq(b.get_unit_count(), 0, "删行后行数应归零")
	b.reset()
	_w("批量起滑 / 插值 / 写缓冲 / 删行 最小验证通过")
	_dump()
	pass_test("SWAnimBatch smoke ok")

# 转向用的「模板原地转」：机器人是单部件、原点就在格心，原地转 90° 必须与
# 「按新朝向重烘」等价（重烘 7.5us/台，一万台同拍转向就是 75ms，所以走这条）。
# 这里的期望值就是 writeInstances 烘 dir=1/2 时的基向量：
#   basis.x = (cos, -sin)、basis.y = (sin, cos)
func test_gdext_rotate_tpl() -> void:
	if not ClassDB.class_exists("SWAnimBatch"):
		pass_test("SWAnimBatch 未构建，回退 GDScript 版")
		return
	var b = ClassDB.instantiate("SWAnimBatch")
	assert_not_null(b, "无法实例化 SWAnimBatch")
	if b == null:
		return
	add_child_autofree(_RefHolder.new(b))
	b.setup(Vector2i(32, 32))
	var tpl := PackedFloat32Array()
	tpl.resize(16)
	tpl[0] = 1.0   #basis.x = (1, 0)
	tpl[5] = 1.0   #basis.y = (0, 1)
	tpl[3] = 116.0 #原点 = 格子左上 (100,200) + 半格 (16,16)
	tpl[7] = 216.0
	assert_eq(int(b.add_unit(tpl, 100.0, 200.0)), 0)

	assert_true(bool(b.rotate_tpl(0, 90.0)), "格心上的单部件模板应当能原地转")
	var buf: PackedFloat32Array = b.get_buffer()
	assert_almost_eq(buf[0], 0.0, 0.001, "转 90° 后 basis.x.x")
	assert_almost_eq(buf[1], -1.0, 0.001, "转 90° 后 basis.x.y（应为 -sin90）")
	assert_almost_eq(buf[4], 1.0, 0.001, "转 90° 后 basis.y.x（应为 sin90）")
	assert_almost_eq(buf[5], 0.0, 0.001, "转 90° 后 basis.y.y")
	assert_almost_eq(buf[3], 116.0, 0.001, "绕格心转不该挪动原点")
	assert_almost_eq(buf[7], 216.0, 0.001, "绕格心转不该挪动原点（y）")

	# 再转 90° = 180°：basis.x 应为 (-1,0)
	assert_true(bool(b.rotate_tpl(0, 90.0)))
	buf = b.get_buffer()
	assert_almost_eq(buf[0], -1.0, 0.001, "累计转 180° 后 basis.x.x")
	assert_almost_eq(buf[1], 0.0, 0.001, "累计转 180° 后 basis.x.y")

	# 原点不在格心（多部件 / 跨格偏移）必须拒绝：那种台只能重铺
	var tpl2 := PackedFloat32Array()
	tpl2.resize(16)
	tpl2[0] = 1.0
	tpl2[5] = 1.0
	tpl2[3] = 300.0
	tpl2[7] = 400.0
	assert_eq(int(b.add_unit(tpl2, 300.0, 400.0)), 1)
	assert_false(bool(b.rotate_tpl(1, 90.0)), "原点不在格心的模板不该允许原地转")
	b.reset()
	pass_test("rotate_tpl ok")


func test_gdext_smoke() -> void:
	var has_class := ClassDB.class_exists("SWExprEval")
	_w("ClassDB.class_exists(SWExprEval) = %s" % str(has_class))
	_w("SWExprBuilder.enable_native 默认 = %s" % str(SWExprBuilder.new().enable_native))
	if not has_class:
		_dump()
		pass_test("GDExtension 未构建，跳过")
		return
	# 只做「类可实例化 + 能 upload」的最小检查，不跑高频循环
	var ev = ClassDB.instantiate("SWExprEval")
	assert_not_null(ev, "无法实例化 SWExprEval")
	if ev == null:
		_dump()
		return
	add_child_autofree(_RefHolder.new(ev))
	# upload 只接受一个 Array（13 张表 + expr_count），见 SWExprEval::upload 注释
	var tables: Array = [
		PackedInt32Array([1]),        # seg_op:   NOT
		PackedInt32Array([0]),        # seg_start
		PackedInt32Array([1]),        # seg_count
		PackedInt32Array([2]),        # seg_dst
		PackedInt32Array([0]),        # seg_src0
		PackedInt32Array([0]),        # seg_src1
		PackedInt32Array([1]),        # seg_n
		PackedInt32Array([0]),        # seg_off
		PackedInt32Array([0]),        # seg_const
		PackedInt32Array([]),         # src_flat
		PackedInt32Array([0, 0]),     # extra_start
		PackedInt32Array([]),         # extra_dst
		PackedInt32Array([2]),        # primary
		1,                            # expr_count
	]
	var ok = ev.upload(tables)
	_w("upload = %s expr=%d seg=%d" % [str(ok), ev.get_expr_count(), ev.get_seg_count()])
	assert_true(ok, "upload 失败")
	# 单次求值验证 NOT 语义
	ev.set_values(PackedInt32Array([0, 0, 0]))
	ev.evaluate()
	var out: PackedInt32Array = ev.get_values()
	_w("NOT(0) -> %s" % str(out))
	assert_eq(out[2], 1, "NOT 语义错误")
	ev.set_values(PackedInt32Array([1, 0, 0]))
	ev.evaluate()
	out = ev.get_values()
	assert_eq(out[2], 0, "NOT 语义错误（输入 1）")
	_w("最小验证通过（注意：原生路径默认未启用，见 SPEC-06 §4）")
	_dump()
	pass_test("gdext smoke ok（最小验证）")


# 强引用持有者：把原生对象挂到场景树上，保证用例期间不被 GC
class _RefHolder extends Node:
	var obj = null
	func _init(o) -> void:
		obj = o


func _dump() -> void:
	var f := FileAccess.open(LOG_PATH, FileAccess.WRITE)
	for l in _lines:
		f.store_line(l)
	f.close()
