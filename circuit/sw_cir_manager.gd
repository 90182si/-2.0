class_name SWCirManager extends RefCounted

# ==========================================================================
# .swcir（纯电路文件）的导出 / 列举 / 加载。
#
# 一个 .swcir 与一个存档同名（user://saves/<存档名>.swcir），内容是该存档里
# **含接口元件的电路分组**：
#   电路分组 → SWNetlist（纯整数表）→ JSON
# 加载侧反向：JSON → SWNetlist.from_dict → SWCircuitBundle（可脱离实体跑拍）。
#
# 只导出「含 EXTERNAL_INPUT / EXTERNAL_OUTPUT 的电路」：普通存档不生成文件，
# 已有同名 .swcir 会被删掉（否则会留下上一次保存的旧电路）。
#
# 机器人可用性合同（与 SPEC-08 §3.9 一致）：
#   必须**恰好 1 条电路**（多电路 → 「电路不可用」），且含输入 clk、输出 move 与 rotation。
# ==========================================================================

const BUNDLE := preload("res://circuit/sim/sw_circuit_bundle.gd")

const DIR_PATH := "user://saves"
const FILE_EXT := ".swcir"
const VERSION := 1

# 机器人能驱动的最小接口合同
const REQUIRED_INPUT := "clk"
const REQUIRED_OUTPUTS: Array[String] = ["move", "rotation"]


# ===== 路径 =====
static func file_path(name: String) -> String:
	return DIR_PATH + "/" + name + FILE_EXT


static func _ensure_dir() -> void:
	if not DirAccess.dir_exists_absolute(DIR_PATH):
		DirAccess.make_dir_recursive_absolute(DIR_PATH)


# ===== 导出 =====
# 把存档里所有含接口元件的电路写成同名 .swcir。
# 返回写入的文件路径；空串表示「没有可导出的电路」（此时顺带清掉旧文件）。
static func export_all(save_name: String, builds: Array) -> String:
	var path: String = file_path(save_name)
	var records: Array = []
	var index: int = 0
	for group: Dictionary in _group_by_circuit(builds):
		var rec: Dictionary = _export_circuit(group["builds"], index)
		if rec.is_empty():
			continue
		records.append(rec)
		index += 1
	if records.is_empty():
		# 这里可能是「曾经有接口电路、现在删掉了」：旧文件必须一起消失
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		return ""
	_ensure_dir()
	var data: Dictionary = {
		"version": VERSION,
		"source_save": save_name,
		"circuits": records,
	}
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("[SWCirManager] 无法写入电路文件: %s (%s)" % [path, str(FileAccess.get_open_error())])
		return ""
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	return path


# 一条电路分组 → 文件里的一条记录（没有接口元件返回空字典）
static func _export_circuit(members: Array, index: int) -> Dictionary:
	var ex := SWNetlistExport.new()
	var nl: SWNetlist = ex.export_netlist(members)
	var ins: Array = []
	var outs: Array = []
	for b in members:
		if b == null or b.buildDefine == null:
			continue
		var t: int = b.buildDefine.circuit_component_type
		if t != SwDefine.CircuitComponentType.EXTERNAL_INPUT \
				and t != SwDefine.CircuitComponentType.EXTERNAL_OUTPUT:
			continue
		# dev 下标 = 网表元件顺序（导出器跳过电线/无电路组件的建筑）
		var dev: int = ex.dev_builds.find(b)
		if dev < 0:
			continue
		var nets: PackedInt32Array = nl.nets_of(dev)
		var rec: Dictionary = {
			"name": str(b.get("io_name")),
			"dev": dev,
			"nets": Array(nets),
			"net_id": int(nets[0]) if nets.size() > 0 else -1,
		}
		if t == SwDefine.CircuitComponentType.EXTERNAL_INPUT:
			ins.append(rec)
		else:
			outs.append(rec)
	if ins.is_empty() and outs.is_empty():
		return {}
	#源元件的初始电平：机器人侧拿不到世界，必须随文件存。
	#少了这一段，加载后所有内部开关/按钮/时钟都是 0，
	#「拿开关当常量 1」的电路（带使能的计数器等）会永远输出 0。
	var sources: Array = []
	for dev in nl.src_devs:
		var sb = ex.dev_builds[dev] if dev < ex.dev_builds.size() else null
		sources.append({"dev": dev, "level": _source_level(sb)})
	#名称排序：同一个存档导出两次要得到逐字节相同的文件（否则版本管理里全是噪声）
	ins.sort_custom(func(a, b) -> bool: return str(a["name"]) < str(b["name"]))
	outs.sort_custom(func(a, b) -> bool: return str(a["name"]) < str(b["name"]))
	return {"index": index, "inputs": ins, "outputs": outs, "sources": sources,
			"netlist": nl.to_dict()}


#源元件当前电平（导出到 .swcir 的 sources 段）
#按定义类型分派而不是按类名：headless 下类名全局缓存可能未刷新
static func _source_level(b) -> int:
	if b == null or b.buildDefine == null:
		return 0
	match b.buildDefine.circuit_component_type:
		SwDefine.CircuitComponentType.EXTERNAL_INPUT:
			return 1 if int(b.get("level")) != 0 else 0
		SwDefine.CircuitComponentType.CLOCK:
			return 1 if int(b.get("curSig")) == int(SwDefine.CircuitSignal.HIGH) else 0
		SwDefine.CircuitComponentType.BUTTON, SwDefine.CircuitComponentType.SWITCH:
			return 1 if bool(b.get("pressed")) else 0
	return 0


