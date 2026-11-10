extends RefCounted

# ==========================================================================
# 动画批处理：上万台机器人的「插值 + 实例缓冲改写」全部在这里做
#
# 为什么要单独抽一层：这段逻辑原来在 SWEntityVisual 里用 Array[Dictionary] 存每台状态，
# 每帧每台要读十几个字段。Dictionary 的字符串键哈希 60~100ns/次，实测 10000 台
# 每帧要 42.7ms（parts=1，也就是说每台实际只写 2 个 float，其余全是解释器开销）。
#
# 本类把它改成**平行数组（SoA）**：行号 = 下标，只有 Packed 数组索引与算术，
# 没有哈希、没有属性链。接口与 C++ 版 SWAnimBatch 完全一致，
# SWEntityVisual 只按接口调用，运行期二选一（见它以 SW_ANIM_NATIVE 开头的分支）。
#
# 数据结构约定（行 = 一台被动画层接管的机器人）：
#   - 每台占一段连续实例槽 [start, start+parts)
#   - 模板 tpl 是「该台在 (tpl_x, tpl_y) 处」的 parts×16 个 float，
#     由 GDScript 的 writeInstances 生成（缩放/style/net/调色板/tint 都在里面）。
#     位置每帧只是「模板原点 + 位移」，旋转才从模板重铺 scale —— 不重跑 writeInstances
# ==========================================================================

# 与 SWBuildCompoentRenderable.INSTANCE_STRIDE 一致
const STRIDE: int = 16
#一格滑动时长 / 转向时长（与 SWEntityVisual 的口径一致，由调用方传入，这里只做插值）
const MOVE_SEC: float = 0.16
const ROTATE_SEC: float = 0.20
const ANGLE_EPS_DEG: float = 0.115   # ≈ 0.002 rad，小于它就不改基向量

# ---- 每台（行）的状态，全部平行数组 ----
var _row: int = 0                          # 有效行数
var _start := PackedInt32Array()           # 在缓冲里的首实例下标
var _parts := PackedInt32Array()           # 部件数（= tpl.size() / STRIDE）
var _fx := PackedFloat32Array()            # 移动起点 x/y
var _fy := PackedFloat32Array()
var _tx := PackedFloat32Array()            # 移动终点 x/y
var _ty := PackedFloat32Array()
var _t := PackedFloat32Array()             # 已走时间
var _dur := PackedFloat32Array()           # 移动时长（0 = 不在动）
var _ang := PackedFloat32Array()           # 起始补角（度，负值）→ 0
var _at := PackedFloat32Array()            # 转向已走时间
var _adur := PackedFloat32Array()          # 转向时长
var _rtflag := PackedByteArray()           # 1 = 下次写缓冲必须重铺 scale（转向帧 / 收尾帧）
var _tpl: Array = []                       # 每行一份 PackedFloat32Array 模板
var _tplx := PackedFloat32Array()          # 模板对应的世界坐标
var _tply := PackedFloat32Array()
var _inact := PackedByteArray()            # 是否已在 _active 里
var _active := PackedInt32Array()          # 本帧要推进的行

# ---- 实例缓冲 ----
var _buf := PackedFloat32Array()
var _cap_inst: int = 0                     # MultiMesh 的 instance_count（容量，2 倍增长）
var _inst_total: int = 0                   # 真正可见的实例数
# 空洞槽位：parts(int) -> Array[int]（可复用的 start）
var _free: Dictionary = {}
var _dirty_hide := PackedInt32Array()      # 被删掉、需要写 0 的槽段（复用前 / 推进前抹掉）
var _dirty: bool = false                   # 缓冲有改动待上传

var _gx: float = 32.0
var _gy: float = 32.0


func setup(grid: Vector2i) -> void:
	_gx = float(grid.x)
	_gy = float(grid.y)


func get_unit_count() -> int:
	return _row


func get_active_count() -> int:
	return _active.size()


func get_visible_count() -> int:
	return _inst_total


func get_capacity() -> int:
	return _cap_inst


func get_buffer() -> PackedFloat32Array:
	return _buf


# 缓冲是否有改动待上传。读一次就清（调用方一帧上传一次）
func consume_dirty() -> bool:
	var d: bool = _dirty
	_dirty = false
	return d


# ---------------- 行管理 ----------------

