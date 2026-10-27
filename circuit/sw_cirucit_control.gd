class_name SWCircuitControl extends Node


var buildManager:SWBuildManager = null
var idling:bool = false
var circuits:Dictionary[int,SwDefine.SWCircuitData] = {}
#本轮重建内的邻接缓存：find1 与 createCircuit 共用，避免重复网格查询与临时对象分配
var _neighborsCache:Dictionary[SWBuildItemDefine,Array] = {}
#本轮电平翻转的 net 所覆盖的区块；由调度方取走并合并进重绘列表
var _dirtyChunks:Dictionary[Vector2i,bool] = {}
#本轮翻电平的 net：渲染端按「net -> 实例颜色列」的预摊平索引批量换色，
#比逐根连线调用脚本补丁快一个数量级（连线数量是门的十几倍）
var _dirtyNets:Dictionary[SWNet,bool] = {}
#当前求值轮次：热点里用成员读代替跨类静态访问
var _curEpoch:int = 0

#开始放置建筑物
func beginIdle()->void:
	idling = true
	pass
	
#停止放置建筑物
func endIdle()->void:
	idling = false
	pass
	
func setBuildManager(bManager:SWBuildManager) -> void:
	buildManager = bManager

#有两种情况：
#每次放置一个建筑物，上下左右端口相连的建筑物都需要重新计算
#1.某侧建筑物有circuit，直接从circuit获取所有建筑物
#2.某侧建筑物没有circuit，但是隔着这个建筑物还有建筑物，如何获取？
#总结：不管有没有circuit，都需要加入到retArr,有circuit就把circuit里面所有建筑物加进去，没有就不加
func getNeighborsCached(build:SWBuildItemDefine) -> Array:
	if not _neighborsCache.has(build):
		_neighborsCache[build] = build.getCircuitCompoent().getBuildIOConnectBuildArr(buildManager)
	return _neighborsCache[build]
func find1(builds:Array[SWBuildItemDefine]) -> Array[SWBuildItemDefine]:
	var retArr:Array[SWBuildItemDefine] = []
	var buildMap:Dictionary[SWBuildItemDefine,bool] = {}
	#同一旧电路只展开一次，避免多个新建筑触碰同一电路时重复扫描整表
	var handledCircuits:Dictionary[SwDefine.SWCircuitData,bool] = {}
	for build:SWBuildItemDefine in builds:
		var neiBuilds = getNeighborsCached(build)
		for neiBuildItem:Dictionary in neiBuilds:
			var neiBuild = neiBuildItem["build"]
			if neiBuild.circuit != null:
				if handledCircuits.has(neiBuild.circuit):
					continue
				handledCircuits[neiBuild.circuit] = true
				for cBuild in neiBuild.circuit.buildArr:
					if cBuild.buildState.state != SwDefine.BuildState.TO_BE_REMOVED:
						buildMap[cBuild] = true
			else:
				if neiBuild.buildState.state != SwDefine.BuildState.TO_BE_REMOVED:
					buildMap[neiBuild] = true
		if build.buildState.state != SwDefine.BuildState.TO_BE_REMOVED:
			buildMap[build] = true
	retArr = buildMap.keys()
	return retArr
func clearBuildsCircuitState(builds:Array[SWBuildItemDefine]) -> void:
	var forDelCircuit:Dictionary = {}
	for build:SWBuildItemDefine in builds:
		build.resetBuildState()
		if build.circuit == null:
			continue
		forDelCircuit[build.circuit] = true
		build.circuit = null
	for build:SWBuildItemDefine in builds:
		build.getCircuitCompoent().initPortState(buildManager)
	for circuit:SwDefine.SWCircuitData in forDelCircuit.keys():
		circuits.erase(circuit.circuitID)
func createNets(builds:Array[SWBuildItemDefine]) -> void:
	for build:SWBuildItemDefine in builds:
		build.getCircuitCompoent().getNet(buildManager)
func resetEmptyWireNet(builds:Array[SWBuildItemDefine]) -> void:
	for build:SWBuildItemDefine in builds:
		if build.buildDefine.circuit_component_type != SwDefine.CircuitComponentType.WIRE:
			continue
		for dir in 4:
			var nextBuild = build.getDirBuild(buildManager,dir)
			if not nextBuild:
				build.getCircuitCompoent().pinNetMap[dir] = null
				build.getCircuitCompoent().invalidateDirMasks()
				continue
			if not nextBuild.getCircuitCompoent().isPort(SwDefine.getAntiDir(dir)):
				build.getCircuitCompoent().pinNetMap[dir] = null
				build.getCircuitCompoent().invalidateDirMasks()
				
