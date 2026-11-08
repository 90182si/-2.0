class_name SWCamera2D extends Camera2D

var view_scale_level = 0

# 亚像素吸附：把渲染位置对齐到整屏幕像素
# 相机停在亚像素位置时，光栅化会按各图元自己的边界取整（区块格距 128*zoom 不是整数），
# 同一屏内有的图元跳 1 像素、有的不动，看起来就是整屏在抖。吸附后所有图元同进同退。
@export var snap_to_pixel: bool = true
# 连续逻辑位置：位移在这里累加，吸附只影响渲染结果，不会把不足 1 像素的位移丢掉
var _logic_pos: Vector2 = Vector2.ZERO
# 最近一次写入的渲染位置：用于发现外部直接改 position 的情况（读档、编辑器等）
var _applied_pos: Vector2 = Vector2.ZERO

var _layerObjList = []
func addLayerNotify(swLayer:SWLayer) -> void:
	_layerObjList.append(swLayer)
func delLayerNotify(swLayer:SWLayer) -> void:
	_layerObjList.erase(swLayer)

func _on_zoomCom_zoom(vec:Vector2,centerPos:Vector2 = Vector2.ZERO) -> void:
	if view_scale_level < SwDefine.VIEW_MIN_LEVEL and vec.y < 0:
		return
	if view_scale_level > SwDefine.VIEW_MAX_LEVEL and vec.y > 0:
		return
	_sync_logic_from_external()
	var old_zoom := zoom
	if vec.y > 0:
		view_scale_level += 1
	elif vec.y < 0:
		view_scale_level -= 1
	var new_zoom := Vector2(pow(1.1,view_scale_level),pow(1.1,view_scale_level))
	zoom = new_zoom
	# 以鼠标为中心缩放：保持鼠标指向的世界坐标点在缩放前后不变
	var mouse_screen := get_viewport().get_mouse_position()
	var viewport_center := get_viewport_rect().position
	var mouse_offset := mouse_screen - viewport_center
	_logic_pos += mouse_offset * (Vector2(1.0,1.0)/old_zoom - Vector2(1.0,1.0)/new_zoom)
	# 挂起的位移已经包含在 _logic_pos 里，下面这次 _apply_position 会一起落地
	_view_pending = false
	_pending_view_speed = Vector2.ZERO
	_apply_position()
	_update_atlas_lod()
	# 缩远时切换到简化内容 LOD（只画主体部件），避免视野变大后实例数暴涨导致的持续卡顿
	get_tree().call_group("DrawManager", "set_scale_level", view_scale_level)
	view_rect_changed()
	pass

# ===== 帧末合并的位移 =====
# 中键拖动时每个 InputEventMouseMotion 都会进来一次，125~1000Hz 的鼠标一帧能发 2~16 个
# 事件。以前每个事件都直接 _apply_position() + view_rect_changed()，而后者要跑 4 个 layer
# 的完整视口刷新（区块格全表枚举，缩远时单层上千格），开销被事件数放大十几倍。
# 现在只累加逻辑位移并打标记，由 SWCameraSystem.frame() 每帧调用 flush_view_update()
# 统一应用 + 刷新一次视口。
var _view_pending:bool = false
var _pending_view_speed:Vector2 = Vector2.ZERO

func _on_moveCom_move(vec:Vector2) -> void:
	_sync_logic_from_external()
	_logic_pos += vec/Vector2(pow(1.05,view_scale_level),pow(1.05,view_scale_level))
	_pending_view_speed += vec
	_view_pending = true

func _on_moveCom_moveByMouse(vec:Vector2) -> void:
	_sync_logic_from_external()
	_logic_pos += vec/zoom#Vector2(pow(1.05,view_scale_level),pow(1.05,view_scale_level))
	_pending_view_speed += vec
	_view_pending = true

