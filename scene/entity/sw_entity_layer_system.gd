class_name SWEntityLayerSystem extends SWLayerSystem

# ==========================================================================
# 实体层系统（机器人场景专用）
#
# 职责（比 SWBuildLayerSystem 裁剪过）：放置、命中、删除、上屏脏标记、统一节拍。
#   - 不做电路重建：机器人跑的是 .swcir 加载出来的 SWCircuitBundle（多电路文件是 SWCircuitSet，
#     接口同名，一拍里所有含接口的电路都跑一遍），与建筑实体无关
#   - 渲染复用 SWBuildManager + SWDrawManager(useName="Entity")：
#     每个机器人挂一个「只画不参与电路」的建筑实例，分区块表、
#     DrawManager 的区块构建/卸载/软缓存全部沿用现成实现
#     （必须是非 preview 实例，原因见 spawn_robot 里的注释）
#   - 位置/朝向的唯一权威是 SWRobotEntity，draw_item 只是跟着它刷
# ==========================================================================

#新建脚本的类名不在 headless 的全局类缓存里，跨文件一律 preload
const ROBOT_ENTITY := preload("res://scene/entity/sw_robot_entity.gd")
const ROBOT_DEFINE: SWBuildDefine = preload("res://res/机器人.tres")
#箱子：只有一个占格实体，不需要电路定义（图集帧与机器人同帧占位，换图只改 .tres 里的 region）
const BOX_DEFINE: SWBuildDefine = preload("res://res/箱子.tres")
#电路输出名 -> 动作（事件接口表；可手动加名字）
const ACTIONS := preload("res://scene/entity/sw_robot_actions.gd")
const CIR_MANAGER := preload("res://circuit/sw_cir_manager.gd")
#位平面批量求值（上万台一个 bit 一台，见 circuit/sim/sw_bit_batch.gd）
const BIT_GROUP := preload("res://circuit/sim/sw_bit_batch_group.gd")

#实体种类
const KIND_ROBOT: String = "robot"
const KIND_BOX: String = "box"

#检测用的 8 方向绝对下标（顺时针，0 北、2 东、4 南、6 西）：
#偶数下标与 SwDefine.SW_Dir 同序（dir*2），斜向是新增的。
#方向码就是这里的下标，**与机器人朝向无关**（检测的是绝对方位）
const DIR8_VECS: Array[Vector2i] = [
	Vector2i(0, -1), Vector2i(1, -1), Vector2i(1, 0), Vector2i(1, 1),
	Vector2i(0, 1), Vector2i(-1, 1), Vector2i(-1, 0), Vector2i(-1, -1),
]

#机器人的 4 个正向（与 SwDefine.dir_to_vec 同序：0 上 1 右 2 下 3 左）。
#为什么不直接调 SwDefine.dir_to_vec：那是 static func + match，每次调用要压栈、
#走一遍分支；而 move_entity 一拍要算上万次目标格（原实现还算了两遍，
#step_forward 内部又调一次 next_cell），改成数组下标取只需一次边界检查
const DIR4_VECS: Array[Vector2i] = [
	Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0),
]

#机器人场景状态（摆位/朝向/绑定电路）：去电路场景改完电路回来靠它恢复。
#全局单份：不管有没有读过存档都能存一份，与存档名解耦
const STATE_PATH: String = "user://saves/_robot_scene.json"

#某个机器人被单击选中（展示电路绑定面板）
signal entity_selected(entity)
#取消选中（点空地 / 选中的那台被删掉）：面板该跟着收起来
signal selection_cleared()
#框选出来的多选集合变了（含框选结束后只剩一台 / 被减空）：HUD 批量绑定面板跟着刷新
signal selection_multi_changed(entities: Array)
#实体集合发生了变化（增删）
signal entities_changed()

# 超过这个台数后，新放下的实体默认不落时序样本。
# 时序图一次只看一台，几千台时每台每半拍 append + 算位图的代价（实测 34us/台）
# 会直接把帧预算吃光；HUD 观测到哪台就把那台的 trace_active 打开
const TRACE_FULL_LIMIT: int = 64

# 超过这个台数后，新绑电路的机器人改走**位平面批量求值**：
# 同一份 .swcir 的所有机器人共用一套网表，每台只占位平面里的 1 个 bit。
# 逐台 tick 实测 0.085ms/台/拍（已优化过），1 万台一拍照样要 850ms；
# 位平面 1 万实例一遍只要 4.6ms。
# 阈值以下的台数保持逐台：时序图/面板/调试全部照旧，零风险
const BATCH_MIN: int = 128

# 实体渲染代理
var entity_manager: SWBuildManager = null
# 视觉层直连句柄（attach_view 时从图层取到）。
# 为什么不每次都走 view.start_visual_move：图层那层只做转发 + 一次 _ensure_visual
# 有效性判断，一拍上万次就是两万次多余调用。这里只保存引用，用前判一次有效性
var _visual = null
# 是否正在批量执行本拍动作（step_beat_low 的循环内）。
# 循环里每台只往视觉层**登个号**，末尾一次提交；直接从外面调 move_entity /
# rotate_entity（面板 / 测试 / 推箱）不在批量里，每次当场提交，
# 保证「调用返回就能看到动画在跑」
var _in_beat_low: bool = false
# 本拍攒下的滑动登记：行号 + 终点 xy 交错。
# 为什么不逐台调视觉层的 start_move：一台一次跨对象调用 + Vector2 构造，
# 上万台就多 15~30ms/拍；攒好后直接转给批处理（PackedArray 传参零复制）
var _mv_rows := PackedInt32Array()
var _mv_xy := PackedFloat32Array()

