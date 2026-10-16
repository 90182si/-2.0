# SPEC-02 · 电路扁平 IR 编译与 Verilog 导出（M1~M3 / T2.1~T2.7）

> 面向 AI 实施的决策完备规格。所有"现状锚点"均来自当前代码，实施前请重新核对行号（代码可能已演进）。
> 全局约束见主文档《大改造技术方案.md》§0.4 AI实施规约。
>
> **分层归属（强制，见主文档 §5）**：
> - `circuit/sw_bool_program.gd`、`circuit/sw_bool_compiler.gd` → **L1 领域层**：纯逻辑，禁止引用 RenderingServer/Image/Thread/任何 Node。与渲染/存档的全部交接只经数据快照（指令数组、slotMap）。
> - `SWCircuitStruct`/`op` 枚举改动 → **L0/L1 数据结构**：不在枚举中间插值。
> - `circuit/export/sw_verilog_emitter.gd` → **L2 服务层**：读 IR 快照产出文本，可被工具/UI（L3）调用，不回写任何游戏状态。
> - 收工自检清单见主文档 §5.5，违例（如下层引用上层、第二处推算同一事实）视为缺陷。

---

## 0. 背景与现状锚点

### 0.1 表达式树现状

**`core/define/sw_define.gd`**（约 L126-141）：

```gdscript
class SWBuildPinStruct extends RefCounted:
	var build:SWBuildItemDefine
	var dir:SW_Dir
	func _init(b:SWBuildItemDefine,d:SW_Dir) -> void: ...

class SWCircuitStruct extends RefCounted:
	var optFunc:Callable
	var optFuncName:String
	var args:Array = []          # 元素为 SWBuildPinStruct(叶) 或 SWCircuitStruct(子树)
	var values:Array = []
	var cachedValue:int = -1
	var cachedEpoch:int = -1
```

**`com/sw_common.gd`**（约 L88-149）：
- `static var evalEpoch:int` + `NextEvalEpoch()`：每轮求值自增，`updateBuildCircuit`（L164）与 `buildSignalChanged`（L185）入口各调一次。
- `EvalStruct(cirStruct)`：epoch memo 命中直接返回；否则 `cirStruct.optFunc.call(cirStruct.args)` 并写回缓存。
- `AndValues`：对 args 顺序 `v = EvalStruct(arg)` 后逐个 `v &= ...`（线与语义，N 元 AND）。
- `NotAndValues`：同上，返回 `1-v`（N 元 NAND）。
- `NotValues` / `EqualValues`：单参，`arg is SWBuildPinStruct` 时调 `arg.build.getCircuitCompoent().getValue(arg.dir)`（**跨建筑递归点**），`is SWCircuitStruct` 时 `EvalStruct(arg)`。

### 0.2 表达式构建现状（各组件 getBuildExpr）

| 组件 | 文件 | 构建 |
|---|---|---|
| 时钟/按钮/开关 | `sw_build_compoent_circuit_clock_siggen.gd` / `..._source.gd` | `pinExprMap[rotation] = {EqualValues, args=[PinStruct(self,rotation)]}` |
| 非门 | `sw_build_compoent_circuit_not.gd` L10-39 | 输入方向 net 的 drivers 逐个 `getBuildExpr()` 后 `args.append(expr)`；`_buildingExpr` 为真时标记 `in_loop`（**环检测点**） |
| LED | `sw_build_compoent_circuit_led.gd` | 每输入方向 `{AndValues, args=[各驱动表达式]}` |
| 寄存器 | `sw_build_compoent_circuit_register.gd` | CLK/D/Q 引脚（`CLK_REF/D_REF/Q_REF` 常量），Q 输出对外提供表达式，D 侧按线与组合；**时序屏障** |
| 电线/交叉/隧道 | `..._wire.gd` / `..._wire_cross.gd` / `..._tunnel.gd` | `reCalSignals()` 返回 `[buildRef]`；视觉由 setValue 传播驱动，不自行求值 |

非门 `getExpr(pinDir)`：`portIsOutput(pinDir)` 时返回 `pinExprMap[antiDir]`（**注意取反方向**）。

### 0.3 依赖与级联现状

