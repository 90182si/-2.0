class_name SWRobotTick extends Node

# ==========================================================================
# 机器人统一节拍驱动器
#
# 机器人场景唯一的时钟：每 PERIOD_SEC 一拍，所有机器人同一拍、同一 clk=1 输入
# 各跑各的电路（各持独立 SWLogicRuntime 状态，互不干扰），一拍内先旋转后移动。
# 具体一拍怎么走由 SWEntityLayerSystem.step_beat() 实现（纯逻辑，可脱离节点测）。
#
# 一拍拆成**两个时间点**发出去（上升沿在拍首、下降沿在半拍）：
# 两个相位各落一条时序图样本，红线才会一格一格地走，上升沿和下降沿
# 都能依次流到红线位置。合成一次发的话红线一拍跳两格，看上去永远停在上升沿。
#
# 为什么在 _physics_process 里累计：SWLogicScene 也是用固定 tick 驱动电路，
# 换成渲染帧会让节拍随帧率抖动；慢帧时按拍补齐但一帧最多补 MAX_STEPS 拍，
# 防止卡顿后一帧里连跳十几格。
# ==========================================================================

const DEFAULT_PERIOD_SEC: float = 0.25
const MAX_STEPS_PER_FRAME: int = 8

#一拍多少秒（默认 250ms；测试可注入更短的节拍加速断言）
@export var period_sec: float = DEFAULT_PERIOD_SEC
#节拍总开关（场景切走/暂停调试时可关）
var enabled: bool = true
#实体层系统（由场景根注入；未注入时本节点什么都不做）
var entity_system = null

var _acc: float = 0.0
#下一个事件是不是上升沿相位：一拍两个事件（高/低）交替发
var _next_is_high: bool = true
var beat_count: int = 0
#本节点驱动出的移动次数（排障用）
var moved_total: int = 0

func _physics_process(delta: float) -> void:
	if not enabled or entity_system == null:
		return
	if delta <= 0.0:
		return
	#节拍秒数配成 0 或负数时不发拍，避免死循环
	if period_sec <= 0.0:
		return
	_acc += delta
	var half: float = period_sec * 0.5
	#一拍两个事件，所以预算也要翻倍，否则一帧能补的拍数只剩一半
	var budgets: int = MAX_STEPS_PER_FRAME * 2
	while _acc >= half and budgets > 0:
		_acc -= half
		budgets -= 1
		if _next_is_high:
			_next_is_high = false
			tick_high()
		else:
			_next_is_high = true
			tick_low()
	#补不完的直接丢掉：攒着下一帧继续补只会让卡顿后连续跳格
	if _acc >= half:
		_acc = fmod(_acc, half)

#走一拍：返回本拍实际移动的机器人数。
#一拍两个相位都当场发完（一次跳两格）——只给步进按钮与测试用；
#实时节拍走 tick_high + tick_low，红线才会逐格推进
func tick_once() -> int:
	if entity_system == null:
		return 0
	beat_count += 1
	var moved: int = entity_system.step_beat()
	moved_total += moved
	#一拍已经完整跑完（含低相位），下一个事件应当是下一拍的上升沿
	_next_is_high = true
	_acc = 0.0
	return moved

#上升沿相位（拍首）：电路锁存、读输出、落高相位样本。返回本拍是否真的推进了
func tick_high() -> bool:
	if entity_system == null:
		return false
	beat_count += 1
	entity_system.step_beat_high()
	return true

#下降沿相位（半拍后）：执行本拍动作、落低相位样本。返回本拍实际移动数
func tick_low() -> int:
	if entity_system == null:
		return 0
	var moved: int = entity_system.step_beat_low()
	moved_total += moved
	return moved

#当前半拍跑了多少（0..1）：时序图用它把最新一格从游标往左「长」出来，
#波形才能连续往左流，而不是每半拍猛跳一格。
#停着的时候返回 1：最后一格是完整的，波形不该缩成一条线
func get_phase_frac() -> float:
	if not enabled or period_sec <= 0.0:
		return 1.0
	return clampf(_acc / (period_sec * 0.5), 0.0, 1.0)

#暂停：物理帧不再发拍（时序图的「步进」仍能单拍前进）
func pause() -> void:
	enabled = false
	#攒到一半的时间也清掉：恢复后不该立刻补一拍
	_acc = 0.0
	_next_is_high = true

#恢复自动节拍
func resume() -> void:
	enabled = true
	reset_clock()

func is_running() -> bool:
	return enabled

#单拍前进（时序图「步进」按钮）：先暂停再走一拍，返回本拍实际移动的机器人数；
#返回 -1 表示没绑实体系统。先暂停是为了让它表现成「走一步然后停住」。
func step_once() -> int:
	if entity_system == null:
		return -1
	pause()
	return tick_once()

#重开/换绑时把累计时间清掉（避免立刻补一拍）
func reset_clock() -> void:
	_acc = 0.0
	_next_is_high = true

#绑定实体层系统（由场景根调用；单独实例化时也可以手动接）
func bind_entity_system(sys) -> void:
	entity_system = sys
	reset_clock()

func get_beat_count() -> int:
	return beat_count

#临时改节拍（测试加速用）
func set_period(sec: float) -> void:
	period_sec = maxf(0.0, sec)
	_acc = 0.0
