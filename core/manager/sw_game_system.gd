# 新游戏系统脚手架模板 / Game system singleton scaffold
# 用途：B 类“新玩法系统”的通用单例骨架（成就、任务、经济、天气、事件……皆可套用）。
#
# 接入步骤（autoload 单例）：
#   1) 保存本文件，重命名为具体系统名，如 sw_quest_system.gd，class_name 改成 SWQuestSystem。
#   2) 项目 -> 项目设置 -> Autoload，把本脚本加入（或手动在 project.godot 的 [autoload] 段加一行）：
#        SwQuestSystem="*res://core/manager/sw_quest_system.gd"
#      名字以 Sw 开头、全局唯一；勾选“启用”即等价于路径前的 *。
#   3) 之后任意脚本用 `SwQuestSystem.xxx()` 访问；跨模块解耦优先用下面声明的信号，别直接互相持有引用。
#
# 约定：
#   - 生命周期用 Godot 虚方法（_ready/_process），自定义方法用 snake_case（符合 GDScript 命名规范）。
#   - 需要存盘的进度，走 SwSaveManager 统一读写，别自己开文件。
#   - 全局事件通过本单例的 signal 广播，避免在场景间硬连。
class_name SWGameSystem extends Node

# 允许在编辑器里给这个单例挂配置（可选，用 CustomSignals / 资源都行）
@export var enabled: bool = true

# ---- 事件总线：外部系统监听这些信号，而不是直接调用彼此 ----
signal system_ready
signal state_changed(key: String, value: Variant)

# ---- 内部运行状态（示例：一个键值状态表，按需要换成你自己的数据结构）----
var _state: Dictionary = {}
var _dirty: bool = false  # 有未保存的改动

func _ready() -> void:
	# 单例在 _ready 里做初始化；此时其它 autoload 已就绪，可安全访问 SwDefine / SwCommon 等
	load_from_save()
	system_ready.emit()

func _process(_delta: float) -> void:
	if not enabled:
		return
	# TODO: 放每帧逻辑（计时、进度推进、条件检测……）。若本系统不需要逐帧更新，删掉本方法。
	tick(_delta)

# ================= 公共 API（按需改名/增删）=================

# 读取一个状态值
func get_state(key: String, default: Variant = null) -> Variant:
	return _state.get(key, default)

# 写入一个状态值并广播变更
func set_state(key: String, value: Variant) -> void:
	if _state.get(key, null) == value:
		return
	_state[key] = value
	_dirty = true
	state_changed.emit(key, value)

# 每帧推进（示例：脏标记批量落盘、条件达成检测）
func tick(_delta: float) -> void:
	pass

# ================= 存档接入 =================
# 与 SwSaveManager 协作：把本系统进度并入全局存档。
# 若项目存档结构不同，请对齐 SwSaveManager 的读写字段。

func save_to_data() -> Dictionary:
	# TODO: 返回本系统需要持久化的数据
	return { "state": _state.duplicate(true) }

func load_from_data(data: Dictionary) -> void:
	# TODO: 从传入数据恢复本系统状态
	_state = data.get("state", {}).duplicate(true)
	_dirty = false

# 游戏启动时尝试从存档恢复（具体取法看 SwSaveManager 暴露的接口）
func load_from_save() -> void:
	# 示例占位：真实项目里改成从 SwSaveManager 读取本系统的子字典
	# var data: Dictionary = SwSaveManager.GetSystemData("SWGameSystem")
	# LoadFromData(data)
	pass

# 需要立即落盘时调用（例如切场景 / 退出前）
func flush_save() -> void:
	if not _dirty:
		return
	# SwSaveManager.SetSystemData("SWGameSystem", SaveToData())
	_dirty = false
