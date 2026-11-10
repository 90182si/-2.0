extends GutTest
# 机器人场景启动冒烟（SPEC-08 阶段 3 场景级验收）
#
# 只验「装配链」：场景能起、实体层系统能被取到、渲染代理真的挂上实体层的 DrawManager、
# HUD 的机器人工具能进手持、手持落子会转成实体、节拍器绑到了同一个实体系统。
# 单拍的电路语义、换格重入表这些纯逻辑断言在 test_robot_runtime.gd 里做。
#
# 跑法：godot --headless --path . -s addons/gut/gut_cmdln.gd
#       -gdir=res://test/circuit -gprefix=test_robot_scene -gexit

const SCENE_PATH: String = "res://scene/sw_robot_scene.tscn"
const GRID: Vector2i = SwDefine.GRID_SIZE
const CIR_MANAGER := preload("res://circuit/sw_cir_manager.gd")
const SESSION := preload("res://core/manager/sw_session.gd")
#切出机器人场景时落盘的状态文件（与 SWEntityLayerSystem.STATE_PATH 一致）
const STATE_PATH: String = "user://saves/_robot_scene.json"

const IN_DEF: SWBuildDefine = preload("res://res/输入接口.tres")
const OUT_DEF: SWBuildDefine = preload("res://res/输出接口.tres")
const WIRE_DEF: SWBuildDefine = preload("res://res/电线A.tres")
const NOT_DEF: SWBuildDefine = preload("res://res/非门.tres")

#绑定面板用例专用的电路文件：clk->move + !clk->rotation / 只有 clk->move / 两条电路各一条
const FILE_OK := "_robot_scene_ok"
const FILE_PARTIAL := "_robot_scene_partial"
const FILE_TWO_CIRCUITS := "_robot_scene_two"

var scene: Node = null
var lm: SWLayerManager = null
var sys = null
var entity_layer: Node = null


func before_each() -> void:
	#上一个用例的场景被释放时会把机器人状态落盘，这里先清掉：
	#否则本用例 _ready 里的恢复会把上一轮的机器人带进来，数量断言全错
	_clear_state_file()
	SESSION.reset()
	var packed: PackedScene = load(SCENE_PATH)
	assert_not_null(packed, "机器人场景加载失败: " + SCENE_PATH)
	if packed == null:
		return
	scene = packed.instantiate()
	add_child_autofree(scene)
	#等 _ready + call_deferred("_init_camera_view") 走完
	await wait_frames(3)
	lm = scene.get_node("SWLayerManager") as SWLayerManager
	entity_layer = lm.get_node("SWEntityLayer")
	sys = lm.get_layer_system("SWEntityLayer")


func after_each() -> void:
	if sys != null and sys.has_method("clear_entities"):
		sys.clear_entities()
	CIR_MANAGER.delete_file(FILE_OK)
	CIR_MANAGER.delete_file(FILE_PARTIAL)
	CIR_MANAGER.delete_file(FILE_TWO_CIRCUITS)
	SESSION.reset()
	_clear_state_file()
	sys = null
	entity_layer = null
	lm = null
	scene = null

func _clear_state_file() -> void:
	if FileAccess.file_exists(STATE_PATH):
		DirAccess.remove_absolute(STATE_PATH)


# 造一条 .swcir：specs = [[格子, 定义, 可选 io_name], ...]；返回是否导出成功
func _export_circuit(name: String, specs: Array) -> bool:
	var mgr := SWBuildManager.new()
	var ctrl := SWCircuitControl.new()
	ctrl.setBuildManager(mgr)
	ctrl.gpu_backend_enabled = false
	var all: Array[SWBuildItemDefine] = []
	for s: Array in specs:
		var b := SwDefine.SWBuildCreator((s[0] as Vector2i) * GRID, s[1], 0)
		#输出接口合并后名字靠实例属性区分（第三个元素写名字）
		if s.size() > 2:
			b.set("io_name", str(s[2]))
		if not mgr.addBuild(b):
			ctrl.free()
			return false
		all.append(b)
	ctrl.updateBuildCircuit(all)
	var ok: bool = CIR_MANAGER.export_all(name, mgr.getAllBuilds()) != ""
	#SWCircuitControl 是 Node，不释放会在 GUT 报告里留 Orphan
	ctrl.free()
	return ok

# clk -> move、!clk -> rotation：两条输出都接着，面板上可点
func _make_usable_circuit() -> bool:
	return _export_circuit(FILE_OK, [
		[Vector2i(0, 7), IN_DEF],
		[Vector2i(0, 6), WIRE_DEF],
		[Vector2i(1, 6), WIRE_DEF],
		[Vector2i(1, 5), OUT_DEF],
		[Vector2i(0, 5), NOT_DEF],
		[Vector2i(0, 4), OUT_DEF, "rotation"],
	])

# 只有 clk -> move，没接 rotation：可用性不再看接口，所以同样可点
func _make_partial_circuit() -> bool:
	return _export_circuit(FILE_PARTIAL, [
		[Vector2i(0, 7), IN_DEF],
		[Vector2i(0, 6), WIRE_DEF],
		[Vector2i(1, 6), WIRE_DEF],
		[Vector2i(1, 5), OUT_DEF],
	])


# 一个文件里两条互不相连的电路：clk->move 与 clk->rotation。
# 同一位 clk 同时驱动两条，用来验证一拍里所有含接口的电路都要跑
func _export_two_circuit_file() -> bool:
	var mgr := SWBuildManager.new()
	var ctrl := SWCircuitControl.new()
	ctrl.setBuildManager(mgr)
	ctrl.gpu_backend_enabled = false
	var groups: Array = [
		[
			[Vector2i(0, 7), IN_DEF],
			[Vector2i(0, 6), WIRE_DEF],
			[Vector2i(1, 6), WIRE_DEF],
			[Vector2i(1, 5), OUT_DEF],
		],
		[
			[Vector2i(20, 7), IN_DEF],
			[Vector2i(20, 6), WIRE_DEF],
			[Vector2i(21, 6), WIRE_DEF],
			[Vector2i(21, 5), OUT_DEF, "rotation"],
		],
	]
	for g: Array in groups:
		var part: Array[SWBuildItemDefine] = []
		for s: Array in g:
			var b := SwDefine.SWBuildCreator((s[0] as Vector2i) * GRID, s[1], 0)
			if s.size() > 2:
				b.set("io_name", str(s[2]))
			if not mgr.addBuild(b):
				ctrl.free()
				return false
			part.append(b)
		ctrl.updateBuildCircuit(part)
	var ok: bool = CIR_MANAGER.export_all(FILE_TWO_CIRCUITS, mgr.getAllBuilds()) != ""
	ctrl.free()
	return ok


# ===== 装配 =====

func test_scene_boots_with_entity_layer() -> void:
	assert_not_null(lm, "场景里没有 SWLayerManager")
	assert_not_null(entity_layer, "场景里没有 SWEntityLayer")
	assert_not_null(sys, "SWLayerManager 取不到实体层系统（get_layer_system 没生效）")
	assert_eq(str(sys.system_name), "core.layer.entity", "取到的不是实体层系统")
	#实体层必须自己持有一份 DrawManager，且已经接上实体系统的分区块表
	var dm: SWDrawManager = entity_layer.get("sw_draw_manager") as SWDrawManager
	assert_not_null(dm, "实体层没有 DrawManager")
	assert_same(dm.sw_build_manager, sys.entity_manager,
			"实体层的 DrawManager 没挂上实体系统的分区块表（机器人画不出来）")


func test_beat_tick_wired_to_entity_system() -> void:
	var tick: Node = scene.get_node_or_null("SWRobotTick")
	assert_not_null(tick, "场景里没有 SWRobotTick")
	assert_same(tick.get("entity_system"), sys, "节拍器没绑到实体层系统")
	assert_eq(float(tick.get("period_sec")), 0.25, "默认节拍应当是 250ms")
	tick.call("tick_once")
	assert_eq(int(tick.get("beat_count")), 1, "手动发一拍没记到 beat_count")


# ===== HUD =====

func test_hud_has_robot_tool_and_scene_switch() -> void:
	assert_not_null(lm.hudLayer, "场景里没有 HUD 层")
	#新类名不在 headless 的全局类缓存里，这里按能力判断而不是按类名
	assert_true(lm.hudLayer.has_method("get_robot_tool_button"),
			"HUD 不是机器人场景的 HUD（缺工具栏）")
	var btn: TextureButton = lm.hudLayer.call("get_robot_tool_button")
	assert_not_null(btn, "HUD 没有机器人工具按钮")
	assert_true(btn.is_in_group("SelTool"), "机器人按钮没进 SelTool 组，父类的选中链接不上")
	assert_eq(btn.name, "机器人", "按钮名必须等于 res/机器人.tres 的文件名")
	assert_not_null(lm.hudLayer.call("get_logic_scene_button"), "HUD 没有「电路场景」切换按钮")
	#机器人场景不该再冒出一个「机器人场景」按钮
	assert_null(lm.hudLayer.get_node_or_null("机器人场景"),
			"机器人场景的 HUD 上不该有「机器人场景」按钮")


func test_robot_tool_goes_into_hold() -> void:
	var btn: TextureButton = lm.hudLayer.call("get_robot_tool_button")
	assert_not_null(btn)
	assert_not_null(lm.holdSystem, "场景里没有手持层系统")
	btn.pressed.emit()
	assert_false(lm.holdSystem.is_hold_empty(), "点了机器人工具，手持还是空的")
	var held: Array = lm.holdSystem.get("_hold_builds")
	assert_gt(held.size(), 0, "手持建筑表是空的")
	assert_eq(str(held[0].buildDefine.buildName), "机器人",
			"手持里拿到的不是机器人定义（res/机器人.tres 名字对不上）")