var _entities: Array = []
#格子占用表：格子世界坐标 -> 实体
var _occupied: Dictionary = {}
#主选（单选与框选共用）：绑定面板的「当前电路」、时序图、光框都看它
var _selected = null
#框选出来的那批台（含主选）。单选点击=替换，Ctrl+拖=追加/移除。
#为什么用 Dictionary 而不是 Array：框选一次可能落几千台，Array.has 是线性的（平方级）
var _sel_set: Dictionary = {}
#框选拖拽状态：起点/当前点（世界坐标）、哪个键、是加还是减
var _box_active: bool = false
var _box_subtract: bool = false
var _box_button: int = MOUSE_BUTTON_LEFT
var _box_from: Vector2 = Vector2.ZERO
var _box_to: Vector2 = Vector2.ZERO
#允许框选的闸门：手持工具（机器人/箱子）时那一笔要拿去放置，不能变成框选。
#由场景根注入 Callable(hold_system, "is_hold_empty")；没注就是一直允许
var _box_gate: Callable = Callable()
#拖拽位移小于这个值（世界像素）就算单击：Ctrl+点一下应当还是点选那一台
const BOX_DRAG_MIN_PX: float = 4.0
#待刷新区块（一次操作里可能改多格，统一提交一次）
var _dirty_chunks: Dictionary[Vector2i, bool] = {}
#移动动画期间/之后由视觉层单独画的实体（已不在分区块表里）。
#这张表是唯一依据：撤下/挂回/删除都得先查它，否则会对同一个建筑删两次（delBuilds 会 assert）。
#⚠ 热路径上**不要**查这张表：一拍一万台都要先问一次「撤了吗」，对象键字典查
#加实例 id 约 600ns/次；实体自己带 render_detached 字段，这里只在撤下/挂回
#这类一次性操作里同步维护，供 is_detached / get_detached_count 这类查询用
var _detached: Dictionary = {}
#上升沿相位读到、等下降沿相位执行的输出：实体与「动作位图」两条**平行数组**（同下标一一对应）。
#一拍内两个相位分属两个时间点，中间必须有地方存「这一拍要做什么」。
#为什么不用 Array[String] 存名字：上千台时每拍要清/插上千项再逐个 has()，
#哈希与字符串比较完全不划算；位图一个 int 装下全部动作，执行时只查置位的位。
#半拍内被删的实体由 step_beat_low 的占格校验兜住（不需要在这里 erase）。
#⚠ 用带类型的 Array[SWRobotEntity]：逐台取出来的是已声明的类型，后面所有
# e.xxx 属性访问才能走成员偏移（Variant 的无类型变量每次都要运行时查属性，
# 低相位两个循环了上万次，实测差一倍）
var _act_ents: Array[SWRobotEntity] = []
var _act_masks := PackedInt32Array()
#批量求值组：电路文件名 -> SWBitBatchGroup（同一份网表只编译一次）
var _groups: Dictionary = {}
#本拍有实体的组（空组不白跑一遍求值）。
#用「组上一拍是否被扫到」的代号标记维护，不用字典：上万台每台一次字典写就是 15ms
var _active_groups: Array = []
var _beat_gen: int = 0

# 性能面板「打印电路输出」：开着时每拍把每台机器人的输入/输出/寄存器状态打到控制台。
# 默认关：每拍 4 行日志在正常游玩时只是噪声
var debug_print_circuit: bool = false

# 动作表的本地副本：ACTION_KIND_IDS / MOVE_MASK / ROT_MASK 都是 SWRobotActions 的静态变量，
# 跨脚本读一次要走运行时查找；低相位一拍要按位图逐位过表，缓存到成员后就是一次字段读
var _kind_ids: PackedInt32Array = PackedInt32Array()
var _mv_mask: int = 0
var _rt_mask: int = 0

func _init() -> void:
	system_name = &"core.layer.entity"
	run_order = SwDefine.ORDER_LAYER_BUILD
	#移动滑块与选中光框要逐帧推进（场景根 _process 会转调 system_manager.frame）
	receives_frame = true
	entity_manager = SWBuildManager.new()
	_kind_ids = ACTIONS.ACTION_KIND_IDS
	_mv_mask = ACTIONS.MOVE_MASK
	_rt_mask = ACTIONS.ROT_MASK

func frame(delta: float) -> void:
	#静态派发：基类 SWLayer 已经有空的 advance_visual，直接调就行。
	#以前用 has_method + call 逐帧反射，虽然一帧一次，但它把分支形状教给了编译器
	if view != null:
		view.advance_visual(delta)

func attach_view(v: SWLayer) -> void:
	super.attach_view(v)
	if v != null and v.has_method("attach_entity_manager"):
		v.call("attach_entity_manager", entity_manager)
	#视觉层直连：热路径（一拍上万次）直调它的 start_move，不再经图层转发
	_visual = v.get_visual() if v != null and v.has_method("get_visual") else null

func _get_view() -> SWLayer:
	return view

#region 放置 / 删除
#手持层落子入口（与 SWBuildLayerSystem.on_hold_idle_builds 同签名，可直接连线）。
#builds 是手持模板（定的是「放的什么东西」）：按元件定义名分派机器人/箱子。
#positions 是锚点格（鼠标那一格），不是模板自己的格子：手持旋转会把模板的局部偏移
#buildAxisPos 挪走（旋转是绕模板原点转的），建筑层落子时是「锚点 + 模板偏移」一起用的
#（见 sw_build_layer_system 里 tmpl.buildAxisPos + grid_pos），这里也必须补上：
#不补的话转一次就整体偏一格、转几次偏几格，且预览里已经转好的朝向也丢了
func on_hold_idle_builds(builds: Array, positions: Array, _replace: bool = false) -> void:
	if positions.is_empty():
		return
	var is_box: bool = _is_box_tool(builds)
	var tmpl = builds[0] if not builds.is_empty() else null
	var tmpl_off: Vector2i = Vector2i.ZERO
	var tmpl_dir: int = 0
	if tmpl != null and tmpl.buildDefine != null:
		tmpl_off = tmpl.buildAxisPos
		tmpl_dir = posmod(int(tmpl.rotation), 4)
	for p in positions:
		var cell: Vector2i = SwCommon.GetGridPos(Vector2i(p) + tmpl_off)
		if is_box:
			spawn_box(cell)
		else:
			spawn_robot(cell, tmpl_dir)
	flush_render()

#手持放的是不是箱子（空手持/其它工具都按机器人处理，保持原行为）
func _is_box_tool(builds: Array) -> bool:
	if builds.is_empty():
		return false
	var tmpl = builds[0]
	if tmpl == null or tmpl.buildDefine == null:
		return false
	return tmpl.buildDefine.buildName == BOX_DEFINE.buildName

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
	return _spawn_entity(world_pos, ROBOT_DEFINE, dir, KIND_ROBOT)

#在某一格放一个箱子（不跟节拍、不绑电路，只占格并可被机器人推动）
func spawn_box(world_pos: Vector2i):
	return _spawn_entity(world_pos, BOX_DEFINE, 0, KIND_BOX)

