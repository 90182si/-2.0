extends GutTest
# 悬浮表达式文本契约（SWExprDescribe 纯格式化 + HUD 右上角面板）：
#   1. 头行是「名称  (格子x, 格子y)」，格子 = buildAxisPos / GRID_SIZE；
#   2. 每个已构建表达式的端口一行，行首是行进方向（上↑ / 右→ / 下↓ / 左←）；
#   3. 叶子写「来源元件[方向]」；指向自己的叶子写「自身[方向]」（开关按下 / 寄存器 Q）；
#   4. 单输入的「线与后取反」显示 NOT，多输入显示 NAND；空输入的 AND 显示 AND()=0
#      （悬空 net 为低电平，不是恒真）；
#   5. 表达式要完整展开，**不许用 … 省略**（只有成环才用 ↺ 刹车）；
#      没有组件 / 没有表达式 / 导体 都给一句原因；
#   6. 共享子表达式只展开一次：正文写 $n，定义统一放最后（编号先内后外，不会前向引用）；
#      只有「一个引脚」的短叶子不编号（给它编号反而更长）。
#   7. 化简表达式：NOT(NOT(x))→x、NOT(NAND)→AND、NOT(AND)→NAND、NAND(x)→NOT(x)、
#      AND(x)→x、AND 去重/常量折叠；多轮折到不动点（简化量为 0 才停）；
#      化简只用于显示，原式照旧完整输出；
#      两块文本不同时才分块给，且简化块用 # 前缀编号（与 $ 不混）。
#   7b. 高级门昵称：NAND(NOT a, NOT b)→OR、AND(NOT a, NOT b)→NOR、
#      NAND(NAND(a,t),NAND(b,t)) 且 t=NAND(a,b) → XOR、取反则得或非/同或；
#      引擎只有与/与非/非三个原语，这些名字只是同一批门的等价写法（求值仍走门表）。
#   8. HUD 右上角面板：show 之后可见且文本与 describe 一致，传 null 就收起。
# 跑法：godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://test/circuit -gprefix=test_expr_describe -gexit

const DESC := preload("res://circuit/sw_expr_describe.gd")
const HUD_SCRIPT := preload("res://layers/hud/sw_hud_layer.gd")
const LED_DEF: SWBuildDefine = preload("res://res/灯泡.tres")
const SWITCH_DEF: SWBuildDefine = preload("res://res/开关.tres")
const WIRE_DEF: SWBuildDefine = preload("res://res/电线A.tres")

#手搓一层表达式节点（optFunc 不填：格式化只看 optFuncName）
func _struct(func_name: String, args: Array) -> SwDefine.SWCircuitStruct:
	var cir := SwDefine.SWCircuitStruct.new()
	cir.optFuncName = func_name
	cir.args = args
	return cir

func _pin(build: SWBuildItemDefine, dir: int) -> SwDefine.SWBuildPinStruct:
	return SwDefine.SWBuildPinStruct.new(build, dir)

func _led() -> SWBuildItemDefine:
	return SwDefine.SWBuildCreator(Vector2i(5, 4) * SwDefine.GRID_SIZE, LED_DEF, 0)

# 1) 一层与门：来源引脚要写清是哪个元件从哪个方向来的
func test_format_leaf_and() -> void:
	var sw := SwDefine.SWBuildCreator(Vector2i.ZERO, SWITCH_DEF, 0)
	var cir := _struct("SwCommon.AndValues", [_pin(sw, SwDefine.SW_Dir.UP)])
	assert_eq(DESC.format_struct(cir, _led().getCircuitCompoent(), {}), "AND(开关[上])")