func getCircuit(builds:Array[SWBuildItemDefine]) -> void:
	#这里wire不用计算
	for build:SWBuildItemDefine in builds:
		build.getCircuitCompoent().getBuildExpr()

func createCircuit(builds:Array[SWBuildItemDefine]) -> void:
	var buildQueue:Array[SWBuildItemDefine] = []
	for buildOne in builds:
		if buildOne.circuit != null:
			continue
		var visited:Dictionary[SWBuildItemDefine,bool] = {}
		buildQueue.append(buildOne)
		while buildQueue.size() > 0:
			var build:SWBuildItemDefine = buildQueue.pop_back()
			if build.circuit != null:
				continue
			if visited.has(build):
				continue
			visited[build] = true
			var neiBuilds = getNeighborsCached(build)
			for neiBuildItem:Dictionary in neiBuilds:
				var dir = neiBuildItem["dir"]
				var neiBuild:SWBuildItemDefine = neiBuildItem["build"]
				if not SwCommon.IsWireBuild(neiBuild):
					continue
				var circuit = neiBuild.getCircuitCompoent()
				if circuit:
					var net:SWNet = circuit.pinNetMap.get(dir,null)
					if not net:
						continue
					for wireBuild in net.wireGroup.wireBuilds.keys():
						visited[wireBuild] = true
					for nextBuildItem in net.getLoads():
						var nextBuild = nextBuildItem["build"]
						buildQueue.append(nextBuild)
					for driverBuildItem in net.getDrivers():
						var driverBuild = driverBuildItem["build"]
						if driverBuild == null or visited.has(driverBuild):
							continue
						buildQueue.append(driverBuild)
			for neiBuildItem:Dictionary in neiBuilds:
				var neiBuild = neiBuildItem["build"]
				if visited.has(neiBuild):
					continue
				buildQueue.append(neiBuild)
		var buildGroup = visited.keys()
		var cir:SwDefine.SWCircuitData = SwDefine.SWCircuitData.new()
		cir.buildArr = buildGroup
		for build:SWBuildItemDefine in buildGroup:
			build.circuit = cir
			if SwCommon.IsWireBuild(build):
				continue
			if build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.BUTTON or build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.SWITCH:
				continue
			var cirComp := build.getCircuitCompoent()
			var depSeen:Dictionary[SWBuildItemDefine,bool] = {}
			for dir in cirComp.pinNetMap.keys():
				if not build.getCircuitCompoent().portIsInput(dir):
					continue
				var net:SWNet = cirComp.pinNetMap[dir]
				if net == null:
					continue
				for driver:Dictionary in net.getDrivers():
					var depBuild = driver["build"]
					if depBuild == null or depBuild == build or depSeen.has(depBuild):
						continue
					depSeen[depBuild] = true
					if not cir.noticeMap.has(depBuild):
						cir.noticeMap[depBuild] = []
					cir.noticeMap[depBuild].append(build)
	#重建后的首轮求值：源先落一次，再让其余元件（浮空门、未接时钟的寄存器）各求值一次。
	#求值时按源输入递归解析上游，一轮足够，不需要反复跑到静止
	_curEpoch = SwCommon.evalEpoch
	_queue.clear()
	_collectingNotify = false
	for build:SWBuildItemDefine in builds:
		if build.bIsToBeRemoved() or SwCommon.IsWireBuild(build):
			continue
		var firstComp:SWBuildCompoentCircuit = build.getCircuitCompoent()
		firstComp.refreshDirMasks()
		if firstComp.inDirMask != 0:
			continue
		_compOut(firstComp)
	_drainQueue()
	for build:SWBuildItemDefine in builds:
		if build.bIsToBeRemoved():
			continue
		var comp:SWBuildCompoentCircuit = build.getCircuitCompoent()
		if comp.evalMark == _curEpoch:
			continue
		_compOut(comp)
	_drainQueue()

#一轮内每个元件只求值一次：求值时从源输入解析（见 resolveNetSignal），
#所以不需要反复迭代到收敛，也不会把中间电平发布出去（寄存器不会锁存毛刺）
var _queue:Array[SWBuildCompoentCircuit] = []
var _notify:Dictionary = {}
var _collectingNotify:bool = false
var _lastQueueSize:int = 0

