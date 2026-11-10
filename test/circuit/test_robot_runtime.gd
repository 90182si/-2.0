extends GutTest
# 机器人实体运行时（SPEC-08 阶段 3 纯逻辑验收，不依赖场景/渲染）
#
# 覆盖点：
#   1. SWRobotEntity 步进/转向/阻挡（纯数据，blocked_probe 外包占用判定）
#   2. SWEntityLayerSystem 放置/占格/删除/换格重入表（渲染代理跟着 authoritative 位置走）
#   3. 单击选中（select_at 走同一张占格表）
#   4. 统一节拍：真实 .swcir bundle 驱动 move/rotation，一拍内先旋转后移动
#   5. SWRobotTick 按 period 发拍、绑系统后可停
#
# 跑法：godot --headless --path . -s addons/gut/gut_cmdln.gd
#       -gdir=res://test/circuit -gprefix=test_robot_runtime -gexit

const ENTITY_SYSTEM := preload("res://scene/entity/sw_entity_layer_system.gd")
const ROBOT_ENTITY := preload("res://scene/entity/sw_robot_entity.gd")
const ROBOT_TICK := preload("res://scene/sw_robot_tick.gd")
const MANAGER := preload("res://circuit/sw_cir_manager.gd")
const BUNDLE := preload("res://circuit/sim/sw_circuit_bundle.gd")

const IN_DEF: SWBuildDefine = preload("res://res/输入接口.tres")
#输出接口已合并为单一定义：move / rotation 只是实例上的 io_name
const OUT_DEF: SWBuildDefine = preload("res://res/输出接口.tres")
const WIRE_DEF: SWBuildDefine = preload("res://res/电线A.tres")
const NOT_DEF: SWBuildDefine = preload("res://res/非门.tres")

const GRID: Vector2i = SwDefine.GRID_SIZE

# 每个用例各用各的电路文件，after_each 统一清掉
const FILE_MOVE := "_robot_beat_move"
const FILE_ROT := "_robot_beat_rot"
const FILE_BOTH := "_robot_beat_both"
const ALL_FILES := [FILE_MOVE, FILE_ROT, FILE_BOTH]

var _sys = null


func before_each() -> void:
	_sys = ENTITY_SYSTEM.new()

func after_each() -> void:
	for n: String in ALL_FILES:
		MANAGER.delete_file(n)
	_sys = null

# 格子坐标 -> 世界坐标（机器人接口一律吃世界坐标）
func _w(cell: Vector2i) -> Vector2i:
	return cell * GRID


# ===== 电路辅助：造一条 clk -> 输出接口 的电路并导出/加载成 bundle =====

# 造电路：specs = [[格子, 定义, 可选 io_name], ...]；返回导出后的 bundle（失败返回 null）
func _make_bundle(file_name: String, specs: Array):
	var mgr := SWBuildManager.new()
	var ctrl := SWCircuitControl.new()
	ctrl.setBuildManager(mgr)
	ctrl.gpu_backend_enabled = false
	var all: Array[SWBuildItemDefine] = []
	for s: Array in specs:
		var build := SwDefine.SWBuildCreator((s[0] as Vector2i) * GRID, s[1], 0)
		#输出接口合并后名字靠实例属性区分（第三个元素写名字）
		if s.size() > 2:
			build.set("io_name", str(s[2]))
		if not mgr.addBuild(build):
			push_error("电路元件放置失败: %s @ %s" % [s[1].buildName, str(s[0])])
			return null
		all.append(build)
	ctrl.updateBuildCircuit(all)
	if MANAGER.export_all(file_name, mgr.getAllBuilds()) == "":
		ctrl.free()
		return null
	var bundle = MANAGER.load_bundle(file_name)
	#SWCircuitControl 是 Node，不释放会在 GUT 报告里留 Orphan
	ctrl.free()
	return bundle

# move = clk、rotation = !clk（纯电线直连 + 一个非门）
# 为什么不能只接一个输出：.swcir 的可用性规则要求 clk/move/rotation 齐全，
# 缺一个就 load_bundle 返回 null，所以用非门把 rotation 按住为 0
func _bundle_move() -> Variant:
	return _make_bundle(FILE_MOVE, [
		[Vector2i(0, 7), IN_DEF],
		[Vector2i(0, 6), WIRE_DEF],
		[Vector2i(1, 6), WIRE_DEF],
		[Vector2i(1, 5), OUT_DEF],
		[Vector2i(0, 5), NOT_DEF],
		[Vector2i(0, 4), OUT_DEF, "rotation"],
	])

