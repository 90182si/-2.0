class_name SWBuildLayerSystem extends SWLayerSystem

var build_manager:SWBuildManager = null
var circuit_control:SWCircuitControl = null

#手持系统引用
var _hold_system:SWHoldLayerSystem = null
#选中的建筑物数组
var _selected_builds:Dictionary[SWBuildItemDefine,bool] = {}
#按住右键擦除期间暂存的被擦除建筑物，右键释放时统一更新电路
var _pendingRemovedBuilds:Dictionary[SWBuildItemDefine,bool] = {}
#按住左键放置期间暂存的新放置建筑物，左键释放时统一更新电路
var _pendingPlacedBuilds:Dictionary[SWBuildItemDefine,bool] = {}
#鼠标按下的位置
var _pressed_button_pos:Vector2i = Vector2i(-9999, -9999)

func _init() -> void:
	system_name = &"core.layer.build"
	run_order = SwDefine.ORDER_LAYER_BUILD
	build_manager = SWBuildManager.new()
	circuit_control = SWCircuitControl.new()
	circuit_control.setBuildManager(build_manager)

func _get_view() -> SWBuildLayer:
	return view as SWBuildLayer

func attach_view(v:SWLayer) -> void:
	super.attach_view(v)
	var build_layer := v as SWBuildLayer
	if build_layer != null:
		build_layer.attach_build_manager(build_manager)
		
#region 实时操作地图（放置、删除、框选）
#tag buildLayer放置元件
# 只登记放置任务：克隆与入图都交给分片循环，否则一次落笔放下上万建筑会卡住整帧。
# 同一位置的连续落笔会排成多个任务，进度条按所有任务的总建筑数合并计算。
func on_hold_idle_builds(builds:Array[SWBuildItemDefine],positions:Array) -> void:
	var v := _get_view()
	if v == null or builds.is_empty() or positions.is_empty():
		return
	if not can_place():
		return
	_place_jobs.append({
		"builds": builds.duplicate(),
		"positions": positions.duplicate(),
		"pos_i": 0,
		"build_i": 0,
	})
	_place_total += builds.size() * positions.size()
	if not _place_running:
		_run_place_loop()
		
#tag buildLayer删除元件
func on_hold_remove_builds(positions:Array[Vector2i]) -> void:
	var v := _get_view()
	if v == null:
		return
	var grid_positions:Array[Vector2i] = []
	grid_positions.assign(positions)
	if _selected_builds.size() != 0:
		var notifyChunkPosArr = getNotifyChunkPosArr(_selected_builds.keys())
		for build in _selected_builds:
			if not build:
				continue
			build_manager.setBuildState(build,SwDefine.BuildState.IDLE)
			#build_manager.setBuildDirty(build,true)
		v.sw_draw_manager.updataChunks(notifyChunkPosArr)
		_selected_builds.clear()
		return
	var builds := build_manager.getBuilds(positions)
	if builds.is_empty():
		return
	#按住右键期间只做视觉删除并记账，电路更新延迟到右键释放时统一执行
	build_manager.setBuildsState(builds,SwDefine.BuildState.TO_BE_REMOVED)
	for build in builds:
		if _selected_builds.has(build):
			_selected_builds.erase(build)
		_pendingRemovedBuilds[build] = true
	build_manager.delBuilds(builds)
	var notifyChunkPosArr = getNotifyChunkPosArr(builds)
	v.sw_draw_manager.updataChunks(notifyChunkPosArr)

#tag buildLayer连续放置元件结束
# 放置本身已由分片循环陆续完成，这里只保证电路求值循环在跑
func on_place_drag_ended() -> void:
	if _pendingPlacedBuilds.is_empty():
		return
	if not _place_running:
		_run_place_loop()

#tag buildLayer连续删除元件结束
func on_erase_drag_ended() -> void:
	var v := _get_view()
	if v == null:
		return
	if _pendingRemovedBuilds.is_empty():
		return
	var removedBuilds:Array[SWBuildItemDefine] = _pendingRemovedBuilds.keys()
	_pendingRemovedBuilds.clear()
	var notifyBuilds = removedBuilds.duplicate()
	if circuit_control:
		notifyBuilds.append_array(circuit_control.updateBuildCircuit(removedBuilds))
	var notifyChunkPosArr = getNotifyChunkPosArr(notifyBuilds)
	v.sw_draw_manager.updataChunks(notifyChunkPosArr)
	for build in removedBuilds:
		if build is SWBuildClockSiggen:
			delClockBuild(build)

#tag 拖拽开始
func on_drag_started() -> void:
	pass
	
#tag 拖拽结束
func on_drag_ended() -> void:
	pass
	
