class_name SWRobotScene extends Node

# ==========================================================================
# 机器人场景（默认主场景）
#
# 与 SWLogicScene 的关系：地板/相机/层装配完全一样，区别只有两点
#   1. 没有 SWBuildLayer（不放电路元件），换成一个 SWEntityLayer 画机器人
#   2. 多一个 SWRobotTick：按 250ms 一拍驱动所有机器人跑各自绑定的 .swcir 电路
#
# 电路场景（sw_logic_scene.tscn）通过机器人 HUD 的「电路场景」按钮进入，
# 那边 HUD 上有回机器人场景的按钮；两场景互斥，纹理单例在 _init 里各建一次。
# ==========================================================================

@onready var sw_camera_2d: SWCamera2D = $SWCamera2D
@onready var sw_layer_manager: SWLayerManager = $SWLayerManager
#节拍器按 Node 持有：新脚本的类名不在 headless 全局类缓存里，不能当类型标注用
@onready var sw_robot_tick: Node = $SWRobotTick

var system_manager: SWSystemManager = null
var camera_system: SWCameraSystem = null
var render_system: SWRenderSystem = null

#实体层系统（由 SWLayerManager 按图层名取出；线接在 _ready 里）
var entity_system = null

func _init() -> void:
	#渲染纹理单例必须先于任何烘焙/补丁创建（与 SWLogicScene 同口径）
	SWStyleTexture.instance = SWStyleTexture.new()
	SWSignalTexture.instance = SWSignalTexture.create_backend()
	SWSignalTexture.instance.init()
	var refresh_cb := _refresh_texture_uniforms
	SWStyleTexture._refresh_cb = refresh_cb
	SWSignalTexture._palette_refresh_cb = refresh_cb
	SWObjectPool.InitSWChunkDataObject()
	system_manager = SWSystemManager.new()
	camera_system = SWCameraSystem.new()
	render_system = SWRenderSystem.new()

#纹理扩容/调色板重建后刷新全部共享材质 uniform（遍历 MESH_GROUP）
func _refresh_texture_uniforms() -> void:
	if is_inside_tree():
		get_tree().call_group(SwAtlas.MESH_GROUP, "_resetShaderUniforms")

func _ready() -> void:
	camera_system.enable = true
	camera_system.attach_camera(sw_camera_2d)
	system_manager.add_system(camera_system)
	for layer in sw_layer_manager.layers:
		sw_camera_2d.addLayerNotify(layer)
	system_manager.start()
	#SWLayerManager._ready 先把系统装好，这里才能取到实体层系统并连线
	_wire_entity_layer()
	#去电路场景改完电路回来时，机器人得还在原地（切出时存在 _robot_scene.json）
	_restore_scene_state()
	#延后一帧再初始化视野，避免窗口尺寸/相机尚未稳定导致首帧加载不完整
	call_deferred("_init_camera_view")

func _wire_entity_layer() -> void:
	entity_system = sw_layer_manager.get_layer_system("SWEntityLayer")
	if entity_system == null:
		push_warning("[RobotScene] 没找到实体层系统：机器人放置与节拍不可用")
		return
	var hold_system: SWHoldLayerSystem = sw_layer_manager.holdSystem
	if hold_system != null:
		#手持层落到空地/连续拖刷 -> 实体系统；右键抹格 -> 删实体
		hold_system.hold_idle_builds.connect(
			Callable(entity_system, "on_hold_idle_builds"))
		hold_system.hold_remove_builds.connect(
			Callable(entity_system, "on_hold_remove_builds"))
	if sw_robot_tick != null:
		sw_robot_tick.call("bind_entity_system", entity_system)
	_wire_bind_panel()
	_wire_timing_panel()

#单击机器人 -> HUD 电路绑定面板；面板选中文件 -> 回来绑到这台机器人。
#HUD 不直接持有实体系统，两边靠信号对接（与 selTool/save_requested 同一套做法）
func _wire_bind_panel() -> void:
	var hud: SWLayer = sw_layer_manager.hudLayer
	if hud == null or not hud.has_method("show_bind_panel"):
		return
	entity_system.entity_selected.connect(Callable(hud, "show_bind_panel"))
	entity_system.selection_cleared.connect(Callable(hud, "hide_bind_panel"))
	#用字符串 connect：hud 的静态类型是 SWLayer，子类自定义信号在静态检查下看不到
	hud.connect("circuit_bind_requested",
			Callable(self, "_on_circuit_bind_requested").bind(entity_system))

func _on_circuit_bind_requested(entity, file_name: String, target_system) -> void:
	if target_system == null:
		return
	target_system.bind_circuit(entity, file_name)

#时序图看哪台：实体系统自己挑（优先选中的，其次第一台绑了电路的）。
#HUD 不持有实体系统，只拿一个取实体的 Callable（与绑定面板同一套信号隔离做法）
func _wire_timing_panel() -> void:
	var hud: SWLayer = sw_layer_manager.hudLayer
	if hud == null or not hud.has_method("set_timing_provider"):
		return
	hud.call("set_timing_provider", Callable(entity_system, "get_timing_entity"))
	#时序面板上的运行/暂停/步进：同样只给一个取节拍器的 Callable，HUD 不持有它
	if hud.has_method("set_tick_provider"):
		hud.call("set_tick_provider", Callable(self, "_get_robot_tick"))

func _get_robot_tick() -> Node:
	return sw_robot_tick

#region 场景状态（切出记录 / 返回重载）
#摆位、朝向、绑的电路都存在实体系统自己身上，这里只负责在切场景的时机把它落盘
func _save_scene_state() -> void:
	if entity_system == null or not entity_system.has_method("save_state"):
		return
	entity_system.save_state()

func _restore_scene_state() -> void:
	if entity_system == null or not entity_system.has_method("load_state"):
		return
	var n: int = entity_system.load_state()
	if n > 0:
		print("[RobotScene] 恢复机器人: ", n)
#endregion

func _physics_process(delta: float) -> void:
	if system_manager != null:
		system_manager.tick(delta)

func _process(delta: float) -> void:
	if system_manager:
		system_manager.frame(delta)

func _init_camera_view() -> void:
	#与电路场景一致：视口尺寸稳定后触发一次完整视野刷新（开局立即到位，不跑过渡）
	sw_camera_2d._on_zoomCom_zoom(Vector2(0,-1), true)

func _exit_tree() -> void:
	#注意执行顺序：子节点的 _exit_tree 比父节点先跑，所以这里实体系统还在：
	#SWLayerManager 只是把 systems_by_view 表清了，我们手上的引用依然有效
	_save_scene_state()
	SWObjectPool.ClearSWChunkDataObject()
