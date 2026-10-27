extends GutTest
# 16x计数器 性能/状态探针（不进默认门禁，按需显式运行）：
#   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/circuit/perf_16x_probe.gd -gexit
# 输出：加载耗时、每拍 求值/通知 平均耗时、状态变化次数；
# 并校验「存档→加载」后时钟自动注册、寄存器/时钟/开关状态原样恢复。

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const SAVE_NAME := "16x计数器"
const TMP_SAVE := "_perf_probe_16x"
const TICKS := 120

var harness = null

func before_each() -> void:
	harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)

func after_each() -> void:
	if harness != null:
		harness.shutdown_game()
		harness = null
	SWSaveManager.delete_save(TMP_SAVE)

func _system() -> SWBuildLayerSystem:
	return harness.build_layer.layer_system as SWBuildLayerSystem

func test_16x_eval_cost_and_state_roundtrip() -> void:
	await harness.boot_game()
	var t_load := Time.get_ticks_usec()
	#同步加载：中间不跑帧，否则时钟会先翻一次，存档状态对照必然不等
	var data: Dictionary = SWSaveManager.load_builds(SAVE_NAME)
	harness.build_layer.load_save_data(data)
	SWSaveManager.apply_viewport(harness.camera, data)
	var load_ms := (Time.get_ticks_usec() - t_load) / 1000.0
	assert_false(data.is_empty(), "存档加载失败: " + SAVE_NAME)

	var sys := _system()
	var cc := sys.circuit_control
	var clocks: Array[SWBuildItemDefine] = sys.clockBuildArr.keys()
	print("[probe] load_ms=%.1f builds=%d clocks=%d" % [
		load_ms, sys.build_manager.getBuildCount(), clocks.size()])
	assert_gt(clocks.size(), 0, "加载存档后 clockBuildArr 为空，时钟不会自动运行")

	#加载必须还原存档里的元件内部状态：按坐标对照（加载会重新分配 id）
	var restore := _check_restored_state(sys, data)
	print("[probe] state restore checked=%d mismatch=%d %s" % [
		restore["checked"], restore["mismatch"].size(), str(restore["mismatch"].slice(0, 5))])
	assert_eq(restore["mismatch"].size(), 0, "加载后元件状态与存档 JSON 不一致")

	#临时：主线程同步绘制 + 增量补丁路径成本（区块必须在场景树内，multimesh 才能提交）
	_bench_patch_path(sys)

	var eval_us: int = 0
	var notify_us: int = 0
	var changed_total: int = 0
	var chunk_total: int = 0
	var seen := {}
	for i in TICKS:
		var t0 := Time.get_ticks_usec()
		for clk in clocks:
			clk.onPressed(true)
		var changed := cc.buildSignalsChanged(clocks)
		var t1 := Time.get_ticks_usec()
		var chunks := sys.getSignalChangedChunkPosArr(changed)
		var t2 := Time.get_ticks_usec()
		eval_us += t1 - t0
		notify_us += t2 - t1
		changed_total += changed.size()
		chunk_total += chunks.size()
		if i < 12:
			print("[probe] tick%d eval=%.2fms gates=%d queue=%d flips=%d" % [
				i, (t1 - t0) / 1000.0, SwCommon.dbgEvaluated, SwCommon.dbgQueue, changed.size()])
		if i % 10 == 0:
			seen[_regs_key(sys)] = true

	var eval_avg := eval_us / 1000.0 / TICKS
	var notify_avg := notify_us / 1000.0 / TICKS
	print("[probe] eval=%.3f ms/tick notify=%.3f ms/tick changed=%.1f/tick chunks=%.1f/tick" % [
		eval_avg, notify_avg, float(changed_total) / TICKS, float(chunk_total) / TICKS])
	print("[probe] distinct register snapshots=%d" % seen.size())
	assert_gt(seen.size(), 1, "寄存器状态从未变化，计数器没有在运行")

	# 锁定相位再跑几拍：时钟不翻转时求值应当幂等，翻转数为 0 才说明没有虚假振荡
	for i in 4:
		var lt0 := Time.get_ticks_usec()
		var locked := cc.buildSignalsChanged(clocks)
		var lt1 := Time.get_ticks_usec()
		print("[probe] locked_tick ms=%.2f flips=%d" % [(lt1 - lt0) / 1000.0, locked.size()])
		sys.getSignalChangedChunkPosArr(locked)

	# 存档→加载：时钟注册、开关/时钟/寄存器状态必须原样恢复
	var before := _state_snapshot(sys)
	assert_true(SWSaveManager.save_builds(TMP_SAVE, sys.build_manager.getAllBuilds(), null),
		"写入临时存档失败")
	#同步加载：中间不跑游戏帧，否则自动 tick 会把时钟相位翻掉，断言随机失败
	var loaded_data: Dictionary = SWSaveManager.load_builds(TMP_SAVE)
	assert_false(loaded_data.is_empty(), "重新读取临时存档失败")
	harness.build_layer.load_save_data(loaded_data)
	var after := _state_snapshot(sys)
	assert_eq(_system().clockBuildArr.size(), clocks.size(), "重新加载后时钟注册数量不一致")
	assert_eq(after[0], before[0], "寄存器 Q 状态不一致")
	assert_eq(after[1], before[1], "时钟相位/按下状态不一致")
	assert_eq(after[2], before[2], "开关按下状态不一致")

