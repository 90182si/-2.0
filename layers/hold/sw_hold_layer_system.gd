class_name SWHoldLayerSystem extends SWLayerSystem

#region 信号
signal hold_idle_builds(builds:Array,posistions:Array,replace:bool)
signal hold_remove_builds(posistions:Array)
signal select_builds_by_rect(rect:Rect2)
signal deselect_builds_by_rect(rect:Rect2)
signal drag_started()
signal drag_ended()
signal place_drag_ended()
signal erase_drag_ended()
#鼠标悬浮到的元件变了（null = 离开了）：HUD 拿它显示这个元件的求值表达式
signal hover_build_changed(build:SWBuildItemDefine)
#endregion

#region 成员变量
var sel_tunnel:bool = false

var _hold_builds:Array[SWBuildItemDefine] = []
var _last_world_pos:Vector2i = Vector2i.ZERO
var _left_mouse_pressed:bool = false
var _right_mouse_pressed:bool = false
var _ctrl_pressed:bool = false
var _selectRectPos:Vector2 = Vector2.ZERO

var _right_ctrl_dragging:bool = false
var _left_drag_started:bool = false
var _right_drag_started:bool = false
var _drag_count: int = 0
var _last_anchor_pos: Vector2i = Vector2i.ZERO

var _hold_smoothed_world_pos:Vector2 = Vector2.ZERO
var _hold_smoothed_world_vel:Vector2 = Vector2.ZERO
var _hold_pos_inited:bool = false

#电线拖拽预览（产品要求：电线不要连续放置，从 A 拖到 B 只显示一条预览线，松手才按预览落子）
var _wire_dragging:bool = false
var _wire_from_cell:Vector2i = Vector2i.ZERO
var _wire_last_cell:Vector2i = Vector2i.ZERO
var _wire_plan:Dictionary = {}
#A→B 两个候选拐点里玩家锁定了哪一个（见 SWWireDragPlan.lock_by_corner_visit）
var _wire_corner_mode:int = 0
#本次拖拽鼠标经过的格子（按经过顺序）：后踩到的候选拐点顶掉先前锁定的那个
var _wire_visited:Array[Vector2i] = []
#只留最近一段经过记录：判定只往后看「最后踩到」的那一个，更早的已经记在 _wire_corner_mode 里了
const WIRE_VISITED_MAX:int = 256
#按下左键时 Ctrl 的快照：整笔拖拽/连刷都按它走，中途松不松 Ctrl 都不变手感
var _replace_mode:bool = false
#鼠标当前悬浮的元件（会在同一元件上持续多帧，所以只变了才发信号）
var _hover_build:SWBuildItemDefine = null
#手持模板格子相对锚点的偏移：落子时放的是「锚点 + 这个偏移」，预览线必须画在同一处才对得上
var _wire_place_offset:Vector2i = Vector2i.ZERO

#遇到被挡的段落要自动放一对隧道跳过去，隧道与桥梁定义这里直接拿
const TUNNEL_DEFINE:SWBuildDefine = preload("res://res/电线隧道.tres")
const BRIDGE_DEFINE:SWBuildDefine = preload("res://res/电线桥梁.tres")
#路径规划走 preload而不是类名：新建脚本的 class_name 要等编辑器重扫全局类缓存才认得，
#headless 跑测不重扫，直接写类名会编译不过
const WIRE_DRAG_PLAN := preload("res://layers/hold/sw_wire_drag_plan.gd")
#endregion

func _init() -> void:
	system_name = &"core.layer.hold"
	run_order = SwDefine.ORDER_LAYER_HOLD
	receives_frame = true

func _get_view() -> SWHoldLayer:
	return view as SWHoldLayer

func attach_view(v:SWLayer) -> void:
	super.attach_view(v)
	var holdLayer = v as SWHoldLayer
	if holdLayer != null:
		if not holdLayer.selectBuildsByRect.is_connected(_on_select_builds_by_rect):
			holdLayer.selectBuildsByRect.connect(_on_select_builds_by_rect)

