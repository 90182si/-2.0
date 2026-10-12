class_name SWCircuitControl extends Node


var buildManager:SWBuildManager = null
var idling:bool = false
var circuits:Dictionary[int,SwDefine.SWCircuitData] = {}
#本轮重建内的邻接缓存：find1 与 createCircuit 共用，避免重复网格查询与临时对象分配
var _neighborsCache:Dictionary[SWBuildItemDefine,Array] = {}

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
#反馈环检测只会命中闭合环那一条边的net，环内其它电线不会被标记；
#此处按拓扑补标：若某in_loop元件的输入net的驱动元件也in_loop，则该net上的电线均处于环内
func markLoopWires(builds:Array[SWBuildItemDefine]) -> void:
	for build:SWBuildItemDefine in builds:
		if not build.in_loop:
			continue
		if SwCommon.IsWireBuild(build):
			continue
		var cirComp := build.getCircuitCompoent()
		for dir in cirComp.pinNetMap.keys():
			if not cirComp.portIsInput(dir):
				continue
			var net:SWNet = cirComp.pinNetMap[dir]
			if net == null:
				continue
			var driverInLoop:bool = false
			for driver:Dictionary in net.getDrivers():
				var driverBuild = driver.get("build",null)
				if driverBuild != null and driverBuild.in_loop:
					driverInLoop = true
					break
			if not driverInLoop:
				continue
			if net.wireGroup == null:
				continue
			for wireBuild:SWBuildItemDefine in net.wireGroup.wireBuilds.keys():
				wireBuild.in_loop = true
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
	#对wire多余的net进行重置
	resetEmptyWireNet(affectBuilds)
	#方向构建依赖电路
	getCircuit(affectBuilds)
	markLoopWires(affectBuilds)
	var affectBuilds2:Array[SWBuildItemDefine] = []
	for affectBuild in affectBuilds:
		if not SwCommon.IsWireBuild(affectBuild):
			affectBuilds2.append(affectBuild)
	createCircuit(affectBuilds2)
	
	return affectBuilds
	
func buildSignalChanged(build:SWBuildItemDefine) -> Array[SWBuildItemDefine]:
	#SwCommon.NextEvalEpoch()
	#var notifyPosArr:Array[SWBuildItemDefine] = []
	#if build.circuit:
		#var cir = build.circuit
		#for noticeBuild:SWBuildItemDefine in cir.noticeMap.get(build,[]):
			#notifyPosArr.append_array(noticeBuild.reCalSignals())
	#return notifyPosArr
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
			if processed.has(noticeBuild):
				continue
			processed[noticeBuild] = true
			notifyPosArr.append_array(noticeBuild.getCircuitCompoent().reCalSignals())
			queue.append(noticeBuild)
	return notifyPosArr
