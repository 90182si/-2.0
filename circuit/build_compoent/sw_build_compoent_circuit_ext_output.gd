class_name SWBuildCompoentCircuitExtOutput extends SWBuildCompoentCircuit

# 外部输出接口（move/rotation）：四向输入口，只读所连 net 电平，不驱动任何 net。
# 与灯泡的区别：不进 LED 分组、不切图集帧、不写任何渲染状态 —— 它是逻辑读取点。

func setPortFlag(_buildDef:SWBuildDefine) -> void:
	setPinDefine(SwDefine.SW_Dir.UP,SwDefine.CircuitPinType.INPUT)
	setPinDefine(SwDefine.SW_Dir.RIGHT,SwDefine.CircuitPinType.INPUT)
	setPinDefine(SwDefine.SW_Dir.DOWN,SwDefine.CircuitPinType.INPUT)
	setPinDefine(SwDefine.SW_Dir.LEFT,SwDefine.CircuitPinType.INPUT)

# 与灯泡同款的汇聚表达式：把上游驱动表达式拉进表达式图。
# 表达式路径（DAG）要求下游先把上游表达式建出来，否则这条线的上游求值不到
func getBuildExpr() -> void:
	for dir in range(3,-1,-1):
		if pinExprMap.has(dir):
			continue
		if not portIsInput(dir):
			continue
		var net:SWNet = pinNetMap.get(dir,null)
		if not net:
			continue
		pinExprMap[dir] = SwDefine.SWCircuitStruct.new()
		pinExprMap[dir].optFunc = SwCommon.AndValues
		pinExprMap[dir].optFuncName = "SwCommon.AndValues"
		var drivers = net.getDrivers()
		for driver:Dictionary in drivers:
			var build = driver["build"]
			var pDir = driver["pinDir"]
			build.getCircuitCompoent().getBuildExpr()
			if build.getCircuitCompoent()._buildingExpr:
				build.in_loop = true
				buildRef.in_loop = true
				continue
			var expr = build.getCircuitCompoent().getExpr(pDir)
			if expr:
				pinExprMap[dir].args.append(expr)

# 不驱动任何 net、不切任何帧：本元件没有任何视觉行为
func evaluate() -> int:
	return 0

func evalOutput() -> int:
	return 0

# 当前读到的电平（0/1）：任一输入口 net 为高即 1。
# 边界层（.swcir 导出 / 机器人）用它取输出信号
func readLevel() -> int:
	for dir in 4:
		if netBit(dir) == 1:
			return 1
	return 0
