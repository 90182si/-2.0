#[compute]
#version 450

// SPEC-01 §8.1 T1.9：CPU 侧电平数组 → 信号纹理 texel（GPU 纹理桥接）。
// 布局：storage buffer levels[]（每 net 一个 float，0=低/1=高）→ image2D（TEX_COLS×TEX_ROWS，R32G32B32A32_SFLOAT）。
// shader 侧 texelFetch(signalBits, ivec2(nid % signalCols, nid / signalCols)).r 读电平——
// 该坐标换算必须与 CPU 后端 texel 公式、本 shader 的写入坐标逐字一致。
// 注意：canvas_item fragment 禁 return 的限制不适用于 compute shader。

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer SignalLevels {
    float levels[];   // 长度 = MAX_NETS（65536），netId 索引
} sig;

layout(set = 0, binding = 1, rgba32f) uniform restrict image2D signal_tex;

void main() {
    uint nid = gl_GlobalInvocationID.x;
    ivec2 tsize = imageSize(signal_tex);
    uint total = uint(tsize.x) * uint(tsize.y);
    if (nid >= total) {
        return;
    }
    uint col = nid % uint(tsize.x);
    uint row = nid / uint(tsize.x);
    float lv = sig.levels[nid];
    imageStore(signal_tex, ivec2(int(col), int(row)), vec4(lv, 0.0, 0.0, 1.0));
}
