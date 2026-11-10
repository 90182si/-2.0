class_name SWExprDescribe extends RefCounted

# 把元件上的求值表达式树（SWBuildCompoentCircuit.pinExprMap）格式化成可读文本，
# 供鼠标悬浮提示显示「这个元件到底在算什么」。
#
# 表达式树是电路构建时 getBuildExpr() 递归建好的，这里**只读不重建**：
# 重建会动 _buildingExpr / in_loop 标记，悬浮提示不该有副作用。
#
# 输出形态（每个已构建表达式的端口一行，方向是世界方向）：
#   非门  (3, 4)
#     下↓ NAND(开关[上])
#   灯泡  (5, 4)
#     左← AND(非门[上])
#     右→ AND(开关[左])
#
# 子表达式复用：同一个节点被 ≥2 个父引用（扇出共享）时，正文里只写 $n，
# 真正的式子摊到最后的定义区。编号按「先内后外」后序分配，所以定义行只会
# 引用比它更小的编号，不会前向引用：
#   灯泡  (5, 4)
#     上↑ AND($1, 开关[下])
#     左← AND($1, 开关[下])
#     $1 = NAND(开关[上], 开关[右])
# 这样既不省略任何一层，也不会把同一棵子树铺满屏幕。
# 注意编号作用域是「同一个元件」：每个元件有自己的 pinExprMap，互不共享编号。
#
# 简化表达式：同一份元件会再算一遍化简后的式子（NOT(NOT(x)) → x、NAND(x) → NOT(x)、
# AND(x) → x、AND 去重/常量折叠）。化简只用于**显示**，求值层的化简在
# SWGateOptimizer 里（那一层能省的只有 op 改写，见该文件注释）。
# 两份一样时只输出一份，免得悬停面板白占两屏。

# 化简产物里的常量节点名（gate 层没有「常量 1」的写法，但表达式树可以有）
const CONST_TRUE := "__CONST_1__"
const CONST_FALSE := "__CONST_0__"
const FUNC_AND := "SwCommon.AndValues"
const FUNC_NAND := "SwCommon.NotAndValues"
const FUNC_NOT := "SwCommon.NotValues"
# 下面四个不是 SwCommon 里的函数（元件只有与/与非/非三套口子），而是化简器用
# De Morgan 与 XOR 标准式**认出来**的等价形态：
#   OR(a,b)  = NAND(NOT a, NOT b)
#   NOR(a,b) = AND(NOT a, NOT b)
#   XOR(a,b) = NAND(NAND(a, t), NAND(b, t))，t = NAND(a, b)
#   XNOR(a,b)= NOT(XOR(a,b))
# 它们只用于悬停文本（更短、更像人写的式子），求值依旧走 gate 表/DAG。
const FUNC_OR := "OR"
const FUNC_NOR := "NOR"
const FUNC_XOR := "XOR"
const FUNC_XNOR := "XNOR"

# 接口元件的「接口: move（输出）」行；非接口元件返回空串
static func _io_name_line(build:SWBuildItemDefine) -> String:
	if build == null or build.buildDefine == null:
		return ""
	var comp_type:int = build.buildDefine.circuit_component_type
	var kind := ""
	if comp_type == SwDefine.CircuitComponentType.EXTERNAL_INPUT:
		kind = "输入"
	elif comp_type == SwDefine.CircuitComponentType.EXTERNAL_OUTPUT:
		kind = "输出"
	else:
		return ""
	var io_name := str(build.get("io_name"))
	if io_name.is_empty():
		return "接口: （未命名）"
	return "接口: %s（%s）" % [io_name, kind]

# 元件层运算函数 → 显示名（SwCommon 里的那些）
const OP_NAMES:Dictionary = {
	FUNC_AND: "AND",
	FUNC_NAND: "NAND",
	FUNC_NOT: "NOT",
	"SwCommon.EqualValues": "EQ",
}
# 世界方向 → 行首标记（SwDefine.SW_Dir：UP=0 RIGHT=1 DOWN=2 LEFT=3）
const DIR_ARROWS:Array[String] = ["上↑", "右→", "下↓", "左←"]
const DIR_NAMES:Array[String] = ["上", "右", "下", "左"]

static func dir_name(d:int) -> String:
	if d < 0 or d >= DIR_NAMES.size():
		return "?"
	return DIR_NAMES[d]

