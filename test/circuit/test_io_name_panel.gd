extends GutTest
# 接口元件点击改名的场景级用例（拉起真实主场景：真实建造系统 + 真实 HUD 层）：
#   1. 左键点到输入/输出接口 → 名称面板弹出，下拉项定位到当前名；
#   2. 下拉选中 → 写回建筑实例的 io_name，并进入存档 state；
#   3. 点非接口元件 / 空格子 → 面板不弹，也不吃掉点击；
#   4. 面板换绑：先点 A 再点 B，面板编辑的对象与选中项都要跟着换；
#      名字不在清单里时落到第一项，但不能把实例上的名字改掉；
#   5. 关闭按钮收起面板；
#   6. 改名 → save_state → load_save_data 读档 → 名字还原，再点开面板仍定位到新名。
#
# 为什么不驱动真实鼠标：headless 下 Viewport.get_mouse_position() 拿不到坐标，
# 所以直接进 SWBuildLayerSystem.click_build_at —— 它就是左键按下换算完格子后调用的同一函数，
# 面板弹出/写回/存档这些真正要验的东西都在这条路径上。
# 跑法：godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://test/circuit -gprefix test_io_name_panel -gexit

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
#新类的类名不在 headless 全局缓存里，一律 preload
const IO_CATALOG := preload("res://circuit/sw_io_name_catalog.gd")
const IN_DEF: SWBuildDefine = preload("res://res/输入接口.tres")
#输出接口已合并为单一元件：move / rotation 只是实例上的 io_name 不同
const OUT_DEF: SWBuildDefine = preload("res://res/输出接口.tres")
const NOT_DEF: SWBuildDefine = preload("res://res/非门.tres")
const WIRE_DEF: SWBuildDefine = preload("res://res/电线A.tres")

# 一片离任何东西都很远的空地（格子坐标）：本文件不读存档，直接用编号当格子
const BASE_CELL := Vector2i(700, 700)

var harness = null
var _build: SWBuildLayerSystem = null
var _hud: SWHudLayer = null

func before_each() -> void:
	harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)

func after_each() -> void:
	if harness != null:
		harness.shutdown_game()
		harness = null
	_build = null
	_hud = null

func _boot() -> bool:
	await harness.boot_game()
	var lm: SWLayerManager = harness.layer_manager
	_build = lm.buildSystem
	_hud = lm.hudLayer
	assert_not_null(_build, "建造系统没接上（SWLayerManager._wire_systems 没跑？）")
	assert_not_null(_hud, "HUD 层没接上")
	return _build != null and _hud != null

func _w(cell: Vector2i) -> Vector2i:
	return cell * SwDefine.GRID_SIZE

# 等放置队列跑完（分帧任务：入图 + 电路重建都要过几帧）
func _settle() -> void:
	var guard := 0
	while (_build.is_job_running() or not _build._place_jobs.is_empty()) and guard < 400:
		guard += 1
		await get_tree().process_frame
	assert_lt(guard, 399, "放置任务一直没跑完")

# 用真实放置队列放一个元件（与手持放置同一条路：入图 → 电路重建）
func _place(def: SWBuildDefine, cell: Vector2i) -> SWBuildItemDefine:
	_build.on_hold_idle_builds([SwDefine.SWBuildCreator(Vector2i.ZERO, def, 0)], [_w(cell)])
	await _settle()
	return harness.get_build(_w(cell))

# 面板里那颗「关闭」按钮（面板是运行期建的，节点树按 VBox 顺序排）
func _find_close_button() -> Button:
	if _hud._io_panel == null:
		return null
	var pending: Array[Node] = [_hud._io_panel]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		if node is Button and not (node is OptionButton) and (node as Button).text == "关闭":
			return node as Button
		pending.append_array(node.get_children())
	return null

# ===== 1. 点接口元件 → 面板弹出，选中项 = 当前名 =====

func test_click_output_port_opens_panel_with_current_name() -> void:
	if not await _boot():
		return
	var build = await _place(OUT_DEF, BASE_CELL)
	assert_not_null(build, "接口元件没能放到地图上")
	assert_false(_hud.is_io_name_panel_visible(), "还没点就弹出了名称面板")
	assert_true(_build.click_build_at(_w(BASE_CELL)), "左键点接口元件应当吃掉这次点击")
	assert_true(_hud.is_io_name_panel_visible(), "点接口元件没有弹出名称面板")
	assert_same(_hud.get_io_name_panel_build(), build, "面板编辑的不是被点的那个元件")
	var opts := _hud.get_io_name_options()
	assert_eq(opts, IO_CATALOG.OUTPUT_NAMES, "输出接口的下拉项不是输出名清单")
	assert_eq(_hud._io_option.selected, opts.find("move"),
			"下拉框没有定位到元件当前的名字（move）")

