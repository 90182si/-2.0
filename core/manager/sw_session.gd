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

#取走待加载存档（取完即清，避免下次切场景又读一遍上次的意图）
static func take_pending_load() -> String:
	var s: String = pending_load_save
	pending_load_save = ""
	return s

#清空会话（测试 after_each 用；也是「新游戏」的语义）
static func reset() -> void:
	current_save_name = ""
	pending_load_save = ""
