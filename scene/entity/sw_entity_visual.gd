extends Node2D

# ==========================================================================
# 实体层动画：机器人移动滑块 + 旋转插值 + 选中光框
#
# 为什么必须单独一层：机器人画在 SWDrawManager 的 chunk MultiMesh 里，是整块烘焙的
# （位置和朝向都烤进实例数据里），没有「某台临时挪个位置 / 转个角度」的接口。
# 所以一旦这台要动，就把它从烘焙层撤下来（SWEntityLayerSystem.detach_render），
# 由这里用一个独立的小 MultiMesh 逐帧重写实例：位置插值 + 在烘焙好的基上再补一个增量角。
#
# 「撤下来就不再交还」是刻意的：交还要走 addBuild -> 区块重建，而区块重建是分帧的，
# 中间会有一两帧既不画动画层、烘焙层也还没把机器人生出来 —— 不选中的那台没有光框衬托，
# 看上去就是「闪一下瞬移」。所以接管后一直留在这层，直到这一台被删 / 场景清空。
#
# 选中不改烘焙层：直接在 _draw 里画一圈光框（进场收缩 -> 持续呼吸 -> 取消淡出），
# 选中底色（buildState.mask_color）照旧由实例 tint 负责，这里重写实例时一并带上。
#
# 逐帧推进由 SWEntityLayerSystem.frame() 调 advance() 驱动（不自己开 _process）：
# 这样 headless 测试可以直接 sys.frame(0.2) 手动把动画走完，不用等真实帧。
# ==========================================================================

#动画渲染载体：直接复用区块节点的场景（自带 shader 材质 / MultiMesh / QuadMesh），
#这样滑块的像素表现和烘焙出来的那台逐像素一致，不会一格白一格黄
const MM_SCENE := preload("res://render/sw_multi_mesh_instance_2d.tscn")

#一格滑动时长。节拍 250ms，留出 90ms 停顿才看得出「走一格」而不是「一直在飘」
const MOVE_SEC: float = 0.16
#转向时长：比移动略长一点，90° 转太快会看不出来
const ROTATE_SEC: float = 0.20
#选中光框：进场收缩时长 / 取消淡出时长 / 呼吸周期
const GLOW_IN_SEC: float = 0.14
const GLOW_FADE_SEC: float = 0.12
const GLOW_BREATH_SEC: float = 1.1
const GLOW_COLOR: Color = Color(0.45, 0.82, 1.0, 1.0)
#角度增量小于这个值就不用改写基向量（省掉纯平移时的浮点抖动）
const ANGLE_EPS_RAD: float = 0.002

#宿主系统（SWEntityLayerSystem，由图层在 attach 时注入）。存成无类型：
#新脚本的类名不在 headless 的全局类缓存里，当静态类型标注用会直接解析失败
var _system = null

var _mm: SWMultiMeshInstance2D = null

#被动画层接管的机器人，每项：
#  {e, pos_from: Vector2, pos_to: Vector2, t_move: float, move_dur: float,
#   ang_delta: float, t_ang: float, ang_dur: float}
#move_dur / ang_dur == 0 表示这一项没有正在跑的动画（位置/角度已经定格）。
var _units: Array = []

#选中光框：看着哪台、淡出时画在哪、进场计时
var _glow_entity = null
var _glow_pos: Vector2 = Vector2.ZERO
var _glow_t: float = 0.0
var _glow_fading: bool = false

#_draw 跑过几次（测试用：headless 下确认光框真的画了）
var draw_count: int = 0
#_sync_mesh 跑过几次（测试用：确认旋转/选中真的重写了实例缓冲）
var rebuild_count: int = 0

func _ready() -> void:
	_ensure_mesh()

#宿主系统
func bind_system(system) -> void:
	_system = system

func get_system():
	return _system

#region 动画
#开始一次滑动：from -> to 都用格子左上角的世界坐标。
#返回 false = 不接（没渲染代理），调用方要立刻把这一台按原地口径重新入表
func start_move(e, from_pos: Vector2i, to_pos: Vector2i) -> bool:
	var existed: bool = _find_unit(e) >= 0
	var u = _ensure_unit(e)
	if u == null:
		return false
	#已经接管的从当前插值位置续上（连点步进 / 一拍多格时不会跳一下）；
	#第一次接管的从旧格子出发
	var from_v: Vector2 = _cur_pos(u) if existed else Vector2(from_pos)
	u.pos_from = from_v
	u.pos_to = Vector2(to_pos)
	u.t_move = 0.0
	u.move_dur = MOVE_SEC
	_sync_mesh()
	return true

