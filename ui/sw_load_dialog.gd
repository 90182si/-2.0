class_name SWLoadDialog extends Window

signal load_confirmed(name: String)
signal load_canceled()

@onready var _save_list: ItemList = $VBoxContainer/HSplitContainer/LeftPanel/SaveList
@onready var _thumbnail: TextureRect = $VBoxContainer/HSplitContainer/RightPanel/Thumbnail
@onready var _thumb_label: Label = $VBoxContainer/HSplitContainer/RightPanel/ThumbnailLabel
@onready var _delete_btn: Button = $VBoxContainer/BtnHBox/DeleteBtn
@onready var _confirm_btn: Button = $VBoxContainer/BtnHBox/ConfirmBtn
@onready var _cancel_btn: Button = $VBoxContainer/BtnHBox/CancelBtn

var _selected_name: String = ""

func _ready() -> void:
	title = "加载"
	unresizable = true
	size = Vector2i(520, 380)
	_confirm_btn.disabled = true
	_delete_btn.disabled = true
	close_requested.connect(_on_cancel_pressed)
	_save_list.item_selected.connect(_on_item_selected)
	_save_list.item_activated.connect(_on_item_activated)
	_delete_btn.pressed.connect(_on_delete_pressed)
	_confirm_btn.pressed.connect(_on_confirm_pressed)
	_cancel_btn.pressed.connect(_on_cancel_pressed)
	call_deferred("_deferred_refresh")

func _deferred_refresh() -> void:
	_refresh_list()
	print("[LoadDialog] SaveList 尺寸: ", _save_list.size, " 项目数: ", _save_list.item_count)
	print("[LoadDialog] HSplitContainer 尺寸: ", $VBoxContainer/HSplitContainer.size)
	print("[LoadDialog] LeftPanel 尺寸: ", $VBoxContainer/HSplitContainer/LeftPanel.size)

func _refresh_list() -> void:
	_save_list.clear()
	var saves = SWSaveManager.list_saves()
	print("[LoadDialog] 刷新列表, 找到 ", saves.size(), " 个存档")
	for save_name in saves:
		_save_list.add_item(save_name)
		print("[LoadDialog] 添加存档项: ", save_name)

func _on_item_selected(index: int) -> void:
	if index < 0 or index >= _save_list.get_item_count():
		return
	_selected_name = _save_list.get_item_text(index)
	_confirm_btn.disabled = false
	_delete_btn.disabled = false
	_update_thumbnail(_selected_name)

func _on_item_activated(index: int) -> void:
	if index < 0:
		return
	_selected_name = _save_list.get_item_text(index)
	_confirm_btn.disabled = false
	_delete_btn.disabled = false
	_update_thumbnail(_selected_name)
	_on_confirm_pressed()

func _update_thumbnail(name: String) -> void:
	var tex = SWSaveManager.get_thumbnail_texture(name)
	if tex:
		_thumbnail.texture = tex
		_thumb_label.text = name
	else:
		_thumbnail.texture = null
		_thumb_label.text = name + " (无缩略图)"

func _on_confirm_pressed() -> void:
	if _selected_name.is_empty():
		return
	var dlg = AcceptDialog.new()
	dlg.title = "确认加载"
	dlg.dialog_text = "加载存档将清空当前地图上的所有建筑物，是否继续？"
	dlg.confirmed.connect(func ():
		load_confirmed.emit(_selected_name)
		queue_free()
	)
	dlg.canceled.connect(func ():
		dlg.queue_free()
	)
	add_child(dlg)
	dlg.popup_centered()

func _on_cancel_pressed() -> void:
	load_canceled.emit()
	queue_free()

func _on_delete_pressed() -> void:
	if _selected_name.is_empty():
		return
	var dlg = AcceptDialog.new()
	dlg.title = "确认删除"
	dlg.dialog_text = "确定要删除存档 \"%s\" 吗？此操作不可撤销。" % _selected_name
	dlg.confirmed.connect(func ():
		var ok = SWSaveManager.delete_save(_selected_name)
		if ok:
			print("[LoadDialog] 删除存档成功: ", _selected_name)
		else:
			push_warning("[LoadDialog] 删除存档失败: " + _selected_name)
		_selected_name = ""
		_confirm_btn.disabled = true
		_delete_btn.disabled = true
		_thumbnail.texture = null
		_thumb_label.text = ""
		_refresh_list()
	)
	dlg.canceled.connect(func ():
		dlg.queue_free()
	)
	add_child(dlg)
	dlg.popup_centered()
