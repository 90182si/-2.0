class_name SWBuildCompoentCircuit extends SWBuildCompoent

var buildRef:SWBuildItemDefine = null
#var expr:String = ""
#0b1111代表四边都有连接
var pinConBit:int = 0
#0b1111代表四边都是输出口
#0b1xxxx代表是电线
var pinDefineBit:int = 0
#0b1111代表四边都输出高电平
var pinValueBit:int = 0

var linkedPort:int = 0

# m×n 多格建筑引脚边缘探测开关（为 false 时所有建筑走旧路径）
var allowMulticell:bool = true

var pinNetMap:Dictionary[SwDefine.SW_Dir,SWNet] = {}
var pinExprMap:Dictionary[SwDefine.SW_Dir,SwDefine.SWCircuitStruct] = {}
#表达式构建中标记（防环），由具体电路组件的 getBuildExpr 维护
var _buildingExpr:bool = false

func setBuildRef(build:SWBuildItemDefine) -> void:
	buildRef = build

func _init() -> void:
	#pinExprMap = SwDefine.SWCircuitStruct.new()
	pass

func getBuildIOConnectBuildArr(swBuildManager:SWBuildManager) -> Array:
	var linkedBuilds:Array = []
	# m×n 多格路径：从引脚格出发查找邻居
	if allowMulticell and _isMultiCell() and not SwCommon.IsWireBuild(buildRef):
		for pinIndex:int in range(3,-1,-1):
			if not isPort(pinIndex):
				continue
			var pin:SWBuildPinDefine = _getPinByWorldDir(pinIndex)
			if pin == null:
				continue
			var nextBuild:SWBuildItemDefine = _getDirBuildFromPin(swBuildManager, pin)
			if nextBuild:
				linkedBuilds.append({"build":nextBuild,"dir":pinIndex})
		return linkedBuilds
	# 旧路径（1×1 建筑或电线或 allowMulticell=false）
	for pinIndex:int in range(3,-1,-1):
		if not isPort(pinIndex):
			continue
		var nextBuild:SWBuildItemDefine = getDirBuild(swBuildManager,pinIndex)
		if nextBuild:
			linkedBuilds.append({"build":nextBuild,"dir":pinIndex})
	return linkedBuilds
	
func getDirBuild(swBuildManager:SWBuildManager,rot:SwDefine.SW_Dir) -> SWBuildItemDefine:
	var nextBuild:SWBuildItemDefine = buildRef.getDirBuild(swBuildManager,rot)
	if not nextBuild:
		return null
	var nextCircuitCom = nextBuild.getCircuitCompoent()
	if not nextCircuitCom:
		return null
	var antiDir:SwDefine.SW_Dir = SwDefine.getAntiDir(rot)
	if not nextCircuitCom.isPort(antiDir):
		return null
	if SwCommon.IsWireBuild(buildRef) or SwCommon.IsWireBuild(nextBuild):
		return nextBuild
	if portIsOutput(rot) and nextCircuitCom.portIsInput(antiDir):
		return nextBuild
	if portIsInput(rot) and nextCircuitCom.portIsOutput(antiDir):
		return nextBuild
	return null
	
func getNet(swBuildManager:SWBuildManager) -> Array:
	if buildRef.bIsToBeRemoved():
		return []
	# m×n 多格路径
	if allowMulticell and _isMultiCell() and not SwCommon.IsWireBuild(buildRef):
		for pinIndex:int in range(3,-1,-1):
			if not isPort(pinIndex):
				continue
			if isLinkedPort(pinIndex):
				continue
			if portIsInput(pinIndex):
				continue
			var pin:SWBuildPinDefine = _getPinByWorldDir(pinIndex)
			if pin == null:
				continue
			var nextBuild:SWBuildItemDefine = _getDirBuildFromPin(swBuildManager, pin)
			if nextBuild == null:
				continue
			var nextBuildCircuitCom:SWBuildCompoentCircuit = nextBuild.getCircuitCompoent()
			if nextBuildCircuitCom == null:
				continue
			var antiDir:SwDefine.SW_Dir = SwDefine.getAntiDir(pinIndex)
			setLinkedPort(pinIndex)
			nextBuildCircuitCom.setLinkedPort(antiDir)
			nextBuildCircuitCom.setDriverOrLoader([{"build":buildRef,"pinDir":pinIndex}],[{"build":nextBuildCircuitCom.buildRef,"pinDir":antiDir}])
		return []
	# 旧路径
	for pinIndex:int in range(3,-1,-1):
		if not isPort(pinIndex):
			continue
		#如果这个方向的端口不可用 或者 是这个建筑物即将被删除 或者 这个端口是输入口
		if isLinkedPort(pinIndex):
			continue
		#这里的portIsInput(pinIndex)会导致wire所有端口跳过，wire连接的下一个输入口没法被获取到
		if portIsInput(pinIndex):
			continue
		#获取开关\按钮方向的建筑物
		var nextBuild:SWBuildItemDefine = getDirBuild(swBuildManager,pinIndex)
		if nextBuild == null:
			continue
		var nextBuildCircuitCom:SWBuildCompoentCircuit = nextBuild.getCircuitCompoent()
		if nextBuildCircuitCom == null:
			continue
		var antiDir:SwDefine.SW_Dir = SwDefine.getAntiDir(pinIndex)
		#标记两个建筑物相应端口占用
		setLinkedPort(pinIndex)
		nextBuildCircuitCom.setLinkedPort(antiDir)
		nextBuildCircuitCom.setDriverOrLoader([{"build":buildRef,"pinDir":pinIndex}],[{"build":nextBuildCircuitCom.buildRef,"pinDir":antiDir}])
	return []

