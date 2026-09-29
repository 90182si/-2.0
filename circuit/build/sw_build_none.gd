class_name SWBuildNone extends SWBuildItemDefine

func getNet(swBuildManager:SWBuildManager) -> Array:
	return [[],{}]

#func getBuildIOConnectBuildArr(swBuildManager:SWBuildManager) -> Array[SWBuildItemDefine]:
	#return []
	
func buildStateChanged(signalValue:SwDefine.CircuitSignal) -> void:
	pass

func setPortFlag(buildDef:SWBuildDefine) -> void:
	pass
	
func getExpr(pinDir:SwDefine.SW_Dir) -> SwDefine.SWCircuitStruct:
	return null

func getBuildExpr() -> void:
	pass
	
func getValue(dir:SwDefine.SW_Dir) -> SwDefine.CircuitSignal:
	return SwDefine.CircuitSignal.NONE
func setValue(dir:SwDefine.SW_Dir,value:SwDefine.CircuitSignal) -> void:
	pass

func _sub_init() -> void:
	var renderable = getCompoent(SwDefine.BuildCompoentType.RENDER_ABLE) as SWBuildCompoentRenderable
	renderable.buildHasAtlas = true
	renderable.buildHasBase = false
