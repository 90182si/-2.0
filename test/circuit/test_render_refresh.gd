extends GutTest
# 区块刷新回归测试：绘制全部在主线程完成后，「内容变了」与「只是信号变了」
# 走两条不同的路径，任何一条失效都会表现为放置/删除元件后画面不更新。
#   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/circuit/test_render_refresh.gd -gexit

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const SAVE_NAME := "16x计数器"
# 含寄存器的存档：计数器类电路对「时钟 + 锁存 + 贴图帧」最敏感
const REGISTER_SAVES := ["16x计数器", "测试寄存器", "计数器2"]

var harness = null

func before_each() -> void:
	harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)

func after_each() -> void:
	if harness != null:
		harness.shutdown_game()
		harness = null

func _boot(save_name: String = SAVE_NAME) -> bool:
	await harness.boot_game()
	var data: Dictionary = await harness.load_save(save_name)
	if data.is_empty():
		push_error("存档加载失败: " + save_name)
		return false
	# 存档视口可能落在 LOD 档位（降级期间颜色按设计冻结），本文件断言全分辨率下的补丁
	SwAtlas.set_lod(0)
	assert_gt(harness.force_load_all_chunks(), 0, "没有任何区块被构建出来")
	return true

# 增删建筑属于内容变化：槽位表已对不上，必须整块重建，实例数随之变化
func test_content_change_rebuilds_chunk() -> void:
	if not await _boot():
		return
	var sys: SWBuildLayerSystem = harness.build_layer.layer_system
	var dm = harness.build_layer.sw_draw_manager
	#挑一个至少有两个建筑的区块：删掉一个后区块仍有内容，才不会走「空区块卸载」分支
	var chunkPos := Vector2i(-9999, -9999)
	var builds: Array = []
	for cp: Vector2i in dm.get_loaded_chunk_positions():
		var cand: Array = sys.build_manager.getBuildsByChunkPos(cp)
		if cand.size() >= 2:
			chunkPos = cp
			builds = cand
			break
	if builds.is_empty():
		fail_test("找不到含两个以上建筑的已加载区块")
		return
	var mi: SWMultiMeshInstance2D = dm._chunkInstance[chunkPos].mesh_instance
	var before: int = mi.multimesh.visible_instance_count
	var removed: SWBuildItemDefine = builds[0]
	var freedPos: Vector2i = removed.buildAxisPos
	sys.build_manager.delBuilds([removed])
	var notify: Array[Vector2i] = [chunkPos]
	dm.updataChunks(notify)
	harness.flush_draw_queue()
	var afterDel: int = mi.multimesh.visible_instance_count
	assert_lt(afterDel, before,
		"删除建筑后区块没有重建内容（实例数 %d -> %d）" % [before, afterDel])

	#再放回同一格：放置同样属于内容变化，实例数应当涨回来
	#（不做电路重连，部件数可能与原来不同，所以只要求变多）
	var placed: SWBuildItemDefine = SwDefine.SWBuildCreator(freedPos, removed.buildDefine, removed.rotation)
	assert_true(sys.build_manager.addBuild(placed), "放置建筑失败，位置 %s" % str(freedPos))
	dm.updataChunks(notify)
	harness.flush_draw_queue()
	assert_gt(mi.multimesh.visible_instance_count, afterDel,
		"放置建筑后区块没有重建内容（实例数停在 %d）" % afterDel)

