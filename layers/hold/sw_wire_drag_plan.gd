# 电线拖拽路径规划：把「从 A 拖到 B」换算成一条最多拐一次 90° 弯的折线，
# 并决定沿途每一格放什么——空格放电线、被建筑物挡住的段落用一对隧道跨过去、
# 正穿过另一条电线的位置换成桥梁、已经是同一种电线的格子什么都不放（线照样连着走过去）。
# 拐点例外：那一格只要有东西（建筑、别人的电线、已铺的同种电线）就整条判非法（预览红线），
# 因为隧道跨不过拐弯、桥梁又会在同一格里把本线拆成两截。
# 纯逻辑：不碰场景、不碰渲染、不认识 build_manager，格子状态由调用方用 probe 回调提供，
# 这样拐一次弯、隧道跨度上限、相交判桥梁这些规则可以脱离游戏单独做单元测试。
class_name SWWireDragPlan extends RefCounted

#格子占用状态（probe(cell) 返回：低 2 位是状态，高位是这根电线的走向标记）
enum CellState {
	FREE,		#空格：要放电线（或隧道）
	SAME,		#已经是同一种电线：不用放，但路径要连着走过去
	BLOCKED,	#被别的建筑挡住：要么用隧道跨过去，要么整条判非法
}
const CELL_STATE_MASK := 3

#走向标记：probe 按位或上来，说「这一格的电线在横轴 / 纵轴上与自己那一头连着别的电线」。
#规划拿它与本页路径方向比对，垂直就是相交 → 换桥梁；只有单一垂直轴才算，
#双轴（三通 / 已是桥梁）换成桥会把别人已有的一条横（或竖）线并进我们这条线，不能动
const CELL_WIRE_HORZ := 1 << 2
const CELL_WIRE_VERT := 1 << 3

#每一格的处置
enum PlaceKind {
	WIRE,	#放一根电线
	TUNNEL,	#放隧道（永远成对：跳过障碍的那对里近端与远端各一格）
	KEEP,	#同种电线已在，什么都不放
	BRIDGE,	#与另一条电线相交：把那一格换成桥梁（两根 net 各走各的，不相交）
}

#拐点的选法：AUTO = 长边先走（默认）；另两个由玩家拖拽时「经过拐点」锁死，
#锁了就不再因为后段拖得更长而自动翻到另一个拐点上
enum CornerMode {
	AUTO,			#玩家没特意经过拐点：按长短自动选
	HORIZ_FIRST,	#先走横边再下竖边（拐点 = (to.x, from.y)）
	VERT_FIRST,		#先走竖边再下横边（拐点 = (from.x, to.y)）
}

#结果里的 reason 取值（非法时用于提示与排障）
const REASON_OK := &"ok"
const REASON_SPAN_TOO_LONG := &"span_too_long"	#被挡的段落超过 MAX_TUNNEL_DIS，跨不过去
const REASON_END_OCCUPIED := &"end_occupied"		#起点或终点被别的建筑占着
const REASON_CORNER_OCCUPIED := &"corner_occupied"	#拐点那一格有东西：拐弯处必须空着
const REASON_NO_ROOM := &"no_room"				#该放隧道的格子上已经有东西 / 隧道出口顶到了要换桥的交叉电线
const REASON_BENT_JUMP := &"bent_jump"			#被挡的段落跨过了拐弯处，隧道接不上直线

#锁拐点要求的「第一段」至少拖开几格：太短多半是鼠标抖动，不能算玩家有意拐这一刀
const MIN_LOCK_LEG := 2

static func world_of(cell: Vector2i) -> Vector2i:
	return cell * SwDefine.GRID_SIZE

static func cell_of(world_pos: Vector2) -> Vector2i:
	return Vector2i((world_pos / Vector2(SwDefine.GRID_SIZE)).floor())

