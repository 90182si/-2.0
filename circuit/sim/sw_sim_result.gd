class_name SWSimResult extends RefCounted

# ==========================================================================
# 一拍仿真结果（事件载荷 / 纯数据快照）
#
# 定位：这是「仿真层 → 表现层」的唯一出口。仿真不再直接改 net.curSignal 或渲染组件，
# 而是产出这个结果对象；订阅方（SWCircuitControl 的实体适配、离线工具、测试）自己决定
# 怎么消费。字段全是整数数组，没有一处对象引用，所以可以跨线程 / 存档 / 回放。
#
# 索引口径：
#   slot_vals[i]      ：第 i 个 slot 的值（0/1），长度 ≥ slot_count
#   net_levels[i]     ：第 i 根 net 的电平，下标 = net slot（= prog.net_slots 的值）
#   led_levels[gi]    ：第 gi 个**灯泡组**的亮灭（组划分见 SWGateProgram.led_group_*）
#   reg_state[i*2]    ：第 i 个寄存器的 Q；reg_state[i*2+1]：上次采样到的 clk（-1 = 未对齐）
# ==========================================================================

# 第几拍（从 1 开始）
var tick: int = 0

var slot_vals := PackedInt32Array()
var net_levels := PackedInt32Array()
var led_levels := PackedInt32Array()
var reg_q := PackedInt32Array()
var reg_state := PackedInt32Array()

# 本拍相对上一拍**真的翻了**的下标（差分事件：渲染侧只需要看这几项）
var changed_nets := PackedInt32Array()
var changed_led_groups := PackedInt32Array()
var changed_regs := PackedInt32Array()

# 本拍是否有任何可观测变化（差分全空 = 这一拍对表现层无影响）
var any_change: bool = false


func net_bit(net_slot: int) -> int:
	if net_slot < 0 or net_slot >= net_levels.size():
		return 0
	return net_levels[net_slot]


func reg_q_at(i: int) -> int:
	if i < 0 or i >= reg_q.size():
		return 0
	return reg_q[i]


# 诊断：一拍结果摘要
func describe() -> String:
	return "tick=%d nets=%d changed_nets=%d led_groups=%d changed_led=%d regs=%d changed_reg=%d" % [
		tick, net_levels.size(), changed_nets.size(), led_levels.size(),
		changed_led_groups.size(), reg_q.size(), changed_regs.size()
	]
