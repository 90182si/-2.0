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
		if pinExprMap.has(dir):
			continue
		if not portIsInput(dir):
			continue
		var net:SWNet = pinNetMap.get(dir,null)
		if not net:
			continue
		var expr_struct = SwDefine.SWCircuitStruct.new()
		expr_struct.optFunc = SwCommon.AndValues
		expr_struct.optFuncName = "SwCommon.AndValues"
		var drivers = net.getDrivers()
		for driver:Dictionary in drivers:
			var build = driver["build"]
			var pDir = driver["pinDir"]
			# 电线桥接
			if SwCommon.IsWireBuild(build):
				var seen_nets:Dictionary = {}
				for wire_net:SWNet in build.getCircuitCompoent().pinNetMap.values():
					if wire_net == null or seen_nets.has(wire_net):
						continue
					seen_nets[wire_net] = true
					appendDriverExprs(expr_struct, wire_net)
				continue
			var drvComp:SWBuildCompoentCircuit = build.getCircuitCompoent()
			drvComp.getBuildExpr()
			# 时序屏障：驱动是寄存器时不判环，直接取其 Q 侧状态叶子
			if drvComp._buildingExpr and not drvComp.isSequential():
				build.in_loop = true
				buildRef.in_loop = true
				continue
			var expr = drvComp.getExpr(pDir)
			if expr:
				expr_struct.args.append(expr)
		# 无驱动源时不创建表达式（浮空=低电平）
		if expr_struct.args.size() > 0:
			expr_struct.op = SwDefine.CircuitOp.OP_AND
			pinExprMap[dir] = expr_struct

func getValue(dir:SwDefine.SW_Dir) -> SwDefine.CircuitSignal:
	# T2.5：IR slot 命中时直读查表，输入 net 电平由驱动者的 push 写回，
	# 本组件不再向 net 写入（避免覆盖驱动源状态）
	var sv := _getIrSlotValue(dir)
	if sv != -1:
		return SwDefine.CircuitSignal.HIGH if sv == 1 else SwDefine.CircuitSignal.LOW
	var value = _getValueTree(dir)
	var net:SWNet = pinNetMap.get(dir,null)
	#仅在有效电平时写入，避免 NONE 覆盖驱动源已写入的正确信号（仅树路径保留副作用）
	if net and value != SwDefine.CircuitSignal.NONE:
		net.curSignal = value
		for load:SWBuildItemDefine in net.wireGroup.wireBuilds:
			load.getCircuitCompoent().setValue(dir,value)
	return value
	
func reCalSignals() -> Array[SWBuildItemDefine]:
	var retArr:Array[SWBuildItemDefine] = [buildRef]#super.reCalSignals()
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
