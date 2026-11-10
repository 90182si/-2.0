class_name SWBuildExtInput extends SWBuildItemDefine

# 外部输入接口建筑（clk 等）
# 电平由边界层写入（机器人场景每拍 setLevel），电路层无视觉行为。
# 名称是实例属性：随存档序列化（save_state / load_state），与元件定义无关。
var level:int = 0
var io_name:String = "clk"
# 上一条写进自采样槽的电平（-1 = 还没写过）：接口元件主体要跟着电平变色，
# 但每拍无脑写一次会把整张信号纹理标脏，所以只在变了的时候写
var _display_level:int = -1

#外部输入接口使用专用组件承载电路逻辑（信号源语义，电平取实例字段）
func getCircuitCompoent() -> SWBuildCompoentCircuit:
	if _circuitCompoent == null:
		_circuitCompoent = getCompoent(SwDefine.BuildCompoentType.CIRCUIT_EXT_INPUT) as SWBuildCompoentCircuit
		_circuitCompoent.setBuildRef(self)
	return _circuitCompoent

func rotOnce() -> void:
	pass

# 写电平（边界层调用）：只改字段，不碰渲染
func setLevel(value:int) -> void:
	level = 1 if value != 0 else 0

# 元件自身显不显示电平：接口元件没有 net 可采样的主体，靠「自采样槽」自己变色。
# 电路场景里没有机器人来喂电平（build 层每拍自己喂方波），玩家要能看见这个口在输入什么
func refresh_display_level() -> bool:
	if level == _display_level:
		return false
	_display_level = level
	getRenderableCompoent().setSelfTintLevel(level == 1)
	return true

func save_state() -> Dictionary:
	return {"io_name": io_name, "level": level}

func load_state(state: Dictionary) -> void:
	var n:String = str(state.get("io_name", ""))
	if n != "":
		io_name = n
	setLevel(int(state.get("level", level)))

func _sub_init() -> void:
	var renderable = getCompoent(SwDefine.BuildCompoentType.RENDER_ABLE) as SWBuildCompoentRenderable
	renderable.buildHasAtlas = true
	renderable.buildHasBase = false
	# 主体按自采样槽上色（高=亮绿/低=暗绿）：接口元件在电路场景里要靠自己把电平显示出来
	renderable.self_tint = true
	renderable.markRenderPartsDirty()
	# 默认名称取定义资源配置，缺省按输入接口给 clk
	var def_name:String = buildDefine.default_io_name if buildDefine != null else ""
	io_name = def_name if def_name != "" else "clk"
