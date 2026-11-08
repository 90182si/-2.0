class_name SWRobotHudLayer extends SWHudLayer

# ==========================================================================
# 机器人场景的 HUD
#
# 继承 SWHudLayer 而不是另起炉灶：两个场景互斥切换，工具栏/任务进度条/面板构建
# 这些东西没必要写两遍；而且 SWLayerManager 认的是 `is SWHudLayer`，
# 继承之后 hudSystem/tool_selected 的装配链在机器人场景里原样可用。
#
# 本类做四件事：
#   1. 代码构建底部工具栏：「机器人」工具按钮（进 SelTool 组，父类的选中链自动接管）
#   2. 「电路场景」切换按钮：跳回 sw_logic_scene.tscn
#   3. 电路绑定面板（单击机器人弹出）：选电路 / 解绑 / 去电路场景改这条电路
#   4. 电路时序图面板：实时看选中机器人的 clk / move / rotation / 是否真的动
# ==========================================================================

const LOGIC_SCENE_PATH: String = "res://scene/sw_logic_scene.tscn"
const ROBOT_TOOL_NAME: String = "机器人"
const CIR_MANAGER := preload("res://circuit/sw_cir_manager.gd")
#跨场景会话：「修改电路」要告诉电路场景该读哪个存档
const SESSION := preload("res://core/manager/sw_session.gd")
#时序图绘制控件
const TIMING_SCOPE := preload("res://layers/hud/sw_timing_scope.gd")
const UNBIND_TEXT: String = "（不绑定电路）"

#请求绑定：由场景根接到实体系统。HUD 只管界面，不直接持有实体系统
signal circuit_bind_requested(entity, file_name: String)

var _toolbar: PanelContainer = null
var _robot_button: TextureButton = null
var _scene_button: Button = null
var _timing_button: Button = null

func _ready() -> void:
	#本场景自己带「电路场景」按钮，基类的「机器人场景」按钮在这里是多余的
	scene_switch_enabled = false
	#必须先把工具按钮建出来并挂进 SelTool 组：父类 _ready 里要按组取工具列表刷图集
	_build_toolbar()
	super._ready()
	_build_bind_panel()
	_build_timing_panel()

func _build_toolbar() -> void:
	var panel := PanelContainer.new()
	panel.name = "RobotToolbar"
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -160
	panel.offset_right = 160
	panel.offset_top = -68
	panel.offset_bottom = -12
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.3372549, 0.5372549, 0.5568628, 0.27)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(4)
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	var box := HBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)

	#工具按钮：名字就是定义资源名（res/机器人.tres），父类的 _on_sel_tool_pressed 按它取资源
	_robot_button = TextureButton.new()
	_robot_button.name = ROBOT_TOOL_NAME
	_robot_button.custom_minimum_size = Vector2(48, 48)
	_robot_button.ignore_texture_size = true
	_robot_button.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	_robot_button.add_to_group("SelTool")
	box.add_child(_robot_button)

	_scene_button = Button.new()
	_scene_button.name = "电路场景"
	_scene_button.custom_minimum_size = Vector2(96, 48)
	_scene_button.add_theme_font_size_override("font_size", 18)
	_scene_button.text = "电路场景"
	_scene_button.pressed.connect(switch_to_logic_scene)
	box.add_child(_scene_button)

	_timing_button = Button.new()
	_timing_button.name = "时序图"
	_timing_button.custom_minimum_size = Vector2(84, 48)
	_timing_button.add_theme_font_size_override("font_size", 18)
	_timing_button.text = "时序图"
	_timing_button.tooltip_text = (
			"打开电路时序图：看选中机器人的 clk / move / rotation / 本拍是否真的动了"
			+ "\n面板里可以暂停/单拍步进；暂停时按钮会变红，记得点「运行」恢复")
	_timing_button.pressed.connect(toggle_timing_panel)
	box.add_child(_timing_button)
	_toolbar = panel

#切到电路场景（原 sw_logic_scene.tscn，HUD 上有回机器人场景的按钮）
func switch_to_logic_scene() -> void:
	if not is_inside_tree():
		return
	get_tree().change_scene_to_file(LOGIC_SCENE_PATH)

func get_robot_tool_button() -> TextureButton:
	return _robot_button

func get_timing_toggle_button() -> Button:
	return _timing_button

func get_scene_switch_button() -> Button:
	return _scene_button

#与基类同名方法区分：基类那个指的是「去机器人场景」，这里指的是「去电路场景」
func get_logic_scene_button() -> Button:
	return _scene_button

func is_toolbar_visible() -> bool:
	return _toolbar != null and _toolbar.visible


