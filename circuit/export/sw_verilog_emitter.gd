class_name SWVerilogEmitter extends RefCounted

## L2 服务层：将 SWBoolProgram IR 导出为平坦门级 Verilog
## 只读 SWBoolProgram，不回写任何游戏状态
## 按需调用，返回 String；严禁接入 tick 路径

const _OP_INPUT  := 0
const _OP_LATCH  := 1
const _OP_AND    := 2
const _OP_NAND   := 3
const _OP_NOT    := 4
const _OP_PASS   := 5
const _OP_CONST  := 6
const _OP_OUT    := 7
const _OP_READ   := 8

# T2.5 后 SWBoolProgram 为持久增量程序（含失活段），导出只遍历存活段内的指令
func _live_indices(program: SWBoolProgram) -> Array:
	var result: Array = []
	if program.segments.is_empty():
		for i in range(program.op_arr.size()):
			result.append(i)
		return result
	var sorted_segs: Array = program.segments.values()
	sorted_segs.sort_custom(func(x, y): return x["start"] < y["start"])
	for seg: Dictionary in sorted_segs:
		for i in range(seg["start"], seg["end"]):
			result.append(i)
	return result

# CircuitComponentType 枚举值（只读引用，避免依赖整数序列化）
const _COMP_BUTTON  := "BUTTON"
const _COMP_SWITCH  := "SWITCH"
const _COMP_CLOCK   := "CLOCK"
const _COMP_LED     := "LED"
const _COMP_REGISTER := "ONE_BIT_REGISTER"