#tag 框选元件
func on_select_by_rect(rect:Rect2) -> void:
	var v := _get_view()
	if v == null:
		return
	var changed:Array[SWBuildItemDefine] = []
	for build in build_manager.getBuildsByRect(rect):
		if _selected_builds.has(build):
			continue   # 已经选中：底色没变，别重复打脏
		_selected_builds[build] = true
		build_manager.setBuildState(build,SwDefine.BuildState.SELECTED)
		changed.append(build)
	if changed.is_empty():
		return
	#只改底色：走增量颜色补丁，不整块重建（整块重建一次要 ~1.8s）
	#选中高亮不是电路状态：LOD 冻结颜色的档位也要立刻写进去
	v.sw_draw_manager.updataChunks(getChunkPosArrOf(changed), changed, {}, 250000, true)
	
#tag 取消框选元件
func on_deselect_by_rect(rect:Rect2) -> void:
	var v := _get_view()
	if v == null:
		return
	var changed:Array[SWBuildItemDefine] = []
	for build in build_manager.getBuildsByRect(rect):
		if not _selected_builds.has(build):
			continue
		_selected_builds.erase(build)
		build_manager.setBuildState(build,SwDefine.BuildState.IDLE)
		changed.append(build)
	if changed.is_empty():
		return
	v.sw_draw_manager.updataChunks(getChunkPosArrOf(changed), changed, {}, 250000, true)
#endregion

#region 内部函数
#tag buildLayer根据建筑物坐标获取区块坐标（不打脏渲染部件）
func getChunkPosArrOf(builds:Array[SWBuildItemDefine]) -> Array[Vector2i]:
	var chunkPosMap:Dictionary[Vector2i,bool] = {}
	for build in builds:
		if not build:
			continue
		chunkPosMap[SwCommon.GetChunkPos(build.buildAxisPos)] = true
	return chunkPosMap.keys()

#tag buildLayer根据建筑物坐标获取区块坐标
func getNotifyChunkPosArr(builds:Array[SWBuildItemDefine],geomDirty:bool = true) -> Array[Vector2i]:
	var chunkPosMap:Dictionary[Vector2i,bool] = {}
	for build in builds:
		if not build:
			continue
		if geomDirty:
			build.markRenderPartsDirty()
		else:
			build.markColorDirty()
		var chunkPos = SwCommon.GetChunkPos(build.buildAxisPos)
		chunkPosMap[chunkPos] = true
	return chunkPosMap.keys()

#信号传播后的重绘区块（不消费脏 net，供测试/统计使用）
func getSignalChangedChunkPosArr(changedBuilds:Array[SWBuildItemDefine]) -> Array[Vector2i]:
	var chunkPosMap:Dictionary[Vector2i,bool] = {}
	for cp:Vector2i in circuit_control.takeDirtyChunks():
		chunkPosMap[cp] = true
	for build in changedBuilds:
		if build == null:
			continue
		build.markColorDirty()
		chunkPosMap[SwCommon.GetChunkPos(build.buildAxisPos)] = true
	return chunkPosMap.keys()

#信号变化后的统一刷新入口：建筑列表走逐实例补丁，翻转的 net 走连线批量换色
#返回本次涉及的区块数（供性能统计）
func refresh_signal_chunks(changedBuilds:Array[SWBuildItemDefine]) -> int:
	var nets:Dictionary = circuit_control.takeDirtyNets()
	var chunkPosMap:Dictionary[Vector2i,bool] = {}
	for cp:Vector2i in circuit_control.takeDirtyChunks():
		chunkPosMap[cp] = true
	for build in changedBuilds:
		if build == null:
			continue
		build.markColorDirty()
		chunkPosMap[SwCommon.GetChunkPos(build.buildAxisPos)] = true
	if chunkPosMap.is_empty() and nets.is_empty():
		return 0
	var v := _get_view()
	if v == null:
		return 0
	v.sw_draw_manager.updataChunks(chunkPosMap.keys(), changedBuilds, nets)
	return chunkPosMap.size()

#tag buildLayer获取选中元件中心点置
func _getSelectedBuildCenter() -> Vector2i:
	if _selected_builds.size() == 0:
		return Vector2i.ZERO
	var minPos := Vector2i(999999, 999999)
	var maxPos := Vector2i(-999999, -999999)
	for build in _selected_builds:
		var pos = build.buildAxisPos
		minPos.x = min(minPos.x, pos.x)
		minPos.y = min(minPos.y, pos.y)
		maxPos.x = max(maxPos.x, pos.x)
		maxPos.y = max(maxPos.y, pos.y)
	var center = (minPos + maxPos) / 2
	var gs = Vector2(SwDefine.GRID_SIZE)
	return Vector2i((Vector2(center) / gs).floor() * gs)

#endregion

#region 复制/剪切准备与放置任务（主线程分帧）
# 单片的处理预算（微秒）：每片做完就让出一帧，让渲染、输入与进度条跟上。
# 克隆建筑与电路重建都是纯主线程活（全局 id、组件、绘制缓冲都不是线程安全的）
const JOB_SLICE_USEC:int = 5000
# 放置后的电路重建预算：比读档（50ms）小一个量级，交互期间要保住手感
const JOB_CIRCUIT_BUDGET_USEC:int = 6000
const JOB_CIRCUIT_STEP:int = 8
# 任务超过这个时长才弹进度条，小批量复制不会闪一下
const JOB_UI_DELAY_MSEC:int = 120

