class_name SWPerformanceMonitor extends CanvasLayer

@onready var stats_container: PanelContainer = $StatsContainer
@onready var fps_label: Label = $StatsContainer/StatsDisplay/FPSLabel
@onready var memory_label: Label = $StatsContainer/StatsDisplay/MemoryLabel
@onready var object_label: Label = $StatsContainer/StatsDisplay/ObjectLabel
@onready var draw_label: Label = $StatsContainer/StatsDisplay/DrawLabel
@onready var log_btn: Button = $StatsContainer/StatsDisplay/LogBtn
@onready var vsync_check: CheckButton = $StatsContainer/StatsDisplay/VsyncCheck
@onready var map_switch: CheckButton = $StatsContainer/StatsDisplay/MapSwitch
@onready var async_load_check: CheckButton = $StatsContainer/StatsDisplay/AsyncLoadCheck
@onready var hover_info_check: CheckButton = $StatsContainer/StatsDisplay/HoverInfoCheck
@onready var build_info_label: Label = $BuildInfoLabel
@onready var crash_log_viewer: Node = $CrashLogViewer
@onready var button: Button = $StatsContainer/StatsDisplay/Button

## 非 FPS 的统计刷新间隔（秒），降低每帧更新开销
const STATS_UPDATE_INTERVAL: float = 0.2
## 建筑悬停信息刷新间隔（秒）
const TOOLTIP_UPDATE_INTERVAL: float = 0.1

var _stats_timer: float = 0.0
var _expandMonitor: bool = true
var _map_layer: SWMapLayer = null
var _map_visible_default: bool = true
var _hold_layer: SWHoldLayer = null
var _build_layer: SWBuildLayer = null
var _tooltip_enabled: bool = true
var _tooltip_timer: float = 0.0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_map_layer = get_parent().get_node_or_null("SWLayerManager/SWMapLayer")
	_hold_layer = get_parent().get_node_or_null("SWLayerManager/SWHoldLayer")
	_build_layer = get_parent().get_node_or_null("SWLayerManager/SWBuildLayer")
	if vsync_check != null:
		vsync_check.toggled.connect(_on_vsync_toggled)
		vsync_check.button_pressed = _is_vsync_enabled()
	if map_switch != null:
		map_switch.toggled.connect(_on_map_switch_toggled)
		if _map_layer != null:
			map_switch.button_pressed = _map_visible_default
			_set_layer_visible_recursive(_map_layer, map_switch.button_pressed)
	if async_load_check != null:
		async_load_check.toggled.connect(_on_async_load_toggled)
		async_load_check.button_pressed = true  # 默认开启异步加载
	if hover_info_check != null:
		hover_info_check.toggled.connect(_on_hover_info_toggled)
	if log_btn != null and crash_log_viewer != null:
		log_btn.pressed.connect(_on_log_btn_pressed)
		crash_log_viewer.visibility_changed.connect(_on_crash_log_viewer_visibility_changed)
		
	_on_button_pressed()

func _process(delta: float) -> void:
	# FPS 与主循环每帧更新
	var fps: float = Performance.get_monitor(Performance.TIME_FPS)
	var process_ms: float = Performance.get_monitor(Performance.TIME_PROCESS) * 1000
	var physics_ms: float = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000

	fps_label.text = "FPS: %.1f  (Process: %.2f ms | Physics: %.2f ms)" % [fps, process_ms, physics_ms]
	_set_fps_label_color(fps_label, fps)

	# 内存 / 对象 / 渲染 按间隔更新，避免每帧读大量 Monitor
	_stats_timer += delta
	if _stats_timer >= STATS_UPDATE_INTERVAL:
		_stats_timer = 0.0
		_update_memory_label()
		_update_object_label()
		_update_draw_label()

	# 建筑悬停信息按间隔更新，避免每帧查询与重建文本
	if _tooltip_enabled:
		_tooltip_timer += delta
		if _tooltip_timer >= TOOLTIP_UPDATE_INTERVAL:
			_tooltip_timer = 0.0
			_update_build_tooltip()


func _set_fps_label_color(label_node: Label, fps: float) -> void:
	if fps >= 55.0:
		label_node.add_theme_color_override("font_color", Color(0.4, 1.0, 0.4))
	elif fps >= 30.0:
		label_node.add_theme_color_override("font_color", Color(1.0, 0.9, 0.3))
	else:
		label_node.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))


