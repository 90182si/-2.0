class_name SWBuildLayerSystem extends SWLayerSystem

#跨场景会话：电路结构改动要记进去，机器人场景回来看它决定「先停节拍、重载最新电路」
const SESSION := preload("res://core/manager/sw_session.gd")

#左键点到接口元件（外部输入/输出）：请求 HUD 打开名称编辑面板
signal edit_build_requested(build:SWBuildItemDefine)

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
#replace 作业（Ctrl 覆盖 / 相交换桥梁）拆下来的旧元件：先攒着，本批放完再统一做电路善后
var _pendingReplacedBuilds:Dictionary[SWBuildItemDefine,bool] = {}
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
# 只登记放置任务：克隆与入图都交给分片循环，一次落笔放下上万建筑会卡住整帧。
# 同一位置的连续落笔会排成多个任务，进度条按所有任务的总建筑数合并计算。
# replace = 这一批落点上有元件的先拆掉再放（Ctrl 覆盖、电线相交换桥梁都走这条路）
func on_hold_idle_builds(builds:Array[SWBuildItemDefine],positions:Array,replace:bool = false) -> void:
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
		"replace": replace,
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
	if _get_view() == null:
		return
	if _pendingRemovedBuilds.is_empty():
		return
	var removedBuilds:Array[SWBuildItemDefine] = _pendingRemovedBuilds.keys()
	_pendingRemovedBuilds.clear()
	# 统一善后：重建电路 + 清时钟注册（与 _do_cut / _do_delete_selected 走同一条路径，
	# 避免某些删除方式漏掉电路更新，导致地图上已经没了的电路还在跑）；
	# 区块刷新也交给善后入口（大批量时要等它先抹掉画面再分帧重建）
	_start_remove_followup(removedBuilds, getNotifyChunkPosArr(removedBuilds))

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
		# 已标待删除（分帧删除进行中，建筑还在表里）：选中它没有意义，
		# 而且之后又会被 Delete 一次
		if build.bIsToBeRemoved():
			continue
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

#信号变化后的统一刷新入口（纹理化）：翻转的 net 电平写进信号纹理，
#不再逐建筑打脏/回写实例缓冲（tick 60Hz 下实例上传量降为 0，只剩脏帧 64KB 纹理上传）。
#一帧内多次调用共享一次 texture.update（SWSignalTexture 内部标脏，每帧最多一次 flush）。
#返回本次实际写入的 net 数（供性能统计；语义从「区块数」变为「net 数」）
func refresh_signal_chunks(changedBuilds:Array[SWBuildItemDefine]) -> int:
	var tex:SWSignalTexture = SWSignalTexture.instance
	var nets:Dictionary = circuit_control.takeDirtyNets()
	if tex == null:
		return 0
	# 帧槽（LED/寄存器/非门/按钮亮灭）也可能独立标脏：nets 为空但纹理脏时也要 flush。
	# GPU LED resolve 下灯泡每帧都要重算（GPU 端不做「变化才刷」），led_pending 也算待刷。
	# 表同步必须放在早退判断之前：表里没灯泡时 led_pending 为假，早退会把「重建表」卡住。
	if tex.has_led_pass():
		circuit_control.sync_led_gpu_table()
	if nets.is_empty() and not tex.is_dirty() and not tex.led_pending():
		return 0
	var count:int = 0
	for net in nets:
		if net == null or net.netId < 0:
			continue
		if net.curSignal != net.paintedSignal:
			tex.set_level(net.netId, net.curSignal == SwDefine.CircuitSignal.HIGH)
			net.paintedSignal = net.curSignal
			count += 1
	tex.flush()
	return count

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
# 一次删除超过这个数才转「分帧善后」：全删几十个元件时同步跑完，
# 等一帧反而让 Delete 键像是没反应
const BULK_REMOVE_THRESHOLD:int = 2048
# 取重建种子时每次进函数的建筑数（粒度与电路重建的 STAGED_STEP 同量级）
const JOB_REMOVE_STEP:int = 256
# 分帧删除时每批喂给 delBuilds 的建筑数：一批约 6~7ms，能守住 JOB_SLICE_USEC
const JOB_REMOVE_DEL_STEP:int = 1024

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
#删除善后（重建电路 + 清时钟）分帧进行中：期间挡掉新的增删 / 复制 / 读存
var _remove_busy:bool = false

#tag 放置是否允许（复制准备 / 删除善后期间禁止；放置任务进行中允许继续放置）
func can_place() -> bool:
	return not _clipboard_busy and not _remove_busy

#tag 擦除是否允许（后台任务期间禁止：会打断分阶段的电路重建）
func can_erase() -> bool:
	return not _clipboard_busy and not _place_running and not _remove_busy

#tag 复制/剪切/粘贴是否允许
func can_edit_clipboard() -> bool:
	return not _clipboard_busy and not _place_running and not _remove_busy

func is_clipboard_busy() -> bool:
	return _clipboard_busy

