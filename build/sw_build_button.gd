class_name SWBuildButton extends SWBuildItemDefine

func setPortFlag() -> void:
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	circuitCompoent.setPinDefine(SWDefine.SW_Dir.UP,SWDefine.CircuitPinType.OUTPUT)

var pressed:bool = false
func onPressed(_pressed:bool) -> void:
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	pressed = _pressed
	if pressed == true:
		drawRect = buildDefine.atlasTextureOn.region
		circuitCompoent.setPinValue(SWDefine.SW_Dir.UP,SWDefine.CircuitSignal.HIGH)
	else:
		drawRect = buildDefine.atlasTextureOff.region
		circuitCompoent.setPinValue(SWDefine.SW_Dir.UP,SWDefine.CircuitSignal.LOW)

func getExpr(pinDir:SWDefine.SW_Dir) -> SWDefine.SWCircuitStruct:
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	#如果是按钮的出口方向
	#函数就是直接等于
	#参数是自己和出口端口
	if pinDir == rotation:
		if not circuitCompoent.pinExprMap.has(pinDir):
			circuitCompoent.pinExprMap[pinDir] = SWDefine.SWCircuitStruct.new()
			circuitCompoent.pinExprMap[pinDir].optFunc = SWCommon.EqualValues
			circuitCompoent.pinExprMap[pinDir].optFuncName = "SWCommon.EqualValues"
			circuitCompoent.pinExprMap[pinDir].args = [SWDefine.SWBuildPinStruct.new(self,pinDir)]
			#return circuitCompoent.pinExprMap[pinDir]
		return circuitCompoent.pinExprMap[pinDir]
	return null

func getBuildExpr() -> void:
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	if not circuitCompoent.pinExprMap.has(rotation):
		circuitCompoent.pinExprMap[rotation] = SWDefine.SWCircuitStruct.new()
		circuitCompoent.pinExprMap[rotation].optFunc = SWCommon.EqualValues
		circuitCompoent.pinExprMap[rotation].optFuncName = "SWCommon.EqualValues"
		circuitCompoent.pinExprMap[rotation].args = [SWDefine.SWBuildPinStruct.new(self,rotation)]


func getValue(dir:SWDefine.SW_Dir) -> SWDefine.CircuitSignal:
	if dir == rotation:
		if pressed == true:
			return SWDefine.CircuitSignal.HIGH
		elif pressed == false:
			return SWDefine.CircuitSignal.LOW
	return SWDefine.CircuitSignal.NONE

func setValue(dir:SWDefine.SW_Dir,value:SWDefine.CircuitSignal) -> void:
	pass