func test_click_input_port_opens_panel_at_clk() -> void:
	if not await _boot():
		return
	var build = await _place(IN_DEF, BASE_CELL)
	assert_not_null(build)
	assert_true(_build.click_build_at(_w(BASE_CELL)))
	assert_true(_hud.is_io_name_panel_visible(), "输入接口也要能点开名称面板")
	var in_opts := _hud.get_io_name_options()
	assert_eq(in_opts, IO_CATALOG.INPUT_NAMES, "输入接口的下拉项不是输入名清单")
	#输入/输出清单必须真的分开：输出名不能出现在输入接口的下拉框里
	assert_eq(in_opts.find("move"), -1, "输入接口的下拉框里不该有输出名 move")
	assert_gte(in_opts.size(), 1, "输入名清单不该是空的")
	assert_eq(in_opts[0], "clk", "输入接口默认名 clk 应当在第一项")
	assert_eq(_hud._io_option.selected, 0, "输入接口默认名 clk 应定位到第 0 项")

# ===== 2. 下拉选中 → 写回实例 + 进存档 state =====

func test_selecting_option_writes_io_name_and_save_state() -> void:
	if not await _boot():
		return
	var build = await _place(OUT_DEF, BASE_CELL)
	assert_not_null(build)
	assert_true(_build.click_build_at(_w(BASE_CELL)))
	var opts := _hud.get_io_name_options()
	var rot_idx: int = opts.find("rotation")
	assert_gt(rot_idx, 0, "输出名清单里没有 rotation")

	# 走 OptionButton 自己的信号（与其下拉被点中时的路径一致）
	_hud._io_option.select(rot_idx)
	_hud._io_option.item_selected.emit(rot_idx)
	assert_eq(str(build.get("io_name")), "rotation", "选中下拉项后没有写回元件实例")
	assert_eq(str(build.save_state().get("io_name", "")), "rotation",
			"改名没进 save_state，存档就带不走")

	# 面板开着可以连着改：这次换成事件输出名
	var push_idx: int = opts.find("push")
	assert_gt(push_idx, 0, "输出名清单里没有 push（机器人事件接不到）")
	_hud._io_option.select(push_idx)
	_hud._io_option.item_selected.emit(push_idx)
	assert_eq(str(build.get("io_name")), "push", "第二次改名没有生效")


# ===== 2b. 检测通道的名字要能选到（输入 detect_res_*、输出 detect_sig_*） =====

func test_detect_channel_names_are_selectable() -> void:
	if not await _boot():
		return
	var in_build = await _place(IN_DEF, BASE_CELL)
	var out_build = await _place(OUT_DEF, BASE_CELL + Vector2i(1, 0))
	assert_not_null(in_build, "输入接口没放上")
	assert_not_null(out_build, "输出接口没放上")
	if in_build == null or out_build == null:
		return

	# 输入接口：clk + detect_res_0..7
	assert_true(_build.click_build_at(_w(BASE_CELL)))
	var in_opts := _hud.get_io_name_options()
	assert_eq(in_opts, IO_CATALOG.INPUT_NAMES, "输入下拉项不是输入名清单")
	for b in range(8):
		assert_gt(in_opts.find("detect_res_%d" % b), 0, "输入清单里没有 detect_res_%d" % b)
	assert_eq(in_opts.find("detect_sig_0"), -1, "输出名不该出现在输入下拉框里")

	# 输出接口：move / rotation / push + detect_sig_0..7
	assert_true(_build.click_build_at(_w(BASE_CELL + Vector2i(1, 0))))
	var out_opts := _hud.get_io_name_options()
	for b in range(8):
		assert_gt(out_opts.find("detect_sig_%d" % b), 0, "输出清单里没有 detect_sig_%d" % b)
	assert_eq(out_opts.find("detect_res_0"), -1, "输入名不该出现在输出下拉框里")

	# 选一个检测方向名：要能写回实例并进存档
	var dir_idx: int = out_opts.find("detect_sig_3")
	_hud._io_option.select(dir_idx)
	_hud._io_option.item_selected.emit(dir_idx)
	assert_eq(str(out_build.get("io_name")), "detect_sig_3", "detect_sig 名字没写回元件")
	assert_eq(str(out_build.save_state().get("io_name", "")), "detect_sig_3",
			"detect_sig 名字没进 save_state")


# ===== 3. 点别的元件 / 空格子：不弹、不吃点击 =====

func test_click_non_interface_build_does_not_open_panel() -> void:
	if not await _boot():
		return
	var gate = await _place(NOT_DEF, BASE_CELL)
	var wire = await _place(WIRE_DEF, BASE_CELL + Vector2i(1, 0))
	assert_not_null(gate)
	assert_not_null(wire)
	#返回 false = 这次点击不吃，继续交给下层（框选 / 手持放置）
	assert_false(_build.click_build_at(_w(BASE_CELL)), "非门不该被当成接口元件吃掉点击")
	assert_false(_build.click_build_at(_w(BASE_CELL + Vector2i(1, 0))), "电线不该被吃掉点击")
	assert_false(_build.click_build_at(_w(BASE_CELL + Vector2i(5, 5))), "空格子不该被吃掉点击")
	assert_false(_hud.is_io_name_panel_visible(), "点非接口元件却弹出了名称面板")

