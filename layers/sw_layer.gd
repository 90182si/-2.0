@abstract
class_name SWLayer extends Node

var layer_system:SWLayerSystem = null

func _ready() -> void:
	pass

func _enter_tree() -> void:
	add_to_group("SWLayer")
	
func _exit_tree() -> void:
	if layer_system != null:
		layer_system.detach_view()
		layer_system = null
		
## 子类返回自己的系统；纯渲染 layer（如 Map）返回 null 即可
func create_layer_system() -> SWLayerSystem:
	return null
	
func _unhandled_input(event: InputEvent) -> void:
	if layer_system == null or (layer_system != null and layer_system.enable == false):
		return
	var handled := layer_system.handle_input(event)
	if handled:
		get_viewport().set_input_as_handled()

func on_view_rect_changed(view_rect: Rect2, speed_vec: Vector2) -> void:
	if layer_system != null:
		layer_system.on_view_rect_changed(view_rect, speed_vec)
