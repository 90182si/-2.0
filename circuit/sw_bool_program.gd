class_name SWBoolProgram extends RefCounted

const OP_INPUT := 0
const OP_LATCH := 1
const OP_AND := 2
const OP_NAND := 3
const OP_NOT := 4
const OP_PASS := 5
const OP_CONST := 6
const OP_OUT := 7
const OP_READ := 8   # 状态驱动叶直读（源/时钟/寄存器 Q），T2.5 push 化的运行时状态入口

var op_arr: PackedInt32Array = PackedInt32Array()
var dst_arr: PackedInt32Array = PackedInt32Array()
var a_arr: PackedInt32Array = PackedInt32Array()
var b_arr: PackedInt32Array = PackedInt32Array()

var input_meta: Array = []   # input_meta[slot] = {"net": SWNet}，由 OP_INPUT 的 dst 索引
var output_meta: Array = []  # output_meta[slot] = {"net": SWNet}，由 OP_OUT 的 dst 索引
var latch_meta: Array = []   # latch_meta[slot] = {"build": SWBuildItemDefine, "dir": int}，由 OP_LATCH 的 dst 索引
var read_meta: Array = []    # read_meta[slot] = {"build": SWBuildItemDefine, "dir": int}，由 OP_READ 的 dst 索引

# T2.5 段式调度：segments[circuitID] = {"start": int, "end": int, "builds": Array}
# 增量编译后指令数组只增不减，失活电路段保留但不再被调度
var segments: Dictionary = {}

var _slots: PackedInt32Array = PackedInt32Array()

# ========== T2.7 变化驱动 ==========
# 本次事件求值中「值真的发生变化」的 slot 集合（slot -> true）。
# 事件路径据此只重跑受影响建筑的 reCalSignals，而不是整条下游闭包。
var changed_slots: Dictionary = {}
# 本次事件求值中被 OP_OUT 改写电平的 net 集合（SWNet -> true），驱动电线传播与 signalTex 上色。
var dirty_nets: Dictionary = {}
# slot -> Array[SWBuildItemDefine]：引脚 slot 的归属建筑（由编译器登记，用于反查需要刷新的建筑）。
# 一个 slot 可能有多个归属（表达式节点跨建筑去重复用），故用数组。
var slot_owner: Dictionary = {}

# ========== Phase 2 变更定向求值索引（编译完成后一次性构建，见 build_indices） ==========
# slot -> Array[指令下标]：读取该 slot 的指令，按发射顺序升序
var slot_uses: Array = []
# build.id -> Array[指令下标]：状态驱动叶（OP_READ/OP_LATCH）指令，事件源的种子入口
var leaf_insts: Dictionary = {}
# circuitID -> Array[指令下标]：本段内全部时序元件（isSequential）的叶指令。
# 寄存器 Q 由 reCalSignals 在 IR 之外改状态，叶指令没有操作数、use 表无从把它踢进队列；
# 时钟事件所在电路若不主动重采样这些叶，锁存后的 qState 永不向下传播（计数器冻结）。
# 整段重跑路径每事件都会重读段内全部叶，故按「事件源所在电路」播种即与整段语义等价，
# 且代价只与本段寄存器数有关，与世界规模无关。
var seq_leaf_insts: Dictionary = {}
# SWNet -> Array[指令下标]：读该 net 的 OP_INPUT 指令
var _net_input_insts: Dictionary = {}
# 被 IR 之外的代码改写过电平的 net，下一事件须补读它们的 OP_INPUT
var _pending_nets: Dictionary = {}
# 工作列表：按指令下标取最小值弹出，弹出序即拓扑序，故每条指令一次事件内至多求值一次
var _heap: Array = []
var _in_heap: Dictionary = {}
# 指令是否落在「有组合环」的段里（iters>1）：变更定向的拓扑序前提对这类段不成立，一旦碰到就整体退回
var _cyclic_inst: PackedByteArray = PackedByteArray()
var _hit_cyclic: bool = false
# 复用缓冲区：collect_seeds 每事件都要拼种子数组，禁止逐事件新建（调用方只在本次事件内使用返回值）
var _seed_buf: Array = []
var _pending_seed_buf: Array = []
# 诊断计数：本次/最近一次求值实际执行的指令条数（变更定向 vs 整段重跑的对照口径）
static var s_eval_inst_count: int = 0
static var s_event_eval_count: int = 0
# 求循环（含堆/段扫描）自身累计的微秒，用于区分「指令解释」与「事件外围 glue」的占比
static var s_eval_usec: int = 0

