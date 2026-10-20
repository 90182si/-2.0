class_name SWCircuitControl extends Node


var buildManager:SWBuildManager = null
var idling:bool = false
var circuits:Dictionary[int,SwDefine.SWCircuitData] = {}
var boolProgram: SWBoolProgram = null
var useIR: bool = false
#本轮重建内的邻接缓存：find1 与 createCircuit 共用，避免重复网格查询与临时对象分配
var _neighborsCache:Dictionary[SWBuildItemDefine,Array] = {}
#T2.2 netId 稳定分配：单调递增计数器，只在 clearAllBuilds / 加载存档时归零
var _netIdCounter: int = 0

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
				continue
			if not nextBuild.getCircuitCompoent().isPort(SwDefine.getAntiDir(dir)):
				build.getCircuitCompoent().pinNetMap[dir] = null
				
func getCircuit(builds:Array[SWBuildItemDefine]) -> void:
	#这里wire不用计算
	for build:SWBuildItemDefine in builds:
		build.getCircuitCompoent().getBuildExpr()
	#时序元件（寄存器）输入侧 CLK/D 表达式在根层级第二遍构建：
	#若在第一遍 DFS 内连带展开输入锥，从 Q 侧进入的外层组合元件会被反向递归命中，
	#把合法的时序反馈误判为组合环（in_loop 误标红）
	for build:SWBuildItemDefine in builds:
		build.getCircuitCompoent().buildInputExprs()

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
	for build:SWBuildItemDefine in builds:
		if not build.bIsToBeRemoved():
			build.getCircuitCompoent().reCalSignals()
		
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
	#查找受影的所有响建筑物
	var affectBuilds = find1(builds)
	#将这些受影响的建筑物关联的电路清空
	clearBuildsCircuitState(affectBuilds)
	#每个建筑物创建net
	createNets(affectBuilds)
	#T2.2：为本轮受影响的 net 分配唯一 netId（wireGroup 共享 SWNet，用 net 对象引用去重）
	_assignNetIds(affectBuilds)
	#对wire多余的net进行重置
	resetEmptyWireNet(affectBuilds)
	#方向构建依赖电路
	getCircuit(affectBuilds)
	var affectBuilds2:Array[SWBuildItemDefine] = []
	for affectBuild in affectBuilds:
		if not SwCommon.IsWireBuild(affectBuild):
			affectBuilds2.append(affectBuild)
	createCircuit(affectBuilds2)
	
	# --- T2.4: 组合环检测 + IR 编译 ---
	var affectedCircuits: Array = []
	for build in affectBuilds:
		if build.circuit != null and not affectedCircuits.has(build.circuit):
			affectedCircuits.append(build.circuit)
	#环检测基于 noticeMap（IR 无关），结果用于 in_loop 红点渲染，必须始终执行
	var loopBuilds := SWBoolCompiler.detect_combinational_loops(affectedCircuits)
	for lb in loopBuilds:
		lb.in_loop = true
	#IR 编译仅在 useIR 开启时执行；关闭时结果无人消费，跳过以免大存档/加载时白白浪费性能
	if useIR:
		var compiler := SWBoolCompiler.new()
		boolProgram = compiler.compile(affectedCircuits)
	
	return affectBuilds

#T2.2：遍历受影响建筑的 pinNetMap，为其中出现的每个 SWNet 分配递增 netId。
#- 累积递增，不每次 updateBuildCircuit 重置，避免增量更新时其他 net 编号漂移；
#- 超过 SWSignalTexture.MAX_NETS 会打警告并保持 -1，防止越界写入信号纹理。
func _assignNetIds(builds: Array[SWBuildItemDefine]) -> void:
	var seen: Dictionary = {}
	var max_nets: int = SWSignalTexture.MAX_NETS
	var overflow_warned: bool = false
	for b: SWBuildItemDefine in builds:
		if b == null:
			continue
		var comp: SWBuildCompoentCircuit = b.getCircuitCompoent()
		if comp == null:
			continue
		for net in comp.pinNetMap.values():
			if net == null or seen.has(net):
				continue
			seen[net] = true
			if _netIdCounter >= max_nets:
				if not overflow_warned:
					overflow_warned = true
					push_warning("[SWCircuitControl] netId 计数已达 SWSignalTexture.MAX_NETS=%d，后续 net 保持 netId=-1（信号纹理不再更新）。请清理建筑或扩容 MAX_NETS。" % max_nets)
				net.netId = -1
				continue
			net.netId = _netIdCounter
			_netIdCounter += 1

#T2.2：全量清理路径（clearAllBuilds / 加载存档）调用，把计数器归零。
func resetNetIdCounter() -> void:
	_netIdCounter = 0

func buildSignalChanged(build:SWBuildItemDefine) -> Array[SWBuildItemDefine]:
	SwCommon.NextEvalEpoch()
	var notifyPosArr:Array[SWBuildItemDefine] = []
	if not build.circuit:
		return notifyPosArr
	var cir = build.circuit
	#noticeMap现在只存直接依赖边，沿边级联展开传递闭包；
	#每个建筑本轮只处理一次，配合EvalStruct缓存总代价为O(下游规模)
	var queue:Array[SWBuildItemDefine] = [build]
	var processed:Dictionary[SWBuildItemDefine,bool] = {build:true}
	var head:int = 0
	while head < queue.size():
		var src:SWBuildItemDefine = queue[head]
		head += 1
		for noticeBuild:SWBuildItemDefine in cir.noticeMap.get(src,[]):
			if noticeBuild.buildDefine.circuit_component_type != SwDefine.CircuitComponentType.LED and noticeBuild.buildDefine.circuit_component_type != SwDefine.CircuitComponentType.ONE_BIT_REGISTER:
				continue
			if processed.has(noticeBuild):
				continue
			processed[noticeBuild] = true
			notifyPosArr.append_array(noticeBuild.getCircuitCompoent().reCalSignals())
			queue.append(noticeBuild)
	# T1.5: signalTex 增量更新 — 只写脏 texel，不触发几何层重算
	# T2.2: 用 netId 去重（每个 SWNet 唯一），避免同一 net 被多个引脚重复写入；
	#       netId 非法（<0 或 >=MAX_NETS）时直接跳过，绝不推进 paintedSignal，防止状态漂移。
	if SWSignalTexture.instance != null:
		var updated_nets: Dictionary = {}
		var max_nets: int = SWSignalTexture.MAX_NETS
		for affected_build: SWBuildItemDefine in processed.keys():
			var comp: SWBuildCompoentCircuit = affected_build.getCircuitCompoent()
			if comp == null:
				continue
			for dir in comp.pinNetMap:
				var net: SWNet = comp.pinNetMap[dir]
				if net == null:
					continue
				if net.netId < 0 or net.netId >= max_nets:
					continue
				if updated_nets.has(net.netId):
					continue
				updated_nets[net.netId] = true
				if net.curSignal != net.paintedSignal:
					var c: Color = SwCommon.get_net_display_color(net)
					SWSignalTexture.instance.set_net_color(net.netId, c)
					net.paintedSignal = net.curSignal
	return notifyPosArr
