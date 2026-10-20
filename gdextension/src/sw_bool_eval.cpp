#include "sw_bool_eval.hpp"

#include <godot_cpp/core/binder_common.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/memory.hpp>

using namespace godot;

void SWBoolEval::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure", "ops", "dst", "a", "b", "in_net", "out_net", "segments", "slot_count", "net_count"), &SWBoolEval::configure);
	ClassDB::bind_method(D_METHOD("set_leaf_callable", "callback"), &SWBoolEval::set_leaf_callable);
	ClassDB::bind_method(D_METHOD("sync_net", "net", "value"), &SWBoolEval::sync_net);
	ClassDB::bind_method(D_METHOD("sync_nets", "net_ids", "values"), &SWBoolEval::sync_nets);
	ClassDB::bind_method(D_METHOD("load_slots", "values"), &SWBoolEval::load_slots);
	ClassDB::bind_method(D_METHOD("begin_event"), &SWBoolEval::begin_event);
	ClassDB::bind_method(D_METHOD("evaluate_from", "seeds"), &SWBoolEval::evaluate_from);
	ClassDB::bind_method(D_METHOD("evaluate_all"), &SWBoolEval::evaluate_all);
	ClassDB::bind_method(D_METHOD("evaluate_span", "start", "end", "iters"), &SWBoolEval::evaluate_span);
	ClassDB::bind_method(D_METHOD("get_slot", "slot"), &SWBoolEval::get_slot);
	ClassDB::bind_method(D_METHOD("get_slots"), &SWBoolEval::get_slots);
	ClassDB::bind_method(D_METHOD("get_changed_slots"), &SWBoolEval::get_changed_slots);
	ClassDB::bind_method(D_METHOD("get_changed_net_ids"), &SWBoolEval::get_changed_net_ids);
	ClassDB::bind_method(D_METHOD("get_changed_net_values"), &SWBoolEval::get_changed_net_values);
	ClassDB::bind_method(D_METHOD("get_eval_inst_count"), &SWBoolEval::get_eval_inst_count);
}

// 读操作数槽位：与 GDScript build_indices 的 use 登记口径必须完全一致
static int read_operand_slots(const SWBoolEval::Inst &p_inst, int32_t *p_out) {
	switch (p_inst.op) {
		case SWBoolEval::OP_AND:
		case SWBoolEval::OP_NAND:
			p_out[0] = p_inst.a;
			p_out[1] = p_inst.b;
			return 2;
		case SWBoolEval::OP_NOT:
		case SWBoolEval::OP_PASS:
		case SWBoolEval::OP_OUT:
			p_out[0] = p_inst.a;
			return 1;
		default:
			return 0;
	}
}

// 整表清零的 resize：CowData::resize_zeroed 只清零「新增尾部」，
// 重新 configure 时数组长度不变或缩小的那部分会留着上一轮编译的计数，
// CSR 前缀和因此偏大，use_items 写入下标越界（删除建筑后重编译直接 FATAL）。
template <typename T>
static void resize_clear(Vector<T> &p_vec, int p_size) {
	p_vec.resize(p_size);
	for (int i = 0; i < p_size; i++) {
		p_vec.write[i] = T();
	}
}

