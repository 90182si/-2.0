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

# ========== T1.10 GPU compute 后端（M3 集成） ==========
# 开关：true 时电路求值走 GPU（RenderingDevice 不可用/编译失败自动回退 CPU）
var gpu_backend_enabled: bool = true
# SWCircuitData -> {"prog": SWGateProgram, "engine": SWSignalEvalGPU}
var _gpu_backends: Dictionary = {}
# 每电路一个 local RD + 每拍 submit/sync 的 D3D12 同步开销会吃掉整个后端收益
#（16x 计数器实测：16 个中等电路每拍 ~34ms）；gate 数低于阈值的电路走 CPU 数据驱动更划算
const GPU_MIN_GATES := 20000
# 共享 local RD：所有 GPU 引擎同一设备，才能「多引擎 list → 一次 submit → 一次 sync」
var _shared_rd: RenderingDevice = null
var _rd_probe_done: bool = false
# gate 规模路由的预编译缓存：SWCircuitData -> SWGateProgram
var _compiled_progs: Dictionary = {}
# 化简版 gate 表缓存：SWCircuitData -> SWGateProgram（见 use_simplified_eval）
var _simplified_progs: Dictionary = {}
# 化简器（class_name 在 headless 下可能还没进 class cache，统一用 preload）
const GATE_OPTIMIZER := preload("res://circuit/sw_gate_optimizer.gd")
# 数据驱动 CPU 求值（T1.10 方案 A）：SWCircuitData -> {"prog": SWGateProgram, "engine": SWSignalEvalCPU}
var cpu_backends_enabled: bool = true
var _cpu_backends: Dictionary = {}

# ========== 信号纹理 netId 分配（T2.2） ==========
# 全局累积计数器：只在全量清除/加载时重置，增量更新绝不回退（防其他 net 编号漂移）
var _netIdCounter:int = 0
# netId -> SWNet 的登记表：供全量同步/测试遍历所有已分配 net（旧 id 槽位残留无碍）
var _netById:Array = []

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
var _find1Visited:Dictionary[SWBuildItemDefine,bool] = {}

func find1(builds:Array[SWBuildItemDefine], from:int = 0, to:int = -1) -> Array[SWBuildItemDefine]:
	if to < 0 or to > builds.size():
		to = builds.size()
	for i in range(from, to):
		_expandAffected(builds[i])
	var retArr:Array[SWBuildItemDefine] = []
	if to >= builds.size():
		retArr.assign(_find1BuildMap.keys())
		_find1BuildMap.clear()
		_find1Handled.clear()
		_find1Visited.clear()
	return retArr

#从一栋建筑出发，把「会被电路连成一片的东西」整组收进本轮重建集合：
#起点 → 起点所在电路的全员 → 它们的邻居 → 邻居所在电路的全员 → … 收敛到不动点。
#必须收敛：电路一旦被劈成两半（成员分散在多个 circuit 里），只展开一层邻居的电路
#只能覆盖其中一半，另一半继续挂着旧 circuit，成为 createCircuitRange BFS 里的屏障
#（build.circuit != null 直接 continue），于是永远合并不回去 ——
#现场就是「同一根 net 上的灯泡和开关，hover 出两个电路 id」。
func _expandAffected(start:SWBuildItemDefine) -> void:
	if start == null:
		return
	var queue:Array[SWBuildItemDefine] = [start]
	while not queue.is_empty():
		var build:SWBuildItemDefine = queue.pop_back()
		if build == null or _find1Visited.has(build):
			continue
		_find1Visited[build] = true
		if build.buildState.state != SwDefine.BuildState.TO_BE_REMOVED:
			_find1BuildMap[build] = true
		if build.circuit != null and not _find1Handled.has(build.circuit):
			_find1Handled[build.circuit] = true
			for cBuild:SWBuildItemDefine in build.circuit.buildArr:
				if cBuild == null or _find1Visited.has(cBuild):
					continue
				if cBuild.buildState.state != SwDefine.BuildState.TO_BE_REMOVED:
					_find1BuildMap[cBuild] = true
				queue.append(cBuild)
		for neiBuildItem:Dictionary in getNeighborsCached(build):
			var neiBuild:SWBuildItemDefine = neiBuildItem["build"]
			if neiBuild != null and not _find1Visited.has(neiBuild):
				queue.append(neiBuild)

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
		_compiled_progs.erase(circuit)
		_simplified_progs.erase(circuit)
		_cpu_backends.erase(circuit)
		_gpu_backends.erase(circuit)

# 删除善后：算「真正需要重建的种子」，而不是把被删的建筑当种子。
# 为什么不能直接拿被删建筑当种子：find1 会对每个种子做一次邻居展开（
# getBuildIOConnectBuildArr 要分配数组 + 写缓存），一次性删 7w 元件就是一个
# 纯白跑的秒级开销（实测 1.4s）；而一整片删除真正的「断口」只有删除区的边界，
# 种子数从 7w 降到周长量级，全删光时直接降到 0。
# 种子 = ① 被删建筑原电路里还活着的成员（与删除区共处一个电路，必须重算）
#        ② 被删建筑的 4 邻里还活着的元件
# 隧道能跨格连到远处的配对端，4 邻看不到，所以隧道单独走完整邻居查询
#（数量少，代价可忽略；漏了它们会把远处那半个电路留成旧拓扑）。
# 删除善后的重建种子 = 「删除区的边界邻居 + 原电路的活成员」。
# 为什么不拿被删建筑本身当种子：一次性删 7w 元件时它们会全部进重建集，白跑一遍
# 完整重建（每栋都要建 net / 表达式 / 分组 / 首轮求值），还会把死建筑重新分回电路。
# 换成边界种子后，整片删除的种子数只有周长量级。
func collectRemoveSeeds(removed:Array[SWBuildItemDefine]) -> Array[SWBuildItemDefine]:
	var state:Dictionary = beginRemoveSeeds()
	collectRemoveSeedsStep(state, removed, 0, removed.size())
	return endRemoveSeeds(state)

# 分帧版本的种子收集：逐个查 4 邻居 + 遍历原电路成员本身就是上百毫秒的主线程活，
# 所以拆成「建状态 → 按区间喂 → 收尾」三段，供删除善后按时间预算分批调用。
func beginRemoveSeeds() -> Dictionary:
	var seeds:Array[SWBuildItemDefine] = []
	# seen 按建筑对象去重；seenPos 按坐标去重：同一格会被相邻的 4 个被删建筑各查一次
	#（7w 元件是 28w 次查表，按坐标去重后降到 7w 次）
	# seenCircuit 按电路去重，这是最要紧的一条：一条电路的 buildArr 可能有上万个成员，
	# 7w 个被删元件都挂在同一个电路上时，逐栋扫 buildArr 就是 7w × 上万 = 数十亿次
	#（「删除 7w 元件花了五个小时」的根因就在这里）。每个电路只扫一遍，结果完全一样。
	return {"seeds": seeds, "seen": {}, "seenPos": {}, "seenCircuit": {}}

