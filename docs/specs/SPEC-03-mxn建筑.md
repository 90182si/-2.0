# SPEC-03 · m×n 多格建筑（M7~M8 / T3.1~T3.8）

> 前置：M5（信号纹理渲染）与 M6（IR）已稳定——本改造的几何层渲染直接走改造一后的"内容变化→几何重建"路径，无高频压力。
> 原则：**单实例多格**，绝不按格拆成多个 build 实例（否则网表/通知/存档全部跟着膨胀）。
>
> **分层归属（强制，见主文档 §5）**：
> - `SWBuildDefine.size`/`getFootprint`/`SWBuildPinDefine.cell_offset` → **L0/L1 数据结构**：纯函数，无引擎 API。
> - `SWBuildManager.occupancy` + `getCoveredCells` → **L1 领域层**：占位关系的**单点真相 owner**（主文档 §5.3 规则 3）——禁止交互层、渲染层、存档各自另算 footprint；所有查询都走 §5.4 占位查询端口。
> - `SWChunkBuildData.shadowBuilds` 与卸载策略 → **L3 表现层**：属渲染调度实现细节，不进入 L1。
> - 渲染多格铺格（T3.5）只扩展 **renderable 组件的 part 字典**（契约不变、part 变多），禁止改渲染器本体。

---

## 0. 背景与现状锚点

### 0.1 单格占用现状
- `circuit/build/sw_build_manager.gd`：
  - `addBuild(build)`（L32-43）：`getChunkOrCreate(build.buildAxisPos)` → `curChunk.addBuild(build)`（单格槽位）→ `buildStoreManager[id]=build`。
  - `getBuild(axisPos)`（L103-107）：单点查 chunk → 槽位。
  - `getBuildsByRect`（L138-161）：按 chunk 遍历 `getAllBuilds()`，`region.has_point(build.buildAxisPos)` **单点命中**。
  - `delBuilds`：按 buildAxisPos 归 chunk 逐个删。
- `render/sw_draw_chunk_data.gd`：`builds` 固定 `CHUNK_SIZE²` 数组，槽位 `inChunkPos.x*CHUNK_SIZE+inChunkPos.y`；`notNullBuilds` 供渲染。
- `circuit/sw_build_pin_define.gd`：**`cell_offset:Vector2i` 字段已存在**（当前恒为 ZERO，供渲染 parts 用）——引脚多格化有现成载体。
- `sw_build_item_define.gd`：`buildAxisPos`（单点）、`rotation` setter（posmod 4，含渲染缓存失效）。
- 渲染：`_buildRenderParts()` 主体 part 单个 drawRect，offset=ZERO；端子 part 用 `cell_offset`。
- 存档：`sw_build_layer.load_save_data`（L67-101）逐条 `{pos,def,rot,comp_type,circuit_on,signal_state,tunnel_pair_id,in_loop}`。

### 0.2 术语
- **footprint**：建筑实际占地 `Vector2i(w,h)`，`buildAxisPos` = footprint **左上角格（锚点）**。
- **主 chunk**：锚点所在 chunk，唯一负责渲染该建筑。
- **影子登记**：footprint 覆盖到的其他 chunk 登记该 build 引用（供查询/删除/notify，不渲染）。

---

## 1. T3.1 定义与 footprint 数学（低风险先行）

### 改动
1. `res/sw_build_define.gd`：`@export var size:Vector2i = Vector2i(1,1)`（**缺省 1×1，旧 .tres 零迁移**）。
2. `circuit/build/sw_build_item_define.gd` 新增：
   ```gdscript
   func getFootprint() -> Vector2i:
       # rotation 为 90/270 时 w/h 互换
       if rotation == SwDefine.SW_Dir.LEFT or rotation == SwDefine.SW_Dir.RIGHT:
           return Vector2i(buildDefine.size.y, buildDefine.size.x)
       return buildDefine.size
   func getCoveredCells() -> Array[Vector2i]:   # 世界格坐标列表（GRID_SIZE 对齐的 axisPos）
   ```
   > 注意：先核对 `SW_Dir` 枚举数值与现有 posmod 旋转约定（`posmod(p.pin_dir+rotation,4)`），互换条件以"旋转 90/270 度"语义为准，不要硬编码枚举值判断，封装在一个函数里便于修正。
3. 单元格步长：所有 footprint 计算以 `SwDefine.GRID_SIZE` 为格步长；`buildAxisPos` 恒为格对齐坐标。

### 验收
- 旧档/旧 .tres 加载后 `getFootprint()==(1,1)`；GUT 全过。