# ========== Phase 4 GDExtension 原生求值 ==========
# 求值循环（堆 + 指令解释 + use 表）搬到 SWBoolEval（gdextension/），GDScript 只留
# 编译器、种子选择与 net/build 对象桥接。取不到原生类（未装扩展/平台缺库）时
# _native 保持 null，全部入口自动回落 GDScript 路径；useNativeEval 是回退开关。
var useNativeEval: bool = true
var _native = null  # SWBoolEval 实例（不做静态类型标注，避免扩展缺失时脚本解析失败）
var _native_failed: bool = false
# net 下标 ↔ SWNet：原生侧只认整数下标，对象桥接全在这张表上
var _native_nets: Array = []
var _native_net_index: Dictionary = {}
# slot → [build, dir]：原生叶子指令回调取状态
var _leaf_meta: Dictionary = {}
# 编译期算出的 slot 总数，切换 useNativeEval 时按此重新装配原生侧
var _slot_count: int = 0
# 复用缓冲区：事件路径每次都要把 seeds 转成 PackedInt32Array，禁止逐事件新建数组
var _native_seeds: PackedInt32Array = PackedInt32Array()
var _native_t0: int = 0
var _native_insts0: int = 0

func _net_index(net: SWNet) -> int:
	if net == null:
		return -1
	var idx: int = _native_net_index.get(net, -1)
	if idx < 0:
		idx = _native_nets.size()
		_native_nets.append(net)
		_native_net_index[net] = idx
	return idx

## 把整份指令流与桥接表交给原生求值器，并用 GDScript 侧现值播种 slot / net 表
func _native_setup(slot_count: int) -> void:
	if not useNativeEval or _native_failed:
		return
	if _native == null:
		if not ClassDB.class_exists("SWBoolEval"):
			_native_failed = true
			return
		_native = ClassDB.instantiate("SWBoolEval")
		if _native == null:
			_native_failed = true
			return
		_native.set_leaf_callable(_native_leaf_cb.bind(self))
	var n: int = op_arr.size()
	var in_net := PackedInt32Array()
	var out_net := PackedInt32Array()
	in_net.resize(n)
	out_net.resize(n)
	in_net.fill(-1)
	out_net.fill(-1)
	for i in range(n):
		var op: int = op_arr[i]
		if op == OP_INPUT:
			var im: Dictionary = input_meta[dst_arr[i]]
			in_net[i] = _net_index(im.get("net", null))
		elif op == OP_OUT:
			var d: int = dst_arr[i]
			if d >= 0 and d < output_meta.size():
				var om: Dictionary = output_meta[d]
				out_net[i] = _net_index(om.get("net", null))
	var seg_arr := PackedInt32Array()
	for sid in segments:
		var seg: Dictionary = segments[sid]
		seg_arr.append(int(seg.get("start", 0)))
		seg_arr.append(int(seg.get("end", 0)))
		seg_arr.append(int(seg.get("iters", 1)))
	_native.configure(op_arr, dst_arr, a_arr, b_arr, in_net, out_net, seg_arr, slot_count, _native_nets.size())
	_native.load_slots(_slots)
	var ids := PackedInt32Array()
	var vals := PackedInt32Array()
	for net: SWNet in _native_nets:
		ids.append(_native_net_index[net])
		vals.append(1 if net.curSignal == SwDefine.CircuitSignal.HIGH else 0)
	_native.sync_nets(ids, vals)

## 原生侧 OP_READ/OP_LATCH 回调：dst 槽即 _leaf_meta 下标，语义与 _eval_inst 一致
static func _native_leaf_cb(slot: int, prog) -> int:
	return prog._leaf_state_of(slot)

## 叶指令的现值读取：建筑可能已被删除（失活段的 meta 仍留在表里），逐层校验后回 0
static func _leaf_state(m: Array) -> int:
	var build = m[0]
	if build == null or not is_instance_valid(build):
		return 0
	var comp = build.getCircuitCompoent()
	if comp == null:
		return 0
	return 1 if comp.getPinReadState(m[1]) == 1 else 0