# 新增一台。tpl = 它在 (base_x, base_y) 处的 parts×STRIDE 实例数据。
# 返回行号；tpl 非法返回 -1
func add_unit(tpl: PackedFloat32Array, base_x: float, base_y: float) -> int:
	if tpl.is_empty() or (tpl.size() % STRIDE) != 0:
		return -1
	var parts: int = tpl.size() / STRIDE
	var start: int = _alloc_slot(parts)
	var r: int = _row
	_row += 1
	_start.resize(_row)
	_parts.resize(_row)
	_fx.resize(_row)
	_fy.resize(_row)
	_tx.resize(_row)
	_ty.resize(_row)
	_t.resize(_row)
	_dur.resize(_row)
	_ang.resize(_row)
	_at.resize(_row)
	_adur.resize(_row)
	_tplx.resize(_row)
	_tply.resize(_row)
	_inact.resize(_row)
	_rtflag.resize(_row)
	_start[r] = start
	_parts[r] = parts
	_tpl.append(tpl)
	_fx[r] = base_x
	_fy[r] = base_y
	_tx[r] = base_x
	_ty[r] = base_y
	_t[r] = 0.0
	_dur[r] = 0.0
	_ang[r] = 0.0
	_at[r] = 0.0
	_adur[r] = 0.0
	_tplx[r] = base_x
	_tply[r] = base_y
	_inact[r] = 0
	_rtflag[r] = 0
	_paint_tpl(r)
	return r


# 重铺模板（选中态变了 —— 底色是烘进实例里的）。tpl 必须是「在 (base_x, base_y) 处」
func refresh_tpl(r: int, tpl: PackedFloat32Array, base_x: float, base_y: float) -> void:
	if r < 0 or r >= _row or tpl.is_empty():
		return
	var parts: int = tpl.size() / STRIDE
	if parts != _parts[r]:
		return
	_tpl[r] = tpl
	_tplx[r] = base_x
	_tply[r] = base_y
	#不动 _fx/_fy：重铺模板不该打断正在跑的移动插值（边滑边被选中会从当前位置
	#重新起算，看起来跳一下）
	_paint_tpl(r)


# 把某一行的模板原地转 sweep_deg 度（与 set_rotate 同口径，顺时针为正）。
# 只对「单部件、且部件原点就在格心」的台成立：这时整台就是一个绕格心转的贴图，
# 原地转与「按新朝向重烘」等价，但省掉一次完整实例重算（实测重烘 7.4us/台，
# 一万台同拍转向就是 74ms）。
# 多部件 / 有跨格偏移的台原地转会挪动部件原点（重烘不会），返回 false 让调用方重铺。
func rotate_tpl(r: int, sweep_deg: float) -> bool:
	if r < 0 or r >= _row:
		return false
	if _parts[r] != 1:
		return false
	var t: PackedFloat32Array = _tpl[r]
	if t.size() != STRIDE:
		return false
	var cx: float = _tplx[r] + _gx * 0.5
	var cy: float = _tply[r] + _gy * 0.5
	if absf(t[3] - cx) > 0.01 or absf(t[7] - cy) > 0.01:
		return false
	var cs: float = 1.0
	var sn: float = 0.0
	if absf(sweep_deg) > ANGLE_EPS_DEG:
		var rad: float = deg_to_rad(sweep_deg)
		cs = cos(rad)
		sn = sin(rad)
	var nt: PackedFloat32Array = t.duplicate()
	var txx: float = nt[0]
	var tyx: float = nt[1]
	var txy: float = nt[4]
	var tyy: float = nt[5]
	#两个基向量同列交错存：t.x = (0,1)、t.y = (4,5)，别按行理解
	nt[0] = cs * txx - sn * txy
	nt[4] = sn * txx + cs * txy
	nt[1] = cs * tyx - sn * tyy
	nt[5] = sn * tyx + cs * tyy
	#原点已经在格心上：绕格心转就是原地不动，写回去保住浮点精度
	nt[3] = cx
	nt[7] = cy
	_tpl[r] = nt
	_paint_tpl(r)
	return true