# 一个建筑 → 多行文本。没有表达式（未接电路 / 纯导体 / 空壳元件）也会给出原因，
# 免得玩家以为提示坏了。
# 接口元件（输入/输出接口）额外补一行接口名：元件定义名已合并成「输出接口」，
# 光看元件名分不出这是 move 还是 rotation（名字是实例属性）
static func describe_build(build:SWBuildItemDefine) -> String:
	if build == null or build.buildDefine == null:
		return ""
	var cell:Vector2i = build.buildAxisPos / SwDefine.GRID_SIZE
	var head := "%s  (%d, %d)" % [build.buildDefine.buildName, cell.x, cell.y]
	var io_line := _io_name_line(build)
	if not io_line.is_empty():
		head += "\n" + io_line
	var comp := build.getCircuitCompoent() as SWBuildCompoentCircuit
	if comp == null:
		return head + "\n（没有电路组件）"
	if comp.pinExprMap.is_empty():
		if SwCommon.IsWireBuild(build):
			return head + "\n导体：只连通，不参与运算"
		return head + "\n（还没有构建表达式）"
	var dirs:Array = comp.pinExprMap.keys()
	dirs.sort()
	var roots:Array = []
	for d:int in dirs:
		roots.append(comp.pinExprMap[d])
	var raw := _ports_and_defs(roots, comp, "$")
	var lines:PackedStringArray = [head]
	# 环上的表达式不化简（化简组合环没有意义，也容易把环改形）
	var cyclic := false
	for root in roots:
		if _has_cycle(root, {}):
			cyclic = true
			break
	if cyclic:
		lines.append_array(_format_block(dirs, raw[0], raw[1]))
		return "\n".join(lines)

	# 化简版：元件树层的等价化简（只用于显示，不改 pinExprMap 里的原树）
	var simple_roots:Array = simplify_all(roots)
	# 先用同一个前缀生成，才能判断「化简有没有真的改变内容」；一变就变
	var simple := _ports_and_defs(simple_roots, comp, "$")
	var raw_lines:PackedStringArray = _format_block(dirs, raw[0], raw[1])
	var simple_lines:PackedStringArray = _format_block(dirs, simple[0], simple[1])
	if raw_lines == simple_lines:
		#没化简出东西：只给一份，别拿两块一模一样的文本刷屏
		lines.append_array(raw_lines)
		return "\n".join(lines)
	# 编号前缀用 #：两块文本里的 $1 / #1 是各自独立的定义，前缀相同会让人以为同一回事
	var renamed := _ports_and_defs(simple_roots, comp, "#")
	lines.append("[原式]")
	lines.append_array(raw_lines)
	lines.append("[简化]")
	lines.append_array(_format_block(dirs, renamed[0], renamed[1]))
	return "\n".join(lines)

# 表达式树里有没有组合环（有环就整体不化简，免得把环改形）
static func _has_cycle(cir, visiting:Dictionary) -> bool:
	if not (cir is SwDefine.SWCircuitStruct):
		return false
	if visiting.has(cir):
		return true
	visiting[cir] = true
	for arg in cir.args:
		if arg is SwDefine.SWCircuitStruct and _has_cycle(arg, visiting):
			visiting.erase(cir)
			return true
	visiting.erase(cir)
	return false

# 每个端口一行（方向前缀 + 表达式）+ 定义区
static func _format_block(dirs:Array, ports:PackedStringArray,
		defs:PackedStringArray) -> PackedStringArray:
	var out:PackedStringArray = []
	for i:int in mini(dirs.size(), ports.size()):
		out.append("%s %s" % [_arrow(dirs[i]), ports[i]])
	out.append_array(defs)
	return out

# 一组表达式根 → [端口文本, 定义区行]
static func _ports_and_defs(roots:Array, comp:SWBuildCompoentCircuit, prefix:String) -> Array:
	var ctx := _make_ctx(roots, prefix)
	var ports:PackedStringArray = []
	for root in roots:
		ports.append(format_struct(root, comp, ctx))
	var defs:PackedStringArray = []
	for def_line:String in ctx["defs"]:
		if not def_line.is_empty():
			defs.append(def_line)
	return [ports, defs]

