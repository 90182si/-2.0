extends GutTest
# 电线拖拽放置的端到端契约（拉起真实场景，但不读存档：在空地图上按格子拖）：
#   1. 按下与拖动阶段地图上一个都不放，只出预览线（不再连续放置）；
#   2. 松手按预览一次放完整条（只拐一次弯的折线）；
#   3. 中间有建筑物阻挡时自动放一对隧道跨过去，两根隧道互相配对、整条电线仍是同一根 net；
#   4. 被挡段落超出隧道跨度（>MAX_TUNNEL_DIS）→ 预览变红，松手什么都不放；
#   5. 拖拽中把鼠标踩到哪个候选拐点上就从哪个拐，**后踩到的顶掉先踩到的**（可以拖回改主意）；
#      两个都没踩到就保持原走法。
#   6. 按住 Ctrl 放在已有元件的格子上 = 拆旧件 + 放新件 + 电路更新（不再落不下）；
#      拖电线遇到挡路建筑时也照抢，不再绕隧道。
#   7. 预览线正穿过另一条电线 → 相交那一格换成电线桥梁：两条线各自连通，
#      而且互不相干（两根独立 net）。
#   8. 拐点那一格压着任何元件（这里用真实电线）→ 预览变红，松手什么都不放。
#   9. 拖拽中按 ESC → 这一笔作废：预览立刻收掉，松手不再落子（按键要被吃掉）。
# 跑法：godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://test/circuit -gprefix=test_wire_drag_place -gexit

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const WIRE_DEF: SWBuildDefine = preload("res://res/电线A.tres")
const BLOCK_DEF: SWBuildDefine = preload("res://res/灯泡.tres")
const SWITCH_DEF: SWBuildDefine = preload("res://res/开关.tres")
const PLAN := preload("res://layers/hold/sw_wire_drag_plan.gd")
const HOLD_VIEW := preload("res://layers/hold/sw_hold_layer.gd")

#一片离任何东西都很远的空地（格子坐标）：本文件不读存档，直接用编号当格子
const BASE_CELL := Vector2i(900, 900)

var harness = null
var _hold = null
var _build = null

func before_each() -> void:
	harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)

func _boot() -> void:
	await harness.boot_game()
	var lm: SWLayerManager = harness.layer_manager
	_hold = lm.holdSystem
	_build = lm.buildSystem
	assert_not_null(_hold, "手持系统没接上")
	assert_not_null(_build, "建造系统没接上")
	#手持电线：与点 HUD 工具按钮走同一个入口
	_hold.set_hold_tool(WIRE_DEF)

func _w(cell: Vector2i) -> Vector2i:
	return cell * SwDefine.GRID_SIZE

#等放置队列跑完（分帧任务：入图 + 电路重建都要过几帧）
func _settle() -> void:
	var guard := 0
	while (_build.is_job_running() or not _build._place_jobs.is_empty()) and guard < 400:
		guard += 1
		await get_tree().process_frame
	assert_lt(guard, 399, "放置任务一直没跑完")

#某格电线/隧道指向的 net（pinNetMap 里第一个非空）
func _net_at(grid_pos: Vector2i) -> SWNet:
	var build = harness.get_build(grid_pos)
	if build == null:
		return null
	var comp = build.getCircuitCompoent()
	if comp == null:
		return null
	for dir in comp.pinNetMap.keys():
		var n: SWNet = comp.pinNetMap[dir]
		if n != null:
			return n
	return null

# 1+2) 按下不放置，松手一次放完整条
func test_release_places_the_whole_previewed_line() -> void:
	await _boot()
	var a := BASE_CELL
	var b := BASE_CELL + Vector2i(4, 3)
	_hold.begin_wire_drag(a)
	_hold.update_wire_drag(b)
	var plan: Dictionary = _hold.get_wire_drag_plan()
	assert_true(bool(plan["valid"]), "空地上拖拽应当合法：%s" % str(plan["reason"]))
	assert_eq(harness.get_build(_w(a)), null, "按下阶段就落了建筑，等于还在连续放置")
	assert_eq(harness.get_build(_w(b)), null, "拖动阶段就把终点的线放下去了")
	assert_true(lm_hold_view().is_wire_preview_visible(), "拖拽中应当显示预览线")
	assert_eq(lm_hold_view().get_wire_preview_color(), HOLD_VIEW.PREVIEW_COLOR_OK, "合法预览不该是红的")
	var expect: int = 4 + 3 + 1
	assert_eq(_hold.finish_wire_drag(), expect, "松手应当按预览一次放完整条")
	await _settle()
	assert_false(lm_hold_view().is_wire_preview_visible(), "落子后预览线没收掉")
	var placed := 0
	for cell: Vector2i in plan["path"]:
		if harness.get_build(_w(cell)) != null:
			placed += 1
	assert_eq(placed, expect, "折线上有格子没放上电线")
	#终点这一格是竖着那段的末端，必须是电线而不是隧道
	var end_build = harness.get_build(_w(b))
	assert_true(end_build is SWBuildWire, "终点应当是电线")

