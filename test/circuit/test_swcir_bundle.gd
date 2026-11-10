extends GutTest
# .swcir 导出 / 加载 / 纯逻辑跑拍（阶段 2 验收）。
#
# 标准电路（格子坐标，y 越小越靠上）：
#   ext_in(clk)@(0,5) → 非门@(0,4) → 电线 (0,3)(0,2)(0,1) → 输出接口 move@(0,0)
#                                        └─ 电线 (1,1) → 输出接口 rotation@(2,1)
#   两条输出读的都是非门的输出：clk=0 → 输出 1；clk=1 → 输出 0。
#
# 验收点：
#   1. 含接口电路的存档导出同名 .swcir，字段/接口名/可用性正确；普通存档不生成文件；
#   2. round-trip：netlist 各扁平表经 JSON 往返逐字段一致（JSON 数字是浮点，必须无精度损失）；
#   3. 加载出的 bundle 与实体电路逐拍对拍（clk 交替 4 拍）；
#   4. 多电路文件 / 缺接口的单电路：都算可用，load_bundle 一拍把每条电路都跑一遍。
# 跑法：godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://test/circuit -gprefix test_swcir_bundle -gexit

const MANAGER := preload("res://circuit/sw_cir_manager.gd")

const IN_DEF: SWBuildDefine = preload("res://res/输入接口.tres")
#输出接口已合并为单一定义：move / rotation 只是实例上的 io_name
const OUT_DEF: SWBuildDefine = preload("res://res/输出接口.tres")
const NOT_DEF: SWBuildDefine = preload("res://res/非门.tres")
const WIRE_DEF: SWBuildDefine = preload("res://res/电线A.tres")
const LED_DEF: SWBuildDefine = preload("res://res/灯泡.tres")
const SWITCH_DEF: SWBuildDefine = preload("res://res/开关.tres")

const GRID: Vector2i = SwDefine.GRID_SIZE

# 各用例各用各的文件名，互不干扰；after_each 统一清掉
const FILE_MAIN := "_swcir_test_main"
const FILE_CLK_ONLY := "_swcir_test_clk_only"
const FILE_TWO := "_swcir_test_two"
const FILE_PLAIN := "_swcir_test_plain"
const FILE_SRC := "_swcir_test_src"
const FILE_MIX := "_swcir_test_mix"

const ALL_FILES := [FILE_MAIN, FILE_CLK_ONLY, FILE_TWO, FILE_PLAIN, FILE_SRC, FILE_MIX]

var _mgr: SWBuildManager = null
var _ctrl: SWCircuitControl = null
var _in: SWBuildItemDefine = null
var _move: SWBuildItemDefine = null
var _rot: SWBuildItemDefine = null


func after_each() -> void:
	for n: String in ALL_FILES:
		MANAGER.delete_file(n)


# ===== 场景搭建 =====

func _new_ctrl() -> void:
	_mgr = SWBuildManager.new()
	_ctrl = SWCircuitControl.new()
	_ctrl.setBuildManager(_mgr)
	_ctrl.gpu_backend_enabled = false


# 按 [格子坐标, 定义, 可选 io_name] 列表放元件并建电路，返回建造对象数组
func _place(specs: Array) -> Array[SWBuildItemDefine]:
	var all: Array[SWBuildItemDefine] = []
	for s: Array in specs:
		var build := SwDefine.SWBuildCreator((s[0] as Vector2i) * GRID, s[1], 0)
		#输出接口合并后名字靠实例属性区分（第三个元素写名字）
		if s.size() > 2:
			build.set("io_name", str(s[2]))
		if not _mgr.addBuild(build):
			push_error("放置失败: %s @ %s" % [s[1].buildName, str(s[0])])
			continue
		all.append(build)
	_ctrl.updateBuildCircuit(all)
	return all


# 标准电路：clk → 非门 → {move, rotation}
func _build_standard() -> void:
	_new_ctrl()
	var all := _place([
		[Vector2i(0, 5), IN_DEF],
		[Vector2i(0, 4), NOT_DEF],
		[Vector2i(0, 3), WIRE_DEF],
		[Vector2i(0, 2), WIRE_DEF],
		[Vector2i(0, 1), WIRE_DEF],
		[Vector2i(0, 0), OUT_DEF],
		[Vector2i(1, 1), WIRE_DEF],
		[Vector2i(2, 1), OUT_DEF, "rotation"],
	])
	assert_eq(all.size(), 8, "标准电路没放齐")
	_in = all[0]
	_move = all[5]
	_rot = all[7]


