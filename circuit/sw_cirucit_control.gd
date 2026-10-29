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

# find1 的分批累加态：读档时按区间多次调用，结果与一次调用完全一致
# （Dictionary 保持插入顺序，因此 Evaluation 对建筑顺序的敏感性不变）
var _find1BuildMap:Dictionary[SWBuildItemDefine,bool] = {}
var _find1Handled:Dictionary[SwDefine.SWCircuitData,bool] = {}
func find1(builds:Array[SWBuildItemDefine], from:int = 0, to:int = -1) -> Array[SWBuildItemDefine]:
	if to < 0 or to > builds.size():
		to = builds.size()
	for i in range(from, to):
		var build:SWBuildItemDefine = builds[i]
		var neiBuilds = getNeighborsCached(build)
		for neiBuildItem:Dictionary in neiBuilds:
			var neiBuild = neiBuildItem["build"]
			if neiBuild.circuit != null:
				if _find1Handled.has(neiBuild.circuit):
					continue
				_find1Handled[neiBuild.circuit] = true
				for cBuild in neiBuild.circuit.buildArr:
					if cBuild.buildState.state != SwDefine.BuildState.TO_BE_REMOVED:
						_find1BuildMap[cBuild] = true
			else:
				if neiBuild.buildState.state != SwDefine.BuildState.TO_BE_REMOVED:
					_find1BuildMap[neiBuild] = true
		if build.buildState.state != SwDefine.BuildState.TO_BE_REMOVED:
			_find1BuildMap[build] = true
	var retArr:Array[SWBuildItemDefine] = []
	if to >= builds.size():
		retArr.assign(_find1BuildMap.keys())
		_find1BuildMap.clear()
		_find1Handled.clear()
	return retArr

func clearBuildsCircuitState(builds:Array[SWBuildItemDefine]) -> void:
	var forDelCircuit:Dictionary = resetBuildCircuitState(builds)
	initBuildPortState(builds)
	dropCircuits(forDelCircuit)

# 只重置建筑自身的电路状态；返回需要从 circuits 表里删掉的旧电路
func resetBuildCircuitState(builds:Array[SWBuildItemDefine], from:int = 0, to:int = -1) -> Dictionary:
	if to < 0 or to > builds.size():
		to = builds.size()
	var forDelCircuit:Dictionary = {}
	for i in range(from, to):
		var build:SWBuildItemDefine = builds[i]
		build.resetBuildState()
		if build.circuit == null:
			continue
		forDelCircuit[build.circuit] = true
		build.circuit = null
	return forDelCircuit

# 各建筑重新初始化端口（连线类会按 wireGroup 重建 net）
func initBuildPortState(builds:Array[SWBuildItemDefine], from:int = 0, to:int = -1) -> void:
	if to < 0 or to > builds.size():
		to = builds.size()
	for i in range(from, to):
		builds[i].getCircuitCompoent().initPortState(buildManager)

func dropCircuits(forDelCircuit:Dictionary) -> void:
	for circuit:SwDefine.SWCircuitData in forDelCircuit.keys():
		circuits.erase(circuit.circuitID)

func createNets(builds:Array[SWBuildItemDefine], from:int = 0, to:int = -1) -> void:
	if to < 0 or to > builds.size():
		to = builds.size()
	for i in range(from, to):
		builds[i].getCircuitCompoent().getNet(buildManager)

func resetEmptyWireNet(builds:Array[SWBuildItemDefine], from:int = 0, to:int = -1) -> void:
	if to < 0 or to > builds.size():
		to = builds.size()
	for i in range(from, to):
		var build:SWBuildItemDefine = builds[i]
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
				
func getCircuit(builds:Array[SWBuildItemDefine], from:int = 0, to:int = -1) -> void:
	if to < 0 or to > builds.size():
		to = builds.size()
	#这里wire不用计算
	for i in range(from, to):
		builds[i].getCircuitCompoent().getBuildExpr()

func createCircuit(builds:Array[SWBuildItemDefine]) -> void:
	createCircuitRange(builds)
	evaluateCircuits(builds)

#给 [from,to) 里还没有 circuit 的建筑建电路分组（按区间分批时语义不变：
#已有 circuit 的建筑本来就会被跳过，分组结果只取决于遍历顺序）
func createCircuitRange(builds:Array[SWBuildItemDefine], from:int = 0, to:int = -1) -> void:
	if to < 0 or to > builds.size():
		to = builds.size()
	var buildQueue:Array[SWBuildItemDefine] = []
	for i in range(from, to):
		var buildOne:SWBuildItemDefine = builds[i]
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

func evaluateCircuits(builds:Array[SWBuildItemDefine]) -> void:
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
		
#一轮重建的公共前置：新求值轮次 + 清空上一轮的缓存/脏集
func prepareRebuild() -> void:
	#开启新的求值轮次，令上一轮的表达式缓存失效
	SwCommon.NextEvalEpoch()
	_neighborsCache.clear()
	#重建期由调用方按返回的建筑列表整体重绘，这里不保留 net 区块脏集
	_dirtyChunks.clear()
	_dirtyNets.clear()
	_find1BuildMap.clear()
	_find1Handled.clear()

func _filterNonWire(builds:Array[SWBuildItemDefine]) -> Array[SWBuildItemDefine]:
	var arr:Array[SWBuildItemDefine] = []
	for build in builds:
		if not SwCommon.IsWireBuild(build):
			arr.append(build)
	return arr