func _update_memory_label() -> void:
	var static_mem: float = Performance.get_monitor(Performance.MEMORY_STATIC)
	var msg_buf: float = Performance.get_monitor(Performance.MEMORY_MESSAGE_BUFFER_MAX)
	var video_mem: float = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)

	var parts: PackedStringArray = PackedStringArray()
	if static_mem > 0:
		parts.append("Static: %s" % _format_memory(static_mem))
	if msg_buf > 0:
		parts.append("MsgBuf: %s" % _format_memory(msg_buf))
	parts.append("Video: %s" % _format_memory(video_mem))

	memory_label.text = "Memory: " + ", ".join(parts) if parts.size() > 0 else "Memory: N/A"


func _update_object_label() -> void:
	var obj_count: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var node_count: int = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var orphan_count: int = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	var res_count: int = int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))

	object_label.text = "Objects: %d  Nodes: %d  Resources: %d  Orphans: %d" % [obj_count, node_count, res_count, orphan_count]


func _update_draw_label() -> void:
	var draw_calls: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var objects_in_frame: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	var primitives: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))

	draw_label.text = "Draw: %d calls  Objects: %d  Primitives: %s" % [draw_calls, objects_in_frame, _format_integer(primitives)]


func _format_memory(bytes: float) -> String:
	if bytes <= 0:
		return "0 B"
	if bytes < 1024:
		return "%d B" % int(bytes)
	if bytes < 1024 * 1024:
		return "%.2f KB" % (bytes / 1024.0)
	if bytes < 1024.0 * 1024.0 * 1024.0:
		return "%.2f MB" % (bytes / (1024.0 * 1024.0))
	return "%.2f GB" % (bytes / (1024.0 * 1024.0 * 1024.0))


func _format_integer(value: int) -> String:
	if value < 1000:
		return str(value)
	if value < 1_000_000:
		return "%.2fK" % (value / 1000.0)
	return "%.2fM" % (value / 1_000_000.0)


func _on_log_btn_pressed() -> void:
	if crash_log_viewer != null:
		if stats_container != null:
			stats_container.visible = false
		crash_log_viewer.show_and_refresh()


func _on_crash_log_viewer_visibility_changed() -> void:
	if crash_log_viewer != null and not crash_log_viewer.visible and stats_container != null:
		stats_container.visible = true


func _get_window_id() -> int:
	return get_viewport().get_window_id()


func _is_vsync_enabled() -> bool:
	var mode := DisplayServer.window_get_vsync_mode(_get_window_id())
	return mode == DisplayServer.VSYNC_ENABLED or mode == DisplayServer.VSYNC_ADAPTIVE


func _on_vsync_toggled(toggled_on: bool) -> void:
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if toggled_on else DisplayServer.VSYNC_DISABLED,
		_get_window_id()
	)


func _on_map_switch_toggled(toggled_on: bool) -> void:
	#if _map_layer != null:
		#_set_layer_visible_recursive(_map_layer, toggled_on)
	var draw_managers = get_tree().get_nodes_in_group("DrawManager")
	for dm in draw_managers:
		if dm.get_name() == "mapDrawManager":
			var dmr = dm as SWDrawManager
			dmr.set_visible(toggled_on)

func _on_async_load_toggled(toggled_on: bool) -> void:
	# 通知所有 DrawManager 切换异步加载模式
	var draw_managers = get_tree().get_nodes_in_group("DrawManager")
	for dm in draw_managers:
		if dm.has_method("set_async_loading"):
			dm.set_async_loading(toggled_on)


func _on_hover_info_toggled(toggled_on: bool) -> void:
	_tooltip_enabled = toggled_on
	if not toggled_on and build_info_label != null:
		build_info_label.visible = false


## 手持为空且鼠标悬停在建筑物上时，显示建筑物基本信息
func _update_build_tooltip() -> void:
	if build_info_label == null:
		return
	var viewport := get_viewport()
	var mouse_view_pos := viewport.get_mouse_position()
	var show := false
	# 鼠标在统计面板上、正在按住鼠标操作、或手持物品不为空时不显示
	if stats_container != null and stats_container.visible \
			and stats_container.get_global_rect().has_point(mouse_view_pos):
		show = false
	elif Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) \
			or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		show = false
	elif _hold_layer == null or not _hold_layer.isHoldEmpty():
		show = false
	elif _build_layer == null or _build_layer.sw_build_manager == null:
		show = false
	else:
		var world_pos = SWCommon.GetGlobalPosByViewPos(mouse_view_pos, viewport)
		var grid_pos:Vector2i = SWCommon.GetGridPos(Vector2i(world_pos))
		var build:SWBuildItemDefine = _build_layer.sw_build_manager.getBuild(grid_pos)
		if build != null:
			build_info_label.text = _format_build_info(build)
			build_info_label.position = _clamp_tooltip_pos(mouse_view_pos)
			show = true
	build_info_label.visible = show