# 混接 net 的电线A/B 必须各按自身线别采样：实例 custom_data 里 palette_id 与线别对应、
# net_id 指向正确 net，信号纹理电平与 net.curSignal 一致（shader 采样的数据源）。
# 旧版断言 buffer 颜色分量，纹理化后颜色由 shader 采样，这里改为验证采样侧的数据契约。
func test_mixed_wire_palette_survives_patch() -> void:
	if not await _boot():
		return
	var sys: SWBuildLayerSystem = harness.build_layer.layer_system
	var dm = harness.build_layer.sw_draw_manager
	# 本用例验证「信号纹理电平随 net.curSignal 更新」——依赖完整回填（默认已是 true）
	sys.circuit_control.backfill_net_signal = true
	sys.circuit_control.backfill_gate_display = true
	sys.circuit_control.clear_cpu_backends()
	var samples: Array = _collect_mixed_net_wires(sys, dm)
	assert_gt(samples.size(), 0, "存档里没有同时含电线A和电线B、且已上屏的 net")
	var clocks: Array[SWBuildItemDefine] = sys.clockBuildArr.keys()
	assert_gt(clocks.size(), 0, "存档里没有时钟，无法驱动级联")
	var flipped: bool = false
	for tick in 8:
		var before: Array = []
		for s: Dictionary in samples:
			before.append((s["net"] as SWNet).curSignal)
		for clk in clocks:
			clk.onPressed(true)
		sys.refresh_signal_chunks(sys.circuit_control.buildSignalsChanged(clocks))
		harness.flush_draw_queue()
		for i: int in samples.size():
			if (samples[i]["net"] as SWNet).curSignal != before[i]:
				flipped = true
		# 每拍都查：采样侧数据契约（net_id / palette_id / 信号纹理电平）
		var bad: Array[String] = []
		for s: Dictionary in samples:
			var b: SWBuildItemDefine = s["build"]
			var net: SWNet = s["net"]
			var mi: SWMultiMeshInstance2D = s["mi"]
			var stride: int = SWBuildCompoentRenderable.INSTANCE_STRIDE
			var idx: int = int(mi._slotStart[b]) * stride
			var net_id: int = int(mi._cpuBuffer[idx + 13])
			var pal_id: int = int(mi._cpuBuffer[idx + 14])
			if net_id != net.netId:
				bad.append("%s@%s netId=%d want=%d" % [b.buildDefine.buildName, str(b.buildAxisPos), net_id, net.netId])
				continue
			var want_pal: int = SWSignalTexture.palette_id_for(net.wireGroup.wireName if net.wireGroup != null else "")
			if pal_id != want_pal:
				bad.append("%s@%s palette=%d want=%d" % [b.buildDefine.buildName, str(b.buildAxisPos), pal_id, want_pal])
			var lv: float = SWSignalTexture.instance.image.get_pixel(
					net.netId % SWSignalTexture.TEX_COLS, net.netId / SWSignalTexture.TEX_COLS).r
			var want_lv: float = 1.0 if net.curSignal == SwDefine.CircuitSignal.HIGH else 0.0
			if not is_equal_approx(lv, want_lv):
				bad.append("%s@%s level=%.0f want=%.0f" % [b.buildDefine.buildName, str(b.buildAxisPos), lv, want_lv])
		assert_eq(bad.size(), 0, "第 %d 拍混接 net 采样数据不一致：%s" % [
			tick, ", ".join(bad.slice(0, 5))])
	assert_true(flipped, "连续 8 拍里混接 net 电平从未翻转，没有真正走到信号纹理更新")

# 收集混接 net（同时含电线A和电线B）上已上屏的电线
func _collect_mixed_net_wires(sys: SWBuildLayerSystem, dm) -> Array:
	var by_net: Dictionary = {}
	for b: SWBuildItemDefine in sys.build_manager.getAllBuilds():
		if b.buildDefine.circuit_component_type != SwDefine.CircuitComponentType.WIRE or b.in_loop:
			continue
		var wire_name: String = b.buildDefine.buildName
		if wire_name != "电线A" and wire_name != "电线B":
			continue
		var cir: SWBuildCompoentCircuit = b.getCircuitCompoent()
		var net: SWNet = null
		for d in 4:
			net = cir.pinNetMap.get(d, null)
			if net != null:
				break
		if net == null:
			continue
		var cp: Vector2i = SwCommon.GetChunkPos(b.buildAxisPos)
		if not dm._chunkInstance.has(cp):
			continue
		var mi: SWMultiMeshInstance2D = dm._chunkInstance[cp].mesh_instance
		if mi == null or not mi._slotStart.has(b):
			continue
		var lst: Array = by_net.get(net, [])
		lst.append({"build": b, "mi": mi, "net": net})
		by_net[net] = lst
	var out: Array = []
	for key in by_net:
		var lst: Array = by_net[key]
		var has_a: bool = false
		var has_b: bool = false
		for s: Dictionary in lst:
			var w: String = (s["build"] as SWBuildItemDefine).buildDefine.buildName
			if w == "电线A":
				has_a = true
			elif w == "电线B":
				has_b = true
		if has_a and has_b:
			out.append_array(lst)
	return out

