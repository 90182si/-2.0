extends GutTest
# 引擎级对拍：SWSignalEvalCPU vs SWSignalEvalGPU（同一 prog、同一输入序列、多拍 readback 逐 slot 对比）
# 目的：定位 sigEpoch 修复后暴露的 CPU 数据驱动与 GPU 引擎求值差异。
# 输出 _engine_parity.txt

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const SAVE_NAME := "加法器3"
const N_ITERS := 12

var harness = null
var _out: FileAccess

func before_each() -> void:
	harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)
	_out = FileAccess.open("j:/godot/无限地图/_engine_parity.txt", FileAccess.WRITE)

func after_each() -> void:
	if harness != null:
		harness.shutdown_game()
		harness = null
	if _out != null:
		_out.close()
		_out = null

func _w(msg: String) -> void:
	if _out != null:
		_out.store_line(msg)

func _collect_inputs(prog: SWGateProgram) -> PackedInt32Array:
	var vals := PackedInt32Array()
	for comp in prog.input_comps:
		var ref = comp.buildRef
		if comp is SWBuildCompoentCircuitClockSiggen:
			var clk := ref as SWBuildClockSiggen
			vals.append(1 if clk != null and clk.curSig == SwDefine.CircuitSignal.HIGH else 0)
		elif comp is SWBuildCompoentCircuitSource:
			var btn := ref as SWBuildButton
			vals.append(1 if btn != null and btn.pressed else 0)
		else:
			vals.append(0)
	return vals

func test_engine_parity() -> void:
	await harness.boot_game()
	var data: Dictionary = await harness.load_save(SAVE_NAME)
	if data.is_empty():
		fail_test("存档加载失败")
		return
	var sys = harness.build_layer.layer_system
	var ctrl = sys.circuit_control
	# 先触发一次求值，确保 backend 已建（GPU/CPU 都会建）
	var first_btn := harness.get_build(SWITCH_POS[0]) as SWBuildButton
	if first_btn != null:
		ctrl.buildSignalChanged(first_btn)
	# 取 GPU backend 里已注册的电路
	var circuit = null
	for c in ctrl._gpu_backends:
		circuit = c
		break
	if circuit == null:
		_w("[PARITY] 仍无 GPU backend（GPU 创建失败？），尝试从 CPU backend 取")
		for c in ctrl._cpu_backends:
			circuit = c
			break
	if circuit == null:
		fail_test("未找到电路")
		return
	# 同一 prog
	var prog := SWGateCompiler.new().compile(circuit.buildArr)
	var cpu := SWSignalEvalCPU.new()
	cpu.setup(prog)
	# GPU 引擎（D3D12 GUT 环境可用）
	var gpu := SWSignalEvalGPU.new()
	gpu.setup(prog)
	if gpu.is_broken():
		fail_test("GPU 引擎不可用")
		return
	# 相同初始状态灌入（net 当前电平 + 寄存器 Q/lastClk）
	var q := PackedInt32Array()
	var lc := PackedInt32Array()
	for i in prog.reg_slots.size():
		var reg := prog.reg_comps[i] as SWBuildCompoentCircuitRegister
		q.append(1 if reg != null and reg.qState == SwDefine.CircuitSignal.HIGH else 0)
		lc.append(-1 if reg == null or reg.lastClk == SwDefine.CircuitSignal.NONE \
				else (1 if reg.lastClk == SwDefine.CircuitSignal.HIGH else 0))
	cpu.init_reg_state(q, lc)
	gpu.init_reg_state(q, lc)
	var prev_slots := PackedInt32Array()
	prev_slots.resize(prog.slot_count)
	prev_slots.fill(0)
	for net in prog.net_to_slot:
		prev_slots[prog.net_to_slot[net]] = 1 if (net as SWNet).curSignal == SwDefine.CircuitSignal.HIGH else 0
	for i in prog.reg_slots.size():
		var reg := prog.reg_comps[i] as SWBuildCompoentCircuitRegister
		prev_slots[prog.reg_slots[i]] = 1 if reg != null and reg.qState == SwDefine.CircuitSignal.HIGH else 0
	cpu.init_prev(prev_slots)
	gpu.init_prev(prev_slots)
	_w("[PARITY] prog gates=%d slots=%d levels=%d regs=%d inputs=%d" % [
		prog.gate_count, prog.slot_count, prog.level_count, prog.reg_slots.size(), prog.input_slots.size()])
	# 拓扑验证：每个 gate 的 src 必须 slot_lv < gate_level（本轮已算）或 -1（外部输入），
	# 否则 GPU read_slot 读 a（旧值）而 CPU 无条件读 _cur（写侧），两者不等价 → 求值分叉
	var slot_lv_check := PackedInt32Array()
	slot_lv_check.resize(prog.slot_count)
	slot_lv_check.fill(-1)
	for gi in prog.gate_count:
		var bb: int = gi * 8
		var dst2: int = prog.gates[bb + 1]
		var lv2: int = prog.gates[bb + 2]
		if dst2 >= 0 and dst2 < prog.slot_count:
			slot_lv_check[dst2] = lv2
	var topo_bad := 0
	var topo_srcs: Array = []
	for gi in prog.gate_count:
		var bb: int = gi * 8
		var op2: int = prog.gates[bb]
		var gl: int = prog.gates[bb + 2]
		var n2: int = prog.gates[bb + 3]
		if op2 == 1:
			var s: int = prog.gates[bb + 4]
			if slot_lv_check[s] >= 0 and slot_lv_check[s] >= gl:
				topo_bad += 1
				if topo_srcs.size() < 12:
					topo_srcs.append("g%d src%d(slot_lv=%d>=%d)" % [gi, s, slot_lv_check[s], gl])
		elif op2 == 2:
			for si in n2:
				var s2: int = prog.gates[bb + 4 + si]
				if slot_lv_check[s2] >= 0 and slot_lv_check[s2] >= gl:
					topo_bad += 1
					if topo_srcs.size() < 12:
						topo_srcs.append("g%d src%d(slot_lv=%d>=%d)" % [gi, s2, slot_lv_check[s2], gl])
	_w("[PARITY] topo_violations=%d 例: %s" % [topo_bad, ", ".join(topo_srcs)])
	var total_diff := 0
	for it in N_ITERS:
		var vals := _collect_inputs(prog)
		# 每拍翻转一个按钮制造变化
		if it < 5:
			var b = harness.get_build(SWITCH_POS[it % 5])
			var btn := b as SWBuildButton
			if btn != null:
				btn.pressed = not btn.pressed
			vals = _collect_inputs(prog)
		cpu.write_sources(vals)
		gpu.write_sources(vals)
		cpu.evaluate()
		gpu.evaluate()
		var crb := cpu.readback()
		var grb := gpu.readback()
		# GPU 双缓冲：readback 读写侧，输入 slot（无 gate 写、由外部写读侧）回读为 0；
		# CPU 引擎单缓冲语义 readback 含当前输入值（集成回填更正确）。比较排除输入 slot。
		var diff := 0
		var first: int = -1
		for s in prog.slot_count:
			if _is_input_slot(prog, s):
				continue
			if crb[s] != grb[s]:
				diff += 1
				if first < 0:
					first = s
		total_diff += diff
		if diff > 0:
			_w("[PARITY] iter=%d diffs=%d first_slot=%d cpu=%d gpu=%d" % [it, diff, first, crb[first], grb[first]])
			for s in prog.slot_count:
				if crb[s] != grb[s]:
					_w("    slot %d: cpu=%d gpu=%d (net=%s)" % [s, crb[s], grb[s], _slot_name(prog, s)])
					_w("      writer: %s" % _writer_desc(prog, s))
					_w("      readers: %s" % _readers_desc(prog, s))
	_w("[PARITY] total_diff=%d/%d" % [total_diff, N_ITERS])
	assert_eq(total_diff, 0, "CPU/GPU 引擎求值有 %d 处差异" % total_diff)