# 箱子工具：同一条选中链，落子后实体层里就是箱子（不再一律当机器人）
func test_box_tool_spawns_box() -> void:
	var btn: TextureButton = lm.hudLayer.call("get_box_tool_button")
	assert_not_null(btn, "HUD 没有箱子工具按钮")
	if btn == null:
		return
	assert_true(btn.is_in_group("SelTool"), "箱子按钮没进 SelTool 组")
	assert_eq(btn.name, "箱子", "按钮名必须等于 res/箱子.tres 的文件名")

	btn.pressed.emit()
	var held: Array = lm.holdSystem.get("_hold_builds")
	assert_gt(held.size(), 0, "点了箱子工具，手持还是空的")
	if held.is_empty():
		return
	assert_eq(str(held[0].buildDefine.buildName), "箱子", "手持里拿到的不是箱子定义")

	var world_pos: Vector2i = Vector2i(12, 10) * GRID
	lm.holdSystem.hold_idle_builds.emit(held, [world_pos], false)
	var e = sys.get_entity_at(world_pos)
	assert_not_null(e, "手持箱子落子没生成实体")
	if e == null:
		return
	assert_eq(str(e.kind), "box", "手持箱子放出来的却是机器人")
	assert_false(e.has_bundle(), "箱子不该绑上电路")

# ===== 放置链路：手持落子 -> 实体系统 =====

func test_hold_idle_builds_spawns_robot() -> void:
	var world_pos: Vector2i = Vector2i(10, 10) * GRID
	#模拟手持层落子（场景根把这条信号接到了实体系统）
	lm.holdSystem.hold_idle_builds.emit([], [world_pos], false)
	assert_eq(sys.get_entity_count(), 1, "手持落子没生成机器人")
	assert_true(sys.has_entity_at(world_pos), "落子的格子没被占住")
	var e = sys.get_entity_at(world_pos)
	assert_not_null(e.draw_item, "生成的机器人没有渲染代理")
	assert_same(sys.entity_manager.getBuild(world_pos), e.draw_item,
			"渲染代理没进实体层分区块表")
	assert_false(bool(e.draw_item.is_preview),
			"渲染代理不能是 preview 克隆：ByContent 图层会把它短路成空实例块")
	#最本质的一条：按渲染链真正的取法烘一次实例块。preview 克隆在这里拿到空数组，
	#而 ByContent 图层就是靠这个数组生成 MultiMesh 实例的，空了就等于「放上去也看不见」。
	#这一步依赖 SWStyleTexture 单例，所以只能放在已经 boot 过场景的用例里（纯逻辑用例跑不了）
	var renderable: SWBuildCompoentRenderable = e.draw_item.getRenderableCompoent()
	var block: PackedFloat32Array = renderable.getInstanceBlock(
			float(e.draw_item.buildAxisPos.x), float(e.draw_item.buildAxisPos.y),
			float(GRID.x), float(GRID.y), e.draw_item.buildState.mask_color, true, 0)
	assert_gt(block.size(), 0, "机器人烧出来的实例块是空的：实体层画不出来")
	assert_eq(block.size() % SWBuildCompoentRenderable.INSTANCE_STRIDE, 0,
			"实例块长度不是 stride 的整数倍")

	#同一格再落一次不叠加
	lm.holdSystem.hold_idle_builds.emit([], [world_pos], false)
	assert_eq(sys.get_entity_count(), 1, "同一格落了两次")


func test_hold_remove_builds_erases_robot() -> void:
	var world_pos: Vector2i = Vector2i(11, 11) * GRID
	lm.holdSystem.hold_idle_builds.emit([], [world_pos], false)
	assert_eq(sys.get_entity_count(), 1)
	#模拟右键抹格
	lm.holdSystem.hold_remove_builds.emit([world_pos])
	assert_eq(sys.get_entity_count(), 0, "抹格没删掉机器人")
	assert_false(sys.has_entity_at(world_pos), "删掉后格子还占着")


# 玩家真实操作路径：点 HUD 工具 → 在地图上按下左键 → 机器人生成。
# 上面几个用例是直接 emit 信号的，绕过了 hold 系统的鼠标处理；这条把它补齐。
func test_real_click_places_robot() -> void:
	var btn: TextureButton = lm.hudLayer.call("get_robot_tool_button")
	assert_not_null(btn)
	btn.pressed.emit()
	assert_false(lm.holdSystem.is_hold_empty(), "手持没装上，后面点了也放不了")
	#构造一次真实左键按下，走与玩家点击完全同一条路径（hold 系统 handle_input）
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	var consumed: bool = lm.holdSystem.handle_input(ev)
	assert_true(consumed, "手持有内容时，左键按下应当被手持层吃掉")
	assert_eq(sys.get_entity_count(), 1, "真实点击没生成机器人（手持落子链路断了）")


# 端到端：机器人所在的区块真的建出来了，而且区块里确实有实例。
# 上一轮踩过的坑就在这里：机器人进了分区块表，但 is_preview 让实例块为 0，
# 区块照建、实例为 0，表现成「点了放不上去」。
func test_entity_chunk_builds_visible_instance() -> void:
	var world_pos: Vector2i = Vector2i(12, 12) * GRID
	lm.holdSystem.hold_idle_builds.emit([], [world_pos], false)
	assert_eq(sys.get_entity_count(), 1, "机器人没放上")
	var dm: SWDrawManager = entity_layer.get("sw_draw_manager") as SWDrawManager
	#headless 下相机视口是空的，手动声明「整张地图都在视野内」，并关掉分帧限流，
	#这样一次就能把机器人所在的区块真正建出来
	dm.async_loading = false
	dm._curViewRect = Rect2(-1e9, -1e9, 2e9, 2e9)
	var chunk: Vector2i = SwCommon.GetChunkPos(world_pos)
	var chunks: Array[Vector2i] = [chunk]
	dm.updataChunks(chunks)
	var guard := 0
	while dm._pending_tasks.has(0) and not dm._pending_tasks[0].is_empty() and guard < 400:
		guard += 1
		dm.process_load_chunk(0)
		for ins in dm.shouldAddToTree:
			if ins.get_parent() == null:
				dm.add_child(ins)
		dm.shouldAddToTree.clear()
	var total: int = 0
	for n in dm.find_children("*", "MultiMeshInstance2D", true, false):
		var mmi := n as SWMultiMeshInstance2D
		if mmi != null:
			total += mmi._usedInstances
	assert_gt(total, 0, "机器人所在区块建出来了，但一个实例都没有（画面上看不到机器人）")


# ===== 电路绑定面板（阶段 4） =====

#面板是代码构建的，没有稳定节点名可取，按文字找按钮
func _find_button(root: Node, text: String) -> Button:
	for n in root.find_children("*", "Button", true, false):
		var b := n as Button
		if b != null and b.text == text:
			return b
	return null

#在某个格子放一台机器人，返回实体
func _spawn_at(cell: Vector2i):
	var world_pos: Vector2i = cell * GRID
	lm.holdSystem.hold_idle_builds.emit([], [world_pos], false)
	return sys.get_entity_at(world_pos)


# 单击机器人 -> 面板弹出；点空地 -> 面板收起。
# 这是阶段 4 的入口：面板本身能画出来不算完成，得真的被 entity_selected 拉起来。
func test_click_robot_opens_bind_panel() -> void:
	assert_true(lm.hudLayer.has_method("show_bind_panel"),
			"机器人场景的 HUD 没有阶段 4 的电路绑定面板")
	assert_not_null(lm.hudLayer.call("get_bind_list"), "面板里没有电路列表")
	var e = _spawn_at(Vector2i(8, 8))
	assert_not_null(e, "机器人没放上")
	assert_false(bool(lm.hudLayer.call("is_bind_panel_visible")),
			"还没点机器人，面板就弹出来了")
	#点地图上的机器人：实体层接左键 -> 命中占格表 -> set_selected -> 场景根把它接到面板
	assert_true(sys.select_at(Vector2i(8, 8) * GRID), "点到机器人却没选中")
	assert_true(bool(lm.hudLayer.call("is_bind_panel_visible")), "点了机器人面板没弹出来")
	assert_same(lm.hudLayer.call("get_bind_panel_entity"), e, "面板对着的不是点中的那台机器人")
	#标题显示格子下标（8,8），不能把 world 坐标直接印出来
	var title: Label = lm.hudLayer.call("get_bind_panel_title")
	assert_not_null(title, "面板没有标题")
	assert_true(title.text.contains("(8, 8)"), "面板标题没显示机器人所在格子：" + title.text)
	#点空地 -> 取消选中 -> 面板跟着收起
	sys.select_at(Vector2i(40, 40) * GRID)
	assert_false(bool(lm.hudLayer.call("is_bind_panel_visible")), "点空地面板没收起来")


# 列表内容：第 0 项恒为「不绑定」；可用性只看「单电路」，接口名不参与判定
func test_bind_panel_lists_files_and_disables_unusable() -> void:
	assert_true(_make_usable_circuit(), "可用电路没造出来")
	assert_true(_make_partial_circuit(), "缺 rotation 的电路没造出来")
	assert_not_null(_spawn_at(Vector2i(9, 9)))
	sys.select_at(Vector2i(9, 9) * GRID)
	var list: ItemList = lm.hudLayer.call("get_bind_list")
	var files: Array = lm.hudLayer.call("get_bind_files")
	#列表下标 = 文件下标 + 1（0 被「不绑定」占了）
	var i_ok: int = files.find(FILE_OK) + 1
	var i_part: int = files.find(FILE_PARTIAL) + 1
	assert_gt(i_ok, 0, "面板没列出接口齐全的电路文件")
	assert_gt(i_part, 0, "面板没列出缺 rotation 的电路文件")
	assert_true(list.get_item_text(0).contains("不绑定"), "列表第 0 项不是「不绑定」")
	assert_false(list.is_item_disabled(i_ok), "接口齐全的电路被置灰了")
	#缺 rotation 不再算不可用：接口名怎么接是玩家的事
	assert_false(list.is_item_disabled(i_part), "缺 rotation 的电路不该再置灰")
	#每项两行：档名 + 接口摘要
	assert_true(list.get_item_text(i_ok).contains("\n"), "列表项没做成两行（档名 + 接口摘要）")
	assert_true(list.get_item_text(i_ok).contains("move"), "可用项没显示出输出接口")
	assert_true(list.get_item_text(i_part).contains("in:"), "缺 rotation 的项也要显示接口摘要")


