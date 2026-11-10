class_name SWRobotActions extends RefCounted

# ==========================================================================
# 机器人事件接口：电路输出名 -> 动作
#
# 机器人每拍读出电路的**全部输出现（名字 + 电平）**，名字登记在这张表里的，
# 电平为 1 就当一次「事件」执行对应动作。所以想让电路多驱动一种行为：
#   1. 在 circuit/sw_io_name_catalog.gd 的 OUTPUT_NAMES 里加名字（HUD 下拉框才有）；
#   2. 在这里加一行 {"name": 同一个名字, "kind": 动作}；
#   3. 动作实现写在 SWEntityLayerSystem 的 step_beat_low() 里（match kind）。
#
# 顺序很重要：TABLE 的顺序就是同一拍内多个事件同时为 1 时的执行顺序。
# rotation 排在 move 前面是历史口径（一拍内先转向、再按新朝向走一格），
# test_robot_runtime 里有对应的断言，不要随手调换。
#
# 检测不走动作表：detect_sig_0..7 是**方向码的那 3 个位**，不是一次性动作。
# 机器人每拍读上一拍这 3 个位拼出的方向值（0..7 = **相对朝向**的方位），
# 把那个方向的检测码写进 detect_res_0..7（详见 SWEntityLayerSystem 的「8 方向检测」region）。
# 所以它们不进 TABLE，也不产生动作，只是把检测结果回灌给电路。
# ==========================================================================

const TABLE: Array = [
	{"name": "rotation", "kind": "rotate"}, # 顺时针转 90 度
	{"name": "move", "kind": "move"},       # 沿当前朝向前进一格（可推箱子）
	{"name": "push", "kind": "push"},       # 只把正前方的箱子推一格，机器人自己不动
]

# ===== 检测通道（方向 3 位 + 物品码 5 位）=====
# 方向码是**相对机器人朝向**的 8 方位，顺时针 +1（绝对方向见 REL8_NAMES/ABS8_NAMES）：
#   0 正前 / 1 右前 / 2 正右 / 3 右后 / 4 正后 / 5 左后 / 6 正左 / 7 左前
# 例：方向码 6（它自己坐标系里的“左边”）+ 机器人朝西 -> 实际看**正南**。
# 换算：abs = posmod(dir * 2 + code, 8)，见 abs_dir_of()。dir 0..3 = 上/右/下/左，
# 乘 2 正好对上 DIR8_VECS 的 0 北 / 2 东 / 4 南 / 6 西。
#
# detect_sig_<i>：电路**输出**。8 根口合起来看成一个 8 位二进制数，位序是
#   **编号小的在左（最高位）**：
#     detect_sig_0 = 权重 4、detect_sig_1 = 权重 2、detect_sig_2 = 权重 1，
#     后 5 位（detect_sig_3..7）保留，暂不参与。
#   => 「sig_0/sig_1/sig_2 = 110」就是方向码 6。
#
# detect_res_<i>：电路**输入**。机器人把检测码回写，同一套「编号小的在左」口径：
#     detect_res_0..2 = 方向码（权重 4/2/1，原样回示电路选的方向码）
#     detect_res_3..7 = 物品码（权重 16/8/4/2/1，例：00111 = 物品码 7）
#
# 内部一律用一个 8 位整数 code 表示：bit7..bit5 = 方向码，bit4..bit0 = 物品。
# 口序号 port 与位序号 bit 的换算见 res_bit（bit = 7 - port）：
#   所以 _bin8(code) 打印出来的 8 个字符，从左到右正好是 res_0..res_7。
const DETECT_COUNT: int = 8 # 8 根口
const DIR_BITS: int = 3     # 方向占高 3 位
const ITEM_BITS: int = 5    # 物品码占低 5 位
const ITEM_MASK: int = 0b11111
# 方向只用前 3 根 sig 口（sig_3..7 是保留位，写了也不参与）
const SIG_DIR_COUNT: int = 3
# 物品码：低位 5 位，0 空、1 机器人、2 箱子，其余值留给以后扩展（0..31）
const ITEM_NONE: int = 0
const ITEM_ROBOT: int = 0b00001
const ITEM_BOX: int = 0b00010

const SIG_PREFIX: String = "detect_sig_"
const RES_PREFIX: String = "detect_res_"

