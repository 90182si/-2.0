class_name SWBoolCompiler extends RefCounted

# ── 编译状态（T2.5：实例由 SWCircuitControl 持有并跨批次复用，slot/指令全局递增）──
var _prog: SWBoolProgram = null
var _next_slot: int = 0
# 扇出去重：表达式节点引用 → slot 索引（跨批次保留：未重建的电路仍引用旧节点）
var _node_slot: Dictionary = {}
# 引脚值映射：key = build.id*4 + dir → slot（getValue 切 slot 的查询表，含 LED/寄存器输入侧内部 slot）
var slotMap: Dictionary = {}

# ── 公开入口 ──

## 将一批电路的 pinExprMap 编译为扁平 IR 指令段（追加到持久程序尾部，旧失活段不再被调度）
## liveCircuitIDs：当前存活的全部电路 id，用于剪除已消失电路的段元数据（防长期泄漏）
func compile(circuits: Array, liveCircuitIDs: Dictionary = {}) -> SWBoolProgram:
	if _prog == null:
		_prog = SWBoolProgram.new()
	# 剪除已消失电路的段元数据（指令本体保留但永不被调度，避免段字典无限增长）
	if not liveCircuitIDs.is_empty():
		for sid in _prog.segments.keys():
			if not liveCircuitIDs.has(sid):
				_prog.segments.erase(sid)

	for cir: SwDefine.SWCircuitData in circuits:
		var seg_start: int = _prog.op_arr.size()
		var seg_builds: Array = []
		# OP_OUT 目标 net 去重：同一批次内多个引脚表达式可能写回同一个 net
		var out_net_seen: Dictionary = {}

		# T2.6：拓扑排序——纯组合电路按 noticeMap 依赖顺序发射指令，
		# 使运行时可用单趟求值收敛（跳过 MAX_SETTLE 迭代）；
		# 只要电路内任一 build 被 in_loop 标记（Kosaraju SCC>=2 检出组合环），
		# 就退回到迭代不动点路径保证语义等价。
		var has_loop: bool = false
		for b: SWBuildItemDefine in cir.buildArr:
			if b.in_loop:
				has_loop = true
				break
		var emit_order: Array = _topo_sort_builds(cir) if not has_loop else cir.buildArr

		for build: SWBuildItemDefine in emit_order:
			if SwCommon.IsWireBuild(build):
				continue
			var comp: SWBuildCompoentCircuit = build.getCircuitCompoent()
			if comp == null:
				continue
			seg_builds.append(build)
			for dir in comp.pinExprMap.keys():
				var expr: SwDefine.SWCircuitStruct = comp.pinExprMap[dir]
				if expr == null:
					continue
				var src_slot := _compile_expr(expr, build, dir)
				# 全部 pinExprMap 方向（含 LED/寄存器输入侧内部 slot）都进 slotMap，供 getValue 切 slot
				slotMap[build.id * 4 + dir] = src_slot
				# T2.7：登记 slot 归属建筑，事件路径据此把「重跑 reCalSignals」缩小到值变化的建筑
				_prog.add_slot_owner(src_slot, build)
				# pinExprMap 的 key 不总是输出方向：
				# NOT 门表达式挂在输入侧（antiDir(rotation)），结果要写回 rotation 方向的输出 net；
				# LED/寄存器输入侧表达式只算内部状态，没有输出 net，不发 OP_OUT
				var out_dir := _expr_output_dir(comp, dir)
				if out_dir >= 0:
					# NOT 门：输出方向的 getValue 也要能查到同一 slot
					slotMap[build.id * 4 + out_dir] = src_slot
					var net: SWNet = comp.pinNetMap.get(out_dir, null)
					if net != null and not out_net_seen.has(net):
						out_net_seen[net] = true
						# 输出写回 net：dst 用 slot 索引（与 OP_AND 等指令 dst 语义一致，
						# 同时作为 output_meta 的下标，和 OP_INPUT 用 dst 索引 input_meta 对称），
						# 不再用指令索引，避免 _ensure_slots 按指令数量过度扩容 _slots
						var out_slot := _alloc_slot()
						_prog.op_arr.append(SWBoolProgram.OP_OUT)
						_prog.dst_arr.append(out_slot)
						_prog.a_arr.append(src_slot)
						_prog.b_arr.append(0)
						while _prog.output_meta.size() <= out_slot:
							_prog.output_meta.append({})
						_prog.output_meta[out_slot] = {"net": net}

		_prog.segments[cir.circuitID] = {
			"start": seg_start,
			"end": _prog.op_arr.size(),
			"builds": seg_builds,
			# T2.6：无组合环的段按拓扑序发射，运行时单趟即收敛；
			# 有组合环时保留 MAX_SETTLE 迭代路径以匹配旧树 pull 语义
			"iters": 1 if not has_loop else SWBoolProgram.MAX_SETTLE
		}

	# Phase 2：指令数组本轮可能追加/重排，索引表统一在编译结束时重建一次
	_prog.build_indices()
	return _prog

