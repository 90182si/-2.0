class_name SWSignalEvalGPU extends RefCounted

# T1.10 GPU 布尔算子求值引擎（用户方案落地）：
# SWGateCompiler 生成的 op_list（SWGateProgram）→ RD storage buffer →
# 单 compute_list 内逐层 dispatch（push constant 传层号）+ 帧边界寄存器锁存 pass。
#
# 数据流（每事件 tick/按钮）：
#   1. write_sources(values)：CPU 把源（时钟/按钮/开关）新值写入读侧缓冲的源 slot；
#   2. evaluate()：组合逐层求值 → 锁存 pass → （有寄存器时）再用新 Q 跑一遍组合，
#      让下游 LED/连线在同一个 tick 内看到新电平；最后交换缓冲；
#   3. readback()：从结果缓冲读回 slot 值（PackedInt32Array），集成方回填 net.curSignal/纹理。
#
# 与 CPU 树求值语义等价性（编译器保证 + 本引擎实现）：
#   - 多驱动线与 = 单条 OP_AND（编译器已合并，无 GPU 写冲突）；
#   - 悬空 net = OP_AND 空输入 → 0（低电平）；
#   - 寄存器：last_clk LOW→HIGH 上升沿采样拍前 D（同步语义）。

const STRIDE: int = SWGateProgram.STRIDE

var _rd: RenderingDevice
var _prog: SWGateProgram
var _broken := false

var _gates_buf: RID
var _slot_lv_buf: RID
var _layer_info_buf: RID
var _regs_buf: RID
var _reg_state_buf: RID
var _buf: Array = [RID(), RID()]
var _eval_shader: RID
var _eval_pipeline: RID
var _latch_shader: RID
var _latch_pipeline: RID
var _eval_sets: Array = [RID(), RID()]
var _level_sets: Array = []   # [phase][level]：每层独立 uniform set（layer_start 编码，零传参）
var _layer_start_bufs: Array = []
var _reg_count_buf: RID
var _latch_sets: Array = [RID(), RID()]
var _phase := 0
var _reg_count := 0


