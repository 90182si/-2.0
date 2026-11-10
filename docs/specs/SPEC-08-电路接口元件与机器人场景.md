# SPEC-08 电路外部接口元件与机器人控制场景

> 状态：规划稿（待确认后实施）
> 目标：电路层新增「外部输入/输出接口」元件并随存档导出 `.swcir` 纯电路文件；新增一个机器人主场景，机器人加载电路后由 `clk` 输入驱动、按 `move`/`rotation` 输出自动移动旋转。

---

## 1. 需求原文映射

| # | 需求 | 落地形态 |
|---|------|---------|
| 1 | 电路层新增 2 个外部输出型元件 | 两个独立元件定义（默认名 `move`、`rotation`），输入端口，读电路内部电平，无视觉行为 |
| 2 | 新增 1 个外部输入型元件 | 元件定义默认名 `clk`，输出端口，电平由边界层写入 |
| 3 | 左键单击编辑名称 / 下拉框选择名称 | 单击接口元件 → 弹出名称面板（OptionButton：clk / move / rotation） |
| 4 | 电路层不需要实际表现行为 | 接口元件只参与编译与求值，不产生视觉变化 |
| 5 | 存档保存时电路单独存同名 `.swcir` | `save_builds` 成功后导出 `user://saves/<存档名>.swcir`（含全部电路的网表） |
| 6 | 加载 `.swcir` 生成不依赖元件实体的电路对象 | 解析网表 → `SWGateCompiler.compile_netlist` → `SWLogicRuntime`（复用已完成的纯逻辑运行时） |
| 7 | 新主场景：可移动缩放，有地图/hud/手持层/实体层 | 复制 `sw_logic_scene.tscn` 的层结构，建筑层换成实体层 |
| 8 | 实体层实体可自动旋转移动；控制接口：移动一格、旋转90度 | `SWRobotEntity`：`step_forward()`（按朝向移动 1 格）、`rot90()` |
| 9 | 放置机器人元件 | 手持层工具「机器人」，点击落子到实体层 |
| 10 | 左键单击机器人 → 打开已保存电路列表 | 弹出 `.swcir` 列表面板（含接口摘要与校验） |
| 11 | 选择含 clk 输入 + move 输出 + rotation 输出的电路加载 | 按名称校验接口，缺任一接口则该电路置灰不可选 |
| 12 | 所有机器人统一 clk → 运行电路 → 按输出自动移动/旋转 | 固定节拍 tick：`clk=1 → tick() → move? step_forward : rot90` |

---

## 2. 现状盘点（已核实的可复用资产）

| 资产 | 位置 | 复用方式 |
|------|------|---------|
| 纯逻辑运行时 | `circuit/sim/sw_logic_runtime.gd` | `.swcir` 电路对象的执行核心（状态自持，不碰实体） |
| 网表数据层 | `circuit/sim/sw_netlist.gd` | `.swcir` 的序列化载体（CSR 扁平表，PackedInt32Array 直接 JSON 化） |
| 网表导出器 | `circuit/sim/sw_netlist_export.gd` | 电路分组 → SWNetlist 的导出（`export_netlist(builds)`） |
| 网表编译 | `circuit/sw_gate_compiler.gd` | `compile_netlist(netlist)` → SWGateProgram（已有，测试通过） |
| 元件定义资源 | `res/*.tres`（SWBuildDefine） | 新接口元件按 `开关.tres`/`灯泡.tres` 同款结构新增 3 个 `.tres` |
| 元件工厂 | `core/define/sw_define.gd::SWBuildCreator` | 按 buildName 注册新元件类 |
| 电路组件 | `circuit/build_compoent/*` | 输入接口=扩展 Source 组件；输出接口=扩展 LED 组件 |
| 场景层架构 | `scene/sw_logic_scene.tscn` + `core/manager/sw_layer_manager.gd` | 新场景照搬，`SWLayerManager` 按 group "SWLayer" 自动装配 |
| 相机/地图/渲染 | `camera/sw_camera_2d.gd`、`layers/map/*`、`core/manager/sw_draw_manager.*` | 原样复用（移动缩放免费获得） |
| 手持层 | `layers/hold/*` | 复用；信号 `hold_idle_builds` 改接实体系统 |
| 存档 | `core/manager/sw_save_manager.gd` | `save_builds` 流程尾部追加 `.swcir` 导出钩子 |
| UI 面板 | `layers/hud/sw_hud_layer.gd`（代码构建面板） | 名称编辑面板、电路列表面板同款代码构建 |
| 测试基建 | `test/circuit/circuit_test_harness.gd` | 新用例沿用；纯逻辑用例不 boot 场景，更快 |

---

## 3. 关键设计决策

### 3.1 枚举追加约束（硬约束）

`SwDefine.CircuitComponentType` 以整数值序列化进 `res/*.tres`，**新增只能追加末尾**：

```
EXTERNAL_INPUT   = 12   # 外部输入接口（clk）：输出端口，边界层写电平
EXTERNAL_OUTPUT  = 13   # 外部输出接口（move/rotation）：输入端口，边界层读电平
```

