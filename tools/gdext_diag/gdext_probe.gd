extends SceneTree
# 稳定复现器：找出 GDExtension 崩溃的确切条件。
#   GX_MODE=keep|reupload  GX_N=4000  godot --headless -s res://tools/gdext_diag/gdext_probe.gd

func _init() -> void:
	var mode := OS.get_environment("GX_MODE")
	var n := int(OS.get_environment("GX_N"))
	if n <= 0:
		n = 4000
	print("[gx] mode=%s n=%d" % [mode, n])
	var ev = ClassDB.instantiate("SWExprEval")
	if ev == null:
		print("[gx] 实例化失败")
		quit(1)
		return
	if not ev.upload(_tables()):
		print("[gx] upload 失败")
		quit(1)
		return
	print("[gx] upload ok expr=%d seg=%d" % [ev.get_expr_count(), ev.get_seg_count()])

	if mode == "reupload":
		for rep in 400:
			ev.upload(_tables())
			for r in 10:
				ev.set_values(PackedInt32Array([r % 2, 1, 0, 0]))
				ev.evaluate()
				ev.get_values()
		print("[gx] reupload 完成")
		quit(0)
		return

	for r in n:
		if r % 500 == 0:
			print("[gx] r=%d" % r)
		var vals := PackedInt32Array([r % 2, (r / 2) % 2, 0, 0])
		ev.set_values(vals)
		ev.evaluate()
		if mode == "keep":
			var out: PackedInt32Array = ev.get_values()
			if out.size() < 4:
				print("[gx] 长度异常 r=%d" % r)
				break
		else:
			ev.get_values()
	print("[gx] 完成 mode=%s" % mode)
	quit(0)


# slot0/1 输入，slot2 = NOT(slot0)，slot3 = AND(slot2, slot1)
func _tables() -> Array:
	return [
		PackedInt32Array([1, 2]),
		PackedInt32Array([0, 1]),
		PackedInt32Array([1, 1]),
		PackedInt32Array([2, 3]),
		PackedInt32Array([0, 2]),
		PackedInt32Array([0, 1]),
		PackedInt32Array([1, 2]),
		PackedInt32Array([0, 0]),
		PackedInt32Array([0, 0]),
		PackedInt32Array([]),
		PackedInt32Array([0, 0]),
		PackedInt32Array([]),
		PackedInt32Array([2, 3]),
		2,
	]