#拖拽的拐点：默认哪条轴拖得远就先走哪条（先长后短，视觉上跟手的走向一致）；
#两条轴一样长时固定先横，保证同一个手势的结果稳定。
#玩家用鼠标锁过（见 lock_by_corner_visit）就一律听锁的，不再自动翻转
static func corner_of(from: Vector2i, to: Vector2i, mode: int = CornerMode.AUTO) -> Vector2i:
	if mode == CornerMode.HORIZ_FIRST:
		return Vector2i(to.x, from.y)
	if mode == CornerMode.VERT_FIRST:
		return Vector2i(from.x, to.y)
	var horiz_first: bool = absi(to.x - from.x) >= absi(to.y - from.y)
	return Vector2i(to.x, from.y) if horiz_first else Vector2i(from.x, to.y)

# 拖拽手势判拐点锁：A→B 有两个候选拐点，玩家想要哪个就把鼠标「踩」到哪个——
# visited 是本次拖拽经过的格子（按经过顺序），**后踩到的候选拐点顶掉先前锁定的那个**，
# 所以先扫过一边、再扫另一边就能改主意。
# 这一轮两个候选都没踩到就保持原走法（锁过的不会自动翻回 AUTO）；
# 拐点离起点不足 MIN_LOCK_LEG 格不算，那多半是按下时的鼠标抖动。
static func lock_by_corner_visit(from: Vector2i, to: Vector2i,
	visited: Array[Vector2i], locked: int = CornerMode.AUTO) -> int:
	var ch := Vector2i(to.x, from.y)
	var cv := Vector2i(from.x, to.y)
	#直线一笔时两个候选都与端点重合，没有「走哪边」的选择
	var can_h := ch != from and ch != to and _leg_long_enough(from, ch)
	var can_v := cv != from and cv != to and _leg_long_enough(from, cv)
	if not can_h and not can_v:
		return locked
	#从最近经过的格子往前找：最后被踩到的那个候选拐点说了算
	for i in range(visited.size() - 1, -1, -1):
		var cell: Vector2i = visited[i]
		if can_h and cell == ch:
			return CornerMode.HORIZ_FIRST
		if can_v and cell == cv:
			return CornerMode.VERT_FIRST
	return locked

static func _leg_long_enough(from: Vector2i, corner: Vector2i) -> bool:
	return absi(corner.x - from.x) + absi(corner.y - from.y) >= MIN_LOCK_LEG

