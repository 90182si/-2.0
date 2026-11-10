class_name SWHudLayer extends SWLayer

signal selTool(buildDefine:SWBuildDefine)
signal save_requested()
signal load_requested()

const selToolPath:String = "res://res/"
const ROBOT_SCENE_PATH: String = "res://scene/sw_robot_scene.tscn"
#接口元件可选名清单（输入/输出分开，手动扩展都在这一个文件里）
const IO_CATALOG := preload("res://circuit/sw_io_name_catalog.gd")
var selTools:Array = []

func _ready() -> void:
	#只收本场景的工具栏按钮：分屏调试时两边的 HUD 同时在树里，
	#直接 get_nodes_in_group 会把另一边的工具也接管（图标与点击都串）
	selTools = SwCommon.GetNodesInGroupInScene(self, "SelTool")
	_apply_atlas()
	for tool:TextureButton in selTools:
		tool.pressed.connect(_on_sel_tool_pressed.bind(tool.name))
	var save_btn = get_node_or_null("HBoxContainer/MarginContainer/MarginContainer/HBoxContainer/保存")
	if save_btn:
		save_btn.tooltip_text = "把当前电路存成存档，并导出同名的 .swcir 纯电路文件给机器人用"
		save_btn.pressed.connect(_on_save_pressed)
	var load_btn = get_node_or_null("HBoxContainer/MarginContainer/MarginContainer/HBoxContainer/加载")
	if load_btn:
		load_btn.tooltip_text = "从存档列表里读回电路（读档后接口名与元件状态一起还原）"
		load_btn.pressed.connect(_on_load_pressed)
	#机器人场景的 HUD 会在 super._ready() 之前把它关掉，避免两个场景互相冒按钮
	#分屏调试的右侧也不需要它：切回机器人场景由分屏壳的顶栏负责
	if scene_switch_enabled:
		_build_scene_switch()
	_build_job_panel()
	_build_expr_panel()
	_build_io_panel()

# ========== 左下角场景切换（只给电路场景用，机器人场景开关见下） ==========
var scene_switch_enabled: bool = true
var _robot_scene_btn: Button = null

func _build_scene_switch() -> void:
	var btn := Button.new()
	btn.name = "机器人场景"
	btn.text = "机器人场景"
	btn.tooltip_text = "切到机器人场景：摆机器人/箱子，给机器人绑一条 .swcir 电路让它自己跑"
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", 18)
	#贴左下角：底部工具栏在屏幕中下方，左下方原本只有任务进度条（已给它上移避让）
	btn.anchor_left = 0.0
	btn.anchor_right = 0.0
	btn.anchor_top = 1.0
	btn.anchor_bottom = 1.0
	btn.offset_left = 12
	btn.offset_right = 140
	btn.offset_top = -52
	btn.offset_bottom = -12
	btn.pressed.connect(switch_to_robot_scene)
	add_child(btn)
	_robot_scene_btn = btn

func switch_to_robot_scene() -> void:
	if not is_inside_tree():
		return
	get_tree().change_scene_to_file(ROBOT_SCENE_PATH)

func get_scene_switch_button() -> Button:
	return _robot_scene_btn

#分屏模式下隐掉「机器人场景」按钮：整体换场景由分屏壳的顶栏负责。
#子类（机器人场景 HUD）重写时先藏自己的重复按钮再调 super
func set_split_mode(on: bool) -> void:
	if _robot_scene_btn != null:
		_robot_scene_btn.visible = not on

# ========== 左下角任务进度条（复制/剪切准备、放置队列） ==========
# 位置在「机器人场景」切换按钮上方：两者都在左下角，不能让它们叠在一起
var _job_panel: Control = null
var _job_label: Label = null
var _job_bar: ProgressBar = null

