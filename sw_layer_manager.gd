class_name SWLayerManager extends Node

var layers:Array[SWLayer] = []
var hudLayer:SWHudLayer = null
var holdLayer:SWHoldLayer = null
var buildLayer:SWBuildLayer = null

func _ready() -> void:
	var _layers = get_tree().get_nodes_in_group("SWLayer")
	for layer in _layers:
		if layer is SWLayer:
			layers.append(layer)
		if layer is SWHudLayer:
			hudLayer = layer
			hudLayer.selTool.connect(hudLayerSelectedTool)
		if layer is SWHoldLayer:
			holdLayer = layer
		if layer is SWBuildLayer:
			buildLayer = layer
	if buildLayer and holdLayer:
		holdLayer.holdIdleBuilds.connect(buildLayer.holdIdleBuilds)
		holdLayer.holdRemoveBuilds.connect(buildLayer.holdRemoveBuilds)
		holdLayer.selectBuildsByRect.connect(func(rect):
			print("选中",rect)
			buildLayer.setSelectedRect(rect))
		
	var build:SWBuildDefine = load("res://res/按钮.tres") as SWBuildDefine
	var build2:SWBuildDefine = load("res://res/开关.tres") as SWBuildDefine
	var build3:SWBuildDefine = load("res://res/灯泡.tres") as SWBuildDefine
	var drawData:SWDrawData = SWDrawData.new()
	drawData.addOneDrawBuildDefine(Vector2i(0,0),build)
	drawData.addOneDrawBuildDefine(Vector2i(0,128),build2)
	drawData.addOneDrawBuildDefine(Vector2i(0,256),build3)
	drawData.addOneDrawBuildDefine(Vector2i(128,128),build3)
	drawData.addOneDrawBuildDefine(Vector2i(-128,128),build3)
	
	holdLayer.on_sel_tool_draw_data(drawData)
			
func hudLayerSelectedTool(buildDefine:SWBuildDefine) -> void:
	var drawData:SWDrawData = SWDrawData.new()
	drawData.addOneDrawBuildDefine(Vector2i(0,0),buildDefine)
	holdLayer.on_sel_tool_draw_data(drawData)