# rotation = clk、move = !clk
func _bundle_rot() -> Variant:
	return _make_bundle(FILE_ROT, [
		[Vector2i(0, 7), IN_DEF],
		[Vector2i(0, 6), WIRE_DEF],
		[Vector2i(1, 6), WIRE_DEF],
		[Vector2i(1, 5), OUT_DEF, "rotation"],
		[Vector2i(0, 5), NOT_DEF],
		[Vector2i(0, 4), OUT_DEF],
	])

# move = rotation = clk（一拍里两个输出同时为 1，用来验证「先转后走」）
func _bundle_both() -> Variant:
	return _make_bundle(FILE_BOTH, [
		[Vector2i(0, 5), IN_DEF],
		[Vector2i(0, 4), WIRE_DEF],
		[Vector2i(0, 3), WIRE_DEF],
		[Vector2i(0, 2), WIRE_DEF],
		[Vector2i(0, 1), WIRE_DEF],
		[Vector2i(0, 0), OUT_DEF],
		[Vector2i(1, 1), WIRE_DEF],
		[Vector2i(2, 1), OUT_DEF, "rotation"],
	])


# T 触发器：Q 每拍翻转一次（D = !Q），move = Q，rotation = 悬空 net（恒 0）。
# 为什么用网表直写而不是摆元件：这里要验证的是「一拍里跑了两个时钟相位」，
# 寄存器/非门的引脚朝向要靠具体格子摆位凑，写成整数表更直白、也不依赖渲染。
#
# 这条电路的价值：Q 推不推进直接反映「时钟上升沿到没到」，
# 只看组合电路（clk 直连输出）永远测不出「少跑低相位」这类缺陷。
func _make_toggle_bundle():
	var nl := SWNetlist.new()
	var clk_net: int = nl.add_net(0)
	var q_net: int = nl.add_net(1)
	var d_net: int = nl.add_net(2)
	var rot_net: int = nl.add_net(3)   # 没人驱动 = 恒低（与线纹空输入同口径）
	var up: int = SwDefine.SW_Dir.UP
	var right: int = SwDefine.SW_Dir.RIGHT
	var down: int = SwDefine.SW_Dir.DOWN
	var left: int = SwDefine.SW_Dir.LEFT
	var src: int = nl.add_device(SWNetlist.DEV_SOURCE, 1 << up, 0)
	nl.set_pin(src, up, clk_net)
	nl.set_role(src, SWNetlist.ROLE_INPUT, nl.add_label("clk"))
	# 寄存器：UP = clk，LEFT = D，RIGHT = Q
	var reg: int = nl.add_device(SWNetlist.DEV_REG,
			(1 << right) | (1 << up) | (1 << left), (1 << up) | (1 << left))
	nl.set_pin(reg, up, clk_net)
	nl.set_pin(reg, left, d_net)
	nl.set_pin(reg, right, q_net)
	nl.set_reg_pins(reg, clk_net, d_net)
	# 非门：DOWN 读 Q，UP 写 D
	var notg: int = nl.add_device(SWNetlist.DEV_NOT, 1 << up, 1 << down)
	nl.set_pin(notg, down, q_net)
	nl.set_pin(notg, up, d_net)
	# 输出接口：灯泡同语义（只读，不驱动）
	var mv: int = nl.add_device(SWNetlist.DEV_LED, 0, 1 << left)
	nl.set_pin(mv, left, q_net)
	nl.set_role(mv, SWNetlist.ROLE_OUTPUT, nl.add_label("move"))
	var rt: int = nl.add_device(SWNetlist.DEV_LED, 0, 1 << left)
	nl.set_pin(rt, left, rot_net)
	nl.set_role(rt, SWNetlist.ROLE_OUTPUT, nl.add_label("rotation"))
	nl.add_driver(clk_net, src)
	nl.add_driver(q_net, reg)
	nl.add_driver(d_net, notg)
	nl.finalize()
	var bundle = BUNDLE.new()
	bundle.setup_from_netlist(nl, [{"name": "clk", "dev": src}],
			[{"name": "move", "dev": mv}, {"name": "rotation", "dev": rt}])
	return bundle


# ===== 1. 实体数据 =====

