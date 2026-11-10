class_name SWBuildExtOutput extends SWBuildItemDefine

# 外部输出接口建筑（move / rotation 等）
# 四向输入口，只读所连 net 的电平，不驱动任何东西，电路层无视觉行为。
# 名称是实例属性：随存档序列化（save_state / load_state），与元件定义无关。
var io_name:String = "move"
# 上一条写进自采样槽的电平（-1 = 还没写过）：本元件没任何视觉行为，
# 靠「自采样槽」把读数显示在主体上，玩家才看得出这个口当前输出几
var _display_level:int = -1

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

# 当前读到几就显示几：把电平写进自采样槽（主体按调色板变色）。
# 电路场景里没有机器人来读这个口，不自己显示的话玩家完全看不出它现在是不是 1
func refresh_display_level() -> bool:
	var lv:int = outputLevel()
	if lv == _display_level:
		return false
	_display_level = lv
	getRenderableCompoent().setSelfTintLevel(lv == 1)
	return true

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
	# 主体按自采样槽上色：本元件是纯读取点，不这么做在画面上永远是个死图标
	renderable.self_tint = true
	renderable.markRenderPartsDirty()
	# 默认名称取定义资源配置，缺省按输出接口给 move
	var def_name:String = buildDefine.default_io_name if buildDefine != null else ""
	io_name = def_name if def_name != "" else "move"
