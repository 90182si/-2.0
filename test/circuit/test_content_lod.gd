extends GutTest
# 内容 LOD 契约：任何缩放档位都必须全量显示建筑部件，基座与电线端子不得丢弃。
#   godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://test/circuit -gprefix=test_content_lod -gexit
# 简化档的实现（SWBuildCompoentRenderable._bakeSimplified）作为休眠路径保留，
# 因此这里只校验「渲染链实际取用的档位」（dm.content_lod），不去断言 lod=3 直调的结果。
# 存档用 ledbug2：本用例只比部件数，不需要大存档。

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const SAVE_NAME := "ledbug2"
const LOG_PATH := "j:/godot/无限地图/_lod.txt"
var _lines: Array[String] = []

func _w(m: String) -> void:
	_lines.append(m)

func test_content_lod_keeps_full_detail() -> void:
	var harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)
	await harness.boot_game()
	var data: Dictionary = await harness.load_save(SAVE_NAME)
	if data.is_empty():
		_w("LOAD FAILED")
		_dump()
		fail_test("存档加载失败")
		return
	var dm = harness.build_layer.sw_draw_manager
	# 1) 档位映射：从近到远全都必须回到满精度
	for level: int in [-5, -20, -31, -32, -33, -40, -45, -60]:
		var got: int = dm._content_lod_for(level)
		assert_eq(got, 0, "缩放档 %d 下内容 LOD 不为 0，基座/端子会被丢掉" % level)
	assert_eq(dm.content_lod, 0, "SWDrawManager.content_lod 应为 0")
	_w("档位映射: -5..-60 全部 -> lod=0")
	# 2) 按渲染链实际取用的档位烘块：每栋建筑的实例数必须等于它的部件总数
	await get_tree().process_frame
	var builds: Array = harness.build_layer.layer_system.build_manager.getAllBuilds()
	var grid_x := float(SwDefine.GRID_SIZE.x)
	var grid_y := float(SwDefine.GRID_SIZE.y)
	var counted := 0
	var dropped := 0
	var inst_total := 0
	for b in builds:
		var comp: SWBuildCompoentRenderable = b.getRenderableCompoent()
		if comp == null:
			continue
		var bx := float(b.buildAxisPos.x)
		var by := float(b.buildAxisPos.y)
		var parts: int = comp.getRenderPartCount()
		var blk: PackedFloat32Array = comp.getInstanceBlock(bx, by, grid_x, grid_y,
				b.buildState.mask_color, true, dm.content_lod)
		var inst: int = blk.size() / SWBuildCompoentRenderable.INSTANCE_STRIDE
		inst_total += inst
		if inst != parts:
			dropped += 1
		counted += 1
	_w("样本建筑=%d  实例合计=%d  丢件建筑=%d" % [counted, inst_total, dropped])
	assert_gt(counted, 0, "没有可统计的建筑")
	assert_eq(dropped, 0, "%d 栋建筑在当前内容 LOD 下部件被丢弃" % dropped)
	_dump()
	pass_test("任何 LOD 档位都全量显示建筑部件")

func _dump() -> void:
	var f := FileAccess.open(LOG_PATH, FileAccess.WRITE)
	for l in _lines:
		f.store_line(l)
	f.close()