## GDScript 路径与原生回调共用 dst → [build, dir] 镜像，两条路径取到同一份现值
func _leaf_state_of(slot: int) -> int:
	var m: Array = _leaf_meta.get(slot, null)
	if m == null:
		return 0
	return _leaf_state(m)

## 切换原生后端（回退/对拍开关）。关闭后 _slots 镜像仍是最新值，GDScript 路径可直接接手。
func set_native_eval(p_enabled: bool) -> void:
	if useNativeEval == p_enabled:
		return
	useNativeEval = p_enabled
	if p_enabled:
		_native_setup(_slot_count)
	else:
		_native = null

func _native_before() -> void:
	_native_t0 = Time.get_ticks_usec()
	_native_insts0 = _native.get_eval_inst_count()

## 收尾：诊断计数按原生累计值差分出账，并把 slot/net 变化回灌到 GDScript 口径
func _native_after() -> void:
	s_eval_usec += Time.get_ticks_usec() - _native_t0
	s_eval_inst_count += _native.get_eval_inst_count() - _native_insts0
	_native_apply_changes()

## 把原生侧记下的变化回灌成 GDScript 的 changed_slots / dirty_nets 口径。
## 同时把变化槽写回 _slots 镜像：原生侧是求值状态的唯一 owner，
## 但重编译时的 load_slots 与「关开关回退 GDScript」都要靠这份镜像。
func _native_apply_changes() -> void:
	var slots_changed: PackedInt32Array = _native.get_changed_slots()
	for slot in slots_changed:
		changed_slots[slot] = true
		if slot >= 0 and slot < _slots.size():
			_slots[slot] = _native.get_slot(slot)
	var ids: PackedInt32Array = _native.get_changed_net_ids()
	var vals: PackedInt32Array = _native.get_changed_net_values()
	for k in range(ids.size()):
		var net: SWNet = _native_nets[ids[k]]
		net.curSignal = SwDefine.CircuitSignal.HIGH if vals[k] == 1 else SwDefine.CircuitSignal.LOW
		dirty_nets[net] = true

## 求值前把 IR 之外改写过电平的 net 现值推进原生侧（原生 OP_INPUT 读的是自己的 net 表）
func _native_sync_pending() -> void:
	for net: SWNet in _pending_nets:
		var idx: int = _native_net_index.get(net, -1)
		if idx >= 0:
			_native.sync_net(idx, 1 if net.curSignal == SwDefine.CircuitSignal.HIGH else 0)

## 编译完成后扫描指令数组，建立变更定向所需的三张索引表（可重复调用，幂等重建）
func build_indices() -> void:
	slot_uses.clear()
	leaf_insts.clear()
	seq_leaf_insts.clear()
	_net_input_insts.clear()
	_leaf_meta.clear()
	var max_slot: int = -1
	# 只扫描活跃段：指令数组只增不减，失活段的 OP_OUT 仍指向上一轮编译的 net 对象，
	# 一旦被当种子执行会把陈旧电平写回活 net（重编译后计数/上色错乱的根源）
	for sid in segments:
		var seg: Dictionary = segments[sid]
		for i in range(int(seg.get("start", 0)), int(seg.get("end", 0))):
			var op: int = op_arr[i]
			var d: int = dst_arr[i]
			if d > max_slot:
				max_slot = d
			match op:
				OP_INPUT:
					var net: SWNet = input_meta[d].net
					if net == null:
						continue
					if not _net_input_insts.has(net):
						_net_input_insts[net] = []
					_net_input_insts[net].append(i)
				OP_LATCH:
					_add_leaf(latch_meta[d].build, i)
					_leaf_meta[d] = [latch_meta[d].build, latch_meta[d].dir]
					_add_seq_leaf(sid, latch_meta[d].build, i)
				OP_READ:
					_add_leaf(read_meta[d].build, i)
					_leaf_meta[d] = [read_meta[d].build, read_meta[d].dir]
					_add_seq_leaf(sid, read_meta[d].build, i)
				OP_CONST:
					pass
				_:
					_add_use(a_arr[i], i)
					if op == OP_AND or op == OP_NAND:
						_add_use(b_arr[i], i)
	# 变更定向路径不再逐趟扫描整段，_ensure_slots 没人调；在此按活跃段最大 dst 一次配好，
	# 否则编译后直接走 evaluate_from 的事件会越界写 _slots
	_ensure_slots(max_slot)
	_slot_count = _slots.size()
	# 组合环段标记：这些段的多趟不动点语义与「按拓扑序一条指令只求值一次」不兼容
	_cyclic_inst.resize(op_arr.size())
	_cyclic_inst.fill(0)
	for sid in segments:
		var seg: Dictionary = segments[sid]
		if int(seg.get("iters", 1)) > 1:
			for i in range(int(seg["start"]), int(seg["end"])):
				_cyclic_inst[i] = 1
	# 口径取 _slots 镜像长度而非本轮 max_dst+1：跨批次编译镜像只增不减，
	# load_slots 会把整份镜像灌进原生侧，两边长度必须同源，否则原生侧按小口径分配会被大镜像写爆
	_native_setup(_slot_count)

