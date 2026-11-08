#[compute]
#version 450

// GPU LED resolve：灯泡亮灭 = OR(输入 slot)，按组一次算完再广播给组内帧槽。
// CPU 侧不再每拍遍历全部灯泡（64x 存档实测 9ms/帧），改为在这里一次 dispatch 算完，
// 结果直接写进信号纹理的 levels[]（帧槽区），后续由 sw_signal_compute.glsl 刷成纹理。
//
// 为什么要分组：一组 = 输入 slot 集合完全相同的灯泡，亮灭必然相同。
// 「多个灯泡接同一根 net」是最常见的接法，逐灯泡一条记录会把同一个 OR 算 N 遍；
// 这里一组一个 dispatch 线程：读一次 slot 求一次 OR，再把结果写满本组所有帧槽。
//
// 组表布局（stride = 8，必须与 CPU 侧 LED_TABLE_STRIDE 逐字一致）：
//   grp[i*8 + 0]      = src_count（0~4）
//   grp[i*8 + 1..4]   = 输入 slot 下标（全局 slot 下标；未接的口 = -1）
//   grp[i*8 + 5]      = dst_off（本组帧槽段在帧槽表 dsts[] 里的起点）
//   grp[i*8 + 6]      = dst_count（本组帧槽数；0 = 空组/表尾填位，直接跳过）
//   grp[i*8 + 7]      = 保留（对齐）
// 表尾由 CPU 侧用全 0 记录补齐到 64 的整数倍：这样既能超发整组不越界，
// 也不需要依赖 SSBO 的 length()（各驱动行为不一致）。
// 全局 slot buffer 跨电路持久保留：本拍没求值的电路区间保留上次值，
// 于是它的灯泡读到「上次的电平」——恰好等于正确显示（没求值就不会变），无需额外补刷。

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer LedTable {
    int grp[];
} tbl;

layout(set = 0, binding = 1, std430) restrict readonly buffer Slots {
    int slots[];
} sl;

layout(set = 0, binding = 2, std430) restrict buffer Levels {
    float levels[];
} lv;

// 帧槽表：各组的目标帧槽（信号纹理 texel 下标）连续存放
layout(set = 0, binding = 3, std430) restrict readonly buffer Dsts {
    int dsts[];
} dst;

void main() {
    uint b = gl_GlobalInvocationID.x * 8u;
    int dc = tbl.grp[b + 6u];
    // 空组 / 表尾填位：直接跳过
    if (dc <= 0) {
        return;
    }
    int cnt = tbl.grp[b];
    int bit = 0;
    for (int k = 0; k < cnt; k++) {
        int s = tbl.grp[b + 1u + uint(k)];
        // -1 = 该方向没接线，按低电平（与 CPU 侧 led_src_slots 语义一致）。
        // 非 -1 的下标一定在 slot buffer 范围内：CPU 侧按「表里出现过的最大下标」保证过容量。
        if (s >= 0) {
            bit |= sl.slots[s];
        }
    }
    float v = float(bit != 0 ? 1 : 0);
    int off = tbl.grp[b + 5u];
    for (int j = 0; j < dc; j++) {
        lv.levels[dst.dsts[off + j]] = v;
    }
}
