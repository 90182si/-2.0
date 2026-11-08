class_name SWEntityLayerSystem extends SWLayerSystem

# ==========================================================================
# 实体层系统（机器人场景专用）
#
# 职责（比 SWBuildLayerSystem 裁剪过）：放置、命中、删除、上屏脏标记、统一节拍。
#   - 不做电路重建：机器人跑的是 .swcir 加载出来的 SWCircuitBundle，与建筑实体无关
#   - 渲染复用 SWBuildManager + SWDrawManager(useName="Entity")：
#     每个机器人挂一个「只画不参与电路」的建筑实例，分区块表、
#     DrawManager 的区块构建/卸载/软缓存全部沿用现成实现
#     （必须是非 preview 实例，原因见 spawn_robot 里的注释）
#   - 位置/朝向的唯一权威是 SWRobotEntity，draw_item 只是跟着它刷
# ==========================================================================

#新建脚本的类名不在 headless 的全局类缓存里，跨文件一律 preload
const ROBOT_ENTITY := preload("res://scene/entity/sw_robot_entity.gd")
const ROBOT_DEFINE: SWBuildDefine = preload("res://res/机器人.tres")
const CIR_MANAGER := preload("res://circuit/sw_cir_manager.gd")

#机器人场景状态（摆位/朝向/绑定电路）：去电路场景改完电路回来靠它恢复。
#全局单份：不管有没有读过存档都能存一份，与存档名解耦
const STATE_PATH: String = "user://saves/_robot_scene.json"

#某个机器人被单击选中（展示电路绑定面板）
signal entity_selected(entity)
#取消选中（点空地 / 选中的那台被删掉）：面板该跟着收起来
signal selection_cleared()
#实体集合发生了变化（增删）
signal entities_changed()

#实体渲染代理
var entity_manager: SWBuildManager = null

var _entities: Array = []
#格子占用表：格子世界坐标 -> 实体
var _occupied: Dictionary = {}
var _selected = null
#待刷新区块（一次操作里可能改多格，统一提交一次）
var _dirty_chunks: Dictionary[Vector2i, bool] = {}
#移动动画期间/之后由视觉层单独画的实体（已不在分区块表里）。
#这张表是唯一依据：撤下/挂回/删除都得先查它，否则会对同一个建筑删两次（delBuilds 会 assert）
var _detached: Dictionary = {}
#上升沿相位读到、等下降沿相位执行的输出：实体 -> Vector2i(move, rotation)。
#一拍内两个相位分属两个时间点，中间必须有个地方存「这一拍要做什么」
var _pending_act: Dictionary = {}

# 性能面板「打印电路输出」：开着时每拍把每台机器人的输入/输出/寄存器状态打到控制台。
# 默认关：每拍 4 行日志在正常游玩时只是噪声
var debug_print_circuit: bool = false

func _init() -> void:
	system_name = &"core.layer.entity"
	run_order = SwDefine.ORDER_LAYER_BUILD
	#移动滑块与选中光框要逐帧推进（场景根 _process 会转调 system_manager.frame）
	receives_frame = true
	entity_manager = SWBuildManager.new()

func frame(delta: float) -> void:
	var v := _get_view()
	if v != null and v.has_method("advance_visual"):
		v.call("advance_visual", delta)

func attach_view(v: SWLayer) -> void:
	super.attach_view(v)
	if v != null and v.has_method("attach_entity_manager"):
		v.call("attach_entity_manager", entity_manager)

func _get_view() -> SWLayer:
	return view

#region 放置 / 删除
#手持层落子入口（与 SWBuildLayerSystem.on_hold_idle_builds 同签名，可直接连线）
func on_hold_idle_builds(_builds: Array, positions: Array, _replace: bool = false) -> void:
	if positions.is_empty():
		return
	for p in positions:
		var cell: Vector2i = p
		spawn_robot(cell)
	flush_render()

#手持层擦除入口（右键抹格）
func on_hold_remove_builds(positions: Array) -> void:
	var removed := false
	for p in positions:
		var cell: Vector2i = p
		if remove_robot_at(cell):
			removed = true
	if removed:
		flush_render()