# builds → 按所属电路分组（顺序按 circuitID，保证导出确定性）
static func _group_by_circuit(builds: Array) -> Array:
	var by: Dictionary = {}
	for b in builds:
		if b == null:
			continue
		var cir = b.circuit
		if cir == null:
			continue
		if not by.has(cir):
			by[cir] = []
		(by[cir] as Array).append(b)
	var cirs: Array = by.keys()
	cirs.sort_custom(func(a, b) -> bool: return a.circuitID < b.circuitID)
	var out: Array = []
	for c in cirs:
		out.append({"circuit": c, "builds": by[c]})
	return out


# ===== 列举 / 读取 =====
static func list_files() -> Array[String]:
	_ensure_dir()
	var names: Array[String] = []
	var dir: DirAccess = DirAccess.open(DIR_PATH)
	if dir == null:
		return names
	dir.list_dir_begin()
	var fn: String = dir.get_next()
	while fn != "":
		if not dir.current_is_dir() and fn.ends_with(FILE_EXT):
			names.append(fn.substr(0, fn.length() - FILE_EXT.length()))
		fn = dir.get_next()
	dir.list_dir_end()
	names.sort()
	return names


static func file_exists(name: String) -> bool:
	return FileAccess.file_exists(file_path(name))


static func load_file(name: String) -> Dictionary:
	var path: String = file_path(name)
	if not FileAccess.file_exists(path):
		return {}
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text: String = f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(text) != OK:
		push_error("[SWCirManager] 电路文件解析失败: " + path)
		return {}
	var data = json.data
	if not data is Dictionary:
		return {}
	if int(data.get("version", 0)) != VERSION:
		push_error("[SWCirManager] 电路文件版本不兼容: %s (v%s)" % [path, str(data.get("version", 0))])
		return {}
	return data


# 面板用摘要：能不能加载、为什么不能、接口清单
static func summarize(name: String) -> Dictionary:
	var info: Dictionary = {
		"name": name,
		"exists": file_exists(name),
		"circuit_count": 0,
		"inputs": [],
		"outputs": [],
		"usable": false,
		"reason": "",
	}
	var data: Dictionary = load_file(name)
	if data.is_empty():
		info["reason"] = "文件不存在或解析失败"
		return info
	var circuits: Array = data.get("circuits", [])
	info["circuit_count"] = circuits.size()
	if circuits.size() != 1:
		info["reason"] = "电路不可用（含 %d 条电路）" % circuits.size()
		return info
	var c: Dictionary = circuits[0]
	var ins: Array = _names_of(c.get("inputs", []))
	var outs: Array = _names_of(c.get("outputs", []))
	info["inputs"] = ins
	info["outputs"] = outs
	var missing: Array[String] = []
	if not ins.has(REQUIRED_INPUT):
		missing.append(REQUIRED_INPUT)
	for o in REQUIRED_OUTPUTS:
		if not outs.has(o):
			missing.append(o)
	if not missing.is_empty():
		info["reason"] = "缺少接口：" + ", ".join(missing)
		return info
	info["usable"] = true
	return info


# ===== 加载 =====
# 一条电路记录 → 可运行的 SWCircuitBundle（不做可用性校验，面板层自己判断）。
# 注意：返回类型故意不写 SWCircuitBundle —— 新建脚本的类名不在 headless 的全局类缓存里，
# 写了会直接解析失败（同项目里其它 new 类一律走 preload 的约定）
static func build_bundle(circuit: Dictionary):
	var nd: Dictionary = circuit.get("netlist", {})
	if nd.is_empty():
		return null
	var nl: SWNetlist = SWNetlist.from_dict(nd)
	var bundle = BUNDLE.new()
	bundle.setup_from_netlist(nl, circuit.get("inputs", []), circuit.get("outputs", []),
			circuit.get("sources", []))
	#老文件没有 sources 段：内部开关/按钮电平无从得知，只能全部按 0。
	#依赖「开关当常量 1」的电路会因此整片恒 0，提示重新保存一次存档
	if not circuit.has("sources") and not nl.src_devs.is_empty():
		push_warning("[SWCirManager] 第 %s 条电路是旧版文件（无源电平），内部开关/按钮按 0 处理；重新保存一次存档即可修复" % str(circuit.get("index", 0)))
	return bundle


# 按文件加载：不可用的文件返回 null（调用方用 summarize 拿原因）
static func load_bundle(name: String):
	var info: Dictionary = summarize(name)
	if not bool(info.get("usable", false)):
		return null
	var data: Dictionary = load_file(name)
	var circuits: Array = data.get("circuits", [])
	if circuits.size() != 1:
		return null
	return build_bundle(circuits[0])


static func delete_file(name: String) -> bool:
	var path: String = file_path(name)
	if not FileAccess.file_exists(path):
		return true
	return DirAccess.remove_absolute(path) == OK


static func _names_of(list) -> Array:
	var out: Array = []
	for e in list:
		if e is Dictionary:
			out.append(str(e.get("name", "")))
	return out