var _hud_view:SWHudLayer = null
#复制/剪切准备进行中：克隆建筑与手持区块构建都算
var _clipboard_busy:bool = false
#剪贴板要带走的电路状态（开关按下、寄存器锁存、时钟相位）：键 = 手持克隆。
#克隆是预览建筑、不建电路组件，状态只能挂在旁边，放置时按克隆取回
var _clip_states:Dictionary[SWBuildItemDefine,Dictionary] = {}
#待执行的放置任务队列，每项 = 一个锚点批次
var _place_jobs:Array[Dictionary] = []
var _place_running:bool = false
#进度条口径：总建筑数 / 已入图数 / 已求值数（求值按 100% 进度补满另一半）
var _place_total:int = 0
var _place_created:int = 0
var _place_evaluated:int = 0
var _job_start_msec:int = 0
var _job_last_pct:float = 0.0
#清空世界时自增：正在 await 的任务发现代数变了就自行退出
var _job_epoch:int = 0

#tag 放置是否允许（复制准备期间禁止；放置任务进行中允许继续放置）
func can_place() -> bool:
	return not _clipboard_busy

#tag 擦除是否允许（后台任务期间禁止：会打断分阶段的电路重建）
func can_erase() -> bool:
	return not _clipboard_busy and not _place_running

#tag 复制/剪切/粘贴是否允许
func can_edit_clipboard() -> bool:
	return not _clipboard_busy and not _place_running

func is_clipboard_busy() -> bool:
	return _clipboard_busy

func is_job_running() -> bool:
	return _clipboard_busy or _place_running

func set_hud_view(hud:SWHudLayer) -> void:
	_hud_view = hud

# 任务进行中又收到保存/加载请求：直接把提示写进进度条
func notify_job_busy(text:String) -> void:
	if _hud_view != null:
		_hud_view.show_job_progress(text, _job_last_pct)

# 进度条只在任务真的慢到看得见时才出现
func _job_report(text:String, pct:float) -> void:
	_job_last_pct = pct
	if _hud_view == null:
		return
	if not _hud_view.is_job_progress_visible() and Time.get_ticks_msec() - _job_start_msec < JOB_UI_DELAY_MSEC:
		return
	_hud_view.show_job_progress(text, pct)

func _job_hide() -> void:
	_job_last_pct = 0.0
	if _hud_view != null:
		_hud_view.hide_job_progress()

# 复制/剪切准备：分帧建好「手持本体 + 阴影占位」两份克隆，全部构建完成后再显示。
# 准备期间手持不可见，复制/剪切/放置都被闸门挡住。
func _start_clipboard_job(builds:Array[SWBuildItemDefine], center:Vector2i) -> void:
	var v := _get_view()
	if v == null or _hold_system == null:
		return
	#状态在源建筑还在（剪切也已读过一遍）时取一次，后续只按克隆取用
	_clip_states.clear()
	var states:Array[Dictionary] = []
	states.resize(builds.size())
	for k in builds.size():
		states[k] = builds[k].save_state()
	var tree:SceneTree = v.get_tree()
	if tree == null:
		for k in builds.size():
			if not states[k].is_empty():
				_clip_states[builds[k]] = states[k]
		#无场景树（纯逻辑测试）：退回一次建完
		_hold_system.set_hold_builds(builds, center)
		return
	_clipboard_busy = true
	_job_start_msec = Time.get_ticks_msec()
	var epoch:int = _job_epoch
	_hold_system.clear_hold_for_prepare()
	var shadow_define := _hold_system.get_hold_shadow_define()
	var draw_data := SWDrawData.new()
	var shadow_data := SWDrawData.new()
	var total:int = builds.size()
	var i:int = 0
	while i < total:
		var t0:int = Time.get_ticks_usec()
		while i < total:
			var src:SWBuildItemDefine = builds[i]
			var rel_pos:Vector2i = src.buildAxisPos - center
			#预览克隆不建电路组件：手持建筑完全不参与电路
			var clone := SwDefine.SWBuildCreator(rel_pos, src.buildDefine, src.rotation, true)
			draw_data.mapDatas.append(clone)
			if not states[i].is_empty():
				_clip_states[clone] = states[i]
				_apply_preview_state(clone, states[i])
			if shadow_define != null:
				shadow_data.mapDatas.append(SwDefine.SWBuildCreator(rel_pos, shadow_define, src.rotation, true))
			i += 1
			if Time.get_ticks_usec() - t0 >= JOB_SLICE_USEC:
				break
		_job_report("准备复制 %d/%d" % [i, total], 0.7 * float(i) / float(total))
		if i < total:
			await tree.process_frame
			if epoch != _job_epoch:
				return
	#先把区块挂上去但不显示，构建完成后统一上屏
	_hold_system.install_prepared_hold(draw_data, shadow_data, false)
	var pending0:int = maxi(_hold_system.get_hold_pending_count(), 1)
	while not _hold_system.is_hold_render_idle():
		var left:int = _hold_system.get_hold_pending_count()
		_job_report("构建手持预览 %d/%d" % [maxi(pending0 - left, 0), pending0],
			0.7 + 0.3 * clampf(1.0 - float(left) / float(pending0), 0.0, 1.0))
		await tree.process_frame
		if epoch != _job_epoch:
			return
	_hold_system.set_hold_visible(true)
	_clipboard_busy = false
	_job_hide()