# 排版上下文：
#   refs    ：节点 → 被几个父引用（判定共享用）
#   ids     ：节点 → 编号（1 起，只收共享节点）
#   defs    ：编号 → 定义行文本
#   defined ：已铺开过的共享节点（之后一律写 $n）
#   visiting：正在展开的节点（撞上就是组合环）
#   prefix  ：编号前缀（原式用 $，简化块用 #）
static func _make_ctx(roots:Array, prefix:String = "$") -> Dictionary:
	var refs:Dictionary = {}
	# 同一个节点被多个端口直接引用也算共享（化简后很常见：几个端口折成同一个节点）
	for root in roots:
		if root is SwDefine.SWCircuitStruct:
			refs[root] = int(refs.get(root, 0)) + 1
	var visited:Dictionary = {}
	for root in roots:
		_count_refs(root, refs, visited)
	var ids:Dictionary = {}
	for root in roots:
		_number_shared(root, refs, ids, {})
	var defs:Array = []
	defs.resize(ids.size())
	defs.fill("")
	return {"refs": refs, "ids": ids, "defs": defs, "defined": {}, "visiting": {},
			"prefix": prefix}

# 数「父 → 子」的边：每个节点只遍历一次，被 ≥2 个父指向才算共享
# （入参不加类型标注：化简会把整棵子树折成单个引脚叶子，根节点就不再是 SWCircuitStruct）
static func _count_refs(cir, refs:Dictionary, visited:Dictionary) -> void:
	if not (cir is SwDefine.SWCircuitStruct) or visited.has(cir):
		return
	visited[cir] = true
	for arg in cir.args:
		if arg is SwDefine.SWCircuitStruct:
			refs[arg] = int(refs.get(arg, 0)) + 1
			_count_refs(arg, refs, visited)

# 后序编号（先子后父）：父的定义里引用子时，子的编号一定更小、定义一定更靠前。
# ⚠ 即使本节点不值得编号（端口根节点本来就没被别的父引用）也必须往下走，
#   否则子树里的共享节点永远薅不到编号。
static func _number_shared(cir, refs:Dictionary, ids:Dictionary, visiting:Dictionary) -> void:
	if not (cir is SwDefine.SWCircuitStruct) or visiting.has(cir) or ids.has(cir):
		return
	visiting[cir] = true
	for arg in cir.args:
		if arg is SwDefine.SWCircuitStruct:
			_number_shared(arg, refs, ids, visiting)
	visiting.erase(cir)
	if _is_shared(cir, refs):
		ids[cir] = ids.size() + 1

# 值得编号的：被 ≥2 个父引用，且不是「摊平就剩一个引脚」的短叶子（编号反而更长）
static func _is_shared(cir:SwDefine.SWCircuitStruct, refs:Dictionary) -> bool:
	if cir == null or int(refs.get(cir, 0)) < 2:
		return false
	return not _is_plain_leaf(cir)

# EQ 只有一个自源叶子（开关按下 / 寄存器 Q）：摊平后就是那个叶子本身
static func _is_plain_leaf(cir:SwDefine.SWCircuitStruct) -> bool:
	return cir.optFuncName == "SwCommon.EqualValues" and cir.args.size() == 1 \
		and cir.args[0] is SwDefine.SWBuildPinStruct

# 一层表达式。不做深度截断（玩家要看完整式子）；防无限递归靠 visiting 记环。
# 传空字典当 ctx 就是「不编号」的老用法：直接整棵展开。
static func format_struct(cir, comp:SWBuildCompoentCircuit, ctx:Dictionary) -> String:
	if cir == null:
		return "—"
	#化简会把整棵子树折成单个引脚叶子（AND(x) → x），这里要能直接显示它
	if cir is SwDefine.SWBuildPinStruct:
		return _pin_text(cir, comp)
	#化简产物里的常量（表达式树能表达「恒 1」，gate 层表不了，所以只在文本层出现）
	var cval:int = _const_of(cir)
	if cval >= 0:
		return "1" if cval == 1 else "0"
	var visiting:Dictionary = ctx.get("visiting", ctx)
	if visiting.has(cir):
		#组合环：这棵子树正在展开中，再往下就是无限递归
		return "↺"
	var ids:Dictionary = ctx.get("ids", {})
	var prefix:String = ctx.get("prefix", "$")
	if ids.has(cir):
		var id:int = ids[cir]
		var defined:Dictionary = ctx["defined"]
		if defined.has(cir):
			return "%s%d" % [prefix, id]
		#首次用到：正文只留 $n，真正的式子摊到最后的定义区
		defined[cir] = true
		visiting[cir] = true
		var body := _format_body(cir, comp, ctx)
		visiting.erase(cir)
		ctx["defs"][id - 1] = "%s%d = %s" % [prefix, id, body]
		return "%s%d" % [prefix, id]
	if _is_plain_leaf(cir):
		return _pin_text(cir.args[0], comp)
	visiting[cir] = true
	var text := _format_body(cir, comp, ctx)
	visiting.erase(cir)
	return text