func test_entity_step_follows_facing() -> void:
	var e = ROBOT_ENTITY.new(Vector2i(5, 5) * GRID, 0)   # 0 = 上
	assert_eq(e.next_cell(), e.grid_pos + Vector2i(0, -1) * GRID, "朝向 0 应当指向上")
	assert_true(e.step_forward(), "前方没被占就该走成")
	assert_eq(e.grid_pos, Vector2i(5, 4) * GRID, "走一格后的坐标不对")

	e.rot90(1)                                            # 顺时针 90° -> 右
	assert_eq(e.dir, 1, "rot90 后的朝向不对")
	assert_eq(e.next_cell(), e.grid_pos + Vector2i(1, 0) * GRID, "朝向 1 应当指向右")

	e.rot90(3)                                            # 再转 270° -> 回到上
	assert_eq(e.dir, 0, "rot90(3) 后的朝向不对")
	assert_eq(e.next_cell(), e.grid_pos + Vector2i(0, -1) * GRID, "朝向 0 应当指向上")


func test_entity_blocked_probe_stops_step() -> void:
	var e = ROBOT_ENTITY.new(Vector2i.ZERO, 1)            # 朝右
	var blocked_cell: Vector2i = e.grid_pos + Vector2i(1, 0) * GRID
	e.blocked_probe = func(cell: Vector2i) -> bool:
		return cell == blocked_cell
	assert_false(e.can_step(), "占格探测说不能进，就不是能走")
	assert_false(e.step_forward(), "被挡时 step_forward 应返回 false")
	assert_eq(e.grid_pos, Vector2i.ZERO, "被挡时不能挪位置")


# ===== 2. 放置 / 删除 / 换格 =====

func test_spawn_robot_occupies_cell() -> void:
	var cell := Vector2i(2, 3)
	var e = _sys.spawn_robot(_w(cell))
	assert_not_null(e, "空地应当能放下机器人")
	assert_eq(_sys.get_entity_count(), 1)
	assert_true(_sys.has_entity_at(_w(cell)), "放下的格子应当被占住")
	assert_same(_sys.get_entity_at(_w(cell)), e, "按位置取回的应当就是刚放的那台")
	# 渲染代理必须真的进了实体层的分区块表
	assert_not_null(e.draw_item, "机器人缺渲染代理")
	assert_same(_sys.entity_manager.getBuild(cell * GRID), e.draw_item,
			"渲染代理没进实体表（画不出来）")
	#关键不变式：实体层的 DrawManager 是 ByContent 模式，它会把 is_preview 建筑
	#短路成空实例块（preview 只给 ByHold/HoldShadow 直写），传 true 就等于看不见机器人
	assert_false(bool(e.draw_item.is_preview),
			"渲染代理不能是 preview 克隆，否则实体层一个实例都不会生成")

	assert_null(_sys.spawn_robot(_w(cell)), "同一格不能放第二台")
	assert_eq(_sys.get_entity_count(), 1, "放失败不该改变实体数")


func test_remove_robot_clears_cell() -> void:
	var cell := Vector2i(1, 1)
	var e = _sys.spawn_robot(_w(cell))
	assert_not_null(e)
	assert_true(_sys.remove_robot_at(_w(cell)), "抹格应当删掉机器人")
	assert_eq(_sys.get_entity_count(), 0)
	assert_false(_sys.has_entity_at(_w(cell)), "删掉后格子应当空出来")
	assert_null(_sys.entity_manager.getBuild(cell * GRID), "删掉后渲染代理还留在实体表里")
	assert_false(_sys.remove_robot_at(_w(cell)), "空格再抹一次应当返回 false")


func test_move_entity_reslots_render_item() -> void:
	var from_cell := Vector2i(4, 4)
	var e = _sys.spawn_robot(_w(from_cell), 1)            # 朝右
	assert_not_null(e)
	assert_true(_sys.move_entity(e), "前方空着应当能走")
	var to_cell: Vector2i = from_cell + Vector2i(1, 0)
	assert_eq(e.grid_pos, _w(to_cell), "实体位置没挪")
	# 分区块表按「格子在区块内的下标」存，换格必须重新入表：旧格空、新格有
	assert_false(_sys.has_entity_at(_w(from_cell)), "旧格子还占着")
	assert_true(_sys.has_entity_at(_w(to_cell)), "新格子没占上")
	assert_null(_sys.entity_manager.getBuild(from_cell * GRID), "旧格的渲染代理没摘掉")
	assert_same(_sys.entity_manager.getBuild(to_cell * GRID), e.draw_item,
			"新格没有渲染代理（走一步就消失）")
	assert_eq(e.draw_item.buildAxisPos, to_cell * GRID, "渲染代理坐标没跟上实体")
	assert_eq(int(e.draw_item.buildState.state), int(SwDefine.BuildState.IDLE),
			"重入表后状态必须是 IDLE：delBuilds 会把它标成待删除")