func collectRemoveSeedsStep(state:Dictionary, removed:Array[SWBuildItemDefine],
		from:int, to:int) -> void:
	var seeds:Array[SWBuildItemDefine] = state["seeds"]
	var seen:Dictionary = state["seen"]
	var seenPos:Dictionary = state["seenPos"]
	var seenCircuit:Dictionary = state["seenCircuit"]
	var end:int = mini(to, removed.size())
	for idx in range(maxi(from, 0), end):
		var build:SWBuildItemDefine = removed[idx]
		if build == null:
			continue
		var cir:SwDefine.SWCircuitData = build.circuit
		# 同一电路只展开一次：它是「整体重算」的粒度，扫多少遍结果都一样
		if cir != null and not seenCircuit.has(cir):
			seenCircuit[cir] = true
			for member:SWBuildItemDefine in cir.buildArr:
				_add_live_member(member, seeds, seen)
		if build is SWBuildWireTunnel:
			for neiBuildItem:Dictionary in getNeighborsCached(build):
				_add_live_member(neiBuildItem["build"], seeds, seen)
			continue
		for dir in 4:
			var nbPos:Vector2i = build.buildAxisPos \
					+ SwDefine.dir_to_vec(dir) * SwDefine.GRID_SIZE
			if seenPos.has(nbPos):
				continue
			seenPos[nbPos] = true
			var nb:SWBuildItemDefine = buildManager.getBuild(nbPos)
			# 从这里取出来的肯定是建筑表里的当前对象，不用再按坐标反查一次
			if nb == null or seen.has(nb) or nb.bIsToBeRemoved():
				continue
			seen[nb] = true
			seeds.append(nb)

func endRemoveSeeds(state:Dictionary) -> Array[SWBuildItemDefine]:
	var seeds:Array[SWBuildItemDefine] = state["seeds"]
	return seeds

# 原电路成员当种子：它们可能已被同批删除（TO_BE_REMOVED）或坐标已换人，必须逐个校验
func _add_live_member(build:SWBuildItemDefine, seeds:Array[SWBuildItemDefine],
		seen:Dictionary) -> void:
	if build == null or seen.has(build) or build.bIsToBeRemoved():
		return
	if buildManager.getBuild(build.buildAxisPos) != build:
		return
	seen[build] = true
	seeds.append(build)

# 被删建筑身上的电路引用要显式摘掉：它们已经不在场，没人会替它们 reset，
# 返回的集合会被调用方 dropCircuits，否则 circuits / 编译产物 / 求值后端
# 会跟着每一批删除一路淤积（删 7w 元件就是几万个泄漏项）。
# 必须在 collectRemoveSeeds + updateBuildCircuit 之后调：
# 重建要靠旧的 circuit 关系把「同电路的活成员」拉进重建集。
func detachRemoved(removed:Array[SWBuildItemDefine]) -> Dictionary:
	var forDel:Dictionary = {}
	for build in removed:
		if build == null:
			continue
		if build.circuit != null:
			forDel[build.circuit] = true
			build.circuit = null
	return forDel

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
					#dir 是「本栋→邻居」的方向，查邻居自己的 net 得用它的反向口；
					#而桥/隧道的 net 是按物理口存的（隧道只有 rotation+1/+3 两个口有 net），
					#方向差一格就查成 null、BFS 直接断在这里，退化成「取任意一根非空 net」：
					#对电路划分足够，同一座桥的两半本来就该在同一个 circuit 里
					var net:SWNet = circuit.pinNetMap.get(SwDefine.getAntiDir(dir),null)
					if not net:
						for d in 4:
							var cand:SWNet = circuit.pinNetMap.get(d,null)
							if cand != null:
								net = cand
								break
					if not net:
						continue
					for wireBuild:SWBuildItemDefine in net.wireGroup.wireBuilds.keys():
						if visited.has(wireBuild):
							continue
						#纯电线没有额外的邻居语义，标记即跳过；桥/隧道能跨格跳转
						#（隧道 getDirBuild 会跳到配对端外侧），必须真正入队展开，
						#否则它们下游的元件会漏掉、掉进另一个 circuit
						if wireBuild.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.WIRE:
							visited[wireBuild] = true
						else:
							buildQueue.append(wireBuild)
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
		# 视野裁剪用的包围盒（世界像素）：建组时顺手算一次。
		# 电路一旦建成就不再增删成员（任何编辑都会整条 dropCircuits 重建），所以不会失效。
		var cullMin := Vector2(INF, INF)
		var cullMax := Vector2(-INF, -INF)
		var cellSize := Vector2(SwDefine.GRID_SIZE.x, SwDefine.GRID_SIZE.y)
		for build:SWBuildItemDefine in buildGroup:
			build.circuit = cir
			var bpos := Vector2(build.buildAxisPos)
			cullMin = cullMin.min(bpos)
			cullMax = cullMax.max(bpos + cellSize)
		cir.cullRect = Rect2(cullMin, cullMax - cullMin)
		for build:SWBuildItemDefine in buildGroup:
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
	#重建后的首轮求值优先走后端（GPU/CPU 数据驱动）：旧组件链是「逐组件递归解析」，
	#大存档（16x 计数器等）在读档/编辑收尾页能卡出数百 ms 单帧；后端是扁平数组单循环 + 回填，
	#语义一致（寄存器首轮 lastClk<0 只对齐不采样）。全量首轮时 net 都是新建（curSignal=NONE），
	#回填必然按「变化」通知到每个负载，显示刷新覆盖面与旧路径（每元件求值一次）一致
	if (cpu_backends_enabled or gpu_backend_enabled) and _eval_backends(builds):
		return
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
		_notify[comp] = true
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
	_find1Visited.clear()

func _filterNonWire(builds:Array[SWBuildItemDefine]) -> Array[SWBuildItemDefine]:
	var arr:Array[SWBuildItemDefine] = []
	for build in builds:
		if not SwCommon.IsWireBuild(build):
			arr.append(build)
	return arr

# T2.2：为一批建筑的全部 net 分配全局唯一 netId（signalBits 纹理 texel 索引）。
# 必须在 createNets 之后、resetEmptyWireNet 之前调用（此时 pinNetMap 已建立、空 net 尚未清除）。
# 按 net 对象引用去重（wireGroup 共享同一个 net 对象）；计数器累积递增不重置，
# 只在全量清除/加载时 resetNetIdCounter()。超过 MAX_NETS 打警告并保持 -1（绝不越界写纹理）。
func _assignNetIds(builds:Array[SWBuildItemDefine]) -> void:
	if builds.is_empty():
		return
	var seen:Dictionary[SWNet,bool] = {}
	var counter:int = _netIdCounter
	var tex:SWSignalTexture = SWSignalTexture.instance
	for build in builds:
		var cir:SWBuildCompoentCircuit = build.getCircuitCompoent()
		if cir == null:
			continue
		for net:SWNet in cir.pinNetMap.values():
			if net == null or seen.has(net):
				continue
			seen[net] = true
			if counter >= SWSignalTexture.MAX_NETS:
				push_warning("SWCircuitControl._assignNetIds: net 超过 MAX_NETS(%d)，超出部分保持 -1" % SWSignalTexture.MAX_NETS)
				continue
			net.netId = counter
			counter += 1
			# 调色板索引：跟所连 net 的线别（wireGroup.wireName），shader 用它查低/高绝对色
			var wireName:String = net.wireGroup.wireName if net.wireGroup != null else ""
			net.paletteId = SWSignalTexture.palette_id_for(wireName)
			if _netById.size() <= net.netId:
				_netById.resize(net.netId + 1)
			_netById[net.netId] = net
			# 新 net 先写一次初始电平（求值前的默认值→LOW），防几何重建后首帧读到旧 texel
			if tex != null:
				tex.set_level(net.netId, net.curSignal == SwDefine.CircuitSignal.HIGH)
				net.paintedSignal = net.curSignal
	_netIdCounter = counter