# 口名预生成：res_name/sig_name 每拍每台要调十几次（写 8 根 res、读 3 根 sig），
# 现拼字符串就是每拍分配十几个临时 String；几十台机器人时白烧垃圾回收。
# 长度必须与 DETECT_COUNT 一致；越界时退回拼接路径（不会崩，只是慢）
const RES_PORT_NAMES: Array[String] = [
	"detect_res_0", "detect_res_1", "detect_res_2", "detect_res_3",
	"detect_res_4", "detect_res_5", "detect_res_6", "detect_res_7",
]
const SIG_PORT_NAMES: Array[String] = [
	"detect_sig_0", "detect_sig_1", "detect_sig_2", "detect_sig_3",
	"detect_sig_4", "detect_sig_5", "detect_sig_6", "detect_sig_7",
]

# 方向显示名：相对名用于方向码（它依赖于机器人朝向），绝对名用于实际落点
const REL8_NAMES: Array[String] = ["正前", "右前", "正右", "右后", "正后", "左后", "正左", "左前"]
const ABS8_NAMES: Array[String] = ["北", "东北", "东", "东南", "南", "西南", "西", "西北"]

# 动作名清单（按 TABLE 顺序自动生成）：实体层每拍用 bundle.read_output_bits(ACTION_NAMES)
# 一次读出全部动作口的电平，不再逐个 output_level
static var ACTION_NAMES: Array[String] = []
# TABLE 的平行数组：动作类型 / 名字。
# 为什么不在热路径里遍历 TABLE 取 Dictionary：上万台时每拍要跑两遍（高相位收/低相位执行），
# 每台碰 3 次 Dictionary + 字符串比较就是几十万次哈希；平行数组只按下标取，
# 而且跟 ACTION_NAMES 同序，动作位图的第 i 位正好对应这里第 i 项
static var ACTION_KINDS: Array[String] = []
# 动作类型 -> 整数 id（与 ACTION_KIND_IDS 一一对应）。
# 低相位执行时每台按位图逐位过表，上万台一拍要跑几万次字符串比较；
# 换成 int 后 match 直接拿跳转表，一次比较都不做。名字只给面板/日志看
const KIND_ROTATE: int = 0
const KIND_MOVE: int = 1
const KIND_PUSH: int = 2
# 与 ACTION_KINDS 平行的整数 id 数组（第 i 位 = 位图第 i 位执行什么）
static var ACTION_KIND_IDS: PackedInt32Array = PackedInt32Array()
# 「move / rotation」在动作位图里的位号（-1 = 表里没这一行）
static var MOVE_BIT: int = -1
static var ROT_BIT: int = -1
# 上面两个位号对应的掩码（0 = 表里没这行，位测试永远为假）
static var MOVE_MASK: int = 0
static var ROT_MASK: int = 0

# 方向选择用的三根 sig 口名（与 SIG_DIR_COUNT 同序，一次批量读）
const SIG_DIR_NAMES: Array[String] = ["detect_sig_0", "detect_sig_1", "detect_sig_2"]

static func _static_init() -> void:
	ACTION_NAMES = []
	ACTION_KINDS = []
	ACTION_KIND_IDS = PackedInt32Array()
	for row: Dictionary in TABLE:
		var nm: String = str(row.get("name", ""))
		ACTION_NAMES.append(nm)
		var kd: String = str(row.get("kind", ""))
		ACTION_KINDS.append(kd)
		ACTION_KIND_IDS.append(_kind_id(kd))
		if nm == "move":
			MOVE_BIT = ACTION_NAMES.size() - 1
		elif nm == "rotation":
			ROT_BIT = ACTION_NAMES.size() - 1
	MOVE_MASK = (1 << MOVE_BIT) if MOVE_BIT >= 0 else 0
	ROT_MASK = (1 << ROT_BIT) if ROT_BIT >= 0 else 0

# 动作类型名 -> 整数 id；表里写错的种类返回 -1（调用方跳过，不当成任何动作）
static func _kind_id(kind_name: String) -> int:
	match kind_name:
		"rotate": return KIND_ROTATE
		"move": return KIND_MOVE
		"push": return KIND_PUSH
		_: return -1

# 输出名 -> 动作类型名；没登记的名字返回空串（只当时序信号看，不产生动作）
static func kind_of(name: String) -> String:
	for row: Dictionary in TABLE:
		if str(row.get("name", "")) == name:
			return str(row.get("kind", ""))
	return ""

# 表里登记过的全部输出名（面板/排障用）
static func names() -> Array[String]:
	var out: Array[String] = []
	for row: Dictionary in TABLE:
		out.append(str(row.get("name", "")))
	return out

