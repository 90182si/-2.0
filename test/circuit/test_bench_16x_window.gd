extends GutTest
# 带窗口帧剖析（headless 无 RenderingDevice，渲染侧成本测不了；此测试必须 NoHeadless 跑）。
# 载入 16x计数器 后：①真实视口帧时间分布 ②全部区块强制可见的最坏帧时间 ③关掉场景后的纯渲染帧时间
# 输出 _perf_16x_window.txt

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const SAVE_NAME := "16x计数器"
const LOG_PATH := "j:/godot/无限地图/_perf_16x_window.txt"

var _lines: Array[String] = []

func _w(msg: String) -> void:
	_lines.append(msg)

func _dump() -> void:
	var f := FileAccess.open(LOG_PATH, FileAccess.WRITE)
	for l in _lines:
		f.store_line(l)
	f.close()

# 真实「呈现帧」耗时：await process_frame（一次 = 一帧渲染），不能用 physics_frame——
# 慢渲染时物理会 catch-up 补跑多个子步，子步之间几乎 0 间隔，physics_frame 间距
# 量出来是「物理节奏」而非「帧率」，会严重低估真实帧时间（这正是此前 5.9ms 假象的根源）
func _time_frames(n: int) -> Array:
	var tree := get_tree()
	var times := []
	var last := Time.get_ticks_usec()
	for i in n:
		await tree.process_frame
		var now := Time.get_ticks_usec()
		times.append(float(now - last) / 1000.0)
		last = now
	return times

