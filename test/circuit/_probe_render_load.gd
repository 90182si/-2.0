extends GutTest
# 临时探针：
#   1) 电线A/B 各自按线别取色（混接 net 也不例外）
#   2) 框选/取消框选只走颜色补丁，不退化成整块重建
#   3) 缩放切 LOD 图集不动实例缓冲（零重绘）
#   4) 分帧读档结果与同步读档逐位一致，并统计每帧最长停顿
#   5) LOD1 下连线统一 high 色并冻结、图集帧继续更新；LOD2 整屏冻结（含图集帧）；回 LOD0 全量补齐
# 命令：godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/circuit/_probe_render_load.gd -gexit

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")

var harness = null

func before_each() -> void:
	harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)

func after_each() -> void:
	if harness != null:
		harness.shutdown_game()
		harness = null

func _boot() -> bool:
	await harness.boot_game()
	var data: Dictionary = await harness.load_save("16x计数器")
	if data.is_empty():
		push_error("存档加载失败")
		return false
	# 存档视口可能落在 LOD 档位：本文件断言的是全分辨率下的颜色补丁
	SwAtlas.set_lod(0)
	harness.force_load_all_chunks()
	harness.flush_draw_queue()
	return true

func _build_color(mi: SWMultiMeshInstance2D, b: SWBuildItemDefine) -> Color:
	var stride: int = SWBuildCompoentRenderable.INSTANCE_STRIDE
	var idx: int = int(mi._slotStart[b]) * stride
	return Color(mi._cpuBuffer[idx + 8], mi._cpuBuffer[idx + 9],
			mi._cpuBuffer[idx + 10], mi._cpuBuffer[idx + 11])

func test_wire_a_b_colors() -> void:
	if not await _boot():
		return
	var sys: SWBuildLayerSystem = harness.build_layer.layer_system
	var dm = harness.build_layer.sw_draw_manager
	var checked: int = 0
	var bad: int = 0
	var mixed_nets: Dictionary = {}
	var bad_samples: Array[String] = []
	for b: SWBuildItemDefine in sys.build_manager.getAllBuilds():
		if b.buildDefine.circuit_component_type != SwDefine.CircuitComponentType.WIRE:
			continue
		if b.in_loop:
			continue
		var bname: String = b.buildDefine.buildName
		if bname != "电线A" and bname != "电线B":
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
		var got: Color = _build_color(mi, b)
		var arr: Array[Color] = SwCommon.GetWireColor(bname)
		var want: Color = arr[1] if net.curSignal == SwDefine.CircuitSignal.HIGH else arr[0]
		checked += 1
		if not got.is_equal_approx(want):
			bad += 1
			if bad_samples.size() < 5:
				bad_samples.append("%s@%s got=%s want=%s" % [bname, str(b.buildAxisPos), str(got), str(want)])
		if net.wireGroup != null and not mixed_nets.has(net):
			var has_a := false
			var has_b := false
			for w in net.wireGroup.wireBuilds.keys():
				if w.buildDefine.buildName == "电线A":
					has_a = true
				elif w.buildDefine.buildName == "电线B":
					has_b = true
			if has_a and has_b:
				mixed_nets[net] = true
	print("[ab] checked=%d bad=%d mixedNets=%d" % [checked, bad, mixed_nets.size()])
	for s in bad_samples:
		print("[ab]  ", s)
	print("[ab] 电线A色=%s 电线B色=%s" % [
		str(SwCommon.GetWireColor("电线A")[0]), str(SwCommon.GetWireColor("电线B")[0])])
	assert_gt(checked, 0, "没有可检查的电线")
	assert_gt(mixed_nets.size(), 0, "存档里没有 A/B 混接的 net，验证不成立")
	assert_eq(bad, 0, "有 %d 根电线没有用自己的线别取色" % bad)