func _build_job_panel() -> void:
	var panel := ColorRect.new()
	panel.color = Color(0.0, 0.0, 0.0, 0.55)
	# 纯展示，不能吃掉地图上的鼠标事件
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	panel.anchor_left = 0.0
	panel.anchor_top = 1.0
	panel.anchor_right = 0.0
	panel.anchor_bottom = 1.0
	panel.offset_left = 12
	panel.offset_top = -128
	panel.offset_right = 292
	panel.offset_bottom = -60
	panel.visible = false
	add_child(panel)

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 6)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 4)
	margin.add_child(box)

	_job_label = Label.new()
	_job_label.text = ""
	box.add_child(_job_label)

	_job_bar = ProgressBar.new()
	_job_bar.show_percentage = false
	_job_bar.min_value = 0.0
	_job_bar.max_value = 1.0
	_job_bar.step = 0.001
	_job_bar.custom_minimum_size = Vector2(0, 14)
	box.add_child(_job_bar)
	_job_panel = panel

func show_job_progress(text: String, pct: float) -> void:
	if _job_panel == null:
		return
	_job_label.text = text
	_job_bar.value = clampf(pct, 0.0, 1.0)
	if not _job_panel.visible:
		_job_panel.visible = true

func hide_job_progress() -> void:
	if _job_panel != null:
		_job_panel.visible = false

func is_job_progress_visible() -> bool:
	return _job_panel != null and _job_panel.visible

# ========== 右上角悬浮表达式面板（鼠标停在元件上时显示它在算什么） ==========
# 表达式树是电路构建时递归建好的，这里只读出来排版（见 SWExprDescribe），不重建
const EXPR_DESCRIBE := preload("res://circuit/sw_expr_describe.gd")
var _expr_panel: Control = null
var _expr_label: Label = null
var _expr_build: SWBuildItemDefine = null
var _expr_text: String = ""

func _build_expr_panel() -> void:
	var panel := PanelContainer.new()
	# 纯展示，不能吃掉地图上的鼠标事件
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 贴右上角：左右都锚在右边，向左长；上下锚在顶部，向下长
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_top = 0.0
	panel.anchor_bottom = 0.0
	panel.offset_left = -352
	panel.offset_right = -12
	panel.offset_top = 12
	panel.offset_bottom = 12
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.grow_vertical = Control.GROW_DIRECTION_END
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.62)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", style)
	panel.visible = false
	add_child(panel)

	_expr_label = Label.new()
	_expr_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 表达式会长，折行比横向撑爆屏幕好
	_expr_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_expr_label.custom_minimum_size = Vector2(320, 0)
	_expr_label.add_theme_font_size_override("font_size", 15)
	panel.add_child(_expr_label)
	_expr_panel = panel

# 表达式面板是否允许显示：与性能面板的「建筑信息」开关联动，
# 关掉建筑信息时右上角也不该再冒出一个同样面积的表达式面板
var expr_enabled:bool = true

func set_expr_enabled(enabled:bool) -> void:
	expr_enabled = enabled
	if not enabled:
		hide_build_expr()

#分屏时右上角被分屏壳的「返回 / 应用」顶栏占住了：表达式面板整体下移让开这一段高度。
#（只在分屏壳里调；普通场景右上角只有面板自己，保持 12px 贴边）
func set_top_right_inset(px:float) -> void:
	if _expr_panel == null:
		return
	var top:float = 12.0 + maxf(0.0, px)
	_expr_panel.offset_top = top
	_expr_panel.offset_bottom = top

# 悬浮到某个元件就显示它的表达式；build 为 null 表示鼠标离开，收面板
func show_build_expr(build: SWBuildItemDefine) -> void:
	if _expr_panel == null or not expr_enabled:
		return
	if build == null:
		hide_build_expr()
		return
	var text: String = EXPR_DESCRIBE.describe_build(build)
	if text.is_empty():
		hide_build_expr()
		return
	_expr_build = build
	_expr_text = text
	_expr_label.text = text
	_expr_panel.visible = true

func hide_build_expr() -> void:
	_expr_build = null
	_expr_text = ""
	if _expr_panel != null:
		_expr_panel.visible = false

func is_build_expr_visible() -> bool:
	return _expr_panel != null and _expr_panel.visible

func get_build_expr_text() -> String:
	return _expr_text

# 把 HUD 图标用的 AtlasTexture 切到全局选中的图集；顺手给按钮写悬停说明
# （工具栏按钮的说明全由元件定义推出来：名称 + 接口可选名 + 每方向引脚类型）
func _apply_atlas() -> void:
	for tool in selTools:
		var resPath = selToolPath+tool.name+".tres"
		var buildDefine = load(resPath) as SWBuildDefine
		if not buildDefine:
			continue
		var btn := tool as TextureButton
		if btn == null:
			continue
		btn.set_texture_normal(buildDefine.atlasIcon)
		btn.tooltip_text = IO_CATALOG.describe_define(buildDefine)