# 全量清除/加载时调用：netId 计数整体作废重建（防上一会话的 id 与新 net 冲突）
func resetNetIdCounter() -> void:
	_netIdCounter = 0
	_netById.clear()

# 全量同步辅助：把登记过的全部 net 电平刷进信号纹理（加载/清空后校正用，低频）
func syncAllSignalLevels() -> void:
	var tex:SWSignalTexture = SWSignalTexture.instance
	if tex == null:
		return
	for net in _netById:
		if net != null:
			tex.set_level(net.netId, net.curSignal == SwDefine.CircuitSignal.HIGH)
	tex.flush()

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
	#分配 netId（信号纹理索引）：必须在空 net 清除前，保证 pinNetMap 里的 net 都拿到编号
	_assignNetIds(affectBuilds)
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
	# 分配 netId（信号纹理索引）：全量重建最后一批完成后统一分配
	_assignNetIds(affectBuilds)
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
	# 读档完成：释放本轮重建累积的邻接缓存/队列，这些数据下次重建会重算，
	# 不释放会常驻 RAM（16万建筑的邻居 Dictionary 可达数十 MB）。
	_neighborsCache.clear()
	_queue.clear()
	_notify.clear()
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
#cull=true：只有视野内的电线与非门刷显示，视野外且不含寄存器的电路不参与求值（每拍时钟驱动与
#压力测试用）；其他调用（玩家点击/按钮、读档、测试）默认 false，全量刷作为显示基线。
#含寄存器的电路无论可见与否都照算——寄存器状态不能停（见视野裁剪说明）。
func buildSignalsChanged(seeds:Array[SWBuildItemDefine], cull: bool = false) -> Array[SWBuildItemDefine]:
	# T1.10 GPU 后端：整电路扁平布尔算子并行求值（用户方案）。失败自动回退 CPU 增量路径。
	if (cpu_backends_enabled or gpu_backend_enabled) and _eval_backends(seeds, cull):
		return _finishNotify()
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
	return _finishNotify()

func _finishNotify() -> Array[SWBuildItemDefine]:
	# _notify 存的是组件，回填成 build 列表（外部签名保持 Array[SWBuildItemDefine]；
	# 目前 refresh_signal_chunks 已不依赖内容，仅为兼容旧路径/测试返回）
	var notifyArr:Array[SWBuildItemDefine] = []
	for comp in _notify:
		if comp != null:
			var b:SWBuildItemDefine = comp.buildRef
			if b != null:
				notifyArr.append(b)
	_notify.clear()
	return notifyArr

# 懒编译：电路 → SWGateProgram（gate 规模路由判据；GPU/CPU 后端共用同一份）
func _compiled_prog(circuit) -> SWGateProgram:
	if _compiled_progs.has(circuit):
		return _compiled_progs[circuit]
	var prog := SWGateCompiler.new().compile(circuit.buildArr)
	_compiled_progs[circuit] = prog
	return prog

# 懒化简：电路 → 化简后的 gate 表（SWGateOptimizer 产物）。
# slot 空间与 dst 编号与原始 prog 完全一致（回填表直接复用），只有 gates 的 op/srcs 换了。
func _simplified_prog(circuit) -> SWGateProgram:
	if _simplified_progs.has(circuit):
		return _simplified_progs[circuit]
	var simple: SWGateProgram = GATE_OPTIMIZER.new().optimize(_compiled_prog(circuit))
	_simplified_progs[circuit] = simple
	return simple

# 本拍该用哪份 gate 表求值（两份的 slot 空间相同，回填永远用 _compiled_prog 那一份）
func _eval_prog(circuit) -> SWGateProgram:
	return _simplified_prog(circuit) if use_simplified_eval else _compiled_prog(circuit)

# 切换「简化表达式求值」（性能面板的「电线/非门跟随电平」开关驱动）。
# 两份程序不通用（gates 不同），所以已经在跑的后端必须重建；重建是懒的：
# _ensure_cpu_backend / _ensure_gpu_backend 下一拍比对 "simple" 标记自行失效重来。
# 这里刻意不 clear()：否则切换瞬间两套后端全空，静止电路（没有源在翻电平）
# 要等到下一次源变化才重建，期间 _cpu_backends 的统计与诊断会凭空掉干净。
func set_use_simplified_eval(v: bool) -> void:
	if use_simplified_eval == v:
		return
	use_simplified_eval = v

# 化简收益诊断（性能面板/测试用）：gate 条数不变，看有多少条被改写成了更便宜的形式
func get_simplify_stats(circuit) -> Dictionary:
	var raw := _compiled_prog(circuit)
	var opt := GATE_OPTIMIZER.new()
	var simple: SWGateProgram = opt.optimize(raw)
	return {
		"gates": raw.gate_count,
		"optimized": opt.optimized_gates,
		"loop_slots": raw.loop_nets,
		"same": simple.gate_count == raw.gate_count,
	}

# 后端统一入口（每拍/首轮同一轮次内完成全部电路）：
# · gate 达阈值的大电路 → GPU：共享 RD 上多引擎录制 list → 一次 submit → 一次 sync → 批量读回
# · 其余电路 → CPU 数据驱动（SWSignalEvalCPU 扁平 gate 单循环）
# 返回 true 表示全部电路已由后端接管；任一 GPU 大电路引擎不可用则整体回退 CPU 路径，
# 两路都无后端的电路落旧组件链
# 诊断计时累加器（微秒，每次 _eval_backends 开头清零）：
# [0]=收集输入值 [1]=net发布回填循环 [2]=engine求值 [3]=回填总计 [4]=notify/LED刷新 [5]=净回读
var dbg_phases: PackedInt64Array = PackedInt64Array()
# 本轮翻转电平的 net 数（每次 _eval_backends 清零）
var dbg_flip_nets: int = 0
# notify 刷新里单组件 >200us 的次数与最后一个的脚本名（诊断尖峰用）
var dbg_slow_recal: int = 0
var dbg_slow_recal_script: String = ""
# 诊断开关：true 时逐组件采样 reCalSignals 耗时（每拍两次系统调用/组件，日常必须关闭）
var dbg_time_recal: bool = false
# ========== 回填策略开关（完整显示 / 只算三类元件的压测档） ==========
# 默认全开：电线（net 电平）与非门（组合门贴图）都跟随电路每拍刷新。
#
# backfill_net_signal：是否把求值结果写回 net.curSignal。
#   true（默认）→ 连线颜色随信号变化
#   false       → 连线颜色不再随信号变化（信号纹理停在最后一次写入值）
# backfill_gate_display：是否刷新非门（组合门）贴图。
#   true（默认）→ 非门随输入变亮暗
#   false       → 非门停在初始档位不变色
#
# 两项都关掉是 64x 存档的压测配置（全显示 15.4ms → 只算三类 5.3ms，2.9 倍），
# 只用于性能对比；正常游戏保持全开，电线与非门才会跟着电路刷新。
# 无论开关如何，LED / 寄存器 / 开关（源）三类元件的值**永远正确刷新**。
var backfill_net_signal: bool = true
var backfill_gate_display: bool = true