func setup(prog: SWGateProgram, shared_rd: RenderingDevice = null) -> void:
	# 4.7：主 RenderingDevice 不允许显式 submit/sync（"Only local devices can submit and sync"），
	# compute 求值必须用 local RD（引擎资源不共享给主渲染，readback 走 CPU）。
	# 优先用集成方传入的共享 local RD：多引擎才能一次 submit/sync，避免每电路一趟同步开销
	_rd = shared_rd if shared_rd != null else RenderingServer.create_local_rendering_device()
	if _rd == null:
		# 无 RenderingDevice（headless/软件后端）属正常降级：调用方回退 CPU，不视为引擎错误
		push_warning("SWSignalEvalGPU.setup: RenderingDevice 不可用，回退 CPU 求值")
		_broken = true
		return
	_prog = prog
	_reg_count = prog.reg_slots.size()

	# 静态表：gates（stride 8 展平）
	_gates_buf = _make_buf(prog.gates.to_byte_array())

	# slot_lv：gate 的 dst → 写层；其余（源/寄存器 Q/未写）→ -1
	var slot_lv := PackedInt32Array()
	slot_lv.resize(prog.slot_count)
	slot_lv.fill(-1)
	for gi in prog.gate_count:
		var base: int = gi * STRIDE
		var dst: int = prog.gates[base + 1]
		var lv: int = prog.gates[base + 2]
		if dst >= 0 and dst < prog.slot_count:
			slot_lv[dst] = lv
	_slot_lv_buf = _make_buf(slot_lv.to_byte_array())

	# 每层起点+层内 gate 数 buffer（8 字节）+ 每层独立 eval uniform set：list 内只换 bind，绕开 4.7 的
	# push constant API（compute_list_set_push_constant 在 4.7 对任何 stages 值均校验失败）与
	# buffer_update（compute_list 创建期间禁止）。count 供 shader 剔除 dispatch 多余线程越界。
	_layer_start_bufs = []
	for lv in prog.level_count:
		_layer_start_bufs.append(_make_buf(PackedInt32Array([
			prog.level_starts[lv], prog.level_counts[lv]]).to_byte_array()))
	# reg_count buffer（4 字节）：latch shader 剔除多余线程用
	_reg_count_buf = _make_buf(PackedInt32Array([_reg_count]).to_byte_array())

	# regs 表（stride 3：q_comp_slot, clk_slot, d_slot）
	var regs := PackedInt32Array()
	for i in _reg_count:
		regs.append(prog.reg_slots[i])
		regs.append(prog.reg_clk_slots[i])
		regs.append(prog.reg_d_slots[i])
	_regs_buf = _make_buf(regs.to_byte_array())

	# reg_state（stride 2：q=0, last_clk=-1 首次只对齐不采样）
	var reg_state := PackedInt32Array()
	reg_state.resize(_reg_count * 2)
	for i in _reg_count:
		reg_state[i * 2 + 0] = 0
		reg_state[i * 2 + 1] = -1
	_reg_state_buf = _make_buf(reg_state.to_byte_array())

	# 值缓冲（2 个 ping-pong）：全 0（低电平）。phase 下读 buf[phase]、写 buf[1-phase]
	var zero := PackedInt32Array()
	zero.resize(prog.slot_count)
	for i in 2:
		_buf[i] = _make_buf(zero.to_byte_array())

	# compute pipelines
	_eval_shader = _load_compute_shader("res://render/sw_signal_compute_eval.glsl")
	if _eval_shader.is_valid():
		_eval_pipeline = _rd.compute_pipeline_create(_eval_shader)
	_latch_shader = _load_compute_shader("res://render/sw_signal_compute_latch.glsl")
	if _latch_shader.is_valid():
		_latch_pipeline = _rd.compute_pipeline_create(_latch_shader)
	if not _eval_shader.is_valid() or not _latch_shader.is_valid():
		_broken = true
		return

	# uniform sets：latch 按 phase（ping-pong）；eval 按 phase × level（每层独立 layer_start）
	for i in 2:
		_latch_sets[i] = _rd.uniform_set_create(_make_uniforms([
			{"binding": 0, "type": RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, "data": _regs_buf},
			{"binding": 1, "type": RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, "data": _reg_state_buf},
			{"binding": 2, "type": RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, "data": _buf[i]},
			{"binding": 3, "type": RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, "data": _buf[1 - i]},
			{"binding": 4, "type": RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, "data": _slot_lv_buf},
			{"binding": 5, "type": RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, "data": _reg_count_buf},
		]), _latch_shader, 0)
	_level_sets = []
	for phase in 2:
		var row := []
		for lv in _prog.level_count:
			row.append(_rd.uniform_set_create(_make_uniforms([
				{"binding": 0, "type": RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, "data": _gates_buf},
				{"binding": 1, "type": RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, "data": _buf[phase]},
				{"binding": 2, "type": RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, "data": _buf[1 - phase]},
				{"binding": 3, "type": RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, "data": _slot_lv_buf},
				{"binding": 4, "type": RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, "data": _layer_start_bufs[lv]},
			]), _eval_shader, 0))
		_level_sets.append(row)
	_phase = 0
	_broken = false


# 集成方/测试在 setup 后灌入当前 net 电平（拍前状态）；否则首次 evaluate 以全 0 为基线，
# 与 CPU 树求值的真实初始电平不一致。写入当前读侧（_buf[_phase]）。
func init_prev(slots: PackedInt32Array) -> void:
	if _broken:
		return
	var data := PackedByteArray()
	data.resize(slots.size() * 4)
	for i in slots.size():
		data.encode_s32(i * 4, slots[i])
	_rd.buffer_update(_buf[_phase], 0, data.size(), data)


# CPU 事件写源输入：values[i] 按 prog.input_slots 顺序（0/1）。写当前读侧（上轮结果所在）
func write_sources(values: PackedInt32Array) -> void:
	if _broken:
		return
	var srcs: PackedInt32Array = _prog.input_slots
	var n: int = mini(values.size(), srcs.size())
	for i in n:
		var data := PackedByteArray()
		data.resize(4)
		data.encode_s32(0, values[i])
		_rd.buffer_update(_buf[_phase], srcs[i] * 4, 4, data)