func _compOut(comp:SWBuildCompoentCircuit) -> int:
	if comp.evalMark == _curEpoch:
		return comp.evalOut
	comp.evalMark = _curEpoch
	comp.seenMark = _curEpoch
	var prevOut:int = comp.evalOut
	var prevSig:int = comp.buildRef.signal_state
	#占位用上一轮电平：组合环回读自己的输出时看到的是上一轮值，不会形成无限递归
	comp.evalOut = prevOut
	comp.evalOut = comp.evaluate()
	#只有显示电平或输出电平真的变了才进入重绘列表，否则整块重绘会被无谓拉满
	if _collectingNotify and (comp.evalOut != prevOut or comp.buildRef.signal_state != prevSig):
		_notify[comp.buildRef] = true
	_publishComp(comp)
	return comp.evalOut

func _drainQueue() -> void:
	var head:int = 0
	while head < _queue.size():
		var comp:SWBuildCompoentCircuit = _queue[head]
		head += 1
		if comp.evalMark == _curEpoch:
			continue
		_compOut(comp)
	_lastQueueSize = head
	_queue.clear()

#时序元件没轮到求值前只回读已锁存电平：解析上游不能顺带触发锁存
func _driverOut(comp:SWBuildCompoentCircuit) -> int:
	if comp == null:
		return 1
	if comp.isStateful() and comp.evalMark != _curEpoch:
		return comp.evalOutput()
	return _compOut(comp)

#net 最终电平 = 所有驱动门输出的线与（无驱动为低）。
#按轮缓存：同一轮内重复读取不再重算驱动锥
func resolveNetSignal(net:SWNet) -> SwDefine.CircuitSignal:
	if net == null:
		return SwDefine.CircuitSignal.NONE
	if net.sigEpoch == _curEpoch:
		return net.curSignal
	if net.resolving:
		return net.curSignal
	net.resolving = true
	var v:int = _netSignal(net)
	net.resolving = false
	net.sigEpoch = _curEpoch
	var sig:SwDefine.CircuitSignal = SwDefine.CircuitSignal.HIGH if v == 1 else SwDefine.CircuitSignal.LOW
	_publishNetSignal(net, sig)
	return net.curSignal
		
func updateBuildCircuit(builds:Array[SWBuildItemDefine])->Array[SWBuildItemDefine]:
	if not buildManager:
		return []
	if idling == true:
		return []
	if builds.is_empty():
		return []
	#开启新的求值轮次，令上一轮的表达式缓存失效
	SwCommon.NextEvalEpoch()
	_neighborsCache.clear()
	#重建期由调用方按返回的建筑列表整体重绘，这里不保留 net 区块脏集
	_dirtyChunks.clear()
	_dirtyNets.clear()
	#查找受影的所有响建筑物
	var affectBuilds = find1(builds)
	#将这些受影响的建筑物关联的电路清空
	clearBuildsCircuitState(affectBuilds)
	#每个建筑物创建net
	createNets(affectBuilds)
	#对wire多余的net进行重置
	resetEmptyWireNet(affectBuilds)
	#net 记录所属电路控制：求值时用它拉取源输入
	_bindNetOwner(affectBuilds)
	#方向构建依赖电路
	getCircuit(affectBuilds)
	var affectBuilds2:Array[SWBuildItemDefine] = []
	for affectBuild in affectBuilds:
		if not SwCommon.IsWireBuild(affectBuild):
			affectBuilds2.append(affectBuild)
	createCircuit(affectBuilds2)
	
	return affectBuilds
	
func buildSignalChanged(build:SWBuildItemDefine) -> Array[SWBuildItemDefine]:
	var seeds:Array[SWBuildItemDefine] = [build]
	return buildSignalsChanged(seeds)