func is_job_running() -> bool:
	return _clipboard_busy or _place_running or _remove_busy

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
		#拆下来的旧元件先做电路善后（拆电路 + 清时钟注册 + 刷区块），再对新元件求值
		_flush_replaced_removed()
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
				if job.get("replace", false):
					_remove_for_replace(new_build.buildAxisPos)
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

# replace 作业：落点这一格已经有元件就先拆下来（一格一建筑，不拆 addBuild 直接失败）。
# 拆下来的旧元件不马上重建电路，只先记账：分片循环可能跨好几帧，逐格重建会把同一批
# 邻居重算十几遍；本批新件全部入图后再统一善后一次
func _remove_for_replace(axis_pos:Vector2i) -> void:
	var old:SWBuildItemDefine = build_manager.getBuild(axis_pos)
	if old == null:
		return
	build_manager.setBuildState(old,SwDefine.BuildState.TO_BE_REMOVED)
	var olds:Array[SWBuildItemDefine] = [old]
	build_manager.delBuilds(olds)
	_pendingReplacedBuilds[old] = true

# 把拆下来的旧元件走一遍删除善后（与擦除释放走同一条路径：重建电路 + 清时钟注册）。
# 这里固定走同步版：每次 replace 只拆一格，量很小；同一个放循环里再排一个分帧任务
# 会跟进度条口径（_place_created/_place_evaluated）互相污染
func _flush_replaced_removed() -> void:
	if _pendingReplacedBuilds.is_empty():
		return
	var v := _get_view()
	var gone:Array[SWBuildItemDefine] = _pendingReplacedBuilds.keys()
	_pendingReplacedBuilds.clear()
	var notifyChunkPosArr:Array = getNotifyChunkPosArr(gone)
	_notify_circuit_after_removed(gone, notifyChunkPosArr)
	if v != null:
		v.sw_draw_manager.updataChunks(notifyChunkPosArr)

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
		else:
			_register_io_port(build)
	#放完就是改过结构了：机器人场景回来要按最新电路重绑
	_mark_circuit_edited()
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
				if job.get("replace", false):
					_remove_for_replace(new_build.buildAxisPos)
				if build_manager.addBuild(new_build):
					created.append(new_build)
					_pendingPlacedBuilds[new_build] = true
	_place_jobs.clear()
	_place_total = 0
	_place_created = 0
	_place_evaluated = 0
	if not created.is_empty() and v != null:
		v.refresh_builds(created)
	_flush_replaced_removed()
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
		else:
			_register_io_port(build)
	_mark_circuit_edited()
#endregion

#region 外部调用操作地图
#tag 设置手持系统
func set_hold_system(hold_sys:SWHoldLayerSystem) -> void:
	_hold_system = hold_sys
	#手持层做电线拖拽时要预判「这一格有没有东西」，建筑表只在这里暴露一个只读入口
	hold_sys.set_cell_probe(Callable(self, "get_build_at"))

#tag 取某格上的建筑物（不做任何修改，供拖拽预览判占用）
func get_build_at(grid_pos:Vector2i) -> SWBuildItemDefine:
	return build_manager.getBuild(grid_pos)
	
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
	_remove_busy = false
	_job_hide()
	_pendingRemovedBuilds.clear()
	_pendingPlacedBuilds.clear()
	_pendingReplacedBuilds.clear()
	_selected_builds.clear()
	_clip_states.clear()
	clockBuildArr.clear()
	io_input_arr.clear()
	io_output_arr.clear()
	#上一份世界的电路/编译产物/求值引擎必须跟着一起释放：它们反引用着旧建筑，
	#只清建筑表的话，换几次存档就残留几份完整世界（这是内存冲上 2GB 的主因）
	if circuit_control:
		circuit_control.clearAllCircuits()
	build_manager.clearAllBuilds()
	# netId 全局计数整体作废：全量清除后从 0 重新分配，防旧会话 id 与新 net 冲突；
	# 帧槽（LED/寄存器/非门/按钮亮灭的 shader 帧选择）同步重置
	if circuit_control:
		circuit_control.resetNetIdCounter()
	var tex := SWSignalTexture.instance
	if tex != null:
		tex.resetFrameSlots()
	var v := _get_view()
	if v != null:
		# 区块上的建筑引用与 CPU 缓冲也属于旧世界，先彻底清掉再标记全量重建
		v.sw_draw_manager.clearChunkCaches()
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
	if MEM_AUDIT_ON_LOAD:
		print_memory_audit("清空后")
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
	if MEM_AUDIT_ON_LOAD:
		print_memory_audit("建筑建完")
	_report_progress(on_progress, 0.50, "连接电路")
	await tree.process_frame
	var allBuilds:Array[SWBuildItemDefine] = build_manager.getAllBuilds()
	await circuit_control.updateBuildCircuitStaged(allBuilds, tree, func(stage:int, p:float) -> void:
		_report_progress(on_progress, 0.50 + 0.45 * (float(stage) + p) / 9.0, LOAD_STAGE_TEXT[stage]))
	if MEM_AUDIT_ON_LOAD:
		print_memory_audit("电路建完")
		# 单独看程序侧规模：这两张缓存每项都是「电路 → 整份 gate 表」，是除建筑外最大的候选
		print("[MEM]prog compiled: gates=%d slots=%d | simplified: gates=%d slots=%d" % [
				_sum_prog_field(circuit_control._compiled_progs, "gate_count"),
				_sum_prog_field(circuit_control._compiled_progs, "slot_count"),
				_sum_prog_field(circuit_control._simplified_progs, "gate_count"),
				_sum_prog_field(circuit_control._simplified_progs, "slot_count")])
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
	#首轮求值只把新电平写进 net.curSignal 与脏集，纹理要等下一次 tick 才刷；
	#读档后先消费一次脏集，电线颜色才能和贴图一起立刻正确
	var changed:Array[SWBuildItemDefine] = []
	refresh_signal_chunks(changed)
	var v := _get_view()
	if v != null:
		v.sw_draw_manager.updataAllChunks()
		v.sw_draw_manager.on_view_rect_changed()
	if MEM_AUDIT_ON_LOAD:
		print_memory_audit("读档后")