func test_select_is_color_patch() -> void:
	if not await _boot():
		return
	var sys: SWBuildLayerSystem = harness.build_layer.layer_system
	var dm = harness.build_layer.sw_draw_manager
	var step: int = SwDefine.GRID_SIZE.x * SwDefine.CHUNK_SIZE
	var chunkPos := Vector2i(-999999, -999999)
	var mi: SWMultiMeshInstance2D = null
	var sample: SWBuildItemDefine = null
	for cp: Vector2i in dm.get_loaded_chunk_positions():
		var cand: Array = sys.build_manager.getBuildsByChunkPos(cp)
		if cand.size() < 20:
			continue
		var cand_mi: SWMultiMeshInstance2D = dm._chunkInstance[cp].mesh_instance
		for b: SWBuildItemDefine in cand:
			if cand_mi != null and cand_mi._slotStart.has(b):
				chunkPos = cp
				mi = cand_mi
				sample = b
				break
		if sample != null:
			break
	if sample == null:
		fail_test("找不到可用的已加载区块")
		return
	var before: Color = _build_color(mi, sample)
	assert_eq(dm._rebuild_queue.size(), 0, "选中前就有残留的整块重建队列")
	var rect := Rect2(Vector2(chunkPos), Vector2(step, step))
	var t0: int = Time.get_ticks_usec()
	sys.on_select_by_rect(rect)
	var ms: float = (Time.get_ticks_usec() - t0) / 1000.0
	var after: Color = _build_color(mi, sample)
	var selected_count: int = sys._selected_builds.size()
	print("[sel] first select ms=%.1f builds=%d before=%s after=%s rebuildQueue=%d" % [
		ms, selected_count, str(before), str(after), dm._rebuild_queue.size()])
	assert_gt(selected_count, 0, "没有选中任何建筑")
	assert_ne(after, before, "选中后区块 buffer 的颜色没有变化")
	assert_true(dm._rebuild_queue.is_empty(), "框选退化成了整块重建")
	# 重复框选同一批：应当去重后直接返回
	var t1: int = Time.get_ticks_usec()
	sys.on_select_by_rect(rect)
	var ms2: float = (Time.get_ticks_usec() - t1) / 1000.0
	print("[sel] repeat select ms=%.1f" % ms2)
	assert_lt(ms2, 50.0, "重复框选没有去重（%.1f ms）" % ms2)
	# 取消框选同样应走颜色补丁
	var t2: int = Time.get_ticks_usec()
	sys.on_deselect_by_rect(rect)
	var ms3: float = (Time.get_ticks_usec() - t2) / 1000.0
	var back: Color = _build_color(mi, sample)
	print("[sel] deselect ms=%.1f colorBack=%s rebuildQueue=%d" % [ms3, str(back), dm._rebuild_queue.size()])
	assert_ne(back, after, "取消框选后颜色没有还原")
	assert_true(dm._rebuild_queue.is_empty(), "取消框选退化成了整块重建")

# 选中高亮不是电路状态：LOD1/LOD2 冻结颜色时也必须立刻写入缓冲
func test_select_color_applies_in_all_lod() -> void:
	if not await _boot():
		return
	var sys: SWBuildLayerSystem = harness.build_layer.layer_system
	var dm = harness.build_layer.sw_draw_manager
	var step: int = SwDefine.GRID_SIZE.x * SwDefine.CHUNK_SIZE
	var chunkPos := Vector2i(-999999, -999999)
	var mi: SWMultiMeshInstance2D = null
	var sample: SWBuildItemDefine = null
	for cp: Vector2i in dm.get_loaded_chunk_positions():
		var cand: Array = sys.build_manager.getBuildsByChunkPos(cp)
		if cand.size() < 20:
			continue
		var cand_mi: SWMultiMeshInstance2D = dm._chunkInstance[cp].mesh_instance
		for b: SWBuildItemDefine in cand:
			if cand_mi != null and cand_mi._slotStart.has(b):
				chunkPos = cp
				mi = cand_mi
				sample = b
				break
		if sample != null:
			break
	if sample == null:
		fail_test("找不到可用的已加载区块")
		return
	var rect := Rect2(Vector2(chunkPos), Vector2(step, step))
	for lod: int in [1, 2]:
		SwAtlas.set_lod(lod)
		harness.flush_draw_queue()
		var before: Color = _build_color(mi, sample)
		sys.on_select_by_rect(rect)
		var after: Color = _build_color(mi, sample)
		print("[sellod] LOD%d before=%s after=%s rebuildQueue=%d" % [
			lod, str(before), str(after), dm._rebuild_queue.size()])
		assert_ne(after, before, "LOD%d 下选中后颜色没有变化" % lod)
		assert_true(dm._rebuild_queue.is_empty(), "LOD%d 选中退化成了整块重建" % lod)
		sys.on_deselect_by_rect(rect)
		var back: Color = _build_color(mi, sample)
		assert_eq(back, before, "LOD%d 取消选中后颜色没有还原" % lod)
	SwAtlas.set_lod(0)

