class_name SWSaveDialog extends Window

signal save_confirmed(name: String)
signal save_canceled()

@onready var _name_edit: LineEdit = $VBoxContainer/FormGrid/NameEdit
@onready var _status_label: Label = $VBoxContainer/FormGrid/StatusLabel
@onready var _confirm_btn: Button = $VBoxContainer/BtnHBox/ConfirmBtn
@onready var _cancel_btn: Button = $VBoxContainer/BtnHBox/CancelBtn

var _allow_overwrite: bool = false

func _ready() -> void:
	title = "保存"
	unresizable = true
	size = Vector2i(360, 220)
	_confirm_btn.disabled = true
	close_requested.connect(_on_cancel_pressed)
	_name_edit.text_changed.connect(_on_name_changed)
	_confirm_btn.pressed.connect(_on_confirm_pressed)
	_cancel_btn.pressed.connect(_on_cancel_pressed)
	_name_edit.grab_focus()

func _on_name_changed(new_text: String) -> void:
	_allow_overwrite = false
	var name = new_text.strip_edges()
	if name.is_empty():
		_status_label.text = ""
		_status_label.modulate = Color.WHITE
		_confirm_btn.disabled = true
		return
	if SWSaveManager.save_exists(name):
		_status_label.text = "已存在同名存档"
		_status_label.modulate = Color(1.0, 0.6, 0.2)
		_confirm_btn.disabled = false
		_allow_overwrite = true
	else:
		_status_label.text = "可以保存"
		_status_label.modulate = Color(0.5, 0.9, 0.5)
		_confirm_btn.disabled = false

func _on_confirm_pressed() -> void:
	var name = _name_edit.text.strip_edges()
	if name.is_empty():
		return
	if _allow_overwrite:
		var dlg = AcceptDialog.new()
		dlg.title = "覆盖确认"
		dlg.dialog_text = "存档 \"%s\" 已存在，是否覆盖？" % name
		dlg.confirmed.connect(func ():
			save_confirmed.emit(name)
			queue_free()
			get_tree().paused = false
		)
		dlg.canceled.connect(func ():
			dlg.queue_free()
		)
		add_child(dlg)
		dlg.popup_centered()
	else:
		save_confirmed.emit(name)
		queue_free()
		get_tree().paused = false

func _on_cancel_pressed() -> void:
	save_canceled.emit()
	queue_free()
	get_tree().paused = false
