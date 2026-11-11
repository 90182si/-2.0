extends GutTest
# 分屏调试壳（左机器人 / 右电路）场景级验收
#
# 这一层验的是「两个场景能不能并排活着」：图层/工具按钮不能被对方收走，
# 渲染单例与区块对象池只能有一份，右侧 clk 要跟着左侧节拍走，
# 改电路要能暂停左边、点应用后按最新电路重绑。
#
# 跑法：godot --headless --path . -s addons/gut/gut_cmdln.gd
#       -gdir=res://test/circuit -gprefix=test_split_scene -gexit

const SPLIT_SCENE_PATH: String = "res://scene/sw_split_scene.tscn"
const ROBOT_SCENE_PATH: String = "res://scene/sw_robot_scene.tscn"
const GRID: Vector2i = SwDefine.GRID_SIZE
const CIR_MANAGER := preload("res://circuit/sw_cir_manager.gd")
const SESSION := preload("res://core/manager/sw_session.gd")
#切出机器人场景时落盘的状态文件（与 SWEntityLayerSystem.STATE_PATH 一致）
const STATE_PATH: String = "user://saves/_robot_scene.json"

const IN_DEF: SWBuildDefine = preload("res://res/输入接口.tres")
const OUT_DEF: SWBuildDefine = preload("res://res/输出接口.tres")
const WIRE_DEF: SWBuildDefine = preload("res://res/电线A.tres")

#分屏用例专用的电路档名（.swcir 与存档同名，机器人绑的就是这个名字）
const FILE_SPLIT := "_split_scene"


func before_each() -> void:
	#上一轮的分屏被释放时会把机器人状态落盘，这里先清掉，否则新场景一起就把旧机器人带进来
	_clear_state_file()
	SESSION.reset()
	CIR_MANAGER.delete_file(FILE_SPLIT)


func after_each() -> void:
	_clear_state_file()
	SESSION.reset()
	CIR_MANAGER.delete_file(FILE_SPLIT)


func _clear_state_file() -> void:
	if FileAccess.file_exists(STATE_PATH):
		DirAccess.remove_absolute(STATE_PATH)


# 造一条 .swcir：specs = [[格子, 定义, 可选 io_name], ...]
func _export_circuit(name: String, specs: Array) -> bool:
	var mgr := SWBuildManager.new()
	var ctrl := SWCircuitControl.new()
	ctrl.setBuildManager(mgr)
	ctrl.gpu_backend_enabled = false
	var all: Array[SWBuildItemDefine] = []
	for s: Array in specs:
		var b := SwDefine.SWBuildCreator((s[0] as Vector2i) * GRID, s[1], 0)
		if s.size() > 2:
			b.set("io_name", str(s[2]))
		if not mgr.addBuild(b):
			ctrl.free()
			return false
		all.append(b)
	ctrl.updateBuildCircuit(all)
	var ok: bool = CIR_MANAGER.export_all(name, mgr.getAllBuilds()) != ""
	ctrl.free()
	return ok


# clk -> move：右侧「改之前」的结构
func _make_move_circuit(name: String) -> bool:
	return _export_circuit(name, [
		[Vector2i(0, 7), IN_DEF],
		[Vector2i(0, 6), WIRE_DEF],
		[Vector2i(1, 6), WIRE_DEF],
		[Vector2i(1, 5), OUT_DEF],
	])


# 把一组元件铺进右侧电路场景（存档里的一条建筑记录 -> build 系统）
# specs 与 _export_circuit 同格式：格子 / 定义 / 可选 io_name
func _load_right(shell: Node, specs: Array) -> void:
	var builds: Array = []
	for s: Array in specs:
		var rec: Dictionary = {
			"pos": {"x": (s[0] as Vector2i).x * GRID.x, "y": (s[0] as Vector2i).y * GRID.y},
			"def": str((s[1] as SWBuildDefine).buildName),
			"rot": 0,
			"state": {},
		}
		if s.size() > 2:
			rec["state"] = {"io_name": str(s[2])}
		builds.append(rec)
	shell.right_build.call("load_save_data", {"builds": builds})


# 起一个分屏壳并等两个子场景 _ready 走完
func _boot() -> Node:
	var packed: PackedScene = load(SPLIT_SCENE_PATH)
	assert_not_null(packed, "分屏壳加载失败: " + SPLIT_SCENE_PATH)
	if packed == null:
		return null
	var shell: Node = packed.instantiate()
	add_child_autofree(shell)
	await wait_frames(3)
	return shell