func test_select_all_timing() -> void:
	if not await _boot():
		return
	var sys: SWBuildLayerSystem = harness.build_layer.layer_system
	var dm = harness.build_layer.sw_draw_manager
	var all_rect := Rect2(-1e9, -1e9, 2e9, 2e9)
	var all_builds: Array = sys.build_manager.getAllBuilds()
	var mn := Vector2i(1 << 30, 1 << 30)
	var mx := -mn
	for b: SWBuildItemDefine in all_builds:
		mn.x = mini(mn.x, b.buildAxisPos.x)
		mn.y = mini(mn.y, b.buildAxisPos.y)
		mx.x = maxi(mx.x, b.buildAxisPos.x)
		mx.y = maxi(mx.y, b.buildAxisPos.y)
	all_rect = Rect2(Vector2(mn), Vector2(mx - mn + SwDefine.GRID_SIZE))
	var t0: int = Time.get_ticks_usec()
	sys.on_select_by_rect(all_rect)
	var ms: float = (Time.get_ticks_usec() - t0) / 1000.0
	print("[selall] select ms=%.1f selected=%d rebuildQueue=%d patchLeft=%d" % [
		ms, sys._selected_builds.size(), dm._rebuild_queue.size(), dm._patch_queue.size()])
	var t1: int = Time.get_ticks_usec()
	sys.on_deselect_by_rect(all_rect)
	var ms2: float = (Time.get_ticks_usec() - t1) / 1000.0
	print("[selall] deselect ms=%.1f rebuildQueue=%d patchLeft=%d" % [
		ms2, dm._rebuild_queue.size(), dm._patch_queue.size()])
	assert_true(dm._rebuild_queue.is_empty(), "全选退化成了整块重建")

func test_lod_swap_keeps_instances() -> void:
	if not await _boot():
		return
	var dm = harness.build_layer.sw_draw_manager
	assert_gt(SwAtlas.get_lod_count(), 0, "没有登记 LOD 图集")
	var mi: SWMultiMeshInstance2D = null
	for cp: Vector2i in dm.get_loaded_chunk_positions():
		var cand: SWMultiMeshInstance2D = dm._chunkInstance[cp].mesh_instance
		if cand != null and cand._cpuBuffer.size() > 0:
			mi = cand
			break
	if mi == null:
		fail_test("没有已构建的区块")
		return
	var before: PackedFloat32Array = mi._cpuBuffer.duplicate()
	var mat := mi.material as ShaderMaterial
	# 存档视口可能本来就缩在 LOD 档位，先强制回全分辨率再测切换
	SwAtlas.set_lod(0)
	harness.flush_draw_queue()
	before = mi._cpuBuffer.duplicate()
	assert_eq(mat.get_shader_parameter("srcImg"), SwAtlas.current)
	var t0: int = Time.get_ticks_usec()
	SwAtlas.set_lod(1)
	var ms: float = (Time.get_ticks_usec() - t0) / 1000.0
	print("[lod] switch ms=%.1f scale=%.2f" % [ms, SwAtlas.lod_scale])
	assert_eq(SwAtlas.lod_level, 1)
	assert_eq(mat.get_shader_parameter("srcImg"), SwAtlas.lod_textures[0], "LOD1 纹理没有生效")
	assert_almost_eq(float(mat.get_shader_parameter("atlas_scale")), SwAtlas.lod_scale, 0.0001)
	# 换档只做一次强制重染（连线统一 high 色），几何/图集列不动，也不重建区块
	harness.flush_draw_queue()
	assert_true(_geometry_same(mi._cpuBuffer, before), "换 LOD 改动了实例几何")
	assert_true(dm._rebuild_queue.is_empty(), "换 LOD 触发了区块重建")
	if SwAtlas.get_lod_count() >= 2:
		SwAtlas.set_lod(2)
		print("[lod] lod2 scale=%.2f" % SwAtlas.lod_scale)
		assert_eq(SwAtlas.lod_level, 2)
		assert_eq(mat.get_shader_parameter("srcImg"), SwAtlas.lod_textures[1], "LOD2 纹理没有生效")
		assert_almost_eq(float(mat.get_shader_parameter("atlas_scale")), SwAtlas.lod_scale, 0.0001)
		assert_almost_eq(SwAtlas.lod_scale, 4.0, 0.0001, "LOD2 应为 1/4 尺寸")
		harness.flush_draw_queue()
		assert_true(_geometry_same(mi._cpuBuffer, before), "换 LOD2 改动了实例几何")
		# 超出已加载档位时退到最高一级，而不是切到不存在的纹理
		SwAtlas.set_lod(9)
		assert_eq(SwAtlas.lod_level, 2)
		assert_eq(mat.get_shader_parameter("srcImg"), SwAtlas.lod_textures[1])
	SwAtlas.set_lod(0)
	harness.flush_draw_queue()
	assert_eq(mat.get_shader_parameter("srcImg"), SwAtlas.current, "没有换回全分辨率纹理")
	assert_almost_eq(float(mat.get_shader_parameter("atlas_scale")), 1.0, 0.0001)
	assert_eq(mi._cpuBuffer, before, "回 LOD0 后实例缓冲没有还原")

