class_name SWSignalTexture extends RefCounted

## 全局单例，启动时初始化
static var instance: SWSignalTexture = null

const MAX_NETS := 65536
# 纹理按 TEX_COLS×TEX_ROWS 的 2D 网格排布（网格总容量 == MAX_NETS）。
# 不用 1×65536 长条：很多 GPU 的纹理最大边长只有 16384，会报
# "Texture dimensions exceed device maximum"；4096 宽在所有目标平台上都安全。
const TEX_COLS := 4096
const TEX_ROWS := MAX_NETS / TEX_COLS

var image: Image          # FORMAT_RGBAF, width=TEX_COLS, height=TEX_ROWS, net_id 行优先展开
var texture: ImageTexture
var _dirty: bool = false
var _update_count: int = 0  # 测试用：记录 texture.update 调用次数

## 分配 image/texture，全 texel 置透明
func init() -> void:
	image = Image.create(TEX_COLS, TEX_ROWS, false, Image.FORMAT_RGBAF)
	# 全透明（黑色零 alpha）
	texture = ImageTexture.create_from_image(image)

## net_id → texel 坐标（与 shader 里的换算公式必须保持一致）
func texel_pos(net_id: int) -> Vector2i:
	return Vector2i(net_id % TEX_COLS, net_id / TEX_COLS)

## 设置 net 颜色，只写 image + 标脏，不立即 update
func set_net_color(net_id: int, c: Color) -> void:
	if net_id < 0 or net_id >= MAX_NETS:
		return
	var pos := texel_pos(net_id)
	image.set_pixel(pos.x, pos.y, c)
	_dirty = true

## 仅脏时统一 update texture，由主循环每帧调用
func flush() -> void:
	if not _dirty:
		return
	texture.update(image)
	_dirty = false
	_update_count += 1

## 获取纹理供 shader 采样
func get_texture() -> ImageTexture:
	return texture

## 重置 update 计数（测试用）
func reset_update_count() -> void:
	_update_count = 0

## 获取 update 次数（测试用）
func get_update_count() -> int:
	return _update_count