# 缺 rotation 的电路能绑上，跑一拍照 clk->move 走一格（绑定不看接口名）
func test_partial_circuit_can_bind_and_tick() -> void:
	assert_true(_make_partial_circuit(), "缺 rotation 的电路没造出来")
	var e = _spawn_at(Vector2i(10, 10))
	assert_not_null(e)
	assert_true(sys.bind_circuit(e, FILE_PARTIAL), "缺 rotation 的电路现在应当能绑")
	assert_true(e.has_bundle(), "绑定后实体上没有 bundle")
	assert_eq(str(e.circuit_file), FILE_PARTIAL)
	var tick: Node = scene.get_node_or_null("SWRobotTick")
	assert_not_null(tick, "场景里没有节拍器")
	tick.call("tick_once")
	assert_eq(e.grid_pos, Vector2i(10, 9) * GRID, "缺 rotation 不影响 move=clk 走一格")


# 多电路文件：一拍里**每条含接口的电路**都要跑（这里 clk 同时驱动 move 与 rotation）
func test_multi_circuit_file_runs_all_circuits() -> void:
	assert_true(_export_two_circuit_file(), "多电路文件没造出来")
	var e = _spawn_at(Vector2i(12, 12))
	assert_not_null(e)
	assert_true(sys.bind_circuit(e, FILE_TWO_CIRCUITS), "多电路文件现在应当能绑")
	assert_eq(int(e.dir), 0, "初始朝上")
	var tick: Node = scene.get_node_or_null("SWRobotTick")
	assert_not_null(tick, "场景里没有节拍器")
	tick.call("tick_once")
	#两条电路都被跑到：先转（dir 0->1）再沿新朝向走一格。
	#只跑 move 那条的话方向不变、只走不转；只跑 rotation 那条则不动
	assert_eq(int(e.dir), 1, "rotation 那条电路没被跑到")
	assert_eq(e.grid_pos, Vector2i(13, 12) * GRID, "move 那条电路没被跑到（或没按转后朝向走）")


# 选中可用电路 -> 绑到这台机器人 -> 面板自动关 -> 下一拍真的按电路走
func test_panel_select_binds_and_beat_moves() -> void:
	assert_true(_make_usable_circuit(), "可用电路没造出来")
	var e = _spawn_at(Vector2i(20, 20))
	assert_not_null(e)
	assert_eq(sys.get_bound_count(), 0, "刚放下的机器人不该已经绑了电路")
	sys.select_at(Vector2i(20, 20) * GRID)
	assert_true(bool(lm.hudLayer.call("is_bind_panel_visible")), "面板没弹出来，后面点不了")
	var list: ItemList = lm.hudLayer.call("get_bind_list")
	var idx: int = (lm.hudLayer.call("get_bind_files") as Array).find(FILE_OK) + 1
	assert_gt(idx, 0, "面板里找不到可用的电路文件")
	#玩家的真实交互：点列表项 -> ItemList 发 item_selected
	list.select(idx)
	list.item_selected.emit(idx)
	assert_true(e.has_bundle(), "面板点了可用电路，实体上没绑上")
	assert_eq(str(e.circuit_file), FILE_OK, "绑的电路文件名不对")
	assert_eq(sys.get_bound_count(), 1)
	assert_false(bool(lm.hudLayer.call("is_bind_panel_visible")), "绑成功后应当自动关掉面板")
	#这条电路是 move = clk（rotation 被非门按住），机器人初始朝上
	var tick: Node = scene.get_node_or_null("SWRobotTick")
	assert_not_null(tick, "场景里没有节拍器")
	tick.call("tick_once")
	assert_eq(e.grid_pos, Vector2i(20, 19) * GRID, "绑定后一拍没按朝向走一格")


# 面板上的「解除绑定」：把电路摘掉，之后不再跟拍
func test_unbind_button_clears_bundle() -> void:
	assert_true(_make_usable_circuit(), "可用电路没造出来")
	var e = _spawn_at(Vector2i(21, 21))
	assert_not_null(e)
	assert_true(sys.bind_circuit(e, FILE_OK), "绑定失败")
	sys.select_at(Vector2i(21, 21) * GRID)
	assert_true(bool(lm.hudLayer.call("is_bind_panel_visible")))
	var btn: Button = _find_button(lm.hudLayer, "解除绑定")
	assert_not_null(btn, "面板上没有「解除绑定」按钮")
	btn.pressed.emit()
	assert_false(e.has_bundle(), "点了「解除绑定」实体上还挂着电路")
	assert_eq(str(e.circuit_file), "", "解绑后电路文件名没清")
	assert_eq(sys.get_bound_count(), 0)


# 选中后把机器人删掉：面板必须自己收起来，否则会对着一个已经不在的实体
func test_removing_selected_robot_hides_panel() -> void:
	assert_not_null(_spawn_at(Vector2i(22, 22)))
	sys.select_at(Vector2i(22, 22) * GRID)
	assert_true(bool(lm.hudLayer.call("is_bind_panel_visible")))
	lm.holdSystem.hold_remove_builds.emit([Vector2i(22, 22) * GRID])
	assert_eq(sys.get_entity_count(), 0, "抹格没删掉机器人")
	assert_null(sys.get_selected(), "删掉后还挂着选中")
	assert_false(bool(lm.hudLayer.call("is_bind_panel_visible")),
			"选中的机器人被删了，面板还开着")


# ===== Ctrl 框选 + 批量绑定 =====

#在一条横排上摆 n 台机器人，返回实体数组
func _spawn_row(from: Vector2i, n: int) -> Array:
	var out: Array = []
	for i in n:
		var e = _spawn_at(from + Vector2i(i, 0))
		if e != null:
			out.append(e)
	return out

#用世界坐标做一次完整拖拽（按下 -> 拖到 -> 松手），绕开视口坐标换算
func _drag_box(from_cell: Vector2i, to_cell: Vector2i, right_button: bool = false) -> void:
	var btn: int = MOUSE_BUTTON_RIGHT if right_button else MOUSE_BUTTON_LEFT
	var from_pos := Vector2(from_cell * GRID)
	var to_pos := Vector2(to_cell * GRID)
	assert_true(sys.box_select_begin(btn, from_pos), "框选没起来")
	assert_true(sys.is_box_selecting(), "按下后没进入框选态")
	sys.box_select_update(to_pos)
	assert_true(sys.box_select_end(to_pos), "松手没被吃掉")
	assert_false(sys.is_box_selecting(), "松手后还挂在框选态")


# Ctrl+左键拖：框住的机器人全部进选区，面板变成「已选 N 台」
func test_ctrl_drag_box_selects_robots_in_rect() -> void:
	var row: Array = _spawn_row(Vector2i(60, 60), 3)
	assert_eq(row.size(), 3, "三台机器人没摆上")
	#框外还有一台：不能被框进去
	var outside = _spawn_at(Vector2i(70, 70))
	assert_not_null(outside)
	_drag_box(Vector2i(59, 59), Vector2i(63, 63))
	assert_eq(sys.get_selection_count(), 3, "框选没选中三台机器人")
	var sel: Array = sys.get_selected_entities()
	assert_false(sel.has(outside), "框外的机器人被框进来了")
	for e in row:
		assert_true(sel.has(e), "框里的机器人漏掉了")
	#面板跟着弹出来，并且对着整批
	assert_true(bool(lm.hudLayer.call("is_bind_panel_visible")), "框选后面板没弹出来")
	var title: Label = lm.hudLayer.call("get_bind_panel_title")
	assert_true(title.text.contains("3"), "面板标题没显示台数：" + title.text)
	assert_eq((lm.hudLayer.call("get_bind_entities") as Array).size(), 3,
			"面板拿到的不是整批机器人")


# Ctrl+右键拖：把框里的从选区去掉，而且**不能**删掉机器人
# （手持层那套 Ctrl+右键框选在机器人场景里会把框内建筑擦掉，所以必须抢在它前面）
func test_ctrl_right_drag_deselects_without_erasing() -> void:
	var row: Array = _spawn_row(Vector2i(80, 80), 3)
	assert_eq(row.size(), 3)
	_drag_box(Vector2i(79, 79), Vector2i(83, 83))
	assert_eq(sys.get_selection_count(), 3, "前置条件：三台都得先选上")
	#只框住中间那台（81,80）
	_drag_box(Vector2i(81, 80), Vector2i(82, 81), true)
	assert_eq(sys.get_selection_count(), 2, "Ctrl+右键拖没把中间那台移出选区")
	assert_false(sys.get_selected_entities().has(row[1]), "中间那台还留在选区里")
	#关键：减选不能变成删机器人
	assert_eq(sys.get_entity_count(), 3, "Ctrl+右键拖把机器人删掉了（落到手持层擦除分支了）")
	assert_true(sys.has_entity_at(Vector2i(81, 80) * GRID), "中间那台被删了")


# 减选减空了：选区没了、面板收起（不能留一个对着空气的面板）
func test_subtract_all_clears_selection() -> void:
	var row: Array = _spawn_row(Vector2i(120, 120), 2)
	assert_eq(row.size(), 2)
	_drag_box(Vector2i(119, 119), Vector2i(123, 123))
	assert_eq(sys.get_selection_count(), 2)
	_drag_box(Vector2i(119, 119), Vector2i(123, 123), true)
	assert_eq(sys.get_selection_count(), 0, "减选没清空")
	assert_null(sys.get_selected(), "清空后还挂着主选")
	assert_false(bool(lm.hudLayer.call("is_bind_panel_visible")), "选区空了面板还开着")
	assert_eq(sys.get_entity_count(), 2, "减选不该删机器人")


# 框选只认机器人：箱子不绑电路，框进去也没意义（与单击选中同一口径）
func test_box_select_ignores_boxes() -> void:
	var box_btn: TextureButton = lm.hudLayer.call("get_box_tool_button")
	assert_not_null(box_btn, "HUD 没有箱子工具按钮")
	box_btn.pressed.emit()
	var held: Array = lm.holdSystem.get("_hold_builds")
	assert_gt(held.size(), 0, "箱子手持没装上")
	lm.holdSystem.hold_idle_builds.emit(held, [Vector2i(111, 111) * GRID], false)
	lm.holdSystem.set_hold_tool(null)
	var box_e = sys.get_entity_at(Vector2i(111, 111) * GRID)
	assert_not_null(box_e, "箱子没放上")
	assert_true(bool(box_e.is_box), "放下的应该是箱子")
	var rob = _spawn_at(Vector2i(112, 111))
	assert_not_null(rob)
	_drag_box(Vector2i(110, 110), Vector2i(114, 114))
	assert_eq(sys.get_selection_count(), 1, "框选把箱子也算进去了")
	assert_true(sys.get_selected_entities().has(rob), "框里的机器人没选中")


