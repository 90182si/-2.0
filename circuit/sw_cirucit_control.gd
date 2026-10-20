class_name SWCircuitControl extends Node

# T2.5：组件求值后端无场景树访问路径，用静态当前实例交接（单一事实 owner 仍在本类）
static var current: SWCircuitControl = null

var buildManager:SWBuildManager = null
var idling:bool = false
var circuits:Dictionary[int,SwDefine.SWCircuitData] = {}
var boolProgram: SWBoolProgram = null
var useIR: bool = false
# T2.5：编译器实例跨批次复用（slot/指令全局递增），失活段靠 segments 剪除
var _compiler: SWBoolCompiler = null
# T2.5：getValue 切 slot 的查询表（key = build.id*4+dir → slot），直接引用编译器内部表
var slotMap: Dictionary = {}
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
		if _compiler == null:
			_compiler = SWBoolCompiler.new()
			slotMap = _compiler.slotMap
		boolProgram = _compiler.compile(affectedCircuits, circuits)
		# T2.5 初始化：编译后立即全量求值一遍，使 slot/输出 net 与当前世界状态一致；
		# 再走一次 push 把 OP_OUT 写回的 net 传播到电线视觉（与后续事件路径同源）
		boolProgram.evaluate()
		var pushBuilds: Array = []
		for cir: SwDefine.SWCircuitData in affectedCircuits:
			for b: SWBuildItemDefine in cir.buildArr:
				pushBuilds.append(b)
		_pushDriverNets(pushBuilds)
	
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

#T2.5：全量清理/加载时重置 IR 后端（程序/编译器/slotMap 一起作废，重建）
func resetIR() -> void:
	boolProgram = null
	_compiler = null
	slotMap = {}

