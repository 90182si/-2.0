#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Gates { int gates[]; };
layout(set = 0, binding = 1, std430) restrict buffer BufA { int a[]; };
layout(set = 0, binding = 2, std430) restrict buffer BufB { int b[]; };
layout(set = 0, binding = 3, std430) restrict buffer SlotLv { int slot_lv[]; };
layout(set = 0, binding = 4, std430) restrict buffer LayerInfo { int layer_start; int layer_count; };

const int OP_NOT = 1;
const int OP_AND = 2;
const int OP_ALIAS = 4;

int read_slot(int s, int gate_level) {
	int lv = slot_lv[s];
	if (lv >= 0 && lv < gate_level) {
		return b[s];
	}
	return a[s];
}

void main() {
	uint gi = gl_GlobalInvocationID.x;
	if (int(gi) >= layer_count) {
		return;
	}
	int base = (layer_start + int(gi)) * 8;
	int op = gates[base];
	int dst = gates[base + 1];
	int gate_level = gates[base + 2];
	int n = gates[base + 3];
	int v = 0;
	if (op == OP_NOT) {
		v = 1 - read_slot(gates[base + 4], gate_level);
	} else if (op == OP_ALIAS) {
		// CSE 产物：直接复用已算出的公共子表达式结果
		v = read_slot(gates[base + 4], gate_level);
	} else if (op == OP_AND) {
		v = 1;
		if (n <= 0) {
			v = 0;
		} else {
			for (int i = 0; i < n; i++) {
				v &= read_slot(gates[base + 4 + i], gate_level);
			}
		}
	}
	b[dst] = v;
}