#开始一次转向：from_dir -> to_dir（0..3，顺时针）。item.rotation 已经改成新朝向，
#所以渲染时要补一个「从旧朝向转过来」的负角度，插到 0 就是新朝向
func start_rotate(e, from_dir: int, to_dir: int) -> bool:
	var u = _ensure_unit(e)
	if u == null:
		return false
	#沿顺时针扫描的角度：只转一格就是 90°，跨 0 也不会绕远路（fposmod 处理 270->0）
	var sweep: float = fposmod(float(to_dir - from_dir) * 90.0, 360.0)
	u.ang_delta = -sweep
	u.t_ang = 0.0
	u.ang_dur = ROTATE_SEC if sweep > 1.0 else 0.0
	_sync_mesh()
	return true

#推进一帧。只在这层真有动画在跑时才重写实例缓冲，全静止时零开销
func advance(delta: float) -> void:
	var dirty: bool = false
	for u: Dictionary in _units:
		if float(u.move_dur) > 0.0:
			var tm: float = float(u.t_move) + delta
			if tm >= float(u.move_dur):
				u.t_move = u.move_dur
				u.move_dur = 0.0
				u.pos_from = u.pos_to
			else:
				u.t_move = tm
			dirty = true
		if float(u.ang_dur) > 0.0:
			var ta: float = float(u.t_ang) + delta
			if ta >= float(u.ang_dur):
				u.t_ang = u.ang_dur
				u.ang_dur = 0.0
				u.ang_delta = 0.0
			else:
				u.t_ang = ta
			dirty = true
	if dirty:
		_sync_mesh()
	_advance_glow(delta)

#这台是不是已经由动画层接管（不再回烘焙层）
func has_unit(e) -> bool:
	return _find_unit(e) >= 0

func get_unit_count() -> int:
	return _units.size()

#这台正在跑移动 / 旋转动画
func is_busy(e) -> bool:
	var i: int = _find_unit(e)
	if i < 0:
		return false
	var u: Dictionary = _units[i]
	return float(u.move_dur) > 0.0 or float(u.ang_dur) > 0.0

#有没有任何一台在跑动画
func is_animating() -> bool:
	for u: Dictionary in _units:
		if float(u.move_dur) > 0.0 or float(u.ang_dur) > 0.0:
			return true
	return false

#这一台当前插值到的世界坐标（格子左上角）。测试与光框跟位都用它
func get_unit_pos(e) -> Vector2:
	var i: int = _find_unit(e)
	if i < 0:
		return Vector2.ZERO
	return _cur_pos(_units[i])

#这一台当前相对烘焙朝向的增量角（度）。旋转动画跑完就是 0
func get_unit_angle_delta(e) -> float:
	var i: int = _find_unit(e)
	if i < 0:
		return 0.0
	return _cur_angle_delta(_units[i])

func _find_unit(e) -> int:
	if e == null:
		return -1
	for i in _units.size():
		if _units[i].e == e:
			return i
	return -1

func _ensure_unit(e):
	if e == null or e.draw_item == null:
		return null
	var i: int = _find_unit(e)
	if i >= 0:
		return _units[i]
	var u := {
		"e": e,
		"pos_from": Vector2(e.grid_pos), "pos_to": Vector2(e.grid_pos),
		"t_move": 0.0, "move_dur": 0.0,
		"ang_delta": 0.0, "t_ang": 0.0, "ang_dur": 0.0,
	}
	_units.append(u)
	return u

#彻底不管这一台（实体被删 / 解绑）：抹掉记录并重写缓冲
func release(e) -> void:
	var i: int = _find_unit(e)
	if i < 0:
		return
	_units.remove_at(i)
	_sync_mesh()

func _cur_pos(u: Dictionary) -> Vector2:
	if float(u.move_dur) <= 0.0:
		return u.pos_to
	var t: float = clampf(float(u.t_move) / float(u.move_dur), 0.0, 1.0)
	#smoothstep：起步/收尾都软一点，匀速滑看着像「贴纸平移」
	t = t * t * (3.0 - 2.0 * t)
	return (u.pos_from as Vector2).lerp(u.pos_to, t)

func _cur_angle_delta(u: Dictionary) -> float:
	if float(u.ang_dur) <= 0.0:
		return 0.0
	var t: float = clampf(float(u.t_ang) / float(u.ang_dur), 0.0, 1.0)
	t = t * t * (3.0 - 2.0 * t)
	#t = 0：ang_delta（负的扫描角）=> 看起来还是旧朝向；t = 1：0 => 烘焙好的新朝向
	return lerpf(float(u.ang_delta), 0.0, t)
#endregion