# 信号翻转只改纹理：tick 期间实例缓冲零写入/零上传，电平只进信号纹理
func test_signal_change_patches_colors() -> void:
	if not await _boot():
		return
	var sys: SWBuildLayerSystem = harness.build_layer.layer_system
	var dm = harness.build_layer.sw_draw_manager
	# 本用例验证「连线随信号变色 / net 标脏」——这依赖完整回填（默认已是 true，
	# 这里显式写死，避免默认值变动让用例失去覆盖）。
	sys.circuit_control.backfill_net_signal = true
	sys.circuit_control.backfill_gate_display = true
	sys.circuit_control.clear_cpu_backends()
	var clocks: Array[SWBuildItemDefine] = sys.clockBuildArr.keys()
	assert_gt(clocks.size(), 0, "存档里没有时钟，无法驱动级联")
	# 预热一拍：存档的时钟相位是在首轮求值**之后**才恢复的（load_state 晚于 evaluateCircuits），
	# 手动第一按往往只是把时钟拨回与 net 当前电平相同的值——净变化为 0，
	# 后面的断言就变成「什么都没发生」的空跑。先跑一轮把相位与电平对齐。
	for clk in clocks:
		clk.onPressed(true)
	sys.refresh_signal_chunks(sys.circuit_control.buildSignalsChanged(clocks))
	# 挑一个已构建的区块：tick 期间 buffer 不得有任何写入/上传
	var mi: SWMultiMeshInstance2D = null
	for chunkPos: Vector2i in dm.get_loaded_chunk_positions():
		var cand: SWMultiMeshInstance2D = dm._chunkInstance[chunkPos].mesh_instance
		if cand != null and cand.hasCpuBuffer():
			mi = cand
			break
	if mi == null:
		fail_test("没有任何已加载且已构建的区块")
		return
	var before: PackedFloat32Array = mi._cpuBuffer.duplicate()
	var uploads_before: int = SWMultiMeshInstance2D.dbg_uploads
	var flush_before: int = SWSignalTexture.instance.dbg_flush_count
	# 先清掉 boot 遗留的补丁/重建队列与计数，让本拍增量从零基线度量
	harness.flush_draw_queue()
	dm._full_rebuilds_frame = 0
	var patch_before: int = dm._patch_queue.size()
	var rebuild_before: int = dm._rebuild_queue.size()
	for clk in clocks:
		clk.onPressed(true)
	var changed: Array = sys.circuit_control.buildSignalsChanged(clocks)
	var touched: int = sys.refresh_signal_chunks(changed)
	assert_gt(touched, 0, "信号级联没有标脏任何 net")
	# tick 路径不得产生补丁/重建队列（信号只进纹理）
	assert_eq(dm._patch_queue.size(), patch_before, "纯信号变化不该进入补丁队列")
	assert_eq(dm._rebuild_queue.size(), rebuild_before, "纯信号变化不该进入重建队列")
	harness.flush_draw_queue()
	assert_eq(mi._cpuBuffer, before, "电平翻转后实例缓冲被改写了（应只写信号纹理）")
	assert_eq(SWMultiMeshInstance2D.dbg_uploads, uploads_before, "电平翻转触发了实例缓冲上传")
	assert_gt(SWSignalTexture.instance.dbg_flush_count, flush_before, "信号纹理没有在 tick 后刷新")
	assert_eq(dm.get_full_rebuilds_last_frame(), 0, "纯信号变化不该退回整块重建")

# 建筑首个实例的颜色分量（连线类建筑的首个部件就是线本身）
func _build_color(mi: SWMultiMeshInstance2D, b: SWBuildItemDefine) -> Color:
	var stride: int = SWBuildCompoentRenderable.INSTANCE_STRIDE
	var idx: int = int(mi._slotStart[b]) * stride
	return Color(mi._cpuBuffer[idx + 8], mi._cpuBuffer[idx + 9],
			mi._cpuBuffer[idx + 10], mi._cpuBuffer[idx + 11])

# 实例颜色分量的加权和：电平翻转必然改变其中一批，用来判断 buffer 是否被回写过
func _color_signature(buf: PackedFloat32Array) -> float:
	var sum := 0.0
	var stride := SWBuildCompoentRenderable.INSTANCE_STRIDE
	for i in range(8, buf.size(), stride):
		sum += buf[i] + buf[i + 1] * 2.0 + buf[i + 2] * 3.0 + buf[i + 3] * 4.0
	return sum

