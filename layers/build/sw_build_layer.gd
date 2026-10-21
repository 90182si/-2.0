class_name SWBuildLayer extends SWLayer

var sw_build_manager:SWBuildManager = null
#var sw_circuit_manager:SWCircuitManager = null
#var sw_circuit_analyzer:SWCircuitAnalyzer = null
var sw_circuit_control:SWCircuitControl = null
var holdLayerRef:SWHoldLayer = null
@onready var sw_draw_manager: SWDrawManager = $SWDrawManager

func _ready() -> void:
	sw_build_manager = SWBuildManager.new()
	sw_draw_manager.setBuildManager(sw_build_manager)
	sw_draw_manager.set_name("buildDrawManager")
	sw_draw_manager.setDrawMode(SwDefine.GridDrawMode.ByContent)
	sw_draw_manager.useName = "Content"

	sw_circuit_control = SWCircuitControl.new()
	#sw_circuit_manager = SWCircuitManager.new()
	#sw_circuit_manager.setup(sw_build_manager)
	#add_child(sw_circuit_manager)
	# 断开旧电路管理器的 build_changed 连接，改用新的卡诺图分析器
	#if sw_build_manager.build_changed.is_connected(sw_circuit_manager._on_build_changed):
		#sw_build_manager.build_changed.disconnect(sw_circuit_manager._on_build_changed)
#
	#sw_circuit_analyzer = SWCircuitAnalyzer.new()
	#sw_circuit_analyzer.setup(sw_build_manager)
	#sw_circuit_analyzer.signal_changed.connect(_on_circuit_signal_changed)
	add_child(sw_circuit_control)
	sw_circuit_control.setBuildManager(sw_build_manager)
	# T2.5：登记当前电路控制实例，供组件求值后端（getValue 切 slot）访问
	SWCircuitControl.current = sw_circuit_control
	
	#var build:SWBuildItemDefine = SwDefine.SWBuildCreator(Vector2i(0,0),load("res://res/按钮.tres") as SWBuildDefine)
	#var build2:SWBuildItemDefine = SwDefine.SWBuildCreator(Vector2i(0,0),load("res://res/开关.tres") as SWBuildDefine)
	#var build3:SWBuildItemDefine = SwDefine.SWBuildCreator(Vector2i(0,0),load("res://res/灯泡.tres") as SWBuildDefine)
	#var chunkPos = Vector2i(-2048,-2048)
	#sw_circuit_analyzer.begin_batch()
	#for x in range(0,128*16,128):
		#for y in range(0,128*16,128):
			#holdIdleBuilds([build],[Vector2i(x,y)+chunkPos])
			#holdIdleBuilds([build2],[Vector2i(x,y)])
			#holdIdleBuilds([build3],[Vector2i(x,y)-chunkPos])
	#sw_circuit_analyzer.end_batch()

func _exit_tree() -> void:
	# T2.5：释放当前实例登记，避免测试多轮 boot/shutdown 后残留野引用
	if SWCircuitControl.current == sw_circuit_control:
		SWCircuitControl.current = null

func _on_circuit_signal_changed() -> void:
	var all_builds = sw_build_manager.getAllBuilds()
	var notifyChunkPosArr = getNotifyChunkPosArr(all_builds)
	flush_and_update_chunks(notifyChunkPosArr)

func _on_drag_started() -> void:
	#if sw_circuit_analyzer:
		#sw_circuit_analyzer.begin_batch()
	pass

func _on_drag_ended() -> void:
	#if sw_circuit_analyzer:
		#sw_circuit_analyzer.end_batch()
	pass

