class_name SWSplitScene extends Node

# ==========================================================================
# 分屏调试壳：左机器人 / 右电路，两个场景同时在树里各跑各的系统
#
# 由机器人 HUD 的「修改电路」进入。壳做四件事：
#   1. 托管全局单例（渲染纹理 / 区块对象池）：两个子场景的 _init 都是幂等的，
#      这里先建好，两边直接复用；退出时也由这里统一清池
#   2. 手摆两个 SubViewportContainer 的位置（左右各半，中间 8px 分隔条可拖）
#   3. 时钟相位锁：机器人每拍的电平写到右侧 clk 口，两边同拍
#   4. 暂停 / 应用：右侧改了电路结构 → 左侧立刻停拍；点「应用到机器人」
#      → 导出同名 .swcir → 左侧按最新电路重绑 → 恢复节拍
#
# 不用 HSplitContainer：它的 min-size 语义会跟「左右各半」打架（子场景里
# 有大量自绘控件，min size 会把分隔条顶住），自己算矩形更好测也更好控
# ==========================================================================

#跨场景会话：读「电路结构改过没有」；分屏标记也在这里（子场景退出时据此不清池）
const SESSION := preload("res://core/manager/sw_session.gd")
#机器人接口名的单一来源（detect_res_0..7 的取名与位序都在这里）
const ACTIONS := preload("res://scene/entity/sw_robot_actions.gd")
const ROBOT_SCENE := preload("res://scene/sw_robot_scene.tscn")
const LOGIC_SCENE := preload("res://scene/sw_logic_scene.tscn")
const ROBOT_SCENE_PATH: String = "res://scene/sw_robot_scene.tscn"

#分隔条宽度与左右比例下限/上限（拖到底也不会把某一侧挤没）
const HANDLE_WIDTH: float = 8.0
const MIN_RATIO: float = 0.2
const MAX_RATIO: float = 0.8
#顶栏：距半屏边缘留白 / 状态文字的理想宽度（放不下时按实际可用宽度收窄）
const BAR_MARGIN: float = 8.0
const STATUS_MIN_WIDTH: float = 220.0
#入场/退场动画时长：左机器人界面从全屏缩到左半屏，右电路界面从窗口右边缘滑入
const ANIM_SEC: float = 0.35

@onready var _pane_root: Control = $PaneRoot
@onready var _left_pane: SubViewportContainer = $PaneRoot/LeftPane
@onready var _left_view: SubViewport = $PaneRoot/LeftPane/LeftView
@onready var _handle: ColorRect = $PaneRoot/Handle
@onready var _right_pane: SubViewportContainer = $PaneRoot/RightPane
@onready var _right_view: SubViewport = $PaneRoot/RightPane/RightView
#顶栏：整体贴右半屏的右上角（详见 _place_topbar）
@onready var _bar: Control = $TopBar/Bar
@onready var _back_btn: Button = $TopBar/Bar/HBox/BackBtn
@onready var _status: Label = $TopBar/Bar/HBox/Status
@onready var _apply_btn: Button = $TopBar/Bar/HBox/ApplyBtn

#两个子场景实例（左机器人 / 右电路）
var left_scene: Node = null
var right_scene: Node = null
#左侧节拍器 / 右侧建筑层系统：相位锁与重绑都靠它们
var left_tick: Node = null
var right_build = null
#左侧实体系统：拿「时序图看的那台」机器人本拍的检测码
var left_entity_sys = null

#左半屏宽度（_layout 算好缓存给顶栏用）
var _pane_left_w: float = 0.0
#左侧宽度占比（0.2~0.8）
var ratio: float = 0.5
#左侧是否已因「电路结构改动」停拍
var _paused: bool = false
var _dragging: bool = false