#在某一格放一个机器人；这一格已经有实体就不放，返回 null
func spawn_robot(world_pos: Vector2i, dir: int = 0):
	var cell: Vector2i = SwCommon.GetGridPos(Vector2i(world_pos))
	if _occupied.has(cell):
		return null
	var e = ROBOT_ENTITY.new(cell, dir)
	e.blocked_probe = Callable(self, "_cell_blocked")
	#第四个参数必须是 false：is_preview=true 的建筑会被
	#SWBuildCompoentRenderable.getInstanceBlock 短路成空实例块（preview 只给 ByHold/HoldShadow
	#直写用），放进 ByContent 图层就一个实例都不生成，表现成「点了没反应 / 放不上去」。
	#机器人不进任何电路控制列表，所以「非 preview」也不会参与求值/连网。
	var item: SWBuildItemDefine = SwDefine.SWBuildCreator(cell, ROBOT_DEFINE, int(e.dir), false)
	e.draw_item = item
	if not entity_manager.addBuild(item):
		return null
	_entities.append(e)
	_occupied[cell] = e
	_dirty_chunks[SwCommon.GetChunkPos(cell)] = true
	entities_changed.emit()
	return e

func remove_robot_at(world_pos: Vector2i) -> bool:
	var cell: Vector2i = SwCommon.GetGridPos(Vector2i(world_pos))
	var e = _occupied.get(cell, null)
	if e == null:
		return false
	return remove_entity(e)

func remove_entity(e) -> bool:
	if e == null:
		return false
	var idx: int = _entities.find(e)
	if idx < 0:
		return false
	_entities.remove_at(idx)
	#本拍还没走到下降沿相位：把它从待办里摘掉，别让一个已删实体在半拍后动起来
	_pending_act.erase(e)
	if _occupied.get(e.grid_pos, null) == e:
		_occupied.erase(e.grid_pos)
	#视觉层把还在滑的那条记录抹掉：否则滑完会去 attach 一个已删实体（把死建筑塞回区块表）
	_stop_visual(e)
	var item: SWBuildItemDefine = e.draw_item
	if item != null:
		var old_pos: Vector2i = item.buildAxisPos
		#动画期间已经撤下来了：不能在表里再删一次（delBuilds 删不到会 assert）
		if not _detached.erase(e):
			var arr: Array[SWBuildItemDefine] = [item]
			entity_manager.delBuilds(arr)
		e.draw_item = null
		_dirty_chunks[SwCommon.GetChunkPos(old_pos)] = true
		_dirty_chunks[SwCommon.GetChunkPos(e.grid_pos)] = true
	if _selected == e:
		_selected = null
		selection_cleared.emit()
	entities_changed.emit()
	return true

#清空所有实体（场景切换/重开）
func clear_entities() -> void:
	for chunk: Vector2i in entity_manager.chunkMap.keys():
		_dirty_chunks[chunk] = true
	#先停动画：清空后视觉层再去 attach 就是往已经倒掉的表里塞建筑
	_cancel_visual()
	_detached.clear()
	_pending_act.clear()
	_entities.clear()
	_occupied.clear()
	if _selected != null:
		_selected = null
		selection_cleared.emit()
	entity_manager.clearAllBuilds()
	entities_changed.emit()
#endregion

#region 移动 / 转向
#目标格被别的实体占住
func _cell_blocked(cell: Vector2i) -> bool:
	return _occupied.has(cell)

#按当前朝向前进一格（被挡 => 原地不动，返回 false）
#注意：位置/占格表在调用的当场就改完了（实体才是权威），变慢的只是**看起来**走过去，
#所以「一拍走一格」的逻辑语义一点没动，测试不用等动画。
func move_entity(e) -> bool:
	if e == null:
		return false
	var from_pos: Vector2i = e.grid_pos
	if not e.step_forward():
		return false
	var to_pos: Vector2i = e.grid_pos
	_occupied.erase(from_pos)
	_occupied[to_pos] = e
	#视觉层能接管就给滑块动画。注意：接管后这台不再回烘焙层，所以只需要 detach 时
	#把旧格子那个区块重建一次；之后每拍都不再碰区块，比「每拍重建两块」省很多
	if _start_move_anim(e, from_pos, to_pos):
		return true
	#接不了（纯逻辑测试 / 没挂视图）：老口径，两个区块都标脏后原地重新入表
	_dirty_chunks[SwCommon.GetChunkPos(from_pos)] = true
	_dirty_chunks[SwCommon.GetChunkPos(to_pos)] = true
	_reslot(e)
	return true