func _left_lm(shell: Node) -> SWLayerManager:
	return shell.left_scene.get_node("SWLayerManager") as SWLayerManager


func _right_lm(shell: Node) -> SWLayerManager:
	return shell.right_scene.get_node("SWLayerManager") as SWLayerManager


# 右侧 io_input_arr 里名为 clk 的输入口
func _clk_build(shell: Node):
	var arr: Dictionary = shell.right_build.get("io_input_arr")
	for b in arr.keys():
		if str(b.get("io_name")) == "clk":
			return b
	return null


# 右侧 io_input_arr 里名为 name 的输入口
func _in_build(shell: Node, name: String):
	var arr: Dictionary = shell.right_build.get("io_input_arr")
	for b in arr.keys():
		if str(b.get("io_name")) == name:
			return b
	return null


# 右侧的输出接口（只有一个）
func _out_build(shell: Node):
	var arr: Dictionary = shell.right_build.get("io_output_arr")
	for b in arr.keys():
		return b
	return null


func _spawn_left_robot(shell: Node, cell: Vector2i):
	var lm := _left_lm(shell)
	lm.holdSystem.hold_idle_builds.emit([], [cell * GRID], false)
	return shell.left_scene.call("get_entity_system").get_entity_at(cell * GRID)


# ===== 1. 结构：两个 SubViewport 各装一个场景，左右各半 =====

func test_shell_hosts_both_scenes() -> void:
	var shell: Node = await _boot()
	if shell == null:
		return
	assert_true(SESSION.split_mode, "进分屏后 SESSION.split_mode 应当是 true")
	var left_vp: SubViewport = shell.get_node("PaneRoot/LeftPane/LeftView")
	var right_vp: SubViewport = shell.get_node("PaneRoot/RightPane/RightView")
	assert_not_null(left_vp, "分屏壳没有左侧 SubViewport")
	assert_not_null(right_vp, "分屏壳没有右侧 SubViewport")
	assert_eq(left_vp.get_child_count(), 1, "左侧 SubViewport 里应当只有一个场景根")
	assert_eq(right_vp.get_child_count(), 1, "右侧 SubViewport 里应当只有一个场景根")
	var left: Node = left_vp.get_child(0)
	var right: Node = right_vp.get_child(0)
	assert_not_null(left.get_node_or_null("SWLayerManager/SWEntityLayer"),
			"左侧不是机器人场景（没有实体层）")
	assert_not_null(right.get_node_or_null("SWLayerManager/SWBuildLayer"),
			"右侧不是电路场景（没有建筑层）")

	#布局：左 + 分隔条 + 右 = 整个面板宽度，且两边大致各半
	var pane_root: Control = shell.get_node("PaneRoot")
	var left_pane: Control = shell.get_node("PaneRoot/LeftPane")
	var handle: Control = shell.get_node("PaneRoot/Handle")
	var right_pane: Control = shell.get_node("PaneRoot/RightPane")
	assert_gt(left_pane.size.x, 0.0, "左侧面板宽度是 0（分屏没摆出来）")
	assert_gt(right_pane.size.x, 0.0, "右侧面板宽度是 0（分屏没摆出来）")
	assert_almost_eq(left_pane.size.x + handle.size.x + right_pane.size.x,
			pane_root.size.x, 1.0, "三个矩形没铺满面板宽度")
	assert_almost_eq(handle.size.x, 8.0, 0.01, "分隔条宽度应当是 8px")
	assert_almost_eq(left_pane.position.x + left_pane.size.x, handle.position.x, 0.01,
			"分隔条没接在左侧面板右边")
	assert_almost_eq(handle.position.x + handle.size.x, right_pane.position.x, 0.01,
			"右侧面板没接在分隔条右边")


# ===== 1b. 顶栏：必须整块落在左半屏右上角，且不压左上角的性能面板 =====