# ========== 电路绑定面板（阶段 4）：单击机器人弹出 ==========
# 数据全部来自 SWCirManager：list_files 列文件，summarize 给「能不能用 + 原因 + 接口清单」。
# 面板不直接调实体系统，只发 circuit_bind_requested，由场景根接线（UI 与逻辑分离）。
var _bind_panel: PanelContainer = null
var _bind_title: Label = null
var _bind_current: Label = null
var _bind_list: ItemList = null
var _bind_entity = null
#列表下标 0 固定是「不绑定」，之后与 _bind_files 一一对应
var _bind_files: Array[String] = []
#刷新期间屏蔽 item_selected：ItemList.clear()/select() 是程序化操作，会把它们当成用户选择
var _bind_refreshing: bool = false

func _build_bind_panel() -> void:
	var panel := PanelContainer.new()
	panel.name = "RobotCircuitPanel"
	#贴右侧中部：不挡底部工具栏，也避开刚点的那台机器人（通常落在视野中心附近）
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_top = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -412
	panel.offset_right = -12
	panel.offset_top = -220
	panel.offset_bottom = 220
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.72)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", style)
	panel.visible = false
	add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)

	_bind_title = Label.new()
	_bind_title.text = "机器人电路"
	_bind_title.add_theme_font_size_override("font_size", 18)
	box.add_child(_bind_title)

	_bind_current = Label.new()
	_bind_current.text = ""
	_bind_current.add_theme_font_size_override("font_size", 14)
	box.add_child(_bind_current)

	_bind_list = ItemList.new()
	_bind_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_bind_list.custom_minimum_size = Vector2(0, 260)
	#两项一行：档名 + 接口摘要（第二行）；置灰项的原因也放第二行
	_bind_list.max_text_lines = 2
	_bind_list.item_selected.connect(_on_bind_item_selected)
	box.add_child(_bind_list)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)

	var unbind_btn := Button.new()
	unbind_btn.text = "解除绑定"
	unbind_btn.add_theme_font_size_override("font_size", 16)
	unbind_btn.pressed.connect(_on_unbind_pressed)
	row.add_child(unbind_btn)

	var edit_btn := Button.new()
	edit_btn.text = "修改电路"
	edit_btn.add_theme_font_size_override("font_size", 16)
	edit_btn.tooltip_text = "进电路场景并打开这条电路所在的存档，改完保存再点「机器人场景」回来"
	edit_btn.pressed.connect(request_edit_circuit)
	row.add_child(edit_btn)

	var close_btn := Button.new()
	close_btn.text = "关闭"
	close_btn.add_theme_font_size_override("font_size", 16)
	close_btn.pressed.connect(hide_bind_panel)
	row.add_child(close_btn)
	_bind_panel = panel

#单击选中某台机器人时由场景根调用
func show_bind_panel(entity) -> void:
	if _bind_panel == null:
		return
	_bind_entity = entity
	refresh_bind_list()
	_bind_panel.visible = true

func hide_bind_panel() -> void:
	_bind_entity = null
	if _bind_panel != null:
		_bind_panel.visible = false

func is_bind_panel_visible() -> bool:
	return _bind_panel != null and _bind_panel.visible

#当前面板对着哪台机器人（测试/排障）
func get_bind_panel_entity():
	return _bind_entity

func get_bind_list() -> ItemList:
	return _bind_list

func get_bind_files() -> Array[String]:
	return _bind_files.duplicate()

#面板标题（测试/排障：应当显示格子下标，而不是世界坐标）
func get_bind_panel_title() -> Label:
	return _bind_title

#列表项两行：第一行档名，第二行接口摘要；不可用则第二行换成原因
func _bind_item_text(file_name: String, info: Dictionary) -> String:
	if not bool(info.get("usable", false)):
		return "%s\n%s" % [file_name, str(info.get("reason", "不可用"))]
	var ins: PackedStringArray = PackedStringArray(info.get("inputs", []))
	var outs: PackedStringArray = PackedStringArray(info.get("outputs", []))
	return "%s\nin: %s    out: %s" % [
		file_name,
		", ".join(ins) if ins.size() > 0 else "无",
		", ".join(outs) if outs.size() > 0 else "无"]

