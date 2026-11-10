class_name SWRobotHudLayer extends SWHudLayer

# ==========================================================================
# 机器人场景的 HUD
#
# 继承 SWHudLayer 而不是另起炉灶：两个场景互斥切换，工具栏/任务进度条/面板构建
# 这些东西没必要写两遍；而且 SWLayerManager 认的是 `is SWHudLayer`，
# 继承之后 hudSystem/tool_selected 的装配链在机器人场景里原样可用。
#
# 本类做四件事：
#   1. 代码构建底部工具栏：「机器人」/「箱子」工具按钮（进 SelTool 组，父类的选中链自动接管）
#   2. 「电路场景」切换按钮：跳回 sw_logic_scene.tscn
#   3. 电路绑定面板（单击机器人弹出）：选电路 / 解绑 / 去电路场景改这条电路
#   4. 电路时序图面板：实时看选中机器人的 clk / move / rotation / 是否真的动
# ==========================================================================

const LOGIC_SCENE_PATH: String = "res://scene/sw_logic_scene.tscn"
#分屏壳：左机器人右电路并排跑。「修改电路」走这里；全屏电路场景入口仍走上面那个
const SPLIT_SCENE_PATH: String = "res://scene/sw_split_scene.tscn"
const ROBOT_TOOL_NAME: String = "机器人"
#箱子：名字同样是定义资源名（res/箱子.tres），放出去的是实体层里的箱子，不绑电路
const BOX_TOOL_NAME: String = "箱子"
const CIR_MANAGER := preload("res://circuit/sw_cir_manager.gd")
#跨场景会话：「修改电路」要告诉电路场景该读哪个存档
const SESSION := preload("res://core/manager/sw_session.gd")
#时序图绘制控件
const TIMING_SCOPE := preload("res://layers/hud/sw_timing_scope.gd")
#接口名清单：父类 SWHudLayer 已经 preload 了 IO_CATALOG，时序面板的信号下拉框直接复用它
#（子类不能重复声明同名常量，会报 "already exists in parent class" 导致整个脚本加载失败）
const UNBIND_TEXT: String = "（不绑定电路）"

#请求绑定：由场景根接到实体系统。HUD 只管界面，不直接持有实体系统
signal circuit_bind_requested(entity, file_name: String)
#请求批量绑定（Ctrl+框选出来的那一批）：一次把同一条电路绑给这一堆台
signal circuit_bind_multi_requested(entities: Array, file_name: String)

var _toolbar: PanelContainer = null
var _robot_button: TextureButton = null
var _box_button: TextureButton = null
var _scene_button: Button = null
var _timing_button: Button = null
#绑定面板的「修改电路」：分屏壳里再点它就是重复入口，需要能隐藏它
var _bind_edit_btn: Button = null

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

	#箱子按钮：与机器人同一套链路，放出去的是可被推动的箱子
	_box_button = TextureButton.new()
	_box_button.name = BOX_TOOL_NAME
	_box_button.custom_minimum_size = Vector2(48, 48)
	_box_button.ignore_texture_size = true
	_box_button.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	_box_button.add_to_group("SelTool")
	box.add_child(_box_button)

	_scene_button = Button.new()
	_scene_button.name = "电路场景"
	_scene_button.custom_minimum_size = Vector2(96, 48)
	_scene_button.add_theme_font_size_override("font_size", 18)
	_scene_button.text = "电路场景"
	_scene_button.tooltip_text = (
			"去电路场景：搭逻辑、导出 .swcir 文件"
			+ "\n回来后在机器人面板里把导出好的电路绑给机器人")
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

func get_box_tool_button() -> TextureButton:
	return _box_button

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
#面板对着的那一堆台：单选就一台，框选就是整批。_bind_entity 永远是主选（第一台），
#「当前电路 / 解除绑定 / 修改电路」都看它
var _bind_entities: Array = []
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
	edit_btn.tooltip_text = "进分屏调试：左边机器人继续跑，右边改这条电路，改结构会先停机器人"
	edit_btn.pressed.connect(request_edit_circuit)
	row.add_child(edit_btn)
	_bind_edit_btn = edit_btn

	var close_btn := Button.new()
	close_btn.text = "关闭"
	close_btn.add_theme_font_size_override("font_size", 16)
	close_btn.pressed.connect(hide_bind_panel)
	row.add_child(close_btn)
	_bind_panel = panel