func test_topbar_sits_in_left_pane_top_right() -> void:
	var shell: Node = await _boot()
	if shell == null:
		return
	var pane_root: Control = shell.get_node("PaneRoot")
	#headless 下根 viewport 只有几十像素宽，先在正常窗口尺寸下重摆一次
	#（顺带把 resize 重摆那条路径也跑了），再验几何关系
	pane_root.size = Vector2(1280.0, 720.0)
	shell.call("_layout")
	var bar: Control = shell.get_node("TopBar/Bar")
	var left_pane: Control = shell.get_node("PaneRoot/LeftPane")
	assert_not_null(bar, "分屏壳没有顶栏")
	if bar == null:
		return
	#落在左半屏：右边贴左半屏右边界 8px，不许越过分隔条去压右侧电路
	assert_almost_eq(bar.position.x + bar.size.x,
			left_pane.position.x + left_pane.size.x - 8.0, 0.5,
			"顶栏没贴到左半屏右上角：右边=%f，期望=%f" % [
				bar.position.x + bar.size.x, left_pane.position.x + left_pane.size.x - 8.0])
	assert_gt(bar.position.x, 0.0, "顶栏左边被窗口切了")
	assert_almost_eq(bar.size.x, bar.get_combined_minimum_size().x, 0.5,
			"顶栏宽度没跟着合最小宽走（会被裁或撑出半个屏幕）")
	#万一合最小宽晚一步才量到，引擎会按 grow 方向撑大 size：必须向左长，不能向右溢出
	assert_eq(bar.grow_horizontal, Control.GROW_DIRECTION_BEGIN,
			"顶栏的 grow 方向不是「向左扩」：最小宽晚量到就会溢出到屏幕外")
	assert_almost_eq(bar.position.y, 8.0, 0.01, "顶栏没贴住顶部")
	var status: Label = shell.get_node("TopBar/Bar/HBox/Status")
	var apply_btn: Button = shell.get_node("TopBar/Bar/HBox/ApplyBtn")
	assert_true(status.clip_text, "状态文字要开 clip_text，否则长文案会把顶栏撑出半屏")
	assert_gt(apply_btn.size.x, 0.0, "「应用到机器人」按钮没摆出来（顶栏被挤扁了）")
	#左半屏左上角的性能面板（展开后很宽）与右上角的表达式面板都要让开顶栏那一条
	var perf = shell.left_scene.get_node_or_null("SWPerformanceMonitor")
	assert_not_null(perf, "左侧场景没有性能面板")
	var stats: Control = perf.get("stats_container") if perf != null else null
	assert_not_null(stats, "性能面板没有统计容器")
	if stats != null:
		assert_true(stats.offset_top >= bar.position.y + bar.size.y,
				"左侧性能面板没让开顶栏：top=%f，顶栏底边=%f" % [
					stats.offset_top, bar.position.y + bar.size.y])
	var left_hud = shell.left_scene.get("sw_layer_manager").get("hudLayer")
	var expr_panel: Control = left_hud.get("_expr_panel") if left_hud != null else null
	assert_not_null(expr_panel, "左侧 HUD 没有悬浮表达式面板")
	if expr_panel != null:
		assert_true(expr_panel.offset_top >= bar.position.y + bar.size.y,
				"左侧表达式面板没让开顶栏：top=%f，顶栏底边=%f" % [
					expr_panel.offset_top, bar.position.y + bar.size.y])


# ===== 1c. 悬浮提示：分屏里也要能看得见 =====

func test_split_keeps_hover_tips_visible() -> void:
	var shell: Node = await _boot()
	if shell == null:
		return
	#tooltip 与下拉菜单本质是嵌入的 Window：子 viewport 不开内嵌就会按「独立 OS 窗口」弹，
	#位置按本半屏坐标算，实际跑到窗口外面去 = 悬浮提示「不显示」
	var left_vp: SubViewport = shell.get_node("PaneRoot/LeftPane/LeftView")
	var right_vp: SubViewport = shell.get_node("PaneRoot/RightPane/RightView")
	assert_true(left_vp.gui_embed_subwindows, "左侧子 viewport 没开内嵌子窗口（tooltip 弹不出来）")
	assert_true(right_vp.gui_embed_subwindows, "右侧子 viewport 没开内嵌子窗口（悬浮提示弹不出来）")
	#右侧性能面板只能收统计面板：跟随鼠标的建筑信息提示是它的子节点，整块藏就一起没了
	var perf = shell.right_scene.get_node_or_null("SWPerformanceMonitor")
	assert_not_null(perf, "右侧场景没有性能面板")
	if perf == null:
		return
	var stats: Control = perf.get("stats_container")
	assert_not_null(stats, "性能面板没有统计容器")
	if stats != null:
		assert_false(stats.visible, "分屏右侧的统计面板应当收起（右上角让给顶栏）")
	assert_true((perf as CanvasLayer).visible,
			"整块藏了性能面板：右半屏「鼠标悬浮看元件信息」也跟着没了")
	assert_not_null(perf.get("build_info_label_box"), "悬停信息框不见了")


# ===== 2. 隔离：按组的收集必须只看自己的场景子树 =====

