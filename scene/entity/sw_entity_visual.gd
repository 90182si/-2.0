extends Node2D

# ==========================================================================
# 实体层动画：机器人移动滑块 + 旋转插值 + 选中光框
#
# 为什么必须单独一层：机器人画在 SWDrawManager 的 chunk MultiMesh 里，是整块烘焙的
# （位置和朝向都烤进实例数据里），没有「某台临时挪个位置 / 转个角度」的接口。
# 所以一旦这台要动，就把它从烘焙层撤下来（SWEntityLayerSystem.detach_render），
# 由这里用一个独立的 MultiMesh 逐帧重写实例：位置插值 + 在烘焙好的基上再补一个增量角。
#
# 「撤下来就不再交还」是刻意的：交还要走 addBuild -> 区块重建，而区块重建是分帧的，
# 中间会有一两帧既不画动画层、烘焙层也还没把机器人生出来 —— 不选中的那台没有光框衬托，
# 看上去就是「闪一下瞬移」。所以接管后一直留在这层，直到这一台被删 / 场景清空。
#
# 万级规模的两个关键设计（这两条是 1 万台不卡的前提，动之前先读）：
#   1. 动画状态与实例缓冲交给批处理对象（_batch），不放在本类的 Array[Dictionary] 里。
#      每台每帧只写 2 个 float（纯平移），但用 Dictionary 存状态的话光取字段就要
#      4.3us/台，一万台即 43ms/帧，全是解释器开销。_batch 有原生实现（GDExtension），
#      没有就退回 GDScript 版，两者接口一致，改一行常量就能测两条路。
#   2. 每台占渲染缓冲里固定的一段实例槽，写缓冲只写「本帧真在动的那几台」。
#      早期写法是每次 start_move 就全量重写所有实例 —— 2500 台/拍 × 1 万台是平方级，
#      真机上一个节拍就要几十秒。
#
# 选中不改烘焙层：直接在 _draw 里画一圈光框（进场收缩 -> 持续呼吸 -> 取消淡出），
# 选中底色（buildState.mask_color）照旧由实例 tint 负责，重铺模板时一并带上。
#
# 逐帧推进由 SWEntityLayerSystem.frame() 调 advance() 驱动（不自己开 _process）：
# 这样 headless 测试可以直接 sys.frame(0.2) 手动把动画走完，不用等真实帧。
# ==========================================================================

#动画渲染载体：直接复用区块节点的场景（自带 shader 材质 / MultiMesh / QuadMesh），
#这样滑块的像素表现和烘焙出来的那台逐像素一致，不会一格白一格黄
const MM_SCENE := preload("res://render/sw_multi_mesh_instance_2d.tscn")
#动画状态与实例缓冲的 GDScript 实现（原生类不可用时的兜底）
const BATCH_GD := preload("res://scene/entity/sw_anim_batch_gd.gd")
#原生实现（gdext/src/sw_anim_batch.{h,cpp}）的全局类名
const BATCH_NATIVE := &"SWAnimBatch"

#一格滑动时长。节拍 250ms，留出 90ms 停顿才看得出「走一格」而不是「一直在飘」
const MOVE_SEC: float = 0.16
#转向时长：比移动略长一点，90° 转太快会看不出来
const ROTATE_SEC: float = 0.20
#选中光框：进场收缩时长 / 取消淡出时长 / 呼吸周期
const GLOW_IN_SEC: float = 0.14
const GLOW_FADE_SEC: float = 0.12
const GLOW_BREATH_SEC: float = 1.1
const GLOW_COLOR: Color = Color(0.45, 0.82, 1.0, 1.0)
#框选矩形：加选（Ctrl+左键拖）青色，减选（Ctrl+右键拖）红色 ——
#与手持层那套建筑框选同一套颜色语言，玩家不用重新学一遍
const BOX_ADD_COLOR: Color = Color(0.557, 1.0, 1.0, 1.0)
const BOX_SUB_COLOR: Color = Color(1.0, 0.2, 0.2, 1.0)

#宿主系统（SWEntityLayerSystem，由图层在 attach 时注入）。存成无类型：
#新脚本的类名不在 headless 的全局类缓存里，当静态类型标注用会直接解析失败
var _system = null

var _mm: SWMultiMeshInstance2D = null