# 逐项对照「存档 JSON」与「加载后的运行时元件」：
# 内部状态（寄存器 Q / 时钟相位 / 开关按下 / 隧道配对）+ 依赖状态的显示图集帧
func _check_restored_state(sys: SWBuildLayerSystem, data: Dictionary) -> Dictionary:
	var checked := 0
	var mismatch: Array = []
	for sb in data.get("builds", []):
		var pos_dict: Dictionary = sb.get("pos", {})
		var p := Vector2i(int(pos_dict.get("x", 0)), int(pos_dict.get("y", 0)))
		var b: SWBuildItemDefine = sys.build_manager.getBuild(p)
		if b == null:
			mismatch.append("%s 缺失" % str(p))
			continue
		var st: Dictionary = sb.get("state", {})
		if b is SWBuildRegister1Bit:
			checked += 1
			var cir := b.getCircuitCompoent() as SWBuildCompoentCircuitRegister
			var saved_q := int(st.get("q", SwDefine.CircuitSignal.LOW))
			if cir == null or int(cir.qState) != saved_q:
				mismatch.append("%s 寄存器 q=%s 期望%d" % [
					str(p), str(int(cir.qState) if cir else -1), saved_q])
		elif b is SWBuildClockSiggen:
			checked += 1
			var saved_sig := int(st.get("cur_sig", SwDefine.CircuitSignal.LOW))
			if int(b.curSig) != saved_sig:
				mismatch.append("%s 时钟 curSig=%d 期望%d" % [str(p), int(b.curSig), saved_sig])
		elif b is SWBuildButton:
			checked += 1
			var saved_pressed := bool(st.get("pressed", false))
			if b.pressed != saved_pressed:
				mismatch.append("%s 开关 pressed=%s 期望%s" % [
					str(p), str(b.pressed), str(saved_pressed)])
			#开关的 signal_state 在存档里可能滞后，显示帧直接按 pressed 判定
			var want_btn: Rect2 = b.buildDefine.atlasTextureOff.region
			if b.pressed:
				want_btn = b.buildDefine.atlasTextureOn.region
			if b.getRenderableCompoent().drawRect != want_btn:
				mismatch.append("%s 开关显示帧未刷新 pressed=%s" % [str(p), str(b.pressed)])
		elif b is SWBuildWireTunnel:
			checked += 1
			var saved_pair := int(sb.get("tunnel_pair_id", -1))
			#pairId 存的是存档里的旧 id，加载后重新分配，只校验「是否成对」这一语义
			if (b.pairId != -1) != (saved_pair != -1):
				mismatch.append("%s 隧道 pairId=%d 期望成对=%s" % [
					str(p), b.pairId, str(saved_pair != -1)])
		#显示必须跟随还原后的状态：LED/非门/寄存器按图集亮灭帧渲染
		if b is SWBuildLed or b is SWBuildNot or b is SWBuildRegister1Bit:
			checked += 1
			var want: Rect2 = b.buildDefine.atlasTextureOff.region
			if int(b.signal_state) == int(SwDefine.CircuitSignal.HIGH):
				want = b.buildDefine.atlasTextureOn.region
			if b.getRenderableCompoent().drawRect != want:
				mismatch.append("%s 显示帧未刷新 signal=%d" % [str(p), int(b.signal_state)])
	return {"checked": checked, "mismatch": mismatch}