#机器人与箱子共用的建实体流程：实体才是位置/占格的权威，draw_item 只是跟着它刷
func _spawn_entity(world_pos: Vector2i, build_def: SWBuildDefine, dir: int, kind: String):
	var cell: Vector2i = SwCommon.GetGridPos(Vector2i(world_pos))
	if _occupied.has(cell):
		return null
	var e = ROBOT_ENTITY.new(cell, dir)
	e.kind = kind
	#前几十台保持采样（小场景波形历史完整），之后的默认关（HUD 观测时再开）
	e.trace_active = _entities.size() < TRACE_FULL_LIMIT
	e.blocked_probe = Callable(self, "_cell_blocked")
	#第四个参数必须是 false：is_preview=true 的建筑会被
	#SWBuildCompoentRenderable.getInstanceBlock 短路成空实例块（preview 只给 ByHold/HoldShadow
	#直写用），放进 ByContent 图层就一个实例都不生成，表现成「点了没反应 / 放不上去」。
	#机器人与箱子都不进任何电路控制列表，所以「非 preview」也不会参与求值/连网。
	var item: SWBuildItemDefine = SwDefine.SWBuildCreator(cell, build_def, int(e.dir), false)
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
	#批量槽位清空：不回收位置（要搬动上万台的状态），只把那一个 bit 抹成 0
	_release_batch(e)
	#本拍还没走到下降沿相位：不需要在这里搓——step_beat_low 会按占格表校验，
	#已删实体（占格表里已不是它）直接跳过
	if _occupied.get(e.grid_pos, null) == e:
		_occupied.erase(e.grid_pos)
	e.alive = false
	#视觉层把还在滑的那条记录抹掉：否则滑完会去 attach 一个已删实体（把死建筑塞回区块表）
	_stop_visual(e)
	var item: SWBuildItemDefine = e.draw_item
	if item != null:
		var old_pos: Vector2i = item.buildAxisPos
		#动画期间已经撤下来了：不能在表里再删一次（delBuilds 删不到会 assert）
		if not _detached.erase(e):
			var arr: Array[SWBuildItemDefine] = [item]
			entity_manager.delBuilds(arr)
		e.render_detached = false
		e.draw_item = null
		_dirty_chunks[SwCommon.GetChunkPos(old_pos)] = true
		_dirty_chunks[SwCommon.GetChunkPos(e.grid_pos)] = true
	#被删的这一台要从选区里摘掉：否则批量绑定会带着一个已经不在表里的实体。
	#主选被删就从剩下的里挑一台接着当主选，全没了才发 selection_cleared（面板收起）
	if _sel_set.erase(e) or _selected == e:
		if _selected == e:
			var rest: Array = _sel_set.keys()
			_selected = rest[0] if not rest.is_empty() else null
			if _selected != null:
				var v := _get_view()
				if v != null:
					v.set_visual_glow(_selected, true)
		if _sel_set.is_empty():
			selection_cleared.emit()
		else:
			selection_multi_changed.emit(get_selected_entities())
	entities_changed.emit()
	return true

#清空所有实体（场景切换/重开）
func clear_entities() -> void:
	for chunk: Vector2i in entity_manager.chunkMap.keys():
		_dirty_chunks[chunk] = true
	#先停动画：清空后视觉层再去 attach 就是往已经倒掉的表里塞建筑
	_cancel_visual()
	for en in _entities:
		if en != null:
			en.alive = false
	_detached.clear()
	_act_ents.clear()
	_act_masks.clear()
	_entities.clear()
	_occupied.clear()
	#批量平面整块丢掉：清场后旧位上的寄存器状态对新场景没意义，
	#留着下次放机器人还得从第几万个 bit 往后排
	_groups.clear()
	_active_groups.clear()
	_sel_set.clear()
	_box_active = false
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
#正前方是箱子时走推箱：箱子前方空闲则箱子先进一格、机器人跟到原箱子格；
#箱子前方被占（墙/另一个箱子/另一台机器人）则整次移动失败，两者都不动。
#注意：位置/占格表在调用的当场就改完了（实体才是权威），变慢的只是**看起来**走过去，
#所以「一拍走一格」的逻辑语义一点没动，测试不用等动画。
func move_entity(e: SWRobotEntity) -> bool:
	if e == null:
		return false
	var from_pos: Vector2i = e.grid_pos
	#目标格一次算出来（原实现算了两次：自己一次 + step_forward 内部一次）
	var to_pos: Vector2i = from_pos + DIR4_VECS[int(e.dir) & 3] * SwDefine.GRID_SIZE
	var other = _occupied.get(to_pos, null)
	if other != null:
		#先推箱：推不动就直接失败，这一步机器人不该迈出去
		if not other.is_box:
			return false
		if not _push_box(other, int(e.dir)):
			return false
	#能进：占用判定就在上面用占格表当场做完（原实现跑到 e.step_forward() 里
	#调一次 blocked_probe 的 Callable，带参数数组装箱，一万台一拍就是一万次动态调用）
	e.grid_pos = to_pos
	_occupied.erase(from_pos)
	_occupied[to_pos] = e
	_lay_moved(e, from_pos, to_pos)
	return true

#push 事件：只把正前方的箱子推一格，机器人自己不动。
#没有箱子 / 箱子前方被占都返回 false
func push_entity(e: SWRobotEntity) -> bool:
	if e == null:
		return false
	#只看正前方那一格，直接对占格表取，不走 _box_at -> next_cell 两层调用
	var other = _occupied.get(e.grid_pos + DIR4_VECS[int(e.dir) & 3] * SwDefine.GRID_SIZE, null)
	if other == null or not other.is_box:
		return false
	return _push_box(other, int(e.dir))

#某格上的箱子：没有实体或不是箱子都返回 null
func _box_at(cell: Vector2i):
	var other = _occupied.get(cell, null)
	if other != null and other.is_box:
		return other
	return null

#把箱子沿 dir 推进一格；箱子前方被占就失败（只支持单层推箱）。
#走的是与机器人同一套「先改权威状态，再补动画」流程
func _push_box(box, dir: int) -> bool:
	if box == null:
		return false
	var box_from: Vector2i = box.grid_pos
	var box_to: Vector2i = box_from + DIR4_VECS[dir & 3] * SwDefine.GRID_SIZE
	if _occupied.has(box_to):
		return false
	box.grid_pos = box_to
	_occupied.erase(box_from)
	_occupied[box_to] = box
	_lay_moved(box, box_from, box_to)
	return true

