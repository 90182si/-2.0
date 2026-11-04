extends GutTest
# 电线拖拽路径规划契约（SWWireDragPlan 纯逻辑，不拉起游戏场景）：
#   1. 一条折线最多拐一次 90°，格子连续无缺口；
#   2. 中间被挡的段落自动换成一对隧道（近端+远端），被挡的格子本身不落子；
#   3. 被挡段落跨度上限 SwDefine.MAX_TUNNEL_DIS（4 格），超出整条判非法（预览要变红）；
#   4. 端点被占、隧道无处可放、阻挡段正好压在拐弯处 —— 都判非法；
#   5. 已经是同一种电线的格子算「通」（标 KEEP，不重复落子），另一种电线算阻挡；
#   6. 拐点默认「长边先走」；玩家把鼠标踩到哪个候选拐点上就从哪个拐，
#      **后踩到的顶掉先踩到的**（可以拖回去改主意），两个都没踩到就保持原走法。
#      拐点离起点不足 MIN_LOCK_LEG 格不算（按下时的鼠标抖动）。
#   7. 预览线正穿过另一条电线（只走垂直轴）→ 相交那一格换成电线桥梁（两条线各走各的 net）；
#      同轴（顺着别人延长）、双轴（三通 / 已是桥梁）都不放桥。
#   8. 按 Ctrl（replace）：路面上的建筑直接拆掉换成电线，不再排隧道跳，端点被占也照抢。
#   9. 拐点那一格只要有任何东西（建筑 / 别人的电线 / 已铺的同种电线）就整条判非法（预览红线），
#      因为隧道跨不过拐弯、桥梁又会在同一格里把本线拆成两截；Ctrl 覆盖例外。
#  10. 要被隧道跨过去的只有「真挡路」的格子；能换桥的交叉电线不是挡路，逐条障碍段扫到它
#      就停——它要是恰好当隧道出口，一格放不下隧道+桥，整条判非法。
#   godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://test/circuit -gprefix=test_wire_drag_plan -gexit

const Plan := preload("res://layers/hold/sw_wire_drag_plan.gd")

#用字典搭一张假地图：键 = 格子，值 = 该格的占用状态（缺省 0 = FREE）
#查询方法必须挂在测试自己身上：内部类实例是 RefCounted，而 Callable 不持有 RefCounted
#强引用，函数一返回对象就被释放，之后 probe.is_valid() 永远是 false（探针踩过这个坑）
var _occ: Dictionary = {}

func _state_of(cell: Vector2i) -> int:
	return int(_occ.get(cell, 0))

func _probe(occ: Dictionary) -> Callable:
	_occ = occ
	return Callable(self, "_state_of")

func _free(from: Vector2i, to: Vector2i) -> Dictionary:
	return Plan.plan(from, to, _probe({}))

func _kinds(res: Dictionary) -> Array:
	return res["kinds"]

func _cells(res: Dictionary) -> Array:
	return res["cells"]

#隧道方向契约：出口在 rotation+1，所以近端的出口必须指向行进方向，远端的出口必须指回来
func _assert_tunnel_rotations(res: Dictionary, note: String) -> void:
	var cells: Array = res["cells"]
	var kinds: Array = res["kinds"]
	var rots: Array = res["rots"]
	for i in cells.size():
		if kinds[i] != Plan.PlaceKind.TUNNEL:
			continue
		#找同一行/同一列里另一个隧道，算出「朝对方」的方向
		var partner: Vector2i = Vector2i.ZERO
		for j in cells.size():
			if j == i or kinds[j] != Plan.PlaceKind.TUNNEL:
				continue
			if cells[j].y == cells[i].y or cells[j].x == cells[i].x:
				partner = cells[j]
				break
		var toward := Vector2i(signi(partner.x - cells[i].x), signi(partner.y - cells[i].y))
		var d: int = Plan.dir_of(toward)
		assert_eq(posmod(int(rots[i]) + 1, 4), d, "%s：rotation 应当让出口朝对方" % note)

# 1) 直线一笔：每格都是电线，没有隧道
func test_straight_drag_places_wire_on_every_cell() -> void:
	var res := _free(Vector2i(0, 0), Vector2i(5, 0))
	assert_true(res["valid"], "空格直线拖拽应当合法")
	assert_eq(_cells(res).size(), 6, "6 格拖拽应当落 6 根电线")
	for k in _kinds(res):
		assert_eq(k, Plan.PlaceKind.WIRE, "全空格时不该出现隧道")
	assert_eq(res["jumped"].size(), 0, "没有障碍不该有跳过的格子")
	assert_eq(res["line"].size(), 2, "直线不该有拐点")

