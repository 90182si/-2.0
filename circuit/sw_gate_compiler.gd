class_name SWGateCompiler extends RefCounted

# 网表 → 扁平布尔算子列表（op_list）编译器（SPEC-01 §8 T1.10 + 用户方案）。
# 输入：电路建筑列表（现有 SWBuildItemDefine 电路结构，纯拓扑，不感知求值实现）；
# 输出：SWGateProgram（每 net 一个 slot + 每驱动组件一个 slot 的布尔算子表 + 拓扑层）。
#
# 语义对应（与现有树求值逐位一致）：
# - 源（时钟/按钮/开关）：comp slot 是外部输入（CPU 事件写入），驱动 net 时参与 AND；
# - NOT：comp slot = ~输入 net slot；
# - 寄存器：comp slot（Q）由帧边界锁存 pass 写入（clk 上升沿采样 D 的拍前值）；
# - 多驱动 net（线与）：net slot = 所有驱动者 comp slot 的 AND——单条 AND 算子，
#   规避 GPU 多线程写同一 dst 的竞态（用户方案核心坑）；
# - 悬空 net：AND 空输入 → 恒 0（低电平，与 _netSignal 空驱动返回 0 一致）；
# - >4 驱动折叠成 AND 链（中间临时 slot），GPU 端固定 stride 遍历。
#
# ========== SPEC-04：化简为什么在这里「有边界」，以及做到了什么 ==========
# 1) 跨 net 的 NOT 链奇偶折叠不可行（用户原始设想）：
#    NOT 门的输入是 **net**，扁平表每一步是 `NOT(c_i) -> n_i ; AND(n_i) -> net_i` 两条；
#    net_i 的电平**对外可观测**——连线颜色/区块标脏/负载通知/parity 测试都按 net 走。
#    把偶数个 NOT 抵消掉 = 把中间 net 改成链头的值，中间那串连线整片变色 → 不是等价变换。
#    等价版（把 net 改成 OP_ALIAS 保留可见电平）gate 数不降，收益为零，故不实现。
# 2) 把两个不同 dst 的同构 AND 合并成一条 gate **会直接算错**：
#    调度是按 dst 的拓扑层 dispatch + `slot_lv` 单层判据，两条不同 dst 的 gate 一旦共享结果，
#    后一条会在自己那一层读到「还没有本层新值」的旧值（环上节点更是被整体排到最后一层）——
#    16x 计数器实测 1200+ 个 net 电平全错。等价共享必须改造调度模型，不在本次范围。
# 3) 本文件实际交付的是**环路检测**（迭代 Tarjan SCC，显式栈，不递归）：
#    prog.loop_nets 给出反馈环上的 slot 数，是后续任何重写的安全边界与诊断依据。
#
# 调试开关：enable_opt=false 时跳过环检测（产物完全相同，只是没有 loop_nets 诊断）。

var enable_opt: bool = true
# 公共子表达式消除（用户方案第一步）：同层同 (op,srcs) 的 gate 只算一次
var enable_cse: bool = true

# 编译入口：builds 里电线/无电路组件自动跳过。
#
# 两条实现，产物同一套口径（test_netlist_compile.gd 逐字段对拍）：
#   use_netlist_path = true ：builds → SWNetlist → compile_netlist → 回接实体表（纯数据入口）
#   use_netlist_path = false：直接读组件 pinNetMap 的老路径（默认，灰度期保守）
# 切到网表路径的意义：编译期拓扑先落成纯整数表，之后离线工具 / 纯逻辑运行时
# 可以用同一个 compile_netlist，不再需要一份世界实体。
var use_netlist_path: bool = false


func compile(builds: Array) -> SWGateProgram:
	if use_netlist_path:
		var ex := SWNetlistExport.new()
		var nl: SWNetlist = ex.export_netlist(builds)
		var prog_net: SWGateProgram = compile_netlist(nl)
		ex.bind_program(prog_net)
		return prog_net
	return _compile_legacy(builds)


