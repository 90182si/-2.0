class_name SWCircuitBundle extends RefCounted

# ==========================================================================
# .swcir 的加载产物：一份**不依赖任何建筑实体**的可运行电路。
#
# 里外两层：
#   外：名称接口（clk / move / rotation → 写入源槽 / 读取 net 槽）
#   里：prog（compile_netlist 的产物）+ SWLogicRuntime（自持状态）
#
# 为什么要它：机器人场景没有电路层，拿不到 SWBuildCompoentCircuit / SWNet；
# 但 SWNetlist → SWGateCompiler.compile_netlist → SWLogicRuntime 这条链本来就只吃整数表，
# 所以「导出一次、离线跑很多次」是免费的。
#
# 槽位约定（与实体路径完全一致，靠 compile_netlist 保证）：
#   - 输入：prog.dev_slots[dev] 就是该源元件的 slot；src_levels 的下标是
#     prog.input_slots.find(slot)，即「第几个源」，与 SWLogicRuntime.set_source(i, lv) 同序
#   - 输出：net 的 slot = prog.net_id_to_slot[netId]；多个端口相连时按 OR 汇聚
#     （与灯泡「任一输入为高即亮」同口径）
# ==========================================================================

# 编译产物与状态机
var netlist: SWNetlist = null
var prog: SWGateProgram = null
var runtime: SWLogicRuntime = null

# name -> 源序号（喂给 SWLogicRuntime.set_source）；-1 = 该接口没接到任何 net
var input_slots: Dictionary = {}
# name -> PackedInt32Array（net slot 列表）；空 = 没读到任何 net
var output_slots: Dictionary = {}

# name -> netlist 里的 dev 下标（排障与存档回放用）
var dev_of_input: Dictionary = {}
var dev_of_output: Dictionary = {}
# 这个 bundle 是否**纯组合**（没有寄存器）：纯组合只要输入没变，重算必然同结果
var _stateless: bool = false
# 输入自上次 tick 以来是否真的变过（纯组合靠它跳过无意义的重算）
var _src_dirty: bool = true
# 上面两个清单的排序缓存（见 input_names / output_names）
var _names_in: Array = []
var _names_out: Array = []


# ins / outs 的元素：{"name": String, "dev": int}
# （.swcir 里解析出来的接口表；dev 是该电路 netlist 里元件表的下标）
# src_levels 的元素：{"dev": int, "level": int}，源元件的初始电平（可省略）
#
# 注意：这是**实例方法**而不是 static —— 新建脚本的 class_name 此刻还不在全局类缓存里，
# 本文件内部也不能按类名 new 自己（会 Identifier not found）。由调用方 preload 后 .new()
func setup_from_netlist(nl: SWNetlist, ins: Array, outs: Array, src_levels: Array = []) -> void:
	netlist = nl
	prog = SWGateCompiler.new().compile_netlist(nl)
	runtime = SWLogicRuntime.new()
	runtime.setup(prog)
	for e in ins:
		var name: String = str(e.get("name", ""))
		var dev: int = int(e.get("dev", -1))
		if name.is_empty() or dev < 0:
			continue
		dev_of_input[name] = dev
		input_slots[name] = _source_index_of(dev)
	# 源初始电平：没有这一段的老文件全部按 0 起（与历史行为一致）
	for e in src_levels:
		set_source_level(int(e.get("dev", -1)), int(e.get("level", 0)))
	for e in outs:
		var oname: String = str(e.get("name", ""))
		var odev: int = int(e.get("dev", -1))
		if oname.is_empty() or odev < 0:
			continue
		dev_of_output[oname] = odev
		output_slots[oname] = _net_slots_of(odev)
	#有没有寄存器决定了能不能走「输入没变就不重算」的快路径
	_stateless = prog.reg_slots.is_empty()
	_src_dirty = true


# ===== 接口查询 =====
func has_input(name: String) -> bool:
	return input_slots.has(name)


func has_output(name: String) -> bool:
	return output_slots.has(name)


# 名字清单缓存：每拍都要问一次（实体层收集高电平输出名、算时序额外轨），
# 而 keys()+sort() 是每次都新建数组，没必要；返回的数组**调用方只读、不要改**
func input_names() -> Array:
	if _names_in.is_empty() and not input_slots.is_empty():
		_names_in = input_slots.keys()
		_names_in.sort()
	return _names_in


func output_names() -> Array:
	if _names_out.is_empty() and not output_slots.is_empty():
		_names_out = output_slots.keys()
		_names_out.sort()
	return _names_out


# ===== 命令入 / 结果出 =====
# 写输入电平；名字不存在或该接口没接 net 时静默忽略（面板会先校验接口齐不齐）
func set_input(name: String, level: int) -> void:
	var i: int = int(input_slots.get(name, -1))
	if i < 0:
		return
	var v: int = 1 if level != 0 else 0
	#只有真的变了才置脏：纯组合子电路靠这个跳过「输入没动还重算」
	if runtime.src_levels[i] != v:
		_src_dirty = true
	runtime.set_source(i, v)


