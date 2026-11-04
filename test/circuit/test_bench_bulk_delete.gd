extends GutTest
# 一次性批量删除（7w 元件）的耗时探针：只打印各阶段毫秒数，方便定位瓶颈。
# 断言部分卡的是「语义」：被删掉的建筑不许再出现在重建集里（否则 7w 删除会白跑一遍
# 完整重建流程 —— 这就是「一次性删除 7w 元件非常慢」的主因）。
# 跑法：godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://test/circuit -gprefix test_bench_bulk_delete -gexit

const WIRE_DEF: SWBuildDefine = preload("res://res/电线A.tres")
const NOT_DEF: SWBuildDefine = preload("res://res/非门.tres")
const LED_DEF: SWBuildDefine = preload("res://res/灯泡.tres")
# 265 * 265 = 70225 ≈ 7w
const SIDE := 265
# 装饰用的活元件（删掉的只有电线，它们必须留下来并被正确重建）
const LIVE_COUNT := 200

func _ms(t0: int) -> int:
	return (Time.get_ticks_usec() - t0) / 1000

func _p(msg: String) -> void:
	print("[bench] " + msg)

# side×side 的电线网格（世界坐标按 GRID_SIZE 铺开），外加一排独立活元件
func _build_world(mgr: SWBuildManager) -> Array:
	var wires: Array[SWBuildItemDefine] = []
	var live: Array[SWBuildItemDefine] = []
	for x in SIDE:
		for y in SIDE:
			var b := SwDefine.SWBuildCreator(Vector2i(x, y) * SwDefine.GRID_SIZE, WIRE_DEF, 0)
			if mgr.addBuild(b):
				wires.append(b)
	# 活元件放在网格外面（互不相连，省掉表达式递归的开销，只验证「没被误删/误重建」）
	for i in LIVE_COUNT:
		var def: SWBuildDefine = NOT_DEF if i % 2 == 0 else LED_DEF
		var b := SwDefine.SWBuildCreator(Vector2i(SIDE + 4 + i, 0) * SwDefine.GRID_SIZE, def, 0)
		if mgr.addBuild(b):
			live.append(b)
	return [wires, live]

func test_bulk_delete_cost() -> void:
	var mgr := SWBuildManager.new()
	var ctrl := SWCircuitControl.new()
	ctrl.setBuildManager(mgr)
	ctrl.gpu_backend_enabled = false

	var t0 := Time.get_ticks_usec()
	var world: Array = _build_world(mgr)
	var wires: Array = world[0]
	var live: Array = world[1]
	_p("建造 %d 电线 + %d 活元件：%d ms" % [wires.size(), live.size(), _ms(t0)])

	var all: Array[SWBuildItemDefine] = []
	all.append_array(wires)
	all.append_array(live)
	t0 = Time.get_ticks_usec()
	ctrl.updateBuildCircuit(all)
	_p("首次建电路：%d ms，circuits=%d" % [_ms(t0), ctrl.circuits.size()])

	# 1) 分段取种子必须与一次性取种子等价：删除善后的分帧版就靠它拆成多帧
	var t_seed := Time.get_ticks_usec()
	var sync_seeds: Array = ctrl.collectRemoveSeeds(wires)
	var t_seed_sync := _ms(t_seed)
	t_seed = Time.get_ticks_usec()
	var state: Dictionary = ctrl.beginRemoveSeeds()
	var k: int = 0
	while k < wires.size():
		var nx: int = mini(k + 1000, wires.size())
		ctrl.collectRemoveSeedsStep(state, wires, k, nx)
		k = nx
	var staged_seeds: Array = ctrl.endRemoveSeeds(state)
	_p("取种子：同步 %d 个 %d ms，分段 %d 个 %d ms（删前，种子=整片电线）" % [
		sync_seeds.size(), t_seed_sync, staged_seeds.size(), _ms(t_seed)])
	assert_eq(staged_seeds.size(), sync_seeds.size(), "分段取种子必须与一次性取种子等价")

	# 2) 只删电线（出图）：标记 TO_BE_REMOVED / 离 id 表 / 区块整批压缩都在 delBuilds 里完成
	t0 = Time.get_ticks_usec()
	var ok := mgr.delBuilds(wires)
	_p("删除 %d 电线（含标记+区块压缩）：%d ms（ok=%s）" % [wires.size(), _ms(t0), ok])
	assert_true(ok, "批量删除应全部成功")
	var leaked := 0
	for b in wires:
		if mgr.getBuildById(b.id) != null:
			leaked += 1
	assert_eq(leaked, 0, "被删建筑要离开 id 表，否则 7w 对象永久驻留")

	# 3) 删除善后：只重建活着的建筑（死建筑不该再进重建集）
	t0 = Time.get_ticks_usec()
	var seeds: Array = ctrl.collectRemoveSeeds(wires)
	var t_seeds := _ms(t0)
	t0 = Time.get_ticks_usec()
	var affected: Array = ctrl.updateBuildCircuit(seeds)
	var t_eval := _ms(t0)
	t0 = Time.get_ticks_usec()
	ctrl.dropCircuits(ctrl.detachRemoved(wires))
	_p("删除善后：取种子 %d 个 %d ms + 重建 %d ms（affected=%d，circuits=%d，drop %d ms）" % [
		seeds.size(), t_seeds, t_eval, affected.size(), ctrl.circuits.size(), _ms(t0)])
	assert_eq(affected.size(), 0, "整片删光时没有活建筑可重建（否则就是白跑一遍 9 阶段）")

	var dead_in_affected := 0
	for b in affected:
		if b == null or b.bIsToBeRemoved() or mgr.getBuild(b.buildAxisPos) != b:
			dead_in_affected += 1
	_p("重建集里残留的死建筑：%d（affected=%d）" % [dead_in_affected, affected.size()])
	assert_eq(dead_in_affected, 0, "被删掉的建筑不能再进重建集（7w 删除的主要开销就在这里）")

	# 活元件必须还在（没被误删），且仍能重新分组
	for b in live:
		assert_eq(mgr.getBuild(b.buildAxisPos), b, "活元件不能丢")
	_p("剩余建筑数：%d，circuits=%d" % [mgr.getBuildCount(), ctrl.circuits.size()])