#实体已经改完 grid_pos 与占格表，这里只管「看起来怎么过去」与上屏
func _lay_moved(e: SWRobotEntity, from_pos: Vector2i, to_pos: Vector2i) -> void:
	#视觉层能接管就给滑块动画。注意：接管后这台不再回烘焙层，所以只需要 detach 时
	#把旧格子那个区块重建一次；之后每拍都不再碰区块，比「每拍重建两块」省很多。
	#快路径（已接管）在这里完全内联：只读一个行号字段 + 两次 PackedArray append，
	#不进视觉层任何函数（一万台一拍少一万次调用）
	var vis = _visual
	var r: int = -1
	if is_instance_valid(vis):
		r = e.anim_row
		if r < 0 and (e.render_detached or detach_render(e)):
			#首次接管：要撤下烘焙实例 + 生成模板（每台只走这一次）
			r = int(vis.adopt(e, from_pos))
			if r < 0:
				attach_render(e)
	if r >= 0:
		_mv_rows.append(r)
		_mv_xy.append(float(to_pos.x))
		_mv_xy.append(float(to_pos.y))
		if not _in_beat_low:
			_flush_visual()
		return
	#接不了（纯逻辑测试 / 没挂视图）：老口径，两个区块都标脏后原地重新入表
	_dirty_chunks[SwCommon.GetChunkPos(from_pos)] = true
	_dirty_chunks[SwCommon.GetChunkPos(to_pos)] = true
	_reslot(e)

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
	elif not _in_beat_low:
		_flush_visual()

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
#静态派发：探测已经不需要了（基类 SWLayer 有空实现，没动画的层直接返回 false）。
#原来每台一次 has_method + 一次 call，一万台一拍就是两万次反射查表
func _start_move_anim(e: SWRobotEntity, from_pos: Vector2i, to_pos: Vector2i) -> bool:
	var vis = _visual
	if not is_instance_valid(vis):
		return false
	if not e.render_detached and not detach_render(e):
		return false
	if not bool(vis.start_move(e, from_pos, to_pos)):
		#视觉层不接（例如没有渲染代理）：立刻挂回去，不能把实体悬在半空
		attach_render(e)
		return false
	return true

func _start_rotate_anim(e: SWRobotEntity, from_dir: int, to_dir: int) -> bool:
	var vis = _visual
	if not is_instance_valid(vis):
		return false
	if not e.render_detached and not detach_render(e):
		return false
	if not bool(vis.start_rotate(e, from_dir, to_dir)):
		attach_render(e)
		return false
	return true

#把一台从烘焙层撤下来（动画期间由视觉层画）。返回 false = 没代理，撤不了
func detach_render(e: SWRobotEntity) -> bool:
	if e == null or e.draw_item == null:
		return false
	if e.render_detached:
		return true
	var item: SWBuildItemDefine = e.draw_item
	var arr: Array[SWBuildItemDefine] = [item]
	entity_manager.delBuilds(arr)
	#delBuilds 把建筑标成了待删除：动画期间它不在表里，但仍要当活建筑用
	item.buildState.state = SwDefine.BuildState.SELECTED if _in_selection(e) else SwDefine.BuildState.IDLE
	_detached[e] = true
	e.render_detached = true
	#原格子所在区块重建一次，把这台的旧实例从烘焙层抹掉（不抹就是「同时有两个」）
	_dirty_chunks[SwCommon.GetChunkPos(item.buildAxisPos)] = true
	return true

#滑完了把这一台按新格子挂回烘焙层（新位置入表 -> 区块重建）。
#正常运行路径上**不再走这里**（接管后一直留在动画层，避免交接空窗），只在视觉层拒接时备用
func attach_render(e) -> void:
	if e == null:
		return
	_detached.erase(e)
	e.render_detached = false
	var item: SWBuildItemDefine = e.draw_item
	if item == null:
		return
	item.buildState.state = SwDefine.BuildState.SELECTED if _in_selection(e) else SwDefine.BuildState.IDLE
	item.buildAxisPos = e.grid_pos
	entity_manager.addBuild(item)
	_dirty_chunks[SwCommon.GetChunkPos(e.grid_pos)] = true
	#动画是帧回调里结束的，不会跟在某次操作后面，得自己提交一次
	flush_render()

func is_detached(e) -> bool:
	return e != null and bool(e.render_detached)

func get_detached_count() -> int:
	return _detached.size()

#把视觉层攒下的登记（滑动批次 / 可见实例数）一次提交
func _flush_visual() -> void:
	if view == null:
		return
	var vis = _visual
	if is_instance_valid(vis) and not _mv_rows.is_empty():
		vis.start_moves(_mv_rows, _mv_xy)
	_mv_rows.clear()
	_mv_xy.clear()
	view.flush_visual()

#视觉层彻底不管这一台（删实体时用）：抹掉动画记录与光框，不碰烘焙层表
func _stop_visual(e) -> void:
	if view == null:
		return
	view.release_visual(e)
	#被删的这一台如果正亮着光框，立刻淡出：跟着已删实体继续亮没意义
	view.set_visual_glow(e, false)

func _cancel_visual() -> void:
	if view != null:
		view.cancel_visual()
#endregion

#region 选中（单击 / Ctrl 框选）
#鼠标左键点到机器人 -> 选中；点到空地 -> 取消选中。
#Ctrl+左键拖 = 框选加选，Ctrl+右键拖 = 框选减选。
#带 Ctrl 的这两笔必须在本层吃掉：不然 Ctrl+右键拖会落到手持层的擦除分支，
#把框里的机器人全删了（手持层那一套框选选的是建筑，机器人场景没有 build system）
func handle_input(event: InputEvent) -> bool:
	if view == null:
		return false
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		#框选进行中：只认「同一个键松开」，中途别的键与滚轮一概吞掉，
		#否则相机缩放 / 放置 / 擦除都会插进这一笔里
		if _box_active:
			if mb.button_index == _box_button and not mb.is_pressed():
				return box_select_end(_event_world(mb.position))
			return true
		if mb.is_pressed() and mb.ctrl_pressed \
				and (mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT):
			#起框选。手上正拿着机器人/箱子时不抢：那一笔是拿去放置的
			return box_select_begin(mb.button_index, _event_world(mb.position))
		if mb.button_index != MOUSE_BUTTON_LEFT or not mb.is_pressed():
			return false
		return select_at(_mouse_grid())
	if event is InputEventMouseMotion and _box_active:
		return box_select_update(_event_world((event as InputEventMouseMotion).position))
	return false

#视口坐标（事件里的 position）-> 世界坐标
func _event_world(view_pos: Vector2) -> Vector2:
	var v := _get_view()
	if v == null:
		return Vector2.ZERO
	var viewport := v.get_viewport()
	if viewport == null:
		return Vector2.ZERO
	return SwCommon.GetGlobalPosByViewPos(view_pos, viewport)

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
	#箱子不绑电路：点它不选中（绑定面板不该弹出来），顺手把已有选中收起
	if e != null and e.is_box:
		clear_selection()
		return false
	if e == null:
		return clear_selection()
	return set_selected(e)

