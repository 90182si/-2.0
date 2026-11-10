class_name SWIOCatalog extends RefCounted

# ==========================================================================
# 接口元件可选名称清单（唯一手动扩展点）
#
# 输入接口（EXTERNAL_INPUT）只能选 INPUT_NAMES 里的名字；
# 输出接口（EXTERNAL_OUTPUT）只能选 OUTPUT_NAMES 里的名字。
# 想加新名字：直接往下面两个数组里加一行即可 —— HUD 的名称下拉框会跟着变，
# 不用改面板代码。
#
# 输出名若同时出现在机器人动作表（scene/entity/sw_robot_actions.gd）里，
# 机器人每拍就会把这个输出电平当成一个动作执行；不登记的输出名只当时序信号看。
# 检测通道是成对的：输出 detect_sig_<位> 拼方向码，输入 detect_res_<位> 收 8 位码。
# 两边都是「编号小的在左（最高位）」：sig_0/sig_1/sig_2 权重 4/2/1（后 5 位保留），
# res_0..2 = 方向码，res_3..7 = 物品码（权重 16/8/4/2/1）。
# ==========================================================================

# 输入接口可选名（电平由边界层/机器人写入）
# detect_res_0..7 = 检测码的 8 位（编号小的在左）：前 3 位方向码、后 5 位物品码，由机器人写
const INPUT_NAMES: Array[String] = [
	"clk",
	"detect_res_0", "detect_res_1", "detect_res_2", "detect_res_3",
	"detect_res_4", "detect_res_5", "detect_res_6", "detect_res_7",
]
# 输出接口可选名（机器人读它做动作；顺序即下拉框顺序）
# push 是**事件输出**：不是绑定合同的必备项（合同仍是 move + rotation），
# 但名字必须出现在这里，HUD 下拉框才能选出来，机器人那边才有事件可接。
# detect_sig_0..2 = 告诉机器人本拍要检测哪个**绝对方向**（0 北 / 2 东 / 6 西…），
# 编号小的口是高位（sig_0=4、sig_1=2、sig_2=1），sig_3..7 保留；
# 它们不是动作（不进动作表），只是把检测结果的选择权交给电路。
const OUTPUT_NAMES: Array[String] = [
	"move", "rotation", "push",
	"detect_sig_0", "detect_sig_1", "detect_sig_2", "detect_sig_3",
	"detect_sig_4", "detect_sig_5", "detect_sig_6", "detect_sig_7",
]

# 引脚类型显示名（下标 = SwDefine.CircuitPinType）
const PIN_TYPE_NAMES: Array[String] = ["无", "输入", "输出"]
# 方向显示名（下标 = SwDefine.SW_Dir）
const DIR_NAMES: Array[String] = ["上", "右", "下", "左"]

# 是不是接口元件（只这两类有 io_name）
static func is_port(comp_type: int) -> bool:
	return comp_type == SwDefine.CircuitComponentType.EXTERNAL_INPUT \
			or comp_type == SwDefine.CircuitComponentType.EXTERNAL_OUTPUT

# 某类接口元件的可选名清单；非接口元件返回空数组
static func options_for(comp_type: int) -> Array[String]:
	if comp_type == SwDefine.CircuitComponentType.EXTERNAL_INPUT:
		return INPUT_NAMES.duplicate()
	if comp_type == SwDefine.CircuitComponentType.EXTERNAL_OUTPUT:
		return OUTPUT_NAMES.duplicate()
	return []

# 「输入」/「输出」；非接口元件返回空串
static func kind_name(comp_type: int) -> String:
	if comp_type == SwDefine.CircuitComponentType.EXTERNAL_INPUT:
		return "输入"
	if comp_type == SwDefine.CircuitComponentType.EXTERNAL_OUTPUT:
		return "输出"
	return ""

static func dir_name(dir: int) -> String:
	if dir < 0 or dir >= DIR_NAMES.size():
		return "?"
	return DIR_NAMES[dir]

static func pin_type_name(pin_type: int) -> String:
	if pin_type < 0 or pin_type >= PIN_TYPE_NAMES.size():
		return "?"
	return PIN_TYPE_NAMES[pin_type]

# 元件定义的悬停说明（HUD 工具栏 tooltip 用）：
# 第一行元件名，接口元件再补「可选名称」，最后每个引脚一行「方向: 输入/输出」
static func describe_define(def: SWBuildDefine) -> String:
	if def == null:
		return ""
	var lines := PackedStringArray([def.buildName])
	var kind: String = kind_name(def.circuit_component_type)
	if not kind.is_empty():
		lines.append("%s接口：左键点击元件可改名" % kind)
		var opts: Array[String] = options_for(def.circuit_component_type)
		lines.append("可选名称：" + ", ".join(PackedStringArray(opts)))
	if def.build_pin != null:
		for pin: SWBuildPinDefine in def.build_pin:
			lines.append("%s: %s" % [dir_name(pin.pin_dir), pin_type_name(pin.pin_define)])
	return "\n".join(lines)