# ===== 入场/退场动画 =====
# _intro 是布局进度：0 = 机器人界面占满全屏、电路界面整块停在窗口右边缘外；
# 1 = 左右各半（最终布局）。只插值三个矩形，不动子场景本身：
# 左视口尺寸随容器走（机器人界面重排，视口缩小到半屏），
# 右视口宽度固定、只平移（电路界面从右边缘滑入／滑出）
#测试可以设 0 直接到位（headless 里等 0.35s 等于白烧二十多帧）
var anim_sec: float = ANIM_SEC
var _intro: float = 1.0
var _anim: Tween = null
var _leaving: bool = false
#左侧场景是外面交过来的（HUD「修改电路」已把正在跑的机器人场景注入）：
#这种路径下不 instantiate 新的、也不 _ready 重来
var _adopted_left: bool = false
#左侧场景已经交还宿主（正常返回路径）：壳的 _exit_tree 不要再做收尾
var _vacated_left: bool = false

func _init() -> void:
	#渲染纹理单例必须先于任何烘焙/补丁创建一个（与两个子场景同口径）。
	#这里是分屏时唯一一次创建：子场景进来时 instance 已经不是空的，直接复用，
	#否则后建的那个会把单例换成自己的实例，先建那边所有材质的 uniform 全指到废纹理
	if SWSignalTexture.instance == null:
		SWStyleTexture.instance = SWStyleTexture.new()
		SWSignalTexture.instance = SWSignalTexture.create_backend()
		SWSignalTexture.instance.init()
	#回调挂在自己身上而不是子场景：分屏期间由壳活着，它一退就是整个分屏结束。
	#（回调本身只做「遍历 MESH_GROUP 重设 uniform」，挂谁都一样，关键是别指向已释放的节点）
	var refresh_cb := _refresh_texture_uniforms
	SWStyleTexture._refresh_cb = refresh_cb
	SWSignalTexture._palette_refresh_cb = refresh_cb
	#幂等：已预热就直接返回
	SWObjectPool.InitSWChunkDataObject()

#纹理扩容/调色板重建后刷新全部共享材质 uniform（遍历 MESH_GROUP）
func _refresh_texture_uniforms() -> void:
	if is_inside_tree():
		get_tree().call_group(SwAtlas.MESH_GROUP, "_resetShaderUniforms")

func _ready() -> void:
	#两个子场景同时在树里：告诉它们别在 _exit_tree 里清共享对象池
	SESSION.split_mode = true
	_left_pane.stretch = true
	_right_pane.stretch = true
	#两个子 viewport 都要开「内嵌子窗口」：Godot 的 tooltip 与下拉菜单本质是嵌入的 Window，
	#这个开关默认是 false，于是它们会按「独立 OS 窗口」去弹（位置按本半屏坐标算，
	#实际跑到窗口外面去了，看起来就是悬浮提示不显示）
	_left_view.gui_embed_subwindows = true
	_right_view.gui_embed_subwindows = true
	_handle.mouse_filter = Control.MOUSE_FILTER_STOP
	_handle.mouse_default_cursor_shape = Control.CURSOR_HSIZE
	_handle.gui_input.connect(_on_handle_gui_input)
	if _status != null:
		_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if _back_btn != null:
		_back_btn.pressed.connect(_on_back_pressed)
	if _apply_btn != null:
		_apply_btn.pressed.connect(_on_apply_pressed)
	#合最小宽变了（字体就绪 / 状态文案长短变了）就重摆一次，否则顶栏会停在上一次的位置
	if _bar != null:
		_bar.minimum_size_changed.connect(_place_topbar)
	#窗口尺寸变了要重摆三个矩形（子场景的相机各自跟自己的 viewport 走）
	_pane_root.resized.connect(_layout)
	_spawn_scenes()
	#接管进来的机器人场景先按「左满屏」摆好，再滑到左右各半：
	#玩家看到的是界面展开，而不是整块场景重建后重新加载
	if _adopted_left:
		_intro = 0.0
	_layout()
	_wire_split()
	_refresh_status()
	if _adopted_left:
		play_intro()