## T2.6：基于 noticeMap 的 Kahn 拓扑排序，返回非电线 build 的发射顺序
## 依赖关系：noticeMap[src] = [dst1, dst2, ...] 表示 src 驱动 dst（src 必须先求值）
## 时序屏障：与 detect_combinational_loops 对齐，isSequential 建筑的出边（如寄存器 Q → 下游）
## 不计入组合依赖图，避免计数器"Q→adder→D→Q"这类合法时序反馈把整段踢出拓扑路径。
## 未访问到的剩余节点（组合环或不可达）按原顺序追加，交由外层 has_loop 判定退回迭代。
static func _topo_sort_builds(cir: SwDefine.SWCircuitData) -> Array:
	var builds: Array = []
	var build_set: Dictionary = {}
	for b: SWBuildItemDefine in cir.buildArr:
		if SwCommon.IsWireBuild(b):
			continue
		builds.append(b)
		build_set[b] = true

	# 过滤邻接表：跳过时序元件出边
	var adj: Dictionary = {}
	for src in cir.noticeMap.keys():
		if not build_set.has(src):
			continue
		var src_comp: SWBuildCompoentCircuit = src.getCircuitCompoent()
		if src_comp != null and src_comp.isSequential():
			continue
		var filtered: Array = []
		for dst in cir.noticeMap[src]:
			if build_set.has(dst):
				filtered.append(dst)
		adj[src] = filtered

	var in_deg: Dictionary = {}
	for b in builds:
		in_deg[b] = 0
	for src in adj.keys():
		for dst in adj[src]:
			in_deg[dst] = in_deg.get(dst, 0) + 1

	var queue: Array = []
	var head := 0
	for b in builds:
		if in_deg[b] == 0:
			queue.append(b)

	var result: Array = []
	var visited: Dictionary = {}
	while head < queue.size():
		var u = queue[head]
		head += 1
		if visited.has(u):
			continue
		visited[u] = true
		result.append(u)
		for v in adj.get(u, []):
			if visited.has(v):
				continue
			in_deg[v] -= 1
			if in_deg[v] == 0:
				queue.append(v)

	# 有环/不可达节点：按原顺序补齐，保证所有 build 仍被编译发射
	for b in builds:
		if not visited.has(b):
			result.append(b)

	return result

## 求表达式 key 对应的输出方向；无输出（LED / 寄存器 CLK·D 输入侧）返回 -1
func _expr_output_dir(comp: SWBuildCompoentCircuit, dir: int) -> int:
	if comp is SWBuildCompoentCircuitNot:
		# NOT 门：表达式挂在输入侧 key 上，输出方向即机身 rotation
		return comp.buildRef.rotation
	if comp.portIsOutput(dir):
		# SOURCE / CLOCK / 寄存器 Q：key 本身就是输出方向
		return dir
	return -1

# ── 表达式树扁平化（两栈迭代后序遍历） ──

func _compile_expr(root: SwDefine.SWCircuitStruct, owner_build: SWBuildItemDefine, owner_dir: int) -> int:
	if _node_slot.has(root):
		return _node_slot[root]

	# 两栈迭代后序遍历
	var stack1: Array = [root]
	var stack2: Array = []
	while stack1.size() > 0:
		var node = stack1.pop_back()
		stack2.append(node)
		for arg in node.args:
			if arg is SwDefine.SWCircuitStruct:
				if not _node_slot.has(arg):
					stack1.append(arg)

	# 按后序处理
	while stack2.size() > 0:
		var node: SwDefine.SWCircuitStruct = stack2.pop_back()
		if _node_slot.has(node):
			continue
		var slot := _emit_node(node, owner_build, owner_dir)
		_node_slot[node] = slot

	return _node_slot[root]