# 只有输入接口、没有任何输出接口的单电路
func _build_clk_only() -> void:
	_new_ctrl()
	var all := _place([
		[Vector2i(0, 3), IN_DEF],
		[Vector2i(0, 2), WIRE_DEF],
		[Vector2i(0, 1), NOT_DEF],
		[Vector2i(0, 0), LED_DEF],
	])
	assert_eq(all.size(), 4)


# 两条互不相连、各自带接口的电路（输出分别命名为 move / rotation）
func _build_two_circuits() -> void:
	_new_ctrl()
	_place([
		[Vector2i(0, 3), IN_DEF],
		[Vector2i(0, 2), WIRE_DEF],
		[Vector2i(0, 1), OUT_DEF],
	])
	_place([
		[Vector2i(20, 3), IN_DEF],
		[Vector2i(20, 2), WIRE_DEF],
		[Vector2i(20, 1), OUT_DEF, "rotation"],
	])
	_ctrl.updateBuildCircuit(_mgr.getAllBuilds())


# 一条 clk 驱动的时序电路 + 一条没有 clk 的组合电路（开关 → detect_sig_0）：
# 组合电路没有时钟也必须每拍跟着跑，否则机器人的方向选择信号永远是冷的
func _build_clk_plus_combo(on: bool) -> void:
	_new_ctrl()
	_place([
		[Vector2i(0, 5), IN_DEF],
		[Vector2i(0, 4), NOT_DEF],
		[Vector2i(0, 3), WIRE_DEF],
		[Vector2i(0, 2), WIRE_DEF],
		[Vector2i(0, 1), WIRE_DEF],
		[Vector2i(0, 0), OUT_DEF],
	])
	var combo := _place([
		[Vector2i(20, 3), SWITCH_DEF],
		[Vector2i(20, 2), WIRE_DEF],
		[Vector2i(20, 1), OUT_DEF, "detect_sig_0"],
	])
	combo[0].call("onPressed", on)
	_ctrl.updateBuildCircuit(_mgr.getAllBuilds())


# 没有任何接口元件的普通电路
func _build_plain() -> void:
	_new_ctrl()
	_place([
		[Vector2i(0, 2), NOT_DEF],
		[Vector2i(0, 1), WIRE_DEF],
		[Vector2i(0, 0), LED_DEF],
	])


# 开关当电平源：一条连通电路里 clk 与开关汇到同一根线（线与）→ move = rotation = clk & 开关。
# 摆位约束：开关/非门/输入接口的输出引脚都朝上，所以「开关在下、线在上」。
func _build_switch_move(on: bool) -> void:
	_new_ctrl()
	var all := _place([
		[Vector2i(0, 4), IN_DEF],
		[Vector2i(0, 3), WIRE_DEF],
		[Vector2i(0, 2), WIRE_DEF],
		[Vector2i(0, 1), WIRE_DEF],
		[Vector2i(0, 0), OUT_DEF],
		[Vector2i(1, 3), SWITCH_DEF],
		[Vector2i(1, 2), WIRE_DEF],
		[Vector2i(2, 2), OUT_DEF, "rotation"],
	])
	assert_eq(all.size(), 8, "开关电路没放齐")
	all[5].call("onPressed", on)


# 让实体电路与 bundle 各自跑一拍（clk = lv）
func _step(lv: int) -> void:
	_in.call("setLevel", lv)
	_ctrl.buildSignalChanged(_in)


func _names(list) -> Array:
	var out: Array = []
	for e in list:
		out.append(str(e.get("name", "")))
	return out


# ===== 1. 导出 =====