# 2) 拐一次弯：先走长边，格子数 = |dx|+|dy|+1，方向只变一次
func test_l_path_turns_exactly_once() -> void:
	var res : Dictionary = Plan.plan(Vector2i(0, 0), Vector2i(4, 3), _probe({}))
	assert_true(res["valid"])
	assert_eq(_cells(res).size(), 4 + 3 + 1, "折线覆盖格子数应当是两边之和加起点")
	var line: Array = res["line"]
	assert_eq(line.size(), 3, "拐弯一次应当给出三个点")
	assert_eq(line[0], Vector2i(0, 0), "折线从按下点起")
	assert_eq(line[1], Vector2i(4, 0), "横着拖得更远就先走完横边")
	assert_eq(line[2], Vector2i(4, 3), "再拐到松开点")
	#方向变化次数：从第一段步进方向开始数，之后每变一次算一次拐弯
	#（起始方向本身不是拐弯，别把它算进去）
	var turns := 0
	var path: Array = res["path"]
	var last_step: Vector2i = path[1] - path[0]
	for i in range(2, path.size()):
		var step: Vector2i = path[i] - path[i - 1]
		if step != last_step:
			turns += 1
			last_step = step
	assert_eq(turns, 1, "产品要求：一条路线只转一次 90 度")

# 3) 单个障碍：自动用一对隧道跨过去，障碍格不落子
func test_single_blocked_cell_jumps_with_tunnel_pair() -> void:
	var occ := {Vector2i(2, 0): Plan.CellState.BLOCKED}
	var res : Dictionary = Plan.plan(Vector2i(0, 0), Vector2i(5, 0), _probe(occ))
	assert_true(res["valid"], "挡 1 格在跨度以内，应当合法")
	assert_eq(_cells(res).size(), 5, "6 格里被挡的 1 格不落子")
	var jumped: Array = res["jumped"]
	assert_eq(jumped.size(), 1, "被跨过的格子要记录下来")
	assert_eq(jumped[0], Vector2i(2, 0), "跳过的应当正好是障碍那一格")
	var kinds: Array = res["kinds"]
	assert_eq(kinds[1], Plan.PlaceKind.TUNNEL, "障碍前一格应当放近端隧道")
	assert_eq(kinds[2], Plan.PlaceKind.TUNNEL, "障碍后一格应当放远端隧道")
	assert_eq(kinds[0], Plan.PlaceKind.WIRE, "没参与跨栏的格子还是电线")
	assert_eq(res["path"].size(), 6, "预览折线仍然经过被挡的格子（线要连着画过去）")
	_assert_tunnel_rotations(res, "跨 1 格")

# 4) 跨度上限：正好 4 格能跨，5 格就判非法（预览红线）
func test_blocked_span_at_max_is_valid() -> void:
	var occ := {}
	for x in range(2, 6):
		occ[Vector2i(x, 0)] = Plan.CellState.BLOCKED
	var res : Dictionary = Plan.plan(Vector2i(0, 0), Vector2i(8, 0), _probe(occ))
	assert_eq(SwDefine.MAX_TUNNEL_DIS, 4, "隧道跨度上限改了要同步改这条用例")
	assert_true(res["valid"], "挡 4 格正好是隧道上限，应当合法：%s" % str(res["reason"]))
	assert_eq(res["jumped"].size(), 4, "4 格障碍应被整体跳过")
	assert_eq(_cells(res).size(), 9 - 4, "被挡的 4 格不落子，隧道占掉挡前挡后两格")

func test_blocked_span_over_max_is_invalid() -> void:
	var occ := {}
	for x in range(2, 7):
		occ[Vector2i(x, 0)] = Plan.CellState.BLOCKED
	var res : Dictionary = Plan.plan(Vector2i(0, 0), Vector2i(9, 0), _probe(occ))
	assert_false(res["valid"], "挡 5 格超出隧道跨度，不能放")
	assert_eq(res["reason"], Plan.REASON_SPAN_TOO_LONG, "失败原因应当是跨度超限")
	assert_eq(_cells(res).size(), 0, "非法结果不该给出落子表")