#手持克隆不建电路组件，静态状态只能体现在贴图帧上（按下的开关、锁存为高的寄存器）
func _apply_preview_state(clone:SWBuildItemDefine, state:Dictionary) -> void:
	var on:bool
	if state.has("q"):
		on = int(state["q"]) == int(SwDefine.CircuitSignal.HIGH)
	elif clone is SWBuildButton:
		on = state.get("pressed", false)
	else:
		return
	var tex:AtlasTexture = clone.buildDefine.atlasTextureOn if on else clone.buildDefine.atlasTextureOff
	clone.getRenderableCompoent().drawRect = tex.region

# 放置循环：先把任务队列里的建筑分片建出来，再对这批建筑做分阶段电路求值。
# 求值期间可以继续放置（新任务排在队列里），循环会自动接着跑。
func _run_place_loop() -> void:
	var v := _get_view()
	if v == null or _place_running:
		return
	var tree:SceneTree = v.get_tree()
	if tree == null:
		_flush_place_jobs_sync()
		return
	_place_running = true
	_job_start_msec = Time.get_ticks_msec()
	var epoch:int = _job_epoch
	while true:
		while not _place_jobs.is_empty():
			await _run_place_slice(tree)
			if epoch != _job_epoch:
				return
		if _pendingPlacedBuilds.is_empty():
			break
		var batch:Array[SWBuildItemDefine] = _pendingPlacedBuilds.keys()
		_pendingPlacedBuilds.clear()
		await _eval_placed_batch(batch, tree)
		if epoch != _job_epoch:
			return
	_place_running = false
	_place_total = 0
	_place_created = 0
	_place_evaluated = 0
	_job_hide()

# 一片放置：按 JOB_SLICE_USEC 建建筑并入图，剩余的留到下一帧
func _run_place_slice(tree:SceneTree) -> void:
	var v := _get_view()
	if v == null:
		_place_jobs.clear()
		return
	var started:int = Time.get_ticks_usec()
	var created:Array[SWBuildItemDefine] = []
	var budget_out:bool = false
	while not _place_jobs.is_empty() and not budget_out:
		var job:Dictionary = _place_jobs[0]
		var builds:Array = job["builds"]
		var positions:Array = job["positions"]
		var pos_i:int = job["pos_i"]
		var build_i:int = job["build_i"]
		while pos_i < positions.size() and not budget_out:
			var grid_pos:Vector2i = SwCommon.GetGridPos(positions[pos_i])
			while build_i < builds.size():
				var tmpl:SWBuildItemDefine = builds[build_i]
				var new_build := SwDefine.SWBuildCreator(tmpl.buildAxisPos + grid_pos, tmpl.buildDefine, tmpl.rotation)
				if _clip_states.has(tmpl):
					new_build.load_state(_clip_states[tmpl])
				if build_manager.addBuild(new_build):
					created.append(new_build)
					_pendingPlacedBuilds[new_build] = true
				build_i += 1
				_place_created += 1
				if Time.get_ticks_usec() - started >= JOB_SLICE_USEC:
					budget_out = true
					break
			if build_i >= builds.size():
				build_i = 0
				pos_i += 1
			job["pos_i"] = pos_i
			job["build_i"] = build_i
		if pos_i >= positions.size():
			_place_jobs.pop_front()
	if not created.is_empty():
		v.refresh_builds(created)
	_report_place_progress("放置 %d/%d" % [_place_created, _place_total])
	if not _place_jobs.is_empty():
		await tree.process_frame

# 对一批已入图的建筑分阶段重建电路；求值阶段按 0..8 折算成批次内进度
func _eval_placed_batch(batch:Array[SWBuildItemDefine], tree:SceneTree) -> void:
	var eval_base:int = _place_evaluated
	var size:int = batch.size()
	var on_stage := func(stage:int, p:float) -> void:
		var frac:float = (float(stage) + clampf(p, 0.0, 1.0)) / 9.0
		_place_evaluated = eval_base + int(frac * float(size))
		_report_place_progress("求解电路 %d/%d" % [_place_evaluated, _place_total])
	var affected:Array[SWBuildItemDefine] = []
	if circuit_control:
		affected = await circuit_control.updateBuildCircuitStaged(
			batch, tree, on_stage, JOB_CIRCUIT_BUDGET_USEC, JOB_CIRCUIT_STEP)
	_place_evaluated = eval_base + size
	var notify_builds:Array[SWBuildItemDefine] = batch.duplicate()
	notify_builds.append_array(affected)
	var chunk_pos_arr = getNotifyChunkPosArr(notify_builds)
	var v := _get_view()
	if v != null:
		v.sw_draw_manager.updataChunks(chunk_pos_arr)
	for build in notify_builds:
		if build is SWBuildClockSiggen:
			addClockBuild(build)
	_report_place_progress("求解电路 %d/%d" % [_place_evaluated, _place_total])