func set_selected(e) -> bool:
	#重复点同一台也要发：面板可能已被用户关掉，再点一下得能重新弹出来
	if _selected == e and _sel_set.size() <= 1 and (e == null or _sel_set.has(e)):
		if e != null:
			entity_selected.emit(e)
		return e != null
	#单选是「替换」语义：框选出来的那一堆要清掉（否则点一下会变成 N+1 台）
	_clear_selection_state()
	if e == null:
		selection_cleared.emit()
		return false
	_sel_set[e] = true
	_selected = e
	_mark_selected(e, true)
	entity_selected.emit(e)
	return true

func clear_selection() -> bool:
	if _selected == null and _sel_set.is_empty():
		return false
	_clear_selection_state()
	selection_cleared.emit()
	return false

#把选区（底色 + 光框 + 主选 + 集合）整块清掉：单选与框选共用
func _clear_selection_state() -> void:
	var v := _get_view()
	if not _sel_set.is_empty():
		var ents: Array = _sel_set.keys()
		for e in ents:
			_set_select_state(e, false)
		_sel_set.clear()
		if v != null:
			v.refresh_visual_tints(ents)
	if _selected != null:
		if v != null:
			v.set_visual_glow(_selected, false)
		_selected = null

#region Ctrl + 拖拽框选
#手持工具（机器人/箱子）时那一笔要拿去放置，框选得让路
func set_box_select_gate(gate: Callable) -> void:
	_box_gate = gate

func _box_allowed() -> bool:
	return not _box_gate.is_valid() or bool(_box_gate.call())

func is_box_selecting() -> bool:
	return _box_active

#当前框选矩形（世界坐标；没在框选时是空矩形）
func get_box_rect() -> Rect2:
	return Rect2(_box_from, _box_to - _box_from).abs() if _box_active else Rect2()

#Ctrl + 左/右键按下：起框选（左 = 加选，右 = 减选）
func box_select_begin(button_index: int, world_pos: Vector2) -> bool:
	if _box_active or not _box_allowed():
		return false
	if button_index != MOUSE_BUTTON_LEFT and button_index != MOUSE_BUTTON_RIGHT:
		return false
	_box_active = true
	_box_button = button_index
	_box_subtract = button_index == MOUSE_BUTTON_RIGHT
	_box_from = world_pos
	_box_to = world_pos
	_push_box_rect()
	return true

func box_select_update(world_pos: Vector2) -> bool:
	if not _box_active:
		return false
	_box_to = world_pos
	_push_box_rect()
	return true

#松手：位移太小当单击（Ctrl+点一下 = 点选那台），否则按矩形加/减选
func box_select_end(world_pos: Vector2) -> bool:
	if not _box_active:
		return false
	_box_to = world_pos
	_box_active = false
	_push_box_rect()
	var rect: Rect2 = Rect2(_box_from, _box_to - _box_from).abs()
	if rect.size.x < BOX_DRAG_MIN_PX and rect.size.y < BOX_DRAG_MIN_PX:
		if _box_button == MOUSE_BUTTON_LEFT:
			return select_at(Vector2i(world_pos))
		return true
	select_rect(rect, _box_subtract)
	return true

func _push_box_rect() -> void:
	var v := _get_view()
	if v == null:
		return
	var r: Rect2 = Rect2(_box_from, _box_to - _box_from).abs() if _box_active else Rect2()
	v.set_box_rect(r, _box_active, _box_subtract)

#把世界矩形里的机器人加进（或移出）选区，返回真正变了几台。
#按实体表逐台判断，不按格子全扫：视野缩到最小时框住的格子数能到几十万，
#而实体最多也就几千个，格子双重循环反而更贵
func select_rect(world_rect: Rect2, subtract: bool = false) -> int:
	var rect: Rect2 = world_rect.abs()
	var g: Vector2 = Vector2(SwDefine.GRID_SIZE)
	#格子范围的闭区间：end 减一兜住「右边界正好压在格线上」的情况
	var c0: Vector2i = Vector2i((rect.position / g).floor())
	var c1: Vector2i = Vector2i(((rect.end - Vector2.ONE) / g).floor())
	var changed: int = 0
	var touched: Array = []
	for e in _entities:
		#箱子不绑电路：框选只认机器人（与单击选中同一口径）
		if e == null or not e.alive or e.is_box:
			continue
		var c: Vector2i = e.cell()
		if c.x < c0.x or c.y < c0.y or c.x > c1.x or c.y > c1.y:
			continue
		if subtract:
			if not _sel_set.has(e):
				continue
			_sel_set.erase(e)
			_set_select_state(e, false)
			if _selected == e:
				var rest: Array = _sel_set.keys()
				_selected = rest[0] if not rest.is_empty() else null
			changed += 1
		else:
			if _sel_set.has(e):
				continue
			_sel_set[e] = true
			_set_select_state(e, true)
			if _selected == null:
				_selected = e
			changed += 1
		touched.append(e)
	if changed == 0:
		return 0
	var v := _get_view()
	if v != null:
		#动画层里那几台的选中色烘在模板 tint 里，得逐台重铺（没接管的台自己会跳过）
		v.refresh_visual_tints(touched)
		#光框只留给主选：视觉层只挂一个，N 台都亮反而看不出主次（底色已经染蓝了）
		v.set_visual_glow(_selected, _selected != null)
	#没接管的台走烘焙层重建，这里当场提交一次：节拍暂停时也能立刻看到选中色
	flush_render()
	#减选减空了：光框淡出、面板收起，别留一个对着空气的面板
	if _selected == null:
		selection_cleared.emit()
	else:
		selection_multi_changed.emit(get_selected_entities())
	return changed
#endregion

#选中高亮：烘焙层改底色（整块重建），视觉层叠一圈光框（收缩 + 呼吸）
#注意顺序：**先**改烘焙状态再通知视觉层。视觉层重写实例时读的就是 buildState.mask_color，
#反过来（先通知后改状态）它拿到的永远是上一态的颜色 ——
#表现就是「取消选中后动画层里那台机器人的底色不变」
func _mark_selected(e, on: bool) -> void:
	_set_select_state(e, on)
	var v := _get_view()
	if v != null:
		#光框不走进烘焙层：单独画才能呼吸/淡出，而且不会每帧重建区块
		v.set_visual_glow(e, on)

#只改底色，不碰光框：框选时 N 台都要染色，但光框只留给主选那一台
func _set_select_state(e, on: bool) -> void:
	if e == null or e.draw_item == null:
		return
	e.draw_item.buildState.state = SwDefine.BuildState.SELECTED if on else SwDefine.BuildState.IDLE
	_dirty_chunks[SwCommon.GetChunkPos(e.draw_item.buildAxisPos)] = true

func get_selected():
	return _selected

#当前选区（框选出来的那批；单选时就是那一台）。HUD 批量绑定用
func get_selected_entities() -> Array:
	return _sel_set.keys()

