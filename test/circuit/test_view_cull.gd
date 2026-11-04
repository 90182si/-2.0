extends GutTest
# 视野裁剪契约：视野外的电线与非门不刷显示，只计算寄存器。
#   godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://test/circuit -gprefix=test_view_cull -gexit
# 两层裁剪（见 SWCircuitControl.set_view_rect）：
#   1. 整条电路与视口不相交：含寄存器的照旧每拍求值（Q 是状态，停下来计数器就断了），
#      只是不回填显示；不含寄存器的（纯连线/纯组合）没有状态，整条跳过求值；
#   2. 部分可见的电路 → 照旧整条求值，但只回填视野内的电线/非门，
#      视野外的把 prev 哨兵置 -1，等它回到视野内那一拍补写。
# 存档用 计数器2（有时钟有寄存器，但 ledbug2 里没有）；
# 无状态电路被整条跳过的契约用 ledbug2（只有开关+电线）。
# headless 下相机推来的视口只覆盖一小块，这里直接调 set_view_rect（与真实链路入口一致）。

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const SAVE_NAME := "计数器2"
const STATELESS_SAVE := "ledbug2"
const LOG_PATH := "j:/godot/无限地图/_cull.txt"

var harness = null
var _lines: Array[String] = []

func before_each() -> void:
	harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)

func after_each() -> void:
	pass

func _w(m: String) -> void:
	_lines.append(m)

func _dump() -> void:
	var f := FileAccess.open(LOG_PATH, FileAccess.WRITE)
	for l in _lines:
		f.store_line(l)
	f.close()

func _boot(save_name: String = SAVE_NAME) -> bool:
	await harness.boot_game()
	var data: Dictionary = await harness.load_save(save_name)
	if data.is_empty():
		_w("LOAD FAILED " + save_name)
		_dump()
		fail_test("存档加载失败: " + save_name)
		return false
	return true

func _sys():
	return harness.build_layer.layer_system

# 收集存档里全部 net（去重）：断言「有没有被回填」直接看它们的变化计数
func _all_nets() -> Array:
	var seen: Dictionary = {}
	var arr: Array = []
	for b in _sys().build_manager.getAllBuilds():
		var comp = b.getCircuitCompoent()
		if comp == null:
			continue
		for dir in comp.pinNetMap.keys():
			var n = comp.pinNetMap[dir]
			if n == null or seen.has(n):
				continue
			seen[n] = true
			arr.append(n)
	return arr

func _version_map(nets: Array) -> Dictionary:
	var m: Dictionary = {}
	for n in nets:
		m[n] = n.sigVersion
	return m

func _changed_count(before: Dictionary, nets: Array) -> int:
	var c := 0
	for n in nets:
		if n.sigVersion != before[n]:
			c += 1
	return c

# 存档里的寄存器与开关（计数器2 的 8 个开关是计数使能，保存时全关着）
func _collect_regs() -> Array:
	var regs: Array = []
	for b in _sys().build_manager.getAllBuilds():
		if b is SWBuildRegister1Bit:
			regs.append(b)
	return regs

func _collect_switches() -> Array[SWBuildItemDefine]:
	# 必须用类型化数组收集：buildSignalsChanged 的第一个参数是 Array[SWBuildItemDefine]，
	# 无类型 Array 即使元素对路也会被运行时拒收（动态调用不做元素逐个转换）。
	var out: Array[SWBuildItemDefine] = []
	for b in _sys().build_manager.getAllBuilds():
		if b is SWBuildButton \
				and b.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.SWITCH:
			out.append(b)
	return out

func _q_key(regs: Array) -> String:
	var key := ""
	for b in regs:
		var cir := b.getCircuitCompoent() as SWBuildCompoentCircuitRegister
		key += str(int(cir.qState))
	return key

# 跑 n 拍「时钟驱动的裁剪轮次」，与 tick() 的调用方式一致
func _tick_culled(ctrl, clocks: Array, n: int) -> void:
	for i in n:
		for c in clocks:
			c.onPressed(true)
		ctrl.buildSignalsChanged(clocks, true)

