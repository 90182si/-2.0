class_name SWHudLayer extends SWLayer

signal selTool(buildDefine:SWBuildDefine)
signal save_requested()
signal load_requested()

const selToolPath:String = "res://res/"
var selTools:Array = []

func _ready() -> void:
	selTools = get_tree().get_nodes_in_group("SelTool")
	for tool:TextureButton in selTools:
		tool.pressed.connect(_on_sel_tool_pressed.bind(tool.name))
	var save_btn = get_node_or_null("HBoxContainer/MarginContainer/MarginContainer/HBoxContainer/保存")
	if save_btn:
		save_btn.pressed.connect(_on_save_pressed)
	var load_btn = get_node_or_null("HBoxContainer/MarginContainer/MarginContainer/HBoxContainer/加载")
	if load_btn:
		load_btn.pressed.connect(_on_load_pressed)

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
