class_name SWBitBatchGroup extends RefCounted

# 「同一份 .swcir」的机器人共享的批量求值上下文。
# 每条子电路一个 SWBitBatch，实例位（bit）就是机器人在这组里的槽位；
# 接口名 → 子电路下标 的索引与 SWCircuitSet 的做法一致（多分组时同名口可能分散在多条子电路）。
#
# 用法（实体层）：
#   var bit: int = grp.alloc_bit()
#   grp.write_bits(grp.res_flat, grp.res_offs, bit, code, 7)
#   grp.tick()
#   var bits: int = grp.read_bits(grp.out_flat, grp.out_offs, bit)
#
# 为什么把「名字解析」预展开成扁平表：上千台时每台每拍要读 6 个、写 8 个口，
# 逐次 Dictionary 查名字就是 14 万次哈希/拍；预解析之后每台只是按下标位移。

# 显式 preload：新加的 class_name 在 headless（测试/CI）里没进 global class cache，
# 直接写 SWBitBatch.new() 会报 not declared
const BIT_BATCH := preload("res://circuit/sim/sw_bit_batch.gd")

var source = null          # SWCircuitBundle 或 SWCircuitSet（只读：取 prog / 接口表）
var subs: Array = []       # 子电路（SWCircuitBundle）
var batches: Array = []    # 与 subs 一一对应的 SWBitBatch
var capacity: int = 0      # 已分配的槽位上限
var next_bit: int = 0      # 下一个可用槽位（单调递增，删实体不回收）
# 是否有子电路带寄存器：带寄存器的组不能按「输入相同 → 输出相同」去重
var has_registers: bool = false
# 是否全部子电路都能批量求值（表达式后端）：有一条第不上就整组退回逐台
var supported: bool = true

# name -> [子电路下标]，以及 (子电路下标) -> (name -> slots)
var _in_idx: Dictionary = {}
var _out_idx: Dictionary = {}
var _in_slots: Array = []
var _out_slots: Array = []

# 常用接口的预解析表（实体层直接持有引用，避免每拍重建）
var act_flat := PackedInt32Array()
var act_offs := PackedInt32Array()
var dir_flat := PackedInt32Array()
var dir_offs := PackedInt32Array()
var res_flat := PackedInt32Array()
var res_offs := PackedInt32Array()
var clk_flat := PackedInt32Array()
# 每条子电路的源初值快照（按 input_slots 序）：电路里的开关/按钮初始电平。
# 新槽位必须先种上它，否则会以全 0 参与运算 —— 实测首个分叉就是某寄存器的 D
# （它依赖一个默认非 0 的源），首拍就与逐台路径不一致
var _src_seed: Array = []
# 共享模板 bundle：批量求值的实体 e.bundle 都指向它（只用来读名字/接口，**从不 tick**）。
# 上万台各持一份 runtime 光是加载就要命，它们的状态全在下面的位平面上
var template = null
# 第 bit 台本拍的 8 位检测码（set_res_code 先存，flush_res_codes 一次摊到平面）
var _codes := PackedInt32Array()
# 检测码临时平面（每个口 words 个字）：先清 0 再置 1，最后整字拷进各子电路
var _res_planes := PackedInt64Array()
# 每台的动作位图 / 方向位图（第 bit 台 = 一个 int，第 j 位 = names[j]，位序同 prepare 传入的名单）。
# 为什么要转置：上万台时实体层每台每拍都要读这两张图（动作在低相位、方向在高相位），
# 直接读位平面是 3 次跨对象 PackedArray 索引（实测 2.3us/台 = 23ms），
# 转置一遍是「词级」的：每个 64 位字一次拿出来，64 台纯位运算摊完（实测 3ms/遍）
var act_mask_by_bit := PackedInt32Array()
var dir_mask_by_bit := PackedInt32Array()
# 本拍被实体层扫到过的代号：实体层每拍 `touch_gen` 一增，首位撞上的实体把组记进活跃表。
# 为什么不直接用字典记「本拍有实体的组」：上万台每台一次字典写就是 15ms
var touch_gen: int = 0


