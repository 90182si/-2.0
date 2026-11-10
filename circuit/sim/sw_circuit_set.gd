class_name SWCircuitSet extends RefCounted

# ==========================================================================
# 一个 .swcir 里可能有**多条互不相连的电路分组**（每条分组至少含一个接口元件）。
# 机器人一侧的口径：只要分组里出现接口元件，这条分组就得跟着节拍一起跑 ——
# 例如「一条 clk 驱动的时序电路 + 8 条 开关→detect_sig_<k> 的组合电路」，
# 合起来才构成一个完整的机器人控制器。
#
# 本类把多条 SWCircuitBundle 打包成一个**接口同名的复合 bundle**：
#   - 写输入：广播给每条子电路（没有该接口名的子电路静默忽略）
#   - 跑一拍：逐条 tick（各持独立 runtime / 寄存器状态，互不影响）
#   - 读输出：任一条子电路为高即 1（同一输出名出现在多条电路里时按 OR 合并）
#
# 这样实体层 / HUD / 时序图都不用区分「单电路」与「多电路」：
# load_bundle 单电路时仍返回原生 SWCircuitBundle，多电路时返回本类，
# 两者方法名完全一致（duck typing）。
# ==========================================================================

# 每条元素都是 SWCircuitBundle
var bundles: Array = []

# name -> 拥有该接口的子电路下标（建一次，加电路时失效）。
# 为什么需要：一个 .swcir 里常有十几条分组（用户实测 17 条），而 clk 只接在其中一条上。
# 原实现每次 set_input / output_level / has_output 都广播给全部子电路，
# 几十台机器人 × 每拍十几次读写时全是白跑的字典查。
var _in_index: Dictionary = {}
var _out_index: Dictionary = {}
var _names_in: Array = []
var _names_out: Array = []
var _index_dirty: bool = true


func add_bundle(b) -> void:
	if b != null:
		bundles.append(b)
		_index_dirty = true


func size() -> int:
	return bundles.size()


func is_empty() -> bool:
	return bundles.is_empty()


# ===== 接口查询（取并集） =====
func has_input(name: String) -> bool:
	_ensure_index()
	return _in_index.has(name)


func has_output(name: String) -> bool:
	_ensure_index()
	return _out_index.has(name)


# 返回的数组**调用方只读、不要改**（内部缓存，不再每次新建）
func input_names() -> Array:
	_ensure_index()
	return _names_in


func output_names() -> Array:
	_ensure_index()
	return _names_out


# ===== 命令入 / 结果出 =====
# 写输入电平：只发给**真持这个接口**的那几条子电路（同名的才广播）
func set_input(name: String, level: int) -> void:
	_ensure_index()
	var idxs = _in_index.get(name, null)
	if idxs == null:
		return
	for i in idxs:
		bundles[i].set_input(name, level)


# 读回当前写入的输入电平：任一子电路为 1 即 1（多条电路接同一名字时按 OR）
func input_level(name: String) -> int:
	_ensure_index()
	var idxs = _in_index.get(name, null)
	if idxs == null:
		return 0
	for i in idxs:
		if int(bundles[i].input_level(name)) != 0:
			return 1
	return 0


# 一拍里把每条子电路都跑一遍。返回最后一条的结果（调用方不依赖返回值，
# 需要逐条结果时直接遍历 bundles）
func tick():
	var last = null
	for b in bundles:
		last = b.tick()
	return last


# 同上，但不打包差分结果（机器人侧用：没人读 SWSimResult）
func tick_fast() -> void:
	for b in bundles:
		b.tick_fast()


# 读输出电平：任一条子电路为高即 1
func output_level(name: String) -> int:
	_ensure_index()
	var idxs = _out_index.get(name, null)
	if idxs == null:
		return 0
	for i in idxs:
		if int(bundles[i].output_level(name)) != 0:
			return 1
	return 0


# 批量读：位图第 i 位 = names[i] 的电平（任一子电路为高即置位）
func read_output_bits(names: Array) -> int:
	_ensure_index()
	var m: int = 0
	for i in names.size():
		var idxs = _out_index.get(str(names[i]), null)
		if idxs == null:
			continue
		for b in idxs:
			if int(bundles[b].output_level(str(names[i]))) != 0:
				m |= 1 << i
				break
	return m


# 批量写位：names[i] 写 (code >> (bit_base - i)) & 1，只发给持该接口的子电路
func write_input_bits(names: Array, code: int, bit_base: int) -> void:
	_ensure_index()
	for i in names.size():
		var key: String = str(names[i])
		var idxs = _in_index.get(key, null)
		if idxs == null:
			continue
		var v: int = (code >> (bit_base - i)) & 1
		for b in idxs:
			bundles[b].set_input(key, v)


func reset() -> void:
	for b in bundles:
		b.reset()


# 各子电路的寄存器 Q 串用 "/" 串起来；全都没有寄存器时返回 "-"
func reg_q_text() -> String:
	var parts := PackedStringArray()
	for b in bundles:
		var t: String = str(b.reg_q_text())
		if t == "-":
			continue
		parts.append(t)
	if parts.is_empty():
		return "-"
	return "/".join(parts)


func describe() -> String:
	return "set(%d) in=%s out=%s" % [bundles.size(), str(input_names()), str(output_names())]


# ===== 内部 =====
# 接口名 -> 子电路下标的索引（惰性重建；名字清单同时排好序）
func _ensure_index() -> void:
	if not _index_dirty:
		return
	_index_dirty = false
	_in_index.clear()
	_out_index.clear()
	_names_in = []
	_names_out = []
	for i in bundles.size():
		var b = bundles[i]
		for n in b.input_names():
			var k: String = str(n)
			if not _in_index.has(k):
				_in_index[k] = []
				_names_in.append(k)
			(_in_index[k] as Array).append(i)
		for n in b.output_names():
			var k: String = str(n)
			if not _out_index.has(k):
				_out_index[k] = []
				_names_out.append(k)
			(_out_index[k] as Array).append(i)
	_names_in.sort()
	_names_out.sort()