func _process(_delta: float) -> void:
	check_circuit_edited()

#右侧改了电路结构：左侧立刻停拍 + 顶栏提示 + 应用按钮可用。
#幂等：已经停过就不再动，恢复运行由「应用到机器人」负责。
#单独抽成方法是因为 headless 用例拿不到可靠的 _process 帧，直接调它就能验同一条链路
func check_circuit_edited() -> bool:
	if _paused or SESSION.edited_save.is_empty():
		return false
	_paused = true
	if left_tick != null:
		left_tick.call("pause")
	_refresh_status()
	return true

func _input(event: InputEvent) -> void:
	#分隔条拖动：按下收在 Handle 的 gui_input 里，移动/松手在这里处理。
	#不靠 gui_input 收移动是因为鼠标滑出 8px 宽的分隔条后那边就收不到事件了
	if not _dragging:
		return
	if event is InputEventMouseMotion:
		_drag_to_mouse()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_dragging = false
		get_viewport().set_input_as_handled()

#region 布局
func _layout() -> void:
	if _pane_root == null:
		return
	var total: float = _pane_root.size.x
	var height: float = _pane_root.size.y
	var handle_w: float = maxf(0.0, minf(HANDLE_WIDTH, total))
	var final_left_w: float = clampf(total * ratio - handle_w * 0.5, 0.0, maxf(0.0, total - handle_w))
	var final_right_x: float = final_left_w + handle_w
	var final_right_w: float = maxf(0.0, total - final_right_x)
	#入场进度插值：起点时左侧占满全宽（与进分屏前的视口尺寸一致，画面不跳）、
	#右侧整块停在窗口右边缘外；k=1 就是平常的左右各半。
	#右侧宽度全程不变（只平移）：电路场景的布局不会跟着动画每帧重排
	var k: float = clampf(_intro, 0.0, 1.0)
	var left_w: float = lerpf(total, final_left_w, k)
	var right_x: float = lerpf(total, final_right_x, k)
	_set_rect(_left_pane, Rect2(0.0, 0.0, left_w, height))
	_set_rect(_handle, Rect2(left_w, 0.0, handle_w, height))
	_pane_left_w = left_w
	_set_rect(_right_pane, Rect2(right_x, 0.0, final_right_w, height))
	#顶栏在动画期间随左半屏右边界左移，同时淡入
	if _bar != null:
		_bar.modulate.a = k
	_place_topbar()

#入场：机器人界面从全屏缩到左半屏，电路界面从窗口右边缘滑进右半屏
func play_intro() -> void:
	if _anim != null:
		_anim.kill()
		_anim = null
	_set_intro(0.0)
	if anim_sec <= 0.0:
		_set_intro(1.0)
		return
	_anim = create_tween()
	_anim.set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	_anim.tween_method(_set_intro, 0.0, 1.0, anim_sec)

#退场：反向播完再执行收尾（中途搬节点会黑一下，所以交给回调）
func _play_outro_then(cb: Callable) -> void:
	if _anim != null:
		_anim.kill()
		_anim = null
	if anim_sec <= 0.0:
		_set_intro(0.0)
		cb.call()
		return
	_anim = create_tween()
	_anim.set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_IN)
	_anim.tween_method(_set_intro, _intro, 0.0, anim_sec)
	_anim.finished.connect(cb, CONNECT_ONE_SHOT)

func _set_intro(p: float) -> void:
	_intro = clampf(p, 0.0, 1.0)
	_layout()