func clear_all_builds() -> void:
	#if sw_circuit_analyzer:
		#sw_circuit_analyzer.begin_batch()、
	_pendingRemovedBuilds.clear()
	_pendingPlacedBuilds.clear()
	#清空时钟登记表，避免加载新存档后残留上一次会话的时钟引用
	clockBuildArr.clear()
	sw_build_manager.clearAllBuilds()
	#if sw_circuit_analyzer:
		#sw_circuit_analyzer.end_batch()
	#T2.2：全量清理后归零 netId 计数器，保证下一次 updateBuildCircuit 从 0 开始分配
	if sw_circuit_control:
		sw_circuit_control.resetNetIdCounter()
		#T2.5：全量清理/加载（本函数开头即调 clear_all_builds）时作废 IR 后端，避免残留旧建筑 slot
		sw_circuit_control.resetIR()
	flush_and_update_all_chunks()

func load_save_data(data: Dictionary) -> void:
	clear_all_builds()
	var builds_arr = data.get("builds", [])
	if not builds_arr is Array:
		return
	#if sw_circuit_analyzer:
		#sw_circuit_analyzer.begin_batch()
	var maxRestoredId:int = 0
	#同一种建筑会被反复 load()：按名字缓存定义资源，40k 建筑的存档能省下几万次字符串拼接与资源查找
	var defCache:Dictionary[String,SWBuildDefine] = {}
	for b in builds_arr:
		var pos_dict = b.get("pos", {})
		var def_name = b.get("def", "")
		var build_def: SWBuildDefine = defCache.get(def_name, null)
		if build_def == null:
			build_def = load("res://res/" + str(def_name) + ".tres") as SWBuildDefine
			if build_def != null:
				defCache[def_name] = build_def
		if not build_def:
			continue
		var rot = b.get("rot", 0)
		var comp_type = b.get("comp_type", 0)
		var circuit_on = b.get("circuit_on", false)
		var signal_state = b.get("signal_state", 0)
		var tunnel_pair_id = b.get("tunnel_pair_id", -1)
		var in_loop = b.get("in_loop", false)
		var saved_id = b.get("id", -1)
		var w = b.get("w", 1)
		var h = b.get("h", 1)
		var state_data = b.get("state", {})
		var pos = Vector2i(pos_dict.get("x", 0), pos_dict.get("y", 0))
		# m×n 多格建筑：size 随 .tres 资源，w/h 字段仅用于向前兼容校验
		# 旧档缺省 1×1，行为完全兼容
		var build = SwDefine.SWBuildCreator(pos, build_def, rot)
		# Fix-3B: 恢复存档中的建筑 id。隧道 pairId 引用的是配对建筑的 id，
		#          只有 id 一致才能让加载后的 pairId 有效，从而 on_idled 跳过空间搜索
		#          （空间搜索按加载顺序逐个 addBuild 触发，配对建筑可能尚未加入导致配对丢失）
		if saved_id != null and int(saved_id) > 0:
			build.id = int(saved_id)
			if int(saved_id) > maxRestoredId:
				maxRestoredId = int(saved_id)
		build.circuit_on = circuit_on
		build.signal_state = signal_state
		# Fix-3B: 回填隧道配对 id（存档字段 tunnel_pair_id 对应 SWBuildWireTunnel.pairId）
		if build is SWBuildWireTunnel:
			(build as SWBuildWireTunnel).pairId = int(tunnel_pair_id)
		build.in_loop = in_loop
		# 元件状态必须在 addBuild/updateBuildCircuit 之前恢复：
		# 开关/时钟的 pressed、寄存器 qState 都是求值入口直读的叶值，晚一步首趟就按默认电平算完
		if state_data is Dictionary:
			build.restoreStateData(state_data)
		sw_build_manager.addBuild(build)
		# Fix-3C: 时钟类建筑重新登记到 clockBuildArr，否则加载后 _process 无法驱动时钟 tick
		if build is SWBuildClockSiggen:
			addClockBuild(build)
	# Fix-3B: 抬高全局 id 计数器，避免后续新建建筑 id 与存档恢复的 id 冲突
	if maxRestoredId > 0:
		SwCommon.EnsureBuildIdCounterAtLeast(maxRestoredId)
	#if sw_circuit_analyzer:
		#sw_circuit_analyzer.end_batch()
	# 加载卡诺图数据（用于后续独立电路单元提取）
	#if sw_circuit_analyzer and kmap_data is Dictionary and not kmap_data.is_empty():
		#sw_circuit_analyzer.load_karnaugh_map_data(kmap_data)
	sw_circuit_control.updateBuildCircuit(sw_build_manager.getAllBuilds())
	flush_and_update_all_chunks()
	# Fix-3D: 删除无参 on_view_rect_changed()——它用当前(尚未恢复)的 color_rect 计算视口会出错；
	#          紧随其后的 SWSaveManager.apply_viewport 会经 camera.view_rect_changed() 触发正确的有参回调