`SwDefine.BuildCompoentType` 同样追加：

```
CIRCUIT_EXT_INPUT     # 复用/扩展 SWBuildCompoentCircuitSource 语义
CIRCUIT_EXT_OUTPUT    # 复用/扩展 SWBuildCompoentCircuitLed 语义
```

### 3.2 接口元件的电路语义

- **外部输入（clk）**：输出端口，表达式恒等于自身电平；编译时映射为 `DEV_SOURCE`，电平由外部写入。电路层求值走与按钮相同的 `evaluate()` 路径，只是值来源是边界层而不是按下的状态。
- **外部输出（move/rotation）**：输入端口，`netBit()` 读所连 net 电平；编译时映射为 `DEV_LED` 同类（只读 net 不驱动），但**不进 LED 分组**——它是逻辑读取点而非显示元件。
- 元件本身**不产生任何视觉行为**（没有 on/off 帧切换）。
- 名称是**实例属性**（存在建筑实例上，随存档序列化），不是元件定义属性。同一类元件（两个输出型）通过名称区分角色。

### 3.3 名称编辑交互

- 复用 hold 系统的悬停链路，新增「点击已有建筑」事件：`holdSystem` 在非工具点击（没有手持放置物）且命中接口元件时发 `edit_build_requested(build)`。
- HUD 弹出名称面板：`OptionButton`（选项：`clk`、`move`、`rotation`）+ 关闭按钮。改动即时写回实例字段并标记渲染文本刷新。
- 默认名：输入型 = `clk`；输出型定义 A = `move`、定义 B = `rotation`（两个 `.tres` 定义，图标可暂用同一图集帧）。

### 3.4 `.swcir` 文件格式（JSON）

```
user://saves/<存档名>.swcir
{
  "version": 1,
  "source_save": "<存档名>",
  "circuits": [
    {
      "index": 0,                       # 该存档内的电路序号
      "inputs":  [{"name": "clk", "net_id": 12}],     # 外部输入接口（名称唯一）
      "outputs": [{"name": "move", "net_id": 5},
                  {"name": "rotation", "net_id": 7}], # 外部输出接口
      "sources": [{"dev": 3, "level": 1}],         # 源元件初始电平（开关/按钮按下、时钟电平）
      "netlist": {                      # SWNetlist 扁平表直出
        "dev_kind": [], "dev_out_mask": [], "dev_in_mask": [],
        "dev_pins": [], "dev_clk_net": [], "dev_d_net": [],
        "net_ids": [], "net_driver_flat": [], "net_driver_offs": [],
        "net_load_flat": [], "net_load_offs": []
      }
    }, ...
  ]
}
```

- 只导出**含接口元件**的电路分组（`circuit.buildArr` 里有 EXTERNAL_INPUT/EXTERNAL_OUTPUT 的才进文件）；无接口电路的存档不生成 `.swcir`。
- `sources` 段存**每条电路里每个源元件的上电电平**（`dev` 为 netlist 元件下标）。机器人侧没有世界可读，不存这一段则加载后内部开关/按钮/时钟全部为 0：把开关当常量 1 用的电路（如带使能端的计数器）会整片恒 0，表现为「绑了电路但机器人不动」。老文件缺这一段时按 0 处理（`build_bundle` 打 warning 提示重新保存）。
- 接口 dev 的识别靠 netlist 里新增两列元数据（见 3.5），net_id 即该 dev 输出/输入所连 net 的 id。
- 加载粒度：**只允许加载含且仅含 1 条电路的 `.swcir`**；含多条电路的文件在机器人面板中置灰标注「电路不可用」。

### 3.5 SWNetlist 扩展

新增两列（与现有 PackedInt32Array 风格一致，不破坏既有导出）：

```
var dev_role := PackedInt32Array()   # 0=内部 / 1=外部输入接口 / 2=外部输出接口
var dev_label := PackedInt32Array()  # 名称表下标；name_table 为 PackedStringArray
```

`SWNetlistExport` 遇到接口元件时填 role 与 label；`compile_netlist` 对 role=1 按 `DEV_SOURCE`、role=2 按 `DEV_LED` 处理（**不加入 LED 渲染分组**）。运行时层（3.6）用 name ↔ slot 映射暴露接口。

### 3.6 纯逻辑电路对象：SWCircuitBundle（新增，`circuit/sim/`）

`.swcir` 加载产物，一层薄封装，**零实体依赖**：

```gdscript
class_name SWCircuitBundle extends RefCounted
# 静态：SWCircuitBundle.from_netlist(netlist, inputs, outputs) -> SWCircuitBundle
var runtime: SWLogicRuntime          # setup(prog) 完成
var input_slots: Dictionary = {}     # name -> 源 slot（写入口）
var output_nets: Dictionary = {}     # name -> net slot（读出口）
func set_input(name: String, level: int) -> void
func tick() -> SWSimResult            # 带差分结果（电路场景/表现层用）
func tick_fast() -> void              # 只推进状态（机器人每拍 2 次走它）
func output_level(name: String) -> int   # 0/1
func has_input(name) / has_output(name)
```