# 框选之后点其中某一台：回到单选（否则会变成「N+1 台」）
func test_click_after_box_select_keeps_single() -> void:
	var row: Array = _spawn_row(Vector2i(100, 100), 3)
	assert_eq(row.size(), 3)
	_drag_box(Vector2i(99, 99), Vector2i(103, 103))
	assert_eq(sys.get_selection_count(), 3)
	sys.select_at(Vector2i(101, 100) * GRID)
	assert_eq(sys.get_selection_count(), 1, "点一下没把选区收成单选")
	assert_same(sys.get_selected(), row[1], "单选的主选不对")
	var title: Label = lm.hudLayer.call("get_bind_panel_title")
	assert_true(title.text.contains("(101, 100)"), "面板没切回单台显示：" + title.text)


# 手上拿着机器人/箱子时，Ctrl+左键那一笔是拿去放置的，不该起框选
func test_box_select_gate_blocks_while_holding_tool() -> void:
	var btn: TextureButton = lm.hudLayer.call("get_robot_tool_button")
	assert_not_null(btn)
	btn.pressed.emit()
	assert_false(sys.box_select_begin(MOUSE_BUTTON_LEFT, Vector2.ZERO),
			"手持工具时还起框选（那一笔应当留给放置）")
	lm.holdSystem.set_hold_tool(null)
	assert_true(sys.box_select_begin(MOUSE_BUTTON_LEFT, Vector2.ZERO),
			"工具清掉后起不了框选")
	sys.box_select_end(Vector2.ZERO)


# 框选后点面板里的一条电路：整批都绑上，下一拍一起按电路走
func test_batch_bind_from_box_selection() -> void:
	assert_true(_make_usable_circuit(), "可用电路没造出来")
	var row: Array = _spawn_row(Vector2i(90, 90), 3)
	assert_eq(row.size(), 3)
	_drag_box(Vector2i(89, 89), Vector2i(93, 93))
	assert_eq(sys.get_selection_count(), 3, "框选没选中三台")
	var list: ItemList = lm.hudLayer.call("get_bind_list")
	var idx: int = (lm.hudLayer.call("get_bind_files") as Array).find(FILE_OK) + 1
	assert_gt(idx, 0, "面板里找不到可用的电路文件")
	list.select(idx)
	list.item_selected.emit(idx)
	for e in row:
		assert_eq(str(e.circuit_file), FILE_OK, "这台没绑上：%s" % str(e.cell()))
	assert_eq(sys.get_bound_count(), 3, "绑定台数不对")
	assert_false(bool(lm.hudLayer.call("is_bind_panel_visible")), "绑完面板没收起来")
	#一起走：这条电路是 move = clk，机器人初始朝上
	var tick: Node = scene.get_node_or_null("SWRobotTick")
	assert_not_null(tick, "场景里没有节拍器")
	tick.call("tick_once")
	for i in 3:
		assert_eq(row[i].grid_pos, Vector2i(90 + i, 89) * GRID,
				"第 %d 台没按电路走" % i)


# 真实输入路径：Ctrl+右键每一笔都要留给实体层做「减选」，
# 绝不能掉到手持层的擦除分支去删机器人（本场景已经把 rect_select_enabled 关了）
func test_ctrl_right_press_does_not_erase_robot() -> void:
	assert_false(bool(lm.holdSystem.rect_select_enabled),
			"机器人场景没关掉手持层的框选（Ctrl+右键拖会删机器人）")
	#鼠标位置的格子（headless 下就是原点那格）：放一台在这里才好分辨是否被擦掉
	var cell: Vector2i = sys.call("_mouse_grid")
	assert_not_null(_spawn_at(cell), "鼠标位置那格没摆上机器人")
	assert_eq(sys.get_entity_count(), 1)
	#带 Ctrl 的右键：不能擦
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_RIGHT
	ev.pressed = true
	ev.ctrl_pressed = true
	lm.holdSystem.handle_input(ev)
	assert_eq(sys.get_entity_count(), 1, "Ctrl+右键按下把机器人擦掉了（应当留给实体层减选）")
	#对照：不带 Ctrl 的右键拖是原有的擦除玩法，应当照旧删掉
	var ev2 := InputEventMouseButton.new()
	ev2.button_index = MOUSE_BUTTON_RIGHT
	ev2.pressed = true
	lm.holdSystem.handle_input(ev2)
	assert_eq(sys.get_entity_count(), 0, "不带 Ctrl 的右键应该照旧擦除（原玩法被改坏了）")


# 框选后把其中一台删掉：选区自己把它们剔掉，不能带着死实体去批量绑定
func test_deleting_box_selected_robot_updates_selection() -> void:
	var row: Array = _spawn_row(Vector2i(130, 130), 3)
	assert_eq(row.size(), 3)
	_drag_box(Vector2i(129, 129), Vector2i(133, 133))
	assert_eq(sys.get_selection_count(), 3)
	lm.holdSystem.hold_remove_builds.emit([Vector2i(130, 130) * GRID])
	assert_eq(sys.get_selection_count(), 2, "删掉的那台还在选区里")
	assert_eq(sys.get_entity_count(), 2)
	assert_false(sys.get_selected_entities().has(row[0]), "删掉的那台还在选区里")


# ===== 修改电路（进电路场景打开这条电路所在的存档） =====

func test_bind_panel_has_edit_circuit_button() -> void:
	assert_true(_make_usable_circuit(), "可用电路没造出来")
	var e = _spawn_at(Vector2i(14, 14))
	assert_not_null(e)
	assert_true(sys.bind_circuit(e, FILE_OK), "绑定失败")
	sys.select_at(Vector2i(14, 14) * GRID)
	assert_not_null(_find_button(lm.hudLayer, "修改电路"),
			"绑定面板上没有「修改电路」按钮")

# 「修改电路」= 记下要读的存档 + 切到电路场景。切场景会把整棵测试树换掉，
# 所以用例只跑前半步（prepare_edit_circuit），真正跳转只由按钮直连 request_edit_circuit
func test_edit_circuit_prepares_pending_save() -> void:
	assert_true(_make_usable_circuit(), "可用电路没造出来")
	var e = _spawn_at(Vector2i(15, 15))
	assert_not_null(e)
	assert_true(sys.bind_circuit(e, FILE_OK), "绑定失败")
	sys.select_at(Vector2i(15, 15) * GRID)
	assert_true(lm.hudLayer.has_method("prepare_edit_circuit"),
			"HUD 没有修改电路的准备入口")
	var target: String = lm.hudLayer.call("prepare_edit_circuit")
	assert_eq(target, FILE_OK, "要改的电路不是这台机器人绑的那条")
	assert_eq(SESSION.pending_load_save, FILE_OK,
			"没把待加载存档交给电路场景（进去会是一片空白）")

# 没绑电路也没选中可用项时不能乱写待加载存档
func test_edit_circuit_without_target_does_nothing() -> void:
	assert_not_null(_spawn_at(Vector2i(16, 16)))
	sys.select_at(Vector2i(16, 16) * GRID)
	assert_eq(str(lm.hudLayer.call("prepare_edit_circuit")), "",
			"没目标时不该返回存档名")
	assert_eq(SESSION.pending_load_save, "", "没目标时不能写待加载存档")


# ===== 电路时序图 =====

func test_timing_panel_collects_beats() -> void:
	assert_true(_make_usable_circuit(), "可用电路没造出来")
	var e = _spawn_at(Vector2i(30, 30))
	assert_not_null(e)
	assert_true(sys.bind_circuit(e, FILE_OK), "绑定失败")
	sys.select_at(Vector2i(30, 30) * GRID)

	var btn: Button = lm.hudLayer.call("get_timing_toggle_button")
	assert_not_null(btn, "底部工具栏上没有「时序图」按钮")
	assert_false(bool(lm.hudLayer.call("is_timing_panel_visible")),
			"时序图面板默认必须是关的")
	btn.pressed.emit()
	assert_true(bool(lm.hudLayer.call("is_timing_panel_visible")), "点了按钮面板没打开")
	var scope = lm.hudLayer.call("get_timing_scope")
	assert_not_null(scope, "时序面板里没有绘制控件")

	#跑两拍：这条电路 move = clk，两拍都该走一格
	var tick: Node = scene.get_node_or_null("SWRobotTick")
	assert_not_null(tick)
	tick.call("tick_once")
	tick.call("tick_once")
	lm.hudLayer.call("refresh_timing")
	#等两帧让绘制真正跑一遍：时序图的 _draw 只有在 headless 下也能触发，
	#排版/字号/字体取不到这类错误才会在这里冒出来
	await wait_process_frames(2)
	assert_same(lm.hudLayer.call("get_timing_entity"), e, "时序图看的不是选中那台")
	assert_eq(scope.get_sample_count(), 4, "两拍应当采到四条样本（每拍高/低两相）")
	assert_gt(int(scope.draw_count), 0, "波形一次都没画（面板开着但 _draw 没跑）")
	#两拍 = 3 个 clk 边沿（1→0 下降、0→1 上升、1→0 下降），都要落到画布上
	assert_gt(int(scope.get("edge_draw_count")), 0, "clk 的上升/下降沿一个都没画出来")

	#关掉面板：样本清空，不再占内存
	lm.hudLayer.call("toggle_timing_panel")
	assert_false(bool(lm.hudLayer.call("is_timing_panel_visible")))
	assert_eq(scope.get_sample_count(), 0, "关掉面板后旧波形没清")


