class_name SWEntityLayer extends SWLayer

# ==========================================================================
# 实体层（机器人场景）：只负责把机器人画出来
#
# 与 SWBuildLayer 同构：一个 SWLayer + 一个 SWDrawManager(useName="Entity")。
# 内容来源是实体系统里的 SWBuildManager（实体渲染代理），所以区块加载/卸载/
# 分帧限流/软缓存全部复用现成实现，这里只剩「转发视口 + 提交脏区块」。
#
#另挂一个 SWEntityVisual（代码创建，不进 tscn）：专管「动画的那一小部分」——
#移动中的机器人、转向中的机器人、选中光框。它们不进烘焙层，原因见那个文件头部。
# ==========================================================================

const ENTITY_SYSTEM := preload("res://scene/entity/sw_entity_layer_system.gd")
const VISUAL := preload("res://scene/entity/sw_entity_visual.gd")

@onready var sw_draw_manager: SWDrawManager = $SWDrawManager

#动画层（无类型：新脚本的类名不在 headless 全局类缓存里，当静态类型标注用会解析失败）
var _visual = null

func create_layer_system() -> SWLayerSystem:
	return ENTITY_SYSTEM.new()

func _ready() -> void:
	sw_draw_manager.set_name("entityDrawManager")
	sw_draw_manager.setDrawMode(SwDefine.GridDrawMode.ByContent)
	sw_draw_manager.useName = "Entity"
	_ensure_entity_manager()
	_ensure_visual()

#由 SWEntityLayerSystem.attach_view 注入：渲染层要拿同一张分区块表查区块内容
func attach_entity_manager(manager: SWBuildManager) -> void:
	sw_draw_manager.setBuildManager(manager)
	#系统已经接上了，动画层要拿到它（写实例时要查渲染代理）
	_ensure_visual()
	#系统可能晚一拍才接上（SWLayerManager 在父节点的 _ready 里才 attach_view），
	#所以在这里补绑一次；不能放在 _ensure_visual 里每次绑 —— 那是一台一次的热路径
	_bind_visual_system()

#兜底：系统侧没注入（单独实例化 / 测试）时从自己的 layer_system 补一次
func _ensure_entity_manager() -> void:
	if sw_draw_manager.sw_build_manager != null:
		return
	var system := layer_system
	if system == null:
		return
	var manager = system.get("entity_manager")
	if manager != null:
		sw_draw_manager.setBuildManager(manager)

#实体增删/移动/转向后提交脏区块（内容变了 => 整块重建，不做增量补丁）
func refresh_chunks(chunks: Array) -> void:
	if chunks.is_empty():
		return
	_ensure_entity_manager()
	var typed: Array[Vector2i] = []
	typed.assign(chunks)
	sw_draw_manager.updataChunks(typed)

func on_view_rect_changed(viewRect: Rect2, speedVec: Vector2) -> void:
	_ensure_entity_manager()
	sw_draw_manager.on_view_rect_changed(viewRect, speedVec)
	super.on_view_rect_changed(viewRect, speedVec)

#region 动画层转发（实体系统 -> SWEntityVisual）
#动画层在 SWDrawManager 之后 add_child：同 z_index 下靠树序排在烘焙区块上面
func _ensure_visual():
	if _visual != null and is_instance_valid(_visual):
		return _visual
	_visual = VISUAL.new()
	_visual.name = "SWEntityVisual"
	add_child(_visual)
	_bind_visual_system()
	return _visual

#把宿主系统告知动画层。只在「新建 / 系统接上」这两个时刻调：
#早期每次 _ensure_visual 都绑一遍，而 _ensure_visual 在一拍几千台的路径上 ——
#一万台就是一万次白调
func _bind_visual_system() -> void:
	if _visual != null and layer_system != null:
		_visual.bind_system(layer_system)

func get_visual():
	return _ensure_visual()

#实体系统问「这一台移动能不能给我做个滑块」
func start_visual_move(e, from_pos: Vector2i, to_pos: Vector2i) -> bool:
	var v = _ensure_visual()
	if v == null:
		return false
	return bool(v.start_move(e, from_pos, to_pos))

#实体系统问「这一台转向能不能给我做个角度插值」
func start_visual_rotate(e, from_dir: int, to_dir: int) -> bool:
	var v = _ensure_visual()
	if v == null:
		return false
	return bool(v.start_rotate(e, from_dir, to_dir))

#实体系统逐帧转进来的 delta（动画层不自己开 _process，方便 headless 测试手动推）
func advance_visual(delta: float) -> void:
	if _visual != null and is_instance_valid(_visual):
		_visual.advance(delta)

#不再管这一台（实体被删）：抹掉动画记录，不让它继续占着实例缓冲
func release_visual(e) -> void:
	if _visual != null and is_instance_valid(_visual):
		_visual.release(e)

func set_visual_glow(e, on: bool) -> void:
	var v = _ensure_visual()
	if v != null:
		v.set_glow(e, on)

#框选矩形：实体系统全程推世界坐标，真正落笔在动画层（这层是 Node，没 _draw）
func set_box_rect(rect: Rect2, active: bool, subtract: bool = false) -> void:
	var v = _ensure_visual()
	if v != null:
		v.set_box_rect(rect, active, subtract)

#框选/多选后把一批台的实例底色重铺一次（底色烘在 tint 里）
func refresh_visual_tints(ents: Array) -> void:
	var v = _ensure_visual()
	if v != null:
		v.refresh_tints(ents)

func cancel_visual() -> void:
	if _visual != null and is_instance_valid(_visual):
		_visual.cancel_all()

#节拍末尾：把本拍攒下的滑动登记一次提交给批处理
func flush_visual() -> void:
	if _visual != null and is_instance_valid(_visual):
		_visual.flush_pending()
#endregion
