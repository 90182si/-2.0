extends Node

## 临时复现：加载存档卡死排查。跑完自动退出。
## 用法：godot --headless --path . res://tools/repro_load_save.tscn

const GAME_SCENE := "res://scene/sw_logic_scene.tscn"
const SAVES := ["计数器2", "测试", "加法器", "38译码器", "bug1", "empty"]

func _ready() -> void:
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
	for name in SAVES:
		var data: Dictionary = SWSaveManager.load_builds(name)
		if data.is_empty():
			print("[REPRO] 跳过（无存档/解析失败）: ", name)
			continue
		var builds = data.get("builds", [])
		var t0 = Time.get_ticks_msec()
		print("[REPRO] 开始加载: ", name, " builds=", builds.size())
		build_layer.load_save_data(data)
		var t1 = Time.get_ticks_msec()
		SWSaveManager.apply_viewport(camera, data)
		var t2 = Time.get_ticks_msec()
		print("[REPRO] 完成: ", name, " load_save_data=", (t1 - t0), "ms apply_viewport=", (t2 - t1), "ms")
		for _i in range(3):
			await get_tree().process_frame
	print("[REPRO] ALL DONE")
	get_tree().quit(0)
