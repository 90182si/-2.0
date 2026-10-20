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

## R3.2：主体贴图切换的轻量失效（只覆写 body part）
func markBodyRectDirty() -> void:
	if _renderableCompoent:
		_renderableCompoent.markBodyRectDirty()

#查询渲染缓存是否已失效；组件尚未创建时视为无需重建（返回 false，避免懒创建误判为 dirty）
func isRenderPartsDirty() -> bool:
	if _renderableCompoent:
		return _renderableCompoent.isRenderPartsDirty()
	return false

func rotOnce() -> void:
	rotation += 1
	
var signal_state:int = SwDefine.CircuitSignal.NONE
var circuit_on:bool = false
#var tunnel_pair_id:int = -1
#var tunnel_extra_data:int = 0
var in_loop:bool = false:
	set(new_value):
		if in_loop == new_value:
			return
		in_loop = new_value
		#环路警示红写在引脚/底座部件的颜色里，翻转后必须整份重建（视觉补丁覆盖不到）
		if _renderableCompoent:
			_renderableCompoent.markRenderPartsDirty()
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
	# 引脚 net 归属与主体贴图都被重置，视觉补丁不足以表达，须整份重建
	markRenderPartsDirty()

func buildStateChanged(signalValue:SwDefine.CircuitSignal) -> void:
	signal_state = signalValue

## R4.1：显示/存档用的电平。电线不再被逐帧回写 signal_state（IR 事件路径省掉整条写回链），
## 其电平按所在 net 现取；其余建筑仍读自身 signal_state。
func getDisplaySignal() -> SwDefine.CircuitSignal:
	if _circuitCompoent != null:
		var lvl: int = _circuitCompoent.getWireLevel()
		if lvl >= 0:
			return lvl as SwDefine.CircuitSignal
	return signal_state

func setValue(dir:SwDefine.SW_Dir,value:SwDefine.CircuitSignal) -> void:
	pass

func bIsToBeRemoved() -> bool:
	return buildState.state == SwDefine.BuildState.TO_BE_REMOVED

#建筑物放置结束时调用
func on_idled(swBuildManager:SWBuildManager) -> void:
	pass

## 获取旋转后的实际占地尺寸
func getFootprint() -> Vector2i:
	if SwDefine.isSideways(rotation):
		return Vector2i(buildDefine.size.y, buildDefine.size.x)
	return buildDefine.size

## 获取 footprint 覆盖的所有世界格坐标（GRID_SIZE 对齐的 axisPos）
func getCoveredCells() -> Array:
	var result: Array = []
	var fp := getFootprint()
	var anchorGrid := buildAxisPos  # 已经是格对齐坐标
	for j in range(fp.y):
		for i in range(fp.x):
			result.append(Vector2i(anchorGrid.x + i * SwDefine.GRID_SIZE.x, anchorGrid.y + j * SwDefine.GRID_SIZE.y))
	return result

## 获取旋转后的 cell_offset（90° CW 递推公式）
## rotation=0: (x, y)
## rotation=1: (y, s.x-1-x)
## rotation=2: (s.x-1-x, s.y-1-y)
## rotation=3: (s.y-1-y, x)
func getRotatedCellOffset(pin:SWBuildPinDefine) -> Vector2i:
	var off := pin.cell_offset
	match rotation:
		0: return off
		1: return Vector2i(off.y, buildDefine.size.x - 1 - off.x)
		2: return Vector2i(buildDefine.size.x - 1 - off.x, buildDefine.size.y - 1 - off.y)
		3: return Vector2i(buildDefine.size.y - 1 - off.y, off.x)
		_: return off

func on_deleted(swBuildManager:SWBuildManager) -> void:
	pass