#临时：把视口区块全部在主线程构建出来，再按每一拍真实调用绘制管理器，
#量出「同步重建一次全视口」和「增量补丁一拍」的主线程成本
func _bench_patch_path(sys: SWBuildLayerSystem) -> void:
	var v: SWBuildLayer = harness.build_layer
	var dm = v.sw_draw_manager
	if dm == null:
		print("[probe] patch bench skipped: draw manager 未就绪")
		return
	var dm_t0 := Time.get_ticks_usec()
	var loaded: int = harness.force_load_all_chunks()
	print("[probe] chunk build total=%.1fms loaded=%d" % [
		(Time.get_ticks_usec() - dm_t0) / 1000.0, loaded])

	var clocks: Array[SWBuildItemDefine] = sys.clockBuildArr.keys()
	var cc := sys.circuit_control
	var patch_us := 0
	var chunk_total := 0
	var full_total := 0
	SWMultiMeshInstance2D.dbg_net_checks = 0
	SWMultiMeshInstance2D.dbg_cols_written = 0
	SWMultiMeshInstance2D.dbg_uploads = 0
	SWMultiMeshInstance2D.dbg_floats_uploaded = 0
	for i in 20:
		for clk in clocks:
			clk.onPressed(true)
		var changed := cc.buildSignalsChanged(clocks)
		var pt := Time.get_ticks_usec()
		chunk_total += sys.refresh_signal_chunks(changed)
		patch_us += Time.get_ticks_usec() - pt
		full_total += dm.get_full_rebuilds_last_frame()
	print("[probe] patch path avg=%.3f ms/tick chunks=%.1f full_rebuild=%.1f loaded=%d" % [
		patch_us / 1000.0 / 20.0, float(chunk_total) / 20.0,
		float(full_total) / 20.0, loaded])
	print("[probe]   net_checks=%.0f/tick cols=%.0f/tick uploads=%.0f/tick KB=%.0f/tick" % [
		float(SWMultiMeshInstance2D.dbg_net_checks) / 20.0,
		float(SWMultiMeshInstance2D.dbg_cols_written) / 20.0,
		float(SWMultiMeshInstance2D.dbg_uploads) / 20.0,
		float(SWMultiMeshInstance2D.dbg_floats_uploaded) * 4.0 / 1024.0 / 20.0])

func _regs_key(sys: SWBuildLayerSystem) -> String:
	var key := ""
	for b in sys.build_manager.getAllBuilds():
		if b is SWBuildRegister1Bit:
			var cir := b.getCircuitCompoent() as SWBuildCompoentCircuitRegister
			if cir != null:
				key += str(b.id) + ":" + str(int(cir.qState)) + ","
	return key

# 与顺序无关的状态快照：寄存器 Q、时钟电平、开关按下
# 键用坐标而非 build.id——加载会重新分配 id，按 id 比较必然不等
# lastClk 不纳入比较：加载期的重建求值顺序不受控，会把它刷回 NONE，与存档无关
func _state_snapshot(sys: SWBuildLayerSystem) -> Array:
	var regs: Array = []
	var clks: Array = []
	var sws: Array = []
	for b in sys.build_manager.getAllBuilds():
		var p: Vector2i = b.buildAxisPos
		if b is SWBuildRegister1Bit:
			var cir := b.getCircuitCompoent() as SWBuildCompoentCircuitRegister
			if cir != null:
				regs.append([p.x, p.y, int(cir.qState)])
		elif b is SWBuildClockSiggen:
			clks.append([p.x, p.y, int(b.curSig), b.pressed])
		elif b is SWBuildButton:
			sws.append([p.x, p.y, b.pressed])
	regs.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	clks.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	sws.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	return [regs, clks, sws]
