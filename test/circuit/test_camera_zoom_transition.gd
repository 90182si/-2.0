extends GutTest
# 滚轮缩放过渡（SWCamera2D.zoom_anim_sec）
#
# 要锁住两条口径：
#   1) 滚轮一按不再「一格一跳」，而是分多帧滑到目标档位；
#   2) **过渡期间只动相机** —— 不往 layer 推 on_view_rect_changed。
#      动画每帧都在改 zoom 和位置，通知下去等于每帧把每个 layer 的区块表全枚举一遍
#      （缩远时单层上千格），过渡本身反而更卡；攒到过渡结束统一通知一次。
#
# 全部同步驱动（手动 _tick_zoom），不 await 帧：headless 帧长不可控，
# 靠真实帧跑 0.18s 的过渡会导致断言时快时慢。

const STEP := 1.1

# 只用于数「有没有往下游推视口变化」的假 layer
class CountingLayer extends SWLayer:
	var calls: int = 0
	func on_view_rect_changed(_view_rect: Rect2, _speed_vec: Vector2) -> void:
		calls += 1

var cam: SWCamera2D = null
var layer: CountingLayer = null

func before_each() -> void:
	cam = SWCamera2D.new()
	add_child_autofree(cam)
	layer = CountingLayer.new()
	add_child_autofree(layer)
	cam.addLayerNotify(layer)
	# 初始视野：set_view 会顺手通知一次（读档口径），记完就清零
	cam.set_view(Vector2(1000, 2000), Vector2.ONE, 0)
	layer.calls = 0

func after_each() -> void:
	cam.delLayerNotify(layer)

# 鼠标在屏幕 pivot 处指向的世界坐标点（Camera2D 以视口中心为原点）
func _world_under(screen: Vector2) -> Vector2:
	var vr: Rect2 = cam.get_viewport_rect()
	return cam.global_position + (screen - vr.position - vr.size * 0.5) / cam.zoom

func test_wheel_step_animates_instead_of_jumping() -> void:
	cam.zoom_anim_sec = 0.2
	cam._on_zoomCom_zoom(Vector2(0, 1))
	assert_true(cam.is_zoom_animating(), "滚轮没有起过渡（还是直接跳到位）")
	assert_almost_eq(cam.zoom.x, 1.0, 0.0001, "滚轮那一瞬间就跳到目标档位了，没有过渡")
	assert_eq(layer.calls, 0, "起过渡就通知 layer 了")

	# 1/4 程：应当已经动了，但还没到位
	cam._tick_zoom(0.05)
	assert_gt(cam.zoom.x, 1.0, "过渡没有推进 zoom")
	assert_lt(cam.zoom.x, STEP, "过渡一步就到位了，没有中间状态")
	assert_eq(layer.calls, 0, "过渡过程中把 on_view_rect_changed 推出去了（每帧重建区块表）")

	# 走完：落到目标档位，并且**只**在最后通知一次
	cam._tick_zoom(0.2)
	assert_almost_eq(cam.zoom.x, STEP, 0.0001, "过渡结束时没落到目标档位")
	assert_false(cam.is_zoom_animating(), "过渡结束了还挂着动画标记")
	assert_eq(layer.calls, 1, "过渡结束应当只通知一次（攒着一起通知）")

func test_move_during_zoom_does_not_notify_layers() -> void:
	cam.zoom_anim_sec = 0.2
	cam._on_zoomCom_zoom(Vector2(0, -1))
	# 过渡途中又拖了一下鼠标：位移要照常落地，但不能惊动 layer
	cam._on_moveCom_moveByMouse(Vector2(30, 0))
	cam.flush_view_update()
	assert_eq(layer.calls, 0, "过渡中的位移也推给 layer 了")
	assert_true(bool(cam.get("_view_dirty")), "过渡中没打上「欠一次通知」的标记")
	# 没有位移的帧（走的是另一个分支）也不能通知
	cam.flush_view_update()
	assert_eq(layer.calls, 0, "过渡中无位移的帧也通知 layer 了")

	cam._tick_zoom(0.2)
	assert_eq(layer.calls, 1, "过渡结束没把欠的那次通知补上（视口会一直错到下次拖动）")

func test_instant_applies_immediately_for_scene_boot() -> void:
	cam._on_zoomCom_zoom(Vector2(0, -1), true)
	assert_false(cam.is_zoom_animating(), "instant 模式还在跑过渡（首屏区块要晚 0.18s 才加载）")
	assert_almost_eq(cam.zoom.x, 1.0 / STEP, 0.0001, "instant 没有立即落到目标档位")
	assert_eq(layer.calls, 1, "instant 应当当场通知一次（加载首屏）")

func test_rapid_wheel_retargets_from_current_zoom() -> void:
	cam.zoom_anim_sec = 0.2
	cam._on_zoomCom_zoom(Vector2(0, 1))
	cam._tick_zoom(0.05)
	var mid: float = cam.zoom.x
	assert_gt(mid, 1.0, "第一格过渡没有推进")
	# 连拨第二格：必须从**当前** zoom 起跑，否则会攒成一段很长的追赶动画
	cam._on_zoomCom_zoom(Vector2(0, 1))
	assert_almost_eq(float(cam.get("_zoom_from")), mid, 0.0001,
			"连拨时从上一档目标值起跑了（会攒出一段长追赶）")
	assert_almost_eq(float(cam.get("_zoom_to")), STEP * STEP, 0.0001, "目标档位没累计到两格")
	cam._tick_zoom(0.3)
	assert_almost_eq(cam.zoom.x, STEP * STEP, 0.0001, "两格结束没落到目标档位")
	assert_eq(layer.calls, 1, "连拨两格只在最后通知一次")

func test_zoom_keeps_point_under_pivot_fixed() -> void:
	# 鼠标支点（屏幕坐标）在缩放前后应当指着同一个世界点
	cam._zoom_pivot = Vector2(120, -80)
	var vr: Rect2 = cam.get_viewport_rect()
	var screen: Vector2 = vr.position + vr.size * 0.5 + cam._zoom_pivot
	var before: Vector2 = _world_under(screen)
	cam._apply_zoom_at(Vector2(STEP, STEP))
	var after: Vector2 = _world_under(screen)
	# 像素吸附会带来不到半个屏幕像素的误差
	assert_almost_eq(after.x, before.x, 1.0, "缩放后鼠标下的世界点跑了（x）")
	assert_almost_eq(after.y, before.y, 1.0, "缩放后鼠标下的世界点跑了（y）")
