class_name SWLayerSystem extends SWSystem

#A["SWLayerManager (Node, 装配根)"] --> B["SWBuildLayer (View)"]
#A --> C["SWHoldLayer (View)"]
#A --> D["SWHudLayer (View)"]
#B --> E["SWBuildLayerSystem (SWSystem)"]
#C --> F["SWHoldLayerSystem (SWSystem)"]
#D --> G["SWHudLayerSystem (SWSystem)"]
#E --> H["SWSystemManager (60Hz + 逐帧)"]
#F --> H
#G --> H

#被控组件
var view:SWLayer = null

#初始化管控的Layer,并在子类函数中进行特例化初始化
func attach_view(v:SWLayer) -> void:
	if v == view:
		return
	# 换绑时先解开旧 view，避免遗留脏的双向链接
	if view != null and view.layer_system == self:
		view.layer_system = null
	view = v
	if view != null and is_instance_valid(view):
		view.layer_system = self
		
func detach_view() -> void:
	if view != null and is_instance_valid(view) and view.layer_system == self:
		view.layer_system = null
	view = null

func frame(_delta:float) -> void:
	pass
	
#事件来源，外部调用
func handle_input(_event:InputEvent) -> bool:
	return false
	
func on_view_rect_changed(_view_rect:Rect2,_speed_vec:Vector2) -> void:
	pass

func _on_unregister(_manager) -> void:
	# Manager 注销时主动断开，防止被 Node 续命的僵尸 system 仍反向连着 view
	detach_view()
