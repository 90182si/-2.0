class_name SWBuildCompoentCircuitLed extends SWBuildCompoentCircuit

# 灯泡（汇聚型输入）组件
# 把所有输入方向 net 上的驱动表达式用 AndValues 组合，求值后传播给电线，
# 只要任一方向为 HIGH 即点亮。

func setPortFlag(_buildDef:SWBuildDefine) -> void:
	setPinDefine(SwDefine.SW_Dir.UP,SwDefine.CircuitPinType.INPUT)
	setPinDefine(SwDefine.SW_Dir.RIGHT,SwDefine.CircuitPinType.INPUT)
	setPinDefine(SwDefine.SW_Dir.DOWN,SwDefine.CircuitPinType.INPUT)
	setPinDefine(SwDefine.SW_Dir.LEFT,SwDefine.CircuitPinType.INPUT)

func getBuildExpr() -> void:
	for dir in range(3,-1,-1):
		#如果已经存在了就不计算
		if pinExprMap.has(dir):
			continue
		#如果不是输入口
		if not portIsInput(dir):
			continue
		var net:SWNet = pinNetMap.get(dir,null)
		if not net:
			continue
		#该部件的函数是需要线与and
		pinExprMap[dir] = SwDefine.SWCircuitStruct.new()
		pinExprMap[dir].optFunc = SwCommon.AndValues
		pinExprMap[dir].optFuncName = "SwCommon.AndValues"
		#把每个条件加到args里面
		#获取net的驱动端口们（穿越寄存器的反馈不判环）
		#appendDriverExprs(pinExprMap[dir], net)
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

func getValue(dir:SwDefine.SW_Dir) -> SwDefine.CircuitSignal:
	var value = super.getValue(dir)
	var net:SWNet = pinNetMap.get(dir,null)
	if net:
		net.curSignal = value
		for load:SWBuildItemDefine in net.wireGroup.wireBuilds:
			load.getCircuitCompoent().setValue(dir,value)
	return value
	
func reCalSignals() -> Array[SWBuildItemDefine]:
	var retArr:Array[SWBuildItemDefine] = super.reCalSignals()
	var v1 = getValue(SwDefine.SW_Dir.UP) == SwDefine.CircuitSignal.HIGH
	var v2 = getValue(SwDefine.SW_Dir.RIGHT) == SwDefine.CircuitSignal.HIGH
	var v3 = getValue(SwDefine.SW_Dir.DOWN) == SwDefine.CircuitSignal.HIGH
	var v4 = getValue(SwDefine.SW_Dir.LEFT) == SwDefine.CircuitSignal.HIGH
	var value = SwDefine.CircuitSignal.LOW
	if v1 or v2 or v3 or v4:
		value = SwDefine.CircuitSignal.HIGH
	else:
		value = SwDefine.CircuitSignal.LOW
	buildRef.buildStateChanged(value)
	return retArr