func frame(_delta:float) -> void:
	var v = _get_view()
	if v == null:
		return
	var world_pos = v.get_mouse_world_pos()
	v.set_hold_draw_pos(get_smoothed_pos(_delta,world_pos,v))
	#电线拖拽：预览线跟着鼠标走（放在这里而不是只靠运动事件，镜头拖动时也要跟着对格）
	if _wire_dragging:
		update_wire_drag(_mouse_cell(v))
		#拖线时收掉悬浮提示：这会儿玩家看的是预览线，不是脚下那个元件
		_refresh_hover_build(null)
		return
	_refresh_hover_build(_build_at_mouse(v))
	if _left_mouse_pressed:
		var anchor_pos = v.get_anchor_pos(world_pos)
		if anchor_pos == _last_anchor_pos:
			return
		_paint_between(_last_anchor_pos, Vector2(anchor_pos))
		_last_anchor_pos = anchor_pos
	
#region 内部函数
func get_smoothed_pos(_delta:float,world_pos:Vector2,v:SWHoldLayer) -> Vector2:
	if not _hold_pos_inited:
		_hold_smoothed_world_pos = world_pos
		_hold_smoothed_world_vel = Vector2.ZERO
		_hold_pos_inited = true
	else:
		# 二阶弹簧/阻尼模型（可回弹）
		var hz: float = maxf(0.0, v.hold_spring_frequency_hz)
		var zeta: float = maxf(0.0, v.hold_damping_ratio)
		var omega: float = TAU * hz
		# 大 delta 时分段积分，减少不稳定和穿透
		var remaining: float = minf(_delta, 0.25)
		var max_step: float = maxf(0.0005, v.hold_max_substep)
		while remaining > 0.0:
			var dt: float = minf(remaining, max_step)
			remaining -= dt
			# a = -2ζω v - ω² (x - target)
			var x_err: Vector2 = _hold_smoothed_world_pos - world_pos
			var accel: Vector2 = (-2.0 * zeta * omega) * _hold_smoothed_world_vel - (omega * omega) * x_err
			_hold_smoothed_world_vel += accel * dt
			_hold_smoothed_world_pos += _hold_smoothed_world_vel * dt
	return _hold_smoothed_world_pos
func _on_select_builds_by_rect(rect:Rect2) -> void:
	select_builds_by_rect.emit(rect)
func _begin_drag() -> void:
	if _drag_count == 0:
		drag_started.emit()
	_drag_count += 1
func _end_drag() -> void:
	_drag_count -= 1
	if _drag_count <= 0:
		_drag_count = 0
		drag_ended.emit()
func _rot_hold(times:int = 1) -> void:
	var v = _get_view()
	if v == null:
		return
	var drawData = v.get_hold_draw_data()
	if drawData == null:
		return
	var chunk_map:Dictionary[Vector2i,bool]={}
	for data:SWBuildItemDefine in drawData.mapDatas:
		for time in times:
			@warning_ignore("static_called_on_instance","integer_division")
			data.buildAxisPos = SwCommon.RotationPos(
				data.buildAxisPos+SwDefine.GRID_SIZE/2,90,Vector2.ZERO
			)-Vector2(SwDefine.GRID_SIZE/2)
			data.buildAxisPos = data.buildAxisPos.snapped(SwDefine.GRID_SIZE)
			@warning_ignore("static_called_on_instance")
			chunk_map[SwCommon.GetChunkPos(data.buildAxisPos)]=true
			data.rotOnce()
	
	var shadowData = v.get_shadow_draw_data()
	if shadowData:
		for i in min(drawData.mapDatas.size(), shadowData.mapDatas.size()):
			shadowData.mapDatas[i].buildAxisPos = drawData.mapDatas[i].buildAxisPos
			shadowData.mapDatas[i].rotation = drawData.mapDatas[i].rotation
	v.refresh_hold_render(chunk_map.keys())
	_hold_pos_inited = false
func _clear_hold() -> void:
	#换工具、右键清空都得把没松手的拖拽预览收掉，否则屏幕上会留一条已经没有归宿的线
	cancel_wire_drag()
	_replace_mode = false
	var v := _get_view()
	if v != null:
		v.clear_hold()
		# 准备阶段可能把预览设成隐藏：清空时恢复，避免下次手持直接不可见
		v.set_hold_visible(true)
	_hold_builds.clear()
	sel_tunnel=false
	_hold_pos_inited = false	
