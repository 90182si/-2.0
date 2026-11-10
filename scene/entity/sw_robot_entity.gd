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
# 实体种类："robot"（跟节拍跑电路）/ "box"（箱子，只占格可被推，没有电路）
# 两种共用这一套类：位置/占格/渲染代理/动画都是同一套代码，
# 区别只在 bundle 恒为 null（箱子自然被节拍跳过）与 kind 判定
var kind: String = "robot":
	set(v):
		kind = v
		is_box = (v == "box")
# 是不是箱子。为什么单独存一份 bool：动作派发/批量检测每拍要判上万次，
# 字符串 == 每次都要走一遍比较（同长不同内容还得逐字节比），换成 bool 就是一次读
var is_box: bool = false
# 最近一次检测结果：8 项，下标 = **绝对方向**（0 北、2 东、4 南、6 西），值是 8 位检测码
# （bit4..0 物品码、bit7..5 方向码；常量与编解码见 sw_robot_actions.gd）
# ⚠ 只有逐台路径（台数 < BATCH_MIN）会每拍刷它。上万台的批量路径每拍只算电路选中的
# 那一个方向（扫 8 格是 8 次占格查询/台，实测 127ms/拍），要全表请调
# SWEntityLayerSystem.detect_around(e) 现算 —— 存档/HUD 都不读这个字段
var last_detect: Array = []
# 时序图额外轨道：要监测的信号名（push、detect_sig_* 、detect_res_* 、clk ...）。
# 两种来源：
#   - 自动模式（trace_names_manual = false）：绑定电路里除 move/rotation 之外的输出名
#   - 手动模式：玩家在时序面板里用勾选菜单自选的清单
# 名字一变就清波形：旧样本的位图是按旧名字算的，留着会把电平画错轨
const TRACE_CAP: int = 16
var trace_names: Array[String] = []
# 清单是不是玩家自己选的（false = 自动跟绑定电路走）
var trace_names_manual: bool = false
# 与 timing 一一对应的电平位图：第 k 位 = trace_names[k] 本条样本的电平。
# 为什么不用字典：一拍两张、每张十几个名字，字典太贵；位图一个 int 就装下了
var trace_masks: Array = []
# 与 trace_names 一一对应的读法：1 = 输出口、2 = 输入口、0 = 电路里没这个口（恒低）。
# 缓存原因：位图每半拍算一次，原实现每个名字都要 has_output + has_input 各查一次，
# 多电路 bundle 的每次查询还要过索引 —— 几十台机器人时纯属白烧
var _trace_flags: PackedByteArray = PackedByteArray()
# 是否落时序样本：时序图一次只看一台，上万台时每台每半拍都 append + 算位图
# 是完全白烧（实体系统的 TRACE_FULL_LIMIT 只管前几台，HUD 观测到哪台就开哪台）
var trace_active: bool = true
# 时序样本上限（一拍两条，即 160 拍，约 40 秒历史）：
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
# .swcir 加载产物（单电路是 SWCircuitBundle，多电路是 SWCircuitSet；接口同名），没绑定电路时为 null
var bundle = null
# 批量求值上下文（上万台时几十台各自 tick 撑不住，改走位平面）。
# 非 null 时：bundle 只是个**共享模板**（只读名字/接口，从不 tick），
# 本台的输入/寄存器状态全在 batch_grp 的第 batch_bit 位上
var batch_grp = null
var batch_bit: int = -1
# 绑定的电路文件名（面板显示 / 存档用，不含扩展名）
var circuit_file: String = ""
# 渲染代理：一个只画不参与电路的建筑定义克隆（由实体系统创建并维护）
var draw_item: SWBuildItemDefine = null
# 动画层的行号（-1 = 还没被接管）。为什么把行号存在实体上而不是视觉层用
# Dictionary[instance_id] 查：移动每拍要问一万次「这台归哪一行」，
# get_instance_id() + 对象键字典查合计约 600ns/次，一万台就是 6ms/拍；
# 存成字段后就是一次整数读
var anim_row: int = -1
# 是否还在实体层里（删掉/清场后置 false）。
# 为什么不用「查占格表里是不是还是它」：低相位一拍一万台都要验一次，
# 字典查 + Vector2i 哈希约 500ns/次；一个 bool 字段读只要 5ns
var alive: bool = true
# 是否已从烘焙层撤下（动画层接管后恒 true，不再交还）。
# 同样从 Dictionary 换成 bool：一拍一万台都要先问一次「撤了吗」
var render_detached: bool = false
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
	_sync_trace_names()
	#名字可能没变但电路换了：读法（输出/输入/没有）得重算
	_rebuild_trace_flags()