# 运算节点 → "NAME(a, b)"；空输入要写成常量 0（悬空 net 为低电平）
static func _format_body(cir:SwDefine.SWCircuitStruct, comp:SWBuildCompoentCircuit,
	ctx:Dictionary) -> String:
	var parts:PackedStringArray = []
	for arg in cir.args:
		if arg is SwDefine.SWBuildPinStruct:
			parts.append(_pin_text(arg, comp))
		elif arg is SwDefine.SWCircuitStruct:
			parts.append(format_struct(arg, comp, ctx))
	var op_name:String = OP_NAMES.get(cir.optFuncName, cir.optFuncName)
	#非门用的是「线与后取反」：只有一个输入时它就是 NOT，多输入才是 NAND，分开写更好读
	if cir.optFuncName == "SwCommon.NotAndValues" and parts.size() <= 1:
		op_name = "NOT"
	if parts.is_empty():
		return "%s()=0" % op_name
	return "%s(%s)" % [op_name, ", ".join(parts)]

# 叶子：某个建筑的某个引脚
static func _pin_text(pin:SwDefine.SWBuildPinStruct, comp:SWBuildCompoentCircuit) -> String:
	var b:SWBuildItemDefine = pin.build
	if b == null:
		return "?"
	if b == comp.buildRef:
		#自源叶子：读自己的状态（开关/按钮的按下状态、寄存器的 Q）
		return "自身[%s]" % dir_name(pin.dir)
	var name:String = "?" if b.buildDefine == null else b.buildDefine.buildName
	return "%s[%s]" % [name, dir_name(pin.dir)]

static func _arrow(d:int) -> String:
	if d < 0 or d >= DIR_ARROWS.size():
		return "?"
	return DIR_ARROWS[d]


# ==========================================================================
# 表达式树化简（只用于悬停面板的「简化」那一块，不碰 pinExprMap 里的原树）
#
# 规则与求值层的 SWGateOptimizer 同源，但这里能表达更多：gate 表只能改写 op，
# 树可以直接把子树换成常量、把两层门压成一层，还能把 NAND/NOT 搭出来的组合
# 认成高级门（引擎没有 OR/XOR 原语，它们只是同一批门的等价昵称）。
#   1. NOT(NOT(x))     → x          ← 用户点名的双非门抵消
#   2. NOT(NAND(…))    → AND(…)     把取反推下去，少一层
#   3. NOT(AND(…))     → NAND(…)    同上，两级门压成一级
#   4. NOT(OR/NOR/XOR/XNOR) → NOR/OR/XNOR/XOR    取反穿过一级
#   5. NAND(x)         → NOT(x)     单个输入时它就是非门
#   6. AND(x) / OR(x) / XOR(x) → x  单输入线与/线或/异或都是直通
#   7. AND/OR 去重、XOR 按奇偶消项（XOR(a,a)→0）
#   8. NAND(NOT a, NOT b) → OR(a,b)         ← 用户点名的「or 就是 nand(not,not)」
#   9. AND(NOT a, NOT b)  → NOR(a,b)        同一套 De Morgan 往另一边推
#  10. NAND(NAND(a,t), NAND(b,t)), t=NAND(a,b) → XOR(a,b)   4-NAND 标准式识别
#  11. AND(…, 0, …) → 0；AND/OR 里的 1 / 0 直接折掉；空输入 AND=0、NAND=1、OR=0、NOR=1
#  12. NOT(0) / NOT(1) → 1 / 0
# 环上的节点一律原样保留（化简组合环没有意义）。
# ==========================================================================

# 不动点迭代的硬上限：正常一两轮就收敛，这里只是死循环保险
const MAX_SIMPLIFY_PASSES := 16

