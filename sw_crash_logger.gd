extends Node

## 崩溃与错误日志系统：将引擎/脚本的 print、error 写入文件，并在启动时检测上次是否崩溃，便于排查原因。
## 依赖 Godot 内置文件日志（debug/file_logging）记录崩溃堆栈；本脚本额外复制到 user://crash_logs/ 并支持查询。

const LOG_SUBDIR := "crash_logs"
const LAST_CRASH_FILE := "last_crash.txt"
const SESSION_LOG_PREFIX := "game_"
const CRASH_MARKER := "Program crashed with signal"
const GDSCRIPT_BACKTRACE_MARKER := "GDScript backtrace"
const END_BACKTRACE_MARKER := "END OF"

var last_crash_text: String = ""
var log_directory: String = ""
var _log_mutex: Mutex
var _session_log_path: String = ""
var _log_dir_ready: bool = false

# 自定义 Logger（Godot 4.5+），用于捕获 print/error 并写入文件
var _file_logger: _CrashFileLogger


func _init() -> void:
	_log_mutex = Mutex.new()
	log_directory = _ensure_log_dir()
	if log_directory.is_empty():
		return
	var date := Time.get_datetime_dict_from_system()
	var suffix := "%04d%02d%02d_%02d%02d%02d" % [date.year, date.month, date.day, date.hour, date.minute, date.second]
	_session_log_path = log_directory.path_join(SESSION_LOG_PREFIX + suffix + ".log")
	_log_dir_ready = true
	# Godot 4.5+ 支持自定义 Logger
	if ClassDB.class_exists("Logger"):
		_file_logger = _CrashFileLogger.new(_log_mutex, _session_log_path)
		OS.add_logger(_file_logger)


func _ready() -> void:
	call_deferred("_check_last_session_crash")


func _ensure_log_dir() -> String:
	var base: String = OS.get_user_data_dir()
	var dir_path: String = base.path_join(LOG_SUBDIR)
	var da := DirAccess.open(base)
	if da == null:
		return ""
	if not da.dir_exists(LOG_SUBDIR):
		var err: Error = da.make_dir(LOG_SUBDIR)
		if err != OK:
			return ""
	return dir_path


func _safe_write_line(path: String, line: String) -> void:
	if path.is_empty() or line.is_empty():
		return
	_log_mutex.lock()
	var f := FileAccess.open(path, FileAccess.WRITE_READ)
	if f != null:
		f.seek_end()
		f.store_line(line)
		f.close()
	_log_mutex.unlock()


func _check_last_session_crash() -> void:
	last_crash_text = ""
	var engine_log_path: String = ""
	if ProjectSettings.get_setting("debug/file_logging/enable_file_logging"):
		engine_log_path = ProjectSettings.get_setting("debug/file_logging/log_path")
	if engine_log_path.is_empty():
		engine_log_path = "user://logs/godot.log"
	engine_log_path = engine_log_path.replace("user://", OS.get_user_data_dir() + "/")
	var log_dir: String = engine_log_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(log_dir):
		return
	var da := DirAccess.open(log_dir)
	if da == null:
		return
	da.list_dir_begin()
	var files: Array[String] = []
	var fname: String = da.get_next()
	while fname != "":
		if not da.current_is_dir() and fname.ends_with(".log"):
			files.append(log_dir.path_join(fname))
		fname = da.get_next()
	da.list_dir_end()
	# 按修改时间倒序，优先读最新的
	files.sort_custom(func(a: String, b: String) -> bool: return FileAccess.get_modified_time(a) > FileAccess.get_modified_time(b))
	for path in files:
		var content: String = _read_file_as_text(path)
		var idx: int = content.find(CRASH_MARKER)
		if idx != -1:
			var end_idx: int = content.find("-- END OF C++ BACKTRACE --", idx)
			if end_idx != -1:
				end_idx = content.find("\n", end_idx) + 1
			else:
				end_idx = content.length()
			var gds_start: int = content.find(GDSCRIPT_BACKTRACE_MARKER, idx)
			if gds_start != -1:
				var gds_end: int = content.find("-- " + END_BACKTRACE_MARKER, gds_start)
				if gds_end != -1:
					end_idx = gds_end + 1
			last_crash_text = content.substr(idx, end_idx - idx).strip_edges()
			# 写入 last_crash.txt 便于查看
			if _log_dir_ready:
				var last_path: String = log_directory.path_join(LAST_CRASH_FILE)
				_safe_write_line(last_path, "=== 上次运行崩溃信息 ===\n" + last_crash_text)
			break


func _read_file_as_text(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var s := f.get_as_text()
	f.close()
	return s


## 返回上次会话的崩溃堆栈文本（若有）
func get_last_crash_text() -> String:
	return last_crash_text


## 是否有上次崩溃记录
func has_last_crash() -> bool:
	return last_crash_text.length() > 0


## 返回当前日志目录（user://crash_logs 的绝对路径）
func get_log_directory_absolute() -> String:
	return log_directory


## 在资源管理器中打开日志目录（仅桌面平台）
func open_log_directory() -> void:
	if log_directory.is_empty():
		return
	OS.shell_open("file://" + log_directory)


## 手动写入一行到当前会话日志（可在线程中调用）
func write_line(message: String, is_error: bool) -> void:
	if not _log_dir_ready or _session_log_path.is_empty():
		return
	var prefix: String = "[ERR] " if is_error else "[INF] "
	var time_str: String = Time.get_time_string_from_system()
	var line: String = "%s %s %s" % [time_str, prefix, message]
	_safe_write_line(_session_log_path, line)


# --- 内部 Logger 实现（Godot 4.5+）---
class _CrashFileLogger extends Logger:
	var _mutex: Mutex
	var _path: String

	func _init(m: Mutex, p: String) -> void:
		_mutex = m
		_path = p

	func _log_message(message: String, error: bool) -> void:
		if _path.is_empty():
			return
		var prefix: String = "[ERR] " if error else "[INF] "
		var line: String = "%s %s%s" % [Time.get_time_string_from_system(), prefix, message]
		_mutex.lock()
		var f := FileAccess.open(_path, FileAccess.WRITE_READ)
		if f != null:
			f.seek_end()
			f.store_line(line)
			f.close()
		_mutex.unlock()

	func _log_error(_function: String, file: String, line: int, _code: String, rationale: String, _editor_notify: bool, _error_type: int, script_backtraces: Array) -> void:
		if _path.is_empty():
			return
		var parts: PackedStringArray = PackedStringArray()
		parts.append("[ERROR] %s:%d - %s" % [file, line, rationale])
		for i in range(script_backtraces.size()):
			var sb: Variant = script_backtraces[i]
			if sb != null and sb.has_method("format"):
				parts.append("  Backtrace:\n" + str(sb))
			elif sb is Dictionary:
				parts.append("  [%d] %s (%s:%d)" % [i, sb.get("function", ""), sb.get("file", ""), sb.get("line", 0)])
		var line_str: String = Time.get_time_string_from_system() + " " + "\n".join(parts)
		_mutex.lock()
		var f := FileAccess.open(_path, FileAccess.WRITE_READ)
		if f != null:
			f.seek_end()
			f.store_line(line_str)
			f.close()
		_mutex.unlock()