func _add_leaf(build: SWBuildItemDefine, inst: int) -> void:
	if build == null:
		return
	if not leaf_insts.has(build.id):
		leaf_insts[build.id] = []
	leaf_insts[build.id].append(inst)

## 登记时序元件（寄存器）的叶指令到所属电路段，供该段内任一事件重采样
func _add_seq_leaf(sid, build: SWBuildItemDefine, inst: int) -> void:
	if build == null or not is_instance_valid(build):
		return
	var comp: SWBuildCompoentCircuit = build.getCircuitCompoent()
	if comp == null or not comp.isSequential():
		return
	if not seq_leaf_insts.has(sid):
		seq_leaf_insts[sid] = []
	seq_leaf_insts[sid].append(inst)

func _add_use(slot: int, inst: int) -> void:
	if slot < 0:
		return
	while slot_uses.size() <= slot:
		slot_uses.append([])
	slot_uses[slot].append(inst)

## 外部（wired-AND 驱动者回溯等）改写 net 电平后登记，下一事件补读其 OP_INPUT
func mark_net_dirty(net: SWNet) -> void:
	if net != null:
		_pending_nets[net] = true

## 取本次事件的种子指令：事件源建筑的叶子指令 + 源所在电路段的时序元件叶指令 + 待补读 net 的 OP_INPUT 指令。
## 返回空数组表示该建筑没有 IR 入口（或没有待补读 net），调用方应退回整段求值路径。
func collect_seeds(build: SWBuildItemDefine) -> Array:
	var seeds: Array = leaf_insts.get(build.id, [])
	# 源建筑没有 IR 入口时整条快路径不可信，交回调用方走整段求值
	if seeds.is_empty() and _pending_nets.is_empty():
		return []
	_seed_buf.clear()
	_seed_buf.append_array(seeds)
	# 时序元件的 Q 在 IR 之外被 reCalSignals 改写，只有本事件重读其叶指令才能把新值传下去；
	# 播种范围限制在源所在段，与整段重跑路径「每事件重读本段全部叶」逐拍等价
	if build.circuit != null:
		_seed_buf.append_array(seq_leaf_insts.get(build.circuit.circuitID, []))
	_pending_seed_buf.clear()
	for net: SWNet in _pending_nets:
		_pending_seed_buf.append_array(_net_input_insts.get(net, []))
	# 原生 OP_INPUT 读自己的 net 表，_pending_nets 清空前必须把 IR 之外改写的现值推进去
	if _native != null and not _pending_seed_buf.is_empty():
		_native_sync_pending()
	_pending_nets.clear()
	if _pending_seed_buf.is_empty():
		return _seed_buf
	_seed_buf.append_array(_pending_seed_buf)
	return _seed_buf