**`circuit/sw_cirucit_control.gd`**：
- `noticeMap`：key=源建筑，value=直接下游建筑数组（O(边数) 登记，见 getCircuit L140-151）。
- `updateBuildCircuit(builds)`（L156-182）：NextEvalEpoch → `find1`（邻居扩展）→ `clearBuildsCircuitState`（内含 `resetBuildState`，清 in_loop/drawRect）→ `createNets` → `resetEmptyWireNet` → `getCircuit`（登记 noticeMap）→ `createCircuit`（非电线建筑构建表达式）→ 返回 affectBuilds。
- `buildSignalChanged(build)`（L184-204）：沿 noticeMap BFS，逐个 `noticeBuild.getCircuitCompoent().reCalSignals()` 并收集返回数组（含 `[buildRef] + 输入 net 的 wireGroup.wireBuilds`）。
- `reCalSignals()` 基类（sw_build_compoent_circuit.gd L217-225）：返回 `[buildRef] + 各输入 net.wireGroup.wireBuilds.keys()`。

**`circuit/sw_net.gd`**：`curSignal`、`_drivers/_loads`（元素 `{build, pinDir}`）、`wireGroup:SWWireGroup`（含 `wireBuilds:Dictionary`）。

**约定**：drivers 恒为非电线建筑（门/源/寄存器），电线只做透明传输——IR 中电线不生成算子。

---

## 1. T2.1 op:int 单态分派（过渡步，M1）

### 目标
消除 `EvalStruct` 的 `Callable.call` 动态派发与 optFunc 内的 `is` 类型判断。树结构、epoch memo 全部保持不变。

### 改动清单

1. `core/define/sw_define.gd`：新增枚举（**追加在文件末尾已有枚举之后，严禁插入既有枚举中间**）：
   ```gdscript
   enum CircuitOp { OP_AND, OP_NAND, OP_PASS, OP_NOT, OP_LEAF }
   ```
2. `SWCircuitStruct` 增加字段：`var op:int = -1  # CircuitOp，-1 表示未迁移`。
3. `com/sw_common.gd`：重写 `EvalStruct`：
   ```gdscript
   static func EvalStruct(cirStruct:SwDefine.SWCircuitStruct) -> int:
       if cirStruct == null: return 0
       if cirStruct.cachedEpoch == evalEpoch: return cirStruct.cachedValue
       var v:int = 0
       if cirStruct.op != -1:
           match cirStruct.op:
               SwDefine.CircuitOp.OP_LEAF:
                   v = EvalLeaf(cirStruct.args[0])   # args[0] 归一化为叶
               SwDefine.CircuitOp.OP_PASS:
                   v = EvalArg(cirStruct, 0)
               SwDefine.CircuitOp.OP_NOT:
                   v = 1 - EvalArg(cirStruct, 0)
               _:
                   v = EvalArgsAnd(cirStruct)        # AND / NAND 公共：顺序归约
                   if cirStruct.op == SwDefine.CircuitOp.OP_NAND: v = 1 - v
       else:
           v = cirStruct.optFunc.call(cirStruct.args)   # 兼容兜底，迁移完删除
       cirStruct.cachedEpoch = evalEpoch
       cirStruct.cachedValue = v
       return v
   ```
   配套私有静态函数：
   - `EvalArg(parent, i)`：取 `parent.args[i]`，若为 `SWCircuitStruct` 则 `EvalStruct`；若为 `SWBuildPinStruct` 则 `EvalLeaf`。
   - `EvalLeaf(pinStruct)`：`pinStruct.build.getCircuitCompoent().getValue(pinStruct.dir)`，HIGH→1 否则 0。集中在此一处，替代散落的 `is` 判断。
   - `EvalArgsAnd(parent)`：`var v = EvalArg(parent, 0)`，从 1 循环 `v &= EvalArg(parent, i)`（保持 AndValues 的短路语义等价：原实现首参必算、后续短路可留待 T2.5 再优化，此处不改变求值顺序）。
4. 各组件 `getBuildExpr` 同步赋 op（**optFunc 行保留，作为回退保险**）：
   - clock_siggen / source：`op = CircuitOp.OP_PASS`
   - not：`op = CircuitOp.OP_NAND`
   - led / register（线与处）：`op = CircuitOp.OP_AND`
5. `NotAndValues/AndValues/NotValues/EqualValues` 函数体不动（T2.3 对拍仍要用旧路径）。

### 验收
- 命令：`godot --headless -d -s addons/gut/gut_cmdln.gd -gdir=res://test -gexit`（以 .gutconfig.json 为准），全部既有电路测试通过。
- 手测：非门链、线与（LED 多输入）、寄存器反馈环（in_loop 红点）、交叉电线，行为与改前一致。
- 性能面板（performance/sw_performance_monitor.gd）记录 EvalStruct 耗时前后对比，写入 `docs/metrics.md`。

