class_name SwCrashLogViewer
extends PanelContainer

## 崩溃日志查看弹窗：显示上次运行崩溃堆栈，并提供打开日志目录入口。

@onready var content: TextEdit = $Margin/VBox/Scroll/Content
@onready var open_dir_btn: Button = $Margin/VBox/Buttons/OpenDirBtn
@onready var close_btn: Button = $Margin/VBox/Buttons/CloseBtn
@onready var no_crash_label: Label = $Margin/VBox/NoCrashLabel

func _ready() -> void:
	open_dir_btn.pressed.connect(_on_open_dir)
	close_btn.pressed.connect(_on_close)
	_refresh_content()


func _refresh_content() -> void:
	if not is_instance_valid(content) or not is_instance_valid(no_crash_label):
		return
	var logger: Node = get_tree().root.get_node_or_null("/root/SwCrashLogger")
	var crash_text: String = ""
	if logger != null and "last_crash_text" in logger:
		crash_text = logger.get_last_crash_text()
	if crash_text.is_empty():
		content.text = ""
		content.visible = false
		no_crash_label.visible = true
		no_crash_label.text = "无上次崩溃记录。\n日志目录：\n%s" % _get_log_dir_placeholder()
	else:
		content.text = crash_text
		content.visible = true
		no_crash_label.visible = false


func _get_log_dir_placeholder() -> String:
	var logger: Node = get_tree().root.get_node_or_null("/root/SwCrashLogger")
	if logger != null and logger.has_method("get_log_directory_absolute"):
		return logger.get_log_directory_absolute()
	return "user://crash_logs"


func _on_open_dir() -> void:
	var logger: Node = get_tree().root.get_node_or_null("/root/SwCrashLogger")
	if logger != null and logger.has_method("open_log_directory"):
		logger.open_log_directory()


func _on_close() -> void:
	hide()


func show_and_refresh() -> void:
	_refresh_content()
	show()