#重建整个列表：第 0 项恒为「不绑定」，其余每个 .swcir 一项
func refresh_bind_list() -> void:
	if _bind_list == null:
		return
	_bind_refreshing = true
	_bind_list.clear()
	_bind_files.clear()
	var cur: String = ""
	if _bind_entity != null:
		#显示格子下标而不是世界坐标：后者是格子边长的整数倍，看着像乱码
		_bind_title.text = "机器人 %s" % str(_bind_entity.cell())
		cur = str(_bind_entity.circuit_file)
		_bind_current.text = ("当前电路：" + cur) if not cur.is_empty() else "当前电路：未绑定"
	else:
		_bind_title.text = "机器人电路"
		_bind_current.text = "没有选中机器人"
	_bind_list.add_item(UNBIND_TEXT)
	if cur.is_empty():
		_bind_list.select(0)
	var files: Array[String] = CIR_MANAGER.list_files()
	for f in files:
		_bind_files.append(f)
		var info: Dictionary = CIR_MANAGER.summarize(f)
		var idx: int = _bind_list.add_item(_bind_item_text(f, info))
		if bool(info.get("usable", false)):
			if cur == f:
				_bind_list.select(idx)
		else:
			#多电路 / 接口不齐 / 文件坏了：置灰并标出原因（SPEC-08 §3.9）
			_bind_list.set_item_disabled(idx, true)
			_bind_list.set_item_custom_fg_color(idx, Color(0.55, 0.55, 0.55))
			_bind_list.set_item_tooltip(idx, str(info.get("reason", "")))
	if files.is_empty():
		var idx: int = _bind_list.add_item("（还没有电路文件：去电路场景摆好接口电路并保存）")
		_bind_list.set_item_disabled(idx, true)
		_bind_list.set_item_custom_fg_color(idx, Color(0.55, 0.55, 0.55))
	_bind_refreshing = false

func _on_bind_item_selected(index: int) -> void:
	if _bind_refreshing or _bind_entity == null or index < 0:
		return
	var file_name: String = ""
	if index > 0:
		var fi: int = index - 1
		if fi >= _bind_files.size():
			return
		file_name = _bind_files[fi]
		#面板已经禁用了不可用项，这里再挡一次（防止程序化 select 绕过）
		var info: Dictionary = CIR_MANAGER.summarize(file_name)
		if not bool(info.get("usable", false)):
			_bind_current.text = "不能绑定：%s" % str(info.get("reason", ""))
			return
	circuit_bind_requested.emit(_bind_entity, file_name)
	#emit 是同步的：回到这里时实体已经绑好（或失败），直接读实体上的结果
	var now: String = str(_bind_entity.circuit_file)
	if file_name.is_empty() or now == file_name:
		hide_bind_panel()
	else:
		_bind_current.text = "绑定失败：%s" % file_name

func _on_unbind_pressed() -> void:
	if _bind_entity == null:
		return
	circuit_bind_requested.emit(_bind_entity, "")
	refresh_bind_list()


# ========== 修改电路：进电路场景并自动打开这条电路所在的存档 ==========
# .swcir 与存档同名，所以面板上的电路文件名就是存档名、也是要打开的存档名。
# 只做「记下要读哪个存档」+ 切场景；真正读档在 SWLogicScene._ready 里消费。
# 拆成 prepare / request 两步：切场景在测试里会把整个测试树换掉，
# 用例只能跑前半步（prepare），真正跳转只给按钮用。
func prepare_edit_circuit() -> String:
	var file_name: String = _bind_target_file()
	if file_name.is_empty():
		if _bind_current != null:
			_bind_current.text = "先选一条可用电路，再点「修改电路」"
		return ""
	SESSION.pending_load_save = file_name
	return file_name

func request_edit_circuit() -> void:
	if prepare_edit_circuit().is_empty():
		return
	hide_bind_panel()
	if is_inside_tree():
		get_tree().change_scene_to_file(LOGIC_SCENE_PATH)

#要改哪条电路：优先列表里选中且可用的，其次机器人已绑定的
func _bind_target_file() -> String:
	if _bind_list != null:
		var sel: PackedInt32Array = _bind_list.get_selected_items()
		if sel.size() > 0:
			var idx: int = sel[0]
			if idx > 0 and idx - 1 < _bind_files.size():
				var f: String = _bind_files[idx - 1]
				#置灰项不能拿去改：多电路/缺接口的文件进电路场景也没意义
				if bool(CIR_MANAGER.summarize(f).get("usable", false)):
					return f
	if _bind_entity == null:
		return ""
	return str(_bind_entity.circuit_file)