# 2) 嵌套 + 非门显示名：单输入 NOT / 多输入 NAND
func test_format_nested_and_not() -> void:
	var sw := SwDefine.SWBuildCreator(Vector2i.ZERO, SWITCH_DEF, 0)
	var comp := _led().getCircuitCompoent()
	var not1 := _struct("SwCommon.NotAndValues", [_pin(sw, SwDefine.SW_Dir.DOWN)])
	assert_eq(DESC.format_struct(not1, comp, {}), "NOT(开关[下])", "只有一个输入时它就是 NOT")
	var nand2 := _struct("SwCommon.NotAndValues", [_pin(sw, SwDefine.SW_Dir.UP), _pin(sw, SwDefine.SW_Dir.RIGHT)])
	assert_eq(DESC.format_struct(nand2, comp, {}), "NAND(开关[上], 开关[右])", "多输入才是 NAND")
	var outer := _struct("SwCommon.AndValues", [not1, _pin(sw, SwDefine.SW_Dir.LEFT)])
	assert_eq(DESC.format_struct(outer, comp, {}), "AND(NOT(开关[下]), 开关[左])", "子树要递归展开")

# 3) 自源叶子、空输入、空表达式
func test_format_self_pin_and_empty() -> void:
	var led := _led()
	var comp := led.getCircuitCompoent()
	var eq := _struct("SwCommon.EqualValues", [_pin(led, SwDefine.SW_Dir.RIGHT)])
	assert_eq(DESC.format_struct(eq, comp, {}), "自身[右]", "指向自己的 EQ 摊平成「自身」")
	assert_eq(DESC.format_struct(_struct("SwCommon.AndValues", []), comp, {}), "AND()=0",
		"没有输入的与门恒低，不能显示成恒真")
	assert_eq(DESC.format_struct(null, comp, {}), "—", "空表达式给占位符")

# 4) 组合环：显示 ↺，不能无限递归下去
func test_format_cycle_shows_loop_mark() -> void:
	var a := _struct("SwCommon.AndValues", [])
	var b := _struct("SwCommon.AndValues", [])
	a.args = [b]
	b.args = [a]
	assert_eq(DESC.format_struct(a, _led().getCircuitCompoent(), {}), "AND(AND(↺))",
		"成环的子树上要打环标记")

# 4b) 深链不截断：整棵式子铺开，不能拿 … 糊弄（有 visiting 记环就不会无限递归）
func test_deep_chain_is_not_truncated() -> void:
	var sw := SwDefine.SWBuildCreator(Vector2i.ZERO, SWITCH_DEF, 0)
	var comp := _led().getCircuitCompoent()
	var inner := _struct("SwCommon.AndValues", [_pin(sw, SwDefine.SW_Dir.UP)])
	for i in 20:
		inner = _struct("SwCommon.AndValues", [inner])
	var text := DESC.format_struct(inner, comp, {})
	assert_false(text.contains("…"), "深链不能被 … 截掉：%s" % text)
	assert_eq(text.count("AND("), 21, "21 层 AND 要一层不少地展开")

# 4c) 共享子表达式：正文两处都写 $1，真正的式子只在定义区出现一次
func test_shared_subexpr_is_defined_once() -> void:
	var sw := SwDefine.SWBuildCreator(Vector2i.ZERO, SWITCH_DEF, 0)
	var led := _led()
	var comp := led.getCircuitCompoent()
	var inner := _struct("SwCommon.NotAndValues",
		[_pin(sw, SwDefine.SW_Dir.UP), _pin(sw, SwDefine.SW_Dir.RIGHT)])
	comp.pinExprMap[SwDefine.SW_Dir.UP] = _struct("SwCommon.AndValues",
		[inner, _pin(sw, SwDefine.SW_Dir.DOWN)])
	comp.pinExprMap[SwDefine.SW_Dir.LEFT] = _struct("SwCommon.AndValues",
		[inner, _pin(sw, SwDefine.SW_Dir.DOWN)])
	var text := DESC.describe_build(led)
	assert_eq(text.count("NAND("), 1, "共享子表达式只完整展开一次：\n%s" % text)
	assert_eq(text.count("$1"), 3, "两处引用 + 一行定义")
	assert_true(text.contains("$1 = NAND(开关[上], 开关[右])"), "定义区要写成 $n = …")