# 把一组表达式根化简到不动点（用户要求：一直折到简化量为 0）。
# 为什么要多轮：一轮后序遍历虽然能处理任意深度，但折叠会**改变节点形态**，
# 由此又露出新的可折形态（例如 NOT(AND(…)) 压成 NAND 后，外面那层 NOT 又能
# 把 NAND 折成 AND），不动点迭代把这类连锁全部吃掉。
# 每轮重新建 memo：上一轮的对象身份已经变了，沿用会错位。
static func simplify_all(roots:Array) -> Array:
	var cur:Array = roots.duplicate()
	for _pass in MAX_SIMPLIFY_PASSES:
		var memo:Dictionary = {}
		var counter:Dictionary = {"n": 0}
		var next:Array = []
		for root in cur:
			next.append(simplify(root, memo, {}, counter))
		cur = next
		if int(counter["n"]) == 0:
			break   # 本轮一个节点都没被改写 = 已到不动点
	return cur

# 两棵树结构上是否等价（元素按对象身份比）。
# 化简器返回节点时为了不改原树总是新建对象，光看「是不是同一个对象」会把
# 没改内容的轮次也算成改动，于是永远收敛不了。
static func _same_node(a, b) -> bool:
	if a == b:
		return true
	if not (a is SwDefine.SWCircuitStruct and b is SwDefine.SWCircuitStruct):
		return false
	if a.optFuncName != b.optFuncName or a.args.size() != b.args.size():
		return false
	for i in a.args.size():
		if a.args[i] != b.args[i]:
			return false
	return true

# 把一棵表达式树化简成等价的更短形式。
# 返回值可能是 SWCircuitStruct，也可能被折叠成单个 SWBuildPinStruct 叶子（AND(x) → x）。
# memo 保证「同一个原节点只化简一次」：共享子表达式化简后仍是同一个对象，
# 于是一个 $n 编号机制照旧生效。
# counter 非空时累加本轮真正发生了改写的节点数（不动点判据）。
static func simplify(cir, memo:Dictionary, visiting:Dictionary, counter:Dictionary = {}):
	if cir == null:
		return null
	# 已经是叶子（引脚 / 常量）：不动点迭代的第二轮会直接把上一轮折出来的叶子传进来
	if not (cir is SwDefine.SWCircuitStruct):
		return cir
	if memo.has(cir):
		return memo[cir]
	if visiting.has(cir):
		#组合环：原样保留，否则就是无限递归
		memo[cir] = cir
		return cir
	visiting[cir] = true
	var kids:Array = []
	for arg in cir.args:
		if arg is SwDefine.SWCircuitStruct:
			kids.append(simplify(arg, memo, visiting))
		else:
			kids.append(arg)
	visiting.erase(cir)
	var out = _fold(cir.optFuncName, kids, cir)
	memo[cir] = out
	if not counter.is_empty() and not _same_node(out, cir):
		counter["n"] = int(counter["n"]) + 1
	return out

static func _fold(name:String, kids:Array, orig):
	match name:
		FUNC_AND:
			return _fold_and(kids, orig, false)
		FUNC_NAND:
			return _fold_and(kids, orig, true)
		FUNC_NOT:
			return _fold_not(kids, orig)
		FUNC_OR:
			return _fold_or(kids, orig, false)
		FUNC_NOR:
			return _fold_or(kids, orig, true)
		FUNC_XOR:
			return _fold_xor(kids, orig, false)
		FUNC_XNOR:
			return _fold_xor(kids, orig, true)
	return _make(name, kids, orig)