# 删一台：隐藏槽段、行做 swap-remove（数组不缩容，只减 _row）
func remove_unit(r: int) -> void:
	if r < 0 or r >= _row:
		return
	var last: int = _row - 1
	#⚠ 先取被删行的槽位：_move_row 会把 last 的槽位覆盖到 r 上，之后再取就是
	#  last 的了，被删的那台会一直画在原地（实例段泄漏）
	var st: int = _start[r]
	var pa: int = _parts[r]
	_drop_from_active(r)
	if last != r:
		_drop_from_active(last)
	_move_row(last, r)
	_row = last
	_hide_slot(st, pa)
	var pool = _free.get(pa, null)
	if pool == null:
		pool = []
		_free[pa] = pool
	(pool as Array).append(st)
	_inst_total -= pa
	if _inst_total <= 0:
		reset()


func reset() -> void:
	_row = 0
	_start = PackedInt32Array()
	_parts = PackedInt32Array()
	_fx = PackedFloat32Array()
	_fy = PackedFloat32Array()
	_tx = PackedFloat32Array()
	_ty = PackedFloat32Array()
	_t = PackedFloat32Array()
	_dur = PackedFloat32Array()
	_ang = PackedFloat32Array()
	_at = PackedFloat32Array()
	_adur = PackedFloat32Array()
	_rtflag = PackedByteArray()
	_tpl.clear()
	_tplx = PackedFloat32Array()
	_tply = PackedFloat32Array()
	_inact = PackedByteArray()
	_active = PackedInt32Array()
	_free.clear()
	_dirty_hide = PackedInt32Array()
	_buf.resize(0)
	_cap_inst = 0
	_inst_total = 0
	# 缓冲清空了也要标脏：调用方得把可见数一起归零
	_dirty = true


# ---------------- 动画登记 ----------------

# 起点就是「这一行当前的插值位置」：新建行时模板已经生成在出发格上，
# 所以 get_pos 就是出发格，不需要再传一份 from
func set_move(r: int, to: Vector2, dur: float = MOVE_SEC) -> void:
	if r < 0 or r >= _row:
		return
	#已经接管的从当前插值位置续上（一拍多格时不会跳）。
	#get_pos 只调一次：两次就是两遍 ease + 两个 Vector2 构造
	var p: Vector2 = get_pos(r)
	_fx[r] = p.x
	_fy[r] = p.y
	_tx[r] = to.x
	_ty[r] = to.y
	_t[r] = 0.0
	_dur[r] = dur if dur > 0.0 else 0.0001
	_add_active(r)


# 批量起滑：一次喂一批（行号 + 终点 xy 交错）。
# 为什么要这个入口：逐台 set_move 每台要过一层跨对象调用 + Vector2 构造 + get_pos，
# 上万台一拍实测 38ms；这里把循环收进本类，调用侧只剩一次（C++ 版只剩一次 C 调用）。
# 语义与逐台 set_move 完全一致：起点就是这一行当前的插值位置
func start_moves(rows: PackedInt32Array, to_xy: PackedFloat32Array, dur: float) -> void:
	var n: int = rows.size()
	if n <= 0:
		return
	var d: float = dur if dur > 0.0 else 0.0001
	var rmax: int = _row
	for i in n:
		var r: int = rows[i]
		if r < 0 or r >= rmax:
			continue
		#内联 get_pos：只取 x/y，不构造 Vector2
		var dur0: float = _dur[r]
		if dur0 > 0.0:
			var k: float = _ease(_t[r] / dur0)
			_fx[r] = _fx[r] + (_tx[r] - _fx[r]) * k
			_fy[r] = _fy[r] + (_ty[r] - _fy[r]) * k
		else:
			_fx[r] = _tx[r]
			_fy[r] = _ty[r]
		_tx[r] = to_xy[i * 2]
		_ty[r] = to_xy[i * 2 + 1]
		_t[r] = 0.0
		_dur[r] = d
		#内联 _add_active
		if _inact[r] == 0:
			_inact[r] = 1
			_active.append(r)


func set_rotate(r: int, sweep_deg: float, dur: float = ROTATE_SEC) -> void:
	if r < 0 or r >= _row:
		return
	if dur <= 0.0:
		#同朝向（扫描角 0）：不转，也就不要留 _rtflag，否则会白跑一次重铺
		_ang[r] = 0.0
		_at[r] = 0.0
		_adur[r] = 0.0
		return
	_ang[r] = -sweep_deg
	_at[r] = 0.0
	_adur[r] = dur
	_rtflag[r] = 1
	_add_active(r)


