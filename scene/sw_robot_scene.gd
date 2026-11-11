class_name SWRobotScene extends Node

# ==========================================================================
# 机器人场景（默认主场景）
#
# 与 SWLogicScene 的关系：地板/相机/层装配完全一样，区别只有两点
#   1. 没有 SWBuildLayer（不放电路元件），换成一个 SWEntityLayer 画机器人
#   2. 多一个 SWRobotTick：按 250ms 一拍驱动所有机器人跑各自绑定的 .swcir 电路
#
#电路场景（sw_logic_scene.tscn）通过机器人 HUD 的「电路场景」按钮进入；
#「修改电路」会进分屏壳（sw_split_scene.tscn）：左右并排，本场景作为左侧实例。
#分屏时本场景与 SWLogicScene 同时活着，各自用自己的系统与相机。
# ==========================================================================

@onready var sw_camera_2d: SWCamera2D = $SWCamera2D
@onready var sw_layer_manager: SWLayerManager = $SWLayerManager
#节拍器按 Node 持有：新脚本的类名不在 headless 全局类缓存里，不能当类型标注用
@onready var sw_robot_tick: Node = $SWRobotTick
#跨场景会话：从电路场景回来时看电路结构是否被改过（决定先停节拍、按最新电路重绑）
const SESSION := preload("res://core/manager/sw_session.gd")
#分屏壳（HUD「修改电路」进）：正常路径是把**本实例**交给它，不重新加载
const SPLIT_SCENE_PATH: String = "res://scene/sw_split_scene.tscn"

var system_manager: SWSystemManager = null
var camera_system: SWCameraSystem = null
var render_system: SWRenderSystem = null

#进分屏前的宿主节点 / 所在的分屏壳：退出时原路搬回去（不重新加载场景）
var _split_host: Node = null
var _split_shell: Node = null

#实体层系统（由 SWLayerManager 按图层名取出；线接在 _ready 里）
var entity_system = null

func _init() -> void:
	#渲染纹理单例必须先于任何烘焙/补丁创建一个（与 SWLogicScene 同口径）。
	#分屏壳里两个场景同时在树里：只由最先创建的那个建一次，后来的直接复用。
	#否则后建的那个会把单例换成自己的实例，先建那边所有材质的 uniform 全指到废纹理
	if SWSignalTexture.instance == null:
		SWStyleTexture.instance = SWStyleTexture.new()
		SWSignalTexture.instance = SWSignalTexture.create_backend()
		SWSignalTexture.instance.init()
	#刷新回调总是挂到自己身上：单例可能是壳或另一个场景建的，而回调绑的是创建者，
	#那一方退出后回调就失效（再多建几个 mesh 也不会重设 uniform）
	var refresh_cb := _refresh_texture_uniforms
	SWStyleTexture._refresh_cb = refresh_cb
	SWSignalTexture._palette_refresh_cb = refresh_cb
	#幂等：已预热就直接返回
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
		#框选机器人交给实体层：手持层那套框选选的是建筑（本场景没有 build system）。
		#不关的话 Ctrl+左键拖会同时出现两圈矩形，Ctrl+右键拖还会落到擦除分支去删机器人
		hold_system.rect_select_enabled = false
		#手上拿着机器人/箱子时那一笔是拿去放置的，不该变成框选
		entity_system.set_box_select_gate(Callable(hold_system, "is_hold_empty"))
	if sw_robot_tick != null:
		sw_robot_tick.call("bind_entity_system", entity_system)
	_wire_bind_panel()
	_wire_timing_panel()

#单击机器人 -> HUD 电路绑定面板；面板选中文件 -> 回来绑到这台机器人。
#Ctrl+框选 -> 同一个面板，但对着整批台：选一项就整批绑上。
#HUD 不直接持有实体系统，两边靠信号对接（与 selTool/save_requested 同一套做法）
func _wire_bind_panel() -> void:
	var hud: SWLayer = sw_layer_manager.hudLayer
	if hud == null or not hud.has_method("show_bind_panel"):
		return
	entity_system.entity_selected.connect(Callable(hud, "show_bind_panel"))
	entity_system.selection_cleared.connect(Callable(hud, "hide_bind_panel"))
	entity_system.selection_multi_changed.connect(Callable(hud, "show_bind_panel_multi"))
	#用字符串 connect：hud 的静态类型是 SWLayer，子类自定义信号在静态检查下看不到
	hud.connect("circuit_bind_requested",
			Callable(self, "_on_circuit_bind_requested").bind(entity_system))
	hud.connect("circuit_bind_multi_requested",
			Callable(self, "_on_circuit_bind_multi_requested").bind(entity_system))

func _on_circuit_bind_requested(entity, file_name: String, target_system) -> void:
	if target_system == null:
		return
	target_system.bind_circuit(entity, file_name)

