class_name SWNetColorEntry extends RefCounted

# 一个区块内「同一 net + 同一调色板」的实例颜色列。
# 电线A/B 可能经桥梁、隧道并进同一个 net，而 net 的 wireName 只能记一个，
# 所以按 net + 线名分组，同 net 的不同线别各占一条，各写自己的低/高电平色。
var net: SWNet = null
var is_own: bool = false
var low: Color = Color.WHITE
var high: Color = Color.WHITE
var cols: PackedInt32Array = PackedInt32Array()
var mask_cols: PackedInt32Array = PackedInt32Array()
var mask_colors: PackedColorArray = PackedColorArray()