#func getExpr(pinDir:SwDefine.SW_Dir) -> SwDefine.SWCircuitStruct:
	#return null

#以下为电路逻辑入口，默认空实现，子类按需覆盖
func getBuildExpr() -> void:
	pass

## 时序元件输入侧表达式的根层构建入口（寄存器重写）
## 表达式 DFS 中只允许取时序元件的状态叶子，输入锥必须在根层级单独展开，
## 否则从 Q 侧进入寄存器的合法时序反馈会被误判为组合环
func buildInputExprs() -> void:
	pass

## 时序元件判定（寄存器返回 true），用于组合环检测跳过时序屏障出边
func isSequential() -> bool:
	return false

## 收集 net 上所有驱动表达式并入 cirStruct.args（统一的防环/时序屏障入口）
## - 驱动是时序元件（寄存器）：不判环，直接取其 Q 侧状态叶子作为输入
## - 驱动是组合元件且构建中：真正的组合回边，标记 in_loop
func appendDriverExprs(cirStruct:SwDefine.SWCircuitStruct, net:SWNet) -> void:
	var drivers = net.getDrivers()
	for driver:Dictionary in drivers:
		var build = driver["build"]
		var pDir = driver["pinDir"]
		if build == null:
			continue
		var drvComp:SWBuildCompoentCircuit = build.getCircuitCompoent()
		if drvComp == null:
			continue
		drvComp.getBuildExpr()
		# 驱动是组合元件且构建中：真正的组合回边，标环；
		# 驱动是时序元件：不判环，其 Q 状态叶子先于输入锥构建，可直接取用
		if drvComp._buildingExpr and not drvComp.isSequential():
			build.in_loop = true
			buildRef.in_loop = true
			continue
		var expr = drvComp.getExpr(pDir)
		if expr != null:
			cirStruct.args.append(expr)

func getExpr(_pinDir:SwDefine.SW_Dir) -> SwDefine.SWCircuitStruct:
	return null
	
var _setDriverOrLoaderCallable:Callable = Callable()
func driverOrLoaderCallable(cb: Callable) -> void:
	if cb.get_argument_count() != 2:
		push_error("需要2个参数：drivers:Array,loaders:Array")
		return
	_setDriverOrLoaderCallable = cb
func setDriverOrLoader(drivers:Array,loaders:Array) -> void:
	if not _setDriverOrLoaderCallable.is_null():
		_setDriverOrLoaderCallable.call(drivers,loaders)
	else:
		var net:SWNet = SWNet.new()
		net.setNet(drivers,loaders)
	
func getValue(dir:SwDefine.SW_Dir) -> SwDefine.CircuitSignal:
	# T2.5：useIR 且编译产物覆盖该引脚时直接读 slot（无 pull 递归/无副作用）
	var sv := _getIrSlotValue(dir)
	if sv != -1:
		return SwDefine.CircuitSignal.HIGH if sv == 1 else SwDefine.CircuitSignal.LOW
	return _getValueTree(dir)

## 树求值（无副作用版）：原 EvalStruct pull 路径，useIR=false 回退与子类副作用分支复用
func _getValueTree(dir:SwDefine.SW_Dir) -> SwDefine.CircuitSignal:
	var sig:SwDefine.CircuitSignal = SwDefine.CircuitSignal.NONE
	if not pinExprMap.has(dir):
		return sig
	var cirStr:SwDefine.SWCircuitStruct = pinExprMap[dir]
	var v = SwCommon.EvalStruct(cirStr)
	if v == 1:
		sig = SwDefine.CircuitSignal.HIGH
	else:
		sig = SwDefine.CircuitSignal.LOW
	return sig