#动画状态 + 实例缓冲（见文件头「万级规模的两个关键设计」）
var _batch = null
#行号 -> 实体 / 渲染代理。模板（tint + 烘焙朝向）要靠它们重新生成，
#所以必须与 _batch 的行号严格对齐。
#注意：「实体 -> 行号」的反向映射**不在这里**，存在实体自己的 anim_row 字段上
#（一拍上万台要问上万次，字典查不划算，理由见 sw_robot_entity.gd）
var _ents: Array = []
var _comps: Array = []

#本拍新建过行：容量的 instance_count / visible_count 拖到 flush 时一次性拔
#（新建一台就改一次 MultiMesh 属性，首拍上万台就是上万次属性写入）
var _meta_dirty: bool = false
#当前批处理有没有 rotate_tpl（原生类可能还是旧构建产物，没有就退回重铺）
var _can_rotate_tpl: bool = false

#选中光框：看着哪台、淡出时画在哪、进场计时
var _glow_entity = null
var _glow_pos: Vector2 = Vector2.ZERO
var _glow_t: float = 0.0
var _glow_fading: bool = false

#框选矩形（世界坐标）+ 是否减选。画在本层而不是手持层：
#机器人场景没有 build system，手持层那圈框选选的是建筑
var _box_active: bool = false
var _box_rect: Rect2 = Rect2()
var _box_subtract: bool = false

#_draw 跑过几次（测试用：headless 下确认光框真的画了）
var draw_count: int = 0
#实例缓冲提交过几次（测试用：确认旋转/选中真的重写了实例缓冲）
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
#返回 false = 不接（没渲染代理），调用方要立刻把这一台按原地口径重新入表。
#热路径：一拍会有上千台走到这里，所以这里**不写实例缓冲**，只改时间参数并把这台
#挂进批处理的待推进表；真正的 float 改写由下一帧 advance 统一做（一帧一次，一次一段）
func start_move(e, from_pos: Vector2i, to_pos: Vector2i) -> bool:
	#新建行的模板直接生成在**出发格**上：这样批处理只要终点，
	#起点就是模板原点；已经接管的从当前插值位置续上（连点步进 / 一拍多格时不会跳）
	var r: int = _ensure_unit(e, Vector2(from_pos))
	if r < 0:
		return false
	_batch.set_move(r, Vector2(to_pos), MOVE_SEC)
	return true

#接管一台（没有就建行），返回行号；-1 = 接不了。
#热路径上节拍循环只调这个（每台首次一次），之后自己攒行号，不再进本类
func adopt(e, base_pos: Vector2i) -> int:
	return _ensure_unit(e, Vector2(base_pos))

#批量起滑：节拍循环已经攒好了 (行号, 终点xy)，这里直接转给批处理（零复制，
#PackedArray 按引用传参、两边都只读）。逐台 set_move 在一万台规模下要多 15ms
func start_moves(rows: PackedInt32Array, to_xy: PackedFloat32Array,
		dur: float = MOVE_SEC) -> void:
	if _batch != null:
		_batch.start_moves(rows, to_xy, dur)

#开始一次转向：from_dir -> to_dir（0..3，顺时针）。item.rotation 已经改成新朝向，
#所以渲染时要补一个「从旧朝向转过来」的负角度，插到 0 就是新朝向。
#⚠ 补角补到 0 之后画面上就是**模板里烘的朝向**，所以模板必须已经按新朝向生成：
#  - 新建行：模板是按当下（新）朝向烘的，直接用
#  - 已接管的行：模板还烘着它进动画层那一刻的旧朝向，必须重铺一次。
#    漏了这一步的表现是「第二次转向起，转完又弹回老朝向」，久了一直朝一个方向
func start_rotate(e, from_dir: int, to_dir: int) -> bool:
	var reused: bool = e != null and int(e.anim_row) >= 0
	var r: int = _ensure_unit(e, Vector2(e.grid_pos))
	if r < 0:
		return false
	#沿顺时针扫描的角度：只转一格就是 90°，跨 0 也不会绕远路（fposmod 处理 270->0）
	var sweep: float = fposmod(float(to_dir - from_dir) * 90.0, 360.0)
	#已有的行：模板原地转（机器人是单部件、原点就在格心，与重烘等价，便宜两个数量级）；
	#它转不了（多部件/跨格偏移）或原生没这个方法，才老老实实按新朝向重铺
	if reused and not (_can_rotate_tpl and bool(_batch.rotate_tpl(r, sweep))):
		_rewrite_unit_of(e)
	_batch.set_rotate(r, sweep, ROTATE_SEC if sweep > 1.0 else 0.0)
	return true

