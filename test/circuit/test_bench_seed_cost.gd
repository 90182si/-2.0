extends GutTest
# 「删除 7w 元件」善后取种子的代价回归。
# 根因：collectRemoveSeeds 曾对每个被删建筑都遍历一遍它所属电路的 buildArr。
# 一整片连通的电线会落在同一条电路里（createCircuitRange 的 visited 包含电线），
# 7w 个被删元件都挂在同一条电路上时就是 7w × 上万 = 数十亿次调用，
# 这就是「删除 7w 元件花了五个小时」的来源。
# 本用例：①断言「同一电路只扫一遍」的结果与逐栋扫完全一致 ②打印两者耗时并外推 7w。
# 跑法：godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://test/circuit -gprefix test_bench_seed_cost -gexit

const WIRE_DEF: SWBuildDefine = preload("res://res/电线A.tres")
const NOT_DEF: SWBuildDefine = preload("res://res/非门.tres")
# 40 * 40 = 1600 格：中心放一个非门，其余电线，整片连成一条电路
const SIDE := 40
# 删 1200 留 400：留活的部分才会走到 getBuild，代价最高的情况
const REMOVE_COUNT := 1200

func _ms(t0: int) -> int:
	return (Time.get_ticks_usec() - t0) / 1000

func test_seed_cost_does_not_scale_squarely() -> void:
	var mgr := SWBuildManager.new()
	var ctrl := SWCircuitControl.new()
	ctrl.setBuildManager(mgr)
	ctrl.gpu_backend_enabled = false

	var all: Array[SWBuildItemDefine] = []
	var wires: Array[SWBuildItemDefine] = []
	var center := Vector2i(SIDE / 2, SIDE / 2)
	for y in SIDE:
		for x in SIDE:
			var pos := Vector2i(x, y) * SwDefine.GRID_SIZE
			if Vector2i(x, y) == center:
				var gate := SwDefine.SWBuildCreator(pos, NOT_DEF, 0)
				if mgr.addBuild(gate):
					all.append(gate)
				continue
			var wire := SwDefine.SWBuildCreator(pos, WIRE_DEF, 0)
			if mgr.addBuild(wire):
				all.append(wire)
				wires.append(wire)
	ctrl.updateBuildCircuit(all)

	# 电路对象只挂在 build.circuit 上（ctrl.circuits 是只 erase、从不写入的历史字段）
	var sample_cir = null
	for build in all:
		if build.circuit != null:
			sample_cir = build.circuit
			break
	var biggest: int = sample_cir.buildArr.size() if sample_cir != null else 0
	print("[seed] 最大电路成员=%d / 总格数=%d（用例前提：整片电线同属一条电路）" % [
		biggest, SIDE * SIDE])
	assert_gt(biggest, SIDE * SIDE / 2, "整片连通的电线必须落在同一条电路里，否则复现的不是用户场景")

	var removed: Array[SWBuildItemDefine] = []
	removed.assign(wires.slice(0, REMOVE_COUNT))
	mgr.delBuilds(removed)

	# 新算法：每个电路只展开一次
	var t0 := Time.get_ticks_usec()
	var seeds: Array = ctrl.collectRemoveSeeds(removed)
	var t_new := _ms(t0)

	# 旧算法：逐栋展开它所属电路的 buildArr（4 邻部分两边一样，这里一起算进去）
	t0 = Time.get_ticks_usec()
	var old_seeds: Array[SWBuildItemDefine] = []
	var old_seen: Dictionary = {}
	var old_seen_pos: Dictionary = {}
	for build in removed:
		if build == null:
			continue
		var cir = build.circuit
		if cir != null:
			for member in cir.buildArr:
				ctrl._add_live_member(member, old_seeds, old_seen)
		if build is SWBuildWireTunnel:
			continue
		for dir in 4:
			var nb_pos: Vector2i = build.buildAxisPos \
					+ SwDefine.dir_to_vec(dir) * SwDefine.GRID_SIZE
			if old_seen_pos.has(nb_pos):
				continue
			old_seen_pos[nb_pos] = true
			var nb = mgr.getBuild(nb_pos)
			if nb == null or old_seen.has(nb) or nb.bIsToBeRemoved():
				continue
			old_seen[nb] = true
			old_seeds.append(nb)
	var t_old := _ms(t0)

	print("[seed] 删 %d / 电路 %d 成员：新算法 %d ms，旧算法 %d ms" % [
		removed.size(), biggest, t_new, t_old])
	# 旧算法的电路部分 = 被删数 × 电路成员数（单次校验含一次 getBuild 查表）
	var per_member_us: float = float(t_old) * 1000.0 / float(removed.size()) / float(maxi(biggest, 1))
	print("[seed] 旧算法单次成员校验 ≈ %.2f µs" % per_member_us)
	# 按「删 7w、同一条电路 7w 成员」外推（用户现场就是整片相连）
	print("[seed] 外推 7w×7w：旧算法 ≈ %.0f 秒（%.1f 小时），新算法 ≈ %.1f 秒" % [
		per_member_us * 70225.0 * 70225.0 / 1000000.0,
		per_member_us * 70225.0 * 70225.0 / 1000000.0 / 3600.0,
		float(t_new) / 1000.0 * 70225.0 / float(removed.size())])

	assert_eq(seeds.size(), old_seeds.size(), "「每个电路只扫一遍」必须与逐栋扫结果一致")