# 编译一批建筑为 SWGateProgram；builds 里电线/无电路组件自动跳过
func _compile_legacy(builds: Array) -> SWGateProgram:
	var prog := SWGateProgram.new()
	var comps: Array = []
	var nets: Dictionary = {}
	for b in builds:
		if b == null:
			continue
		if SwCommon.IsWireBuild(b):
			continue
		var comp = b.getCircuitCompoent()
		if comp == null:
			continue
		comps.append(comp)
		if comp is SWBuildCompoentCircuitLed:
			prog.led_comps.append(comp)
			prog.led_refresh_comps.append(b.getRenderableCompoent())
		# 每拍要刷显示的非时序组件：编译期定死扁平表，回填阶段直接遍历，
		# 省掉逐组件 isStateful() 虚调用（大存档实测 6 万次/拍）
		if not comp.isStateful():
			prog.display_comps.append(comp)
		comp.refreshDirMasks()
		for d in 4:
			var net: SWNet = comp.pinNetMap.get(d, null)
			if net != null and net.netId >= 0:
				nets[net] = true

	# 确定性顺序：net 按 netId 升序；组件按收集序
	var net_list: Array = nets.keys()
	net_list.sort_custom(func(a, b): return a.netId < b.netId)
	var net_slot: Dictionary = {}
	for i in net_list.size():
		net_slot[net_list[i]] = i

	# comp slot：只给「驱动了某 net」的组件分配
	var comp_list: Array = comps
	var comp_slot: Dictionary = {}
	var next_slot: int = net_list.size()
	for comp in comp_list:
		if _is_driver(comp, net_slot):
			comp_slot[comp] = next_slot
			next_slot += 1

	prog.net_count = net_list.size()
	prog.comp_count = comp_slot.size()
	prog.net_to_slot = net_slot
	prog.comp_to_slot = comp_slot
	prog.all_comps = comps
	for net in net_list:
		if net.netId >= 0:
			prog.net_id_to_slot[net.netId] = net_slot[net]
	# slot -> net（反查，O(1)）
	prog.slot_to_net = {}
	for net in net_slot:
		prog.slot_to_net[net_slot[net]] = net
	# 回填扁平表：net 顺序与 net_list 一致（回填阶段纯下标访问，不走 Dictionary）
	prog.net_list = net_list
	var slot_arr := PackedInt32Array()
	slot_arr.resize(net_list.size())
	for i in net_list.size():
		slot_arr[i] = net_slot[net_list[i]]
	prog.net_slots = slot_arr
	# 回填缓存初值 -1（首拍必写一次，与 resetBuildState 后的贴图状态对齐）
	prog.net_prev_bit.resize(net_list.size())
	prog.net_prev_bit.fill(-1)
	# 每个 LED 输入方向对应的 net slot（回填时按 slot 判亮灭，不走 SWNet 对象链）。
	# 去重 + 升序：OR 与顺序无关、重复 slot 无额外信息（一盏灯左右两口接同一根 net 很常见），
	# 归并后「输入集合相同」才算同一组，分组命中率才高。
	for led_comp in prog.led_comps:
		var slots_arr := PackedInt32Array()
		for d in 4:
			var lnet: SWNet = led_comp.pinNetMap.get(d, null)
			if lnet != null and net_slot.has(lnet):
				slots_arr.append(net_slot[lnet])
		slots_arr.sort()
		var uniq_slots := PackedInt32Array()
		for s in slots_arr:
			if uniq_slots.is_empty() or uniq_slots[uniq_slots.size() - 1] != s:
				uniq_slots.append(s)
		prog.led_src_slots.append(uniq_slots)
	_build_led_groups(prog)
	# 组合门显示刷新扁平表：每个驱动组件 → (输出 slot, 渲染组件)
	for comp in comp_list:
		if not comp_slot.has(comp):
			continue
		if comp.isStateful() or _is_source(comp):
			continue
		var out_slot: int = comp_slot[comp]
		prog.gate_out_slots.append(out_slot)
		prog.gate_refresh_comps.append(comp.buildRef.getRenderableCompoent())
		prog.gate_prev_level.append(-1)
		# 非门贴图按输入电平选帧（见 SWBuildCompoentCircuitNot.evaluate），输出位要取反才是显示位
		prog.gate_display_invert.append(1 if comp is SWBuildCompoentCircuitNot else 0)
	# 组件层兜底刷新表：LED 走 led_comps、组合门走 gate_out_slots，剩下的才进这里
	# （64x 存档里通常只剩时钟/按钮等源类显示件，数量极少）
	for comp in comps:
		if comp.isStateful():
			continue
		if comp is SWBuildCompoentCircuitLed:
			continue
		if comp_slot.has(comp):
			continue   # 组合门已由 gate_out_slots 批量处理
		prog.fallback_display_comps.append(comp)

	# 原始 gate 表（改造前的老逻辑，一条组件一条 gate + 一条 net 线与 gate）
	# slot_count 由 _build_raw 自己落定：>4 驱动的折叠链会在它内部追加中间 slot，
	# 而 next_slot 是按值传进去的，外面这份副本不会增长。
	var gate_records: Array = _build_raw(prog, comp_list, net_list, net_slot, comp_slot, next_slot)
	prog.raw_gate_count = gate_records.size()
	_finish(prog, gate_records)
	return prog


