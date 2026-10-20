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

# 所有指令（含 OP_OUT）的 dst 统一为 slot 索引，按 dst 最大值扩容即为实际需要的 slot 数
func _ensure_slots(max_slot: int) -> void:
	if _slots.size() < max_slot + 1:
		_slots.resize(max_slot + 1)

func get_slot_value(slot: int) -> int:
	if slot < 0 or slot >= _slots.size():
		return -1
	return _slots[slot]

# 全量求值：迭代至不动点。指令段按 build 顺序发射并非拓扑序，
# OP_INPUT 读 net.curSignal 可能读到尚未写回的上游输出，单趟不足以让组合逻辑稳定；
# 反复求值直到 _slots 不再变化（组合电路在寄存器屏障内至多几轮即收敛），最多 MAX_SETTLE 轮。
# 对拍门禁以“与树 pull 结果一致”为准，迭代不动点与树的顺序无关递归语义等价。
const MAX_SETTLE := 64
func evaluate() -> void:
	var prev: PackedInt32Array = PackedInt32Array()
	for _iter in range(MAX_SETTLE):
		if segments.is_empty():
			_evaluate_span(0, op_arr.size())
		else:
			for sid in segments:
				var seg: Dictionary = segments[sid]
				_evaluate_span(seg["start"], seg["end"])
		if prev == _slots:
			break
		prev = _slots.duplicate()

# T2.5：只重算指定指令区间（一个电路段 = 该电路全部指令）。
# 与 evaluate() 同理：段内非拓扑序，需迭代至不动点才与树 pull 语义一致。
func evaluate_range(start: int, end: int) -> void:
	var prev: PackedInt32Array = PackedInt32Array()
	for _iter in range(MAX_SETTLE):
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
	for i in range(start, end):
		var op := op_arr[i]
		var d := dst_arr[i]
		match op:
			OP_INPUT:
				var net: SWNet = input_meta[d].net
				_slots[d] = 1 if net.curSignal == SwDefine.CircuitSignal.HIGH else 0
			OP_LATCH:
				# 时序屏障：直读寄存器组件的 qState（状态机唯一真相，边沿检测在组件 getValue 中）
				var lmeta: Dictionary = latch_meta[d]
				var lval: int = lmeta["build"].getCircuitCompoent().getPinReadState(lmeta["dir"])
				_slots[d] = 1 if lval == 1 else 0
			OP_READ:
				var rmeta: Dictionary = read_meta[d]
				var rval: int = rmeta["build"].getCircuitCompoent().getPinReadState(rmeta["dir"])
				_slots[d] = 1 if rval == 1 else 0
			OP_AND:
				_slots[d] = _slots[a_arr[i]] & _slots[b_arr[i]]
			OP_NAND:
				_slots[d] = 1 - (_slots[a_arr[i]] & _slots[b_arr[i]])
			OP_NOT:
				_slots[d] = 1 - _slots[a_arr[i]]
			OP_PASS:
				_slots[d] = _slots[a_arr[i]]
			OP_CONST:
				_slots[d] = a_arr[i]
			OP_OUT:
				# dst 是 slot 索引（兼作 output_meta 下标），值从 a 槽读出写回 net，不写 _slots[d]
				# 电线视觉传播由 SWCircuitControl 的 push 阶段统一处理
				if d < 0 or d >= output_meta.size():
					continue
				var net: SWNet = output_meta[d].net
				var sig = SwDefine.CircuitSignal.HIGH if _slots[a_arr[i]] == 1 else SwDefine.CircuitSignal.LOW
				if net.curSignal != sig:
					net.curSignal = sig