#这一台在不在选区里（单选与框选同一口径）。撤下/挂回烘焙层时用
func _in_selection(e) -> bool:
	return e != null and _sel_set.has(e)

func get_selection_count() -> int:
	return _sel_set.size()
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

#region 8 方向检测（相对方向码 3 位 + 物品码 5 位）
# 编码（详见 sw_robot_actions.gd）：bit7..bit5 = **相对朝向**的方向码
# （0 正前 / 2 正右 / 4 正后 / 6 正左，顺时针 +1），bit4..bit0 = 物品码
# （空 0 / 机器人 1 / 箱子 2，其余值留给以后）。
# 实际看哪里要叠上机器人朝向：abs = posmod(dir * 2 + code, 8)，DIR8_VECS 同序（0 北…7 西北）。
# 例：方向码 6 + 机器人朝西 -> 实际看正南；若那边有箱子，检测码 = 0b11000010
# （口序 res_0=1, res_1=1, res_6=1）。
#
# 两条通道：
#   - 内部接口：detect_around / detect_at / detect_code（测试/AI 可调）
#   - 电路接口：detect_sig_0..2 拼出方向码（相对朝向），机器人把该方向的
#     检测码拆成 8 个 bit 写进 detect_res_0..7
#
# 返回固定 8 项，**下标即方向码**（0 正前、2 正右、4 正后、6 正左）：
# 所以 last_detect[k] 就是电路选 k 时会拿到的码，两边直接对得上。
func detect_around(e) -> Array:
	if e == null:
		return []
	#一次算出格子和朝向偏移，别让 detect_code 每轮重算（e.cell() 是除法）
	var cell: Vector2i = e.cell()
	var facing: int = ACTIONS.facing_dir8(e.dir)
	var out: Array = []
	for d in DIR8_VECS.size():
		out.append(ACTIONS.encode_code(d, _item_code_at(cell + DIR8_VECS[(facing + d) & 7])))
	return out

# 按格子 + 假定朝向北（dir=0）查周围 8 格：这时相对方向码与绝对方向同序，
# 外部不持实体也能用（要别的朝向就传 robot_dir：0 上 / 1 右 / 2 下 / 3 左）
func detect_at(cell: Vector2i, robot_dir: int = 0) -> Array:
	var out: Array = []
	for d in DIR8_VECS.size():
		var a: int = ACTIONS.abs_dir_of(robot_dir, d)
		out.append(ACTIONS.encode_code(d, _item_code_at(cell + DIR8_VECS[a])))
	return out

# 单个方向的检测码（写电路的那份就是它）：方向码原样回填 + 该格物品码
# 方向码是相对的：真正去看的格子 = 机器人朝向叠加 dir_code
func detect_code(e, dir_code: int) -> int:
	if e == null:
		return 0
	var d: int = posmod(dir_code, DIR8_VECS.size())
	var a: int = ACTIONS.abs_dir_of(e.dir, d)
	return ACTIONS.encode_code(d, _item_code_at(e.cell() + DIR8_VECS[a]))

# 格子下标 -> 物品码（空格 0 / 机器人 1 / 箱子 2）
func _item_code_at(cell: Vector2i) -> int:
	var e = _occupied.get(cell * SwDefine.GRID_SIZE, null)
	if e == null:
		return ACTIONS.ITEM_NONE
	return ACTIONS.ITEM_BOX if e.is_box else ACTIONS.ITEM_ROBOT
#endregion

#region 电路绑定
# 给某个机器人绑一条 .swcir（阶段 4）。file_name 传空串 = 解绑。
# 不可用（文件缺失 / 解析失败 / 文件里没有电路）时返回 false；具体原因不在这里算，
# 面板用 SWCirManager.summarize 拿（同一个函数，避免两套判定逻辑跑偏）。
func bind_circuit(e, file_name: String) -> bool:
	if e == null:
		return false
	#换绑/解绑前先把旧槽位清出来（不清的话那块 bit 会带着旧状态继续跑，
	#虽然读不到它，但它会占着平面白烧位运算）
	_release_batch(e)
	if file_name.is_empty():
		#半拍空档里解绑：本拍已经排好的动作一并撤掉，否则低相位还会让它走一格
		_drop_pending_act(e)
		e.set_bundle(null)
		entities_changed.emit()
		return true
	var grp = _group_for(file_name)
	if grp != null and _entities.size() >= BATCH_MIN:
		e.batch_grp = grp
		e.batch_bit = grp.alloc_bit()
		#共享模板：只用来读接口名（面板/时序图/调试），从不 tick
		e.set_bundle(grp.template, file_name)
	else:
		var bundle = CIR_MANAGER.load_bundle(file_name)
		if bundle == null:
			return false
		e.set_bundle(bundle, file_name)
	#换电路了，旧电路的波形对新电路没意义，直接清空
	e.clear_timing()
	#每台机器人各持一份 runtime：同一文件绑给多台互不影响
	entities_changed.emit()
	return true

# 把实体从批量平面里摘出来（删机器人 / 换电路 / 解绑）
func _release_batch(e) -> void:
	if e == null or e.batch_grp == null:
		return
	e.batch_grp.clear_bit(e.batch_bit)
	e.batch_grp = null
	e.batch_bit = -1

# 把实体从本拍待执行队列里摘掉（解绑用）。
# 一拍分成高/低两个相位、中间隔半拍：玩家正好在这半拍里点「解除绑定」，
# 高相位读到的动作位图就还留在这台身上，低相位会把解绑前决定的那一步执行掉。
# 低相位正在遍历数组时不能改它（真撞上也由 step_beat_low 的 bundle 判空兜底）
func _drop_pending_act(e) -> void:
	if _in_beat_low or _act_ents.is_empty():
		return
	for i in range(_act_ents.size() - 1, -1, -1):
		if _act_ents[i] == e:
			_act_ents.remove_at(i)
			_act_masks.remove_at(i)

# 取/建某个电路文件的批量组：同一份网表只加载一次、表达式只编译一次。
# 返回 null = 这条电路跑不了批量（表达式后端不可用/文件缺失），调用方退回逐台
func _group_for(file_name: String):
	var g = _groups.get(file_name, null)
	if g != null:
		return g
	var tpl = CIR_MANAGER.load_bundle(file_name)
	if tpl == null:
		return null
	var grp = BIT_GROUP.new()
	grp.setup(tpl)
	if not grp.supported:
		return null
	grp.prepare(ACTIONS.ACTION_NAMES, ACTIONS.SIG_DIR_NAMES, ACTIONS.RES_PORT_NAMES)
	_groups[file_name] = grp
	return grp