# ==========================================================================
# 公共子表达式消除（CSE）
#
# 原理：一个 slot 的值只由「写它的那条 gate 的 op + 按序 srcs」决定。
# 若两条 gate 的 (op, srcs) 完全相同，它们的值必然相同，可以只算一次。
#
# ⚠ 但**不能按「同层」合并**（实测踩坑）：
#   求值按层 dispatch，层内 gate 之间**没有执行顺序保证**。同层的两个相同表达式
#   （例如两个 NOT 都吃同一个 net）会被分配同层，此时"第一个"还没算出来，
#   第二个 alias 过去读到的是上一拍的残留值 → 计数器电平整片错乱。
#   实测 30 条同层 alias 让加法器 3 的第一个电路出现 4 处不一致。
#
# ✅ 安全条件：**canon 的层严格小于 dst 的层**。
#   这样 canon 必然在本拍更早的层里算完，dst 从写缓冲里读到的是本轮新值。
#   这正好对应「把 (a&b) 提成中间表达式 S2」的场景：S2 在更低的层，引用它的表达式在更高的层。
#
# 实现：不删 slot（slot 编号是对外契约），重复 dst 改成 OP_ALIAS(canon)。
# ==========================================================================
func _cse(prog: SWGateProgram, records: Array, loop_slots: Array[bool]) -> void:
	var n: int = prog.slot_count
	# 每个 slot 的写层（-1 = 无写 gate，如源/寄存器 Q）
	var slot_level := PackedInt32Array()
	slot_level.resize(n)
	slot_level.fill(-1)
	for rec in records:
		var d: int = rec["dst"]
		if d >= 0 and d < n:
			slot_level[d] = rec.get("level", -1)
	# key -> [canon_slot, canon_level]（保留同 key 里层级最低的那个作为 canon）
	var seen: Dictionary = {}
	var merged := 0
	for ri in records.size():
		var rec: Dictionary = records[ri]
		var dst: int = rec["dst"]
		var op: int = rec["op"]
		if op != SWGateProgram.OP_NOT and op != SWGateProgram.OP_AND:
			continue
		if dst < 0 or dst >= n or loop_slots[dst]:
			continue
		var srcs: Array = rec["srcs"]
		if srcs.is_empty():
			continue
		var lv: int = rec.get("level", -1)
		var key := "%d,%s" % [op, _srcs_key(srcs)]
		if not seen.has(key):
			seen[key] = [dst, lv]
			continue
		var prev: Array = seen[key]
		var canon: int = prev[0]
		var canon_lv: int = prev[1]
		if canon_lv >= lv:
			# canon 的层不低于本 gate：不能安全复用（同层无执行序）。
			# 若本 gate 层级更低，则把本 gate 提升为新的 canon，供更高层的重复项复用。
			if lv < canon_lv:
				seen[key] = [dst, lv]
			continue
		# canon 层严格更低 → 一定已算完，安全复用
		records[ri] = {"op": SWGateProgram.OP_ALIAS, "dst": dst, "srcs": [canon],
				"level": lv, "synthetic": true}
		merged += 1
	prog.cse_merged = merged


# srcs -> 稳定字符串键（源数很小，开销可忽略）
func _srcs_key(srcs: Array) -> String:
	var parts := PackedStringArray()
	for s in srcs:
		parts.append(str(s))
	return ".".join(parts)