func on_view_rect_changed(viewRect:Rect2,speedVec:Vector2) -> void:
	sw_draw_manager.on_view_rect_changed(viewRect,speedVec)
	pass

func getNotifyChunkPosArr(builds:Array[SWBuildItemDefine]) -> Array[Vector2i]:
	var chunkPosMap:Dictionary[Vector2i,bool] = {}
	for build in builds:
		if not build:
			continue
		build.markRenderPartsDirty()
		var chunkPos = SwCommon.GetChunkPos(build.buildAxisPos)
		chunkPosMap[chunkPos] = true
	return chunkPosMap.keys()

# T1.4: 在 updataChunks 前 flush signalTex，确保渲染时 net 颜色是最新的
func flush_and_update_chunks(chunk_pos_arr: Array[Vector2i]) -> void:
	flush_signal_tex()
	sw_draw_manager.updataChunks(chunk_pos_arr)

func flush_and_update_all_chunks() -> void:
	flush_signal_tex()
	sw_draw_manager.updataAllChunks()

# Fix-3A: 从信号变化影响的建筑里挑出"渲染缓存已失效"（drawRect 等视觉状态真变化）的建筑，
#         只重建它们所在 chunk 的几何层。signalTex 已由调用方增量刷新，此处不再全量 flush，
#         从而在恢复 LED/按钮/非门/寄存器贴图切换的同时，保持时钟 tick 路径的增量性能。
func _refreshDirtyBuildChunks(builds:Array) -> void:
	var changedBuilds:Dictionary[SWBuildItemDefine,bool] = {}
	var dirtyBuilds:Array[SWBuildItemDefine] = []
	for b in builds:
		if b:
			changedBuilds[b] = true
	for b in changedBuilds.keys():
		if b.isRenderPartsDirty():
			dirtyBuilds.append(b)
	if dirtyBuilds.size() == 0:
		return
	# R3.1：信号变化只改了少数建筑的部件（非门/LED 换贴图），按 chunk 分组下发增量补丁，
	# 不再让一个建筑的变化牵动整块所有建筑重填实例
	var notifyChunkPosArr:Array[Vector2i] = []
	var patchMap:Dictionary[Vector2i,Array] = {}
	for b in dirtyBuilds:
		# 补丁条目一律是 [建筑, parts 快照, style 补丁]，全部在主线程准备好，工作线程只读：
		# - style 补丁非空：本次只换了主体贴图，条目形如 [b, [], [style_id, bodyStart, bodyCount]]，
		#   不必复制 parts 数组，工作线程只覆写主体那几行的 style 浮点（R3.4）；
		# - style 补丁为空：结构变了，下发 [b, parts 快照, []]，由工作线程整行重写
		var comp: SWBuildCompoentRenderable = b.getRenderableCompoent()
		var stylePatch: Array = comp.getStylePatch()
		var entry: Array = [b, [], stylePatch] if not stylePatch.is_empty() else [b, comp.getRenderParts(), []]
		var chunkPos = SwCommon.GetChunkPos(b.buildAxisPos)
		if not patchMap.has(chunkPos):
			patchMap[chunkPos] = []
			notifyChunkPosArr.append(chunkPos)
		patchMap[chunkPos].append(entry)
	sw_draw_manager.updataChunks(notifyChunkPosArr, patchMap)

