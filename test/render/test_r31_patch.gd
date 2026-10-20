extends GutTest
# R3.1 验收：信号变化帧确实走了「按建筑增量补丁」，且补丁产物与整块重填逐浮点一致。
#
# 判定口径：
# 1) 视口内的区块完成整块填充并登记实例区间（s_full_refill_count 增加）；
# 2) 驱动事件后补丁分支被命中（s_patch_hit_count 增加）；
# 3) 记录补丁后的 multimesh buffer，再对同一批区块强制整块重填，
#    两份 buffer 的可见实例数与逐浮点内容必须完全相同——
#    这就是 R3.1 的核心正确性：少写实例行 ≠ 写错实例行。
#
# 事件源用开关（SWITCH）而不是时钟：计数器2 存档在本测试的打拍序列下
# LED/寄存器外观全程不变（IR 与树两条后端实测均 0 个脏标记），无法制造补丁对象；
# 按下开关必然切换自身贴图并连带非门/灯泡换贴图，脏标记是确定的。

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const SAVE_COUNTER := "计数器2"
const TOGGLE_ROUNDS := 4
const MAX_WAIT_FRAMES := 400
const MIN_SETTLE_FRAMES := 10

func test_render_patch_matches_full_refill() -> void:
	var harness = HARNESS_SCRIPT.new()
	add_child(harness)
	await harness.boot_game()
	var data: Dictionary = await harness.load_save(SAVE_COUNTER)
	if data.is_empty():
		await _dispose_harness(harness)
		pending("存档不存在，跳过: " + SAVE_COUNTER)
		return

	# 屏蔽自动 tick，只手动驱动，保证「事件 → 快照 → 整块重填 → 快照」之间电路状态不再变化
	harness.build_layer.clockBuildArr.clear()
	var switches: Array = _collect_switches(harness.build_layer.sw_build_manager)
	if switches.is_empty():
		await _dispose_harness(harness)
		pending("存档里没有开关，无法制造外观变化")
		return
	var sw: SWBuildItemDefine = switches[0]

	# 预探测一次按下：搞清楚哪些 chunk 的渲染部件会被弄脏。
	# 存档记录的相机位置不一定落在这些 chunk 上（实测会偏到空白 chunk，导致视口内一个区块都不加载），
	# 先把视口对准真正会变的 chunk，补丁路径才有对象。
	var dirty_chunks: Array = _collect_dirty_chunks(_fire_switch(harness, sw, true))
	if dirty_chunks.is_empty():
		await _dispose_harness(harness)
		pending("按下开关后没有渲染脏建筑，补丁路径无可对象")
		return
	_point_view_at_chunks(harness, dirty_chunks)

	var full_before: int = SWMultiMeshInstance2D.s_full_refill_count
	var patch_before: int = SWMultiMeshInstance2D.s_patch_hit_count
	var style_before: int = SWMultiMeshInstance2D.s_patch_style_only_count
	await _wait_chunks_appear(harness)
	await _wait_render_idle(harness)
	assert_gt(SWMultiMeshInstance2D.s_full_refill_count, full_before,
		"视口内区块未发生整块填充，无法登记实例区间（dirtyChunks=%s loaded=%s）" % [
			str(dirty_chunks), str(harness.build_layer.sw_draw_manager._chunkInstance.keys())])

	# 正式事件：开→关→开…… 每轮都换贴图，走运行同款 _refreshDirtyBuildChunks 增量下发
	var state := false
	for i in range(TOGGLE_ROUNDS):
		state = not state
		harness.build_layer._refreshDirtyBuildChunks(_fire_switch(harness, sw, state))
		await _wait_render_idle(harness)

	var patch_hits: int = SWMultiMeshInstance2D.s_patch_hit_count - patch_before
	assert_gt(patch_hits, 0,
		"事件后应命中增量补丁路径（实际 %d 次；dFull=%d；退回原因 %s）" % [
			patch_hits, SWMultiMeshInstance2D.s_full_refill_count - full_before,
			str(SWMultiMeshInstance2D.s_patch_bail)])

	# R3.3：换贴图类事件应走「只覆写主体 style 浮点」的快速通道，
	# 否则下面的逐浮点一致就只是整行重写的自证，测不到增量补丁真正的省点
	var style_hits: int = SWMultiMeshInstance2D.s_patch_style_only_count - style_before
	assert_gt(style_hits, 0,
		"事件后应命中 style-only 快速通道（实际 %d 次；补丁命中 %d 次；退回原因 %s）" % [
			style_hits, patch_hits, str(SWMultiMeshInstance2D.s_patch_bail)])

	# 快照补丁后的 buffer
	var patched: Dictionary = _snapshot_chunk_buffers(harness)
	assert_false(patched.is_empty(), "没有可比较的区块 buffer")

	# 强制整块重填同一批区块
	var chunk_arr: Array[Vector2i] = []
	for chunkPos: Vector2i in patched:
		chunk_arr.append(chunkPos)
	var full_before2: int = SWMultiMeshInstance2D.s_full_refill_count
	harness.build_layer.flush_and_update_chunks(chunk_arr)
	await _wait_render_idle(harness)
	assert_gt(SWMultiMeshInstance2D.s_full_refill_count, full_before2,
		"flush_and_update_chunks 未触发整块重填")

	# 逐浮点对比：补丁产物 == 整块重填产物
	var refilled: Dictionary = _snapshot_chunk_buffers(harness)
	for chunkPos: Vector2i in patched:
		var a: PackedFloat32Array = patched[chunkPos]["buf"]
		var b: PackedFloat32Array = refilled[chunkPos]["buf"]
		var count_a: int = patched[chunkPos]["count"]
		var count_b: int = refilled[chunkPos]["count"]
		assert_eq(count_b, count_a, "chunk %s 可见实例数不一致（补丁 %d vs 重填 %d）" % [str(chunkPos), count_a, count_b])
		var diff: int = _first_diff(a, b)
		assert_eq(diff, -1, "chunk %s 补丁产物与整块重填不一致，首个差异下标 %d（实例行 %d）" % [str(chunkPos), diff, diff / 16])

	harness.shutdown_game()
	await _dispose_harness(harness)