# 原始 gate 生成（改造前的逻辑，一条组件一条 gate + 一条 net 线与 gate）
func _build_raw(prog: SWGateProgram, comp_list: Array, net_list: Array,
		net_slot: Dictionary, comp_slot: Dictionary, next_slot_in: int) -> Array:
	var next_slot: int = next_slot_in
	var gate_records: Array = []   # {op, dst, srcs}
	for comp in comp_list:
		if not comp_slot.has(comp):
			continue
		var dst: int = comp_slot[comp]
		if _is_source(comp):
			prog.input_slots.append(dst)
			prog.input_comps.append(comp)
			continue
		if comp.isStateful():
			prog.reg_slots.append(dst)
			prog.reg_comps.append(comp)
			var clk_slot := -1
			var d_slot := -1
			for d in 4:
				var net: SWNet = comp.pinNetMap.get(d, null)
				if net == null or not net_slot.has(net):
					continue
				if comp._worldDir(comp.CLK_REF) == d:
					clk_slot = net_slot[net]
				if comp._worldDir(comp.D_REF) == d:
					d_slot = net_slot[net]
			prog.reg_clk_slots.append(clk_slot)
			prog.reg_d_slots.append(d_slot)
			continue
		# 组合驱动（NOT 或其他）：输出 = f(输入 net)
		var in_slots: Array[int] = []
		for d in 4:
			if (comp.inDirMask & (1 << d)) != 0:
				var net: SWNet = comp.inNets[d]
				if net != null and net_slot.has(net):
					in_slots.append(net_slot[net])
		var op: int = SWGateProgram.OP_NOT if comp is SWBuildCompoentCircuitNot else SWGateProgram.OP_AND
		gate_records.append({"op": op, "dst": dst, "srcs": in_slots, "synthetic": false})

	# net 线与 gate（驱动者输出 AND；>4 驱动折叠链）
	for net in net_list:
		var dst: int = net_slot[net]
		var drv_slots: Array[int] = []
		for dcomp in net._driverComps:
			if comp_slot.has(dcomp):
				drv_slots.append(comp_slot[dcomp])
		if drv_slots.is_empty():
			gate_records.append({"op": SWGateProgram.OP_AND, "dst": dst, "srcs": [], "synthetic": false})
		elif drv_slots.size() <= 4:
			gate_records.append({"op": SWGateProgram.OP_AND, "dst": dst, "srcs": drv_slots, "synthetic": false})
		else:
			var pending: Array[int] = drv_slots.duplicate()
			while pending.size() > 4:
				var batch: Array[int] = []
				for i in 4:
					batch.append(pending.pop_front())
				var tmp: int = next_slot
				next_slot += 1
				gate_records.append({"op": SWGateProgram.OP_AND, "dst": tmp, "srcs": batch, "synthetic": true})
				pending.append(tmp)
			gate_records.append({"op": SWGateProgram.OP_AND, "dst": dst, "srcs": pending, "synthetic": false})
	# 折叠链的中间 slot 是在本函数里追加的，所以总槽数必须在这里落定：
	# 交给调用方的 next_slot 副本不包含它们，曾经算得偏小，导致折叠 gate 的 dst 越界 ——
	# _compute_levels 对它写拓扑层会报 Invalid assignment 并静默丢层，
	# _detect_loops / _cse 则用 d < n 把这些 gate 整个跳过，环路判定与 CSE 都漏一批。
	prog.slot_count = next_slot
	return gate_records


