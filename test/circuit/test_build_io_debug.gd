extends GutTest
# 电路场景的「接口调试」与「改结构→停机重载」契约：
#   1. 外部输入/输出接口在加载后登记进 build 层的调试注册表；
#   2. tick 每半拍翻转外部输入里名叫 clk 的那一个，并把翻转的口当本轮求值种子
#      （否则电路场景里没有机器人喂 clk，一张没有时钟的电路一步都不会走）；
#      数据输入口 detect_res_* 不碰：它们是机器人每拍写的真实检测码，
#      在这里扫方波会让解码电路和 8 个元件一起乱闪；
#   3. 输出口读到几就把几写进自己的「自采样槽」——元件主体按调色板变色，
#      实例缓冲零写入（这是玩家唯一能看见这个口电平的地方）；
#   4. 放置/删除会记住「这个存档的电路结构改过」，退出电路场景时据此强制导出
#      .swcir（不管玩家有没有点保存），机器人场景回来才能按最新电路重绑。
# 跑法：godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://test/circuit -gprefix test_build_io_debug -gexit

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const SESSION := preload("res://core/manager/sw_session.gd")
const CIR_MANAGER := preload("res://circuit/sw_cir_manager.gd")

const GRID: Vector2i = SwDefine.GRID_SIZE
#临时电路文件名：用例自己写、自己删，不要碰玩家的存档
const TMP_SAVE := "_tmp_io_debug"

# 起电路场景并摆一张最小电路：输入接口（在下，输出口朝上）直连输出接口（在上）。
# 两个元件相邻即可接通，与 test_ext_io_port 里的摆法一致
func _boot_pair() -> Array:
	SESSION.reset()
	var harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)
	await harness.boot_game()
	var data: Dictionary = {"builds": [
		{"pos": {"x": 0, "y": GRID.y}, "def": "输入接口", "rot": 0, "state": {}},
		{"pos": {"x": 0, "y": 0}, "def": "输出接口", "rot": 0,
				"state": {"io_name": "move"}},
	]}
	harness.build_layer.load_save_data(data)
	await get_tree().process_frame
	var sys: SWBuildLayerSystem = harness.layer_manager.buildSystem
	assert_not_null(sys, "建筑层系统要建起来")
	#自采样槽在烘焙渲染部件时才分配：headless 下必须把区块真正建出来
	harness.force_load_all_chunks()
	harness.flush_draw_queue()
	return [harness, sys]

func _in_build(harness) -> SWBuildItemDefine:
	return harness.get_build(Vector2i(0, GRID.y))

func _out_build(harness) -> SWBuildItemDefine:
	return harness.get_build(Vector2i.ZERO)

# 1) 加载即登记：两张注册表各有一项，且输入口不是靠时钟注册表蹭进来的
func test_ports_registered_on_load() -> void:
	var r = await _boot_pair()
	var harness = r[0]
	var sys: SWBuildLayerSystem = r[1]
	var in_build := _in_build(harness)
	var out_build := _out_build(harness)
	assert_not_null(in_build, "输入接口要在建筑表里")
	assert_not_null(out_build, "输出接口要在建筑表里")
	assert_eq(sys.io_input_arr.size(), 1, "外部输入口要登记进调试注册表")
	assert_eq(sys.io_output_arr.size(), 1, "外部输出口要登记进调试注册表")
	assert_true(sys.io_input_arr.has(in_build), "登记进来的必须是输入接口本身")
	assert_true(sys.io_output_arr.has(out_build))
	assert_false(sys.clockBuildArr.has(in_build), "接口不能被当成时钟")

# 2) 自采样槽：主体挂一个虚拟电平槽，且用的是帧槽空间（与真实 netId 天然隔离）
func test_self_tint_slot_allocated_from_frame_space() -> void:
	var r = await _boot_pair()
	var harness = r[0]
	var in_render = _in_build(harness).getRenderableCompoent()
	var out_render = _out_build(harness).getRenderableCompoent()
	assert_true(in_render.self_tint, "输入接口要开启自采样着色")
	assert_true(out_render.self_tint, "输出接口要开启自采样着色")
	var in_slot: int = in_render.getSelfTintSlot()
	var out_slot: int = out_render.getSelfTintSlot()
	assert_true(in_slot >= 0, "输入接口要拿到自采样槽，否则主体永远是死图标")
	assert_true(out_slot >= 0, "输出接口要拿到自采样槽")
	assert_ne(in_slot, out_slot, "每个接口各占一个槽")
	#帧槽从 MAX_NETS-1 向下分配，真实 netId 从 0 向上：两者永不相撞
	assert_gt(in_slot, SWSignalTexture.MAX_NETS - 256, "自采样槽必须落在帧槽区间里")

