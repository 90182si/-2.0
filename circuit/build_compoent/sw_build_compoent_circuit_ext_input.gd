class_name SWBuildCompoentCircuitExtInput extends SWBuildCompoentCircuitSource

# 外部输入接口（clk）：与按钮/开关同属信号源（网表里也是 DEV_SOURCE），
# 区别只在电平来源 —— 不是交互状态，而是建筑实例上的 level 字段（由边界层写入）。
# 电路层完全无视觉行为：没有按下态、不切图集帧。

# 当前输出电平（0/1）：由建筑实例字段给出，未初始化时为 0
func levelOf() -> int:
	return 1 if int(buildRef.get("level")) != 0 else 0

func getValue(dir:SwDefine.SW_Dir) -> SwDefine.CircuitSignal:
	if dir != buildRef.rotation:
		return SwDefine.CircuitSignal.NONE
	return SwDefine.CircuitSignal.HIGH if levelOf() == 1 else SwDefine.CircuitSignal.LOW

func evaluate() -> int:
	return levelOf()

func evalOutput() -> int:
	return evaluate()
