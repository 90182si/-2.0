class_name SWCircuitControl extends Node


var buildManager:SWBuildManager = null
var idling:bool = false
var circuits:Dictionary[int,SWDefine.SWCircuitData] = {}

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
func find1(builds:Array[SWBuildItemDefine]) -> Array[SWBuildItemDefine]:
	var retArr:Array[SWBuildItemDefine] = []
	var buildMap:Dictionary[SWBuildItemDefine,bool] = {}
	for build:SWBuildItemDefine in builds:
		var neiBuilds = build.getBuildIOConnectBuildArr(buildManager)
		for neiBuildItem:Dictionary in neiBuilds:
			var neiBuild = neiBuildItem["build"]
			if neiBuild.circuit != null:
				for cBuild in neiBuild.circuit.buildArr:
					if cBuild.innerData.state != SWDefine.BuildState.TO_BE_REMOVED:
						buildMap[cBuild] = true
			else:
				if neiBuild.innerData.state != SWDefine.BuildState.TO_BE_REMOVED:
					buildMap[neiBuild] = true
		if build.innerData.state != SWDefine.BuildState.TO_BE_REMOVED:
			buildMap[build] = true
	retArr = buildMap.keys()
	return retArr
func clearBuildsCircuitState(builds:Array[SWBuildItemDefine]) -> void:
	var forDelCircuit:Dictionary = {}
	for build:SWBuildItemDefine in builds:
		build.resetPortState(buildManager)
		if build.circuit == null:
			continue
		forDelCircuit[build.circuit] = true
		build.circuit = null
	for build:SWBuildItemDefine in builds:
		build.initPortState(buildManager)
	for circuit:SWDefine.SWCircuitData in forDelCircuit.keys():
		circuits.erase(circuit.circuitID)
func createNets(builds:Array[SWBuildItemDefine]) -> void:
	for build:SWBuildItemDefine in builds:
		build.getNet(buildManager)
func getCircuit(builds:Array[SWBuildItemDefine]) -> void:
	#这里wire不用计算
	for build:SWBuildItemDefine in builds:
		build.getBuildExpr()
func createCircuit(builds:Array[SWBuildItemDefine]) -> void:
	var buildQueue:Array[SWBuildItemDefine] = []
	var visited:Dictionary[SWBuildItemDefine,bool] = {}
	var circuitBuildsGroup:Dictionary = {}
	
	#90182si 20260919  builds是去掉了wire类型的build
	#90182si 在判断是否是一个circuit的时候再添加wire
	for buildOne in builds:
		if buildOne.circuit != null:
			continue
		buildQueue.append(buildOne)
		while buildQueue.size() > 0:
			var build:SWBuildItemDefine = buildQueue.pop_back()
			if build.circuit != null:
				continue
			if visited.has(build):
				continue
			visited[build] = true
			var neiBuilds = build.getBuildIOConnectBuildArr(buildManager)
			for neiBuildItem:Dictionary in neiBuilds:
				var dir = neiBuildItem["dir"]
				var neiBuild:SWBuildItemDefine = neiBuildItem["build"]
				if not SwCommon.IsWireBuild(neiBuild):
					continue
				var circuit = neiBuild.getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
				if circuit:
					var net:SWNet = circuit.pinNetMap[dir]
					for wireBuild in net.wireGroup.wireBuilds.keys():
						visited[wireBuild] = true
					for nextBuildItem in net.getLoads():
						var nextBuild = nextBuildItem["build"]
						buildQueue.append(nextBuild)
			for neiBuildItem:Dictionary in neiBuilds:
				var neiBuild = neiBuildItem["build"]
				if visited.has(neiBuild):
					continue
				#if SwCommon.IsWireBuild(neiBuild):
					#continue
				#visited[neiBuild] = true
				buildQueue.append(neiBuild)
		var buildGroup = visited.keys()
		var cir:SWDefine.SWCircuitData = SWDefine.SWCircuitData.new()
		cir.buildArr = buildGroup
		for build:SWBuildItemDefine in buildGroup:
			build.circuit = cir
			if build.comp_type != SWDefine.CircuitComponentType.BUTTON and build.comp_type != SWDefine.CircuitComponentType.SWITCH:
				var cirComp := build.getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
				var dependBuildIds = cirComp.getDependBuildIds()
				#print(build.buildDefine.buildName+"的dependIds是"+str(dependBuildIds))
				for id in dependBuildIds:
					var depBuild = buildManager.getBuildById(id)
					if not depBuild:
						continue
					if not cir.noticeMap.has(depBuild):
						cir.noticeMap[depBuild] = []
					cir.noticeMap[depBuild].append(build)
	for build:SWBuildItemDefine in builds:
		if not build.bIsToBeRemoved():
			build.reCalSignals()
		
func updateBuildCircuit(builds:Array[SWBuildItemDefine])->Array[SWBuildItemDefine]:
	if not buildManager:
		return []
	if idling == true:
		return []
	if builds.is_empty():
		return []
	#查找受影的所有响建筑物
	var affectBuilds = find1(builds)
	#将这些受影响的建筑物关联的电路清空
	clearBuildsCircuitState(affectBuilds)
	#每个建筑物创建net
	createNets(affectBuilds)
	#获取网络终点建筑物
	#var endBuilds = getNetEndBuilds(affectBuilds)
	#方向构建依赖电路
	getCircuit(affectBuilds)
	
	var affectBuilds2:Array[SWBuildItemDefine] = []
	for affectBuild in affectBuilds:
		if not SwCommon.IsWireBuild(affectBuild):
			affectBuilds2.append(affectBuild)
	createCircuit(affectBuilds2)
	
	return affectBuilds
	
func buildSignalChanged(build:SWBuildItemDefine) -> Array[SWBuildItemDefine]:
	var notifyPosArr:Array[SWBuildItemDefine] = []
	if build.circuit:
		var cir = build.circuit
		for noticeBuild:SWBuildItemDefine in cir.noticeMap.get(build,[]):
			notifyPosArr.append_array(noticeBuild.reCalSignals())
	return notifyPosArr