func test_export_writes_single_circuit_file() -> void:
	_build_standard()
	var path: String = MANAGER.export_all(FILE_MAIN, _mgr.getAllBuilds())
	assert_ne(path, "", "含接口电路的存档必须生成 .swcir")
	assert_true(FileAccess.file_exists(path), "文件没落盘: " + path)

	var data: Dictionary = MANAGER.load_file(FILE_MAIN)
	assert_false(data.is_empty(), "读不回刚导出的文件")
	assert_eq(int(data.get("version", 0)), 1, "文件版本号不对")
	assert_eq(str(data.get("source_save", "")), FILE_MAIN, "source_save 没写对")

	var circs: Array = data.get("circuits", [])
	assert_eq(circs.size(), 1, "同一条连通电路应当只导出 1 条")
	var c: Dictionary = circs[0]
	assert_eq(_names(c.get("inputs", [])), ["clk"], "输入接口清单不对")
	assert_eq(_names(c.get("outputs", [])), ["move", "rotation"], "输出接口清单不对")
	# 接口记录必须带得上 net：dev 下标 + 所连 net 的 netId
	for rec: Dictionary in c.get("outputs", []):
		assert_gt(int(rec.get("dev", -1)), -1, "输出接口缺 dev 下标")
		assert_gt((rec.get("nets", []) as Array).size(), 0,
				"%s 没有记录所连 net" % str(rec.get("name")))
		assert_eq(int(rec.get("net_id", -1)), int(rec.get("nets", [])[0]),
				"net_id 与 nets[0] 不一致")

	var info: Dictionary = MANAGER.summarize(FILE_MAIN)
	assert_true(bool(info.get("usable", false)),
			"单电路文件应当可用：%s" % str(info.get("reason")))
	assert_eq(int(info.get("circuit_count", 0)), 1)


func test_plain_save_creates_no_file() -> void:
	_build_plain()
	var path: String = MANAGER.export_all(FILE_PLAIN, _mgr.getAllBuilds())
	assert_eq(path, "", "没有接口元件的存档不该生成 .swcir")
	assert_false(MANAGER.file_exists(FILE_PLAIN), "不该有文件残留")


# 曾经有接口电路、后来把接口删了：旧 .swcir 必须被清掉，不能留着上一次的电路
func test_export_over_old_file_removes_it() -> void:
	_build_standard()
	assert_ne(MANAGER.export_all(FILE_PLAIN, _mgr.getAllBuilds()), "")
	assert_true(MANAGER.file_exists(FILE_PLAIN))
	_build_plain()
	assert_eq(MANAGER.export_all(FILE_PLAIN, _mgr.getAllBuilds()), "")
	assert_false(MANAGER.file_exists(FILE_PLAIN), "旧电路文件没被删掉")


# ===== 2. netlist 字段往返（JSON 数字是浮点，不能掉精度）=====

func test_netlist_survives_json_roundtrip() -> void:
	_build_standard()
	var ex := SWNetlistExport.new()
	var nl: SWNetlist = ex.export_netlist(_mgr.getAllBuilds())
	assert_gt(nl.dev_count(), 0, "导出的网表是空的")

	var text: String = JSON.stringify(nl.to_dict())
	assert_false(text.is_empty())
	var back: SWNetlist = SWNetlist.from_dict(JSON.parse_string(text))
	assert_eq(back.dev_kind, nl.dev_kind, "dev_kind 往返不一致")
	assert_eq(back.dev_out_mask, nl.dev_out_mask, "dev_out_mask 往返不一致")
	assert_eq(back.dev_in_mask, nl.dev_in_mask, "dev_in_mask 往返不一致")
	assert_eq(back.dev_pins, nl.dev_pins, "dev_pins 往返不一致")
	assert_eq(back.dev_clk_net, nl.dev_clk_net, "dev_clk_net 往返不一致")
	assert_eq(back.dev_d_net, nl.dev_d_net, "dev_d_net 往返不一致")
	assert_eq(back.dev_role, nl.dev_role, "dev_role 往返不一致")
	assert_eq(back.dev_label, nl.dev_label, "dev_label 往返不一致")
	assert_eq(back.name_table, nl.name_table, "name_table 往返不一致")
	assert_eq(back.net_ids, nl.net_ids, "net_ids 往返不一致")
	assert_eq(back.net_driver_flat, nl.net_driver_flat, "net_driver_flat 往返不一致")
	assert_eq(back.net_driver_offs, nl.net_driver_offs, "net_driver_offs 往返不一致")
	assert_eq(back.net_load_flat, nl.net_load_flat, "net_load_flat 往返不一致")
	assert_eq(back.net_load_offs, nl.net_load_offs, "net_load_offs 往返不一致")
	assert_eq(back.net_id_to_index, nl.net_id_to_index, "net_id_to_index 没重建")
	assert_eq(back.describe(), nl.describe(), "规模摘要不一致")

	# 角色与名字：接口元件必须在往返后仍然认得出来
	var roles: Array = []
	for dev in nl.dev_role.size():
		if nl.dev_role[dev] != SWNetlist.ROLE_INTERNAL:
			roles.append([nl.role_of(dev), nl.label_name(dev)])
	assert_eq(roles.size(), 3, "标准电路应有 3 个接口（clk/move/rotation）")
	assert_true(roles.has([SWNetlist.ROLE_INPUT, "clk"]), "clk 角色/名字丢失")
	assert_true(roles.has([SWNetlist.ROLE_OUTPUT, "move"]), "move 角色/名字丢失")
	assert_true(roles.has([SWNetlist.ROLE_OUTPUT, "rotation"]), "rotation 角色/名字丢失")