# 3) 半拍方波：到点就翻，没到点不翻；翻过的口作为本轮求值种子返回
func test_drive_inputs_toggles_on_half_beat() -> void:
	var r = await _boot_pair()
	var harness = r[0]
	var sys: SWBuildLayerSystem = r[1]
	var in_build := _in_build(harness)
	var before: int = int(in_build.level)
	assert_eq(before, 0, "读档缺省电平是 0")

	#还没到半拍：什么都不该发生
	sys._io_last_usec = Time.get_ticks_usec()
	var quiet: Array = sys._drive_io_inputs(Time.get_ticks_usec())
	assert_eq(quiet.size(), 0, "不到半拍不该翻电平，也不该当种子")
	assert_eq(int(in_build.level), before)

	#到半拍了：翻一次，并把这个口交回去当求值种子
	sys._io_last_usec = Time.get_ticks_usec() - sys.IO_HALF_USEC
	var seeds: Array = sys._drive_io_inputs(Time.get_ticks_usec())
	assert_eq(seeds.size(), 1, "翻过的输入口要当本轮求值种子")
	assert_eq(seeds[0], in_build, "种子就是这个输入接口")
	assert_eq(int(in_build.level), 1, "到半拍后电平要翻成 1")

# 4) 关掉调试开关：电平停在最后一次的值，不再翻
func test_interface_debug_can_be_switched_off() -> void:
	var r = await _boot_pair()
	var harness = r[0]
	var sys: SWBuildLayerSystem = r[1]
	var in_build := _in_build(harness)
	sys.interface_debug_enabled = false
	var frozen: int = int(in_build.level)
	for i in 3:
		sys._io_last_usec = Time.get_ticks_usec() - sys.IO_HALF_USEC
		assert_eq(sys._drive_io_inputs(Time.get_ticks_usec()).size(), 0)
	assert_eq(int(in_build.level), frozen, "关掉调试后输入口电平要冻住")
	sys.interface_debug_enabled = true

# 5) 整拍闭环：build 层每拍自己喂方波 → 输出口读到并显示在自己身上
func test_tick_drives_input_and_lights_output() -> void:
	var r = await _boot_pair()
	var harness = r[0]
	var sys: SWBuildLayerSystem = r[1]
	var in_build := _in_build(harness)
	var out_build := _out_build(harness)
	var before: int = int(in_build.level)
	#把计时器拨到「该翻了」，让系统自己的 tick 在下一帧完成这一次翻转 + 求值 + 显示
	sys._io_last_usec = Time.get_ticks_usec() - sys.IO_HALF_USEC
	for i in 4:
		await get_tree().process_frame
	var after: int = int(in_build.level)
	assert_ne(after, before, "build 层每拍要自动翻转外部输入口")
	assert_eq(int(out_build.get("_display_level")), after,
			"输出口要把本拍读到的电平显示在自己身上（%d）" % after)
	assert_eq(out_build.getRenderableCompoent().getSelfTintSlot() >= 0, true,
			"显示电平走的是自采样槽，实例缓冲零写入")

# 6) 结构改动标记：只有知道是哪个存档才记，取走即清
func test_mark_circuit_edited_needs_save_name() -> void:
	var r = await _boot_pair()
	var harness = r[0]
	var sys: SWBuildLayerSystem = r[1]
	assert_not_null(harness)
	assert_eq(SESSION.current_save_name, "")
	sys._mark_circuit_edited()
	assert_eq(SESSION.edited_save, "", "不知道存档名时不该留下标记")

	SESSION.current_save_name = TMP_SAVE
	sys._mark_circuit_edited()
	assert_eq(SESSION.edited_save, TMP_SAVE, "改过结构要记到会话里")
	assert_eq(SESSION.take_edited_save(), TMP_SAVE, "取走要拿到存档名")
	assert_eq(SESSION.edited_save, "", "取走即清，避免下次退出又重导一遍")