func test_groups_are_collected_per_scene() -> void:
	var shell: Node = await _boot()
	if shell == null:
		return
	var left_vp: SubViewport = shell.get_node("PaneRoot/LeftPane/LeftView")
	var right_vp: SubViewport = shell.get_node("PaneRoot/RightPane/RightView")
	var left_lm := _left_lm(shell)
	var right_lm := _right_lm(shell)

	#图层管理器不能把另一边的图层收进来：收了就会把 build/entity 系统装配两遍
	for layer in left_lm.layers:
		assert_true(left_vp.is_ancestor_of(layer), "左侧收进了别的场景的图层: " + str(layer.name))
	for layer in right_lm.layers:
		assert_true(right_vp.is_ancestor_of(layer), "右侧收进了别的场景的图层: " + str(layer.name))
	assert_null(left_lm.buildLayer, "左侧不该有建筑层（把右边电路场景的收进来了）")
	assert_not_null(left_lm.get_layer_system("SWEntityLayer"), "左侧没有实体层系统")
	assert_not_null(right_lm.buildSystem, "右侧没有建筑层系统")
	assert_null(right_lm.get_layer_system("SWEntityLayer"), "右侧不该有实体层系统")

	#工具按钮同理：两边的 HUD 不能互相接管（否则图标与点击都会串）
	var left_tools: Array = left_lm.hudLayer.get("selTools")
	var right_tools: Array = right_lm.hudLayer.get("selTools")
	assert_eq(left_tools.size(), 2, "左侧工具栏应当只有机器人 + 箱子两个按钮")
	assert_gt(right_tools.size(), 0, "右侧工具栏是空的")
	for t in left_tools:
		assert_true(left_vp.is_ancestor_of(t), "左侧工具按钮不属于左侧场景")
		assert_false(right_tools.has(t), "同一个工具按钮被两边都接管了")
	for t in right_tools:
		assert_true(right_vp.is_ancestor_of(t), "右侧工具按钮不属于右侧场景")


# 两边的重复入口在分屏里要藏起来：整体换场景由壳的顶栏负责
func test_duplicate_scene_buttons_are_hidden() -> void:
	var shell: Node = await _boot()
	if shell == null:
		return
	var left_hud: SWHudLayer = _left_lm(shell).hudLayer
	var logic_btn: Button = left_hud.call("get_logic_scene_button")
	assert_not_null(logic_btn, "机器人 HUD 没有「电路场景」按钮")
	assert_false(logic_btn.visible, "分屏里「电路场景」按钮还露着（会整体换掉分屏）")
	var right_hud: SWHudLayer = _right_lm(shell).hudLayer
	var back_btn: Button = right_hud.get_scene_switch_button()
	if back_btn != null:
		assert_false(back_btn.visible, "分屏里右侧「机器人场景」按钮还露着")


# ===== 3. 单例：渲染纹理只由壳建一次 =====

func test_render_singletons_created_once() -> void:
	var packed: PackedScene = load(SPLIT_SCENE_PATH)
	if packed == null:
		assert_not_null(packed, "分屏壳加载失败")
		return
	#壳的 _init 先建单例，两个子场景随后进来只能复用
	var shell: Node = packed.instantiate()
	var style_tex = SWStyleTexture.instance
	var signal_tex = SWSignalTexture.instance
	assert_not_null(style_tex, "壳 _init 里没建样式纹理单例")
	assert_not_null(signal_tex, "壳 _init 里没建信号纹理单例")
	add_child_autofree(shell)
	await wait_frames(3)
	assert_same(SWStyleTexture.instance, style_tex, "子场景把样式纹理单例换掉了")
	assert_same(SWSignalTexture.instance, signal_tex, "子场景把信号纹理单例换掉了")


# ===== 4. 时钟相位锁：右侧 clk 跟着机器人节拍翻 =====