# 寄存器必须在真实 tick（_physics_process 驱动时钟）下持续锁存，
# 且每拍都要把 Q 同步成对应贴图帧——这是「计数器不工作」最直接的判据
func test_register_keeps_latching_16x() -> void:
	await _check_register_save("16x计数器", false)

func test_register_keeps_latching_test_save() -> void:
	#这张存档没有时钟（开关接的是 D 不是 CLK）：没有上升沿就不能锁存，Q 必须保持
	await _check_register_holds_without_clock("测试寄存器")

func test_register_keeps_latching_counter2() -> void:
	#存档里的 8 个开关是计数使能，保存时全部关着（计数器静止）；打开后靠自带的时钟走数
	await _check_register_save("计数器2", true)

func _collect_regs_and_switches(sys: SWBuildLayerSystem) -> Array:
	var regs: Array[SWBuildItemDefine] = []
	var switches: Array[SWBuildItemDefine] = []
	for b: SWBuildItemDefine in sys.build_manager.getAllBuilds():
		if b is SWBuildRegister1Bit:
			regs.append(b)
		elif b is SWBuildButton and b.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.SWITCH:
			switches.append(b)
	return [regs, switches]

func _check_register_save(save_name: String, enable_switches: bool) -> void:
	if not await _boot(save_name):
		return
	var sys: SWBuildLayerSystem = harness.build_layer.layer_system
	var pair := _collect_regs_and_switches(sys)
	var regs: Array = pair[0]
	var switches: Array = pair[1]
	assert_gt(regs.size(), 0, "%s 里没有寄存器" % save_name)
	if enable_switches and not switches.is_empty():
		for s in switches:
			s.onPressed(true)
		sys.refresh_signal_chunks(sys.circuit_control.buildSignalsChanged(switches))
	var seen := {}
	for i in 240:
		await get_tree().physics_frame
		seen[_q_key(regs)] = true
		if seen.size() >= 4:
			break
	assert_gt(seen.size(), 1, "%s 在真实 tick 下寄存器 Q 从未变化（时钟未跑或锁存失效）" % save_name)
	_verify_register_display(save_name, regs)

#没有时钟的存档：输入（开关接在 D 上）反复变化也不该出现锁存
func _check_register_holds_without_clock(save_name: String) -> void:
	if not await _boot(save_name):
		return
	var sys: SWBuildLayerSystem = harness.build_layer.layer_system
	var pair := _collect_regs_and_switches(sys)
	var regs: Array = pair[0]
	var switches: Array = pair[1]
	assert_gt(regs.size(), 0, "%s 里没有寄存器" % save_name)
	assert_false(switches.is_empty(), "%s 里没有可以驱动输入的开关" % save_name)
	var before := _q_key(regs)
	for i in 60:
		await get_tree().physics_frame
		if i % 4 != 0:
			continue
		for s in switches:
			s.onPressed(not s.pressed)
		sys.refresh_signal_chunks(sys.circuit_control.buildSignalsChanged(switches))
	assert_eq(_q_key(regs), before, "%s 没有时钟却在输入变化后锁存了" % save_name)
	_verify_register_display(save_name, regs)

func _verify_register_display(save_name: String, regs: Array[SWBuildItemDefine]) -> void:
	for b in regs:
		var cir := b.getCircuitCompoent() as SWBuildCompoentCircuitRegister
		var want: Rect2 = b.buildDefine.atlasTextureOn.region \
				if cir.qState == SwDefine.CircuitSignal.HIGH else b.buildDefine.atlasTextureOff.region
		assert_eq(b.getRenderableCompoent().drawRect, want,
			"%s 寄存器 %s 贴图帧与 Q 不一致" % [save_name, str(b.buildAxisPos)])
	#组件上的 drawRect 对了还不够：帧切换已 shader 化——寄存器帧部件必须登记了帧槽
	#（buffer 13 列 = 帧槽 id），且信号纹理帧槽电平必须与 Q 一致，否则画面仍是旧帧
	harness.flush_draw_queue()
	var dm = harness.build_layer.sw_draw_manager
	var stride := SWBuildCompoentRenderable.INSTANCE_STRIDE
	var tex := SWSignalTexture.instance
	var stale := 0
	for b in regs:
		var cir2 := b.getCircuitCompoent() as SWBuildCompoentCircuitRegister
		var cp: Vector2i = SwCommon.GetChunkPos(b.buildAxisPos)
		if not dm._chunkInstance.has(cp):
			continue
		var mi: SWMultiMeshInstance2D = dm._chunkInstance[cp].mesh_instance
		if not mi._slotStart.has(b):
			continue
		var parts: int = mi._slotParts[b]
		if parts <= 0:
			continue
		var col: int = (int(mi._slotStart[b]) + parts - 1) * stride
		var slot: int = int(mi._cpuBuffer[col + 13])
		if slot < 0:
			stale += 1
			continue
		var lv: float = tex.image.get_pixel(slot % SWSignalTexture.TEX_COLS, slot / SWSignalTexture.TEX_COLS).r
		var want: float = 1.0 if cir2.qState == SwDefine.CircuitSignal.HIGH else 0.0
		if not is_equal_approx(lv, want):
			stale += 1
	assert_eq(stale, 0, "有 %d 个寄存器在信号纹理里的帧状态没跟上 Q" % stale)

