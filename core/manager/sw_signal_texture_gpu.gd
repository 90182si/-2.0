class_name SWSignalTextureGPU extends SWSignalTexture

# GPU 后端（SPEC-01 §8.1 T1.9）：电平数组 → RD storage buffer → compute shader imageStore → storage 纹理。
# - set_level 只写 CPU 侧 PackedFloat32Array（标脏），帧末 flush() 一次 buffer_update + dispatch；
# - texture 为 Texture2DRD，材质 signalBits uniform 采样（texelFetch .r 读电平，与 CPU R8 后端语义一致）；
# - 信号计算本身仍在 CPU（T1.10 才上 GPU）；本阶段上传量为 256KB/脏帧，是 T1.10 的地基，
#   T1.10 完成后 CPU 不再写数组，只剩按需 readback，上传归零。
# - Compatibility/WebGL2/headless 下 RenderingDevice 为 null，工厂自动回退 CPU（本类不实例化）。

var _rd: RenderingDevice
var _levels: PackedFloat32Array
var _levels_buf: RID
var _rd_tex: RID
var _shader: RID
var _pipeline: RID
var _uniform_set: RID
var _dispatch_x: int
var _dirty := false
var _broken := false

# ========== GPU LED resolve（sw_signal_led.glsl） ==========
# 灯泡亮灭 = OR(输入 slot)，按组一次算完再广播给组内帧槽，整批一次 dispatch。
# 四个 buffer 都在主 RD：table（组表，低频重建）/ dsts（帧槽表，随组表一起重建）/
# slots（全局 slot 空间，每拍局部上传）/ levels（复用）。
# 关键：levels 是「CPU 数组 → buffer_update → imageStore」链路，所以 LED pass 必须与 signal_compute
# 放在同一个 compute list 里、中间加 barrier，否则 compute 可能把旧 levels 刷进纹理。
var _led_ok := false
var _led_record_count := 0
var _led_dispatch_x := 0
var _led_table_buf: RID
var _led_table_bytes := 0    # 表 buffer 当前字节数（尺寸变化时重建，避免超发越界）
var _led_dst_buf: RID
var _led_dst_bytes := 0
var _led_slots_buf: RID
var _led_slots_cap := 0
var _led_shader: RID
var _led_pipeline: RID
var _led_uniform_set: RID
# 组记录步长（[src_count, gs0..gs3, dst_off, dst_count, 0]），必须与 sw_signal_led.glsl 逐字一致
const LED_STRIDE := 8
# slot buffer 初始容量：256KB = 65536 个 int，避免首批求值就扩容
const LED_INIT_SLOTS_BYTES := 262144

func init() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		push_error("SWSignalTextureGPU.init: RenderingDevice 不可用（工厂应在无 RD 时回退 CPU）")
		_broken = true
		return
	_levels = PackedFloat32Array()
	_levels.resize(MAX_NETS)   # 全 0（低电平）
	_levels_buf = _rd.storage_buffer_create(MAX_NETS * 4)

	# RD storage 纹理：R32G32B32A32_SFLOAT，采样 + storage（compute 写）+ can_update
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.width = TEX_COLS
	fmt.height = TEX_ROWS
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var view := RDTextureView.new()
	_rd_tex = _rd.texture_create(fmt, view, [])
	var tex_rd := Texture2DRD.new()
	tex_rd.texture_rd_rid = _rd_tex
	texture = tex_rd

	# compute pipeline（ResourceLoader 加载 .glsl 自动编译；4.7 无 load_from_file/get_spirv_stage）
	var shader_file: RDShaderFile = load("res://render/sw_signal_compute.glsl")
	if shader_file == null:
		push_error("SWSignalTextureGPU.init: compute shader 资源加载失败")
		_broken = true
		return
	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	if spirv == null:
		push_error("SWSignalTextureGPU.init: compute shader 无 SPIRV 产物")
		_broken = true
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)
	_uniform_set = _rd.uniform_set_create(_make_uniforms([
		{
			"binding": 0,
			"type": RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,
			"data": _levels_buf,
		},
		{
			"binding": 1,
			"type": RenderingDevice.UNIFORM_TYPE_IMAGE,
			"data": _rd_tex,
		},
	], _shader), _shader, 0)
	_dispatch_x = ceili(float(MAX_NETS) / 64.0)
	_dirty = false
	_broken = false
	dbg_flush_count = 0
	dbg_set_level_count = 0
	_next_frame_slot = MAX_NETS - 1
	_init_led_pass()