# 读档各阶段打一行 [MEM] 汇总（内存诊断开关，排查完可置 false）
const MEM_AUDIT_ON_LOAD: bool = true
# ========== 内存诊断 ==========
# 读档结束后打一行汇总：静态内存总量 + 各主要容器的条目数。
# 比对着看就能判断「内存是不是随读档次数上涨」（上涨 = 旧世界还被人引用着），
# 也能看出大头在建筑侧、电路程序侧还是区块缓冲侧。不需要时把开关置 false。
func print_memory_audit(tag: String = "") -> void:
	if build_manager == null:
		return
	var builds:int = build_manager.getBuildCount()
	var circuits:int = 0
	var progs:String = "0/0/0/0"
	var nets:int = 0
	var neighbors:int = 0
	if circuit_control != null:
		circuits = circuit_control.circuits.size()
		progs = "%d/%d/%d/%d" % [circuit_control._compiled_progs.size(),
				circuit_control._simplified_progs.size(),
				circuit_control._cpu_backends.size(),
				circuit_control._gpu_backends.size()]
		nets = circuit_control._netById.size()
		neighbors = circuit_control._neighborsCache.size()
	var chunks:int = 0
	var idle_cache:int = 0
	var chunk_buf_bytes:int = 0
	var v := _get_view()
	if v != null and v.sw_draw_manager != null:
		var dm = v.sw_draw_manager
		chunks = dm._chunkInstance.size()
		idle_cache = dm._idleChunkCache.size()
		for chunkIns:SwDefine.SWDrawChunkData in dm._chunkInstance.values():
			if chunkIns.mesh_instance != null:
				chunk_buf_bytes += chunkIns.mesh_instance._cpuBuffer.size() * 4
	print("[MEM]%s static=%.1fMB obj=%d orphan=%d builds=%d circuits=%d prog(c/s/cpu/gpu)=%s nets=%d neighbors=%d chunks=%d idleCache=%d chunkBuf=%.1fKB" % [
		tag,
		float(OS.get_static_memory_usage()) / (1024.0 * 1024.0),
		int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		builds, circuits, progs, nets, neighbors, chunks, idle_cache,
		float(chunk_buf_bytes) / 1024.0])

# 汇总一张「电路 → SWGateProgram」缓存里某个字段的总和（内存诊断用，读档后跑一次）
func _sum_prog_field(progs:Dictionary, field:String) -> int:
	var total:int = 0
	for prog in progs.values():
		if prog != null:
			total += int(prog.get(field))
	return total

#存档里的旧定义名 -> 现定义名（合并过的元件：旧存档不能因此读不回来）
const DEF_NAME_ALIAS:Dictionary = {
	"输出接口move":"输出接口",
	"输出接口rotation":"输出接口",
}

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
	#定义资源已被合并：先按名字直取，取不到再走别名表（旧存档里的 move/rotation 两个定义）。
	#必须先 ResourceLoader.exists：旧定义名对应的 .tres 已删，直接 load 会往控制台喷一条错误
	var def_path = "res://res/" + str(def_name) + ".tres"
	if not ResourceLoader.exists(def_path) and DEF_NAME_ALIAS.has(def_name):
		def_path = "res://res/" + str(DEF_NAME_ALIAS[def_name]) + ".tres"
	var build_def = load(def_path) as SWBuildDefine if ResourceLoader.exists(def_path) else null
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
	var notifyChunkPosArr = getNotifyChunkPosArr(builds)
	# 电路必须重建：不重建的话时钟注册表还留着被删的时钟，
	# 每帧继续 tick → 已经删掉的电路还在跑（用户反馈的「删除后电路依旧在跑」）。
	# 剪切还要接着做分帧克隆：两个异步任务会抢进度条，所以排到重建完之后再开工；
	# 克隆只依赖定义/坐标/朝向/元件状态（源对象由 builds 持有，删表不影响）
	_start_remove_and_followup(builds, notifyChunkPosArr,
		func() -> void: _start_clipboard_job(builds, center))