func on_view_rect_changed(_viewRect:Rect2,_speedVec:Vector2) -> void:
	pass

func _on_sel_tool_pressed(extra_arg_0: String) -> void:
	var resPath = selToolPath+extra_arg_0+".tres"
	var buildDefine = load(resPath) as SWBuildDefine
	if buildDefine:
		selTool.emit(buildDefine)
	else:
		printerr(resPath,"不存在")

func _on_save_pressed() -> void:
	save_requested.emit()

func _on_load_pressed() -> void:
	load_requested.emit()

# ========== 接口元件名称编辑面板（左键点击输入/输出接口时弹出） ==========
# 名称是实例属性（建筑上的 io_name），下拉项按元件类型给：
#   输入接口 -> SWIOCatalog.INPUT_NAMES（现在只有 clk）
#   输出接口 -> SWIOCatalog.OUTPUT_NAMES（现在 move / rotation）
# 想加新名字只改那个清单文件，这里每次弹面板都重建下拉项
var _io_panel: PanelContainer = null
var _io_title: Label = null
var _io_option: OptionButton = null
var _io_build: SWBuildItemDefine = null
# 当前面板正在展示的名称清单（与下拉项一一对应）
var _io_options: Array[String] = []

func _build_io_panel() -> void:
	var panel := PanelContainer.new()
	# 屏幕上方居中：避开底部工具栏与右上角表达式面板
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.0
	panel.anchor_bottom = 0.0
	panel.offset_left = -110
	panel.offset_right = 110
	panel.offset_top = 96
	panel.offset_bottom = 96
	panel.grow_vertical = Control.GROW_DIRECTION_END
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

	var title := Label.new()
	title.text = "接口名称"
	title.add_theme_font_size_override("font_size", 18)
	box.add_child(title)
	_io_title = title

	# 下拉项不在这里填：每次弹面板按被点元件的类型重建
	_io_option = OptionButton.new()
	_io_option.add_theme_font_size_override("font_size", 18)
	_io_option.item_selected.connect(_on_io_name_selected)
	box.add_child(_io_option)

	var close_btn := Button.new()
	close_btn.text = "关闭"
	close_btn.add_theme_font_size_override("font_size", 16)
	close_btn.pressed.connect(hide_io_name_panel)
	box.add_child(close_btn)
	_io_panel = panel

# 点开某个接口元件的名称面板：按元件类型重建下拉项，再定位到当前名。
# 当前名不在清单里（老存档 / 别的存档加了名字）时落到第一项，但不改实例上的名字
func show_io_name_panel(build: SWBuildItemDefine) -> void:
	if _io_panel == null or build == null:
		return
	_io_build = build
	var comp_type: int = 0
	if build.buildDefine != null:
		comp_type = build.buildDefine.circuit_component_type
	_io_options = IO_CATALOG.options_for(comp_type)
	_io_option.clear()
	for opt: String in _io_options:
		_io_option.add_item(opt)
	if _io_title != null:
		var kind: String = IO_CATALOG.kind_name(comp_type)
		_io_title.text = ("接口名称（%s接口）" % kind) if not kind.is_empty() else "接口名称"
	var current: String = str(build.get("io_name"))
	var idx: int = _io_options.find(current)
	_io_option.select(idx if idx >= 0 else 0)
	_io_panel.visible = true

func hide_io_name_panel() -> void:
	_io_build = null
	if _io_panel != null:
		_io_panel.visible = false

func is_io_name_panel_visible() -> bool:
	return _io_panel != null and _io_panel.visible

# 面板当前编辑的是哪个元件（测试与排障用）
func get_io_name_panel_build() -> SWBuildItemDefine:
	return _io_build

func get_io_name_options() -> Array[String]:
	return _io_options.duplicate()

func _on_io_name_selected(index: int) -> void:
	if _io_build == null or index < 0 or index >= _io_options.size():
		return
	_io_build.set("io_name", _io_options[index])

func create_layer_system() -> SWLayerSystem:
	return SWHudLayerSystem.new()
