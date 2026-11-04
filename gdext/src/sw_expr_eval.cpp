#include "sw_expr_eval.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void SWExprEval::_bind_methods() {
	ClassDB::bind_method(D_METHOD("upload", "tables"), &SWExprEval::upload);
	ClassDB::bind_method(D_METHOD("set_values", "vals"), &SWExprEval::set_values);
	ClassDB::bind_method(D_METHOD("evaluate"), &SWExprEval::evaluate);
	ClassDB::bind_method(D_METHOD("get_values"), &SWExprEval::get_values);
	ClassDB::bind_method(D_METHOD("get_slot_value", "slot"), &SWExprEval::get_slot_value);
	ClassDB::bind_method(D_METHOD("get_expr_count"), &SWExprEval::get_expr_count);
	ClassDB::bind_method(D_METHOD("get_seg_count"), &SWExprEval::get_seg_count);
}

SWExprEval::SWExprEval() {}
SWExprEval::~SWExprEval() {}

bool SWExprEval::upload(Array p_tables) {
	// 展开打包参数（见头文件注释：单 Array 传参，避开多 packed array 形参的栈问题）
	if (p_tables.size() < 14) {
		ERR_PRINT("SWExprEval.upload: tables 至少需要 14 项");
		return false;
	}
	// 显式转换而非隐式赋值：Variant -> PackedInt32Array / int32_t 的隐式转换
	// 在某些 godot-cpp 版本上会走非预期的转换路径（实测可能在后续调用时崩溃）。
	seg_op = PackedInt32Array(p_tables[0]);
	seg_start = PackedInt32Array(p_tables[1]);
	seg_count = PackedInt32Array(p_tables[2]);
	seg_dst = PackedInt32Array(p_tables[3]);
	seg_src0 = PackedInt32Array(p_tables[4]);
	seg_src1 = PackedInt32Array(p_tables[5]);
	seg_n = PackedInt32Array(p_tables[6]);
	seg_off = PackedInt32Array(p_tables[7]);
	seg_const = PackedInt32Array(p_tables[8]);
	src_flat = PackedInt32Array(p_tables[9]);
	extra_start = PackedInt32Array(p_tables[10]);
	extra_dst = PackedInt32Array(p_tables[11]);
	primary = PackedInt32Array(p_tables[12]);
	expr_count = static_cast<int32_t>(p_tables[13]);
	seg_total = seg_op.size();
	uploaded = true;
	return true;
}

void SWExprEval::set_values(const PackedInt32Array &p_vals) {
	const int32_t n = p_vals.size();
	values.resize(n);
	const int32_t *src = p_vals.ptr();
	for (int32_t i = 0; i < n; ++i) {
		values[i] = src[i];
	}
}