# ========== 电路时序图（实时） ==========
# 数据源是实体系统：每台机器人每拍往 entity.timing 追一条
# Vector4i(clk, move, rotation, acted)。HUD 只做三件事：问 provider 要「该看哪台」、
# 把它的样本推给绘制控件、顺手把 Q 与拍数显示出来。
var _timing_panel: PanelContainer = null
var _timing_scope = null
var _timing_title: Label = null
var _timing_footer: Label = null
#取「该看哪台机器人」的 Callable，由场景根注入（Callable(entity_system, "get_timing_entity")）
var _timing_provider: Callable = Callable()
#上一次同步到 footer 的采样序号：相位（红线）每帧都在动，但标题/footer 不必每帧重算
var _timing_seq_shown: int = -1
#当前正在看的那台（测试/排障用）
var _timing_entity = null
#运行/暂停/步进三个按钮
var _timing_run_btn: Button = null
var _timing_pause_btn: Button = null
var _timing_step_btn: Button = null
#取节拍器的 Callable（Callable(scene, "_get_robot_tick")）。
#与实体系统同口径：HUD 不持有节拍器节点，只拿一个能取到它的 Callable
var _tick_provider: Callable = Callable()
#上一次同步到按钮上的运行态（-1 = 还不知道），避免每帧重写 disabled
var _tick_state_shown: int = -1

func _build_timing_panel() -> void:
	var panel := PanelContainer.new()
	panel.name = "RobotTimingPanel"
	#贴左侧中部：右边是电路绑定面板，底部是工具栏，左上留给表达式/接口面板
	panel.anchor_left = 0.0
	panel.anchor_right = 0.0
	panel.anchor_top = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = 12
	panel.offset_right = 392
	#比只有波形时高一圈：中间多了一行运行/暂停/步进按钮
	panel.offset_top = -176
	panel.offset_bottom = 176
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.72)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", style)
	panel.visible = false
	add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)

	_timing_title = Label.new()
	_timing_title.text = "电路时序"
	_timing_title.add_theme_font_size_override("font_size", 16)
	box.add_child(_timing_title)

	_timing_scope = TIMING_SCOPE.new()
	_timing_scope.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_timing_scope)

	#波形控制条：暂停后点步进一拍一拍看，是排时序问题最快的方式
	var ctrl := HBoxContainer.new()
	ctrl.add_theme_constant_override("separation", 8)
	box.add_child(ctrl)

	_timing_run_btn = _make_ctrl_button("运行", "恢复自动节拍（250ms 一拍）", request_run)
	ctrl.add_child(_timing_run_btn)
	_timing_pause_btn = _make_ctrl_button("暂停", "停掉自动节拍，机器人原地不动", request_pause)
	ctrl.add_child(_timing_pause_btn)
	_timing_step_btn = _make_ctrl_button("步进", "暂停状态下单拍前进：走一拍，波形追一格", request_step)
	ctrl.add_child(_timing_step_btn)

	_timing_footer = Label.new()
	_timing_footer.text = ""
	_timing_footer.add_theme_font_size_override("font_size", 14)
	box.add_child(_timing_footer)
	_timing_panel = panel
	#还没接入节拍器时也先摆好两个按钮的初始可用态
	_sync_tick_buttons()

func _make_ctrl_button(text: String, tip: String, cb: Callable) -> Button:
	var btn := Button.new()
	btn.name = text
	btn.text = text
	btn.tooltip_text = tip
	btn.add_theme_font_size_override("font_size", 15)
	#三个按钮平分一行宽度
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.pressed.connect(cb)
	return btn

#场景根注入数据源；注入后立即刷一次，面板不用等下两拍
func set_timing_provider(provider: Callable) -> void:
	_timing_provider = provider
	refresh_timing()

#场景根注入节拍器取用口；注入后按当前运行态刷一次按钮
func set_tick_provider(provider: Callable) -> void:
	_tick_provider = provider
	_tick_state_shown = -1
	_sync_tick_buttons()

func get_tick_node():
	if _tick_provider.is_valid():
		return _tick_provider.call()
	return null

#当前节拍器在不在跑（拿不到节拍器时按「停」处理，按钮就不会误显示为运行中）
func is_tick_running() -> bool:
	var t = get_tick_node()
	if t == null or not t.has_method("is_running"):
		return false
	return bool(t.call("is_running"))

#「运行」：恢复自动节拍
func request_run() -> bool:
	var t = get_tick_node()
	if t == null or not t.has_method("resume"):
		return false
	t.call("resume")
	_sync_tick_buttons()
	return true

#「暂停」：停掉自动节拍
func request_pause() -> bool:
	var t = get_tick_node()
	if t == null or not t.has_method("pause"):
		return false
	t.call("pause")
	_sync_tick_buttons()
	return true

#「步进」：走一拍就停。返回本拍移动的机器人数（-1 = 没接上节拍器）
func request_step() -> int:
	var t = get_tick_node()
	if t == null or not t.has_method("step_once"):
		return -1
	var moved: int = int(t.call("step_once"))
	_sync_tick_buttons()
	#立刻把新样本推给控件：不用等下一次 _process，点一下就看见多一格
	refresh_timing()
	return moved