void SWBoolEval::configure(const PackedInt32Array &p_ops, const PackedInt32Array &p_dst,
		const PackedInt32Array &p_a, const PackedInt32Array &p_b,
		const PackedInt32Array &p_in_net, const PackedInt32Array &p_out_net,
		const PackedInt32Array &p_segments, int p_slot_count, int p_net_count) {
	const int n = p_ops.size();
	insts.resize(n);
	for (int i = 0; i < n; i++) {
		Inst &out = insts.write[i];
		out.op = p_ops[i];
		out.dst = p_dst[i];
		out.a = p_a[i];
		out.b = p_b[i];
		out.in_net = p_in_net[i];
		out.out_net = p_out_net[i];
	}

	seg_start.clear();
	seg_end.clear();
	seg_iters.clear();
	resize_clear(cyclic, n);
	for (int s = 0; s + 2 < p_segments.size(); s += 3) {
		const int start = MAX(p_segments[s], 0);
		const int end = MIN(p_segments[s + 1], n);
		const int iters = p_segments[s + 2];
		seg_start.push_back(start);
		seg_end.push_back(end);
		seg_iters.push_back(iters);
		if (iters > 1) {
			for (int i = start; i < end; i++) {
				cyclic.write[i] = 1;
			}
		}
	}

	// 外部口径只是「本轮活跃段用到的 slot 数」，跨批次还会因为剪掉失活段而缩小；
	// 原生侧按指令流里真实出现的下标取上界，保证任何一条指令都不会写到数组外面
	int32_t scan_operands[2];
	int slot_count = p_slot_count;
	int net_count = p_net_count;
	for (int i = 0; i < n; i++) {
		const Inst &in = insts[i];
		if (in.dst >= 0) {
			slot_count = MAX(slot_count, in.dst + 1);
		}
		const int count = read_operand_slots(in, scan_operands);
		for (int k = 0; k < count; k++) {
			slot_count = MAX(slot_count, scan_operands[k] + 1);
		}
		if (in.in_net >= 0) {
			net_count = MAX(net_count, in.in_net + 1);
		}
		if (in.out_net >= 0) {
			net_count = MAX(net_count, in.out_net + 1);
		}
	}
	slot_count = MAX(slot_count, 1);
	net_count = MAX(net_count, 1);

	// 指令数组跨批次只增不减，槽位值必须活过重新 configure，因此只扩容不清零已有格子
	const int old_slot_count = slots.size();
	if (old_slot_count < slot_count) {
		slots.resize(slot_count);
		for (int i = old_slot_count; i < slot_count; i++) {
			slots.write[i] = 0;
		}
	}
	resize_clear(net_values, net_count);
	resize_clear(slot_dirty, slot_count);
	resize_clear(net_dirty, net_count);
	resize_clear(heap_stamp, n);
	heap_stamp_id = 0;

	// 两趟建 CSR（计数桶必须与填充桶用同一套判定，否则下标错位）
	resize_clear(use_head, slot_count + 1);
	resize_clear(net_head, net_count + 1);
	int use_total = 0;
	int net_total = 0;
	int32_t operands[2];
	for (int i = 0; i < n; i++) {
		const Inst &in = insts[i];
		if (in.op == OP_INPUT) {
			if (in.in_net >= 0 && in.in_net < net_count) {
				net_head.write[in.in_net + 1]++;
				net_total++;
			}
			continue;
		}
		const int count = read_operand_slots(in, operands);
		for (int k = 0; k < count; k++) {
			const int slot = operands[k];
			if (slot < 0 || slot >= slot_count) {
				continue;
			}
			use_head.write[slot + 1]++;
			use_total++;
		}
	}
	for (int i = 1; i <= slot_count; i++) {
		use_head.write[i] += use_head[i - 1];
	}
	for (int i = 1; i <= net_count; i++) {
		net_head.write[i] += net_head[i - 1];
	}
	use_items.resize(use_total);
	net_items.resize(net_total);
	Vector<int32_t> cursor;
	resize_clear(cursor, slot_count + 1);
	Vector<int32_t> net_cursor;
	resize_clear(net_cursor, net_count + 1);
	for (int i = 0; i < n; i++) {
		const Inst &in = insts[i];
		if (in.op == OP_INPUT) {
			if (in.in_net >= 0 && in.in_net < net_count) {
				const int pos = net_head[in.in_net] + net_cursor[in.in_net];
				net_cursor.write[in.in_net] = net_cursor[in.in_net] + 1;
				net_items.write[pos] = i;
			}
			continue;
		}
		const int count = read_operand_slots(in, operands);
		for (int k = 0; k < count; k++) {
			const int slot = operands[k];
			if (slot < 0 || slot >= slot_count) {
				continue;
			}
			const int pos = use_head[slot] + cursor[slot];
			cursor.write[slot] = cursor[slot] + 1;
			use_items.write[pos] = i;
		}
	}

	changed_slots.clear();
	changed_net_ids.clear();
	changed_net_values.clear();
	heap.clear();
	eval_inst_count = 0;
	hit_cyclic = false;
}

void SWBoolEval::set_leaf_callable(const Callable &p_cb) {
	leaf_cb = p_cb;
}

void SWBoolEval::sync_net(int p_net, int p_value) {
	if (p_net < 0 || p_net >= net_values.size()) {
		return;
	}
	net_values.write[p_net] = p_value ? 1 : 0;
}

void SWBoolEval::sync_nets(const PackedInt32Array &p_net_ids, const PackedInt32Array &p_values) {
	for (int k = 0; k < p_net_ids.size(); k++) {
		sync_net(p_net_ids[k], p_values[k]);
	}
}

void SWBoolEval::load_slots(const PackedInt32Array &p_values) {
	const int count = p_values.size();
	if (slots.size() < count) {
		const int old = slots.size();
		slots.resize(count);
		for (int i = old; i < count; i++) {
			slots.write[i] = 0;
		}
	}
	for (int i = 0; i < count; i++) {
		slots.write[i] = p_values[i] ? 1 : 0;
	}
}

