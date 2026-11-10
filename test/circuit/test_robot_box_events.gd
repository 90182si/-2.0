extends GutTest
# 机器人事件接口 / 8 方向检测 / 箱子与推箱（SPEC-08 增补，纯逻辑，不 boot 场景）
#
# 覆盖点：
#   1. SWRobotActions：输出名 -> 动作映射表（未登记的名字不产生动作，顺序即同拍执行顺序）
#   2. detect_around / detect_at：固定 8 项，值是 8 位码（高 3 位方向码 + 低 5 位物品码），
#      下标即方向码（相对朝向）
#   3. 推箱：箱子前方空 -> 箱子与机器人各进一格；箱子前方被占 -> 两者都不动
#   4. 事件动作：push=1 只推箱不前进；move=1 照常前进
#   5. 检测通道：上拍 detect_sig_0..2 拼成方向码（编号小的在左、相对朝向），
#      detect_res_0..7 回写 8 位码（前 3 位方向码、后 5 位物品码）
#   6. 时序图额外轨道：绑定电路的其它输出名（push / detect_sig_*）进 trace_names + 位图
#   7. 箱子不可选中（点它不该弹电路绑定面板）
#   8. 手持分派：箱子模板放箱子、机器人模板放机器人
#   9. 场景状态往返：to_dict / load_from_dict 能还原箱子（版本号升到 2，旧档仍可读）
#
# 跑法：godot --headless --path . -s addons/gut/gut_cmdln.gd
#       -gdir=res://test/circuit -gprefix test_robot_box_events -gexit

const ENTITY_SYSTEM := preload("res://scene/entity/sw_entity_layer_system.gd")
const ACTIONS := preload("res://scene/entity/sw_robot_actions.gd")
const BUNDLE := preload("res://circuit/sim/sw_circuit_bundle.gd")

const ROBOT_DEF: SWBuildDefine = preload("res://res/机器人.tres")
const BOX_DEF: SWBuildDefine = preload("res://res/箱子.tres")

const GRID: Vector2i = SwDefine.GRID_SIZE

var _sys = null


func before_each() -> void:
	_sys = ENTITY_SYSTEM.new()

func after_each() -> void:
	_sys = null


# 格子坐标 -> 世界坐标（实体接口一律吃世界坐标）
func _w(cell: Vector2i) -> Vector2i:
	return cell * GRID


# 这条 bundle 的全部输出口：move/rotation 是绑定合同，push 是事件，
# detect_sig_0..7 里前 3 根拼方向码（后面 5 根是保留位）
const OUT_NAMES: Array[String] = [
	"move", "rotation", "push",
	"detect_sig_0", "detect_sig_1", "detect_sig_2", "detect_sig_3",
	"detect_sig_4", "detect_sig_5", "detect_sig_6", "detect_sig_7",
]