#tag buildLayer删除选中
func _do_delete_selected() -> void:
	if _selected_builds.size() == 0:
		return
	var builds:Array[SWBuildItemDefine] = []
	for build in _selected_builds:
		builds.append(build)
	var notifyChunkPosArr = getNotifyChunkPosArr(builds)
	_selected_builds.clear()
	# 标记与真正离表都交给善后任务：一次删 7w 时同步删要占住一帧 400+ms
	_start_remove_and_followup(builds, notifyChunkPosArr)

# 删除建筑后统一善后（同步版）：重建电路 + 从时钟注册表移除被删的时钟。
# 把「重建电路」和「清时钟」绑在一起，避免任何删除路径漏掉其中一步
# （历史上 _do_cut / _do_delete_selected 就漏了整段，导致删掉的时钟仍在驱动电路求值）。
# removed 会被就地追加「受影响的建筑」，供调用方一起刷新区块。
# 一次删上万个元件请走 _start_remove_followup（它会转成分帧版）。
func _notify_circuit_after_removed(removed:Array[SWBuildItemDefine],
		notifyChunkPosArr:Array) -> void:
	# 1) 重建电路：只重建还活着的建筑，把受影响的区块并进通知集
	if circuit_control != null:
		var seeds:Array[SWBuildItemDefine] = circuit_control.collectRemoveSeeds(removed)
		var affected:Array[SWBuildItemDefine] = circuit_control.updateBuildCircuit(seeds)
		# 被删建筑独占的旧电路不会有活成员去 reset，必须在这里摘掉，
		# 否则 circuits / 编译产物 / 求值后端 / 信号纹理槽位会一路泄漏
		circuit_control.dropCircuits(circuit_control.detachRemoved(removed))
		_append_affected_chunks(affected, notifyChunkPosArr)
	# 2) 清时钟注册
	_cleanup_clocks_after_removed(removed)
	# 3) 结构改过了
	_mark_circuit_edited()

# 把受影响的建筑并进通知区块集（去重用字典：affected 可能上万，在数组上 has() 是平方级）
func _append_affected_chunks(affected:Array[SWBuildItemDefine], notifyChunkPosArr:Array) -> void:
	var seen:Dictionary[Vector2i,bool] = {}
	for cp:Vector2i in notifyChunkPosArr:
		seen[cp] = true
	for b:SWBuildItemDefine in affected:
		if b == null:
			continue
		var cp:Vector2i = SwCommon.GetChunkPos(b.buildAxisPos)
		if seen.has(cp):
			continue
		seen[cp] = true
		notifyChunkPosArr.append(cp)

# 从时钟注册表移除（含「被删的建筑本身是时钟」的情况）
func _cleanup_clocks_after_removed(removed:Array[SWBuildItemDefine]) -> void:
	for build in removed:
		if build is SWBuildClockSiggen:
			delClockBuild(build)
		else:
			io_input_arr.erase(build)
			io_output_arr.erase(build)
	# 兜底：注册表里凡是已经不在建筑表内的时钟一律清掉。
	# 只遍历注册表（通常只有几个时钟），代价可忽略；
	# 这样可以覆盖「时钟被间接删除」等没走到上面分支的情况。
	if not clockBuildArr.is_empty():
		var stale:Array[SWBuildItemDefine] = []
		for build in clockBuildArr.keys():
			if build == null or build.bIsToBeRemoved() or build_manager.getBuild(build.buildAxisPos) != build:
				stale.append(build)
		for build in stale:
			delClockBuild(build)
	# 接口元件同样兜底清一遍：删掉的输入/输出口留着会让每拍白跑一次 writeInstances
	var stale_ports:Array = []
	for build in io_input_arr.keys():
		if build == null or build.bIsToBeRemoved() or build_manager.getBuild(build.buildAxisPos) != build:
			stale_ports.append(build)
	for build in io_output_arr.keys():
		if build == null or build.bIsToBeRemoved() or build_manager.getBuild(build.buildAxisPos) != build:
			stale_ports.append(build)
	for build in stale_ports:
		io_input_arr.erase(build)
		io_output_arr.erase(build)

# 删除善后入口（建筑已经离表，比如右键擦除）：小批量同步跑完，大批量转分帧。
# 需要「先标 TO_BE_REMOVED、再分帧真正离表」的路径（Delete / 剪切）请走 _start_remove_and_followup。
# on_done 在善后全部做完后调：剪切的克隆任务靠它跟重建任务串行，不去抢进度条。
func _start_remove_followup(removed:Array[SWBuildItemDefine], notifyChunkPosArr:Array,
		on_done:Callable = Callable()) -> void:
	_start_remove_common(removed, notifyChunkPosArr, on_done, false)

