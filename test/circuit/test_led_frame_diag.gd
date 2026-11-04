extends GutTest
# LED 帧链路运行时诊断：一次性打印「帧槽分配 / 帧槽 texel / buffer 13·15 列 /
# styleTex off·on rect / 材质 uniform」五个环节，定位「电平变了但样式不变」的故障层。
# 同时守住回归底线：帧建筑的 styleTex row1 必须 ≠ row0，否则 shader 取哪行都是灭帧。
#   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/circuit/test_led_frame_diag.gd -gexit

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

func _boot() -> bool:
	await harness.boot_game()
	var data: Dictionary = await harness.load_save(SAVE_NAME)
	if data.is_empty():
		push_error("存档加载失败: " + SAVE_NAME)
		return false
	SwAtlas.set_lod(0)
	assert_gt(harness.force_load_all_chunks(), 0, "没有任何区块被构建出来")
	return true

func test_led_frame_chain_diag() -> void:
	if not await _boot():
		return
	var sys: SWBuildLayerSystem = harness.build_layer.layer_system
	var dm = harness.build_layer.sw_draw_manager
	var tex: SWSignalTexture = SWSignalTexture.instance
	var stex: SWStyleTexture = SWStyleTexture.instance
	var found := 0
	var broken: Array[String] = []  # 定义了 on 帧、但 styleTex 两行却相同的 LED
	for b: SWBuildItemDefine in sys.build_manager.getAllBuilds():
		if not (b is SWBuildLed):
			continue
		found += 1
		var r: SWBuildCompoentRenderable = b.getRenderableCompoent()
		var slot: int = r._frameSlot
		var lv := -1.0
		if slot >= 0:
			lv = tex.image.get_pixel(slot % tex.TEX_COLS, slot / tex.TEX_COLS).r
		var mi: SWMultiMeshInstance2D = null
		var cp: Vector2i = SwCommon.GetChunkPos(b.buildAxisPos)
		if dm._chunkInstance.has(cp):
			mi = dm._chunkInstance[cp].mesh_instance
		var buf13 := -1.0
		var buf15 := -1.0
		var sid := -1
		if mi != null and mi._slotStart.has(b):
			var stride := SWBuildCompoentRenderable.INSTANCE_STRIDE
			var idx := int(mi._slotStart[b]) * stride + maxi(r._atlasPartIndex, 0) * stride
			buf13 = mi._cpuBuffer[idx + 13]
			buf15 = mi._cpuBuffer[idx + 15]
			sid = int(mi._cpuBuffer[idx + 12])
		var off: Rect2 = b.buildDefine.atlasTextureOff.region if b.buildDefine.atlasTextureOff != null else Rect2()
		var on: Rect2 = b.buildDefine.atlasTextureOn.region if b.buildDefine.atlasTextureOn != null else Rect2()
		var row0 := Rect2()
		var row1 := Rect2()
		if sid >= 0:
			row0 = stex.get_rect_by_id(sid, false)
			row1 = stex.get_rect_by_id(sid, true)
			if b.buildDefine.atlasTextureOn != null and on != off and row0 == row1:
				broken.append(str(b.buildAxisPos))
		print("[led-diag] LED@%s slot=%d texel=%.0f buf13=%.0f buf15=%.0f styleId=%d defineOnNull=%s onEqOff=%s row0=%s row1=%s row1EqRow0=%s" % [
			str(b.buildAxisPos), slot, lv, buf13, buf15, sid,
			str(b.buildDefine.atlasTextureOn == null), str(off == on),
			str(row0), str(row1), str(row0 == row1)])
	var any_mat: ShaderMaterial = null
	for chunkPos: Vector2i in dm.get_loaded_chunk_positions():
		var cand: SWMultiMeshInstance2D = dm._chunkInstance[chunkPos].mesh_instance
		if cand != null and cand.material is ShaderMaterial:
			any_mat = cand.material as ShaderMaterial
			break
	if any_mat != null:
		print("[led-diag] signalBits_set=%s styleTex_set=%s signalCols=%s signalFrozen=%s" % [
			str(any_mat.get_shader_parameter("signalBits") == tex.texture),
			str(any_mat.get_shader_parameter("styleTex") == stex.texture),
			str(any_mat.get_shader_parameter("signalCols")),
			str(any_mat.get_shader_parameter("signalFrozen"))])
	if found == 0:
		pending("存档 %s 里没有 LED" % SAVE_NAME)
	assert_eq(broken.size(), 0,
		"这些 LED 的 styleTex on 行被降级成 off 帧，只会显示灭帧：%s" % ", ".join(broken.slice(0, 5)))
