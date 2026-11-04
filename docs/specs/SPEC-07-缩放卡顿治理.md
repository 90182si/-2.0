# SPEC-07 · 缩放卡顿治理（内容 LOD）

> 用户反馈：「缩放不流畅，每次缩小都要重新绘制」→ 进一步确认：「越缩越卡，缩小后持续卡」，
> 且「缩远时细节可以牺牲」。

---

## 0. 结论

**根因不是几何量太大，而是「缩远时不必要的区块重建」。**

修复后：连续缩放时重建次数从「每跨一个 LOD 阈值就重建全部已上屏区块」降到 **0**（只有真正跨区块边界时才有 1 次必要加载）。

---

## 1. 一开始的错误假设

我最初判断是「缩远 → 视野面积 ×1.21 → 区块数暴涨 → 每个区块 320+ 实例」，
并据此做了两件事：

1. 给 `SWBuildCompoentRenderable.getInstanceBlock()` 加 LOD 参数，缩远时只画主体部件（丢底板/端子）
2. 在 `SWCamera2D._on_zoomCom_zoom` 里按缩放档位通知 `SWDrawManager.set_scale_level()`

**实测数据推翻了这个假设。** 诊断脚本每缩 5 档记录一次：

```
档位   新区块  重建数  实例总数   耗时ms
  -1       0       0       175      0.31
  -6       0       0       175      0.18
 -11       0       0       175      0.18
 -16       0       0       175      0.18
 -21       1       1       495      3.29   ← 跨区块边界，必要
 -26       0       0       495      0.26
 -31       0       0       495      0.21
 -36       0       0       495      0.26
```

关键事实：

- **区块世界尺寸 = `GRID_SIZE(128) × CHUNK_SIZE(16) × 8 = 16384`，非常大**
- 即使缩到 level=-36，1920×1080 视口也只覆盖 **1~2 个区块**
- 所以「区块数暴涨」根本没发生，实例总数只从 175 涨到 495

而真正的开销在这里：

```
档位 -21：重建数 2
档位 -26：重建数 2      ← 这是我引入 LOD 切档导致的
耗时 3.59ms / 1.01ms
```

**LOD 切档时把已上屏区块标记为待重建，每次切档都重跑 `drawMap`（几百个实例）。**
连续缩放就会连续卡。我引入 LOD 反而制造了新的卡顿来源。

---

## 2. 真正的修法

### 2.1 切档时不重建已上屏区块

```gdscript
func _apply_content_lod() -> void:
    # ⚠ 不重建已上屏的区块
    #   这些区块的几何本来就已烘好，重建只为把端子换成不画 ——
    #   收益 2 倍实例，却要付一次完整重建的代价，在「区块数很少」时是负收益。
    for chunkPos in _idleChunkCache.keys():
        mi.builtVersion = -1
        mi.content_lod = content_lod
```

已上屏的保持原样；**只有当区块重新进入视野（软缓存复用/新加载）时才按最新档位烘培**。
随着平移/缩放，远景区块会自然被替换成简化版。

### 2.2 LOD 阈值对齐图集 LOD

```
CONTENT_LOD_LEVEL_1 = -32   （对齐 SwDefine.VIEW_LOD_LEVEL）
CONTENT_LOD_LEVEL_2 = -40   （对齐 SwDefine.VIEW_LOD2_LEVEL）
```

比原来宽松得多的阈值：只有在**图集都已经糊了**的时候才丢细节，避免可察觉的画质下降。
内容简化比图集 LOD 再晚一档。

### 2.3 保留的优化

缩远简化本身是有效的（`test_content_lod.gd` 实测）：

```
样本建筑=3000  满精度实例=7044  简化档实例=3000  压缩比=2.35x
平均每建筑部件数: 满精度=2.35 简化=1.00
```

只是它**不该以「重建」为代价**。现在它只在新区块加载时生效，属于纯收益。

---

## 3. 改动清单

| 文件 | 改动 |
|---|---|
| `circuit/build_compoent/sw_build_compoent_renderable.gd` | `getInstanceBlock(lod)` 参数 + `_bakeSimplified()`；新增 `LOD_SIMPLIFY_LEVEL=2`、`_instanceBlockLod`、`_blockLodValid` |
| `render/sw_multi_mesh_instance_2d.gd` | 新增 `content_lod` 字段；`_buildContent()` 按档位取实例块；简化档下 `_slotsValid=false` |
| `core/manager/sw_draw_manager.gd` | 新增 `content_lod` / `set_scale_level()` / `_content_lod_for()` / `_apply_content_lod()`；`process_load_chunk` 与 `_refreshChunkContent` 同步档位 |
| `camera/sw_camera_2d.gd` | `_on_zoomCom_zoom` 里广播 `set_scale_level` |

---

## 4. 验证

### 4.1 内容 LOD 本身（`test/circuit/test_content_lod.gd`）

- 简化档实例数 < 满精度（`2.35x` 压缩）
- 档位映射：近景 `lod=0`、中景 `lod=2`、远景 `lod=3`
- **通过**

### 4.2 缩放重建次数（诊断脚本，未入库）

修复前：`-21` / `-26` 各 2 次重建
修复后：只有 `-21` 一次（新区块进入视野，必要）

### 4.3 全量测试

32 通过 / 4 失败（失败项与基线一致，均为 headless 无 RenderingDevice）。

---

## 5. 如果之后还想进一步优化

按收益排序：

1. **区块上屏复用（软缓存）命中率**：`_idleChunkCache` 容量上限 256，
   缩远时视口覆盖范围大，命中率可能不高。可以按「最近缩放过」预扩容。
2. **`drawMap` 的实例烘培加速**：目前逐建筑 `append_array`，
   可改为预分配 + `memcpy` 到连续区间。
3. **真正的几何 LOD**（一个区块代表更大世界范围的多格合并）：
   如果将来区块尺寸改小、或世界规模再大一个数量级，才值得做。
   当前 16384 的区块尺寸下，区块数不是瓶颈。
