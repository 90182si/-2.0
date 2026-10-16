class_name SWLogicScene extends Node
@onready var sw_zoom_com: SWZoomCom = $SWZoomCom
@onready var sw_move_com: SWMoveCom = $SWMoveCom
@onready var sw_camera_2d: SWCamera2D = $SWCamera2D
@onready var sw_layer_manager: SWLayerManager = $SWLayerManager

func _init() -> void:
	# 初始化不依赖 autoload 的全局单例（StyleTexture/SignalTexture）。
	# 对象池预热需要 SwAtlas.current（在 autoload 的 _ready 里才赋值），
	# 因此放到 _ready() 中执行。
	# 初始化 StyleTexture 单例：从 registry 批量登记 atlas region
	var style_tex := SWStyleTexture.new()
	var registry = load("res://res/build_define_registry.tres")
	if registry:
		style_tex.build_from_registry(registry)
	SWStyleTexture.instance = style_tex
	# 初始化 SignalTexture 单例
	var signal_tex := SWSignalTexture.new()
	signal_tex.init()
	SWSignalTexture.instance = signal_tex

func _ready() -> void:
	# 此时 autoload 的 _ready 已执行完毕（SwAtlas.current 已就绪），
	# 预热对象池；池化节点 reUse()→_resetShaderUniforms() 需要三个 uniform 源均可用。
	SWObjectPool.InitSWChunkDataObject()
	sw_zoom_com.addZoomFuncCamObject(sw_camera_2d)
	sw_move_com.addMoveFuncCamObject(sw_camera_2d)
	for layer in sw_layer_manager.layers:
		sw_camera_2d.addLayerNotify(layer)
	# 延后一帧再初始化视野，避免窗口尺寸、相机等信息尚未稳定导致首帧加载不完整
	call_deferred("_init_camera_view")
	pass

func _init_camera_view() -> void:
	# 保持原有缩放逻辑，同时在视口尺寸稳定后触发一次完整的视野刷新
	sw_camera_2d._on_zoomCom_zoom(Vector2(0,-1), Vector2.ZERO)

func _exit_tree() -> void:
	SWObjectPool.ClearSWChunkDataObject()