# 进度条口径：入图与求值各占一半；任务中途追加时分母变大，进度会略微回退，符合「合并所有任务」
func _report_place_progress(text:String) -> void:
	if _place_total <= 0:
		return
	var done:int = _place_created + _place_evaluated
	_job_report(text, clampf(float(done) / float(_place_total * 2), 0.0, 1.0))

# 无场景树（纯逻辑测试）时的同步回退：一次放完并立即求值，与旧行为一致
func _flush_place_jobs_sync() -> void:
	var v := _get_view()
	var created:Array[SWBuildItemDefine] = []
	for job:Dictionary in _place_jobs:
		var builds:Array = job["builds"]
		var positions:Array = job["positions"]
		for pos in positions:
			var grid_pos:Vector2i = SwCommon.GetGridPos(pos)
			for tmpl:SWBuildItemDefine in builds:
				var new_build := SwDefine.SWBuildCreator(tmpl.buildAxisPos + grid_pos, tmpl.buildDefine, tmpl.rotation)
				if _clip_states.has(tmpl):
					new_build.load_state(_clip_states[tmpl])
				if build_manager.addBuild(new_build):
					created.append(new_build)
					_pendingPlacedBuilds[new_build] = true
	_place_jobs.clear()
	_place_total = 0
	_place_created = 0
	_place_evaluated = 0
	if not created.is_empty() and v != null:
		v.refresh_builds(created)
	if _pendingPlacedBuilds.is_empty():
		return
	var placed:Array[SWBuildItemDefine] = _pendingPlacedBuilds.keys()
	_pendingPlacedBuilds.clear()
	var notify_builds:Array[SWBuildItemDefine] = placed.duplicate()
	if circuit_control:
		notify_builds.append_array(circuit_control.updateBuildCircuit(placed))
	var chunk_pos_arr = getNotifyChunkPosArr(notify_builds)
	if v != null:
		v.sw_draw_manager.updataChunks(chunk_pos_arr)
	for build in notify_builds:
		if build is SWBuildClockSiggen:
			addClockBuild(build)
#endregion

#region 外部调用操作地图
#tag 设置手持系统
func set_hold_system(hold_sys:SWHoldLayerSystem) -> void:
	_hold_system = hold_sys
	
#tag 清除地图上所有元件
func clear_all_builds() -> void:
	#任务必须一并作废：它们引用的建筑马上就要离开地图，继续跑只会写坏电路
	_job_epoch += 1
	_place_jobs.clear()
	_place_total = 0
	_place_created = 0
	_place_evaluated = 0
	_place_running = false
	_clipboard_busy = false
	_job_hide()
	_pendingRemovedBuilds.clear()
	_pendingPlacedBuilds.clear()
	_selected_builds.clear()
	_clip_states.clear()
	clockBuildArr.clear()
	build_manager.clearAllBuilds()
	var v := _get_view()
	if v != null:
		v.sw_draw_manager.updataAllChunks()

#加载存档数据（同步版本；GUT/无 UI 场景用）
func load_save_data(data: Dictionary) -> void:
	clear_all_builds()
	var builds_arr = data.get("builds", [])
	if not builds_arr is Array:
		return
	#所有隧道：加载期 addBuild 的 on_idled 按数组顺序试探过配对，统一交给几何重配按位置确定性重建
	var unpaired_tunnels:Array[SWBuildWireTunnel] = []
	for b in builds_arr:
		_add_build_from_save(b, unpaired_tunnels)
	_repair_tunnel_pairs(unpaired_tunnels)
	circuit_control.updateBuildCircuit(build_manager.getAllBuilds())
	#时钟不依赖放置操作注册：加载后统一扫描，保证存档里的计数器自动运行
	_rebuild_clock_registry()
	_refresh_after_load()

