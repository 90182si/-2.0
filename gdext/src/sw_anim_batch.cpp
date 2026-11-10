#include "sw_anim_batch.h"

#include <godot_cpp/core/class_db.hpp>

#include <cmath>
#include <cstring>

using namespace godot;

void SWAnimBatch::_bind_methods() {
	ClassDB::bind_method(D_METHOD("setup", "grid"), &SWAnimBatch::setup);
	ClassDB::bind_method(D_METHOD("get_unit_count"), &SWAnimBatch::get_unit_count);
	ClassDB::bind_method(D_METHOD("get_active_count"), &SWAnimBatch::get_active_count);
	ClassDB::bind_method(D_METHOD("get_visible_count"), &SWAnimBatch::get_visible_count);
	ClassDB::bind_method(D_METHOD("get_capacity"), &SWAnimBatch::get_capacity);
	ClassDB::bind_method(D_METHOD("consume_dirty"), &SWAnimBatch::consume_dirty);
	ClassDB::bind_method(D_METHOD("get_buffer"), &SWAnimBatch::get_buffer);
	ClassDB::bind_method(D_METHOD("add_unit", "tpl", "base_x", "base_y"), &SWAnimBatch::add_unit);
	ClassDB::bind_method(D_METHOD("refresh_tpl", "r", "tpl", "base_x", "base_y"), &SWAnimBatch::refresh_tpl);
	ClassDB::bind_method(D_METHOD("rotate_tpl", "r", "sweep_deg"), &SWAnimBatch::rotate_tpl);
	ClassDB::bind_method(D_METHOD("remove_unit", "r"), &SWAnimBatch::remove_unit);
	ClassDB::bind_method(D_METHOD("reset"), &SWAnimBatch::reset);
	ClassDB::bind_method(D_METHOD("set_move", "r", "to", "dur"), &SWAnimBatch::set_move, DEFVAL(0.16));
	ClassDB::bind_method(D_METHOD("start_moves", "rows", "to_xy", "dur"), &SWAnimBatch::start_moves, DEFVAL(0.16));
	ClassDB::bind_method(D_METHOD("set_rotate", "r", "sweep_deg", "dur"), &SWAnimBatch::set_rotate, DEFVAL(0.2));
	ClassDB::bind_method(D_METHOD("is_busy", "r"), &SWAnimBatch::is_busy);
	ClassDB::bind_method(D_METHOD("get_pos", "r"), &SWAnimBatch::get_pos);
	ClassDB::bind_method(D_METHOD("get_angle_deg", "r"), &SWAnimBatch::get_angle_deg);
	ClassDB::bind_method(D_METHOD("advance", "delta"), &SWAnimBatch::advance);
}

void SWAnimBatch::setup(const Vector2i &p_grid) {
	gx = (float)p_grid.x;
	gy = (float)p_grid.y;
}

// ---------------- 行管理 ----------------

int32_t SWAnimBatch::add_unit(PackedFloat32Array p_tpl, float p_base_x, float p_base_y) {
	const int32_t n = p_tpl.size();
	if (n <= 0 || (n % STRIDE) != 0) {
		return -1;
	}
	const int32_t pa = n / STRIDE;
	const int32_t r = row_count;
	row_count += 1;
	const size_t sz = (size_t)row_count;
	slot_start.resize(sz);
	slot_parts.resize(sz);
	mv_fx.resize(sz);
	mv_fy.resize(sz);
	mv_tx.resize(sz);
	mv_ty.resize(sz);
	mv_t.resize(sz);
	mv_dur.resize(sz);
	rt_ang.resize(sz);
	rt_t.resize(sz);
	rt_dur.resize(sz);
	rt_flag.resize(sz);
	tpl.resize(sz);
	tpl_x.resize(sz);
	tpl_y.resize(sz);
	in_act.resize(sz);

	{
		const float *src = p_tpl.ptr();
		tpl[r].assign(src, src + n);
	}
	slot_parts[r] = pa;
	// _alloc_slot 内部可能扩 buf 容量，必须在拿到 tpl 之后调用
	slot_start[r] = _alloc_slot(pa);
	mv_fx[r] = p_base_x;
	mv_fy[r] = p_base_y;
	mv_tx[r] = p_base_x;
	mv_ty[r] = p_base_y;
	mv_t[r] = 0.0f;
	mv_dur[r] = 0.0f;
	rt_ang[r] = 0.0f;
	rt_t[r] = 0.0f;
	rt_dur[r] = 0.0f;
	rt_flag[r] = 0;
	tpl_x[r] = p_base_x;
	tpl_y[r] = p_base_y;
	in_act[r] = 0;
	// 新槽位先按「站着不动」的口径铺一次，否则它那一段是 0 尺度（看不见）
	_paint_tpl(r);
	return r;
}