# 1) 整条电路在视野外：电线与非门一拍不刷，但寄存器必须继续算
func test_offview_registers_still_compute_while_wires_stay_still() -> void:
	if not await _boot():
		return
	var ctrl = _sys().circuit_control
	var clocks: Array = _sys().clockBuildArr.keys()
	if clocks.is_empty():
		_w("no clocks in save")
		_dump()
		fail_test("存档里没有时钟，无法驱动每拍求值")
		return
	var nets: Array = _all_nets()
	assert_gt(nets.size(), 0, "存档里没有 net")
	# 「电线」= 有连线格覆盖的 net（会在画面上画出来的那些）；
	# 门直连带载的内部 net 没有 chunkPosArr，登记它的电平属于状态殿后，
	# 不产生任何画面写入（不标脏区块、没有实例采样它），所以不在裁剪范围内。
	var wire_nets: Array = []
	for n in nets:
		if (n as SWNet).chunkPosArr.size() > 0:
			wire_nets.append(n)
	assert_gt(wire_nets.size(), 0, "存档里没有带连线覆盖的 net")
	var regs: Array = _collect_regs()
	assert_gt(regs.size(), 0, "存档里没有寄存器，测不出「视野外只算寄存器」")
	var circuit = clocks[0].circuit
	assert_ne(circuit, null, "时钟没有归属电路")
	var r: Rect2 = circuit.cullRect
	assert_gt(r.size.x, 0.0, "电路包围盒未计算（cullRect 为空）")
	_w("电路包围盒 = " + str(r))
	# 先打开计数使能并跑一轮不裁剪的轮次（读档/交互轮次一律全量刷，作为显示基线）
	var switches: Array = _collect_switches()
	for s in switches:
		s.onPressed(true)
	if not switches.is_empty():
		ctrl.buildSignalsChanged(switches)
	# 视口放到离电路很远的空地上：整条电路不可见
	ctrl.set_view_rect(Rect2(r.end + Vector2(200000, 200000), Vector2(4096, 4096)))
	assert_false(ctrl._circuit_in_view(circuit), "远离电路的视口不该判为可见")
	var before := _version_map(nets)
	var before_wire := _version_map(wire_nets)
	_tick_culled(ctrl, clocks, 24)
	var off_changed := _changed_count(before, nets)
	var off_wire := _changed_count(before_wire, wire_nets)
	var off_chunks: Array = ctrl.takeDirtyChunks()
	_w("视野外 24 拍：电线变化=%d 全部 net 变化=%d 发布=%d 脏区块=%d 含寄存器照算=%d 整条跳过=%d" % [
		off_wire, off_changed, ctrl.dbg_flip_nets, off_chunks.size(),
		ctrl.dbg_cull_stateful, ctrl.dbg_cull_skipped])
	assert_gt(ctrl.dbg_cull_stateful, 0, "视野外含寄存器的电路被整条跳过了，寄存器停了")
	assert_eq(off_wire, 0, "视野外的电线仍被刷了显示（%d 根 net 变化）" % off_wire)
	assert_eq(off_chunks.size(), 0, "视野外仍有区块被标脏：%s" % str(off_chunks.slice(0, 4)))
	# 寄存器：看不见也得跟着时钟继续锁存
	var q_states := {}
	for i in 24:
		for c in clocks:
			c.onPressed(true)
		ctrl.buildSignalsChanged(clocks, true)
		q_states[_q_key(regs)] = true
		if q_states.size() > 1:
			break
	_w("视野外再跑拍：寄存器 Q 组合数=%d" % q_states.size())
	assert_gt(q_states.size(), 1, "视野外的寄存器停算了（Q 从未变化）")
	# 镜头移回来：下一拍自动接上显示刷新
	ctrl.set_view_rect(r.grow(2048.0))
	assert_true(ctrl._circuit_in_view(circuit), "覆盖电路的视口应判为可见")
	var before2 := _version_map(nets)
	_tick_culled(ctrl, clocks, 8)
	var back_changed := _changed_count(before2, nets)
	_w("移回视野 8 拍：net 变化=%d" % back_changed)
	assert_gt(back_changed, 0, "电路回到视野后电线仍不刷新，裁剪没法恢复")
	_dump()
	pass_test("视野外：寄存器照算，电线与非门不刷显示")