# 构建 LED resolve 管线（失败时只禁用该能力，net 纹理照常工作，调用方回退 CPU 遍历）
func _init_led_pass() -> void:
	_led_ok = false
	var shader_file: RDShaderFile = load("res://render/sw_signal_led.glsl")
	if shader_file == null:
		push_warning("SWSignalTextureGPU: sw_signal_led.glsl 加载失败，LED 回退 CPU 遍历")
		return
	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	if spirv == null:
		push_warning("SWSignalTextureGPU: sw_signal_led.glsl 无 SPIRV 产物，LED 回退 CPU 遍历")
		return
	_led_shader = _rd.shader_create_from_spirv(spirv)
	_led_pipeline = _rd.compute_pipeline_create(_led_shader)
	# 表 / 帧槽表 buffer 由 led_set_table 按实际尺寸重建，这里先放一个占位
	_led_table_buf = _rd.storage_buffer_create(4)
	_led_table_bytes = 0
	_led_dst_buf = _rd.storage_buffer_create(4)
	_led_dst_bytes = 4
	# slot buffer 一次给足：扩容会重建 buffer 并丢掉已上传的其他电路 slot，
	# 表现为该帧已求值电路的灯泡集体暗一下。256KB（65536 个 int）覆盖绝大多数存档。
	_led_slots_buf = _rd.storage_buffer_create(LED_INIT_SLOTS_BYTES)
	_led_slots_cap = LED_INIT_SLOTS_BYTES
	_rebuild_led_uniform_set()
	_led_ok = true


func _rebuild_led_uniform_set() -> void:
	if _led_uniform_set.is_valid():
		_rd.free_rid(_led_uniform_set)
		_led_uniform_set = RID()
	_led_uniform_set = _rd.uniform_set_create(_make_uniforms([
		{
			"binding": 0,
			"type": RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,
			"data": _led_table_buf,
		},
		{
			"binding": 1,
			"type": RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,
			"data": _led_slots_buf,
		},
		{
			"binding": 2,
			"type": RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,
			"data": _levels_buf,
		},
		{
			"binding": 3,
			"type": RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,
			"data": _led_dst_buf,
		},
	], _led_shader), _led_shader, 0)


# slot buffer 按需扩容（2 倍增长）。扩容后旧内容丢失：未求值电路的 LED 会暗一拍，
# 但扩容只在读档/新电路首次编译时发生，可接受。
# 注意 RD 依赖顺序：uniform set 引用着旧 buffer，必须先拆 uniform set 再 free buffer，
# 否则引擎会报「释放被依赖资源」，且新 uniform set 仍绑着已失效的 RID。
func _ensure_led_slots(want_bytes: int) -> void:
	if want_bytes <= _led_slots_cap:
		return
	var grown: int = _led_slots_cap
	while grown < want_bytes:
		grown *= 2
	_drop_led_uniform_set()
	if _led_slots_buf.is_valid():
		_rd.free_rid(_led_slots_buf)
	_led_slots_buf = _rd.storage_buffer_create(grown)
	_led_slots_cap = grown
	_rebuild_led_uniform_set()


func _drop_led_uniform_set() -> void:
	if _led_uniform_set.is_valid():
		_rd.free_rid(_led_uniform_set)
		_led_uniform_set = RID()


# 只要管线就绪就算支持：表可能暂时为空（帧槽还没烘出来），调用方仍需走 GPU 分支
# （表重建就发生在调用方这一侧，若这里返回 false 就永远建不出表）。
func has_led_pass() -> bool:
	return _led_ok


func led_pending() -> bool:
	return _led_ok and _led_record_count > 0


# 上传全局 LED 组表（stride 8）：[src_count, gs0..gs3, dst_off, dst_count, 0]
# 与帧槽表 dsts 一起上传，两件必须做的事：
# 1) 表尾用「全 0 记录」补齐到 64 的整数倍：dispatch 按整组发，shader 靠 dst_count = 0
#    避开「超发越界」与「尾部读成全 0 当合法记录」（两者都不需要 length()）。
# 2) slot buffer 至少覆盖表里出现过的最大下标：表格可能包含尚未求值过的电路区间。
func led_set_table(records: PackedInt32Array, dst_slots: PackedInt32Array) -> void:
	if not _led_ok:
		return
	_led_record_count = records.size() / LED_STRIDE
	# 只扫源 slot 字段（1..4）：首字段是源数，后两字段是帧槽表下标/帧槽数，都不能当 slot 用
	var max_gs := -1
	for r in _led_record_count:
		var cnt: int = mini(records[r * LED_STRIDE], 4)
		for k in cnt:
			var gs: int = records[r * LED_STRIDE + 1 + k]
			if gs > max_gs:
				max_gs = gs
	if max_gs >= 0:
		_ensure_led_slots((max_gs + 1) * 4)
	# 帧槽表：shader 按 dst_off/dst_count 读取，无需补齐；空表时留 1 个 int 避免 0 字节 buffer
	_upload_led_dsts(dst_slots if not dst_slots.is_empty() else PackedInt32Array([0]))
	var pad_to: int = ((_led_record_count + 63) / 64) * 64
	var padded: PackedInt32Array = records.duplicate()
	if pad_to > _led_record_count:
		# 填位记录全 0：src_count = 0、dst_count = 0 → shader 直接跳过
		padded.resize(pad_to * LED_STRIDE)
	_led_dispatch_x = pad_to / 64
	var bytes: int = padded.size() * 4
	if bytes <= 0:
		return
	if bytes == _led_table_bytes and _led_table_buf.is_valid():
		_rd.buffer_update(_led_table_buf, 0, bytes, padded.to_byte_array())
		return
	# 尺寸变了：先拆 uniform set，再换 buffer，最后重建 uniform set（RD 依赖顺序）
	_drop_led_uniform_set()
	if _led_table_buf.is_valid():
		_rd.free_rid(_led_table_buf)
	_led_table_buf = _rd.storage_buffer_create(bytes)
	_led_table_bytes = bytes
	_rd.buffer_update(_led_table_buf, 0, bytes, padded.to_byte_array())
	_rebuild_led_uniform_set()