void SWAnimBatch::refresh_tpl(int32_t r, PackedFloat32Array p_tpl, float p_base_x, float p_base_y) {
	if (r < 0 || r >= row_count) {
		return;
	}
	const int32_t n = p_tpl.size();
	if (n <= 0 || (n % STRIDE) != 0 || (n / STRIDE) != slot_parts[r]) {
		return;
	}
	{
		const float *src = p_tpl.ptr();
		tpl[r].assign(src, src + n);
	}
	tpl_x[r] = p_base_x;
	tpl_y[r] = p_base_y;
	// ⚠ 不动 mv_fx / mv_fy：重铺模板不该打断正在跑的移动插值
	//   （否则「一边滑一边被选中」会从当前位置重新起算，看起来跳一下）
	_paint_tpl(r);
}

bool SWAnimBatch::rotate_tpl(int32_t r, double p_sweep_deg) {
	if (r < 0 || r >= row_count) {
		return false;
	}
	// 只做「单部件且部件原点就在格心上」这一种：这时整台就是一个绕格心转的贴图，
	// 原地转与按新朝向重烘等价。多部件 / 跨格偏移的台若原地转，部件原点会跟着转，
	// 而重烘不会 —— 那种台如实拒绝，交给调用方重铺
	if (slot_parts[r] != 1) {
		return false;
	}
	std::vector<float> &t = tpl[r];
	if (t.size() != (size_t)STRIDE) {
		return false;
	}
	const float cx = tpl_x[r] + gx * 0.5f;
	const float cy = tpl_y[r] + gy * 0.5f;
	if (std::fabs(t[3] - cx) > 0.01f || std::fabs(t[7] - cy) > 0.01f) {
		return false;
	}
	float cs = 1.0f;
	float sn = 0.0f;
	if (std::fabs(p_sweep_deg) > (double)ANGLE_EPS_DEG) {
		// 度 -> 弧度直接用常量，避免为了一个 M_PI 引入平台相关的宏
		const float rad = (float)p_sweep_deg * 0.017453292519943295f;
		cs = std::cos(rad);
		sn = std::sin(rad);
	}
	// 两个基向量同列交错存：t.x = (0,1)、t.y = (4,5)
	const float txx = t[0];
	const float tyx = t[1];
	const float txy = t[4];
	const float tyy = t[5];
	t[0] = cs * txx - sn * txy;
	t[4] = sn * txx + cs * txy;
	t[1] = cs * tyx - sn * tyy;
	t[5] = sn * tyx + cs * tyy;
	// 原点已经在格心上：绕格心转就是原地不动，写回去保住浮点精度
	t[3] = cx;
	t[7] = cy;
	_paint_tpl(r);
	return true;
}

void SWAnimBatch::remove_unit(int32_t r) {
	if (r < 0 || r >= row_count) {
		return;
	}
	const int32_t last = row_count - 1;
	// ⚠ 先取被删行的槽位：_move_row 会把 last 的槽位覆盖到 r 上，之后就取不到了。
	//   取错会「泄漏一段实例」（被删的那台一直画在原地）。
	const int32_t st = slot_start[r];
	const int32_t pa = slot_parts[r];
	_drop_act(r);
	if (last != r) {
		_drop_act(last);
		_move_row(last, r);
	}
	row_count = last;
	hide_pairs.push_back(st);
	hide_pairs.push_back(pa);
	free_pool[pa].push_back(st);
	inst_total -= pa;
	if (inst_total <= 0) {
		reset();
		return;
	}
	buf_dirty = true;
}

void SWAnimBatch::reset() {
	row_count = 0;
	slot_start.clear();
	slot_parts.clear();
	mv_fx.clear();
	mv_fy.clear();
	mv_tx.clear();
	mv_ty.clear();
	mv_t.clear();
	mv_dur.clear();
	rt_ang.clear();
	rt_t.clear();
	rt_dur.clear();
	rt_flag.clear();
	tpl.clear();
	tpl_x.clear();
	tpl_y.clear();
	in_act.clear();
	act.clear();
	free_pool.clear();
	hide_pairs.clear();
	buf.clear();
	cap_inst = 0;
	inst_total = 0;
	// 缓冲清空了也要标脏：调用方得把可见数一起归零
	buf_dirty = true;
}

