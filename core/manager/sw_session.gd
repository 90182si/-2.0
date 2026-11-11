class_name SWSession extends RefCounted

# ==========================================================================
# 跨场景会话状态
#
# change_scene_to_file 会把整棵树换掉：SWLayerManager、实体层系统、HUD 全是新实例，
# 但「当前在哪个存档」「从机器人面板点了哪条电路要进去改」这类信息必须跨场景活着。
#
# 用静态变量而不是 autoload：
#   1. 纯逻辑用例只想 preload 一个脚本就能读写，不用起节点
#   2. autoload 要经 project.godot 注册，多一层耦合
# 静态变量只活一个进程：切场景够用，重启游戏就清空（正好是「会话」语义）。
# ==========================================================================

#当前存档名：读档成功 / 保存成功后写入，保存对话框回填它
static var current_save_name: String = ""
#待加载存档：机器人面板点「修改电路」时写入，电路场景起来后取走并清空
static var pending_load_save: String = ""
#时序图监测信号（HUD 时序面板里玩家自选的接口名）：跨场景保留，空 = 自动模式
#（自动 = 把绑定电路里 move/rotation 之外的输出名全画成额外轨）
static var timing_signals: Array = []
#电路结构被改过的存档名：改完不管有没有保存，退出电路场景时都要把当前结构导出成
#同名 .swcir，机器人场景回来才能按最新电路重绑（玩家不用先点保存）
static var edited_save: String = ""
#当前是不是在「机器人 + 电路」并排调试的分屏壳里。
#分屏时两个子场景同时在树里，渲染纹理单例与区块对象池必须只由壳持有一次，
#子场景退出时也不能把共享的对象池清掉（否则先退出的那边会把另一边的池清空）
static var split_mode: bool = false
#场景树内部搬迁中：HUD「修改电路」把正在跑的机器人场景从根视口搬进分屏壳的左视口。
#搬迁会触发一次 _exit_tree，但节点并没有销毁、也不会再走 _ready，
#所以图层管理器/图层/场景根在那次退出里都不能做「真退出」的清理
static var relocating_scene: bool = false

#取走待加载存档（取完即清，避免下次切场景又读一遍上次的意图）
static func take_pending_load() -> String:
	var s: String = pending_load_save
	pending_load_save = ""
	return s

#记「这个存档的电路结构改过」。save_name 为空时退回 current_save_name
static func mark_circuit_edited(save_name: String = "") -> void:
	var n: String = save_name if not save_name.is_empty() else current_save_name
	if not n.is_empty():
		edited_save = n

#取走「结构改过」标记（取完即清，避免下次退出又重导一遍）
static func take_edited_save() -> String:
	var s: String = edited_save
	edited_save = ""
	return s

#清空会话（测试 after_each 用；也是「新游戏」的语义）
static func reset() -> void:
	current_save_name = ""
	pending_load_save = ""
	timing_signals = []
	edited_save = ""
	split_mode = false
	relocating_scene = false