#把本拍攒下的东西一次提交：容量/可见数。
#节拍末尾调一次（SWEntityLayerSystem.step_beat_low）；advance 开头也兜一次，
#这样不经节拍直接调 rotate_entity 的路径最多晚一帧生效
func flush_pending() -> void:
	if _batch == null:
		return
	if _meta_dirty:
		_meta_dirty = false
		_flush_meta()

#推进一帧。只跑**真的在动**的那几台，只重写它们自己的实例段；
#全静止时连缓冲都不传（consume_dirty 为 false，一帧零上传）
func advance(delta: float) -> void:
	if _batch != null:
		#帧回调也兜一次攒批：rotate/push 不经节拍直接调用时不会漏（最多晚一帧）
		flush_pending()
		_batch.advance(delta)
		_flush_buf()
	_advance_glow(delta)

#这台是不是已经由动画层接管（不再回烘焙层）
func has_unit(e) -> bool:
	return _find_row(e) >= 0

func get_unit_count() -> int:
	return _batch.get_unit_count() if _batch != null else 0

#本帧还有多少台在跑动画（排障/测试用）
func get_active_count() -> int:
	return _batch.get_active_count() if _batch != null else 0

#这台正在跑移动 / 旋转动画
func is_busy(e) -> bool:
	var r: int = _find_row(e)
	return _batch != null and r >= 0 and bool(_batch.is_busy(r))

#有没有任何一台在跑动画
func is_animating() -> bool:
	return get_active_count() > 0

#这一台当前插值到的世界坐标（格子左上角）。测试与光框跟位都用它
func get_unit_pos(e) -> Vector2:
	var r: int = _find_row(e)
	if _batch == null or r < 0:
		return Vector2.ZERO
	return _batch.get_pos(r)

#这一台当前相对烘焙朝向的增量角（度）。旋转动画跑完就是 0
func get_unit_angle_delta(e) -> float:
	var r: int = _find_row(e)
	if _batch == null or r < 0:
		return 0.0
	return _batch.get_angle_deg(r)

#这一台在批处理里的行号（-1 = 没接管）
func _find_row(e) -> int:
	if e == null:
		return -1
	return int(e.anim_row)

#拿到（必要时创建）批处理对象。原生优先，没有就用 GDScript 版
func _ensure_batch():
	if _batch != null:
		return _batch
	if ClassDB.class_exists(BATCH_NATIVE):
		_batch = ClassDB.instantiate(BATCH_NATIVE)
	if _batch == null:
		_batch = BATCH_GD.new()
	if _batch != null:
		_batch.setup(SwDefine.GRID_SIZE)
		_can_rotate_tpl = _batch.has_method("rotate_tpl")
	return _batch

#确保这一台已被接管，返回它的行号（-1 = 接不了）。
#base_pos = 模板要生成在哪个世界坐标（只在新建行时用得上）
func _ensure_unit(e, base_pos: Vector2) -> int:
	if e == null or e.draw_item == null:
		return -1
	var r: int = int(e.anim_row)
	if r >= 0:
		return r
	var b = _ensure_batch()
	if b == null:
		return -1
	#渲染代理缓存进 _comps：每帧都去 getRenderableCompoent() 是万台时的固定税
	var comp = e.draw_item.getRenderableCompoent()
	if comp == null:
		return -1
	var parts: int = int(comp.getRenderPartCount())
	if parts <= 0:
		return -1
	var tpl: PackedFloat32Array = _make_tpl(e, comp, base_pos, parts)
	if tpl.is_empty():
		return -1
	r = int(b.add_unit(tpl, base_pos.x, base_pos.y))
	if r < 0:
		return -1
	_ents.resize(r + 1)
	_comps.resize(r + 1)
	_ents[r] = e
	_comps[r] = comp
	e.anim_row = r
	#只按容量与计数把它纳入可见范围，不在这里传整块缓冲：
	#上万台首次接管时每人一次全量上传是 GB 级，数据留给本帧的 advance 统一传一次。
	#容量属性也拖到 flush_pending 一次拔（首拍一万台就是一万次属性写 + 一万次容器 resize）
	_meta_dirty = true
	return r

