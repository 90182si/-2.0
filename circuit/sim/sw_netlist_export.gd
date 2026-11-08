class_name SWNetlistExport extends RefCounted

# ==========================================================================
# 实体 → 纯数据网表的导出器：**整条链路里唯一读实体拓扑的地方**。
#
# 三条职责，互不混杂：
#   1. export_netlist(builds)  ：SWBuildItemDefine 列表 → SWNetlist（纯整数表）
#   2. compile(builds)         ：export + SWGateCompiler.compile_netlist 一步到位
#   3. bind_program(prog)      ：把「下标空间」反接回实体对象表，供表现层回填用
#
# 为什么绑定要单独一步：step 1+2 的目标是「slot 是唯一真值，实体只是表现副本」。
# 编译只需要整数表；而现有回填（net.curSignal / 渲染组件帧槽）还需要对象引用，
# 所以这些引用表打成显式的 bind 阶段，纯逻辑运行时完全不碰它们。
#
# 一致性口径（与老的 SWGateCompiler.compile 逐项对齐，test_netlist_compile.gd 对拍）：
#   - 元件顺序 = builds 顺序（跳过电线 / 无电路组件的建筑，与老代码同判据）
#   - net 顺序 = 按 netId 升序（net 下标即 slot）
#   - 每根 net 的驱动者顺序 = net._driverComps 顺序（AND 的源顺序，影响 CSE 命中性）
# ==========================================================================

# dev 下标 → 源建筑 / 源组件（顺序与 netlist 的 dev 一致；纯逻辑运行时不需要）
var dev_builds: Array = []
var comps: Array = []
var dev_of_comp: Dictionary = {}
# net 下标 → SWNet（顺序与 netlist 的 net_ids 一致）
var net_objects: Array = []
var net_by_id: Dictionary = {}

var netlist: SWNetlist = null


# 纯数据导出：本函数结束后，拓扑已经全部落在 netlist 的整数表里
func export_netlist(builds: Array) -> SWNetlist:
	var nl := SWNetlist.new()
	dev_builds = []
	comps = []
	dev_of_comp = {}
	net_objects = []
	net_by_id = {}
	for b in builds:
		if b == null:
			continue
		if SwCommon.IsWireBuild(b):
			continue
		var comp = b.getCircuitCompoent()
		if comp == null:
			continue
		comp.refreshDirMasks()
		var kind: int = _classify(comp)
		var dev: int = nl.add_device(kind, comp.outDirMask, comp.inDirMask)
		dev_builds.append(b)
		comps.append(comp)
		dev_of_comp[comp] = dev
		for d in 4:
			var net: SWNet = comp.pinNetMap.get(d, null)
			if net == null or net.netId < 0:
				continue
			nl.set_pin(dev, d, net.netId)
			if not net_by_id.has(net.netId):
				net_by_id[net.netId] = net
		if kind == SWNetlist.DEV_REG:
			# 逻辑端口（CLK/D）在参考坐标系，旋转后才是世界方向（与组件 _worldDir 同式）
			var clk_dir: int = comp._worldDir(comp.CLK_REF)
			var d_dir: int = comp._worldDir(comp.D_REF)
			nl.set_reg_pins(dev, nl.pin_net(dev, clk_dir), nl.pin_net(dev, d_dir))
	# net：按 netId 升序 —— 这与老编译器的 net_list.sort_custom(netId) 完全一致
	var ids: Array = net_by_id.keys()
	ids.sort()
	for i in ids.size():
		var net_id: int = int(ids[i])
		var net: SWNet = net_by_id[net_id]
		var ni: int = nl.add_net(net_id)
		net_objects.append(net)
		for dcomp in net._driverComps:
			var dv: int = int(dev_of_comp.get(dcomp, -1))
			if dv >= 0:
				nl.add_driver(ni, dv)
		for lcomp in net._loadComps:
			var lv: int = int(dev_of_comp.get(lcomp, -1))
			if lv >= 0:
				nl.add_load(ni, lv)
	nl.finalize()
	netlist = nl
	return nl


# 导出 + 编译：纯数据路径（不 bind 实体表，拿到的是可以直接喂引擎的 prog）
func compile(builds: Array) -> SWGateProgram:
	var nl: SWNetlist = export_netlist(builds)
	return SWGateCompiler.new().compile_netlist(nl)


# 把编译产物接回实体对象表（表现层回填用；纯逻辑运行时不需要）。
# 下标空间由 prog 自己给出（dev_slots / net_id_to_slot），这里只做映射，不改任何数值。
func bind_program(prog: SWGateProgram) -> void:
	prog.all_comps = comps.duplicate()
	prog.net_list = net_objects.duplicate()
	prog.net_to_slot = {}
	prog.slot_to_net = {}
	prog.comp_to_slot = {}
	for ni in net_objects.size():
		var net: SWNet = net_objects[ni]
		if net == null:
			continue
		var slot: int = int(prog.net_id_to_slot.get(net.netId, -1))
		if slot < 0:
			continue
		prog.net_to_slot[net] = slot
		prog.slot_to_net[slot] = net
	for dev in comps.size():
		if dev >= prog.dev_slots.size():
			break
		var cslot: int = prog.dev_slots[dev]
		if cslot >= 0:
			prog.comp_to_slot[comps[dev]] = cslot
	prog.input_comps = _comps_of(prog.input_devs)
	prog.reg_comps = _comps_of(prog.reg_devs)
	prog.led_comps = _comps_of(prog.led_devs)
	prog.led_refresh_comps = _renderables_of(prog.led_devs)
	prog.gate_refresh_comps = _renderables_of(prog.gate_devs)
	prog.display_comps = _comps_of(prog.display_devs)
	prog.fallback_display_comps = _comps_of(prog.fallback_display_devs)


# 组件 → 网表元件类型（判据与 SWGateCompiler.compile 的老分支同口径）
func _classify(comp) -> int:
	if comp is SWBuildCompoentCircuitClockSiggen or comp is SWBuildCompoentCircuitSource:
		return SWNetlist.DEV_SOURCE
	if comp is SWBuildCompoentCircuitLed:
		return SWNetlist.DEV_LED
	if comp.isStateful():
		return SWNetlist.DEV_REG
	if comp is SWBuildCompoentCircuitNot:
		return SWNetlist.DEV_NOT
	return SWNetlist.DEV_AND


func _comps_of(devs: PackedInt32Array) -> Array:
	var out: Array = []
	for k in devs.size():
		var dev: int = devs[k]
		if dev >= 0 and dev < comps.size():
			out.append(comps[dev])
	return out


func _renderables_of(devs: PackedInt32Array) -> Array:
	var out: Array = []
	for k in devs.size():
		var dev: int = devs[k]
		if dev >= 0 and dev < dev_builds.size():
			out.append(dev_builds[dev].getRenderableCompoent())
	return out