# AND / NAND 共用一套折况（NAND 只是结果取反）
static func _fold_and(kids:Array, orig, negate:bool):
	var kept:Array = []
	for k in kids:
		var c:int = _const_of(k)
		if c == 0:
			#与门里出现恒 0 → 整体恒 0；NAND 是它的取反 → 恒 1
			return _const(1 if negate else 0)
		if c == 1:
			continue     #与恒 1 相与等于自身，直接去掉
		if not kept.has(k):
			kept.append(k)   #去重：AND(a, a) 与 AND(a) 等价
	if kept.is_empty():
		#没有输入（或全被去掉）：AND = 0（悬空 net 为低电平），NAND = 1
		return _const(1 if negate else 0)
	if kept.size() == 1 and kept[0] is SwDefine.SWCircuitStruct:
		if negate:
			return _fold_not(kept, kept[0])      #NAND(x) = NOT(x)
		return kept[0]                            #AND(x) = x
	#4-NAND 异或标准式：NAND(NAND(a,t), NAND(b,t)), t = NAND(a,b) → XOR(a,b)
	if negate:
		var xr = _match_xor(kept)
		if xr != null:
			return _make(FUNC_XOR, xr, orig)
	#De Morgan：输入全都带非门时，取反推下去就成了一级线或
	#   NAND(NOT a, NOT b) → OR(a,b)    ← 用户点名的「or 就是 nand(not,not)」
	#   AND(NOT a, NOT b)  → NOR(a,b)
	var all_not:bool = kept.size() >= 2
	var inner:Array = []
	if all_not:
		for kn in kept:
			if not (kn is SwDefine.SWCircuitStruct) or kn.optFuncName != FUNC_NOT \
					or kn.args.size() != 1:
				all_not = false
				break
			inner.append(kn.args[0])
	if all_not:
		return _fold_or(inner, orig, not negate)
	return _make(FUNC_NAND if negate else FUNC_AND, kept, orig)

static func _fold_not(kids:Array, orig):
	if kids.size() != 1:
		return _make(FUNC_NOT, kids, orig)
	var k = kids[0]
	var c:int = _const_of(k)
	if c == 0:
		return _const(1)
	if c == 1:
		return _const(0)
	if k is SwDefine.SWCircuitStruct:
		match k.optFuncName:
			FUNC_NOT:
				#NOT(NOT(x)) → x
				if k.args.size() == 1:
					return k.args[0]
			FUNC_NAND:
				#NOT(NAND(…)) → AND(…)：把取反推下去，少一层
				return _fold_and(k.args, k, false)
			FUNC_AND:
				#NOT(AND(…)) → NAND(…)：同上，两级门压成一级
				return _fold_and(k.args, k, true)
			FUNC_OR:
				#NOT(OR(…)) → NOR(…)：取反穿过一级，门层数不变但更好读
				return _fold_or(k.args, k, true)
			FUNC_NOR:
				#NOT(NOR(…)) → OR(…)
				return _fold_or(k.args, k, false)
			FUNC_XOR:
				#NOT(XOR(…)) → XNOR(…)
				return _fold_xor(k.args, k, true)
			FUNC_XNOR:
				#NOT(XNOR(…)) → XOR(…)
				return _fold_xor(k.args, k, false)
	return _make(FUNC_NOT, kids, orig)

# OR / NOR 共用一套折况（NOR 只是结果取反）
static func _fold_or(kids:Array, orig, negate:bool):
	var kept:Array = []
	for k in kids:
		var c:int = _const_of(k)
		if c == 1:
			#或门里出现恒 1 → 整体恒 1；NOR 是它的取反 → 恒 0
			return _const(0 if negate else 1)
		if c == 0:
			continue     #或恒 0 等于自身，直接去掉
		if not kept.has(k):
			kept.append(k)   #去重：OR(a, a) 与 OR(a) 等价
	if kept.is_empty():
		#没有输入（或全被去掉）：OR = 0（悬空 net 为低电平），NOR = 1
		return _const(1 if negate else 0)
	if kept.size() == 1 and kept[0] is SwDefine.SWCircuitStruct:
		if negate:
			return _fold_not(kept, kept[0])      #NOR(x) = NOT(x)
		return kept[0]                            #OR(x) = x
	return _make(FUNC_NOR if negate else FUNC_OR, kept, orig)

# XOR / XNOR 共用一套折况（XNOR 只是结果取反）
static func _fold_xor(kids:Array, orig, negate:bool):
	var kept:Array = []
	var flip:bool = false
	for k in kids:
		var c:int = _const_of(k)
		if c == 1:
			flip = not flip    #异或恒 1 = 取反，翻一次奇偶
			continue
		if c == 0:
			continue           #异或恒 0 = 原样，直接去掉
		var at:int = kept.find(k)
		if at < 0:
			kept.append(k)
			continue
		kept.remove_at(at)     #XOR(a, a) = 0：同一项出现两次就消掉
	if flip:
		negate = not negate
	if kept.is_empty():
		#没有剩项：XOR = 0，XNOR = 1（flip 已经把取反算进 negate 了）
		return _const(1 if negate else 0)
	if kept.size() == 1 and kept[0] is SwDefine.SWCircuitStruct:
		if negate:
			return _fold_not(kept, kept[0])      #XNOR(x) = NOT(x)
		return kept[0]                            #XOR(x) = x
	return _make(FUNC_XNOR if negate else FUNC_XOR, kept, orig)