# T2.5 push 核心：对每个处理过的建筑，取其作为驱动者的 net，
# 用驱动器 slot 新值与 net.curSignal 比较，变化时写回 net 并对 wireGroup 电线调 setValue（视觉传播）。
# 这取代了原 NOT/LED/源类组件 getValue 内的副作用传播（树路径 useIR=false 时仍保留旧行为）。
# 段重复求值幂等：同一电路多个处理建筑命中同一段时，重复 evaluate 结果不变。
func _pushDriverNets(builds: Array) -> void:
	if boolProgram == null:
		return
	# 收集本轮触及的 net（去重），逐 net 写回：
	# wired-AND 多驱动 net 的 curSignal 复刻树语义——最后一个注册驱动者的 getValue 最后写回者胜，
	# 即取 net.getDrivers() 中最后一个带 slot 的驱动者的 slot 值（树里各驱动者都写同一 net，末位覆盖前者）
	var touched: Dictionary = {}
	for b: SWBuildItemDefine in builds:
		if b == null or SwCommon.IsWireBuild(b):
			continue
		var comp: SWBuildCompoentCircuit = b.getCircuitCompoent()
		if comp == null:
			continue
		for dir in comp.pinNetMap:
			var net0: SWNet = comp.pinNetMap[dir]
			if net0 != null and not touched.has(net0):
				touched[net0] = true
	for net: SWNet in touched:
		var drivers: Array = net.getDrivers()
		var slot: int = -1
		# 从末位驱动者向前回溯，取第一个能命中 slot 的驱动者（末位者胜，与树一致）
		for i in range(drivers.size() - 1, -1, -1):
			var db = drivers[i]["build"]
			if db == null:
				continue
			slot = slotMap.get(db.id * 4 + int(drivers[i]["pinDir"]), -1)
			if slot >= 0:
				break
		if slot < 0:
			continue
		var v: int = boolProgram.get_slot_value(slot)
		if v < 0:
			continue
		var sig = SwDefine.CircuitSignal.HIGH if v == 1 else SwDefine.CircuitSignal.LOW
		# OP_OUT 在 evaluate_range 阶段已把驱动值写回 net.curSignal（跨段 OP_INPUT 反馈依赖需此副作用），
		# 使旧的 `net.curSignal != sig` 守卫恒为假而跳过电线传播——事件路径不跑 createCircuit 树 pass，
		# 电线视觉会陈旧。故此处无条件写回（末位驱动者胜，复刻树语义）并每轮刷新电线。
		net.curSignal = sig
		for load: SWBuildItemDefine in net.wireGroup.wireBuilds:
			load.getCircuitCompoent().setValue(0, sig)

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
	#T2.5：保序快照（Dictionary.keys() 每次调用会新建数组，循环内缓存复用避免热路径分配）
	var processedList:Array[SWBuildItemDefine] = [build]
	var head:int = 0
	# Pass A：纯结构 BFS（仅靠 noticeMap 展开，不调用 reCalSignals）
	# 把 reCalSignals 推迟到段求值之后（Pass B），确保 IR 模式下 getValue/reCalSignals 读到的是本轮刷新后的 slot，
	# 而非上一次事件的陈旧 slot；遍历顺序与 processedList 一致，notifyPosArr 语义不变
	while head < queue.size():
		var src:SWBuildItemDefine = queue[head]
		head += 1
		for noticeBuild:SWBuildItemDefine in cir.noticeMap.get(src,[]):
			# T2.5：NOT 也须入 BFS——IR 路径靠它触发输出 net 的 push 重算；
			# 树路径下多处理一次 NOT 的 pull 求值幂等，语义不变（memo 命中）
			if noticeBuild.buildDefine.circuit_component_type != SwDefine.CircuitComponentType.LED and noticeBuild.buildDefine.circuit_component_type != SwDefine.CircuitComponentType.ONE_BIT_REGISTER and noticeBuild.buildDefine.circuit_component_type != SwDefine.CircuitComponentType.NOT_GATE:
				continue
			if processed.has(noticeBuild):
				continue
			processed[noticeBuild] = true
			processedList.append(noticeBuild)
			queue.append(noticeBuild)
	# T2.5 主路径：IR 段重算 + push 写 net（getValue 已切 slot 查表，无 pull 递归/副作用）
	# 先求值受影响电路段刷新 slot，再跑 Pass B 的 reCalSignals（读新 slot）
	var evaluatedSegs: Dictionary = {}
	if useIR and boolProgram != null:
		# 只重算受影响电路的指令段（段=电路全部指令，拓扑序保证输入先更新）；
		# 同电路多处理建筑只评一次（本轮事件序列内求值幂等，去重省常数开销）
		for srcBuild: SWBuildItemDefine in processedList:
			var srcCirc = srcBuild.circuit
			if srcCirc == null:
				continue
			if evaluatedSegs.has(srcCirc.circuitID):
				continue
			var seg: Dictionary = boolProgram.segments.get(srcCirc.circuitID, {})
			if seg.is_empty():
				continue
			evaluatedSegs[srcCirc.circuitID] = true
			boolProgram.evaluate_range(seg["start"], seg["end"])
	# Pass B：按发现顺序对每个下游建筑调 reCalSignals（IR 模式下 slot 已刷新；树模式与旧路径逐拍等价）
	for idx in range(1, processedList.size()):
		notifyPosArr.append_array(processedList[idx].getCircuitCompoent().reCalSignals())
	if useIR and boolProgram != null:
		# push：把驱动器建筑输出 slot 的新电平写回 net 并传播电线视觉（替代原 getValue 内副作用）
		_pushDriverNets(processedList)
	# T1.5: signalTex 增量更新 — 只写脏 texel，不触发几何层重算
	# T2.2: 用 netId 去重（每个 SWNet 唯一），避免同一 net 被多个引脚重复写入；
	#       netId 非法（<0 或 >=MAX_NETS）时直接跳过，绝不推进 paintedSignal，防止状态漂移。
	if SWSignalTexture.instance != null:
		var updated_nets: Dictionary = {}
		var max_nets: int = SWSignalTexture.MAX_NETS
		for affected_build: SWBuildItemDefine in processedList:
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