# ===== 3. 选中 =====

func test_select_at_robot() -> void:
	var cell := Vector2i(6, 2)
	var e = _sys.spawn_robot(_w(cell))
	assert_not_null(e)
	watch_signals(_sys)
	assert_true(_sys.select_at(_w(cell)), "点到机器人应当算选中")
	assert_same(_sys.get_selected(), e)
	assert_signal_emit_count(_sys, "entity_selected", 1)
	assert_eq(int(e.draw_item.buildState.state), int(SwDefine.BuildState.SELECTED),
			"选中的机器人没打上高亮状态")

	assert_false(_sys.select_at(_w(Vector2i(9, 9))), "点到空地应当算取消选中")
	assert_null(_sys.get_selected(), "点空地后不该还挂着选中")
	assert_eq(int(e.draw_item.buildState.state), int(SwDefine.BuildState.IDLE),
			"取消选中后高亮没清")


# ===== 4. 统一节拍 =====

func test_beat_move_only() -> void:
	var bundle = _bundle_move()
	assert_not_null(bundle, "move 电路的 bundle 没造出来")
	if bundle == null:
		return
	var e = _sys.spawn_robot(_w(Vector2i(3, 3)), 0)       # 朝上
	assert_not_null(e, "机器人没放上")
	if e == null:
		return
	e.set_bundle(bundle, FILE_MOVE)

	assert_eq(_sys.step_beat(), 1, "clk=1 且 move=1，这一拍应当走一格")
	assert_eq(e.grid_pos, _w(Vector2i(3, 2)), "朝上走一格应当到 (3,2)")
	assert_eq(e.dir, 0, "只给 move 不该转向")

	assert_eq(_sys.step_beat(), 1, "第二拍应当继续走")
	assert_eq(e.grid_pos, _w(Vector2i(3, 1)), "第二拍没继续往前")

	# 没绑电路的机器人不参与节拍
	var idle = _sys.spawn_robot(_w(Vector2i(8, 8)))
	assert_not_null(idle)
	assert_eq(_sys.step_beat(), 1, "只有绑了电路的那台会动")
	assert_eq(idle.grid_pos, _w(Vector2i(8, 8)), "没绑电路的机器人不该动")


func test_beat_rotate_then_move() -> void:
	var bundle = _bundle_both()
	assert_not_null(bundle, "move+rotation 电路的 bundle 没造出来")
	if bundle == null:
		return
	var from_cell := Vector2i(3, 3)
	var e = _sys.spawn_robot(_w(from_cell), 0)            # 朝上
	e.set_bundle(bundle, FILE_BOTH)

	assert_eq(_sys.step_beat(), 1, "move=1 应当走一格")
	# 一拍内先旋转后移动：0(上) -> 1(右)，再按新朝向走一格
	assert_eq(e.dir, 1, "同一拍里应当先转向")
	assert_eq(e.grid_pos, _w(from_cell + Vector2i(1, 0)),
			"应当按旋转后的朝向（右）移动，说明顺序反了")
	assert_eq(int(e.draw_item.rotation), 1, "渲染代理的朝向没跟着转")


func test_beat_blocked_by_other_robot() -> void:
	var bundle = _bundle_move()
	assert_not_null(bundle)
	if bundle == null:
		return
	var front_cell := Vector2i(2, 1)
	var back_cell := Vector2i(2, 2)
	var front = _sys.spawn_robot(_w(front_cell), 0)
	var back = _sys.spawn_robot(_w(back_cell), 0)         # 朝上，前方被 front 占着
	assert_not_null(front)
	assert_not_null(back)
	back.set_bundle(bundle, FILE_MOVE)

	assert_eq(_sys.step_beat(), 0, "前方被别的机器人占着，这一拍不该移动")
	assert_eq(back.grid_pos, _w(back_cell), "被挡的机器人挪位了")
	assert_eq(front.grid_pos, _w(front_cell), "被撞的那台不该动")