func test_timing_footer_shows_total_beats() -> void:
	assert_true(_make_usable_circuit(), "可用电路没造出来")
	var e = _spawn_at(Vector2i(32, 32))
	assert_not_null(e)
	assert_true(sys.bind_circuit(e, FILE_OK), "绑定失败")
	sys.select_at(Vector2i(32, 32) * GRID)
	var tick: Node = scene.get_node_or_null("SWRobotTick")
	assert_not_null(tick)
	#先停下：不然节拍器自己走拍，拍数就对不上了
	tick.call("pause")
	var footer: Label = lm.hudLayer.call("get_timing_footer")
	assert_not_null(footer, "时序面板没有 footer 标签")

	tick.call("step_once")
	tick.call("step_once")
	var beats: int = int(e.timing_beats)
	assert_eq(beats, 2, "两拍应当累两拍")
	assert_eq(e.timing.size(), 4, "两拍应当落四条样本（高相位 + 低相位）")
	lm.hudLayer.call("toggle_timing_panel")
	#footer 的 beats 必须是累计拍数，不能是封顶后的窗口大小（否则看着像停了）
	assert_true(footer.text.contains("beats=%d" % beats),
			"footer 没显示累计拍数: " + footer.text)


func test_timing_scope_uses_global_beat_phase() -> void:
	#时间栅格的相位必须按全局拍号算：窗口后移时用窗口内下标算会让底色/刻度跳一下
	var scope = lm.hudLayer.call("get_timing_scope")
	assert_not_null(scope, "时序面板里没有绘制控件")
	var samples: Array = []
	for i in range(60):
		samples.append(Vector4i(1, 0, 0, 0))
	scope.call("set_samples", samples, 60)
	assert_eq(int(scope.get("_base_seq")), 0, "窗口没滑动时基序号应当是 0")

	#追到 100 拍时窗口只剩最后 20 条：基序号要推进到 80，
	#屏幕上的底色/刻度才不会跟着重排（按窗口内下标算的话会跳一下）
	scope.call("set_samples", samples.slice(40), 100)
	assert_eq(int(scope.get("_base_seq")), 80, "窗口滑动后基序号应当推进 40 拍")


func test_timing_scope_reads_low_clk_phase() -> void:
	#一拍两条样本，clk 高低两相都必须能被绘制控件区分出来
	var scope = lm.hudLayer.call("get_timing_scope")
	assert_not_null(scope, "时序面板里没有绘制控件")
	assert_eq(int(scope.call("_track_level", Vector4i(1, 0, 0, 0), 0)), 1,
			"高相位样本应当是高电平")
	assert_eq(int(scope.call("_track_level", Vector4i(0, 0, 0, 0), 0)), 0,
			"clk=0 的样本没被认成低电平")
	#clk 轨不能被 move/rotation 串过去
	assert_eq(int(scope.call("_track_level", Vector4i(0, 1, 1, 0), 0)), 0,
			"clk 轨把别的轨读进去了")

	#占空比：每拍两条样本必须是 1:1（一条高、一条低）。数据不是 1:1 的话，
	#画出来的高低电平宽度自然对不上，看着就像波形错了
	var e = _spawn_at(Vector2i(70, 70))
	assert_not_null(e, "机器人没放上")
	e.clear_timing()
	e.push_beat(0, 0, 0)
	assert_eq(e.timing.size(), 2, "一拍应当追两条样本")
	assert_eq(int(e.timing[0].x), 1, "拍首那条不是高电平")
	assert_eq(int(e.timing[1].x), 0, "拍末那条不是低电平")
	#绘制层不能再自己改占空比：曾经把高相位格画成「前半格低、后半格高」的窄脉冲，
	#视觉占空比变成 25%；现在 clk 轨和其他三轨走同一条整格电平画法
	assert_false(scope.has_method("_draw_pulse"),
			"clk 轨又被特殊画法改占空比了（应当整格画电平）")


func test_timing_scope_marks_clk_edges() -> void:
	#clk 有沿就必须能观测：上升沿（电路吃到时钟沿的那一刻）和下降沿都要分得开
	var scope = lm.hudLayer.call("get_timing_scope")
	assert_not_null(scope, "时序面板里没有绘制控件")
	var samples: Array = []
	for i in range(3):
		samples.append(Vector4i(1, 0, 0, 0))
		samples.append(Vector4i(0, 0, 0, 0))
	scope.call("set_samples", samples, samples.size())
	#样本序列 1,0,1,0,1,0
	assert_eq(int(scope.call("get_clk_edge", 0)), 0, "第一条样本没有前驱，不该报边沿")
	assert_eq(int(scope.call("get_clk_edge", 1)), -1, "高 -> 低没被认成下降沿")
	assert_eq(int(scope.call("get_clk_edge", 2)), 1, "低 -> 高没被认成上升沿")
	assert_eq(int(scope.call("get_clk_edge", 5)), -1, "最后一格的下降沿没认出来")
	assert_eq(int(scope.call("get_clk_edge", 6)), 0, "越界下标不该报边沿")
	#三拍 = 2 个上升沿（第一拍的那个没有前驱）+ 3 个下降沿
	assert_eq(int(scope.call("count_clk_edges", 1)), 2, "上升沿个数不对")
	assert_eq(int(scope.call("count_clk_edges", -1)), 3, "下降沿个数不对")
	#边沿就是方波自己的跳变竖线：不另加三角、不另换色（用户要的就是原来那种素线）
	assert_false(scope.has_method("_draw_clk_edge"),
			"clk 边沿又加三角标记了（应当就是方波自己的竖线）")
	assert_true(scope.has_method("get_clk_edge"), "没有可查询的 clk 边沿接口")


# 窗口最左一格如果是边沿，也要能看到：前驱取全局样本，不能用窗口内下标截断
func test_timing_scope_marks_edge_at_window_start() -> void:
	var scope = lm.hudLayer.call("get_timing_scope")
	assert_not_null(scope)
	#_samples 是全量数组（HUD 每帧推整个 entity.timing），_draw 只按 start 裁显示范围，
	#所以 start 那一格的边沿应当能用 start-1（窗口外）判出来
	var samples: Array = []
	for i in range(8):
		samples.append(Vector4i(1, 0, 0, 0))
		samples.append(Vector4i(0, 0, 0, 0))
	scope.call("set_samples", samples, samples.size())
	var cols: int = int(scope.call("visible_columns"))
	var start: int = maxi(0, samples.size() - cols)
	if start <= 0:
		pending("面板太宽，样本没溢出窗口，跳过后半段")
		return
	#窗口外的最后一条与窗口首条不同 -> 首格就是边沿，不能因为 i == start 就漏画
	assert_ne(int(scope.call("get_clk_edge", start)), 0,
			"窗口首格的边沿丢了（前驱不该按窗口内下标算）")


# 红线（游标）必须钉在右端不走，波形从它下面往左流：
# 这样最新的那个边沿会先在红线处冒出来，再往左流走 —— 上升沿和下降沿才都能在红线位置看到。
# 曾经一拍写两条样本（红线一次跳两格），看上去永远停在上升沿上、下降沿被跳过。
func test_timing_scope_cursor_stays_put_while_wave_flows() -> void:
	var scope = lm.hudLayer.call("get_timing_scope")
	assert_not_null(scope, "时序面板里没有绘制控件")
	var samples: Array = []
	for i in range(6):
		samples.append(Vector4i(1, 0, 0, 0))
	var n: int = samples.size()

	#相位 1（停住）：最新一格画满
	scope.call("set_samples", samples, n, 1.0)
	var full: Vector2 = scope.call("_cell_bounds", n - 1, n, 300.0)
	assert_almost_eq(full.y, 300.0, 0.01, "最新一格的右边界没钉在游标上")
	var w_full: float = full.y - full.x
	assert_gt(w_full, 0.0, "停住时最新一格宽度不该是 0（波形会缩成一条线）")
	var prev_full: Vector2 = scope.call("_cell_bounds", n - 2, n, 300.0)
	assert_almost_eq(prev_full.y, full.x, 0.01, "上一格右边界没接在最新一格左边界上（波形会断开）")

	#相位 0.25（刚流过四分之一）：游标不动，只把最新一格缩成四分之一
	scope.call("set_samples", samples, n, 0.25)
	var part: Vector2 = scope.call("_cell_bounds", n - 1, n, 300.0)
	assert_almost_eq(part.y, full.y, 0.01, "相位变了游标跟着动了（红线就不当参照物了）")
	assert_almost_eq(part.y - part.x, w_full * 0.25, 0.01, "最新一格没按相位进度只画一部分")
	var prev_part: Vector2 = scope.call("_cell_bounds", n - 2, n, 300.0)
	assert_almost_eq(prev_part.y, part.x, 0.01, "上一格没跟上最新一格的收缩（波形会断开）")

	#停住时 HUD 推的相位必须是 1：否则最后一格会被画成 0 宽
	var e = _spawn_at(Vector2i(84, 84))
	assert_not_null(e, "机器人没放上")
	sys.select_at(Vector2i(84, 84) * GRID)
	var tick: Node = scene.get_node_or_null("SWRobotTick")
	assert_not_null(tick, "场景里没有节拍器")
	tick.call("pause")
	lm.hudLayer.call("refresh_timing")
	assert_almost_eq(float(scope.get("_frac")), 1.0, 0.001, "停住时最新一格没画满")


# 绑定电路里的其它输出（push / detect_sig_*）要能各占一轨：
# 轨道名由实体侧给（entity.trace_names），电平按位图（entity.trace_masks）查；
# move/rotation 已经是固定四轨之二，不能再重复成新轨
func test_timing_scope_shows_extra_output_tracks() -> void:
	var scope = lm.hudLayer.call("get_timing_scope")
	assert_not_null(scope, "时序面板里没有绘制控件")
	var samples: Array = []
	var masks: Array = []
	for i in range(4):
		samples.append(Vector4i(1 if (i % 2) == 0 else 0, 0, 0, 0))
		masks.append(1 if i == 1 else 0)   # 只有第 2 条样本上 push 为高
	assert_true(bool(scope.call("set_samples", samples, samples.size(), 1.0,
			["push", "detect_sig_1"], masks)), "换了轨道却没要求重画")
	assert_eq(int(scope.call("track_count")), 6, "额外输出没加成轨道（4 固定 + 2）")
	assert_eq(str(scope.call("track_name", 4)), "push", "第 5 条轨应当是 push")
	assert_eq(str(scope.call("track_name", 5)), "detect_sig_1")
	#位图第 0 位 = push 轨、第 1 位 = detect_sig_1 轨
	assert_eq(int(scope.call("_level_at", 1, 4)), 1, "位图里的 push 电平没被读出来")
	assert_eq(int(scope.call("_level_at", 0, 4)), 0, "第 1 条样本上 push 不该是高")
	#固定轨仍走原来的 Vector4i 字段，不能被额外轨道串掉
	assert_eq(int(scope.call("_level_at", 0, 0)), 1, "clk 轨读错了")
	assert_eq(int(scope.call("_level_at", 1, 0)), 0, "clk 轨读错了")

	#move/rotation 再传一遍不能被加成额外轨（否则会出现两条一模一样的波形）
	scope.call("set_samples", samples, samples.size(), 1.0,
			["move", "rotation", "push"], masks)
	assert_eq(int(scope.call("track_count")), 5, "move/rotation 不该重复成额外轨")
	#轨道多了要能缩行高：不然 13 条轨在固定面板里只能挤出界面（最小 12）
	assert_gte(float(scope.call("_row_h", 13)), 12.0, "行高被压到比最小行高还小")
	scope.call("clear_samples")


