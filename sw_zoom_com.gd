class_name SWZoomCom extends Control
	
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if not event.pressed:
			return
		var vec:Vector2 = Vector2(0,0)
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			vec.y = 1
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			vec.y = -1
		if vec.length()>0:
			zoomObj(vec)
	
var _zoomLayerObjList = []
func addZoomFuncObject(swLayer:SWLayer) -> void:
	_zoomLayerObjList.append(swLayer)
func delZoomFuncObject(swLayer:SWLayer) -> void:
	_zoomLayerObjList.erase(swLayer)
func zoomObj(vec) -> void:
	var mousePos = get_local_mouse_position()
	for cam:SWCamera2D in _zoomCamObjList:
		cam._on_zoomCom_zoom(vec,mousePos)

var _zoomCamObjList = []
func addZoomFuncCamObject(swCam:Camera2D) -> void:
	_zoomCamObjList.append(swCam)
func delZoomFuncCamObject(swCam:Camera2D) -> void:
	_zoomCamObjList.erase(swCam)