# 2) 部分可见的电路：只刷视野内的电线与非门，视野外的既不刷也不欠着
func test_partial_view_only_refreshes_visible_elements() -> void:
	if not await _boot():
		return
	var ctrl = _sys().circuit_control
	var clocks: Array = _sys().clockBuildArr.keys()
	if clocks.is_empty():
		_dump()
		fail_test("存档里没有时钟")
		return
	var circuit = clocks[0].circuit
	var r: Rect2 = circuit.cullRect
	# 只盖住电路包围盒左侧一小条：右侧的电线/非门应当被裁掉
	var view := Rect2(r.position - Vector2(4096, 4096),
			Vector2(r.size.x * 0.3 + 8192.0, r.size.y + 8192.0))
	ctrl.set_view_rect(view)
	_w("裁剪视口 = " + str(view))
	_tick_culled(ctrl, clocks, 4)
	var prog: SWGateProgram = null
	for cid in ctrl._cpu_backends:
		var cb: Dictionary = ctrl._cpu_backends[cid]
		if cb["prog"] == ctrl._compiled_prog(circuit):
			prog = cb["prog"]
	if prog == null:
		_dump()
		fail_test("取不到该电路的 CPU 后端")
		return
	var net_total: int = prog.net_list.size()
	var net_vis: int = prog.net_view_idx.size()
	var gate_total: int = prog.gate_out_slots.size()
	var gate_vis: int = prog.gate_view_idx.size()
	_w("net 总数=%d 视野内=%d   非门总数=%d 视野内=%d" % [net_total, net_vis, gate_total, gate_vis])
	assert_lt(net_vis, net_total, "这条存档裁不出「部分可见」的电线，用例失效（覆盖面太大）")
	# 视野外的电线：prev 哨兵被置 -1，等回到视野内那一拍补写；视野内的必须是 0/1
	var marked := 0
	var published := 0
	for i in net_total:
		var bit: int = prog.net_prev_bit[i]
		if bit == -1:
			marked += 1
		else:
			published += 1
			assert_true(bit == 0 or bit == 1, "net prev 出现非法值 %d" % bit)
	_w("电线 prev=-1（欠补写）=%d  已登记=%d" % [marked, published])
	assert_eq(marked, net_total - net_vis, "视野外的电线没有被标记成待补写")
	assert_gt(published, 0, "视野内的电线一个都没登记")
	# 本拍标脏的电线必须都在视野内（否则等于没裁）
	var out_dirty := 0
	for n in ctrl.takeDirtyNets().keys():
		if not ctrl._net_in_view(n):
			out_dirty += 1
	assert_eq(out_dirty, 0, "有 %d 根视野外的电线仍被送去刷显示" % out_dirty)
	# 非门同理：视野外的 prev 置 -1 且不进 dirty 表
	var g_marked := 0
	for gi in gate_total:
		var lv: int = prog.gate_prev_level[gi]
		if lv == -1:
			g_marked += 1
	_w("非门 prev=-1（欠补写）=%d" % g_marked)
	var out_gate := 0
	for gi in prog.dirty_gate_idx:
		var rr = prog.gate_refresh_comps[gi]
		if rr != null and rr.buildRef != null and not ctrl._pos_in_view(rr.buildRef.buildAxisPos):
			out_gate += 1
	assert_eq(out_gate, 0, "有 %d 个视野外的非门仍在刷贴图" % out_gate)
	_dump()
	pass_test("部分可见的电路只刷视野内的电线与非门")