func is_busy(r: int) -> bool:
	if r < 0 or r >= _row:
		return false
	return _dur[r] > 0.0 or _adur[r] > 0.0


func get_pos(r: int) -> Vector2:
	if r < 0 or r >= _row:
		return Vector2.ZERO
	var dur: float = _dur[r]
	if dur <= 0.0:
		return Vector2(_tx[r], _ty[r])
	var e: float = _ease(_t[r] / dur)
	return Vector2(_fx[r] + (_tx[r] - _fx[r]) * e, _fy[r] + (_ty[r] - _fy[r]) * e)


# 当前相对烘焙朝向的增量角（度）。转完是 0
func get_angle_deg(r: int) -> float:
	if r < 0 or r >= _row:
		return 0.0
	var adur: float = _adur[r]
	if adur <= 0.0:
		return 0.0
	return _ang[r] * (1.0 - _ease(_at[r] / adur))


# ---------------- 每帧推进 ----------------

# 推进所有在跑动画的行，并把新的位置/角度写进缓冲。
# 缓冲改没改由 consume_dirty() 告诉调用方（一帧上传一次）
func advance(delta: float) -> void:
	#删台留下的隐藏段在这里统一抹掉（全 0 = 零尺度退化三角形，GPU 成本可忽略）
	_flush_hides()
	var n: int = _active.size()
	if n <= 0:
		return
	var keep: int = 0
	for i in n:
		var r: int = _active[i]
		var busy: bool = false
		var rot_ended: bool = false
		var dur: float = _dur[r]
		if dur > 0.0:
			var t: float = _t[r] + delta
			if t >= dur:
				_t[r] = dur
				_dur[r] = 0.0
				_fx[r] = _tx[r]
				_fy[r] = _ty[r]
			else:
				_t[r] = t
				busy = true
		var adur: float = _adur[r]
		if adur > 0.0:
			var ta: float = _at[r] + delta
			if ta >= adur:
				_at[r] = adur
				_adur[r] = 0.0
				_ang[r] = 0.0
				#_rtflag 留给下面写缓冲时消费：收尾帧仍要走重铺分支
				rot_ended = true
			else:
				_at[r] = ta
				busy = true
		#到位那一帧也要写一次：最后停的位置/角度就是这一帧的值
		_write_row(r, rot_ended)
		if busy:
			_active[keep] = r
			keep += 1
		else:
			_inact[r] = 0
	if keep < n:
		_active.resize(keep)


# ---------------- 内部 ----------------

static func _ease(t: float) -> float:
	var k: float = t
	if k < 0.0:
		k = 0.0
	elif k > 1.0:
		k = 1.0
	return k * k * (3.0 - 2.0 * k)


func _add_active(r: int) -> void:
	if _inact[r] != 0:
		return
	_inact[r] = 1
	_active.append(r)


func _drop_from_active(r: int) -> void:
	if r < 0 or r >= _inact.size() or _inact[r] == 0:
		return
	_inact[r] = 0
	var n: int = _active.size()
	for i in n:
		if _active[i] == r:
			_active.remove_at(i)
			return


func _move_row(src: int, dst: int) -> void:
	if src == dst:
		return
	_start[dst] = _start[src]
	_parts[dst] = _parts[src]
	_fx[dst] = _fx[src]
	_fy[dst] = _fy[src]
	_tx[dst] = _tx[src]
	_ty[dst] = _ty[src]
	_t[dst] = _t[src]
	_dur[dst] = _dur[src]
	_ang[dst] = _ang[src]
	_at[dst] = _at[src]
	_adur[dst] = _adur[src]
	_rtflag[dst] = _rtflag[src]
	_tpl[dst] = _tpl[src]
	_tplx[dst] = _tplx[src]
	_tply[dst] = _tply[src]


func _alloc_slot(parts: int) -> int:
	var pool = _free.get(parts, null)
	if pool != null and not (pool as Array).is_empty():
		#复用前先把「待隐藏」抹掉：否则那一段的 0 会盖掉新台刚铺好的数据
		_flush_hides()
		var s: int = int((pool as Array).pop_back())
		_inst_total += parts
		return s
	var s2: int = _inst_total
	_inst_total += parts
	_ensure_cap(_inst_total)
	return s2


