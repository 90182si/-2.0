class_name SWSaveManager extends RefCounted

const SAVE_VERSION: int = 1
const SAVE_DIR_NAME: String = "saves"
const THUMBNAIL_SIZE: Vector2i = Vector2i(256, 256)

static func _get_save_dir() -> String:
	return "user://saves"

static func _ensure_dir() -> void:
	if not DirAccess.dir_exists_absolute(_get_save_dir()):
		DirAccess.make_dir_recursive_absolute(_get_save_dir())

static func _save_file_path(name: String) -> String:
	return _get_save_dir() + "/" + name + ".json"

static func _thumb_file_path(name: String) -> String:
	return _get_save_dir() + "/" + name + ".png"

static func save_exists(name: String) -> bool:
	return FileAccess.file_exists(_save_file_path(name))

static func list_saves() -> Array[String]:
	_ensure_dir()
	var dir_path: String = _get_save_dir()
	print("[SWSaveManager] list_saves 目录: ", dir_path)
	var dir: DirAccess = DirAccess.open(dir_path)
	var names: Array[String] = []
	if dir == null:
		push_error("[SWSaveManager] 无法打开存档目录: " + dir_path)
		return names
	var err = dir.list_dir_begin()
	if err != OK:
		push_error("[SWSaveManager] list_dir_begin 失败: " + str(err))
		dir.list_dir_end()
		return names
	var file_name: String = dir.get_next()
	while file_name != "":
		print("[SWSaveManager] 发现文件: ", file_name)
		if file_name.ends_with(".json"):
			var dot_pos: int = file_name.rfind(".json")
			var save_name: String = file_name.substr(0, dot_pos)
			names.append(save_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	names.sort()
	print("[SWSaveManager] 找到 ", names.size(), " 个存档: ", str(names))
	return names

static func delete_save(name: String) -> bool:
	var dir: DirAccess = DirAccess.open(_get_save_dir())
	if dir == null:
		push_error("[SWSaveManager] 无法打开存档目录进行删除")
		return false
	var save_file: String = name + ".json"
	var thumb_file: String = name + ".png"
	var ok1: bool = dir.remove(save_file)
	var ok2: bool = dir.remove(thumb_file)
	return ok1 == true and ok2 == true

static func save_builds(name: String, builds: Array, viewport: Viewport, karnaugh_map_data: Dictionary = {}) -> bool:
	_ensure_dir()
	var save_path: String = _save_file_path(name)
	print("[SWSaveManager] 保存路径: ", save_path)
	print("[SWSaveManager] 建筑物数量: ", builds.size())
	var data: Dictionary = {}
	data["version"] = SAVE_VERSION
	data["save_name"] = name
	data["timestamp"] = Time.get_unix_time_from_system()
	var builds_arr: Array = []
	for build in builds:
		if not build:
			continue
		var b: Dictionary = {}
		b["id"] = build.id
		b["pos"] = {"x": build.buildAxisPos.x, "y": build.buildAxisPos.y}
		b["def"] = build.buildDefine.buildName if build.buildDefine else ""
		b["rot"] = build.rotation
		b["comp_type"] = build.comp_type
		b["circuit_on"] = build.circuit_on
		b["signal_state"] = build.signal_state
		b["tunnel_pair_id"] = build.tunnel_pair_id
		b["in_loop"] = build.in_loop
		builds_arr.append(b)
	data["builds"] = builds_arr
	if not karnaugh_map_data.is_empty():
		data["karnaugh_map"] = karnaugh_map_data
	var json_str: String = JSON.stringify(data, "\t")
	print("[SWSaveManager] JSON 长度: ", json_str.length())
	var file = FileAccess.open(save_path, FileAccess.WRITE)
	if file == null:
		push_error("无法写入存档文件: " + name + " 路径: " + save_path + " 错误: " + str(FileAccess.get_open_error()))
		return false
	file.store_string(json_str)
	file.close()
	print("[SWSaveManager] 文件写入完成, 验证存在: ", FileAccess.file_exists(save_path))
	_capture_thumbnail(name, viewport)
	return true

static func load_builds(name: String) -> Dictionary:
	var file = FileAccess.open(_save_file_path(name), FileAccess.READ)
	if file == null:
		return {}
	var json_str: String = file.get_as_text()
	file.close()
	var json = JSON.new()
	var err = json.parse(json_str)
	if err != OK:
		push_error("存档 JSON 解析失败: " + name)
		return {}
	var data = json.data
	if not data is Dictionary:
		return {}
	var version: int = data.get("version", 0)
	if version != SAVE_VERSION:
		push_error("存档版本不兼容: v%d (当前v%d)".format([version, SAVE_VERSION]))
		return {}
	return data

static func get_thumbnail_texture(name: String) -> Texture2D:
	var path: String = _thumb_file_path(name)
	if not FileAccess.file_exists(path):
		return null
	var tex: ImageTexture = ImageTexture.create_from_image(Image.load_from_file(path))
	return tex

static func _capture_thumbnail(name: String, viewport: Viewport) -> void:
	if viewport == null:
		return
	var img = viewport.get_texture().get_image()
	if img == null:
		return
	var tex_img: Image = img.duplicate()
	tex_img.resize(THUMBNAIL_SIZE.x, THUMBNAIL_SIZE.y, Image.INTERPOLATE_BILINEAR)
	var file = FileAccess.open(_thumb_file_path(name), FileAccess.WRITE)
	if file == null:
		return
	var png_buf: PackedByteArray = tex_img.save_png_to_buffer()
	if png_buf:
		file.store_buffer(png_buf)
	file.close()
