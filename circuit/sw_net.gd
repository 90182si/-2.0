class_name SWNet extends RefCounted

# 渲染线色缓存：按 wireName 解析一次，信号高频变化时不再每帧 GetWireColor
var renderColorLow: Color = Color()
var renderColorHigh: Color = Color()
var renderColorResolved: bool = false

# net 当前电平（由驱动门统一解析后写入，是连线颜色的唯一真源）
var curSignal:SwDefine.CircuitSignal
# 电平最后一次变化的求值轮次：下游门据此判断要不要重新求值
var changedEpoch:int = -1
# 电平版本号：每次翻转 +1，渲染端在区块重绘时比对它决定连线颜色要不要重刷
var sigVersion:int = 0
# 本 net 的连线覆盖到的区块：信号翻转时直接按它标脏，
# 省掉「逐根电线 buildStateChanged + markColorDirty」（连线数量是门的十几倍）
var chunkPosArr:Array[Vector2i] = []
# 所属电路控制：求值时经它拉取源输入（见 SWCircuitControl.resolveNetSignal）
var circuit:SWCircuitControl = null
# 本轮的最终电平缓存；sigEpoch 与求值轮次一致表示本轮已解析
var sigEpoch:int = -1
# 本轮第一次翻转前的电平。时序元件用它采样数据输入：
# 同一轮里上游传播（含其它寄存器刚锁存的 Q）不会污染本拍的采样值
var preEpoch:int = -1
var preSignal:SwDefine.CircuitSignal = SwDefine.CircuitSignal.NONE
# 解析中标记：组合环回读时用上一轮电平打断递归
var resolving:bool = false
#输入
var wireGroup:SwDefine.SWWireGroup = null
#{SWBuildItemDefine,SwDefine.SW_Dir}
var _drivers:Array = []
#输出
#{SWBuildItemDefine,SwDefine.SW_Dir}
var _loads:Array = []
#扁平索引：求值热点直接遍历组件，不再逐项解包 Dictionary、也不再每拍查表
var _driverComps:Array = []
var _loadComps:Array[SWBuildCompoentCircuit] = []

#func setWireGroup
func _init() -> void:
	wireGroup = SwDefine.SWWireGroup.new()

#取本轮的最终电平：有电路控制时按源输入解析，否则退回上一轮发布值
func signalNow() -> SwDefine.CircuitSignal:
	if circuit != null and is_instance_valid(circuit):
		return circuit.resolveNetSignal(self)
	return curSignal

#本拍开始前（上一轮结清后）的电平：时序元件采样数据输入用，不触发上游求值
func epochSignal() -> SwDefine.CircuitSignal:
	if circuit != null and is_instance_valid(circuit) and preEpoch == circuit._curEpoch:
		return preSignal
	return curSignal

func getDrivers() -> Array:
	return _drivers

func getLoads() -> Array:
	return _loads

func getDriverComps() -> Array:
	return _driverComps

func getLoadComps() -> Array[SWBuildCompoentCircuit]:
	return _loadComps

func addDriver(driver:Dictionary) -> void:
	_drivers.append(driver)
	_appendDriverComp(driver)
	setBuildNet([driver])
	
func addLoader(load:Dictionary) -> void:
	_loads.append(load)
	_appendLoadComp(load)
	setBuildNet([load])

func _appendDriverComp(driver:Dictionary) -> void:
	var build:SWBuildItemDefine = driver.get("build", null)
	#电线本身不是驱动，只是把驱动门转发到本 net
	if build == null or SwCommon.IsWireBuild(build):
		return
	var comp:SWBuildCompoentCircuit = build.getCircuitCompoent()
	if comp != null:
		_driverComps.append(comp)

func _appendLoadComp(load:Dictionary) -> void:
	var build:SWBuildItemDefine = load.get("build", null)
	if build == null:
		return
	var comp:SWBuildCompoentCircuit = build.getCircuitCompoent()
	if comp != null:
		_loadComps.append(comp)
	
func setBuildNet(driversAndLoads:Array) -> void:
	for driver:Dictionary in driversAndLoads:
		var build = driver.get_or_add("build",null)
		var pinDir = driver.get_or_add("pinDir",null)
		if not build:
			continue
		var circuitCompoent:SWBuildCompoentCircuit = build.getCircuitCompoent()
		if circuitCompoent:
			circuitCompoent.pinNetMap[pinDir] = self
			#端口→net 的扁平缓存随连线变化失效
			circuitCompoent.invalidateDirMasks()
			
func setNet(drivers:Array,loads:Array) -> void:
	for driver:Dictionary in drivers:
		_drivers.append(driver)
		_appendDriverComp(driver)
	for load:Dictionary in loads:
		_loads.append(load)
		_appendLoadComp(load)
	setBuildNet(drivers)
	setBuildNet(loads)
	pass

# 连线组装配完成后调用一次：缓存本 net 覆盖的区块，运行期翻转时直接标脏
func buildChunkIndex() -> void:
	chunkPosArr.clear()
	if wireGroup == null:
		return
	var seen:Dictionary = {}
	for w:SWBuildItemDefine in wireGroup.wireBuilds:
		var cp:Vector2i = SwCommon.GetChunkPos(w.buildAxisPos)
		if seen.has(cp):
			continue
		seen[cp] = true
		chunkPosArr.append(cp)