#彻底不管这一台（实体被删 / 解绑）：摘掉记录，把那一段隐藏、槽位留给下一台
func release(e) -> void:
	if e == null:
		return
	var r: int = int(e.anim_row)
	if r < 0:
		return
	var b = _batch
	#批处理内部是 swap-remove：最后一台被搬到 r 上，平行表要同步搬（只在删台时走）
	var last: int = int(b.get_unit_count()) - 1
	e.anim_row = -1
	b.remove_unit(r)
	if r != last and r < int(b.get_unit_count()):
		_ents[r] = _ents[last]
		_comps[r] = _comps[last]
		if _ents[r] != null:
			_ents[r].anim_row = r
	_ents.resize(last)
	_comps.resize(last)
	if last <= 0:
		_reset_buffer()
		return
	_meta_dirty = false
	_flush_meta()

#把实例缓冲与容量全部归零（删光 / 清场）
func _reset_buffer() -> void:
	if _batch != null:
		_batch.reset()
	var node := _ensure_mesh()
	if node == null or node.multimesh == null:
		return
	node.multimesh.visible_instance_count = 0
#endregion

#region 实例缓冲
#生成「这一台站在 pos 处」的完整实例段（parts × stride）。
#模板里的缩放 / style_id / net_id / 调色板 / tint 都与位置无关，位置每帧只是
#「模板原点 + 位移」。不重跑 writeInstances 是因为它每台要做 cos/sin +
#图集登记 + 混色，实测 9us/台/帧 —— 一万台就是 90ms 白费
func _make_tpl(e, comp, pos: Vector2, parts: int) -> PackedFloat32Array:
	var stride: int = SWBuildCompoentRenderable.INSTANCE_STRIDE
	var tmp := PackedFloat32Array()
	tmp.resize(parts * stride)
	var written: int = comp.writeInstances(tmp, 0, pos.x, pos.y,
			float(SwDefine.GRID_SIZE.x), float(SwDefine.GRID_SIZE.y),
			e.draw_item.buildState.mask_color, parts)
	#部件数对不上就不接管：接管了也会在后续每帧的段长校验里被丢掉
	if written != parts:
		return PackedFloat32Array()
	return tmp

#重铺某一台的模板（选中底色变了：tint 是烘进实例里的，得重新生成一次；
#转向时也是它：朝向同样烘在模板里）。只碰这一台，不为一次点选重写上万台
func _rewrite_unit_of(e) -> void:
	var r: int = _find_row(e)
	if r < 0 or _batch == null:
		return
	var comp = _comps[r]
	if comp == null or e == null or e.draw_item == null:
		return
	var pos: Vector2 = _batch.get_pos(r)
	var parts: int = int(comp.getRenderPartCount())
	if parts <= 0:
		return
	var tpl: PackedFloat32Array = _make_tpl(e, comp, pos, parts)
	if tpl.is_empty():
		return
	_batch.refresh_tpl(r, tpl, pos.x, pos.y)

#只把容量与可见数拔到位、不传数据：新建台时用
func _flush_meta() -> void:
	var node := _ensure_mesh()
	if node == null or node.multimesh == null or _batch == null:
		return
	var mm: MultiMesh = node.multimesh
	var cap: int = _batch.get_capacity()
	#visible 超过 instance_count 时引擎会直接拒绝并报错，所以容量先跟上
	if mm.instance_count != cap:
		mm.instance_count = cap
	mm.visible_instance_count = _batch.get_visible_count()

#一帧只提交一次缓冲。没改动时（consume_dirty 为 false）什么都不做
func _flush_buf() -> void:
	if _batch == null or not _batch.consume_dirty():
		return
	var node := _ensure_mesh()
	if node == null or node.multimesh == null:
		return
	var mm: MultiMesh = node.multimesh
	var cap: int = _batch.get_capacity()
	var vis: int = _batch.get_visible_count()
	if cap <= 0 or vis <= 0:
		mm.visible_instance_count = 0
		return
	var data: PackedFloat32Array = _batch.get_buffer()
	#set_buffer 要求长度与 instance_count 严格匹配（多了少了都会报错）
	if data.size() != cap * SWBuildCompoentRenderable.INSTANCE_STRIDE:
		return
	if mm.instance_count != cap:
		mm.instance_count = cap
	mm.set_buffer(data)
	mm.visible_instance_count = vis
	mm.emit_changed()
	rebuild_count += 1

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