func test_clock_phase_lock_follows_robot_tick() -> void:
	var shell: Node = await _boot()
	if shell == null:
		return
	#先停掉自动节拍，下面手动发相位
	shell.left_tick.call("pause")
	_load_right(shell, [
		[Vector2i(0, 7), IN_DEF],
		[Vector2i(0, 6), WIRE_DEF],
		[Vector2i(1, 6), WIRE_DEF],
		[Vector2i(1, 5), OUT_DEF],
	])
	await wait_frames(1)
	assert_true(bool(shell.right_build.get("external_clock")),
			"分屏壳没把右侧切到外部时钟（它还在自己按挂钟扫方波）")
	var clk = _clk_build(shell)
	assert_not_null(clk, "右侧没有名为 clk 的输入接口")
	if clk == null:
		return
	assert_eq(int(clk.level), 0, "初始 clk 应当是低电平")
	shell.left_tick.call("tick_high")
	assert_eq(int(clk.level), 1, "机器人上升沿没写到右侧 clk（两边不同拍）")
	shell.left_tick.call("tick_low")
	assert_eq(int(clk.level), 0, "机器人下降沿没写到右侧 clk")
	#暂停时补一次低电平：机器人停住，右边不能停在半空
	shell.left_tick.call("tick_high")
	shell.left_tick.call("pause")
	assert_eq(int(clk.level), 0, "暂停时右侧 clk 没落低")


# ===== 4b. 时序图「步进」：右侧电路要跟着每个相位各算一次 =====

func test_step_once_evaluates_right_circuit_per_phase() -> void:
	var shell: Node = await _boot()
	if shell == null:
		return
	_load_right(shell, [
		[Vector2i(0, 7), IN_DEF],
		[Vector2i(0, 6), WIRE_DEF],
		[Vector2i(1, 6), WIRE_DEF],
		[Vector2i(1, 5), OUT_DEF],
	])
	await wait_frames(1)
	var clk = _clk_build(shell)
	var out = _out_build(shell)
	assert_not_null(clk, "右侧没有名为 clk 的输入接口")
	assert_not_null(out, "右侧没有输出接口")
	if clk == null or out == null:
		return
	#先停掉自动节拍：下面模拟玩家点「步进」
	shell.left_tick.call("pause")
	var before: int = int(shell.right_build.get("phase_steps_total"))
	#一拍 = 高相位 + 低相位，两个相位都必须在右侧当场算一次。
	#旧实现把两相位攒着等右侧自己的帧 tick，那时 clk 已经被低相位覆写，
	#上升沿那次求值被吃掉——右边一步都不走
	shell.left_tick.call("step_once")
	var after: int = int(shell.right_build.get("phase_steps_total"))
	assert_eq(after - before, 2,
			"机器人步进一拍，右侧应当各算高/低两个相位（实际 %d 个）" % (after - before))
	assert_eq(int(clk.level), 0, "步进结束 clk 应当停在低电平")
	assert_eq(int(out.get("_display_level")), 0,
			"低相位求值结果要回填到输出口显示")
	#同一帧内再步进一次：右侧不能被帧 tick 的「一帧只算一次」卡住
	shell.left_tick.call("step_once")
	assert_eq(int(shell.right_build.get("phase_steps_total")) - after, 2,
			"同一帧内再步进，右侧仍要各算两个相位（不能被帧 tick 兜死）")


# ===== 4c. 数据位镜像：机器人的 detect_res_* 要写到右侧同名输入接口 =====

func test_detect_bits_are_mirrored_to_right_circuit() -> void:
	#左侧机器人绑的电路带 detect_res_6 输入口；右侧铺同一套名字
	assert_true(_export_circuit(FILE_SPLIT, [
		[Vector2i(0, 7), IN_DEF, "detect_res_6"],
		[Vector2i(0, 6), WIRE_DEF],
		[Vector2i(1, 6), WIRE_DEF],
		[Vector2i(1, 5), OUT_DEF],
	]), "左侧电路没造出来（detect_res_6 -> move）")
	var shell: Node = await _boot()
	if shell == null:
		return
	var e = _spawn_left_robot(shell, Vector2i(5, 5))
	assert_not_null(e, "左侧机器人没放上")
	if e == null:
		return
	var sys = shell.left_scene.call("get_entity_system")
	assert_true(sys.bind_circuit(e, FILE_SPLIT), "左侧机器人绑电路失败")
	_load_right(shell, [
		[Vector2i(0, 7), IN_DEF, "detect_res_6"],
		[Vector2i(0, 6), WIRE_DEF],
		[Vector2i(1, 6), WIRE_DEF],
		[Vector2i(1, 5), OUT_DEF],
	])
	await wait_frames(1)
	var res_in = _in_build(shell, "detect_res_6")
	var out = _out_build(shell)
	assert_not_null(res_in, "右侧没有 detect_res_6 输入接口")
	assert_not_null(out, "右侧没有输出接口")
	if res_in == null or out == null:
		return
	#先停自动节拍（pause 会补发一次相位），再抬机器人的检测位：
	#这样「镜像之前是低的」与后面的变化才先后有序
	shell.left_tick.call("pause")
	assert_eq(int(res_in.level), 0, "镜像之前右侧数据位应当是低")
	e.bundle.set_input("detect_res_6", 1)
	#推一个相位：壳应当先把机器人的检测位镜过来，再按新电平求值
	shell.left_tick.call("tick_high")
	assert_eq(int(res_in.level), 1,
			"机器人的 detect_res_6 没镜到右侧输入接口（时序图有高电平、灯却不亮）")
	assert_eq(int(out.get("_display_level")), 1,
			"右侧电路没按镜像后的输入求值（灯泡不会亮）")
	#下一相位：机器人真实检测码是 0（前方空地），右侧要跟着落回低
	shell.left_tick.call("tick_low")
	assert_eq(int(res_in.level), 0, "机器人检测位落回低，右侧要跟着落回低")
	assert_eq(int(out.get("_display_level")), 0, "右侧输出没跟着落回低")