func _paint_between(from_world_pos: Vector2, to_world_pos: Vector2) -> void:
	if _hold_builds.is_empty() and _left_mouse_pressed:
		return
	var grid_size_v := Vector2(SwDefine.GRID_SIZE)
	var last_grid_index:Vector2i = Vector2i(from_world_pos / grid_size_v)
	var cur_grid_index:Vector2i = Vector2i(to_world_pos / grid_size_v)
	if last_grid_index == cur_grid_index:
		return
	var x0:int = last_grid_index.x
	var y0:int = last_grid_index.y
	var x1:int = cur_grid_index.x
	var y1:int = cur_grid_index.y
	var dx:int = abs(x1 - x0)
	var dy:int = -abs(y1 - y0)
	var sx:int = 0
	if x0 < x1:
		sx = 1
	elif x0 > x1:
		sx = -1
	var sy:int = 0
	if y0 < y1:
		sy = 1
	elif y0 > y1:
		sy = -1
	var err:int = dx + dy
	var poss:Array[Vector2i] = []
	var x:int = x0
	var y:int = y0
	while true:
		if x == x1 and y == y1:
			break
		var e2 := 2 * err
		if e2 >= dy:
			err += dy
			x += sx
		if e2 <= dx:
			err += dx
			y += sy
		poss.append(Vector2i(x, y) * SwDefine.GRID_SIZE)

	if poss.size() == 0:
		return

	if _left_mouse_pressed:
		hold_idle_builds.emit(_hold_builds,poss,_replace_mode)
	elif _right_mouse_pressed:
		hold_remove_builds.emit(poss)
	_last_world_pos = to_world_pos
#endregion

#region 电线拖拽预览
# 手持是不是「一根普通电线」：只有它走拖拽预览。
# 隧道/桥梁自身就是要摆在具体一格上，复制出来的一大片更是整体落子，都保持原来的连续刷
func _is_wire_tool() -> bool:
	if _hold_builds.size() != 1:
		return false
	return _hold_builds[0].buildDefine.circuit_component_type == SwDefine.CircuitComponentType.WIRE

#鼠标当前对应哪一个格子（拿 anchor 而不是裸世界坐标：anchor 已经补过手持模板的中心偏移）
func _mouse_cell(v:SWHoldLayer) -> Vector2i:
	return WIRE_DRAG_PLAN.cell_of(Vector2(v.get_anchor_pos(v.get_mouse_world_pos())))

#鼠标现在压在哪个元件上（没有就 null）。格子查询由 build 系统注入，与 _probe_cell 同一个入口
func _build_at_mouse(v:SWHoldLayer) -> SWBuildItemDefine:
	if not _cell_probe.is_valid():
		return null
	var build:SWBuildItemDefine = _cell_probe.call(v.get_mouse_grid_world_pos())
	if build == null or build.bIsToBeRemoved():
		return null
	return build

#悬浮元件变了才发信号：同一元件会连续命中好几帧，每帧都发会让 HUD 反复重排文本
func _refresh_hover_build(build:SWBuildItemDefine) -> void:
	if build == _hover_build:
		return
	_hover_build = build
	hover_build_changed.emit(build)

#当前悬浮的元件（测试与排障用，不参与业务判断）
func get_hover_build() -> SWBuildItemDefine:
	return _hover_build

#这一格现在放着什么：空格 / 同一种电线（已在位，不用重放）/ 别的东西（挡住路了），
#再或上这根电线的走向标记（横/纵）：规划拿它与路径方向比对，垂直就是相交→换桥梁
#查询由 build 系统注入；没注入时全当空格，纯逻辑跑测不依赖场景也能走同一条代码
func _probe_cell(cell:Vector2i) -> int:
	if not _cell_probe.is_valid():
		return WIRE_DRAG_PLAN.CellState.FREE
	var build:SWBuildItemDefine = _cell_probe.call(WIRE_DRAG_PLAN.world_of(cell))
	if build == null or build.bIsToBeRemoved():
		return WIRE_DRAG_PLAN.CellState.FREE
	if build is SWBuildWireCross:
		#桥梁横竖是两根独立 net，本来就允许我们的线穿过去：这一格什么都不用放
		return WIRE_DRAG_PLAN.CellState.SAME | WIRE_DRAG_PLAN.CELL_WIRE_HORZ | WIRE_DRAG_PLAN.CELL_WIRE_VERT
	var raw:int = WIRE_DRAG_PLAN.CellState.BLOCKED
	if _hold_builds.size() == 1 and build.buildDefine == _hold_builds[0].buildDefine:
		#已经是同一种电线：电线组本身就连着（见 SWBuildWire.getDirBuild），不用放也不会断
		raw = WIRE_DRAG_PLAN.CellState.SAME
	#另一种电线（电线A 遇电线B）在电路里根本不相连，跟建筑物一样算阻挡
	return raw | _wire_axis(build, cell)