#单击选中某台机器人时由场景根调用
func show_bind_panel(entity) -> void:
	show_bind_panel_multi([] if entity == null else [entity])

#框选结束后由场景根调用：整批台一起展示、一起绑
func show_bind_panel_multi(entities: Array) -> void:
	if _bind_panel == null:
		return
	if entities.is_empty():
		hide_bind_panel()
		return
	_bind_entities = entities.duplicate()
	_bind_entity = _bind_entities[0]
	refresh_bind_list()
	_bind_panel.visible = true

func hide_bind_panel() -> void:
	_bind_entity = null
	_bind_entities.clear()
	if _bind_panel != null:
		_bind_panel.visible = false

func is_bind_panel_visible() -> bool:
	return _bind_panel != null and _bind_panel.visible

#当前面板对着哪台机器人（测试/排障）
func get_bind_panel_entity():
	return _bind_entity

#当前面板对着的整批台（框选时是整批）。测试/排障用
func get_bind_entities() -> Array:
	return _bind_entities.duplicate()

func get_bind_list() -> ItemList:
	return _bind_list

func get_bind_files() -> Array[String]:
	return _bind_files.duplicate()

#面板标题（测试/排障：应当显示格子下标，而不是世界坐标）
func get_bind_panel_title() -> Label:
	return _bind_title

