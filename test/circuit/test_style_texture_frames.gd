extends GutTest
# styleTex 的键契约：styleId 必须按「帧对 (off, on)」区分，而不是只按 off rect。
# 图集里不同建筑复用同一像素 region：通用底座 512,0 恰好也是灯泡的 off 帧，
# 非门 off 帧 384,0 恰好是电线隧道的一种 rect。旧实现只按 off 索引，
# 于是任何 buildHasBase 的建筑烘焙时都会把帧对的 row1 覆盖回 off 帧，
# shader 取哪一行都是灭帧（读档后 LED 不随电路变化的根因）。

const RECT_BASE := Rect2(512, 0, 128, 128)      # 建筑物底座 == 灯泡 off 帧
const RECT_LED_ON := Rect2(512, 128, 128, 128)  # 灯泡 on 帧
const RECT_WIRE := Rect2(0, 256, 128, 128)      # 只作为静态样式出现的 rect

var _style: SWStyleTexture = null

func before_each() -> void:
	# 独立实例，不碰 SWStyleTexture.instance；重建回调置空避免误刷别的场景材质
	SWStyleTexture._refresh_cb = Callable()
	_style = SWStyleTexture.new()

# 先登记静态底座、再登记同 off 的帧对：帧对的 on 行不得被静态登记吃掉
func test_static_reg_after_frame_keeps_on_row() -> void:
	var frame_id: int = _style.register_frame(RECT_BASE, RECT_LED_ON)
	var static_id: int = _style.register_rect(RECT_BASE)
	assert_ne(static_id, frame_id, "同一 off 帧配不同 on 帧必须另起 styleId")
	assert_eq(_style.get_rect_by_id(frame_id, false), RECT_BASE, "帧样式的 row0 应是 off 帧")
	assert_eq(_style.get_rect_by_id(frame_id, true), RECT_LED_ON, "帧样式的 row1 必须是 on 帧")
	assert_eq(_style.get_rect_by_id(static_id, true), RECT_BASE, "静态样式两行都应是自身")

# 反序（先帧对后静态）结果必须一致：注册顺序不得影响显示正确性
func test_static_reg_before_frame_keeps_on_row() -> void:
	var static_id: int = _style.register_rect(RECT_BASE)
	var frame_id: int = _style.register_frame(RECT_BASE, RECT_LED_ON)
	assert_ne(static_id, frame_id, "同一 off 帧配不同 on 帧必须另起 styleId")
	assert_eq(_style.get_rect_by_id(static_id, true), RECT_BASE, "静态样式的高帧被帧对污染了")
	assert_eq(_style.get_rect_by_id(frame_id, true), RECT_LED_ON, "帧样式的 row1 被静态登记降级了")

# 重复登记只查表不扩容：烘焙是十万建筑 × 部件的热路径，
# 一旦键表miss 就会为每个部件新建 styleId（纹理与实例数据同步膨胀）
func test_repeated_register_is_idempotent() -> void:
	var first_static: int = _style.register_rect(RECT_BASE)
	var first_frame: int = _style.register_frame(RECT_BASE, RECT_LED_ON)
	var first_wire: int = _style.register_rect(RECT_WIRE)
	var count_after_first: int = _style.style_count()
	for _i in 100:
		assert_eq(_style.register_rect(RECT_BASE), first_static, "静态登记未命中缓存")
		assert_eq(_style.register_frame(RECT_BASE, RECT_LED_ON), first_frame, "帧对登记未命中缓存")
		assert_eq(_style.register_rect(RECT_WIRE), first_wire, "同一 rect 两次登记 id 不一致")
	assert_eq(_style.style_count(), count_after_first, "重复登记让 styleTex 扩容了")

# 只有 on == off 才算同一帧对；off 相同、on 不同必须各自独立
func test_same_off_different_on_gets_distinct_ids() -> void:
	var id_a: int = _style.register_frame(RECT_BASE, RECT_LED_ON)
	var id_b: int = _style.register_frame(RECT_BASE, RECT_WIRE)
	assert_ne(id_a, id_b, "不同 on 帧共用了 styleId")
	assert_eq(_style.get_rect_by_id(id_a, true), RECT_LED_ON)
	assert_eq(_style.get_rect_by_id(id_b, true), RECT_WIRE)

# 非法 rect（空尺寸）不登记：返回 -1 让 shader 走品红哨兵，也不得占一个 styleId
func test_empty_rect_not_registered() -> void:
	assert_eq(_style.register_rect(Rect2(512, 0, 0, 128)), -1, "空 rect 被登记了")
	assert_eq(_style.register_frame(Rect2(), RECT_LED_ON), -1, "off 帧非法仍登记了")
	assert_eq(_style.style_count(), 0, "非法登记仍占了 styleId")
	assert_eq(_style.get_style_id(Rect2(512, 0, 0, 128)), -1, "空 rect 不该查得到 id")


# styleTex 是 shader 的 sampler2D，绑 null 会让 GPU 后端在 uniform_set_create 阶段报
# 「Texture is not a valid texture」并让整个材质失效（而且不会自己重试）。
# 所以纹理必须在构造时就有，而不是等第一次登记 style 才建：否则场景刚起来、建档之前
# 那一小段时间里渲染的区块全部是废材质。
func test_texture_exists_before_any_style_registered() -> void:
	var fresh: SWStyleTexture = SWStyleTexture.new()
	assert_eq(fresh.style_count(), 0, "新实例不该带任何 style")
	assert_not_null(fresh.texture, "没登记任何 style 时 styleTex 也不能是 null，否则材质整块失效")
	assert_eq(fresh.texture.get_width(), 1, "空表纹理应为 1×2 全零占位")
	assert_eq(fresh.texture.get_height(), 2)
