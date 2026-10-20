#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/templates/vector.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

namespace godot {

// Phase 4：IR 求值循环的原生实现。
// 指令编码与 circuit/sw_bool_program.gd 保持一致（改那边必须同步改这里，
// 由 test/circuit/ir_parity_test.gd 的原生对拍兜住）。
class SWBoolEval : public RefCounted {
	GDCLASS(SWBoolEval, RefCounted);

public:
	enum Op {
		OP_INPUT = 0,
		OP_LATCH = 1,
		OP_AND = 2,
		OP_NAND = 3,
		OP_NOT = 4,
		OP_PASS = 5,
		OP_CONST = 6,
		OP_OUT = 7,
		OP_READ = 8,
	};

	enum Result {
		RESULT_FALLBACK = 1, // 传播撞进组合环段，已退回全量收敛
	};

	struct Inst {
		int32_t op;
		int32_t dst;
		int32_t a;
		int32_t b;
		int32_t in_net; // OP_INPUT 读的 net 下标，其余 -1
		int32_t out_net; // OP_OUT 写的 net 下标，其余 -1
	};

protected:
	static void _bind_methods();

public:
	void configure(const PackedInt32Array &p_ops, const PackedInt32Array &p_dst,
			const PackedInt32Array &p_a, const PackedInt32Array &p_b,
			const PackedInt32Array &p_in_net, const PackedInt32Array &p_out_net,
			const PackedInt32Array &p_segments, int p_slot_count, int p_net_count);
	void set_leaf_callable(const Callable &p_cb);
	void sync_net(int p_net, int p_value);
	void sync_nets(const PackedInt32Array &p_net_ids, const PackedInt32Array &p_values);
	void load_slots(const PackedInt32Array &p_values);

	void begin_event();
	int evaluate_from(const PackedInt32Array &p_seeds);
	void evaluate_all();
	void evaluate_span(int p_start, int p_end, int p_iters);

	int get_slot(int p_slot) const;
	PackedInt32Array get_slots() const;
	PackedInt32Array get_changed_slots() const;
	PackedInt32Array get_changed_net_ids() const;
	PackedInt32Array get_changed_net_values() const;
	int get_eval_inst_count() const { return eval_inst_count; }

private:
	void eval_inst(int p_inst, bool p_propagate);
	void propagate(int p_slot);
	void mark_slot_changed(int p_slot);
	void set_net(int p_net, int p_value, bool p_propagate);
	void heap_push(int p_inst);
	int heap_pop();
	void run_span(int p_start, int p_end, int p_iters);

	Vector<Inst> insts;
	Vector<int32_t> seg_start;
	Vector<int32_t> seg_end;
	Vector<int32_t> seg_iters;
	Vector<uint8_t> cyclic; // 指令是否位于 iters>1 的段
	Vector<uint8_t> slots;
	Vector<int32_t> net_values;

	// CSR 邻接：slot -> 读它的指令；net -> 读它的 OP_INPUT 指令
	Vector<int32_t> use_head;
	Vector<int32_t> use_items;
	Vector<int32_t> net_head;
	Vector<int32_t> net_items;

	Vector<uint8_t> slot_dirty;
	Vector<uint8_t> net_dirty;
	Vector<int32_t> changed_slots;
	Vector<int32_t> changed_net_ids;
	Vector<int32_t> changed_net_values;

	// 堆成员用「世代戳」判定，避免每次事件清零 O(指令数) 的数组
	Vector<int32_t> heap_stamp;
	int32_t heap_stamp_id = 0;
	Vector<int32_t> heap;

	Callable leaf_cb;
	int eval_inst_count = 0;
	bool hit_cyclic = false;
};

} // namespace godot
