class_name SWBuildLayer extends SWLayer

@onready var sw_draw_manager: SWDrawManager = $SWDrawManager

func create_layer_system() -> SWLayerSystem:
	return SWBuildLayerSystem.new()

func _ready() -> void:
	sw_draw_manager.set_name("buildDrawManager")
	sw_draw_manager.setDrawMode(SwDefine.GridDrawMode.ByContent)
	sw_draw_manager.useName = "Content"

# 由 SWBuildLayerSystem 在 attach_view 时注入：渲染层需要同一个 build_manager
# 去查 getBuildCountByChunkPos / getBuildsByChunkPos
func attach_build_manager(build_manager:SWBuildManager) -> void:
	sw_draw_manager.setBuildManager(build_manager)
	
# 兜底：万一系统侧没注入（顺序问题 / 单独实例化 / 测试），这里再补一次
func _ensure_build_manager() -> void:
	if sw_draw_manager.sw_build_manager != null:
		return
	var system := layer_system as SWBuildLayerSystem
	if system != null and system.build_manager != null:
		sw_draw_manager.setBuildManager(system.build_manager)
		
func refresh_builds(builds: Array) -> void:
	if builds.is_empty():
		return
	var chunk_positions: Array[Vector2i] = []
	var seen: Dictionary[Vector2i, bool] = {}
	for build in builds:
		if build == null:
			continue
		build.markRenderPartsDirty()
		var chunk_pos := SwCommon.GetChunkPos(build.buildAxisPos)
		if not seen.has(chunk_pos):
			seen[chunk_pos] = true
			chunk_positions.append(chunk_pos)
	sw_draw_manager.updataChunks(chunk_positions)
	
func refresh_all() -> void:
	_ensure_build_manager()
	sw_draw_manager.updataAllChunks()
	sw_draw_manager.on_view_rect_changed()

func on_view_rect_changed(viewRect:Rect2,speedVec:Vector2) -> void:
	_ensure_build_manager()
	sw_draw_manager.on_view_rect_changed(viewRect,speedVec)
	super.on_view_rect_changed(viewRect,speedVec)
	
# ---- 迁移期兼容转发：让 CircuitTestHarness / 旧 UI 不改也能跑 ----
var sw_build_manager: SWBuildManager:
	get:
		var system := layer_system as SWBuildLayerSystem
		return system.build_manager if system != null else null
		
var sw_circuit_control: SWCircuitControl:
		get:
			var system := layer_system as SWBuildLayerSystem
			return system.circuit_control if system != null else null
		
func load_save_data(data: Dictionary) -> void:
	var system := layer_system as SWBuildLayerSystem
	if system != null:
		system.load_save_data(data)

func getNotifyChunkPosArr(builds:Array[SWBuildItemDefine]) -> Array[Vector2i]:
	var system := layer_system as SWBuildLayerSystem
	if system != null:
		return system.getNotifyChunkPosArr(builds)
	return []
