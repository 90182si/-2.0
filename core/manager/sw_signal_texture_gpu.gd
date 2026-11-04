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


# 脏时：全量电平数组 → storage buffer → dispatch imageStore → 提交
func flush() -> void:
	if _broken or not _dirty:
		return
	_rd.buffer_update(_levels_buf, 0, _levels.size() * 4, _levels.to_byte_array())
	var cl := _rd.compute_list_begin()
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