# 3）相机→绘制层→电路的推进链路真的接上了，且「整屏都可见」时不删任何元件
func test_wired_view_rect_and_full_view_keeps_full_refresh() -> void:
	if not await _boot():
		return
	var ctrl = _sys().circuit_control
	var clocks: Array = _sys().clockBuildArr.keys()
	if clocks.is_empty():
		_dump()
		fail_test("存档里没有时钟")
		return
	# boot_game 里真实相机会推视口（headless 也是有效矩形），说明裁剪不靠调用方手动 set_view_rect
	var wired: Rect2 = ctrl.get_view_rect()
	_w("启动后推进来的视口 = " + str(wired))
	assert_ne(wired.size.x, 2e9, "相机视口没传到电路侧（view_rect_cb 未接通）")
	# 整屏可见（缩到很远 / 无限大矩形）：下标表覆盖全部元件，必须走原来的全量循环
	ctrl.set_view_rect(Rect2(-1e9, -1e9, 2e9, 2e9))
	_tick_culled(ctrl, clocks, 4)
	var marked := 0
	var total := 0
	for cid in ctrl._cpu_backends:
		var prog: SWGateProgram = ctrl._cpu_backends[cid]["prog"]
		total += prog.net_prev_bit.size()
		assert_eq(prog.net_view_idx.size(), prog.net_list.size(), "全可见时下标表应覆盖全部电线")
		assert_eq(prog.gate_view_idx.size(), prog.gate_out_slots.size(), "全可见时下标表应覆盖全部非门")
		for bit in prog.net_prev_bit:
			if bit == -1:
				marked += 1
	_w("整屏可见：net 总数=%d prev=-1 的=%d" % [total, marked])
	assert_gt(total, 0, "没有 CPU 后端可统计")
	assert_eq(marked, 0, "整屏可见时仍有电线被裁掉")
	_dump()
	pass_test("视口链路已接通，且全可见时不裁剪")

# 4) 视野外且不含寄存器的电路（纯连线/纯组合）：没有状态要推进，连求值都跳过
func test_offview_stateless_circuit_is_skipped() -> void:
	if not await _boot(STATELESS_SAVE):
		return
	var ctrl = _sys().circuit_control
	var switches: Array = _collect_switches()
	if switches.is_empty():
		_w("no switches in " + STATELESS_SAVE)
		_dump()
		fail_test("存档里没有可驱动的开关")
		return
	var sw = switches[0]
	var circuit = sw.circuit
	assert_ne(circuit, null, "开关没有归属电路")
	assert_false(ctrl._circuit_has_register(circuit), "这条存档的电路里不该有寄存器")
	var r: Rect2 = circuit.cullRect
	assert_gt(r.size.x, 0.0, "电路包围盒未计算")
	var nets: Array = []
	for b in circuit.buildArr:
		var comp = b.getCircuitCompoent()
		if comp == null:
			continue
		for dir in comp.pinNetMap.keys():
			var n = comp.pinNetMap[dir]
			if n != null and not nets.has(n):
				nets.append(n)
	assert_gt(nets.size(), 0, "这条电路里没有 net")
	# 视口挪开，然后拨一下开关：整条被跳过，真值变了但屏幕上什么都不会动
	ctrl.set_view_rect(Rect2(r.end + Vector2(200000, 200000), Vector2(4096, 4096)))
	var before := _version_map(nets)
	sw.onPressed(not sw.pressed)
	var seeds: Array[SWBuildItemDefine] = [sw]
	ctrl.buildSignalsChanged(seeds, true)
	var off_changed := _changed_count(before, nets)
	_w("视野外（无寄存器）：跳过电路=%d net 变化=%d 发布=%d" % [
		ctrl.dbg_cull_skipped, off_changed, ctrl.dbg_flip_nets])
	assert_eq(ctrl.dbg_cull_skipped, 1, "视野外的无状态电路没有整条跳过求值")
	assert_eq(off_changed, 0, "整条被跳过的电路仍动了显示")
	# 镜头移回来：不必再拨开关，那一拍落下的变化下一拍自动补上
	ctrl.set_view_rect(r.grow(4096.0))
	var before2 := _version_map(nets)
	ctrl.buildSignalsChanged(seeds, true)
	var back_changed := _changed_count(before2, nets)
	_w("移回视野一轮（不再拨开关）：跳过=%d net 变化=%d" % [ctrl.dbg_cull_skipped, back_changed])
	assert_eq(ctrl.dbg_cull_skipped, 0, "可见电路仍被跳过")
	assert_gt(back_changed, 0, "镜头回来后欠下的电平没补上")
	_dump()
	pass_test("视野外的无状态电路整条不求值，回来自动补写")
