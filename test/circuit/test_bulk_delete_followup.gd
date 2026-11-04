extends GutTest
# 大批量删除的「先标记再分帧」回归：一次删超过 BULK_REMOVE_THRESHOLD 时，
# SWBuildLayerSystem 必须先把整批标成 TO_BE_REMOVED（电路当场视作断开），
# 再把标记与真正离表分帧做（_run_remove_job），跑完后：
#   被删建筑离开 id 表、剩下的建筑一个不丢、删除善后闸门（_remove_busy）复位。
# 之前是单帧同步删 + 单帧同步善后：7w 元件会把主线程钉住好几秒（用户反馈的「非常慢」）。
# 跑法：godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://test/circuit -gprefix test_bulk_delete_followup -gexit

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const WIRE_DEF: SWBuildDefine = preload("res://res/电线A.tres")
# 60 * 50 = 3000 > BULK_REMOVE_THRESHOLD(2048)
const SIDE_X := 60
const SIDE_Y := 50
# 留下的活元件数（删除区里的「周长」邻居就是它们）
const KEEP := 200

var harness = null

func before_each() -> void:
	harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)

func after_each() -> void:
	if harness != null:
		harness.shutdown_game()
		harness = null

# 铺一片电线，返回按行优先顺序的数组
func _build_block(mgr: SWBuildManager) -> Array[SWBuildItemDefine]:
	var arr: Array[SWBuildItemDefine] = []
	for y in SIDE_Y:
		for x in SIDE_X:
			var b := SwDefine.SWBuildCreator(Vector2i(x, y) * SwDefine.GRID_SIZE, WIRE_DEF, 0)
			if mgr.addBuild(b):
				arr.append(b)
	return arr

# 等善后任务跑完（每帧推进一次）。返回用掉的帧数，超过上限返回 -1。
func _wait_remove_done(sys: SWBuildLayerSystem, max_frames: int = 900) -> int:
	var frames: int = 0
	while sys._remove_busy:
		frames += 1
		if frames > max_frames:
			return -1
		await get_tree().process_frame
	return frames

func test_bulk_remove_runs_staged_and_keeps_survivors() -> void:
	await harness.boot_game()
	var sys: SWBuildLayerSystem = harness.build_layer.layer_system
	var mgr: SWBuildManager = sys.build_manager
	var all := _build_block(mgr)
	assert_eq(all.size(), SIDE_X * SIDE_Y, "电线没有全部入图")
	sys.circuit_control.updateBuildCircuit(all)

	# 删掉前面 2800 根，留下最后 KEEP 根（它们紧挨着删除区，走「边界邻居」种子）
	var removed: Array[SWBuildItemDefine] = []
	removed.assign(all.slice(0, all.size() - KEEP))
	var survivors: Array[SWBuildItemDefine] = []
	survivors.assign(all.slice(all.size() - KEEP))
	assert_gt(removed.size(), sys.BULK_REMOVE_THRESHOLD, "用例必须跨过大批量阈值")

	var notify: Array = sys.getNotifyChunkPosArr(removed)
	sys._start_remove_and_followup(removed, notify)
	# 先标记（一次纯状态赋值），真正的离表在后面的帧里分片做
	assert_true(removed[0].bIsToBeRemoved(), "必须先把整批标成 TO_BE_REMOVED 再分帧删除")
	assert_true(sys._remove_busy, "超过阈值时应走分帧删除+善后，而不是单帧同步跑完")
	assert_false(sys.can_erase(), "删除善后进行中禁止擦除")

	var frames: int = await _wait_remove_done(sys)
	assert_ne(frames, -1, "善后任务没有在合理帧数内结束")
	print("[bulk] 删除 %d 个用了 %d 帧" % [removed.size(), frames])
	assert_false(sys._remove_busy, "善后结束后闸门必须复位")

	# 被删的：离开 id 表（不摘表就永远不会释放）
	var leaked: int = 0
	for b in removed:
		if mgr.getBuildById(b.id) != null:
			leaked += 1
	assert_eq(leaked, 0, "被删建筑要离开 id 表")

	# 留下的：一个不丢、状态回到 IDLE、仍能查到
	var lost: int = 0
	var stuck: int = 0
	for b in survivors:
		if mgr.getBuild(b.buildAxisPos) != b:
			lost += 1
			continue
		if b.buildState.state == SwDefine.BuildState.TO_BE_REMOVED:
			stuck += 1
	assert_eq(lost, 0, "活元件不能被误删")
	assert_eq(stuck, 0, "活元件不能残留待删除状态")
	assert_eq(mgr.getBuildCount(), KEEP, "建筑表总数应只剩活元件")

func test_bulk_remove_all_leaves_empty_world() -> void:
	await harness.boot_game()
	var sys: SWBuildLayerSystem = harness.build_layer.layer_system
	var mgr: SWBuildManager = sys.build_manager
	var all := _build_block(mgr)
	sys.circuit_control.updateBuildCircuit(all)

	var notify: Array = sys.getNotifyChunkPosArr(all)
	sys._start_remove_and_followup(all, notify)
	var frames: int = await _wait_remove_done(sys)
	assert_ne(frames, -1, "整片删除的善后没有结束")
	assert_eq(mgr.getBuildCount(), 0, "整片删除后建筑表应为空")
	# 全删光时没有活建筑可重建，但旧电路必须被摘掉（否则编译产物/求值后端一路泄漏）
	# 注意不能查 circuits 字典：它只在 dropCircuits 里 erase、从没被写入过，永远是空的
	var ctrl: SWCircuitControl = sys.circuit_control
	assert_eq(ctrl._compiled_progs.size(), 0, "整片删除后不应残留电路编译产物")
	assert_eq(ctrl._cpu_backends.size(), 0, "整片删除后不应残留 CPU 求值后端")