#顶栏贴左半屏的右上角：左半屏左上角是机器人场景自己的性能面板，顶栏压过去两边都看不清。
#宽度取子控件的合最小宽（Status 固定最小宽 + clip_text，长文案只会被截断）。
#坑：_ready 首帧子控件可能还没量过，直接读合最小宽会得到 0，随后引擎把 size 撑到最小宽——
#按默认 grow 方向向右撑就溢出到窗口外（看起来就是「没挪过去」）。所以先 reset_size 逼它量一次，
#tscn 里又把 grow_horizontal 设成 BEGIN：万一还是晚量到，也是向左长，右边保持贴右
func _place_topbar() -> void:
	if _bar == null:
		return
	_bar.reset_size()
	#左半屏被拖很窄时先让状态文字让位（clip_text 会截断），别把顶栏挤到右半屏去
	if _status != null:
		var chrome: float = maxf(0.0, _bar.size.x - _status.get_combined_minimum_size().x)
		var avail: float = maxf(0.0, _pane_left_w - BAR_MARGIN * 2.0)
		var want: float = clampf(avail - chrome, 0.0, STATUS_MIN_WIDTH)
		if not is_equal_approx(_status.custom_minimum_size.x, want):
			_status.custom_minimum_size.x = want
			_bar.reset_size()
	_bar.position = Vector2(maxf(0.0, _pane_left_w - BAR_MARGIN - _bar.size.x), BAR_MARGIN)

func _set_rect(c: Control, r: Rect2) -> void:
	if c == null:
		return
	c.position = r.position
	c.size = r.size

func _on_handle_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_dragging = true
		_handle.accept_event()

func _drag_to_mouse() -> void:
	var total: float = _pane_root.size.x
	if total <= 1.0:
		return
	#拖分隔条一定是在动画结束后：进度拉满，否则拖完还会被入场插值拉回去
	_intro = 1.0
	#用控件自己的局部鼠标坐标：拖到窗口边缘外也能算对，不用去接窗口坐标变换
	var x: float = _pane_root.get_local_mouse_position().x
	ratio = clampf(x / total, MIN_RATIO, MAX_RATIO)
	_layout()
#endregion

#region 装配
func _spawn_scenes() -> void:
	#左侧：调用方可能已经把「正在跑的机器人场景」交过来（HUD「修改电路」走这条路：
	#不重载机器人界面，机器人/相机/区块/选中状态全部沿用）。
	#没有的话自己起一份（直接进分屏壳的兜底路径，测试也是这条）
	var robot_owned: bool = left_scene == null or not is_instance_valid(left_scene)
	if not robot_owned:
		_adopted_left = true
	else:
		left_scene = ROBOT_SCENE.instantiate()
	left_scene.name = "LeftRobotScene"
	#交付过来的实例目前还挂在别的父节点下：Godot 4 的 add_child 不会自动搬家，
	#必须先摘下来再挂（搬家会触发 _exit_tree，靠 SESSION.relocating_scene 区分于真退出）
	if not robot_owned:
		var old_parent: Node = left_scene.get_parent()
		if old_parent != null:
			old_parent.remove_child(left_scene)
	_left_view.add_child(left_scene)
	right_scene = LOGIC_SCENE.instantiate()
	right_scene.name = "RightLogicScene"
	_right_view.add_child(right_scene)

func _wire_split() -> void:
	#两边各留一份 HUD（工具栏/面板都还要用），只隐掉重复的场景切换入口
	_set_hud_split_mode(left_scene, true)
	_set_hud_split_mode(right_scene, true)
	left_tick = _scene_call(left_scene, "get_robot_tick")
	left_entity_sys = _scene_call(left_scene, "get_entity_system")
	right_build = _scene_call(right_scene, "get_build_system")
	_wire_clock_phase()
	#右侧的性能统计面板收起来：两个 FPS 面板会把两个角都占住。
	#只收统计面板本身，不整块藏这个 CanvasLayer —— 跟随鼠标的建筑信息提示是它的子节点，
	#整块藏了右半屏「鼠标悬浮看元件信息」就没了
	var perf := right_scene.get_node_or_null("SWPerformanceMonitor")
	if perf != null:
		if perf.has_method("set_split_mode"):
			perf.call("set_split_mode", true)
		elif perf is CanvasLayer:
			(perf as CanvasLayer).visible = false
	#顶栏占了左半屏顶部那一条：左侧性能面板与右上角表达式面板都往下让开
	#（顶栏在左半屏右上角，而性能面板在左上角且展开后很宽，纵向躲开比横向挪靠谱）
	var bar_h: float = _bar.size.y + BAR_MARGIN
	var left_perf := left_scene.get_node_or_null("SWPerformanceMonitor")
	if left_perf != null and left_perf.has_method("set_top_inset"):
		left_perf.call("set_top_inset", bar_h)
	var left_hud = _hud_of(left_scene)
	if left_hud != null and left_hud.has_method("set_top_right_inset"):
		left_hud.call("set_top_right_inset", bar_h)