func flush_signal_tex() -> void:
	if SWSignalTexture.instance == null:
		return
	var all_builds := sw_build_manager.getAllBuilds()
	var seen_nets: Dictionary = {}
	for build: SWBuildItemDefine in all_builds:
		var circuit_comp: SWBuildCompoentCircuit = build.getCircuitCompoent()
		if circuit_comp == null:
			continue
		for net: SWNet in circuit_comp.pinNetMap.values():
			if net == null or seen_nets.has(net):
				continue
			seen_nets[net] = true
			var c: Color = SwCommon.get_net_display_color(net)
			SWSignalTexture.instance.set_net_color(net.netId, c)
	SWSignalTexture.instance.flush()

func holdIdleBuilds(builds:Array[SWBuildItemDefine],poss:Array[Vector2i]) -> void:
	var successBuilds:Array[SWBuildItemDefine] = []
	for pos in poss:
		var gridPos = SwCommon.GetGridPos(pos)
		for build in builds:
			#var newBuild = SWBuildItemDefine.new(build.buildAxisPos+gridPos,build.buildDefine,build.rotation)
			var newBuild = SwDefine.SWBuildCreator(build.buildAxisPos+gridPos,build.buildDefine,build.rotation)
			var ok := sw_build_manager.addBuild(newBuild)
			if ok:
				successBuilds.append(newBuild)

	if successBuilds.size() == 0:
		return

	var notifyChunkPosArr = getNotifyChunkPosArr(successBuilds)
	flush_and_update_chunks(notifyChunkPosArr)
	 #按住左键期间只做视觉放置并记账，电路更新延迟到左键释放时统一执行
	for b in successBuilds:
		_pendingPlacedBuilds[b] = true
	# if sw_circuit_control:
	# 	successBuilds.append_array(sw_circuit_control.updateBuildCircuit(successBuilds))
	# 	notifyChunkPosArr = getNotifyChunkPosArr(successBuilds)
	# 	sw_draw_manager.updataChunks(notifyChunkPosArr)

func holdRemoveBuilds(poss:Array[Vector2i]) -> void:
	if selectedBuilds.size() != 0:
		var notifyChunkPosArr = getNotifyChunkPosArr(selectedBuilds.keys())
		for build in selectedBuilds:
			if not build:
				continue
			sw_build_manager.setBuildState(build,SwDefine.BuildState.IDLE)
		flush_and_update_chunks(notifyChunkPosArr)
		selectedBuilds.clear()
		return
	var builds := sw_build_manager.getBuilds(poss)
	if builds.is_empty():
		return
	#按住右键期间只做视觉删除并记账，电路更新延迟到右键释放时统一执行
	sw_build_manager.setBuildsState(builds,SwDefine.BuildState.TO_BE_REMOVED)
	for build in builds:
		if selectedBuilds.has(build):
			selectedBuilds.erase(build)
		_pendingRemovedBuilds[build] = true
	sw_build_manager.delBuilds(builds)
	var notifyChunkPosArr = getNotifyChunkPosArr(builds)
	flush_and_update_chunks(notifyChunkPosArr)

#右键释放：把本次按住期间擦除的所有建筑物一次性提交给电路重建
func onEraseDragEnded() -> void:
	if _pendingRemovedBuilds.is_empty():
		return
	var removedBuilds:Array[SWBuildItemDefine] = _pendingRemovedBuilds.keys()
	_pendingRemovedBuilds.clear()
	var notifyBuilds = removedBuilds.duplicate()
	if sw_circuit_control:
		notifyBuilds.append_array(sw_circuit_control.updateBuildCircuit(removedBuilds))
	var notifyChunkPosArr = getNotifyChunkPosArr(notifyBuilds)
	flush_and_update_chunks(notifyChunkPosArr)
	for build in removedBuilds:
		if build is SWBuildClockSiggen:
			delClockBuild(build)

