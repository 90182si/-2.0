extends GutTest
# GPU LED resolve 的数据面回归（headless 可跑，不依赖 RenderingDevice）。
#
# 覆盖四件最容易写错的事：
#   1) 全局 slot 基址分配：幂等、区间不重叠、水位按 slot_count 前进；
#   2) 组表布局：[src_count, gs0..gs3, dst_off, dst_count, 0]，dst 指向帧槽表；
#   3) 分组语义：同一组灯泡的输入集合完全相同（组内最后一次 OR 广播给全部帧槽），
#      且每个已烘焙帧槽恰好出现一次（compute 并发写同一 texel 会竞态）；
#   4) 下标换算：用「全局 slot 数组」按表算出的 OR，必须等于「局部 slot 数组」按
#      led_src_slots 算出的 OR（这是 CPU 侧 _refreshLedDisplay 的原语义）。
#
# 真正的 GPU 结果（sw_signal_led.glsl 写帧槽 → draw shader 选帧）只能在有 RD 的机器上目视验证。

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const SAVE_NAME := "ledbug2"
const STRIDE := 8

var harness = null

func before_each() -> void:
	harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)

func after_each() -> void:
	if harness != null:
		harness.shutdown_game()
		harness = null

func test_led_table_layout_and_slot_indexing() -> void:
	await harness.boot_game()
	var data: Dictionary = await harness.load_save(SAVE_NAME)
	if data.is_empty():
		pending("存档不存在: " + SAVE_NAME)
		return
	harness.force_load_all_chunks()

	var ctrl = harness.build_layer.layer_system.circuit_control
	var tex: SWSignalTexture = SWSignalTexture.instance
	assert_not_null(ctrl, "拿不到 SWCircuitControl")
	assert_not_null(tex, "信号纹理未初始化")

	# 等懒建后端把电路表填出来（headless 下 ctrl.circuits 可能为空）
	var guard := 0
	while guard < 3000 and ctrl._cpu_backends.is_empty():
		guard += 1
		await get_tree().process_frame

	# 取第一条含灯泡的电路（prog 是懒编译缓存）
	var prog: SWGateProgram = null
	for c in ctrl._cpu_backends.keys():
		var p: SWGateProgram = ctrl._compiled_prog(c)
		if p != null and not p.led_comps.is_empty():
			prog = p
			break
	if prog == null:
		pending("存档里没有灯泡")
		return

	# 1) 基址分配：幂等 + 水位推进
	var base0: int = ctrl._led_global_slots
	ctrl._alloc_gpu_slot_base(prog)
	assert_eq(prog.gpu_slot_base, base0, "首次分配应从当前全局水位开始")
	assert_eq(ctrl._led_global_slots, base0 + maxi(prog.slot_count, 1),
			"全局水位应按 slot_count 前进")
	ctrl._alloc_gpu_slot_base(prog)
	assert_eq(prog.gpu_slot_base, base0, "重复分配必须幂等")
	assert_eq(ctrl._led_global_slots, base0 + maxi(prog.slot_count, 1),
			"重复分配不得再涨水位")

	# 2) 模拟烘焙：给本电路每个灯泡的渲染组件分配帧槽
	for i in prog.led_comps.size():
		var rc0 := prog.led_refresh_comps[i] as SWBuildCompoentRenderable
		if rc0 != null and rc0._frameSlot < 0:
			rc0._frameSlot = tex.alloc_frame_slot()

	# 3) 建表（绕过节流）
	ctrl._led_table_us = 0
	ctrl._led_table_dirty = true
	ctrl._sync_led_gpu_table(tex)
	var tbl: PackedInt32Array = ctrl._led_table
	var dsts: PackedInt32Array = ctrl._led_dst_slots
	assert_gt(tbl.size(), 0, "至少应导出一条灯泡组记录")
	assert_eq(tbl.size() % STRIDE, 0, "表必须按 stride 8 对齐")
	assert_gt(dsts.size(), 0, "帧槽表不能为空")

	# 分组本身：组号与组表自洽（组号范围、成员段覆盖每个灯泡恰好一次）
	assert_eq(prog.led_group_id.size(), prog.led_comps.size(), "组号表应与灯泡数同长")
	var seen_led := {}
	for gi in prog.led_group_src_offs.size():
		var mo: int = prog.led_group_mem_offs[gi]
		var mlen: int = prog.led_group_mem_lens[gi]
		assert_gt(mlen, 0, "组 %d 不应该没有成员" % gi)
		for k in range(mo, mo + mlen):
			var li: int = prog.led_group_members[k]
			assert_eq(prog.led_group_id[li], gi, "灯泡 %d 的组号与成员段不一致" % li)
			assert_false(seen_led.has(li), "灯泡 %d 在成员段里出现了两次" % li)
			seen_led[li] = true
	assert_eq(seen_led.size(), prog.led_comps.size(), "成员段必须覆盖全部灯泡")

	# 4) 下标换算对拍：全局 slot 数组 vs 局部 slot 数组
	var slots := PackedInt32Array()
	slots.resize(maxi(prog.slot_count, 1))
	for i in slots.size():
		slots[i] = i % 2
	var gslots := PackedInt32Array()
	gslots.resize(maxi(ctrl._led_global_slots, 1))
	gslots.fill(0)
	for i in slots.size():
		gslots[base0 + i] = slots[i]

	var fs_to_li := {}
	for i in prog.led_comps.size():
		var rc1 := prog.led_refresh_comps[i] as SWBuildCompoentRenderable
		if rc1 != null and rc1._frameSlot >= 0:
			fs_to_li[rc1._frameSlot] = i

	var seen_fs := {}
	var checked := 0
	for r in tbl.size() / STRIDE:
		var n: int = tbl[r * STRIDE]
		var dc: int = tbl[r * STRIDE + 6]
		var off: int = tbl[r * STRIDE + 5]
		assert_between(n, 0, 4, "第 %d 条记录的源数越界" % r)
		assert_gt(dc, 0, "第 %d 条记录的帧槽数必须 > 0（空组不该进表）" % r)
		assert_between(off, 0, maxi(dsts.size() - 1, 0), "第 %d 条记录的 dst_off 越界" % r)
		var group_srcs: Array = []
		for k in n:
			var gs: int = tbl[r * STRIDE + 1 + k]
			assert_between(gs, 0, gslots.size() - 1, "第 %d 条记录的全局 slot 下标越界" % r)
			group_srcs.append(gs)
		for j in dc:
			var fs: int = dsts[off + j]
			assert_false(seen_fs.has(fs), "帧槽 %d 出现在多条记录里（并发写同一 texel）" % fs)
			seen_fs[fs] = true
			if not fs_to_li.has(fs):
				continue
			var li: int = fs_to_li[fs]
			var want_srcs: PackedInt32Array = prog.led_src_slots[li]
			assert_eq(n, want_srcs.size(), "灯泡 %d 的源数不符" % li)
			var want := 0
			for k in want_srcs.size():
				want |= slots[want_srcs[k]]
				assert_eq(group_srcs[k], base0 + want_srcs[k], "灯泡 %d 的全局 slot 下标不符" % li)
			var got := 0
			for gs in group_srcs:
				got |= gslots[int(gs)]
			assert_eq(got, want, "灯泡 %d 的 OR 结果与全局下标换算不一致" % li)
			checked += 1
	assert_gt(checked, 0, "表里应至少覆盖本电路的一个灯泡")
	# 本电路所有已烘焙灯泡都必须被表覆盖
	for fs in fs_to_li.keys():
		assert_true(seen_fs.has(fs), "已烘焙帧槽 %d 没有进表" % fs)