# 批量写源（每拍一次 buffer_update）：values 按 prog.input_slots 序。
# 逐 slot 的 4 字节 buffer_update 在 D3D12 上每次都是一趟常量缓冲上传，
# 多电路 × 多源的 RD 往返比求值本身还贵；这里先读出整段，本地改完一次写回
func write_sources_batch(values: PackedInt32Array) -> void:
	if _broken:
		return
	var srcs: PackedInt32Array = _prog.input_slots
	var n: int = mini(values.size(), srcs.size())
	if n <= 0:
		return
	var data := _rd.buffer_get_data(_buf[_phase], 0, _prog.slot_count * 4)
	for i in n:
		data.encode_s32(srcs[i] * 4, values[i])
	_rd.buffer_update(_buf[_phase], 0, data.size(), data)


# 集成方在 setup 后把 CPU 寄存器当前状态灌入（q=0/1，last_clk=-1/0/1，按 reg_slots 序）。
# 默认 setup 是全 0 + 首次对齐（-1），存档加载后必须调用本方法对齐 CPU 侧 qState/lastClk。
func init_reg_state(q: PackedInt32Array, last_clk: PackedInt32Array) -> void:
	if _broken:
		return
	var reg_state := PackedInt32Array()
	reg_state.resize(_reg_count * 2)
	for i in _reg_count:
		reg_state[i * 2 + 0] = q[i] if i < q.size() else 0
		reg_state[i * 2 + 1] = last_clk[i] if i < last_clk.size() else -1
	_rd.buffer_update(_reg_state_buf, 0, reg_state.size() * 4, reg_state.to_byte_array())


# 读回寄存器状态（q, last_clk 交替，stride 2）：集成方回填 CPU 寄存器组件状态用
func read_reg_state() -> PackedInt32Array:
	if _broken:
		return PackedInt32Array()
	var data := _rd.buffer_get_data(_reg_state_buf, 0, _reg_count * 2 * 4)
	return data.to_int32_array()


# 组合逐层 + 锁存 + 交换缓冲。sync=true 保留旧单拍语义（测试/单引擎手动三段用）；
# 每拍集成路径走「多引擎 list → 一次 submit → 一次 sync」批处理，见 SWCircuitControl
func evaluate(sync: bool = true) -> void:
	execute()
	if sync:
		submit()
		end_tick()


# 录制本引擎的 compute 列表（多引擎可共用一个 list，层间 barrier 已在内部加好）
func execute() -> void:
	if _broken:
		return
	var cl := _rd.compute_list_begin()
	_record_levels(cl)
	if _reg_count > 0:
		_rd.compute_list_bind_compute_pipeline(cl, _latch_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _latch_sets[_phase], 0)
		_rd.compute_list_dispatch(cl, ceili(float(_reg_count) / 64.0), 1, 1)
		_rd.compute_list_add_barrier(cl)
		# 锁存后 Q 可能真的翻了：latch 把新 Q 同时写回了读侧 a，
		# 这里再跑一遍组合层，下游（LED/连线）当拍就能看到新电平
		# （否则要等到下一拍，表现为「寄存器贴图变了、灯泡却要等下一次信号变化」）。
		# 无寄存器的电路不受影响，恒走单遍。
		_record_levels(cl)
	_rd.compute_list_end()


# 按层录制组合求值 dispatch（层间 barrier 保证跨层依赖）
func _record_levels(cl: int) -> void:
	for lv in _prog.level_count:
		var cnt: int = _prog.level_counts[lv]
		if cnt <= 0:
			continue
		_rd.compute_list_bind_compute_pipeline(cl, _eval_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _level_sets[_phase][lv], 0)
		_rd.compute_list_dispatch(cl, ceili(float(cnt) / 64.0), 1, 1)
		_rd.compute_list_add_barrier(cl)


# 提交已录制的全部列表（不同步；同步由集成方统一做一次 rd.sync()）
func submit() -> void:
	if _broken:
		return
	_rd.submit()


# 同步完成后交换 ping-pong 相位（必须在集成方 rd.sync() 之后调）
func end_tick() -> void:
	if _broken:
		return
	_phase = 1 - _phase