#读档分帧版本：建建筑按 LOAD_BUILD_STEP 一批、电路重建按 STAGED_STEP 一批，
#两批之间让出主线程刷进度条。阶段顺序与 load_save_data 完全一致
#（重建结果对建筑遍历顺序敏感，不能跳步也不能重排）。
#on_progress.call(percent:float, text:String)
const LOAD_BUILD_STEP:int = 512
const LOAD_BUILD_BUDGET_USEC:int = 50000
const LOAD_STAGE_TEXT:Array[String] = ["连接电路", "清空旧电路", "重建端口", "建立网络", "整理网络", "绑定电路", "构建表达式", "划分电路", "求解电路"]
func load_save_data_async(data: Dictionary, on_progress:Callable = Callable()) -> void:
	var v := _get_view()
	var tree:SceneTree = v.get_tree() if v != null else null
	if tree == null:
		load_save_data(data)
		return
	_report_progress(on_progress, 0.0, "清空地图")
	clear_all_builds()
	var builds_arr = data.get("builds", [])
	if not builds_arr is Array:
		return
	var total:int = builds_arr.size()
	var unpaired_tunnels:Array[SWBuildWireTunnel] = []
	var i:int = 0
	while i < total:
		var t0:int = Time.get_ticks_usec()
		while i < total:
			var next:int = mini(i + LOAD_BUILD_STEP, total)
			for k in range(i, next):
				_add_build_from_save(builds_arr[k], unpaired_tunnels)
			i = next
			if Time.get_ticks_usec() - t0 >= LOAD_BUILD_BUDGET_USEC:
				break
		_report_progress(on_progress, 0.02 + 0.48 * float(i) / float(total), "创建建筑 %d/%d" % [i, total])
		if i < total:
			await tree.process_frame
	_repair_tunnel_pairs(unpaired_tunnels)
	_report_progress(on_progress, 0.50, "连接电路")
	await tree.process_frame
	var allBuilds:Array[SWBuildItemDefine] = build_manager.getAllBuilds()
	await circuit_control.updateBuildCircuitStaged(allBuilds, tree, func(stage:int, p:float) -> void:
		_report_progress(on_progress, 0.50 + 0.45 * (float(stage) + p) / 9.0, LOAD_STAGE_TEXT[stage]))
	_report_progress(on_progress, 0.98, "刷新画面")
	await tree.process_frame
	#时钟注册放在最后一次让帧之后：注册即开始走拍，提前注册会多跑一拍计数器
	_rebuild_clock_registry()
	_refresh_after_load()
	_report_progress(on_progress, 1.0, "完成")

func _report_progress(on_progress:Callable, pct:float, text:String) -> void:
	if on_progress.is_valid():
		on_progress.call(clampf(pct, 0.0, 1.0), text)

func _refresh_after_load() -> void:
	var v := _get_view()
	if v != null:
		v.sw_draw_manager.updataAllChunks()
		v.sw_draw_manager.on_view_rect_changed()

#存档的一条建筑记录 -> 建筑对象并加入地图；失败返回 null
func _add_build_from_save(b:Dictionary, unpaired_tunnels:Array[SWBuildWireTunnel]) -> SWBuildItemDefine:
	var pos_dict = b.get("pos", {})
	var def_name = b.get("def", "")
	var rot = b.get("rot", 0)
	var comp_type = b.get("comp_type", 0)
	var circuit_on = b.get("circuit_on", false)
	var signal_state = b.get("signal_state", 0)
	var in_loop = b.get("in_loop", false)
	var pos = Vector2i(pos_dict.get("x", 0), pos_dict.get("y", 0))
	var def_path = "res://res/" + def_name + ".tres"
	var build_def = load(def_path) as SWBuildDefine
	if not build_def:
		return null
	var build = SwDefine.SWBuildCreator(pos, build_def, rot)
	build.circuit_on = circuit_on
	build.signal_state = signal_state
	build.in_loop = in_loop
	#存档里的 tunnel_pair_id 是上一次会话的 build id，加载时 id 重新分配，直接采信会指向
	#不相干的建筑甚至空引用（connectWireGroup 会拿到 Nil）。一律不恢复，交给几何重配统一重建。
	if build is SWBuildWireTunnel:
		unpaired_tunnels.append(build)
	#元件内部状态（开关按下、时钟电平、寄存器锁存）在重建电路前恢复
	build.load_state(b.get("state", {}))
	build_manager.addBuild(build)
	return build
#endregion

#region buildLayer事件(剪切、复制、删除选中、建筑物点击)
#tag buildLayer剪切
func _do_cut() -> void:
	if not can_edit_clipboard():
		return
	if _selected_builds.size() == 0 or not _hold_system:
		return
	var builds:Array[SWBuildItemDefine] = _selected_builds.keys()
	var center := _getSelectedBuildCenter()
	_selected_builds.clear()
	#源建筑立即删除：克隆只依赖定义/坐标/朝向，删除不影响后续分帧创建
	var notifyChunkPosArr = getNotifyChunkPosArr(builds)
	build_manager.delBuilds(builds)
	var v := _get_view()
	if v != null:
		v.sw_draw_manager.updataChunks(notifyChunkPosArr)
	_start_clipboard_job(builds, center)

#tag buildLayer复制
func _do_copy() -> void:
	if not can_edit_clipboard():
		return
	if _selected_builds.size() == 0 or not _hold_system:
		return
	var builds:Array[SWBuildItemDefine] = _selected_builds.keys()
	var center := _getSelectedBuildCenter()
	var notifyChunkPosArr = getChunkPosArrOf(builds)
	for build in builds:
		build_manager.setBuildState(build,SwDefine.BuildState.IDLE)
	_selected_builds.clear()
	var v := _get_view()
	if v != null:
		#复制后选中圈只是恢复原底色：同样走增量颜色补丁（LOD 下也要恢复）
		v.sw_draw_manager.updataChunks(notifyChunkPosArr, builds, {}, 250000, true)
	_start_clipboard_job(builds, center)

