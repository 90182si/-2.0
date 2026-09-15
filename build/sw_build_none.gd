class_name SWBuildNone extends SWBuildItemDefine

func getNet(swBuildManager:SWBuildManager) -> Array:
	return [[],{}]

func getBuildIOConnectBuildArr(swBuildManager:SWBuildManager) -> Array[SWBuildItemDefine]:
	return []
	
func buildStateChanged(signalValue:SWDefine.CircuitSignal) -> void:
	pass

func setPortFlag() -> void:
	#canConBit = 0b0000
	#portDefine = 0b0000
	pass


func getExpr(pinDir:SWDefine.SW_Dir) -> SWDefine.SWCircuitStruct:
	return null

func getBuildExpr() -> void:
	pass
	
func getValue(swBuildManager:SWBuildManager,dir:SWDefine.SW_Dir) -> SWDefine.CircuitSignal:
	return SWDefine.CircuitSignal.NONE