#region 实例缓冲
func _ensure_mesh() -> SWMultiMeshInstance2D:
	if _mm != null and is_instance_valid(_mm):
		return _mm
	var node = MM_SCENE.instantiate()
	if node == null:
		return null
	_mm = node as SWMultiMeshInstance2D
	if _mm == null:
		return null
	_mm.name = "SWEntityAnimMesh"
	#实例坐标就是世界坐标，节点本身摆在原点（ByContent 模式 offset = 0）
	_mm.position = Vector2.ZERO
	#z_index 与烘焙区块同层，靠树序（本节点是 SWDrawManager 的弟弟）排在它上面
	_mm.setDrawMode(SwDefine.GridDrawMode.ByContent)
	_mm.setMeshSize(SwDefine.GRID_SIZE)
	#画在本节点自己的 _draw 之后：否则选中光框会被正在滑的那个盖住，
	#看上去就像「移动中的机器人没有高亮」
	_mm.show_behind_parent = true
	add_child(_mm)
	return _mm

#按当前插值位置/角度重写动画层实例。台数极少（绑了电路的机器人），
#而且只在真有动画在跑或选中态变化时才重写
func _sync_mesh() -> void:
	var node := _ensure_mesh()
	if node == null or node.multimesh == null:
		return
	var mm: MultiMesh = node.multimesh
	var stride: int = SWBuildCompoentRenderable.INSTANCE_STRIDE
	var total: int = 0
	for u: Dictionary in _units:
		total += _part_count(u.e)
	if total <= 0:
		mm.visible_instance_count = 0
		return
	var buf := PackedFloat32Array()
	buf.resize(total * stride)
	var gx: float = float(SwDefine.GRID_SIZE.x)
	var gy: float = float(SwDefine.GRID_SIZE.y)
	var half := Vector2(gx, gy) * 0.5
	var inst: int = 0
	for u: Dictionary in _units:
		var e = u.e
		if e.draw_item == null:
			continue
		var comp: SWBuildCompoentRenderable = e.draw_item.getRenderableCompoent()
		if comp == null:
			continue
		var p: Vector2 = _cur_pos(u)
		#writeInstances 每次现算世界坐标（没有跨帧缓存），正好拿来做插值
		var written: int = comp.writeInstances(buf, inst, p.x, p.y, gx, gy,
				e.draw_item.buildState.mask_color, total)
		if written <= 0:
			continue
		#旋转动画：烘焙出来的是整倍数朝向，这里在基向量上再补一个增量角
		var ang: float = deg_to_rad(_cur_angle_delta(u))
		if absf(ang) > ANGLE_EPS_RAD:
			_rotate_range(buf, inst, written, ang, p + half)
		inst += written
	if inst <= 0:
		mm.visible_instance_count = 0
		return
	if buf.size() != inst * stride:
		buf.resize(inst * stride)
	if mm.instance_count != inst:
		mm.instance_count = inst
	mm.set_buffer(buf)
	mm.visible_instance_count = inst
	mm.emit_changed()
	rebuild_count += 1

#动画层自己的 MultiMesh 节点（测试用：确认真的提交了可见实例）
func get_anim_mesh():
	return _mm

func _part_count(e) -> int:
	if e == null or e.draw_item == null:
		return 0
	var comp: SWBuildCompoentRenderable = e.draw_item.getRenderableCompoent()
	if comp == null:
		return 0
	return comp.getRenderPartCount()

#把 [start, start+count) 这段实例绕 cellCenter 转 ang 弧度。
#缓冲布局（见 writeInstances）：[0]=t.x.x [1]=t.y.x [3]=t.x 原点x
#                             [4]=t.x.y [5]=t.y.y [7]=t.y 原点y
#注意两个分量都在同一列上：t.x = (buf[0], buf[4])，别按行读
func _rotate_range(buf: PackedFloat32Array, start_inst: int, count: int,
		ang: float, cell_center: Vector2) -> void:
	var c: float = cos(ang)
	var s: float = sin(ang)
	var stride: int = SWBuildCompoentRenderable.INSTANCE_STRIDE
	for k in count:
		var i: int = (start_inst + k) * stride
		var txx: float = buf[i + 0]
		var tyx: float = buf[i + 1]
		var txy: float = buf[i + 4]
		var tyy: float = buf[i + 5]
		buf[i + 0] = c * txx - s * txy
		buf[i + 4] = s * txx + c * txy
		buf[i + 1] = c * tyx - s * tyy
		buf[i + 5] = s * tyx + c * tyy
		var ox: float = buf[i + 3] - cell_center.x
		var oy: float = buf[i + 7] - cell_center.y
		buf[i + 3] = cell_center.x + c * ox - s * oy
		buf[i + 7] = cell_center.y + s * ox + c * oy
#endregion

