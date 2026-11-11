#ifndef SW_ANIM_BATCH_H
#define SW_ANIM_BATCH_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <cstdint>
#include <unordered_map>
#include <vector>

namespace godot {

// 万级机器人「动画插值 + 实例缓冲改写」（热路径下沉到原生代码）。
//
// 与 GDScript 版 scene/entity/sw_anim_batch_gd.gd 接口一一对应、语义一致：
// 有原生类就用原生类，没有就用 GDScript 版兜底（SWEntityVisual 只按接口调用）。
//
// 为什么必须下沉：动画层每台每帧实际只写 2 个 float（parts=1 时纯平移），
// 但 GDScript 里这 2 个 float 要付十几个 PackedArray 下标 + 属性链 + 函数调用的
// 解释器开销，实测 10000 台 4.3us/台/帧。C++ 侧同样的循环是纯指针算术。
//
// 数据结构约定（行 = 一台被动画层接管的机器人）：
//   - 每行占渲染缓冲里一段连续实例槽 [slot_start, slot_start + slot_parts)
//   - 模板 tpl 是「该行在 (tpl_x, tpl_y) 处」的 parts*STRIDE 个 float，
//     由 GDScript 的 writeInstances 生成（缩放/style/net/调色板/tint 都在里面）。
//     每帧位置只是「模板原点 + 位移」，转向时才从模板重铺 scale
//     （不能在上一帧结果上继续乘，否则角度会永久叠进去）
//
// ⚠ 内部状态全部用 std::vector / 裸 float，不用 Packed*Array 成员：
//   PackedArray 的底层缓冲在赋值 / 写时复制时会迁移，跨调用缓存 ptrw() 指针
//   会变成悬空指针（详见 sw_expr_eval.h 里记的实测崩溃）。
//   std::vector 的生命周期完全由本对象掌控。
class SWAnimBatch : public RefCounted {
	GDCLASS(SWAnimBatch, RefCounted)

public:
	// 与 SWBuildCompoentRenderable.INSTANCE_STRIDE 一致
	static constexpr int32_t STRIDE = 16;
	// 角度增量小于这个值就当 0（约 0.002 rad）
	static constexpr float ANGLE_EPS_DEG = 0.115f;

protected:
	static void _bind_methods();

public:
	SWAnimBatch() {}
	~SWAnimBatch() {}

	// 格子尺寸（绕格心转向要用）
	void setup(const Vector2i &p_grid);

	int32_t get_unit_count() const { return row_count; }
	int32_t get_active_count() const { return (int32_t)act.size(); }
	int32_t get_visible_count() const { return inst_total; }
	int32_t get_capacity() const { return cap_inst; }

	// 缓冲是否有改动待上传。读一次就清（调用方一帧上传一次）
	bool consume_dirty() {
		const bool d = buf_dirty;
		buf_dirty = false;
		return d;
	}

	// 实例缓冲副本（长度 = get_capacity() * STRIDE）。
	// 返回副本而不是内部引用：调用方要把它交给 MultiMesh.set_buffer()，引擎那边
	// 自己会再拷一份。两边共享同一块会让后续任何写入触发写时复制整块迁移。
	PackedFloat32Array get_buffer() const;

	// 新增一行。tpl = 该台在 (base_x, base_y) 处的 parts*STRIDE 实例数据。
	// 返回行号；tpl 非法返回 -1
	int32_t add_unit(PackedFloat32Array p_tpl, float p_base_x, float p_base_y);

	// 重铺模板（选中态变了：选中色是烘进实例 tint 里的）
	void refresh_tpl(int32_t r, PackedFloat32Array p_tpl, float p_base_x, float p_base_y);

	// 把某一行的模板原地转 p_sweep_deg 度（与 set_rotate 同口径，顺时针为正）。
	// 只对「单部件、且部件原点就在格心」的台成立：这时整台就是一个绕格心转的
	// 贴图，原地转与「按新朝向重烘」等价，但省掉一次完整实例重算
	// （实测重烘 7.4us/台，一万台同拍转向就是 74ms）。
	// 多部件 / 有跨格偏移的台原地转会挪动部件原点（重烘不会），返回 false，
	// 由调用方按新朝向重铺模板
	bool rotate_tpl(int32_t r, double p_sweep_deg);

