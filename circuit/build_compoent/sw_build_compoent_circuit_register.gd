class_name SWBuildCompoentCircuitRegister extends SWBuildCompoentCircuit

# 1bit 寄存器（D 触发器，CLK 上升沿锁存）组件
# 端口约定（参考 rotation=0 的坐标系，随机身旋转）：
#   UP    = CLK  输入（时钟）
#   LEFT  = D    输入（数据）
#   RIGHT = Q    输出（锁存结果）
# 时序元件：Q 输出取自内部锁存状态，不参与组合逻辑求值，
# 因此寄存器能打断组合环——输入侧表达式永远只在 CLK/D 方向展开，
# Q 方向是一个自源叶子（读取 qState），下游按普通信号源取用。

# 逻辑端口在参考坐标系中的方向
const CLK_REF:int = SwDefine.SW_Dir.UP
const D_REF:int = SwDefine.SW_Dir.LEFT
const Q_REF:int = SwDefine.SW_Dir.RIGHT

# 锁存输出的状态（Q 电平）
var qState:SwDefine.CircuitSignal = SwDefine.CircuitSignal.LOW
# 上一次采样到的 CLK 电平，用于上升沿检测；NONE 表示尚未对齐过时钟相位
var lastClk:SwDefine.CircuitSignal = SwDefine.CircuitSignal.NONE

# 参考方向 + 机身旋转 = 世界方向
func _worldDir(refDir:int) -> int:
	return posmod(refDir + buildRef.rotation, 4)

func setPortFlag(_buildDef:SWBuildDefine) -> void:
	setPinDefine(CLK_REF, SwDefine.CircuitPinType.INPUT)
	setPinDefine(D_REF, SwDefine.CircuitPinType.INPUT)
	setPinDefine(Q_REF, SwDefine.CircuitPinType.OUTPUT)

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
	for dir in range(3,-1,-1):
		#如果已经存在了就不计算
		if pinExprMap.has(dir):
			continue
		#如果不是输入口
		if not portIsOutput(dir):
			continue
		var net:SWNet = pinNetMap.get(dir,null)
		if not net:
			continue
		pinExprMap[dir] = SwDefine.SWCircuitStruct.new()
		pinExprMap[dir].optFunc = SwCommon.EqualValues
		pinExprMap[dir].optFuncName = "SwCommon.EqualValues"
		pinExprMap[dir].args = [SwDefine.SWBuildPinStruct.new(buildRef,dir)]
	#if _buildingExpr:
		#return
	#_buildingExpr = true
	# Q 输出：锁存状态自源表达式（叶子读取 qState，打断组合环）
	# 先建好 Q 叶子，反馈链上的组合元件反向进入时才能直接取用而不触发环路判定
	#var qDir = _worldDir(Q_REF)
	#var net:SWNet = pinNetMap.get(qDir,null)
	#if not net:
		##_buildingExpr = false
		#return
	#if not pinExprMap.has(qDir):
		#pinExprMap[qDir] = SwDefine.SWCircuitStruct.new()
		#pinExprMap[qDir].optFunc = SwCommon.EqualValues
		#pinExprMap[qDir].optFuncName = "SwCommon.EqualValues"
		#pinExprMap[qDir].args = [SwDefine.SWBuildPinStruct.new(buildRef, qDir)]
		#var drivers = net.getDrivers()
		#for driver:Dictionary in drivers:
			#var build = driver["build"]
			#var pDir = driver["pinDir"]
			#build.getCircuitCompoent().getBuildExpr()
			#if build.getCircuitCompoent()._buildingExpr:
				#build.in_loop = true
				#buildRef.in_loop = true
				#continue
			#var expr = build.getCircuitCompoent().getExpr(pDir)
			#if expr != null:
				#pinExprMap[qDir].args.append(expr)
		#_buildingExpr = false

func getExpr(pinDir:SwDefine.SW_Dir) -> SwDefine.SWCircuitStruct:
	# 仅输出端口（Q）对外提供表达式
	if portIsOutput(pinDir):
		return pinExprMap.get(pinDir, null)
	return null

var curClk:SwDefine.CircuitSignal = SwDefine.CircuitSignal.NONE
var curD:SwDefine.CircuitSignal = SwDefine.CircuitSignal.NONE

func netValue(dir:SwDefine.SW_Dir) -> SwDefine.CircuitSignal:
	if not _dirMaskValid:
		refreshDirMasks()
	var net:SWNet = inNets[dir]
	if net == null:
		return SwDefine.CircuitSignal.NONE
	return net.signalNow()

#数据输入取本拍开始前的电平：既不触发上游求值，也不受同拍传播影响
func epochNetValue(dir:SwDefine.SW_Dir) -> SwDefine.CircuitSignal:
	if not _dirMaskValid:
		refreshDirMasks()
	var net:SWNet = inNets[dir]
	if net == null:
		return SwDefine.CircuitSignal.NONE
	return net.epochSignal()

func getValue(dir:SwDefine.SW_Dir) -> SwDefine.CircuitSignal:
	if dir == _worldDir(Q_REF):
		return qState
	return netValue(dir)

#输出电平只看锁存状态
func evalOutput() -> int:
	return 1 if qState == SwDefine.CircuitSignal.HIGH else 0

#时序元件：一轮求值只允许锁存一次，避免同拍内上游反复翻转把寄存器采样多次
func isStateful() -> bool:
	return true

func evaluate() -> int:
	var clkDir = _worldDir(CLK_REF)
	var dDir = _worldDir(D_REF)
	#时钟读本拍最新电平（上升沿就发生在本拍），数据读本拍开始前的结清值：
	#同一拍里其它寄存器先锁存的 Q 不能改变本寄存器的采样值（同步电路必须同时采样）
	curClk = netValue(clkDir)
	curD = epochNetValue(dDir)
	#还没有已知时钟相位（首次求值/旧存档）：只对齐电平，不采样可能未稳定的 D
	if lastClk == SwDefine.CircuitSignal.NONE:
		lastClk = curClk
	elif lastClk == SwDefine.CircuitSignal.LOW and curClk == SwDefine.CircuitSignal.HIGH:
		qState = curD
		lastClk = curClk
	else:
		lastClk = curClk
	buildRef.buildStateChanged(qState)
	return 1 if qState == SwDefine.CircuitSignal.HIGH else 0

func reCalSignals() -> void:
	evaluate()
