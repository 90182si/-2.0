#[compute]
#version 450

// T1.10 寄存器锁存 pass（组合求值后跑，每寄存器一个线程）。
// 与 CPU SWBuildCompoentCircuitRegister.evaluate() 语义逐位一致：
//   - 上升沿检测：last_clk == LOW(0) && clk_new == HIGH(1) → 采样；
//   - 采样值 = 「拍前 D」（a[d]，旧值缓冲 = 本轮组合开始前的上一轮结果），同步电路同时采样；
//   - 首次（last_clk = -1，旧存档/未定相位）只对齐电平不采样；
//   - Q 新值同时写 b[q]（结果缓冲）与 a[q]（读侧）：写 b 是为了下一轮交换后继续使用，
//     写 a 是为了「锁存后紧跟的第二遍组合」能立即读到新 Q（否则下游要等下一拍）。
// regs stride 3: [q_comp_slot, clk_slot, d_slot]
// reg_state stride 2: [q_old, last_clk_old]（每线程独立条目，读旧写新，无跨线程写冲突）

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Regs { int regs[]; };
layout(set = 0, binding = 1, std430) restrict buffer RegState { int reg_state[]; };
layout(set = 0, binding = 2, std430) restrict buffer BufA { int a[]; };
layout(set = 0, binding = 3, std430) restrict buffer BufB { int b[]; };
layout(set = 0, binding = 4, std430) restrict buffer SlotLv { int slot_lv[]; };
// 寄存器条数（剔除 dispatch 多余线程的越界读写）
layout(set = 0, binding = 5, std430) restrict buffer RegCount { int reg_count; };

// 锁存 pass 在组合完成后跑：组合 slot（lv>=0）本轮已算到 b → 读 b；外部/寄存器（lv=-1）读 a
int read_slot(int s) {
	int lv = slot_lv[s];
	if (lv >= 0) {
		return b[s];
	}
	return a[s];
}

void main() {
	uint ri = gl_GlobalInvocationID.x;
	if (int(ri) >= reg_count) {
		return;
	}
	int base = int(ri) * 3;
	int q = regs[base];
	int clk = regs[base + 1];
	int d = regs[base + 2];
	int st = int(ri) * 2;
	int q_val = reg_state[st];
	int last_clk = reg_state[st + 1];
	int clk_new = read_slot(clk);
	int d_old = a[d];
	if (last_clk == 0 && clk_new == 1) {
		q_val = d_old;
	}
	reg_state[st] = q_val;
	reg_state[st + 1] = clk_new;
	b[q] = q_val;
	// 写回读侧：紧随其后的第二遍组合要直接读到新 Q（下游同拍响应）
	a[q] = q_val;
}
