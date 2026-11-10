extends GutTest
# 外部接口元件（阶段 1）：工厂/默认名/端口语义/电路求值/存档往返。
# 头less 不重扫全局类缓存，所以新建类的判断一律走 preload 脚本比对，不写类名。
# 跑法：godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://test/circuit -gprefix test_ext_io_port -gexit

const GRID: Vector2i = SwDefine.GRID_SIZE
const IN_DEF: SWBuildDefine = preload("res://res/输入接口.tres")
#输出接口已合并为单一定义：move / rotation 只是实例上的 io_name
const OUT_DEF: SWBuildDefine = preload("res://res/输出接口.tres")
const NOT_DEF: SWBuildDefine = preload("res://res/非门.tres")
const LED_DEF: SWBuildDefine = preload("res://res/灯泡.tres")

const EXT_IN_SCRIPT := preload("res://circuit/build/sw_build_ext_input.gd")
const EXT_OUT_SCRIPT := preload("res://circuit/build/sw_build_ext_output.gd")


func _new_ctrl() -> Array:
	var mgr := SWBuildManager.new()
	var ctrl := SWCircuitControl.new()
	ctrl.setBuildManager(mgr)
	ctrl.gpu_backend_enabled = false
	return [mgr, ctrl]


# ===== 定义资源与实例默认值 =====

func test_definitions_wire_component_types() -> void:
	assert_eq(IN_DEF.circuit_component_type, SwDefine.CircuitComponentType.EXTERNAL_INPUT,
			"输入接口定义必须用 EXTERNAL_INPUT")
	assert_eq(OUT_DEF.circuit_component_type, SwDefine.CircuitComponentType.EXTERNAL_OUTPUT,
			"输出接口定义必须用 EXTERNAL_OUTPUT")
	assert_eq(IN_DEF.default_io_name, "clk")
	assert_eq(OUT_DEF.default_io_name, "move", "输出接口的默认名仍是 move")


func test_factory_creates_ext_builds_with_default_name() -> void:
	var ext_in := SwDefine.SWBuildCreator(Vector2i.ZERO, IN_DEF)
	assert_eq(ext_in.get_script(), EXT_IN_SCRIPT, "输入接口应由 SWBuildExtInput 创建")
	assert_eq(str(ext_in.get("io_name")), "clk", "输入接口默认名应为 clk")

	var move := SwDefine.SWBuildCreator(Vector2i.ZERO, OUT_DEF)
	assert_eq(move.get_script(), EXT_OUT_SCRIPT, "输出接口应由 SWBuildExtOutput 创建")
	assert_eq(str(move.get("io_name")), "move")

	# 合并后同一个定义也能是 rotation：名字是实例属性，不是定义属性
	var rot := SwDefine.SWBuildCreator(Vector2i.ZERO, OUT_DEF)
	rot.set("io_name", "rotation")
	assert_eq(rot.get_script(), EXT_OUT_SCRIPT, "两个输出接口共用同一个建筑类")
	assert_eq(str(rot.get("io_name")), "rotation")


# 接口元件不应落到默认兜底类（SWBuildNone），否则既没端口也不进电路
func test_factory_does_not_fall_back_to_none() -> void:
	for def: SWBuildDefine in [IN_DEF, OUT_DEF]:
		var build := SwDefine.SWBuildCreator(Vector2i.ZERO, def)
		assert_true(build.get_script() != SWBuildNone, "定义 %s 掉进了 SWBuildNone" % def.buildName)


# ===== 端口方向 =====

func test_input_port_points_up_as_output() -> void:
	var ext_in := SwDefine.SWBuildCreator(Vector2i.ZERO, IN_DEF)
	var comp := ext_in.getCircuitCompoent()
	assert_true(comp.portIsOutput(SwDefine.SW_Dir.UP), "输入接口的 UP 口必须是输出口")
	assert_false(comp.portIsInput(SwDefine.SW_Dir.UP))


