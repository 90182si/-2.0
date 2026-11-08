class_name SWRobotEntity extends RefCounted

# ==========================================================================
# 机器人实体数据（纯数据 + 纯几何，不碰场景树、不碰渲染）
#
# 位置与朝向是**权威状态**，渲染只是跟着它刷：
#   - grid_pos：世界格子坐标（SwCommon.GetGridPos 口径，即 GRID_SIZE 的整数倍）
#   - dir：0..3 朝向，与 SwDefine.dir_to_vec 同序（0=上 1=右 2=下 3=左）
#   - bundle：绑定的 .swcir 电路（可为空 = 没接线，节拍里不会动）
#
# 「越界/被占则不动」的占用判定由实体系统注入 blocked_probe（格子查询外包），
# 这样本文件不依赖任何实体层/建筑表，纯逻辑测试直接 new 就能跑。
# ==========================================================================

var grid_pos: Vector2i = Vector2i.ZERO
var dir: int = 0
# 时序图样本上限（一拍两条，即 160 拍，约 40 秒历史）：
# 不封顶的话挂一晚上会无限长
const TIMING_CAP: int = 320
# 时序图样本：每条 Vector4i(clk, move, rotation, acted)，最新的在末尾。
# 一拍落两条：高相位（clk=1，电路收到时钟沿）+ 低相位（clk=0，拍末回落）。
# 只记高相位的话 clk 轨永远是 1，看不出「0 的那段」，波形也不像时钟。
# 只给界面看，不进存档；acted = 本拍真的动了/转了（输出=1 但被挡住时为 0）
var timing: Array = []
# 采样序号：每条样本 +1。界面靠它判断「有没有新样本」：
# 两拍输出完全一样时，单看末条会漏掉一次滚动
var timing_seq: int = 0
# 拍数（= timing_seq / 2，单独记一份免得界面自己除）
var timing_beats: int = 0
# .swcir 加载产物（SWCircuitBundle），没绑定电路时为 null
var bundle = null
# 绑定的电路文件名（面板显示 / 存档用，不含扩展名）
var circuit_file: String = ""
# 渲染代理：一个只画不参与电路的建筑定义克隆（由实体系统创建并维护）
var draw_item: SWBuildItemDefine = null
# 目标格是否不许进（被别的实体占住）：由实体系统注入，空 Callable = 不校验
var blocked_probe: Callable = Callable()

func _init(pos: Vector2i = Vector2i.ZERO, d: int = 0) -> void:
	grid_pos = pos
	dir = posmod(d, 4)

# 按当前朝向往前一格（不改状态）。dir_to_vec 给的是单位方向，这里要乘格子边长
func next_cell() -> Vector2i:
	return grid_pos + SwDefine.dir_to_vec(dir) * SwDefine.GRID_SIZE

# 格子下标（grid_pos 除以格子边长）：面板标题与日志里显示这个，直接印 world 坐标不直观
func cell() -> Vector2i:
	return grid_pos / SwDefine.GRID_SIZE

# 这一格能不能进
func can_step() -> bool:
	if not blocked_probe.is_valid():
		return true
	return not bool(blocked_probe.call(next_cell()))

# 前进一格；被挡就原地不动并返回 false
func step_forward() -> bool:
	if not can_step():
		return false
	grid_pos = next_cell()
	return true

# 顺时针转 90°（times 可一次转多格）
func rot90(times: int = 1) -> void:
	dir = posmod(dir + times, 4)

# 绑定/解绑电路（加载在实体系统或面板里做，这里只接管结果）
func set_bundle(b, file_name: String = "") -> void:
	bundle = b
	circuit_file = file_name if b != null else ""

func has_bundle() -> bool:
	return bundle != null

# 渲染代理换位置/朝向：坐标由调用方写（分区块表按格子下标存，必须走系统重新入表）
func set_facing(new_dir: int) -> void:
	dir = posmod(new_dir, 4)
	if draw_item != null:
		draw_item.rotation = dir

func describe() -> String:
	return "robot pos=%s dir=%d circuit=%s" % [
		str(grid_pos), dir, circuit_file if not circuit_file.is_empty() else "<none>"]

# 时序图样本（一拍两条，一条一个时间点）：
#   上升沿相位（clk 0->1，电路刚锁存）：push_phase_high
#   下降沿相位（clk 1->0，半拍后，动作在这一相位执行）：push_phase_low
# 两个相位**分两次落盘**，时序图的红线才会一格一格地走，
# 上升沿和下降沿都能依次流到红线位置；一次写两条的话红线一拍跳两格，
# 看上去永远停在上升沿上、下降沿被跳过。
# move/rotation 两条相同（本拍的输出结果，整拍内不变）；acted 只有低相位那条有值。
#上升沿相位（clk 0->1，电路刚锁存）：只落高相位样本。
#act 此刻必然是 0：动作要到下降沿相位才执行。
func push_phase_high(mv: int, rot: int) -> void:
	_append_timing(Vector4i(1, mv, rot, 0))

#下降沿相位（clk 1->0，拍末回落）：落低相位样本，拍数在这里才算完。
func push_phase_low(mv: int, rot: int, acted: int) -> void:
	_append_timing(Vector4i(0, mv, rot, acted))
	timing_beats += 1

#一拍两条一起写：两条的 move/rotation/acted 完全相同。
#仅供测试 / 一次性口径；实时节拍走 push_phase_high + push_phase_low（分两个时间点），
#这样红线才会逐格推进（一次写两条则一拍跳两格，看着像下降沿被跳过）。
func push_beat(mv: int, rot: int, acted: int) -> void:
	_append_timing(Vector4i(1, mv, rot, acted))
	_append_timing(Vector4i(0, mv, rot, acted))
	timing_beats += 1

# 直接写一条样本（clk = 本拍写入的电平）：底层接口，仅供测试/特殊场景
func push_timing(clk: int, mv: int, rot: int, acted: int) -> void:
	_append_timing(Vector4i(clk, mv, rot, acted))

func _append_timing(sample: Vector4i) -> void:
	timing.append(sample)
	timing_seq += 1
	#超出上限就丢最老的一条（320 条的 O(n) 位移，一拍才一次，可以忽略）
	if timing.size() > TIMING_CAP:
		timing.pop_front()

func clear_timing() -> void:
	timing.clear()
	timing_seq = 0
	timing_beats = 0