# 删除入口（Delete / 剪切）：一次删 7w 时光 delBuilds 那一帧就要 400+ms。
# 先把整批标成 TO_BE_REMOVED（纯状态赋值，电路当场就视作断开），
# 再分帧离表 + 分帧善后，全程只吃 JOB_SLICE_USEC 量级的单帧时间。
func _start_remove_and_followup(removed:Array[SWBuildItemDefine], notifyChunkPosArr:Array,
		on_done:Callable = Callable()) -> void:
	_start_remove_common(removed, notifyChunkPosArr, on_done, true)

func _start_remove_common(removed:Array[SWBuildItemDefine], notifyChunkPosArr:Array,
		on_done:Callable, do_delete:bool) -> void:
	var v := _get_view()
	var tree:SceneTree = v.get_tree() if v != null else null
	# 四个入口都被闸门挡着，所以「善后进行中又被调」理论上走不到；
	# 真走到也只跑同步版——删除已经在选择集里定下了，善后绝不能漏。
	if removed.size() < BULK_REMOVE_THRESHOLD or tree == null \
			or _remove_busy or _place_running or _clipboard_busy:
		if do_delete:
			build_manager.setBuildsState(removed, SwDefine.BuildState.TO_BE_REMOVED)
			build_manager.delBuilds(removed)
		_notify_circuit_after_removed(removed, notifyChunkPosArr)
		if v != null:
			v.sw_draw_manager.updataChunks(notifyChunkPosArr)
		if on_done.is_valid():
			on_done.call()
		return
	# 不 await：标记 → 分帧离表 → 分帧善后都在后面的帧里跑，当前帧立即交还给输入/绘制
	_run_remove_job(removed, notifyChunkPosArr, tree, on_done, do_delete)

# 分帧删除 + 善后：整批标 TO_BE_REMOVED → 分帧离表 → 抹画面 → 按预算取种子
# → 9 阶段重建 → 摘旧电路 → 清时钟 → 补刷受影响区块。
# epoch 变了（清空世界 / 读档）就自行退出，别把旧建筑写回电路。
func _run_remove_job(removed:Array[SWBuildItemDefine], notifyChunkPosArr:Array,
		tree:SceneTree, on_done:Callable, do_delete:bool = false) -> void:
	_remove_busy = true
	_job_start_msec = Time.get_ticks_msec()
	var epoch:int = _job_epoch
	var total:int = removed.size()
	# 1) 整批标记待删除：一趟纯状态赋值，但意义是「电路当场视作断开」，
	#    取种子与重建都靠它把这些建筑挡在重建集外
	if do_delete:
		build_manager.setBuildsState(removed, SwDefine.BuildState.TO_BE_REMOVED)
	# 让当前帧的输入/绘制收尾，再开始吃预算
	await tree.process_frame
	if epoch != _job_epoch:
		_remove_busy = false
		return
	var v := _get_view()
	if do_delete:
		# 2) 分帧离表：一次删 7w 时这里原本要占住一帧 400+ms
		var j:int = 0
		while j < total:
			var t_del:int = Time.get_ticks_usec()
			while j < total:
				var next:int = mini(j + JOB_REMOVE_DEL_STEP, total)
				var part:Array[SWBuildItemDefine] = []
				part.assign(removed.slice(j, next))
				build_manager.delBuilds(part)
				j = next
				if Time.get_ticks_usec() - t_del >= JOB_SLICE_USEC:
					break
			_job_report("删除元件 %d/%d" % [j, total], 0.02 + 0.23 * float(j) / float(total))
			if j < total:
				await tree.process_frame
				if epoch != _job_epoch:
					_remove_busy = false
					return
	# 3) 抹掉画面：重建还要跑好几帧，不能让删掉的元件一直留在屏幕上
	if v != null:
		v.sw_draw_manager.updataChunks(notifyChunkPosArr)
	var affected:Array[SWBuildItemDefine] = []
	if circuit_control != null:
		# 4) 取重建种子：整片删除时种子只有周长量级
		var state:Dictionary = circuit_control.beginRemoveSeeds()
		var i:int = 0
		while i < total:
			var t_seed:int = Time.get_ticks_usec()
			while i < total:
				var next:int = mini(i + JOB_REMOVE_STEP, total)
				circuit_control.collectRemoveSeedsStep(state, removed, i, next)
				i = next
				if Time.get_ticks_usec() - t_seed >= JOB_SLICE_USEC:
					break
			_job_report("整理删除 %d/%d" % [i, total], 0.25 + 0.1 * float(i) / float(total))
			if i < total:
				await tree.process_frame
				if epoch != _job_epoch:
					_remove_busy = false
					return
		var seeds:Array[SWBuildItemDefine] = circuit_control.endRemoveSeeds(state)
		# 5) 9 阶段重建：活着的建筑每帧吃 JOB_CIRCUIT_BUDGET_USEC
		affected = await circuit_control.updateBuildCircuitStaged(seeds, tree,
			func(stage:int, p:float) -> void:
				_job_report(LOAD_STAGE_TEXT[stage],
					0.35 + 0.65 * (float(stage) + clampf(p, 0.0, 1.0)) / 9.0),
			JOB_CIRCUIT_BUDGET_USEC, JOB_CIRCUIT_STEP)
		if epoch != _job_epoch:
			_remove_busy = false
			return
		# 6) 被删建筑独占的旧电路在这里摘掉（没人会替它们 reset）
		circuit_control.dropCircuits(circuit_control.detachRemoved(removed))
	# 7) 清时钟注册 + 补刷受影响区块
	_cleanup_clocks_after_removed(removed)
	_mark_circuit_edited()
	_append_affected_chunks(affected, notifyChunkPosArr)
	if v != null:
		v.sw_draw_manager.updataChunks(notifyChunkPosArr)
	_remove_busy = false
	_job_hide()
	if on_done.is_valid():
		on_done.call()

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