# 造一条 bundle（netlist 直造，不走 .swcir）：
#   输入：clk + detect_res_0..7（机器人写电平的源）
#   输出：OUT_NAMES 全部，**每个输出各由一个可写源 drv_<名字> 驱动**
# 这样测试里 bundle.set_input("drv_push", 1) 就能把某一路输出拉高，
# 且电平要过一次 tick 才反映到输出上（与真电路一致，也是「方向来自上一拍输出」的由来）
func _bundle_all_outputs():
	var nl := SWNetlist.new()
	var up: int = SwDefine.SW_Dir.UP
	var left: int = SwDefine.SW_Dir.LEFT
	var ins: Array = []
	var outs: Array = []
	# clk 源：真节拍里由实体层每拍写 0/1
	var clk_net: int = nl.add_net(0)
	var src: int = nl.add_device(SWNetlist.DEV_SOURCE, 1 << up, 0)
	nl.set_pin(src, up, clk_net)
	nl.set_role(src, SWNetlist.ROLE_INPUT, nl.add_label("clk"))
	nl.add_driver(clk_net, src)
	ins.append({"name": "clk", "dev": src})
	# detect_res_0..7：8 个源，只靠 set_input 写电平（没人读也无妨）
	# 注意 add_net 返回的是 **net 下标**，set_pin 吃的是 **netId**：两个别搞混
	for b in 8:
		var res_id: int = b + 1
		var res_ni: int = nl.add_net(res_id)
		var res_dev: int = nl.add_device(SWNetlist.DEV_SOURCE, 1 << up, 0)
		nl.set_pin(res_dev, up, res_id)
		nl.set_role(res_dev, SWNetlist.ROLE_INPUT, nl.add_label("detect_res_%d" % b))
		nl.add_driver(res_ni, res_dev)
		ins.append({"name": "detect_res_%d" % b, "dev": res_dev})
	# 每个输出：源 drv_<name> -> net -> LED 口
	var net_id: int = 20
	for name: String in OUT_NAMES:
		var out_id: int = net_id
		var out_ni: int = nl.add_net(out_id)
		net_id += 1
		var drv: int = nl.add_device(SWNetlist.DEV_SOURCE, 1 << up, 0)
		nl.set_pin(drv, up, out_id)
		nl.set_role(drv, SWNetlist.ROLE_INPUT, nl.add_label("drv_" + name))
		nl.add_driver(out_ni, drv)
		ins.append({"name": "drv_" + name, "dev": drv})
		var led: int = nl.add_device(SWNetlist.DEV_LED, 0, 1 << left)
		nl.set_pin(led, left, out_id)
		nl.set_role(led, SWNetlist.ROLE_OUTPUT, nl.add_label(name))
		outs.append({"name": name, "dev": led})
	nl.finalize()
	var bundle = BUNDLE.new()
	bundle.setup_from_netlist(nl, ins, outs)
	return bundle

# 预先拉高若干输出，并 tick 一次：等价于「上一拍电路就已经是这些电平」。
# 不补这次 tick 的话，第一拍读到的输出还是 0（电平变化本身也要过一次 tick 才可见）
func _bundle_driving(high_names: Array):
	var b = _bundle_all_outputs()
	for n in high_names:
		b.set_input("drv_" + str(n), 1)
	b.tick()
	return b

# 拉高/拉低某路输出并 tick 一次（让下一拍读到的就是新电平）
func _raise(bundle, name: String) -> void:
	bundle.set_input("drv_" + name, 1)
	bundle.tick()

func _lower(bundle, name: String) -> void:
	bundle.set_input("drv_" + name, 0)
	bundle.tick()

# 把 detect_res_0..7 的 8 根口读回成一个整数（口序「编号小的在左」：res_0 是 bit7）
func _res_code(bundle) -> int:
	var code: int = 0
	for port in 8:
		if bundle.input_level(ACTIONS.res_name(port)) != 0:
			code |= 1 << ACTIONS.res_bit(port)
	return code

# 方向码 + 物品码 -> 8 位码（与 ACTIONS.encode_code 同口径，单独写一份便于看出表达式）
func _code(dir_code: int, item_code: int) -> int:
	return (dir_code << 5) | item_code


# ===== 1. 动作表 =====

func test_action_table_maps_names_to_kinds() -> void:
	assert_eq(ACTIONS.kind_of("rotation"), "rotate")
	assert_eq(ACTIONS.kind_of("move"), "move")
	assert_eq(ACTIONS.kind_of("push"), "push")
	# 检测不是动作：detect_sig_* 只选方向，不产生动作
	assert_eq(ACTIONS.kind_of("detect_sig_0"), "", "detect_sig 不该进动作表")
	assert_eq(ACTIONS.kind_of("no_such_action"), "", "未登记的名字不该产生动作")
	# 顺序即同拍执行顺序：一拍里同时有 rotation 与 move 时必须先转后走
	var names: Array[String] = ACTIONS.names()
	assert_lt(names.find("rotation"), names.find("move"),
			"rotation 必须排在 move 前面（一拍内先转后走）")


# ===== 2. 8 方向检测（方向码相对朝向 + 物品码） =====

