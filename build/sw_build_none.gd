class_name SWBuildNone extends SWBuildItemDefine

func getLinkedBuilds(swBuildManager:SWBuildManager) -> Array:
	return [[],{}]

func getBuildIOConnectBuildArr(swBuildManager:SWBuildManager) -> Array[SWBuildItemDefine]:
	return []
	
func buildStateChanged() -> void:
	drawRect = buildDefine.atlasTextureOff.region

func setPortFlag() -> void:
	canConBit = 0b0000
	portDefine = 0b0000
