class_name SWNetlist extends RefCounted

# ==========================================================================
# 纯数据网表（SimCore S1 落地件）：仿真层的唯一输入，**不含任何实体引用**。
#
# 为什么需要它：求值内核（SWGateProgram + 引擎）本来就只吃整数数组，但「拓扑从哪来」
# 一直长在建筑/组件对象上（组件 pinNetMap、net._driverComps、buildArr…），
# 所以整条链路仍然必须先有一份世界实体才能开始算（见 docs/SimCore框架设计文档.md §2.1）。
# SWNetlist 把拓扑抽成纯整数表：导出一次之后，编译 / 求值 / 回填都只读它。
#
# 布局（全部 PackedInt32Array，下标即 id；表长约定写在字段注释里）：
#   dev_*        ：元件表（一台元件一行，按导出顺序，与实体路径的 comp 顺序一致）
#   net_ids[i]   ：第 i 根 net 的全局 netId（**升序**，i 即 net slot）
#   net_driver_* ：每根 net 的驱动者（dev 下标，顺序 = 导线建立顺序）
#   net_load_*   ：每根 net 的负载（dev 下标）
#
# 与实体的关系：实体只在导出时读一次（见 sw_netlist_export.gd）。
# 本文件刻意不 import 任何 SWBuild* / SWNet 类型，保证仿真层可以脱离游戏世界单测。
# ==========================================================================

# 元件类型：只影响「它在布尔算子表里扮演什么角色」，与具体建筑定义无关
const DEV_UNKNOWN := 0
const DEV_SOURCE := 1   # 外部输入（时钟 / 按钮 / 开关）：电平由边界层写入
const DEV_NOT := 2      # 非门：输出 = ~输入
const DEV_AND := 3      # 其它组合驱动：输出 = AND(全部输入 net)
const DEV_REG := 4      # 寄存器：Q 由帧边界锁存 pass 写
const DEV_LED := 5      # 灯泡：只读输入（亮灭 = OR(输入 net)），不驱动任何 net

# 接口角色（.swcir 用）：标出「这个 dev 是电路对外的接口」
const ROLE_INTERNAL := 0   # 内部元件
const ROLE_INPUT := 1     # 外部输入接口：电平由边界层写入（写入口）
const ROLE_OUTPUT := 2    # 外部输出接口：边界层读它相连 net 的电平（读出口）

# ===== 元件表 =====
var dev_kind := PackedInt32Array()
# 世界方向的端口掩码（bit(dir) = 1 表示该方向是输出/输入口）
var dev_out_mask := PackedInt32Array()
var dev_in_mask := PackedInt32Array()
# 方向 d 所连 net 的 netId（-1 = 未连）：4 个/元件，下标 dev * 4 + d
var dev_pins := PackedInt32Array()
# 寄存器的 clk / d 输入 netId（已按旋转算成世界方向；-1 = 未连）
var dev_clk_net := PackedInt32Array()
var dev_d_net := PackedInt32Array()

# ===== 接口元数据（.swcir 导出/回放用；纯整数表，与上面同风格） =====
# 角色：0 = 内部，1 = 外部输入接口，2 = 外部输出接口（下标 = dev）
var dev_role := PackedInt32Array()
# 接口名在 name_table 里的下标（-1 = 无名字）
var dev_label := PackedInt32Array()
var name_table := PackedStringArray()

# ===== net 表 =====
var net_ids := PackedInt32Array()
# 驱动者 / 负载（CSR：offs 长度 = net_count + 1）
var net_driver_flat := PackedInt32Array()
var net_driver_offs := PackedInt32Array()
var net_load_flat := PackedInt32Array()
var net_load_offs := PackedInt32Array()

# ===== 便捷索引（导出时填，只读使用） =====
var src_devs := PackedInt32Array()   # 外部输入元件
var led_devs := PackedInt32Array()   # 灯泡元件
var reg_devs := PackedInt32Array()   # 寄存器元件
var net_id_to_index := {}            # netId -> net 下标（= net slot）

# 构造期累加缓冲（finalize 之后不再使用）
var _drv: Array = []
var _ld: Array = []


