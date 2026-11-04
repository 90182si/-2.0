extends GutTest
# RD 创建探针：连续创建 local RD，验证 D3D12/Vulkan 下可用性（含加载存档渲染后）
# 输出 _probe_rd.txt

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const SAVE_NAME := "加法器3"

func test_rd_probe() -> void:
	var main_rd: RenderingDevice = RenderingServer.get_rendering_device()
	var ok := 0
	var fail := 0
	var rds: Array = []
	# 先加载存档（构建区块+渲染），模拟游戏真实负载
	var harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)
	await harness.boot_game()
	var data: Dictionary = await harness.load_save(SAVE_NAME)
	for i in 10:
		var rd: RenderingDevice = RenderingServer.create_local_rendering_device()
		if rd != null:
			ok += 1
			rds.append(rd)
		else:
			fail += 1
	var f := FileAccess.open("j:/godot/无限地图/_probe_rd.txt", FileAccess.WRITE)
	f.store_line("save_loaded=%s main_rd_valid=%s local_ok=%d local_fail=%d" % [
		str(not data.is_empty()), str(main_rd != null), ok, fail])
	f.close()
	for rd in rds:
		rd.free()
	pass_test("rd probe done")
