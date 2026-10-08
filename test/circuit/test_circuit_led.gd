extends GutTest
# 电路 LED 状态集成测试
# 流程：运行游戏 -> 加载存档 -> 点击指定位置的按钮/开关 -> 断言若干灯泡亮灭是否正确。
#
# ┌────────────────────────────────────────────────────────────────────────┐
# │ 你需要填写的三处配置（都在本文件下方，标了 TODO）：                             │
# │   1) SAVE_NAME          要加载的存档名（对应 user://saves/<名字>.json）     │
# │   2) CLICK_ACTIONS      点击/设置哪些位置的开关、按钮                       │
# │   3) LED_EXPECTATIONS    期望某些位置的灯泡处于亮(HIGH)还是灭(LOW)           │
# └────────────────────────────────────────────────────────────────────────┘
#
# 位置一律用网格坐标 Vector2i（即建筑物的 buildAxisPos，通常是 128 的整数倍）。
# 若不确定坐标，可先用 print_builds_around() 打印存档里所有建筑物及其位置来定位。

# ===== TODO 1：填写存档名 =================================================
const SAVE_NAME := "加法器"   # 例如 "我的存档1"

# 用 preload 按路径引用测试台，避免依赖 class_name 的全局注册（新脚本需编辑器重扫才可见）。
const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")

var harness = null

func before_each() -> void:
	harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)

func after_each() -> void:
	if harness != null:
		harness.shutdown_game()
		harness = null

# 主测试：加载存档后按配置驱动电路并校验 LED 状态。
func test_led_states_after_interactions() -> void:
	if SAVE_NAME == "":
		pending("尚未填写 SAVE_NAME（存档名）")
		return

	await harness.boot_game()
	var data: Dictionary = await harness.load_save(SAVE_NAME)
	assert_false(data.is_empty(), "存档不存在或无法加载: " + SAVE_NAME)

	# ===== TODO 2：填写点击/设置动作 =======================================
	# 每一项是一个 Dictionary：
	#   { "pos": Vector2i, "op": "click" | "switch_on" | "switch_off" }
	#   - "click"      : 点击该位置（按钮=一次脉冲；开关=切换）
	#   - "switch_on"  : 把该位置的开关直接置为“开”
	#   - "switch_off" : 把该位置的开关直接置为“关”
	var click_actions: Array = [
		# { "pos": Vector2i(0, 0),     "op": "click" },
		{ "pos": Vector2i(5760, 3456),   "op": "switch_on" },
		{ "pos": Vector2i(4480, 3456),   "op": "switch_on" },
		{ "pos": Vector2i(3200, 3456),   "op": "switch_on" },
		{ "pos": Vector2i(1920, 3456),   "op": "switch_on" },
		{ "pos": Vector2i(5888, 3072),   "op": "switch_on" },
	]

	for action: Dictionary in click_actions:
		var pos: Vector2i = action["pos"]
		match String(action.get("op", "click")):
			"switch_on":
				assert_true(harness.set_switch(pos, true), "无法在 %s 打开开关" % str(pos))
			"switch_off":
				assert_true(harness.set_switch(pos, false), "无法在 %s 关闭开关" % str(pos))
			_:
				assert_true(harness.click_build(pos), "无法点击 %s" % str(pos))

	# 让信号传播后的状态在断言前稳定（reCalSignals 为同步，但保留一帧更稳妥）
	await wait_process_frames(1)

	# ===== TODO 3：填写期望的 LED 状态 =====================================
	# 每一项：{ "pos": Vector2i, "expect": SwDefine.CircuitSignal.HIGH 或 LOW }
	var led_expectations: Array = [
		{ "pos": Vector2i(6016, 384),  "expect": SwDefine.CircuitSignal.LOW }, # 应灭
		{ "pos": Vector2i(4736, 384),  "expect": SwDefine.CircuitSignal.LOW }, # 应灭
		{ "pos": Vector2i(3456, 384),  "expect": SwDefine.CircuitSignal.LOW }, # 应灭
		{ "pos": Vector2i(2176, 384),  "expect": SwDefine.CircuitSignal.LOW }, # 应灭
		{ "pos": Vector2i(896, 384),  "expect": SwDefine.CircuitSignal.HIGH }, # 应亮
	]

	assert_gt(led_expectations.size(), 0, "尚未配置 LED 期望（led_expectations 为空）")
	for expect_item: Dictionary in led_expectations:
		var led_pos: Vector2i = expect_item["pos"]
		var expect: SwDefine.CircuitSignal = expect_item["expect"]
		var actual: SwDefine.CircuitSignal = harness.get_signal_state(led_pos)
		assert_eq(actual, expect,
			"灯泡 %s 状态不符：期望 %s，实际 %s" % [str(led_pos), _sig_name(expect), _sig_name(actual)])

func _sig_name(s: SwDefine.CircuitSignal) -> String:
	match s:
		SwDefine.CircuitSignal.HIGH: return "HIGH(亮)"
		SwDefine.CircuitSignal.LOW: return "LOW(灭)"
		_: return "NONE"

func _comp_name(c: SwDefine.CircuitComponentType) -> String:
	match c:
		SwDefine.CircuitComponentType.BUTTON: return "BUTTON"
		SwDefine.CircuitComponentType.SWITCH: return "SWITCH"
		SwDefine.CircuitComponentType.LED: return "LED"
		SwDefine.CircuitComponentType.WIRE: return "WIRE"
		SwDefine.CircuitComponentType.NOT_GATE: return "NOT_GATE"
		SwDefine.CircuitComponentType.AND_GATE: return "AND_GATE"
		SwDefine.CircuitComponentType.WIRE_TUNNEL: return "WIRE_TUNNEL"
		_: return "OTHER(%d)" % c