# 两点之间按 Bresenham 走过的格子（8 邻接，不含起点、含终点）。
# 拖得快时鼠标事件会跳格，补上中间点才不漏掉「经过拐点」那一下。
static func line_cells(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var dx := absi(to.x - from.x)
	var dy := -absi(to.y - from.y)
	var sx := 1 if to.x > from.x else -1
	var sy := 1 if to.y > from.y else -1
	var err := dx + dy
	var cur := from
	while cur != to:
		var e2 := 2 * err
		if e2 >= dy:
			err += dy
			cur.x += sx
		if e2 <= dx:
			err += dx
			cur.y += sy
		out.append(cur)
	return out

#格子步进向量 → 行进方向（SW_Dir）；本规划里只走直线段，不会出现对角
static func dir_of(step: Vector2i) -> int:
	if step.x != 0:
		return SwDefine.SW_Dir.RIGHT if step.x > 0 else SwDefine.SW_Dir.LEFT
	return SwDefine.SW_Dir.DOWN if step.y > 0 else SwDefine.SW_Dir.UP

#折线覆盖的全部格子（含两端）：先走第一段到拐点，再从拐点走到终点
static func path_cells(from: Vector2i, to: Vector2i, mode: int = CornerMode.AUTO) -> Array[Vector2i]:
	var corner := corner_of(from, to, mode)
	var cells: Array[Vector2i] = [from]
	_append_leg(cells, from, corner)
	_append_leg(cells, corner, to)
	return cells

static func _append_leg(cells: Array[Vector2i], from: Vector2i, to: Vector2i) -> void:
	var step := Vector2i(signi(to.x - from.x), signi(to.y - from.y))
	var cur := from
	while cur != to:
		cur += step
		cells.append(cur)

# 规划一次拖拽（mode = 拐点选法，玩家锁过就听锁的；replace = 按住 Ctrl 要覆盖原有元件）：
#   {
#     valid: bool, reason: StringName,
#     path: Array[Vector2i],   # 折线原始格子（预览线就照它画，被跨过的格子也在里面）
#     cells: Array[Vector2i],  # 真正要落子的格子（被跨过的格子已剔除）
#     kinds: Array[int],       # 与 cells 一一对应：PlaceKind
#     rots: Array[int],        # 与 cells 一一对应：隧道用 SwDefine.SW_Dir（电线与桥梁无意义，填 0）
#     jumped: Array[Vector2i], # 被隧道跨过去、不放东西的格子
#     line: Array[Vector2i],   # 折线端点与拐点（画线用，最多 3 个点）
#   }
# 隧道的跨法：一段连续被挡的格子 [i,j)，长度 span≤MAX_TUNNEL_DIS；
# 挡在前面的那一格放「近端隧道」，挡在后面的第一格放「远端隧道」，中间 span 格空着不铺。
# 两根隧道的引脚必须相对（见 SWBuildWireTunnel.pinFaces）：
# 隧道出口在 rotation+1、入口在 rotation+3，所以 rot = posmod(朝对方的方向 + 3, 4)。
# 注意拐点已强制为空，所以「被挡段跨过拐弯」实际不可达（REASON_BENT_JUMP 留作防御分支）。
static func plan(from: Vector2i, to: Vector2i, probe: Callable,
	mode: int = CornerMode.AUTO, replace: bool = false) -> Dictionary:
	var cells := path_cells(from, to, mode)
	var line: Array[Vector2i] = [from]
	var corner := corner_of(from, to, mode)
	#直线一笔时 corner_of 给出的就是终点或起点：那儿并没有拐弯，
	#「拐角格不许放桥」的限制不能套到它头上，否则端点正好压在别人线上就会误判堵
	var bent := corner != from and corner != to
	if bent:
		line.append(corner)
	line.append(to)
	#拐点必须落在空格上：那一格只要有东西（建筑、别人的电线，或已经铺了同种电线），
	#这一笔就摆不顺了——隧道跨不过拐弯，桥梁又会在同一格里把本线拆成两截，一律判非法
	#（预览红线）。按 Ctrl 覆盖是例外：那一格会被拆掉重放电线，线仍然是连续的
	if bent and not replace and _raw(probe, corner) != 0:
		return _invalid(REASON_CORNER_OCCUPIED, cells, line)
	#端点：不覆盖时起点终点都必须落得下去（换成桥能接上的交叉不算堵）；按了 Ctrl 就抢过来放
	if not replace and (_blocked_here(probe, cells, 0, bent and cells[0] == corner)
		or _blocked_here(probe, cells, cells.size() - 1, bent and cells[cells.size() - 1] == corner)):
		return _invalid(REASON_END_OCCUPIED, cells, line)
	var out_cells: Array[Vector2i] = []
	var kinds: Array[int] = []
	var rots: Array[int] = []
	var jumped: Array[Vector2i] = []
	var i := 0
	while i < cells.size():
		var raw: int = _raw(probe, cells[i])
		var st: int = raw & CELL_STATE_MASK
		#正穿过另一条电线（只走垂直轴）：这一格换成桥梁，两条线各走各的 net
		#（原地一笔没拖动连方向都没有，谈不上相交）
		if cells.size() > 1 and is_crossing(raw, _leg_axis(cells, i), bent and cells[i] == corner):
			out_cells.append(cells[i])
			kinds.append(PlaceKind.BRIDGE)
			rots.append(0)
			i += 1
			continue
		if st != CellState.BLOCKED:
			out_cells.append(cells[i])
			kinds.append(PlaceKind.KEEP if st == CellState.SAME else PlaceKind.WIRE)
			rots.append(0)
			i += 1
			continue
		#Ctrl 覆盖：路面上的建筑一律拆掉换成电线，不再排隧道跳过去
		if replace:
			out_cells.append(cells[i])
			kinds.append(PlaceKind.WIRE)
			rots.append(0)
			i += 1
			continue
		var j := i
		#只有「真的堵」的格子才算进被跨段：能与本段交叉换桥的电线不是挡路的，它是落脚点。
		#⚠ 这里若只看 probe 低 2 位的 BLOCKED，压在别人垂直电线上的终点也会被算进这一段，
		#  扫描会一路拖到 cells.size()，下面的 cells[j] 直接越界（实测崩溃）。
		while j < cells.size() and _blocked_here(probe, cells, j, false):
			j += 1
		#挡到了路径尽头：远端隧道没有落脚点
		if j >= cells.size():
			return _invalid(REASON_NO_ROOM, cells, line)
		var span := j - i
		if span > SwDefine.MAX_TUNNEL_DIS:
			return _invalid(REASON_SPAN_TOO_LONG, cells, line)
		#端点已判过，这里近端一定存在（i>0）
		var near_idx: int = out_cells.size() - 1
		var near: Vector2i = out_cells[near_idx]
		if kinds[near_idx] != PlaceKind.WIRE:
			#近端已经是上一跳的出口隧道：一格放不下两根隧道
			return _invalid(REASON_NO_ROOM, cells, line)
		var dir := dir_of(cells[i] - near)
		var far := cells[j]
		#远端要放隧道，可它本身是要换成桥的交叉电线：一格容不下两样东西
		if is_crossing(_raw(probe, far), _leg_axis(cells, i), bent and far == corner):
			return _invalid(REASON_NO_ROOM, cells, line)
		#远端必须与近端同线且正好隔 span 格：拐弯正好被挡住时隧道接不上，只能判非法
		if far != near + SwDefine.dir_to_vec(dir) * (span + 1):
			return _invalid(REASON_BENT_JUMP, cells, line)
		kinds[near_idx] = PlaceKind.TUNNEL
		rots[near_idx] = posmod(dir + 3, 4)
		for k in range(i, j):
			jumped.append(cells[k])
		out_cells.append(far)
		kinds.append(PlaceKind.TUNNEL)
		rots.append(posmod(dir + 1, 4))
		i = j + 1
	return {
		"valid": true,
		"reason": REASON_OK,
		"path": cells,
		"cells": out_cells,
		"kinds": kinds,
		"rots": rots,
		"jumped": jumped,
		"line": line,
	}

static func _invalid(reason: StringName, path: Array[Vector2i],
	polyline: Array[Vector2i]) -> Dictionary:
	return {
		"valid": false,
		"reason": reason,
		"path": path,
		"cells": [],
		"kinds": [],
		"rots": [],
		"jumped": [],
		"line": polyline,
	}

#probe 没接上（纯逻辑跑测、或调用方没给查询）时一律当空格：
#规划退化成「整条铺电线」，与不裁剪前的行为一致，不会因为缺依赖而报错
static func _raw(probe: Callable, cell: Vector2i) -> int:
	if not probe.is_valid():
		return CellState.FREE
	return int(probe.call(cell))

#这一段路径走哪个轴（横线还是竖线）：用上一格到本格的步进判，起点只能用下一格
static func _leg_axis(cells: Array[Vector2i], i: int) -> int:
	var step: Vector2i = Vector2i(1, 0)
	if cells.size() > 1:
		step = cells[i] - cells[i - 1] if i > 0 else cells[1] - cells[0]
	return CELL_WIRE_HORZ if step.x != 0 else CELL_WIRE_VERT

#相交判定：这一格已有电线，而且它只走在与本页路径垂直的那个轴上 → 拿桥梁换掉它
#（桥的 v_net/h_net 分开两组，两条线各自连通、互不相干）。拐角格不能放桥：
#我们的两段线会落到桥的两根独立 net 上，反而把自己拆成两截
static func is_crossing(raw: int, leg_axis: int, at_corner: bool) -> bool:
	if at_corner or (raw & CELL_STATE_MASK) == CellState.FREE:
		return false
	#只垂直接过来才算相交；同轴（延线）与双轴（三通 / 已是桥梁）都别动
	return (raw & ~CELL_STATE_MASK) == (CELL_WIRE_HORZ if leg_axis == CELL_WIRE_VERT else CELL_WIRE_VERT)

#这一格是否真的堵住了：已是电线且能换成桥的交叉不算堵
static func _blocked_here(probe: Callable, cells: Array[Vector2i], i: int, at_corner: bool) -> bool:
	var raw: int = _raw(probe, cells[i])
	if (raw & CELL_STATE_MASK) != CellState.BLOCKED:
		return false
	return not is_crossing(raw, _leg_axis(cells, i), at_corner)