#一拍内多个源（多个时钟）合并到同一求值轮次。
#增量驱动：只有输入 net 在本轮翻过电平的门才需要重新求值，
#下游只沿「输出电平真的变了」的边继续展开，因此每拍代价是 O(真实变化的下游规模)。
func buildSignalsChanged(seeds:Array[SWBuildItemDefine]) -> Array[SWBuildItemDefine]:
	var epoch:int = SwCommon.NextEvalEpoch()
	_curEpoch = epoch
	_dirtyChunks.clear()
	_dirtyNets.clear()
	_notify.clear()
	_collectingNotify = true
	_queue.clear()
	for seed in seeds:
		if seed.circuit == null:
			continue
		var comp:SWBuildCompoentCircuit = seed.getCircuitCompoent()
		if comp.evalMark == epoch:
			continue
		_compOut(comp)
	_drainQueue()
	_collectingNotify = false
	SwCommon.dbgEvaluated = _notify.size()
	SwCommon.dbgQueue = _lastQueueSize
	var notifyArr:Array[SWBuildItemDefine] = []
	notifyArr.assign(_notify.keys())
	_notify.clear()
	return notifyArr

#把刚求出的输出电平写回该元件驱动的 net；电平真的变了才标脏连线并展开下游
func _publishComp(comp:SWBuildCompoentCircuit) -> void:
	if not comp._dirMaskValid:
		comp.refreshDirMasks()
	var mask:int = comp.outDirMask
	if mask == 0:
		return
	var nets:Array = comp.outNets
	if (mask & 1) != 0:
		_publishOutNet(nets[0], comp)
	if (mask & 2) != 0:
		_publishOutNet(nets[1], comp)
	if (mask & 4) != 0:
		_publishOutNet(nets[2], comp)
	if (mask & 8) != 0:
		_publishOutNet(nets[3], comp)

func _publishOutNet(net:SWNet, comp:SWBuildCompoentCircuit) -> void:
	if net == null:
		return
	#单驱动 net 直接用刚算出的电平（0/1）；多驱动 net 才需要重新做线与
	#注意 evalOut 是 0/1，net.curSignal 是 CircuitSignal（LOW=1/HIGH=2），不能混用
	var sig:SwDefine.CircuitSignal
	var drivers:Array = net._driverComps
	if drivers.size() == 1 and drivers[0] == comp:
		sig = SwDefine.CircuitSignal.HIGH if comp.evalOut == 1 else SwDefine.CircuitSignal.LOW
	else:
		sig = SwDefine.CircuitSignal.HIGH if _netSignal(net) == 1 else SwDefine.CircuitSignal.LOW
	net.sigEpoch = _curEpoch
	_publishNetSignal(net, sig)

func _publishNetSignal(net:SWNet, sig:SwDefine.CircuitSignal) -> void:
	if net.curSignal == sig:
		return
	#第一次翻转时记下本拍开始前的电平（时序元件的数据输入取它）
	if net.preEpoch != _curEpoch:
		net.preEpoch = _curEpoch
		net.preSignal = net.curSignal
	net.curSignal = sig
	net.changedEpoch = _curEpoch
	net.sigVersion += 1
	#连线颜色由 net 电平决定：把翻转的 net 交给渲染端批量换色
	#（门/灯/寄存器在上游求值里已进了 notify 列表，无需在这里逐根展开连线）
	_dirtyNets[net] = true
	#按覆盖区块标脏：真正需要重绘的区块集
	for cp:Vector2i in net.chunkPosArr:
		_dirtyChunks[cp] = true
	_queue.append_array(net._loadComps)

#取走本轮被翻转 net 标脏的区块（调用方负责合并去重）
func takeDirtyChunks() -> Array[Vector2i]:
	var arr:Array[Vector2i] = _dirtyChunks.keys()
	_dirtyChunks.clear()
	return arr

#取走本轮翻转的 net 集合（net -> true；连线换色的批量索引键）
func takeDirtyNets() -> Dictionary:
	var nets:Dictionary = _dirtyNets
	_dirtyNets = {}
	return nets

#net 电平 = 所有驱动门输出的线与（无驱动视为低），返回 0/1 电平。
#驱动门按源输入现算：时序元件只回读已锁存电平，组合元件按需递归解析
func _netSignal(net:SWNet) -> int:
	var comps:Array = net._driverComps
	if comps.is_empty():
		return 0
	for comp:SWBuildCompoentCircuit in comps:
		if comp == null:
			continue
		if _driverOut(comp) == 0:
			return 0
	return 1

#把电路控制挂到本轮所有 net 上：元件求值时经 net.signalNow() 拉取源输入
func _bindNetOwner(builds:Array) -> void:
	for build:SWBuildItemDefine in builds:
		var comp:SWBuildCompoentCircuit = build.getCircuitCompoent()
		if comp == null:
			continue
		for net in comp.pinNetMap.values():
			if net != null:
				net.circuit = self