# 码：高 3 位方向码（相对朝向：0 正前 / 2 正右 / 4 正后 / 6 正左），低 5 位物品码
# （空 0 / 机器人 1 / 箱子 2）
func test_detect_code_layout() -> void:
	assert_eq(ACTIONS.ITEM_ROBOT, 0b00001, "机器人物品码必须是 0b00001")
	assert_eq(ACTIONS.ITEM_BOX, 0b00010, "箱子物品码必须是 0b00010")
	# 正左方的箱子 = 方向码 6 + 物品码 2 -> 0b11000010
	assert_eq(_code(6, ACTIONS.ITEM_BOX), 0b11000010)
	assert_eq(ACTIONS.decode_dir(0b11000010), 6, "方向码该落在高 3 位")
	assert_eq(ACTIONS.decode_item(0b11000010), ACTIONS.ITEM_BOX, "物品码该落在低 5 位")
	# 方向码是相对的：要叠机器人朝向才知道看哪边
	assert_eq(ACTIONS.facing_dir8(3), 6, "朝西 = 绝对方向 6")
	assert_eq(ACTIONS.abs_dir_of(3, 6), 4, "朝西 + 方向码 6 应当看正南（用户举的例子）")
	assert_eq(ACTIONS.abs_dir_of(0, 6), 6, "朝北时方向码 6 = 正西")
	assert_eq(ACTIONS.abs_dir_of(1, 0), 2, "朝东时方向码 0 = 正前 = 正东")
	assert_eq(ACTIONS.abs_dir_of(2, 6), 2, "朝南 + 方向码 6（正左）= 正东")
	assert_eq(ACTIONS.abs_dir_of(3, 4), 2, "朝西 + 方向码 4（正后）= 正东")
	# 名字 <-> 口序号
	assert_eq(ACTIONS.sig_name(3), "detect_sig_3")
	assert_eq(ACTIONS.res_name(7), "detect_res_7")
	# sig 口的方向权重：编号小的在左（sig_0 = 4、sig_1 = 2、sig_2 = 1），后 5 位保留
	assert_eq(ACTIONS.sig_weight(0), 4, "detect_sig_0 是方向最高位")
	assert_eq(ACTIONS.sig_weight(1), 2)
	assert_eq(ACTIONS.sig_weight(2), 1, "detect_sig_2 是方向最低位")
	assert_eq(ACTIONS.sig_weight(3), 0, "sig_3..7 是保留位，不参与方向")
	assert_eq(ACTIONS.sig_weight_of("detect_sig_0"), 4)
	assert_eq(ACTIONS.sig_weight_of("detect_sig_8"), -1, "越界的口号不该被认")
	assert_eq(ACTIONS.sig_weight_of("move"), -1, "动作名不是方向名")
	# res 口序：编号小的在左（res_0 是 bit7、res_7 是 bit0）
	assert_eq(ACTIONS.res_bit(0), 7, "detect_res_0 是最高位")
	assert_eq(ACTIONS.res_bit(7), 0)
	assert_eq(ACTIONS.bit_of_res("detect_res_0"), 7)
	assert_eq(ACTIONS.bit_of_res("detect_res_7"), 0)
	assert_eq(ACTIONS.bit_of_res("push"), -1)
	# 用户口径的例子：后五位 00111 = 物品码 7（此时方向 0，所以 0b 串就是 00000111）
	var item7: int = ACTIONS.encode_code(0, 7)
	assert_eq(ACTIONS.decode_item(item7), 7)
	assert_eq(ACTIONS._bin8(item7), "00000111", "0b 串从左到右就是 res_0..res_7")


# 下标就是方向码：朝北时相对方向与绝对方向同序（0 正前=北、1 右前=东北、5 左后=西南）
func test_detect_around_follows_dir_codes() -> void:
	var mid := Vector2i(5, 5)
	var e = _sys.spawn_robot(_w(mid), 0)          # 朝北
	assert_not_null(e, "中心机器人没放上")
	if e == null:
		return
	assert_not_null(_sys.spawn_robot(_w(mid + Vector2i(0, -1))), "正北（正前）的机器人没放上")
	assert_not_null(_sys.spawn_box(_w(mid + Vector2i(1, -1))), "东北（右前）的箱子没放上")
	assert_not_null(_sys.spawn_box(_w(mid + Vector2i(-1, 1))), "西南（左后）的箱子没放上")

	var info: Array = _sys.detect_around(e)
	assert_eq(info.size(), 8, "必须固定返回 8 项")
	assert_eq(int(info[0]), _code(0, ACTIONS.ITEM_ROBOT), "0 号：正前（朝北即正北）的机器人")
	assert_eq(int(info[1]), _code(1, ACTIONS.ITEM_BOX), "1 号：右前的箱子")
	assert_eq(int(info[2]), _code(2, ACTIONS.ITEM_NONE), "2 号（正右）空着，物品码该是 0")
	assert_eq(int(info[5]), _code(5, ACTIONS.ITEM_BOX), "5 号：左后的箱子")