# 换存档：地图上已有建筑时再加载另一个存档，旧建筑必须当场被替换。
# 之前旧区块只是被标成 UNLOADING，加载任务又因为区块还留在 _chunkInstance 里被丢掉，
# 区块就一直显示上一个存档的内容，要等相机移出视野再移回才刷新
func test_load_other_save_rebuilds_loaded_chunks() -> void:
	if not await _boot(SAVE_NAME):
		return
	var sys: SWBuildLayerSystem = harness.build_layer.layer_system
	var dm = harness.build_layer.sw_draw_manager
	var before: Array[Vector2i] = dm.get_loaded_chunk_positions().duplicate()
	assert_gt(before.size(), 0, "没有已加载的区块")
	var data: Dictionary = SWSaveManager.load_builds("计数器2")
	if data.is_empty():
		fail_test("存档加载失败: 计数器2")
		return
	#同一拍内同步加载：断言的是加载当场的结果，不依赖帧循环
	harness.build_layer.load_save_data(data)
	#模拟真实相机：给绘制层一个覆盖这些区块的视口（旧实现会在这里把旧区块复活）
	dm.on_view_rect_changed(_chunk_bounds(before))
	harness.flush_draw_queue()
	assert_chunk_content_matches(sys, dm)
	#再跑几帧，确认卸载/重新加载路径不会把旧 buffer 带回来
	for i in 3:
		await get_tree().process_frame
	harness.flush_draw_queue()
	assert_chunk_content_matches(sys, dm)

# 每个已上屏区块的内容都必须来自当前存档：旧存档的建筑对象一个都不能留
func assert_chunk_content_matches(sys: SWBuildLayerSystem, dm) -> void:
	var stale: int = 0
	var leftover: int = 0
	for cp: Vector2i in dm.get_loaded_chunk_positions():
		var chunkIns: SwDefine.SWDrawChunkData = dm._chunkInstance[cp]
		var mi: SWMultiMeshInstance2D = chunkIns.mesh_instance
		if mi == null or not mi.visible:
			continue
		var builds: Array = sys.build_manager.getBuildsByChunkPos(cp)
		if builds.is_empty():
			if mi.multimesh != null and mi.multimesh.visible_instance_count > 0:
				leftover += 1
			continue
		for b: SWBuildItemDefine in mi.curMapData:
			if sys.build_manager.getBuild(b.buildAxisPos) != b:
				stale += 1
	assert_eq(stale, 0, "有 %d 个上屏实例仍来自上一个存档" % stale)
	assert_eq(leftover, 0, "有 %d 个区块在新存档里已无建筑却还在显示" % leftover)

# 对齐到区块步长、能覆盖这些区块的视口矩形
func _chunk_bounds(chunks: Array[Vector2i]) -> Rect2:
	var step: int = SwDefine.GRID_SIZE.x * SwDefine.CHUNK_SIZE
	var mn: Vector2i = chunks[0]
	var mx: Vector2i = chunks[0]
	for cp in chunks:
		mn.x = mini(mn.x, cp.x)
		mn.y = mini(mn.y, cp.y)
		mx.x = maxi(mx.x, cp.x)
		mx.y = maxi(mx.y, cp.y)
	return Rect2(Vector2(mn), Vector2(mx - mn + Vector2i(step, step)))

func _q_key(regs: Array[SWBuildItemDefine]) -> String:
	var key := ""
	for b in regs:
		var cir := b.getCircuitCompoent() as SWBuildCompoentCircuitRegister
		key += str(int(cir.qState))
	return key
