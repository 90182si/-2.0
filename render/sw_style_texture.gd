class_name SWStyleTexture extends RefCounted

# 图集 rect 纹理：2×N RGBA32F，texel[styleId, row] = (x, y, w, h)，row0=off 帧、row1=on 帧。
# 与 registry 方案不同：本实现采用「惰性注册 + 纹理扩容」——
# 任何 rect 首次被烘焙时自动登记并返回 id，未登记 region 不会出现品红哨兵，
# 因此不依赖 build_define_registry.tres 的完整性（当前注册表缺与门/时钟/1bit寄存器等条目）。
# region 是 AtlasTexture 的原图像素坐标（可能 >1），故用 RGBA32F 存浮点，不量化。

static var instance: SWStyleTexture = null
# 扩容重建纹理后的刷新回调（主场景注入：遍历 MESH_GROUP 重设 shader uniform）
static var _refresh_cb: Callable = Callable()

# styleId 的键是「帧对 (off, on)」而非仅 off rect：图集里不同建筑物会复用同一个像素
# region（通用底座 512,0 恰好也是灯泡的 off 帧），若只按 off 索引，静态登记会把已登记
# 帧对的 row1 覆盖回 off 帧，shader 取哪一行都是灭帧（LED 读档后不随电路变化的根因）。
# 归一化 Rect2（Vector4i）-> styleId；浮点尾差不得分裂成两个 id。
var _id_static: Dictionary = {}   # Vector4i(off) -> id，仅收 on==off 的静态登记
var _id_frame: Dictionary = {}    # Vector4i(off) -> { Vector4i(on) -> id }，帧对登记
var _rects: Array = []            # Array[Rect2]（off/低帧 rect），下标即 styleId
var _frame_on: Dictionary = {}    # styleId -> Rect2（on/高帧 rect；非帧建筑 == off）
var image: Image = null           # FORMAT_RGBAF 2×N：row0=off 帧，row1=on 帧
var texture: ImageTexture = null


func _norm_key(r: Rect2) -> Vector4i:
	return Vector4i(roundi(r.position.x), roundi(r.position.y), roundi(r.size.x), roundi(r.size.y))


# 登记一个静态 rect（非帧建筑）：on 帧与 off 帧相同
func register_rect(r: Rect2) -> int:
	return register_frame(r, r)


# 登记图集帧对 (off, on)：同一 off 配不同 on 必须是不同 styleId，两者互不覆盖。
# 帧切换 shader 化后，LED/寄存器/非门/按钮的亮灭不再写实例缓冲，只改信号纹理帧槽电平。
# 烘焙热循环里调用是 O(1) 查表（静态路径仅一次哈希），仅首次新帧对触发一次重建。
func register_frame(off: Rect2, on: Rect2) -> int:
	if off.size.x <= 0.0 or off.size.y <= 0.0:
		return -1
	var key := _norm_key(off)
	# 静态 rect（底座/端子/连线主体）：查静态表，命中即复用
	if on.position == off.position and on.size == off.size:
		var static_id: int = _id_static.get(key, -1)
		if static_id >= 0:
			return static_id
		var new_id: int = _append_style(off, off)
		_id_static[key] = new_id
		return new_id
	# 帧对 rect：帧建筑数量极少，多一次嵌套查表可接受
	var on_key := _norm_key(on)
	if not _id_frame.has(key):
		_id_frame[key] = {}
	var sub: Dictionary = _id_frame[key]
	var frame_id: int = sub.get(on_key, -1)
	if frame_id >= 0:
		return frame_id
	frame_id = _append_style(off, on)
	sub[on_key] = frame_id
	return frame_id


# 追加一个新 styleId（off/on 两行写进纹理）；调用方负责把返回的 id 登记到对应的键表
func _append_style(off: Rect2, on: Rect2) -> int:
	var id: int = _rects.size()
	_rects.append(Rect2(off.position, off.size))
	_frame_on[id] = Rect2(on.position, on.size)
	_rebuild_texture()
	return id


# 未登记返回 -1（shader 侧品红哨兵来源；惰性注册下正常路径不会触发）。
# 语义为「该 rect 作为静态样式登记时的 id」，与登记时的 on 帧无关。
func get_style_id(r: Rect2) -> int:
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return -1
	return _id_static.get(_norm_key(r), -1)


func style_count() -> int:
	return _rects.size()


func _rebuild_texture() -> void:
	var n: int = _rects.size()
	image = Image.create(maxi(n, 1), 2, false, Image.FORMAT_RGBAF)
	for i in n:
		var off: Rect2 = _rects[i]
		var on: Rect2 = _frame_on.get(i, off)
		image.set_pixel(i, 0, Color(off.position.x, off.position.y, off.size.x, off.size.y))
		image.set_pixel(i, 1, Color(on.position.x, on.position.y, on.size.x, on.size.y))
	texture = ImageTexture.create_from_image(image)
	if _refresh_cb.is_valid():
		_refresh_cb.call()


# 校验辅助：styleId 回查 texel 与原 rect 逐分量相等（GUT 验收用）；on=true 取高帧
func get_rect_by_id(style_id: int, on: bool = false) -> Rect2:
	if style_id < 0 or style_id >= _rects.size():
		return Rect2()
	if on:
		return _frame_on.get(style_id, _rects[style_id])
	return _rects[style_id]
