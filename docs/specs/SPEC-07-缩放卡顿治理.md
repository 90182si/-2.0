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
2. 在 `SWCamera2D` 里按缩放档位通知 `SWDrawManager.set_scale_level()`（现在挪到过渡结束的 `_finish_zoom()` 里，见 §6）

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
| `camera/sw_camera_2d.gd` | 广播 `set_scale_level`（现由 `_finish_zoom()` 在过渡结束时发，见 §6） |

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

---

## 6. 滚轮缩放过渡（观感）

用户反馈：「鼠标滑轮缩放太僵硬了，增加过渡效果，过渡过程中只动相机，不对 layer 调用 on_view_rect_changed」。

### 6.1 做法

- `SWCamera2D.zoom_anim_sec`（默认 `0.18s`，`0` = 关闭过渡）：滚轮只改 `view_scale_level`，
  zoom 由 `_process → _tick_zoom()` 分多帧滑到 `pow(1.1, level)`，缓出曲线 `1-(1-t)^3`；
- 支点仍是鼠标：滚轮那一刻的鼠标屏幕位置存进 `_zoom_pivot`，每帧由 `_apply_zoom_at()`
  按 `+pivot*(1/z_old - 1/z_new)` 补位，鼠标下的世界坐标点全程不动；
- 连拨不积压：新事件从**当前** zoom 起跑（重设 `_zoom_from`），不会攒成一段长追赶；
- **过渡期间只动相机**：不调 `view_rect_changed()`、不换图集 LOD、不广播 `set_scale_level`。
  `flush_view_update()` 在 `is_zoom_animating()` 时只落地位移并置 `_view_dirty`，
  等 `_finish_zoom()` 统一通知一次（否则动画每帧都在改可见范围，通知下去
  等于每帧把每个 layer 的区块表全枚举一遍，缩远时单层上千格，过渡反而更卡）；
- 过渡期间每帧 `mark_view_moving()`：光靠滚轮事件那一瞬只能盖住 120ms，
  后面的过渡帧会漏，电路 tick 会在画面还在动时跑起来；
- 开局那一次（`_init_camera_view`）走 `instant = true`：要的是那一遍完整刷新，
  跑过渡的话首屏区块要晚 0.18s 才加载。`set_view()`（读档）也会取消在跑的过渡。

### 6.2 验收（`test/circuit/test_camera_zoom_transition.gd`，5 例 23 断言）

- 滚轮后 zoom 不立即变，`_tick_zoom` 分段推进，结束时精确落到目标档位；
- 过渡中 `on_view_rect_changed` 调用次数为 0（含「有位移」与「无位移」两条分支），
  结束时恰好 1 次，`_view_dirty` 被清掉；
- `instant = true` 立即到位并当场通知一次；
- 连拨两格：`_zoom_from` 取当前 zoom、`_zoom_to` 累计到两格，只在最后通知一次；
- 支点不动：`_apply_zoom_at` 前后鼠标下的世界坐标点一致（容差 1 世界单位，像素吸附造成）。

### 6.3 已知取舍

过渡中不通知 layer ⇒ 缩远时新进入视野的区块要等过渡结束（≈0.18s）才加载，
缩得很快时边缘会短暂露出空白。这是「过渡期间只动相机」的直接代价；
真要补，只能改成节流通知（例如过渡中最多每 100ms 发一次），但那又回到了逐帧重建老路。