void SWBoolEval::begin_event() {
	for (int i = 0; i < changed_slots.size(); i++) {
		slot_dirty.write[changed_slots[i]] = 0;
	}
	for (int i = 0; i < changed_net_ids.size(); i++) {
		net_dirty.write[changed_net_ids[i]] = 0;
	}
	changed_slots.clear();
	changed_net_ids.clear();
	changed_net_values.clear();
}

void SWBoolEval::mark_slot_changed(int p_slot) {
	if (p_slot < 0 || p_slot >= slot_dirty.size() || slot_dirty[p_slot]) {
		return;
	}
	slot_dirty.write[p_slot] = 1;
	changed_slots.push_back(p_slot);
}

void SWBoolEval::set_net(int p_net, int p_value, bool p_propagate) {
	if (p_net < 0 || p_net >= net_values.size()) {
		return;
	}
	if (net_values[p_net] != p_value) {
		net_values.write[p_net] = p_value;
		if (net_dirty[p_net]) {
			// 同一事件内二次翻转：只留末位值，与 GDScript 的 Dictionary 去重同义
			for (int i = changed_net_ids.size() - 1; i >= 0; i--) {
				if (changed_net_ids[i] == p_net) {
					changed_net_values.write[i] = p_value;
					break;
				}
			}
		} else {
			net_dirty.write[p_net] = 1;
			changed_net_ids.push_back(p_net);
			changed_net_values.push_back(p_value);
		}
	}
	if (p_propagate) {
		for (int k = net_head[p_net]; k < net_head[p_net + 1]; k++) {
			heap_push(net_items[k]);
		}
	}
}

void SWBoolEval::propagate(int p_slot) {
	if (p_slot < 0 || p_slot + 1 >= use_head.size()) {
		return;
	}
	for (int k = use_head[p_slot]; k < use_head[p_slot + 1]; k++) {
		heap_push(use_items[k]);
	}
}

void SWBoolEval::heap_push(int p_inst) {
	if (p_inst < 0 || p_inst >= heap_stamp.size() || heap_stamp[p_inst] == heap_stamp_id) {
		return;
	}
	if (cyclic[p_inst]) {
		hit_cyclic = true;
		return;
	}
	heap_stamp.write[p_inst] = heap_stamp_id;
	heap.push_back(p_inst);
	int c = heap.size() - 1;
	while (c > 0) {
		const int p = (c - 1) >> 1;
		if (heap[p] <= heap[c]) {
			break;
		}
		const int32_t tmp = heap[p];
		heap.write[p] = heap[c];
		heap.write[c] = tmp;
		c = p;
	}
}

int SWBoolEval::heap_pop() {
	const int top = heap[0];
	const int32_t last = heap[heap.size() - 1];
	heap.write[0] = last;
	heap.remove_at(heap.size() - 1);
	int p = 0;
	const int n = heap.size();
	while (true) {
		const int l = p * 2 + 1;
		if (l >= n) {
			break;
		}
		const int r = l + 1;
		const int s = (r >= n || heap[l] <= heap[r]) ? l : r;
		if (heap[p] <= heap[s]) {
			break;
		}
		const int32_t tmp = heap[p];
		heap.write[p] = heap[s];
		heap.write[s] = tmp;
		p = s;
	}
	return top;
}

void SWBoolEval::eval_inst(int p_inst, bool p_propagate) {
	const Inst &in = insts[p_inst];
	const int d = in.dst;
	eval_inst_count++;
	int next = 0;
	switch (in.op) {
		case OP_INPUT:
			next = (in.in_net >= 0 && net_values[in.in_net]) ? 1 : 0;
			break;
		case OP_LATCH:
		case OP_READ: {
			if (!leaf_cb.is_null() && leaf_cb.is_valid()) {
				const Variant ret = leaf_cb.call(d);
				next = ret.operator int64_t() == 1 ? 1 : 0;
			}
			break;
		}
		case OP_AND:
			next = slots[in.a] & slots[in.b];
			break;
		case OP_NAND:
			next = 1 - (slots[in.a] & slots[in.b]);
			break;
		case OP_NOT:
			next = 1 - slots[in.a];
			break;
		case OP_PASS:
			next = slots[in.a];
			break;
		case OP_CONST:
			next = in.a ? 1 : 0;
			break;
		case OP_OUT:
			set_net(in.out_net, slots[in.a] ? 1 : 0, p_propagate);
			return;
		default:
			return;
	}
	if (d < 0 || d >= slots.size()) {
		return;
	}
	if (slots[d] != next) {
		slots.write[d] = next;
		mark_slot_changed(d);
		if (p_propagate) {
			propagate(d);
		}
	}
}

