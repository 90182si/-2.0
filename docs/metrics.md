# 性能验收报告

## 改造一：信号纹理驱动 GPU 着色

### 架构变更

- **时钟 tick 路径**：从 O(chunk 几何重算) 降为 O(翻转 net 数) 增量纹理写入
- **custom_data 格式**：从 `[rect.x, rect.y, rect.w, rect.h]` 改为 `[style_id, net_id, flags, 0]`
- **新增纹理**：
  - `styleTex`（`SWStyleTexture`）：1×N 像素，N = 已注册 region 数（动态，由 `build_from_registry` 决定），FORMAT_RGBAF
  - `signalTex`（`SWSignalTexture`）：65536×1 像素，FORMAT_RGBAF（每 net 一列，RGBA 编码信号颜色）
- **shader 采样**：片段着色器通过 `custom_data.x` 查 styleTex 取 atlas UV rect，通过 `custom_data.y` 查 signalTex 取信号颜色

### 性能指标

| 指标 | 改造前 | 改造后 | 备注 |
|------|--------|--------|------|
| `getRenderParts`/tick | O(chunk 全部建筑) — 每次 calBuffer 遍历 `curMapData` 全量调用 | 0（tick 期间不再调用） | tick 仅写 signalTex 像素，不触发几何重算；`_renderPartsDirty` 脏标记缓存保证仅几何层事件（放置/删除/旋转/连接）时重建 |
| `drawMap`/tick | 每 tick 调用（时钟翻转→区块重绘→全量 calBuffer） | 0（tick 期间不再调用） | tick 路径不经过 `drawMap`；仅在几何层变更（`_refreshChunkContent`/`process_load_chunk`）时调用 |
| `signalTex flush`/tick | N/A | O(1) texture.update（脏时） | `flush()` 每帧最多一次 `texture.update`，写入量 = O(翻转 net 数) 像素 |
| 帧率 | 待测 | 目标 ≥55 fps | 需实测，性能面板 `SWPerformanceMonitor` 已含 FPS 颜色阈值（≥55 绿/≥30 黄/<30 红） |
| ping-pong buffer 大小 | 单 buffer，每帧 realloc + 清零 | 2 × `maxInstances × 16 × 4` 字节/chunk | 见下方计算 |

### Ping-Pong Buffer 大小计算

```
CHUNK_SIZE        = 16
n                 = 16 × 16 = 256
MAX_RENDER_PARTS  = 6
maxInstances      = 256 × 6 = 1536
float/实例        = 16（use_colors=true：transform 8 + color 4 + custom_data 4）
单 buffer 字节    = 1536 × 16 × 4 = 98,304 B ≈ 96 KB
ping-pong 总字节  = 2 × 96 KB = 192 KB/chunk
```

### 纹理内存开销

| 纹理 | 尺寸 | 格式 | 大小 |
|------|------|------|------|
| `styleTex` | styleCount × 1 | RGBAF | styleCount × 16 B（通常 < 1 KB） |
| `signalTex` | 65536 × 1 | RGBAF | 65536 × 16 B = 1 MB |

### 静态计数器

为验收测试添加了以下静态计数器（不持久化，进程内有效）：

| 计数器 | 位置 | 说明 |
|--------|------|------|
| `SWBuildCompoentRenderable.s_get_render_parts_call_count` | `circuit/build_compoent/sw_build_compoent_renderable.gd` | `getRenderParts()` 被 `calBuffer` 调用的累计次数 |
| `SWMultiMeshInstance2D.s_draw_map_call_count` | `render/sw_multi_mesh_instance_2d.gd` | `drawMap()` 被调用的累计次数 |

测试时可在任意时刻读取这两个 static var 的值进行断言。

### 测试场景

> 待补充：实际运行后填入具体数据

- 电路规模：_待补充_
- 时钟数量：_待补充_
- 电线密度：_待补充_
- 实测帧率：_待补充_
- `getRenderParts` 调用数/tick：_待补充_
- `drawMap` 调用数/tick：_待补充_
- `signalTex flush` 次数/tick：_待补充_