void SWExprEval::evaluate() {
	if (!uploaded || expr_count == 0 || values.empty()) {
		return;
	}
	// 执行表完整性检查：缺任何一个表都直接返回，避免用空指针对下标越界崩溃。
	// （实测：测试套件里出现过 upload 后成员表被 GC 掉的竞态，裸指针变悬空 → signal 11）
	if (seg_op.is_empty() || seg_start.is_empty() || seg_count.is_empty() ||
			seg_dst.is_empty() || seg_src0.is_empty()) {
		return;
	}
	// 每次求值开头从成员取指针：PackedInt32Array 的底层缓冲在复制/写时复制时可能迁移，
	// 不能跨调用缓存（实测缓存会导致段错误）。
	const int32_t *m_seg_op = seg_op.ptr();
	const int32_t *m_seg_start = seg_start.ptr();
	const int32_t *m_seg_count = seg_count.ptr();
	const int32_t *m_seg_dst = seg_dst.ptr();
	const int32_t *m_seg_src0 = seg_src0.ptr();
	const int32_t *m_seg_src1 = seg_src1.ptr();
	const int32_t *m_seg_n = seg_n.ptr();
	const int32_t *m_seg_off = seg_off.ptr();
	const int32_t *m_seg_const = seg_const.ptr();
	const int32_t *m_src_flat = src_flat.ptr();
	const int32_t *m_extra_start = extra_start.ptr();
	const int32_t *m_extra_dst = extra_dst.ptr();
	const int32_t *m_primary = primary.ptr();
	// 段循环的安全上限取所有相关表长度的最小值：
	// 之前只校验了 seg_* 里的几项，seg_start / seg_count 比 seg_op 短时会越界读。
	const int32_t seg_cnt = MIN(seg_op.size(),
			MIN(seg_start.size(), MIN(seg_count.size(), MIN(seg_dst.size(), seg_src0.size()))));
	const int32_t seg_n_size = seg_n.size();
	const int32_t seg_off_size = seg_off.size();
	const int32_t seg_const_size = seg_const.size();
	const int32_t seg_src1_size = seg_src1.size();
	const int32_t dst_size = seg_dst.size();
	const int32_t s0_size = seg_src0.size();
	const int32_t src_flat_size = src_flat.size();
	const int32_t extra_start_size = extra_start.size();
	const int32_t extra_dst_size = extra_dst.size();
	const int32_t primary_size = primary.size();
	// 取可写裸指针（原地改写）
	int32_t *v = values.data();
	const int32_t vcount = (int32_t)values.size();

	// ---- 主循环：按 op 分段，段内一条紧凑循环 ----
	// 所有下标都做边界检查：宁可少算一个 slot 也绝不越界崩溃。
	// （正常编译出的执行表不会越界；这里的检查是防御测试环境下的竞态/脏数据。）
	// 注意每张表都要单独判长度：曾经只校验 seg_dst/seg_src0，
	// 而 seg_n / seg_const / seg_src1 更短时仍会越界读 → signal 11。
	for (int32_t seg = 0; seg < seg_cnt; ++seg) {
		const int32_t kind = m_seg_op[seg];
		const int32_t base = m_seg_start[seg];
		const int32_t end = base + m_seg_count[seg];
		if (base < 0 || end > dst_size || end > s0_size) {
			continue;
		}
		if (kind == EX_NOT) {
			for (int32_t k = base; k < end; ++k) {
				const int32_t d = m_seg_dst[k];
				const int32_t s = m_seg_src0[k];
				if (d >= 0 && d < vcount && s >= 0 && s < vcount) {
					v[d] = 1 - v[s];
				}
			}
		} else if (kind == EX_AND) {
			if (end > seg_n_size) {
				continue;
			}
			for (int32_t k = base; k < end; ++k) {
				const int32_t d = m_seg_dst[k];
				if (d < 0 || d >= vcount) {
					continue;
				}
				const int32_t ln = m_seg_n[k];
				if (ln == 2) {
					if (k >= seg_src1_size) {
						continue;
					}
					const int32_t a = m_seg_src0[k];
					const int32_t b = m_seg_src1[k];
					if (a >= 0 && a < vcount && b >= 0 && b < vcount) {
						v[d] = v[a] & v[b];
					}
				} else if (ln == 1) {
					const int32_t a = m_seg_src0[k];
					if (a >= 0 && a < vcount) {
						v[d] = v[a];
					}
				} else if (ln == 0) {
					// 空输入 AND = 常量 0（悬空 net 为低电平）
					v[d] = 0;
				} else {
					if (k >= seg_off_size) {
						continue;
					}
					const int32_t off = m_seg_off[k];
					if (off < 0 || off + ln > src_flat_size) {
						continue;
					}
					int32_t acc = 1;
					for (int32_t j = 0; j < ln; ++j) {
						const int32_t s = m_src_flat[off + j];
						if (s >= 0 && s < vcount) {
							acc = acc & v[s];
						}
					}
					v[d] = acc;
				}
			}
		} else if (kind == EX_ALIAS) {
			for (int32_t k = base; k < end; ++k) {
				const int32_t d = m_seg_dst[k];
				const int32_t s = m_seg_src0[k];
				if (d >= 0 && d < vcount && s >= 0 && s < vcount) {
					v[d] = v[s];
				}
			}
		} else { // EX_CONST
			if (end > seg_const_size) {
				continue;
			}
			for (int32_t k = base; k < end; ++k) {
				const int32_t d = m_seg_dst[k];
				if (d >= 0 && d < vcount) {
					v[d] = m_seg_const[k];
				}
			}
		}
	}

	// ---- 附加写目标：同一表达式服务多个 slot 时补写 ----
	// extra_start 的约定长度是 expr_count + 1（CSR 前缀和）。
	//
	// ⚠ 这里曾崩过：直接用 `for i < expr_count: m_extra_start[i+1]`，
	//   但没校验 extra_start 的实际长度。当调用方传的 extra_start 比
	//   expr_count + 1 短时，i+1 就越界读 → ASan 报 heap-buffer-overflow，
	//   非 ASan 版则表现为随机段错误（signal 11，崩溃地址落在指令中间）。
	//   修法：循环上界取 min(expr_count, extra_start.size() - 1)。
	const int32_t extra_loop = MIN(expr_count, extra_start_size - 1);
	if (extra_loop > 0) {
		for (int32_t i = 0; i < extra_loop; ++i) {
			const int32_t s = m_extra_start[i];
			const int32_t e = m_extra_start[i + 1];
			if (s == e || s < 0 || e > extra_dst_size) {
				continue;
			}
			if (i >= primary_size) {
				continue;
			}
			const int32_t v2 = v[m_primary[i]];
			for (int32_t k = s; k < e; ++k) {
				const int32_t dst = m_extra_dst[k];
				if (dst >= 0 && dst < vcount) {
					v[dst] = v2;
				}
			}
		}
	}
}