#tag buildLayer删除选中
func _do_delete_selected() -> void:
	if _selected_builds.size() == 0:
		return
	var builds:Array[SWBuildItemDefine] = []
	for build in _selected_builds:
		builds.append(build)
	var notifyChunkPosArr = getNotifyChunkPosArr(builds)
	_selected_builds.clear()
	build_manager.delBuilds(builds)
	var v := _get_view()
	if v != null:
		v.sw_draw_manager.updataChunks(notifyChunkPosArr)

#tag buildLayer删除选中、剪切、复制
func _on_event_key(event: InputEventKey) -> bool:
	if event.is_pressed():
		#后台任务期间的增删会打乱分阶段重建的中间态，也违反「任务未完成禁用复制/剪切」
		if _clipboard_busy or _place_running:
			return false
		if event.keycode == KEY_DELETE:
			_do_delete_selected()
			return true
		if event.ctrl_pressed and _selected_builds.size() > 0:
			if event.keycode == KEY_X:
				_do_cut()
				return true
			elif event.keycode == KEY_C:
				_do_copy()
				return true
	return false
	
#tag buildLayer左键按下	
func _on_left_pressed(v:SWBuildLayer) -> bool:
	#任务期间点按钮会在半重建的电路上做增量求值，直接忽略这次点击
	if _clipboard_busy or _place_running:
		return false
	var viewport := v.get_viewport()
	var mouse_pos := viewport.get_mouse_position()
	var world_pos = SwCommon.GetGlobalPosByViewPos(mouse_pos, viewport)
	var grid_pos:Vector2i = SwCommon.GetGridPos(Vector2i(world_pos))
	var build = build_manager.getBuild(grid_pos)
	#print("[Build] grid=", grid_pos, " build=", build, " total=", build_manager.getAllBuilds().size())
	if build and (build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.BUTTON or build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.SWITCH):
		if build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.BUTTON:
			#tag 地图上的元件被点击
			build.onPressed(true)
		elif build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.SWITCH:
			build.onPressed(!build.pressed)
		var newBuilds = circuit_control.buildSignalChanged(build)
		newBuilds.append(build)
		refresh_signal_chunks(newBuilds)
		if build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.BUTTON:
			_pressed_button_pos = grid_pos
		v.get_viewport().set_input_as_handled()
		return true
	return false
	
#tag buildLayer左键释放
func _on_left_released(v:SWBuildLayer) -> bool:
	if _clipboard_busy or _place_running:
		return false
	if _pressed_button_pos != Vector2i(-9999, -9999):
		var grid_pos:Vector2i = SwCommon.GetGridPos(Vector2i(_pressed_button_pos))
		var build = build_manager.getBuild(grid_pos)
		if build and (build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.BUTTON or build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.SWITCH):
			if build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.BUTTON:
				#tag 地图上的元件被点击释放
				build.onPressed(false)
			elif build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.SWITCH:
				pass
			var newBuilds = circuit_control.buildSignalChanged(build)
			newBuilds.append(build)
			refresh_signal_chunks(newBuilds)
		_pressed_button_pos = Vector2i(-9999, -9999)
		return true
	return false
	
#tag buildLayer鼠标事件
func _on_event_mouse_button(event: InputEventMouseButton) -> bool:
	var v := _get_view()
	if v == null:
		return false
	if event.is_pressed():
		if event.button_index == MOUSE_BUTTON_LEFT:
			_on_left_pressed(v)
	elif event.is_released():
		if event.button_index == MOUSE_BUTTON_LEFT:
			_on_left_released(v)
	return false
	
#tag buildLayer事件
func handle_input(event: InputEvent) -> bool:
	if _get_view() == null:
		return false
	if event is InputEventKey:
		return _on_event_key(event as InputEventKey)
	elif event is InputEventMouseButton:
		return _on_event_mouse_button(event as InputEventMouseButton)
	return false
	
#endregion

#region 建筑物时钟每帧更新
#tag 建筑物时钟每帧更新
var clockBuildArr:Dictionary[SWBuildItemDefine,bool] = {}
#时钟节拍 ≈ 1/30 秒。按挂钟时间判定，不用物理 delta：慢帧时物理会补跑多个子步，
#照 delta 累加会让同一帧里叠出好几拍
const CLOCK_GAP_USEC:int = 33333
#本帧是否已处理过电路拍：一帧最多一拍，切断「掉帧→传播次数翻倍→更卡」的正反馈
var _last_tick_frame:int = -1
var _last_clock_usec:int = 0
func addClockBuild(build:SWBuildItemDefine) -> void:
	clockBuildArr[build]=true
func delClockBuild(build:SWBuildItemDefine) -> void:
	clockBuildArr.erase(build)