# 一拍必须跑完整个时钟周期（低相位 + 上升沿），否则寄存器/计数器永远不推进。
# 曾经只 set 1→tick→set 0（低相位不 tick），last_clk 一直停在 1：
# 组合电路看着正常（clk 直连输出），带寄存器的电路则恒为 0，机器人不动也不转。
func test_beat_clock_edge_advances_register() -> void:
	var bundle = _make_toggle_bundle()
	var cell := Vector2i(5, 5)
	var e = _sys.spawn_robot(_w(cell), 0)                  # 朝上
	assert_not_null(e, "机器人没放上")
	if e == null:
		return
	e.set_bundle(bundle, "_test_toggle")

	# 第 1 拍：上升沿锁进 D=1 → Q 从 0 翻到 1 → move=1，往上走一格
	assert_eq(_sys.step_beat(), 1, "第一拍没有产生上升沿（Q 没翻转）")
	assert_eq(e.bundle.reg_q_text(), "1", "第一拍后 Q 应当是 1")
	assert_eq(e.grid_pos, _w(cell + Vector2i(0, -1)), "Q=1 却没按朝向走一格")

	# 第 2 拍：Q 翻回 0 → move=0，位置不动
	assert_eq(_sys.step_beat(), 0, "第二拍 Q 翻回 0，不该移动")
	assert_eq(e.bundle.reg_q_text(), "0", "第二拍后 Q 应当是 0")
	assert_eq(e.grid_pos, _w(cell + Vector2i(0, -1)), "move=0 时机器人挪位了")

	# 第 3 拍：再翻回 1，能反复翻转才叫计数器
	assert_eq(_sys.step_beat(), 1, "第三拍应当再次翻转并移动")
	assert_eq(e.bundle.reg_q_text(), "1", "第三拍后 Q 应当是 1")


# 性能面板「打印电路输出」开关：默认关；开着时不影响求值结果（只多一行日志）
func test_debug_print_circuit_does_not_change_result() -> void:
	assert_false(_sys.debug_print_circuit, "打印开关默认必须是关的")
	var bundle = _bundle_move()
	assert_not_null(bundle)
	if bundle == null:
		return
	var e = _sys.spawn_robot(_w(Vector2i(3, 3)), 0)
	e.set_bundle(bundle, FILE_MOVE)
	_sys.debug_print_circuit = true
	assert_eq(_sys.step_beat(), 1, "打开打印后这一拍应当照常走一格")
	assert_eq(e.grid_pos, _w(Vector2i(3, 2)), "打开打印时机器人位置不对")
	_sys.debug_print_circuit = false


# ===== 4.5 时序图样本与场景状态 =====

# 每拍必须落两条样本（高相位 + 低相位）：时序图全靠它，少一条就少一格波形
func test_beat_records_timing_samples() -> void:
	var bundle = _make_toggle_bundle()
	assert_not_null(bundle)
	if bundle == null:
		return
	var e = _sys.spawn_robot(_w(Vector2i(4, 4)), 0)      # 朝上，前方空着
	assert_not_null(e)
	e.set_bundle(bundle, "_test_toggle")

	assert_eq(_sys.step_beat(), 1, "第一拍 Q 0→1，应当走一格")
	assert_eq(_sys.step_beat(), 0, "第二拍 Q 1→0，不该动")
	assert_eq(e.timing_beats, 2, "拍数没跟拍递增")
	assert_eq(e.timing.size(), 4, "两拍应当采到四条样本（每拍两条）")
	assert_eq(e.timing_seq, 4, "采样序号没跟样本递增（波形会不滚动）")
	#Vector4i(clk, move, rotation, acted)：每拍两条，高相位在前；
	#acted 只有低相位那条才可能为 1（动作在下降沿相位执行）
	assert_eq(e.timing[0], Vector4i(1, 1, 0, 0), "第一拍高相位：clk=1 move=1 rot=0，但还没动（动作在下降沿）")
	assert_eq(e.timing[1], Vector4i(0, 1, 0, 1), "同一拍回落时 clk 必须记 0，且本拍真的动了")
	assert_eq(e.timing[2], Vector4i(1, 0, 0, 0), "第二拍高相位 move=0")
	assert_eq(e.timing[3], Vector4i(0, 0, 0, 0), "第二拍低相位 clk=0")

