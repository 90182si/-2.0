class_name SWSystemManager extends RefCounted

#事件总线
var bus = null

var _systems:Array[SWSystem] = []
var _by_name:Dictionary[StringName,SWSystem] = {}
var _order_map:Dictionary[SWSystem,int] = {}
var _seq_map:Dictionary[SWSystem,int] = {}
var _pending_add:Array[SWSystem] = []
var _pending_remove:Array[StringName] = []

#正在时刻内，各个系统执行tick()
var _running:bool = false
var _iterating:bool = false
var _tick_index:int = 0
var _system_insert_order:int = 0

#region 外部调用装配和卸载、启停
#注册
func add_system(system:SWSystem) -> bool:
	if system == null:
		push_error("[SWSystemManager] add_system: system 为 null")
		return false
	if system.system_name == &"":
		push_error("[SWSystemManager] add_system: 未设置 system_name")
		return false
	# 同名旧系统正在等待移除 → 先立即移除，再注册新系统
	if _pending_remove.has(system.system_name):
		_pending_remove.erase(system.system_name)
		_remove_now_condition(system.system_name)
	if _by_name.has(system.system_name):
		push_error("[SWSystemManager] add_system: 系统名重复 %s" % system.system_name)
		return false
	_by_name[system.system_name] = system
	#如果其他系统在执行tick
	if _iterating:
		_pending_add.append(system)
	else:
		_insert_system_condition(system)
	return true
	
#卸载
func remove_system(system_name:StringName) -> bool:
	var system:SWSystem = _by_name.get(system_name)
	if system == null:
		return false
	#如果正在执行tick
	if _iterating:
		if not _pending_remove.has(system_name):
			_pending_remove.append(system_name)
	else:
		_remove_now_condition(system_name)
	return true

#按名查询（只读，用于取系统引用）
func get_system(system_name:StringName) -> SWSystem:
	return _by_name.get(system_name)

func has_system(system_name:StringName) -> bool:
	return _by_name.has(system_name)
	
#子系统启停
func set_enable(system_name:StringName,enable:bool) -> bool:
	var system:SWSystem = _by_name.get(system_name)
	if system == null:
		return false
	if system.enable == enable:
		return true
	#系统控制权大于子系统，所以在这里直接设置，如果任由子系统随意启停会导致其他问题
	system.enable = enable
	system._on_enabled_changed(enable)
	return true

#清理
func clear() -> void:
	if _iterating:
		for name in _by_name.keys():
			if not _pending_remove.has(name):
				_pending_remove.append(name)
		return
	_pending_add.clear()
	for i in range(_systems.size()-1,-1,-1):
		_remove_now(_systems[i])
	_by_name.clear()
	_pending_add.clear()
	_pending_remove.clear()
	_order_map.clear()
	_seq_map.clear()
	_tick_index = 0
	_system_insert_order = 0
	_running = false
#region 主系统启停
#开始
func start() -> void:
	if _running:
		return
	_running = true
	_tick_index = 0

#停止
func stop() -> void:
	_running = false
	_tick_index = 0

#暂停
func pause() -> void:
	_running = false

#继续
func run() -> void:
	_running = true
#endregion

#endregion

#region 子系统卸载
func _remove_now(system:SWSystem) -> void:
	#如果已经添加到子系统列表中
	var _systems_index:int = _systems.find(system)
	if _systems_index >= 0:
		_systems.remove_at(_systems_index)
		_order_map.erase(system)
		_seq_map.erase(system)
		system._on_unregister(self)
	
func _remove_now_condition(system_name:String) -> void:
	var system:SWSystem = _by_name.get(system_name)
	if system == null:
		return
	_by_name.erase(system_name)
	#如果还在_pending_add中未添加，直接删
	var _pending_index:int = _pending_add.find(system)
	if _pending_index >= 0:
		_pending_add.remove_at(_pending_index)
		return
	_remove_now(system)
#endregion

#region 子系统装配
func _insert_system(system:SWSystem,index:int) -> void:
	_systems.insert(index,system)
	_order_map[system] = system.run_order
	_seq_map[system] = _system_insert_order
	system._on_register(self)
	_system_insert_order += 1
	
func _insert_system_condition(system:SWSystem) -> void:
	#内部按照order排序，order一样的，就按照insert先后顺序
	var system_order:int = system.run_order
	var system_seq:int = _system_insert_order
	var index = _systems.size()
	while index > 0:
		var prev_system = _systems[index-1]
		var prev_system_order = _order_map[prev_system]
		var prev_system_seq = _seq_map[prev_system]
		if prev_system_order < system_order or (prev_system_order == system_order and prev_system_seq < system_seq):
			break
		index -= 1
	_insert_system(system,index)
#endregion

#region tick or frame
func tick(_delta:float) -> void:
	if not _running or _iterating:
		return
	_iterating = true
	_tick_index += 1
	for sub_system in _systems:
		if not sub_system.enable:
			continue
		sub_system.tick(_delta,_tick_index)
	_apply_pending()
	_iterating = false
func frame(_delta:float) -> void:
	if not _running or _iterating:
		return
	_iterating = true
	_tick_index += 1
	for sub_system in _systems:
		if not sub_system.enable or not sub_system.receives_frame:
			continue
		sub_system.frame(_delta)
	_apply_pending()
	_iterating = false
#endregion
	
#region 内部
func _init(event_bus = null) -> void:
	bus = event_bus

func _apply_pending() -> void:
	#先卸载再加载
	for name in _pending_remove:
		_remove_now_condition(name)
	_pending_remove.clear()
	for system in _pending_add:
		#同名子系统只允许有一个
		if _by_name[system.system_name] == system:
			_insert_system_condition(system)
	_pending_add.clear()
#endregion

#region 调试
#调试
func describe() -> PackedStringArray:
	var out := PackedStringArray()
	for system in _systems:
		out.append("%s(order=%d,enabled=%s,frame=%s)" % [
			system.system_name, _order_map.get(system, 0), str(system.enable), str(system.receives_frame)
		])
	return out
#endregion
