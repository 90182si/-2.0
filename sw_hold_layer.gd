class_name SWHoldLayer extends SWLayer

@onready var sw_draw_manager: SWDrawManager = $SWDrawManager
@onready var sw_draw_manager_2: SWDrawManager = $SWDrawManager2

@export var _hold_shadow_define:SWBuildDefine

@export var hold_spring_frequency_hz: float = 6.0
@export var hold_damping_ratio: float = 0.7
@export var hold_max_substep: float = 1.0 / 60.0

var _hold_smoothed_world_pos: Vector2
var _hold_smoothed_world_vel := Vector2.ZERO
var _hold_pos_inited := false
var _cur_hold_builds:Array[SWBuildDefine] = []

signal holdIdleBuilds(builds:Array[SWBuildDefine])

func _ready() -> void:
	sw_draw_manager.setDrawMode(SWDefine.GridDrawMode.ByHold)
	sw_draw_manager_2.setDrawMode(SWDefine.GridDrawMode.HoldShadow)
	
func on_view_rect_changed(viewRect:Rect2,speedVec:Vector2) -> void:
	sw_draw_manager.on_view_rect_changed(viewRect,speedVec)
	sw_draw_manager_2.on_view_rect_changed(viewRect,speedVec)
	
	if left_mouse_pressed:
		var world_pos = getCurWorldPosByMouse()
		if _cur_hold_builds.size() != 1:
			return
		if abs(world_pos.x-last_world_pos.x)>=SWDefine.GRID_SIZE.x or abs(world_pos.y-last_world_pos.y)>=SWDefine.GRID_SIZE.y:
			last_world_pos = world_pos
			holdIdleBuilds.emit(_cur_hold_builds)
			print("idle")
	pass

func on_sel_tool(buildDefine:SWBuildDefine) -> void:
	var drawData:SWDrawData = SWDrawData.new()
	drawData.addOneDrawBuildDefine(Vector2i(0,0),buildDefine)
	#drawData.addOneDrawBuildDefine(Vector2i(2,0),buildDefine)
	#drawData.addOneDrawBuildDefine(Vector2i(1,0),buildDefine)
	#drawData.addOneDrawBuildDefine(Vector2i(1,1),buildDefine)
	sw_draw_manager.setHoldBuild(drawData)
	var drawData2:SWDrawData = SWDrawData.new()
	drawData2.addOneDrawBuildDefine(Vector2i(0,0),_hold_shadow_define)
	#drawData2.addOneDrawBuildDefine(Vector2i(2,0),_hold_shadow_define)
	#drawData2.addOneDrawBuildDefine(Vector2i(1,0),_hold_shadow_define)
	#drawData2.addOneDrawBuildDefine(Vector2i(1,1),_hold_shadow_define)
	sw_draw_manager_2.setHoldBuild(drawData2)
	_hold_pos_inited = false
	
	_cur_hold_builds.append(buildDefine)
	pass
	
func getCurWorldPosByMouse() -> Vector2:
	var viewport := get_viewport()
	var mouse_pos := viewport.get_mouse_position()
	## 视口坐标转为世界坐标（canvas 坐标）
	var world_pos = SWCommon.GetGlobalPosByViewPos(mouse_pos,viewport)
	return world_pos
	
func _process(delta: float) -> void:
	
	var world_pos = getCurWorldPosByMouse()
	if not _hold_pos_inited:
		_hold_smoothed_world_pos = world_pos
		_hold_smoothed_world_vel = Vector2.ZERO
		_hold_pos_inited = true
	else:
		# 二阶弹簧/阻尼模型（可回弹）
		var hz: float = maxf(0.0, hold_spring_frequency_hz)
		var zeta: float = maxf(0.0, hold_damping_ratio)
		var omega: float = TAU * hz
		
		# 大 delta 时分段积分，减少不稳定和穿透
		var remaining: float = minf(delta, 0.25)
		var max_step: float = maxf(0.0005, hold_max_substep)
		while remaining > 0.0:
			var dt: float = minf(remaining, max_step)
			remaining -= dt
			
			# a = -2ζω v - ω² (x - target)
			var x_err: Vector2 = _hold_smoothed_world_pos - world_pos
			var accel: Vector2 = (-2.0 * zeta * omega) * _hold_smoothed_world_vel - (omega * omega) * x_err
			_hold_smoothed_world_vel += accel * dt
			_hold_smoothed_world_pos += _hold_smoothed_world_vel * dt
	
	sw_draw_manager.setHoldBuildsPos(_hold_smoothed_world_pos)
	sw_draw_manager_2.setHoldBuildsPos(_hold_smoothed_world_pos)

var last_world_pos
var left_mouse_pressed = false
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.is_pressed():
			if event.button_index == MOUSE_BUTTON_RIGHT:
				sw_draw_manager.setHoldBuild(null) 
				sw_draw_manager_2.setHoldBuild(null) 
				_hold_pos_inited = false
				_cur_hold_builds.clear()
			elif event.button_index == MOUSE_BUTTON_LEFT:
				if _cur_hold_builds.size() > 0:
					last_world_pos = getCurWorldPosByMouse()
					holdIdleBuilds.emit(_cur_hold_builds)
					left_mouse_pressed = true
					#print("idle")
		elif event.is_released():
			if event.button_index == MOUSE_BUTTON_LEFT:
				left_mouse_pressed = false
	elif event is InputEventMouseMotion:
		#如果鼠标左键按下
		if left_mouse_pressed:
			var world_pos = getCurWorldPosByMouse()
			if _cur_hold_builds.size() != 1:
				return
			if abs(world_pos.x-last_world_pos.x)>=SWDefine.GRID_SIZE.x or abs(world_pos.y-last_world_pos.y)>=SWDefine.GRID_SIZE.y:
				last_world_pos = world_pos
				holdIdleBuilds.emit(_cur_hold_builds)
				#print("idle")