# 5) 端点被占：起点或终点都没法落子
func test_occupied_endpoint_is_invalid() -> void:
	var at_end : Dictionary = Plan.plan(Vector2i(0, 0), Vector2i(3, 0),
		_probe({Vector2i(3, 0): Plan.CellState.BLOCKED}))
	assert_false(at_end["valid"], "终点被占应当非法")
	assert_eq(at_end["reason"], Plan.REASON_END_OCCUPIED)
	var at_start : Dictionary = Plan.plan(Vector2i(0, 0), Vector2i(3, 0),
		_probe({Vector2i(0, 0): Plan.CellState.BLOCKED}))
	assert_false(at_start["valid"], "起点被占应当非法")
	assert_eq(at_start["reason"], Plan.REASON_END_OCCUPIED)

# 6) 同一种电线已经在路上：算通，标 KEEP 不重复落子
func test_same_wire_cells_are_kept() -> void:
	var occ := {Vector2i(2, 0): Plan.CellState.SAME}
	var res : Dictionary = Plan.plan(Vector2i(0, 0), Vector2i(4, 0), _probe(occ))
	assert_true(res["valid"], "已有同种电线不算阻挡")
	var kinds: Array = res["kinds"]
	assert_eq(kinds[2], Plan.PlaceKind.KEEP, "那一格什么都不用放")
	assert_eq(res["jumped"].size(), 0, "不该被当成障碍跳过去")

# 已有电线紧挨着障碍时，近端隧道没地方放（那一格已被自己的电线占着）
func test_same_wire_before_blocked_run_has_no_room() -> void:
	var occ := {
		Vector2i(1, 0): Plan.CellState.SAME,
		Vector2i(2, 0): Plan.CellState.BLOCKED,
	}
	var res : Dictionary = Plan.plan(Vector2i(0, 0), Vector2i(4, 0), _probe(occ))
	assert_false(res["valid"], "近端格子放不下隧道，应当整条判非法")
	assert_eq(res["reason"], Plan.REASON_NO_ROOM)

# 两段障碍中间只隔一格：那一格要同时当出口隧道和入口隧道，放不下
func test_two_jumps_sharing_one_cell_is_invalid() -> void:
	var occ := {
		Vector2i(1, 0): Plan.CellState.BLOCKED,
		Vector2i(3, 0): Plan.CellState.BLOCKED,
	}
	var res : Dictionary = Plan.plan(Vector2i(0, 0), Vector2i(5, 0), _probe(occ))
	assert_false(res["valid"], "一格放不下两根隧道，应当判非法")
	assert_eq(res["reason"], Plan.REASON_NO_ROOM)

# 7) 障碍压在拐点上：拐点必须空着才能摆，直接判非法（预览红线）
func test_blocked_run_across_corner_is_invalid() -> void:
	var occ := {
		Vector2i(1, 0): Plan.CellState.BLOCKED,
		Vector2i(2, 0): Plan.CellState.BLOCKED,
	}
	var res : Dictionary = Plan.plan(Vector2i(0, 0), Vector2i(2, 2), _probe(occ))
	assert_false(res["valid"], "拐点那一格被挡，应当判非法")
	assert_eq(res["reason"], Plan.REASON_CORNER_OCCUPIED, "失败原因应当记在拐点被占")

# 8) 格子与世界坐标来回换算（含负方向：地图是无限的了，负半边必须也对）
func test_cell_world_roundtrip() -> void:
	for cell in [Vector2i(0, 0), Vector2i(7, -3), Vector2i(-12, 45), Vector2i(-1, -1)]:
		assert_eq(Plan.cell_of(Vector2(Plan.world_of(cell)) + Vector2(63, 63)), cell,
			"格内任意一点都该换算回同一格")
	assert_eq(Plan.cell_of(Vector2(Plan.world_of(Vector2i(-1, -1)))), Vector2i(-1, -1),
		"负坐标不能因为整除截断偏一格")

# probe 没接上（纯逻辑或依赖缺失）时退化成全空格，不报错
func test_without_probe_everything_is_free() -> void:
	var res : Dictionary = Plan.plan(Vector2i(0, 0), Vector2i(2, 2), Callable())
	assert_true(res["valid"])
	assert_eq(_cells(res).size(), 5, "|dx|+|dy|+1 = 5")