#按最新 .swcir 重绑某个文件的全部机器人（分屏壳的「应用到机器人」走这里）。
#_groups 里缓的是旧网表的批量组，先摘掉它再逐台 bind_circuit：
#摘掉后旧组仍能被 _release_batch 清位（实体自己抓着组引用），新组按新文件重建。
#时序波形顺带清掉（旧电路的波形对新电路没意义）。返回重绑成功的台数
func reload_circuit(file_name: String) -> int:
	if file_name.is_empty():
		return 0
	_groups.erase(file_name)
	var n: int = 0
	for e in _entities:
		if e == null or str(e.circuit_file) != file_name:
			continue
		if bind_circuit(e, file_name):
			n += 1
	return n

func unbind_circuit(e) -> void:
	if e == null or not e.has_bundle():
		return
	_release_batch(e)
	_drop_pending_act(e)
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
	_act_ents.clear()
	_act_masks.clear()
	_active_groups.clear()
	#方向位图必须在开拍**之前**刷新：批量检测读的就是上一拍的 sig 电平。
	#这里刷全部组而不是「本拍活跃的组」：活跃集合要扫完实体才知道，
	#而刷一次是词级转置（每 64 台一个 64 位字，整组约 3ms），空组 next_bit=0 直接空转
	if not _groups.is_empty():
		for grp in _groups.values():
			grp.refresh_dir_masks()
	_beat_gen += 1
	var gen: int = _beat_gen
	#走批量的实体：它们的 tick 必须等**整组输入都写完**才跑（一组一次 tick 顶几千台）
	var batch_ents: Array = []
	var vecs: Array[Vector2i] = DIR8_VECS
	var gs: Vector2i = SwDefine.GRID_SIZE
	for e: SWRobotEntity in _entities:
		if e.bundle == null:
			continue
		var grp = e.batch_grp
		if grp != null:
			#内联批量检测：只算电路选中的**那一个方向**。
			#为什么不像逐台那样扫 8 格：8 次占格查询 × 上万台 = 8 万次字典查
			#（实测 127ms/拍，占掉一拍预算一半），而写进电路的只有一个方向的码。
			#代价：批量实体的 last_detect 不再逐拍刷新，要全表时调 detect_around(e) 现算
			#（存档/HUD 都不读它，只有小场景的测试路径会读到）
			var bit: int = e.batch_bit
			var m: int = grp.dir_mask_by_bit[bit]
			var dir: int = ((m & 1) << 2) | (m & 2) | ((m & 4) >> 2)
			#绕一圈 DIR8_VECS 而不是调 e.cell()/detect_code：省掉两步除法/乘法
			var v: Vector2i = vecs[(int(e.dir) * 2 + dir) & 7]
			var other = _occupied.get(e.grid_pos + v * gs, null)
			var item: int = 0
			if other != null:
				item = ACTIONS.ITEM_BOX if other.is_box else ACTIONS.ITEM_ROBOT
			grp._codes[bit] = (dir << ACTIONS.ITEM_BITS) | item
			if grp.touch_gen != gen:
				grp.touch_gen = gen
				_active_groups.append(grp)
			batch_ents.append(e)
			continue
		#先按上一拍的 detect_sig_* 选方向、把 8 位检测码写进输入口：
		#同一拍的电平与上升沿锁存就都能立刻用上这个结果
		_write_detect_inputs(e)
		e.bundle.set_input("clk", 0)
		e.bundle.tick_fast()
		e.bundle.set_input("clk", 1)
		e.bundle.tick_fast()
		_finish_high(e)
	#批量组：先 clk=0 跑一遍（让 last_clk 归零），再抬到 1 跑上升沿
	if not batch_ents.is_empty():
		for grp in _active_groups:
			grp.flush_res_codes(ACTIONS.DETECT_COUNT - 1)
			grp.fill_flat(grp.clk_flat, 0)
			grp.tick()
			grp.fill_flat(grp.clk_flat, 1)
			grp.tick()
			grp.refresh_action_masks()
		#收起尾：批量台只有「本拍真有事」才进低相位队列（没动作的台低相位本来也无事可做，
		#它们的 clk 是整组平面控制的、不需要单台回落）。上万台时这能省掉一整轮遍历
		var mv: int = ACTIONS.MOVE_MASK
		var rt: int = ACTIONS.ROT_MASK
		for e: SWRobotEntity in batch_ents:
			var grp = e.batch_grp
			var mask: int = grp.act_mask_by_bit[e.batch_bit]
			if e.trace_active:
				e.push_phase_high(1 if (mask & mv) != 0 else 0, 1 if (mask & rt) != 0 else 0)
				_act_ents.append(e)
				_act_masks.append(mask)
			elif mask != 0:
				_act_ents.append(e)
				_act_masks.append(mask)

#上升沿相位对**一台**的收尾：读动作位图、落高相位样本、记下这拍要做什么。
#逐台与批量两条路径只差在「位图从哪读」
func _finish_high(e) -> void:
	#一次批量读：位图第 i 位 = ACTION_NAMES[i] 的电平
	var mask: int = e.bundle.read_output_bits(ACTIONS.ACTION_NAMES)
	if debug_print_circuit:
		#排障口径：额外把**所有**输出名扫一遍（含 TABLE 里没登记的中间信号）。
		#打印口径：本拍确实写进去的 clk / 电平为 1 的输出名 / 寄存器 Q 串（高位在后）。
		#计数器"不动"时先看这里：Q 不推进 = 时钟沿没到，Q 推进而输出恒 0 = 电路逻辑问题。
		#日志保持 ASCII：Windows 控制台是 GBK，中文会乱码且没法 grep
		var act_names: Array = []
		for name in e.bundle.output_names():
			if e.bundle.output_level(str(name)) != 0:
				act_names.append(str(name))
		print("[robot-circuit] cell=%s file=%s clk=%d act=%s Q=%s" % [
				str(e.cell()), str(e.circuit_file), e.bundle.input_level("clk"),
				str(act_names), e.bundle.reg_q_text()])
	#clk 停在 1 直到下降沿相位（那里才回落）。只记高相位的样本
	if e.trace_active:
		e.push_phase_high(1 if (mask & ACTIONS.MOVE_MASK) != 0 else 0,
				1 if (mask & ACTIONS.ROT_MASK) != 0 else 0)
	_act_ents.append(e)
	_act_masks.append(mask)