# 呈现帧 + 引擎内置监控快照：TIME_FPS 是引擎自算的每秒呈现帧数（最贴近用户看到的「帧」），
# 再取当帧 draw call / 三角面 / GPU 处理时间，判断瓶颈在渲染提交还是脚本逻辑
func _fps_probe(tag: String, n: int) -> void:
	var tree := get_tree()
	var fps_sum := 0.0
	var dc := 0
	var prim := 0
	var gpu := 0.0
	for i in n:
		await tree.process_frame
		fps_sum += Performance.get_monitor(Performance.TIME_FPS)
		dc = maxi(dc, int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
		prim = maxi(prim, int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)))
		gpu = maxf(gpu, Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	var eng_fps: float = Engine.get_frames_per_second()
	_w("%s FPS(引擎)=%s TIME_FPS均=%s draw_call=%d 面数=%d process=%.2fms" % [
		tag, str(roundi(eng_fps)), str(roundi(fps_sum / float(maxi(n, 1)))), dc, prim, gpu])

func test_windowed_frame_profile() -> void:
	var harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)
	await harness.boot_game()
	var data: Dictionary = await harness.load_save(SAVE_NAME)
	if data.is_empty():
		_w("LOAD FAILED")
		_dump()
		return
	var sys = harness.build_layer.layer_system
	var dm = harness.build_layer.sw_draw_manager
	var ctrl = sys.circuit_control
	var guard := 0
	while guard < 600 and not ctrl._neighborsCache.is_empty():
		guard += 1
		await get_tree().process_frame
	var n_chunk: int = harness.force_load_all_chunks()
	harness.flush_draw_queue()
	var inst := 0
	var vis := 0
	for cp in dm._chunkInstance.keys():
		var mi = dm._chunkInstance[cp].mesh_instance
		if mi != null:
			inst += mi.multimesh.visible_instance_count
			if mi.visible:
				vis += 1
	_w("chunks=%d visible_chunks=%d instances=%d clocks=%d" % [n_chunk, vis, inst, sys.clockBuildArr.size()])
	await wait_process_frames(30)
	var t_view := await _time_frames(180)
	_w("真实视口帧 med=%s p90=%s max=%s" % [str(_p(t_view, 0.5)), str(_p(t_view, 0.9)), str(_max(t_view))])
	# ===== 真机呈现帧率拆解：逻辑 vs 渲染 =====
	# ① 正常：时钟 30Hz 驱动 + 区块可见（对应用户看到的帧）
	await _fps_probe("①正常(clock+区块)", 120)
	# ② 冻结时钟（清空时钟注册表，电路 tick 不再跑），只留渲染 → 分离脚本逻辑成本
	var _saved_clocks: Array = sys.clockBuildArr.keys()
	sys.clockBuildArr.clear()
	await _fps_probe("②时钟停(纯渲染)", 120)
	# ③ 恢复时钟但隐藏全部区块 → 只留逻辑，无提交
	for cp in dm._chunkInstance.keys():
		dm._chunkInstance[cp].mesh_instance.visible = false
	await _fps_probe("③区块隐(纯逻辑)", 120)
	# 恢复：时钟注册表 + 区块可见
	for _c in _saved_clocks:
		sys.clockBuildArr[_c] = true
	for cp in dm._chunkInstance.keys():
		dm._chunkInstance[cp].mesh_instance.visible = true
	# ④ 整图入镜（最坏渲染压力）：把相机拉到极小 zoom，让全部区块进入真实裁剪框。
	# renderer 按相机矩形而非 visible 旗标剔除 CanvasItem，前面 draw_call=150 说明只有部分地图入镜；
	# 用户缩小看全局时才会一次性画出几百个 MultiMeshInstance2D 节点
	var cam = harness.camera
	cam.zoom = Vector2(0.05, 0.05)
	await wait_process_frames(30)
	await _fps_probe("④整图入镜(zoom缩)", 120)
	SWSaveManager.apply_viewport(cam, data)
	# ===== 每拍 tick 成本分解（真机 D3D12：GPU 后端 vs CPU 数据驱动）=====
	var clocks: Array[SWBuildItemDefine] = []
	clocks.assign(sys.clockBuildArr.keys())
	var t_gpu_eval := await _bench_eval(ctrl, sys, clocks, true)
	var t_cpu_eval := await _bench_eval(ctrl, sys, clocks, false)
	_w("GPU拍均=%sms CPU拍均=%sms" % [str(_avg(t_gpu_eval)), str(_avg(t_cpu_eval))])
	_w("GPU拍 med=%s p90=%s max=%s" % [str(_p(t_gpu_eval, 0.5)), str(_p(t_gpu_eval, 0.9)), str(_max(t_gpu_eval))])
	_w("CPU拍 med=%s p90=%s max=%s" % [str(_p(t_cpu_eval, 0.5)), str(_p(t_cpu_eval, 0.9)), str(_max(t_cpu_eval))])
	# 相位分解：定位 p90 尖峰在 engine 还是 apply 回填
	var ph: Array = await _phase_breakdown(ctrl, sys)
	_w("engine med=%s p90=%s max=%s" % [str(_p(ph[0], 0.5)), str(_p(ph[0], 0.9)), str(_max(ph[0]))])
	_w("apply1 med=%s p90=%s max=%s" % [str(_p(ph[1], 0.5)), str(_p(ph[1], 0.9)), str(_max(ph[1]))])
	ctrl.gpu_backend_enabled = true
	# 最坏情况：全部区块强制可见
	for cp in dm._chunkInstance.keys():
		dm._chunkInstance[cp].mesh_instance.visible = true
	await wait_process_frames(30)
	var t_all := await _time_frames(180)
	_w("全部区块帧 med=%s p90=%s max=%s" % [str(_p(t_all, 0.5)), str(_p(t_all, 0.9)), str(_max(t_all))])
	# 纯渲染基线：隐藏全部区块（电路 tick 照跑）
	for cp in dm._chunkInstance.keys():
		dm._chunkInstance[cp].mesh_instance.visible = false
	await wait_process_frames(30)
	var t_nodraw := await _time_frames(180)
	_w("隐藏区块帧 med=%s p90=%s max=%s" % [str(_p(t_nodraw, 0.5)), str(_p(t_nodraw, 0.9)), str(_max(t_nodraw))])
	# 相位诊断：CPU 路径逐拍拆解（dbg_phases 由 _eval_backends 每拍清零累加）
	ctrl.gpu_backend_enabled = false
	var t_eval := []
	var ph_vals := []
	var flips := []
	var notifies := []
	for i in 60:
		for c in clocks:
			c.onPressed(true)
		var t0 := Time.get_ticks_usec()
		var changed: Array[SWBuildItemDefine] = ctrl.buildSignalsChanged(clocks)
		sys.refresh_signal_chunks(changed)
		var t1 := Time.get_ticks_usec()
		t_eval.append(float(t1 - t0) / 1000.0)
		ph_vals.append(ctrl.dbg_phases.duplicate())
		flips.append(ctrl.dbg_flip_nets)
		notifies.append(SwCommon.dbgEvaluated)
		await get_tree().process_frame
	_w("CPU拍 med=%s p90=%s max=%s" % [str(_p(t_eval, 0.5)), str(_p(t_eval, 0.9)), str(_max(t_eval))])
	var names := ["收集输入", "net发布", "engine", "回填总", "notify刷", "净回读"]
	for p in 6:
		var pv := []
		for v in ph_vals:
			pv.append(float(v[p]) / 1000.0)
		_w("  %s med=%s p90=%s max=%s" % [names[p], str(_p(pv, 0.5)), str(_p(pv, 0.9)), str(_max(pv))])
	# 最慢 3 拍的完整相位
	var order := []
	for i in t_eval.size():
		order.append(i)
	order.sort_custom(func(a, b): return t_eval[a] > t_eval[b])
	for j in mini(3, order.size()):
		var i: int = order[j]
		var one := []
		for p in 6:
			one.append("%s=%.2f" % [names[p], float(ph_vals[i][p]) / 1000.0])
		_w("  慢拍#%d total=%.2f flip_nets=%d notify=%d %s" % [
			i, t_eval[i], flips[i], notifies[i], " ".join(one)])
	_dump()
	pass_test("window profile done")

