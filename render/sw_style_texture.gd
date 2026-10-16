class_name SWStyleTexture extends RefCounted
## L2 服务层 —— 将建筑图集 region 编码为 1×N 像素纹理，供 shader 采样。
## 每个唯一的 Rect2 region 对应一个 styleId（像素列），
## 像素 RGBA 四通道分别存储 region 的 x, y, w, h。

## 全局单例，启动时初始化
static var instance: SWStyleTexture = null

var image: Image          # FORMAT_RGBAF, width=styleCount, height=1
var texture: ImageTexture
var styleCount: int = 0
var _rect_to_id: Dictionary = {}  # "x,y,w,h" → styleId

# ──────────────────────────────────────────────
#  去重登记
# ──────────────────────────────────────────────

## 去重登记 region，返回 styleId。已存在则返回既有 id
func register_rect(r: Rect2) -> int:
	var key := "%d,%d,%d,%d" % [int(r.position.x), int(r.position.y), int(r.size.x), int(r.size.y)]
	if _rect_to_id.has(key):
		return _rect_to_id[key]
	var id := styleCount
	_rect_to_id[key] = id
	styleCount += 1
	return id

## 查询已登记 rect 的 styleId，未登记返回 -1
func get_style_id(r: Rect2) -> int:
	var key := "%d,%d,%d,%d" % [int(r.position.x), int(r.position.y), int(r.size.x), int(r.size.y)]
	return _rect_to_id.get(key, -1)

# ──────────────────────────────────────────────
#  构建纹理
# ──────────────────────────────────────────────

## register 完毕后调用，生成 image 和 texture
func build_texture() -> void:
	if styleCount == 0:
		return
	image = Image.create(styleCount, 1, false, Image.FORMAT_RGBAF)
	for key in _rect_to_id:
		var parts = key.split(",")
		var rect := Rect2(int(parts[0]), int(parts[1]), int(parts[2]), int(parts[3]))
		var id: int = _rect_to_id[key]
		image.set_pixel(id, 0, Color(rect.position.x, rect.position.y, rect.size.x, rect.size.y))
	texture = ImageTexture.create_from_image(image)

# ──────────────────────────────────────────────
#  从 Registry 批量登记
# ──────────────────────────────────────────────

## 辅助：登记单个 AtlasTexture 的 region（null 安全）
func _register_atlas_region(at: AtlasTexture) -> void:
	if at != null:
		register_rect(at.region)

## 从 build_define_registry 批量登记所有建筑的图集 region，然后构建纹理。
## registry: Registry 实例（preload 或 autoload 均可）
func build_from_registry(registry: Resource) -> void:
	for uid: StringName in registry.get_all_uids():
		var define: SWBuildDefine = registry.load_entry(uid) as SWBuildDefine
		if define == null:
			continue
		# 1) atlasBuildBase（共享常量，但统一登记保证完整性）
		_register_atlas_region(define.atlasBuildBase)
		# 2) atlasIcon
		_register_atlas_region(define.atlasIcon)
		# 3) atlasTextureOn
		_register_atlas_region(define.atlasTextureOn)
		# 4) atlasTextureOff
		_register_atlas_region(define.atlasTextureOff)
		# 5) 每个 build_pin 的 wire_pin
		for pin: SWBuildPinDefine in define.build_pin:
			_register_atlas_region(pin.wire_pin)
	build_texture()