# 7) 退出电路场景：改过结构就按当前结构导出同名 .swcir（不等玩家保存）
func test_exit_exports_edited_circuit() -> void:
	var r = await _boot_pair()
	var harness = r[0]
	var sys: SWBuildLayerSystem = r[1]
	assert_not_null(sys)
	#脏数据清理：上一轮中断可能留下同名文件
	CIR_MANAGER.delete_file(TMP_SAVE)
	assert_false(CIR_MANAGER.file_exists(TMP_SAVE), "起点不该已经有文件")

	SESSION.current_save_name = TMP_SAVE
	sys._mark_circuit_edited()
	harness.scene.call("_export_edited_circuit")

	assert_true(CIR_MANAGER.file_exists(TMP_SAVE), "改过结构退出时必须导出电路文件")
	var info: Dictionary = CIR_MANAGER.summarize(TMP_SAVE)
	assert_true(bool(info["usable"]), "导出的文件要能直接绑给机器人: %s" % str(info["reason"]))
	assert_eq(int(info["circuit_count"]), 1, "一个接口电路分组 → 一条记录")
	assert_eq(info["inputs"], ["clk"], "输入接口名要进文件")
	assert_eq(info["outputs"], ["move"], "输出接口名要进文件")
	assert_eq(SESSION.edited_save, "", "导出后标记要清掉（退出路径不能重复导出）")

	CIR_MANAGER.delete_file(TMP_SAVE)

# 8) 没改结构就退出：不产生电路文件（存盘路径仍然只由「保存存档」负责）
func test_exit_without_edit_exports_nothing() -> void:
	var r = await _boot_pair()
	var harness = r[0]
	assert_not_null(harness)
	CIR_MANAGER.delete_file(TMP_SAVE)
	SESSION.current_save_name = TMP_SAVE
	harness.scene.call("_export_edited_circuit")
	assert_false(CIR_MANAGER.file_exists(TMP_SAVE), "没改结构不该写任何电路文件")

# 9) 数据位不参与方波：detect_res_* 是机器人写的检测码，电路场景里给它们扫方波只会乱闪
func test_data_inputs_are_not_clocked() -> void:
	SESSION.reset()
	var harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)
	await harness.boot_game()
	var data: Dictionary = {"builds": [
		{"pos": {"x": 0, "y": GRID.y}, "def": "输入接口", "rot": 0, "state": {}},
		{"pos": {"x": 0, "y": 0}, "def": "输出接口", "rot": 0,
				"state": {"io_name": "move"}},
		{"pos": {"x": 4 * GRID.x, "y": 4 * GRID.y}, "def": "输入接口", "rot": 0,
				"state": {"io_name": "detect_res_3"}},
	]}
	harness.build_layer.load_save_data(data)
	await get_tree().process_frame
	var sys: SWBuildLayerSystem = harness.layer_manager.buildSystem
	var clk_build := _in_build(harness)
	var data_build: SWBuildItemDefine = harness.get_build(Vector2i(4, 4) * GRID)
	assert_not_null(data_build, "数据位输入口要在建筑表里")
	assert_eq(str(data_build.get("io_name")), "detect_res_3")
	assert_eq(sys.io_input_arr.size(), 2, "两个输入口都要登记（登记不等于都喂方波）")

	#连翻 3 个半拍：只有 clk 该动，detect_res 必须一直停在 0
	for i in 3:
		sys._io_last_usec = Time.get_ticks_usec() - sys.IO_HALF_USEC
		var seeds: Array = sys._drive_io_inputs(Time.get_ticks_usec())
		assert_eq(seeds.size(), 1, "每半拍只该有 clk 口进种子")
		assert_eq(seeds[0], clk_build, "进种子的必须是 clk 口")
	assert_eq(int(clk_build.level), 1, "clk 口应当已经翻到高电平")
	assert_eq(int(data_build.level), 0, "detect_res_* 是数据位，不能跟着方波一起闪")

func after_each() -> void:
	SESSION.reset()
	CIR_MANAGER.delete_file(TMP_SAVE)
