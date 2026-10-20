extends Node

## 临时复现：加载"计数器2"后检查 in_loop 标记分布（1bit寄存器是否被误判环路）。
## 用法：godot --headless --path . res://tools/repro_loop_check.tscn

const GAME_SCENE := "res://scene/sw_logic_scene.tscn"
const SAVE_NAME := "计数器2"

func _ready() -> void:
	var packed: PackedScene = load(GAME_SCENE)
	if packed == null:
		print("[LOOPCHK] 无法加载主场景")
		get_tree().quit(1)
		return
	var scene: Node = packed.instantiate()
	add_child(scene)
	for _i in range(5):
		await get_tree().process_frame
	var layer_manager = scene.get_node("SWLayerManager")
	var build_layer = layer_manager.buildLayer
	var data: Dictionary = SWSaveManager.load_builds(SAVE_NAME)
	if data.is_empty():
		print("[LOOPCHK] 无存档")
		get_tree().quit(1)
		return
	var builds = data.get("builds", [])
	print("[LOOPCHK] 开始加载: ", SAVE_NAME, " builds=", builds.size())
	build_layer.load_save_data(data)
	await get_tree().process_frame
	var all: Array[SWBuildItemDefine] = build_layer.sw_build_manager.getAllBuilds()
	var loop_by_def: Dictionary = {}
	var regs: Array = []
	var loop_total := 0
	for b in all:
		if b.buildDefine == null:
			continue
		var dname: String = b.buildDefine.buildName
		if dname == "1bit寄存器":
			regs.append(b)
		if b.in_loop:
			loop_total += 1
			loop_by_def[dname] = loop_by_def.get(dname, 0) + 1
	print("[LOOPCHK] in_loop 总数=", loop_total, " 按类型=", loop_by_def)
	for r in regs:
		var comp = r.getCircuitCompoent()
		print("[LOOPCHK] 寄存器 pos=", r.buildAxisPos, " rot=", r.rotation,
			" in_loop=", r.in_loop,
			" exprDirs=", comp.pinExprMap.keys(),
			" netDirs=", comp.pinNetMap.keys())
	print("[LOOPCHK] DONE")
	get_tree().quit(0)
