class_name SWCircuitControl extends Node


var buildManager:SWBuildManager = null
var idling:bool = false
var circuits:Dictionary[int,SWDefine.SWCircuitData] = {}
var linkedMap = {}
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
#更新某些建筑物相关的电路
#1.查找可以与这些建筑物相连的电路
#2.统计需要更新的电路，找到输入源头，重新计算bfs连接图
#3.全部计算完毕后，再开始生成卡诺图
func updateBuildCircuit(builds:Array[SWBuildItemDefine])->bool:
	if not buildManager:
		return false
	if idling == true:
		return false
		
	var forDelDict:Dictionary[SWDefine.SWCircuitData,bool] = {}
	var input_build_com:Array[SWBuildItemDefine] = []
	for build:SWBuildItemDefine in builds:
		if build.comp_type == SWDefine.CircuitComponentType.BUTTON or \
			build.comp_type == SWDefine.CircuitComponentType.SWITCH:
			input_build_com.append(build)
		#找到与这些建筑相连的建筑物
		var ioConBuild:Array[SWBuildItemDefine] = build.getBuildIOConnectBuildArr(buildManager)
		#统计受影响的电路
		for conBuild:SWBuildItemDefine in ioConBuild:
			var circuit:SWDefine.SWCircuitData = conBuild.circuit
			if circuit != null:
				forDelDict[circuit] = true
			input_build_com.append(conBuild)
	#对受影响的电路进行清空
	for circuit in forDelDict.keys():
		clearRelatedCircuitAllBuildingIndices(circuit)
		circuits.erase(circuit.circuitID)
		
	#重建电路
	while input_build_com.size() > 0:
		var inputBuild:SWBuildItemDefine = input_build_com.pop_back()
		var conMap:Array[SWBuildItemDefine] = findConnectBuildsMaps(inputBuild)
		for build in conMap:
			input_build_com.append(build)
			
	
	
	return false
	
#清空关联电路里所有建筑物的电路索引
func clearRelatedCircuitAllBuildingIndices(circuit:SWDefine.SWCircuitData) -> void:
	if not buildManager:
		return
	for buildID:int in circuit.buildIdArr:
		var build = buildManager.getBuildById(buildID)
		if build:
			build.linkedID.clear()
			build.circuit = null

#从该建筑物开始获取整个传播路径
func findConnectBuildsMaps(srcBuild:SWBuildItemDefine) -> Array[SWBuildItemDefine]:
	var builds:Array[SWBuildItemDefine] = []
	var signalTransMap:Array = srcBuild.getLinkedBuilds(buildManager)
	linkedMap.merge(signalTransMap[1])
	for build:SWBuildItemDefine in signalTransMap[0]:
		builds.append(build)
	return builds