#框选批量绑定：逐台绑（同一个文件走同一套共享网表，第二台起只是分配一个 bit）
func _on_circuit_bind_multi_requested(entities: Array, file_name: String, target_system) -> void:
	if target_system == null or entities.is_empty():
		return
	for e in entities:
		target_system.bind_circuit(e, file_name)

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

#分屏壳取实体系统 / 节拍器用（壳要协调「改电路→暂停」与「应用→重绑」）
func get_entity_system():
	return entity_system

func get_robot_tick() -> Node:
	return sw_robot_tick

#region 分屏接管（HUD「修改电路」）
# 进分屏：把**本实例**交给壳搬进左视口，机器人/相机/区块/选中状态全部沿用。
# 原来是 change_scene_to_file，整棵场景重建（重读存档、重算区块、界面闪一下）。
# 返回 false = 没进成，调用方退回整体换场景。
# 坑：搬父节点会触发一次 _exit_tree，但它不是真退出（重入树也不会再走 _ready），
# 所以 SWLayerManager / SWLayer / 本场景在那次退出里都靠 SESSION.relocating_scene 跳过清理
func enter_split_mode() -> bool:
	if SESSION.split_mode or not is_inside_tree():
		return false
	var host: Node = get_parent()
	if host == null:
		return false
	var packed: PackedScene = load(SPLIT_SCENE_PATH)
	if packed == null:
		push_warning("[RobotScene] 分屏壳加载失败: " + SPLIT_SCENE_PATH)
		return false
	var shell: Node = packed.instantiate()
	#壳的 _ready 在下面 add_child 时同步跑：先把它要接管的实例注入好，
	#它就不会再 instantiate 一份新的机器人场景
	shell.set("left_scene", self)
	_split_host = host
	_split_shell = shell
	SESSION.split_mode = true
	SESSION.relocating_scene = true
	host.add_child(shell)
	SESSION.relocating_scene = false
	if host == get_tree().root:
		get_tree().current_scene = shell
	#换到左视口后要重新成为该视口的当前相机
	call_deferred("_refresh_camera_after_move")
	return true

# 退出分屏：壳反过来调它，把本实例搬回原来的宿主节点。不重建、不读存档
func return_from_split() -> void:
	if not is_inside_tree():
		return
	var tree := get_tree()
	SESSION.relocating_scene = true
	var p: Node = get_parent()
	if p != null:
		p.remove_child(self)
	var host: Node = _split_host if is_instance_valid(_split_host) else tree.root
	host.add_child(self)
	SESSION.relocating_scene = false
	if host == tree.root:
		tree.current_scene = self
	_split_host = null
	_split_shell = null
	call_deferred("_refresh_camera_after_move")

# 搬进/搬出子视口后相机要重新接手：Camera2D 的 current 是按视口算的，
# 换了视口不重新 make_current，新视口里就没有相机（画面全黑/不动）
func _refresh_camera_after_move() -> void:
	if sw_camera_2d == null or not is_inside_tree():
		return
	sw_camera_2d.make_current()
	#可见范围的整体尺寸变了（全屏→半屏，或反之），让各层重算一次区块
	sw_camera_2d.call("view_rect_changed")
#endregion

#region 场景状态（切出记录 / 返回重载）
#摆位、朝向、绑的电路都存在实体系统自己身上，这里只负责在切场景的时机把它落盘
func _save_scene_state() -> void:
	if entity_system == null or not entity_system.has_method("save_state"):
		return
	entity_system.save_state()

func _restore_scene_state() -> void:
	if entity_system == null or not entity_system.has_method("load_state"):
		return
	#电路场景里改过电路结构：先停节拍。
	#load_state 会逐台重新 bind_circuit（重新读最新的 .swcir），要是在半拍中间换掉电路，
	#机器人会带着上一拍的动作跑下一条电路。用户口径：改了电路就先停机器人，重载完再继续
	var edited: String = SESSION.take_edited_save()
	if not edited.is_empty() and sw_robot_tick != null:
		sw_robot_tick.call("pause")
	var n: int = entity_system.load_state()
	if n > 0:
		print("[RobotScene] 恢复机器人: ", n)
	if not edited.is_empty() and sw_robot_tick != null:
		sw_robot_tick.call("resume")
		print("[RobotScene] 电路结构已改，已按最新电路重绑并继续运行: ", edited)
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
	#场景树内部搬迁（进分屏 / 退回全屏）：节点没死，不能存盘也不能清共享池。
	#注意子节点的 _exit_tree 比父节点先跑，所以这里实体系统还在：
	#SWLayerManager 只是把 systems_by_view 表清了，我们手上的引用依然有效
	if SESSION.relocating_scene:
		return
	_save_scene_state()
	#分屏时对象池是与另一个场景共用的，清池交给壳在自己最后一个退出时做，
	#这里清掉会把还在跑的那一边的区块数据全抽走
	if not SESSION.split_mode:
		SWObjectPool.ClearSWChunkDataObject()