#这一格的电线在哪些轴上与自己那一头连着别的电线（非电线建筑返 0）
func _wire_axis(build:SWBuildItemDefine, cell:Vector2i) -> int:
	if not SwCommon.IsWireBuild(build):
		return 0
	var axis:int = 0
	if _wire_linked(build, cell + Vector2i(1, 0)) or _wire_linked(build, cell + Vector2i(-1, 0)):
		axis |= WIRE_DRAG_PLAN.CELL_WIRE_HORZ
	if _wire_linked(build, cell + Vector2i(0, 1)) or _wire_linked(build, cell + Vector2i(0, -1)):
		axis |= WIRE_DRAG_PLAN.CELL_WIRE_VERT
	return axis

#邻居是不是与本格连通的一根电线：桥梁两边什么都接，普通电线只连同名电线
func _wire_linked(build:SWBuildItemDefine, nb_cell:Vector2i) -> bool:
	var nb:SWBuildItemDefine = _cell_probe.call(WIRE_DRAG_PLAN.world_of(nb_cell))
	if nb == null or nb.bIsToBeRemoved() or not SwCommon.IsWireBuild(nb):
		return false
	if build is SWBuildWireCross or nb is SWBuildWireCross:
		return true
	return nb.buildDefine.buildName == build.buildDefine.buildName

func _preview_point(cell:Vector2i) -> Vector2:
	return Vector2(WIRE_DRAG_PLAN.world_of(cell) + _wire_place_offset + SwDefine.GRID_SIZE / 2)

func begin_wire_drag(from_cell:Vector2i) -> void:
	if _hold_builds.is_empty():
		return
	_wire_dragging = true
	_wire_from_cell = from_cell
	_wire_last_cell = from_cell
	_wire_corner_mode = WIRE_DRAG_PLAN.CornerMode.AUTO
	_wire_place_offset = _hold_builds[0].buildAxisPos
	_wire_visited.clear()
	_wire_visited.append(from_cell)
	_refresh_wire_preview()

# 拖到新格子：先记下鼠标经过的格子（拖得快会跳格，Bresenham 补上中间点），
# 再看两个候选拐点里哪一个是「后」被踩到的——后踩到的说了算，所以玩家把鼠标
# 扫过哪个拐点就从哪个拐，先扫过一边再扫另一边还能改主意；都没踩到就保持原走法
func update_wire_drag(to_cell:Vector2i) -> void:
	if not _wire_dragging or to_cell == _wire_last_cell:
		return
	_wire_visited.append_array(WIRE_DRAG_PLAN.line_cells(_wire_last_cell, to_cell))
	if _wire_visited.size() > WIRE_VISITED_MAX:
		_wire_visited = _wire_visited.slice(_wire_visited.size() - WIRE_VISITED_MAX)
	_wire_corner_mode = WIRE_DRAG_PLAN.lock_by_corner_visit(
		_wire_from_cell, to_cell, _wire_visited, _wire_corner_mode)
	_wire_last_cell = to_cell
	_refresh_wire_preview()

func cancel_wire_drag() -> void:
	_wire_dragging = false
	_wire_plan = {}
	_wire_corner_mode = WIRE_DRAG_PLAN.CornerMode.AUTO
	_wire_visited.clear()
	var v := _get_view()
	if v != null:
		v.hide_wire_preview()

#最后一次预览的规划结果（测试与排障用，不参与业务判断）
func get_wire_drag_plan() -> Dictionary:
	return _wire_plan

#当前拐点锁（AUTO / 先横 / 先竖）
func get_wire_corner_mode() -> int:
	return _wire_corner_mode

#这一笔要不要抢原有元件的位置（按下左键时 Ctrl 的状态）
func is_replace_mode() -> bool:
	return _replace_mode

# 松手：预览合法才落子，非法（红线）什么都不放——宁可不放也不能放出一条不通的线
func finish_wire_drag() -> int:
	var plan:Dictionary = _wire_plan
	cancel_wire_drag()
	if not bool(plan.get("valid", false)):
		return 0
	return _emit_wire_plan(plan)