# 3) 中间一格被建筑物挡住：自动补一对隧道，整条电还是通的
func test_drag_jumps_blocking_build_with_paired_tunnel() -> void:
	await _boot()
	var a := BASE_CELL
	var b := BASE_CELL + Vector2i(6, 0)
	var block_cell := BASE_CELL + Vector2i(3, 0)
	#先用真实入口在路中间放个灯泡当障碍
	var blocker := SwDefine.SWBuildCreator(_w(block_cell), BLOCK_DEF, 0)
	assert_true(_build.build_manager.addBuild(blocker), "障碍建筑没能入图")
	_hold.begin_wire_drag(a)
	_hold.update_wire_drag(b)
	var plan: Dictionary = _hold.get_wire_drag_plan()
	assert_true(bool(plan["valid"]), "只挡 1 格，隧道跨得过去：%s" % str(plan["reason"]))
	assert_eq(plan["jumped"].size(), 1, "被挡的那格应当记在 jumped 里")
	assert_eq(_hold.finish_wire_drag(), 7 - 1, "挡着的那格不放，其余 6 格照放")
	await _settle()
	assert_not_null(harness.get_build(_w(block_cell)), "隧道不该把挡路的建筑物顶掉")
	var near := harness.get_build(_w(block_cell + Vector2i(-1, 0))) as SWBuildWireTunnel
	var far := harness.get_build(_w(block_cell + Vector2i(1, 0))) as SWBuildWireTunnel
	assert_not_null(near, "障碍前应当落近端隧道")
	assert_not_null(far, "障碍后应当落远端隧道")
	assert_eq(near.pairId, far.id, "两根隧道没配上对")
	assert_eq(far.pairId, near.id, "反向配对也断了")
	#两根隧道旋转互反：出口都朝对方（见 SWBuildWireTunnel.pinFaces）
	assert_eq(posmod(near.rotation + 1, 4), SwDefine.SW_Dir.RIGHT, "近端出口应当朝行进方向")
	assert_eq(posmod(far.rotation + 1, 4), SwDefine.SW_Dir.LEFT, "远端出口应当朝回近端")
	#电的连通性：隧道是等电位导线，整条线必须落在同一根 net 上
	var head_net := _net_at(_w(a))
	var tail_net := _net_at(_w(b))
	assert_not_null(head_net, "起点电线没有 net，电路没建起来")
	assert_same(head_net, tail_net, "跨过隧道之后电线断成两根 net，等于没接上")

# 4) 挡了一长条（超过隧道跨度）：预览红，松手什么都不放
func test_long_blocked_turns_preview_red_and_places_nothing() -> void:
	await _boot()
	var a := BASE_CELL
	var b := BASE_CELL + Vector2i(2 + SwDefine.MAX_TUNNEL_DIS + 2, 0)
	#连续挡 MAX_TUNNEL_DIS+1 格：隧道跨不过去
	for x in range(a.x + 2, a.x + 2 + SwDefine.MAX_TUNNEL_DIS + 1):
		var block := SwDefine.SWBuildCreator(_w(Vector2i(x, a.y)), BLOCK_DEF, 0)
		assert_true(_build.build_manager.addBuild(block), "障碍建筑没能入图")
	_hold.begin_wire_drag(a)
	_hold.update_wire_drag(b)
	var plan: Dictionary = _hold.get_wire_drag_plan()
	assert_false(bool(plan["valid"]), "障碍段超出隧道跨度，必须判非法")
	assert_eq(plan["reason"], PLAN.REASON_SPAN_TOO_LONG, "失败原因应当记在跨度超限")
	assert_eq(lm_hold_view().get_wire_preview_color(), HOLD_VIEW.PREVIEW_COLOR_BAD, "非法预览线条必须变红")
	assert_eq(_hold.finish_wire_drag(), 0, "红色预览松手不该放任何东西")
	await _settle()
	assert_eq(harness.get_build(_w(a)), null, "非法拖拽还是落子")
	assert_eq(harness.get_build(_w(b)), null, "非法拖拽在终点也落了子")

