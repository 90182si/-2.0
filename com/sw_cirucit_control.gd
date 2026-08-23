class_name SWCircuitControl extends Node


var buildManager:SWBuildManager = null
var idling:bool = false
var circuits:Dictionary[int,SWDefine.SWCircuitData] = {}
var linkedMap = {}
var linkedMaps = {}
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
			
	#根据linkedMap，将每个元件的来源替换为信号源头，如按钮->非门、非门->led，转换为按钮->led
	linkedMaps = {}
	resolveLinkedMapToSources()
	
	#改为depends模式
	#第一个wire创建一个cir，后续置在旁边的wire继承这个cir，组成一个wire组，信号值从cir中取，不从每个wire取
	for mapKey in linkedMaps.keys():
		var cir:SWDefine.SWCircuitData = SWDefine.SWCircuitData.new()
		var values = linkedMaps[mapKey]
		if not cir.signalMaps.has(mapKey):
			cir.signalMaps[mapKey] = {}
		for value in values:
			cir.signalMaps[mapKey][value["to"]]=value
		#cir.signalMaps[mapKey].append_array(values)
		for value in values:
			if not cir.signalAntiMaps.has(value["to"]):
				cir.signalAntiMaps[value["to"]] = []
			cir.signalAntiMaps[value["to"]].append(mapKey)
		circuits[cir.circuitID] = cir
		var from_build:SWBuildItemDefine = buildManager.getBuildById(mapKey)
		if from_build.comp_type == SWDefine.CircuitComponentType.BUTTON or \
			from_build.comp_type == SWDefine.CircuitComponentType.SWITCH:
				cir.signalValues[mapKey] = 0
				pass
		for value in values:
			var to_build:SWBuildItemDefine = buildManager.getBuildById(value["to"])
			if from_build and to_build:
				from_build.circuit = cir
				to_build.circuit = cir
				cir.buildIdArr.append(value["to"])
			pass
		#var to_build:SWBuildItemDefine = buildManager.getBuildById(value["to"])
		#if from_build and to_build:
			#from_build.circuit = cir
			#to_build.circuit = cir
	return false
	
#清空关联电路里所有建筑物的电路索引
func clearRelatedCircuitAllBuildingIndices(circuit:SWDefine.SWCircuitData) -> void:
	if not buildManager:
		return
	for buildID:int in circuit.buildIdArr:
		var build = buildManager.getBuildById(buildID)
		if build:
			build.resetPortCon()
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

#判断是否为信号源头（按钮/开关）
func _is_source_component(comp_type:int) -> bool:
	return comp_type == SWDefine.CircuitComponentType.BUTTON or \
		   comp_type == SWDefine.CircuitComponentType.SWITCH

#判断是否为中间元件（非源头、非终端，仅传递信号）
func _is_intermediate_component(comp_type:int) -> bool:
	return not _is_source_component(comp_type) and comp_type != SWDefine.CircuitComponentType.LED

#组合信号类型：'=' + '=' = '=', '=' + '!' = '!', '!' + '!' = '='
func _combine_signal(existing_signal:String, new_signal:String) -> String:
	if new_signal == "=":
		return existing_signal
	elif new_signal == "!":
		return "!" if existing_signal == "=" else "="
	return existing_signal

#根据linkedMap，将每个元件的来源替换为信号源头
#如：按钮->非门、非门->led 转换为 按钮->led
func resolveLinkedMapToSources() -> void:
	if linkedMap.is_empty():
		return
	linkedMaps = {}
	#步骤1: 构建反向查找表 - 从目标ID找到对应的linkedMap条目
	# to_id -> [{"from_key": key, "from_id": id, "signal": signal}, ...]
	var to_lookup:Dictionary[int,Array] = {}
	for key in linkedMap.keys():
		var val:Dictionary = linkedMap[key]
		var to_id:int = val["to"]
		if not to_lookup.has(to_id):
			to_lookup[to_id] = []
		to_lookup[to_id].append({"from_key": key, "from_id": key["from"], "signal": val["signal"]})
	
	#步骤2: 对每个条目，沿链路反向追溯到信号源头（按钮/开关）
	# 构建简化后的linkedMap，源头直达目标
	var simplifiedMap = {}
	for key in linkedMap.keys():
		var val:Dictionary = linkedMap[key]
		var dest_id:int = val["to"]
		var dest_name:String = val["name"]
		
		#从当前条目的信号源开始，沿链路反向追溯
		var current_id:int = key["from"]
		var combined_signal:String = val["signal"]
		var visited:Dictionary[int,bool] = {current_id: true}
		var resolved_source_id:int = current_id
		var resolved_source_name:String = key["name"]
		var resolved_source_dir = key["dir"]
		
		#反向追溯，直到找到信号源头或无法继续
		while not _is_source_component(buildManager.getBuildById(resolved_source_id).comp_type if buildManager.getBuildById(resolved_source_id) else -1):
			if not to_lookup.has(resolved_source_id):
				break
			var feeders:Array = to_lookup[resolved_source_id]
			if feeders.size() == 0:
				break
			#取第一个反馈源（通常只有一个输入）
			var feeder:Dictionary = feeders[0]
			if visited.has(feeder["from_id"]):
				break  #防止循环
			visited[feeder["from_id"]] = true
			combined_signal = _combine_signal(combined_signal, feeder["signal"])
			resolved_source_id = feeder["from_id"]
			var feeder_key:Dictionary = feeder["from_key"]
			resolved_source_name = feeder_key["name"]
			resolved_source_dir = feeder_key["dir"]
		
		#构建源头直达条目
		var new_key:Dictionary = {"from": resolved_source_id, "dir": resolved_source_dir, "name": resolved_source_name}
		var new_val:Dictionary = {"to": dest_id, "name": dest_name, "signal": combined_signal}
		#simplifiedMap[new_key] = new_val
		if not simplifiedMap.has(new_val):
			simplifiedMap[new_val] = []
		simplifiedMap[new_val].append(new_key)
	
	#步骤3: 移除中间元件的条目，只保留源头直达的条目
	# 源头直达 = from是BUTTON/SWITCH 或 to是LED
	# 中间元件（如非门）的from->to条目被清除
	var finalMap = {}
	for key in simplifiedMap.keys():
		var vals = simplifiedMap[key]
		for val in vals:
			var from_id:int = val["from"]
			var to_id:int = key["to"]
			var from_build:SWBuildItemDefine = buildManager.getBuildById(from_id)
			var to_build:SWBuildItemDefine = buildManager.getBuildById(to_id)
			var from_is_source:bool = from_build != null and _is_source_component(from_build.comp_type)
			#var to_is_led:bool = to_build != null and to_build.comp_type == SWDefine.CircuitComponentType.LED
			#只保留源头(BUTTON/SWITCH)发出 或 到达终端(LED)的条目
			#if from_is_source or to_is_led:
			if not finalMap.has(from_id):
				finalMap[from_id] = []
			finalMap[from_id].append(key)
	
	linkedMaps = finalMap

func buildSignalChanged(build:SWBuildItemDefine) -> Array[SWBuildItemDefine]:
	var buildPosArr:Array[SWBuildItemDefine] = []
	if build.circuit:
		for signalValue in build.circuit.signalMaps[build.id]:
			#var val = build.circuit.signalMaps[build.id][signalValue]
			var toBuild = buildManager.getBuildById(signalValue)
			if toBuild:
				# TODO:20260822.在circuit里面加一个antiMap
				#通知这个建筑物重新计算信号，
				toBuild.reCalSignals(buildManager)
				buildPosArr.append(toBuild)
	return buildPosArr