## Phase 2：从种子指令出发，沿 use 表只重跑受影响的指令。
## 弹出顺序按指令下标升序 = 编译器拓扑发射序，因此任一指令求值时其全部输入已定值，
## 一次事件内每条指令至多执行一次；预算耗尽（组合环把后边踢回队列）即退回全量收敛。
func evaluate_from(seeds: Array) -> void:
	if seeds.is_empty():
		return
	if _native != null:
		s_event_eval_count += 1
		_native_seeds.resize(seeds.size())
		for k in range(seeds.size()):
			_native_seeds[k] = seeds[k]
		_native_before()
		_native.evaluate_from(_native_seeds)
		_native_after()
		return
	_heap.clear()
	_in_heap.clear()
	_hit_cyclic = false
	for i: int in seeds:
		_heap_push(i)
	s_event_eval_count += 1
	var budget: int = op_arr.size() + seeds.size()
	var t0: int = Time.get_ticks_usec()
	while not _heap.is_empty():
		var i: int = _heap_pop()
		_eval_inst(i, true)
		budget -= 1
		if _hit_cyclic or budget < 0:
			break
	s_eval_usec += Time.get_ticks_usec() - t0
	if _hit_cyclic or budget < 0:
		# 变化扩散进了组合环段（或拓扑序被回头踢爆）：退回全量收敛，语义与整段路径一致
		_heap.clear()
		_in_heap.clear()
		evaluate()

## 单条指令求值。propagate=true 时把变化扩散到工作列表（变更定向路径专用）；
## 整段路径按拓扑序线性扫描，无需扩散。
func _eval_inst(i: int, propagate: bool) -> void:
	var op := op_arr[i]
	var d := dst_arr[i]
	s_eval_inst_count += 1
	match op:
		OP_INPUT:
			var net: SWNet = input_meta[d].net
			var iv: int = 1 if net.curSignal == SwDefine.CircuitSignal.HIGH else 0
			if _slots[d] != iv:
				_slots[d] = iv
				changed_slots[d] = true
				if propagate:
					_propagate(d)
		OP_LATCH:
			# 时序屏障：直读寄存器组件的 qState（状态机唯一真相，边沿检测在组件 getValue 中）
			var lv: int = _leaf_state_of(d)
			if _slots[d] != lv:
				_slots[d] = lv
				changed_slots[d] = true
				if propagate:
					_propagate(d)
		OP_READ:
			var rv: int = _leaf_state_of(d)
			if _slots[d] != rv:
				_slots[d] = rv
				changed_slots[d] = true
				if propagate:
					_propagate(d)
		OP_AND:
			var av: int = _slots[a_arr[i]] & _slots[b_arr[i]]
			if _slots[d] != av:
				_slots[d] = av
				changed_slots[d] = true
				if propagate:
					_propagate(d)
		OP_NAND:
			var nv: int = 1 - (_slots[a_arr[i]] & _slots[b_arr[i]])
			if _slots[d] != nv:
				_slots[d] = nv
				changed_slots[d] = true
				if propagate:
					_propagate(d)
		OP_NOT:
			var tv: int = 1 - _slots[a_arr[i]]
			if _slots[d] != tv:
				_slots[d] = tv
				changed_slots[d] = true
				if propagate:
					_propagate(d)
		OP_PASS:
			var pv: int = _slots[a_arr[i]]
			if _slots[d] != pv:
				_slots[d] = pv
				changed_slots[d] = true
				if propagate:
					_propagate(d)
		OP_CONST:
			var cv: int = a_arr[i]
			if _slots[d] != cv:
				_slots[d] = cv
				changed_slots[d] = true
				if propagate:
					_propagate(d)
		OP_OUT:
			# dst 是 slot 索引（兼作 output_meta 下标），值从 a 槽读出写回 net，不写 _slots[d]
			# 电线视觉传播由 SWCircuitControl 的 push 阶段统一处理
			if d < 0 or d >= output_meta.size():
				return
			var onet: SWNet = output_meta[d].net
			var sig = SwDefine.CircuitSignal.HIGH if _slots[a_arr[i]] == 1 else SwDefine.CircuitSignal.LOW
			if onet.curSignal != sig:
				onet.curSignal = sig
				# T2.7：登记电平真变化了的 net，事件路径只对这些 net 做上色
				dirty_nets[onet] = true
				if propagate:
					for j: int in _net_input_insts.get(onet, []):
						_heap_push(j)

## 把变化 slot 的全部消费者指令推入工作列表（OP_OUT 只读 slot 不写，故其消费者同样登记在 use 表）
func _propagate(slot: int) -> void:
	if slot < 0 or slot >= slot_uses.size():
		return
	for j: int in slot_uses[slot]:
		_heap_push(j)