func _scene_call(scene: Node, method: String):
	if scene == null or not scene.has_method(method):
		return null
	return scene.call(method)

func _hud_of(scene: Node):
	var mgr = scene.get("sw_layer_manager") if scene != null else null
	return mgr.get("hudLayer") if mgr != null else null

func _set_hud_split_mode(scene: Node, on: bool) -> void:
	var hud = _hud_of(scene)
	if hud != null and hud.has_method("set_split_mode"):
		hud.call("set_split_mode", on)

#时钟相位锁：右侧不再按挂钟自走（external_clock = true），clk 口电平与时钟元件
#全由机器人节拍写，两边就同拍
func _wire_clock_phase() -> void:
	if left_tick == null or right_build == null:
		return
	if not left_tick.has_signal("phase_changed"):
		return
	right_build.external_clock = true
	var cb := Callable(self, "_on_phase_changed")
	#字符串 connect：left_tick 的静态类型是 Node，它的自定义信号在静态检查下看不到
	if not left_tick.is_connected("phase_changed", cb):
		left_tick.connect("phase_changed", cb)

func _on_phase_changed(high: bool) -> void:
	if right_build == null:
		return
	#先把机器人本拍的检测位镜到右侧同名输入接口，再推这一相位：
	#顺序反了的话数据位要等到下一个相位才进求值种子（灯会慢半拍）
	right_build.call("apply_input_levels", _collect_robot_inputs())
	#当场求值：步进时高/低两相位落在同一帧里，若等右侧自己的帧 tick 去消费，
	#它只来得及看到最后一次电平，上升沿那一拍就白跑了
	right_build.call("step_clock_phase", high)

#机器人每拍写进自己电路的检测码（detect_res_0..7）：分屏右侧必须有同样的位，
#否则「左侧时序图看到高、右侧灯泡不亮」。
#看哪台与左侧时序图一致：优先选中的，否则第一台绑了电路的
func _collect_robot_inputs() -> Dictionary:
	var out: Dictionary = {}
	if left_entity_sys == null or not left_entity_sys.has_method("get_detect_code"):
		return out
	var e = null
	if left_entity_sys.has_method("get_timing_entity"):
		e = left_entity_sys.call("get_timing_entity")
	if e == null:
		return out
	var code: int = int(left_entity_sys.call("get_detect_code", e))
	for port in ACTIONS.DETECT_COUNT:
		out[ACTIONS.res_name(port)] = (code >> ACTIONS.res_bit(port)) & 1
	return out
#endregion

#region 暂停 / 应用 / 返回
func _refresh_status() -> void:
	if _apply_btn != null:
		_apply_btn.disabled = not _paused
	if _status == null:
		return
	if _paused:
		_status.text = "电路已修改，机器人已暂停"
	else:
		_status.text = "两边同步运行中"