# ==========================================================================
# 环路检测（SPEC-04）：迭代 Tarjan SCC，显式栈，绝不递归（GDScript 深链会爆栈）
# 返回 slot -> bool：true = 该 slot 在某个反馈环里（SCC 大小 > 1 或自环）
# 环上 slot 是任何网表重写（折叠/共享/淘汰）的绝对边界：
# 那里的中间电平既是计数器时序的一部分，又可能停在「迭代到收敛前」的中间态。
# ==========================================================================
func _detect_loops(prog: SWGateProgram, records: Array) -> Array[bool]:
	var n: int = prog.slot_count
	var loop_slots: Array[bool] = []
	loop_slots.resize(n)
	loop_slots.fill(false)
	if n == 0 or records.is_empty():
		return loop_slots

	# 邻接表（CSR 展平）：dst -> src
	var out_start := PackedInt32Array()
	out_start.resize(n + 1)
	out_start.fill(0)
	var deg := PackedInt32Array()
	deg.resize(n)
	deg.fill(0)
	for rec in records:
		var d: int = rec["dst"]
		if d >= 0 and d < n:
			deg[d] += (rec["srcs"] as Array).size()
	var acc := 0
	for i in n:
		out_start[i] = acc
		acc += deg[i]
	out_start[n] = acc
	var out_src := PackedInt32Array()
	out_src.resize(acc)
	out_src.fill(0)
	var cursor := out_start.duplicate()
	for rec in records:
		var d: int = rec["dst"]
		if d < 0 or d >= n:
			continue
		for s in rec["srcs"]:
			if s >= 0 and s < n:
				out_src[cursor[d]] = s
				cursor[d] += 1
	# 自环
	for i in n:
		for k in range(out_start[i], out_start[i + 1]):
			if out_src[k] == i:
				loop_slots[i] = true
				break

	# 迭代 Tarjan
	var index := PackedInt32Array()
	index.resize(n)
	index.fill(-1)
	var low := PackedInt32Array()
	low.resize(n)
	low.fill(0)
	var on_stack: Array[bool] = []
	on_stack.resize(n)
	on_stack.fill(false)
	var scc_stack := PackedInt32Array()
	var call_node := PackedInt32Array()
	var call_edge := PackedInt32Array()
	var idx_counter := 0
	for root in n:
		if index[root] != -1:
			continue
		call_node.clear()
		call_edge.clear()
		index[root] = idx_counter
		low[root] = idx_counter
		idx_counter += 1
		scc_stack.append(root)
		on_stack[root] = true
		call_node.append(root)
		call_edge.append(out_start[root])
		while not call_node.is_empty():
			var top: int = call_node.size() - 1
			var v: int = call_node[top]
			var e: int = call_edge[top]
			if e < out_start[v + 1]:
				call_edge[top] = e + 1
				var w: int = out_src[e]
				if index[w] == -1:
					index[w] = idx_counter
					low[w] = idx_counter
					idx_counter += 1
					scc_stack.append(w)
					on_stack[w] = true
					call_node.append(w)
					call_edge.append(out_start[w])
				elif on_stack[w]:
					low[v] = mini(low[v], index[w])
				continue
			call_node.remove_at(top)
			call_edge.remove_at(top)
			if low[v] == index[v]:
				var members: Array[int] = []
				while true:
					var u: int = scc_stack[scc_stack.size() - 1]
					scc_stack.remove_at(scc_stack.size() - 1)
					on_stack[u] = false
					members.append(u)
					if u == v:
						break
				if members.size() > 1:
					for u in members:
						loop_slots[u] = true
			if not call_node.is_empty():
				var parent: int = call_node[call_node.size() - 1]
				low[parent] = mini(low[parent], low[v])
	return loop_slots


func _is_driver(comp, net_slot: Dictionary) -> bool:
	for d in 4:
		if (comp.outDirMask & (1 << d)) != 0:
			var net: SWNet = comp.outNets[d]
			if net != null and net_slot.has(net):
				return true
	return false


func _is_source(comp) -> bool:
	return comp is SWBuildCompoentCircuitClockSiggen \
			or comp is SWBuildCompoentCircuitSource


# ==========================================================================
# 展平为 stride 8 + 层区间表
# ==========================================================================
func _flatten(prog: SWGateProgram, gate_records: Array) -> void:
	gate_records.sort_custom(func(a, b): return a["level"] < b["level"])
	prog.gates.resize(gate_records.size() * SWGateProgram.STRIDE)
	prog.gate_count = gate_records.size()
	var level_starts := {}
	var level_counts := {}
	var gi := 0
	var cur_level := -1
	for rec in gate_records:
		var lv: int = rec["level"]
		if lv != cur_level:
			cur_level = lv
			level_starts[lv] = gi
			level_counts[lv] = 0
		level_counts[lv] = int(level_counts.get(lv, 0)) + 1
		var base: int = gi * SWGateProgram.STRIDE
		prog.gates[base + 0] = rec["op"]
		prog.gates[base + 1] = rec["dst"]
		prog.gates[base + 2] = lv
		var srcs: Array = rec["srcs"]
		var cnt: int = mini(srcs.size(), 4)
		prog.gates[base + 3] = cnt
		for i in cnt:
			prog.gates[base + 4 + i] = srcs[i]
		gi += 1
	prog.level_starts.resize(prog.level_count)
	prog.level_counts.resize(prog.level_count)
	for lv in prog.level_count:
		prog.level_starts[lv] = int(level_starts.get(lv, -1))
		prog.level_counts[lv] = int(level_counts.get(lv, 0))