# 除颜色列（8..11）外逐字段比较：换档允许重染颜色，但不允许改几何/图集帧
func _geometry_same(a: PackedFloat32Array, b: PackedFloat32Array) -> bool:
	if a.size() != b.size():
		return false
	var stride: int = SWBuildCompoentRenderable.INSTANCE_STRIDE
	for i in range(0, a.size(), stride):
		for k in stride:
			if k >= 8 and k < 12:
				continue
			if a[i + k] != b[i + k]:
				return false
	return true

# LOD 降级后除灯泡外的建筑不随电路更新：连线统一 high 色且不再变、图集帧继续更新；回 LOD0 还原
func test_lod_freezes_signal_colors() -> void:
	if not await _boot():
		return
	var dm = harness.build_layer.sw_draw_manager
	SwAtlas.set_lod(0)
	harness.flush_draw_queue()
	var mi: SWMultiMeshInstance2D = null
	var cp: Vector2i = Vector2i.ZERO
	for c: Vector2i in dm.get_loaded_chunk_positions():
		var cand: SWMultiMeshInstance2D = dm._chunkInstance[c].mesh_instance
		if cand != null and not cand._netEntries.is_empty():
			mi = cand
			cp = c
			break
	if mi == null:
		fail_test("没有带连线颜色索引的已构建区块")
		return
	var net: SWNet = (mi._netEntries[0] as SWNetColorEntry).net
	# 降级：进入 LOD 会整屏重染一次（连线统一 high 色），之后再翻转电平就不该有任何回写
	SwAtlas.set_lod(1)
	harness.flush_draw_queue()
	var frozen: PackedFloat32Array = mi._cpuBuffer.duplicate()
	if net.curSignal != SwDefine.CircuitSignal.LOW:
		net.curSignal = SwDefine.CircuitSignal.LOW
	else:
		net.curSignal = SwDefine.CircuitSignal.HIGH
	net.sigVersion += 1
	SwCommon.netPatchStamp += 1
	net.patchStamp = SwCommon.netPatchStamp
	assert_false(mi.patchNets(), "LOD1 期间不应回写连线颜色")
	assert_eq(mi._cpuBuffer, frozen, "LOD1 期间连线颜色跟随了电路")
	# 但图集帧（灯泡/开关/寄存器）必须继续更新
	var atlas_build: SWBuildItemDefine = null
	for b: SWBuildItemDefine in mi.curMapData:
		if not mi._slotStart.has(b):
			continue
		var c0: SWBuildCompoentRenderable = b.getRenderableCompoent()
		if c0 != null and c0.buildHasAtlas:
			atlas_build = b
			break
	if atlas_build == null:
		fail_test("区块里没有带图集帧的建筑")
		return
	var comp: SWBuildCompoentRenderable = atlas_build.getRenderableCompoent()
	comp.drawRect = Rect2(comp.drawRect.position + Vector2(1, 0), comp.drawRect.size)
	comp.markAtlasRectDirty()
	var cps: Array[Vector2i] = [cp]
	dm.updataChunks(cps, [atlas_build], {}, 1000000)
	assert_true(mi._cpuBuffer != frozen, "LOD1 期间图集帧（灯泡/开关）没有更新")
	# 回到全分辨率：冻结期间的电平变化被补齐（连线从统一 high 色还原成真实电平）
	var last: PackedFloat32Array = mi._cpuBuffer.duplicate()
	# LOD2：连图集帧一起冻结——信号变化的补丁不再产生任何 buffer 写回或上传
	SwAtlas.set_lod(2)
	harness.flush_draw_queue()
	assert_true(SwAtlas.is_frame_updates_frozen(), "LOD2 应处于整屏冻结")
	var frozen2: PackedFloat32Array = mi._cpuBuffer.duplicate()
	var uploads_before: int = SWMultiMeshInstance2D.dbg_uploads
	comp.drawRect = Rect2(comp.drawRect.position + Vector2(1, 0), comp.drawRect.size)
	comp.markAtlasRectDirty()
	dm.updataChunks(cps, [atlas_build], {}, 1000000)
	assert_eq(mi._cpuBuffer, frozen2, "LOD2 期间图集帧仍随电路更新")
	assert_eq(SWMultiMeshInstance2D.dbg_uploads, uploads_before, "LOD2 期间仍然上传了 buffer")
	assert_true(dm._rebuild_queue.is_empty(), "LOD2 期间补丁退化成了整块重建")
	# 回 LOD0：冻结期间的图集帧与电平颜色一次性补齐
	SwAtlas.set_lod(0)
	harness.flush_draw_queue()
	assert_true(dm._color_resync_queue.is_empty(), "LOD 恢复后的颜色补齐没有跑完")
	assert_true(mi._cpuBuffer != last, "回到 LOD0 后没有还原真实电平颜色")
	var ai: int = int(comp._atlasPartIndex)
	assert_true(ai >= 0 and mi._slotStart.has(atlas_build), "图集帧部件索引丢失")
	var idx: int = (int(mi._slotStart[atlas_build]) + ai) \
			* SWBuildCompoentRenderable.INSTANCE_STRIDE + 12
	assert_almost_eq(mi._cpuBuffer[idx], comp.drawRect.position.x, 0.0001, "回 LOD0 后图集帧没有补齐")

