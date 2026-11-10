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

#region 动画层转发钩子
# 实体系统一拍要问几千次「这一台移动能不能做个滑块」，早期用 has_method + call
# 逐台探测，一万台光反射查方法表就是 5ms/拍。钩子放基类、由 SWEntityLayer 覆盖，
# 调用方就能静态派发（走 vtable），一次探测都不需要。
# 没动画的层用这里的空实现，返回 false = 不接，调用方走自己的原地口径。
func start_visual_move(_e, _from_pos: Vector2i, _to_pos: Vector2i) -> bool:
	return false

func start_visual_rotate(_e, _from_dir: int, _to_dir: int) -> bool:
	return false

func advance_visual(_delta: float) -> void:
	pass

func release_visual(_e) -> void:
	pass

func set_visual_glow(_e, _on: bool) -> void:
	pass

func cancel_visual() -> void:
	pass

#把本拍攒下的动画登记一次提交（滑动批次 / 可见实例数）。
#节拍末尾调一次：逐台起滑在一万台规模下要 30ms/拍，攒成一批后只剩一次提交
func flush_visual() -> void:
	pass

#框选矩形（世界坐标）。active = false 表示收起
#这层是 Node，画不了东西：真正落笔在动画层（SWEntityVisual._draw）
func set_box_rect(_rect: Rect2, _active: bool, _subtract: bool = false) -> void:
	pass

#一批实体的实例底色重刷：底色烘在模板 tint 里，框选/多选改完得逐台重铺
func refresh_visual_tints(_ents: Array) -> void:
	pass
#endregion

func _unhandled_input(event: InputEvent) -> void:
	if layer_system == null or (layer_system != null and layer_system.enable == false):
		return
	var handled := layer_system.handle_input(event)
	if handled:
		get_viewport().set_input_as_handled()

func on_view_rect_changed(view_rect: Rect2, speed_vec: Vector2) -> void:
	if is_instance_valid(layer_system):
		layer_system.on_view_rect_changed(view_rect, speed_vec)