# Kahn 拓扑层：输入类 slot（源 comp slot / 寄存器 Q comp slot）level 0；
# gate level = max(输入 slot level) + 1；环路/残余（依赖未定的）排到最后一层（收敛靠迭代轮次）
func _compute_levels(prog: SWGateProgram, records: Array) -> void:
	var slot_level: Array[int] = []
	slot_level.resize(prog.slot_count)
	slot_level.fill(-1)
	for i in prog.input_slots.size():
		slot_level[prog.input_slots[i]] = 0
	for i in prog.reg_slots.size():
		slot_level[prog.reg_slots[i]] = 0
	var assigned: Array[bool] = []
	assigned.resize(records.size())
	assigned.fill(false)
	var max_level := 0
	var progress := true
	while progress:
		progress = false
		for gi in records.size():
			if assigned[gi]:
				continue
			var rec: Dictionary = records[gi]
			var srcs: Array = rec["srcs"]
			var max_in := -1
			var all_known := true
			for s in srcs:
				if s < 0:
					continue
				if s < 0 or s >= slot_level.size():
					all_known = false
					break
				if slot_level[s] < 0:
					all_known = false
					break
				max_in = maxi(max_in, slot_level[s])
			if not all_known:
				continue
			var lv: int = max_in + 1
			slot_level[rec["dst"]] = lv
			rec["level"] = lv
			assigned[gi] = true
			max_level = maxi(max_level, lv)
			progress = true
	for gi in records.size():
		if not assigned[gi]:
			max_level += 1
			var rec: Dictionary = records[gi]
			rec["level"] = max_level
			slot_level[rec["dst"]] = max_level
			assigned[gi] = true
	prog.level_count = max_level + 1


# ==========================================================================
# 灯泡分组（两条编译路径共用）：输入 slot 集合完全相同的灯泡亮灭必然同步
# 编译期建好「组 → 输入段 + 成员段」三张平坦表，回填与 GPU 建表都只走下标访问。
# ==========================================================================
func _build_led_groups(prog: SWGateProgram) -> void:
	var gid_of_key: Dictionary = {}
	var gid_list := PackedInt32Array()
	var g_src_off := PackedInt32Array()
	var g_src_len := PackedInt32Array()
	var g_src_flat := PackedInt32Array()
	# 第一遍：按输入集合去重分组，记下每组的输入段与「第 i 盏灯属于哪组」
	for li in prog.led_src_slots.size():
		var led_srcs: PackedInt32Array = prog.led_src_slots[li]
		var key := "|"
		for s in led_srcs:
			key += str(s) + ","
		var gid: int = gid_of_key.get(key, -1)
		if gid < 0:
			gid = g_src_off.size()
			gid_of_key[key] = gid
			g_src_off.append(g_src_flat.size())
			g_src_len.append(led_srcs.size())
			g_src_flat.append_array(led_srcs)
		gid_list.append(gid)
	# 第二遍：成员段用「计数 + 前缀和 + 游标」铺平。
	# 不能在第一遍直接 append li：不同组的灯泡会交错出现（组号如 0,1,0,1），
	# 那样组的成员段就不连续，mem_off/mem_len 会扫到别的组的灯泡。
	var g_mem_len := PackedInt32Array()
	g_mem_len.resize(g_src_off.size())
	g_mem_len.fill(0)
	for gid in gid_list:
		g_mem_len[gid] = g_mem_len[gid] + 1
	var g_mem_off := PackedInt32Array()
	var cursor := 0
	for gi in g_src_off.size():
		g_mem_off.append(cursor)
		cursor += g_mem_len[gi]
	var g_members := PackedInt32Array()
	g_members.resize(gid_list.size())
	var fill := g_mem_off.duplicate()
	for li in gid_list.size():
		var gid: int = gid_list[li]
		g_members[fill[gid]] = li
		fill[gid] = fill[gid] + 1
	prog.led_group_id = gid_list
	prog.led_group_src_flat = g_src_flat
	prog.led_group_src_offs = g_src_off
	prog.led_group_src_lens = g_src_len
	prog.led_group_members = g_members
	prog.led_group_mem_offs = g_mem_off
	prog.led_group_mem_lens = g_mem_len
	prog.led_group_prev.resize(g_src_off.size())
	prog.led_group_prev.fill(-1)