#左键释放：把本次按住期间放置的所有建筑物一次性提交给电路重建
func onPlaceDragEnded() -> void:
	if _pendingPlacedBuilds.is_empty():
		return
	var placedBuilds:Array[SWBuildItemDefine] = _pendingPlacedBuilds.keys()
	_pendingPlacedBuilds.clear()
	var notifyBuilds = placedBuilds.duplicate()
	if sw_circuit_control:
		var start_us := Time.get_ticks_usec()
		notifyBuilds.append_array(sw_circuit_control.updateBuildCircuit(placedBuilds))
		var end_us := Time.get_ticks_usec()
		var cost_us := end_us - start_us
		var cost_ms := cost_us / 1000.0
		var cost_s := cost_us / 1000000.0

		print("耗时：%d us | %.3f ms | %.6f s" % [cost_us, cost_ms, cost_s])
	var notifyChunkPosArr = getNotifyChunkPosArr(notifyBuilds)
	flush_and_update_chunks(notifyChunkPosArr)
	for build in notifyBuilds:
		if build is SWBuildClockSiggen:
			addClockBuild(build)

var selectedBuilds:Dictionary[SWBuildItemDefine,bool] = {}
#按住右键擦除期间暂存的被擦除建筑物，右键释放时统一更新电路
var _pendingRemovedBuilds:Dictionary[SWBuildItemDefine,bool] = {}
#按住左键放置期间暂存的新放置建筑物，左键释放时统一更新电路
var _pendingPlacedBuilds:Dictionary[SWBuildItemDefine,bool] = {}

signal cut_builds()
signal copy_builds()

func setSelectedRect(rect:Rect2) -> void:
	var builds := sw_build_manager.getBuildsByRect(rect)
	var notifyChunkPosArr = getNotifyChunkPosArr(builds)
	for build in builds:
		selectedBuilds[build] = true
		sw_build_manager.setBuildState(build,SwDefine.BuildState.SELECTED)
	flush_and_update_chunks(notifyChunkPosArr)
	pass

func clearSelectedByRect(rect:Rect2) -> void:
	var builds := sw_build_manager.getBuildsByRect(rect)
	var notifyChunkPosArr = getNotifyChunkPosArr(builds)
	for build in builds:
		if selectedBuilds.has(build):
			selectedBuilds.erase(build)
			sw_build_manager.setBuildState(build,SwDefine.BuildState.IDLE)
	flush_and_update_chunks(notifyChunkPosArr)
	pass

func _getSelectedBuildCenter() -> Vector2i:
	if selectedBuilds.size() == 0:
		return Vector2i.ZERO
	var minPos := Vector2i(999999, 999999)
	var maxPos := Vector2i(-999999, -999999)
	for build in selectedBuilds:
		var pos = build.buildAxisPos
		minPos.x = min(minPos.x, pos.x)
		minPos.y = min(minPos.y, pos.y)
		maxPos.x = max(maxPos.x, pos.x)
		maxPos.y = max(maxPos.y, pos.y)
	var center = (minPos + maxPos) / 2
	var gs = Vector2(SwDefine.GRID_SIZE)
	return Vector2i((Vector2(center) / gs).floor() * gs)

