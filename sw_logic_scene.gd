class_name SWLogicScene extends Node
@onready var sw_zoom_com: SWZoomCom = $SWZoomCom
@onready var sw_move_com: SWMoveCom = $SWMoveCom
@onready var sw_camera_2d: SWCamera2D = $SWCamera2D
@onready var sw_layer_manager: SWLayerManager = $SWLayerManager

func _init() -> void:
	SWObjectPool.InitSWChunkDataObject()

func _ready() -> void:
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