#下降沿相位：clk 回落到 0、执行上升沿相位读到的输出、落低相位样本。
#返回本拍实际移动数
func step_beat_low() -> int:
	var moved: int = 0
	var ids: PackedInt32Array = _kind_ids
	var kn: int = ids.size()
	var mv: int = _mv_mask
	var rt: int = _rt_mask
	_in_beat_low = true
	for i in _act_ents.size():
		var e: SWRobotEntity = _act_ents[i]
		#高相位到低相位之间这台被删/被清场了：不能再动它（会把死实体塞回占格表）。
		#只查一个 bool 字段：原实现每台一次占格表字典查（Vector2i 哈希），实测 10ms/拍
		if e == null or not e.alive:
			continue
		var mask: int = _act_masks[i]
		#批量的 clk 整组共用一个平面，这里不能单台写（会把整组拨回 0，
		#而那些已经轮到下一拍的台会丢上升沿）；下一拍高相位本来就会重写一次。
		#bundle 判空：高相位到低相位之间隔了半拍，玩家可能在这期间解绑这台
		#（外面若没来得及把实体从 _act_ents 摘掉，这里也不能对着 null 调方法）
		if e.batch_grp == null and e.bundle != null:
			e.bundle.set_input("clk", 0)
		var acted: int = 0
		#按 SWRobotActions.TABLE 的顺序执行：顺序即同一拍内多个事件同时为 1 时的先后。
		#mask == 0（绝大多数拍）直接跳过，不看表
		if mask != 0:
			for r in kn:
				if (mask & (1 << r)) == 0:
					continue
				#动作 id 是整数：以前这里取字符串再逐个 ==，一万台一拍几万次字符串比较
				var k: int = ids[r]
				if k == ACTIONS.KIND_ROTATE:
					rotate_entity(e, 1)
					acted = 1
				elif k == ACTIONS.KIND_MOVE:
					if move_entity(e):
						moved += 1
						acted = 1
				elif k == ACTIONS.KIND_PUSH:
					if push_entity(e):
						acted = 1
		#时序图两条轨仍只认 move/rotation 的**输出电平**（被挡住时 mv=1 但 acted=0）
		if e.trace_active:
			e.push_phase_low(1 if (mask & mv) != 0 else 0, 1 if (mask & rt) != 0 else 0, acted)
	_act_ents.clear()
	_act_masks.clear()
	_in_beat_low = false
	#本拍攒下的滑动登记一次提交（逐台起滑在一万台规模下要多 30ms）
	_flush_visual()
	flush_render()
	return moved

#把**上一拍电路给的方向码**的检测码写进 detect_res_0..7。
# 方向码来自 detect_sig_0..2（编号小的口在左：权重 4/2/1），拼出 0..7 的
#   **相对朝向**方向码（0 正前 / 2 正右 / 4 正后 / 6 正左）；
#   三根全低 = 方向码 0（正前，即机器人当前朝的那一格）—— 没有「不上报」这一态，
#   所以机器人每拍都会回填一个方向的检测结果。
# detect_sig_3..7 是保留位，写了也不参与。
# 写回的口序同样「编号小的在左」：res_0..2 = 方向码（4/2/1，原样回示），
#   res_3..7 = 物品码（16/8/4/2/1，例：00111 = 物品码 7）。
#读的是「上一拍」的输出：此刻电路还没跑本拍的 tick，slot 里就是上一拍的结果。
func _write_detect_inputs(e) -> void:
	if e == null or e.bundle == null:
		return
	var dir: int = _read_sig_dir(e)
	#8 个方向一次扫完：既拿到电路选的那一位（要回写的 res 口），
	#也顺手刷新面板/AI/测试看的全表（原来先 detect_code 再 detect_around，同一格子扫两遍）
	var around: Array = detect_around(e)
	var code: int = int(around[posmod(dir, around.size())])
	#一次循环写 8 个口：编号小的在左（res_0 = 最高位，bit_base = DETECT_COUNT - 1）
	if e.batch_grp != null:
		#批量：先存进组里，等整组输入凑齐再一次性摊到位平面
		e.batch_grp.set_res_code(e.batch_bit, code)
	else:
		e.bundle.write_input_bits(ACTIONS.RES_PORT_NAMES, code, ACTIONS.DETECT_COUNT - 1)
	#内部接口也同步刷一份：面板/AI/测试不跑电路也能看到这拍的检测结果
	e.last_detect = around

#某台机器人本拍写进电路的检测码（8 位：bit7..bit0 = detect_res_0..7）。
#批量路径下 e.bundle 只是共享模板、输入槽不随本台更新，真正的值在组里那份 code 上；
#逐台路径直接按口读回来。分屏壳用它把两边的输入位对齐（否则右侧永远看不到高电平）
func get_detect_code(e) -> int:
	if e == null or e.bundle == null:
		return 0
	if e.batch_grp != null:
		return int(e.batch_grp.get_res_code(e.batch_bit))
	var code:int = 0
	for port in ACTIONS.DETECT_COUNT:
		if e.bundle.input_level(ACTIONS.res_name(port)) != 0:
			code |= 1 << ACTIONS.res_bit(port)
	return code

#把 detect_sig_0..2 拼成方向码（0..7，相对朝向）。
# 编号小的口是高位：sig_0=4、sig_1=2、sig_2=1，所以「110」= 6 = 正左（自己坐标系）；
# 保留位（sig_3..7）不参与，三根全低就是方向码 0（正前）。
func _read_sig_dir(e) -> int:
	#一次批量读三根方向位（原来 3 次 output_level + 3 次名字查）
	var bits: int = e.bundle.read_output_bits(ACTIONS.SIG_DIR_NAMES)
	var dir: int = 0
	for i in ACTIONS.SIG_DIR_COUNT:
		if (bits & (1 << i)) != 0:
			dir |= ACTIONS.sig_weight(i)
	return dir
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
	var boxes: Array = []
	for e in _entities:
		var c: Vector2i = e.cell()
		#箱子只有摆位（不跟节拍、没朝向、没电路），单独一张表
		if e.kind == KIND_BOX:
			boxes.append({"x": c.x, "y": c.y})
			continue
		robots.append({
			"x": c.x, "y": c.y,
			"dir": int(e.dir),
			"circuit": str(e.circuit_file)})
	return {"version": 2, "robots": robots, "boxes": boxes}

#按 to_dict 重建；返回真正建出来的机器人数（被删掉的电路文件会解绑但仍保留机器人）
#先建箱子再建机器人：正常存档两者不会重叠；真撞上了后建的（机器人）会被占格挡掉，
#不为此做位置迁移——那种存档本来就不该存在
func load_from_dict(data: Dictionary) -> int:
	clear_entities()
	#旧存档（version 1）没有 boxes 字段，缺省当空数组
	for b in data.get("boxes", []):
		#JSON 数字回来是 float，统一 int() 一下
		spawn_box(Vector2i(int(b.get("x", 0)), int(b.get("y", 0))) * SwDefine.GRID_SIZE)
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
