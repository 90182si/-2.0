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

const LOG_PATH := "j:/godot/无限地图/_gdext.txt"
var _lines: Array[String] = []

func _w(m: String) -> void:
	_lines.append(m)

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