#tag buildLayer删除选中、剪切、复制
func _on_event_key(event: InputEventKey) -> bool:
	if event.is_pressed():
		#后台任务期间的增删会打乱分阶段重建的中间态，也违反「任务未完成禁用复制/剪切」
		if _clipboard_busy or _place_running or _remove_busy:
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
	var viewport := v.get_viewport()
	var mouse_pos := viewport.get_mouse_position()
	var world_pos = SwCommon.GetGlobalPosByViewPos(mouse_pos, viewport)
	var grid_pos:Vector2i = SwCommon.GetGridPos(Vector2i(world_pos))
	return click_build_at(grid_pos)

#tag 点击某格上的元件（鼠标位置换算成格子后进这里；测试走同一入口，
#不依赖真实鼠标位置——headless 下 viewport.get_mouse_position 拿不到坐标）
func click_build_at(grid_pos:Vector2i) -> bool:
	#任务期间点按钮会在半重建的电路上做增量求值，直接忽略这次点击
	if _clipboard_busy or _place_running:
		return false
	var v := _get_view()
	if v == null:
		return false
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
	if build and (build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.EXTERNAL_INPUT \
			or build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.EXTERNAL_OUTPUT):
		#tag 地图上的接口元件被点击：交给 HUD 改名，电路层本身没有行为
		edit_build_requested.emit(build)
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
const CLOCK_GAP_USEC:int = 1
#本帧是否已处理过电路拍：一帧最多一拍，切断「掉帧→传播次数翻倍→更卡」的正反馈
var _last_tick_frame:int = -1
var _last_clock_usec:int = 0
func addClockBuild(build:SWBuildItemDefine) -> void:
	clockBuildArr[build]=true
	_register_io_port(build)
func delClockBuild(build:SWBuildItemDefine) -> void:
	clockBuildArr.erase(build)
	io_input_arr.erase(build)
	io_output_arr.erase(build)

# ===== 接口调试（外部输入/输出接口在电路场景里持续输入输出） =====
# 电路场景没有机器人：没人给外部输入口喂电平、也没人读外部输出，
# 结果就是电路整片不动、接口元件永远是个死图标，玩家改完电路无从验证。
# 这里按与机器人节拍同口径的方波自己喂**clk**，并把输出口读到的电平写回元件自身。
#
# 只喂 clk：detect_res_0..7 是**机器人每拍写进来的真实检测码**（不是时钟），
# 给它们翻方波会让解码电路乱跑、8 个元件一起闪，看上去像电路在发疯（实际是假信号）。
# 没有机器人时这些数据位就该是静止的，玩家要验证解码逻辑得回机器人场景看时序图。
# 关掉（排查用）时整段空转，输入口电平停在最后一次的值。
const IO_HALF_USEC:int = 125000   # 半拍：SWRobotTick 是 250ms 一拍，一拍两个相位
#只有叫这个名字的输入口才当钟。其余输入名（detect_res_*）是数据位，一律不碰
const IO_CLOCK_NAME:String = "clk"
var interface_debug_enabled:bool = true
#外部输入接口（喂方波）与外部输出接口（读电平点亮自己），注册时机与时钟一致
var io_input_arr:Dictionary = {}
var io_output_arr:Dictionary = {}
var _io_level:bool = false
var _io_last_usec:int = 0
#分屏调试：右侧时序整个交给机器人节拍（见 step_clock_phase）。
#开着时 tick 直接早退：既不自翻时钟元件，也不按挂钟扫方波
var external_clock:bool = false
#刚被 apply_clock_level 写过电平的 clk 口：step_clock_phase 就地消费成求值种子
var _io_pending_seeds:Array[SWBuildItemDefine] = []
#本系统被机器人节拍推着算了多少个相位（排障 / 用例断言用）
var phase_steps_total:int = 0

#把建筑按「接口元件」登记进来；不是接口的直接忽略（放置路径每个元件都会过一遍，很便宜）
func _register_io_port(build:SWBuildItemDefine) -> void:
	if build == null or build.buildDefine == null:
		return
	match build.buildDefine.circuit_component_type:
		SwDefine.CircuitComponentType.EXTERNAL_INPUT:
			io_input_arr[build] = true
		SwDefine.CircuitComponentType.EXTERNAL_OUTPUT:
			io_output_arr[build] = true