# 设置要监测的信号清单（时序面板的「添加 / 删除」调它）。
# 传空 = 回到自动模式（把电路里 move/rotation 之外的输出名全画出来）
func set_trace_signals(names) -> void:
	var list: Array[String] = _clean_trace_names(names)
	var manual: bool = not list.is_empty()
	if manual == trace_names_manual and list == trace_names:
		return
	trace_names_manual = manual
	var target: Array[String] = list if manual else _auto_trace_names()
	if target != trace_names:
		trace_names = target
		clear_timing()
	_rebuild_trace_flags()

# 自动模式下的清单：绑定电路里除 move/rotation 之外的输出名
func _auto_trace_names() -> Array[String]:
	var names: Array[String] = []
	if bundle == null or not bundle.has_method("output_names"):
		return names
	for n in bundle.output_names():
		var s: String = str(n)
		#move/rotation 已经是固定基础轨，不再重复画
		if s == "move" or s == "rotation":
			continue
		if names.size() >= TRACE_CAP:
			break
		names.append(s)
	return names

# 换电路后同步清单：手动模式保留玩家选的（电路里没这名字就是恒低电平，玩家自己删）
func _sync_trace_names() -> void:
	var target: Array[String] = trace_names.duplicate() if trace_names_manual else _auto_trace_names()
	if target == trace_names:
		return
	trace_names = target
	clear_timing()

# 过滤信号名：去空 / 去重 / 去掉已经是固定轨的名字（clk/move/rotation/act）/ 封顶 TRACE_CAP
func _clean_trace_names(names) -> Array[String]:
	var out: Array[String] = []
	if names == null:
		return out
	for v in names:
		var s: String = str(v)
		if s.is_empty() or s == "clk" or s == "move" or s == "rotation" or s == "act":
			continue
		if out.has(s):
			continue
		if out.size() >= TRACE_CAP:
			break
		out.append(s)
	return out

func has_bundle() -> bool:
	return bundle != null

# 渲染代理换位置/朝向：坐标由调用方写（分区块表按格子下标存，必须走系统重新入表）
func set_facing(new_dir: int) -> void:
	dir = posmod(new_dir, 4)
	if draw_item != null:
		draw_item.rotation = dir

func describe() -> String:
	return "%s pos=%s dir=%d circuit=%s" % [
		kind, str(grid_pos), dir, circuit_file if not circuit_file.is_empty() else "<none>" ]

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
	if not trace_active:
		return
	timing.append(sample)
	#额外轨道与本条样本一起落位：位图在第 k 位记 trace_names[k] 的电平（没额外轨就是 0）
	trace_masks.append(_out_mask() if not trace_names.is_empty() else 0)
	timing_seq += 1
	#超出上限就丢最老的一条（320 条的 O(n) 位移，一拍才一次，可以忽略）
	if timing.size() > TIMING_CAP:
		timing.pop_front()
		if not trace_masks.is_empty():
			trace_masks.pop_front()

#当前时刻某个监测信号的读法（1 = 输出口、2 = 输入口、0 = 电路里没这个口）
func _trace_flags_of(name: String) -> int:
	if bundle == null:
		return 0
	if bundle.has_output(name):
		return 1
	if bundle.has_input(name):
		return 2
	return 0

#重建读法缓存（换电路 / 换清单时各调一次）
func _rebuild_trace_flags() -> void:
	_trace_flags = PackedByteArray()
	_trace_flags.resize(trace_names.size())
	for k in trace_names.size():
		_trace_flags[k] = _trace_flags_of(trace_names[k])

#当前时刻额外轨道的电平位图：第 k 位 = trace_names[k]
func _out_mask() -> int:
	var m: int = 0
	if bundle == null:
		return 0
	var cnt: int = mini(trace_names.size(), _trace_flags.size())
	for k in cnt:
		var f: int = _trace_flags[k]
		var lv: int = 0
		if f == 1:
			lv = bundle.output_level(trace_names[k])
		elif f == 2:
			lv = bundle.input_level(trace_names[k])
		if lv != 0:
			m |= 1 << k
	return m

func clear_timing() -> void:
	timing.clear()
	trace_masks.clear()
	timing_seq = 0
	timing_beats = 0