# 时序图样本不能无限长：只留最近 TIMING_CAP 条（一拍两条）
func test_timing_samples_are_capped() -> void:
	var e = ROBOT_ENTITY.new(Vector2i.ZERO, 0)
	var i: int = 0
	while i < ROBOT_ENTITY.TIMING_CAP + 20:
		e.push_timing(1, 0, 0, 0)
		i += 1
	assert_eq(e.timing.size(), ROBOT_ENTITY.TIMING_CAP, "时序样本没有封顶")

	#push_beat 走同一条封顶路径：上限应当是一拍的整数倍
	var e2 = ROBOT_ENTITY.new(Vector2i.ZERO, 0)
	i = 0
	while i < ROBOT_ENTITY.TIMING_CAP + 20:
		e2.push_beat(0, 0, 0)
		i += 1
	assert_eq(e2.timing.size(), ROBOT_ENTITY.TIMING_CAP, "push_beat 没走封顶")
	assert_eq(e2.timing.size() % 2, 0, "窗口必须整拍对齐（否则色块与刻度会错相位）")

# 时序图看哪台：优先选中，没选中取第一台绑了电路的
func test_get_timing_entity_prefers_selection() -> void:
	var a = _sys.spawn_robot(_w(Vector2i(1, 1)))
	var b = _sys.spawn_robot(_w(Vector2i(2, 2)))
	assert_not_null(a)
	assert_not_null(b)
	assert_null(_sys.get_timing_entity(), "一台都没绑电路时不该有观测对象")
	var bundle = _bundle_move()
	assert_not_null(bundle)
	if bundle == null:
		return
	b.set_bundle(bundle, FILE_MOVE)
	assert_same(_sys.get_timing_entity(), b, "没选中时应当取第一台绑了电路的")
	_sys.set_selected(a)
	assert_same(_sys.get_timing_entity(), a, "选中哪台就该看哪台")

# 切出/返回机器人场景的往返：摆位、朝向、绑定电路都要原样回来
func test_scene_state_roundtrip() -> void:
	var bundle = _bundle_move()
	assert_not_null(bundle)
	if bundle == null:
		return
	var a = _sys.spawn_robot(_w(Vector2i(2, 2)), 1)       # 朝右
	var b = _sys.spawn_robot(_w(Vector2i(7, 4)), 3)       # 朝左
	assert_not_null(a)
	assert_not_null(b)
	assert_true(_sys.bind_circuit(a, FILE_MOVE), "绑定失败")

	var data: Dictionary = _sys.to_dict()
	assert_eq((data.get("robots", []) as Array).size(), 2, "状态里应当有两台机器人")

	#另一套系统当作「重新进入场景」
	var other = ENTITY_SYSTEM.new()
	var n: int = other.load_from_dict(data)
	assert_eq(n, 2, "恢复出来的机器人数量不对")
	var ra = other.get_entity_at(_w(Vector2i(2, 2)))
	var rb = other.get_entity_at(_w(Vector2i(7, 4)))
	assert_not_null(ra, "(2,2) 上的机器人没恢复")
	assert_not_null(rb, "(7,4) 上的机器人没恢复")
	if ra == null or rb == null:
		return
	assert_eq(int(ra.dir), 1, "朝向没恢复")
	assert_eq(int(rb.dir), 3, "朝向没恢复")
	assert_eq(str(ra.circuit_file), FILE_MOVE, "绑定的电路名没恢复")
	assert_true(ra.has_bundle(), "恢复后没重新加载 bundle（回来就不动了）")
	assert_eq(str(rb.circuit_file), "", "没绑电路的那台不该凭空绑上")
	other.clear_entities()


# ===== 5. 节拍器 =====

func test_tick_driver_emits_on_period() -> void:
	var tick = ROBOT_TICK.new()
	add_child_autofree(tick)
	tick.set_period(0.25)
	tick.bind_entity_system(_sys)

	# 不到一个节拍不发拍
	tick._physics_process(0.1)
	assert_eq(tick.get_beat_count(), 0, "没攒够一个节拍不该发拍")
	tick._physics_process(0.2)
	assert_eq(tick.get_beat_count(), 1, "攒够 250ms 应当正好发一拍")

	# 关掉总开关后不再发拍
	tick.enabled = false
	tick._physics_process(1.0)
	assert_eq(tick.get_beat_count(), 1, "关掉后还在发拍")

	# 没绑系统时也不发拍
	tick.enabled = true
	tick.bind_entity_system(null)
	tick._physics_process(1.0)
	assert_eq(tick.get_beat_count(), 1, "没绑系统还在发拍")

	# 重新绑上，一拍最多补 MAX_STEPS_PER_FRAME 拍（卡顿后不能一次跳十几格）
	tick.bind_entity_system(_sys)
	tick._physics_process(0.25 * 20.0)
	assert_eq(tick.get_beat_count(), 1 + int(ROBOT_TICK.MAX_STEPS_PER_FRAME),
			"单帧补拍数应当被 MAX_STEPS_PER_FRAME 限住")