# 方向码是**相对朝向**的：同一个箱子换了朝向就落到不同方向码上
func test_detect_around_is_relative() -> void:
	var mid := Vector2i(20, 20)
	var e = _sys.spawn_robot(_w(mid), 1)          # 朝东
	assert_not_null(e)
	if e == null:
		return
	assert_not_null(_sys.spawn_box(_w(mid + Vector2i(0, -1))), "正北的箱子没放上")
	var info: Array = _sys.detect_around(e)
	assert_eq(int(info[6]), _code(6, ACTIONS.ITEM_BOX), "朝东时正北在正左（方向码 6）")
	assert_eq(int(info[0]), _code(0, ACTIONS.ITEM_NONE), "0 号是正前（正东），空着")
	# 再转 180°（朝西）：同一个箱子变成右手边
	_sys.rotate_entity(e, 2)
	var info2: Array = _sys.detect_around(e)
	assert_eq(int(info2[2]), _code(2, ACTIONS.ITEM_BOX), "朝西时正北在正右（方向码 2）")
	assert_eq(int(info2[6]), _code(6, ACTIONS.ITEM_NONE), "6 号（正左，朝西即正南）空着")


func test_detect_at_takes_cell_and_dir() -> void:
	var cell := Vector2i(2, 2)
	assert_not_null(_sys.spawn_box(_w(cell + Vector2i(0, 1))), "正南的箱子没放上")
	var info: Array = _sys.detect_at(cell)
	assert_eq(info.size(), 8, "detect_at 也要固定 8 项")
	assert_eq(int(info[4]), _code(4, ACTIONS.ITEM_BOX), "默认朝北时 4 号是正后（正南）")
	# 假定朝东：正南变成正右（方向码 2）
	var info2: Array = _sys.detect_at(cell, 1)
	assert_eq(int(info2[2]), _code(2, ACTIONS.ITEM_BOX), "朝东时正南落在方向码 2")
	assert_eq(int(info2[4]), _code(4, ACTIONS.ITEM_NONE), "朝东时 4 号（正西）空着")


# ===== 2b. 检测通道：上拍 sig 拼方向，本拍把码写回 detect_res =====

# sig_0..2 当二进制位拼方向码（编号小的在左）：朝北时“110”= 6 = 正左（正好是正西）
func test_detect_res_follows_sig_binary_direction() -> void:
	var cell := Vector2i(40, 40)
	var e = _sys.spawn_robot(_w(cell), 0)          # 朝北：相对=绝对，先把位序测清楚
	assert_not_null(e)
	if e == null:
		return
	assert_not_null(_sys.spawn_box(_w(cell + Vector2i(0, -1))), "正北的箱子没放上")
	assert_not_null(_sys.spawn_box(_w(cell + Vector2i(1, 0))), "正东的箱子没放上")
	assert_not_null(_sys.spawn_box(_w(cell + Vector2i(-1, 0))), "正西的箱子没放上")
	var b = _bundle_all_outputs()
	e.set_bundle(b, "_test_detect")

	# 三根 sig 全低 = 方向 0（正北）
	_sys.step_beat()
	assert_eq(_res_code(b), _code(0, ACTIONS.ITEM_BOX), "sig 全低应当检测正北")

	# 只拉高 sig_1（权重 2）= 方向码 2（正右，朝北时就是正东）
	_raise(b, ACTIONS.sig_name(1))
	_sys.step_beat()
	assert_eq(_res_code(b), _code(2, ACTIONS.ITEM_BOX), "sig_1 权重 2，应检测方向码 2")
	assert_eq(int(e.last_detect[2]), _code(2, ACTIONS.ITEM_BOX),
			"last_detect 下标就是方向码")

	# sig_0 + sig_1 = 4 + 2 = 6 = 正左（就是“110”那个例子；朝北时正好是正西）
	_raise(b, ACTIONS.sig_name(0))
	_sys.step_beat()
	assert_eq(_res_code(b), _code(6, ACTIONS.ITEM_BOX), "“110”应当选中方向码 6")
	# 口序：res_0/res_1 = 方向高/中位，res_6 = 物品码 bit1（箱子）
	assert_eq(b.input_level(ACTIONS.res_name(0)), 1, "方向 6 的最高位该在 res_0")
	assert_eq(b.input_level(ACTIONS.res_name(1)), 1, "方向 6 的中位该在 res_1")
	assert_eq(b.input_level(ACTIONS.res_name(2)), 0, "方向 6 的最低位该是 0")
	assert_eq(b.input_level(ACTIONS.res_name(6)), 1, "箱子（物品码 2）落在 res_6")

	# 只留 sig_2（权重 1）= 方向 1（东北）：空的，只剩方向位
	_lower(b, ACTIONS.sig_name(0))
	_lower(b, ACTIONS.sig_name(1))
	_raise(b, ACTIONS.sig_name(2))
	_sys.step_beat()
	assert_eq(_res_code(b), _code(1, ACTIONS.ITEM_NONE), "东北是空的，只剩方向码")

	# sig_3..7 是保留位：拉高也不参与方向
	_lower(b, ACTIONS.sig_name(2))
	_raise(b, ACTIONS.sig_name(5))
	_sys.step_beat()
	assert_eq(_res_code(b), _code(0, ACTIONS.ITEM_BOX), "保留位不该影响方向（回到正北）")