func _on_apply_pressed() -> void:
	if left_scene == null or right_scene == null:
		return
	#1) 先把当前结构导出成同名 .swcir（空串 = 没有可导出的接口电路）
	var path: String = str(right_scene.call("_export_edited_circuit"))
	if path.is_empty():
		#没有可导出的东西：不恢复运行，否则机器人会拿着旧电路继续跑
		if _status != null:
			_status.text = "没有可导出的接口电路"
		return
	#2) 按最新电路重绑左侧机器人（.swcir 与存档同名，机器人绑的就是这个名字）
	var bound: int = 0
	var sys = _scene_call(left_scene, "get_entity_system")
	if sys != null and sys.has_method("reload_circuit"):
		var file_name: String = path.get_file().get_basename()
		bound = int(sys.call("reload_circuit", file_name))
	#3) 恢复节拍
	_paused = false
	if left_tick != null:
		left_tick.call("resume")
	_refresh_status()
	if _status != null:
		_status.text = "已应用：重绑 %d 台机器人" % bound

func _on_back_pressed() -> void:
	if _leaving or not is_inside_tree():
		return
	#这里**不要**清 SESSION.split_mode：两个子场景的 _exit_tree 还要靠它跳过清池，
	#等机器人场景交还出去、壳要退的时候再复位。
	#先播退场动画（机器人界面放大回全屏、电路界面滑出窗口右侧），再搬节点
	_leaving = true
	_play_outro_then(_vacate_left_scene)

#正常返回：把机器人场景原路交还宿主（不重建、不读存档），然后释放壳与右侧电路。
#动画播完之后才调它
func _vacate_left_scene() -> void:
	if left_scene == null or not is_instance_valid(left_scene):
		_vacated_left = true
		SESSION.split_mode = false
		queue_free()
		return
	#1) 右边改了电路又直接返回：先按当前结构导出同名 .swcir，再让左侧按最新电路重绑。
	#原来是靠「重载机器人场景 → 读状态 → 重绑」补救的，现在不重载了就必须当场做，
	#否则机器人会拿着旧电路接着跑
	var path: String = ""
	if right_scene != null and is_instance_valid(right_scene):
		path = str(right_scene.call("_export_edited_circuit"))
	if not path.is_empty() and left_entity_sys != null and left_entity_sys.has_method("reload_circuit"):
		left_entity_sys.call("reload_circuit", path.get_file().get_basename())
	#2) 因为改电路被暂停过的话恢复运行
	if _paused and left_tick != null:
		left_tick.call("resume")
	_paused = false
	#3) 左侧 HUD/性能面板在进分屏时被改过（藏了场景切换入口、整体让开了顶栏那一条）：
	#机器人场景是原样留下来的，这些改动必须显式撤掉，否则回到全屏后按钮还是隐的
	_set_hud_split_mode(left_scene, false)
	var left_perf := left_scene.get_node_or_null("SWPerformanceMonitor")
	if left_perf != null and left_perf.has_method("set_top_inset"):
		left_perf.call("set_top_inset", 0.0)
	var left_hud = _hud_of(left_scene)
	if left_hud != null and left_hud.has_method("set_top_right_inset"):
		left_hud.call("set_top_right_inset", 0.0)
	#4) 交还机器人场景：只换父节点，实例不重建
	left_scene.call("return_from_split")
	_vacated_left = true
	#5) 机器人场景还活着、还在用共享对象池：这里不能清池
	SESSION.split_mode = false
	queue_free()

func _exit_tree() -> void:
	#正常返回路径：机器人场景已经交还宿主，收尾都在 _vacate_left_scene 做完了
	if _vacated_left:
		return
	#退出顺序不要依赖引擎（父子的 _exit_tree 先后不一定）：这里先显式把两个子场景的
	#收尾跑完：存机器人状态 + 导出改过的电路。两只都是幂等的（导出会 get 走标记），
	#子场景自己的 _exit_tree 再跑一遍也是空转
	if left_scene != null and is_instance_valid(left_scene):
		left_scene.call("_save_scene_state")
	if right_scene != null and is_instance_valid(right_scene):
		right_scene.call("_export_edited_circuit")
	#子场景还没退的话，它们这时已经不需要共享单例了：先复位标记，
	#它们自己的 _exit_tree 再清池就是一次空转
	SESSION.split_mode = false
	SWObjectPool.ClearSWChunkDataObject()
#endregion