# 取某建筑各连线部件（带 pin_dir 的部件）在区块缓冲里的实例颜色
func _wire_part_colors(mi: SWMultiMeshInstance2D, b: SWBuildItemDefine) -> Array[Color]:
	var out: Array[Color] = []
	if not mi._slotStart.has(b):
		return out
	var parts: Array = b.getRenderableCompoent().getRenderParts()
	var start: int = int(mi._slotStart[b])
	var stride: int = SWBuildCompoentRenderable.INSTANCE_STRIDE
	for i in parts.size():
		if not (parts[i] as Dictionary).has("pin_dir"):
			continue
		var idx: int = (start + i) * stride + 8
		out.append(Color(mi._cpuBuffer[idx], mi._cpuBuffer[idx + 1],
				mi._cpuBuffer[idx + 2], mi._cpuBuffer[idx + 3]))
	return out

# 低分辨率档位下所有电线统一取 high 色，回到 LOD0 还原真实电平
func test_lod_forces_wire_high_color() -> void:
	if not await _boot():
		return
	var dm = harness.build_layer.sw_draw_manager
	var sys: SWBuildLayerSystem = harness.build_layer.layer_system
	# 找一根当前为低电平的电线：LOD 档应变成 high 色
	var low_wire: SWBuildItemDefine = null
	for b: SWBuildItemDefine in sys.build_manager.getAllBuilds():
		if b.buildDefine.circuit_component_type != SwDefine.CircuitComponentType.WIRE:
			continue
		var bname: String = b.buildDefine.buildName
		if bname != "电线A" and bname != "电线B":
			continue
		if b.in_loop:
			continue
		var cir: SWBuildCompoentCircuit = b.getCircuitCompoent()
		for d in 4:
			var n: SWNet = cir.pinNetMap.get(d, null)
			if n != null and n.curSignal == SwDefine.CircuitSignal.LOW:
				low_wire = b
				break
		if low_wire != null:
			break
	if low_wire == null:
		fail_test("找不到低电平的电线，无法验证 LOD high 色")
		return
	var mi: SWMultiMeshInstance2D = dm._chunkInstance[
			SwCommon.GetChunkPos(low_wire.buildAxisPos)].mesh_instance
	var palette: Array[Color] = SwCommon.GetWireColor(low_wire.buildDefine.buildName)
	var mask: Color = low_wire.buildState.mask_color
	var expect_low: Color = mask * palette[0]
	var expect_high: Color = mask * palette[1]
	SwAtlas.set_lod(0)
	harness.flush_draw_queue()
	assert_true(_wire_part_colors(mi, low_wire).has(expect_low), "LOD0 该电线的低电平段不是 low 色")
	SwAtlas.set_lod(1)
	harness.flush_draw_queue()
	var cols: Array[Color] = _wire_part_colors(mi, low_wire)
	assert_gt(cols.size(), 0, "该电线没有任何连线部件")
	for c in cols:
		assert_eq(c, expect_high, "LOD1 期间电线没有统一成 high 色")
	SwAtlas.set_lod(2)
	harness.flush_draw_queue()
	for c in _wire_part_colors(mi, low_wire):
		assert_eq(c, expect_high, "LOD2 期间电线没有统一成 high 色")
	SwAtlas.set_lod(0)
	harness.flush_draw_queue()
	assert_true(_wire_part_colors(mi, low_wire).has(expect_low), "回到 LOD0 后电线颜色没有还原")

