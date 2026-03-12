class_name SWHudLayer extends SWLayer

signal selTool(buildDefine:SWBuildDefine)

const selToolPath:String = "res://res/"
var selTools:Array = []

func _ready() -> void:
	selTools = get_tree().get_nodes_in_group("SelTool")
	for tool:TextureButton in selTools:
		tool.pressed.connect(_on_sel_tool_pressed.bind(tool.name))

func on_view_rect_changed(_viewRect:Rect2,_speedVec:Vector2) -> void:
	pass

func _on_sel_tool_pressed(extra_arg_0: String) -> void:
	var resPath = selToolPath+extra_arg_0+".tres"
	var buildDefine = load(resPath) as SWBuildDefine
	if buildDefine:
		selTool.emit(buildDefine)
	else:
		printerr(resPath,"不存在")
	pass # Replace with function body.