func test_output_port_accepts_all_four_directions() -> void:
	var ext_out := SwDefine.SWBuildCreator(Vector2i.ZERO, OUT_DEF)
	var comp := ext_out.getCircuitCompoent()
	for d in 4:
		assert_true(comp.portIsInput(d), "输出接口四向都应能接输入（dir=%d）" % d)
	# 只读元件：网表分类时不能落到灯泡的 LED 分组（否则会进 LED 渲染表）
	assert_false(comp is SWBuildCompoentCircuitLed, "输出接口不能复用灯泡组件")


# ===== 名称存档往返（state 字段，不需要改 SWSaveManager） =====

func test_io_name_roundtrip_through_save_state() -> void:
	var out := SwDefine.SWBuildCreator(Vector2i.ZERO, OUT_DEF)
	out.set("io_name", "rotation")
	var state: Dictionary = out.save_state()
	assert_eq(str(state.get("io_name", "")), "rotation", "改名必须进存档 state")

	var reloaded := SwDefine.SWBuildCreator(Vector2i.ZERO, OUT_DEF)
	reloaded.load_state(state)
	assert_eq(str(reloaded.get("io_name")), "rotation", "读档必须还原实例上的 io_name")

	# 载入空 state 不能把默认名冲掉
	var fresh := SwDefine.SWBuildCreator(Vector2i.ZERO, IN_DEF)
	fresh.load_state({})
	assert_eq(str(fresh.get("io_name")), "clk")


# ===== 电路求值：clk 电平 → 非门 → 灯泡 =====

func test_input_level_drives_not_and_led() -> void:
	var pair := _new_ctrl()
	var mgr: SWBuildManager = pair[0]
	var ctrl: SWCircuitControl = pair[1]
	# ext_in 在下（输出口朝上），非门居中，灯泡在上
	var ext_in := SwDefine.SWBuildCreator(Vector2i(0, 2) * GRID, IN_DEF, 0)
	var not_g := SwDefine.SWBuildCreator(Vector2i(0, 1) * GRID, NOT_DEF, 0)
	var led := SwDefine.SWBuildCreator(Vector2i(0, 0) * GRID, LED_DEF, 0)
	var all: Array[SWBuildItemDefine] = [ext_in, not_g, led]
	for b in all:
		assert_true(mgr.addBuild(b), "放置失败: %s" % b.buildDefine.buildName)
	ctrl.updateBuildCircuit(all)

	# clk=0 → 非门输出 1 → 灯泡亮
	ext_in.call("setLevel", 0)
	ctrl.buildSignalChanged(ext_in)
	assert_eq(_led_signal(led), SwDefine.CircuitSignal.HIGH, "clk=0 时非门应输出高，灯泡应亮")

	# clk=1 → 非门输出 0 → 灯泡灭
	ext_in.call("setLevel", 1)
	ctrl.buildSignalChanged(ext_in)
	assert_eq(_led_signal(led), SwDefine.CircuitSignal.LOW, "clk=1 时非门应输出低，灯泡应灭")


# ===== 输出接口读电平：ext_in 直连 ext_out =====

func test_output_port_reads_driving_level() -> void:
	var pair := _new_ctrl()
	var mgr: SWBuildManager = pair[0]
	var ctrl: SWCircuitControl = pair[1]
	var ext_in := SwDefine.SWBuildCreator(Vector2i(0, 1) * GRID, IN_DEF, 0)
	var ext_out := SwDefine.SWBuildCreator(Vector2i(0, 0) * GRID, OUT_DEF, 0)
	var all: Array[SWBuildItemDefine] = [ext_in, ext_out]
	for b in all:
		assert_true(mgr.addBuild(b))
	ctrl.updateBuildCircuit(all)

	ext_in.call("setLevel", 1)
	ctrl.buildSignalChanged(ext_in)
	assert_eq(int(ext_out.call("outputLevel")), 1, "clk=1 时输出接口应读到 1")

	ext_in.call("setLevel", 0)
	ctrl.buildSignalChanged(ext_in)
	assert_eq(int(ext_out.call("outputLevel")), 0, "clk=0 时输出接口应读到 0")


func _led_signal(build: SWBuildItemDefine) -> SwDefine.CircuitSignal:
	var led := build as SWBuildLed
	if led == null:
		return SwDefine.CircuitSignal.NONE
	return led.currentSignal()