#按当前建筑表重建时钟注册表：加载存档、批量删除后调用
func _rebuild_clock_registry() -> void:
	clockBuildArr.clear()
	for build in build_manager.getAllBuilds():
		if build is SWBuildClockSiggen:
			clockBuildArr[build] = true

#加载存档后重建隧道配对：addBuild 的 on_idled 依赖放置顺序，
#批量加载时同一对隧道可能互相错过甚至配错，这里按几何位置确定性地重配。
#存档里的 tunnel_pair_id 存的是旧会话 id，加载时不恢复，所以这里面对的是全部隧道。
func _repair_tunnel_pairs(unpaired:Array[SWBuildWireTunnel]) -> void:
	if unpaired.is_empty():
		return
	for t in unpaired:
		#撤销加载期 on_idled 按数组顺序做出的试探配对
		t.pairId = -1
	#左→右、上→下，保证"最近的前方隧道"这一配对结果与加载顺序无关
	unpaired.sort_custom(func(a:SWBuildWireTunnel,b:SWBuildWireTunnel) -> bool:
		return a.buildAxisPos.x < b.buildAxisPos.x if a.buildAxisPos.x != b.buildAxisPos.x else a.buildAxisPos.y < b.buildAxisPos.y)
	for t in unpaired:
		if t.pairId != -1:
			continue
		var dir:int = posmod(t.rotation+1,4)
		var vec:Vector2i = SwDefine.dir_to_vec(dir)*SwDefine.GRID_SIZE
		for dis in SwDefine.MAX_TUNNEL_DIS+1:
			var other := build_manager.getBuild(t.buildAxisPos+vec*(1+dis)) as SWBuildWireTunnel
			if other == null or other == t or other.pairId != -1:
				continue
			#对方引脚必须朝向本隧道，方向不对的继续往前找
			if not other.pinFaces(SwDefine.getAntiDir(dir)):
				continue
			t.pairId = other.id
			other.pairId = t.id
			break
# ===== 临时实验开关：绕过电路，强制所有已加载区块每拍全部翻转并整块重绘 =====
# true  = 渲染压测（电路不驱动建筑，脏率拉满 100%）
# false = 恢复原电路 tick
const RENDER_STRESS := false
var _stressFlip:bool = false

func tick(_delta: float,_tick_index:int) -> void:
	#return
	#放置任务的电路重建是分帧进行的：中间态下跑时钟增量求值会把电路写坏
	if _place_running:
		return
	var frame:int = Engine.get_process_frames()
	if frame == _last_tick_frame:
		return
	_last_tick_frame = frame
	var now:int = Time.get_ticks_usec()
	if _last_clock_usec == 0:
		_last_clock_usec = now
		return
	if now - _last_clock_usec < CLOCK_GAP_USEC:
		return
	#不补拍：帧率低于 30 时时钟降到帧率，换来单帧电路开销封顶
	_last_clock_usec = now
	if RENDER_STRESS:
		_stress_render_all()
		return
	var clocks:Array[SWBuildItemDefine] = []
	clocks.assign(clockBuildArr.keys())
	for build in clocks:
		build.onPressed(true)
	var changedBuilds := circuit_control.buildSignalsChanged(clocks)
	#整屏冻结档位（LOD2）：补丁会被 _patch_chunk 直接丢弃，
	#脏区块/脏 net/逐建筑标脏全都不必登记。求值照跑（寄存器不能停），
	#回 LOD0 时 on_atlas_lod_changed 会整屏补齐颜色与图集帧
	if SwAtlas.is_frame_updates_frozen():
		return
	refresh_signal_chunks(changedBuilds)

# 每拍翻转全局信号值：写入各建筑 signal_state 与其所在 net 的 curSignal，
# 再让所有建筑按新信号值刷新（颜色 + 图集帧），并整块重绘所有已加载区块（纯渲染压测）
func _stress_render_all() -> void:
	var v := _get_view()
	if v == null:
		return
	var dm = v.sw_draw_manager
	var chunkPosArr:Array[Vector2i] = dm.get_loaded_chunk_positions()
	_stressFlip = not _stressFlip
	var sig:SwDefine.CircuitSignal = SwDefine.CircuitSignal.HIGH if _stressFlip else SwDefine.CircuitSignal.LOW
	for cp in chunkPosArr:
		for b:SWBuildItemDefine in build_manager.getBuildsByChunkPos(cp):
			# 修改信号值：建筑自身状态（LED/非门/寄存器据此换图集帧）+ 所连 net 的电平
			b.buildStateChanged(sig)
			var cir:SWBuildCompoentCircuit = b.getCircuitCompoent()
			if cir != null:
				for net in cir.pinNetMap.values():
					if net != null:
						net.curSignal = sig
			# 按新信号值刷新建筑：颜色重算 + 图集帧 rect 回写（不重建部件/几何）
			b.markColorDirty()
			b.markAtlasRectDirty()
	dm.updataChunks(chunkPosArr)
#endregion
