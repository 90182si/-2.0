class_name SWBuildNone extends SWBuildItemDefine

func getNet(swBuildManager:SWBuildManager) -> Array:
	return [[],{}]

func getBuildIOConnectBuildArr(swBuildManager:SWBuildManager) -> Array[SWBuildItemDefine]:
	return []
	
func buildStateChanged(signalValue:SWDefine.CircuitSignal) -> void:
	pass

func setPortFlag() -> void:
	pass
	
func getExpr(pinDir:SWDefine.SW_Dir) -> SWDefine.SWCircuitStruct:
	return null

func getBuildExpr() -> void:
	pass
	
func getValue(dir:SWDefine.SW_Dir) -> SWDefine.CircuitSignal:
	return SWDefine.CircuitSignal.NONE
func setValue(dir:SWDefine.SW_Dir,value:SWDefine.CircuitSignal) -> void:
	pass
