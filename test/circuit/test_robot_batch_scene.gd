extends GutTest

# 万级规模路径（位平面批量求值）在**实体层**的端到端一致性。
#
# 为什么要单独一个文件：台数达到 BATCH_MIN 之后，检测/读输出/低相位执行全部走批量分支，
# 而那几个分支为了让 1 万台跑得动都做了内联与稀疏化（只算电路选中的那一个方向、
# 只有本拍有动作的台才进低相位队列）。这些优化一旦写错，表现是「机器人在大批量场景里
# 行为与少量场景不一样」，很难靠肉眼发现，只能靠这里把两条路径逐拍对拍。
#
# 只放 128 台（= BATCH_MIN）而不是上万台：这条用例验的是语义，不是性能；
# 上万台的耗时由临时探针观察（不进常规回归，见 .qoder/rules/testing.md）

const ENTITY_SYSTEM := preload("res://scene/entity/sw_entity_layer_system.gd")
const SAVE_NAME := "机器人测试2"
#刚达到批量阈值：再多就只是重复同样的代码路径
const PAD: int = 128
const PHASES: int = 20


func _w(cell: Vector2i) -> Vector2i:
	return cell * SwDefine.GRID_SIZE


func test_batch_matches_per_entity() -> void:
	var sys = ENTITY_SYSTEM.new()
	var pad: Array = []
	for i in PAD:
		var r = sys.spawn_robot(_w(Vector2i(1000 + (i % 20) * 4, 1000 + (i / 20) * 4)), 0)
		if r == null:
			continue
		sys.bind_circuit(r, SAVE_NAME)
		pad.append(r)
	assert_eq(pad.size(), PAD, "128 台都该放上")
	#参考台：手动塞独立 bundle（不走批量），离 pad 足够远不互相挡
	var ref = sys.spawn_robot(_w(Vector2i(1000, 3000)), 0)
	assert_not_null(ref, "参考台没放上")
	ref.set_bundle(SWCirManager.load_bundle(SAVE_NAME))
	var obs = pad[pad.size() - 1]
	assert_not_null(obs.batch_grp, "达到阈值后应当走批量")
	assert_null(ref.batch_grp, "参考台应当走逐台")
	for phase in PHASES:
		sys.step_beat()
		var got: int = obs.batch_grp.read_bits(
				obs.batch_grp.act_flat, obs.batch_grp.act_offs, obs.batch_bit)
		var exp: int = ref.bundle.read_output_bits(SWRobotActions.ACTION_NAMES)
		if got != exp:
			assert_eq(got, exp, "第 %d 拍动作位图不一致" % phase)
			return
	#顺带对一下寄存器：动作位图可能恰好相同，Q 不对就是锁存路径出了问题。
	#注意不能把寄存器条数写死：这条用例读的是玩家当前的存档（机器人测试2.swcir），
	#电路被编辑过就会重新导出，第一条子电路里几个寄存器是变的。
	#有多少对就核多少对，没寄存器就只验动作位图
	var ref_sub = ref.bundle.bundles[0] if ref.bundle is SWCircuitSet else ref.bundle
	var st: Array = []
	st.assign(ref_sub.runtime.reg_state)
	assert_eq(st.size() % 2, 0, "寄存器状态应当成对（Q/Q̄）")
	for i in mini(4, st.size() / 2):
		assert_eq(obs.batch_grp.batches[0].reg_bit(i, obs.batch_bit), int(st[i * 2]),
				"第 %d 个寄存器 Q 不一致" % i)


# 批量台被删掉之后：它必须从平面里摘出来（不再占着「有输入有寄存器」的槽），
# 而且新来的台不能复用它那块 bit（回收要搬动上万台的状态），否则两台会串味。
# 注意：摘出来 ≠ 那块 bit 的电平全 0。空 bit 相当于一个「输入全 0 的幽灵实例」，
# 组合求值照旧会写它（NOT 会把 0 变 1），但没任何实体读它，不影响其他台。
func test_remove_and_rebind_keeps_group_sane() -> void:
	var sys = ENTITY_SYSTEM.new()
	var pad: Array = []
	for i in PAD:
		var r = sys.spawn_robot(_w(Vector2i(2000 + (i % 20) * 4, 2000 + (i / 20) * 4)), 0)
		if r == null:
			continue
		sys.bind_circuit(r, SAVE_NAME)
		pad.append(r)
	var keep = pad[pad.size() - 1]
	var victim = pad[pad.size() - 2]
	var grp = keep.batch_grp
	assert_not_null(grp, "应当有批量组")
	sys.step_beat()
	var dead_bit: int = victim.batch_bit
	assert_true(sys.remove_entity(victim), "删除失败")
	assert_null(victim.batch_grp, "被删的台应当从批量平面里摘出来")
	assert_eq(sys.get_entity_count(), PAD - 1, "删完应当少一台")
	#剩下的台照常跑，而且新绑的台会拿到新 bit（不复用死掉的槽位）
	for k in 5:
		sys.step_beat()
	assert_same(keep.batch_grp, grp, "剩下的台不该被踢出组")
	var extra = sys.spawn_robot(_w(Vector2i(2000, 2600)), 0)
	assert_not_null(extra, "新机器没放上")
	assert_true(sys.bind_circuit(extra, SAVE_NAME), "新机器绑电路失败")
	assert_same(extra.batch_grp, grp, "新机器应当进同一个组")
	assert_ne(extra.batch_bit, dead_bit, "新机器复用了死槽位")
	sys.step_beat()
