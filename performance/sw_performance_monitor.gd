class_name SWPerformanceMonitor extends CanvasLayer

@onready var stats_container: PanelContainer = $StatsContainer
@onready var fps_label: Label = $StatsContainer/StatsDisplay/FPSLabel
@onready var memory_label: Label = $StatsContainer/StatsDisplay/MemoryLabel
@onready var object_label: Label = $StatsContainer/StatsDisplay/ObjectLabel
@onready var draw_label: Label = $StatsContainer/StatsDisplay/DrawLabel
@onready var build_count_label: Label = $StatsContainer/StatsDisplay/BuildCountLabel
@onready var chunk_count_label: Label = $StatsContainer/StatsDisplay/ChunkCountLabel
@onready var redraw_chunk_label: Label = $StatsContainer/StatsDisplay/RedrawChunkLabel
@onready var log_btn: Button = $StatsContainer/StatsDisplay/LogBtn
@onready var vsync_check: CheckButton = $StatsContainer/StatsDisplay/VsyncCheck
@onready var map_switch: CheckButton = $StatsContainer/StatsDisplay/MapSwitch
@onready var async_load_check: CheckButton = $StatsContainer/StatsDisplay/AsyncLoadCheck
@onready var hover_info_check: CheckButton = $StatsContainer/StatsDisplay/HoverInfoCheck
@onready var build_info_label: Label = $HBoxContainer/BuildInfoLabel
@onready var build_info_label_box: HBoxContainer = $HBoxContainer
@onready var crash_log_viewer: Node = $CrashLogViewer
@onready var button: Button = $StatsContainer/StatsDisplay/Button

## 非 FPS 的统计刷新间隔（秒），降低每帧更新开销
const STATS_UPDATE_INTERVAL: float = 0.2
## 建筑悬停信息刷新间隔（秒）
const TOOLTIP_UPDATE_INTERVAL: float = 0.1
## 物理帧率实测窗口（微秒）。物理步进与渲染帧率无关，Performance 没有对应监控项，
## 只能对 Engine.get_physics_frames() 做差分；用挂钟而不是累加 delta，避免 time_scale / 暂停影响统计
const PHYS_FPS_WINDOW_USEC: int = 500_000

var _stats_timer: float = 0.0
## 实测物理帧率（帧/秒），-1 表示首个统计窗口还没结束
var _physics_fps: float = -1.0
var _phys_fps_last_usec: int = 0
var _phys_fps_last_frames: int = 0
var _expandMonitor: bool = true
var _map_layer: SWMapLayer = null
var _map_visible_default: bool = true
var _hold_layer: SWHoldLayer = null
var _build_layer: SWBuildLayer = null
var _tooltip_enabled: bool = true
var _tooltip_timer: float = 0.0
# 回填策略开关「电线/非门跟随电平」（对应 SWCircuitControl.backfill_net_signal / backfill_gate_display）：
# 关掉后电线颜色与非门贴图冻结在最后一次写入值，省掉每拍 net 回填与门 dirty 扫描；
# LED / 寄存器 / 开关的显示始终正确刷新。
var _follow_check: CheckButton = null
# 电路时钟开关「电路时钟 tick」（对应 SWBuildLayerSystem.tick_enabled）：
# 关掉后每拍时钟推进整条链不执行，用来分离「电路 tick 吃帧」与「渲染吃帧」。
var _tick_check: CheckButton = null
# 面板可能比 SWLayerManager 先 ready（此时 buildSystem 还是 null）：
# 勾选意图先存着，等系统就绪后在 _process 里落地。-1 = 没有待落地意图
var _tick_pending: int = -1
# LOD 级别一行：图集精度档（SwAtlas）/ 内容简化档（区块烘培）/ 相机缩放档（触发源）
var _lod_label: Label = null

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
	_build_follow_check()
	_build_tick_check()
	_build_lod_label()
	if log_btn != null and crash_log_viewer != null:
		log_btn.pressed.connect(_on_log_btn_pressed)
		crash_log_viewer.visibility_changed.connect(_on_crash_log_viewer_visibility_changed)
		
	_on_button_pressed()