func dev_count() -> int:
	return dev_kind.size()


func net_count() -> int:
	return net_ids.size()


# 方向 dir 所连的 netId（-1 = 未连）
func pin_net(dev: int, dir: int) -> int:
	var i: int = dev * 4 + dir
	if i < 0 or i >= dev_pins.size():
		return -1
	return dev_pins[i]


func driver_count(ni: int) -> int:
	if ni < 0 or ni + 1 >= net_driver_offs.size():
		return 0
	return net_driver_offs[ni + 1] - net_driver_offs[ni]


func driver_dev(ni: int, k: int) -> int:
	var i: int = net_driver_offs[ni] + k
	if i < 0 or i >= net_driver_flat.size():
		return -1
	return net_driver_flat[i]


# ===== 构造 API（导出器与测试用） =====
func add_device(kind: int, out_mask: int, in_mask: int) -> int:
	dev_kind.append(kind)
	dev_out_mask.append(out_mask)
	dev_in_mask.append(in_mask)
	for d in 4:
		dev_pins.append(-1)
	dev_clk_net.append(-1)
	dev_d_net.append(-1)
	dev_role.append(ROLE_INTERNAL)
	dev_label.append(-1)
	var dev: int = dev_kind.size() - 1
	if kind == DEV_SOURCE:
		src_devs.append(dev)
	elif kind == DEV_LED:
		led_devs.append(dev)
	elif kind == DEV_REG:
		reg_devs.append(dev)
	return dev


func set_pin(dev: int, dir: int, net_id: int) -> void:
	var i: int = dev * 4 + dir
	if i >= 0 and i < dev_pins.size():
		dev_pins[i] = net_id


func set_reg_pins(dev: int, clk_net_id: int, d_net_id: int) -> void:
	if dev >= 0 and dev < dev_clk_net.size():
		dev_clk_net[dev] = clk_net_id
		dev_d_net[dev] = d_net_id


# 登记一个接口名（同名复用），返回 name_table 下标
func add_label(name: String) -> int:
	var i: int = name_table.find(name)
	if i >= 0:
		return i
	name_table.append(name)
	return name_table.size() - 1


# 把某个 dev 标成对外接口（role 取 ROLE_*，label 用 add_label 的返回值）
func set_role(dev: int, role: int, label: int = -1) -> void:
	if dev >= 0 and dev < dev_role.size():
		dev_role[dev] = role
		dev_label[dev] = label


func role_of(dev: int) -> int:
	if dev < 0 or dev >= dev_role.size():
		return ROLE_INTERNAL
	return dev_role[dev]


# 接口名（没有名字返回空串）
func label_name(dev: int) -> String:
	if dev < 0 or dev >= dev_label.size():
		return ""
	var li: int = dev_label[dev]
	if li < 0 or li >= name_table.size():
		return ""
	return name_table[li]


