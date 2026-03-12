class_name SWPerformanceMonitor extends CanvasLayer

@onready var stats_container: PanelContainer = $StatsContainer
@onready var fps_label: Label = $StatsContainer/StatsDisplay/FPSLabel
@onready var memory_label: Label = $StatsContainer/StatsDisplay/MemoryLabel
@onready var object_label: Label = $StatsContainer/StatsDisplay/ObjectLabel
@onready var draw_label: Label = $StatsContainer/StatsDisplay/DrawLabel
@onready var log_btn: Button = $StatsContainer/StatsDisplay/LogBtn
@onready var vsync_check: CheckButton = $StatsContainer/StatsDisplay/VsyncCheck
@onready var crash_log_viewer: Node = $CrashLogViewer
@onready var button: Button = $StatsContainer/StatsDisplay/Button

## 非 FPS 的统计刷新间隔（秒），降低每帧更新开销
const STATS_UPDATE_INTERVAL: float = 0.2

var _stats_timer: float = 0.0
var _expandMonitor: bool = true

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if vsync_check != null:
		vsync_check.toggled.connect(_on_vsync_toggled)
		vsync_check.button_pressed = _is_vsync_enabled()
	if log_btn != null and crash_log_viewer != null:
		log_btn.pressed.connect(_on_log_btn_pressed)
		crash_log_viewer.visibility_changed.connect(_on_crash_log_viewer_visibility_changed)

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


func expandMonitor(expand: bool) -> void:
	fps_label.visible = expand
	memory_label.visible = expand
	object_label.visible = expand
	draw_label.visible = expand
	log_btn.visible = expand
	if vsync_check != null:
		vsync_check.visible = expand
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