func test_tick_pause_resume_blocks_beats() -> void:
	var tick = ROBOT_TICK.new()
	add_child_autofree(tick)
	tick.set_period(0.25)
	tick.bind_entity_system(_sys)
	assert_true(tick.is_running(), "新节拍器默认应当在跑")

	tick.pause()
	assert_false(tick.is_running(), "暂停后还报在跑")
	tick._physics_process(1.0)
	assert_eq(tick.get_beat_count(), 0, "暂停后物理帧还在发拍")

	#暂停期间攒下的时间不能在恢复时变成一串补拍
	tick.resume()
	assert_true(tick.is_running(), "恢复后还报停着")
	tick._physics_process(0.25)
	assert_eq(tick.get_beat_count(), 1, "恢复后应当正好发一拍")


func test_tick_step_once_moves_exactly_one_beat() -> void:
	var tick = ROBOT_TICK.new()
	add_child_autofree(tick)
	tick.set_period(0.25)
	tick.bind_entity_system(_sys)

	#步进：先自己停下，再只走一拍
	var moved: int = tick.step_once()
	assert_false(tick.is_running(), "步进后应当停在暂停态")
	assert_eq(tick.get_beat_count(), 1, "步进应当只走一拍")
	assert_true(moved >= 0, "步进返回值应当是移动台数，不该是 -1")

	tick.step_once()
	assert_eq(tick.get_beat_count(), 2, "连点两次步进应当走两拍")
	#步进之后物理帧不能自己接着跑
	tick._physics_process(2.0)
	assert_eq(tick.get_beat_count(), 2, "步进后物理帧又自己发拍了")

	#没绑实体系统时步进不开拍，返回 -1
	tick.bind_entity_system(null)
	assert_eq(tick.step_once(), -1, "没绑实体系统时步进应当返回 -1")
	assert_eq(tick.get_beat_count(), 2, "没绑系统还发拍")


# 实时节拍一拍拆成**两个时间点**发：
#   半拍一次「上升沿相位」（锁存、读输出、落高相位样本，但不动作）
#   再半拍一次「下降沿相位」（clk 回落、动作、落低相位样本）
# 一次写两条样本的话，时序图的红线一拍跳两格，看起来永远停在上升沿、下降沿被跳过。
func test_tick_splits_beat_into_two_phases() -> void:
	var bundle = _make_toggle_bundle()
	assert_not_null(bundle, "toggle 电路没造出来")
	if bundle == null:
		return
	var tick = ROBOT_TICK.new()
	add_child_autofree(tick)
	tick.set_period(0.25)
	tick.bind_entity_system(_sys)
	var cell := Vector2i(4, 4)
	var e = _sys.spawn_robot(_w(cell), 0)                 # 朝上，前方空着
	assert_not_null(e)
	e.set_bundle(bundle, "_test_toggle")

	#半拍：只走上升沿相位 —— 落一条高相位样本，机器还没动
	tick._physics_process(0.125)
	assert_eq(tick.get_beat_count(), 1, "半拍应当发到上升沿相位")
	assert_eq(e.timing.size(), 1, "上升沿相位应当只落一条样本（不是两条）")
	assert_eq(int(e.timing[0].x), 1, "上升沿相位那条不是高电平")
	assert_eq(int(e.timing[0].w), 0, "上升沿相位不该已经算动过")
	assert_eq(e.grid_pos, _w(cell), "上升沿相位就动了：动作应当留到下降沿相位")
	assert_almost_eq(float(tick.get_phase_frac()), 0.0, 0.001, "刚发完上升沿，相位进度应当归零")

	#再跑半拍的四分之一：相位进度要能跟上（红线靠它把最新一格慢慢画出来）
	tick._physics_process(0.0625)
	assert_almost_eq(float(tick.get_phase_frac()), 0.5, 0.05, "相位进度没跟上物理时间")
	assert_eq(e.timing.size(), 1, "没到下降沿就不该再落样本")

	#剩下的半拍：下降沿相位，这时才动作
	assert_eq(tick.tick_low(), 1, "下降沿相位应当执行本拍的移动")
	assert_eq(e.timing.size(), 2, "下降沿相位应当再落一条样本")
	assert_eq(int(e.timing[1].x), 0, "下降沿那条不是低电平")
	assert_eq(int(e.timing[1].w), 1, "下降沿相位没记下本拍真的动了")
	assert_eq(e.timing_beats, 1, "拍数应当在下降沿相位才算完")
	assert_eq(e.grid_pos, _w(cell + Vector2i(0, -1)), "下降沿相位应当往上走一格")

	#停住时相位进度按 1 算：最后一格是完整的，波形不该缩成一条线
	tick.pause()
	assert_almost_eq(float(tick.get_phase_frac()), 1.0, 0.001, "停住时最新一格应当画满")