# 4d) 嵌套共享：先内后外编号，父的定义只引用比它小的编号；
#     同时验证化简块用 # 前缀、与原式的 $ 不混。
func test_nested_shared_definition_order() -> void:
	var sw := SwDefine.SWBuildCreator(Vector2i.ZERO, SWITCH_DEF, 0)
	var led := _led()
	var comp := led.getCircuitCompoent()
	var inner := _struct("SwCommon.NotAndValues", [_pin(sw, SwDefine.SW_Dir.UP)])
	var parent := _struct("SwCommon.AndValues", [inner, inner])
	comp.pinExprMap[SwDefine.SW_Dir.UP] = _struct("SwCommon.AndValues", [parent])
	comp.pinExprMap[SwDefine.SW_Dir.LEFT] = _struct("SwCommon.AndValues", [parent])
	assert_eq(DESC.describe_build(led),
		"灯泡  (5, 4)\n[原式]\n上↑ AND($2)\n左← AND($2)\n$1 = NOT(开关[上])\n$2 = AND($1, $1)"
		+ "\n[简化]\n上↑ #1\n左← #1\n#1 = NOT(开关[上])",
		"编号先内后外，定义不会前向引用；化简把 AND(x,x)/AND(x) 压成 x")

# 4e) 不共享不出编号；只有一个引脚的短叶子也不编号
func test_no_numbering_when_not_worth_it() -> void:
	var sw := SwDefine.SWBuildCreator(Vector2i.ZERO, SWITCH_DEF, 0)
	var led := _led()
	var comp := led.getCircuitCompoent()
	comp.pinExprMap[SwDefine.SW_Dir.UP] = _struct("SwCommon.AndValues", [_pin(sw, SwDefine.SW_Dir.UP)])
	comp.pinExprMap[SwDefine.SW_Dir.LEFT] = _struct("SwCommon.AndValues", [_pin(sw, SwDefine.SW_Dir.DOWN)])
	assert_false(DESC.describe_build(led).contains("$"), "没有共享就不该冒出编号")

	var led2 := _led()
	var comp2 := led2.getCircuitCompoent()
	var leaf := _struct("SwCommon.EqualValues", [_pin(led2, SwDefine.SW_Dir.UP)])
	comp2.pinExprMap[SwDefine.SW_Dir.UP] = _struct("SwCommon.AndValues", [leaf])
	comp2.pinExprMap[SwDefine.SW_Dir.LEFT] = _struct("SwCommon.AndValues", [leaf])
	assert_eq(DESC.describe_build(led2),
		"灯泡  (5, 4)\n[原式]\n上↑ AND(自身[上])\n左← AND(自身[上])"
		+ "\n[简化]\n上↑ 自身[上]\n左← 自身[上]",
		"摊平就剩一个引脚的短叶子不编号")

# 4f) 双非门抵消：用户点名的简化规则
func test_simplify_not_not_cancels() -> void:
	var sw := SwDefine.SWBuildCreator(Vector2i.ZERO, SWITCH_DEF, 0)
	var comp := _led().getCircuitCompoent()
	var pin := _pin(sw, SwDefine.SW_Dir.UP)
	var not1 := _struct(DESC.FUNC_NOT, [pin])
	var not2 := _struct(DESC.FUNC_NOT, [not1])
	assert_eq(DESC.format_struct(DESC.simplify(not2, {}, {}), comp, {}), "开关[上]",
		"NOT(NOT(x)) 要直接消成 x")
	var not3 := _struct(DESC.FUNC_NOT, [not2])
	assert_eq(DESC.format_struct(DESC.simplify(not3, {}, {}), comp, {}), "NOT(开关[上])",
		"三层取反只能消两层")