# 9) 拐点选法：锁过的走法高于「长边先走」的自动规则
func test_locked_corner_mode_overrides_auto() -> void:
	var auto_res : Dictionary = Plan.plan(Vector2i(0, 0), Vector2i(2, 5), _probe({}))
	assert_eq(auto_res["line"][1], Vector2i(0, 5), "默认长边先走：竖边比横边长就先走竖边")
	var horiz : Dictionary = Plan.plan(Vector2i(0, 0), Vector2i(2, 5),
		_probe({}), Plan.CornerMode.HORIZ_FIRST)
	assert_eq(horiz["line"][1], Vector2i(2, 0), "锁了先横：拐点定在起点那一行的末端")
	var vert : Dictionary = Plan.plan(Vector2i(0, 0), Vector2i(5, 2),
		_probe({}), Plan.CornerMode.VERT_FIRST)
	assert_eq(vert["line"][1], Vector2i(0, 2), "锁了先竖：拐点定在起点那一列的末端")
	assert_eq(_cells(vert).size(), 5 + 2 + 1, "换一个拐点不该改变要落的格子总数")

# 10) 拖拽手势判锁：玩家把鼠标踩到哪个候选拐点上就从哪个拐（visited 按经过顺序）
func test_corner_lock_gesture() -> void:
	var a := Vector2i(0, 0)
	var along_h: Array[Vector2i] = [a, Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0), Vector2i(3, 1)]
	assert_eq(Plan.lock_by_corner_visit(a, Vector2i(3, 1), along_h, Plan.CornerMode.AUTO),
		Plan.CornerMode.HORIZ_FIRST, "踩过 (3,0) 再往下折：拐点应当锁在 (3,0)")
	var along_v: Array[Vector2i] = [a, Vector2i(0, 1), Vector2i(0, 2), Vector2i(0, 3), Vector2i(1, 3)]
	assert_eq(Plan.lock_by_corner_visit(a, Vector2i(1, 3), along_v, Plan.CornerMode.AUTO),
		Plan.CornerMode.VERT_FIRST, "踩过 (0,3) 再往右折：拐点应当锁在 (0,3)")
	var jitter: Array[Vector2i] = [a, Vector2i(1, 0), Vector2i(1, 1)]
	assert_eq(Plan.lock_by_corner_visit(a, Vector2i(1, 1), jitter, Plan.CornerMode.AUTO),
		Plan.CornerMode.AUTO, "只拖开一格就折，多半是鼠标抖动，不能锁")
	var diagonal: Array[Vector2i] = [a, Vector2i(1, 0), Vector2i(2, 1), Vector2i(3, 1), Vector2i(4, 1)]
	assert_eq(Plan.lock_by_corner_visit(a, Vector2i(4, 1), diagonal, Plan.CornerMode.AUTO),
		Plan.CornerMode.AUTO, "斜着拖出去（没踩到候选拐点）不算拐这一刀")
	var back_h: Array[Vector2i] = [a, Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1), Vector2i(3, 1)]
	assert_eq(Plan.lock_by_corner_visit(a, Vector2i(3, 1), back_h, Plan.CornerMode.AUTO),
		Plan.CornerMode.AUTO, "从竖边直接跳回横边也不算锁")

# 11) 「后踩到的说了算」：先扫过 A 拐点、再扫过 B 拐点，最终听 B；掉头扫回去又能听回 A
func test_later_visited_corner_wins() -> void:
	var a := Vector2i(0, 0)
	var target := Vector2i(4, 4)
	#先沿第 0 行出去（踩过横拐点 (4,0)），再回到第 0 列（踩过竖拐点 (0,4)）：后踩的是竖
	var h_then_v: Array[Vector2i] = [a, Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0), Vector2i(4, 0),
		Vector2i(4, 1), Vector2i(4, 2), Vector2i(4, 3), Vector2i(4, 4),
		Vector2i(3, 4), Vector2i(2, 4), Vector2i(1, 4), Vector2i(0, 4)]
	assert_eq(Plan.lock_by_corner_visit(a, target, h_then_v, Plan.CornerMode.AUTO),
		Plan.CornerMode.VERT_FIRST, "先扫横拐点再扫竖拐点：后者说了算")
	#顺序反过来：后踩的是横拐点
	var v_then_h: Array[Vector2i] = [a, Vector2i(0, 1), Vector2i(0, 2), Vector2i(0, 3), Vector2i(0, 4),
		Vector2i(1, 4), Vector2i(2, 4), Vector2i(3, 4), Vector2i(4, 4),
		Vector2i(4, 3), Vector2i(4, 2), Vector2i(4, 1), Vector2i(4, 0)]
	assert_eq(Plan.lock_by_corner_visit(a, target, v_then_h, Plan.CornerMode.AUTO),
		Plan.CornerMode.HORIZ_FIRST, "先扫竖拐点再扫横拐点：后者说了算")
	#都没踩到时保持上一轮锁的那个，不能自动翻回 AUTO
	var none: Array[Vector2i] = [a, Vector2i(1, 1), Vector2i(2, 2)]
	assert_eq(Plan.lock_by_corner_visit(a, target, none, Plan.CornerMode.VERT_FIRST),
		Plan.CornerMode.VERT_FIRST, "这一轮两个候选都没踩到，保持原锁")