static func _avg(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += v
	return roundf(s / a.size() * 1000.0) / 1000.0

# 每拍走游戏同源入口：时钟翻转 + 求值回填 + 显示刷新
func _bench_eval(ctrl, sys, clocks: Array[SWBuildItemDefine], gpu: bool) -> Array:
	ctrl.gpu_backend_enabled = gpu
	var times := []
	for i in 120:
		for c in clocks:
			c.onPressed(true)
		var t0 := Time.get_ticks_usec()
		var changed: Array[SWBuildItemDefine] = ctrl.buildSignalsChanged(clocks)
		sys.refresh_signal_chunks(changed)
		var t1 := Time.get_ticks_usec()
		times.append(float(t1 - t0) / 1000.0)
		await get_tree().process_frame
	return times

# 相位分解：用一次性钩子把 buildSignalsChanged 内部拆成 engine 求值 / apply 回填
func _phase_breakdown(ctrl, sys) -> Array:
	var eng_t := []
	var apply_t := []
	for i in 60:
		for c in sys.clockBuildArr.keys():
			(c as SWBuildItemDefine).onPressed(true)
		# 钩住首个 CPU 后端测 engine 相位
		var be: Dictionary = ctrl._cpu_backends.values()[0]
		var engine = be["engine"]
		var prog: SWGateProgram = be["prog"]
		var t0 := Time.get_ticks_usec()
		engine.write_sources(ctrl._buildInputVals(prog))
		engine.evaluate()
		var t1 := Time.get_ticks_usec()
		ctrl._applyBackendResult(null, prog, engine.readback(), engine.read_reg_state())
		var t2 := Time.get_ticks_usec()
		eng_t.append(float(t1 - t0) / 1000.0)
		apply_t.append(float(t2 - t1) / 1000.0)
		await get_tree().process_frame
	return [eng_t, apply_t]

static func _max(a: Array) -> float:
	return _p(a, 1.0)

static func _p(a: Array, q: float) -> float:
	if a.is_empty():
		return 0.0
	var s := a.duplicate()
	s.sort()
	var idx: int = mini(int(s.size() * q), s.size() - 1)
	return roundf(float(s[idx]) * 1000.0) / 1000.0