# 方向码要叠上机器人朝向：用户举的例子 ——「110」（方向码 6，正左）+ 朝西 = 看正南
func test_detect_res_follows_robot_facing() -> void:
	var cell := Vector2i(44, 44)
	var e = _sys.spawn_robot(_w(cell), 3)          # 朝西
	assert_not_null(e)
	if e == null:
		return
	assert_not_null(_sys.spawn_box(_w(cell + Vector2i(0, 1))), "正南的箱子没放上")
	assert_not_null(_sys.spawn_box(_w(cell + Vector2i(0, -1))), "正北的箱子没放上")
	var b = _bundle_all_outputs()
	e.set_bundle(b, "_test_detect_facing")

	# 三根全低 = 方向码 0（正前 = 正西）：西边空着
	_sys.step_beat()
	assert_eq(_res_code(b), _code(0, ACTIONS.ITEM_NONE), "方向码 0 该看正前（正西，空）")

	# sig_0 + sig_1 = 6（“110”）+ 朝西 -> 正南，那边有箱子
	_raise(b, ACTIONS.sig_name(0))
	_raise(b, ACTIONS.sig_name(1))
	_sys.step_beat()
	assert_eq(_res_code(b), _code(6, ACTIONS.ITEM_BOX), "“110”+ 朝西 应当看正南的箱子")
	assert_eq(int(e.last_detect[6]), _code(6, ACTIONS.ITEM_BOX), "last_detect 下标就是方向码")

	# 方向码 4（正后）= 正东：那边空着，只剩方向位（只需 sig_0 高，权重 4）
	_lower(b, ACTIONS.sig_name(1))
	_lower(b, ACTIONS.sig_name(2))
	_sys.step_beat()
	assert_eq(_res_code(b), _code(4, ACTIONS.ITEM_NONE), "朝西时方向码 4 该看正东（空）")


# ===== 2c. 时序图额外轨道：其它输出名要能画出来 =====

func test_trace_names_cover_outputs_except_move_rotation() -> void:
	var e = _sys.spawn_robot(_w(Vector2i(50, 50)), 0)
	assert_not_null(e)
	if e == null:
		return
	var b = _bundle_all_outputs()
	e.set_bundle(b, "_test_trace")
	assert_true(e.trace_names.has("push"), "push 应当自成一轨")
	assert_true(e.trace_names.has("detect_sig_0"), "detect_sig_* 也该出现在时序图上")
	assert_eq(e.trace_names.find("move"), -1, "move 已经是固定轨，不该重复")
	assert_eq(e.trace_names.find("rotation"), -1)

	# 每拍两张样本都要配一张电平位图，位图里能读到 push 的高低
	_raise(b, "push")
	_sys.step_beat()
	assert_eq(e.timing.size(), e.trace_masks.size(),
			"位图必须与样本一一对应")
	var k: int = e.trace_names.find("push")
	var mask: int = int(e.trace_masks[e.trace_masks.size() - 1])
	assert_eq((mask >> k) & 1, 1, "push 输出为高，位图里该置位")

	# 解绑后轨道清空（旧电路的名字对新电路没意义）
	e.set_bundle(null)
	assert_eq(e.trace_names.size(), 0, "解绑电路后不该留着旧轨道")