# ===== 3. 加载出的 bundle 与实体电路逐拍对拍 =====

func test_loaded_bundle_matches_live_circuit() -> void:
	_build_standard()
	assert_ne(MANAGER.export_all(FILE_MAIN, _mgr.getAllBuilds()), "")
	var bundle = MANAGER.load_bundle(FILE_MAIN)
	assert_not_null(bundle, "单电路文件必须能加载")
	if bundle == null:
		return
	assert_true(bundle.has_input("clk"), "bundle 没有 clk 写入口")
	assert_true(bundle.has_output("move"), "bundle 没有 move 读出口")
	assert_true(bundle.has_output("rotation"), "bundle 没有 rotation 读出口")

	for k in 4:
		var lv: int = k % 2
		_step(lv)
		bundle.set_input("clk", lv)
		bundle.tick()
		var live_move: int = int(_move.call("outputLevel"))
		var live_rot: int = int(_rot.call("outputLevel"))
		assert_eq(bundle.output_level("move"), live_move,
				"第 %d 拍 move 与实体电路不一致" % k)
		assert_eq(bundle.output_level("rotation"), live_rot,
				"第 %d 拍 rotation 与实体电路不一致" % k)
		# 实体电路里 clk → 非门 → 输出接口，所以输出必须是 clk 的反
		assert_eq(live_move, 1 - lv, "第 %d 拍 clk=%d 时实体电路 move 应为 %d" % [k, lv, 1 - lv])
		assert_eq(bundle.output_level("move"), 1 - lv, "第 %d 拍 bundle move 计算错误" % k)

	# 写不存在的接口名不能炸，只是忽略
	bundle.set_input("no_such", 1)
	assert_eq(bundle.output_level("no_such"), 0)


# ===== 3.5 源电平随文件走 =====
# 机器人侧拿不到世界，开关/按钮的电平必须存在 .swcir 里。
# 不存的话加载后所有内部源都是 0：拿开关当常量 1 的电路（带使能的计数器）永远输出 0。
func test_export_keeps_source_levels() -> void:
	_build_switch_move(true)
	assert_ne(MANAGER.export_all(FILE_SRC, _mgr.getAllBuilds()), "")
	var data: Dictionary = MANAGER.load_file(FILE_SRC)
	var c: Dictionary = (data.get("circuits", []) as Array)[0]
	var srcs: Array = c.get("sources", [])
	assert_gt(srcs.size(), 0, "文件里没有 sources 段")
	var highs: Array = []
	for e: Dictionary in srcs:
		if int(e.get("level", 0)) != 0:
			highs.append(int(e.get("dev", -1)))
	assert_eq(highs.size(), 1, "按下的那个开关没有记成 1：%s" % str(srcs))

	# 加载后写 clk=1 跑一拍：move 必须只由开关电平决定（没存开关电平就恒为 0）
	var bundle = MANAGER.load_bundle(FILE_SRC)
	assert_not_null(bundle)
	if bundle == null:
		return
	bundle.set_input("clk", 1)
	bundle.tick()
	assert_eq(bundle.output_level("move"), 1, "开关为 1 的电路加载后 move 应当为 1")


func test_source_off_exports_zero() -> void:
	_build_switch_move(false)
	assert_ne(MANAGER.export_all(FILE_SRC, _mgr.getAllBuilds()), "")
	var bundle = MANAGER.load_bundle(FILE_SRC)
	assert_not_null(bundle)
	if bundle == null:
		return
	bundle.set_input("clk", 1)
	bundle.tick()
	assert_eq(bundle.output_level("move"), 0, "开关没按下时 move 应当是 0")


# ===== 4. 多电路 / 多接口：都算可用，一拍全跑 =====

