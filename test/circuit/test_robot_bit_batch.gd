extends GutTest

# 位平面批量求值 vs 逐台 SWCircuitBundle 对拍：
# 同一份 .swcir、N 台、每台输入序列不同（寄存器状态会分化），
# 每拍每台的输出位图必须完全一致 —— 这是批量路径的**正确性**底线。
const SAVE_NAME := "机器人测试2"
const N: int = 24
const BEATS: int = 12
# 新 class_name 在 headless 里没进 global class cache，统一走 preload
const GROUP := preload("res://circuit/sim/sw_bit_batch_group.gd")


func _all_names() -> Array:
	var names: Array = SWRobotActions.ACTION_NAMES.duplicate()
	names.append_array(SWRobotActions.SIG_DIR_NAMES)
	return names


func test_bitbatch_matches_bundle() -> void:
	var src = SWCirManager.load_bundle(SAVE_NAME)
	assert_not_null(src, "电路没加载出来")

	var grp := GROUP.new()
	grp.setup(src)
	assert_eq(grp.subs.size(), 17, "子电路条数不对（存档换了？）")
	assert_true(grp.has_registers, "这份存档应当有寄存器子电路")

	var names: Array = _all_names()
	var ro: Dictionary = grp.resolve_outputs(names)
	var ri: Dictionary = grp.resolve_inputs(SWRobotActions.RES_PORT_NAMES)
	var clk_in: Dictionary = grp.resolve_inputs(["clk"])
	var out_flat: PackedInt32Array = ro["flat"]
	var out_offs: PackedInt32Array = ro["offs"]
	var in_flat: PackedInt32Array = ri["flat"]
	var in_offs: PackedInt32Array = ri["offs"]
	var clk_flat: PackedInt32Array = clk_in["flat"]
	assert_gt(out_flat.size(), 0, "输出口没解析出来")
	assert_gt(in_flat.size(), 0, "detect_res 口没解析出来")
	assert_gt(clk_flat.size(), 0, "clk 口没解析出来")

	# 参考实现：每台一份独立 bundle（状态互不影响）
	var refs: Array = []
	for i in N:
		var b = SWCirManager.load_bundle(SAVE_NAME)
		assert_not_null(b, "第 %d 台的电路没加载出来" % i)
		refs.append(b)
		grp.alloc_bit()

	for phase in BEATS:
		# 每台给不同的 detect 码 + 不同的 clk 序列：寄存器状态会真正分化
		for i in N:
			var code: int = (i * 37 + phase * 11) & 0xFF
			grp.write_bits(in_flat, in_offs, i, code, SWRobotActions.DETECT_COUNT - 1)
			refs[i].write_input_bits(SWRobotActions.RES_PORT_NAMES, code,
					SWRobotActions.DETECT_COUNT - 1)

		# 一拍两次 tick：clk 先 0 后 1（与 step_beat_high 同序）
		for clk in [0, 1]:
			for i in N:
				# 奇数台在奇数拍不抬起 clk：让它们的寄存器停在别的状态
				var lv: int = clk
				if (i & 1) == 1 and (phase & 1) == 1:
					lv = 0
				grp.write_pair(clk_flat, i, lv)
				refs[i].set_input("clk", lv)
			grp.tick()
			for i in N:
				refs[i].tick_fast()

		for i in N:
			var exp: int = refs[i].read_output_bits(names)
			var got: int = grp.read_bits(out_flat, out_offs, i)
			assert_eq(got, exp, "第 %d 台第 %d 拍输出位图不一致（%s）" % [
					i, phase, names])


# 扩容不能丢寄存器状态：先跑几拍，再扩容，再继续跑，结果应与参考一致
func test_bitbatch_grow_keeps_state() -> void:
	var src = SWCirManager.load_bundle(SAVE_NAME)
	var grp := GROUP.new()
	grp.setup(src)
	var names: Array = _all_names()
	var ro: Dictionary = grp.resolve_outputs(names)
	var clk_in: Dictionary = grp.resolve_inputs(["clk"])
	var out_flat: PackedInt32Array = ro["flat"]
	var out_offs: PackedInt32Array = ro["offs"]
	var clk_flat: PackedInt32Array = clk_in["flat"]

	var ref = SWCirManager.load_bundle(SAVE_NAME)
	grp.alloc_bit()

	# 第一阶段：跑 6 拍把寄存器推到某个状态
	for phase in 6:
		for clk in [0, 1]:
			grp.write_pair(clk_flat, 0, clk)
			ref.set_input("clk", clk)
			grp.tick()
			ref.tick_fast()

	# 扩容到 200 台（words 从 1 变 4）
	grp.ensure_capacity(200)
	assert_eq(grp.capacity, 200, "容量没扩上去")

	# 第二阶段：接着跑，老实例状态必须还在
	for phase in 6:
		for clk in [0, 1]:
			grp.write_pair(clk_flat, 0, clk)
			ref.set_input("clk", clk)
			grp.tick()
			ref.tick_fast()
		assert_eq(grp.read_bits(out_flat, out_offs, 0), ref.read_output_bits(names),
				"扩容后第 %d 拍输出漂了（寄存器状态没搬过去）" % phase)


# 删掉的槽位不能影响别人：清 bit 后其它实例输出不变
func test_bitbatch_clear_bit_isolated() -> void:
	var src = SWCirManager.load_bundle(SAVE_NAME)
	var grp := GROUP.new()
	grp.setup(src)
	var names: Array = _all_names()
	var ro: Dictionary = grp.resolve_outputs(names)
	var clk_in: Dictionary = grp.resolve_inputs(["clk"])
	var out_flat: PackedInt32Array = ro["flat"]
	var out_offs: PackedInt32Array = ro["offs"]
	var clk_flat: PackedInt32Array = clk_in["flat"]

	var ref = SWCirManager.load_bundle(SAVE_NAME)
	grp.alloc_bit()
	grp.alloc_bit()

	for phase in 6:
		for clk in [0, 1]:
			for bit in 2:
				grp.write_pair(clk_flat, bit, clk)
			ref.set_input("clk", clk)
			grp.tick()
			ref.tick_fast()
	# 清掉 bit 1（模拟删机器人）
	grp.clear_bit(1)
	for phase in 6:
		for clk in [0, 1]:
			grp.write_pair(clk_flat, 0, clk)
			ref.set_input("clk", clk)
			grp.tick()
			ref.tick_fast()
		assert_eq(grp.read_bits(out_flat, out_offs, 0), ref.read_output_bits(names),
				"清掉空槽位后其它实例漂了（第 %d 拍）" % phase)