## T2.5：查 IR slot 值；未命中（useIR 关/无程序/无 slot/越界）返回 -1
func _getIrSlotValue(dir:SwDefine.SW_Dir) -> int:
	var control := SWCircuitControl.current
	if control == null or not control.useIR or control.boolProgram == null:
		return -1
	var slot: int = control.slotMap.get(buildRef.id * 4 + dir, -1)
	if slot < 0:
		return -1
	return control.boolProgram.get_slot_value(slot)

## T2.5：状态驱动叶的运行时直读入口（按钮/开关/时钟/寄存器 Q 重写）；
## 返回 0/1 表示状态驱动，-1 表示非状态驱动（IR 编译器据此区分 OP_READ 与 OP_INPUT 叶）
func getPinReadState(_dir:SwDefine.SW_Dir) -> int:
	return -1

func ff(cirStruct:SwDefine.SWCircuitStruct,visited:Dictionary = {}) -> Array:
	var result:Array = []
	if cirStruct == null or visited.has(cirStruct):
		return result
	visited[cirStruct]=true
	for arg in cirStruct.args:
		if arg is SwDefine.SWBuildPinStruct:
			#叶子：直接依赖的引脚
			result.append(arg.build.id)
		elif arg is SwDefine.SWCircuitStruct:
			#子树：继续向下递归
			result.append_array(ff(arg,visited))
	return result
		
func getDependBuildIds() -> Array[int]:
	var ids:Array[int] = []
	for dir in range(3,-1,-1):
		if pinExprMap.has(dir):
			ids.append_array(ff(pinExprMap[dir]))
	return ids

#端口方向定义（原建筑 setPortFlag 逻辑下沉至组件），子类按需覆盖
func setPortFlag(_buildDef:SWBuildDefine) -> void:
	pass

func setPinDefine(pinDir:SwDefine.SW_Dir,define:SwDefine.CircuitPinType) -> void:
	if define == SwDefine.CircuitPinType.INPUT:
		pinDefineBit = pinDefineBit & (0b11111-(1<<pinDir))
	elif define == SwDefine.CircuitPinType.OUTPUT:
		pinDefineBit = pinDefineBit | (1<<pinDir)
	elif define == SwDefine.CircuitPinType.WIRE:
		pinDefineBit = 0b10000
	pinConBit = pinConBit | (1<<pinDir)
	
func setPinValue(pinDir:SwDefine.SW_Dir,value:SwDefine.CircuitSignal) -> void:
	if value == SwDefine.CircuitSignal.HIGH:
		pinValueBit = pinValueBit & (1<<(3-pinDir))
	elif value == SwDefine.CircuitSignal.LOW or value == SwDefine.CircuitSignal.NONE:
		pinValueBit = pinValueBit & (0b11111-(1<<(3-pinDir)))

func isPort(value:int) -> bool:
	value = posmod(value-buildRef.rotation,4)
	return pinConBit&(1<<value) > 0

func portIsOutput(value:int) -> bool:
	var newValue = posmod(value - buildRef.rotation, 4)
	if not isPort(value):
		return false
	if pinDefineBit >= 16:
		return true
	return pinDefineBit&(1<<newValue) > 0
	
func portIsInput(value:int) -> bool:
	var newValue = posmod(value - buildRef.rotation, 4)
	if not isPort(value):
		return false
	if pinDefineBit >= 16:
		return true
	return pinDefineBit&(1<<newValue) == 0

func isLinkedPort(dir:SwDefine.SW_Dir) -> bool:
	var newValue = posmod(dir - buildRef.rotation, 4)
	return (linkedPort&(1<<newValue)) > 0

func setLinkedPort(dir:SwDefine.SW_Dir) -> void:
	var newValue = posmod(dir - buildRef.rotation, 4)
	linkedPort|=(1<<newValue)
	
func resetPortState() -> void:
	linkedPort = 0
	pinNetMap = {}
	pinExprMap = {}
	_buildingExpr = false