# ========== 简化表达式求值 ==========
# true：后端用化简后的 gate 表（SWGateOptimizer：双非门抵消、单输入线与直通、
#       AND 去重/常量折叠）求值，少算几步。
# false：用未简化的 gate 表（每一级门都真算一遍）。
# 与 backfill_net_signal 反向联动：性能面板关掉「电线/非门跟随电平」（压测档）
# 时玩家看不见门在动，于是连求值也走简化版；打开时恢复未简化版。
# 两份 prog 的 slot 空间与回填表完全一致，所以切换只影响求值，不影响显示正确性。
var use_simplified_eval: bool = false

# ========== 视野裁剪（产品要求：视野外的电线与非门不刷显示，只计算寄存器） ==========
# 两层裁剪：
#   1. 整条电路与视口不相交：含寄存器的照旧整条求值（Q 是状态，一停下来计数器就断了，
#      而视野外的只计算寄存器就是这个意思），只是不回填任何电线/非门显示；
#      不含寄存器的（纯连线、纯组合）没有状态，看不见时算出来没人读，整条跳过求值。
#   2. 只有一部分在视野里的电路：照旧整条求值（信号必须连着算才不会算错），
#      但回填只显示视野内的电线与非门（见 SWGateProgram.net_view_idx）。
# 寄存器 / LED / 开关（源）三类元件的状态与贴图帧永远全量同步，不参与裁剪；
# 被裁剪的只有「跟随电路刷新」的电线与非门两类显示。
# 只作用于「每拍时钟驱动」的那一轮（buildSignalsChanged(clocks, true)）：
# 读档/重建/玩家点击等一次性轮次一律全量刷，作为显示正确性的基线，
# 这样镜头移回来时纹理/帧槽里至少是一个一致（最多偏旧）的值，不会闪黑线。
var view_cull_enabled: bool = true
# 裁剪矩形（世界像素，由绘制层推进来：已按区块对齐并外扩 unload_margin_chunks 圈）
# 默认无限大 = 不裁剪：相机事件到达前、以及 headless 测试保持完整显示
var _cull_rect: Rect2 = Rect2(-1e9, -1e9, 2e9, 2e9)
# 矩形拆成整数边界：热点里只做 int 比较，避开 Rect2/Vector2 的浮点与类型转换开销
var _cull_x0: int = -1000000000
var _cull_y0: int = -1000000000
var _cull_x1: int = 1000000000
var _cull_y1: int = 1000000000
# 视口变更戳：与各 prog.cull_stamp 比对，决定视野下标表要不要重建
var _cull_stamp: int = 0
# 诊断（每轮 _eval_backends 清零）：视野外整条跳过求值的电路数 / 视野外但含寄存器照算的电路数
var dbg_cull_skipped: int = 0
var dbg_cull_stateful: int = 0

# 绘制层在视口变化时推进来（见 SWBuildLayer._sync_circuit_view_rect）
func set_view_rect(rect: Rect2) -> void:
	if rect == _cull_rect:
		return
	_cull_rect = rect
	_cull_x0 = int(rect.position.x)
	_cull_y0 = int(rect.position.y)
	_cull_x1 = int(rect.end.x)
	_cull_y1 = int(rect.end.y)
	_cull_stamp += 1

func get_view_rect() -> Rect2:
	return _cull_rect

# 建筑格/区块原点（都是世界像素坐标）是否在视口内
func _pos_in_view(p: Vector2i) -> bool:
	return p.x >= _cull_x0 and p.x < _cull_x1 and p.y >= _cull_y0 and p.y < _cull_y1

# 一根 net 要不要刷显示：它的连线覆盖到的区块有任一个在视口内就算可见。
# chunkPosArr 为空 = 覆盖范围未知（没有连线组的 net，例如门直连负载），保守当作可见
func _net_in_view(net: SWNet) -> bool:
	if net == null:
		return true
	var arr: Array[Vector2i] = net.chunkPosArr
	var n: int = arr.size()
	if n == 0:
		return true
	for k in n:
		if _pos_in_view(arr[k]):
			return true
	return false

# 整条电路是否与视口相交（用建组时算好的包围盒；L 形/斜长条会被保守判为可见）
func _circuit_in_view(circuit) -> bool:
	var r: Rect2 = circuit.cullRect
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return true
	return r.end.x > _cull_x0 and r.position.x < _cull_x1 \
			and r.end.y > _cull_y0 and r.position.y < _cull_y1

# 电路里有没有寄存器（决定视野外能不能整条不算）：寄存器的 Q 是状态，
# 停下来就丢拍；纯连线/纯组合电路没有状态，看不见时算出来没人读。
# prog 是懒编译缓存，这里取一次后面 GPU 路由还要用，不重复编译。
func _circuit_has_register(circuit) -> bool:
	return not _compiled_prog(circuit).reg_slots.is_empty()

# 重建视野下标表：只在「视口变了之后的第一拍」跑一次 O(n) 扫描。
# 同时在扫描中把视野外元件的 prev 哨兵置 -1：它回到视野内那一拍必然判为「变了」，
# 于是补写正确的电平；视野外期间 curSignal/帧槽保持上一次写进去的值（一致、不闪黑）。
func _refresh_view_index(prog: SWGateProgram) -> void:
	prog.cull_stamp = _cull_stamp
	var net_n: int = prog.net_list.size()
	var nvi := PackedInt32Array()
	nvi.resize(net_n)
	var np: int = 0
	var n_prev: PackedInt32Array = prog.net_prev_bit
	var has_prev: bool = n_prev.size() == net_n
	for i in net_n:
		if _net_in_view(prog.net_list[i]):
			nvi[np] = i
			np += 1
		elif has_prev:
			n_prev[i] = -1
	if np < net_n:
		nvi.resize(np)
	prog.net_view_idx = nvi
	var g_n: int = prog.gate_out_slots.size()
	var gvi := PackedInt32Array()
	gvi.resize(g_n)
	var gp: int = 0
	var g_prev: PackedInt32Array = prog.gate_prev_level
	var has_gprev: bool = g_prev.size() == g_n
	var refs: Array = prog.gate_refresh_comps
	for gi in g_n:
		var rr = refs[gi] if gi < refs.size() else null
		var b: SWBuildItemDefine = rr.buildRef if rr != null else null
		# 取不到建筑位置就保守刷（不能冒「永远不刷」的风险）
		if b == null or _pos_in_view(b.buildAxisPos):
			gvi[gp] = gi
			gp += 1
		elif has_gprev:
			g_prev[gi] = -1
	if gp < g_n:
		gvi.resize(gp)
	prog.gate_view_idx = gvi

# ========== SPEC-05 唯一表达式 DAG（用户方案） ==========
# true：编译期把 (op, srcs) 相同的运算合并成一个「唯一表达式」，每拍只算一次。
#       64x 存档实测：25152 条 gate → 178~28242 个唯一表达式（按电路切分后）。
# false：退回原 gate 表逐层求值（等价性已验证，作为回退路径）。
var enable_expr_dag: bool = true

# 诊断：本拍显示刷新里被合并掉的重复 set_level 次数
var dbg_frame_dedup: int = 0
# 最近一次回填使用的 slot 数组（LED 批量匹配读它）
var _last_slots: PackedInt32Array = PackedInt32Array()
# 诊断：LED 批量刷新累计耗时（微秒）
var dbg_led_usec: int = 0
# 诊断：组合门批量刷新累计耗时（微秒）
var dbg_gate_usec: int = 0
# 显示刷新去重标记（每次回填 +1，见 _applyBackendResult）
var _display_mark: int = 0

