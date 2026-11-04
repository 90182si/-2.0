class_name SWSignalTexture extends RefCounted

# 信号电平纹理后端基类（T1.8 接口化）。
# - 电平纹理（net 电平 → shader 采样）由 CPU/GPU 后端各自实现 init/set_level/flush/get_texture；
# - 帧槽（LED/寄存器/非门/按钮亮灭）与调色板（线别颜色）与后端无关，留在基类共享；
# - 工厂 create_backend() 按项目设置 sw_render/signal_backend（auto/cpu/gpu）+ RD 可用性选择，
#   调用点只与 SWSignalTexture.instance 交互，不感知后端类型（SPEC-01 §8 全局禁区 2）。

# 电平纹理常量：R8 网格，texel[netId] = 0/1 电平。
# - 必须用 2D 网格排布（TEX_COLS×TEX_ROWS）：1×65536 长条会超 GPU 最大边长 16384（曾踩坑）。
# - texel_pos(net_id) = (net_id % TEX_COLS, net_id / TEX_COLS)，此公式必须与 shader 内换算逐字一致。
const MAX_NETS := 65536
const TEX_COLS := 4096
const TEX_ROWS := MAX_NETS / TEX_COLS

static var instance: SWSignalTexture = null

enum Backend { AUTO, CPU, GPU }

# 工厂：按偏好 + RD 可用性选择后端。GPU 后端脚本经 load 延迟引用（T1.9 落盘后自动生效）。
# auto 语义（SPEC §8）：读项目设置 sw_render/signal_backend（枚举 auto/cpu/gpu）；未配置或 auto 时，
# RenderingDevice 可用 → GPU 后端，否则（Compatibility/WebGL2/headless）→ CPU 后端。
static func create_backend(prefer: int = Backend.AUTO) -> SWSignalTexture:
	_ensure_palette_preregistered()
	var rd_ok: bool = RenderingServer.get_rendering_device() != null
	var want: int = prefer
	if want == Backend.AUTO:
		var cfg: String = str(ProjectSettings.get_setting("sw_render/signal_backend", "auto"))
		if cfg == "gpu":
			want = Backend.GPU
		elif cfg == "cpu":
			want = Backend.CPU
		else:
			want = Backend.GPU if rd_ok else Backend.CPU
	if want == Backend.GPU:
		if not rd_ok:
			push_warning("SWSignalTexture.create_backend: 请求 GPU 后端但 RenderingDevice 不可用，回退 CPU")
			return SWSignalTextureCPU.new()
		var gpu_script: GDScript = load("res://core/manager/sw_signal_texture_gpu.gd")
		if gpu_script == null or not gpu_script.can_instantiate():
			push_warning("SWSignalTexture.create_backend: GPU 后端脚本不可用，回退 CPU")
			return SWSignalTextureCPU.new()
		var gpu: SWSignalTexture = gpu_script.new()
		if gpu == null:
			push_warning("SWSignalTexture.create_backend: GPU 后端实例化失败，回退 CPU")
			return SWSignalTextureCPU.new()
		return gpu
	return SWSignalTextureCPU.new()


# ---------- 后端虚接口 ----------
# CPU/GPU 后端各自实现；基类只给默认空实现（未实现的后端不会进入工厂选择）。

func init() -> void:
	pass

# 写一个 net/帧槽的电平；越界静默忽略（netId 越界保持 -1 时绝不越界写纹理）
func set_level(net_id: int, high: bool) -> void:
	pass

# 脏时才把本帧累积的电平提交到 GPU 侧纹理（每帧最多一次；tick 60Hz 下脏帧才产生上行）
func flush() -> void:
	pass

func is_dirty() -> bool:
	return false