// ---------------- 动画登记 ----------------

void SWAnimBatch::set_move(int32_t r, const Vector2 &p_to, double p_dur) {
	if (r < 0 || r >= row_count) {
		return;
	}
	// 已经接管的从当前插值位置续上（一拍多格时不会跳）
	const Vector2 cur = get_pos(r);
	mv_fx[r] = cur.x;
	mv_fy[r] = cur.y;
	mv_tx[r] = p_to.x;
	mv_ty[r] = p_to.y;
	mv_t[r] = 0.0f;
	mv_dur[r] = (p_dur > 0.0) ? (float)p_dur : 0.0001f;
	_add_act(r);
}

void SWAnimBatch::start_moves(const PackedInt32Array &p_rows, const PackedFloat32Array &p_to_xy, double p_dur) {
	const int32_t n = p_rows.size();
	// to_xy 是 (x, y) 交错，长度必须够 2n；对不上就整批丢掉：
	// 宁可这一拍不动，也不能越界读到别的堆数据
	if (n <= 0 || p_to_xy.size() < n * 2) {
		return;
	}
	const int32_t *rows = p_rows.ptr();
	const float *xy = p_to_xy.ptr();
	const float d = (p_dur > 0.0) ? (float)p_dur : 0.0001f;
	const int32_t rmax = row_count;
	for (int32_t i = 0; i < n; ++i) {
		const int32_t r = rows[i];
		if (r < 0 || r >= rmax) {
			continue;
		}
		// 内联 get_pos：只取当前插值位置的两个分量，不构造 Vector2
		const float dur0 = mv_dur[r];
		if (dur0 > 0.0f) {
			const float e = _ease(mv_t[r] / dur0);
			mv_fx[r] = mv_fx[r] + (mv_tx[r] - mv_fx[r]) * e;
			mv_fy[r] = mv_fy[r] + (mv_ty[r] - mv_fy[r]) * e;
		} else {
			mv_fx[r] = mv_tx[r];
			mv_fy[r] = mv_ty[r];
		}
		mv_tx[r] = xy[i * 2];
		mv_ty[r] = xy[i * 2 + 1];
		mv_t[r] = 0.0f;
		mv_dur[r] = d;
		// 内联 _add_act
		if (in_act[r] == 0) {
			in_act[r] = 1;
			act.push_back(r);
		}
	}
}

void SWAnimBatch::set_rotate(int32_t r, double p_sweep_deg, double p_dur) {
	if (r < 0 || r >= row_count) {
		return;
	}
	if (p_dur <= 0.0) {
		// 同朝向（扫描角 0）：不转，也就不要留 rt_flag，否则会白跑一次重铺
		rt_ang[r] = 0.0f;
		rt_t[r] = 0.0f;
		rt_dur[r] = 0.0f;
		return;
	}
	rt_ang[r] = -(float)p_sweep_deg;
	rt_t[r] = 0.0f;
	rt_dur[r] = (float)p_dur;
	rt_flag[r] = 1;
	_add_act(r);
}

bool SWAnimBatch::is_busy(int32_t r) const {
	if (r < 0 || r >= row_count) {
		return false;
	}
	return mv_dur[r] > 0.0f || rt_dur[r] > 0.0f;
}

Vector2 SWAnimBatch::get_pos(int32_t r) const {
	if (r < 0 || r >= row_count) {
		return Vector2(0.0f, 0.0f);
	}
	const float d = mv_dur[r];
	if (d <= 0.0f) {
		return Vector2(mv_tx[r], mv_ty[r]);
	}
	const float e = _ease(mv_t[r] / d);
	return Vector2(mv_fx[r] + (mv_tx[r] - mv_fx[r]) * e,
			mv_fy[r] + (mv_ty[r] - mv_fy[r]) * e);
}

double SWAnimBatch::get_angle_deg(int32_t r) const {
	if (r < 0 || r >= row_count) {
		return 0.0;
	}
	const float ad = rt_dur[r];
	if (ad <= 0.0f) {
		return 0.0;
	}
	return (double)(rt_ang[r] * (1.0f - _ease(rt_t[r] / ad)));
}

// ---------------- 每帧推进 ----------------

