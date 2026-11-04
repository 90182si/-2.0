extends GutTest
# 隧道是等电位导线：两个物理口（入口 rotation+3 / 出口 rotation+1）必须始终指向同一根 net。
#
# 回归点：原先 setNet 只按 BFS 传入的 dir 写一个口，而 dir 是「从上一个建筑看本建筑」的方向，
# 不一定等于隧道的物理口方向（从正上方扫进来时一个物理口都设不上）；先放的隧道又会把自己
# 已建过 net 的口留在旧 net 上。于是「先放隧道、再连线」之后两个口各指一根 net，
# 接在未更新那一口的灯泡恒读到空 net —— 表面现象就是灯泡不亮、tooltip 驱动数为 0。
#   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/circuit/test_tunnel_net_pins.gd -gexit

const TUNNEL_DEF: SWBuildDefine = preload("res://res/电线隧道.tres")

func _make_tunnel(rot: int) -> SWBuildWireTunnel:
	return SWBuildWireTunnel.new(Vector2i(0, 0), TUNNEL_DEF, rot)

func _in_pin(tunnel: SWBuildWireTunnel) -> int:
	return posmod(tunnel.rotation + 3, 4)

func _out_pin(tunnel: SWBuildWireTunnel) -> int:
	return posmod(tunnel.rotation + 1, 4)

# 四种朝向下，随便传一个非物理口的方向（UP）也必须把两个口都填上
func test_set_net_fills_both_physical_pins() -> void:
	for rot in 4:
		var tunnel := _make_tunnel(rot)
		var comp := tunnel.getCircuitCompoent() as SWBuildCompoentCircuitTunnel
		var net := SWNet.new()
		comp.setNet(net, SwDefine.SW_Dir.UP)
		assert_same(comp.net, net, "rotation=%d 时组件 net 引用未更新" % rot)
		assert_same(comp.pinNetMap.get(_in_pin(tunnel)), net, "rotation=%d 入口口未指向 net" % rot)
		assert_same(comp.pinNetMap.get(_out_pin(tunnel)), net, "rotation=%d 出口口未指向 net" % rot)

# 「先放隧道（自建 net）→ 再连线（换 net）」：两个口必须一起换，不能留下一个口指着旧 net
func test_set_net_replaces_both_pins() -> void:
	var tunnel := _make_tunnel(0)
	var comp := tunnel.getCircuitCompoent() as SWBuildCompoentCircuitTunnel
	var old_net := SWNet.new()
	var new_net := SWNet.new()
	comp.setNet(old_net, _out_pin(tunnel))
	comp.setNet(new_net, SwDefine.SW_Dir.LEFT)
	assert_same(comp.pinNetMap.get(_in_pin(tunnel)), new_net, "入口口还留在旧 net")
	assert_same(comp.pinNetMap.get(_out_pin(tunnel)), new_net, "出口口还留在旧 net")

# 重建时 resetPortState 必须把两个口一起清掉，否则旧 net 会跨轮残留
func test_reset_port_state_clears_both_pins() -> void:
	var tunnel := _make_tunnel(1)
	var comp := tunnel.getCircuitCompoent() as SWBuildCompoentCircuitTunnel
	comp.setNet(SWNet.new(), SwDefine.SW_Dir.DOWN)
	comp.resetPortState()
	assert_null(comp.net, "resetPortState 后 net 未清空")
	assert_null(comp.pinNetMap.get(_in_pin(tunnel)), "resetPortState 后入口口仍有 net")
	assert_null(comp.pinNetMap.get(_out_pin(tunnel)), "resetPortState 后出口口仍有 net")