## 主入口：输入 SWBoolProgram + 建筑列表，输出 .v 文本，失败返回空串并 push_error
func emit(program: SWBoolProgram, builds: Array) -> String:
	if program == null:
		push_error("SWVerilogEmitter.emit: program 为 null")
		return ""
	if program.op_arr.size() == 0:
		push_error("SWVerilogEmitter.emit: program.op_arr 为空")
		return ""

	# ── 1. 端口收集 ──────────────────────────────────────────────
	# 输入端口：{ build_id: {"name": String, "comment": String} }
	var input_ports: Dictionary = {}
	# 输出端口：{ build_id: {"name": String, "comment": String} }
	var output_ports: Dictionary = {}
	# 寄存器：{ build_id: {"name": String, "comment": String} }
	var register_ports: Dictionary = {}
	# 是否有时钟
	var has_clock: bool = false

	for build in builds:
		if _is_wire_build(build):
			continue
		var comp_type_str := _get_comp_type_str(build)
		var bid: int = build.id
		var pos: Vector2i = build.buildAxisPos
		var bname: String = build.buildDefine.buildName
		var comment := "// %s@%d,%d" % [bname, pos.x, pos.y]
		match comp_type_str:
			_COMP_BUTTON:
				input_ports[bid] = {"name": "sw_%d" % bid, "comment": comment}
			_COMP_SWITCH:
				input_ports[bid] = {"name": "sw_%d" % bid, "comment": comment}
			_COMP_CLOCK:
				has_clock = true
			_COMP_LED:
				output_ports[bid] = {"name": "led_%d" % bid, "comment": comment}
			_COMP_REGISTER:
				register_ports[bid] = {"name": "q_%d" % bid, "comment": comment}

	# ── 2. 建立 net → build 反查表 ────────────────────────────────
	# net_to_input_build: { SWNet: SWBuildItemDefine }  源类建筑（BUTTON/SWITCH/CLOCK）
	var net_to_src_build: Dictionary = {}
	# net_to_output_build: { SWNet: SWBuildItemDefine }  LED 建筑
	var net_to_dst_build: Dictionary = {}
	# net_to_reg_build: { SWNet: SWBuildItemDefine }  寄存器的 D 输入 net
	var net_to_reg_d_build: Dictionary = {}
	# net_to_reg_q_build: { SWNet: SWBuildItemDefine }  寄存器的 Q 输出 net
	var net_to_reg_q_build: Dictionary = {}

	for build in builds:
		if _is_wire_build(build):
			continue
		var comp_type_str := _get_comp_type_str(build)
		var circuit_com = build.getCircuitCompoent()
		if circuit_com == null:
			continue
		var pin_net_map: Dictionary = circuit_com.pinNetMap
		for pin_dir in pin_net_map:
			var net: SWNet = pin_net_map[pin_dir]
			if net == null:
				continue
			match comp_type_str:
				_COMP_BUTTON, _COMP_SWITCH, _COMP_CLOCK:
					# 源类建筑的输出端口 → 记录 net 到 build 映射
					if circuit_com.portIsOutput(pin_dir):
						net_to_src_build[net] = build
				_COMP_LED:
					# LED 的输入端口 → 记录 net 到 build 映射
					if circuit_com.portIsInput(pin_dir):
						net_to_dst_build[net] = build
				_COMP_REGISTER:
					# 寄存器的 D 输入（D_REF 方向）和 Q 输出
					var reg_com = circuit_com as SWBuildCompoentCircuitRegister
					if reg_com:
						var d_world_dir := _world_dir(build, SWBuildCompoentCircuitRegister.D_REF)
						var q_world_dir := _world_dir(build, SWBuildCompoentCircuitRegister.Q_REF)
						if pin_dir == d_world_dir:
							net_to_reg_d_build[net] = build
						if pin_dir == q_world_dir:
							net_to_reg_q_build[net] = build

	# ── 3. 建立 slot → 名称映射 ──────────────────────────────────
	var slot_name: Dictionary = {}   # slot_idx → String
	var slot_driven: Dictionary = {} # slot_idx → true（多驱动检测）

	# OP_READ → 源类端口名（T2.5：状态驱动叶不再经 net 反查，直接由 meta 拿建筑）
	for i in _live_indices(program):
		if program.op_arr[i] != _OP_READ:
			continue
		var dst_slot: int = program.dst_arr[i]
		if dst_slot < 0 or dst_slot >= program.read_meta.size():
			continue
		var rbuild: SWBuildItemDefine = program.read_meta[dst_slot]["build"]
		var rtype := _get_comp_type_str(rbuild)
		if rtype == _COMP_CLOCK:
			slot_name[dst_slot] = "clk"
		else:
			slot_name[dst_slot] = "sw_%d" % rbuild.id

	# OP_INPUT → 对应 input 端口名
	for i in _live_indices(program):
		if program.op_arr[i] != _OP_INPUT:
			continue
		var dst_slot: int = program.dst_arr[i]
		var meta_idx: int = dst_slot
		if meta_idx < 0 or meta_idx >= program.input_meta.size():
			continue
		var net: SWNet = program.input_meta[meta_idx].net
		var src_build = net_to_src_build.get(net, null)
		if src_build != null:
			var src_comp_type := _get_comp_type_str(src_build)
			if src_comp_type == _COMP_CLOCK:
				slot_name[dst_slot] = "clk"
			else:
				slot_name[dst_slot] = "sw_%d" % src_build.id
		else:
			# 悬空输入：默认低电平
			slot_name[dst_slot] = "n_%d" % dst_slot

	# OP_LATCH → q_<reg_id>
	for i in _live_indices(program):
		if program.op_arr[i] != _OP_LATCH:
			continue
		var dst_slot: int = program.dst_arr[i]
		# 从 output_meta 或 input_meta 找寄存器对应的 net？
		# OP_LATCH 的 dst 对应寄存器 Q 输出 net
		# 需要通过 latch slot 找到对应的寄存器建筑
		# 方法：遍历寄存器建筑，检查其 Q 方向 net 对应的 OP_LATCH
		# 实际上 OP_LATCH 的 dst slot 在 _latch_indices 中注册
		# 我们直接通过遍历寄存器建筑来建立映射
		# 先跳过，下面统一处理

	# 为 OP_LATCH 建立映射：遍历所有寄存器建筑
	for bid in register_ports:
		var build = _find_build_by_id(builds, bid)
		if build == null:
			continue
		var reg_com = build.getCircuitCompoent() as SWBuildCompoentCircuitRegister
		if reg_com == null:
			continue
		var q_world_dir := _world_dir(build, SWBuildCompoentCircuitRegister.Q_REF)
		var q_net: SWNet = reg_com.pinNetMap.get(q_world_dir, null)
		if q_net == null:
			continue
		# 找到 q_net 对应的 OP_OUT 或 OP_LATCH slot
		# OP_LATCH 的 dst slot 对应 Q 输出
		for i in _live_indices(program):
			if program.op_arr[i] != _OP_LATCH:
				continue
			var dst_slot: int = program.dst_arr[i]
			# OP_LATCH 在 evaluate 中不直接使用 output_meta
			# 但 latch slot 与寄存器 Q 输出 slot 相同
			# 通过 _latch_indices 可以确认
			if not slot_name.has(dst_slot):
				slot_name[dst_slot] = "q_%d" % bid

	# 其余非 OP_INPUT/OP_LATCH/OP_OUT 的 slot → wire n_<slotIdx>
	var max_slot := 0
	for i in _live_indices(program):
		if program.dst_arr[i] > max_slot:
			max_slot = program.dst_arr[i]
	for s in range(max_slot + 1):
		if not slot_name.has(s):
			slot_name[s] = "n_%d" % s

	# ── 4. 多驱动检测 ─────────────────────────────────────────────
	for i in _live_indices(program):
		var op := program.op_arr[i]
		var dst_slot: int = program.dst_arr[i]
		# OP_INPUT/OP_READ 和 OP_LATCH 不产生组合 assign，跳过
		if op == _OP_INPUT or op == _OP_READ or op == _OP_LATCH or op == _OP_OUT:
			continue
		if slot_driven.has(dst_slot):
			push_error("SWVerilogEmitter.emit: 多驱动检测 — slot %d 被多条指令写入" % dst_slot)
			return ""
		slot_driven[dst_slot] = true

	# ── 5. 生成 Verilog 文本 ──────────────────────────────────────
	var lines: Array[String] = []
	var timestamp := Time.get_datetime_string_from_system()
	lines.append("// Auto-generated by SWVerilogEmitter")
	lines.append("// 电路导出 @ %s" % timestamp)
	lines.append("")

	# module 端口列表
	var port_list: Array[String] = []
	if has_clock:
		port_list.append("clk")
	for bid in input_ports:
		port_list.append(input_ports[bid].name)
	for bid in output_ports:
		port_list.append(output_ports[bid].name)

	var port_decl := "module circuit_top(\n    "
	for idx in range(port_list.size()):
		var pname := port_list[idx]
		var comment := ""
		# 查找对应注释
		for bid in input_ports:
			if input_ports[bid].name == pname:
				comment = " " + input_ports[bid].comment
				break
		for bid in output_ports:
			if output_ports[bid].name == pname:
				comment = " " + output_ports[bid].comment
				break
		var suffix := "," if idx < port_list.size() - 1 else ""
		port_decl += pname + comment + suffix + "\n    "
	port_decl = port_decl.rstrip("\n    ")
	port_decl += "\n);"
	lines.append(port_decl)
	lines.append("")

	# input 声明
	if has_clock:
		lines.append("input clk;")
	for bid in input_ports:
		lines.append("input %s;" % input_ports[bid].name)

	# output 声明
	for bid in output_ports:
		lines.append("output %s;" % output_ports[bid].name)

	# reg 声明（寄存器）
	for bid in register_ports:
		lines.append("reg %s;" % register_ports[bid].name)

	lines.append("")

	# Internal wires
	var wire_lines: Array[String] = []
	for s in range(max_slot + 1):
		var sname: String = slot_name[s]
		# 跳过已经是端口名的 slot（input port / latch output）
		if sname.begins_with("sw_") or sname.begins_with("clk") or sname.begins_with("q_"):
			continue
		if sname.begins_with("n_"):
			wire_lines.append("wire %s;" % sname)
	if wire_lines.size() > 0:
		lines.append("// Internal wires")
		lines.append_array(wire_lines)
		lines.append("")

	# Register initial values
	if register_ports.size() > 0:
		lines.append("// Register initial values")
		for bid in register_ports:
			lines.append("initial %s = 1'b0;" % register_ports[bid].name)
		lines.append("")

	# 悬空输入默认低电平
	lines.append("// Gate assignments")
	for i in _live_indices(program):
		var op := program.op_arr[i]
		if op != _OP_INPUT:
			continue
		var dst_slot: int = program.dst_arr[i]
		var sname: String = slot_name[dst_slot]
		if sname.begins_with("n_"):
			# 悬空输入
			lines.append("assign %s = 1'b0; // 悬空输入，默认低电平" % sname)

	# 门指令
	for i in _live_indices(program):
		var op := program.op_arr[i]
		var dst_slot: int = program.dst_arr[i]
		var a_slot: int = program.a_arr[i]
		var b_slot: int = program.b_arr[i]
		var dst_name: String = slot_name.get(dst_slot, "n_%d" % dst_slot)
		var a_name: String = slot_name.get(a_slot, "n_%d" % a_slot)
		var b_name: String = slot_name.get(b_slot, "n_%d" % b_slot)
		match op:
			_OP_AND:
				lines.append("assign %s = %s & %s;" % [dst_name, a_name, b_name])
			_OP_NAND:
				lines.append("assign %s = ~(%s & %s);" % [dst_name, a_name, b_name])
			_OP_NOT:
				lines.append("assign %s = ~%s;" % [dst_name, a_name])
			_OP_PASS:
				lines.append("assign %s = %s;" % [dst_name, a_name])
			_OP_READ:
				# 状态驱动叶的包装 slot（如寄存器 Q 的 PASS 自源叶子）：直通到端口名
				lines.append("assign %s = %s;" % [dst_name, a_name])
			_OP_CONST:
				var val: int = a_slot  # a_arr[i] 为常量值
				lines.append("assign %s = 1'b%d;" % [dst_name, val])
			_OP_OUT:
				# 通过 output_meta 找到 LED build
				var meta_idx: int = dst_slot
				if meta_idx >= 0 and meta_idx < program.output_meta.size():
					var net: SWNet = program.output_meta[meta_idx].net
					var led_build = net_to_dst_build.get(net, null)
					if led_build != null:
						var led_name := "led_%d" % led_build.id
						lines.append("assign %s = %s;" % [led_name, a_name])
					# else：内部 net（驱动其它门/寄存器，而非 LED）的 OP_OUT。
					# T2.5 push 化后编译器为每个门输出 net 都发 OP_OUT（写回 net.curSignal 供跨段 OP_INPUT 读），
					# 但结构导出的信号值已由 a_name（门计算结果线 n_x）表达，下游逻辑据此重连，
					# 该 OP_OUT 对 Verilog 冗余 → 跳过（不报错）。
				else:
					push_error("SWVerilogEmitter.emit: OP_OUT slot %d output_meta 越界" % dst_slot)
					return ""

	lines.append("")

	# Register always blocks
	if register_ports.size() > 0 and has_clock:
		lines.append("// Register always blocks")
		for bid in register_ports:
			var build = _find_build_by_id(builds, bid)
			if build == null:
				continue
			var reg_com = build.getCircuitCompoent() as SWBuildCompoentCircuitRegister
			if reg_com == null:
				continue
			var d_world_dir := _world_dir(build, SWBuildCompoentCircuitRegister.D_REF)
			var d_net: SWNet = reg_com.pinNetMap.get(d_world_dir, null)
			# 找到 D net 对应的 slot（通过 input_meta 反查）
			var d_slot_name := "1'b0"
			for i in _live_indices(program):
				if program.op_arr[i] != _OP_INPUT:
					continue
				var meta_idx: int = program.dst_arr[i]
				if meta_idx < 0 or meta_idx >= program.input_meta.size():
					continue
				if program.input_meta[meta_idx].net == d_net:
					d_slot_name = slot_name.get(program.dst_arr[i], "n_%d" % program.dst_arr[i])
					break
			# 也检查是否是内部 wire（可能是 PASS/AND 等输出）
			# 遍历所有指令找 dst 对应的 net
			# 实际上 D net 是寄存器 D 输入端的 net，对应某个 OP_INPUT 的 slot
			# 如果找不到 OP_INPUT，说明 D 端悬空
			lines.append("always @(posedge clk)")
			lines.append("    %s <= %s;" % [register_ports[bid].name, d_slot_name])
		lines.append("")

	lines.append("endmodule")
	lines.append("")

	return "\n".join(lines)


