class_name SWBuildButton extends SWBuildItemDefine

var pressed:bool = false

#按钮定义
func setPortFlag(buildDef:SWBuildDefine) -> void:
	var circuitCompoent := getCircuitCompoent()
	circuitCompoent.setPinDefine(SwDefine.SW_Dir.UP,SwDefine.CircuitPinType.OUTPUT)

func onPressed(_pressed:bool) -> void:
	var circuitCompoent := getCircuitCompoent()
	pressed = _pressed
	if pressed == true:
		getRenderableCompoent().drawRect = buildDefine.atlasTextureOn.region
		circuitCompoent.setPinValue(SwDefine.SW_Dir.UP,SwDefine.CircuitSignal.HIGH)
	else:
		getRenderableCompoent().drawRect = buildDefine.atlasTextureOff.region
		circuitCompoent.setPinValue(SwDefine.SW_Dir.UP,SwDefine.CircuitSignal.LOW)

func getExpr(pinDir:SwDefine.SW_Dir) -> SwDefine.SWCircuitStruct:
	return getCircuitCompoent().pinExprMap.get(pinDir,null)

func getBuildExpr() -> void:
	var circuitCompoent := getCircuitCompoent()
	if not circuitCompoent.pinExprMap.has(rotation):
		circuitCompoent.pinExprMap[rotation] = SwDefine.SWCircuitStruct.new()
		circuitCompoent.pinExprMap[rotation].optFunc = SwCommon.EqualValues
		circuitCompoent.pinExprMap[rotation].optFuncName = "SwCommon.EqualValues"
		circuitCompoent.pinExprMap[rotation].args = [SwDefine.SWBuildPinStruct.new(self,rotation)]


func getValue(dir:SwDefine.SW_Dir) -> SwDefine.CircuitSignal:
	if dir != rotation:
		return SwDefine.CircuitSignal.NONE
	return SwDefine.CircuitSignal.HIGH if pressed else SwDefine.CircuitSignal.LOW
