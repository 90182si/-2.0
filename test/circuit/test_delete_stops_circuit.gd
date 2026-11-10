extends GutTest
# 删除元件后电路必须停止求值（用户反馈：「删除某些元件后，电路依旧在跑」）。
#   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/circuit/test_delete_stops_circuit.gd -gselect=test_delete_stops_circuit -gexit
#
# 根因（修复前）：_do_cut / _do_delete_selected 只调 build_manager.delBuilds，
#   既没 updateBuildCircuit 重建电路，也没从 clockBuildArr 移除被删的时钟，
#   于是每帧 tick 仍用「已删除的时钟」当 seed 触发 buildSignalsChanged → 电路继续跑。

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const SAVE_NAME := "16x计数器"
#排障转储：以前写死旧盘符的绝对路径，工程搬家后 FileAccess.open 拿到 null，
#整个用例变成「Unexpected Errors」失败。写到 user:// 跟盘符无关
const LOG_PATH := "user://_del.txt"
var _lines: Array[String] = []

func _w(m: String) -> void:
	_lines.append(m)

func test_delete_stops_circuit() -> void:
	var harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)
	await harness.boot_game()
	var data: Dictionary = await harness.load_save(SAVE_NAME)
	if data.is_empty():
		_w("LOAD FAILED"); _dump(); fail_test("存档加载失败"); return
	var sys = harness.build_layer.layer_system
	var ctrl = sys.circuit_control
	var guard := 0
	while guard < 2000 and sys.clockBuildArr.is_empty():
		guard += 1
		await get_tree().process_frame

	var clocks_before: int = sys.clockBuildArr.size()
	_w("删除前：时钟注册表=%d 电路数=%d" % [clocks_before, ctrl.circuits.size()])
	assert_gt(clocks_before, 0, "存档应有时钟")

	# 先跑几拍让电路真正建起后端并开始求值，证明「删除前是活的」
	sys._last_clock_usec = 0
	for i in 3:
		_force_tick(sys)
	var ctrl_circuits: int = ctrl.circuits.size()
	var backends: int = ctrl._cpu_backends.size() + ctrl._gpu_backends.size()
	var epoch_alive: int = SwCommon.evalEpoch
	_w("删除前跑 3 拍后：电路数=%d 后端数=%d evalEpoch=%d" % [
		ctrl_circuits, backends, epoch_alive])
	assert_gt(backends, 0, "删除前应有已建好的求值后端（否则测试无效）")

	# 取出全部时钟并删除（模拟玩家删除元件）
	var clocks: Array = sys.clockBuildArr.keys()
	for c in clocks:
		sys._pendingRemovedBuilds[c] = true
		c.buildState.state = SwDefine.BuildState.TO_BE_REMOVED
	sys.build_manager.delBuilds(clocks)
	# 走删除善后（与 _do_delete_selected / _do_cut 相同的统一入口）
	var notify: Array = sys.getNotifyChunkPosArr(clocks)
	sys._notify_circuit_after_removed(clocks, notify)

	var clocks_after: int = sys.clockBuildArr.size()
	_w("删除后：时钟注册表=%d 电路数=%d" % [clocks_after, ctrl.circuits.size()])
	assert_eq(clocks_after, 0, "删除时钟后注册表应清空（否则电路会继续跑）")

	# 再手动跑几次 tick：不应再有任何求值动作
	var eval_before: int = SwCommon.evalEpoch
	for i in 5:
		sys._last_clock_usec = 0   # 强制允许 tick
		sys.tick_clocks() if sys.has_method("tick_clocks") else _force_tick(sys)
	var eval_after: int = SwCommon.evalEpoch
	_w("删除后连续 tick 5 次：evalEpoch %d -> %d" % [eval_before, eval_after])
	assert_eq(eval_after, eval_before,
			"删除全部时钟后电路仍在求值（evalEpoch 前进了 %d）" % (eval_after - eval_before))
	_dump()
	pass_test("删除后电路已停止")

# 直接调时钟驱动入口（不同版本命名可能不同，这里做容错）
func _force_tick(sys) -> void:
	if sys.has_method("_clock_tick"):
		sys._clock_tick()
	elif sys.has_method("tick_clock"):
		sys.tick_clock()
	else:
		# 兜底：手工复刻 tick 主体（注意 buildSignalsChanged 需要 typed array）
		var clocks: Array[SWBuildItemDefine] = []
		for b in sys.clockBuildArr.keys():
			clocks.append(b)
		if clocks.is_empty():
			return
		for build in clocks:
			build.onPressed(true)
		var changed = sys.circuit_control.buildSignalsChanged(clocks)
		sys.refresh_signal_chunks(changed)

func _dump() -> void:
	var f := FileAccess.open(LOG_PATH, FileAccess.WRITE)
	for l in _lines:
		f.store_line(l)
	f.close()