# ==========================================================================
# 收尾（两条编译路径共用）：拓扑层 → 环检测 → CSE → 展平
# ==========================================================================
func _finish(prog: SWGateProgram, gate_records: Array) -> void:
	var t0 := Time.get_ticks_usec()
	_compute_levels(prog, gate_records)
	# 环上 slot 明细：既是诊断（loop_nets），也是后续任何重写（CSE / 化简器）的安全边界
	var loop_slots: Array[bool] = []
	loop_slots.resize(prog.slot_count)
	loop_slots.fill(false)
	if enable_opt:
		# 环上 slot 统计（诊断用）：反馈环里的中间态是计数器时序的一部分，任何重写都不能动它。
		# 无环的纯 DAG 电路（加法器等）这里会是 0，有寄存器的计数器反馈环会命中。
		loop_slots = _detect_loops(prog, gate_records)
		prog.loop_nets = 0
		for s in loop_slots.size():
			if loop_slots[s]:
				prog.loop_nets += 1
		# ===== 第一步：公共子表达式消除（CSE）=====
		# 用户方案：把 (a&b)&(a&b) 里的 (a&b) 提成中间表达式 S2，只算一次。
		# 这里在**求值层**做等价的事：同层内 (op, srcs) 完全相同的两条 gate 共用第一个结果。
		if enable_cse:
			_cse(prog, gate_records, loop_slots)
	else:
		# 关掉环检测就拿不到安全边界：全部当环处理，化简器一律不动（保守安全）
		loop_slots.fill(true)
	prog.loop_slot_flags.resize(loop_slots.size())
	for s in loop_slots.size():
		prog.loop_slot_flags[s] = 1 if loop_slots[s] else 0
	prog.opt_usec = Time.get_ticks_usec() - t0
	_flatten(prog, gate_records)