# 玩家自选监测信号：输入口（detect_res_N）也能进时序图，且位图能读到电平
func test_trace_signals_can_watch_input_code() -> void:
	var cell := Vector2i(50, 50)
	var e = _sys.spawn_robot(_w(cell), 0)          # 朝上
	assert_not_null(e)
	if e == null:
		return
	#南边放一个箱子：方向 4 的码 = (4<<5)|0b00010，物品码 bit1 落在 res_6
	_sys.spawn_box(_w(cell + Vector2i(0, 1)))
	#电路里 detect_sig_0 已经是上一拍的高电平（权重 4）：本拍按方向 4（正南）上报
	var b = _bundle_driving(["detect_sig_0"])
	e.set_bundle(b, "_test_trace_in")
	e.set_trace_signals(["detect_res_0", "detect_res_6", "detect_sig_0"])
	assert_true(e.trace_names_manual, "设了清单应当进入手动模式")
	assert_eq(e.trace_names.size(), 3, "三条自选信号应当都进清单")
	assert_eq(e.trace_names.find("detect_res_0"), 0, "清单要按玩家添加顺序保留")

	_sys.step_beat()
	assert_eq(e.timing.size(), e.trace_masks.size(), "位图必须与样本一一对应")
	var k_dir: int = e.trace_names.find("detect_res_0")
	var k_item: int = e.trace_names.find("detect_res_6")
	var k_sig: int = e.trace_names.find("detect_sig_0")
	var mask: int = int(e.trace_masks[e.trace_masks.size() - 1])
	assert_eq((mask >> k_dir) & 1, 1, "方向 4 的最高位（res_0）应当为 1（输入口也要被采到）")
	assert_eq((mask >> k_item) & 1, 1, "南边有箱子，物品码 bit1（res_6）应当为 1")
	assert_eq((mask >> k_sig) & 1, 1, "detect_sig_0 本拍一直是高")

	#固定轨名字会被过滤（否则同一个波形会画两遍）
	e.set_trace_signals(["move", "clk", "push"])
	assert_eq(e.trace_names.size(), 1, "固定轨名字不该进额外轨")
	assert_eq(e.trace_names.find("push"), 0)

	#清空 = 回到自动模式：把电路里 move/rotation 之外的输出名全列出来
	e.set_trace_signals([])
	assert_false(e.trace_names_manual, "清空清单应当回到自动模式")
	assert_true(e.trace_names.has("push"), "自动模式要把电路的其它输出名都列出来")
	assert_true(e.trace_names.has("detect_sig_0"))


# ===== 3. 推箱 =====

func test_move_pushes_box_when_front_cell_free() -> void:
	var robot_cell := Vector2i(3, 5)
	var box_cell := robot_cell + Vector2i(0, -1)
	var robot = _sys.spawn_robot(_w(robot_cell), 0)      # 朝上
	var box = _sys.spawn_box(_w(box_cell))
	assert_not_null(robot, "机器人没放上")
	assert_not_null(box, "箱子没放上")
	if robot == null or box == null:
		return

	assert_true(_sys.move_entity(robot), "箱子前方空着，应当推得动")
	assert_eq(box.grid_pos, _w(box_cell + Vector2i(0, -1)), "箱子没被推走")
	assert_eq(robot.grid_pos, _w(box_cell), "机器人应当跟到箱子原来的格子")
	assert_false(_sys.has_entity_at(_w(robot_cell)), "机器人旧格子应当空出来")
	assert_same(_sys.get_entity_at(_w(box_cell + Vector2i(0, -1))), box,
			"箱子新格子的占格记录不对")
	# 渲染代理要跟着权威位置走
	assert_eq(box.draw_item.buildAxisPos, _w(box_cell + Vector2i(0, -1)),
			"箱子的渲染代理没跟着挪")


