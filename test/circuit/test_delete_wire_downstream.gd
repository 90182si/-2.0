extends GutTest
# 删除电线的回归用例：开关 → 电线 → 灯泡 链路，打开开关点亮灯泡后删掉中间电线，
# 灯泡必须熄灭。
# 修前问题：_do_delete_selected/_do_cut 没标 TO_BE_REMOVED 就调 updateBuildCircuit，
# 被删电线以"存活"身份混进重建集合，其 getNet/connectWireGroup 按旧格位查邻格，
# 把开关和灯泡重新桥到同一条 net 上 → 删了电线下游元件仍收到信号。
# （右键擦除路径 holdRemoveBuilds 有标记，作为对照组一并覆盖。）

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")

const POS_SWITCH := Vector2i(0, 0)
const POS_WIRE := Vector2i(0, -128)   # 开关端口朝 UP（dir_to_vec(0)=(0,-1)）
const POS_LED := Vector2i(0, -256)

func test_delete_key_removes_wire_bridging() -> void:
	await _run_and_delete("delete_key")

func test_erase_drag_removes_wire_bridging() -> void:
	await _run_and_delete("erase")

func test_cut_removes_wire_bridging() -> void:
	await _run_and_delete("cut")

func _run_and_delete(delete_path: String) -> void:
	var harness = HARNESS_SCRIPT.new()
	add_child(harness)
	await harness.boot_game()
	var build_layer: SWBuildLayer = harness.build_layer
	var mgr: SWBuildManager = build_layer.sw_build_manager

	var wire := _place(mgr, load("res://res/电线A.tres") as SWBuildDefine, POS_WIRE)
	var sw := _place(mgr, load("res://res/开关.tres") as SWBuildDefine, POS_SWITCH)
	var led := _place(mgr, load("res://res/灯泡.tres") as SWBuildDefine, POS_LED)
	assert_not_null(wire, "放置电线失败")
	assert_not_null(sw, "放置开关失败")
	assert_not_null(led, "放置灯泡失败")
	build_layer.sw_circuit_control.updateBuildCircuit([sw, wire, led])

	# 打开开关 → 灯泡应亮（链路本身成立，否则后面的断言没有意义）
	assert_true(harness.set_switch(POS_SWITCH, true), "无法打开开关")
	await wait_process_frames(1)
	assert_eq(harness.get_signal_state(POS_LED), SwDefine.CircuitSignal.HIGH,
		"前置条件失败：开关闭合后灯泡未点亮")

	# 按三种删除入口删除中间电线
	match delete_path:
		"delete_key":
			build_layer.selectedBuilds[wire] = true
			build_layer._do_delete_selected()
		"cut":
			build_layer.selectedBuilds[wire] = true
			build_layer._do_cut()
		_:
			build_layer.holdRemoveBuilds([POS_WIRE])
			build_layer.onEraseDragEnded()
	await wait_process_frames(1)

	# 灯泡必须熄灭：电线删除后开关与灯泡之间不再有 net
	assert_eq(harness.get_signal_state(POS_LED), SwDefine.CircuitSignal.LOW,
		"删除电线（路径 %s）后灯泡仍收到信号" % delete_path)
	var led_net: SWNet = led.getCircuitCompoent().pinNetMap.get(SwDefine.SW_Dir.DOWN, null)
	assert_null(led_net, "删除电线（路径 %s）后灯泡输入引脚仍挂在 net 上" % delete_path)

	harness.shutdown_game()
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(harness):
		remove_child(harness)
		harness.free()

func _place(mgr: SWBuildManager, def: SWBuildDefine, pos: Vector2i) -> SWBuildItemDefine:
	var build: SWBuildItemDefine = SwDefine.SWBuildCreator(pos, def)
	if not mgr.addBuild(build):
		return null
	return build