func _do_cut() -> void:
	if selectedBuilds.size() == 0:
		return
	if not holdLayerRef:
		return
	var builds:Array[SWBuildItemDefine] = []
	for build in selectedBuilds:
		builds.append(build)
	var center = _getSelectedBuildCenter()
	holdLayerRef.setHeldBuilds(builds, center)
	var notifyBuilds = builds.duplicate()
	# 与擦除路径（holdRemoveBuilds）同构：必须先标 TO_BE_REMOVED 再删。
	# updateBuildCircuit 的 find1/getNet 都靠该状态把已删建筑排除在重建集合外；
	# 不标记时被删电线会按旧格位继续查邻格，把开关和灯泡重新桥到同一条 net 上，
	# 下游元件删了电线仍收得到信号
	sw_build_manager.setBuildsState(builds, SwDefine.BuildState.TO_BE_REMOVED)
	sw_build_manager.delBuilds(builds)
	# 与擦除路径同构：删除必须触发电路重建，否则旧电路/IR 段里仍留着被剪切的建筑；
	# 只 flush 被剪区块会让渲染与电路状态分叉（R3.1 补丁会去给已不在 chunk 里的建筑刷格子）
	if sw_circuit_control:
		notifyBuilds.append_array(sw_circuit_control.updateBuildCircuit(builds))
	flush_and_update_chunks(getNotifyChunkPosArr(notifyBuilds))
	# 剪切的建筑进入暂存层待重放，本拍必须先注销时钟；重放放置时 onPlaceDragEnded 会重新登记
	for build in builds:
		if build is SWBuildClockSiggen:
			delClockBuild(build)
	selectedBuilds.clear()
	#if sw_circuit_analyzer and not sw_circuit_analyzer.is_in_batch():
		#sw_circuit_analyzer.analyze()

func _do_delete_selected() -> void:
	if selectedBuilds.size() == 0:
		return
	var builds:Array[SWBuildItemDefine] = []
	for build in selectedBuilds:
		builds.append(build)
	selectedBuilds.clear()
	var notifyBuilds = builds.duplicate()
	#if sw_circuit_analyzer:
		#sw_circuit_analyzer.begin_batch()
	# 同 _do_cut：删除前必须标 TO_BE_REMOVED，否则被删电线会参与重建并桥接旧邻格，
	# 下游元件删了电线仍收得到信号
	sw_build_manager.setBuildsState(builds, SwDefine.BuildState.TO_BE_REMOVED)
	sw_build_manager.delBuilds(builds)
	if sw_circuit_control:
		notifyBuilds.append_array(sw_circuit_control.updateBuildCircuit(builds))
	#if sw_circuit_analyzer:
		#sw_circuit_analyzer.end_batch()
	flush_and_update_chunks(getNotifyChunkPosArr(notifyBuilds))
	# 漏注销会让已删除的时钟留在 clockBuildArr 里逐拍驱动旧电路（删除后计数器仍在跳的根因）
	for build in builds:
		if build is SWBuildClockSiggen:
			delClockBuild(build)

func _do_copy() -> void:
	if selectedBuilds.size() == 0:
		return
	if not holdLayerRef:
		return
	var builds:Array[SWBuildItemDefine] = []
	for build in selectedBuilds:
		builds.append(build)
	var center = _getSelectedBuildCenter()
	holdLayerRef.setHeldBuilds(builds, center)
	var notifyChunkPosArr = getNotifyChunkPosArr(builds)
	for build in builds:
		sw_build_manager.setBuildState(build,SwDefine.BuildState.IDLE)
	selectedBuilds.clear()
	flush_and_update_chunks(notifyChunkPosArr)

var _pressed_button_pos:Vector2i = Vector2i(-9999, -9999)

