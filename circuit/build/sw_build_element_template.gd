# 电路元件脚手架模板 / Circuit element scaffold
# 用法：复制本文件 -> 重命名为 sw_build_xxx.gd 且把 class_name 改成 SWBuildXxx
#      -> 按需实现下面的方法 -> 按文件底部 “注册步骤” 接入工厂/枚举/资源。
#
# 约定：
# - 元件本体继承 SWBuildItemDefine，端口/网络/表达式等状态放在 CIRCUIT 组件
#   (SWBuildCompoentCircuit) 上，通过 getCompoent(...) 取得。
# - 端口在“本地未旋转坐标系”里声明(UP/RIGHT/DOWN/LEFT)，框架在查询时自动叠加 rotation。
# - 组合逻辑函数复用 SwCommon.AndValues / NotAndValues / EqualValues，
#   或在 com/sw_common.gd 里新增(例如 OrValues / XorValues)。
class_name SWBuildElementTemplate extends SWBuildItemDefine

# 元件自身状态（按需保留）
var _active: bool = false

# 端口定义：声明每个方向是 INPUT / OUTPUT / WIRE
func setPortFlag(buildDef:SWBuildDefine) -> void:
	var circuit: SWBuildCompoentCircuit = getCircuitCompoent()
	circuit.setPinDefine(SwDefine.SW_Dir.UP, SwDefine.CircuitPinType.OUTPUT)
	circuit.setPinDefine(SwDefine.SW_Dir.DOWN, SwDefine.CircuitPinType.INPUT)
	circuit.setPinDefine(SwDefine.SW_Dir.LEFT, SwDefine.CircuitPinType.INPUT)
	circuit.setPinDefine(SwDefine.SW_Dir.RIGHT, SwDefine.CircuitPinType.INPUT)

# 组合逻辑：把所有输入侧 net 上的驱动表达式，用一个逻辑函数组合成表达式树，
# 存到输出方向 circuit.pinExprMap[...] 里。
func getBuildExpr() -> void:
	if _buildingExpr:
		return
	_buildingExpr = true
	var circuit: SWBuildCompoentCircuit = getCircuitCompoent()
	# TODO: 遍历输入侧 net 的 drivers，收集子表达式后用 SwCommon.AndValues 等组合
	_buildingExpr = false

# 供上游取本元件在某方向上的输出表达式
func getExpr(pinDir: SwDefine.SW_Dir) -> SwDefine.SWCircuitStruct:
	var circuit: SWBuildCompoentCircuit = getCircuitCompoent()
	if circuit.portIsOutput(pinDir):
		return circuit.pinExprMap.get(SwDefine.getAntiDir(pinDir), null)
	return null

# 求值：读取表达式树结果，并把值推给下游电线
func getValue(dir: SwDefine.SW_Dir) -> SwDefine.CircuitSignal:
	var circuit: SWBuildCompoentCircuit = getCircuitCompoent()
	var value: SwDefine.CircuitSignal = circuit.getValue(dir)
	var net: SWNet = circuit.pinNetMap.get(dir, null)
	if net:
		for load: SWBuildItemDefine in net.wireGroup.wireBuilds:
			load.setValue(dir, value)
	return value

func setValue(dir: SwDefine.SW_Dir, value: SwDefine.CircuitSignal) -> void:
	pass

# 重算自身状态并返回需要级联重算的下游元件
func reCalSignals() -> Array[SWBuildItemDefine]:
	var retArr: Array[SWBuildItemDefine] = [self]
	buildStateChanged(getValue(rotation))
	return retArr

# 视觉：切换图集 on/off 区域
func buildStateChanged(signalValue: SwDefine.CircuitSignal) -> void:
	super.buildStateChanged(signalValue)
	if signalValue == SwDefine.CircuitSignal.HIGH:
		getRenderableCompoent().drawRect = buildDefine.atlasTextureOn.region
	else:
		getRenderableCompoent().drawRect = buildDefine.atlasTextureOff.region

func resetPortState() -> void:
	super.resetPortState()
	getRenderableCompoent().drawRect = buildDefine.atlasTextureOff.region

# ===== 注册步骤（新增元件后必做）=====
# 1) core/define/sw_define.gd -> enum CircuitComponentType 末尾加一个类型(如 AND_GATE)
# 2) core/define/sw_define.gd -> SWBuildCreator() 里加:
#      "元件名": return SWBuildXxx.new(axisPos, buildDef, rot)
# 3) res/ 下新建 元件名.tres(script_class="SWBuildDefine")，
#      buildName 填 "元件名"，circuit_component_type 填新枚举整数值，
#      atlasTextureOn/Off 填图集里对应的 region 矩形。yard 注册表会自动扫描 res/ 完成登记。
# 4) 若要让元件出现在手持/工具栏，另在对应 UI(如 layers/hud、layers/hold) 添加入口。