func _is_input_slot(prog: SWGateProgram, s: int) -> bool:
	for isl in prog.input_slots:
		if isl == s:
			return true
	return false

func _slot_name(prog: SWGateProgram, s: int) -> String:
	for net in prog.net_to_slot:
		if prog.net_to_slot[net] == s:
			return str(net)
	for i in prog.reg_slots.size():
		if prog.reg_slots[i] == s:
			return "regQ[%d]" % i
	return "tmp"

func _writer_desc(prog: SWGateProgram, s: int) -> String:
	for gi in prog.gate_count:
		var bb: int = gi * 8
		if prog.gates[bb + 1] == s:
			return "g%d op=%d lv=%d n=%d srcs=[%d,%d,%d,%d]" % [
				gi, prog.gates[bb], prog.gates[bb + 2], prog.gates[bb + 3],
				prog.gates[bb + 4], prog.gates[bb + 5], prog.gates[bb + 6], prog.gates[bb + 7]]
	return "none"

func _readers_desc(prog: SWGateProgram, s: int) -> String:
	var out: Array = []
	for gi in prog.gate_count:
		var bb: int = gi * 8
		var op2: int = prog.gates[bb]
		var gl: int = prog.gates[bb + 2]
		var n2: int = prog.gates[bb + 3]
		if op2 == 1:
			if prog.gates[bb + 4] == s:
				out.append("g%d(not,lv%d)" % [gi, gl])
		elif op2 == 2:
			for si in n2:
				if prog.gates[bb + 4 + si] == s:
					out.append("g%d(and,lv%d)" % [gi, gl])
					break
	return ", ".join(out) if out.size() > 0 else "none"

const SWITCH_POS: Array = [
	Vector2i(5760, 3456), Vector2i(4480, 3456), Vector2i(3200, 3456),
	Vector2i(1920, 3456), Vector2i(5888, 3072),
]
