extends Node

## 可切换的图集列表：要加皮肤时，把图片路径追加进来即可
const ATLAS_PATHS: Array[String] = [
	"res://图集.png",
	"res://图集2.png",
	"res://图集3.png",
]

## 【运行前改这里】选择用第几张图：0=图集.png，1=图集2.png，2=图集3.png
var atlas_index: int = 0

## 启动时按 atlas_index 载入好的纹理，全项目统一从这里取
var current: Texture2D = null

func _ready() -> void:
	# 也支持在「项目设置」里加 atlas/index 覆盖，不改代码就能切换
	if ProjectSettings.has_setting("atlas/index"):
		atlas_index = int(ProjectSettings.get_setting("atlas/index"))
	reload()

## 根据 atlas_index 把对应纹理载入到 current
func reload() -> void:
	atlas_index = clampi(atlas_index, 0, ATLAS_PATHS.size() - 1)
	var path := ATLAS_PATHS[atlas_index]
	current = load(path)
	if current == null:
		push_error("[SwAtlas] 图集加载失败: " + path)
