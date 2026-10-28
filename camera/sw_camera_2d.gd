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
	_apply_position()
	_update_atlas_lod()
	view_rect_changed()
	pass

func _on_moveCom_move(vec:Vector2) -> void:
	_sync_logic_from_external()
	_logic_pos += vec/Vector2(pow(1.05,view_scale_level),pow(1.05,view_scale_level))
	_apply_position()
	view_rect_changed(vec)
	pass
	
func _on_moveCom_moveByMouse(vec:Vector2) -> void:
	_sync_logic_from_external()
	_logic_pos += vec/zoom#Vector2(pow(1.05,view_scale_level),pow(1.05,view_scale_level))
	_apply_position()
	view_rect_changed(vec)
	pass

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
	var z := zoom.x if zoom.x != 0.0 else 1.0
	if (global_position - _applied_pos).length() * z > 1.0:
		_logic_pos = global_position
		_applied_pos = global_position

# 外部直接设置视野（读档等）：同步连续位置，避免吸附后与逻辑位置脱节
func set_view(pos:Vector2, zoom_vec:Vector2, level:int) -> void:
	zoom = zoom_vec
	view_scale_level = level
	_logic_pos = pos
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

func view_rect_changed(speedVec:Vector2=Vector2.ZERO) -> void:
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