---

## 2. T3.2 occupancy 占位表

### `circuit/build/sw_build_manager.gd` 改动
1. `var occupancy:Dictionary[Vector2i,int] = {}  # 格axisPos → anchor build.id`。
2. `addBuild`：校验 `getCoveredCells()` 全部空闲（且不越出允许区域逻辑不变）→ 逐格写 occupancy → 原单格逻辑保留（chunk.addBuild 仍只登记锚点格）→ 成功后才写 buildStoreManager。任一格冲突 → 返回 false（原子性：先校验后写入）。
3. `delBuilds`：按 footprint 逐格清 occupancy（仅当 `occupancy[cell]==build.id` 才清，防误删）。
4. `getBuild(axisPos)`：先 `occupancy.get(axisPos)` → `getBuildById` 回退（**兼容期双路径**，行为对 1×1 完全一致）。
5. `getBuildsByRect`：命中判定改为 footprint 矩形与 region 相交；用 `Dictionary[anchor_id,bool]` 去重，防跨 chunk 重复收集。
6. `clearAllBuilds`：`occupancy.clear()`。
7. `build_changed` 信号时机不变。

### 验收
- 单格行为回归（既有 GUT + 手测放置/重叠/删除）；
- 新增 GUT：2×2 放置→四角 getBuild 均返回同一 build；重叠放置失败；删除后 occupancy 清空。

---

## 3. T3.3 跨 chunk 影子登记与卸载

### 改动
1. `render/sw_draw_chunk_data.gd`：新增 `var shadowBuilds:Array[SWBuildItemDefine] = []`；`addBuild` 不变（锚点才进 builds/notNullBuilds）。
2. `sw_build_manager.addBuild/delBuilds`：计算 footprint 覆盖的全部 chunk（`SwCommon.GetChunkPos` 逐角+采样覆盖区间），对非主 chunk：`chunk.shadowBuilds.append(build)`（删除时 erase）。
3. `getBuildsByChunkPos(chunkPos)`：返回 `chunk.getAllBuilds() + chunk.shadowBuilds`（查询语义正确）；**渲染专用**新增 `getRenderBuildsByChunkPos` 只返回锚点在chunk内的建筑（主 chunk 渲染，避免重复绘制）——`core/manager/sw_draw_manager.gd _refreshChunkContent` 改用后者。
4. `sw_build_manager.getBuildsByRect` 已去重（T3.2），遍历范围包含影子 chunk。
5. 卸载策略（`sw_draw_manager`）：
   - 只有**主 chunk** 卸载才回收建筑（delBuilds）；
   - 影子 chunk 卸载仅清 shadowBuilds；
   - 加载 chunk 时：主 chunk 正常加载；若某影子 chunk 覆盖了"主 chunk 尚未加载"的已有建筑 → 把该建筑补登 shadowBuilds（遍历邻近 chunk 的 builds 检查 footprint 相交，仅边缘一圈，代价可接受）。
6. 视野加载留 1 chunk 余量（`on_view_rect_changed` 现有 margin 机制上确认/加一圈），防边界大建筑闪烁。

### 验收（高难点，重点测）
- 3×3 建筑骑在 4 个 chunk 交角：四方向平移穿越边界，渲染无重复/无丢失/无闪烁；
- 卸载主 chunk 后建筑消失且 occupancy 清空；只卸影子 chunk 建筑仍在。

---

## 4. T3.4 引脚边缘探测（高难，含旋转/交叉/隧道兼容）

### 改动
1. 引脚语义升级：`cell_offset`（已存在）= 相对锚点的格偏移，**仅边缘格有效**；`pin_dir` 不变。
2. 探测函数（`sw_build_compoent_circuit.gd`）：`getBuildIOConnectBuildArr` / `getDirBuild` 中，邻居查找从"锚点单点"改为"引脚格 = 锚点 + 旋转后的 cell_offset"，再沿 pin_dir（世界方向 = `posmod(pin_dir+rotation,4)`）取邻格 → `swBuildManager.getBuild`（此时 occupancy 已支持多格，天然命中大建筑边缘）。
   - `cell_offset` 旋转：`rotated_offset = (offset.y, size.x-1-offset.x)` 随 rotation 90°递推（封装 `getRotatedCellOffset(pin)` 函数，与 footprint 互换同一处维护）。