# ===== 4. 面板换绑 + 名字不在清单里时落第一项 =====

func test_panel_switches_between_builds() -> void:
	if not await _boot():
		return
	var cell_a := BASE_CELL
	var cell_b := BASE_CELL + Vector2i(3, 0)
	var a = await _place(OUT_DEF, cell_a)
	var b = await _place(OUT_DEF, cell_b)
	assert_not_null(a)
	assert_not_null(b)
	# 合并后两个输出接口是同一个定义，名字靠实例属性区分
	b.set("io_name", "rotation")

	assert_true(_build.click_build_at(_w(cell_a)))
	assert_same(_hud.get_io_name_panel_build(), a)
	var opts := _hud.get_io_name_options()
	assert_eq(_hud._io_option.selected, opts.find("move"), "move 应定位到清单里 move 那一项")

	# 面板开着再点另一个接口元件：编辑对象与选中项都要换过去
	assert_true(_build.click_build_at(_w(cell_b)))
	assert_same(_hud.get_io_name_panel_build(), b, "再点另一个接口元件时面板没换绑")
	assert_eq(_hud._io_option.selected, opts.find("rotation"),
			"rotation 应定位到清单里 rotation 那一项")

	# 名字不在清单里（老存档 / 以后回调过的取值）：落到第一项，但不能改坏实例
	a.set("io_name", "weird")
	assert_true(_build.click_build_at(_w(cell_a)))
	assert_eq(_hud._io_option.selected, 0, "未知名字应落到第一项")
	assert_eq(str(a.get("io_name")), "weird", "仅仅打开面板就改掉了元件名字")

# ===== 5. 关闭按钮 =====

func test_close_button_hides_panel() -> void:
	if not await _boot():
		return
	var build = await _place(OUT_DEF, BASE_CELL)
	assert_not_null(build)
	assert_true(_build.click_build_at(_w(BASE_CELL)))
	assert_true(_hud.is_io_name_panel_visible())
	var close_btn := _find_close_button()
	assert_not_null(close_btn, "面板里找不到「关闭」按钮")
	if close_btn == null:
		return
	close_btn.pressed.emit()
	assert_false(_hud.is_io_name_panel_visible(), "点关闭后面板还在")
	assert_null(_hud.get_io_name_panel_build(), "收起面板后仍挂着编辑对象")
	#收起后再选一次下拉，不该改到刚才那个元件
	var before := str(build.get("io_name"))
	_hud._io_option.select(0)
	_hud._io_option.item_selected.emit(0)
	assert_eq(str(build.get("io_name")), before, "面板已收起却还在写回元件")

# ===== 6. 改名 → 存档 → 读档 → 名字还在 =====

func test_io_name_survives_save_and_load() -> void:
	if not await _boot():
		return
	var pos := _w(BASE_CELL)
	var build = await _place(OUT_DEF, BASE_CELL)
	assert_not_null(build)
	assert_true(_build.click_build_at(pos))
	var opts := _hud.get_io_name_options()
	var rot_idx: int = opts.find("rotation")
	_hud._io_option.select(rot_idx)
	_hud._io_option.item_selected.emit(rot_idx)
	assert_eq(str(build.get("io_name")), "rotation")
	_hud.hide_io_name_panel()

	# 按存档真实格式往返一次（同名同坐标，state 走 build.save_state()）
	var data := {
		"builds": [{
			"pos": {"x": pos.x, "y": pos.y},
			"def": OUT_DEF.buildName,
			"rot": 0,
			"state": build.save_state(),
		}],
	}
	_build.load_save_data(data)
	var reloaded = harness.get_build(pos)
	assert_not_null(reloaded, "读档后这一格没有元件")
	if reloaded == null:
		return
	assert_eq(str(reloaded.get("io_name")), "rotation", "读档没有还原接口名")
	assert_true(_build.click_build_at(pos), "读档后的接口元件也要能点开面板")
	assert_same(_hud.get_io_name_panel_build(), reloaded)
	assert_eq(_hud._io_option.selected, _hud.get_io_name_options().find("rotation"),
			"读档后的名字没有定位到 rotation")

# ===== 7. 旧存档（合并前的定义名）仍能读回来 =====

func test_legacy_def_name_still_loads() -> void:
	if not await _boot():
		return
	var pos := _w(BASE_CELL)
	# 合并前存档里写的是「输出接口rotation」这个已经不存在的定义名
	_build.load_save_data({
		"builds": [{
			"pos": {"x": pos.x, "y": pos.y},
			"def": "输出接口rotation",
			"rot": 0,
			"state": {"io_name": "rotation"},
		}],
	})
	var reloaded = harness.get_build(pos)
	assert_not_null(reloaded, "旧定义名（输出接口rotation）没能按别名读回来")
	if reloaded == null:
		return
	assert_eq(str(reloaded.buildDefine.buildName), "输出接口", "别名没有落到合并后的定义上")
	assert_eq(str(reloaded.get("io_name")), "rotation", "旧存档的接口名没有还原")
