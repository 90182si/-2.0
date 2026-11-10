class_name SWLogicScene extends Node
#跨场景会话：从机器人面板「修改电路」过来时，待加载存档名存在这里
const SESSION := preload("res://core/manager/sw_session.gd")
#电路文件管理器：新建脚本的类名不在 headless 的全局类缓存里，一律走 preload
const CIR_MANAGER := preload("res://circuit/sw_cir_manager.gd")
@onready var sw_camera_2d: SWCamera2D = $SWCamera2D
@onready var sw_layer_manager: SWLayerManager = $SWLayerManager

var system_manager: SWSystemManager = null
var camera_system: SWCameraSystem = null
var render_system :SWRenderSystem = null
#建筑层系统引用：必须在 _ready 里抓住。SWLayerManager._exit_tree 会把 buildSystem 置空，
#而子节点的 _exit_tree 先于父节点执行，退出时再从 sw_layer_manager.buildSystem 取就是 null
var build_system: SWBuildLayerSystem = null

func _init() -> void:
	# 渲染纹理单例必须先于任何烘焙/补丁创建一个（与 SWRobotScene 同口径）。
	# 分屏壳里两个场景同时在树里：只由最先创建的那个建一次，后来的直接复用。
	# 否则后建的那个会把单例换成自己的实例，先建那边所有材质的 uniform 全指到废纹理
	if SWSignalTexture.instance == null:
		SWStyleTexture.instance = SWStyleTexture.new()
		SWSignalTexture.instance = SWSignalTexture.create_backend()
		SWSignalTexture.instance.init()
	#刷新回调总是挂到自己身上：单例可能是壳或另一个场景建的，而回调绑的是创建者，
	#那一方退出后回调就失效（再多建几个 mesh 也不会重设 uniform）
	var refresh_cb := _refresh_texture_uniforms
	SWStyleTexture._refresh_cb = refresh_cb
	SWSignalTexture._palette_refresh_cb = refresh_cb
	# 幂等：已预热就直接返回
	SWObjectPool.InitSWChunkDataObject()
	system_manager = SWSystemManager.new()
	camera_system = SWCameraSystem.new()
	render_system = SWRenderSystem.new()

# 纹理扩容/调色板重建后刷新全部共享材质 uniform（遍历 MESH_GROUP）
func _refresh_texture_uniforms() -> void:
	if is_inside_tree():
		get_tree().call_group(SwAtlas.MESH_GROUP, "_resetShaderUniforms")

func _ready() -> void:
	camera_system.enable = true
	camera_system.attach_camera(sw_camera_2d)
	system_manager.add_system(camera_system)
	#system_manager.add_system(render_system)
	for layer in sw_layer_manager.layers:
		sw_camera_2d.addLayerNotify(layer)
	system_manager.start()
	#图层管理器的 _ready（子节点先跑）已经把建筑层系统建好，这里只是把引用留住
	if sw_layer_manager != null:
		build_system = sw_layer_manager.buildSystem
	
	# 延后一帧再初始化视野，避免窗口尺寸/相机等信息尚未稳定导致首帧加载不完整
	call_deferred("_init_camera_view")
	# 机器人面板点「修改电路」过来：把目标存档读进来再让玩家改
	call_deferred("_load_pending_save")
	
# 固定逻辑 tick 驱动：时钟元件、电路批处理等 tick 系统靠这里跑
func _physics_process(delta: float) -> void:
	if system_manager != null:
		system_manager.tick(delta)
		
func _process(delta: float) -> void:
	if system_manager:
		system_manager.frame(delta)
		
func _init_camera_view() -> void:
	# 保持原有缩放逻辑，同时在视口尺寸稳定后触发一次完整的视野刷新。
	# 开局这次必须**立即到位**（instant）：要的是那一遍完整刷新，
	# 跑过渡的话首屏区块得等 0.18s 才加载
	sw_camera_2d._on_zoomCom_zoom(Vector2(0,-1), true)

# 消费 SWSession 里的「待加载存档」：成功则顺带记下当前存档名（保存对话框回填用）。
# .swcir 与存档同名，所以机器人面板上的电路文件名就是这里的存档名
func _load_pending_save() -> void:
	var name: String = SESSION.take_pending_load()
	if name.is_empty():
		return
	if not SWSaveManager.save_exists(name):
		push_warning("[LogicScene] 要修改的存档不存在: " + name)
		return
	if sw_layer_manager == null:
		push_warning("[LogicScene] 没有 SWLayerManager，无法自动读档")
		return
	await sw_layer_manager.load_save_by_name(name)

func _exit_tree() -> void:
	#先导出再掉单例：导出要读建筑表的当前结构
	_export_edited_circuit()
	#分屏时对象池是与机器人场景共用的，清池交给壳做，
	#这里清掉会把还在跑的那一边的区块数据全抽走
	if not SESSION.split_mode:
		SWObjectPool.ClearSWChunkDataObject()

#分屏壳取建筑层系统/相机用（导出、读档前需要先问它有没有东西可导）
func get_build_system() -> SWBuildLayerSystem:
	return build_system

#tag 退出时导出改过的电路
#玩家改过结构就把**当前**结构写回同名 .swcir：机器人场景回来要按最新电路重绑。
#不能等玩家点保存——「改完直接返回」才是最常见的操作，用户明确定下了这个口径。
#返回导出的 .swcir 路径（空串 = 没导出）：分屏壳的「应用到机器人」也走这一条
func _export_edited_circuit() -> String:
	var save_name: String = SESSION.take_edited_save()
	if save_name.is_empty():
		return ""
	if build_system == null or build_system.build_manager == null:
		return ""
	var builds: Array = []
	for build in build_system.build_manager.getAllBuilds():
		if build != null and not build.bIsToBeRemoved():
			builds.append(build)
	var path: String = CIR_MANAGER.export_all(save_name, builds)
	if path.is_empty():
		print("[LogicScene] 电路结构已改，但没有可导出的接口电路（旧文件已清掉）: " + save_name)
	else:
		print("[LogicScene] 电路结构已改，已导出: " + path)
	return path
