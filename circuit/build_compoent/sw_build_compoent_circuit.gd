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

#世界方向的端口掩码：bit(dir)=1 表示该方向是输出/输入口。
#求值热点只读这两个 int 并做位判断，不再对每个方向跑 posmod 判定
var outDirMask:int = 0
var inDirMask:int = 0
var _dirMaskValid:bool = false
#按世界方向直接索引的端口 net 表（扁平缓存）：热点里 array[dir] 取代 pinNetMap 的 hash 查询
var outNets:Array = [null, null, null, null]
var inNets:Array = [null, null, null, null]
#本轮是否已求值：用 int 轮次代替 Dictionary 去重，级联队列里省掉一次 hash
var evalMark:int = -1
#本轮求值结果（0/1）：每个元件每轮只求值一次，下游回读直接取缓存
var evalOut:int = 0
#本轮是否至少求值过一次（重建电路时给「源到不了的元件」补初值用）
var seenMark:int = -1

func refreshDirMasks() -> void:
	if _dirMaskValid:
		return
	_dirMaskValid = true
	outDirMask = 0
	inDirMask = 0
	for d in 4:
		if portIsOutput(d):
			outDirMask |= 1 << d
		elif portIsInput(d):
			inDirMask |= 1 << d
		var net:SWNet = pinNetMap.get(d, null)
		outNets[d] = net
		inNets[d] = net

func invalidateDirMasks() -> void:
	_dirMaskValid = false

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
	_dirMaskValid = false
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
	_dirMaskValid = false

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

#元件自身求值后的可见变化（换图集帧/刷新状态）。
#调用方固定把该建筑记入本轮的脏列表，具体组件只负责刷新自身，无需返回数组
func reCalSignals() -> void:
	pass

#一轮求值：刷新自身显示并返回输出电平（0/1）。
#子类覆盖它，把「读输入 → 更新显示 → 算输出」合成一次，热点里少一次 net 读取与一次虚调用
func evaluate() -> int:
	reCalSignals()
	return evalOutput()

#时序元件（寄存器等）：一轮里只能求值一次，且数据输入取本拍开始前的电平
#（见 SWNet.epochSignal），否则同拍内上游传播会改变它的采样值
func isStateful() -> bool:
	return false

#门输出电平（0/1）：只读输入 net 的当前电平，不再递归展开上游表达式
func evalOutput() -> int:
	return 0

#某方向所连 net 的电平（HIGH 记为 1）。
#按源输入解析：上游驱动门在本轮内会先算好，读到的永远不是中间电平
func netBit(dir:SwDefine.SW_Dir) -> int:
	if not _dirMaskValid:
		refreshDirMasks()
	var net:SWNet = inNets[dir]
	if net == null:
		return 0
	#本轮已解析过就直接读缓存，热点里省掉 signalNow → resolveNetSignal 两次脚本调用
	var cc:SWCircuitControl = net.circuit
	if cc != null and net.sigEpoch != cc._curEpoch:
		cc.resolveNetSignal(net)
	return 1 if net.curSignal == SwDefine.CircuitSignal.HIGH else 0

func initPortState(swBuildManager:SWBuildManager) -> void:
	pass