#转向（顺时针 90° × times）
#item.rotation 当场就改成新朝向（几何重烘），动画层播的是一个「从旧朝向转过去」的补角，
#所以转完的静态表现和以前一模一样，只是中间有过渡
func rotate_entity(e, times: int = 1) -> void:
	if e == null:
		return
	var from_dir: int = int(e.dir)
	e.rot90(times)
	if e.draw_item != null:
		e.draw_item.rotation = int(e.dir)
	#能接管就播动画；接不了（纯逻辑测试 / 没挂视图）就保持瞬切
	if not _start_rotate_anim(e, from_dir, int(e.dir)):
		_dirty_chunks[SwCommon.GetChunkPos(e.grid_pos)] = true

#换格子必须在分区块表里重新入表：区块表按「格子在区块内的下标」存，不能原地改坐标
func _reslot(e) -> void:
	var item: SWBuildItemDefine = e.draw_item
	if item == null:
		return
	var arr: Array[SWBuildItemDefine] = [item]
	entity_manager.delBuilds(arr)
	#delBuilds 会把建筑标成待删除：重新入表前复位，否则后续查询会被当成死建筑
	item.buildState.state = SwDefine.BuildState.IDLE
	item.buildAxisPos = e.grid_pos
	entity_manager.addBuild(item)
#endregion

#region 移动 / 旋转动画
# 为什么要有 detach/attach 这一对：机器人画在 SWDrawManager 的 chunk MultiMesh 里，
# 整块烘焙、位置和朝向都烤死在实例数据里，没法定点插值/插角。所以动画期间把这一台
# 从烘焙层撤下来交给视觉层单独画。
# 注意：滑完/转完**不交还**烘焙层（attach_render 还在，只当备用）。
# 交还要走 addBuild -> 区块重建，而区块重建是分帧的，中间会有一两帧两层都没画这台；
# 选中的那台有光框撑着看不出来，未选中的看上去就是「闪一下瞬移」。
# 代价只是这几台不再享受烘焙层的「内容不变就不重写」，而它们本来每拍都在动。

#问视觉层接不接；接了就由它画，本系统不管了。返回 false = 调用方得自己 _reslot
func _start_move_anim(e, from_pos: Vector2i, to_pos: Vector2i) -> bool:
	var v := _get_view()
	if v == null or not v.has_method("start_visual_move"):
		return false
	if not _detached.has(e) and not detach_render(e):
		return false
	if not bool(v.call("start_visual_move", e, from_pos, to_pos)):
		#视觉层不接（例如没有渲染代理）：立刻挂回去，不能把实体悬在半空
		attach_render(e)
		return false
	return true

func _start_rotate_anim(e, from_dir: int, to_dir: int) -> bool:
	var v := _get_view()
	if v == null or not v.has_method("start_visual_rotate"):
		return false
	if not _detached.has(e) and not detach_render(e):
		return false
	if not bool(v.call("start_visual_rotate", e, from_dir, to_dir)):
		attach_render(e)
		return false
	return true

#把一台从烘焙层撤下来（动画期间由视觉层画）。返回 false = 没代理，撤不了
func detach_render(e) -> bool:
	if e == null or e.draw_item == null:
		return false
	if _detached.has(e):
		return true
	var item: SWBuildItemDefine = e.draw_item
	var arr: Array[SWBuildItemDefine] = [item]
	entity_manager.delBuilds(arr)
	#delBuilds 把建筑标成了待删除：动画期间它不在表里，但仍要当活建筑用
	item.buildState.state = SwDefine.BuildState.SELECTED if e == _selected else SwDefine.BuildState.IDLE
	_detached[e] = true
	#原格子所在区块重建一次，把这台的旧实例从烘焙层抹掉（不抹就是「同时有两个」）
	_dirty_chunks[SwCommon.GetChunkPos(item.buildAxisPos)] = true
	return true