func _emit_node(node: SwDefine.SWCircuitStruct, owner_build: SWBuildItemDefine, owner_dir: int) -> int:
	var op := node.op
	match op:
		SwDefine.CircuitOp.OP_LEAF:
			if node.args.size() == 0:
				return _emit_const(0)
			return _emit_leaf(node.args[0], owner_build, owner_dir)
		SwDefine.CircuitOp.OP_PASS:
			if node.args.size() == 0:
				return _emit_const(0)
			var a := _resolve_arg(node, 0, owner_build, owner_dir)
			var s := _alloc_slot()
			_prog.op_arr.append(SWBoolProgram.OP_PASS)
			_prog.dst_arr.append(s)
			_prog.a_arr.append(a)
			_prog.b_arr.append(0)
			return s
		SwDefine.CircuitOp.OP_NOT:
			if node.args.size() == 0:
				# 与树 EvalStruct 对齐：NOT 无入 = 1 - EvalArg(0)=1-0 = 1
				return _emit_const(1)
			var a := _resolve_arg(node, 0, owner_build, owner_dir)
			var s := _alloc_slot()
			_prog.op_arr.append(SWBoolProgram.OP_NOT)
			_prog.dst_arr.append(s)
			_prog.a_arr.append(a)
			_prog.b_arr.append(0)
			return s
		SwDefine.CircuitOp.OP_AND:
			if node.args.size() == 0:
				return _emit_const(0)
			return _emit_nary(node, SWBoolProgram.OP_AND, owner_build, owner_dir)
		SwDefine.CircuitOp.OP_NAND:
			if node.args.size() == 0:
				# 与树 EvalStruct 对齐：NAND 无入 = 1 - EvalArgsAnd(0)=1-0 = 1
				# （NOT 门输入 net 的驱动全部被防环/in_loop 剔除时会出现空 args NAND）
				return _emit_const(1)
			return _emit_nary(node, SWBoolProgram.OP_NAND, owner_build, owner_dir)
		_:
			# 兜底：尝试旧路径 optFuncName
			return _emit_via_optfunc(node, owner_build, owner_dir)

func _emit_nary(node: SwDefine.SWCircuitStruct, ir_op: int, owner_build: SWBuildItemDefine, owner_dir: int) -> int:
	# 多输入 AND/NAND：链式两两归约
	var first := _resolve_arg(node, 0, owner_build, owner_dir)
	if node.args.size() == 1:
		if ir_op == SWBoolProgram.OP_NAND:
			var s := _alloc_slot()
			_prog.op_arr.append(SWBoolProgram.OP_NOT)
			_prog.dst_arr.append(s)
			_prog.a_arr.append(first)
			_prog.b_arr.append(0)
			return s
		return first
	var acc := first
	for i in range(1, node.args.size()):
		var b := _resolve_arg(node, i, owner_build, owner_dir)
		var s := _alloc_slot()
		# 多输入归约恒用 OP_AND 链（结合律成立）；NAND 不能在链上级联 OP_NAND，
		# 否则 NAND(NAND(a,b),c)=(a&b)|~c ≠ NOT(a&b&c)，会在纹波进位链中级联污染布尔函数
		_prog.op_arr.append(SWBoolProgram.OP_AND)
		_prog.dst_arr.append(s)
		_prog.a_arr.append(acc)
		_prog.b_arr.append(b)
		acc = s
	if ir_op == SWBoolProgram.OP_NAND:
		var ns := _alloc_slot()
		_prog.op_arr.append(SWBoolProgram.OP_NOT)
		_prog.dst_arr.append(ns)
		_prog.a_arr.append(acc)
		_prog.b_arr.append(0)
		acc = ns
	return acc

func _resolve_arg(node: SwDefine.SWCircuitStruct, idx: int, owner_build: SWBuildItemDefine, owner_dir: int) -> int:
	if idx >= node.args.size():
		return _emit_const(0)
	var arg = node.args[idx]
	if arg is SwDefine.SWCircuitStruct:
		if _node_slot.has(arg):
			return _node_slot[arg]
		return _compile_expr(arg, owner_build, owner_dir)
	elif arg is SwDefine.SWBuildPinStruct:
		return _emit_leaf(arg, owner_build, owner_dir)
	# 常量
	var s := _alloc_slot()
	_prog.op_arr.append(SWBoolProgram.OP_CONST)
	_prog.dst_arr.append(s)
	_prog.a_arr.append(0)
	_prog.b_arr.append(0)
	return s