func setup(src) -> void:
	source = src
	template = src
	subs = []
	if src == null:
		return
	if src is SWCircuitSet:
		subs = src.bundles.duplicate()
	else:
		subs = [src]
	batches = []
	_in_idx = {}
	_out_idx = {}
	_in_slots = []
	_out_slots = []
	_src_seed = []
	has_registers = false
	supported = true
	for i in subs.size():
		var sb = subs[i]
		var bb := BIT_BATCH.new()
		# 批量建在表达式后端上（与生产一致，见 sw_bit_batch.gd 头部说明）
		var ex = null
		if sb.runtime != null and sb.runtime._expr_active:
			ex = sb.runtime.expr
		bb.setup(ex, 0)
		if not bb.is_usable():
			supported = false
		batches.append(bb)
		_in_slots.append(sb.input_slots)
		_out_slots.append(sb.output_slots)
		# 快照源初值：模板 bundle 自己不会再 tick，但外边可能拿它当逐台场景的实例，
		# 所以拷一份，不跟着变
		if sb.runtime != null:
			_src_seed.append(sb.runtime.src_levels.duplicate())
		else:
			_src_seed.append(PackedInt32Array())
		for n in sb.input_slots.keys():
			var key: String = str(n)
			if not _in_idx.has(key):
				_in_idx[key] = []
			(_in_idx[key] as Array).append(i)
		for n in sb.output_slots.keys():
			var key: String = str(n)
			if not _out_idx.has(key):
				_out_idx[key] = []
			(_out_idx[key] as Array).append(i)
		if sb.prog != null and not sb.prog.reg_slots.is_empty():
			has_registers = true

# 预解析实体层每拍要用的那几个口（动作 / 方向 / 检测码 / 时钟）。
# 不解析成扁平表的话每台每拍光查名字就要十几万次哈希
func prepare(act_names: Array, dir_names: Array, res_names: Array) -> void:
	var a: Dictionary = resolve_outputs(act_names)
	act_flat = a["flat"]
	act_offs = a["offs"]
	var d: Dictionary = resolve_outputs(dir_names)
	dir_flat = d["flat"]
	dir_offs = d["offs"]
	var r: Dictionary = resolve_inputs(res_names)
	res_flat = r["flat"]
	res_offs = r["offs"]
	var c: Dictionary = resolve_inputs(["clk"])
	clk_flat = c["flat"]


# 给一台机器人分配槽位（位置用完不回收：回收要搬动上万台的状态，空洞只剩一个 bit）
func alloc_bit() -> int:
	var b: int = next_bit
	next_bit += 1
	ensure_capacity(next_bit)
	if b >= _codes.size():
		_codes.resize(next_bit)
	_seed_bit(b)
	return b


# ------- 批量接口（实体层每拍调这几个，不逐台走） -------
# 记一台的检测码：只写内存，整组 flush 时一次摊到平面上。
# 为什么不在 set_res_code 里就写：逐台写 8 个位 = 上万台 8 万次跨对象索引，
# 集中成一层循环后每台只剩 8 次纯位运算
func set_res_code(bit: int, code: int) -> void:
	if bit >= 0 and bit < _codes.size():
		_codes[bit] = code


# 读回某台本拍记下的检测码（分屏镜像 / 排障用）。
# 批量路径下模板 bundle 的输入槽不随本台更新，这里才是权威值
func get_res_code(bit: int) -> int:
	if bit >= 0 and bit < _codes.size():
		return _codes[bit]
	return 0


func flush_res_codes(bit_base: int) -> void:
	if res_flat.is_empty():
		return
	var names: int = res_offs.size() - 1
	var n: int = mini(_codes.size(), next_bit)
	# 字数由容量推算（各组 batch 的 ensure_capacity 是同一批调用的，words 必然相同）
	var w: int = (maxi(capacity, 1) + 63) >> 6
	# 先进临时平面（全清 0），再把为 1 的位 OR 上去。
	# 这样 c == 0 的台可以整台跳过 8 次位判断——大多数机器人的检测码本来就是 0（前方空地）
	if _res_planes.size() != names * w:
		_res_planes.resize(names * w)
	_res_planes.fill(0)
	for bit in n:
		var c: int = _codes[bit]
		if c == 0:
			continue
		var o: int = bit >> 6
		var m: int = 1 << (bit & 63)
		for i in names:
			if ((c >> (bit_base - i)) & 1) != 0:
				_res_planes[i * w + o] = _res_planes[i * w + o] | m
	# 最后整字拷进各自子电路的平面（每口只搬 words 个字，不按台）
	for i in names:
		var k: int = res_offs[i]
		var e2: int = res_offs[i + 1]
		while k < e2:
			var bb = batches[res_flat[k]]
			var base: int = res_flat[k + 1] * bb.words
			for x in w:
				bb.buf[base + x] = _res_planes[i * w + x]
			k += 2