# ==========================================================================
# 网表 → prog（纯数据入口）
#
# 只读 SWNetlist 的整数表，全程不碰任何 SWBuild* / SWNet 对象。
# 与 _compile_legacy 的差别只有「拓扑从哪读」：那里是组件 pinNetMap / net._driverComps，
# 这里是 dev_pins / net_driver_flat。其余（slot 分配顺序、LED 分组、层/环/CSE/展平）
# 走同一套函数，产物逐字段一致（由 test_netlist_compile.gd 对拍）。
#
# 产物里 net_list / all_comps / *_comps 这些**对象表留空**：
# 需要表现层的调用方自己走 SWNetlistExport.bind_program 回接；
# 纯逻辑运行时只读 slot 空间，完全不需要它们。
# ==========================================================================
func compile_netlist(nl: SWNetlist) -> SWGateProgram:
	var prog := SWGateProgram.new()
	var dev_n: int = nl.dev_count()
	var net_n: int = nl.net_count()
	# net slot：网表的 net 已按 netId 升序，下标即 slot（net_slots[i] == i）
	prog.net_count = net_n
	prog.net_slots.resize(net_n)
	prog.net_prev_bit.resize(net_n)
	for i in net_n:
		prog.net_id_to_slot[nl.net_ids[i]] = i
		prog.net_slots[i] = i
		prog.net_prev_bit[i] = -1
	# comp slot：只给「驱动了某 net」的元件（与 _is_driver 同判据）
	var dev_slots := PackedInt32Array()
	dev_slots.resize(dev_n)
	dev_slots.fill(-1)
	var next_slot: int = net_n
	for dev in dev_n:
		if _nl_is_driver(nl, dev):
			dev_slots[dev] = next_slot
			next_slot += 1
	prog.dev_slots = dev_slots
	prog.comp_count = next_slot - net_n
	# 灯泡输入 slot（去重 + 升序，与实体路径同口径：OR 与顺序无关）
	for k in nl.led_devs.size():
		var ld: int = nl.led_devs[k]
		var arr := PackedInt32Array()
		for d in 4:
			var lslot: int = _nl_net_slot(prog, nl.pin_net(ld, d))
			if lslot >= 0:
				arr.append(lslot)
		arr.sort()
		var uniq := PackedInt32Array()
		for s in arr:
			if uniq.is_empty() or uniq[uniq.size() - 1] != s:
				uniq.append(s)
		prog.led_src_slots.append(uniq)
		prog.led_devs.append(ld)
	_build_led_groups(prog)
	# 显示刷新三张表（顺序 = 元件序，与实体路径一致）
	for dev in dev_n:
		var kind: int = nl.dev_kind[dev]
		if kind != SWNetlist.DEV_REG:
			prog.display_devs.append(dev)
		if dev_slots[dev] < 0:
			continue
		if kind == SWNetlist.DEV_REG or kind == SWNetlist.DEV_SOURCE:
			continue
		prog.gate_out_slots.append(dev_slots[dev])
		prog.gate_devs.append(dev)
		prog.gate_prev_level.append(-1)
		prog.gate_display_invert.append(1 if kind == SWNetlist.DEV_NOT else 0)
	for dev in dev_n:
		var kind2: int = nl.dev_kind[dev]
		if kind2 == SWNetlist.DEV_REG or kind2 == SWNetlist.DEV_LED:
			continue
		if dev_slots[dev] >= 0:
			continue
		prog.fallback_display_devs.append(dev)
	# gate 记录：元件驱动（源/寄存器只登记 slot，不产 gate）+ 每根 net 的线与
	var gate_records: Array = []
	for dev in dev_n:
		var slot: int = dev_slots[dev]
		if slot < 0:
			continue
		var kind3: int = nl.dev_kind[dev]
		if kind3 == SWNetlist.DEV_SOURCE:
			prog.input_slots.append(slot)
			prog.input_devs.append(dev)
			continue
		if kind3 == SWNetlist.DEV_REG:
			prog.reg_slots.append(slot)
			prog.reg_devs.append(dev)
			prog.reg_clk_slots.append(_nl_net_slot(prog, nl.dev_clk_net[dev]))
			prog.reg_d_slots.append(_nl_net_slot(prog, nl.dev_d_net[dev]))
			continue
		var srcs: Array[int] = []
		var im: int = nl.dev_in_mask[dev]
		for d in 4:
			if (im & (1 << d)) != 0:
				var s_in: int = _nl_net_slot(prog, nl.pin_net(dev, d))
				if s_in >= 0:
					srcs.append(s_in)
		var op: int = SWGateProgram.OP_NOT if kind3 == SWNetlist.DEV_NOT else SWGateProgram.OP_AND
		gate_records.append({"op": op, "dst": slot, "srcs": srcs, "synthetic": false})
	for ni in net_n:
		var dst: int = ni
		var drv: Array[int] = []
		var e: int = nl.net_driver_offs[ni + 1]
		for k in range(nl.net_driver_offs[ni], e):
			var dv: int = nl.net_driver_flat[k]
			if dev_slots[dv] >= 0:
				drv.append(dev_slots[dv])
		if drv.size() <= 4:
			gate_records.append({"op": SWGateProgram.OP_AND, "dst": dst, "srcs": drv, "synthetic": false})
		else:
			# >4 驱动折叠成 AND 链（中间 slot 追加在末尾，与实体路径同一编号顺序）
			var pending: Array[int] = drv.duplicate()
			while pending.size() > 4:
				var batch: Array[int] = []
				for i in 4:
					batch.append(pending.pop_front())
				var tmp: int = next_slot
				next_slot += 1
				gate_records.append({"op": SWGateProgram.OP_AND, "dst": tmp, "srcs": batch, "synthetic": true})
				pending.append(tmp)
			gate_records.append({"op": SWGateProgram.OP_AND, "dst": dst, "srcs": pending, "synthetic": false})
	prog.raw_gate_count = gate_records.size()
	prog.slot_count = next_slot
	_finish(prog, gate_records)
	return prog


# 网表元件是否驱动了某根受本电路关注的 net（与 _is_driver 同判据）
func _nl_is_driver(nl: SWNetlist, dev: int) -> bool:
	var om: int = nl.dev_out_mask[dev]
	for d in 4:
		if (om & (1 << d)) != 0:
			var nid: int = nl.pin_net(dev, d)
			if nid >= 0 and nl.net_id_to_index.has(nid):
				return true
	return false


# netId → net slot（-1 = 不在本电路里）
func _nl_net_slot(prog: SWGateProgram, net_id: int) -> int:
	return int(prog.net_id_to_slot.get(net_id, -1))