#列表项两行：第一行档名（多电路文件额外标出条数），第二行接口摘要；不可用则第二行换成原因
func _bind_item_text(file_name: String, info: Dictionary) -> String:
	if not bool(info.get("usable", false)):
		return "%s\n%s" % [file_name, str(info.get("reason", "不可用"))]
	var head: String = file_name
	var n: int = int(info.get("circuit_count", 1))
	if n > 1:
		#多电路文件也能绑：一拍里所有含接口的电路都会跑，这里只提醒玩家它有 N 条
		head = "%s  (%d 条电路)" % [file_name, n]
	var ins: PackedStringArray = PackedStringArray(info.get("inputs", []))
	var outs: PackedStringArray = PackedStringArray(info.get("outputs", []))
	return "%s\nin: %s    out: %s" % [
		head,
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
	var n: int = _bind_entities.size()
	if n > 1:
		#多选：每台的电路可能不一样，只报「有几台已经绑了」；点一项就是整批换掉
		_bind_title.text = "已选 %d 台机器人" % n
		var bound: int = 0
		for e in _bind_entities:
			if not str(e.circuit_file).is_empty():
				bound += 1
		_bind_current.text = "已绑 %d / %d 台（选一项 = 整批绑定）" % [bound, n]
		#全部绑同一条电路时才把它选上：混着绑的话预选哪一条都是误导
		if bound == n:
			cur = str(_bind_entity.circuit_file)
	elif _bind_entity != null:
		#显示格子下标而不是世界坐标：后者是格子边长的整数倍，看着像乱码
		_bind_title.text = "机器人 %s" % str(_bind_entity.cell())
		cur = str(_bind_entity.circuit_file)
		_bind_current.text = ("当前电路：" + cur) if not cur.is_empty() else "当前电路：未绑定"
	else:
		_bind_title.text = "机器人电路"
		_bind_current.text = "没有选中机器人"
	_bind_list.add_item(UNBIND_TEXT)
	#多选且各台不一致时什么都不预选：选上「不绑定」会让人以为整批都没绑
	if cur.is_empty() and n <= 1:
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
			#文件坏了 / 文件里没有电路：置灰并标出原因（电路条数与接口名都不参与判定）
			_bind_list.set_item_disabled(idx, true)
			_bind_list.set_item_custom_fg_color(idx, Color(0.55, 0.55, 0.55))
			_bind_list.set_item_tooltip(idx, str(info.get("reason", "")))
	if files.is_empty():
		var idx: int = _bind_list.add_item("（还没有电路文件：去电路场景摆好接口电路并保存）")
		_bind_list.set_item_disabled(idx, true)
		_bind_list.set_item_custom_fg_color(idx, Color(0.55, 0.55, 0.55))
	_bind_refreshing = false

func _on_bind_item_selected(index: int) -> void:
	if _bind_refreshing or _bind_entities.is_empty() or index < 0:
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
	if _bind_entities.size() <= 1:
		circuit_bind_requested.emit(_bind_entity, file_name)
	else:
		circuit_bind_multi_requested.emit(_bind_entities.duplicate(), file_name)
	#emit 是同步的：回到这里时实体已经绑好（或失败），直接读实体上的结果
	var ok: int = 0
	for e in _bind_entities:
		if str(e.circuit_file) == file_name:
			ok += 1
	if ok == _bind_entities.size():
		hide_bind_panel()
	else:
		_bind_current.text = "绑定失败：%s（成功 %d / %d）" % [file_name, ok, _bind_entities.size()]

func _on_unbind_pressed() -> void:
	if _bind_entities.is_empty():
		return
	if _bind_entities.size() <= 1:
		circuit_bind_requested.emit(_bind_entity, "")
	else:
		circuit_bind_multi_requested.emit(_bind_entities.duplicate(), "")
	refresh_bind_list()


# ========== 修改电路：进分屏壳（左机器人 / 右电路） ==========
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
		get_tree().change_scene_to_file(SPLIT_SCENE_PATH)

#分屏模式下隐掉重复入口：「电路场景」（整体换场景）与「修改电路」（已在本分屏里）
#由分屏壳在 _ready 里调用
func set_split_mode(on: bool) -> void:
	if _scene_button != null:
		_scene_button.visible = not on
	if _bind_edit_btn != null:
		_bind_edit_btn.visible = not on
	super.set_split_mode(on)

#要改哪条电路：优先列表里选中且可用的，其次机器人已绑定的
func _bind_target_file() -> String:
	if _bind_list != null:
		var sel: PackedInt32Array = _bind_list.get_selected_items()
		if sel.size() > 0:
			var idx: int = sel[0]
			if idx > 0 and idx - 1 < _bind_files.size():
				var f: String = _bind_files[idx - 1]
				#置灰项不能拿去改：文件坏了的存档进电路场景也没意义
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
#监测信号区：勾选菜单（多选，勾一项就一条轨）+ 清空
#额外轨上限：与 sw_robot_entity.gd 的 TRACE_CAP 保持一致（实体侧也会截断，这里只用于提示/拦截）
const TIMING_TRACE_CAP: int = 16
var _timing_signal_menu: MenuButton = null
var _timing_signal_popup: PopupMenu = null
var _timing_clear_btn: Button = null
#上一次推给实体的信号清单 + 那台实体：换了观测对象 / 清单变了才重新推
var _timing_signals_applied: Array = []
var _timing_entity_applied = null

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
	#比只有波形时高一圈：中间多了两行（信号选择 + 运行/暂停/步进）；
	#再给额外输出轨（push + detect_sig_0..7）留出高度，不然 13 条轨只能压成很薄的条
	panel.offset_top = -264
	panel.offset_bottom = 264
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

	#监测信号区：勾选菜单。列表是「所有输入/输出接口名」，勾上就多一条轨、取消就去掉
	var sig_row := HBoxContainer.new()
	sig_row.add_theme_constant_override("separation", 6)
	box.add_child(sig_row)

	_timing_signal_menu = MenuButton.new()
	_timing_signal_menu.name = "TimingSignalMenu"
	_timing_signal_menu.add_theme_font_size_override("font_size", 14)
	#按钮吃满剩余宽度，「清空」保持自然宽度
	_timing_signal_menu.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_timing_signal_menu.tooltip_text = "勾选要监测的接口名：勾上立刻多一条轨，取消立刻去掉；固定四轨恒在"
	_timing_signal_popup = _timing_signal_menu.get_popup()
	#勾/取消后不收起菜单：这样才能一口气勾好几个（这就是「多选」的实现方式）
	_timing_signal_popup.hide_on_checkable_item_selection = false
	#每次弹出前重排：勾选态以会话里的清单为准（外部改了也能对上）
	_timing_signal_popup.about_to_popup.connect(_fill_timing_signal_menu)
	_timing_signal_popup.index_pressed.connect(_on_timing_signal_menu_pressed)
	sig_row.add_child(_timing_signal_menu)

	_timing_clear_btn = _make_small_button("清空", "全部取消勾选 = 回到自动模式（自动显示电路里 move/rotation 之外的输出）", _on_timing_clear_signals)
	sig_row.add_child(_timing_clear_btn)
	_fill_timing_signal_menu()
	_sync_timing_signal_menu()

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

#信号区的小按钮：不撑宽（同排的下拉框要占满剩余宽度）
func _make_small_button(text: String, tip: String, cb: Callable) -> Button:
	var btn := Button.new()
	btn.name = text
	btn.text = text
	btn.tooltip_text = tip
	btn.add_theme_font_size_override("font_size", 14)
	btn.pressed.connect(cb)
	return btn


# ===== 监测信号（勾选菜单，多选即时生效） =====
#玩家要监测哪些信号：空 = 自动模式（绑定电路里 move/rotation 之外的输出名全画）
func _timing_signals() -> Array:
	return SESSION.timing_signals

#菜单选项：所有输入接口名 + 所有输出接口名（含固定轨的 clk/move/rotation，
#它们恒勾选且置灰 —— 波形里本来就有，不能再当额外轨画一遍）
func _timing_signal_choices() -> Array[String]:
	var out: Array[String] = []
	for n in IO_CATALOG.INPUT_NAMES:
		out.append(str(n))
	for n in IO_CATALOG.OUTPUT_NAMES:
		var s: String = str(n)
		if not out.has(s):
			out.append(s)
	return out

#重排勾选菜单：勾选态以会话里的清单为准（点击后也是重建，不在控件上读状态）
func _fill_timing_signal_menu() -> void:
	if _timing_signal_popup == null:
		return
	var watched: Array = _timing_signals()
	_timing_signal_popup.clear()
	var i: int = 0
	for n in _timing_signal_choices():
		var fixed: bool = _is_fixed_track(n)
		_timing_signal_popup.add_check_item(n, i)
		_timing_signal_popup.set_item_metadata(i, n)
		_timing_signal_popup.set_item_checked(i, fixed or watched.has(n))
		if fixed:
			_timing_signal_popup.set_item_disabled(i, true)
		i += 1
	#末尾一行说明：告诉玩家上限（固定四轨不计）—— 这一项没有 metadata，点击会被忽略
	_timing_signal_popup.add_separator()
	_timing_signal_popup.add_item("最多 %d 条额外轨；清空 = 自动模式" % TIMING_TRACE_CAP, i)
	_timing_signal_popup.set_item_disabled(i, true)

#固定四轨（clk/move/rotation/act）已经在波形里了，不能当额外轨勾选
static func _is_fixed_track(name: String) -> bool:
	return name == "clk" or name == "move" or name == "rotation" or name == "act"

#按钮态：标题里带当前条数（0 条 = 自动模式），清空按钮空清单时禁用
func _sync_timing_signal_menu() -> void:
	var n: int = _timing_signals().size()
	if _timing_signal_menu != null:
		_timing_signal_menu.text = "监测信号（自动）" if n == 0 else "监测信号（%d）" % n
	if _timing_clear_btn != null:
		_timing_clear_btn.disabled = n == 0

#勾选/取消一项：立即生效（不需要再点添加/删除）
func _on_timing_signal_menu_pressed(index: int) -> void:
	if _timing_signal_popup == null or index < 0 or index >= _timing_signal_popup.item_count:
		return
	#真实接口名放 metadata；分隔符/说明行没有 metadata，直接忽略
	var meta = _timing_signal_popup.get_item_metadata(index)
	if meta == null:
		return
	var name: String = str(meta)
	if name.is_empty() or _is_fixed_track(name):
		return
	var was: bool = _timing_signals().has(name)
	if not was and _timing_signals().size() >= TIMING_TRACE_CAP:
		return
	#按「去掉这个名 → 需要就重新追加」重建：顺序即玩家勾选顺序
	var list: Array = []
	for n in _timing_signals():
		if str(n) != name:
			list.append(str(n))
	if not was:
		list.append(name)
	_set_timing_signals(list)

#清空 = 回到自动模式（仍然自动显示电路里 move/rotation 之外的输出）
func _on_timing_clear_signals() -> void:
	if _timing_signals().is_empty():
		return
	_set_timing_signals([])

#改监测清单：写回会话（跳场景回来还在）+ 立即推给当前观测对象 + 重画
func _set_timing_signals(list: Array) -> void:
	SESSION.timing_signals = list.duplicate()
	#强制重推：清单没变时实体侧会自己早退，这里不清缓存也没事
	_timing_signals_applied = []
	_timing_entity_applied = null
	refresh_timing()
	#重建菜单：勾选态与标题条数都得跟着变
	_fill_timing_signal_menu()
	_sync_timing_signal_menu()

#把会话里的清单推给当前观测对象；换了机器人 / 清单变了才推
func _apply_timing_signals(e) -> void:
	var list: Array = _timing_signals()
	if e == _timing_entity_applied and list == _timing_signals_applied:
		return
	_timing_entity_applied = e
	_timing_signals_applied = list.duplicate()
	if e == null or not e.has_method("set_trace_signals"):
		return
	var before: Array = e.trace_names.duplicate()
	e.set_trace_signals(list)
	#实体那边清单变了就会清波形：绘制控件的窗口状态也得一并重置，
	#否则 _last_seq 还是旧值，新波形不重画、旧画面残留在画布上
	if before != e.trace_names and _timing_scope != null:
		_timing_scope.clear_samples()

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
		_sync_timing_signal_menu()
		refresh_timing()
	else:
		#观测结束：把这台的采样关掉（上千台时只有被观测的那台在采样）
		_stop_trace(_timing_entity)
		_timing_entity = null
		if _timing_scope != null:
			_timing_scope.clear_samples()
	return _timing_panel.visible

#开始/结束采样某个实体的时序样本。默认只有前几十台会采样（见实体系统的
#TRACE_FULL_LIMIT）：上千台机器人时每台每半拍算一份位图，帧预算直接吃光
func _start_trace(e) -> void:
	if e != null:
		e.trace_active = true

func _stop_trace(e) -> void:
	if e != null:
		e.trace_active = false

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

#监测信号区（测试/排障用）：菜单按钮 + 它的勾选弹窗（多选就靠这个 PopupMenu）
func get_timing_signal_menu() -> MenuButton:
	return _timing_signal_menu

func get_timing_signal_popup() -> PopupMenu:
	return _timing_signal_popup

func get_timing_clear_button() -> Button:
	return _timing_clear_btn

#某个信号在菜单里的下标（没有返回 -1），测试模拟勾选时用
func get_timing_signal_index(name: String) -> int:
	if _timing_signal_popup == null:
		return -1
	for i in _timing_signal_popup.item_count:
		var meta = _timing_signal_popup.get_item_metadata(i)
		if meta != null and str(meta) == name:
			return i
	return -1

#当前要监测的信号清单（空 = 自动模式）
func get_timing_signals() -> Array:
	return _timing_signals().duplicate()

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
		_timing_entity_applied = null
		_timing_seq_shown = -1
		if _timing_scope.get_sample_count() > 0:
			_timing_scope.clear_samples()
		if _timing_title != null:
			_timing_title.text = "电路时序：先点一台机器人"
		if _timing_footer != null:
			_timing_footer.text = ""
		return
	var prev = _timing_entity
	var changed_entity: bool = prev != e
	#换了观测对象：旧的那台别再采样（上千台时只留一台在算位图）
	if changed_entity:
		_stop_trace(prev)
	_timing_entity = e
	#观测对象就开采样：新对象可能在前 64 台之外（默认关着）
	_start_trace(e)
	#监测清单先推给实体：清单一变实体就清波形，所以必须在取样本之前做完
	_apply_timing_signals(e)
	var frac: float = 1.0
	var t = get_tick_node()
	if t != null and t.has_method("get_phase_frac"):
		frac = float(t.call("get_phase_frac"))
	#带采样序号：两拍输出完全一样时也能正确滚动（控件靠序号判断新增）
	var seq: int = int(e.timing_seq)
	#换了观测对象也得重算一次：两台碰巧序号相同不能当成「没变」
	var sample_changed: bool = changed_entity or seq != _timing_seq_shown
	#额外轨道（绑定电路里 move/rotation 之外的输出名）跟着样本一起推：
	#push / detect_sig_0..7 这些没有固定轨，全靠实体侧算好的名字 + 电平位图
	if not _timing_scope.set_samples(e.timing, seq, frac, e.trace_names, e.trace_masks):
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