# 每拍刷两张「按台展开」的位图：方向位图必须在组 tick **之前**（读上一拍输出），
# 动作位图在 tick **之后**。实体层直接按下标取，不再走方法
func refresh_action_masks() -> void:
	_transpose(act_flat, act_offs, true)


func refresh_dir_masks() -> void:
	_transpose(dir_flat, dir_offs, false)


# 位平面 -> 「每台一个 int」的转置。
# 快路径：恰好 3 个名字、每个名字只对应 1 条子电路 1 个 slot（实体层要的动作/方向口都是这种），
# 这时整词取出来，64 台的 3 个位一起摊；慢路径（多子电路同名口）才回到逐台循环。
func _transpose(flat: PackedInt32Array, offs: PackedInt32Array, is_act: bool) -> void:
	var n: int = next_bit
	if is_act:
		if act_mask_by_bit.size() < n:
			act_mask_by_bit.resize(n)
		act_mask_by_bit.fill(0)
	else:
		if dir_mask_by_bit.size() < n:
			dir_mask_by_bit.resize(n)
		dir_mask_by_bit.fill(0)
	if n <= 0:
		return
	var w: int = (maxi(capacity, 1) + 63) >> 6
	var names: int = offs.size() - 1
	if names == 3 and offs[1] == 2 and offs[2] == 4 and offs[3] == 6:
		var b0 = batches[flat[0]]
		var s0: int = flat[1] * w
		var b1 = batches[flat[2]]
		var s1: int = flat[3] * w
		var b2 = batches[flat[4]]
		var s2: int = flat[5] * w
		for o in w:
			var lo: int = o << 6
			if lo >= n:
				break
			var hi: int = mini(lo + 64, n)
			var v0: int = b0.buf[s0 + o]
			var v1: int = b1.buf[s1 + o]
			var v2: int = b2.buf[s2 + o]
			#整词全 0（大多数机器人的大多数口）直接跳，连位都不用拆
			if (v0 | v1 | v2) == 0:
				continue
			for k in range(lo, hi):
				var sh: int = k & 63
				var m: int = ((v0 >> sh) & 1) | (((v1 >> sh) & 1) << 1) | (((v2 >> sh) & 1) << 2)
				if m == 0:
					continue
				if is_act:
					act_mask_by_bit[k] = m
				else:
					dir_mask_by_bit[k] = m
		return
	#慢路径：同一个名字可能落在多条子电路上，任一对为 1 就算这一位是 1
	for k in n:
		var o: int = k >> 6
		var sh: int = k & 63
		var m: int = 0
		for j in names:
			var e2: int = offs[j + 1]
			var p: int = offs[j]
			while p < e2:
				var bb = batches[flat[p]]
				if ((bb.buf[flat[p + 1] * w + o] >> sh) & 1) != 0:
					m |= 1 << j
					break
				p += 2
		if m == 0:
			continue
		if is_act:
			act_mask_by_bit[k] = m
		else:
			dir_mask_by_bit[k] = m


# 整组同值写一个口（clk 每拍全组都是同一个电平）：搬 words 个字 vs 上万台各写 1 位
func fill_flat(flat: PackedInt32Array, level: int) -> void:
	var v: int = -1 if level != 0 else 0
	var k: int = 0
	while k < flat.size():
		var bb = batches[flat[k]]
		var base: int = flat[k + 1] * bb.words
		for x in bb.words:
			bb.buf[base + x] = v
		k += 2