func updateBuildCircuit(builds:Array[SWBuildItemDefine])->Array[SWBuildItemDefine]:
	if not buildManager:
		return []
	if idling == true:
		return []
	if builds.is_empty():
		return []
	prepareRebuild()
	#查找受影的所有响建筑物
	var affectBuilds:Array[SWBuildItemDefine] = find1(builds)
	#将这些受影响的建筑物关联的电路清空
	clearBuildsCircuitState(affectBuilds)
	#每个建筑物创建net
	createNets(affectBuilds)
	#对wire多余的net进行重置
	resetEmptyWireNet(affectBuilds)
	#net 记录所属电路控制：求值时用它拉取源输入
	bindNetOwner(affectBuilds)
	#方向构建依赖电路
	getCircuit(affectBuilds)
	createCircuit(_filterNonWire(affectBuilds))

	return affectBuilds

#读档专用：阶段顺序与 updateBuildCircuit 完全一致（加载结果对建筑遍历顺序敏感，
#不能跳步也不能重排），只是按时间预算分帧，每批之间让出主线程。
#on_stage.call(stage:int, percent:float)；stage 0..8。
#单批预算：太小会让每帧的等待时间占满（读档总时长翻倍），太大则卡顿明显。
const STAGED_BUDGET_USEC:int = 50000
#预算的最细粒度（每次进 fn 的建筑数），避免单个超慢批次把预算撑破太多
#（重建端口阶段单建筑可达数百微秒，粒度要小才能守住 50ms 预算）
const STAGED_STEP:int = 64
func updateBuildCircuitStaged(builds:Array[SWBuildItemDefine], tree:SceneTree, on_stage:Callable,
		budget_usec:int = STAGED_BUDGET_USEC, step:int = STAGED_STEP) -> Array[SWBuildItemDefine]:
	if not buildManager or idling or builds.is_empty():
		return []
	prepareRebuild()
	var total:int = builds.size()
	# 1) find1：邻居扩展（累加态，最后一次调用才产出结果）
	var affectBuilds:Array[SWBuildItemDefine] = []
	var i:int = 0
	while i < total:
		var t0:int = Time.get_ticks_usec()
		while i < total:
			var next:int = mini(i + step, total)
			var res:Array[SWBuildItemDefine] = find1(builds, i, next)
			i = next
			if i >= total:
				affectBuilds = res
			if Time.get_ticks_usec() - t0 >= budget_usec:
				break
		on_stage.call(0, float(i) / float(total))
		if i >= total:
			break
		await tree.process_frame
	var affectTotal:int = affectBuilds.size()
	if affectTotal == 0:
		return affectBuilds
	# 2) 重置建筑电路状态
	var forDelCircuit:Dictionary = {}
	await _staged_range(func(from:int, to:int) -> void:
		var part:Dictionary = resetBuildCircuitState(affectBuilds, from, to)
		for c in part:
			forDelCircuit[c] = true, affectTotal, 1, tree, on_stage, budget_usec, step)
	# 3) 重建端口
	await _staged_range(func(from:int, to:int) -> void:
		initBuildPortState(affectBuilds, from, to), affectTotal, 2, tree, on_stage, budget_usec, step)
	dropCircuits(forDelCircuit)
	# 4) 建立 net
	await _staged_range(func(from:int, to:int) -> void:
		createNets(affectBuilds, from, to), affectTotal, 3, tree, on_stage, budget_usec, step)
	# 5) 清理空 net
	await _staged_range(func(from:int, to:int) -> void:
		resetEmptyWireNet(affectBuilds, from, to), affectTotal, 4, tree, on_stage, budget_usec, step)
	# 6) net 挂回电路控制
	await _staged_range(func(from:int, to:int) -> void:
		bindNetOwner(affectBuilds, from, to), affectTotal, 5, tree, on_stage, budget_usec, step)
	# 7) 元件表达式
	await _staged_range(func(from:int, to:int) -> void:
		getCircuit(affectBuilds, from, to), affectTotal, 6, tree, on_stage, budget_usec, step)
	# 8) 电路分组
	var nonWire:Array[SWBuildItemDefine] = _filterNonWire(affectBuilds)
	await _staged_range(func(from:int, to:int) -> void:
		createCircuitRange(nonWire, from, to), nonWire.size(), 7, tree, on_stage, budget_usec, step)
	# 9) 首轮求值（整体一次，不切分：求值依赖完整拓扑）
	on_stage.call(8, 0.0)
	await tree.process_frame
	evaluateCircuits(nonWire)
	on_stage.call(8, 1.0)
	return affectBuilds

#按时间预算跑一个逐建筑阶段，超预算就报进度并让出主线程
func _staged_range(fn:Callable, total:int, stage:int, tree:SceneTree, on_stage:Callable,
		budget_usec:int = STAGED_BUDGET_USEC, step:int = STAGED_STEP) -> void:
	var i:int = 0
	while i < total:
		var t0:int = Time.get_ticks_usec()
		while i < total:
			var next:int = mini(i + step, total)
			fn.call(i, next)
			i = next
			if Time.get_ticks_usec() - t0 >= budget_usec:
				break
		on_stage.call(stage, float(i) / float(total))
		if i < total:
			await tree.process_frame
	
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
	#翻转戳：区块补丁按它判断本区块有哪些连线需要重染（不用逐帧累积 net 集合）
	SwCommon.netPatchStamp += 1
	net.patchStamp = SwCommon.netPatchStamp
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
		if _driverOut(comp) == 0:
			return 0
	return 1

#把电路控制挂到本轮所有 net 上：元件求值时经 net.signalNow() 拉取源输入
func bindNetOwner(builds:Array[SWBuildItemDefine], from:int = 0, to:int = -1) -> void:
	if to < 0 or to > builds.size():
		to = builds.size()
	for i in range(from, to):
		var build:SWBuildItemDefine = builds[i]
		var comp:SWBuildCompoentCircuit = build.getCircuitCompoent()
		if comp == null:
			continue
		for net in comp.pinNetMap.values():
			if net != null:
				net.circuit = self