# 5) 踩拐点：沿起点那一行拖 3 格再折下去，拐点锁在这一刀；之后把竖边拖到远远长于横边，
#    自动规则会翻到另一个拐点，但那个拐点没被踩过，锁定不会翻
func test_passing_through_corner_locks_it_for_the_whole_drag() -> void:
	await _boot()
	var a := BASE_CELL
	_hold.begin_wire_drag(a)
	for x in range(1, 4):
		_hold.update_wire_drag(a + Vector2i(x, 0))
	assert_eq(_hold.get_wire_corner_mode(), PLAN.CornerMode.AUTO, "还没折出去不该提前锁")
	_hold.update_wire_drag(a + Vector2i(3, 1))
	assert_eq(_hold.get_wire_corner_mode(), PLAN.CornerMode.HORIZ_FIRST, "描出来的拐点没锁上")
	var b := a + Vector2i(3, 8)
	_hold.update_wire_drag(b)
	var plan: Dictionary = _hold.get_wire_drag_plan()
	assert_true(bool(plan["valid"]), "锁拐点不影响合法性：%s" % str(plan["reason"]))
	assert_eq(plan["line"].size(), 3, "拐点仍然只拐一次")
	assert_eq(plan["line"][1], a + Vector2i(3, 0), "拐点应当停在描出来的那一格，而不是翻到 (0,8)")
	assert_eq(_hold.finish_wire_drag(), 3 + 8 + 1, "拐点是哪一个不影响要落的格子总数")
	await _settle()
	assert_not_null(harness.get_build(_w(a + Vector2i(3, 0))), "拐点那一格没落子")
	assert_not_null(harness.get_build(_w(b)), "终点没落子")
	assert_eq(harness.get_build(_w(a + Vector2i(0, 8))), null, "另一个拐点（先竖）的格子不该被放")

# 5b) 后踩到的拐点顶掉先踩到的：先扫过横拐点、再扫过竖拐点，就改从竖拐；
#      把鼠标移回横拐点又能改回来（同一笔拖拽里可反复改主意）
func test_later_visited_corner_overrides_the_earlier_one() -> void:
	await _boot()
	var a := BASE_CELL + Vector2i(60, 0)
	_hold.begin_wire_drag(a)
	#先沿第 0 行走出去，踩到横拐点 (4,0)
	for x in range(1, 5):
		_hold.update_wire_drag(a + Vector2i(x, 0))
	_hold.update_wire_drag(a + Vector2i(4, 1))
	assert_eq(_hold.get_wire_corner_mode(), PLAN.CornerMode.HORIZ_FIRST, "先踩到横拐点应当先锁横")
	#再横扫到竖拐点 (0,4)：压上去那一格时路径还是直线（没得选），挪开一格就生效
	_hold.update_wire_drag(a + Vector2i(4, 4))
	_hold.update_wire_drag(a + Vector2i(0, 4))
	assert_eq(_hold.get_wire_corner_mode(), PLAN.CornerMode.HORIZ_FIRST,
		"正好压在竖拐点上时路径是直线，两个候选都退化，不算踩到")
	_hold.update_wire_drag(a + Vector2i(1, 4))
	assert_eq(_hold.get_wire_corner_mode(), PLAN.CornerMode.VERT_FIRST, "后踩到的竖拐点应当顶掉横拐点")
	assert_eq(_hold.get_wire_drag_plan()["line"][1], a + Vector2i(0, 4), "预览拐点要跟着换到先竖")
	#把鼠标移回横拐点 (4,0)（同样先变直线），再挪开一格 → 又听横的
	_hold.update_wire_drag(a + Vector2i(4, 0))
	_hold.update_wire_drag(a + Vector2i(4, 1))
	assert_eq(_hold.get_wire_corner_mode(), PLAN.CornerMode.HORIZ_FIRST, "把鼠标移回横拐点就又能改回先横")
	_hold.cancel_wire_drag()