# ========== 小顶堆（按指令下标） ==========
func _heap_push(v: int) -> void:
	if _in_heap.has(v):
		return
	if v < _cyclic_inst.size() and _cyclic_inst[v] == 1:
		_hit_cyclic = true
		return
	_in_heap[v] = true
	_heap.append(v)
	var c: int = _heap.size() - 1
	while c > 0:
		var p: int = (c - 1) >> 1
		if int(_heap[p]) <= int(_heap[c]):
			break
		var tmp = _heap[p]
		_heap[p] = _heap[c]
		_heap[c] = tmp
		c = p

func _heap_pop() -> int:
	var top: int = int(_heap[0])
	_in_heap.erase(top)
	var last: int = int(_heap[_heap.size() - 1])
	_heap[0] = last
	_heap.remove_at(_heap.size() - 1)
	var p: int = 0
	var n: int = _heap.size()
	while true:
		var l: int = p * 2 + 1
		if l >= n:
			break
		var r: int = l + 1
		var s: int = l if (r >= n or int(_heap[l]) <= int(_heap[r])) else r
		if int(_heap[p]) <= int(_heap[s]):
			break
		var tmp = _heap[p]
		_heap[p] = _heap[s]
		_heap[s] = tmp
		p = s
	return top

## 事件求值前清空变化集（编译器/全量求值不需要调用，其结果无人消费）
func begin_event() -> void:
	if _native != null:
		_native.begin_event()
	if not changed_slots.is_empty():
		changed_slots.clear()
	if not dirty_nets.is_empty():
		dirty_nets.clear()

## 编译器登记引脚 slot 的归属建筑；重复登记同一建筑时不追加
func add_slot_owner(slot: int, build: SWBuildItemDefine) -> void:
	if not slot_owner.has(slot):
		slot_owner[slot] = [build]
		return
	var arr: Array = slot_owner[slot]
	if not arr.has(build):
		arr.append(build)

# 所有指令（含 OP_OUT）的 dst 统一为 slot 索引，按 dst 最大值扩容即为实际需要的 slot 数
func _ensure_slots(max_slot: int) -> void:
	if _slots.size() < max_slot + 1:
		_slots.resize(max_slot + 1)

func get_slot_value(slot: int) -> int:
	if _native != null:
		return _native.get_slot(slot)
	if slot < 0 or slot >= _slots.size():
		return -1
	return _slots[slot]

# 全量求值：按段分派——
# T2.6：段元数据 iters=1（编译期无组合环 + 拓扑序发射）直接单趟执行；
# iters>1（组合环段）保留原不动点迭代语义。
# 各段独立收敛（电路间不共享 net，段间无依赖）。
const MAX_SETTLE := 64
func evaluate() -> void:
	if _native != null:
		_native_before()
		_native.evaluate_all()
		_native_after()
		return
	if segments.is_empty():
		_evaluate_span(0, op_arr.size())
		return
	for sid in segments:
		var seg: Dictionary = segments[sid]
		_run_span(seg["start"], seg["end"], int(seg.get("iters", MAX_SETTLE)))

# T2.5：只重算指定指令区间（一个电路段 = 该电路全部指令）。
# T2.6：iters 参数缺省时走 MAX_SETTLE 迭代以兼容未升级的调用点；
# 传入 1 时跳过 prev.duplicate 与比较，单趟返回。
func evaluate_range(start: int, end: int, iters: int = MAX_SETTLE) -> void:
	if _native != null:
		_native_before()
		_native.evaluate_span(start, end, iters)
		_native_after()
		return
	_run_span(start, end, iters)

func _run_span(start: int, end: int, iters: int) -> void:
	if iters <= 1:
		_evaluate_span(start, end)
		return
	var prev: PackedInt32Array = PackedInt32Array()
	for _iter in range(iters):
		_evaluate_span(start, end)
		if prev == _slots:
			break
		prev = _slots.duplicate()

func _evaluate_span(start: int, end: int) -> void:
	var n := op_arr.size()
	if start < 0:
		start = 0
	if end > n:
		end = n
	if start >= end:
		return
	var max_slot := 0
	for i in range(start, end):
		if dst_arr[i] > max_slot:
			max_slot = dst_arr[i]
	_ensure_slots(max_slot)
	var t0: int = Time.get_ticks_usec()
	for i in range(start, end):
		_eval_inst(i, false)
	s_eval_usec += Time.get_ticks_usec() - t0