# ========== 显示刷新去重（大存档卡顿治理） ==========
# NOT / LED / 寄存器的亮灭刷新最终都落到 SWSignalTexture.set_level(frameSlot, high)。
# 一次求值里同一个组件会被多次触达，导致同一个 frameSlot 被反复写（64x 存档实测
# 每拍 5.6k 次 set_level 只为决定 ~几百个帧槽），而 set_level 还要调
# SWSignalTextureGPU.instance 的 getter，非常贵。
# 这里按「拍」批量收集，同一帧槽只保留最后一次写入，再统一刷到纹理。
# 只对纯显示写入做合并（signal_state 仍在发布点立即写），所以语义不变：
# 同一帧槽在一拍内被多次写时，最终值本来就只取决于最后一次。
var _frame_pending: Dictionary = {}   # frameSlot:int -> bool
var _frame_flush_active: bool = false

# 登记一次帧槽写入（供组件侧调用）；merge=false 时立即写纹理（保持旧行为）
func submitFrameState(frameSlot: int, high: bool) -> void:
	if _frame_flush_active:
		_frame_pending[frameSlot] = high
		dbg_frame_dedup += 1
		return
	var tex: SWSignalTexture = SWSignalTexture.instance
	if tex != null:
		tex.set_level(frameSlot, high)

# 拍末统一刷帧槽（一槽一次），然后清表
func _flushFrameStates() -> void:
	if _frame_pending.is_empty():
		return
	var tex: SWSignalTexture = SWSignalTexture.instance
	if tex == null:
		_frame_pending.clear()
		return
	for slot in _frame_pending:
		tex.set_level(slot, _frame_pending[slot])
	_frame_pending.clear()

func _eval_backends(seeds: Array[SWBuildItemDefine], cull: bool = false) -> bool:
	dbg_phases.resize(6)
	dbg_phases.fill(0)
	dbg_flip_nets = 0
	dbg_cull_skipped = 0
	dbg_cull_stateful = 0
	dbg_slow_recal = 0
	dbg_slow_recal_script = ""
	var circuits: Array = []
	for seed in seeds:
		if seed == null or seed.circuit == null:
			continue
		if not seed.circuit in circuits:
			circuits.append(seed.circuit)
	if circuits.is_empty():
		return false
	# 视野裁剪第一层：整条不可见的电路里，只有不含寄存器的才连求值一起跳过；
	# 含寄存器的照旧每拍算（Q 要跟着时钟走），只是不回填电线/非门显示。
	# 含时钟的电路每拍都在种子集合里，镜头移回来下一拍自然接上刷新，不需要补算队列。
	# 全部被筛掉时要返回 true 交给本函数「处理完毕」，
	# 否则调用方会退回旧组件链、把视野外的电路全算一遍。
	if cull and view_cull_enabled:
		var seed_circuits: int = circuits.size()
		var kept: Array = []
		for circuit in circuits:
			if _circuit_in_view(circuit):
				kept.append(circuit)
			elif _circuit_has_register(circuit):
				kept.append(circuit)
				dbg_cull_stateful += 1
			else:
				dbg_cull_skipped += 1
		circuits = kept
		if circuits.is_empty():
			return seed_circuits > 0
	var gpu_circuits: Array = []
	for circuit in circuits:
		if gpu_backend_enabled and _compiled_prog(circuit).gate_count >= GPU_MIN_GATES:
			gpu_circuits.append(circuit)
	var rd: RenderingDevice = null
	if not gpu_circuits.is_empty():
		rd = _ensure_shared_rd()
		if rd == null:
			gpu_circuits.clear()
		else:
			# 懒建后端；任一电路建不起来就全部落 CPU（避免部分电路已求值状态擕裂）
			# 简化开关变了也要重建：gates 不同，engine 内部缓冲与 prev 基线都是一套
			for circuit in gpu_circuits:
				if not _gpu_backends.has(circuit) \
						or bool(_gpu_backends[circuit].get("simple", false)) != use_simplified_eval:
					_ensure_gpu_backend(circuit)
				if not _gpu_engine_ok(circuit):
					gpu_circuits.clear()
					break
	var epoch:int = SwCommon.NextEvalEpoch()
	_curEpoch = epoch
	_dirtyChunks.clear()
	_dirtyNets.clear()
	_notify.clear()
	_collectingNotify = true
	var handled := 0
	if not gpu_circuits.is_empty():
		for circuit in gpu_circuits:
			var gb: Dictionary = _gpu_backends[circuit]
			gb["engine"].write_sources_batch(_buildInputVals(gb["prog"]))
		for circuit in gpu_circuits:
			_gpu_backends[circuit]["engine"].execute()
		rd.submit()
		rd.sync()
		for circuit in gpu_circuits:
			var gb: Dictionary = _gpu_backends[circuit]
			var engine = gb["engine"]
			engine.end_tick()
			# 回填永远用未简化 prog（两份的 slot 空间与回填扁平表一致，且缓存只维护一份）
			_applyBackendResult(circuit, _compiled_prog(circuit),
					engine.take_readback(), engine.take_reg_state(), cull)
		handled += gpu_circuits.size()
	for circuit in circuits:
		if circuit in gpu_circuits:
			continue
		# 开关切换后需要重建对应后端（表达式 DAG 与 gate 表引擎状态不通用）
		var cb: Dictionary = _ensure_cpu_backend(circuit)
		if cb.is_empty():
			continue
		if enable_expr_dag and cb["expr"] == null:
			_cpu_backends.erase(circuit)
			cb = _ensure_cpu_backend(circuit)
		elif not enable_expr_dag and cb["expr"] != null:
			_cpu_backends.erase(circuit)
			cb = _ensure_cpu_backend(circuit)
		if cb.is_empty():
			continue
		var prog: SWGateProgram = cb["prog"]
		var engine: SWSignalEvalCPU = cb["engine"]
		var _pt0 := Time.get_ticks_usec()
		var vals := _buildInputVals(prog)
		var _pt1 := Time.get_ticks_usec()
		var rb: PackedInt32Array
		var rs: PackedInt32Array
		if cb["expr"] != null:
			# ===== SPEC-05/06：表达式 DAG 求值（优先走 GDExtension 原生实现）=====
			# src 写入 → tick（内部完成快照/灌 Q/拓扑序求值/锁存/滚动）
			var expr: SWExprProgram = cb["expr"]
			var ev: PackedInt32Array = cb["expr_vals"]
			for i in mini(vals.size(), prog.input_slots.size()):
				ev[prog.input_slots[i]] = vals[i]
			# 注意：原生路径下 tick 返回的是新数组（结果在 C++ 内部缓冲里算出来的），
			# 必须用返回值；同时把它存回后端，供下拍继续使用。
			var out_ev := expr.tick(ev)
			cb["expr_vals"] = out_ev
			ev = out_ev
			rb = ev
			# 直接取内部锁存数组（读取方只读，不改）。避免每拍 duplicate 一份寄存器状态。
			rs = expr.lock_state
		else:
			# 回退路径：原 gate 表逐层求值
			engine.clear_changed()
			engine.write_sources(vals)
			engine.evaluate()
			rb = engine.readback()
			rs = engine.read_reg_state()
		var _pt2 := Time.get_ticks_usec()
		var _pt3 := Time.get_ticks_usec()
		_applyBackendResult(circuit, _compiled_prog(circuit), rb, rs, cull)
		var _pt4 := Time.get_ticks_usec()
		dbg_phases[0] += _pt1 - _pt0
		dbg_phases[2] += _pt2 - _pt1
		dbg_phases[5] += _pt3 - _pt2
		dbg_phases[3] += _pt4 - _pt3
		handled += 1
	_collectingNotify = false
	SwCommon.dbgEvaluated = _notify.size()
	SwCommon.dbgQueue = 0
	return handled > 0

