class_name SWBuildWire extends SWBuildItemDefine


var wireGroup:SWDefine.SWWireGroup = null

func getLinkedBuilds(swBuildManager:SWBuildManager) -> Array:
	var retArr = []
	var linkBuilds = []
	var linkMap = {}
	for dir in range(4):
		if bLinkedPort(dir) or bIsToBeRemoved():
			continue
		var nextBuild:SWBuildItemDefine = getDirBuild(swBuildManager,dir)
		if nextBuild == null:
			continue
		if nextBuild.comp_type != SWDefine.CircuitComponentType.WIRE:
			var antiDir:SWDefine.SW_Dir = SWDefine.getAntiDir(dir)
			linkBuilds.append(nextBuild)
			if nextBuild.portIsInput(1<<(3-antiDir)):
				setLinkedPort(dir)
				nextBuild.setLinkedPort(antiDir)
				linkMap[{"from":id,"dir":dir,"name":buildDefine.buildName}]={"to":nextBuild.id,"name":nextBuild.buildDefine.buildName,"signal":'='}
		else:
			var antiDir:SWDefine.SW_Dir = SWDefine.getAntiDir(dir)
			setLinkedPort(dir)
			nextBuild.setLinkedPort(antiDir)
			linkBuilds.append(nextBuild)
			#if nextBuild.portIsInput(antiDir):
			#	linkMap[{"from":id,"dir":dir,"name":buildDefine.buildName}]={"to":nextBuild.id,"name":nextBuild.buildDefine.buildName,"signal":'='}
			
	retArr.append(linkBuilds)
	retArr.append(linkMap)
	return retArr

func getDirBuild(swBuildManager:SWBuildManager,rot:SWDefine.SW_Dir) -> SWBuildItemDefine:
	var nextPos:Vector2i = buildAxisPos + 128*SWDefine.dir_to_vec(rot)
	var dir:SWDefine.SW_Dir = rot
	var nextBuild:SWBuildItemDefine = swBuildManager.getBuild(nextPos)
	if nextBuild == null:
		return null
	var antiDir:SWDefine.SW_Dir = SWDefine.getAntiDir(dir)
	var v:int = 1<<((3-antiDir+nextBuild.rotation)%4)
	if not nextBuild.isPort(v):
		return null
	if nextBuild.bLinkedPort(v):
		return null
	if nextBuild.isWireBuild():
		var wireBuild:SWBuildWire = nextBuild as SWBuildWire
		if wireBuild.wireGroup == null:
			if wireGroup == null:
				wireGroup = SWDefine.SWWireGroup.new()
				wireGroup.addWireBuild(self)
			wireBuild.wireGroup = wireGroup
			wireGroup.addWireBuild(wireBuild)
		return nextBuild
	#if nextBuild.portIsInput(v):
	#	return nextBuild
	return nextBuild

func getBuildIOConnectBuildArr(swBuildManager:SWBuildManager) -> Array[SWBuildItemDefine]:
	var linkedBuilds:Array[SWBuildItemDefine] = []
	for dir in range(4):
		var nextBuild:SWBuildItemDefine = getDirBuild(swBuildManager,dir)
		if nextBuild == null:
			continue
		linkedBuilds.append(nextBuild)
	if wireGroup == null:
		wireGroup = SWDefine.SWWireGroup.new()
		wireGroup.addWireBuild(self)
	return linkedBuilds
	
func buildStateChanged(signalValue:SWDefine.CircuitSignal) -> void:
	if signalValue == SWDefine.CircuitSignal.LOW:
		drawRect = buildDefine.atlasTextureOff.region
	elif signalValue == SWDefine.CircuitSignal.HIGH:
		drawRect = buildDefine.atlasTextureOn.region

func setPortFlag() -> void:
	canConBit = 0b1111
	portDefine = 0b10000
	portValue = 0b0000

func reCalSignals(swBuildManager:SWBuildManager) -> Array[SWBuildItemDefine]:
	var v:int = 0
	var f = 1
	var dependWires = wireGroup.wireBuilds
	for dependWire in dependWires:
		var depends = dependWire.circuit.sourceSignalMap[dependWire.id]
		for dependItem in depends:
			var vs = dependItem["signal"]
			var k:int = 1 if dependWire.circuit.inputValues[dependItem["from"]] > 0 else 0
			if vs == '!':
				k = 1 - k
			if f:
				f=0
				v = k
			else:
				v &= k
	if v > 0:
		for dependWire in dependWires:
			dependWire.buildStateChanged(SWDefine.CircuitSignal.HIGH)
	else:
		for dependWire in dependWires:
			dependWire.buildStateChanged(SWDefine.CircuitSignal.LOW)
	return dependWires