func _format_build_info(build: SWBuildItemDefine) -> String:
	var lines:PackedStringArray = []
	if build.buildDefine:
		lines.append("名称: %s" % build.buildDefine.buildName)
	lines.append("ID: %d" % build.id)
	lines.append("位置: (%d, %d)" % [build.buildAxisPos.x, build.buildAxisPos.y])
	lines.append("朝向: %s" % _dir_to_text(build.rotation))
	lines.append("类型: %s" % _comp_type_to_text(build.comp_type))
	lines.append("信号: %s" % _signal_to_text(build.signal_state))
	lines.append("电路: %s" % _circuit_to_text(build.circuit))
	if build.comp_type == SWDefine.CircuitComponentType.WIRE:
		var wireBuild:SWBuildWire = build as SWBuildWire
		lines.append("WireGroup: %s" % _wire_group_to_text(wireBuild.net.wireGroup))
	if build.circuit_on:
		lines.append("电路: 通电")
	return "\n".join(lines)


func _dir_to_text(dir: int) -> String:
	match dir:
		SWDefine.SW_Dir.UP: return "上"
		SWDefine.SW_Dir.RIGHT: return "右"
		SWDefine.SW_Dir.DOWN: return "下"
		SWDefine.SW_Dir.LEFT: return "左"
	return "未知"


func _comp_type_to_text(comp_type: int) -> String:
	match comp_type:
		SWDefine.CircuitComponentType.BUTTON: return "按钮"
		SWDefine.CircuitComponentType.SWITCH: return "开关"
		SWDefine.CircuitComponentType.LED: return "灯泡"
		SWDefine.CircuitComponentType.WIRE: return "电线"
		SWDefine.CircuitComponentType.WIRE_STRAIGHT: return "直线电线"
		SWDefine.CircuitComponentType.WIRE_BENT: return "弯头电线"
		SWDefine.CircuitComponentType.WIRE_BRIDGE: return "桥梁电线"
		SWDefine.CircuitComponentType.NOT_GATE: return "非门"
		SWDefine.CircuitComponentType.WIRE_TUNNEL: return "隧道电线"
	return "无"


func _signal_to_text(signal_value: int) -> String:
	match signal_value:
		SWDefine.CircuitSignal.LOW: return "输入低电平"
		SWDefine.CircuitSignal.HIGH: return "输入高电平"
	return "输入无信号"

func _circuit_to_text(circuit: SWDefine.SWCircuitData) -> String:
	if circuit:
		return str(circuit.circuitID)
	return "无电路"

func _wire_group_to_text(wiregroup:SWDefine.SWWireGroup) -> String:
	if wiregroup:
		return str(wiregroup.wireHeaderID)
	return "无WireGroup"

## 提示框跟随鼠标，超出视口边缘时翻转到另一侧
func _clamp_tooltip_pos(mouse_pos: Vector2) -> Vector2:
	var offset := Vector2(16, 16)
	var pos := mouse_pos + offset
	var vp_size := get_viewport().get_visible_rect().size
	var label_size := build_info_label.get_combined_minimum_size()
	if pos.x + label_size.x > vp_size.x:
		pos.x = mouse_pos.x - label_size.x - 8
	if pos.y + label_size.y > vp_size.y:
		pos.y = mouse_pos.y - label_size.y - 8
	return pos


func _set_layer_visible_recursive(node: Node, is_visible: bool) -> void:
	if node is ColorRect:
		return
	if node is CanvasItem:
		(node as CanvasItem).visible = is_visible
	for child in node.get_children():
		if child is Node:
			_set_layer_visible_recursive(child, is_visible)


func expandMonitor(expand: bool) -> void:
	fps_label.visible = expand
	memory_label.visible = expand
	object_label.visible = expand
	draw_label.visible = expand
	log_btn.visible = expand
	if vsync_check != null:
		vsync_check.visible = expand
	if map_switch != null:
		map_switch.visible = expand
	if async_load_check != null:
		async_load_check.visible = expand
	if hover_info_check != null:
		hover_info_check.visible = expand
	if not expand and build_info_label != null:
		build_info_label.visible = false
	if stats_container != null:
		stats_container.custom_minimum_size = Vector2.ZERO
		if expand:
			call_deferred("_apply_expanded_size")
		else:
			call_deferred("_apply_collapsed_size")
	if button != null:
		button.text = "→" if not expand else "←"


func _apply_collapsed_size() -> void:
	if stats_container == null or button == null or _expandMonitor:
		return
	var pad := Vector2(0, 0)
	stats_container.size = button.get_combined_minimum_size() + pad


func _apply_expanded_size() -> void:
	if stats_container == null or not _expandMonitor:
		return
	stats_container.size = stats_container.get_combined_minimum_size()


func _on_button_pressed() -> void:
	_expandMonitor = not _expandMonitor
	expandMonitor(_expandMonitor)