func getWireGroupBuilds(swBuildManager:SWBuildManager,wireBuild:SWBuildItemDefine,srcDir:SwDefine.SW_Dir) -> Array:
	var wireGroup:Array = []
	var visited:Dictionary[Vector2i,bool] = {}
	var wireBuildQueue:Array = [{"build":wireBuild,"dir":srcDir}]
	wireGroup.append({"build":wireBuild,"dir":srcDir})
	visited[wireBuild.buildAxisPos] = true
	while wireBuildQueue.size() > 0:
		var wireBuildItem = wireBuildQueue.pop_back()
		var wBuild:SWBuildItemDefine = wireBuildItem["build"]
		var dir = wireBuildItem["dir"]
		var neiBuilds = wBuild.getCircuitCompoent().getBuildIOConnectBuildArr(swBuildManager)
		for neiBuildItem:Dictionary in neiBuilds:
			var neiBuild = neiBuildItem["build"]
			var neiDir = neiBuildItem["dir"]
			if not SwCommon.IsWireBuild(neiBuild):
				continue
			if wBuild is SWBuildWireCross:
				if neiDir != dir and neiDir != SwDefine.getAntiDir(dir):
					continue
			if visited.has(neiBuild.buildAxisPos):
				continue
			visited[neiBuild.buildAxisPos] = true
			
			wireBuildQueue.append({"build":neiBuild,"dir":neiDir})
			wireGroup.append({"build":neiBuild,"dir":neiDir})
	return wireGroup

func reCalSignals() -> Array[SWBuildItemDefine]:
	var retArr:Array[SWBuildItemDefine] = [buildRef]
	for dir in 4:
		if not portIsInput(dir):
			continue
		var net:SWNet = pinNetMap.get(dir,null)
		if net:
			retArr.append_array(net.wireGroup.wireBuilds.keys())
	return retArr

func initPortState(swBuildManager:SWBuildManager) -> void:
	pass

# ─── m×n 多格建筑引脚边缘探测辅助函数 ───

## 判断当前建筑是否为多格建筑（size 非 1×1）
func _isMultiCell() -> bool:
	return buildRef.buildDefine.size.x > 1 or buildRef.buildDefine.size.y > 1

## 按世界方向查找引脚定义（遍历 build_pin，O(pins)）
func _getPinByWorldDir(worldDir:SwDefine.SW_Dir) -> SWBuildPinDefine:
	for pin:SWBuildPinDefine in buildRef.buildDefine.build_pin:
		var wdir:int = posmod(pin.pin_dir + buildRef.rotation, 4)
		if wdir == worldDir:
			return pin
	return null

## 从引脚格出发查找邻居建筑（m×n 专用）
func _getDirBuildFromPin(swBuildManager:SWBuildManager, pin:SWBuildPinDefine) -> SWBuildItemDefine:
	var rotatedOffset:Vector2i = buildRef.getRotatedCellOffset(pin)
	var pinCell:Vector2i = buildRef.buildAxisPos + rotatedOffset * SwDefine.GRID_SIZE
	var worldDir:int = posmod(pin.pin_dir + buildRef.rotation, 4)
	var neighborPos:Vector2i = pinCell + SwDefine.dir_to_vec(worldDir) * SwDefine.GRID_SIZE
	var nextBuild:SWBuildItemDefine = swBuildManager.getBuild(neighborPos)
	if nextBuild == null or nextBuild.bIsToBeRemoved():
		return null
	var nextCircuitCom:SWBuildCompoentCircuit = nextBuild.getCircuitCompoent()
	if nextCircuitCom == null:
		return null
	var antiDir:SwDefine.SW_Dir = SwDefine.getAntiDir(worldDir)
	# 邻居是 m×n 建筑时，需确认对方在该格有对应方向的引脚
	if nextBuild.buildDefine.size.x > 1 or nextBuild.buildDefine.size.y > 1:
		if not nextBuild.hasPinAt(neighborPos, antiDir):
			return null
	if not nextCircuitCom.isPort(antiDir):
		return null
	# 电线走特殊规则（电线始终 1×1，无需多格判定）
	if SwCommon.IsWireBuild(buildRef) or SwCommon.IsWireBuild(nextBuild):
		return nextBuild
	if portIsOutput(worldDir) and nextCircuitCom.portIsInput(antiDir):
		return nextBuild
	if portIsInput(worldDir) and nextCircuitCom.portIsOutput(antiDir):
		return nextBuild
	return null

## 查询该建筑在指定世界格是否有引脚且方向为 worldDir
## 用于 m×n 邻居连接判定
func hasPinAt(worldCell:Vector2i, worldDir:SwDefine.SW_Dir) -> bool:
	for pin:SWBuildPinDefine in buildRef.buildDefine.build_pin:
		var rotatedOffset:Vector2i = buildRef.getRotatedCellOffset(pin)
		var pinWorldCell:Vector2i = buildRef.buildAxisPos + rotatedOffset * SwDefine.GRID_SIZE
		if pinWorldCell != worldCell:
			continue
		var pinWorldDir:int = posmod(pin.pin_dir + buildRef.rotation, 4)
		if pinWorldDir == worldDir:
			return true
	return false