- 加载路径：JSON → 重建 `SWNetlist` 各 PackedInt32Array → `SWGateCompiler.compile_netlist` → `SWLogicRuntime.setup` → 按接口表的 net_id 反查 slot 建立 name 映射。
- 该对象即为「不依赖元件实体运行的电路对象」，机器人持有它。

### 3.7 新主场景结构（`scene/sw_robot_scene.tscn`）

照搬 `sw_logic_scene.tscn`，改动点：

```
SWRobotScene (Node, 脚本 sw_robot_scene.gd)   ← 默认主场景（project.godot 的 run/main_scene）
├─ SWLayerManager            # 复用，自动装配
│  ├─ SWMapLayer             # 复用（含 SWDrawManager/Tiling + SWRenderNode）
│  ├─ SWHudCanvasLayer → SWRobotHudLayer   # 新建：代码构建工具栏（机器人/切换入口）
│  ├─ SWEntityLayer          # 新建：实体层（Node + SWLayer，同 SWBuildLayer 模式）
│  │  └─ SWDrawManager(useName="Entity")   # 实体用 DrawManager 渲染
│  └─ SWHoldLayer             # 复用：手持层（工具=机器人），信号改接实体系统
├─ SWCamera2D                # 复用
└─ SWRobotTick               # 新建：统一节拍驱动器（Node，见 3.8）
```

- 场景入口：**机器人场景设为默认主场景**（`project.godot` 的 `run/main_scene` 指向 `scene/sw_robot_scene.tscn`）；电路场景（原 `sw_logic_scene.tscn`）通过机器人 HUD 上的「电路场景」按钮切换进入。
- `SWRobotScene._init` 与 `SWLogicScene` 同样初始化 `SWStyleTexture/SWSignalTexture` 单例（两场景互斥切换，退出时按原逻辑清理重建）。
- `SWEntityLayerSystem`（新建）参照 `SWBuildLayerSystem` 的职责裁剪：放置（响应 `hold_idle_builds`）、实体表、点击命中（`_cell_probe` 注入）、删除；不做电路重建。

### 3.8 机器人实体与统一 tick

```gdscript
class_name SWRobotEntity extends RefCounted
var grid_pos: Vector2i      # 世界格坐标
var dir: int                # 0..3 朝向
var bundle: SWCircuitBundle # 绑定电路（可空）
func step_forward() -> void # grid_pos += dir_to_vec(dir)，越界/被占则不动
func rot90() -> void        # dir = (dir + 1) % 4
```

- 统一节拍 `SWRobotTick`（`_physics_process` 内累计计时，默认每 **250ms** 一拍，常量可调）：
  1. **一拍 = 一个完整时钟周期，必须跑两个相位**：先 `clk=0` → `tick()`（寄存器只更新 `last_clk`，不锁存），再 `clk=1` → `tick()`（这才是 0→1 上升沿，锁存 D，输出在此之后才稳定）
  2. 读 `bundle.output_level("move")` = 1 → `step_forward()`；`output_level("rotation")` = 1 → `rot90()`
  3. `clk` 收回 0，下一拍重新走 0→1
  4. 渲染脏标记 → 实体层刷新绘制
- 一拍又拆成**两个时间点**发出去（时序图需要）：`step_beat_high()` 在拍首（锁存 + 读输出 + 落高相位样本，
  **不动作**），`step_beat_low()` 在半拍后（`clk` 回落 + 才真正旋转/移动 + 落低相位样本）。
  `step_beat()` = 两者连跑（原子口径，测试与「步进」按钮走它）。两个相位之间的待办存在实体系统的 `_pending_act` 里，
  半拍内被删的实体会被摘掉（不能让已删实体半拍后动起来）。
- ⚠ 只跑高相位（置 1 → tick → 置 0 不 tick）会让 `last_clk` 永远停在 1：只有寄存器的电路（计数器）永远看不到上升沿，电平整拍恒 0，表现为「机器人不动也不转」；而纯组合电路（clk 直连输出）看着正常，所以只靠组合电路测不出这个缺陷。
- 「所有机器人统一调用输入 clk」：所有机器人在同一拍、以同一 clk=1 输入跑各自电路，互不干扰（各持独立 SWLogicRuntime 状态）。
- 移动方向语义：**按实体当前朝向**前进一格（`rotation` 输出为 1 时转 90°）。旋转先于移动执行（同一拍内 `rot90` 在 `step_forward` 之前）。
- **多机器人性能口径**（几十台挂电路时 Physics 帧会爆，实测 50 台 × 17 条子电路曾到 46.6 ms/拍）：
  1. 机器人侧走 `tick_fast()`：`tick()` 的差分打包（新建 `SWSimResult` + 扫全部 net/灯泡组/寄存器 + 广播信号）机器人侧没人读，却占 tick 时间的大头；
  2. `.swcir` 常含十几条分组，`SWCircuitSet` 把「接口名 → 子电路下标」建成索引：`set_input` / `output_level` / `has_output` 只碰真正持该接口的那几条，不再广播给全部子电路；
  3. 纯组合子电路（`prog.reg_slots` 为空）输入没变就跳过 tick：一拍两个相位里只有高相位前写过输入，低相位那次重算必然同结果（寄存器电路照旧每相位 tick）；
  4. `output_names()` 的排序结果、`detect_res_*` 口名都缓存，不每拍现拼字符串；
  5. `step_beat_high` 正常路径只查 `SWRobotActions.TABLE` 里登记的动作名（3 个），不再每拍遍历电路全部输出名；开 `debug_print_circuit` 时退回全量打印。
  实测同规模 46.6 → 6.1 ms/拍。