# 共享 local RD（一次性探测，不可用时不再重试）
func _ensure_shared_rd() -> RenderingDevice:
	if not _rd_probe_done:
		_rd_probe_done = true
		if RenderingServer.get_rendering_device() != null:
			_shared_rd = RenderingServer.create_local_rendering_device()
	return _shared_rd

func _gpu_engine_ok(circuit) -> bool:
	var backend: Dictionary = _gpu_backends.get(circuit, {})
	return not backend.is_empty() and not backend["engine"].is_broken()

# 懒构建：电路 → SWGateProgram + 引擎（缓存；电路结构变化时调用方需 clear_gpu_backend(circuit)）。
# 返回空 Dictionary 表示该电路无 GPU 后端（无 RenderingDevice/编译失败），调用方回退 CPU。
func _ensure_gpu_backend(circuit) -> Dictionary:
	if _gpu_backends.has(circuit):
		var cached: Dictionary = _gpu_backends[circuit]
		# 空 dict 是「无 RenderingDevice/编译失败」的永久标记；否则要校对简化开关
		if cached.is_empty() or bool(cached.get("simple", false)) == use_simplified_eval:
			return cached
		_gpu_backends.erase(circuit)
	# 无 RenderingDevice（headless）直接缓存空 dict，避免每拍重复 setup
	var rd := _ensure_shared_rd()
	if rd == null:
		_gpu_backends[circuit] = {}
		return {}
	var prog := _eval_prog(circuit)
	var engine := SWSignalEvalGPU.new()
	engine.setup(prog, rd)
	if not engine.is_broken():
		# 把 CPU 寄存器当前状态灌入引擎（qState/lastClk 按 reg_slots 序）
		var q := PackedInt32Array()
		var lc := PackedInt32Array()
		for i in prog.reg_slots.size():
			var reg := prog.reg_comps[i] as SWBuildCompoentCircuitRegister
			q.append(1 if reg != null and reg.qState == SwDefine.CircuitSignal.HIGH else 0)
			lc.append(-1 if reg == null or reg.lastClk == SwDefine.CircuitSignal.NONE \
					else (1 if reg.lastClk == SwDefine.CircuitSignal.HIGH else 0))
		engine.init_reg_state(q, lc)
		# 首次创建灌入当前 net 电平 + 寄存器 Q（拍前基线），否则 GPU 以全 0 起算与 CPU 状态不一致
		var prev_slots := PackedInt32Array()
		prev_slots.resize(prog.slot_count)
		prev_slots.fill(0)
		for net in prog.net_to_slot:
			prev_slots[prog.net_to_slot[net]] = 1 if (net as SWNet).curSignal == SwDefine.CircuitSignal.HIGH else 0
		for i in prog.reg_slots.size():
			var reg := prog.reg_comps[i] as SWBuildCompoentCircuitRegister
			prev_slots[prog.reg_slots[i]] = 1 if reg != null and reg.qState == SwDefine.CircuitSignal.HIGH else 0
		engine.init_prev(prev_slots)
	var backend := {"prog": prog, "engine": engine, "simple": use_simplified_eval}
	_gpu_backends[circuit] = backend
	return backend

# 丢弃该电路全部后端使下次 tick 重编译（包含化简版 prog 缓存）
func clear_gpu_backend(circuit) -> void:
	_gpu_backends.erase(circuit)
	_cpu_backends.erase(circuit)
	_compiled_progs.erase(circuit)
	_simplified_progs.erase(circuit)

# 丢弃全部 CPU 后端（切换求值策略后需要重建：表达式 DAG 与 gate 表引擎状态不通用）
func clear_cpu_backends() -> void:
	_cpu_backends.clear()

