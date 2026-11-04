extends GutTest
# T1.8 诊断：确认 create_backend 返回后端类型、tick 后 takeDirtyNets 是否覆盖混接 net、
# set_level 是否真实写入 texel（GUT 环境编译正常，排除 -s 脚本模式时序干扰）。
#   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/circuit/test_t18_backend_diag.gd -gexit

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const SAVE_NAME := "16x计数器"

var harness = null

func before_each() -> void:
	harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)

func after_each() -> void:
	if harness != null:
		harness.shutdown_game()
		harness = null

func test_t18_backend_probe() -> void:
	await harness.boot_game()
	var data: Dictionary = await harness.load_save(SAVE_NAME)
	if data.is_empty():
		fail_test("存档加载失败")
		return
	SwAtlas.set_lod(0)
	harness.force_load_all_chunks()

	var tex: SWSignalTexture = SWSignalTexture.instance
	print("[t18] backend=", tex, " rd_ok=", RenderingServer.get_rendering_device() != null)
	print("[t18] tex.image_null=", tex.image == null)
	if tex.image == null:
		fail_test("instance.image 为 null（不是 CPU 后端）")
		return

	var sys: SWBuildLayerSystem = harness.build_layer.layer_system
	var clocks: Array[SWBuildItemDefine] = sys.clockBuildArr.keys()
	print("[t18] clocks=", clocks.size())
	if clocks.is_empty():
		fail_test("无时钟")
		return

	# 收集混接 net（含电线A和电线B的 net）
	var mixed: Dictionary = {}
	for clk: SWBuildItemDefine in clocks:
		var defs: Array = clk.buildDefine.build_pin
		for p: Dictionary in defs:
			var net: SWNet = clk.pinNetMap[p.pin_dir]
			if net == null:
				continue
			if net.wireGroup != null and net.wireGroup.wireName == "电线A" and net.netId >= 0:
				mixed[net.netId] = net
			if net.wireGroup != null and net.wireGroup.wireName == "电线B" and net.netId >= 0:
				mixed[net.netId] = net
	print("[t18] mixed_net_count=", mixed.size())

	var changed: Array = sys.circuit_control.buildSignalsChanged(clocks)
	print("[t18] changedBuilds=", changed.size())
	var nets: Dictionary = sys.circuit_control.takeDirtyNets()
	print("[t18] takeDirtyNets_size=", nets.size())
	var hit: int = 0
	for nid: int in mixed:
		if nets.has(mixed[nid]):
			hit += 1
	print("[t18] mixed_in_dirty=", hit, "/", mixed.size())
	for nid: int in mixed:
		var net: SWNet = mixed[nid]
		var lv: float = tex.image.get_pixel(nid % SWSignalTexture.TEX_COLS, nid / SWSignalTexture.TEX_COLS).r
		var want: float = 1.0 if net.curSignal == SwDefine.CircuitSignal.HIGH else 0.0
		print("[t18] net=", nid, " cur=", net.curSignal, " painted=", net.paintedSignal,
				" in_dirty=", nets.has(net), " texel=", lv, " want=", want,
				" in_mixed=", mixed.has(nid))
	assert_gt(hit, 0, "混接 net 完全不在 dirty 队列里，纹理永不更新")
