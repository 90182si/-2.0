class_name SWSignalTextureCPU extends SWSignalTexture

# CPU 后端（T1.8 迁入原实现）：FORMAT_R8 网格电平纹理 + ImageTexture.update 整图上传。
# - 格式按位压缩（1 字节/net），整图 64KB；比 RGBA32F 每 net 16B 小 16 倍。
# - set_level 只写 image 并标脏，flush() 每帧最多一次 update（脏帧 64KB 上行）。
# - 帧槽与调色板由基类共享（本类只负责电平 texel 的 CPU 镜像）。

var _dirty := false

func init() -> void:
	image = Image.create(TEX_COLS, TEX_ROWS, false, Image.FORMAT_R8)
	image.fill(Color(0, 0, 0, 1))
	texture = ImageTexture.create_from_image(image)
	_dirty = false
	dbg_flush_count = 0
	dbg_set_level_count = 0
	_next_frame_slot = MAX_NETS - 1


# 写一个 net 的电平；越界静默忽略（netId 越界保持 -1 时绝不越界写纹理）
func set_level(net_id: int, high: bool) -> void:
	if net_id < 0 or net_id >= MAX_NETS:
		return
	var col: int = net_id % TEX_COLS
	var row: int = net_id / TEX_COLS
	var want: float = 1.0 if high else 0.0
	if is_equal_approx(image.get_pixel(col, row).r, want):
		return
	image.set_pixel(col, row, Color(want, 0, 0, 1))
	_dirty = true
	dbg_set_level_count += 1


# 脏时才整图上传（每帧最多一次）；tick 60Hz 下脏帧才产生 64KB 上行
func flush() -> void:
	if _dirty and texture != null:
		texture.update(image)
		_dirty = false
		dbg_flush_count += 1


func is_dirty() -> bool:
	return _dirty
