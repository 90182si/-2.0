class_name SWBoolProgram extends RefCounted

const OP_INPUT := 0
const OP_LATCH := 1
const OP_AND := 2
const OP_NAND := 3
const OP_NOT := 4
const OP_PASS := 5
const OP_CONST := 6
const OP_OUT := 7

var op_arr: PackedInt32Array = PackedInt32Array()
var dst_arr: PackedInt32Array = PackedInt32Array()
var a_arr: PackedInt32Array = PackedInt32Array()
var b_arr: PackedInt32Array = PackedInt32Array()

var input_meta: Array = []   # input_meta[idx] = {"net": SWNet}
var output_meta: Array = []  # output_meta[idx] = {"net": SWNet}

var _slots: PackedInt32Array = PackedInt32Array()
var _latch_prev: PackedInt32Array = PackedInt32Array()
var _latch_indices: Array = []

func _ensure_slots(max_slot: int) -> void:
	if _slots.size() < max_slot + 1:
		_slots.resize(max_slot + 1)
	if _latch_prev.size() < max_slot + 1:
		_latch_prev.resize(max_slot + 1)

func evaluate() -> void:
	var n := op_arr.size()
	if n == 0:
		return
	var max_slot := 0
	for i in range(n):
		if dst_arr[i] > max_slot:
			max_slot = dst_arr[i]
	_ensure_slots(max_slot)
	for i in range(n):
		var op := op_arr[i]
		var d := dst_arr[i]
		match op:
			OP_INPUT:
				var net: SWNet = input_meta[d].net
				_slots[d] = 1 if net.curSignal == SwDefine.CircuitSignal.HIGH else 0
			OP_LATCH:
				_slots[d] = _latch_prev[d]
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
				var net: SWNet = output_meta[d].net
				var sig = SwDefine.CircuitSignal.HIGH if _slots[a_arr[i]] == 1 else SwDefine.CircuitSignal.LOW
				if net.curSignal != sig:
					net.curSignal = sig

func register_latch(slot: int) -> void:
	if not _latch_indices.has(slot):
		_latch_indices.append(slot)

func latch_commit() -> void:
	for idx in _latch_indices:
		_latch_prev[idx] = _slots[idx]