func _process(delta: float) -> void:
	# FPS 与主循环每帧更新
	var fps: float = Performance.get_monitor(Performance.TIME_FPS)
	var process_ms: float = Performance.get_monitor(Performance.TIME_PROCESS) * 1000
	var physics_ms: float = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000
	_update_physics_fps()

	#物理帧率单独统计：掉帧时一渲染帧会补跑多个物理步、高帧率时一渲染帧可能一步都不跑，
	#渲染 FPS 看不出物理是否落后。显示成「实测/设定」，方便区分设定值与掉速
	var phys_fps_text: String = "--" if _physics_fps < 0.0 else "%.1f" % _physics_fps
	fps_label.text = "FPS: %.1f  PhysFPS: %s/%d  (Process: %.2f ms | Physics: %.2f ms)" % [
		fps, phys_fps_text, Engine.physics_ticks_per_second, process_ms, physics_ms]
	_set_fps_label_color(fps_label, fps)

	# 内存 / 对象 / 渲染 按间隔更新，避免每帧读大量 Monitor
	_stats_timer += delta
	if _stats_timer >= STATS_UPDATE_INTERVAL:
		_stats_timer = 0.0
		_update_memory_label()
		_update_object_label()
		_update_draw_label()
		_update_build_count_label()
		_update_chunk_count_label()
		_update_redraw_chunk_label()
		_update_lod_label()

	# 建筑悬停信息按间隔更新，避免每帧查询与重建文本
	if _tooltip_enabled:
		_tooltip_timer += delta
		if _tooltip_timer >= TOOLTIP_UPDATE_INTERVAL:
			_tooltip_timer = 0.0
			_update_build_tooltip()

	# 时钟开关的待落地意图：SWLayerManager 建好 buildSystem 后补上
	if _tick_pending >= 0:
		var sys := _get_build_system()
		if sys != null:
			sys.tick_enabled = _tick_pending == 1
			_tick_pending = -1


## 窗口到期才结算一次，读数滞后约 0.5s，换来不抖动的稳定值
func _update_physics_fps() -> void:
	var now_usec: int = Time.get_ticks_usec()
	var frames: int = Engine.get_physics_frames()
	if _phys_fps_last_usec == 0:
		_phys_fps_last_usec = now_usec
		_phys_fps_last_frames = frames
		return
	var span_usec: int = now_usec - _phys_fps_last_usec
	if span_usec < PHYS_FPS_WINDOW_USEC:
		return
	_physics_fps = float(frames - _phys_fps_last_frames) * 1_000_000.0 / float(span_usec)
	_phys_fps_last_usec = now_usec
	_phys_fps_last_frames = frames


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


func _update_build_count_label() -> void:
	if build_count_label == null:
		return
	var build_count: int = 0
	if _build_layer != null and _build_layer.sw_build_manager != null:
		build_count = _build_layer.sw_build_manager.getBuildCount()
	build_count_label.text = "建筑物: %s" % _format_integer(build_count)


func _update_chunk_count_label() -> void:
	if chunk_count_label == null:
		return
	var total: int = 0
	for dm in get_tree().get_nodes_in_group("DrawManager"):
		if dm.has_method("get_visible_chunk_count"):
			total += dm.get_visible_chunk_count()
	chunk_count_label.text = "显示区块: %s" % _format_integer(total)


func _update_redraw_chunk_label() -> void:
	if redraw_chunk_label == null:
		return
	var total: int = 0
	for dm in get_tree().get_nodes_in_group("DrawManager"):
		if dm.has_method("get_redraw_chunks_per_frame"):
			total += dm.get_redraw_chunks_per_frame()
	redraw_chunk_label.text = "每帧重绘区块: %s" % _format_integer(total)


## LOD 三档放一行：缩放档是触发源，图集/内容档是它跨过阈值后的结果
func _update_lod_label() -> void:
	if _lod_label == null:
		return
	var content: int = 0
	if _build_layer != null and _build_layer.sw_draw_manager != null:
		content = _build_layer.sw_draw_manager.content_lod
	var scale_text: String = "--"
	var cam := get_viewport().get_camera_2d() as SWCamera2D
	if cam != null:
		scale_text = str(cam.view_scale_level)
	_lod_label.text = "LOD: 图集 %d  内容 %d  缩放档 %s" % [SwAtlas.lod_level, content, scale_text]


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
	return str(value)
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


## 建筑层系统：时钟开关与电路控制都经它取。
## 延迟到每次要用时再取：面板 _ready 可能早于 LayerManager 建服务
func _get_build_system() -> SWBuildLayerSystem:
	# SWLayerManager 在 _ready 里建系统并缓存，优先用它（面板可能比它先 ready）
	var lm := get_parent().get_node_or_null("SWLayerManager") as SWLayerManager
	if lm != null and lm.buildSystem != null:
		return lm.buildSystem
	if _build_layer == null:
		_build_layer = get_parent().get_node_or_null("SWLayerManager/SWBuildLayer")
	if _build_layer == null or _build_layer.layer_system == null:
		return null
	return _build_layer.layer_system as SWBuildLayerSystem

func _get_circuit_control() -> SWCircuitControl:
	var sys := _get_build_system()
	return null if sys == null else sys.circuit_control


