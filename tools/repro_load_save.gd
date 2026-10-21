extends Node

## TEMP 复现：加载存档耗时排查。
## 用法：godot --headless --path . res://tools/repro_load_save.tscn -- 16x计数器
## 不带参数则跑默认存档列表。

const GAME_SCENE := "res://scene/sw_logic_scene.tscn"
const SAVES_DEFAULT := ["计数器2", "测试", "加法器", "38译码器", "bug1", "empty"]

func _snapshot(layer) -> String:
	var builds = layer.sw_build_manager.getAllBuilds()
	builds.sort_custom(func(x, y): return x.id < y.id)
	var parts := PackedStringArray()
	for b: SWBuildItemDefine in builds:
		parts.append("%d:%d:%d" % [b.id, b.getDisplaySignal(), 1 if b.in_loop else 0])
	return ";".join(parts)

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var saves: Array = args if args.size() > 0 else SAVES_DEFAULT
	var packed: PackedScene = load(GAME_SCENE)
	if packed == null:
		print("[REPRO] 无法加载主场景")
		get_tree().quit(1)
		return
	var scene: Node = packed.instantiate()
	add_child(scene)
	# 等待 _ready + call_deferred(_init_camera_view)
	for _i in range(5):
		await get_tree().process_frame
	var layer_manager = scene.get_node("SWLayerManager")
	var build_layer = layer_manager.buildLayer
	var camera = scene.get_node("SWCamera2D")
	var snapshots := ""
	for name in saves:
		var tj0 = Time.get_ticks_msec()
		var data: Dictionary = SWSaveManager.load_builds(name)
		var tj1 = Time.get_ticks_msec()
		if data.is_empty():
			print("[REPRO] 跳过（无存档/解析失败）: ", name)
			continue
		var builds = data.get("builds", [])
		var t0 = Time.get_ticks_msec()
		print("[REPRO] 开始加载: ", name, " builds=", builds.size(), " 读文件+解析=", tj1 - tj0, "ms")
		build_layer.load_save_data(data)
		var t1 = Time.get_ticks_msec()
		SWSaveManager.apply_viewport(camera, data)
		var t2 = Time.get_ticks_msec()
		print("[REPRO] 完成: ", name, " load_save_data=", (t1 - t0), "ms apply_viewport=", (t2 - t1), "ms")
		for _i in range(3):
			await get_tree().process_frame
		snapshots += "%s|%s\n" % [name, _snapshot(build_layer)]
	var tag := OS.get_environment("SNAP_TAG")
	if tag != "":
		var f := FileAccess.open("user://snap_%s.txt" % tag, FileAccess.WRITE)
		if f != null:
			f.store_string(snapshots)
			f.close()
			print("[REPRO] 快照已写入 user://snap_", tag, ".txt 长度=", snapshots.length())
	print("[REPRO] ALL DONE")
	get_tree().quit(0)
