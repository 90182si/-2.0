class_name SWSystem extends RefCounted

#系统唯一名称
var system_name:String = &""
#数值小的线执行
var run_order:int = 0
#启用/停用
var enable:bool = true
#是否需要逐帧回调 frame()（表现层系统置 true）
var receives_frame:bool = false

func _on_register(_manager) -> void:
	pass
	
func _on_unregister(_manager) -> void:
	pass
	
func _on_enabled_changed(_value:bool) -> void:
	pass
	
func tick(_delta:float,_tick_index:int) -> void:
	pass

func frame(_delta:float) -> void:
	pass