# 同步后读回结果缓冲（本轮结果写侧 = end_tick 前的 1-_phase）与寄存器状态
func take_readback() -> PackedInt32Array:
	if _broken:
		return PackedInt32Array()
	var data := _rd.buffer_get_data(_buf[1 - _phase], 0, _prog.slot_count * 4)
	return data.to_int32_array()


func take_reg_state() -> PackedInt32Array:
	if _broken:
		return PackedInt32Array()
	var data := _rd.buffer_get_data(_reg_state_buf, 0, _reg_count * 2 * 4)
	return data.to_int32_array()


# 读回结果缓冲（交换后 = 本轮结果写侧）：slot → 0/1
func readback() -> PackedInt32Array:
	if _broken:
		return PackedInt32Array()
	var data := _rd.buffer_get_data(_buf[_phase], 0, _prog.slot_count * 4)
	return data.to_int32_array()


# 本引擎的 RD（批处理段统一 submit/sync 用）
func get_rd() -> RenderingDevice:
	return _rd


func is_broken() -> bool:
	return _broken


# 层号编码进每层独立 uniform set 的 layer_start buffer（binding 4），list 内只换 bind；
# 4.7 push constant API 不可用（任何 stages 均校验失败），buffer_update 又禁止于 compute_list 创建期间


func _make_buf(data: PackedByteArray) -> RID:
	# d3d12 拒绝 0 字节 buffer：空数组时 padding 到 4 字节（无寄存器场景，shader 不读）
	if data.size() == 0:
		var pad := PackedByteArray()
		pad.resize(4)
		return _rd.storage_buffer_create(4, pad)
	return _rd.storage_buffer_create(data.size(), data)


# Godot 4.7：uniform_set_create 接受 Array[RDUniform]（RDUniform 对象，非 Dictionary）
func _make_uniforms(descs: Array) -> Array[RDUniform]:
	var out: Array[RDUniform] = []
	for d in descs:
		var u := RDUniform.new()
		u.uniform_type = d["type"]
		u.binding = d["binding"]
		u.add_id(d["data"])
		out.append(u)
	return out


func _load_compute_shader(path: String) -> RID:
	# Godot 4.7：RDShaderFile 无 load_from_file/get_spirv_stage；用 ResourceLoader 加载 .glsl（自动编译），
	# get_spirv() 直接返回现成 RDShaderSPIRV
	var shader_file: RDShaderFile = load(path)
	if shader_file == null:
		push_error("SWSignalEvalGPU: shader 资源加载失败: %s" % path)
		return RID()
	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	if spirv == null:
		push_error("SWSignalEvalGPU: %s 无 SPIRV 产物" % path)
		return RID()
	return _rd.shader_create_from_spirv(spirv)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd != null:
		for i in 2:
			if _eval_sets[i].is_valid():
				_rd.free_rid(_eval_sets[i])
			if _latch_sets[i].is_valid():
				_rd.free_rid(_latch_sets[i])
			if _buf[i].is_valid():
				_rd.free_rid(_buf[i])
		if _reg_state_buf.is_valid():
			_rd.free_rid(_reg_state_buf)
		if _reg_count_buf.is_valid():
			_rd.free_rid(_reg_count_buf)
		if _regs_buf.is_valid():
			_rd.free_rid(_regs_buf)
		for buf in _layer_start_bufs:
			if buf.is_valid():
				_rd.free_rid(buf)
		for phase_row in _level_sets:
			for set_rid in phase_row:
				if set_rid.is_valid():
					_rd.free_rid(set_rid)
		if _slot_lv_buf.is_valid():
			_rd.free_rid(_slot_lv_buf)
		if _gates_buf.is_valid():
			_rd.free_rid(_gates_buf)
		if _latch_pipeline.is_valid():
			_rd.free_rid(_latch_pipeline)
		if _latch_shader.is_valid():
			_rd.free_rid(_latch_shader)
		if _eval_pipeline.is_valid():
			_rd.free_rid(_eval_pipeline)
		if _eval_shader.is_valid():
			_rd.free_rid(_eval_shader)
