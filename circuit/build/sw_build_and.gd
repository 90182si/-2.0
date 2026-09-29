# 与门 / AND gate（A 类新元件的可运行示例）
# 逻辑：所有“已连接的输入侧”驱动都为 HIGH 时，输出 HIGH。
#      组合逻辑直接复用 SwCommon.AndValues（n 输入线与）。
# 注意(TODO-几何)：当前把“上=输出、下/左/右=输入”。若你的摆放只需 2 输入，
#      请在 setPortFlag 里去掉多余输入口并核对信号极性后再上线。
class_name SWBuildAnd extends SWBuildItemDefine

func setPortFlag(buildDef:SWBuildDefine) -> void:
	var circuit := getCircuitCompoent()
	circuit.setPinDefine(SwDefine.SW_Dir.UP, SwDefine.CircuitPinType.OUTPUT)
	circuit.setPinDefine(SwDefine.SW_Dir.DOWN, SwDefine.CircuitPinType.INPUT)
	circuit.setPinDefine(SwDefine.SW_Dir.LEFT, SwDefine.CircuitPinType.INPUT)
	circuit.setPinDefine(SwDefine.SW_Dir.RIGHT, SwDefine.CircuitPinType.INPUT)

func resetPortState() -> void:
	super.resetPortState()
	getRenderableCompoent().drawRect = buildDefine.atlasTextureOff.region

func getExpr(pinDir: SwDefine.SW_Dir) -> SwDefine.SWCircuitStruct:
	var circuit := getCircuitCompoent()
	if getCircuitCompoent().portIsOutput(pinDir):
		return circuit.pinExprMap.get(rotation, null)
	return null

func getBuildExpr() -> void:
	if _buildingExpr:
		return
	_buildingExpr = true
	var circuit := getCircuitCompoent()
	if circuit.pinExprMap.has(rotation):
		_buildingExpr = false
		return
	var expr := SwDefine.SWCircuitStruct.new()
	expr.optFunc = SwCommon.AndValues
	expr.optFuncName = "SwCommon.AndValues"
	for dir in range(3, -1, -1):
		if not getCircuitCompoent().portIsInput(dir):
			continue
		var net: SWNet = circuit.pinNetMap.get(dir, null)
		if not net:
			continue
		for driver: Dictionary in net.getDrivers():
			var build = driver["build"]
			var pDir = driver["pinDir"]
			build.getBuildExpr()
			if build._buildingExpr:
				build.in_loop = true
				in_loop = true
				continue
			var sub = build.getExpr(pDir)
			if sub:
				expr.args.append(sub)
	circuit.pinExprMap[rotation] = expr
	_buildingExpr = false

func getValue(dir: SwDefine.SW_Dir) -> SwDefine.CircuitSignal:
	var circuit := getCircuitCompoent()
	var value = circuit.getValue(dir)
	var net = circuit.pinNetMap.get(dir, null)
	if net:
		for load: SWBuildItemDefine in net.wireGroup.wireBuilds:
			load.setValue(dir, value)
	return value

func reCalSignals() -> Array[SWBuildItemDefine]:
	var retArr: Array[SWBuildItemDefine] = [self]
	buildStateChanged(getValue(rotation))
	return retArr

func buildStateChanged(signalValue: SwDefine.CircuitSignal) -> void:
	super.buildStateChanged(signalValue)
	if signalValue == SwDefine.CircuitSignal.LOW:
		getRenderableCompoent().drawRect = buildDefine.atlasTextureOff.region
	elif signalValue == SwDefine.CircuitSignal.HIGH:
		getRenderableCompoent().drawRect = buildDefine.atlasTextureOn.region

func setValue(dir: SwDefine.SW_Dir, value: SwDefine.CircuitSignal) -> void:
	pass