## 面板上的「电线/非门跟随电平」：同时管 net 电平回填与非门贴图刷新
func _build_follow_check() -> void:
	var box := get_node_or_null("StatsContainer/StatsDisplay")
	if box == null:
		return
	_follow_check = CheckButton.new()
	_follow_check.text = "电线/非门跟随电平"
	_follow_check.tooltip_text = "关掉可省每拍回填（连线颜色与非门档位会冻结）；LED/寄存器/开关始终正确"
	_follow_check.mouse_filter = Control.MOUSE_FILTER_PASS
	var cc: SWCircuitControl = _get_circuit_control()
	_follow_check.set_pressed_no_signal(true if cc == null else cc.backfill_net_signal)
	if cc != null:
		# 面板初值也要与求值策略对齐（跟随 = 未简化，不跟随 = 简化），
		# 否则默认值一变就会出现「按钮看着没开，却在用不简化式子算」
		cc.set_use_simplified_eval(not cc.backfill_net_signal)
	_follow_check.toggled.connect(_on_follow_toggled)
	box.add_child(_follow_check)


func _on_follow_toggled(toggled_on: bool) -> void:
	var cc: SWCircuitControl = _get_circuit_control()
	if cc == null:
		return
	cc.backfill_net_signal = toggled_on
	cc.backfill_gate_display = toggled_on
	# 关掉跟随 = 压测档：玩家看不见每级门在动，求值改走化简表达式（双非门抵消等）。
	# 打开时恢复未简化表达式，每一级门都真算一遍。
	cc.set_use_simplified_eval(not toggled_on)
	if toggled_on:
		#重新打开：清后端缓存，下一拍走首轮全刷，把冻结住的连线颜色与非门档位补齐
		cc.clear_cpu_backends()


## 面板上的「电路时钟 tick」：直接开关 SWBuildLayerSystem.tick 是否执行。
## 关掉后整条链（时钟翻转 → 求值 → 回填 → 刷显示）都停在原地，
## 只剩下渲染开销，用来分辨「电路 tick 吃帧」还是「渲染吃帧」。
func _build_tick_check() -> void:
	var box := get_node_or_null("StatsContainer/StatsDisplay")
	if box == null:
		return
	_tick_check = CheckButton.new()
	_tick_check.text = "电路时钟 tick"
	_tick_check.tooltip_text = "关掉后每拍时钟推进整条链不执行（时钟不翻、寄存器不锁、不求值、不刷显示）"
	_tick_check.mouse_filter = Control.MOUSE_FILTER_PASS
	var sys := _get_build_system()
	_tick_check.set_pressed_no_signal(true if sys == null else sys.tick_enabled)
	_tick_check.toggled.connect(_on_tick_toggled)
	box.add_child(_tick_check)

func _on_tick_toggled(toggled_on: bool) -> void:
	var sys := _get_build_system()
	if sys == null:
		# 系统还没建好：先记下意图，等 _process 里能拿到系统再落地
		_tick_pending = 1 if toggled_on else 0
		return
	sys.tick_enabled = toggled_on
	_tick_pending = -1


## 面板上的 LOD 一行：图集档 / 内容档 / 相机缩放档
func _build_lod_label() -> void:
	var box := get_node_or_null("StatsContainer/StatsDisplay")
	if box == null:
		return
	_lod_label = Label.new()
	_lod_label.mouse_filter = Control.MOUSE_FILTER_PASS
	_lod_label.text = "LOD: -"
	box.add_child(_lod_label)
	#放到 FPS 之后：LOD 是统计读数，不该跟下面一排开关混在一起
	if fps_label != null:
		box.move_child(_lod_label, fps_label.get_index() + 1)


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
		var world_pos = SwCommon.GetGlobalPosByViewPos(mouse_view_pos, viewport)
		var grid_pos:Vector2i = SwCommon.GetGridPos(Vector2i(world_pos))
		var build:SWBuildItemDefine = _build_layer.sw_build_manager.getBuild(grid_pos)
		if build != null:
			build_info_label.text = _format_build_info(build)
			build_info_label_box.position = _clamp_tooltip_pos(mouse_view_pos)
			show = true
	build_info_label.visible = show


