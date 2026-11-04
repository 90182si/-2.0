extends GutTest
# 增量重建必须保持「一个连通电路 = 一个 SWCircuitData」。
#
# 回归点：find1 原先只展开「邻居」所在的电路，被操作建筑自己的电路不展开。
# 于是对一个大电路里的某一栋建筑做重建时，只有它自己被 reset，其余同伴仍挂着旧 circuit；
# createCircuitRange 的 BFS 遇到「已有 circuit」的成员直接 continue，电路被劈成新旧两半，
# 旧的那半已被 dropCircuits 删表、不再参与求值。
# 现场表现：两个明明连在一起的建筑 hover 出不同的「电路」id，其中一半不响应。
#   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/circuit/test_circuit_group_whole.gd -gexit

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const SAVE_NAME := "加法器3"

var harness = null

func before_each() -> void:
	harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)

func after_each() -> void:
	if harness != null:
		harness.shutdown_game()
		harness = null

func test_single_build_rebuild_keeps_circuit_whole() -> void:
	await harness.boot_game()
	var data: Dictionary = await harness.load_save(SAVE_NAME)
	assert_false(data.is_empty(), "存档不存在或无法加载: " + SAVE_NAME)
	var cc: SWCircuitControl = harness.build_layer.sw_circuit_control
	var manager: SWBuildManager = harness.build_layer.sw_build_manager

	# 挑成员最多的那个电路里的一个非电线建筑，作为「被操作对象」
	var target: SWBuildItemDefine = null
	var best_size: int = 0
	for b: SWBuildItemDefine in manager.getAllBuilds():
		if SwCommon.IsWireBuild(b) or b.circuit == null:
			continue
		var size: int = b.circuit.buildArr.size()
		if size > best_size:
			best_size = size
			target = b
	if target == null or best_size < 3:
		pending("存档 %s 里没有 3 成员以上的电路，用例无法覆盖" % SAVE_NAME)
		return

	var before_count: int = target.circuit.buildArr.size()

	# 只把这一栋建筑丢给增量重建：整组都应该被重建，不能只重建它自己
	var seeds: Array[SWBuildItemDefine] = [target]
	var affect: Array[SWBuildItemDefine] = cc.updateBuildCircuit(seeds)
	assert_true(affect.size() >= before_count,
		"重建范围只有 %d 栋，少于原电路成员数 %d：没有整组展开" % [affect.size(), before_count])

	var cir: SwDefine.SWCircuitData = target.circuit
	assert_not_null(cir, "重建后被操作建筑没有电路")
	if cir == null:
		return

	# 一个电路对象内部的成员必须全部指回它自己，出现别的引用就是被劈开了
	var strays: PackedStringArray = PackedStringArray()
	for b: SWBuildItemDefine in cir.buildArr:
		if b.circuit != cir:
			strays.append(str(b.buildAxisPos))
	assert_eq(strays.size(), 0,
		"电路 %d 里有 %d 栋成员指向了别的电路：%s" % [cir.circuitID, strays.size(), ",".join(strays)])
	assert_eq(cir.buildArr.size(), before_count,
		"电路成员数从 %d 变成 %d，说明同一个连通电路被劈成了两个 id" % [before_count, cir.buildArr.size()])

# 历史遗留的「已经劈开」状态必须能被一次普普通通的增量重建合并回去。
# 人为把一个电路拆成两个各自完整的 circuit 对象（=现场看到 65 / 63 的样子），
# 再从其中一栋建筑触发重建，两半必须合回同一个电路。
func test_already_split_circuit_gets_merged() -> void:
	await harness.boot_game()
	var data: Dictionary = await harness.load_save(SAVE_NAME)
	assert_false(data.is_empty(), "存档不存在或无法加载: " + SAVE_NAME)
	var cc: SWCircuitControl = harness.build_layer.sw_circuit_control
	var manager: SWBuildManager = harness.build_layer.sw_build_manager

	var target: SWBuildItemDefine = null
	var best_size: int = 0
	for b: SWBuildItemDefine in manager.getAllBuilds():
		if SwCommon.IsWireBuild(b) or b.circuit == null:
			continue
		var size: int = b.circuit.buildArr.size()
		if size > best_size:
			best_size = size
			target = b
	if target == null or best_size < 4:
		pending("存档 %s 里没有 4 成员以上的电路，用例无法覆盖" % SAVE_NAME)
		return

	var whole: Array[SWBuildItemDefine] = []
	whole.assign(target.circuit.buildArr)
	var cut: int = whole.size() / 2
	var half_a := SwDefine.SWCircuitData.new()
	var half_b := SwDefine.SWCircuitData.new()
	half_a.buildArr.assign(whole.slice(0, cut))
	half_b.buildArr.assign(whole.slice(cut, whole.size()))
	for b: SWBuildItemDefine in half_a.buildArr:
		b.circuit = half_a
	for b: SWBuildItemDefine in half_b.buildArr:
		b.circuit = half_b

	# 只从一半里的某一栋触发重建
	var seeds: Array[SWBuildItemDefine] = [half_a.buildArr[0]]
	cc.updateBuildCircuit(seeds)

	var cir: SwDefine.SWCircuitData = half_a.buildArr[0].circuit
	assert_not_null(cir, "重建后没有电路")
	if cir == null:
		return
	var strays: PackedStringArray = PackedStringArray()
	for b: SWBuildItemDefine in whole:
		if b.circuit != cir:
			strays.append(str(b.buildAxisPos))
	assert_eq(strays.size(), 0,
		"劈开的两半没有合并，%d 栋还挂在别的电路上：%s" % [strays.size(), ",".join(strays)])
	assert_eq(cir.buildArr.size(), whole.size(),
		"合并后成员数应为 %d，实际 %d" % [whole.size(), cir.buildArr.size()])
