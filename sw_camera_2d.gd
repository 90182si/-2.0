class_name SWCamera2D extends Camera2D

var view_scale_level = 0

var _layerObjList = []
func addLayerNotify(swLayer:SWLayer) -> void:
	_layerObjList.append(swLayer)
func delLayerNotify(swLayer:SWLayer) -> void:
	_layerObjList.erase(swLayer)

func _on_zoomCom_zoom(vec:Vector2,centerPos:Vector2) -> void:
	if view_scale_level < SWDefine.VIEW_MIN_LEVEL and vec.y < 0:
		return
	if view_scale_level > SWDefine.VIEW_MAX_LEVEL and vec.y > 0:
		return
	var myScale = Vector2(pow(1.1,view_scale_level),pow(1.1,view_scale_level))
	if vec.y > 0:
		view_scale_level += 1
	elif vec.y < 0:
		view_scale_level -= 1
	myScale = Vector2(pow(1.1,view_scale_level),pow(1.1,view_scale_level))
	zoom = myScale
	var mousePos2 = get_global_mouse_position()
	position-=(mousePos2-centerPos)
	view_rect_changed()
	pass

func _on_moveCom_move(vec:Vector2) -> void:
	position += vec/Vector2(pow(1.05,view_scale_level),pow(1.05,view_scale_level))
	view_rect_changed(vec)
	pass
	
func _on_moveCom_moveByMouse(vec:Vector2) -> void:
	position += vec/zoom#Vector2(pow(1.05,view_scale_level),pow(1.05,view_scale_level))
	view_rect_changed(vec)
	pass

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

	var sca = 1
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
	if rotation != 0:
		# 获取矩形的四个顶点
		var top_left = visible_rect.position
		var top_right = visible_rect.position + Vector2(visible_rect.size.x, 0)
		var bottom_left = visible_rect.position + Vector2(0, visible_rect.size.y)
		var bottom_right = visible_rect.end

		# 将顶点围绕相机中心旋转
		var center = global_position
		top_left = center + (top_left - center).rotated(rotation)
		top_right = center + (top_right - center).rotated(rotation)
		bottom_left = center + (bottom_left - center).rotated(rotation)
		bottom_right = center + (bottom_right - center).rotated(rotation)

		# 重新计算旋转后的包围矩形
		var min_x = min(top_left.x, top_right.x, bottom_left.x, bottom_right.x)
		var min_y = min(top_left.y, top_right.y, bottom_left.y, bottom_right.y)
		var max_x = max(top_left.x, top_right.x, bottom_left.x, bottom_right.x)
		var max_y = max(top_left.y, top_right.y, bottom_left.y, bottom_right.y)

		visible_rect = Rect2(min_x, min_y, max_x - min_x, max_y - min_y)

	return visible_rect