# ===== 5. 暂停-应用闭环 =====

func test_edit_pauses_left_and_apply_rebinds() -> void:
	assert_true(_make_move_circuit(FILE_SPLIT), "起点电路 clk->move 没造出来")
	var shell: Node = await _boot()
	if shell == null:
		return
	var e = _spawn_left_robot(shell, Vector2i(5, 5))
	assert_not_null(e, "左侧机器人没放上")
	assert_true(shell.left_scene.call("get_entity_system").bind_circuit(e, FILE_SPLIT),
			"左侧机器人绑电路失败")
	assert_true((e.bundle.output_names() as Array).has("move"), "前置条件：现在是 clk->move")

	#玩家在右侧把这条电路改成 clk->rotation（改结构即暂停）
	_load_right(shell, [
		[Vector2i(0, 7), IN_DEF],
		[Vector2i(0, 6), WIRE_DEF],
		[Vector2i(1, 6), WIRE_DEF],
		[Vector2i(1, 5), OUT_DEF, "rotation"],
	])
	#放置/删除元件的路径就是调这一句（sw_build_layer_system._mark_circuit_edited）
	SESSION.mark_circuit_edited(FILE_SPLIT)
	#壳的 _process 每帧轮询这个标记；headless 用例直接调同一个方法（同一段逻辑）
	assert_true(bool(shell.call("check_circuit_edited")), "壳没认出「电路结构改过」")
	assert_false(bool(shell.call("check_circuit_edited")), "已经暂停了不该重复动作")
	assert_false(bool(shell.left_tick.get("enabled")), "右侧改了结构，左侧应当立刻停拍")
	var apply_btn: Button = shell.get_node("TopBar/Bar/HBox/ApplyBtn")
	var status: Label = shell.get_node("TopBar/Bar/HBox/Status")
	assert_false(apply_btn.disabled, "改结构后「应用到机器人」应当可点")
	assert_true(status.text.contains("暂停"), "顶栏没提示机器人已暂停：" + status.text)

	apply_btn.pressed.emit()
	var names: Array = e.bundle.output_names()
	assert_true(names.has("rotation"), "应用到机器人后没按最新电路重绑")
	assert_false(names.has("move"), "应用后还挂着旧电路的接口")
	assert_true(bool(shell.left_tick.get("enabled")), "应用后节拍应当恢复运行")
	assert_true(apply_btn.disabled, "应用完成后按钮该置灰")
	assert_eq(SESSION.edited_save, "", "应用后「结构改过」标记要被取走")
	#同名文件确实被重新导出成新结构
	var info: Dictionary = CIR_MANAGER.summarize(FILE_SPLIT)
	assert_true((info.get("outputs", []) as Array).has("rotation"),
			"应用后 .swcir 里还是旧结构")


# 没有可导出的接口电路时不能恢复运行（否则机器人会拿着旧电路继续跑）
func test_apply_without_exportable_circuit_keeps_paused() -> void:
	assert_true(_make_move_circuit(FILE_SPLIT), "起点电路没造出来")
	var shell: Node = await _boot()
	if shell == null:
		return
	var e = _spawn_left_robot(shell, Vector2i(6, 6))
	assert_not_null(e)
	assert_true(shell.left_scene.call("get_entity_system").bind_circuit(e, FILE_SPLIT))
	#右侧把接口全删掉：没有任何可导出的接口电路
	_load_right(shell, [])
	SESSION.mark_circuit_edited(FILE_SPLIT)
	shell.call("check_circuit_edited")
	var apply_btn: Button = shell.get_node("TopBar/Bar/HBox/ApplyBtn")
	apply_btn.pressed.emit()
	assert_false(bool(shell.left_tick.get("enabled")), "导不出电路时不该把节拍恢复")
	var status: Label = shell.get_node("TopBar/Bar/HBox/Status")
	assert_true(status.text.contains("接口"), "顶栏没说明为什么应用失败：" + status.text)


