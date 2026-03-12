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
			
func hudLayerSelectedTool(buildDefine:SWBuildDefine) -> void:
	holdLayer.on_sel_tool(buildDefine)