func _ensure_cap(need: int) -> void:
	if need <= _cap_inst:
		return
	var cap: int = maxi(_cap_inst * 2, 64)
	while cap < need:
		cap *= 2
	_cap_inst = cap
	if _buf.size() < cap * STRIDE:
		_buf.resize(cap * STRIDE)
	_dirty = true


# 把模板整段铺进缓冲（新建 / 模板更新时一次）
func _paint_tpl(r: int) -> void:
	var parts: int = _parts[r]
	if parts <= 0:
		return
	var tpl: PackedFloat32Array = _tpl[r]
	if tpl.size() < parts * STRIDE:
		return
	var base: int = _start[r] * STRIDE
	if base + parts * STRIDE > _buf.size():
		return
	for k in parts:
		var ii: int = base + k * STRIDE
		var t0: int = k * STRIDE
		for j in STRIDE:
			_buf[ii + j] = tpl[t0 + j]
	_dirty = true


func _hide_slot(start: int, parts: int) -> void:
	_dirty_hide.append(start)
	_dirty_hide.append(parts)
	_dirty = true


# 全 0 transform = 缩放 0 的退化三角形，GPU 成本可忽略
func _flush_hides() -> void:
	if _dirty_hide.is_empty():
		return
	var i: int = 0
	var n: int = _dirty_hide.size()
	while i < n:
		var start: int = _dirty_hide[i]
		var parts: int = _dirty_hide[i + 1]
		var sb: int = start * STRIDE
		var eb: int = (start + parts) * STRIDE
		var k: int = sb
		while k < eb and k < _buf.size():
			_buf[k] = 0.0
			k += 1
		i += 2
	_dirty_hide = PackedInt32Array()
	_dirty = true


# 写一台的实例段：纯平移只改 2 个 float；转向帧先从模板恢复 scale 再绕格心转。
# force_rot = true 时即使 _adur 已归零也走重铺分支：转向收尾那一帧必须把模板
# 的原始 scale 写回去，否则上一帧转歪的基向量会永久留在缓冲里
func _write_row(r: int, force_rot: bool) -> void:
	var dur: float = _dur[r]
	var px: float
	var py: float
	if dur > 0.0:
		var e: float = _ease(_t[r] / dur)
		px = _fx[r] + (_tx[r] - _fx[r]) * e
		py = _fy[r] + (_ty[r] - _fy[r]) * e
	else:
		px = _tx[r]
		py = _ty[r]
	var tpl: PackedFloat32Array = _tpl[r]
	if tpl.is_empty():
		return
	var parts: int = _parts[r]
	var base: int = _start[r] * STRIDE
	var dx: float = px - _tplx[r]
	var dy: float = py - _tply[r]
	var adur: float = _adur[r]
	if adur > 0.0 or force_rot:
		var ang: float = 0.0
		if adur > 0.0:
			ang = _ang[r] * (1.0 - _ease(_at[r] / adur))
		var cx: float = px + _gx * 0.5
		var cy: float = py + _gy * 0.5
		var rad: float = 0.0
		var cs: float = 1.0
		var sn: float = 0.0
		if absf(ang) > ANGLE_EPS_DEG:
			rad = deg_to_rad(ang)
			cs = cos(rad)
			sn = sin(rad)
		for k in parts:
			var ii: int = base + k * STRIDE
			var t0: int = k * STRIDE
			var txx: float = tpl[t0 + 0]
			var tyx: float = tpl[t0 + 1]
			var txy: float = tpl[t0 + 4]
			var tyy: float = tpl[t0 + 5]
			var ox: float = tpl[t0 + 3] + dx - cx
			var oy: float = tpl[t0 + 7] + dy - cy
			_buf[ii + 0] = cs * txx - sn * txy
			_buf[ii + 4] = sn * txx + cs * txy
			_buf[ii + 1] = cs * tyx - sn * tyy
			_buf[ii + 5] = sn * tyx + cs * tyy
			_buf[ii + 3] = cx + cs * ox - sn * oy
			_buf[ii + 7] = cy + sn * ox + cs * oy
		_rtflag[r] = 0
		_dirty = true
		return
	if dx == 0.0 and dy == 0.0:
		return
	for k in parts:
		var ii: int = base + k * STRIDE
		var t0: int = k * STRIDE
		_buf[ii + 3] = tpl[t0 + 3] + dx
		_buf[ii + 7] = tpl[t0 + 7] + dy
	_dirty = true
