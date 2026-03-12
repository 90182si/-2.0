class_name SWMoveCom extends Control

@export var speed = 1000
@export var speedUp = 3
@export var acceleration = 8.0  # 加速度系数，数值越大加速越快
@export var deceleration = 10.0  # 减速度系数，数值越大减速越快

var _moveLayerObjList = []
func addMoveFuncObject(swLayer:SWLayer) -> void:
	_moveLayerObjList.append(swLayer)
func delMoveFuncObject(swLayer:SWLayer) -> void:
	_moveLayerObjList.erase(swLayer)
	
var _moveCamObjList = []
func addMoveFuncCamObject(swCam:Camera2D) -> void:
	_moveCamObjList.append(swCam)
func delMoveFuncCamObject(swCam:Camera2D) -> void:
	_moveCamObjList.erase(swCam)

var middleButtonPressed = false
var current_velocity = Vector2.ZERO  # 当前速度
var target_velocity = Vector2.ZERO    # 目标速度

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _process(delta: float) -> void:
	# 计算目标速度
	target_velocity = Vector2(0,0)
	if Input.is_action_pressed("UP"):
		target_velocity.y-=speed
	if Input.is_action_pressed("DOWN"):
		target_velocity.y+=speed
	if Input.is_action_pressed("LEFT"):
		target_velocity.x-=speed
	if Input.is_action_pressed("RIGHT"):
		target_velocity.x+=speed
	if Input.is_action_pressed("SPEED_UP"):
		target_velocity*=speedUp
	
	# 计算速度差
	var velocity_diff = target_velocity - current_velocity
	
	# 根据速度差和方向计算加速度
	var accel_rate = 0.0
	if velocity_diff.length() > 0:
		# 如果当前正在加速（速度差与当前速度方向相同或从静止开始）
		if current_velocity.dot(velocity_diff) > 0 || current_velocity.length() < 0.1:
			accel_rate = acceleration
		else:
			# 否则是减速
			accel_rate = deceleration
	
	# 应用加速度
	current_velocity += velocity_diff * accel_rate * delta
	
	# 当接近目标速度时，直接设置为目标速度，避免震荡
	if velocity_diff.length() < 10.0:
		current_velocity = target_velocity
	
	# 当速度很小时，直接设置为0，避免因精度问题导致的持续移动
	if current_velocity.length() < 1:
		current_velocity = Vector2.ZERO
	
	# 计算实际移动量
	var vec = current_velocity * delta
	if vec.length()>0:
		moveObj(vec)
		pass
	pass
	
func moveObj(vec:Vector2) -> void:
	for cam:SWCamera2D in _moveCamObjList:
		cam._on_moveCom_move(vec)

func moveObjByMouse(vec:Vector2) -> void:
	for cam:SWCamera2D in _moveCamObjList:
		cam._on_moveCom_moveByMouse(vec)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			if event.is_pressed():
				middleButtonPressed = true
			elif event.is_released():
				middleButtonPressed = false
	elif event is InputEventMouseMotion:
		if middleButtonPressed:
			var vec:Vector2 = Vector2(0,0)
			vec = -event.relative
			if vec.length()>0:
				moveObjByMouse(vec)  # 使用与WASD相同的移动方法
	pass