	// 删一行：隐藏它的槽段，行做 swap-remove（数组不缩容，只减 row_count）
	void remove_unit(int32_t r);
	void reset();

	// 开始一次滑动 / 转向。起点是「该行当前插值位置」，不额外传
	void set_move(int32_t r, const Vector2 &p_to, double p_dur);

	// 批量起滑：p_rows = 行号，p_to_xy = 终点 xy 交错（长度 = 2 * p_rows.size()）。
	// 语义与逐台 set_move 完全一致（起点仍是各行当前插值位置）。
	// 为什么要有这个入口：逐台调用每台都要过一次绑定层（参数从 Variant 逐个解包），
	// 一万台一拍实测多花 30ms；收进 C++ 后调用侧只剩一次调用。
	// 两个入参都是只读（用 ptr()，不碰 ptrw()，不会触发写时复制迁移）
	void start_moves(const PackedInt32Array &p_rows, const PackedFloat32Array &p_to_xy, double p_dur);
	void set_rotate(int32_t r, double p_sweep_deg, double p_dur);

	bool is_busy(int32_t r) const;
	Vector2 get_pos(int32_t r) const;
	// 当前相对烘焙朝向的增量角（度）。转完是 0
	double get_angle_deg(int32_t r) const;

	// 推进一帧：只跑真的在动的那几行，只改它们自己的实例段
	void advance(double p_delta);

private:
	// ---- 每行状态，全部平行数组（行号 = 下标）----
	int32_t row_count = 0;
	std::vector<int32_t> slot_start; // 渲染缓冲里的首实例下标
	std::vector<int32_t> slot_parts; // 部件数
	std::vector<float> mv_fx, mv_fy; // 移动起点
	std::vector<float> mv_tx, mv_ty; // 移动终点
	std::vector<float> mv_t; // 移动已走时间
	std::vector<float> mv_dur; // 移动时长（0 = 不在动）
	std::vector<float> rt_ang; // 起始补角（度，负值）→ 0
	std::vector<float> rt_t; // 转向已走时间
	std::vector<float> rt_dur; // 转向时长（0 = 不在转）
	std::vector<uint8_t> rt_flag; // 1 = 下一次写缓冲必须走「重铺 scale」分支
	std::vector<std::vector<float>> tpl; // 每行一份模板
	std::vector<float> tpl_x, tpl_y; // 模板对应的世界坐标
	std::vector<uint8_t> in_act; // 已在 act 里
	std::vector<int32_t> act; // 本帧要推进的行（无重复）

	// ---- 实例缓冲 ----
	std::vector<float> buf;
	int32_t cap_inst = 0; // MultiMesh 的 instance_count（容量，2 倍增长）
	int32_t inst_total = 0; // 真正可见的实例数
	// 空洞槽位：parts -> 可复用的 slot_start
	std::unordered_map<int32_t, std::vector<int32_t>> free_pool;
	// 待隐藏的槽段，成对存 (start, parts)
	std::vector<int32_t> hide_pairs;

	float gx = 32.0f;
	float gy = 32.0f;
	bool buf_dirty = false;

	static inline float _ease(float k) {
		if (k < 0.0f) {
			k = 0.0f;
		} else if (k > 1.0f) {
			k = 1.0f;
		}
		return k * k * (3.0f - 2.0f * k);
	}

	void _add_act(int32_t r);
	void _drop_act(int32_t r);
	void _move_row(int32_t src, int32_t dst);
	void _ensure_cap(int32_t need);
	int32_t _alloc_slot(int32_t pa);
	// 回收贴着可见区末尾的空洞（否则反复增删会把可见实例数越留越大）
	void _reclaim_tail_holes();
	void _paint_tpl(int32_t r);
	void _flush_hides();
	// force_rot = true 时即使 rt_dur 已归零也走「重铺 scale」分支：
	// 转向收尾那一帧必须把模板的原始 scale 写回去，否则上一帧转歪的基向量会留在缓冲里
	void _write_row(int32_t r, bool force_rot);
};

} // namespace godot

#endif // SW_ANIM_BATCH_H