#滑完了把这一台按新格子挂回烘焙层（新位置入表 -> 区块重建）。
#正常运行路径上**不再走这里**（接管后一直留在动画层，避免交接空窗），只在视觉层拒接时备用
func attach_render(e) -> void:
	if e == null:
		return
	_detached.erase(e)
	var item: SWBuildItemDefine = e.draw_item
	if item == null:
		return
	item.buildState.state = SwDefine.BuildState.SELECTED if e == _selected else SwDefine.BuildState.IDLE
	item.buildAxisPos = e.grid_pos
	entity_manager.addBuild(item)
	_dirty_chunks[SwCommon.GetChunkPos(e.grid_pos)] = true
	#动画是帧回调里结束的，不会跟在某次操作后面，得自己提交一次
	flush_render()

func is_detached(e) -> bool:
	return _detached.has(e)

func get_detached_count() -> int:
	return _detached.size()

#视觉层彻底不管这一台（删实体时用）：抹掉动画记录与光框，不碰烘焙层表
func _stop_visual(e) -> void:
	var v := _get_view()
	if v == null:
		return
	if v.has_method("release_visual"):
		v.call("release_visual", e)
	#被删的这一台如果正亮着光框，立刻淡出：跟着已删实体继续亮没意义
	if v.has_method("set_visual_glow"):
		v.call("set_visual_glow", e, false)

func _cancel_visual() -> void:
	var v := _get_view()
	if v != null and v.has_method("cancel_visual"):
		v.call("cancel_visual")
#endregion

#region 单击选中
#鼠标左键点到机器人 -> 选中；点到空地 -> 取消选中
func handle_input(event: InputEvent) -> bool:
	if view == null:
		return false
	if not (event is InputEventMouseButton):
		return false
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.is_pressed():
		return false
	return select_at(_mouse_grid())

#鼠标位置换算成格子（headless 下拿不到真实鼠标坐标，测试走 select_at）
func _mouse_grid() -> Vector2i:
	var v := _get_view()
	if v == null:
		return Vector2i.ZERO
	var viewport := v.get_viewport()
	if viewport == null:
		return Vector2i.ZERO
	var world_pos = SwCommon.GetGlobalPosByViewPos(viewport.get_mouse_position(), viewport)
	return SwCommon.GetGridPos(Vector2i(world_pos))

#点击某格：命中机器人就选中它，否则取消选中
func select_at(world_pos: Vector2i) -> bool:
	var cell: Vector2i = SwCommon.GetGridPos(Vector2i(world_pos))
	var e = _occupied.get(cell, null)
	if e == null:
		return clear_selection()
	return set_selected(e)

func set_selected(e) -> bool:
	if _selected == e:
		#重复点同一台也要发：面板可能已被用户关掉，再点一下得能重新弹出来
		if e != null:
			entity_selected.emit(e)
		return e != null
	_mark_selected(_selected, false)
	_selected = e
	_mark_selected(_selected, true)
	if e != null:
		entity_selected.emit(e)
	return e != null

func clear_selection() -> bool:
	if _selected == null:
		return false
	_mark_selected(_selected, false)
	_selected = null
	selection_cleared.emit()
	return false

#选中高亮：烘焙层改底色（整块重建），视觉层叠一圈光框（收缩 + 呼吸）
func _mark_selected(e, on: bool) -> void:
	var v := _get_view()
	if v != null and v.has_method("set_visual_glow"):
		#光框不走进烘焙层：单独画才能呼吸/淡出，而且不会每帧重建区块
		v.call("set_visual_glow", e, on)
	if e == null or e.draw_item == null:
		return
	e.draw_item.buildState.state = SwDefine.BuildState.SELECTED if on else SwDefine.BuildState.IDLE
	_dirty_chunks[SwCommon.GetChunkPos(e.draw_item.buildAxisPos)] = true

func get_selected():
	return _selected
#endregion

#region 查询
func get_entities() -> Array:
	return _entities

func get_entity_count() -> int:
	return _entities.size()

func get_entity_at(world_pos: Vector2i):
	var cell: Vector2i = SwCommon.GetGridPos(Vector2i(world_pos))
	return _occupied.get(cell, null)