# ===== 时序面板：监测信号勾选菜单（多选） =====

# 模拟玩家在勾选菜单里点某一项（真实点击也是发 index_pressed；
# 勾选态一律由会话清单重排出来，不在控件上读）
func _toggle_signal(menu: MenuButton, name: String) -> void:
	var popup: PopupMenu = menu.get_popup()
	for i in popup.item_count:
		var meta = popup.get_item_metadata(i)
		if meta != null and str(meta) == name:
			popup.index_pressed.emit(i)
			return
	fail_test("勾选菜单里没有信号：" + name)


# 勾选菜单要列出所有输入/输出接口名；固定轨（clk）恒勾选且置灰
func test_timing_panel_has_signal_picker() -> void:
	var hud = lm.hudLayer
	var menu: MenuButton = hud.call("get_timing_signal_menu")
	var popup: PopupMenu = hud.call("get_timing_signal_popup")
	var clear_btn: Button = hud.call("get_timing_clear_button")
	assert_not_null(menu, "时序面板上没有监测信号菜单")
	assert_not_null(popup, "监测信号菜单没有弹窗")
	assert_not_null(clear_btn, "时序面板上没有「清空」按钮")
	assert_eq(clear_btn.text, "清空")
	#多选的前提：勾一项后菜单不收起，否则一次只能勾一个
	assert_false(popup.hide_on_checkable_item_selection, "勾选后菜单不该收起（否则不能多选）")

	var items: Array = []
	for i in popup.item_count:
		items.append(popup.get_item_text(i))
	assert_true(items.has("clk"), "菜单要列出输入接口 clk")
	assert_true(items.has("detect_res_0"), "菜单要列出输入接口 detect_res_0")
	assert_true(items.has("detect_res_7"), "菜单要列出输入接口 detect_res_7")
	assert_true(items.has("detect_sig_0"), "菜单要列出输出接口 detect_sig_0")
	assert_true(items.has("push"), "菜单要列出输出接口 push")

	#第 0 项是 clk（已是固定轨）：恒勾选 + 置灰
	assert_eq(str(popup.get_item_metadata(0)), "clk", "菜单第 1 项应当是输入接口 clk")
	assert_true(popup.is_item_checked(0), "clk 是固定轨，应当恒勾选")
	assert_true(popup.is_item_disabled(0), "clk 是固定轨，应当置灰")
	#自动模式下没有额外轨：按钮显示「自动」、清空不可点
	assert_true(menu.text.contains("自动"), "自动模式下菜单标题该显示「自动」")
	assert_true(clear_btn.disabled, "没监测任何信号时「清空」不该可点")


# 勾选即生效：多选同时监测；取消勾选 / 清空回自动；固定轨与上限拦截
func test_timing_signal_menu_multi_select() -> void:
	assert_true(_make_usable_circuit(), "可用电路没造出来")
	var e = _spawn_at(Vector2i(34, 34))
	assert_not_null(e)
	assert_true(sys.bind_circuit(e, FILE_OK), "绑定失败")
	sys.select_at(Vector2i(34, 34) * GRID)
	var hud = lm.hudLayer
	assert_true(bool(hud.call("toggle_timing_panel")), "时序面板没打开")
	var menu: MenuButton = hud.call("get_timing_signal_menu")
	var popup: PopupMenu = hud.call("get_timing_signal_popup")
	var clear_btn: Button = hud.call("get_timing_clear_button")
	var scope = hud.call("get_timing_scope")
	assert_not_null(scope, "时序面板里没有绘制控件")

	#勾一个输出名：立刻多一条轨，无需再点「添加」
	_toggle_signal(menu, "detect_sig_3")
	assert_eq(hud.call("get_timing_signals"), ["detect_sig_3"], "勾选后清单不对")
	assert_eq(e.trace_names, ["detect_sig_3"], "清单没推给实体")
	assert_true(e.trace_names_manual, "勾选后应当进入手动模式")
	assert_eq(int(scope.call("track_count")), 5, "勾选的信号没变成一条额外轨")
	assert_eq(str(scope.call("track_name", 4)), "detect_sig_3")
	assert_true(popup.is_item_checked(int(hud.call("get_timing_signal_index", "detect_sig_3"))),
			"已监测的信号在菜单里应当勾上")

	#不关菜单接着勾第二个（这就是多选），顺序按勾选顺序
	_toggle_signal(menu, "detect_res_1")
	assert_eq(hud.call("get_timing_signals"), ["detect_sig_3", "detect_res_1"])
	assert_eq(e.trace_names, ["detect_sig_3", "detect_res_1"], "输入口也要能监测")
	assert_eq(int(scope.call("track_count")), 6, "两条自选信号应当占两条轨")
	assert_eq(menu.text, "监测信号（2）", "菜单标题该带当前条数")

	#取消勾选：该项消失，其余顺序不变
	_toggle_signal(menu, "detect_sig_3")
	assert_eq(hud.call("get_timing_signals"), ["detect_res_1"])
	assert_false(popup.is_item_checked(int(hud.call("get_timing_signal_index", "detect_sig_3"))),
			"取消勾选后应当没勾上")
	assert_eq(int(scope.call("track_count")), 5, "取消勾选后应当少一条轨")

	#固定轨点不动：clk 永远在波形里，不该进自选清单
	_toggle_signal(menu, "clk")
	assert_eq(hud.call("get_timing_signals"), ["detect_res_1"], "固定轨不该被加进清单")

	#清空 = 回到自动模式（这条电路只有 move/rotation）
	clear_btn.pressed.emit()
	assert_eq((hud.call("get_timing_signals") as Array).size(), 0, "清空后清单该空")
	assert_false(e.trace_names_manual, "清空清单应当回到自动模式")
	assert_eq(int(scope.call("track_count")), 4, "自动模式下这条电路没有额外输出")
	assert_true(clear_btn.disabled, "清空后「清空」该置灰")

	#上限拦截：16 条额外轨封顶，第 17 条点了也不进清单
	var all: Array = []
	for i in popup.item_count:
		var meta = popup.get_item_metadata(i)
		var n: String = str(meta) if meta != null else ""
		if not n.is_empty() and not n in ["clk", "move", "rotation", "act"]:
			all.append(n)
	assert_true(all.size() >= 17, "接口名清单应当够测上限")
	for k in 16:
		_toggle_signal(menu, str(all[k]))
	assert_eq((hud.call("get_timing_signals") as Array).size(), 16, "应当刚好填到上限 16 条")
	_toggle_signal(menu, str(all[16]))
	assert_eq((hud.call("get_timing_signals") as Array).size(), 16, "超过上限的信号不该被加进来")
	assert_eq(int(scope.call("track_count")), 20, "16 条额外轨 + 固定 4 轨")


# ===== 时序面板上的运行 / 暂停 / 步进 =====

func test_timing_panel_has_tick_control_buttons() -> void:
	var hud = lm.hudLayer
	assert_not_null(hud, "没有 HUD")
	var tick: Node = scene.get_node_or_null("SWRobotTick")
	assert_not_null(tick, "场景里没有节拍器")
	assert_true(bool(tick.get("enabled")), "节拍器默认应当在跑")

	var run_btn: Button = hud.call("get_timing_run_button")
	var pause_btn: Button = hud.call("get_timing_pause_button")
	var step_btn: Button = hud.call("get_timing_step_button")
	assert_not_null(run_btn, "时序面板上没有「运行」按钮")
	assert_not_null(pause_btn, "时序面板上没有「暂停」按钮")
	assert_not_null(step_btn, "时序面板上没有「步进」按钮")
	assert_eq(run_btn.text, "运行")
	assert_eq(pause_btn.text, "暂停")
	assert_eq(step_btn.text, "步进")
	#默认在跑：此时「运行」该置灰、「暂停」可点
	assert_true(run_btn.disabled, "运行中「运行」按钮该置灰")
	assert_false(pause_btn.disabled, "运行中「暂停」按钮该可点")


func test_tick_buttons_control_robot_tick() -> void:
	var hud = lm.hudLayer
	var tick: Node = scene.get_node_or_null("SWRobotTick")
	assert_not_null(tick, "场景里没有节拍器")
	var run_btn: Button = hud.call("get_timing_run_button")
	var pause_btn: Button = hud.call("get_timing_pause_button")
	var step_btn: Button = hud.call("get_timing_step_button")

	#暂停：节拍器总开关关掉，两个按钮的可用态互换
	pause_btn.pressed.emit()
	assert_false(bool(tick.get("enabled")), "点了「暂停」节拍器还在跑")
	assert_false(run_btn.disabled, "暂停后「运行」按钮该可点")
	assert_true(pause_btn.disabled, "暂停后「暂停」按钮该置灰")
	#暂停时工具栏「时序图」按钮变色：面板关掉也看得出来机器人为什么不动
	var toggle_btn: Button = hud.call("get_timing_toggle_button")
	assert_true(toggle_btn.has_theme_color_override("font_color"),
			"暂停后工具栏「时序图」按钮没有变色提示")

	#步进：只走一拍，且走完仍然停着
	var before: int = int(tick.call("get_beat_count"))
	step_btn.pressed.emit()
	assert_eq(int(tick.call("get_beat_count")), before + 1,
			"点一次「步进」应当只走一拍")
	assert_false(bool(tick.get("enabled")), "步进后应当停在暂停态")
	#物理帧不能再自己冒拍
	tick.call("_physics_process", 1.0)
	assert_eq(int(tick.call("get_beat_count")), before + 1,
			"步进之后物理帧又自己发拍了")

	#运行：恢复自动节拍
	run_btn.pressed.emit()
	assert_true(bool(tick.get("enabled")), "点了「运行」节拍器没恢复")
	assert_true(run_btn.disabled, "恢复后「运行」按钮该置灰")
	assert_false(pause_btn.disabled, "恢复后「暂停」按钮该可点")
	assert_false(toggle_btn.has_theme_color_override("font_color"),
			"恢复运行后工具栏按钮没变回正常颜色")