# ===== 6. 退出兜底：不点应用直接返回，也要按最新结构导出 =====

func test_exit_without_apply_exports_latest_structure() -> void:
	assert_true(_make_move_circuit(FILE_SPLIT), "起点电路 clk->move 没造出来")
	var packed: PackedScene = load(SPLIT_SCENE_PATH)
	if packed == null:
		assert_not_null(packed, "分屏壳加载失败")
		return
	#这条用例要自己控制释放时机，不用 add_child_autofree
	var shell: Node = packed.instantiate()
	add_child(shell)
	await wait_frames(3)
	_load_right(shell, [
		[Vector2i(0, 7), IN_DEF],
		[Vector2i(0, 6), WIRE_DEF],
		[Vector2i(1, 6), WIRE_DEF],
		[Vector2i(1, 5), OUT_DEF, "rotation"],
	])
	SESSION.mark_circuit_edited(FILE_SPLIT)
	await wait_frames(2)
	#不点「应用到机器人」，直接返回机器人场景（整棵分屏壳被释放）
	shell.free()
	await wait_frames(1)

	var info: Dictionary = CIR_MANAGER.summarize(FILE_SPLIT)
	assert_true((info.get("outputs", []) as Array).has("rotation"),
			"退出分屏时没按最新结构导出 .swcir")
	assert_eq(SESSION.split_mode, false, "退出后 split_mode 没复位")
	assert_eq(SESSION.edited_save, "", "退出后「结构改过」标记没清")
	#左侧退出时会把机器人状态落盘，回机器人场景才能把机器人摆回原位
	assert_true(FileAccess.file_exists(STATE_PATH), "退出分屏时没把机器人状态落盘")


# ===== 7. 修改电路：「不重载机器人界面」接管现成场景 + 展开动画 =====

# 起一个「正在玩的」机器人场景（模拟主场景已经跑起来的样子）
func _boot_robot() -> Node:
	var packed: PackedScene = load(ROBOT_SCENE_PATH)
	assert_not_null(packed, "机器人场景加载失败: " + ROBOT_SCENE_PATH)
	if packed == null:
		return null
	var robot: Node = packed.instantiate()
	add_child_autofree(robot)
	await wait_frames(3)
	return robot


# 在机器人场景里摆一台机器人（走手持落子那条真实链路）
func _spawn_in(robot: Node, cell: Vector2i):
	var lm := robot.get_node("SWLayerManager") as SWLayerManager
	lm.holdSystem.hold_idle_builds.emit([], [cell * GRID], false)
	return robot.call("get_entity_system").get_entity_at(cell * GRID)


# 让现成的机器人场景进分屏。动画关掉（headless 等 0.35s 等于白烧二十多帧），
# 并顺手把 _ready 里已经起跑的入场 tween kill 掉，后面手调的几何断言才不会被它覆盖
func _enter_split(robot: Node) -> Node:
	assert_true(bool(robot.call("enter_split_mode")), "没能进分屏（接管机器人场景失败）")
	var shell = robot.get("_split_shell")
	assert_not_null(shell, "机器人场景没记下所在的分屏壳")
	if shell == null:
		return null
	#壳是在 enter_split_mode 里挂到本测试节点下的，用完必须一起回收：
	#留着的话它的子场景会跟下一个用例新建的场景混在同一个“场景根”里，
	#SWLayerManager 按组收图层时会把它们全收进来（系统名重复报错）
	autofree(shell)
	shell.set("anim_sec", 0.0)
	shell.call("play_intro")
	await wait_frames(1)
	return shell