func _format_build_info(build: SWBuildItemDefine) -> String:
	var lines:PackedStringArray = []
	if build.buildDefine:
		lines.append("名称: %s" % build.buildDefine.buildName)
	lines.append("ID: %d" % build.id)
	lines.append("位置: (%d, %d)" % [build.buildAxisPos.x, build.buildAxisPos.y])
	lines.append("朝向: %s" % _dir_to_text(build.rotation))
	lines.append("类型: %s" % _comp_type_to_text(build.buildDefine.circuit_component_type))
	lines.append("信号: %s" % _signal_to_text(build.signal_state))
	#灯泡：悬空引脚与「接在低电平线上」在 signal_state 上是同一个 LOW，光看「信号」
	#分不出是没接上还是真接到了低电平，这里补一行引脚摘要（悬空方向 + 驱动数）
	if build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.LED:
		lines.append(_format_pin_summary(build))
	lines.append("电路: %s" % _circuit_to_text(build.circuit))
	#分阶段重建/孤立电线时 net 可能还没建出来，取组名要先判空
	if build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.WIRE:
		var wireBuild:SWBuildWire = build as SWBuildWire
		var wireNet:SWNet = wireBuild.getCircuitCompoent().net
		lines.append("WireGroup: %s" % _wire_group_to_text(wireNet.wireGroup if wireNet != null else null))
	elif build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.WIRE_BRIDGE:
		var wireBuild:SWBuildWireCross = build as SWBuildWireCross
		var vNet:SWNet = wireBuild.getCircuitCompoent().v_net
		var hNet:SWNet = wireBuild.getCircuitCompoent().h_net
		lines.append("VerticalWireGroup: %s" % _wire_group_to_text(vNet.wireGroup if vNet != null else null))
		lines.append("HorizontalWireGroup: %s" % _wire_group_to_text(hNet.wireGroup if hNet != null else null))
	if build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.WIRE_TUNNEL:
		var tunnelBuild:SWBuildWireTunnel = build as SWBuildWireTunnel
		lines.append("Tunnel PairId: %d" % tunnelBuild.pairId)
	if build.circuit_on:
		lines.append("电路: 通电")
	return "\n".join(lines)


## 负载（灯泡）引脚摘要：悬空引脚不会产生 net，回填时按 0 处理，
## 所以 tooltip 的「信号」对「悬空」和「接到低电平」都显示低电平；
## 这里把「已连接几个方向 / 高低分布 / 驱动数 / 哪些方向悬空」摊开，接线断点一眼可见。
func _format_pin_summary(build: SWBuildItemDefine) -> String:
	var comp := build.getCircuitCompoent() as SWBuildCompoentCircuit
	if comp == null:
		return "引脚: 组件未创建"
	var linked: int = 0
	var high: int = 0
	var low: int = 0
	var drivers: int = 0
	var empty_dirs: PackedStringArray = PackedStringArray()
	for d in 4:
		var net: SWNet = comp.pinNetMap.get(d, null)
		if net == null:
			empty_dirs.append(_dir_to_text(d))
			continue
		linked += 1
		drivers += net.getDrivers().size()
		if net.curSignal == SwDefine.CircuitSignal.HIGH:
			high += 1
		else:
			low += 1
	var text := "引脚: 已连接 %d/4  高 %d / 低 %d  驱动 %d" % [linked, high, low, drivers]
	if not empty_dirs.is_empty():
		text += "  悬空(未接): %s" % ",".join(empty_dirs)
	return text


func _dir_to_text(dir: int) -> String:
	match dir:
		SwDefine.SW_Dir.UP: return "上"
		SwDefine.SW_Dir.RIGHT: return "右"
		SwDefine.SW_Dir.DOWN: return "下"
		SwDefine.SW_Dir.LEFT: return "左"
	return "未知"


func _comp_type_to_text(comp_type: int) -> String:
	match comp_type:
		SwDefine.CircuitComponentType.BUTTON: return "按钮"
		SwDefine.CircuitComponentType.SWITCH: return "开关"
		SwDefine.CircuitComponentType.LED: return "灯泡"
		SwDefine.CircuitComponentType.WIRE: return "电线"
		SwDefine.CircuitComponentType.WIRE_STRAIGHT: return "直线电线"
		SwDefine.CircuitComponentType.WIRE_BENT: return "弯头电线"
		SwDefine.CircuitComponentType.WIRE_BRIDGE: return "桥梁电线"
		SwDefine.CircuitComponentType.NOT_GATE: return "非门"
		SwDefine.CircuitComponentType.WIRE_TUNNEL: return "隧道电线"
		SwDefine.CircuitComponentType.CLOCK: return "时钟"
		SwDefine.CircuitComponentType.ONE_BIT_REGISTER: return "1bit寄存器"
		SwDefine.CircuitComponentType.AND_GATE: return "与门"
	return "无"


func _signal_to_text(signal_value: int) -> String:
	match signal_value:
		SwDefine.CircuitSignal.LOW: return "输入低电平"
		SwDefine.CircuitSignal.HIGH: return "输入高电平"
	return "输入无信号"

func _circuit_to_text(circuit: SwDefine.SWCircuitData) -> String:
	if circuit:
		return str(circuit.circuitID)
	return "无电路"

func _wire_group_to_text(wiregroup:SwDefine.SWWireGroup) -> String:
	if wiregroup:
		return str(wiregroup.wireGroupID)
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
	if build_count_label != null:
		build_count_label.visible = expand
	if chunk_count_label != null:
		chunk_count_label.visible = expand
	if redraw_chunk_label != null:
		redraw_chunk_label.visible = expand
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