# 读回当前写入的输入电平（0/1，调试用）
func input_level(name: String) -> int:
	var i: int = int(input_slots.get(name, -1))
	if i < 0 or i >= runtime.src_levels.size():
		return 0
	return runtime.src_levels[i]


# 按 netlist 的 dev 下标写源电平（读档时灌初值用；不是源的 dev 静默忽略）
func set_source_level(dev: int, level: int) -> void:
	if runtime == null or prog == null:
		return
	_src_dirty = true
	runtime.set_source(_source_index_of(dev), level)


# 寄存器 Q 的一行摘要（排障打印用，高位在后）：没寄存器返回 "-"
func reg_q_text() -> String:
	if runtime == null or runtime.reg_state.is_empty():
		return "-"
	var parts := PackedStringArray()
	var i: int = runtime.reg_state.size() / 2 - 1
	while i >= 0:
		parts.append(str(runtime.reg_state[i * 2]))
		i -= 1
	return "".join(parts)


func tick() -> SWSimResult:
	_src_dirty = false
	return runtime.tick()


# 只推进状态、不打包差分结果（机器人每拍跑两次 tick 走它：没人读结果，
# 但 tick() 要扫全部 net/灯泡/寄存器，几十台机器人时是纯浪费）。
# 纯组合（无寄存器）且输入自上次 tick 后没变过 → 直接跳过：
#   一个 .swcir 常带十几条分组（用户实测 17 条），多数是「开关 -> detect_sig_k」
#   这类组合分组；一拍两个相位里只有高相位前写过输入，低相位那次重算必然同结果。
# 寄存器电路不吃这套（时间与锁存要推进），照旧每相位 tick。
func tick_fast() -> void:
	if runtime == null:
		return
	if _stateless and not _src_dirty:
		return
	runtime.tick_fast()
	_src_dirty = false


# 读输出电平（0/1）：所连 net 任一为高即 1
func output_level(name: String) -> int:
	var slots = output_slots.get(name, null)
	if slots == null:
		return 0
	var vals: PackedInt32Array = runtime.slot_vals
	for s in slots:
		if s >= 0 and s < vals.size() and vals[s] != 0:
			return 1
	return 0


# 批量读：返回位图，第 i 位 = names[i] 的输出电平。
# 机器人每拍要读 move/rotation/push（开时序时还有十几条监测轨），
# 逐个 output_level 就是 N 次函数调用 + N 次「名字 -> slot」查表，这里一次循环搞定
func read_output_bits(names: Array) -> int:
	var m: int = 0
	if runtime == null:
		return 0
	var vals: PackedInt32Array = runtime.slot_vals
	var n: int = vals.size()
	for i in names.size():
		var slots = output_slots.get(str(names[i]), null)
		if slots == null:
			continue
		for s in slots:
			if s >= 0 and s < n and vals[s] != 0:
				m |= 1 << i
				break
	return m


# 批量写位：names[i] 对应的输入口写 (code >> (bit_base - i)) & 1。
# 机器人每拍要写 8 个 detect_res 口（编号小的在左 = 高位），
# 改成一次循环比 8 次 set_input 省掉一大半函数调用与查表
func write_input_bits(names: Array, code: int, bit_base: int) -> void:
	if runtime == null:
		return
	var levels: PackedInt32Array = runtime.src_levels
	var n: int = levels.size()
	for i in names.size():
		var s: int = int(input_slots.get(str(names[i]), -1))
		if s < 0 or s >= n:
			continue
		var v: int = (code >> (bit_base - i)) & 1
		if levels[s] != v:
			levels[s] = v
			_src_dirty = true


# 复位到上电态（换了绑定电路 / 重新开始时用）
func reset() -> void:
	_src_dirty = true
	if runtime != null:
		runtime.reset()


func describe() -> String:
	return "bundle in=%s out=%s %s" % [
		str(input_names()), str(output_names()),
		netlist.describe() if netlist != null else "netlist=null"]


# ===== 内部 =====
# dev → 源序号（src_levels 的下标）；不是「驱动了 net 的源」返回 -1
func _source_index_of(dev: int) -> int:
	if prog == null or dev < 0 or dev >= prog.dev_slots.size():
		return -1
	var slot: int = prog.dev_slots[dev]
	if slot < 0:
		return -1
	return prog.input_slots.find(slot)


# dev 所连 net → net slot 列表（不在本电路里的 net 直接跳过）
func _net_slots_of(dev: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if prog == null or netlist == null:
		return out
	for nid in netlist.nets_of(dev):
		var s: int = int(prog.net_id_to_slot.get(nid, -1))
		if s >= 0:
			out.append(s)
	return out