void SWAnimBatch::advance(double p_delta) {
	const float delta = (float)p_delta;
	// 删台留下的隐藏段在这里统一抹掉（全 0 = 零尺度退化三角形，GPU 成本可忽略）
	_flush_hides();
	const int32_t n = (int32_t)act.size();
	if (n <= 0) {
		return;
	}
	int32_t keep = 0;
	for (int32_t i = 0; i < n; ++i) {
		const int32_t r = act[i];
		bool busy = false;
		const float d = mv_dur[r];
		if (d > 0.0f) {
			const float nt = mv_t[r] + delta;
			if (nt >= d) {
				mv_t[r] = d;
				mv_dur[r] = 0.0f;
				mv_fx[r] = mv_tx[r];
				mv_fy[r] = mv_ty[r];
			} else {
				mv_t[r] = nt;
				busy = true;
			}
		}
		const float ad = rt_dur[r];
		bool rot_ended = false;
		if (ad > 0.0f) {
			const float na = rt_t[r] + delta;
			if (na >= ad) {
				rt_t[r] = ad;
				rt_dur[r] = 0.0f;
				rt_ang[r] = 0.0f;
				// rt_flag 由下面这行写缓冲时消费：收尾帧仍要走重铺分支
				rot_ended = true;
			} else {
				rt_t[r] = na;
				busy = true;
			}
		}
		// 到位那一帧也要写一次：最后停的位置/角度就是这一帧的值
		_write_row(r, rot_ended);
		if (busy) {
			act[keep] = r;
			keep += 1;
		} else {
			in_act[r] = 0;
		}
	}
	// 一趟压缩式回收，不逐个 erase（那样每删一条都要 memmove 整段）
	if (keep < n) {
		act.resize((size_t)keep);
	}
}

// ---------------- 内部 ----------------

void SWAnimBatch::_add_act(int32_t r) {
	if (r < 0 || r >= (int32_t)in_act.size()) {
		return;
	}
	if (in_act[r] != 0) {
		return;
	}
	in_act[r] = 1;
	act.push_back(r);
}

void SWAnimBatch::_drop_act(int32_t r) {
	if (r < 0 || r >= (int32_t)in_act.size()) {
		return;
	}
	if (in_act[r] == 0) {
		return;
	}
	in_act[r] = 0;
	const int32_t n = (int32_t)act.size();
	for (int32_t i = 0; i < n; ++i) {
		if (act[i] == r) {
			act.erase(act.begin() + i);
			return;
		}
	}
}

void SWAnimBatch::_move_row(int32_t src, int32_t dst) {
	if (src == dst) {
		return;
	}
	slot_start[dst] = slot_start[src];
	slot_parts[dst] = slot_parts[src];
	mv_fx[dst] = mv_fx[src];
	mv_fy[dst] = mv_fy[src];
	mv_tx[dst] = mv_tx[src];
	mv_ty[dst] = mv_ty[src];
	mv_t[dst] = mv_t[src];
	mv_dur[dst] = mv_dur[src];
	rt_ang[dst] = rt_ang[src];
	rt_t[dst] = rt_t[src];
	rt_dur[dst] = rt_dur[src];
	rt_flag[dst] = rt_flag[src];
	tpl[dst] = std::move(tpl[src]);
	tpl_x[dst] = tpl_x[src];
	tpl_y[dst] = tpl_y[src];
	// in_act 不搬：调用方已经把 src 和 dst 两行都从 act 里摘掉了
}

int32_t SWAnimBatch::_alloc_slot(int32_t pa) {
	auto it = free_pool.find(pa);
	if (it != free_pool.end() && !it->second.empty()) {
		// 复用前先把「待隐藏」抹掉：否则那一段的 0 会盖掉新台刚铺好的数据
		_flush_hides();
		const int32_t s = it->second.back();
		it->second.pop_back();
		inst_total += pa;
		return s;
	}
	const int32_t s = inst_total;
	inst_total += pa;
	_ensure_cap(inst_total);
	return s;
}

void SWAnimBatch::_ensure_cap(int32_t need) {
	if (need <= cap_inst) {
		return;
	}
	// 一次涨到 2 倍：万台逐台接管时摊还是 O(1) 次重分配。
	// 直接用 need 会让「每新增一台都扩一点」变成 O(n^2) 的显存与内存搬运
	int32_t cap = (cap_inst > 0) ? (cap_inst * 2) : 64;
	while (cap < need) {
		cap *= 2;
	}
	cap_inst = cap;
	buf.resize((size_t)cap * STRIDE, 0.0f);
	buf_dirty = true;
}