### 3.9 机器人电路绑定面板

- 单击机器人（hold 系统点击命中实体层）→ 弹出面板：
  - 列出 `SWCirManager.list_circuit_files()` 的所有 `.swcir` 文件；
  - 每个文件显示接口摘要（`in: clk` / `out: move, rotation`）；**含多条电路的文件置灰标注「电路不可用」**；接口不齐的同样置灰；
  - 选择 → `SWCirManager.load_circuit(file)` → 绑定到该机器人 → 关闭面板。
- 面板复用 `ui/sw_load_dialog.tscn` 的视觉风格（代码构建，不新增场景资源）。

---

## 4. 分阶段实施

### 阶段 1：电路层接口元件 + 名称编辑

| 动作 | 文件 |
|------|------|
| `CircuitComponentType` / `BuildCompoentType` 枚举追加 | `core/define/sw_define.gd` |
| 接口元件电路组件：`CIRCUIT_EXT_INPUT`（source 语义）、`CIRCUIT_EXT_OUTPUT`（led 语义，不进 LED 分组） | 新增 `circuit/build_compoent/sw_build_compoent_circuit_ext_io.gd` |
| 元件建筑类：`SWBuildExtInput`、`SWBuildExtOutput`（含 `io_name` 实例字段、`save_state/load_state`） | 新增 `circuit/build/sw_build_ext_io.gd` |
| 工厂登记 3 个名称 | `core/define/sw_define.gd::SWBuildCreator` |
| 3 个定义资源（图标暂复用图集现有帧） | 新增 `res/输入接口.tres`、`res/输出接口move.tres`、`res/输出接口rotation.tres` |
| 主场景 HUD 工具栏加 3 个工具按钮 | `layers/hud/sw_hud_layer.tscn` + `.gd` |
| hold 系统「点击已有建筑」事件 + HUD 名称编辑面板（OptionButton） | `layers/hold/sw_hold_layer_system.gd`、`layers/hud/sw_hud_layer.gd` |
| 存档往返：`io_name` 序列化 | `core/manager/sw_save_manager.gd`（builds 条目加 `io_name`） |
| 编译兼容：接口元件进网表/表达式路径不出错 | `circuit/sw_gate_compiler.gd`（如需要） |

验收：电路层放置 3 元件、单击改名、连上非门/灯泡后求值正确、存档读档名称保留。

### 阶段 2：`.swcir` 导出与加载

| 动作 | 文件 |
|------|------|
| SWNetlist 增加 `dev_role` / `dev_label` / `name_table` | `circuit/sim/sw_netlist.gd` |
| 导出器识别接口元件填 role/label；输出接口不混入 LED 分组 | `circuit/sim/sw_netlist_export.gd` |
| `.swcir` 管理器：export_all / list_circuit_files / load_circuit（JSON 序列化+解析） | 新增 `circuit/sw_cir_manager.gd` |
| SWCircuitBundle（3.6） | 新增 `circuit/sim/sw_circuit_bundle.gd` |
| `SWSaveManager.save_builds` 尾部钩子（由 `SWLayerManager._on_save_requested` 调用 `SWCirManager.export_all`，不改 SWSaveManager 签名） | `core/manager/sw_layer_manager.gd` |

验收：保存含接口电路存档 → 生成同名 `.swcir`；`load_circuit` 后 `bundle.tick()` 与实体电路对拍一致（clk 输入 → move/rotation 输出正确）。

### 阶段 3：新场景 + 实体层 + 机器人

| 动作 | 文件 |
|------|------|
| 实体数据：`SWRobotEntity`（3.8） | 新增 `scene/entity/sw_robot_entity.gd` |
| 实体层 + 实体系统（放置/命中/删除/绘制） | 新增 `scene/entity/sw_entity_layer.gd`、`sw_entity_layer_system.gd` |
| 机器人场景 + HUD（工具栏、切换入口） | 新增 `scene/sw_robot_scene.gd`、`scene/sw_robot_scene.tscn`、`layers/hud/sw_robot_hud_layer.gd`（代码构建 UI） |
| hold 层信号接线（放置 → 实体系统） | `scene/sw_robot_scene.tscn` |
| 节拍驱动器 `SWRobotTick` | 新增 `scene/sw_robot_tick.gd` |

验收：进入机器人场景可移动缩放地图；HUD 选「机器人」点击放置；单击选中；实体渲染正常。

### 阶段 4：电路绑定与统一驱动

| 动作 | 文件 |
|------|------|
| 电路列表/接口校验面板（3.9） | `layers/hud/sw_robot_hud_layer.gd` |
| 绑定与 tick 驱动（3.8 步骤） | `scene/sw_robot_tick.gd`、`scene/entity/sw_entity_layer_system.gd` |