# 4g) 转高级门：NAND(x)→NOT(x)、NOT(NAND(a,b))→AND(a,b)、NOT(AND(a,b))→NAND(a,b)、AND(x)→x
func test_simplify_upgrades_gates() -> void:
	var sw := SwDefine.SWBuildCreator(Vector2i.ZERO, SWITCH_DEF, 0)
	var comp := _led().getCircuitCompoent()
	var p1 := _pin(sw, SwDefine.SW_Dir.UP)
	var p2 := _pin(sw, SwDefine.SW_Dir.RIGHT)
	var nand1 := _struct(DESC.FUNC_NAND, [p1])
	assert_eq(DESC.format_struct(DESC.simplify(nand1, {}, {}), comp, {}), "NOT(开关[上])",
		"单输入的线与后取反就是非门")
	var nand2 := _struct(DESC.FUNC_NAND, [p1, p2])
	var not_nand := _struct(DESC.FUNC_NOT, [nand2])
	assert_eq(DESC.format_struct(DESC.simplify(not_nand, {}, {}), comp, {}),
		"AND(开关[上], 开关[右])", "NOT(NAND(a,b)) 就是与门，少一层")
	var and2 := _struct(DESC.FUNC_AND, [p1, p2])
	var not_and := _struct(DESC.FUNC_NOT, [and2])
	assert_eq(DESC.format_struct(DESC.simplify(not_and, {}, {}), comp, {}),
		"NAND(开关[上], 开关[右])", "NOT(AND(a,b)) 压成与非门，两级变一级")
	var and1 := _struct(DESC.FUNC_AND, [nand2])
	assert_eq(DESC.format_struct(DESC.simplify(and1, {}, {}), comp, {}),
		"NAND(开关[上], 开关[右])", "单输入与门直通到它的唯一输入")

# 4h) AND 去重 / 常量折叠 / 环不动
func test_simplify_dedup_and_const() -> void:
	var sw := SwDefine.SWBuildCreator(Vector2i.ZERO, SWITCH_DEF, 0)
	var comp := _led().getCircuitCompoent()
	var p1 := _pin(sw, SwDefine.SW_Dir.UP)
	var p2 := _pin(sw, SwDefine.SW_Dir.RIGHT)
	var dup := _struct(DESC.FUNC_AND, [p1, p1, p2])
	assert_eq(DESC.format_struct(DESC.simplify(dup, {}, {}), comp, {}),
		"AND(开关[上], 开关[右])", "重复项只留一个")
	assert_eq(DESC.format_struct(DESC.simplify(_struct(DESC.FUNC_AND, []), {}, {}), comp, {}),
		"0", "空输入与门恒低电平")
	assert_eq(DESC.format_struct(DESC.simplify(_struct(DESC.FUNC_NAND, []), {}, {}), comp, {}),
		"1", "空输入线与取反后恒高电平")
	assert_eq(DESC.format_struct(DESC.simplify(_struct(DESC.FUNC_NOT, [_struct(DESC.FUNC_AND, [])]), {}, {}), comp, {}),
		"1", "NOT(0) = 1")
	# 环上的表达式整体不化简：化简会改变环的形状（甚至把环拆掉），所以直接跳过简化那块
	var cyc := _led()
	var ccomp := cyc.getCircuitCompoent()
	var a := _struct(DESC.FUNC_AND, [])
	var b := _struct(DESC.FUNC_NOT, [a])
	a.args = [b]
	assert_true(DESC._has_cycle(a, {}), "成环的表达式要能识别出来")
	ccomp.pinExprMap[SwDefine.SW_Dir.UP] = a
	assert_false(DESC.describe_build(cyc).contains("[简化]"), "有环就不化简")

