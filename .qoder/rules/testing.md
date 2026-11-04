---
trigger: always_on
---

# 测试执行规范

## 禁止全量跑 GUT

`test/circuit` 下用例众多，其中多个用例要加载完整存档（`计数器1.json` 2.6MB、`64x寄存器.json` 38MB），
一轮全量要十几分钟以上，严重拖慢迭代。**默认只跑与本次改动直接相关的测试文件。**

只有用户明确要求「跑全量 / 回归所有测试 / 完整回归」时才允许跑全量。

## 单文件跑法（推荐）

```powershell
& 'K:\Godot_v4.7.2-stable_win64\Godot_v4.7.2-stable_win64_console.exe' --headless --path 'j:\godot\无限地图' `
  -s addons/gut/gut_cmdln.gd -gdir=res://test/circuit -gprefix=test_xxx -gexit
```

- `-gprefix=` 传测试文件名前缀（不带 `.gd`），只匹配那一个文件
- 不要用 `-gtest=`：会被 `.gutconfig.json` 的 `dirs` 覆盖成跑全量
- 不要加 `-gsuffix=.gd`：报 Unknown arguments
- PowerShell 下不能用 `&&` 串联，需要分步执行

## 排查用临时探针

产品问题需要现场数据时，写 `test/circuit/_tmp_<主题>_probe.gd` 探针（继承 GutTest，用
`circuit_test_harness.gd` 拉起场景），跑法同上。**用完必须删掉 `.gd` 与 `.gd.uid`**，
不要留在仓库里污染全量耗时。

优先选择小存档（`ledbug2`）做探针载体；确需大存档时，只加载一次并在同一个用例里跑完全部断言。

## 已知环境噪声（不算失败）

- headless 无渲染设备：`GPU 引擎不可用` / `RD 不可用`
- `sw_expr_eval_asan.gdextension` 加载失败
- 控制台中文 GBK 乱码：搜日志时用 ASCII 关键字，不要用中文 pattern
