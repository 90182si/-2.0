#建筑物定义
@abstract
class_name SWBuildItemDefine extends RefCounted
var buildState:SwDefine.SWBuildState = null
var id:int
var buildAxisPos:Vector2i
var buildDefine:SWBuildDefine
var rotation:SwDefine.SW_Dir = 0:
	set(new_value):
		rotation = new_value
		rotation = posmod(rotation,4)
		#旋转会改变部件朝向，直接失效渲染缓存
		if _renderableCompoent:
			_renderableCompoent.markRenderPartsDirty()
var compoent:Dictionary[SwDefine.BuildCompoentType,SWBuildCompoent] = {}
#性能优化：缓存 CIRCUIT 组件引用，避免热点端口判断反复走 getCompoent 字典查找
var _circuitCompoent:SWBuildCompoentCircuit = null
var _renderableCompoent:SWBuildCompoentRenderable = null

func getCompoent(compoentType:SwDefine.BuildCompoentType) -> SWBuildCompoent:
	if not compoent.has(compoentType):
		compoent[compoentType] = SwCommon.CreateCompoent(compoentType)
	return compoent[compoentType]
func getCircuitCompoent() -> SWBuildCompoentCircuit:
	if _circuitCompoent == null:
		_circuitCompoent = getCompoent(SwDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
		_circuitCompoent.setBuildRef(self)
	return _circuitCompoent
func getRenderableCompoent() -> SWBuildCompoentRenderable:
	if _renderableCompoent == null:
		_renderableCompoent = getCompoent(SwDefine.BuildCompoentType.RENDER_ABLE) as SWBuildCompoentRenderable
		_renderableCompoent.setBuildRef(self)
	return _renderableCompoent
#转发渲染部件缓存失效；组件尚未创建时无需处理（新建后默认 dirty）
func markRenderPartsDirty() -> void:
	if _renderableCompoent:
		_renderableCompoent.markRenderPartsDirty()

func rotOnce() -> void:
	rotation += 1
	
var signal_state:int = SwDefine.CircuitSignal.NONE
var circuit_on:bool = false
#var tunnel_pair_id:int = -1
#var tunnel_extra_data:int = 0
var in_loop:bool = false
var circuit:SwDefine.SWCircuitData = null


func _sub_init() -> void:
	pass
	
func _init(axisPos:Vector2i,buildDef:SWBuildDefine,rot:int = 0) -> void:
	id = SwCommon.GenNextBuildId()
	buildState = SwDefine.SWBuildState.new()
	buildAxisPos = axisPos
	buildDefine = buildDef
	getCircuitCompoent().setPortFlag(buildDefine)
	var rotCount:int = rot
	for i in range(rotCount):
		rotOnce()
	var renderable = getRenderableCompoent()
	renderable.buildHasAtlas = true
	renderable.buildHasBase = true
	renderable.drawRect = buildDefine.atlasTextureOff.region
	_sub_init()

func getDirBuild(swBuildManager:SWBuildManager,rot:SwDefine.SW_Dir) -> SWBuildItemDefine:
	var nextPos:Vector2i = buildAxisPos + SwDefine.dir_to_vec(rot)*SwDefine.GRID_SIZE
	var nextBuild:SWBuildItemDefine = swBuildManager.getBuild(nextPos)
	if nextBuild == null:
		return null
	if nextBuild.bIsToBeRemoved():
		return null
	return nextBuild

func onPressed(_pressed:bool) -> void:
	pass


	
func resetBuildState() -> void:
	in_loop = false
	getCircuitCompoent().resetPortState()
	getRenderableCompoent().drawRect = buildDefine.atlasTextureOff.region

func buildStateChanged(signalValue:SwDefine.CircuitSignal) -> void:
	signal_state = signalValue

func setValue(dir:SwDefine.SW_Dir,value:SwDefine.CircuitSignal) -> void:
	pass

func bIsToBeRemoved() -> bool:
	return buildState.state == SwDefine.BuildState.TO_BE_REMOVED

#建筑物放置结束时调用
func on_idled(swBuildManager:SWBuildManager) -> void:
	pass

func on_deleted(swBuildManager:SWBuildManager) -> void:
	pass