#按钮禁用态跟着真实运行态走：运行中不能点「运行」，暂停中不能点「暂停」
func _sync_tick_buttons() -> void:
	var running: bool = is_tick_running()
	var flag: int = 1 if running else 0
	if flag == _tick_state_shown:
		return
	_tick_state_shown = flag
	if _timing_run_btn != null:
		_timing_run_btn.disabled = running
	if _timing_pause_btn != null:
		_timing_pause_btn.disabled = not running
	#暂停时工具栏按钮变红：否则玩家关掉面板后看见机器人不动，会以为卡住了。
	#未接入节拍器时不染色（否则会把「没接上」误报成「暂停中」）
	if _timing_button != null and _tick_provider.is_valid():
		if flag == 1:
			_timing_button.remove_theme_color_override("font_color")
		else:
			_timing_button.add_theme_color_override("font_color", Color(1.0, 0.55, 0.45))

#面板开关（工具栏「时序图」按钮直连）。返回开后的状态
func toggle_timing_panel() -> bool:
	if _timing_panel == null:
		return false
	_timing_panel.visible = not _timing_panel.visible
	if _timing_panel.visible:
		_sync_tick_buttons()
		refresh_timing()
	else:
		_timing_entity = null
		if _timing_scope != null:
			_timing_scope.clear_samples()
	return _timing_panel.visible

func is_timing_panel_visible() -> bool:
	return _timing_panel != null and _timing_panel.visible

func get_timing_panel():
	return _timing_panel

func get_timing_scope():
	return _timing_scope

func get_timing_entity():
	return _timing_entity

func get_timing_run_button() -> Button:
	return _timing_run_btn

func get_timing_pause_button() -> Button:
	return _timing_pause_btn

func get_timing_step_button() -> Button:
	return _timing_step_btn

func get_timing_footer() -> Label:
	return _timing_footer

#把最新样本推给控件。样本每半拍落一条；另外每帧把「当前半拍跑了多少」也传下去，
#控件才能把最新一格从游标往左长出来（波形连续往左流，边沿正好在红线处冒出）。
#控件自己靠序号 + 相位判断要不要重画
func refresh_timing() -> void:
	if _timing_scope == null:
		return
	var e = null
	if _timing_provider.is_valid():
		e = _timing_provider.call()
	if e == null:
		_timing_entity = null
		_timing_seq_shown = -1
		if _timing_scope.get_sample_count() > 0:
			_timing_scope.clear_samples()
		if _timing_title != null:
			_timing_title.text = "电路时序：先点一台机器人"
		if _timing_footer != null:
			_timing_footer.text = ""
		return
	var changed_entity: bool = _timing_entity != e
	_timing_entity = e
	var frac: float = 1.0
	var t = get_tick_node()
	if t != null and t.has_method("get_phase_frac"):
		frac = float(t.call("get_phase_frac"))
	#带采样序号：两拍输出完全一样时也能正确滚动（控件靠序号判断新增）
	var seq: int = int(e.timing_seq)
	#换了观测对象也得重算一次：两台碰巧序号相同不能当成「没变」
	var sample_changed: bool = changed_entity or seq != _timing_seq_shown
	if not _timing_scope.set_samples(e.timing, seq, frac):
		return
	_timing_scope.queue_redraw()
	#只有相位在动时不重算标题/footer：footer 要串一遍寄存器 Q，每帧算一遍没必要
	if not sample_changed:
		return
	_timing_seq_shown = seq
	var file_name: String = str(e.circuit_file)
	if _timing_title != null:
		_timing_title.text = "电路时序 %s · %s" % [
				str(e.cell()), file_name if not file_name.is_empty() else "未绑定电路"]
	if _timing_footer != null:
		var q: String = e.bundle.reg_q_text() if e.has_bundle() else "-"
		#beats 用拍数 timing_beats（样本数的一半）：timing.size() 封顶后就不动了，
		#那样看着像节拍器停了，反而遮住了「其实在跑」
		_timing_footer.text = "Q=%s  beats=%d  win=%d" % [
				q, int(e.timing_beats), int(e.timing.size()) >> 1]

func _process(_delta: float) -> void:
	#面板关着就什么都不做：正常游玩时这里零开销
	if _timing_panel != null and _timing_panel.visible:
		#外部改了节拍（比如脚本里启用/禁用）也能让按钮禁用态跟上
		_sync_tick_buttons()
		refresh_timing()
