# 电路 LED 状态测试台
# 职责：把游戏主场景跑起来、加载指定存档、以「点击建筑」的方式驱动电路，
#       并提供读取某个位置灯泡亮灭状态的接口，供 GUT 测试断言。
#
# 说明：这里不调用 UI 对话框，而是直接复用游戏运行时的真实入口
#   - 加载存档：SWBuildLayer.load_save_data(data) + SWSaveManager.apply_viewport(camera, data)
#   - 点击建筑：复刻 SWBuildLayer._unhandled_input 中左键点击按钮/开关的处理，
#     即 build.onPressed(...) 后调用 sw_circuit_control.buildSignalChanged(build) 触发级联求值。
class_name CircuitTestHarness extends Node

const GAME_SCENE := "res://scene/sw_logic_scene.tscn"

var scene: Node = null            # SWLogicScene 实例
var layer_manager: SWLayerManager = null
var build_layer: SWBuildLayer = null
var camera: SWCamera2D = null

# 启动游戏主场景并等待其 _ready/延迟初始化完成。
# 需要 await，因为要等待若干帧让相机视野与区块加载稳定。
func boot_game() -> void:
	if scene != null:
		return
	var packed: PackedScene = load(GAME_SCENE)
	assert(packed != null, "无法加载游戏主场景: " + GAME_SCENE)
	scene = packed.instantiate()
	add_child(scene)
	# 等待 _ready + call_deferred("_init_camera_view") 生效
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	layer_manager = scene.get_node("SWLayerManager") as SWLayerManager
	build_layer = layer_manager.buildLayer
	camera = scene.get_node("SWCamera2D") as SWCamera2D

# 关闭并释放游戏场景（测试结束时调用）。
func shutdown_game() -> void:
	if scene != null:
		scene.queue_free()
		scene = null
		layer_manager = null
		build_layer = null
		camera = null

# 从存档名加载并应用到当前游戏世界（含视口恢复）。
# 返回存档数据字典；若为空表示存档不存在或解析失败。
func load_save(save_name: String) -> Dictionary:
	assert(scene != null, "请先调用 boot_game()")
	var data: Dictionary = SWSaveManager.load_builds(save_name)
	if data.is_empty():
		return data
	build_layer.load_save_data(data)
	SWSaveManager.apply_viewport(camera, data)
	await get_tree().process_frame
	return data

# 按网格位置（buildAxisPos，通常是 128 的整数倍）取建筑物。
func get_build(grid_pos: Vector2i) -> SWBuildItemDefine:
	assert(scene != null, "请先调用 boot_game()")
	return build_layer.sw_build_manager.getBuild(grid_pos)

# 把存档里所有有建筑的区块在主线程构建出来，返回已加载区块数。
# headless 下相机视口是空矩形，正常帧循环一个区块都不会加载，
# 渲染相关的断言必须先把区块真正建出来。
func force_load_all_chunks() -> int:
	assert(scene != null, "请先调用 boot_game()")
	var dm = build_layer.sw_draw_manager
	var sys = build_layer.layer_system
	dm._curViewRect = Rect2(-1e9, -1e9, 2e9, 2e9)
	#关掉分帧上限：一次把所有区块建完
	dm.async_loading = false
	var all: Array[Vector2i] = []
	all.assign(sys.build_manager.chunkMap.keys())
	dm.updataChunks(all)
	var guard := 0
	while dm._pending_tasks.has(0) and not dm._pending_tasks[0].is_empty() and guard < 400:
		guard += 1
		dm.process_load_chunk(0)
		for ins in dm.shouldAddToTree:
			#带窗口跑时 _process 也在推进，可能已经把它挂上去了
			if ins.get_parent() == null:
				dm.add_child(ins)
		dm.shouldAddToTree.clear()
	return dm.get_loaded_chunk_positions().size()

# 把挂起的区块刷新队列一次性处理完（测试里不跑帧循环，预算分帧不会自己推进）。
func flush_draw_queue() -> void:
	assert(scene != null, "请先调用 boot_game()")
	build_layer.sw_draw_manager._flush_patches(100000000)

# 点击某位置的建筑物（按钮：一次按下+松开脉冲；开关：切换开/关）。
# 点击后会触发电路级联求值。返回是否成功点击到按钮/开关。
func click_build(grid_pos: Vector2i) -> bool:
	var build := get_build(grid_pos)
	if build == null:
		push_error("点击失败：位置 %s 没有建筑物" % str(grid_pos))
		return false
	var comp_type = build.buildDefine.circuit_component_type
	var btn := build as SWBuildButton
	if btn == null:
		push_error("点击失败：位置 %s 不是可点击的按钮/开关" % str(grid_pos))
		return false
	if comp_type == SwDefine.CircuitComponentType.SWITCH:
		# 开关：切换并保持
		btn.onPressed(not btn.pressed)
		_notify_signal_changed(btn)
	elif comp_type == SwDefine.CircuitComponentType.BUTTON:
		# 按钮：按下再松开，产生一次脉冲（最终回到未按下状态）
		btn.onPressed(true)
		_notify_signal_changed(btn)
		btn.onPressed(false)
		_notify_signal_changed(btn)
	else:
		push_error("点击失败：位置 %s 类型不可点击" % str(grid_pos))
		return false
	return true

# 直接把某位置的开关设置为指定状态（true=开）。用于构造稳定的期望场景。
func set_switch(grid_pos: Vector2i, on: bool) -> bool:
	var build := get_build(grid_pos)
	var btn := build as SWBuildButton
	if btn == null:
		push_error("设置失败：位置 %s 不是开关/按钮" % str(grid_pos))
		return false
	btn.onPressed(on)
	_notify_signal_changed(btn)
	return true

# 读取某位置建筑物当前的信号状态（CircuitSignal）。
# 对灯泡(SWBuildLed)而言，signal_state 即其亮灭：HIGH=亮，LOW=灭。
func get_signal_state(grid_pos: Vector2i) -> SwDefine.CircuitSignal:
	var build := get_build(grid_pos)
	if build == null:
		return SwDefine.CircuitSignal.NONE
	return build.signal_state as SwDefine.CircuitSignal

func _notify_signal_changed(build: SWBuildItemDefine) -> void:
	var affected = build_layer.sw_circuit_control.buildSignalChanged(build)
	affected.append(build)
	# 刷新受影响区块（与游戏运行时一致；纯逻辑断言其实不依赖此步）
	build_layer.layer_system.refresh_signal_chunks(affected)