void SWAnimBatch::_paint_tpl(int32_t r) {
	const int32_t pa = slot_parts[r];
	if (pa <= 0) {
		return;
	}
	const std::vector<float> &tp = tpl[r];
	const size_t need = (size_t)pa * STRIDE;
	if (tp.size() < need) {
		return;
	}
	const size_t base = (size_t)slot_start[r] * STRIDE;
	if (base + need > buf.size()) {
		return;
	}
	memcpy(buf.data() + base, tp.data(), need * sizeof(float));
	buf_dirty = true;
}

void SWAnimBatch::_flush_hides() {
	const size_t n = hide_pairs.size();
	if (n == 0) {
		return;
	}
	const int64_t lim = (int64_t)buf.size();
	for (size_t i = 0; i + 1 < n; i += 2) {
		const int64_t st = hide_pairs[i];
		const int64_t pa = hide_pairs[i + 1];
		const int64_t sb = st * STRIDE;
		int64_t eb = (st + pa) * STRIDE;
		if (eb > lim) {
			eb = lim;
		}
		for (int64_t k = sb; k < eb; ++k) {
			buf[(size_t)k] = 0.0f;
		}
	}
	hide_pairs.clear();
	buf_dirty = true;
}

void SWAnimBatch::_write_row(int32_t r, bool force_rot) {
	const float d = mv_dur[r];
	float px;
	float py;
	if (d > 0.0f) {
		const float e = _ease(mv_t[r] / d);
		px = mv_fx[r] + (mv_tx[r] - mv_fx[r]) * e;
		py = mv_fy[r] + (mv_ty[r] - mv_fy[r]) * e;
	} else {
		px = mv_tx[r];
		py = mv_ty[r];
	}
	const int32_t pa = slot_parts[r];
	if (pa <= 0) {
		return;
	}
	const std::vector<float> &tp = tpl[r];
	const size_t need = (size_t)pa * STRIDE;
	if (tp.size() < need) {
		return;
	}
	const size_t base = (size_t)slot_start[r] * STRIDE;
	if (base + need > buf.size()) {
		return;
	}
	const float dx = px - tpl_x[r];
	const float dy = py - tpl_y[r];
	const bool rot = (rt_dur[r] > 0.0f) || force_rot;
	if (rot) {
		// 转向帧：scale 从模板整段重铺再转，不能在上一次的旋转结果上继续乘
		float ang = 0.0f;
		const float ad = rt_dur[r];
		if (ad > 0.0f) {
			ang = rt_ang[r] * (1.0f - _ease(rt_t[r] / ad));
		}
		const float cx = px + gx * 0.5f;
		const float cy = py + gy * 0.5f;
		float cs = 1.0f;
		float sn = 0.0f;
		if (std::fabs(ang) > ANGLE_EPS_DEG) {
			// 度 -> 弧度直接用常量，避免为了一个 M_PI 引入平台相关的宏
			const float rad = ang * 0.017453292519943295f;
			cs = std::cos(rad);
			sn = std::sin(rad);
		}
		float *b = buf.data() + base;
		const float *t = tp.data();
		for (int32_t k = 0; k < pa; ++k) {
			const int32_t ii = k * STRIDE;
			const float txx = t[ii + 0];
			const float tyx = t[ii + 1];
			const float txy = t[ii + 4];
			const float tyy = t[ii + 5];
			const float ox = t[ii + 3] + dx - cx;
			const float oy = t[ii + 7] + dy - cy;
			b[ii + 0] = cs * txx - sn * txy;
			b[ii + 4] = sn * txx + cs * txy;
			b[ii + 1] = cs * tyx - sn * tyy;
			b[ii + 5] = sn * tyx + cs * tyy;
			b[ii + 3] = cx + cs * ox - sn * oy;
			b[ii + 7] = cy + sn * ox + cs * oy;
		}
		rt_flag[r] = 0;
		buf_dirty = true;
		return;
	}
	if (dx == 0.0f && dy == 0.0f) {
		return;
	}
	// 纯平移：每台每帧只写 2 * parts 个 float
	float *b = buf.data() + base;
	const float *t = tp.data();
	for (int32_t k = 0; k < pa; ++k) {
		const int32_t ii = k * STRIDE;
		b[ii + 3] = t[ii + 3] + dx;
		b[ii + 7] = t[ii + 7] + dy;
	}
	buf_dirty = true;
}

PackedFloat32Array SWAnimBatch::get_buffer() const {
	PackedFloat32Array out;
	const int32_t n = (int32_t)buf.size();
	out.resize(n);
	if (n > 0) {
		memcpy(out.ptrw(), buf.data(), (size_t)n * sizeof(float));
	}
	return out;
}