# 后端求值结果回填（GPU/CPU 数据驱动共用）：
# 1) net 电平回填 + 标脏（_publishGpuNetSignal：值变才标脏，加载后首算与 curSignal 同值时不标脏）
# 2) 寄存器组件状态同步（q + last_clk）
# 3) 显示型负载刷新（非状态型负载 + 全电路 LED）：不依赖「net 值变化」事件，否则灯泡停在存档值
func _applyBackendResult(_circuit, prog: SWGateProgram, slots: PackedInt32Array, reg_state: PackedInt32Array, cull: bool = false) -> void:
	#首轮回填（读档/重建后）：resetBuildState 已把贴图重置为 off，且未变化的
	#net/寄存器不进通知集，必须全量刷一次显示（旧路径靠「每元件求值一次」顺带做到）；
	#之后每拍只刷「输入 net 翻过的负载 + 全电路 LED」
	var force: bool = not prog.display_synced
	prog.display_synced = true
	_last_slots = slots
	var _at0 := Time.get_ticks_usec()
	# 视野裁剪：本拍只遍历「视野内」的电线与非门。下标表只在视口变化后的第一拍重建，
	# 而且当表已经覆盖全部元件（缩到很远、整屏都可见）时直接走原来的全量循环，不多一分开销。
	var net_vis: PackedInt32Array = prog.net_view_idx
	var gate_vis: PackedInt32Array = prog.gate_view_idx
	var cull_net: bool = false
	var cull_gate: bool = false
	if cull and view_cull_enabled:
		if prog.cull_stamp != _cull_stamp:
			_refresh_view_index(prog)
			net_vis = prog.net_view_idx
			gate_vis = prog.gate_view_idx
		cull_net = net_vis.size() < prog.net_list.size()
		cull_gate = gate_vis.size() < prog.gate_out_slots.size()
	# ---- 回填策略开关（见 backfill_* 声明处的说明；默认全开 = 完整显示）----
	# backfill_net_signal=true：把 slot 值写回 net.curSignal，连线随之变色。
	#   置 false 时连线颜色停在最后一次写入值，net.sigEpoch 也不再维护，
	#   可省掉 64x 存档每拍 ~4ms 的 11392 根 net 回填（纯压测用）。
	# backfill_gate_display=true：非门（组合门）贴图随输入变亮暗。
	#   置 false 时非门停在初始档位，可省掉每拍 ~1.5ms 的门 dirty 扫描。
	if backfill_net_signal:
		# 回填 net 电平：走编译期建好的平行数组（net_list / net_slots），纯下标访问；
		# 原实现遍历 net_to_slot 字典，每根 net 一次哈希查表，64x 存档 11392 根实测 8ms/拍。
		var n_list: Array = prog.net_list
		var n_slots: PackedInt32Array = prog.net_slots
		var n_prev: PackedInt32Array = prog.net_prev_bit
		var net_n: int = n_list.size()
		if cull_net:
			# 视野外的电线：curSignal / sigEpoch / 信号纹理全不写。
			# _refresh_view_index 已把它们的 n_prev 置成 -1，回到视野内那一拍会补写。
			for k in net_vis.size():
				var vi: int = net_vis[k]
				var vnet: SWNet = n_list[vi]
				var vbit: int = slots[n_slots[vi]]
				if n_prev[vi] != vbit:
					n_prev[vi] = vbit
					dbg_flip_nets += 1
					_publishGpuNetSignal(vnet,
							SwDefine.CircuitSignal.HIGH if vbit == 1 else SwDefine.CircuitSignal.LOW)
				else:
					vnet.sigEpoch = _curEpoch
		else:
			for i in net_n:
				var net: SWNet = n_list[i]
				var bit: int = slots[n_slots[i]]
				# 翻转判断走 int 缓存（net.curSignal 是类型化枚举属性，读写各一次类型转换）；
				# 同值 net 只需补 sigEpoch（漏设会让 netBit 判「本轮未解析」而掉回旧组件链）
				if n_prev[i] != bit:
					n_prev[i] = bit
					dbg_flip_nets += 1
					_publishGpuNetSignal(net,
							SwDefine.CircuitSignal.HIGH if bit == 1 else SwDefine.CircuitSignal.LOW)
				else:
					net.sigEpoch = _curEpoch
	var _at1 := Time.get_ticks_usec()
	for i in prog.reg_slots.size():
		var reg := prog.reg_comps[i] as SWBuildCompoentCircuitRegister
		if reg == null:
			continue
		var prev_q: SwDefine.CircuitSignal = reg.qState
		reg.qState = SwDefine.CircuitSignal.HIGH if reg_state[i * 2] == 1 else SwDefine.CircuitSignal.LOW
		reg.lastClk = SwDefine.CircuitSignal.NONE if reg_state[i * 2 + 1] < 0 \
				else (SwDefine.CircuitSignal.HIGH if reg_state[i * 2 + 1] == 1 else SwDefine.CircuitSignal.LOW)
		#后端路径寄存器不走 reCalSignals（防重复锁存），Q 翻转时在这里同步刷贴图/帧槽，
		#否则 GPU/CPU 数据驱动路径下寄存器显示冻住；首轮无条件刷（Q 没变但贴图已被重置）
		if force or reg.qState != prev_q:
			reg.buildRef.buildStateChanged(reg.qState)
	# 显示刷新全程开启帧槽合并：组件侧 setFrameState 期间只登记，拍末统一刷一次
	_frame_pending.clear()
	_frame_flush_active = true
	SWBuildCompoentRenderable._activeOwner = self
	if force:
		# 首轮（读档/重建后）：贴图被 resetBuildState 重置，需要重新刷一次显示。
		# 仍遵守开关：关掉非门刷新时就不刷组合门，只刷 LED/寄存器/源等三类元件。
		for comp in prog.all_comps:
			if comp == null or comp.isStateful():
				continue
			if not backfill_gate_display and prog.comp_to_slot.has(comp):
				continue   # 组合门：按开关跳过
			comp.reCalSignals()
		_flushFrameStates()
		_frame_flush_active = false
		SWBuildCompoentRenderable._activeOwner = null
		return
	var _at2 := Time.get_ticks_usec()
	# 刷新负载显示。热点路径优化（64x 存档读档卡顿治理）：
	# 1) 用编译期定死的 prog.display_comps 扁平表遍历，不再对 _notify 里每个组件跑
	#    isStateful() 虚调用（原实现 61.4k 次/拍、9.25ms）；
	# 2) 用 evalMark 去重：同一组件本拍只刷一次（原实现按 _notify 集合本就去重，
	#    换成扁平表后必须显式判，否则 LED 会被刷两遍）；
	# 3) LED 的 reCalSignals 只是「读 input net → buildStateChanged」，这里直接做，
	#    省掉组件层的一次方法套壳（原实现 13.8k 次/拍、59ms）。
	var time_recal: bool = dbg_time_recal
	# 本拍显示刷新去重标记：用独立自增计数器，不复用 comp.evalMark（那是旧组件链的轮次语义，
	# 后端路径不维护它，混用会让去重失效或误判）。
	_display_mark += 1
	if _display_mark >= 0x3FFFFFFF:
		_display_mark = 1
		# 回绕时清空所有组件的标记，避免撞上上一轮的值
		for c in prog.display_comps:
			if c != null:
				c.evalMark = -1
	var mark: int = _display_mark
	var cur_slots: PackedInt32Array = _last_slots
	var led_start := Time.get_ticks_usec()
	var led_refs: Array = prog.led_refresh_comps
	var led_comps: Array = prog.led_comps
	var flat_src: PackedInt32Array = prog.led_src_flat
	var src_offs: PackedInt32Array = prog.led_src_offs
	var src_lens: PackedInt32Array = prog.led_src_lens
	var led_n: int = led_comps.size()
	# 首轮强制刷（贴图被重建重置）；之后只刷亮灭真的变了的 LED
	var led_prev: PackedInt32Array = prog.led_prev_level
	if led_prev.size() != led_n:
		led_prev.resize(led_n)
		led_prev.fill(-1)
	for li in led_n:
		var off: int = src_offs[li]
		var ln: int = src_lens[li]
		var bit := 0
		# LED 输入数 1~4，直接比较 slot 值（cur_slots 是 PackedInt32Array，下标访问最快）
		if ln > 0:
			bit = cur_slots[flat_src[off]]
			if ln > 1:
				bit = bit | cur_slots[flat_src[off + 1]]
				if ln > 2:
					bit = bit | cur_slots[flat_src[off + 2]]
					if ln > 3:
						bit = bit | cur_slots[flat_src[off + 3]]
		var high: bool = bit != 0
		# 亮灭没变的 LED 不必重刷（buildStateChanged 会写 signal_state + setFrameState 走帧槽合并）
		if force or led_prev[li] != bit:
			led_prev[li] = bit
			var rr = led_refs[li]
			rr.buildRef.buildStateChanged(
					SwDefine.CircuitSignal.HIGH if high else SwDefine.CircuitSignal.LOW)
			rr.setFrameState(high)
		led_comps[li].evalMark = mark
	var led_usec := Time.get_ticks_usec() - led_start
	# ---- NOT 门显示：只按「本拍值变了」刷 ----
	# NOT 的显示刷新（reCalSignals → evaluate → netBit → buildRef.buildStateChanged）
	# 是 64x 存档最大的单点开销：13.8k 个非门 × 每次 4 层间接调用。但它的语义只是
	# 「把本拍算出来的电平画到贴图上」，而**绝大多数非门一拍内电平根本没变**。
	# 这里用编译期建好的扁平表（输出 slot / 显示取反标记 / 渲染组件）直接：
	#   本拍 ≠ 上拍 才动手；动手时也不进组件层，直接写 signal_state + 帧槽。
	var cur_slots0: PackedInt32Array = _last_slots
	var refs_for_dirty: Array = prog.gate_refresh_comps
	var prev_for_dirty: PackedInt32Array = prog.gate_prev_level
	if not backfill_gate_display:
		# 压测档：不刷非门贴图，只把兜底显示件刷掉，组合门完全跳过
		for comp in prog.fallback_display_comps:
			if comp != null:
				comp.reCalSignals()
	elif not force:
		var out_slots: PackedInt32Array = prog.gate_out_slots
		var prev: PackedInt32Array = prog.gate_prev_level
		var gcount: int = out_slots.size()
		var dirty: PackedInt32Array = prog.dirty_gate_idx
		dirty.clear()
		var gate_start := Time.get_ticks_usec()
		if cull_gate:
			# 视野外的非门：prev 已被置 -1 且不进 dirty，这一拍不写帧槽也不写 signal_state
			for k in gate_vis.size():
				var cgi: int = gate_vis[k]
				var cnv: int = cur_slots0[out_slots[cgi]]
				if cnv == prev[cgi]:
					continue
				prev[cgi] = cnv
				dirty.append(cgi)
		else:
			for gi in gcount:
				var os: int = out_slots[gi]
				var nv: int = cur_slots0[os]
				if nv == prev[gi]:
					continue
				prev[gi] = nv
				dirty.append(gi)
		dbg_gate_usec += Time.get_ticks_usec() - gate_start
		# 只刷本拍真的变了电平的组合门：绝大多数拍真正变化的是极少数
		# （64x 存档实测每拍 ~500/13824 个非门翻转，刷全量纯属浪费）
		var dirty_refs := Time.get_ticks_usec()
		var invert: PackedByteArray = prog.gate_display_invert
		for gi in prog.dirty_gate_idx:
			var rr2 = refs_for_dirty[gi]
			# 显示位 = 输出位（非门再取反：它按输入电平选帧）
			var hv: bool = (prev_for_dirty[gi] == 1) != (invert[gi] == 1)
			rr2.buildRef.buildStateChanged(
					SwDefine.CircuitSignal.HIGH if hv else SwDefine.CircuitSignal.LOW)
			rr2.setFrameState(hv)
		dbg_gate_usec += Time.get_ticks_usec() - dirty_refs
		# 兜底：既不是 LED、也不是组合门的显示件（通常只有时钟/按钮等源类，数量极少）
		for comp in prog.fallback_display_comps:
			if comp != null:
				comp.reCalSignals()
	else:
		# 首轮（读档/重建后）：贴图被 resetBuildState 重置成 off，必须全量刷一次
		for comp in prog.display_comps:
			if comp == null or comp.evalMark == mark:
				continue
			comp.evalMark = mark
			if time_recal:
				var _rt0 := Time.get_ticks_usec()
				comp.reCalSignals()
				var _rt1 := Time.get_ticks_usec()
				if _rt1 - _rt0 > 200:
					dbg_slow_recal += 1
					dbg_slow_recal_script = comp.get_script().resource_path.get_file()
			else:
				comp.reCalSignals()
	var _at3 := Time.get_ticks_usec()
	# 拍末统一刷帧槽：本拍所有 NOT/LED/寄存器 的显示状态合并后每槽只写一次
	_flushFrameStates()
	_frame_flush_active = false
	SWBuildCompoentRenderable._activeOwner = null
	dbg_phases[1] += _at1 - _at0
	dbg_phases[4] += _at3 - _at2
	dbg_led_usec += led_usec