#region 选中光框
#on = true：开始盯着这一台；on = false：这一台取消选中，光框淡出
func set_glow(e, on: bool) -> void:
	if on:
		if e == null:
			return
		_glow_entity = e
		_glow_pos = Vector2(e.grid_pos)
		_glow_t = 0.0
		_glow_fading = false
		#选中色是烘进实例 tint 的：接管的那些必须重写一次缓冲才变得过来
		_sync_mesh()
		queue_redraw()
		return
	if _glow_entity != null and (e == null or _glow_entity == e):
		_begin_fade()
		_sync_mesh()

func has_glow() -> bool:
	return _glow_entity != null or _glow_fading

func get_glow_entity():
	return _glow_entity

#立刻清干净（清空实体 / 场景切换）：不淡出，直接没了
func cancel_all() -> void:
	_units.clear()
	_sync_mesh()
	_glow_entity = null
	_glow_fading = false
	_glow_t = 0.0
	queue_redraw()

func _begin_fade() -> void:
	#先记下当前位置：实体可能已经删了，或者正在滑，淡出就该画在那儿
	_glow_pos = _glow_draw_pos()
	_glow_entity = null
	_glow_fading = true
	_glow_t = GLOW_FADE_SEC
	queue_redraw()

func _advance_glow(delta: float) -> void:
	if _glow_fading:
		_glow_t -= delta
		if _glow_t <= 0.0:
			_glow_t = 0.0
			_glow_fading = false
		queue_redraw()
	elif _glow_entity != null:
		_glow_t += delta
		queue_redraw()

func _glow_draw_pos() -> Vector2:
	#被接管的（正在滑/正在转 / 已经接管过）：跟着滑块走，不跳到目标格
	var i: int = _find_unit(_glow_entity)
	if i >= 0:
		return _cur_pos(_units[i])
	#还没被接管过（刚放下就选中）：就是当初记下的那一格，不能退到世界原点
	return _glow_pos

#光框当前画在哪（世界坐标）。测试用
func get_glow_pos() -> Vector2:
	return _glow_draw_pos()

func _glow_alpha() -> float:
	if _glow_fading:
		return clampf(_glow_t / GLOW_FADE_SEC, 0.0, 1.0) * 0.9
	#进场 0 -> 1，之后原地呼吸（一眼能看出「这台是选中的」而不用盯着看）
	var k: float = clampf(_glow_t / GLOW_IN_SEC, 0.0, 1.0)
	var breathe: float = 0.62 + 0.38 * sin(_glow_t * TAU / GLOW_BREATH_SEC)
	return k * breathe

func _draw() -> void:
	draw_count += 1
	if not has_glow():
		return
	var a: float = _glow_alpha()
	if a <= 0.001:
		return
	var cell := Vector2(SwDefine.GRID_SIZE)
	var pos: Vector2 = _glow_draw_pos()
	#进场：1.3 倍收到 1.0 倍，之后定形
	var grow: float = 1.0
	if not _glow_fading and _glow_t < GLOW_IN_SEC:
		grow = lerpf(1.3, 1.0, _glow_t / GLOW_IN_SEC)
	var box: Vector2 = cell * grow
	var origin: Vector2 = pos + (cell - box) * 0.5
	var rect := Rect2(origin, box)
	draw_rect(rect, Color(GLOW_COLOR.r, GLOW_COLOR.g, GLOW_COLOR.b, a * 0.10), true)
	draw_rect(rect, Color(GLOW_COLOR.r, GLOW_COLOR.g, GLOW_COLOR.b, a * 0.95), false, 2.0)
	#四角勾边：一格只有 32px，2px 细框容易糊，带角标一眼就能认出来
	var c: float = minf(box.x, box.y) * 0.32
	var corner := Color(GLOW_COLOR.r, GLOW_COLOR.g, GLOW_COLOR.b, a)
	var right: float = origin.x + box.x
	var bottom: float = origin.y + box.y
	draw_line(Vector2(origin.x, origin.y), Vector2(origin.x + c, origin.y), corner, 3.0)
	draw_line(Vector2(origin.x, origin.y), Vector2(origin.x, origin.y + c), corner, 3.0)
	draw_line(Vector2(right, origin.y), Vector2(right - c, origin.y), corner, 3.0)
	draw_line(Vector2(right, origin.y), Vector2(right, origin.y + c), corner, 3.0)
	draw_line(Vector2(origin.x, bottom), Vector2(origin.x + c, bottom), corner, 3.0)
	draw_line(Vector2(origin.x, bottom), Vector2(origin.x, bottom - c), corner, 3.0)
	draw_line(Vector2(right, bottom), Vector2(right - c, bottom), corner, 3.0)
	draw_line(Vector2(right, bottom), Vector2(right, bottom - c), corner, 3.0)
#endregion