# 12) 拖快时鼠标事件会跳格：line_cells 要把中间点补齐（不含起点、含终点）
func test_line_cells_fills_gaps() -> void:
	var straight: Array[Vector2i] = Plan.line_cells(Vector2i(0, 0), Vector2i(3, 0))
	assert_eq(straight, ([Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0)] as Array[Vector2i]),
		"横着跳 3 格要补出中间两格，终点算经过、起点不算")
	var diagonal: Array[Vector2i] = Plan.line_cells(Vector2i(0, 0), Vector2i(2, 2))
	assert_eq(diagonal, ([Vector2i(1, 1), Vector2i(2, 2)] as Array[Vector2i]),
		"斜着跳也要补点，否则漏掉鼠标擦过拐点那一下")
	assert_eq(Plan.line_cells(Vector2i(5, 5), Vector2i(5, 5)).size(), 0, "原地不动不补点")

# 13) 相交换桥梁：横着拖过去，正压在一条竖着的电线上 → 那一格放桥，两条线各走各的 net
func test_perpendicular_wire_becomes_bridge() -> void:
	var occ := {Vector2i(2, 0): Plan.CellState.SAME | Plan.CELL_WIRE_VERT}
	var res : Dictionary = Plan.plan(Vector2i(0, 0), Vector2i(5, 0), _probe(occ))
	assert_true(bool(res["valid"]), "垂直相交可以换桥，不该判非法：%s" % str(res["reason"]))
	var kinds: Array = res["kinds"]
	assert_eq(kinds[2], Plan.PlaceKind.BRIDGE, "相交那一格应当换成桥梁")
	assert_eq(kinds[1], Plan.PlaceKind.WIRE, "不相交的格子还是电线")
	assert_eq(res["jumped"].size(), 0, "换桥就接得过去，不该再排隧道")
	assert_eq(_cells(res).size(), 6, "桥梁那一格照样要落子（把原来的电线顶掉）")
	assert_eq(res["rots"][2], 0, "桥梁横竖是绝对方向，不给旋转")

# 另一种电线（电线A 遇上电线B）本来就不与本线相连，相交同样换成桥——
# 桥的 v_net / h_net 各走一头，换完两条线仍然互不相干
func test_other_wire_type_crossing_also_bridges() -> void:
	var occ := {Vector2i(2, 0): Plan.CellState.BLOCKED | Plan.CELL_WIRE_VERT}
	var res : Dictionary = Plan.plan(Vector2i(0, 0), Vector2i(5, 0), _probe(occ))
	assert_true(bool(res["valid"]), "别的电线能换桥接上，不该判非法：%s" % str(res["reason"]))
	assert_eq(res["kinds"][2], Plan.PlaceKind.BRIDGE)

# 端点正好落在别人的竖线上：直线一笔没有真拐点，这一格照样算相交而不是堵
func test_straight_drag_endpoint_on_perpendicular_wire_bridges() -> void:
	var occ := {Vector2i(3, 0): Plan.CellState.SAME | Plan.CELL_WIRE_VERT}
	var res : Dictionary = Plan.plan(Vector2i(0, 0), Vector2i(3, 0), _probe(occ))
	assert_true(bool(res["valid"]), "端点换桥能接上，不该判端点被占：%s" % str(res["reason"]))
	assert_eq(res["kinds"][3], Plan.PlaceKind.BRIDGE, "终点应当换成桥梁收尾")