3. 邻居是 m×n 建筑时：连接判定只需对方该格"存在引脚且方向相对"——新增 `hasPinAt(worldCell, worldDir)` 查询（遍历对方 buildDefine.build_pin 比对，引脚数少，O(pins) 可接受）。
4. 电线 BFS（`getWireGroupBuilds` / `getBuildIOConnectBuildArr`）：电线仍单格，无需改；交叉电线 v/h 通道判定不变。
5. 隧道：配对逻辑（circuit_tunnel 的 net 直连）不感知 footprint，无需改，但隧道只能 1×1（在 .tres 上约束）。
6. **兼容开关**：`sw_cirucit_control` 或 manager 级 `var allowMulticell:bool = true`；1×1 建筑全部走旧路径（cell_offset 恒 ZERO 时数学上等价，需对拍验证）。

### 验收
- GUT 新增：2×2 建筑四边各置引脚，分别连电线/非门/LED，网表 drivers/loads 正确；旋转后引脚跟随（含 90/180/270）；
- ir_parity_test 扩展多格用例零差异（若 M6 已完成）。

---

## 5. T3.5 渲染：主体/底座多格铺格

### 改动（`sw_build_compoent_renderable.gd`）
1. 主体 part：`buildHasAtlas` 时由 1 个 part 展开为 `w*h` 个 part，每个 `offset = (i,j)`、rect 复用 drawRect（平铺 UV 由渲染端按 offset 采样同一 region；**如需"整图跨格采样"**需 shader 支持 UV fract，列为二期，先做平铺）。
2. 底座 part：同样按 footprint 展开。
3. 引脚 part：`offset = 旋转后 cell_offset`（替换现 ZERO/单点假设）。
4. layer 叠放顺序：遵守"layer 升序绘制、端子先、主体后"约定——展开后的 parts 保持原顺序语义（端子组→主体组），每格内部顺序一致。
5. 几何层容量：`maxInstances = CHUNK_SIZE² * MAX_RENDER_PARTS`，大建筑 parts 数增大——监控 showCount 逼近 maxInstances 的截断日志，必要时 `MAX_RENDER_PARTS` 调大（写明依据）。

### 验收
- 像素回归（1×1 全元件）零差异；2×2/1×3 样例贴图正确、旋转正确、选中 mask/holding 半透明正确。

---

## 6. T3.6 交互

### 改动（`layers/build/sw_build_layer.gd`、`layers/hold/*`）
1. 放置（holdIdleBuilds）：`sw_build_manager.addBuild` 已含 footprint 校验；拖动预览按 footprint 高亮全部覆盖格（HUD 层绘制，沿用手持渲染流程）。
2. 命中：点击/框选/擦除统一先 `occupancy.get(cell)` 定位 anchor，再按 footprint 操作（删除/选中整块，不允许半选）。
3. hold 阴影（sw_hold_layer L355-357 附近）：shadowData 的 mapDatas 复制逻辑扩展为 footprint parts 复制（与 T3.5 的 parts 展开一致）。
4. 右键擦除记账 `_pendingRemovedBuilds`：按 anchor 记账（已有按 build 粒度，天然兼容）。

### 验收
- 手测脚本：拖放预览、点击大建筑任意格选中整块、框选/擦除整块；1×1 行为无变化。

---

## 7. T3.7 存档兼容

### 改动
1. `load_save_data`（L74-93）：条目新增读取 `var w = b.get("w",1); var h = b.get("h",1)`，创建后 `build.buildDefine` 为共享资源——**size 存在 define 上而非实例**，因此存档只需保证 def 资源本身已带 size（.tres 内）。若未来出现"同 def 不同尺寸"需求，才在实例级加 sizeOverride（本期不做，决策留档）。
2. 保存端：无需新字段（尺寸随 .tres），但保存截图流程（保存前隐藏对话框）不受影响。
3. 往返测试：放 2×2 + 1×1 混合 → 保存 → 加载 → occupancy/影子/网表/渲染截图一致。

### 验收
- 旧档（无 w/h）可读；新档往返一致；GUT 存档用例全过。

---

## 8. T3.8 样例元件

新增 `res/`：`2x2基地.tres`、`1x3横梁.tres`、`3x3测试块.tres`（复制既有 .tres 改 size 与贴图），作为全流程验收载体。

---

## 9. 本 SPEC 全局禁区

1. 不按格拆实例；不改动 SWNet/网表语义（引脚探测变化除外）。
2. occupancy 与影子登记必须由 manager 单点维护，禁止渲染/交互层各自推算 footprint。
3. 每任务完成跑 GUT 全量 + 1×1 像素回归；T3.3/T3.4 未过验收禁止进入 T3.5。
4. 与隧道/交叉相关的旋转补偿逻辑（既有特殊约定）不得重写，只能复用。