# 懒构建：电路 → SWGateProgram + CPU 数据驱动引擎（缓存；结构变化时 clear_gpu_backend 已一并清）
func _ensure_cpu_backend(circuit) -> Dictionary:
	if _cpu_backends.has(circuit):
		var cached: Dictionary = _cpu_backends[circuit]
		# 简化开关变了：gates 不同，求值程序必须重建（slot 空间没变，回填不受影响）
		if bool(cached.get("simple", false)) == use_simplified_eval:
			return cached
		_cpu_backends.erase(circuit)
	var prog := _eval_prog(circuit)
	var engine := SWSignalEvalCPU.new()
	engine.setup(prog)
	# SPEC-05：唯一表达式 DAG（用户方案）。表达式去重后每拍只算唯一表达式，
	# 不再逐 gate 重复计算。enable_expr_dag=false 时退回原 gate 表逐层求值。
	var expr: SWExprProgram = null
	var expr_vals := PackedInt32Array()
	if enable_expr_dag:
		expr = SWExprBuilder.new().build(prog, [])
		expr_vals.resize(expr.value_space())
		expr_vals.fill(0)
	# 灌入寄存器当前状态 + 拍前基线（与 GPU ensure 一致）
	var q := PackedInt32Array()
	var lc := PackedInt32Array()
	for i in prog.reg_slots.size():
		var reg := prog.reg_comps[i] as SWBuildCompoentCircuitRegister
		q.append(1 if reg != null and reg.qState == SwDefine.CircuitSignal.HIGH else 0)
		lc.append(-1 if reg == null or reg.lastClk == SwDefine.CircuitSignal.NONE \
				else (1 if reg.lastClk == SwDefine.CircuitSignal.HIGH else 0))
	engine.init_reg_state(q, lc)
	var prev_slots := PackedInt32Array()
	prev_slots.resize(prog.slot_count)
	prev_slots.fill(0)
	for net in prog.net_to_slot:
		prev_slots[prog.net_to_slot[net]] = 1 if (net as SWNet).curSignal == SwDefine.CircuitSignal.HIGH else 0
	for i in prog.reg_slots.size():
		var reg := prog.reg_comps[i] as SWBuildCompoentCircuitRegister
		prev_slots[prog.reg_slots[i]] = 1 if reg != null and reg.qState == SwDefine.CircuitSignal.HIGH else 0
	engine.init_prev(prev_slots)
	if expr != null:
		expr.set_lock_state(q, lc)
		# 首拍基线与旧引擎对齐：当前 net 电平写进 vals
		for net in prog.net_to_slot:
			expr_vals[prog.net_to_slot[net]] = prev_slots[prog.net_to_slot[net]]
	var backend := {"prog": prog, "engine": engine, "expr": expr, "expr_vals": expr_vals,
			"simple": use_simplified_eval}
	_cpu_backends[circuit] = backend
	return backend

# 源值：按 input_comps 序读组件当前状态（时钟 curSig / 按钮 pressed）
func _buildInputVals(prog: SWGateProgram) -> PackedInt32Array:
	var vals := PackedInt32Array()
	for comp in prog.input_comps:
		var ref = comp.buildRef
		if comp is SWBuildCompoentCircuitClockSiggen:
			var clk := ref as SWBuildClockSiggen
			vals.append(1 if clk != null and clk.curSig == SwDefine.CircuitSignal.HIGH else 0)
		elif comp is SWBuildCompoentCircuitSource:
			var btn := ref as SWBuildButton
			vals.append(1 if btn != null and btn.pressed else 0)
		else:
			vals.append(0)
	return vals

# GPU 回填用标脏：与 _publishNetSignal 的副作用一致，但不把负载排进 CPU 求值队列（GPU 已全量算完）
func _publishGpuNetSignal(net:SWNet, sig:SwDefine.CircuitSignal) -> void:
	if net.curSignal == sig:
		return
	if net.preEpoch != _curEpoch:
		net.preEpoch = _curEpoch
		net.preSignal = net.curSignal
	net.curSignal = sig
	net.changedEpoch = _curEpoch
	# 标记本轮已解析：netBit() 用 sigEpoch != _curEpoch 判断「本轮未解析」，
	# 漏设会让每次 net 读取触发 resolveNetSignal（旧增量全量重求值），GPU/CPU 数据驱动白算
	net.sigEpoch = _curEpoch
	net.sigVersion += 1
	SwCommon.netPatchStamp += 1
	net.patchStamp = SwCommon.netPatchStamp
	_dirtyNets[net] = true
	for cp:Vector2i in net.chunkPosArr:
		_dirtyChunks[cp] = true
	for load in net._loadComps:
		if load != null:
			_notify[load] = true

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