# ===== 移动 / 旋转 / 选中的动画过渡 =====

# 未选中也必须看得到滑块：逻辑位置一拍就到新格子（节拍语义不能被动画带跑），
# 而画面由动画层接管，而且**滑完不交还烘焙层**（交还要等区块重建，会掉一两帧）
func test_move_slides_even_when_not_selected() -> void:
	var from_pos: Vector2i = Vector2i(50, 50) * GRID
	var to_pos: Vector2i = Vector2i(50, 49) * GRID
	var e = _spawn_at(Vector2i(50, 50))
	assert_not_null(e, "机器人没放上")
	var item: SWBuildItemDefine = e.draw_item
	var visual = entity_layer.call("get_visual")
	assert_not_null(visual, "实体层没有动画层（只能硬跳）")
	assert_null(sys.get_selected(), "前置条件：本用例不该有选中（要验的就是不选中也有动画）")

	assert_true(sys.move_entity(e), "走一格失败")
	#1. 逻辑位置当场到位
	assert_eq(e.grid_pos, to_pos, "逻辑位置没有立刻走到新格")
	#2. 烘焙层把这一台撤下来了，否则屏幕上会同时有两台
	assert_true(sys.is_detached(e), "开始移动了却没从烘焙层撤下（会同时出现两台）")
	assert_null(sys.entity_manager.getBuild(from_pos), "撤下后旧位置还有这台")
	#3. 动画层接管，且真的提交了可见实例（没选中也是）
	assert_true(bool(visual.has_unit(e)), "动画层没接管这一台")
	assert_true(bool(visual.is_busy(e)), "动画层没在跑（会看到瞬移）")
	var mm = visual.get_anim_mesh()
	assert_not_null(mm, "动画层没有 MultiMesh 载体")
	assert_gt(int(mm.multimesh.visible_instance_count), 0, "没选中就一个实例也不画（看不到动画）")

	#4. 中途推半帧：位置应当卡在两格之间，且还在画（get_unit_pos 是世界坐标，除 GRID 换算成格）
	sys.frame(0.08)
	assert_almost_eq(float(visual.get_unit_pos(e).y) / float(GRID.y), 49.5, 0.05,
			"滑到一半位置不对（要么没插值，要么一步跳过去了）")
	assert_gt(int(mm.multimesh.visible_instance_count), 0, "滑到一半就不画了")

	#5. 推完：动画停下来，但**仍然由动画层画**（滑完不能有一两帧空白）
	sys.frame(0.20)
	assert_false(bool(visual.is_busy(e)), "推完还在跑动画")
	assert_true(bool(visual.has_unit(e)), "滑完就把动画层记录抹了（末帧会闪一下）")
	assert_almost_eq(float(visual.get_unit_pos(e).y), float(to_pos.y), 1.0, "滑完位置没对齐新格")
	assert_gt(int(mm.multimesh.visible_instance_count), 0, "滑完就没实例了（会白一瞬）")
	assert_true(sys.is_detached(e), "滑完还是该留在动画层（交还要等区块重建）")
	assert_null(sys.entity_manager.getBuild(to_pos), "又入了一次烘焙层（会和动画层重叠成两个）")

	#6. 连续再走一格：从当前位置续上，不能先跳回上一格
	assert_true(sys.move_entity(e), "第二格走不动")
	assert_almost_eq(float(visual.get_unit_pos(e).y), float(to_pos.y), 1.0,
			"第二次移动的起点跳掉了")
	sys.frame(0.30)
	assert_almost_eq(float(visual.get_unit_pos(e).y) / float(GRID.y), 48.0, 0.05, "第二格没走到位")
	assert_eq(int(visual.get_unit_count()), 1, "连续移动后动画层记录数不对")


# 旋转也要有过渡：item.rotation 当场改成新朝向，动画层补一个「从旧朝向转过来」的补角
func test_rotate_plays_angle_transition() -> void:
	var e = _spawn_at(Vector2i(56, 56))
	assert_not_null(e, "机器人没放上")
	var visual = entity_layer.call("get_visual")
	assert_not_null(visual)
	assert_eq(int(e.dir), 0, "前置条件：刚放下朝右")

	sys.rotate_entity(e, 1)
	#1. 朝向当场就是新的（逻辑语义不变），几何也重烘了
	assert_eq(int(e.dir), 1, "转完之后实体朝向不对")
	assert_eq(int(e.draw_item.rotation), 1, "渲染代理的朝向没跟上（会画出旧朝向）")
	#2. 但画面上是从旧朝向开始转的：补角 = -90°
	assert_true(bool(visual.has_unit(e)), "只转向没有移动时动画层没接（会瞬切）")
	assert_true(bool(visual.is_busy(e)), "旋转动画没跑起来")
	assert_almost_eq(float(visual.get_unit_angle_delta(e)), -90.0, 0.5,
			"起点的补角不是 -90°（看起来会直接是新朝向）")
	#3. 半程应当是 -45° 左右（smoothstep 在 0.5 处为 0.5）
	sys.frame(0.10)
	assert_almost_eq(float(visual.get_unit_angle_delta(e)), -45.0, 5.0, "转到一半的角度不对")
	#4. 转完补角归零 = 就是烘焙好的新朝向
	sys.frame(0.20)
	assert_false(bool(visual.is_busy(e)), "转完还在跑")
	assert_almost_eq(float(visual.get_unit_angle_delta(e)), 0.0, 0.01, "转完还有残留补角")
	assert_true(bool(visual.has_unit(e)), "转完就把动画层记录抹了（末帧会闪一下）")


# 第二次转向：补角归零后画出来得是**新**朝向。
# 朝向是烘在模板里的，模板只生成一次；漏了重铺就会在第二次转向之后弹回
# 进动画层那一刻的旧朝向 —— 表现是「机器人一直朝一个方向」。
func test_second_rotate_keeps_new_orientation() -> void:
	var e = _spawn_at(Vector2i(56, 58))
	assert_not_null(e, "机器人没放上")
	var visual = entity_layer.call("get_visual")
	assert_not_null(visual)

	# 第一次转（这一下是新建行，模板本来就按新朝向烘）
	sys.rotate_entity(e, 1)
	sys.frame(0.30)
	assert_almost_eq(float(visual.get_unit_angle_delta(e)), 0.0, 0.01, "第一次转向没收尾")
	# 批处理是懒建的（第一次接管才 new），所以得在这之后才拿得到
	var batch = visual.get("_batch")
	assert_not_null(batch, "动画批处理没建起来")
	var first: PackedFloat32Array = batch.get_buffer().duplicate()

	# 第二次转：动画跑完以后，实例基向量必须跟着变成 180°，否则就是还画着旧朝向
	sys.rotate_entity(e, 1)
	assert_eq(int(e.dir), 2, "前置条件：应当转到朝左")
	sys.frame(0.30)
	assert_almost_eq(float(visual.get_unit_angle_delta(e)), 0.0, 0.01, "第二次转向没收尾")
	var after: PackedFloat32Array = batch.get_buffer()
	var basis_changed: bool = false
	var i: int = 0
	while i + 5 < after.size():
		#[0..1] 与 [4..5] 是两根基向量分量；位置/颜色不该参与比较
		if absf(after[i] - first[i]) > 0.001 or absf(after[i + 1] - first[i + 1]) > 0.001 \
				or absf(after[i + 4] - first[i + 4]) > 0.001 \
				or absf(after[i + 5] - first[i + 5]) > 0.001:
			basis_changed = true
			break
		i += 16
	assert_true(basis_changed, "第二次转向后实例基向量没变：模板还烘着旧朝向，画面会一直朝一个方向")


# 动画还没走完就被删：不能对分区块表再删一次（delBuilds 删不到会 assert，整条用例直接崩）
func test_removing_robot_mid_slide_is_safe() -> void:
	var e = _spawn_at(Vector2i(52, 52))
	assert_not_null(e)
	assert_true(sys.move_entity(e))
	assert_true(sys.is_detached(e), "前置条件：移动后应当处于撤下状态")
	assert_true(sys.remove_entity(e), "正在滑的机器人删不掉")
	assert_eq(sys.get_entity_count(), 0, "删完计数没减")
	assert_eq(sys.get_detached_count(), 0, "删掉后还留着 detached 记录")
	var visual = entity_layer.call("get_visual")
	assert_false(bool(visual.has_unit(e)), "删掉后动画层还在画这一台")
	assert_eq(int(visual.get_anim_mesh().multimesh.visible_instance_count), 0,
			"删掉后实例缓冲没清（会在原地留个幽灵）")
	assert_null(sys.entity_manager.getBuild(Vector2i(52, 52) * GRID), "删掉后还在烘焙层里")