# 4i) 多轮简化：一直折到简化量为 0（不是只扫一遍）
func test_simplify_runs_until_stable() -> void:
	var sw := SwDefine.SWBuildCreator(Vector2i.ZERO, SWITCH_DEF, 0)
	var comp := _led().getCircuitCompoent()
	var p1 := _pin(sw, SwDefine.SW_Dir.UP)
	var p2 := _pin(sw, SwDefine.SW_Dir.RIGHT)
	# 6 层取反串起来：全要抵消掉
	var node = p1
	for _i in 6:
		node = _struct(DESC.FUNC_NOT, [node])
	var out = DESC.simplify_all([node])[0]
	assert_eq(DESC.format_struct(out, comp, {}), "开关[上]", "偶数层取反要全部抵消")
	# 不动点：再折一次必须一条不改
	var again = DESC.simplify_all([out])[0]
	assert_true(DESC._same_node(again, out), "已到不动点：再化简不再变化")
	# 连锁折叠：NOT(AND(NOT(NAND(a,b)))) 最终只剩一级与非门
	var nand2 := _struct(DESC.FUNC_NAND, [p1, p2])
	var chain := _struct(DESC.FUNC_NOT, [_struct(DESC.FUNC_AND, [_struct(DESC.FUNC_NOT, [nand2])])])
	assert_eq(DESC.format_struct(DESC.simplify_all([chain])[0], comp, {}),
		"NAND(开关[上], 开关[右])", "四层混合门要一层层压到只剩一级")

# 4j) 高级门识别：OR / NOR / XOR / XNOR 不是元件原语，是化简器从 NAND/NOT 组合里认出来的昵称
#     OR(a,b)  = NAND(NOT a, NOT b)        ← 用户点名的「or 就是 nand(not,not)」
#     NOR(a,b) = AND(NOT a, NOT b)  = NOT(OR(a,b))
#     XOR(a,b) = NAND(NAND(a,t), NAND(b,t))，t = NAND(a,b)
#     XNOR     = NOT(XOR)
func test_simplify_recognizes_or_xor() -> void:
	var sw := SwDefine.SWBuildCreator(Vector2i.ZERO, SWITCH_DEF, 0)
	var comp := _led().getCircuitCompoent()
	var p1 := _pin(sw, SwDefine.SW_Dir.UP)
	var p2 := _pin(sw, SwDefine.SW_Dir.RIGHT)

	# or 就是 nand(not, not)
	var or_node := _struct(DESC.FUNC_NAND,
		[_struct(DESC.FUNC_NOT, [p1]), _struct(DESC.FUNC_NOT, [p2])])
	assert_eq(DESC.format_struct(DESC.simplify_all([or_node])[0], comp, {}),
		"OR(开关[上], 开关[右])", "NAND(NOT a, NOT b) 就是或门")

	# 再套一层取反：或非；同一形态换个壳（AND(NOT,NOT)）也是或非
	var nor_node := _struct(DESC.FUNC_NOT, [_struct(DESC.FUNC_NAND,
		[_struct(DESC.FUNC_NOT, [p1]), _struct(DESC.FUNC_NOT, [p2])])])
	assert_eq(DESC.format_struct(DESC.simplify_all([nor_node])[0], comp, {}),
		"NOR(开关[上], 开关[右])", "NOT(OR) 就是或非")
	assert_eq(DESC.format_struct(DESC.simplify_all([_struct(DESC.FUNC_AND,
		[_struct(DESC.FUNC_NOT, [p1]), _struct(DESC.FUNC_NOT, [p2])])])[0], comp, {}),
		"NOR(开关[上], 开关[右])", "AND(NOT a, NOT b) 与 NOR 同义")

	# 4 个与非门搭的异或
	var t := _struct(DESC.FUNC_NAND, [p1, p2])
	var xor_node := _struct(DESC.FUNC_NAND,
		[_struct(DESC.FUNC_NAND, [p1, t]), _struct(DESC.FUNC_NAND, [p2, t])])
	assert_eq(DESC.format_struct(DESC.simplify_all([xor_node])[0], comp, {}),
		"XOR(开关[上], 开关[右])", "NAND(NAND(a,t),NAND(b,t)), t=NAND(a,b) 就是异或")
	assert_eq(DESC.format_struct(DESC.simplify_all([_struct(DESC.FUNC_NOT, [xor_node])])[0], comp, {}),
		"XNOR(开关[上], 开关[右])", "取反异或就是同或")

	# 保守：只是共用了一个普通输入，不能算成异或（否则把与门写成 XOR 就是错的）
	var shared := _pin(sw, SwDefine.SW_Dir.LEFT)
	var fake := _struct(DESC.FUNC_NAND,
		[_struct(DESC.FUNC_NAND, [p1, shared]), _struct(DESC.FUNC_NAND, [p2, shared])])
	assert_eq(DESC.format_struct(DESC.simplify_all([fake])[0], comp, {}),
		"NAND(NAND(开关[上], 开关[左]), NAND(开关[右], 开关[左]))",
		"共用项不是 NAND(a,b) 就不能认成 XOR")

	# 奇偶消项：XOR(a,a)=0、XNOR(a,a)=1、空异或=0
	assert_eq(DESC.format_struct(DESC._fold_xor([p1, p1], null, false), comp, {}), "0",
		"XOR(a, a) = 0")
	assert_eq(DESC.format_struct(DESC._fold_xor([p1, p1], null, true), comp, {}), "1",
		"XNOR(a, a) = 1")
	assert_eq(DESC.format_struct(DESC._fold_xor([], null, false), comp, {}), "0",
		"空异或恒低")