# ---------- 帧状态槽（基类共享） ----------
# LED/寄存器/非门/按钮的显示状态（亮灭帧）也 shader 化：每个带帧建筑占一个专用 texel，
# 从 MAX_NETS-1 向下分配，与 netId（0 向上）天然隔离，互不冲突。
# 帧槽随全量清除/加载整体重置（与 netId 同步），增量删除不回收（耗尽有 warning + 回退 off 帧）。
var _next_frame_slot: int = MAX_NETS - 1

func alloc_frame_slot() -> int:
	if _next_frame_slot < 0:
		push_warning("SWSignalTexture.alloc_frame_slot: 帧槽耗尽，帧切换回退 off 帧")
		return -1
	var slot: int = _next_frame_slot
	_next_frame_slot -= 1
	return slot

# 全量清除/加载时调用（与 resetNetIdCounter 同步）：帧槽整体作废重建
func resetFrameSlots() -> void:
	_next_frame_slot = MAX_NETS - 1


# ---------- 电平纹理（后端各自的产物） ----------
# CPU 后端：image=FORMAT_R8 网格 + texture=ImageTexture（update 上传）；
# GPU 后端：image=null（无 CPU 镜像），texture=Texture2DRD（storage 纹理）。
var image: Image = null
var texture: Texture2D = null
# 探针：每帧 flush 次数（验收：tick 期间 ≤ 帧数）/ 写过的 texel 数（验收：与翻转 net 数一致）
var dbg_flush_count: int = 0
var dbg_set_level_count: int = 0


# ---------- 调色板（静态，与后端无关） ----------
# wireName(String) -> paletteId(int)；首次遇到线别时经 GetWireColor 惰性注册。
# 颜色单一真源 SwCommon.GetWireColor(wireName)；实例 custom_data.z 携带 palette_id。
static var _palette_id_by_wire: Dictionary = {}
static var _palette_colors: Array = []          # Array[Array[Color]]：每线别 [low, high]
static var palette_image: Image = null          # RGBA8 2×P：texel(level, palette_id)
static var palette_texture: ImageTexture = null
# 调色板纹理重建后的刷新回调（主场景注入：遍历 MESH_GROUP 重设 shader uniform）
static var _palette_refresh_cb: Callable = Callable()
static var _palette_preregistered: bool = false


# 预注册三条线别调色板（电线A / 电线B / 默认），保证 shader 采样前已就位（幂等，只做一次）
static func _ensure_palette_preregistered() -> void:
	if _palette_preregistered:
		return
	_palette_preregistered = true
	register_palette("电线A")
	register_palette("电线B")
	register_palette("")


# 按线别注册调色板；已注册返回既有 id（幂等）
static func register_palette(wire_name: String) -> int:
	if _palette_id_by_wire.has(wire_name):
		return _palette_id_by_wire[wire_name]
	var colors: Array[Color] = SwCommon.GetWireColor(wire_name)
	var id: int = _palette_colors.size()
	_palette_id_by_wire[wire_name] = id
	_palette_colors.append(colors)
	_rebuild_palette_texture()
	return id


# 查询线别调色板 id；未注册的线别惰性注册（默认取 LOW 色渲染，不崩）
static func palette_id_for(wire_name: String) -> int:
	if not _palette_id_by_wire.has(wire_name):
		return register_palette(wire_name)
	return _palette_id_by_wire[wire_name]


static func _rebuild_palette_texture() -> void:
	var p: int = _palette_colors.size()
	if p <= 0:
		return
	palette_image = Image.create(2, p, false, Image.FORMAT_RGBA8)
	for i in p:
		var colors: Array[Color] = _palette_colors[i]
		var lo: Color = colors[0]
		var hi: Color = colors[1] if colors.size() > 1 else colors[0]
		palette_image.set_pixel(0, i, Color(lo.r, lo.g, lo.b, 1.0))
		palette_image.set_pixel(1, i, Color(hi.r, hi.g, hi.b, 1.0))
	palette_texture = ImageTexture.create_from_image(palette_image)
	if _palette_refresh_cb.is_valid():
		_palette_refresh_cb.call()