# 点「修改电路」不能再重建机器人场景：机器人/层系统/选中状态都得留着
func test_edit_circuit_reuses_running_robot_scene() -> void:
	assert_true(_make_move_circuit(FILE_SPLIT), "电路档没造出来")
	var robot: Node = await _boot_robot()
	if robot == null:
		return
	var e = _spawn_in(robot, Vector2i(8, 8))
	assert_not_null(e, "机器人没摆上")
	var shell: Node = await _enter_split(robot)
	if shell == null:
		return
	assert_same(shell.get("left_scene"), robot,
			"分屏壳没有接管正在跑的机器人场景（又重新加载了一份）")
	var left_vp: SubViewport = shell.get_node("PaneRoot/LeftPane/LeftView")
	assert_true(left_vp.is_ancestor_of(robot), "机器人场景没搬进左侧视口")
	#搬家会触发一次 _exit_tree：图层系统必须还接得上（重入树不会再走 _ready）
	var lm := robot.get_node("SWLayerManager") as SWLayerManager
	assert_not_null(lm.get_layer_system("SWEntityLayer"),
			"接管后图层系统表被清空了")
	var sys = robot.call("get_entity_system")
	assert_not_null(sys, "接管后实体系统丢了")
	assert_eq(int(sys.call("get_entity_count")), 1, "接管后机器人没了")
	assert_not_null(sys.get_entity_at(Vector2i(8, 8) * GRID), "接管后机器人换了位置")


# 展开动画：起点机器人界面占满全屏、电路界面整块在窗口右边缘外；终点左右各半
func test_split_intro_geometry() -> void:
	var robot: Node = await _boot_robot()
	if robot == null:
		return
	var shell: Node = await _enter_split(robot)
	if shell == null:
		return
	var pane_root: Control = shell.get_node("PaneRoot")
	pane_root.size = Vector2(1280.0, 720.0)
	var left_pane: Control = shell.get_node("PaneRoot/LeftPane")
	var right_pane: Control = shell.get_node("PaneRoot/RightPane")
	#入场起点
	shell.call("_set_intro", 0.0)
	assert_almost_eq(left_pane.size.x, 1280.0, 0.5, "入场起点机器人界面不是全屏")
	assert_true(right_pane.position.x >= 1279.5,
			"入场起点电路界面不在窗口右侧外（x=%f）" % right_pane.position.x)
	#终点
	shell.call("_set_intro", 1.0)
	assert_almost_eq(left_pane.size.x + 8.0 + right_pane.size.x, 1280.0, 1.0,
			"终点没铺成左右各半")
	assert_true(right_pane.position.x < 1279.5, "终点电路界面还在屏幕外")
	assert_almost_eq(left_pane.size.x, right_pane.size.x, 10.0, "左右没大致各半")


# 点「返回」：机器人场景原路搬回去，不重建、不读存档；壳与右侧电路释放
func test_back_returns_same_robot_scene() -> void:
	var robot: Node = await _boot_robot()
	if robot == null:
		return
	var e = _spawn_in(robot, Vector2i(9, 9))
	assert_not_null(e)
	var shell: Node = await _enter_split(robot)
	if shell == null:
		return
	var back: Button = shell.get_node("TopBar/Bar/HBox/BackBtn")
	back.pressed.emit()
	await wait_frames(3)
	assert_false(SESSION.split_mode, "返回后 split_mode 没复位")
	assert_same(robot.get_parent(), self, "机器人场景没搬回原来的宿主节点")
	assert_true(robot.get("_split_shell") == null, "机器人场景还记着旧的分屏壳")
	assert_eq(int(robot.call("get_entity_system").call("get_entity_count")), 1,
			"返回后机器人丢了")
	assert_not_null(robot.call("get_entity_system").get_entity_at(Vector2i(9, 9) * GRID),
			"返回后机器人换了位置")
	#分屏时藏起来的入口要重新露出来（机器人场景是原样留下来的，不重置就永远消失）
	var hud = robot.get("sw_layer_manager").get("hudLayer")
	assert_not_null(hud, "返回后 HUD 不见了")
	if hud != null:
		var logic_btn: Button = hud.call("get_logic_scene_button")
		assert_true(logic_btn.visible, "返回全屏后「电路场景」按钮还是隐的（分屏模式没撤掉）")
		var edit_btn = hud.get("_bind_edit_btn")
		assert_true(edit_btn != null and (edit_btn as Button).visible,
				"返回全屏后「修改电路」按钮还是隐的（分屏模式没撤掉）")
		var expr_panel = hud.get("_expr_panel")
		assert_almost_eq((expr_panel as Control).offset_top, 12.0, 0.5,
				"返回全屏后表达式面板还让着分屏顶栏那一条")
	var perf = robot.get_node_or_null("SWPerformanceMonitor")
	if perf != null:
		var stats = perf.get("stats_container")
		assert_almost_eq((stats as Control).offset_top, 0.0, 0.5,
				"返回全屏后性能面板还让着分屏顶栏那一条")
	assert_false(is_instance_valid(shell) and shell.is_inside_tree(), "分屏壳返回后没释放")
