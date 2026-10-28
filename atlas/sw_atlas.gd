extends Node

## 可切换的图集列表：要加皮肤时，把图片路径追加进来即可
const ATLAS_PATHS: Array[String] = [
	"res://atlas/图集.png",
	"res://atlas/图集2.png",
	"res://atlas/图集3.png",
	"res://atlas/图集4.png"
]

## 低分辨率 LOD 图集：键 = atlas_index，值 = 各级 LOD 的图片路径（下标 0 即 LOD1）。
## 布局必须与全分辨率图集完全一致（整图等比缩小，不能重新排版），
## 这样实例里的 rect 只需按尺寸比例缩放，不用重建任何区块。
const ATLAS_LOD_PATHS: Dictionary = {
	3: [
		"res://atlas/图集6LOD1.png",
		"res://atlas/图集7LOD2.png",
	],
}

## 所有用本图集的 MultiMeshInstance2D 都登记进这个组，换图时统一刷材质参数
const MESH_GROUP := "SWAtlasMesh"

## 从该档位起连图集帧（灯泡/开关/寄存器）也不再更新：降到最远档位时整屏完全静止
const LOD_FREEZE_FRAMES_LEVEL := 2

## 【运行前改这里】选择用第几张图：0=图集.png，1=图集2.png，2=图集3.png
var atlas_index: int = 3

## 启动时按 atlas_index 载入好的纹理，全项目统一从这里取
var current: Texture2D = null

## 0 = 全分辨率，1..N = 第 N 级 LOD（数值越大越模糊）
var lod_level: int = 0
## 各级低分辨率图集，按档位顺序排列（[0] 即 LOD1）
var lod_textures: Array[Texture2D] = []
## 实例 rect 是全分辨率像素，换 LOD 后要除以该缩放
var lod_scale: float = 1.0

func _ready() -> void:
	# 也支持在「项目设置」里加 atlas/index 覆盖，不改代码就能切换
	if ProjectSettings.has_setting("atlas/index"):
		atlas_index = int(ProjectSettings.get_setting("atlas/index"))
	reload()

## 根据 atlas_index 把对应纹理载入到 current，并按顺序载入各级 LOD 图集
func reload() -> void:
	atlas_index = clampi(atlas_index, 0, ATLAS_PATHS.size() - 1)
	var path := ATLAS_PATHS[atlas_index]
	current = load(path)
	if current == null:
		push_error("[SwAtlas] 图集加载失败: " + path)
	lod_textures.clear()
	var lod_paths: Array = ATLAS_LOD_PATHS.get(atlas_index, [])
	for lod_path: String in lod_paths:
		var lod_tex: Texture2D = load(lod_path)
		if lod_tex == null:
			push_error("[SwAtlas] LOD 图集加载失败: " + lod_path)
		lod_textures.append(lod_tex)
	lod_level = 0
	lod_scale = 1.0
	_apply_to_meshes()
	# 换图集时若之前在 LOD 档位，颜色是冻结的：回全分辨率后要补齐
	if is_inside_tree():
		get_tree().call_group("DrawManager", "on_atlas_lod_changed", 0)

## 已加载的 LOD 档数（LOD1 到 LOD N）
func get_lod_count() -> int:
	return lod_textures.size()

func _lod_texture_at(level: int) -> Texture2D:
	if level <= 0 or level > lod_textures.size():
		return null
	return lod_textures[level - 1]

func get_texture() -> Texture2D:
	var lod_tex: Texture2D = _lod_texture_at(lod_level)
	return lod_tex if lod_tex != null else current

func get_rect_scale() -> float:
	return lod_scale if is_lod_active() else 1.0

## 是否处于低分辨率档：此时内容层只更新图集帧（灯泡/开关/寄存器），
## 不跟随电路电平换色，省掉高频电路在缩小视角下的颜色回写与上传
func is_lod_active() -> bool:
	return _lod_texture_at(lod_level) != null

## 冻结整屏：从 LOD_FREEZE_FRAMES_LEVEL 起，连图集帧（灯泡/开关/寄存器）
## 也不再随电路更新，新区块/结构性变更仍按当前状态整块构建
func is_frame_updates_frozen() -> bool:
	return is_lod_active() and lod_level >= LOD_FREEZE_FRAMES_LEVEL

## 切换 LOD：只改材质参数，不动实例缓冲，所以建筑不会重绘。
## 档位上限为已加载的 LOD 图集数量，缺图时退到能用的最高一级。
func set_lod(level: int) -> void:
	var want: int = clampi(level, 0, lod_textures.size())
	while want > 0 and _lod_texture_at(want) == null:
		want -= 1
	if want == lod_level:
		return
	lod_level = want
	lod_scale = 1.0
	var lod_tex: Texture2D = _lod_texture_at(lod_level)
	if lod_tex != null and current != null:
		var w0: int = current.get_width()
		var w1: int = lod_tex.get_width()
		if w0 > 0 and w1 > 0:
			lod_scale = float(w0) / float(w1)
	_apply_to_meshes()
	# 通知各绘制层：降级期间冻结颜色补丁，回到全分辨率时把冻结期间的颜色一次性补齐
	if is_inside_tree():
		get_tree().call_group("DrawManager", "on_atlas_lod_changed", lod_level)

func _apply_to_meshes() -> void:
	if not is_inside_tree():
		return
	var tex: Texture2D = get_texture()
	var sc: float = get_rect_scale()
	for node in get_tree().get_nodes_in_group(MESH_GROUP):
		var ci := node as CanvasItem
		if ci == null:
			continue
		var mat := ci.material as ShaderMaterial
		if mat == null:
			continue
		if tex != null and mat.get_shader_parameter("srcImg") != tex:
			mat.set_shader_parameter("srcImg", tex)
		if mat.get_shader_parameter("atlas_scale") != sc:
			mat.set_shader_parameter("atlas_scale", sc)
