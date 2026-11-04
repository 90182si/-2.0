extends SceneTree
# 独立脚本（不经 GUT）：直接验证 GDExtension 求值器的正确性与稳定性。
#   godot --headless -s res://test/circuit/gdext_standalone_check.gd
#
# 说明：把这段检查从 GUT 用例里拿出来，是因为 GUT 的 autofree/orphan 机制
# 与 RefCounted 原生对象的生命周期交互复杂，曾导致偶发段错误且难以定位。
# 这里用最朴素的方式跑，确认扩展本身没问题。

func _init() -> void:
	var ok := true
	if not ClassDB.class_exists("SWExprEval"):
		print("[gdext] SWExprEval 未注册（扩展未构建），跳过")
		quit(0)
		return
	print("[gdext] SWExprEval 已注册")
	var ev = ClassDB.instantiate("SWExprEval")
	if ev == null:
		print("[gdext] 实例化失败")
		quit(1)
		return

	# slot0/1 输入，slot2 = NOT(slot0)，slot3 = AND(slot2, slot1)
	var seg_op := PackedInt32Array([1, 2])
	var seg_start := PackedInt32Array([0, 1])
	var seg_count := PackedInt32Array([1, 1])
	var seg_dst := PackedInt32Array([2, 3])
	var seg_src0 := PackedInt32Array([0, 2])
	var seg_src1 := PackedInt32Array([0, 1])
	var seg_n := PackedInt32Array([1, 2])
	var seg_off := PackedInt32Array([0, 0])
	var seg_const := PackedInt32Array([0, 0])
	var src_flat := PackedInt32Array([])
	var extra_start := PackedInt32Array([0, 0])
	var extra_dst := PackedInt32Array([])
	var primary := PackedInt32Array([2, 3])
	ev.upload(seg_op, seg_start, seg_count, seg_dst, seg_src0, seg_src1,
			seg_n, seg_off, seg_const, src_flat, extra_start, extra_dst, primary, 2)

	# 4 种输入组合各跑 1000 次（压力测试稳定性）
	var keys := [Vector2i(0, 0), Vector2i(0, 1), Vector2i(1, 0), Vector2i(1, 1)]
	var want2 := [1, 1, 0, 0]
	var want3 := [0, 1, 0, 0]
	var rounds := 1000
	for idx in keys.size():
		var kk: Vector2i = keys[idx]
		for r in rounds:
			if r % 100 == 0:
				print("[gdext] idx=%d round=%d" % [idx, r])
			ev.set_values(PackedInt32Array([kk.x, kk.y, 0, 0]))
			ev.evaluate()
			var out: PackedInt32Array = ev.get_values()
			if out.size() < 4:
				print("[gdext] get_values 长度异常=%d" % out.size())
				ok = false
				break
			if out[2] != int(want2[idx]) or out[3] != int(want3[idx]):
				print("[gdext] 失败 输入=%s 输出=%s" % [str(kk), str(out)])
				ok = false
				break
	print("[gdext] 压力测试 4000 次求值 %s" % ("通过" if ok else "失败"))
	quit(0 if ok else 1)