func has_entity_at(world_pos: Vector2i) -> bool:
	return get_entity_at(world_pos) != null
#endregion

#region 电路绑定
# 给某个机器人绑一条 .swcir（阶段 4）。file_name 传空串 = 解绑。
# 不可用（多电路 / 接口不齐 / 文件坏了）时返回 false；具体原因不在这里算，
# 面板用 SWCirManager.summarize 拿（同一个函数，避免两套判定逻辑跑偏）。
func bind_circuit(e, file_name: String) -> bool:
	if e == null:
		return false
	if file_name.is_empty():
		e.set_bundle(null)
		entities_changed.emit()
		return true
	var bundle = CIR_MANAGER.load_bundle(file_name)
	if bundle == null:
		return false
	e.set_bundle(bundle, file_name)
	#换电路了，旧电路的波形对新电路没意义，直接清空
	e.clear_timing()
	#每台机器人各持一份 runtime：同一文件绑给多台互不影响
	entities_changed.emit()
	return true

func unbind_circuit(e) -> void:
	if e == null or not e.has_bundle():
		return
	e.set_bundle(null)
	entities_changed.emit()

#已经绑上电路的机器人数（排障与测试用）
func get_bound_count() -> int:
	var n: int = 0
	for e in _entities:
		if e.has_bundle():
			n += 1
	return n

#时序图看哪台：优先当前选中的，没选中就取第一台绑了电路的（面板总能有点东西看）
func get_timing_entity():
	if _selected != null:
		return _selected
	for e in _entities:
		if e.has_bundle():
			return e
	return null
#endregion

#region 统一节拍
# 一拍 = 一个完整时钟周期，所有机器人各跑各的电路（各持独立 runtime，互不干扰）。
# 周期内必须跑**两个相位**：
#   低相位 tick：寄存器看到 clk=0（只更新 last_clk，不锁存）
#   高相位 tick：这才是 0→1 上升沿，锁存 D；输出也在这一相位之后才稳定
# 少掉低相位那次 tick（只置 0 不 tick），last_clk 会一直停在 1，
# 计数器/寄存器永远看不到上升沿——电平整拍都是 0，机器人于是不动也不转。
# 同一拍内先旋转后移动，方向按旋转后的朝向。
#
# 一个周期还被拆成**两个时间点**（step_beat_high / step_beat_low），不是一次跑完：
#   上升沿相位（拍首）：锁存、读输出、落高相位样本
#   下降沿相位（半拍后）：clk 回落到 0、执行旋转/移动、落低相位样本
# 拆开是为了时序图：两个相位各落一条样本，红线才会**一格一格**地走，
# 上升沿和下降沿都能依次流到红线位置。一次写两条的话红线一拍跳两格，
# 看上去永远停在上升沿上、下降沿被跳过。
# step_beat() 保留「一拍跑完」的原子口径（测试 / 步进按钮 / 一次性口径走它）。
func step_beat() -> int:
	step_beat_high()
	return step_beat_low()

#上升沿相位：跑完 0→1 的两次 tick、读输出、落高相位样本。
#**不动作**：旋转/移动要等下降沿相位（action 依赖的输出此刻刚稳定，
#但时序图上「输出有效」这一段应当从上升沿画到下降沿，所以留到低相位执行）。
func step_beat_high() -> void:
	_pending_act.clear()
	for e in _entities:
		if e.bundle == null:
			continue
		e.bundle.set_input("clk", 0)
		e.bundle.tick()
		e.bundle.set_input("clk", 1)
		e.bundle.tick()
		var do_rot: bool = e.bundle.output_level("rotation") != 0
		var do_move: bool = e.bundle.output_level("move") != 0
		if debug_print_circuit:
			# 打印口径：本拍确实写进去的 clk / 读到的两个输出 / 寄存器 Q 串（高位在后）。
			# 计数器"不动"时先看这里：Q 不推进 = 时钟沿没到，Q 推进而输出恒 0 = 电路逻辑问题。
			# 日志保持 ASCII：Windows 控制台是 GBK，中文会乱码且没法 grep
			print("[robot-circuit] cell=%s file=%s clk=%d move=%d rotation=%d Q=%s" % [
					str(e.cell()), str(e.circuit_file), e.bundle.input_level("clk"),
					1 if do_move else 0, 1 if do_rot else 0, e.bundle.reg_q_text()])
		#clk 停在 1 直到下降沿相位（那里才回落）。只记高相位的样本
		e.push_phase_high(1 if do_move else 0, 1 if do_rot else 0)
		_pending_act[e] = Vector2i(1 if do_move else 0, 1 if do_rot else 0)