#把外部输入里的**钟**口抬/落到方波电平，返回本次真正翻了的输入口（当本轮求值种子）。
#按挂钟时间判定（同 clockBuildArr 的理由）：慢帧不补拍，电平不会被一帧里叠好几下。
#非 clk 的数据位（detect_res_*）跳过：它们由机器人按真实检测结果写，
#在电路场景里拿方波去碰它们只会让解码电路和元件一起乱闪
func _drive_io_inputs(now:int) -> Array[SWBuildItemDefine]:
	var out:Array[SWBuildItemDefine] = []
	if not interface_debug_enabled or io_input_arr.is_empty():
		return out
	if _io_last_usec == 0:
		_io_last_usec = now
		return out
	if now - _io_last_usec < IO_HALF_USEC:
		return out
	_io_last_usec = now
	_io_level = not _io_level
	var lv:int = 1 if _io_level else 0
	for build in io_input_arr.keys():
		if build == null or build.bIsToBeRemoved():
			continue
		if str(build.get("io_name")) != IO_CLOCK_NAME:
			continue
		build.setLevel(lv)
		out.append(build)
	return out

#外部时钟（分屏调试时由机器人节拍驱动）写 clk 口电平：只碰 io_name == "clk" 的输入口，
#真正翻了的口攒成下一次求值的种子。与 _drive_io_inputs 互斥（external_clock 一开，
#那边就不再按挂钟扫方波）。返回本次改动的口数（0 = 没有 clk 口或电平没变）
func apply_clock_level(lv:int) -> int:
	var changed:int = 0
	for build in io_input_arr.keys():
		if build == null or build.bIsToBeRemoved():
			continue
		if str(build.get("io_name")) != IO_CLOCK_NAME:
			continue
		if int(build.level) == lv:
			continue
		build.setLevel(lv)
		_io_pending_seeds.append(build)
		changed += 1
	return changed

#分屏调试：把机器人本拍的数据输入位（detect_res_0..7）镜到本场景同名输入接口。
#levels 是 {口名: 0/1}；只写真的变了的，变化的进 _io_pending_seeds，
#随下一个相位一起求值（否则灯要等到下一拍才亮）。返回改动口数
func apply_input_levels(levels:Dictionary) -> int:
	var changed:int = 0
	if levels.is_empty():
		return changed
	for build in io_input_arr.keys():
		if build == null or build.bIsToBeRemoved():
			continue
		var name:String = str(build.get("io_name"))
		#clk 归相位锁管（step_clock_phase），这里不能碰
		if name == IO_CLOCK_NAME or not levels.has(name):
			continue
		var lv:int = 1 if int(levels[name]) != 0 else 0
		if int(build.level) == lv:
			continue
		build.setLevel(lv)
		_io_pending_seeds.append(build)
		changed += 1
	return changed

#分屏调试：机器人每来一个相位事件，当场把这一相位算完（不等本场景自己的帧 tick）。
#步进时高/低两相位落在同一帧里，靠帧 tick 只消费得到最后一次写入的电平，
#上升沿那次求值被吃掉——电路看上去一步都不走。
#右侧的时钟元件也在这里翻：一拍「高+低」两相位 = 一个完整方波周期，与 clk 口同口径。
func step_clock_phase(high:bool) -> void:
	if not tick_enabled:
		return
	#放置任务 / 删除善后的电路重建是分帧进行的：中间态求值会把电路写坏（与 tick 同一口径）
	if _place_running or _remove_busy:
		return
	if circuit_control == null:
		return
	var clocks:Array[SWBuildItemDefine] = []
	clocks.assign(clockBuildArr.keys())
	for build in clocks:
		build.onPressed(true)
	var seeds:Array[SWBuildItemDefine] = clocks.duplicate()
	apply_clock_level(1 if high else 0)
	seeds.append_array(_io_pending_seeds)
	_io_pending_seeds.clear()
	#两侧都没东西可翻（没有 clk 口、也没有时钟元件）：这一相位无事可做
	if seeds.is_empty():
		return
	#与 tick 同一口径：cull=true 只刷视野内，want_builds=false 不回填 build 数组
	var changedBuilds := circuit_control.buildSignalsChanged(seeds, true, false)
	phase_steps_total += 1
	_refresh_io_displays()
	refresh_signal_chunks(changedBuilds)

#读出外部输出接口的电平并写进它自己的采样槽（元件主体跟着变色）。
#必须在求值之后调：这样点亮的是本拍刚算出来的结果
func _refresh_io_displays() -> void:
	for build in io_input_arr.keys():
		if build != null and not build.bIsToBeRemoved():
			build.refresh_display_level()
	for build in io_output_arr.keys():
		if build != null and not build.bIsToBeRemoved():
			build.refresh_display_level()

