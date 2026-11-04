#ifndef SW_EXPR_EVAL_H
#define SW_EXPR_EVAL_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/array.hpp>

#include <vector>

using namespace godot;

// 表达式 DAG 的求值器（热路径下沉到原生代码）。
//
// 与 GDScript 版 SWExprProgram.evaluate() 语义完全一致，只是把三层循环搬到 C++。
class SWExprEval : public RefCounted {
	GDCLASS(SWExprEval, RefCounted)

	// 运算类型（与 SWExprProgram 的 EX_* 一致）
	enum {
		EX_NOT = 1,
		EX_AND = 2,
		EX_CONST = 3,
		EX_ALIAS = 4,
	};

	// 分段执行表
	PackedInt32Array seg_op;
	PackedInt32Array seg_start;
	PackedInt32Array seg_count;
	PackedInt32Array seg_dst;
	PackedInt32Array seg_src0;
	PackedInt32Array seg_src1;
	PackedInt32Array seg_n;
	PackedInt32Array seg_off;
	PackedInt32Array seg_const;
	PackedInt32Array src_flat;
	// 附加写目标
	PackedInt32Array extra_start;
	PackedInt32Array extra_dst;
	PackedInt32Array primary;

	int32_t expr_count = 0;
	int32_t seg_total = 0;   // 段数（注意不要和 get_seg_count() 同名冲突）
	bool uploaded = false;

	// 注意：不在 upload() 时缓存裸指针。
	// 曾缓存 m_seg_op = seg_op.ptr()，但当 PackedInt32Array 成员被重新赋值/写时复制时
	// 底层缓冲会迁移，缓存的指针变成悬空 → 求值时直接段错误（实测崩溃）。
	// 改为每次 evaluate() 开头从成员取指针，开销可忽略（每拍每电路一次）。

protected:
	static void _bind_methods();

public:
	SWExprEval();
	~SWExprEval();

	// 灌入执行表（编译期一次）。返回 true 表示成功。
	//
	// ⚠ 只用**一个** Array 参数，不要拆成 13 个 PackedInt32Array 形参。
	//   实测：14 个 packed array 形参经过 godot-cpp 绑定层 + x64 栈传参时，
	//   会出现返回地址被破坏导致的 signal 11（崩溃地址落在 mov qword ptr [rsp+90h]
	//   指令中间，说明栈已坏，不是正常调用路径）。
	//   打包成 Array 后传参只剩一个 Variant，彻底绕开这个问题。
	//
	// tables[0..12] 依次为：
	//   seg_op, seg_start, seg_count, seg_dst, seg_src0, seg_src1,
	//   seg_n, seg_off, seg_const, src_flat, extra_start, extra_dst, primary
	// tables[13] = expr_count（int）
	//
	// 按值传 Array（不是 const Array &）：godot-cpp 的 PtrToArg 对引用形参与值形参
	// 走不同转换路径，引用形式返回值时容易留下悬空引用。
	bool upload(Array p_tables);

	// 每拍求值。C++ 内部持有值缓冲（values），避免每拍跨越绑定层搬运数组。
	// 调用流程：
	//   set_values(ev)   ← 把 GDScript 的 vals 灌进来（每拍一次 memcpy）
	//   evaluate()
	//   get_values()     ← 取回结果（每拍一次，返回值是引用计数共享的副本）
	void set_values(const PackedInt32Array &p_vals);
	void evaluate();
	// 取回结果（返回独立副本，与内部缓冲彻底隔离）
	PackedInt32Array get_values() const {
		PackedInt32Array out;
		const int32_t n = (int32_t)values.size();
		out.resize(n);
		int32_t *dst = out.ptrw();
		for (int32_t i = 0; i < n; ++i) {
			dst[i] = values[i];
		}
		return out;
	}

	// 直接按原 slot 读一个值（回填时逐个取值，避免整表拷回）
	int32_t get_slot_value(int32_t p_slot) const {
		return (p_slot >= 0 && p_slot < (int32_t)values.size()) ? values[p_slot] : 0;
	}

	// 执行表规模（诊断）
	int32_t get_expr_count() const { return expr_count; }
	int32_t get_seg_count() const { return seg_total; }

	// 值缓冲（长度 = 原 slot 数）。
	// 用 std::vector 而不是 PackedInt32Array：PackedInt32Array 的底层缓冲会在
	// 赋值/写时复制时迁移，ptrw() 拿到的指针下次调用就可能悬空
	// （实测导致偶发段错误，且难以复现）。std::vector 的生命周期完全由本对象掌控。
	std::vector<int32_t> values;

};

#endif // SW_EXPR_EVAL_H