# 上传帧槽表（组内目标的帧槽下标），尺寸变化时按 RD 依赖顺序重建 buffer
func _upload_led_dsts(dsts: PackedInt32Array) -> void:
	var bytes: int = dsts.size() * 4
	if bytes == _led_dst_bytes and _led_dst_buf.is_valid():
		_rd.buffer_update(_led_dst_buf, 0, bytes, dsts.to_byte_array())
		return
	_drop_led_uniform_set()
	if _led_dst_buf.is_valid():
		_rd.free_rid(_led_dst_buf)
	_led_dst_buf = _rd.storage_buffer_create(bytes)
	_led_dst_bytes = bytes
	_rd.buffer_update(_led_dst_buf, 0, bytes, dsts.to_byte_array())
	_rebuild_led_uniform_set()


# 上传一条电路的 slot 值（写到全局 slot buffer 的 base 起，局部 slot 下标不变）
func led_upload_slots(base: int, slots: PackedInt32Array, limit: int = -1) -> void:
	if not _led_ok or base < 0 or slots.is_empty():
		return
	var n: int = slots.size()
	if limit > 0 and n > limit:
		n = limit
	if n <= 0:
		return
	var bytes: int = n * 4
	_ensure_led_slots(base * 4 + bytes)
	var data: PackedByteArray = slots.to_byte_array()
	if n < slots.size():
		data = data.slice(0, bytes)
	_rd.buffer_update(_led_slots_buf, base * 4, bytes, data)


# 写一个 net/帧槽的电平；越界或后端损坏时静默忽略
func set_level(net_id: int, high: bool) -> void:
	if _broken or net_id < 0 or net_id >= MAX_NETS:
		return
	if _levels.is_empty():
		return
	var want: float = 1.0 if high else 0.0
	if is_equal_approx(_levels[net_id], want):
		return
	_levels[net_id] = want
	_dirty = true
	dbg_set_level_count += 1


# 脏时：全量电平数组 → storage buffer → （LED pass）→ dispatch imageStore → 提交
func flush() -> void:
	if _broken:
		return
	# 有灯泡时常规必须每帧跑（GPU 端不做「变化才刷」，直接全量重算一遍）。
	var led_run: bool = _led_ok and _led_record_count > 0
	if not _dirty and not led_run:
		return
	if _dirty:
		_rd.buffer_update(_levels_buf, 0, _levels.size() * 4, _levels.to_byte_array())
	var cl := _rd.compute_list_begin()
	if led_run:
		_rd.compute_list_bind_compute_pipeline(cl, _led_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _led_uniform_set, 0)
		_rd.compute_list_dispatch(cl, _led_dispatch_x, 1, 1)
		_rd.compute_list_add_barrier(cl)
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, _uniform_set, 0)
	_rd.compute_list_dispatch(cl, _dispatch_x, 1, 1)
	_rd.compute_list_add_barrier(cl)
	_rd.compute_list_end()
	# 4.7：主 RenderingDevice 禁止显式 submit/sync（"Only local devices can submit and sync"），
	# compute 命令由 RenderingServer 在帧末统一提交；storage 纹理须在主 RD 上才能被材质采样，
	# 故不能改用 local RD（local RD 资源对主渲染不可见）。
	_dirty = false
	dbg_flush_count += 1


func is_dirty() -> bool:
	return _dirty


# Godot 4.7：uniform_set_create 接受 Array[RDUniform]（RDUniform 对象，非 Dictionary）
func _make_uniforms(descs: Array, shader: RID) -> Array[RDUniform]:
	var out: Array[RDUniform] = []
	for d in descs:
		var u := RDUniform.new()
		u.uniform_type = d["type"]
		u.binding = d["binding"]
		u.add_id(d["data"])
		out.append(u)
	return out


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd != null:
		if _led_uniform_set.is_valid():
			_rd.free_rid(_led_uniform_set)
		if _led_pipeline.is_valid():
			_rd.free_rid(_led_pipeline)
		if _led_shader.is_valid():
			_rd.free_rid(_led_shader)
		if _led_table_buf.is_valid():
			_rd.free_rid(_led_table_buf)
		if _led_dst_buf.is_valid():
			_rd.free_rid(_led_dst_buf)
		if _led_slots_buf.is_valid():
			_rd.free_rid(_led_slots_buf)
		if _uniform_set.is_valid():
			_rd.free_rid(_uniform_set)
		if _pipeline.is_valid():
			_rd.free_rid(_pipeline)
		if _shader.is_valid():
			_rd.free_rid(_shader)
		if _rd_tex.is_valid():
			_rd.free_rid(_rd_tex)
		if _levels_buf.is_valid():
			_rd.free_rid(_levels_buf)