# ===== 6. 电路绑定（阶段 4） =====

# 绑定走真实装载路径：bind_circuit 内部 load_bundle，不是直接塞 bundle 进去
func test_bind_circuit_then_beat_moves() -> void:
	var made = _bundle_move()
	assert_not_null(made, "电路文件没造出来")
	if made == null:
		return
	var e = _sys.spawn_robot(_w(Vector2i(4, 4)), 0)        # 朝上
	assert_eq(_sys.get_bound_count(), 0, "刚放下的机器人不该已经绑了电路")
	assert_true(_sys.bind_circuit(e, FILE_MOVE), "绑定失败")
	assert_true(e.has_bundle(), "绑完实体上还没有 bundle")
	assert_eq(e.circuit_file, FILE_MOVE, "绑定的电路文件名没记上")
	assert_eq(_sys.get_bound_count(), 1)
	# 绑上后第一拍就该动：move = clk
	assert_eq(_sys.step_beat(), 1, "绑了电路却没按节拍移动")
	assert_eq(e.grid_pos, _w(Vector2i(4, 3)), "朝向 0（上）应当往上走一格")

# 不存在的文件一律拒绝，且不能把实体弄成半绑定状态
func test_bind_circuit_rejects_invalid() -> void:
	var e = _sys.spawn_robot(_w(Vector2i(4, 4)))
	assert_false(_sys.bind_circuit(e, "_no_such_circuit"), "不存在的文件不该绑成功")
	assert_false(e.has_bundle(), "绑定失败却留下了 bundle")
	assert_eq(e.circuit_file, "", "绑定失败却记了文件名")
	assert_eq(_sys.get_bound_count(), 0)
	assert_false(_sys.bind_circuit(null, FILE_MOVE), "空实体不该绑成功")

# 解绑后不再参与节拍
func test_unbind_circuit_stops_beat() -> void:
	var made = _bundle_move()
	assert_not_null(made)
	if made == null:
		return
	var e = _sys.spawn_robot(_w(Vector2i(4, 4)), 0)
	assert_true(_sys.bind_circuit(e, FILE_MOVE))
	assert_eq(_sys.step_beat(), 1)
	var at: Vector2i = e.grid_pos
	_sys.unbind_circuit(e)
	assert_false(e.has_bundle(), "解绑后实体上还挂着 bundle")
	assert_eq(e.circuit_file, "", "解绑后电路文件名没清")
	assert_eq(_sys.get_bound_count(), 0)
	assert_eq(_sys.step_beat(), 0, "解绑后不该再移动")
	assert_eq(e.grid_pos, at, "解绑后位置被改了")

# 同一个文件绑给两台：各持一份 runtime，同一拍两边都动（状态不串）
func test_two_robots_share_file_but_not_state() -> void:
	var made = _bundle_move()
	assert_not_null(made)
	if made == null:
		return
	var a = _sys.spawn_robot(_w(Vector2i(1, 1)), 0)
	var b = _sys.spawn_robot(_w(Vector2i(1, 4)), 0)
	assert_true(_sys.bind_circuit(a, FILE_MOVE))
	assert_true(_sys.bind_circuit(b, FILE_MOVE))
	assert_ne(a.bundle, b.bundle, "两台机器人共用了同一个 runtime 实例")
	assert_eq(_sys.get_bound_count(), 2)
	assert_eq(_sys.step_beat(), 2, "同一拍两台都该动")
	assert_eq(a.grid_pos, _w(Vector2i(1, 0)), "第一台该往上走")
	assert_eq(b.grid_pos, _w(Vector2i(1, 3)), "第二台该往上走")