void SWBoolEval::run_span(int p_start, int p_end, int p_iters) {
	if (p_start < 0) {
		p_start = 0;
	}
	if (p_end > insts.size()) {
		p_end = insts.size();
	}
	if (p_start >= p_end) {
		return;
	}
	if (p_iters <= 1) {
		for (int i = p_start; i < p_end; i++) {
			eval_inst(i, false);
		}
		return;
	}
	// 不动点迭代：与 GDScript _run_span 同款「先求值，再与上一趟整份 slot 快照比较」。
	// 注意 GDScript 的 prev 初始为空数组，第一趟的比较恒为假，所以 iters>1 时至少跑两趟；
	// 这里保持一致，避免两条后端在收敛趟数（以及诊断指令数）上出现口径差。
	const int slot_count = slots.size();
	Vector<uint8_t> prev;
	for (int it = 0; it < p_iters; it++) {
		for (int i = p_start; i < p_end; i++) {
			eval_inst(i, false);
		}
		bool same = (prev.size() == slot_count);
		if (same) {
			for (int i = 0; i < slot_count; i++) {
				if (prev[i] != slots[i]) {
					same = false;
					break;
				}
			}
		}
		prev.resize(slot_count);
		for (int i = 0; i < slot_count; i++) {
			prev.write[i] = slots[i];
		}
		if (same) {
			break;
		}
	}
}

void SWBoolEval::evaluate_all() {
	if (seg_start.is_empty()) {
		run_span(0, insts.size(), 1);
		return;
	}
	for (int s = 0; s < seg_start.size(); s++) {
		run_span(seg_start[s], seg_end[s], seg_iters[s]);
	}
}

void SWBoolEval::evaluate_span(int p_start, int p_end, int p_iters) {
	hit_cyclic = false;
	run_span(p_start, p_end, p_iters);
}

int SWBoolEval::evaluate_from(const PackedInt32Array &p_seeds) {
	if (p_seeds.is_empty()) {
		return 0;
	}
	if (heap_stamp_id == INT32_MAX) {
		// 同长度 resize_zeroed 不清零已有元素，必须整表清零，否则旧代际戳会被当成「已在堆中」
		resize_clear(heap_stamp, heap_stamp.size());
		heap_stamp_id = 0;
	}
	heap_stamp_id++;
	heap.clear();
	hit_cyclic = false;
	for (int i = 0; i < p_seeds.size(); i++) {
		heap_push(p_seeds[i]);
	}
	const int budget = insts.size() + p_seeds.size();
	int done = 0;
	while (!heap.is_empty()) {
		eval_inst(heap_pop(), true);
		done++;
		if (hit_cyclic || done > budget) {
			break;
		}
	}
	if (hit_cyclic || done > budget) {
		heap.clear();
		hit_cyclic = false;
		evaluate_all();
		return RESULT_FALLBACK;
	}
	return 0;
}

int SWBoolEval::get_slot(int p_slot) const {
	if (p_slot < 0 || p_slot >= slots.size()) {
		return -1;
	}
	return slots[p_slot] ? 1 : 0;
}

PackedInt32Array SWBoolEval::get_slots() const {
	PackedInt32Array ret;
	ret.resize(slots.size());
	for (int i = 0; i < slots.size(); i++) {
		ret[i] = slots[i] ? 1 : 0;
	}
	return ret;
}

PackedInt32Array SWBoolEval::get_changed_slots() const {
	PackedInt32Array ret;
	ret.resize(changed_slots.size());
	for (int i = 0; i < changed_slots.size(); i++) {
		ret[i] = changed_slots[i];
	}
	return ret;
}

PackedInt32Array SWBoolEval::get_changed_net_ids() const {
	PackedInt32Array ret;
	ret.resize(changed_net_ids.size());
	for (int i = 0; i < changed_net_ids.size(); i++) {
		ret[i] = changed_net_ids[i];
	}
	return ret;
}

PackedInt32Array SWBoolEval::get_changed_net_values() const {
	PackedInt32Array ret;
	ret.resize(changed_net_values.size());
	for (int i = 0; i < changed_net_values.size(); i++) {
		ret[i] = changed_net_values[i];
	}
	return ret;
}