# ===== 视口移动速度（性能面板读数 + 低速不通知 layer 的判定）=====
# 用连续逻辑位置的帧间差算：来源无关（中键拖动 / 方向键 / 滚轮缩放的锚点位移都算），
# 且不经过像素吸附——吸附后的 global_position 是整像素跳变，慢速拖动读出来会一顿一顿。
# _pending_view_speed 不能用：WASD 累加的是世界位移，鼠标拖动累加的是屏幕像素，两者单位不一致。
var view_speed: float = 0.0        # 世界单位/秒（指数平滑）
var view_speed_px: float = 0.0     # 屏幕像素/秒 = 世界速度 * zoom.x
# 低于该速度（世界单位/秒）时不触发 layer 的 on_view_rect_changed。
# 32 ≈ 每秒移动 1/4 个建筑格（格距 128）：这个量级的位移不可能让区块进出视野，
# 却会让每个 layer 都把区块格枚举一遍（缩远时单层上千格）。设 0 = 关闭该阈值。
@export var view_speed_min: float = 32.0
var _speed_prev_logic: Vector2 = Vector2.ZERO
var _speed_seeded: bool = false
# 位移已落地但没通知 layer 的标记（等下个无位移帧补上）
var _view_dirty: bool = false
# 上一次真正通知 layer 时的逻辑位置：低速跳过的累计位移超上限就必须补通知，
# 否则「慢慢拖很远」会让整屏区块都不加载。
var _last_notify_logic: Vector2 = Vector2.ZERO

func _process(delta: float) -> void:
	if delta <= 0.0:
		return
	if not _speed_seeded:
		_speed_seeded = true
		_speed_prev_logic = _logic_pos
		_last_notify_logic = _logic_pos
		return
	var inst := (_logic_pos - _speed_prev_logic).length() / delta
	_speed_prev_logic = _logic_pos
	# 指数平滑：读数不抖，但停下后 3~5 帧就落到 0（足够让「补最后一次通知」尽早触发）
	view_speed = lerpf(view_speed, inst, 0.4)
	if view_speed < 0.5:
		view_speed = 0.0
	view_speed_px = view_speed * absf(zoom.x)

# 距上一次通知 layer 累积了多少世界位移
func _skip_drift() -> float:
	return (_logic_pos - _last_notify_logic).length()

# 低速跳过期间允许积压的位移上限：取视口短边 1/4，夹在 [128, 2048]（= 1/16 到 1 个区块）
func _skip_drift_max() -> float:
	var vs := get_visible_rect().size
	return clampf(minf(vs.x, vs.y) * 0.25, 128.0, 2048.0)

# 把本帧累积的位移写进渲染位置，并刷新一次视口（每帧最多一次）
func flush_view_update() -> void:
	if _view_pending:
		_view_pending = false
		var speed := _pending_view_speed
		_pending_view_speed = Vector2.ZERO
		_apply_position()
		# 低速：位置照常落地，但不惊动 layer（见 view_speed_min）。
		# 积压位移到上限必须补通知，否则区块会跟不上。
		if view_speed >= view_speed_min or _skip_drift() >= _skip_drift_max():
			view_rect_changed(speed)
		else:
			_view_dirty = true
		return
	# 本帧没有新位移且速度也落下来了：把攒下的那次通知补上，保证视口最终一致。
	# 只在「无 pending」时补：连续慢速拖动如果每帧都补，「低速不通知」就白设了。
	if _view_dirty and view_speed < view_speed_min:
		view_rect_changed(Vector2.ZERO)

# 把连续逻辑位置写进渲染位置（按需吸附到整屏幕像素）
func _apply_position() -> void:
	if not snap_to_pixel or zoom.x == 0.0 or zoom.y == 0.0:
		global_position = _logic_pos
	else:
		# 屏幕坐标 = 世界坐标 * zoom，吸附到整数后再换回世界坐标
		global_position = (_logic_pos * zoom).round() / zoom
	_applied_pos = global_position

# 外部直接改过位置时（超过吸附可能造成的半个像素），把连续位置拉回来，避免下次移动跳回旧值
func _sync_logic_from_external() -> void:
	# 有未应用的位移时 global_position 落后于 _logic_pos，这种情况下比较没有意义，
	# 否则会把刚累积的位移当成「位置被外部改过」而整段丢掉
	if _view_pending:
		return
	var z := zoom.x if zoom.x != 0.0 else 1.0
	if (global_position - _applied_pos).length() * z > 1.0:
		_logic_pos = global_position
		_applied_pos = global_position

# 外部直接设置视野（读档等）：同步连续位置，避免吸附后与逻辑位置脱节
func set_view(pos:Vector2, zoom_vec:Vector2, level:int) -> void:
	zoom = zoom_vec
	view_scale_level = level
	_logic_pos = pos
	# 位移已被这次直接设置覆盖，挂起的更新作废
	_view_pending = false
	_pending_view_speed = Vector2.ZERO
	# 读档跳位置不是「移动」：速度基准一起重置，否则面板会读出一下假峰值
	_speed_prev_logic = pos
	view_speed = 0.0
	view_speed_px = 0.0
	_apply_position()
	_update_atlas_lod()
	view_rect_changed()