验收：保存「计数器 + 接口」存档 → 机器人场景放机器人 → 单击选电路 → 所有机器人随 clk 节拍按电路结果移动/旋转。

### 阶段 5：测试与回归

按 `.qoder/rules/testing.md` 单文件跑法（`-gprefix=`）：

| 用例 | 覆盖 |
|------|------|
| `test_ext_io_port.gd` | 接口元件默认名、改名、下拉选项、存档往返（复用 harness 小存档） |
| `test_swcir_bundle.gd` | 导出→加载往返字段一致；`bundle.set_input("clk",1) → tick` 输出与实体电路对拍；缺接口校验 |
| `test_robot_runtime.gd` | 纯逻辑：机器人 step_forward/rot90 语义；绑定电路 tick N 拍后位置/朝向断言 |
| `test_robot_scene.gd` | 场景 boot 冒烟：进入场景、放置机器人、绑定电路文件、跑一拍（headless 下 GPU/RD 报错属环境噪声） |

回归：`test_circuit_led`、`test_cpu_flat`、`test_netlist_compile`、`test_logic_runtime`（本次改动触达的既有链路）。

---

## 5. 文件清单汇总

**新增**
```
circuit/build_compoent/sw_build_compoent_circuit_ext_io.gd
circuit/build/sw_build_ext_io.gd
circuit/sw_cir_manager.gd
circuit/sim/sw_circuit_bundle.gd
scene/sw_robot_scene.gd / sw_robot_scene.tscn
scene/sw_robot_tick.gd
core/manager/sw_session.gd
layers/hud/sw_timing_scope.gd
scene/entity/sw_robot_entity.gd
scene/entity/sw_entity_layer.gd / sw_entity_layer_system.gd
layers/hud/sw_robot_hud_layer.gd
res/输入接口.tres / res/输出接口move.tres / res/输出接口rotation.tres
test/circuit/test_ext_io_port.gd / test_swcir_bundle.gd / test_robot_runtime.gd / test_robot_scene.gd
```

**修改**
```
core/define/sw_define.gd              # 枚举 + 工厂
circuit/sim/sw_netlist.gd             # dev_role/dev_label/name_table
circuit/sim/sw_netlist_export.gd      # 接口识别
core/manager/sw_save_manager.gd       # io_name 序列化
core/manager/sw_layer_manager.gd      # 保存钩子
layers/hold/sw_hold_layer_system.gd   # 点击已有建筑事件
layers/hud/sw_hud_layer.gd / .tscn    # 工具栏 + 名称面板
circuit/sw_gate_compiler.gd           # 接口 dev 处理（如需）
```

---

## 6. 风险与注意

1. **枚举顺序**：`CircuitComponentType` 只能追加末尾（3.1），历史 `.tres`/存档的数值语义不能被改写。
2. **输出接口与 LED 渲染耦合**：输出接口复用 LED 组件语义时必须绕过 LED 分组（`led_comps`/GPU LED 表），否则灯泡分组会把它当显示元件。规划用 role 区分（3.5）。
3. **电路分组粒度**：一条「电路」= `circuit.buildArr` 一个连通分组。含接口元件才会被导出；同一存档多条电路 → 一个 `.swcir` 内多条记录，机器人面板展开选择。
4. **电线隧道/桥梁**：netlist 导出对隧道/桥梁的等价处理已有测试覆盖（`test_netlist_compile` 5 存档对拍），新元件不改动此路径；如发现接口元件与隧道相邻的极端拓扑问题，单独修导出器。
5. **交互冲突**：现有 hold 点击用于放置/删除；「单击编辑」只在**空手持**（无放置物）时触发，避免与放置操作冲突。
6. **图集资源**：新元件图标先复用现有图集帧占位；正式贴图后续补（`atlas/图集*.png` 加帧即可，不阻塞逻辑）。
7. **双场景单例**：`SWStyleTexture/SWSignalTexture/SWObjectPool` 在 `_init` 创建；机器人场景为默认主场景，两场景经 HUD 按钮互斥切换，退出时按 `SWLogicScene._exit_tree` 同款清理。
8. **节拍可调**：`SWRobotTick` 的 250ms 常量集中定义，测试里可注入更短节拍加速断言。

---

## 7. 待确认决策点（实施时可调整，默认值已给出）

| 决策 | 确认结论 |
|------|------|
| 同一拍内 move 与 rotation 同时为 1 的执行顺序 | 先旋转后移动 |
| 移动方向 | 按机器人当前朝向 |
| 机器人 tick 节拍 | **250ms / 拍**（常量可调） |
| `.swcir` 多电路组织 | 仍导出为一个文件；**含多条电路的文件在面板中显示「电路不可用」**，不可加载 |
| 接口名称下拉选项 | 固定三选：clk / move / rotation（不含自定义文本） |
| 新场景入口 | **机器人场景为默认主场景**（`project.godot` 主场景改指 `sw_robot_scene.tscn`）；电路场景由 HUD 按钮切换进入 |