func _emit_leaf(leaf, owner_build: SWBuildItemDefine, owner_dir: int) -> int:
	if leaf is SwDefine.SWBuildPinStruct:
		var build: SWBuildItemDefine = leaf.build
		var dir: int = leaf.dir
		# 寄存器 Q → OP_LATCH（时序屏障）：直读组件 qState，无论自引用还是跨建筑引用
		if _is_register_q(build, dir):
			var s := _alloc_slot()
			_prog.op_arr.append(SWBoolProgram.OP_LATCH)
			_prog.dst_arr.append(s)
			_prog.a_arr.append(0)
			_prog.b_arr.append(0)
			while _prog.latch_meta.size() <= s:
				_prog.latch_meta.append({})
			_prog.latch_meta[s] = {"build": build, "dir": dir}
			return s
		# 状态驱动的叶（按钮/开关/时钟自引用，跨建筑引用同理）→ OP_READ 直读运行时状态；
		# 不能走 OP_INPUT：push 化后 net.curSignal 由本程序 OP_OUT 写回，读 net 会形成自我依赖
		var comp: SWBuildCompoentCircuit = build.getCircuitCompoent()
		if comp.getPinReadState(dir) != -1:
			var s := _alloc_slot()
			_prog.op_arr.append(SWBoolProgram.OP_READ)
			_prog.dst_arr.append(s)
			_prog.a_arr.append(0)
			_prog.b_arr.append(0)
			while _prog.read_meta.size() <= s:
				_prog.read_meta.append({})
			_prog.read_meta[s] = {"build": build, "dir": dir}
			return s
		# 普通输入：从 net 读取当前信号
		var net: SWNet = comp.pinNetMap.get(dir, null)
		if net == null:
			# 无 net 连接，视为常量 0
			var s := _alloc_slot()
			_prog.op_arr.append(SWBoolProgram.OP_CONST)
			_prog.dst_arr.append(s)
			_prog.a_arr.append(0)
			_prog.b_arr.append(0)
			return s
		var s := _alloc_slot()
		_prog.op_arr.append(SWBoolProgram.OP_INPUT)
		_prog.dst_arr.append(s)
		_prog.a_arr.append(0)
		_prog.b_arr.append(0)
		while _prog.input_meta.size() <= s:
			_prog.input_meta.append({})
		_prog.input_meta[s] = {"net": net}
		return s
	# SWCircuitStruct 子树（不应到这里，但兜底）
	if leaf is SwDefine.SWCircuitStruct:
		if _node_slot.has(leaf):
			return _node_slot[leaf]
		return _compile_expr(leaf, owner_build, owner_dir)
	return 0

func _is_register_q(build: SWBuildItemDefine, dir: int) -> bool:
	if build.buildDefine.circuit_component_type != SwDefine.CircuitComponentType.ONE_BIT_REGISTER:
		return false
	# Q_REF = RIGHT = 2, 世界方向 = posmod(2 + rotation, 4)
	var q_world_dir := posmod(2 + build.rotation, 4)
	return dir == q_world_dir

func _emit_via_optfunc(node: SwDefine.SWCircuitStruct, owner_build: SWBuildItemDefine, owner_dir: int) -> int:
	# 旧路径兜底：根据 optFuncName 推断操作
	var fname: String = node.optFuncName
	if node.args.size() == 0:
		return _emit_const(0)
	if fname == "SwCommon.AndValues":
		return _emit_nary(node, SWBoolProgram.OP_AND, owner_build, owner_dir)
	elif fname == "SwCommon.NotAndValues":
		return _emit_nary(node, SWBoolProgram.OP_NAND, owner_build, owner_dir)
	elif fname == "SwCommon.NotValues":
		var a := _resolve_arg(node, 0, owner_build, owner_dir)
		var s := _alloc_slot()
		_prog.op_arr.append(SWBoolProgram.OP_NOT)
		_prog.dst_arr.append(s)
		_prog.a_arr.append(a)
		_prog.b_arr.append(0)
		return s
	elif fname == "SwCommon.EqualValues":
		var a := _resolve_arg(node, 0, owner_build, owner_dir)
		var s := _alloc_slot()
		_prog.op_arr.append(SWBoolProgram.OP_PASS)
		_prog.dst_arr.append(s)
		_prog.a_arr.append(a)
		_prog.b_arr.append(0)
		return s
	# 最终兜底：常量 0
	var s := _alloc_slot()
	_prog.op_arr.append(SWBoolProgram.OP_CONST)
	_prog.dst_arr.append(s)
	_prog.a_arr.append(0)
	_prog.b_arr.append(0)
	return s