# 顺着别人延长（同轴）与三通 / 已是桥梁（双轴）都不能换成桥：
# 前者本来就连着，后者换桥会把别人已有的一条线并进我们这条线
func test_same_axis_and_double_axis_are_not_bridged() -> void:
	var along : Dictionary = Plan.plan(Vector2i(0, 0), Vector2i(4, 0),
		_probe({Vector2i(2, 0): Plan.CellState.SAME | Plan.CELL_WIRE_HORZ}))
	assert_eq(along["kinds"][2], Plan.PlaceKind.KEEP, "同轴的电线本来就连着，什么都不用放")
	var tee : Dictionary = Plan.plan(Vector2i(0, 0), Vector2i(4, 0),
		_probe({Vector2i(2, 0): Plan.CellState.SAME
			| Plan.CELL_WIRE_HORZ | Plan.CELL_WIRE_VERT}))
	assert_eq(tee["kinds"][2], Plan.PlaceKind.KEEP, "三通 / 已有桥梁那格别动")

# 拐点那一格只要有任何元件就整条判非法（预览红线）：
# 隧道跨不过拐弯，桥梁又会在同一格里把本线拆成两截，宁可红也不能放出一条不通的线
func test_corner_cell_must_be_empty() -> void:
	var wire := {Vector2i(3, 0): Plan.CellState.SAME | Plan.CELL_WIRE_VERT}
	var res : Dictionary = Plan.plan(Vector2i(0, 0), Vector2i(3, 4),
		_probe(wire), Plan.CornerMode.HORIZ_FIRST)
	assert_false(bool(res["valid"]), "拐点压在同种电线上也不能放")
	assert_eq(res["reason"], Plan.REASON_CORNER_OCCUPIED)
	assert_eq(res["line"][1], Vector2i(3, 0), "红线仍然画到那个拐点上")
	assert_eq(res["cells"].size(), 0, "非法结果不该给出落子表")
	#建筑物压在拐点上同样非法
	var by_build := {Vector2i(3, 0): Plan.CellState.BLOCKED}
	var deny : Dictionary = Plan.plan(Vector2i(0, 0), Vector2i(3, 4),
		_probe(by_build), Plan.CornerMode.HORIZ_FIRST)
	assert_eq(deny["reason"], Plan.REASON_CORNER_OCCUPIED, "建筑压在拐点上也要变红")
	#Ctrl 覆盖例外：那一格会被拆掉重放电线，线仍然是连续的
	var forced : Dictionary = Plan.plan(Vector2i(0, 0), Vector2i(3, 4),
		_probe(by_build), Plan.CornerMode.HORIZ_FIRST, true)
	assert_true(bool(forced["valid"]), "Ctrl 覆盖可以把拐点上那件拆掉重放：%s" % str(forced["reason"]))
	assert_eq(forced["kinds"][3], Plan.PlaceKind.WIRE, "覆盖后拐点那一格是电线")

# 拐点禁桥：真拐弯的那一格永远不会被规划成桥梁
func test_corner_cell_is_never_bridged() -> void:
	var occ := {Vector2i(3, 0): Plan.CellState.SAME | Plan.CELL_WIRE_VERT}
	var res : Dictionary = Plan.plan(Vector2i(0, 0), Vector2i(3, 4),
		_probe(occ), Plan.CornerMode.HORIZ_FIRST, true)
	assert_true(bool(res["valid"]), "%s" % str(res["reason"]))
	for k in res["kinds"]:
		assert_ne(k, Plan.PlaceKind.BRIDGE, "拐角格不能被换成桥梁")

# 相交判定本身的契约（只有单一垂直轴才算）
func test_is_crossing_rules() -> void:
	var H := Plan.CELL_WIRE_HORZ
	var V := Plan.CELL_WIRE_VERT
	var blocked := Plan.CellState.BLOCKED
	var same := Plan.CellState.SAME
	assert_true(Plan.is_crossing(same | V, H, false), "走横边压到竖线：相交")
	assert_true(Plan.is_crossing(blocked | H, V, false), "走竖边压到横线：相交")
	assert_false(Plan.is_crossing(same | V, V, false), "顺着竖线延长：不相交")
	assert_false(Plan.is_crossing(same | V, V, true), "拐角格永不相交")
	assert_false(Plan.is_crossing(same | H | V, V, false), "双轴（三通 / 桥梁）不动")
	assert_false(Plan.is_crossing(same, H, false), "没带走向标记（孤立电线 / 老用法）不算相交")
	assert_false(Plan.is_crossing(blocked, V, false), "建筑物没有走向，仍然是挡路")
	assert_false(Plan.is_crossing(Plan.CellState.FREE | V, H, false), "空格谈不上相交")

