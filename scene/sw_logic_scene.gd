class_name SWLogicScene extends Node
#跨场景会话：从机器人面板「修改电路」过来时，待加载存档名存在这里
const SESSION := preload("res://core/manager/sw_session.gd")
@onready var sw_camera_2d: SWCamera2D = $SWCamera2D
@onready var sw_layer_manager: SWLayerManager = $SWLayerManager

var system_manager: SWSystemManager = null
var camera_system: SWCameraSystem = null
var render_system :SWRenderSystem = null

func _init() -> void:
	# 渲染纹理单例必须先于任何烘焙/补丁创建：styleTex 惰性注册、signalBits 电平纹理、
	# paletteTex 调色板纹理。扩容/注册重建纹理后经回调刷新共享材质 uniform。
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
	SWObjectPool.ClearSWChunkDataObject()