func _refresh_wire_preview() -> void:
	var v := _get_view()
	if v == null:
		return
	var probe := Callable(self, "_probe_cell")
	_wire_plan = WIRE_DRAG_PLAN.plan(_wire_from_cell, _wire_last_cell, probe, _wire_corner_mode, _replace_mode)
	var line:Array = _wire_plan["line"]
	var pts := PackedVector2Array()
	for cell:Vector2i in line:
		pts.append(_preview_point(cell))
	if line.size() == 1 or line[0] == line[line.size() - 1]:
		#原地一笔没拖动：折线退化成一个点看不见，改成横跨这一格的小短条
		var c := _preview_point(_wire_from_cell)
		var half := Vector2(SwDefine.GRID_SIZE.x * 0.5, 0.0)
		pts = PackedVector2Array([c - half, c + half])
	v.show_wire_preview(pts, bool(_wire_plan["valid"]))

# 把规划拆成放置任务：电线一整批，桥梁一批（总是抢位置），隧道按旋转分组各一批
# （on_hold_idle_builds 是「模板 × 格子」的笛卡尔积，不同旋转不能混在同一批里）
func _emit_wire_plan(plan:Dictionary) -> int:
	if _hold_builds.is_empty():
		return 0
	var cells:Array = plan["cells"]
	var kinds:Array = plan["kinds"]
	var rots:Array = plan["rots"]
	var wire_positions:Array = []
	var bridge_positions:Array = []
	var tunnel_positions:Dictionary = {}
	for i in cells.size():
		var pos:Vector2i = WIRE_DRAG_PLAN.world_of(cells[i])
		var kind:int = int(kinds[i])
		if kind == WIRE_DRAG_PLAN.PlaceKind.KEEP:
			#同种电线已经在位，重放只会 addBuild 失败，跳过
			continue
		if kind == WIRE_DRAG_PLAN.PlaceKind.TUNNEL:
			var rot:int = int(rots[i])
			if not tunnel_positions.has(rot):
				tunnel_positions[rot] = []
			tunnel_positions[rot].append(pos)
		elif kind == WIRE_DRAG_PLAN.PlaceKind.BRIDGE:
			bridge_positions.append(pos)
		else:
			wire_positions.append(pos)
	if not wire_positions.is_empty():
		hold_idle_builds.emit(_hold_builds, wire_positions, _replace_mode)
	if not bridge_positions.is_empty():
		#相交那一格原本已有电线，必须先拆掉才能放桥（一格一建筑）
		var bridge:SWBuildItemDefine = SwDefine.SWBuildCreator(_wire_place_offset, BRIDGE_DEFINE, 0, true)
		var bridge_builds:Array[SWBuildItemDefine] = [bridge]
		hold_idle_builds.emit(bridge_builds, bridge_positions, true)
	for rot:int in tunnel_positions.keys():
		#预览克隆（preview=true）只当描述子用：定以后只提供 define/旋转/格子偏移
		var tmpl:SWBuildItemDefine = SwDefine.SWBuildCreator(_wire_place_offset, TUNNEL_DEFINE, rot, true)
		var tunnel_builds:Array[SWBuildItemDefine] = [tmpl]
		hold_idle_builds.emit(tunnel_builds, tunnel_positions[rot], false)
	return cells.size()
#endregion

#region 外部输入事件
func _on_left_pressed(v:SWHoldLayer) -> bool:
	# 复制/剪切准备期间既不能放置也不能开始框选
	if not _can_place_now():
		return false
	# Ctrl + 落在已有元件上 = 拆掉旧的再放新的（连刷与拖拽都跟这一笔一致）
	_replace_mode = Input.is_key_pressed(KEY_CTRL)
	# 电线走「拖拽预览 + 松手落子」：按下不埋建筑，也不能置 _left_mouse_pressed（那是连续刷开关）
	if _is_wire_tool():
		_left_drag_started = true
		_begin_drag()
		begin_wire_drag(_mouse_cell(v))
		return true
	_left_mouse_pressed = true
	if _hold_builds.size() > 0:
		var world_pos = v.get_mouse_world_pos()
		var anchorPos = v.get_anchor_pos(world_pos)
		_last_anchor_pos = anchorPos
		_left_drag_started = true
		_begin_drag()
		hold_idle_builds.emit(_hold_builds,[anchorPos],_replace_mode)
		if _hold_builds.size() > 1:
			_left_mouse_pressed = false
		return true
	var world_pos2 = v.get_mouse_world_pos()
	v.set_select_rect_origin(world_pos2,Color(0.557, 1.0, 1.0, 0.3))
	_selectRectPos = world_pos2
	return false