# 给新槽位种上源初值（只写非 0 的，0 本来就是默认态）
func _seed_bit(bit: int) -> void:
	for i in subs.size():
		var lv: PackedInt32Array = _src_seed[i]
		if lv.is_empty():
			continue
		var sub = subs[i]
		if sub.runtime == null or sub.runtime.prog == null:
			continue
		var ins: PackedInt32Array = sub.runtime.prog.input_slots
		var bb = batches[i]
		var n: int = mini(lv.size(), ins.size())
		for k in n:
			if lv[k] != 0:
				bb.write_slot_bit(ins[k], bit, 1)


func ensure_capacity(n: int) -> void:
	if n <= capacity:
		return
	capacity = n
	for bb in batches:
		bb.ensure_capacity(n)


func clear_bit(bit: int) -> void:
	for bb in batches:
		bb.clear_bit(bit)


func reset_all() -> void:
	for bb in batches:
		bb.reset_all()


func tick() -> void:
	for bb in batches:
		bb.tick()


func has_output(name: String) -> bool:
	return _out_idx.has(name)


func has_input(name: String) -> bool:
	return _in_idx.has(name)


# ---------- 预解析：把一批名字展开成 [batch?, slot?] 交替的扁平表 ----------
# offs[i] .. offs[i+1] 是第 i 个名字在 flat 里的区间（每对 = batch 下标 + slot）
func resolve_outputs(names: Array) -> Dictionary:
	var flat := PackedInt32Array()
	var offs := PackedInt32Array()
	offs.append(0)
	for n in names:
		var idxs = _out_idx.get(str(n), null)
		if idxs != null:
			for si in idxs:
				var slots = (_out_slots[si] as Dictionary).get(str(n), null)
				if slots == null:
					continue
				for s in slots:
					flat.append(int(si))
					flat.append(int(s))
		offs.append(flat.size())
	return {"flat": flat, "offs": offs}


func resolve_inputs(names: Array) -> Dictionary:
	var flat := PackedInt32Array()
	var offs := PackedInt32Array()
	offs.append(0)
	for n in names:
		var idxs = _in_idx.get(str(n), null)
		if idxs != null:
			for si in idxs:
				var tbl = _in_slots[si]
				if not (tbl as Dictionary).has(str(n)):
					continue
				# ⚠ bundle.input_slots 存的是「源序号」（set_input 按它写 src_levels），
				# 不是 slot 编号；真正的 slot 在 prog.input_slots[源序号] 里
				var src_idx: int = int((tbl as Dictionary)[str(n)])
				var prog: SWGateProgram = subs[si].prog
				if prog == null or src_idx < 0 or src_idx >= prog.input_slots.size():
					continue
				flat.append(int(si))
				flat.append(int(prog.input_slots[src_idx]))
		offs.append(flat.size())
	return {"flat": flat, "offs": offs}


# 读：返回位图，第 i 位 = names[i] 在 bit 这台的输出电平
func read_bits(flat: PackedInt32Array, offs: PackedInt32Array, bit: int) -> int:
	var m: int = 0
	for i in offs.size() - 1:
		var e: int = offs[i + 1]
		var k: int = offs[i]
		while k < e:
			if batches[flat[k]].read_slot_bit(flat[k + 1], bit) != 0:
				m |= 1 << i
				break
			k += 2
	return m


# 写：names[i] 写 (code >> (bit_base - i)) & 1
func write_bits(flat: PackedInt32Array, offs: PackedInt32Array, bit: int, code: int, bit_base: int) -> void:
	for i in offs.size() - 1:
		var v: int = (code >> (bit_base - i)) & 1
		var e: int = offs[i + 1]
		var k: int = offs[i]
		while k < e:
			batches[flat[k]].write_slot_bit(flat[k + 1], bit, v)
			k += 2


# 单口读写（clk 这类每拍都要动的口用：预解析后只有一对）
func write_pair(flat: PackedInt32Array, bit: int, level: int) -> void:
	var k: int = 0
	while k < flat.size():
		batches[flat[k]].write_slot_bit(flat[k + 1], bit, level)
		k += 2


# 寄存器 Q 串（排障用）：按寄存器序号取某台的 Q 电平
func reg_bit(i: int, bit: int) -> int:
	for bb in batches:
		if bb.prog == null:
			continue
		for r in bb.prog.reg_slots.size():
			return bb.reg_debug(r, bit)   # 只在单子电路/首条有寄存器时有意义
	return 0
