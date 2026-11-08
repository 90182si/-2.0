class_name SWBuildExtOutput extends SWBuildItemDefine

# 外部输出接口建筑（move / rotation 等）
# 四向输入口，只读所连 net 的电平，不驱动任何东西，电路层无视觉行为。
# 名称是实例属性：随存档序列化（save_state / load_state），与元件定义无关。
var io_name:String = "move"

#外部输出接口使用专用组件（汇聚输入语义，不进 LED 分组）
func getCircuitCompoent() -> SWBuildCompoentCircuit:
	if _circuitCompoent == null:
		_circuitCompoent = getCompoent(SwDefine.BuildCompoentType.CIRCUIT_EXT_OUTPUT) as SWBuildCompoentCircuit
		_circuitCompoent.setBuildRef(self)
	return _circuitCompoent

func rotOnce() -> void:
	pass

# 当前读到的电平（0/1）：边界层每拍读取（.swcir 导出 / 机器人 move、rotation）
func outputLevel() -> int:
	var comp := getCircuitCompoent()
	if comp != null and comp.has_method("readLevel"):
		return int(comp.readLevel())
	return 0

func save_state() -> Dictionary:
	return {"io_name": io_name}

func load_state(state: Dictionary) -> void:
	var n:String = str(state.get("io_name", ""))
	if n != "":
		io_name = n

func _sub_init() -> void:
	var renderable = getCompoent(SwDefine.BuildCompoentType.RENDER_ABLE) as SWBuildCompoentRenderable
	renderable.buildHasAtlas = true
	renderable.buildHasBase = false
	# 默认名称取定义资源配置，缺省按输出接口给 move
	var def_name:String = buildDefine.default_io_name if buildDefine != null else ""
	io_name = def_name if def_name != "" else "move"