# 4-NAND 异或标准式识别（保守：只认同一个对象构成的共享子式）
#   NAND(NAND(a,t), NAND(b,t)) 且 t = NAND(a,b)  →  [a, b]
# 认不出就返回 null：宁可少认一种写法，也不能把不是异或的式子写成 XOR。
# 之所以要 t 恰好是 NAND(a,b)：少了这条，随便两个共用输入的与非门都会被当成异或。
static func _match_xor(kept:Array):
	if kept.size() != 2:
		return null
	var p = kept[0]
	var q = kept[1]
	if not (p is SwDefine.SWCircuitStruct) or not (q is SwDefine.SWCircuitStruct):
		return null
	if p.optFuncName != FUNC_NAND or q.optFuncName != FUNC_NAND:
		return null
	if p.args.size() != 2 or q.args.size() != 2:
		return null
	var t = null
	var a = null
	var b = null
	for i in 2:
		for j in 2:
			if p.args[i] != q.args[j]:
				continue
			#t 是两个内层共用的那一项，a / b 是各自独有的那一项
			t = p.args[i]
			a = p.args[1 - i]
			b = q.args[1 - j]
			break
		if t != null:
			break
	#a == b（两个内层完全一样）根本不是异或，按保守原则放弃
	if t == null or a == null or b == null or a == b:
		return null
	if not (t is SwDefine.SWCircuitStruct) or t.optFuncName != FUNC_NAND \
			or t.args.size() != 2:
		return null
	if not ((t.args[0] == a and t.args[1] == b) or (t.args[0] == b and t.args[1] == a)):
		return null
	return [a, b]

# 化简产物的常量识别（-1 = 不是常量）
static func _const_of(k) -> int:
	if k is SwDefine.SWCircuitStruct:
		if k.optFuncName == CONST_TRUE:
			return 1
		if k.optFuncName == CONST_FALSE:
			return 0
	return -1

static func _const(v:int) -> SwDefine.SWCircuitStruct:
	var cir := SwDefine.SWCircuitStruct.new()
	cir.optFuncName = CONST_TRUE if v != 0 else CONST_FALSE
	cir.args = []
	return cir

static func _make(name:String, kids:Array, orig) -> SwDefine.SWCircuitStruct:
	var cir := SwDefine.SWCircuitStruct.new()
	cir.optFuncName = name
	cir.args = kids
	# optFunc 只给本来就有的同名节点用（格式化不读它，但万一有人拿简化树求值也不会错）
	if orig != null and orig.optFuncName == name:
		cir.optFunc = orig.optFunc
	else:
		cir.optFunc = _func_of(name)
	return cir

static func _func_of(name:String) -> Callable:
	match name:
		FUNC_AND: return SwCommon.AndValues
		FUNC_NAND: return SwCommon.NotAndValues
		FUNC_NOT: return SwCommon.NotValues
		"SwCommon.EqualValues": return SwCommon.EqualValues
		#OR/NOR/XOR/XNOR 不是元件原语，只是化简器认出来的等价形态，求值要自己兜住
		FUNC_OR: return func(args): return _or_values(args)
		FUNC_NOR: return func(args): return _nor_values(args)
		FUNC_XOR: return func(args): return _xor_values(args)
		FUNC_XNOR: return func(args): return _xnor_values(args)
	return Callable()

# ---- OR/NOR/XOR/XNOR 的求值（只当自洽保险：显示层从不求简化树） ----
# 引脚直接读电平，语义与 SwCommon.EqualValues 一致；其余交给 EvalStruct 递归
static func _eval_arg(k) -> int:
	if k is SwDefine.SWBuildPinStruct:
		return SwCommon.EqualValues([k])
	return SwCommon.EvalStruct(k)

static func _or_values(args:Array) -> int:
	for arg in args:
		if _eval_arg(arg) != 0:
			return 1
	return 0

static func _nor_values(args:Array) -> int:
	return 1 - _or_values(args)

static func _xor_values(args:Array) -> int:
	var v:int = 0
	for arg in args:
		v ^= _eval_arg(arg) & 1
	return v

static func _xnor_values(args:Array) -> int:
	return 1 - _xor_values(args)