---

## 8. 迭代补充：改电路 / 存档名回填 / 场景状态 / 时序图

### 8.1 「修改电路」按钮（绑定面板）

绑定面板底部新增「修改电路」：把列表里选中（或机器人已绑定）的电路文件记进
`SWSession.pending_load_save`，然后切到电路场景。

- `.swcir` 与存档同名，所以**电路文件名就是存档名**，进电路场景后直接读这个存档；
- `SWLogicScene._ready` 用 `call_deferred("_load_pending_save")` 消费这个意图，
  调 `SWLayerManager.load_save_by_name()`；成功后 `take_pending_load()` 清空，不会二次触发；
- 拆成 `prepare_edit_circuit()`（只记意图，返回目标存档名）与 `request_edit_circuit()`（记意图 + 切场景）：
  用例里切场景会把整棵测试树换掉，只能跑前半步。

### 8.2 当前存档名：加载时记录、保存时回填

- `SWSession.current_save_name`（静态变量）跨场景存活；`SWLayerManager.current_save_name` 是它的属性代理；
- 读档成功（`load_save_by_name`）与存盘成功（`_on_save_requested` 的成功分支）都更新它；
- 保存对话框新增 `SWSaveDialog.set_default_name()`：`_ready` 之前调用只存字段（此时 `@onready` 还是 null），
  `_ready` 里再落到输入框并**重跑一遍名称校验**——否则确认按钮仍是禁用的，看起来像回填失败。

### 8.3 机器人场景状态：切出记录、返回重载

- 状态 = `[{x, y, dir, circuit}]` 列表，落在 `user://saves/_robot_scene.json`（**全局单份**，与存档名解耦）；
- `SWRobotScene._exit_tree` 调 `entity_system.save_state()`，`_ready` 在 `_wire_entity_layer()` 之后调 `load_state()`；
- 只存摆位不存电路状态：`bundle` 由 `.swcir` 重新加载，重存旧网表会把玩家刚在电路场景改好的电路盖回去；
- 电路文件被删/改坏时保持未绑定（机器人还在，只是不跟拍），比整台消失好；
- 子节点的 `_exit_tree` 比父节点先跑，所以父节点里 `entity_system` 引用仍然有效（只是 `systems_by_view` 表被清了）。

### 8.4 电路时序图

- 数据：`SWRobotEntity.timing` **每拍追两条** `Vector4i(clk, move, rotation, acted)`，
  高相位（`clk=1`，电路收到时钟沿，**拍首**）+ 低相位（`clk=0`，下降沿，**半拍后**），
  上限 `TIMING_CAP = 320` 条（160 拍）；
- 两条样本**分两个时间点落盘**：`step_beat_high()`（拍首，锁存 + 读输出 + `push_phase_high()`）
  与 `step_beat_low()`（半拍后，`clk` 回落 + 执行旋转/移动 + `push_phase_low()`）；
  `SWRobotTick._physics_process` 每 `period/2` 交替发这两个相位。
  **一次写两条的话红线一拍跳两格，看上去永远停在上升沿上、下降沿被跳过** ——
  拆开之后两个边沿都会依次流到红线位置；`step_beat()` 保留「一拍跑完」的原子口径（测试 / 步进按钮）；
- 只记高相位的话 clk 轨永远恒 1，看不出「0 的那段」，波形也不像时钟——这是更早一次改动的原因；
  `move/rotation` 两条相同（本拍输出结果，整拍不变），`acted` 只有低相位那条可能为 1
  （动作在下降沿相位才执行）；`timing_beats` 只由低相位递增，`timing_seq` 是样本序号；
- `acted` = 本拍真的动了/转了。`move=1` 但前面被别的机器人挡住时 `acted=0`，
  用来区分「电路没输出」与「输出对了但走不了」；
- 观测对象由 `SWEntityLayerSystem.get_timing_entity()` 决定：优先选中的，其次第一台绑了电路的；
  HUD 只拿一个 `Callable`，不直接持有实体系统（沿用绑定面板的解耦做法）；
- 绘制在 `SWTimingScope`（纯 `Control`，`_draw` 画四条轨：clk / move / rotation / act），
  一拍两格（`COL_W = 8`）；靠 `timing_seq` 判断有没有新样本
  （不能只看「样本数 + 末条」：样本封顶后两拍输出完全相同时两者都不变，波形会看着卡死）；
- **红线（游标）钉在右端不动，波形从它下面往左流**：最新一格的右边界固定在游标列，
  还没流完的那半拍只画一部分（宽度 = `_frac * COL_W`，`_frac` 由 `SWRobotTick.get_phase_frac()`
  每帧推给 `set_samples()`）。所以最新的边沿**先在红线位置冒出来**，再往左流走，
  上升沿与下降沿都能在红线处被看到；停着时 `_frac = 1`，最后一格是完整的（不会缩成一条线）；
  历史格子整格宽，窗口最左那一格会被切掉半截（按 `LEFT_PAD` 裁剪）；