# 选中：烘焙层改底色 + 动画层叠一圈会呼吸的光框，取消后淡出
func test_selection_shows_animated_glow() -> void:
	var cell: Vector2i = Vector2i(54, 54)
	var e = _spawn_at(cell)
	assert_not_null(e)
	var visual = entity_layer.call("get_visual")
	assert_not_null(visual, "实体层没有动画层")
	assert_false(bool(visual.has_glow()), "还没选中就先亮光框了")

	sys.select_at(cell * GRID)
	assert_true(bool(visual.has_glow()), "选中后没有光框")
	assert_same(visual.get_glow_entity(), e, "光框没对着选中的那台")
	#光框要画在这一格上。刚放下还没动过的机器人不在动画层里，
	#这里退化成插值位置查表就会画到世界原点（一个很隐蔽的回归）
	assert_almost_eq(float(visual.get_glow_pos().y), float(cell.y * GRID.y), 0.5,
			"光框画到别处去了")
	#光框必须真的重绘（headless 下 _draw 也会跑）：盯一次绘制计数
	var before: int = int(visual.draw_count)
	await wait_process_frames(2)
	assert_gt(int(visual.draw_count), before, "光框一次都没重绘（呼吸动画没跑）")

	#选中的那台走一格：光框要跟着滑块走，不能直接跳到新格
	assert_true(sys.move_entity(e), "选中的那台走不动")
	sys.frame(0.08)
	var mid_y: float = float(visual.get_glow_pos().y)
	assert_gt(mid_y, float(cell.y * GRID.y) - float(GRID.y), "光框跑到新格下面去了")
	assert_lt(mid_y, float(cell.y * GRID.y), "光框直接跳到新格了（没跟滑块）")
	sys.frame(0.30)

	sys.clear_selection()
	assert_null(visual.get_glow_entity(), "取消选中后还盯着那台")
	assert_true(bool(visual.has_glow()), "取消选中应当先淡出，不是直接没")
	sys.frame(0.30)
	assert_false(bool(visual.has_glow()), "淡出结束光框还亮着")


# ===== 存档名：加载时记录、保存时回填 =====

func test_current_save_name_persists_in_session() -> void:
	#存在 SWSession 静态变量里，切场景（换 SWLayerManager 实例）也不会丢
	lm.current_save_name = "我的存档"
	assert_eq(SESSION.current_save_name, "我的存档", "当前存档名没进会话")

func test_save_dialog_prefills_current_name() -> void:
	lm.current_save_name = "我的存档"
	var dlg = preload("res://ui/sw_save_dialog.tscn").instantiate()
	dlg.call("set_default_name", lm.current_save_name)
	add_child_autofree(dlg)
	await wait_frames(1)
	var edit: LineEdit = dlg.get_node("VBoxContainer/FormGrid/NameEdit")
	assert_eq(edit.text, "我的存档", "保存对话框没回填当前存档名")
	var ok: Button = dlg.get_node("VBoxContainer/BtnHBox/ConfirmBtn")
	assert_false(ok.disabled, "回填后确认按钮还是禁用的（玩家会以为回填失败）")


# ===== 切出记录 / 返回重载 =====

# 去电路场景再回来，机器人得还在原地。这里直接验实体的存取接口，
# 场景级往返（_exit_tree 落盘 -> _ready 读回）由两个函数各自覆盖
func test_scene_state_survives_roundtrip() -> void:
	assert_true(_make_usable_circuit(), "可用电路没造出来")
	var a = _spawn_at(Vector2i(40, 40))
	var b = _spawn_at(Vector2i(41, 41))
	assert_not_null(a)
	assert_not_null(b)
	assert_true(sys.bind_circuit(a, FILE_OK), "绑定失败")
	assert_true(sys.save_state(STATE_PATH), "状态没写进去")
	assert_true(FileAccess.file_exists(STATE_PATH), "状态文件没落盘")

	#当作重新进场景：先清空，再从文件恢复
	sys.clear_entities()
	assert_eq(sys.get_entity_count(), 0)
	assert_eq(sys.load_state(STATE_PATH), 2, "恢复出来的机器人数量不对")
	var ra = sys.get_entity_at(Vector2i(40, 40) * GRID)
	var rb = sys.get_entity_at(Vector2i(41, 41) * GRID)
	assert_not_null(ra, "(40,40) 上的机器人没恢复")
	assert_not_null(rb, "(41,41) 上的机器人没恢复")
	if ra != null:
		assert_eq(str(ra.circuit_file), FILE_OK, "绑定的电路没恢复")
		assert_true(ra.has_bundle(), "恢复后没重新加载 bundle（回来就不动了）")
	if rb != null:
		assert_eq(str(rb.circuit_file), "", "没绑电路的那台不该凭空绑上")


# 「修改电路」的落点：电路场景必须把 pending 消费掉，
# 否则每次进场景都会重复读同一个存档，玩家手改也白改
func test_logic_scene_consumes_pending_save() -> void:
	#先拆掉机器人场景：两套场景同时在会把系统重复注册
	if scene != null:
		remove_child(scene)
		scene.queue_free()
		scene = null
		lm = null
		sys = null
		entity_layer = null
		await wait_frames(2)
	#故意用一个不存在的存档：不走真读档，只验「取走并清空」这一步
	SESSION.pending_load_save = "_robot_scene_no_such_save"
	var packed: PackedScene = load("res://scene/sw_logic_scene.tscn")
	assert_not_null(packed, "电路场景加载失败")
	if packed == null:
		return
	var logic := packed.instantiate()
	add_child_autofree(logic)
	await wait_frames(3)
	assert_eq(SESSION.pending_load_save, "", "电路场景没把待加载存档消费掉")


# ===== 反方向：电路场景 HUD 上要有回机器人场景的按钮（决策 6） =====

func test_logic_scene_hud_has_robot_switch() -> void:
	#SWLayerManager 是按全局 SWLayer 组取图层的：两套场景同时在场会把系统重复注册，
	#所以先把机器人场景拆掉，再单独起一遍电路场景
	if scene != null:
		remove_child(scene)
		scene.queue_free()
		scene = null
		lm = null
		sys = null
		entity_layer = null
		await wait_frames(2)
	var packed: PackedScene = load("res://scene/sw_logic_scene.tscn")
	assert_not_null(packed, "电路场景加载失败")
	if packed == null:
		return
	var logic := packed.instantiate()
	add_child_autofree(logic)
	await wait_frames(3)
	var logic_lm := logic.get_node("SWLayerManager") as SWLayerManager
	var hud: Node = logic_lm.hudLayer
	assert_not_null(hud, "电路场景没有 HUD 层")
	var btn: Button = hud.get_node_or_null("机器人场景") as Button
	assert_not_null(btn, "电路场景 HUD 上没有「机器人场景」按钮，切不回去")
	assert_eq(btn.text, "机器人场景")
	#定位在左下角：底部上下锚都在 1.0（屏幕底），offset 为负值贴底
	assert_eq(btn.anchor_top, 1.0, "场景切换按钮不在屏幕底部锚点上")
	assert_eq(btn.anchor_bottom, 1.0, "场景切换按钮不在屏幕底部锚点上")
	assert_lt(btn.offset_bottom, 0.0, "场景切换按钮没贴到屏幕底边")
	#不能和左下角的任务进度条叠在一起（进度条底边必须在按钮顶边之上）
	var job: Control = null
	for c in hud.get_children():
		if c is ColorRect:
			job = c as Control
			break
	assert_not_null(job, "HUD 上找不到任务进度条")
	if job != null:
		assert_lt(job.offset_bottom, btn.offset_top, "任务进度条压到场景切换按钮上了")


# ===== 电路改结构后返回：先停节拍 → 按最新电路重绑 → 继续运行 =====
# 实际流程：机器人面板点「修改电路」→ 电路场景里改元件（不管存不存盘，退出时按当前结构
# 覆盖同名 .swcir）→ 回机器人场景。回来时必须按**最新**电路重绑，否则机器人还在跑旧指令。
func test_return_after_circuit_edit_reloads_latest_circuit() -> void:
	assert_true(_make_partial_circuit(), "起点要给一个 clk->move 的电路文件")
	var e = _spawn_at(Vector2i(60, 60))
	assert_not_null(e, "机器人没放上")
	assert_true(sys.bind_circuit(e, FILE_PARTIAL), "绑电路要成功")
	assert_true((e.bundle.output_names() as Array).has("move"), "前置条件：现在是 clk->move")

	# 玩家在电路场景里把这条电路改了结构：同名文件换成 clk->rotation
	assert_true(_export_circuit(FILE_PARTIAL, [
		[Vector2i(0, 7), IN_DEF],
		[Vector2i(0, 6), WIRE_DEF],
		[Vector2i(1, 6), WIRE_DEF],
		[Vector2i(1, 5), OUT_DEF, "rotation"],
	]), "改过的电路要能重新导出")

	# 切场景时机器人状态落盘，回来时实体是重建的
	assert_true(sys.save_state(), "场景状态要能落盘")
	sys.clear_entities()
	assert_eq(sys.get_entity_count(), 0, "前置条件：实体已清空（模拟重进场景）")

	# 电路场景退出时留下的「结构改过」标记
	SESSION.edited_save = FILE_PARTIAL
	var tick: Node = scene.get_node("SWRobotTick")
	assert_not_null(tick, "场景里没有 SWRobotTick")
	# 先手动暂停：能证明下面确实是「重载完再恢复运行」，而不是恰好默认就是开的
	tick.call("pause")
	scene.call("_restore_scene_state")

	assert_eq(sys.get_entity_count(), 1, "机器人要按存档状态恢复")
	var back = sys.get_entities()[0]
	assert_eq(str(back.circuit_file), FILE_PARTIAL, "恢复后还绑着同一条电路")
	var names: Array = back.bundle.output_names()
	assert_true(names.has("rotation"), "重绑用的还是旧电路（应该跑最新的 rotation）")
	assert_false(names.has("move"), "重绑用的还是旧电路（旧接口还在）")
	assert_true(bool(tick.get("enabled")), "重载完成后节拍要恢复运行")
	assert_eq(SESSION.edited_save, "", "标记要被取走，不能留着反复重载")


# 没改电路（SESSION 没有标记）时，恢复场景不该动运行状态：玩家自己暂停的保持暂停
func test_return_without_edit_keeps_tick_state() -> void:
	var e = _spawn_at(Vector2i(62, 62))
	assert_not_null(e, "机器人没放上")
	assert_true(sys.save_state(), "场景状态要能落盘")
	sys.clear_entities()
	scene.call("_restore_scene_state")
	var tick: Node = scene.get_node("SWRobotTick")
	tick.call("pause")
	sys.clear_entities()
	scene.call("_restore_scene_state")
	assert_eq(sys.get_entity_count(), 1, "没改电路也要恢复机器人")
	assert_false(bool(tick.get("enabled")), "没改电路就擅自把节拍打开了")
	tick.call("resume")