func _alloc_slot() -> int:
	var s := _next_slot
	_next_slot += 1
	return s

func _emit_const(value: int) -> int:
	var s := _alloc_slot()
	_prog.op_arr.append(SWBoolProgram.OP_CONST)
	_prog.dst_arr.append(s)
	_prog.a_arr.append(value)
	_prog.b_arr.append(0)
	return s

# ── Kosaraju 组合环检测（静态方法） ──

## 从 noticeMap 构建邻接表，用迭代式 Kosaraju 找 SCC
## 返回所有处于组合环中的建筑列表
static func detect_combinational_loops(circuits: Array) -> Array:
	# 1. 构建正向/反向邻接表（仅非电线建筑）
	var adj: Dictionary = {}    # build -> [downstream builds]
	var radj: Dictionary = {}   # build -> [upstream builds]
	var all_nodes: Dictionary = {}

	for cir: SwDefine.SWCircuitData in circuits:
		for src_build: SWBuildItemDefine in cir.noticeMap.keys():
			# 时序屏障：寄存器 Q 出边不参与组合环判定
			var comp = src_build.getCircuitCompoent()
			if comp and comp.isSequential():
				all_nodes[src_build] = true
				continue
			all_nodes[src_build] = true
			if not adj.has(src_build):
				adj[src_build] = []
			for dst_build: SWBuildItemDefine in cir.noticeMap[src_build]:
				all_nodes[dst_build] = true
				adj[src_build].append(dst_build)
				if not radj.has(dst_build):
					radj[dst_build] = []
				radj[dst_build].append(src_build)
		# 确保所有建筑都在节点集中
		for build: SWBuildItemDefine in cir.buildArr:
			if not SwCommon.IsWireBuild(build):
				all_nodes[build] = true

	# 2. 第一遍 DFS（正向图）求完成顺序
	var order: Array = []
	var visited: Dictionary = {}
	for node in all_nodes.keys():
		if visited.has(node):
			continue
		_iterative_dfs_forward(node, adj, visited, order)

	# 3. 第二遍 DFS（反向图，按完成逆序）找 SCC
	var visited2: Dictionary = {}
	var scc_id: Dictionary = {}
	var scc_size: Dictionary = {}
	var current_scc: int = 0

	for i in range(order.size() - 1, -1, -1):
		var node = order[i]
		if visited2.has(node):
			continue
		var size := _iterative_dfs_reverse(node, radj, visited2, scc_id, current_scc)
		scc_size[current_scc] = size
		current_scc += 1

	# 4. 收集大小 >= 2 的 SCC 中的节点
	var loop_builds: Array = []
	for node in all_nodes.keys():
		if not scc_id.has(node):
			continue
		var cid: int = scc_id[node]
		if scc_size.get(cid, 0) >= 2:
			loop_builds.append(node)

	return loop_builds

static func _iterative_dfs_forward(start, adj: Dictionary, visited: Dictionary, order: Array) -> void:
	if visited.has(start):
		return
	var stack: Array = [{"node": start, "idx": 0}]
	visited[start] = true
	while stack.size() > 0:
		var top: Dictionary = stack[stack.size() - 1]
		var node = top["node"]
		var neighbors: Array = adj.get(node, [])
		if top["idx"] < neighbors.size():
			var nb = neighbors[top["idx"]]
			top["idx"] += 1
			if not visited.has(nb):
				visited[nb] = true
				stack.append({"node": nb, "idx": 0})
		else:
			stack.pop_back()
			order.append(node)

static func _iterative_dfs_reverse(start, radj: Dictionary, visited: Dictionary, scc_id: Dictionary, scc_idx: int) -> int:
	var stack: Array = [start]
	var count: int = 0
	while stack.size() > 0:
		var node = stack.pop_back()
		if visited.has(node):
			continue
		visited[node] = true
		scc_id[node] = scc_idx
		count += 1
		var neighbors: Array = radj.get(node, [])
		for neighbor in neighbors:
			if not visited.has(neighbor):
				stack.append(neighbor)
	return count