#手持视图（预览线在它身上）
func lm_hold_view() -> SWHoldLayer:
	return harness.layer_manager.holdLayer

# 6a) 放在已有元件的格子上：不带 Ctrl 落不下去，带 Ctrl 就是「先拆后放再更新电路」
func test_replace_builds_over_an_existing_one() -> void:
	await _boot()
	var cell := BASE_CELL + Vector2i(20, 20)
	var old = SwDefine.SWBuildCreator(_w(cell), SWITCH_DEF, 0)
	assert_true(_build.build_manager.addBuild(old), "旧元件没能入图")
	var tmpl:SWBuildItemDefine = SwDefine.SWBuildCreator(Vector2i.ZERO, BLOCK_DEF, 0)
	var builds:Array[SWBuildItemDefine] = [tmpl]
	#一格一建筑：不抢位置就什么也放不上，旧的还在
	_build.on_hold_idle_builds(builds, [_w(cell)], false)
	await _settle()
	assert_true(harness.get_build(_w(cell)) is SWBuildButton, "不带 Ctrl 不该抢掉原有元件")
	#抢位置：拆旧的 → 放新的 → 电路更新（与按下 Ctrl 的手持层发出同一入口）
	_build.on_hold_idle_builds(builds, [_w(cell)], true)
	await _settle()
	var now = harness.get_build(_w(cell))
	assert_true(now is SWBuildLed, "Ctrl 放置应当把旧元件换成新元件")
	assert_not_same(now, old, "拿回来的还是旧元件")
	assert_true(old.bIsToBeRemoved(), "被替换的旧元件没标记成待删除")
	assert_true(_build._pendingReplacedBuilds.is_empty(), "拆下来的旧元件没善后完毕")
	assert_not_null(now.getCircuitCompoent(), "新元件没拿到电路组件")

# 6b) 拖电线遇到挡路建筑：按住 Ctrl 直接拆掉铺过去，不再绕隧道
func test_ctrl_drag_replaces_blocking_build() -> void:
	await _boot()
	var a := BASE_CELL + Vector2i(0, 30)
	var b := a + Vector2i(6, 0)
	var block_cell := a + Vector2i(3, 0)
	var blocker = SwDefine.SWBuildCreator(_w(block_cell), SWITCH_DEF, 0)
	assert_true(_build.build_manager.addBuild(blocker), "障碍建筑没能入图")
	var plain : Dictionary = _hold_plan(a, b)
	assert_true(bool(plain["valid"]), "不覆盖时应当改为绕隧道：%s" % str(plain["reason"]))
	assert_eq(plain["jumped"].size(), 1, "不覆盖时会把建筑跳过去")
	_hold._replace_mode = true
	var plan : Dictionary = _hold_plan(a, b)
	assert_true(bool(plan["valid"]), "Ctrl 覆盖不该被挡路建筑判非法：%s" % str(plan["reason"]))
	assert_eq(plan["jumped"].size(), 0, "覆盖模式下不绕路")
	assert_eq(_hold.finish_wire_drag(), 7, "七格全放")
	await _settle()
	var rep = harness.get_build(_w(block_cell))
	assert_not_null(rep, "覆盖后那一格空了")
	assert_true(rep is SWBuildWire, "挡路的建筑应当被电线换掉")
	assert_true(blocker.bIsToBeRemoved(), "被顶掉的旧元件没标记成待删除")
	assert_same(_net_at(_w(a)), _net_at(_w(b)), "拆了旧件之后这条线没接起来")