### 回退
op 路径有误时，把各组件 op 改回 -1 即回到 Callable 路径（零删除式回退）。

---

## 2. T2.2 netId 稳定分配（M1）

### 改动清单
1. `circuit/sw_net.gd`：`var netId:int = -1`。
2. `circuit/sw_cirucit_control.gd`：`updateBuildCircuit` 内，`createNets(affectBuilds)` 完成后统一重编号：
   - 新增成员 `var _netIdCounter:int = 0`；
   - 遍历 `affectBuilds` 每个建筑 `pinNetMap.values()` 去重收集 net（用 Dictionary 去重），按收集顺序 `net.netId = _netIdCounter; _netIdCounter += 1`；
   - `clearAllBuilds` / 存档加载时 `_netIdCounter = 0` 重置。
3. 预留钩子（T1.2 用）：`SwCommon.NextEvalEpoch()` 所在文件新增 `static var registeredNetMax:int = 0`；重编号时更新之。

### 验收
- 放置/删除/旋转/存档加载后打印 netId：连续、无 -1 残留（未连 net 的建筑 pinNetMap 为空不算）。
- GUT 全过。

### 注意
- netId 生命周期 = 两次拓扑重建之间；重建会重编号，**这正是改造一几何层重建的同频事件**，两处绑定在同一事务（见 SPEC-01 T1.4）。

---

## 3. T2.3 SWBoolProgram（M2）

### 新文件 `circuit/sw_bool_program.gd`

```gdscript
class_name SWBoolProgram extends RefCounted

# 操作码（与 CircuitOp 对应，另含数据源）
const OP_IN_PIN  := 0   # dst = 叶引脚当前电平（读 provider 表）
const OP_LATCH   := 1   # dst = 寄存器 Q（时序屏障，读 latch 表）
const OP_AND     := 2
const OP_NAND    := 3
const OP_PASS    := 4
const OP_NOT     := 5

var op:  PackedInt32Array
var dst: PackedInt32Array   # 目标 slot
var a:   PackedInt32Array   # 操作数A：slot 下标；OP_IN_PIN/OP_LATCH 时为 provider 下标
var b:   PackedInt32Array   # 操作数B：slot 下标；单目指令填 0
var slotCount:int = 0
var _slots:PackedInt32Array # 复用，禁止每拍 resize（size 相等时跳过）

# provider 表（由编译器填充，IR 只按下标读）
var pinProviders:Array = []   # 元素 {build:SWBuildItemDefine, dir:int}
var latchProviders:Array = [] # 元素 SWBuildItemDefine（寄存器，读其 Q 值）

func evaluate() -> void:
    if _slots.size() != slotCount: _slots.resize(slotCount)
    for i in op.size():
        match op[i]:
            OP_IN_PIN:
                var pv = pinProviders[a[i]]
                _slots[dst[i]] = 1 if pv.build.getCircuitCompoent().getValue(pv.dir) == SwDefine.CircuitSignal.HIGH else 0
            OP_LATCH:
                var lb = latchProviders[a[i]]
                _slots[dst[i]] = 1 if lb.getCircuitCompoent().getValue(lb.rotation) == SwDefine.CircuitSignal.HIGH else 0
            OP_AND:  _slots[dst[i]] = _slots[a[i]] & _slots[b[i]]
            OP_NAND: _slots[dst[i]] = 1 - (_slots[a[i]] & _slots[b[i]])
            OP_PASS: _slots[dst[i]] = _slots[a[i]]
            OP_NOT:  _slots[dst[i]] = 1 - _slots[a[i]]
```

> 说明：OP_IN_PIN/OP_LATCH 仍走 `getValue`（内部读树或 slot 由开关决定），保证过渡期两种后端共享叶读路径；T2.5 完成后叶读统一为 slot/寄存器值。

### 编译器（新文件 `circuit/sw_bool_compiler.gd`）

```gdscript
class_name SWBoolCompiler extends RefCounted
# 输入：全部参与求值的根表达式（各非电线建筑 pinExprMap 的输出 expr）
# 输出：SWBoolProgram + slot 映射（供 getValue/Emitter 查询）
```

