extends GutTest
# 「删除 7w 元件花了五个小时」的端到端规模回归。
# 与 test_bench_seed_cost 的区别：这里走真实场景树 + 完整删除链路
# （标记 → 分帧离表 → 取种子 → 9 阶段重建 → 摘旧电路），并且整片是「有电路」的
# （纯电线不建电路，只有挂了非门的那一片才落在同一条 circuit 里）。
# 验证目标：删除总耗时随规模大致线性，不出现平方级放大。
# 跑法：godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://test/circuit -gprefix test_bench_bulk_delete_circuit -gexit

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const WIRE_DEF: SWBuildDefine = preload("res://res/电线A.tres")
const NOT_DEF: SWBuildDefine = preload("res://res/非门.tres")
# 每隔这么多格放一个非门：保证整片是「有电路」的场景（纯电线不建 circuit）
const GATE_EVERY := 40

var harness = null
# 两个规模必须分在两个用例里：同一帧内 shutdown 后再 boot 会撞上
# 旧场景还没执行完的 _process（它引用的渲染系统已经释放）
var _small: Dictionary = {}

func before_each() -> void:
	harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)

func after_each() -> void:
	if harness != null:
		harness.shutdown_game()
		harness = null

func _fill(mgr: SWBuildManager, side: int) -> Array[SWBuildItemDefine]:
	var arr: Array[SWBuildItemDefine] = []
	var n: int = 0
	for y in side:
		for x in side:
			n += 1
			var def: SWBuildDefine = NOT_DEF if n % GATE_EVERY == 0 else WIRE_DEF
			var b := SwDefine.SWBuildCreator(Vector2i(x, y) * SwDefine.GRID_SIZE, def, 0)
			if mgr.addBuild(b):
				arr.append(b)
	return arr

func _wait_remove_done(sys: SWBuildLayerSystem, max_frames: int = 6000) -> int:
	var frames: int = 0
	while sys._remove_busy:
		frames += 1
		if frames > max_frames:
			return -1
		await get_tree().process_frame
	return frames

# 返回 {n, keep, ms, frames, ms_per_del, biggest_circuit}
func _run_case(side: int, keep: int) -> Dictionary:
	await harness.boot_game()
	var sys: SWBuildLayerSystem = harness.build_layer.layer_system
	var mgr: SWBuildManager = sys.build_manager
	var all := _fill(mgr, side)
	var ctrl: SWCircuitControl = sys.circuit_control
	ctrl.updateBuildCircuit(all)

	var biggest: int = 0
	for b in all:
		if b.circuit != null:
			biggest = maxi(biggest, b.circuit.buildArr.size())

	var n := all.size()
	var removed: Array[SWBuildItemDefine] = []
	removed.assign(all.slice(0, n - keep))
	var t0 := Time.get_ticks_msec()
	sys._start_remove_and_followup(removed, sys.getNotifyChunkPosArr(removed))
	var frames: int = await _wait_remove_done(sys)
	var ms := Time.get_ticks_msec() - t0

	var alive: int = 0
	for b in all.slice(n - keep, n):
		if mgr.getBuild(b.buildAxisPos) == b:
			alive += 1
	var total: int = mgr.getBuildCount()
	return {
		"n": removed.size(), "keep": keep, "ms": ms, "frames": frames,
		"ms_per_del": float(ms) / float(maxi(removed.size(), 1)),
		"biggest_circuit": biggest, "alive": alive, "total": total,
	}

func test_a_small_bulk_remove_with_circuit() -> void:
	_small = await _run_case(64, 1600)
	print("[scale] 删 %d（电路 %d）：%d ms / %d 帧 ≈ %.3f ms 每栋，活 %d" % [
		_small["n"], _small["biggest_circuit"], _small["ms"], _small["frames"],
		_small["ms_per_del"], _small["alive"]])
	assert_ne(_small["frames"], -1, "小规模删除没在合理帧数内结束")
	assert_eq(_small["alive"], _small["keep"], "活元件不能丢")
	assert_eq(_small["total"], _small["keep"], "建筑表应只剩活元件")

func test_b_big_bulk_remove_scales_linearly() -> void:
	var big: Dictionary = await _run_case(90, 2100)
	print("[scale] 删 %d（电路 %d）：%d ms / %d 帧 ≈ %.3f ms 每栋，活 %d" % [
		big["n"], big["biggest_circuit"], big["ms"], big["frames"],
		big["ms_per_del"], big["alive"]])
	assert_ne(big["frames"], -1, "大规模删除没在合理帧数内结束")
	assert_eq(big["alive"], big["keep"], "活元件不能丢")
	assert_eq(big["total"], big["keep"], "建筑表应只剩活元件")

	if _small.is_empty():
		return
	# 删除数放大 2.4 倍：按单栋耗时比较，放大超过 2 倍就说明还有超线性环节
	var ratio: float = float(big["ms_per_del"]) / maxf(float(_small["ms_per_del"]), 0.001)
	print("[scale] 单栋耗时比 = %.2f（删除数比 = %.2f）" % [
		ratio, float(big["n"]) / float(_small["n"])])
	assert_lt(ratio, 2.0, "删除单栋耗时随规模不能明显变大（说明存在平方级环节）")
