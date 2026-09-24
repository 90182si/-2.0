class_name SWBuildNone extends SWBuildItemDefine

func getNet(swBuildManager:SWBuildManager) -> Array:
	return [[],{}]

func getBuildIOConnectBuildArr(swBuildManager:SWBuildManager) -> Array[SWBuildItemDefine]:
	return []
	
func buildStateChanged(signalValue:SwDefine.CircuitSignal) -> void:
	pass

func setPortFlag() -> void:
	pass
	
func getExpr(pinDir:SwDefine.SW_Dir) -> SwDefine.SWCircuitStruct:
	return null

func getBuildExpr() -> void:
	pass
	
func getValue(dir:SwDefine.SW_Dir) -> SwDefine.CircuitSignal:
	return SwDefine.CircuitSignal.NONE
func setValue(dir:SwDefine.SW_Dir,value:SwDefine.CircuitSignal) -> void:
	pass