# 7) 相交换桥梁：先埋一条竖线，横着拖过去，相交那一格换成电线桥梁，
#    两条线各自连通而且互不相干（桥的 v_net / h_net 是两根 net）
func test_drag_across_existing_wire_makes_a_bridge() -> void:
	await _boot()
	var mid := BASE_CELL + Vector2i(40, 40)
	for dy in range(-1, 2):
		var v:SWBuildItemDefine = SwDefine.SWBuildCreator(_w(mid + Vector2i(0, dy)), WIRE_DEF, 0)
		assert_true(_build.build_manager.addBuild(v), "竖着的电线没能入图")
	var a := mid + Vector2i(-3, 0)
	var b := mid + Vector2i(3, 0)
	var plan : Dictionary = _hold_plan(a, b)
	assert_true(bool(plan["valid"]), "遇到垂直相交应当换桥而不是判非法：%s" % str(plan["reason"]))
	var kinds: Array = plan["kinds"]
	assert_eq(kinds[3], PLAN.PlaceKind.BRIDGE, "相交那一格应当规划成桥梁")
	assert_eq(plan["jumped"].size(), 0, "换桥就接得过去，不该再排隧道")
	assert_eq(_hold.finish_wire_drag(), 7, "七格全放（含那一格桥）")
	await _settle()
	var cross = harness.get_build(_w(mid))
	assert_true(cross is SWBuildWireCross, "相交那一格应当是电线桥梁，而不是电线或旧竖线")
	assert_not_null(harness.get_build(_w(mid + Vector2i(0, -1))), "桥不该把竖线其余部分也拆掉")
	assert_not_null(harness.get_build(_w(mid + Vector2i(0, 1))), "桥不该把竖线其余部分也拆掉")
	#两条线各自完整连通
	var horiz := _net_at(_w(a))
	var horiz_end := _net_at(_w(b))
	var vert_a := _net_at(_w(mid + Vector2i(0, -1)))
	var vert_b := _net_at(_w(mid + Vector2i(0, 1)))
	assert_not_null(horiz, "横线没接进电路")
	assert_same(horiz, horiz_end, "横线被桥截成了两截")
	assert_same(vert_a, vert_b, "竖线被桥截断了")
	assert_not_same(horiz, vert_a, "桥把两条线并成了一根 net，等于相交导通了")

# 8) 拐点那一格压着真实电线：预览变红，松手什么都不放
func test_corner_on_existing_wire_turns_preview_red() -> void:
	await _boot()
	var a := BASE_CELL + Vector2i(0, 60)
	var b := a + Vector2i(4, 4)
	#长边一样长时先横，所以拐点是 (a.x+4, a.y)
	var corner := a + Vector2i(4, 0)
	var on_corner:SWBuildItemDefine = SwDefine.SWBuildCreator(_w(corner), WIRE_DEF, 0)
	assert_true(_build.build_manager.addBuild(on_corner), "拐点上的电线没能入图")
	var plan : Dictionary = _hold_plan(a, b)
	assert_false(bool(plan["valid"]), "拐点被占应当判非法")
	assert_eq(plan["reason"], PLAN.REASON_CORNER_OCCUPIED, "失败原因应当记在拐点被占")
	assert_eq(lm_hold_view().get_wire_preview_color(), HOLD_VIEW.PREVIEW_COLOR_BAD, "拐点被占预览必须变红")
	assert_eq(_hold.finish_wire_drag(), 0, "红色预览松手不该放任何东西")
	await _settle()
	assert_eq(harness.get_build(_w(a)), null, "非法拖拽还是落子")
	assert_eq(harness.get_build(_w(b)), null, "非法拖拽在终点也落了子")

# 走与真实输入相同的路径拿到规划结果（按下不埋建筑，拖动才刷新预览）
func _hold_plan(a: Vector2i, b: Vector2i) -> Dictionary:
	_hold.cancel_wire_drag()
	_hold.begin_wire_drag(a)
	_hold.update_wire_drag(b)
	return _hold.get_wire_drag_plan()

# 9) 拖到一半按 ESC：这一笔作废，预览收掉，松手什么都不放
func test_escape_cancels_the_preview() -> void:
	await _boot()
	var a := BASE_CELL + Vector2i(0, 80)
	var b := a + Vector2i(5, 0)
	_hold.begin_wire_drag(a)
	_hold.update_wire_drag(b)
	assert_true(lm_hold_view().is_wire_preview_visible(), "拖拽中应当先有预览线")
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.physical_keycode = KEY_ESCAPE
	esc.pressed = true
	assert_true(_hold.handle_input(esc), "ESC 应当被吃掉，不再传给别处")
	assert_false(lm_hold_view().is_wire_preview_visible(), "ESC 后预览线要立刻收掉")
	assert_false(bool(_hold.get_wire_drag_plan().get("valid", false)), "作废后不该留下合法规划")
	assert_eq(_hold.finish_wire_drag(), 0, "作废的一笔松手不能再落子")
	await _settle()
	for cell: Vector2i in PLAN.path_cells(a, b):
		assert_eq(harness.get_build(_w(cell)), null, "作废后地图上不该出现电线：%s" % str(cell))