func _on_right_pressed(v:SWHoldLayer) -> bool:
	# 清空手持不碰地图，也不影响已入队的放置任务：放置没跑完也要能随时收手
	if _hold_builds.size() > 0:
		_clear_hold()
		return false
	# 擦除会打断分阶段的电路重建：后台任务期间一律不响应
	if not _can_erase_now():
		return false
	if _ctrl_pressed:
		_right_ctrl_dragging = true
		var world_pos = v.get_mouse_world_pos()
		v.set_select_rect_origin(world_pos,Color(1.0, 0.2, 0.2, 0.3))
		_selectRectPos = world_pos
	else:
		_last_world_pos = v.get_mouse_grid_world_pos()
		_right_drag_started = true
		_begin_drag()
		var remove_positions:Array[Vector2i] = [_last_world_pos]
		hold_remove_builds.emit(remove_positions)
		_right_mouse_pressed = true
	return false
func _on_left_released(v:SWHoldLayer) -> bool:
	_left_mouse_pressed = false
	# 电线拖拽：以松手那一刻的格子为准重算一次（不依赖上一帧的运动事件有没有递到位）
	if _wire_dragging:
		update_wire_drag(_mouse_cell(v))
		#落子要在 _replace_mode 被清掉之前发出去（Ctrl 拖电线要一路覆盖）
		finish_wire_drag()
		_left_drag_started = false
		_replace_mode = false
		_end_drag()
		place_drag_ended.emit()
		return false
	_replace_mode = false
	if not _left_drag_started:
		return false
	_left_drag_started = false
	_end_drag()
	place_drag_ended.emit()
	if sel_tunnel:
		_rot_hold(2)
	return false
func _on_right_released(v:SWHoldLayer) -> bool:
	if _right_ctrl_dragging:
		_right_ctrl_dragging = false
		var rect = v.get_select_rect()
		if rect.size.x > 5 and rect.size.y > 5:
			deselect_builds_by_rect.emit(rect)
		v.hide_select_rect()
		_ctrl_pressed = false
		return false
	_right_mouse_pressed = false
	if _right_drag_started:
		_right_drag_started = false
		_end_drag()
		erase_drag_ended.emit()
	return false
func _handle_mouse_button(event:InputEventMouseButton) -> bool:
	var v := _get_view()
	if event.is_pressed():
		if event.button_index == MOUSE_BUTTON_LEFT:
			if _on_left_pressed(v):
				return true
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_on_right_pressed(v)
	elif event.is_released():
		if event.button_index == MOUSE_BUTTON_LEFT:
			_on_left_released(v)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_on_right_released(v)
	return false
func _handle_mouse_motion(_event:InputEventMouseMotion) -> bool:
	var v = _get_view()
	if not _ctrl_pressed:
		if _wire_dragging:
			update_wire_drag(_mouse_cell(v))
			return false
		if _left_mouse_pressed:
			var saved_last = _last_world_pos
			var anchor_pos = v.get_anchor_pos(v.get_mouse_world_pos())
			_paint_between(_last_anchor_pos, Vector2(anchor_pos))
			_last_anchor_pos = anchor_pos
			_last_world_pos = saved_last
		elif _right_mouse_pressed:
			_paint_between(_last_world_pos, v.get_mouse_grid_world_pos())
		return false
	var world_pos_mouse := v.get_mouse_world_pos()
	if _right_ctrl_dragging:
		v.update_select_rect(_selectRectPos,world_pos_mouse)
	elif _left_mouse_pressed:
		var rect:Rect2 = v.update_select_rect(_selectRectPos,world_pos_mouse)
		v.request_select_by_rect(rect)
	return false
func _handle_key(event:InputEventKey) -> bool:
	var v = _get_view()
	#ESC：放弃正在拖的这一笔电线——预览立刻收掉，松手也不再落子。
	#只吃 ESC 按下那一下，其余键位与状态一概不碰；左键松手照旧走 _on_left_released 收尾，
	#这样 _drag_count / _left_drag_started 仍然成对，不会把拖拽状态卡住
	if _wire_dragging and event.is_pressed() and not event.is_echo() \
		and event.keycode == KEY_ESCAPE:
		cancel_wire_drag()
		return true
	if Input.is_action_pressed("Rotation"):
		_rot_hold(1)
		return false
	if Input.is_key_pressed(KEY_CTRL) and _hold_builds.size() == 0:
		_ctrl_pressed = true
		v.show_select_rect()
		return false
	v.hide_select_rect()
	_ctrl_pressed = false
	_right_ctrl_dragging = false
	v.reset_select_color()
	v.reset_select_throttle()
	return false