#动画层自己的 MultiMesh 节点（测试用：确认真的提交了可见实例）
func get_anim_mesh():
	return _mm
#endregion

#region 选中光框
#on = true：开始盯着这一台；on = false：这一台取消选中，光框淡出
func set_glow(e, on: bool) -> void:
	var prev = _glow_entity
	if on:
		if e == null:
			return
		_glow_entity = e
		_glow_pos = Vector2(e.grid_pos)
		_glow_t = 0.0
		_glow_fading = false
		#选中色是烘进实例 tint 的：被接管的那几台得重铺一次才变得过来。
		#只重写刚取消的那台和刚选中的这台 —— 为一次点选重写上万台是没必要的
		_rewrite_unit_of(prev)
		_rewrite_unit_of(e)
		_flush_buf()
		queue_redraw()
		return
	if _glow_entity != null and (e == null or _glow_entity == e):
		_begin_fade()

func has_glow() -> bool:
	return _glow_entity != null or _glow_fading
func get_glow_entity():
	return _glow_entity

#一批台的实例底色重刷（框选/多选）：底色是烘在模板 tint 里的，
#没被动画层接管的台 _rewrite_unit_of 自己会早退，所以整批丢进来就行。
#只在上传缓冲一次：逐台 _flush_buf 在上千台时就是上千次全量上传
func refresh_tints(ents: Array) -> void:
	if _batch == null or ents.is_empty():
		return
	for e in ents:
		_rewrite_unit_of(e)
	_flush_buf()

#框选矩形：active = false 收起。subtract = true 用红色（减选）
func set_box_rect(rect: Rect2, active: bool, subtract: bool = false) -> void:
	if _box_active == active and _box_rect == rect and _box_subtract == subtract:
		return
	_box_active = active
	_box_rect = rect
	_box_subtract = subtract
	queue_redraw()

#当前框选矩形（世界坐标）。没在框选时是空矩形；测试用
func get_box_rect() -> Rect2:
	return _box_rect if _box_active else Rect2()

func is_box_selecting() -> bool:
	return _box_active

#立刻清干净（清空实体 / 场景切换）：不淡出，直接没了
func cancel_all() -> void:
	#行号存回实体前先把它们全部作废：否则清场后旧实体会带着过期行号回来
	for i in _ents.size():
		var en = _ents[i]
		if en != null:
			en.anim_row = -1
	_ents.clear()
	_comps.clear()
	_meta_dirty = false
	_reset_buffer()
	_glow_entity = null
	_glow_fading = false
	_glow_t = 0.0
	_box_active = false
	_box_rect = Rect2()
	queue_redraw()

func _begin_fade() -> void:
	#先记下当前位置：实体可能已经删了，或者正在滑，淡出就该画在那儿
	var prev = _glow_entity
	_glow_pos = _glow_draw_pos()
	_glow_entity = null
	_glow_fading = true
	_glow_t = GLOW_FADE_SEC
	#取消选中也要把它那台底色从选中色改回去（同样只重写这一台）
	_rewrite_unit_of(prev)
	_flush_buf()
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
	var r: int = _find_row(_glow_entity)
	if r >= 0 and _batch != null:
		return _batch.get_pos(r)
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
	_draw_glow()
	_draw_box()

#框选矩形：半透明填充 + 实线边框。不进烘焙层也不进批处理 ——
#它只在拖拽过程中存在，画两笔就够
func _draw_box() -> void:
	if not _box_active:
		return
	var r: Rect2 = _box_rect.abs()
	if r.size.x < 1.0 and r.size.y < 1.0:
		return
	var c: Color = BOX_SUB_COLOR if _box_subtract else BOX_ADD_COLOR
	draw_rect(r, Color(c.r, c.g, c.b, 0.12), true)
	draw_rect(r, c, false, 2.0)

func _draw_glow() -> void:
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