# 缩到阈值以外换低分辨率图集：只换纹理，不触发区块重绘
func _update_atlas_lod() -> void:
	if view_scale_level <= SwDefine.VIEW_LOD2_LEVEL:
		SwAtlas.set_lod(2)
	elif view_scale_level <= SwDefine.VIEW_LOD_LEVEL:
		SwAtlas.set_lod(1)
	else:
		SwAtlas.set_lod(0)

# ===== 画面移动状态（供电路 tick 等系统做「移动中暂停」）=====
# 只有真实玩家输入（中键拖动 / 方向键 / 滚轮缩放）才会打这个时间戳。
# 读档的 set_view、开局初始化都不算 —— 否则一进游戏电路就会先冻 120ms，测试也会被误伤。
const VIEW_SETTLE_USEC:int = 120000
static var _last_input_move_usec:int = -100000000

static func mark_view_moving() -> void:
	_last_input_move_usec = Time.get_ticks_usec()

# 停下 VIEW_SETTLE_USEC 之后才算「不动了」：拖动中鼠标事件 8~16ms 一个，
# 偶尔停一下也不会让电路拍抖起来。
static func is_view_moving() -> bool:
	return Time.get_ticks_usec() - _last_input_move_usec < VIEW_SETTLE_USEC

func view_rect_changed(speedVec:Vector2=Vector2.ZERO) -> void:
	# 记账：本次已通知，低速跳过看的就是这里到当前位置的距离
	_view_dirty = false
	_last_notify_logic = _logic_pos
	var viewRect := get_visible_rect()
	#viewRect.size/=6
	#viewRect.position += viewRect.size*2
	for layer:SWLayer in _layerObjList:
		layer.on_view_rect_changed(viewRect,speedVec)

# 获取 Camera2D 的可视范围（返回 Rect2 类型，包含位置和尺寸）
func get_visible_rect() -> Rect2:
	# 1. 获取视口大小（屏幕/窗口的像素尺寸）
	var viewport_size = get_viewport_rect().size

	# 2. 获取相机的缩放（会影响可视范围的大小）
	var camera_zoom = zoom

	var sca = 1#0.2
	# 3. 计算相机可视范围的半宽和半高（考虑缩放）
	var half_width = (viewport_size.x / 2.0 / camera_zoom.x)
	var half_height = (viewport_size.y / 2.0 / camera_zoom.y)

	# 4. 构建以相机位置为中心的矩形（未旋转）
	var visible_rect = Rect2(
		global_position.x + half_width*(1-sca),  # 矩形左上角 x 坐标
		global_position.y + half_height*(1-sca), # 矩形左上角 y 坐标
		half_width * 2.0 * sca,                # 矩形宽度
		half_height * 2.0 * sca                # 矩形高度
	)

	# （可选）如果相机有旋转，需要对矩形进行旋转修正
	#if rotation != 0:
		## 获取矩形的四个顶点
		#var top_left = visible_rect.position
		#var top_right = visible_rect.position + Vector2(visible_rect.size.x, 0)
		#var bottom_left = visible_rect.position + Vector2(0, visible_rect.size.y)
		#var bottom_right = visible_rect.end
#
		## 将顶点围绕相机中心旋转
		#var center = global_position
		#top_left = center + (top_left - center).rotated(rotation)
		#top_right = center + (top_right - center).rotated(rotation)
		#bottom_left = center + (bottom_left - center).rotated(rotation)
		#bottom_right = center + (bottom_right - center).rotated(rotation)
#
		## 重新计算旋转后的包围矩形
		#var min_x = min(top_left.x, top_right.x, bottom_left.x, bottom_right.x)
		#var min_y = min(top_left.y, top_right.y, bottom_left.y, bottom_right.y)
		#var max_x = max(top_left.x, top_right.x, bottom_left.x, bottom_right.x)
		#var max_y = max(top_left.y, top_right.y, bottom_left.y, bottom_right.y)
#
		#visible_rect = Rect2(min_x, min_y, max_x - min_x, max_y - min_y)

	return visible_rect

var _camera_sys:SWCameraSystem = null
func set_camere_system(cs:SWCameraSystem) -> void:
	_camera_sys = cs
func _unhandled_input(event: InputEvent) -> void:
	if _camera_sys and _camera_sys.enable:
		_camera_sys.handle_input(event)