# 口序号 -> 该 sig 口的输出名（选方向用的三根就是 sig_name(0..2)）
static func sig_name(port: int) -> String:
	if port >= 0 and port < SIG_PORT_NAMES.size():
		return SIG_PORT_NAMES[port]
	return SIG_PREFIX + str(port)

# 口序号 -> 该 res 口的输入名
static func res_name(port: int) -> String:
	if port >= 0 and port < RES_PORT_NAMES.size():
		return RES_PORT_NAMES[port]
	return RES_PREFIX + str(port)

# 口序号 -> 内部位序号：编号小的口在左（最高位），即 res_0 是 bit7、res_7 是 bit0
static func res_bit(port: int) -> int:
	return DETECT_COUNT - 1 - port

# 方向用的某根 sig 口的权重（sig_0=4、sig_1=2、sig_2=1）；保留位返回 0
static func sig_weight(port: int) -> int:
	if port < 0 or port >= SIG_DIR_COUNT:
		return 0
	return 1 << (SIG_DIR_COUNT - 1 - port)

# 输出名 -> 该 sig 口的方向权重（不是 detect_sig_* 返回 -1，保留位返回 0）
static func sig_weight_of(name: String) -> int:
	if not name.begins_with(SIG_PREFIX):
		return -1
	var s: String = name.substr(SIG_PREFIX.length())
	if not s.is_valid_int():
		return -1
	var d: int = int(s)
	if d < 0 or d >= DETECT_COUNT:
		return -1
	return sig_weight(d)

# 输入名 -> 内部位序号（detect_res_0 是 bit7）；不是 detect_res_* 返回 -1
static func bit_of_res(name: String) -> int:
	if not name.begins_with(RES_PREFIX):
		return -1
	var s: String = name.substr(RES_PREFIX.length())
	if not s.is_valid_int():
		return -1
	return res_bit(int(s)) if int(s) >= 0 and int(s) < DETECT_COUNT else -1

# 机器人朝向 dir（0 上 1 右 2 下 3 左）-> 绝对方向码 8 方位（0 北 2 东 4 南 6 西）
# 乘 2 是因为朝向只取 4 个正向，而检测方向码是 8 方位
static func facing_dir8(dir: int) -> int:
	return posmod(dir, 4) * 2

# 方向码（相对朝向）-> 绝对方向码（0 北 … 7 西北）
# 例：朝西（dir=3 -> 6）+ 方向码 6 = 12 mod 8 = 4 = 正南
static func abs_dir_of(robot_dir: int, dir_code: int) -> int:
	return posmod(facing_dir8(robot_dir) + dir_code, DETECT_COUNT)

# 方向码 + 物品码 -> 8 位检测码
static func encode_code(dir_code: int, item_code: int) -> int:
	return ((dir_code & 0b111) << ITEM_BITS) | (item_code & ITEM_MASK)

# 取出码里的方向码（**相对朝向**的原始值，即电路当初选的那个）
static func decode_dir(code: int) -> int:
	return (code >> ITEM_BITS) & 0b111

static func decode_item(code: int) -> int:
	return code & ITEM_MASK

# 检测码 -> 人读文本（日志/面板/测试失败信息用）
# 0b 后面那 8 个字符从左到右就是 res_0..res_7 的口序（前 3 位方向 + 后 5 位物品）
# robot_dir >= 0 时额外标出实际落点（相对码只有配合朝向才知道看的是哪边）
static func code_text(code: int, robot_dir: int = -1) -> String:
	var d: int = decode_dir(code)
	var item: int = decode_item(code)
	var dir_name: String = REL8_NAMES[d] if d < REL8_NAMES.size() else str(d)
	if robot_dir >= 0:
		var a: int = abs_dir_of(robot_dir, d)
		dir_name = "%s->%s" % [ABS8_NAMES[a], dir_name]
	var item_name: String = "空"
	if item == ITEM_ROBOT:
		item_name = "机器人"
	elif item == ITEM_BOX:
		item_name = "箱子"
	elif item != ITEM_NONE:
		item_name = "物品%d" % item
	return "%s/%s(0b%s)" % [dir_name, item_name, _bin8(code)]

static func _bin8(code: int) -> String:
	var s: String = ""
	for i in range(DETECT_COUNT - 1, -1, -1):
		s += "1" if ((code >> i) & 1) == 1 else "0"
	return s