#下降沿相位：clk 回落到 0、执行上升沿相位读到的输出、落低相位样本。
#返回本拍实际移动数
func step_beat_low() -> int:
	var moved: int = 0
	for e in _pending_act.keys():
		var mv_rot: Vector2i = _pending_act[e]
		#高相位到低相位之间这台被删/被清场了：不能再动它（会把死实体塞回占格表）
		if e == null or e.bundle == null or _occupied.get(e.grid_pos, null) != e:
			continue
		e.bundle.set_input("clk", 0)
		var acted: int = 0
		if int(mv_rot.y) != 0:
			rotate_entity(e, 1)
			acted = 1
		if int(mv_rot.x) != 0 and move_entity(e):
			moved += 1
			acted = 1
		e.push_phase_low(int(mv_rot.x), int(mv_rot.y), acted)
	_pending_act.clear()
	flush_render()
	return moved
#endregion

#region 上屏
#把本轮累积的脏区块交给实体层重建（没有视图时只清标记：纯逻辑测试不依赖场景）
func flush_render() -> void:
	if _dirty_chunks.is_empty():
		return
	var chunks: Array[Vector2i] = []
	for k in _dirty_chunks.keys():
		chunks.append(k)
	_dirty_chunks.clear()
	var v := _get_view()
	if v != null and v.has_method("refresh_chunks"):
		v.call("refresh_chunks", chunks)
#endregion

#region 场景状态存取
#切出机器人场景时把「摆了哪些机器人、朝向、绑的哪条电路」存下来，
#回来时整表重建。只存摆位不存电路状态：bundle 是 .swcir 加载出来的，
#重存一遍反而会把玩家刚在电路场景改好的网表盖回旧的。
func to_dict() -> Dictionary:
	var robots: Array = []
	for e in _entities:
		var c: Vector2i = e.cell()
		robots.append({
			"x": c.x, "y": c.y,
			"dir": int(e.dir),
			"circuit": str(e.circuit_file)})
	return {"version": 1, "robots": robots}

#按 to_dict 重建；返回真正建出来的机器人数（被删掉的电路文件会解绑但仍保留机器人）
func load_from_dict(data: Dictionary) -> int:
	clear_entities()
	var n: int = 0
	for r in data.get("robots", []):
		#JSON 数字回来是 float，统一 int() 一下
		var cell := Vector2i(int(r.get("x", 0)), int(r.get("y", 0)))
		var e = spawn_robot(cell * SwDefine.GRID_SIZE, int(r.get("dir", 0)))
		if e == null:
			continue
		n += 1
		var f: String = str(r.get("circuit", ""))
		#文件被删了/改坏了就保持未绑定：机器人还在，只是不跟拍，比整台消失好
		if not f.is_empty():
			bind_circuit(e, f)
	flush_render()
	return n

func save_state(path: String = STATE_PATH) -> bool:
	_ensure_state_dir()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[EntityLayer] 场景状态写不进去: " + path)
		return false
	f.store_string(JSON.stringify(to_dict(), "\t"))
	f.close()
	return true

#取不到文件/格式不对都当「没有状态」，不能把现有实体清空以后再报错
func load_state(path: String = STATE_PATH) -> int:
	if not FileAccess.file_exists(path):
		return 0
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(data) != TYPE_DICTIONARY:
		push_warning("[EntityLayer] 场景状态文件坏了，忽略: " + path)
		return 0
	return load_from_dict(data)

static func _ensure_state_dir() -> void:
	if not DirAccess.dir_exists_absolute(STATE_PATH.get_base_dir()):
		DirAccess.make_dir_recursive_absolute(STATE_PATH.get_base_dir())
#endregion