func test_two_circuits_file_is_usable_and_runs_all() -> void:
	_build_two_circuits()
	assert_ne(MANAGER.export_all(FILE_TWO, _mgr.getAllBuilds()), "")
	var data: Dictionary = MANAGER.load_file(FILE_TWO)
	assert_eq((data.get("circuits", []) as Array).size(), 2, "两条电路必须都进文件")

	var info: Dictionary = MANAGER.summarize(FILE_TWO)
	assert_eq(int(info.get("circuit_count", 0)), 2)
	assert_true(bool(info.get("usable", false)),
			"多电路文件现在算可用：%s" % str(info.get("reason")))
	assert_eq(str(info.get("reason", "")), "", "可用文件不该带置灰理由")
	# 摘要里的接口清单是所有电路的并集
	assert_eq(info.get("outputs", []), ["move", "rotation"], "接口摘要不是并集")

	var pack = MANAGER.load_bundle(FILE_TWO)
	assert_not_null(pack, "多电路文件必须能加载")
	if pack == null:
		return
	assert_eq(int(pack.size()), 2, "两条电路都要装进复合 bundle")
	assert_eq(pack.output_names(), ["move", "rotation"], "输出名要合并两条电路")
	# 一拍把两条电路都跑一遍：clk=1 时 move 与 rotation 同时为 1
	pack.set_input("clk", 1)
	pack.tick()
	assert_eq(pack.output_level("move"), 1, "第一条电路没被跑到")
	assert_eq(pack.output_level("rotation"), 1, "第二条电路没被跑到")
	pack.set_input("clk", 0)
	pack.tick()
	assert_eq(pack.output_level("move"), 0, "clk 回落后第一条电路输出没跟着变")
	assert_eq(pack.output_level("rotation"), 0, "clk 回落后第二条电路输出没跟着变")


# 组合电路（没接 clk）也要每拍跑：只要电路里有接口元件，机器人就得跑它
func test_combo_circuit_without_clk_also_runs() -> void:
	_build_clk_plus_combo(true)
	assert_ne(MANAGER.export_all(FILE_MIX, _mgr.getAllBuilds()), "")
	var data: Dictionary = MANAGER.load_file(FILE_MIX)
	assert_eq((data.get("circuits", []) as Array).size(), 2, "应当有两条电路")
	var info: Dictionary = MANAGER.summarize(FILE_MIX)
	assert_true(bool(info.get("usable", false)),
			"多电路文件应当可用：%s" % str(info.get("reason")))
	assert_eq(info.get("outputs", []), ["detect_sig_0", "move"], "接口清单取并集")

	var pack = MANAGER.load_bundle(FILE_MIX)
	assert_not_null(pack, "多电路文件必须能加载")
	if pack == null:
		return
	assert_true(pack.has_output("detect_sig_0"), "组合电路的输出没被认出来")
	# 组合电路不接 clk：一拍里同样要跑，输出直接跟着开关（源电平存在文件里）
	pack.set_input("clk", 0)
	pack.tick()
	assert_eq(pack.output_level("detect_sig_0"), 1, "没有 clk 的组合电路没跟着跑")
	assert_eq(pack.output_level("move"), 1, "clk 那条电路的输出丢了")


# 只有一个输入接口、零个输出接口的单电路：接口名不再参与可用性判定，照样可用
func test_missing_outputs_is_still_usable() -> void:
	_build_clk_only()
	assert_ne(MANAGER.export_all(FILE_CLK_ONLY, _mgr.getAllBuilds()), "")
	var info: Dictionary = MANAGER.summarize(FILE_CLK_ONLY)
	assert_eq(int(info.get("circuit_count", 0)), 1, "这里应当只有一条电路")
	assert_true(bool(info.get("usable", false)),
			"缺 move/rotation 的文件现在也算可用：%s" % str(info.get("reason")))
	assert_eq(str(info.get("reason", "")), "", "可用文件不该带置灰理由")
	assert_false((info.get("outputs", []) as Array).has("move"), "这条电路确实没有 move")
	assert_not_null(MANAGER.load_bundle(FILE_CLK_ONLY), "单电路文件应当能加载成 bundle")


func test_list_files_sees_exported_circuits() -> void:
	_build_standard()
	MANAGER.export_all(FILE_MAIN, _mgr.getAllBuilds())
	_build_clk_only()
	MANAGER.export_all(FILE_CLK_ONLY, _mgr.getAllBuilds())
	var files: Array[String] = MANAGER.list_files()
	assert_true(files.has(FILE_MAIN), "列举里没有 %s：%s" % [FILE_MAIN, str(files)])
	assert_true(files.has(FILE_CLK_ONLY), "列举里没有 %s" % FILE_CLK_ONLY)
