class_name SWCameraSystem extends SWSystem

#被控组件
var _camera:SWCamera2D = null

var _speed = 2000
var _speedUp = 10
var _acceleration = 1.3  # 加速度系数，数值越大加速越快
var _deceleration = 5.0  # 减速度系数，数值越大减速越快
var _middleButtonPressed = false

func _init() -> void:
	system_name = &"core.camera"
	run_order = SwDefine.ORDER_CAMERA
	receives_frame = true

func attach_camera(c:SWCamera2D) -> void:
	_camera = c
	_camera.set_camere_system(self)
	
func handle_input(event:InputEvent) -> bool:
	if _camera == null:
		return false
	if event is InputEventMouseButton:
		var vec:Vector2 = Vector2(0,0)
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			vec.y = 1
			_camera._on_zoomCom_zoom(vec)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			vec.y = -1
			_camera._on_zoomCom_zoom(vec)
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			_middleButtonPressed = event.pressed
	elif event is InputEventMouseMotion:
		if _middleButtonPressed:
			var vec:Vector2 = -event.relative
			if vec.length() > 0:
				_camera._on_moveCom_moveByMouse(vec)
	return false
var _target_velocity := Vector2.ZERO
var _current_velocity = Vector2.ZERO
func frame(_delta:float) -> void:
	# 计算目标速度
	_target_velocity = Vector2(0,0)
	if Input.is_action_pressed("UP"):
		_target_velocity.y-=_speed
	if Input.is_action_pressed("DOWN"):
		_target_velocity.y+=_speed
	if Input.is_action_pressed("LEFT"):
		_target_velocity.x-=_speed
	if Input.is_action_pressed("RIGHT"):
		_target_velocity.x+=_speed
	if Input.is_action_pressed("SPEED_UP"):
		_target_velocity*=_speedUp
	
	# 计算速度差
	var velocity_diff = _target_velocity - _current_velocity
	
	# 根据速度差和方向计算加速度
	var accel_rate = 0.0
	if velocity_diff.length() > 0:
		# 如果当前正在加速（速度差与当前速度方向相同或从静止开始）
		if _current_velocity.dot(velocity_diff) > 0 || _current_velocity.length() < 0.1:
			accel_rate = _acceleration
		else:
			# 否则是减速
			accel_rate = _deceleration
	
	# 应用加速度
	_current_velocity += velocity_diff * accel_rate * _delta
	
	# 当接近目标速度时，直接设置为目标速度，避免震荡
	if velocity_diff.length() < 10.0:
		_current_velocity = _target_velocity
	
	# 当速度很小时，直接设置为0，避免因精度问题导致的持续移动
	if _current_velocity.length() < 1:
		_current_velocity = Vector2.ZERO
	
	# 计算实际移动量
	var vec = _current_velocity * _delta
	if vec.length()>0:
		_camera._on_moveCom_move(vec)