编译规则（逐步实现，全部必须遵守）：
1. **节点枚举**：对每棵根树做迭代 DFS（显式栈，禁止递归——GDScript 深链会爆栈），收集所有 `SWCircuitStruct` 节点；`node→slotIdx` 字典去重（**扇出共享 = 同一节点一个 slot**）。
2. **拓扑排序**：按"子节点先于父节点"后序输出指令；跨建筑引用（叶 `SWBuildPinStruct`）指向的目标建筑表达式视为外部输入，生成 `OP_IN_PIN`。
3. **寄存器屏障**：叶引用目标建筑为寄存器（`buildRef is SWBuildCompoentCircuitRegister 所属 build`，即 `circuit_component_type == REGISTER`，判定用 buildDefine 字段而非类名）时生成 `OP_LATCH`——这与游戏内"跨寄存器反馈不判环"策略一致，同时保证 IR 无环。若 DFS 发现**非寄存器环**（visited 命中且不在当前栈回退路径外）→ 编译失败，返回错误并附环上建筑列表（与 Kosaraju 判定互相校验，二者不一致视为 bug 上报）。
4. **N 元门展开**：AND/NAND 的 N 个 args 生成 N-1 条二元指令（a=前值 slot，b=下一 arg slot）；单 arg 的 NAND 视作 NOT，单 arg AND 视作 PASS（编译期化简）。
5. **provider 表去重**：相同 (build,dir) 的叶共享下标。

### 双跑对拍框架（新测试文件 `test/circuit/ir_parity_test.gd`，GUT）

1. 搭建用例集（复用 CircuitTestHarness）：非门链(≥8级)、LED 多输入线与、寄存器 D 触发器打拍、寄存器反馈环(in_loop)、交叉电线双通道、按钮脉冲。
2. 每个 tick：先走旧路径（ExprTree 求值）记录全部输出引脚值 → `SwCommon.NextEvalEpoch()` 重置 → IR `evaluate()` 后按 slot 映射取同批引脚值 → 逐个断言相等。
3. 随机压力：随机放置 N=200 元件（电线/非门/LED/寄存器/开关按权重），随机翻转开关打 10000 拍，每拍对拍。**零差异为出口标准**。
4. 结果落盘 `test/ir_parity_last.txt` 便于定位首个 diff（build.id + dir + 期望/实际）。

### 验收
- 对拍 10^4 拍零差异；GUT 全过；`SWBoolProgram.evaluate()` 单次调用不产生任何对象分配（用 performance monitor 的 allocation 计数验证——若无法测量，代码评审确认无 new/字面量字典）。

---

## 4. T2.4 编译集成（M2）

### 集成点
`circuit/sw_cirucit_control.gd` `updateBuildCircuit` 末尾（`return affectBuilds` 之前）：
1. 收集根：遍历 `swBuildManager.getAllBuilds()` 中 `IsWireBuild()==false` 且有 circuit 的建筑，取其输出方向 expr（getExpr 语义：输出端口方向）。
2. `SWBoolCompiler.compile(roots)` 生成全局 IR，存到 `sw_cirucit_control` 成员 `var boolProgram:SWBoolProgram`；同时保存 `slotMap:Dictionary`（key=`build.id*4+dir` → slotIdx，供 getValue/Emitter）。
3. 编译失败（环）：`push_error` 列出环成员，**保留旧树路径继续工作**（fail-open），不中断游戏。

### 验收
- 放置/删除/旋转/加载存档后 boolProgram 指令数与建筑数同量级；重复 updateBuildCircuit 不泄漏（旧 IR 直接整体替换，无残留引用）。

---

## 5. T2.5 getValue 切 slot + push 化（M6，最后做）

### 设计
1. `SWBuildCompoentCircuit.getValue(dir)` 增加分支：`sw_cirucit_control.boolProgram` 存在且 `slotMap.has(build.id*4+dir)` → 直接 `_slots[slot]` 读 int 返回 HIGH/LOW；否则走旧路径。**控制开关**：`sw_cirucit_control` 成员 `var useIR:bool = true`，出问题一键回退。
2. push 化：`buildSignalChanged` 的 BFS 中，对每个处理完的建筑，将其输出 slot 新值与旧值比较，变化时写入其各输出引脚 net：`net.curSignal = newSig` 并对 `net.wireGroup.wireBuilds` 调 `setValue`（与现有非门/LED getValue 中的传播逻辑等价——迁移后删除那些 getValue 内的传播代码，传播只在这一处发生）。
3. 电线建筑 `getValue` 保持恒等返回 `net.curSignal`（视觉直接读 net）。
4. 删除项（确认对拍稳定后）：`optFunc/optFuncName/NotValues/EqualValues/AndValues/NotAndValues` 中不再被引用者；`SWCircuitStruct.args` 树可整体退役。