#电路结构改过了（放置/删除）：记进会话。回机器人场景时据此先把绑着它的机器人停住、
#按最新结构重载电路，电路场景退出时据此把当前结构导出成 .swcir
func _mark_circuit_edited() -> void:
	SESSION.mark_circuit_edited(SESSION.current_save_name)

#按当前建筑表重建时钟注册表：加载存档、批量删除后调用
func _rebuild_clock_registry() -> void:
	clockBuildArr.clear()
	io_input_arr.clear()
	io_output_arr.clear()
	for build in build_manager.getAllBuilds():
		if build is SWBuildClockSiggen:
			clockBuildArr[build] = true
		_register_io_port(build)

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

# 性能面板「电路时钟 tick」开关：false 时 tick 整个不执行（时钟不翻、寄存器不锁、
# 不求值、不刷显示），用来分离「电路 tick 吃帧」与「渲染吃帧」两类开销。
# 恢复时 _last_clock_usec 不重置：下一拍按正常间隔继续推进，不会补拍。
var tick_enabled:bool = true

# 移动中是否连求值一起停：true 退回最早的「移动就停 tick」行为（时钟停摆、寄存器不锁）。
# 默认 false = 求值/寄存器照跑，显示回填降档分片（见 SWCircuitControl.display_throttled）。
var pause_tick_while_moving:bool = false

# 把「移动中降档」落到电路控制上。每拍必调（包括早退分支），
# 否则标志残留成 true 会让停下后的显示一直处于分片模式。
func _set_display_throttled(throttled:bool) -> void:
	if circuit_control != null and circuit_control.display_throttled != throttled:
		circuit_control.display_throttled = throttled

func tick(_delta: float,_tick_index:int) -> void:
	#return
	#相机在动（中键拖动 / 方向键 / 滚轮缩放）：这一拍照常推进电路，但显示回填降档成
	#分片模式（每拍只比 1/MOVING_SLICES 的 net 与门，几拍内全部跟上）。
	#元件状态照常更新：不冻结、不回退，移动中新进视野的区块也会在 2~3 拍内补上正确状态。
	#为什么不直接暂停 tick：暂停会让时钟停摆、寄存器不锁，移动一秒就丢一秒电路时间。
	#放置/删除善后期间强制退回全量（那段时间要看中间结果）。
	var moving:bool = SWCamera2D.is_view_moving()
	var throttle:bool = moving and tick_enabled and not _place_running and not _remove_busy
	#降档标志必须在所有早退之前落定
	_set_display_throttled(throttle)
	if not tick_enabled:
		return
	if external_clock:
		#分屏调试：右侧一切时序都由机器人节拍推（clk 口与时钟元件都在
		#step_clock_phase 里），这里不再按帧自走，否则两边不同拍
		return
	if moving and pause_tick_while_moving:
		return
	#放置任务 / 删除善后的电路重建是分帧进行的：中间态下跑时钟增量求值会把电路写坏
	if _place_running or _remove_busy:
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
	var seeds:Array[SWBuildItemDefine] = clocks.duplicate()
	#接口调试：给外部输入接口喂方波，这一拍真正翻了的输入口也当本轮求值种子，
	#否则没有时钟的电路在电路场景里一步都不会走
	seeds.append_array(_drive_io_inputs(now))
	# cull=true：这一拍的显示只刷视野内的东西（产品要求）。
	# 视野外的电线与非门不刷显示，视野外且不含寄存器的电路连求值都跳过；
	# 含寄存器的电路看不见也照算，Q 得跟着时钟继续走（计数器不能停在半路）。
	# 第三个参数 want_builds=false：时钟 tick 不读返回值（refresh_signal_chunks 只用
	# dirty net 与信号纹理），没必要每拍把 _notify 里几百上千个组件回填成 build 数组。
	var changedBuilds := circuit_control.buildSignalsChanged(seeds, true, false)
	#求值之后才读输出口：点亮的是这一拍刚算出来的结果
	_refresh_io_displays()
	#for build in clocks:
		#build.onPressed(true)
	#changedBuilds = circuit_control.buildSignalsChanged(clocks)
	# LOD 冻结由 shader signalFrozen 统一处理：冻结期间信号纹理照常更新
	#（寄存器不能停），回 LOD0 时立即显示最新电平，无需整屏重染
	refresh_signal_chunks(changedBuilds)

# 每拍翻转全局信号值：直接改写全部已分配 net 的电平并写信号纹理（纯渲染压测）
func _stress_render_all() -> void:
	_stressFlip = not _stressFlip
	var sig:SwDefine.CircuitSignal = SwDefine.CircuitSignal.HIGH if _stressFlip else SwDefine.CircuitSignal.LOW
	var tex:SWSignalTexture = SWSignalTexture.instance
	for net in circuit_control._netById:
		if net != null:
			net.curSignal = sig
			if tex != null:
				tex.set_level(net.netId, sig == SwDefine.CircuitSignal.HIGH)
	if tex != null:
		tex.flush()
#endregion