func handle_input(event:InputEvent) -> bool:
	if _get_view() == null:
		return false
	if event is InputEventMouseButton:
		return _handle_mouse_button(event as InputEventMouseButton)
	if event is InputEventMouseMotion:
		_handle_mouse_motion(event as InputEventMouseMotion)
	elif event is InputEventKey:
		return _handle_key(event as InputEventKey)
	return false
#endregion

#region 设置函数
#放置/擦除闸门：由 build 系统注入。复制准备期间两把都关；放置任务期间只关擦除
var _place_gate:Callable = Callable()
var _erase_gate:Callable = Callable()
#格子占用查询：也由 build 系统注入（电线拖拽要预判这一格能不能落子）
var _cell_probe:Callable = Callable()

func set_edit_gates(place_gate:Callable, erase_gate:Callable) -> void:
	_place_gate = place_gate
	_erase_gate = erase_gate

func set_cell_probe(probe:Callable) -> void:
	_cell_probe = probe

func _can_place_now() -> bool:
	return not _place_gate.is_valid() or bool(_place_gate.call())

func _can_erase_now() -> bool:
	return not _erase_gate.is_valid() or bool(_erase_gate.call())

func set_hold_tool(build_define:SWBuildDefine) -> void:
	if build_define == null:
		_clear_hold()
		return
	var drawData:SWDrawData = SWDrawData.new()
	drawData.addOneDrawBuildDefine(Vector2i(0,0),build_define)
	set_hold_draw_data(drawData)
# 真正的置手持逻辑：视图只负责画，数据全在系统里
func set_hold_draw_data(draw_data:SWDrawData) -> void:
	var v := _get_view()
	if v == null:
		return
	if draw_data == null or draw_data.mapDatas.is_empty():
		_clear_hold()
		return
	var shadow_define := v.get_hold_shadow_define()
	var shadow_data := SWDrawData.new()
	if shadow_define != null:
		for data:SWBuildItemDefine in draw_data.mapDatas:
			shadow_data.addOneDrawBuildDefine(data.buildAxisPos, shadow_define, data.rotation)
	install_prepared_hold(draw_data, shadow_data, true)
# 安装已分帧准备好的手持数据（复制/剪切的准备协程调用）：
# mapDatas 与 shadowData 都必须由调用方建好，这里只做挂接，避免一次性创建上万份克隆
func install_prepared_hold(draw_data:SWDrawData, shadow_data:SWDrawData, make_visible:bool) -> void:
	var v := _get_view()
	if v == null or draw_data == null or draw_data.mapDatas.is_empty():
		_clear_hold()
		return
	_hold_builds.clear()
	_hold_builds.assign(draw_data.mapDatas)
	v.install_hold_prepared(draw_data, shadow_data, make_visible)
	v.refresh_hold_render([])
	_hold_pos_inited = false
# 准备阶段开始：旧手持立即清掉并隐藏，准备完成后才会重新出现
func clear_hold_for_prepare() -> void:
	_clear_hold()
	set_hold_visible(false)
func set_hold_visible(enable:bool) -> void:
	var v := _get_view()
	if v != null:
		v.set_hold_visible(enable)
func is_hold_render_idle() -> bool:
	var v := _get_view()
	return v.is_hold_render_idle() if v != null else true
func get_hold_pending_count() -> int:
	var v := _get_view()
	return v.get_hold_pending_count() if v != null else 0
func get_hold_shadow_define() -> SWBuildDefine:
	var v := _get_view()
	return v.get_hold_shadow_define() if v != null else null
func set_hold_builds(builds:Array[SWBuildItemDefine], center:Vector2i) -> void:
	if builds.is_empty():
		_clear_hold()
		return
	var draw_data := SWDrawData.new()
	for build in builds:
		draw_data.addOneDrawBuildDefine(build.buildAxisPos - center, build.buildDefine, build.rotation)
	set_hold_draw_data(draw_data)
func is_hold_empty() -> bool:
	return _hold_builds.is_empty()
func rotate_hold(times:int = 1) -> void:
	_rot_hold(times)
func set_tunnel_mode(value:bool) -> void:
	sel_tunnel = value
#endregion