### 验收
- GUT 全过 + ir_parity_test 在 useIR=true 下作为主断言；性能面板：4853 次/tick 级 EvalStruct 调用归零，时钟密集场景（≥50 时钟）帧率对比记录入 `docs/metrics.md`。

### 回退
`useIR=false` 单开关回退到树路径（树路径在 M6 前一直保留并随 GUT 维护）。

---

## 6. T2.6 SWVerilogEmitter（M3）

### 新文件 `circuit/export/sw_verilog_emitter.gd`

```gdscript
class_name SWVerilogEmitter extends RefCounted
# 输入：SWBoolProgram + slotMap + 建筑元数据
# 输出：String（.v 文本）
func emit(program:SWBoolProgram, slotMap:Dictionary, builds:Array[SWBuildItemDefine]) -> String
```

### 生成规则
1. **端口**：
   - input：`CircuitComponentType.BUTTON/SWITCH` → `sw_<id>`；`CLOCK_SIGGEN` → 统一 `clk`（多个时钟合并为一个 clk 端口，各时钟使能折叠为门控说明注释）。
   - output：`LED` → `led_<id>`。
   - 寄存器：`reg q_<id>;` + `always @(posedge clk) q_<id> <= <D表达式slot名>;`（D 取自寄存器 D 方向输入 slot；寄存器初值生成 `initial q_<id> = 1'b0;` 并注明需与游戏 resetBuildState 初值一致）。
2. **wire**：每个 slot `wire n_<slotIdx>;`；被判定为端口/寄存器Q的 slot 用端口名替代。
3. **指令映射**：AND→`assign n_d = n_a & n_b;`；NAND→`assign n_d = ~(n_a & n_b);`；PASS→`assign n_d = n_a;`；NOT→`assign n_d = ~n_a;`；OP_IN_PIN→其 provider 是源类建筑时绑端口；电线不产 wire（透明）。
4. **命名**：全部 `[a-z_][a-z0-9_]*`；中文 buildName 只进注释 `// 开关@12,34`。**禁止**使用 CircuitComponentType 枚举数值命名。
5. **导出前校验**（失败则不产出文件，返回错误串）：
   - 组合环：IR 编译已保证无环，此处断言复核（拓扑序即证）；
   - 多驱动：slot 有多个驱动指令 → 报错（编译器化简已保证单驱动，此为防御）；
   - 悬空输入：OP_IN_PIN 的 provider 若为无驱动引脚 → `assign n_x = 1'b0;` 并注释"默认上拉约定"。
6. **触发方式**：调试控制台命令/菜单项，调用 `emit` 后 `FileAccess.open("user://circuit_export.v", WRITE)` 落盘。**严禁**接入每 tick 路径。

### 验收
- 样例电路导出文件可通过 `iverilog -g2012 -o out.vvp circuit_export.v tb.v && vvp out.vvp` 编译运行（tb.v 由 T2.7 提供）。

---

## 7. T2.7 iverilog 回环测试（M3）

### 新测试 `test/circuit/verilog_parity_test.gd`
1. 前置探测：`OS.execute("iverilog", ["-V"])` 失败 → `push_warning` 并 skip（CI 环境可装 iverilog）。
2. 流程：搭建样例（非门链+LED+寄存器打拍+按钮）→ 引擎跑 100 拍记录输出序列 → 导出 .v → 生成 tb.v（同激励）→ iverilog+vvp 执行 → 解析输出序列 → 逐拍 diff。
3. 出口标准：三种样例（纯组合 / 含寄存器 / 含反馈环经寄存器打断）全部逐拍一致。
4. 波形留档：vvp 加 `-vcd` 输出到 `test/verilog_wave/`，diff 失败时附首个不一致拍号。

---

## 8. 本 SPEC 全局禁区

1. 不得修改 `render/`、`layers/` 下任何文件（改造二纯逻辑层）。
2. 不得在既有枚举中间插入值；新增枚举一律追加尾部。
3. 每完成一个 T 任务：跑一次 GUT 全量 + 记录性能指标到 `docs/metrics.md`，再进入下一任务。
4. M2 对拍不通过时，**禁止**继续 T2.5/T2.6。