## 按下/松开一个开关，返回受影响的建筑列表（含开关自身），并刷 signalTex
func _fire_switch(harness, sw: SWBuildItemDefine, on: bool) -> Array:
	(sw as SWBuildButton).onPressed(on)
	var changed: Array = harness.build_layer.sw_circuit_control.buildSignalChanged(sw)
	changed.append(sw)
	if SWSignalTexture.instance != null:
		SWSignalTexture.instance.flush()
	return changed

func _collect_switches(bm: SWBuildManager) -> Array:
	var result: Array = []
	for b: SWBuildItemDefine in bm.getAllBuilds():
		if b.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.SWITCH:
			result.append(b)
	result.sort_custom(func(x, y): return x.buildAxisPos < y.buildAxisPos)
	return result

## 从受影响建筑里收集会被标脏的 chunk 位置（不刷新区块，只探查）
func _collect_dirty_chunks(changed_builds: Array) -> Array:
	var chunks: Dictionary = {}
	var ordered: Array = []
	for b: SWBuildItemDefine in changed_builds:
		if b == null or not b.isRenderPartsDirty():
			continue
		var chunkPos: Vector2i = SwCommon.GetChunkPos(b.buildAxisPos)
		if chunks.has(chunkPos):
			continue
		chunks[chunkPos] = true
		ordered.append(chunkPos)
	return ordered

## 把视口矩形扩到覆盖给定的一批 chunk，走生产入口 on_view_rect_changed 触发区块加载
func _point_view_at_chunks(harness, chunk_positions: Array) -> void:
	var cs := Vector2(harness.build_layer.sw_draw_manager._chunkSize)
	var min_pos := Vector2(INF, INF)
	var max_pos := Vector2(-INF, -INF)
	for chunkPos: Vector2i in chunk_positions:
		var p := Vector2(chunkPos)
		min_pos = min_pos.min(p)
		max_pos = max_pos.max(p + cs)
	harness.build_layer.on_view_rect_changed(Rect2(min_pos, max_pos - min_pos), Vector2.ZERO)

## 首个不相等浮点的下标；长度不同返回 min(len)；完全相同返回 -1
func _first_diff(a: PackedFloat32Array, b: PackedFloat32Array) -> int:
	var n: int = mini(a.size(), b.size())
	for i in range(n):
		if a[i] != b[i]:
			return i
	return n if a.size() != b.size() else -1

## 快照每个已加载区块当前 multimesh 的实例 buffer 与可见实例数
func _snapshot_chunk_buffers(harness) -> Dictionary:
	var out: Dictionary = {}
	var dm = harness.build_layer.sw_draw_manager
	for chunkPos: Vector2i in dm._chunkInstance.keys():
		var mi: SWMultiMeshInstance2D = dm._chunkInstance[chunkPos].mesh_instance
		if mi == null or mi.multimesh == null:
			continue
		if mi.multimesh.visible_instance_count <= 0:
			continue
		out[chunkPos] = {
			"buf": mi.multimesh.get_buffer().duplicate(),
			"count": mi.multimesh.visible_instance_count,
		}
	return out

## 区块由 SWDrawManager._process 异步分帧加载，先等第一个区块实例出现
func _wait_chunks_appear(harness) -> void:
	var dm = harness.build_layer.sw_draw_manager
	for i in range(MAX_WAIT_FRAMES):
		if dm._chunkInstance.size() > 0:
			return
		await get_tree().process_frame
	push_warning("_wait_chunks_appear 超时：没有任何区块被加载")

## 等待区块算完 buffer：至少 MIN_SETTLE_FRAMES 帧（区块分帧异步加载，过早采样会看到 0 个），
## 之后连续 3 帧绘制计数器不变且无工作线程在跑，即认为稳定。
func _wait_render_idle(harness) -> void:
	var stable_frames := 0
	var last_total := _draw_total()
	for i in range(MAX_WAIT_FRAMES):
		await get_tree().process_frame
		if i < MIN_SETTLE_FRAMES:
			last_total = _draw_total()
			continue
		var total := _draw_total()
		if total == last_total and not _any_plan_running(harness):
			stable_frames += 1
			if stable_frames >= 3:
				return
		else:
			stable_frames = 0
			last_total = total
	push_warning("_wait_render_idle 超时：渲染线程仍在出活")

func _draw_total() -> int:
	return SWMultiMeshInstance2D.s_draw_map_call_count \
		+ SWMultiMeshInstance2D.s_full_refill_count \
		+ SWMultiMeshInstance2D.s_patch_hit_count

func _any_plan_running(harness) -> bool:
	var dm = harness.build_layer.sw_draw_manager
	for chunkPos: Vector2i in dm._chunkInstance.keys():
		var mi: SWMultiMeshInstance2D = dm._chunkInstance[chunkPos].mesh_instance
		if mi != null and mi.planIsRunning:
			return true
	return false

func _dispose_harness(harness) -> void:
	harness.shutdown_game()
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(harness):
		remove_child(harness)
		harness.free()