# 读档指纹：建筑数 / 电路分组 / 每建筑电平。分帧加载必须与同步加载逐位一致
# （重建结果对建筑遍历顺序敏感，分区间的实现不能改变顺序）。
# 注意不能拿 build.id 做键：那是全局自增计数，跨两次加载必然不同
func _fingerprint(sys: SWBuildLayerSystem) -> String:
	var all: Array = sys.build_manager.getAllBuilds()
	var sig: int = 0
	var cirRep: Dictionary = {}
	for b: SWBuildItemDefine in all:
		sig = sig * 1000003 + b.buildAxisPos.x * 7 + b.buildAxisPos.y * 13 \
				+ int(b.signal_state) + b.buildDefine.buildName.hash()
		if b.circuit != null:
			var key: String = str(b.buildAxisPos)
			var cur = cirRep.get(b.circuit, "")
			if cur == "" or key < cur:
				cirRep[b.circuit] = key
	var reps: Array = cirRep.values()
	reps.sort()
	return "%d-%d-%d" % [all.size(), cirRep.size(), str(reps).hash()]

func _state_map(sys: SWBuildLayerSystem) -> Dictionary:
	var m: Dictionary = {}
	for b: SWBuildItemDefine in sys.build_manager.getAllBuilds():
		m["%s@%s" % [b.buildDefine.buildName, str(b.buildAxisPos)]] = int(b.signal_state)
	return m

func test_async_load_matches_sync() -> void:
	await harness.boot_game()
	var sys: SWBuildLayerSystem = harness.build_layer.layer_system
	#关掉时钟 tick：比较的是「加载本身」的确定性，不让中途多跑一拍计数器
	sys.enable = false
	var data := SWSaveManager.load_builds("计数器2")
	if data.is_empty():
		fail_test("存档不存在: 计数器2")
		return
	sys.load_save_data(data)
	var fp_sync: String = _fingerprint(sys)
	var sync_map: Dictionary = _state_map(sys)
	var data2 := SWSaveManager.load_builds("计数器2")
	var stages: Array[String] = []
	await sys.load_save_data_async(data2, func(_p: float, t: String) -> void:
		stages.append(t))
	var fp_async: String = _fingerprint(sys)
	var async_map: Dictionary = _state_map(sys)
	sys.enable = true
	var diff: Array[String] = []
	for key in sync_map:
		if async_map.get(key, -1) != sync_map[key]:
			diff.append("%s sync=%d async=%d" % [key, sync_map[key], int(async_map.get(key, -1))])
	print("[async] sync=%s async=%s stages=%d diff=%d" % [fp_sync, fp_async, stages.size(), diff.size()])
	for k in mini(diff.size(), 8):
		print("[async]   ", diff[k])
	assert_eq(fp_async, fp_sync, "分帧加载结果与同步加载不一致（%d 个建筑不同）" % diff.size())

func test_async_load_timing() -> void:
	await harness.boot_game()
	var sys: SWBuildLayerSystem = harness.build_layer.layer_system
	var data := SWSaveManager.load_builds("16x计数器")
	if data.is_empty():
		fail_test("存档不存在: 16x计数器")
		return
	var t0: int = Time.get_ticks_usec()
	#lambda 按值捕获局部变量，测量结果要放进数组（引用类型）里才拿得回来
	var box: Array = [t0, 0]   # [last_usec, max_gap_usec]
	var log: Array[String] = []
	await sys.load_save_data_async(data, func(p: float, t: String) -> void:
		var now: int = Time.get_ticks_usec()
		box[1] = maxi(box[1], now - box[0])
		box[0] = now
		log.append("%-16s %3.0f%%  +%.0fms" % [t, p * 100.0, (now - t0) / 1000.0]))
	var total: float = (Time.get_ticks_usec() - t0) / 1000.0
	var max_gap: int = box[1]
	print("[async] total=%.0fms maxFrameGap=%.0fms" % [total, max_gap / 1000.0])
	for s in log:
		print("[async]   ", s)
	assert_gt(log.size(), 0, "没有收到任何进度回调")