func test_move_blocked_when_box_cannot_move() -> void:
	var robot_cell := Vector2i(3, 5)
	var box_cell := robot_cell + Vector2i(0, -1)
	var wall_cell := box_cell + Vector2i(0, -1)
	var robot = _sys.spawn_robot(_w(robot_cell), 0)      # 朝上
	var box = _sys.spawn_box(_w(box_cell))
	var wall = _sys.spawn_box(_w(wall_cell))
	assert_not_null(robot)
	assert_not_null(box)
	assert_not_null(wall)
	if robot == null or box == null or wall == null:
		return

	# 只支持单层推箱：箱子前面还是箱子就推不动，这一步整体失败
	assert_false(_sys.move_entity(robot), "箱子前方被占，这一格不该走成")
	assert_eq(robot.grid_pos, _w(robot_cell), "推不动时机器人不该动")
	assert_eq(box.grid_pos, _w(box_cell), "推不动时箱子不该动")
	assert_eq(wall.grid_pos, _w(wall_cell), "被挡的那个箱子也不该动")


func test_push_entity_requires_box_in_front() -> void:
	var robot_cell := Vector2i(7, 7)
	var robot = _sys.spawn_robot(_w(robot_cell), 0)      # 朝上
	assert_not_null(robot)
	if robot == null:
		return
	assert_false(_sys.push_entity(robot), "前方没有箱子时 push 应当返回 false")
	assert_eq(robot.grid_pos, _w(robot_cell), "push 失败不该挪动机器人")


# ===== 4. 事件动作（走完整的一拍：上升沿相位 + 下降沿相位） =====

func test_push_event_only_pushes_without_moving() -> void:
	var bundle = _bundle_driving(["push"])
	assert_not_null(bundle, "push 事件的 bundle 没造出来")
	if bundle == null:
		return
	var robot_cell := Vector2i(4, 4)
	var box_cell := robot_cell + Vector2i(0, -1)
	var robot = _sys.spawn_robot(_w(robot_cell), 0)      # 朝上
	var box = _sys.spawn_box(_w(box_cell))
	assert_not_null(robot)
	assert_not_null(box)
	if robot == null or box == null:
		return
	robot.set_bundle(bundle, "_test_events")

	assert_eq(_sys.step_beat(), 0, "push 事件不该算「移动」，返回值应当是 0")
	assert_eq(box.grid_pos, _w(box_cell + Vector2i(0, -1)), "push=1 却没推动箱子")
	assert_eq(robot.grid_pos, _w(robot_cell), "push 事件里机器人自己不该前进")
	# 时序图口径没变：acted 记「本拍真的动了」，move 轨仍记 move 输出电平
	assert_eq(robot.timing[1], Vector4i(0, 0, 0, 1), "推箱也算本拍动了")


func test_move_event_still_walks_forward() -> void:
	var bundle = _bundle_driving(["move"])
	assert_not_null(bundle, "move 事件的 bundle 没造出来")
	if bundle == null:
		return
	var cell := Vector2i(6, 6)
	var robot = _sys.spawn_robot(_w(cell), 0)            # 朝上
	assert_not_null(robot)
	if robot == null:
		return
	robot.set_bundle(bundle, "_test_events")

	assert_eq(_sys.step_beat(), 1, "move=1 应当照常走一格")
	assert_eq(robot.grid_pos, _w(cell + Vector2i(0, -1)), "move 事件没让机器人前进")
	assert_eq(robot.timing[1], Vector4i(0, 1, 0, 1), "move 轨与 acted 都应当记下来")