- clk 轨：**整格电平**（高相位格整格高、低相位格整格低）→ 规整方波，占空比 50%，
  与数据 1:1 两相严格对应；早期曾把高相位格画成「前半格低、后半格高」的窄脉冲，
  占空比变成 25%，既不真实也让人怀疑波形错了，已改回整格；
  能看出在走靠的是高低交替 + 刻度线 + 游标，不需要窄脉冲（底色是**纯灰**，见下）；
- clk **边沿不另加标记**：上升沿/下降沿就是方波自己的跳变竖线（与 move/rotation/act 同一条画法，
  用本轨色、2px），不画方向三角、不另换颜色。曾经试过在每个跳变处叠 ▲/▼ 三角并分色，
  结果波形被挡得看不清，用户明确要求改回**素线**；电平高低本身已经能分出是哪个沿，
  再靠红线（游标）逐格滚过去就看得见两个边沿依次经过；
- 跳变竖线的前驱取 `_samples[i-1]`（**全局样本索引**，不是窗口内下标），
  所以样本溢出窗口时最左那一格的跳变也画得出来（老写法 `if i > start` 会把它漏掉）；
- `get_clk_edge(i)`（`+1` 上升 / `-1` 下降 / `0` 无边沿）与 `count_clk_edges(kind)` 保留下来
  供测试与诊断用，**不再参与绘制**；`edge_draw_count` 统计的是画过多少条 clk 跳变竖线；
- 时间栅格：底色是**纯灰**（`BG_COLOR`，不带纹条）——曾经按拍号奇偶叠浅底色做交替色块，
  用户要求改为纯灰：纹条会和波形跳变竖线混在一起，容易把格子边界当成信号边沿；
  每 `TICK_EVERY`（4）拍在拍首格画一根刻度线，右端一根游标（红线）——
  “看得出在走”的参照物全部交给这两样；
  相位按**全局样本号**（`_base_seq = timing_seq - 样本数`）算，不按窗口内下标，否则窗口滑动时栅格会跳；
  刻度/游标/波形全部走同一个 `_cell_bounds(i, n, x_now)`：三者的 x 必须一致，
  否则最新一格缩进来时刻度会和波形错位；
- footer 的 `beats` 用 `timing_beats`（累计拍数），`win` 才是封顶的窗口拍数；
- 入口是底部工具栏「时序图」按钮，默认关；关掉时清空样本，`_process` 里零开销。

clk 边沿的验收（`test/circuit/test_robot_scene.gd`）：

- `test_timing_scope_marks_clk_edges`：样本 `1,0,1,0,1,0` → `get_clk_edge` 在 1/3/5 为 `-1`、
  在 2/4 为 `+1`、在下标 0 与越界处为 `0`；`count_clk_edges(±1)` 分别是 2 / 3；
  同时锁住 **`_draw_clk_edge` 不再存在**（不准再给 clk 加三角标记）；
- `test_timing_scope_marks_edge_at_window_start`：样本溢出窗口时，窗口首格的边沿不能被丢；
- 打开面板跑两拍后断言 `edge_draw_count > 0`（跳变竖线真的落到了画布上，不是只有接口没画）。

逐格推进的验收：

- `test_robot_runtime.test_tick_splits_beat_into_two_phases`：半拍只落一条高相位样本且机器**还没动**，
  再过半拍才动作、落低相位样本、`timing_beats` 才加一；`get_phase_frac()` 随物理时间推进、停住时为 1；
- `test_robot_scene.test_timing_scope_cursor_stays_put_while_wave_flows`：`_cell_bounds` 在相位 1 与 0.25
  下右边界不变（红线钉住）、最新一格宽度按相位缩、上一格右边界紧接最新一格左边界（波形不断开）；
  停住时 HUD 推给控件的相位必须是 1。

### 8.5 时序面板的「运行 / 暂停 / 步进」

面板里波形下面一行三个按钮，控制的是机器人场景唯一的时钟 `SWRobotTick`：

- 「运行」→ `SWRobotTick.resume()`（`enabled = true` + `reset_clock()`）；
- 「暂停」→ `SWRobotTick.pause()`（`enabled = false` 且清 `_acc`：暂停期间攒的时间不能在恢复时变成一串补拍）；
- 「步进」→ `SWRobotTick.step_once()`：**先暂停再走一拍**，所以表现出来是「走一步然后停住」；
  返回本拍移动的机器人数（`-1` = 没绑实体系统）；HUD 随后立即 `refresh_timing()`，
  点一下波形就多一拍（两个相位两条样本，两格）；
- 按钮是否置灰跟着真实运行态走（运行中「运行」禁用、暂停中「暂停」禁用），
  每帧 `_process` 同步一次，外部脚本改了 `enabled` 也能对上；
- 解耦方式与实体系统一致：场景根 `set_tick_provider(Callable(self, "_get_robot_tick"))` 注入取用口，
  HUD 只拿到节拍器节点后 `call("resume"/"pause"/"step_once")`，不依赖它的静态类型。

### 8.6 机器人移动、旋转与选中的动画过渡

机器人是走 `SWDrawManager(useName="Entity", ByContent)` 烘焙的：一个 chunk 一个 MultiMesh，
位置和朝向在 `_buildContent` 里就烤进实例数据了，**没有「某台临时换位置 / 转个角度」的接口**。
所以动画必须另开一条路。