# 某个 dev 当前相连的全部 netId（去重，升序）—— 接口的「读出口」就是这些 net
func nets_of(dev: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for d in 4:
		var nid: int = pin_net(dev, d)
		if nid < 0 or out.has(nid):
			continue
		out.append(nid)
	out.sort()
	return out


# ===== 序列化（.swcir 的 netlist 段）=====
# 全部是整数/字符串扁平表，直接 JSON 化；JSON 数字回读是浮点，所以 from_dict 逐个 int()
func to_dict() -> Dictionary:
	return {
		"dev_kind": Array(dev_kind),
		"dev_out_mask": Array(dev_out_mask),
		"dev_in_mask": Array(dev_in_mask),
		"dev_pins": Array(dev_pins),
		"dev_clk_net": Array(dev_clk_net),
		"dev_d_net": Array(dev_d_net),
		"dev_role": Array(dev_role),
		"dev_label": Array(dev_label),
		"name_table": Array(name_table),
		"net_ids": Array(net_ids),
		"net_driver_flat": Array(net_driver_flat),
		"net_driver_offs": Array(net_driver_offs),
		"net_load_flat": Array(net_load_flat),
		"net_load_offs": Array(net_load_offs),
	}


static func from_dict(d: Dictionary) -> SWNetlist:
	var nl := SWNetlist.new()
	nl.dev_kind = _i32(d.get("dev_kind", []))
	nl.dev_out_mask = _i32(d.get("dev_out_mask", []))
	nl.dev_in_mask = _i32(d.get("dev_in_mask", []))
	nl.dev_pins = _i32(d.get("dev_pins", []))
	nl.dev_clk_net = _i32(d.get("dev_clk_net", []))
	nl.dev_d_net = _i32(d.get("dev_d_net", []))
	nl.dev_role = _i32(d.get("dev_role", []))
	nl.dev_label = _i32(d.get("dev_label", []))
	nl.name_table = PackedStringArray(d.get("name_table", []))
	nl.net_ids = _i32(d.get("net_ids", []))
	nl.net_driver_flat = _i32(d.get("net_driver_flat", []))
	nl.net_driver_offs = _i32(d.get("net_driver_offs", []))
	nl.net_load_flat = _i32(d.get("net_load_flat", []))
	nl.net_load_offs = _i32(d.get("net_load_offs", []))
	#兼容只有老字段（没有 dev_role/dev_label）的文件：补齐到 dev 数，否则按下标访问会越界
	while nl.dev_role.size() < nl.dev_kind.size():
		nl.dev_role.append(ROLE_INTERNAL)
	while nl.dev_label.size() < nl.dev_kind.size():
		nl.dev_label.append(-1)
	#便捷索引重建（net_id_to_index 是 slot 反查表，编译与运行时都要用）
	nl.net_id_to_index = {}
	for i in nl.net_ids.size():
		nl.net_id_to_index[nl.net_ids[i]] = i
	for dev in nl.dev_kind.size():
		var k: int = nl.dev_kind[dev]
		if k == DEV_SOURCE:
			nl.src_devs.append(dev)
		elif k == DEV_LED:
			nl.led_devs.append(dev)
		elif k == DEV_REG:
			nl.reg_devs.append(dev)
	return nl


static func _i32(arr) -> PackedInt32Array:
	var out := PackedInt32Array()
	for v in arr:
		out.append(int(v))
	return out

# 必须按 netId 升序调用：net 下标就是 slot（与实体路径「按 netId 升序分配 slot」一致）
func add_net(net_id: int) -> int:
	net_ids.append(net_id)
	net_id_to_index[net_id] = net_ids.size() - 1
	_drv.append([])
	_ld.append([])
	return net_ids.size() - 1


func add_driver(ni: int, dev: int) -> void:
	if ni >= 0 and ni < _drv.size():
		(_drv[ni] as Array).append(dev)


func add_load(ni: int, dev: int) -> void:
	if ni >= 0 and ni < _ld.size():
		(_ld[ni] as Array).append(dev)


# 把构造期 Array 缓冲压成 CSR 平坦表（之后本网表只读）
func finalize() -> void:
	var n: int = net_ids.size()
	net_driver_flat = PackedInt32Array()
	net_driver_offs = PackedInt32Array()
	net_load_flat = PackedInt32Array()
	net_load_offs = PackedInt32Array()
	net_driver_offs.resize(n + 1)
	net_load_offs.resize(n + 1)
	for ni in n:
		net_driver_offs[ni] = net_driver_flat.size()
		for dv in _drv[ni]:
			net_driver_flat.append(int(dv))
		net_load_offs[ni] = net_load_flat.size()
		for lv in _ld[ni]:
			net_load_flat.append(int(lv))
	net_driver_offs[n] = net_driver_flat.size()
	net_load_offs[n] = net_load_flat.size()


# 诊断：网表规模摘要（测试/日志用）
func describe() -> String:
	var ios: int = 0
	for dev in dev_role.size():
		if dev_role[dev] != ROLE_INTERNAL:
			ios += 1
	return "netlist dev=%d net=%d src=%d led=%d reg=%d io=%d drv=%d" % [
		dev_count(), net_count(), src_devs.size(), led_devs.size(),
		reg_devs.size(), ios, net_driver_flat.size()
	]