# 13) Ctrl 覆盖：路面上的建筑拆掉换成电线，端点被占也照抢，不再排隧道
func test_replace_mode_overrides_blocked_buildings() -> void:
	var occ := {
		Vector2i(0, 0): Plan.CellState.BLOCKED,
		Vector2i(2, 0): Plan.CellState.BLOCKED,
		Vector2i(5, 0): Plan.CellState.BLOCKED,
	}
	var keep_end : Dictionary = Plan.plan(Vector2i(0, 0), Vector2i(6, 0), _probe(occ))
	assert_false(bool(keep_end["valid"]), "不覆盖时端点被占就该判非法：%s" % str(keep_end["reason"]))
	assert_eq(keep_end["reason"], Plan.REASON_END_OCCUPIED)
	var res : Dictionary = Plan.plan(Vector2i(0, 0), Vector2i(6, 0), _probe(occ),
		Plan.CornerMode.AUTO, true)
	assert_true(bool(res["valid"]), "按了 Ctrl 端点也要抢下来：%s" % str(res["reason"]))
	assert_eq(res["jumped"].size(), 0, "覆盖模式下不绕路，不该有跳过的格子")
	for k in res["kinds"]:
		assert_eq(k, Plan.PlaceKind.WIRE, "每一格都该直接放电线，不再排隧道")
	assert_eq(_cells(res).size(), 7, "七格全落子")

# 覆盖模式不影响桥梁优先：相交那一格还是放桥，不是拿电线把别人顶掉
func test_replace_mode_still_prefers_bridge() -> void:
	var occ := {
		Vector2i(1, 0): Plan.CellState.SAME | Plan.CELL_WIRE_VERT,
		Vector2i(2, 0): Plan.CellState.BLOCKED,
	}
	var res : Dictionary = Plan.plan(Vector2i(0, 0), Vector2i(4, 0), _probe(occ),
		Plan.CornerMode.AUTO, true)
	assert_eq(res["kinds"][1], Plan.PlaceKind.BRIDGE, "相交优先于覆盖")
	assert_eq(res["kinds"][2], Plan.PlaceKind.WIRE, "建筑物那格在覆盖模式下换成电线")

# 14) 终点压在别人的垂直电线上（本来该换桥），前面又整段被挡住：
#     这段障碍不能一路吃进终点（曾经把扫描拖到 cells.size() → cells[j] 越界崩溃），
#     而且隧道出口与桥抢同一格，物理上无解 → 判非法
func test_blocked_run_up_to_crossing_end_is_invalid() -> void:
	var occ := {
		Vector2i(0, 1): Plan.CellState.BLOCKED,
		Vector2i(0, 2): Plan.CellState.BLOCKED,
		Vector2i(0, 3): Plan.CellState.BLOCKED | Plan.CELL_WIRE_HORZ,
	}
	var res : Dictionary = Plan.plan(Vector2i(0, 0), Vector2i(0, 3), _probe(occ))
	assert_false(bool(res["valid"]), "隧道出口顶在交叉电线上，放不下")
	assert_eq(res["reason"], Plan.REASON_NO_ROOM)
	assert_eq(res["cells"].size(), 0, "非法结果不落子")

# 障碍段中间夹着一根可换桥的垂直电线：它不算被跨的格子，也不许当隧道出口
func test_crossing_wire_stops_the_tunnel_span() -> void:
	var occ := {
		Vector2i(2, 0): Plan.CellState.BLOCKED,
		Vector2i(3, 0): Plan.CellState.BLOCKED | Plan.CELL_WIRE_VERT,
		Vector2i(4, 0): Plan.CellState.BLOCKED,
	}
	var res : Dictionary = Plan.plan(Vector2i(0, 0), Vector2i(6, 0), _probe(occ))
	assert_false(bool(res["valid"]), "隧道出口那格要换桥，一格放不下两样东西：%s" % str(res["reason"]))
	assert_eq(res["reason"], Plan.REASON_NO_ROOM)
	assert_eq(res["jumped"].size(), 0, "判非法时不该记账跳过任何格子")
