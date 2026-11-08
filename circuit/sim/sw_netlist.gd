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
	return "netlist dev=%d net=%d src=%d led=%d reg=%d drv=%d" % [
		dev_count(), net_count(), src_devs.size(), led_devs.size(),
		reg_devs.size(), net_driver_flat.size()
	]