func reorderRenderIndex(builds:Array[SWBuildItemDefine]) -> void:
	var drawIndex = 0
	for build:SWBuildItemDefine in builds:
		build.getRenderableCompoent().drawIndex = drawIndex
		drawIndex+=1

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.is_pressed():
		if event.keycode == KEY_DELETE:
			_do_delete_selected()
			get_viewport().set_input_as_handled()
			return
		if event.ctrl_pressed and selectedBuilds.size() > 0:
			if event.keycode == KEY_X:
				cut_builds.emit()
				get_viewport().set_input_as_handled()
				return
			elif event.keycode == KEY_C:
				copy_builds.emit()
				get_viewport().set_input_as_handled()
				return

	if event is InputEventMouseButton:
		if event.is_pressed():
			if event.button_index == MOUSE_BUTTON_LEFT:
				var viewport := get_viewport()
				var mouse_pos := viewport.get_mouse_position()
				var world_pos = SwCommon.GetGlobalPosByViewPos(mouse_pos, viewport)
				var grid_pos:Vector2i = SwCommon.GetGridPos(Vector2i(world_pos))
				var build = sw_build_manager.getBuild(grid_pos)
				if build and (build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.BUTTON or build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.SWITCH):
					if build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.BUTTON:
						build.onPressed(true)
					elif build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.SWITCH:
						build.onPressed(!build.pressed)
					var newBuilds = sw_circuit_control.buildSignalChanged(build)
					newBuilds.append(build)
					# T1.5: 点击路径增量刷 signalTex；Fix-3A: 再按需重建主体贴图真变化的建筑所在 chunk
					if SWSignalTexture.instance != null:
						SWSignalTexture.instance.flush()
					reorderRenderIndex(newBuilds)
					_refreshDirtyBuildChunks(newBuilds)
					if build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.BUTTON:
						_pressed_button_pos = grid_pos
					get_viewport().set_input_as_handled()
					return
		elif event.is_released():
			if event.button_index == MOUSE_BUTTON_LEFT:
				if _pressed_button_pos != Vector2i(-9999, -9999):
					var grid_pos:Vector2i = SwCommon.GetGridPos(Vector2i(_pressed_button_pos))
					var build = sw_build_manager.getBuild(grid_pos)
					if build and (build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.BUTTON or build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.SWITCH):
						if build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.BUTTON:
							#90182si 按钮被点击
							build.onPressed(false)
						elif build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.SWITCH:
							pass
						var newBuilds = sw_circuit_control.buildSignalChanged(build)
						newBuilds.append(build)
						# T1.5: 点击释放路径增量刷 signalTex；Fix-3A: 再按需重建主体贴图真变化的建筑所在 chunk
						if SWSignalTexture.instance != null:
							SWSignalTexture.instance.flush()
						reorderRenderIndex(newBuilds)
						_refreshDirtyBuildChunks(newBuilds)
					_pressed_button_pos = Vector2i(-9999, -9999)

	#if event.is_action_pressed("TEST_PERFORMANCE"):
		#print("开始性能测试...")
		#var test_regions = [
			#Rect2i(Vector2i(0, 0), Vector2i(512, 512)),
			#Rect2i(Vector2i(0, 0), Vector2i(1024, 1024)),
			#Rect2i(Vector2i(-512, -512), Vector2i(2048, 2048))
		#]
		#for region in test_regions:
			#sw_build_manager.test_getBuildsByRect_performance(region)
			#await get_tree().create_timer(0.5).timeout

var clockBuildArr:Dictionary[SWBuildItemDefine,bool] = {}
const CLOCK_GAP_TIME = 1.0/60
var curTimeGap:float = 0
func addClockBuild(build:SWBuildItemDefine) -> void:
	clockBuildArr[build]=true
func delClockBuild(build:SWBuildItemDefine) -> void:
	clockBuildArr.erase(build)
func _process(delta: float) -> void:
	curTimeGap+=delta
	var changedBuilds:Array[SWBuildItemDefine] = []
	if curTimeGap > CLOCK_GAP_TIME*2:
		curTimeGap = 0
		# T2.8：本拍所有时钟事件共用下游 net，signalTex 上色合并到拍尾去重
		sw_circuit_control.beginTick()
		for build in clockBuildArr.keys():
			build.onPressed(true)
		#sw_circuit_control.updateBuildCircuit(clockBuildArr.keys())
			var newBuilds = sw_circuit_control.buildSignalChanged(build)
			changedBuilds.append_array(newBuilds)
			changedBuilds.append(build)
		sw_circuit_control.endTick()
		# T1.5: 时钟 tick 路径增量刷 signalTex；Fix-3A: 仅当 LED/NOT/寄存器等主体贴图真变化时才重建对应 chunk
		if changedBuilds.size() > 0:
			if SWSignalTexture.instance != null:
				SWSignalTexture.instance.flush()
			_refreshDirtyBuildChunks(changedBuilds)