func test_detect_does_not_move_robot() -> void:
	var bundle = _bundle_driving([ACTIONS.sig_name(0)])
	assert_not_null(bundle, "detect 通道的 bundle 没造出来")
	if bundle == null:
		return
	var cell := Vector2i(8, 8)
	var robot = _sys.spawn_robot(_w(cell), 0)
	assert_not_null(robot)
	var box = _sys.spawn_box(_w(cell + Vector2i(1, -1)))   # 右前
	assert_not_null(box)
	if robot == null:
		return
	robot.set_bundle(bundle, "_test_events")

	assert_eq(_sys.step_beat(), 0, "检测不该改变位置（返回值是移动台数）")
	assert_eq(robot.grid_pos, _w(cell), "检测把机器人挪走了")
	assert_eq(robot.last_detect.size(), 8, "检测没把内部结果记到实体上")
	if robot.last_detect.size() == 8:
		assert_eq(int(robot.last_detect[1]), _code(1, ACTIONS.ITEM_BOX),
				"右前方的箱子没被检测到")


# ===== 5. 箱子不可选中 =====

func test_box_is_not_selectable() -> void:
	var box_cell := Vector2i(9, 9)
	var robot_cell := Vector2i(9, 10)
	var robot = _sys.spawn_robot(_w(robot_cell))
	var box = _sys.spawn_box(_w(box_cell))
	assert_not_null(robot)
	assert_not_null(box)

	assert_true(_sys.select_at(_w(robot_cell)), "机器人应当能选中")
	assert_same(_sys.get_selected(), robot)
	# 箱子不绑电路：点它不选中，且把原来的选中收起
	assert_false(_sys.select_at(_w(box_cell)), "点箱子不该算选中")
	assert_null(_sys.get_selected(), "点箱子后应当取消原来的选中")


# ===== 6. 手持分派 =====

func test_hold_tool_dispatch_places_box_or_robot() -> void:
	var box_cell := Vector2i(1, 1)
	var robot_cell := Vector2i(2, 1)
	_sys.on_hold_idle_builds([SwDefine.SWBuildCreator(Vector2i.ZERO, BOX_DEF)], [_w(box_cell)])
	_sys.on_hold_idle_builds([SwDefine.SWBuildCreator(Vector2i.ZERO, ROBOT_DEF)], [_w(robot_cell)])

	var at_box = _sys.get_entity_at(_w(box_cell))
	var at_robot = _sys.get_entity_at(_w(robot_cell))
	assert_not_null(at_box, "箱子模板没有放出箱子")
	assert_not_null(at_robot, "机器人模板没有放出机器人")
	if at_box != null:
		assert_eq(str(at_box.kind), "box", "箱子模板放出来的不是箱子")
	if at_robot != null:
		assert_eq(str(at_robot.kind), "robot", "机器人模板放出来的不是机器人")


# ===== 7. 场景状态往返 =====

func test_scene_state_roundtrip_keeps_boxes() -> void:
	var robot = _sys.spawn_robot(_w(Vector2i(2, 2)), 1)
	var box = _sys.spawn_box(_w(Vector2i(5, 3)))
	assert_not_null(robot)
	assert_not_null(box)

	var data: Dictionary = _sys.to_dict()
	assert_eq(int(data.get("version", 0)), 2, "场景状态版本号应当升到 2")
	assert_eq((data.get("robots", []) as Array).size(), 1, "状态里应当有一台机器人")
	assert_eq((data.get("boxes", []) as Array).size(), 1, "状态里应当有一个箱子")

	# 另一套系统当作「重新进入场景」
	var other = ENTITY_SYSTEM.new()
	assert_eq(other.load_from_dict(data), 1, "恢复出来的机器人数不对")
	assert_eq(other.get_entity_count(), 2, "恢复后应当是 1 机器人 + 1 箱子")
	var rb = other.get_entity_at(_w(Vector2i(5, 3)))
	assert_not_null(rb, "箱子没恢复回来")
	if rb != null:
		assert_eq(str(rb.kind), "box", "恢复出来的不是箱子")
		assert_false(rb.has_bundle(), "箱子不该绑上电路")
	other.clear_entities()


# 旧存档（version 1）没有 boxes 字段：必须当空数组读，不能报错也不能清空机器人
func test_old_state_without_boxes_loads() -> void:
	var n: int = _sys.load_from_dict({
		"version": 1,
		"robots": [{"x": 1, "y": 2, "dir": 0, "circuit": ""}],
	})
	assert_eq(n, 1, "旧状态里的机器人应当照常读回来")
	assert_eq(_sys.get_entity_count(), 1, "旧状态不该凭空多出实体")