**移动滑块 + 旋转插值**（`scene/entity/sw_entity_visual.gd`）

- 语义不动：`SWEntitySystem.move_entity` / `rotate_entity` 当场就改 `grid_pos` / `dir` / `draw_item.rotation`
  — 「一拍走一格、转一格」的逻辑与测试完全不受动画影响，变慢的只是**看起来**走过去 / 转过去；
- 要动的那一台先**从烘焙层撤下**（`detach_render` = `delBuilds` + 复原 `buildState` + 记入 `_detached`），
  由 `SWEntityVisual` 用一个独立的小 MultiMesh（复用 `sw_multi_mesh_instance_2d.tscn`，同 shader / 同 QuadMesh，
  所以滑块和烘焙出来的那台逐像素一致）每帧 `writeInstances(...)` 按插值坐标重写实例；
- **撤下后不再交还烘焙层**（`attach_render` 只在视觉层拒接时兜底）。交还要走 `addBuild` → 区块重建，
  而区块重建是分帧的，中间会有一两帧两层都没画这台；选中的那台有光框撑着看不出来，
  未选中的看上去就是「闪一下瞬移」。代价只是这几台不再享受烘焙层「内容不变就不重写」，
  而它们本来每拍都在动 —— 顺带还把每拍的区块重建次数从 2 降到 0（只有首次接管时 1 次）；
- 移动：`MOVE_SEC = 0.16s`（节拍 250ms，留出停顿才看得出「跳格」），smoothstep 缓动；
  连续移动时把 `from` 取成**当前插值位置**，不跳变；
- 旋转：`ROTATE_SEC = 0.20s`（90° 转太快看不出来）。烘焙出来的基向量是整倍数朝向，
  所以渲染时在实例基上再补一个**增量角** `_rotate_range()`：沿顺时针扫描角取
  `fposmod((to - from) * 90, 360)`（过 0 不绕远路），起点补角 = `-sweep`（看起来是旧朝向），插到 0 就是新朝向；
  同时把实例原点绕**格子中心**旋转，转完原点严丝合缝回到烘焙值；
- 缓冲布局：`[0]=t.x.x [1]=t.y.x [3]=原点x [4]=t.x.y [5]=t.y.y [7]=原点y`。
  两个分量在**同一列**上（`t.x = (buf[0], buf[4])`），按行读会写出镜像的基；
- `_detached` 是唯一依据：`remove_entity` / `clear_entities` 必须先查它，否则会对同一个建筑 `delBuilds` 两次（会 `assert`）；
- 逐帧推进由 `SWEntityLayerSystem.frame(delta)` 转给 `SWEntityLayer.advance_visual`（系统 `receives_frame = true`），
  视觉层**不自己开 `_process`**，这样 headless 测试可以直接 `sys.frame(0.2)` 把动画走完；
  全静止时不重写实例缓冲（零开销）；
- 没有视图（纯逻辑测试 / 未装配）时 `_start_move_anim` / `_start_rotate_anim` 返回 false，
  退回原来的 `_reslot` 一拍了事。

**选中光框**

- 烘焙层那套照旧（`buildState.state = SELECTED` 改 `mask_color`），另外在 `SWEntityVisual._draw` 里叠一圈光框：
  进场 140ms 从 1.3 倍收到 1.0 倍、之后按 1.1s 周期呼吸、取消选中 120ms 淡出；四角加粗勾边（一格只有 32px，细框会糊）；
- 光框不走进烘焙层：要呼吸/淡出就得逐帧重画，走烘焙意味着每帧重建区块；
- 被接管的那几台，选中底色是烘进实例 `tint` 的，所以 `set_glow` 里必须顺手 `_sync_mesh()` 重写一次，
  否则点在动画层里的机器人会「选中了但没变色」；
- 选中那台正在滑/转时，光框画在**插值位置**上（跟着滑块走）；`_mm.show_behind_parent = true` 保证光框压在滑块之上。

**验收**（`test/circuit/test_robot_scene.gd`）：

- `test_move_slides_even_when_not_selected`：不选中也有动画（动画层 `visible_instance_count > 0`、
  半程位置卡在两格之间）+ 逻辑位置立刻到位 + 滑完仍留在动画层且不再入烘焙层 + 连续第二格从当前位置续上；
- `test_rotate_plays_angle_transition`：`item.rotation` 当场变新朝向，补角从 -90° 插到 0，只转向不移动也走动画层；
- `test_removing_robot_mid_slide_is_safe`：动画没走完就删（不能再 `delBuilds` 一次），实例缓冲要清空；
- `test_selection_shows_animated_glow`：选中后有光框并逐帧重绘、取消后先淡出再消失。

真实渲染后端（非 headless）另验过：`visible_instance_count == 1`、旋转起点基向量 = 单位矩阵（旧朝向）、
中点 45°、终点 90°，原点全程不漂。headless 是 dummy 后端，`MultiMesh.set_buffer` 布局错了也不报错，
布局类改动必须真机验一次。