# 5) 整块描述：头行 + 端口行
func test_describe_build_head_and_ports() -> void:
	var sw := SwDefine.SWBuildCreator(Vector2i(2, 3) * SwDefine.GRID_SIZE, SWITCH_DEF, 0)
	var comp := sw.getCircuitCompoent()
	comp.pinExprMap[SwDefine.SW_Dir.UP] = _struct("SwCommon.EqualValues",
		[_pin(sw, SwDefine.SW_Dir.UP)])
	comp.pinExprMap[SwDefine.SW_Dir.DOWN] = _struct("SwCommon.AndValues",
		[_pin(sw, SwDefine.SW_Dir.UP)])
	var text := DESC.describe_build(sw)
	assert_eq(text, "开关  (2, 3)\n上↑ 自身[上]\n下↓ AND(自身[上])",
		"头行带格子坐标，每个已构建端口一行")

# 6) 没东西可显示时也要说清原因，别让玩家以为提示坏了
func test_describe_build_explains_missing() -> void:
	assert_eq(DESC.describe_build(null), "", "空建筑什么都不显示")
	var wire := SwDefine.SWBuildCreator(Vector2i(3, 4) * SwDefine.GRID_SIZE, WIRE_DEF, 0)
	assert_true(DESC.describe_build(wire).contains("导体"), "电线只说它是导体")
	var fresh := SwDefine.SWBuildCreator(Vector2i(0, 0), LED_DEF, 0)
	assert_true(DESC.describe_build(fresh).contains("还没有构建表达式"), "没建过表达式要说清楚")

# 8) HUD 面板：show / hide 与文本一致
func test_hud_panel_show_and_hide() -> void:
	var hud := HUD_SCRIPT.new()
	add_child_autofree(hud)
	assert_false(hud.is_build_expr_visible(), "一开始不该显示")
	var sw := SwDefine.SWBuildCreator(Vector2i(2, 3) * SwDefine.GRID_SIZE, SWITCH_DEF, 0)
	var comp := sw.getCircuitCompoent()
	comp.pinExprMap[SwDefine.SW_Dir.UP] = _struct("SwCommon.EqualValues",
		[_pin(sw, SwDefine.SW_Dir.UP)])
	hud.show_build_expr(sw)
	assert_true(hud.is_build_expr_visible(), "悬浮元件应当显示面板")
	assert_eq(hud.get_build_expr_text(), DESC.describe_build(sw), "面板文本要与格式化一致")
	hud.show_build_expr(null)
	assert_false(hud.is_build_expr_visible(), "鼠标离开要收起面板")
	assert_eq(hud.get_build_expr_text(), "", "收起后不留旧文本")