# ── 辅助函数 ─────────────────────────────────────────────────────

## 判断建筑是否为电线类（WIRE / WIRE_BRIDGE / WIRE_TUNNEL）
func _is_wire_build(build: SWBuildItemDefine) -> bool:
	if build == null or build.buildDefine == null:
		return false
	var ct = build.buildDefine.circuit_component_type
	return ct == SwDefine.CircuitComponentType.WIRE \
		or ct == SwDefine.CircuitComponentType.WIRE_STRAIGHT \
		or ct == SwDefine.CircuitComponentType.WIRE_BENT \
		or ct == SwDefine.CircuitComponentType.WIRE_BRIDGE \
		or ct == SwDefine.CircuitComponentType.WIRE_TUNNEL


## 获取建筑的 CircuitComponentType 枚举名称（字符串）
func _get_comp_type_str(build: SWBuildItemDefine) -> String:
	if build == null or build.buildDefine == null:
		return "NONE"
	var ct: int = build.buildDefine.circuit_component_type
	match ct:
		SwDefine.CircuitComponentType.NONE: return "NONE"
		SwDefine.CircuitComponentType.BUTTON: return "BUTTON"
		SwDefine.CircuitComponentType.SWITCH: return "SWITCH"
		SwDefine.CircuitComponentType.CLOCK: return "CLOCK"
		SwDefine.CircuitComponentType.LED: return "LED"
		SwDefine.CircuitComponentType.WIRE: return "WIRE"
		SwDefine.CircuitComponentType.WIRE_STRAIGHT: return "WIRE_STRAIGHT"
		SwDefine.CircuitComponentType.WIRE_BENT: return "WIRE_BENT"
		SwDefine.CircuitComponentType.WIRE_BRIDGE: return "WIRE_BRIDGE"
		SwDefine.CircuitComponentType.NOT_GATE: return "NOT_GATE"
		SwDefine.CircuitComponentType.WIRE_TUNNEL: return "WIRE_TUNNEL"
		SwDefine.CircuitComponentType.AND_GATE: return "AND_GATE"
		SwDefine.CircuitComponentType.ONE_BIT_REGISTER: return "ONE_BIT_REGISTER"
		_: return "NONE"


## 按 id 查找建筑
func _find_build_by_id(builds: Array, bid: int) -> SWBuildItemDefine:
	for build in builds:
		if build.id == bid:
			return build
	return null


## 计算参考方向经机身旋转后的世界方向
func _world_dir(build: SWBuildItemDefine, ref_dir: int) -> int:
	return posmod(ref_dir + build.rotation, 4)
