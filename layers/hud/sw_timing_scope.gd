class_name SWTimingScope extends Control

# ==========================================================================
# 电路时序图绘制（纯展示控件）
#
# 数据来源：机器人实体每半拍往 entity.timing 追**一条**样本。
# 每条 Vector4i(clk, move, rotation, acted)，两条一组 = 一拍：
# 高相位（clk=1，电路收到时钟沿，拍首）+ 低相位（clk=0，下降沿，半拍后）。
# 一拍两格，所以一屏的「拍数」是列数的一半。
# HUD 每帧把那份数组 + 当前相位进度（0..1）推给 set_samples()，这里只负责画。
#
# 排版：最新一格右边界钉在红线（游标）上，还没流完的那半拍只画一部分；
# 历史向左排，满了整体往左流。所以上升沿/下降沿都是从红线处冒出来再往左走，
# 两个边沿都能在红线位置被看到（一次性写两条样本时红线一拍跳两格，下降沿被跳过）。
#
# 四条**固定**轨：
#   clk       每半拍一格（方波，占空比 50%）
#   move      电路 move 输出
#   rotation  电路 rotation 输出
#   act       本拍真的动了吗
# clk 的边沿就是方波自己的竖线（与其他轨同一条画法），不另加三角/换色：
# 电平高低本身就把它分出来了，额外标记反而把波形挡得看不清。
# act 单独一轨的价值：move=1 但前面被别的机器人挡住时 act=0，
# 一眼能分辨「电路没输出」和「输出对了但走不了」。
#
# 固定四轨之外，玩家在 HUD 里选的监测信号（push、detect_sig_0..7、detect_res_0..7 ...）各占一轨：
# 轨道名与电平位图都由实体侧算好（entity.trace_names / entity.trace_masks）。
# 默认（玩家没选过）就是电路里 move/rotation 之外的输出名，以后电路再加输出名也不用改绘制代码。
# ==========================================================================

const ROW_H: int = 30
#轨道多了要能压缩：面板高度是固定的，行高不够就按可用高度均分
const MIN_ROW_H: int = 12
#一拍两条样本，列宽比「一拍一格」时窄：不然一屏只剩十几拍
const COL_W: int = 8
#左侧轨道名栏宽：按最长名字动态算（detect_sig_7 这种名字 58px 放不下）
const LEFT_PAD_MIN: int = 58
const LEFT_PAD_MAX: int = 150
const TOP_PAD: int = 6
#每几拍画一根刻度线：给「波形真的在滚」提供可见的参照物
const TICK_EVERY: int = 4
#固定四轨（下标 0..3 的样本字段顺序与 _track_level 对应）
const BASE_TRACKS: Array[String] = ["clk", "move", "rotation", "act"]
const BASE_COLORS: Array[Color] = [
	Color(0.45, 0.78, 1.0),
	Color(0.50, 1.0, 0.55),
	Color(1.0, 0.78, 0.32),
	Color(0.85, 0.85, 0.85),
]
#额外轨道配色（绑定电路里 move/rotation 之外的输出名，按顺序循环取色）
const EXTRA_COLORS: Array[Color] = [
	Color(1.0, 0.60, 0.85),
	Color(0.60, 0.95, 0.95),
	Color(0.95, 0.95, 0.55),
	Color(0.75, 0.70, 1.0),
	Color(1.0, 0.72, 0.55),
	Color(0.70, 0.95, 0.70),
	Color(0.95, 0.85, 0.65),
	Color(0.80, 0.80, 0.95),
]

#画布底色：**纯灰**，不做黑/灰交替条纹 ——
#条纹会跟波形跳变竖线混在一起，读码时容易把格子边界当信号边沿
const BG_COLOR: Color = Color(0.21, 0.21, 0.21, 1.0)

#实际画过多少次（测试用：headless 下也能断言波形真的被画了）
var draw_count: int = 0
#累计画过多少个 clk 跳变竖线（测试用：确认上升/下降沿真的落到了画布上）
var edge_draw_count: int = 0

var _samples: Array = []
#额外轨道：名字（实体给的，已排掉 move/rotation）与逐样本电平位图
var _trace_names: Array = []
var _trace_masks: Array = []
#左侧轨道名栏宽（按最长名字算，见 _apply_trace_names）
var _left_pad: int = LEFT_PAD_MIN
#上一次见过的采样序号：同号就不重画。
#为什么不用「样本数 + 末条」判断：样本封顶后，两拍输出完全一样时
#长度和末条都不变，波形就不会滚动，看上去像卡死了
var _last_seq: int = -1
#没传序号时的兜底：样本数与最后一条
var _last_size: int = -1
var _last_tail: Vector4i = Vector4i(-1, -1, -1, -1)
#窗口第一条对应的全局拍号（= timing_seq - 样本数）。
#底色/刻度的相位要用全局拍号算：用窗口内下标算的话，每回样本满了往后移，
#整个底色和刻度会跟着跳一下，看着反而像花屏
var _base_seq: int = 0
#当前半拍已经跑掉多少（0..1）：最新一格只画流过的那部分，右边贴游标。
#停着的时候是 1（最后一格画满），波形不会缩成一条线
var _frac: float = 1.0

func _ready() -> void:
	#纯展示，不能吃掉地图上的鼠标事件
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_recalc_layout()

#推入最新样本。直接持引用不复制：样本每半拍动一次，画的时候不会被同时改
#seq = 采样序号（entity.timing_seq）；传了就用它判断新增，否则兜底看末条
#frac = 当前半拍跑了多少（0..1）：最新一格从游标往左长出来，波形才能连续往左流
#names/masks = 额外轨道名 + 逐样本电平位图（与 samples 等长）
#返回 true 表示需要重画（有新样本 / 换了额外轨道 / 相位动了）
func set_samples(samples: Array, seq: int = -1, frac: float = 1.0,
		names: Array = [], masks: Array = []) -> bool:
	_samples = samples if samples != null else []
	_trace_masks = masks if masks != null else []
	#轨道清单变了：重算左栏宽与最小高度，并且强制重画（名字变了必须重画）
	var names_changed: bool = _apply_trace_names(names if names != null else [])
	var f: float = clampf(frac, 0.0, 1.0)
	#相位差异太小就不重画：停着的时候这里每帧都返回 false，面板零开销
	var phase_moved: bool = absf(f - _frac) > 0.002
	_frac = f
	if seq >= 0:
		if seq == _last_seq:
			return phase_moved or names_changed
		_last_seq = seq
		_last_size = _samples.size()
		_last_tail = _samples[_samples.size() - 1] if _samples.size() > 0 else Vector4i(-1, -1, -1, -1)
		_base_seq = maxi(0, seq - _samples.size())
		return true
	var n: int = _samples.size()
	var tail: Vector4i = _samples[n - 1] if n > 0 else Vector4i(-1, -1, -1, -1)
	if n == _last_size and tail == _last_tail:
		return phase_moved or names_changed
	_last_size = n
	_last_tail = tail
	return true

func get_sample_count() -> int:
	return _samples.size()

func clear_samples() -> void:
	_samples = []
	_trace_masks = []
	_last_seq = -1
	_last_size = -1
	_last_tail = Vector4i(-1, -1, -1, -1)
	_base_seq = 0
	_frac = 1.0
	queue_redraw()

#一屏能画多少拍
func visible_columns() -> int:
	return maxi(1, int((size.x - _left_pad) / float(COL_W)))

#轨道总数（固定四轨 + 额外输出轨）
func track_count() -> int:
	return _track_count()

#轨道名（下标即轨道号，测试/排障用）
func track_name(track: int) -> String:
	var all: Array = _all_names()
	return str(all[track]) if track >= 0 and track < all.size() else ""

func _track_count() -> int:
	return BASE_TRACKS.size() + _trace_names.size()

func _all_names() -> Array:
	var out: Array = []
	out.append_array(BASE_TRACKS)
	out.append_array(_trace_names)
	return out

#重算轨道清单。返回 true 表示清单真的变了（没变就完全不碰布局：
#set_samples 每帧都被调一次，量字体这种事不能每帧做）
func _apply_trace_names(names: Array) -> bool:
	var clean: Array = []
	for v in names:
		var s: String = str(v)
		#已经是固定基础轨的名字（clk/move/rotation/act）不能再画一遍：
		#否则会出现两条一模一样的波形，左栏还会同名两次
		if s.is_empty() or BASE_TRACKS.has(s):
			continue
		clean.append(s)
	if clean == _trace_names:
		return false
	_trace_names = clean
	_recalc_layout()
	return true

#按当前轨道名重算「左栏宽 + 最小高度」
func _recalc_layout() -> void:
	var font: Font = get_theme_default_font()
	if font == null:
		font = ThemeDB.fallback_font
	var font_size: int = maxi(8, get_theme_default_font_size() - 2)
	var w: int = LEFT_PAD_MIN
	for name: String in _all_names():
		w = maxi(w, int(font.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x) + 10)
	_left_pad = clampi(w, LEFT_PAD_MIN, LEFT_PAD_MAX)
	#最小高度只保证「每行还剩得下字」：真的摆不下的部分由面板/容器去裁
	var min_h: int = TOP_PAD * 2 + MIN_ROW_H * _track_count()
	if int(custom_minimum_size.y) != min_h:
		custom_minimum_size = Vector2(custom_minimum_size.x, min_h)

#行高：高度够就用固定行高，轨道多了（detect_sig_0..7 这种）按可用高度均分
func _row_h(count: int) -> float:
	if count <= 0:
		return float(ROW_H)
	if size.y <= 0:
		return float(ROW_H)
	return clampf((size.y - TOP_PAD * 2) / float(count), float(MIN_ROW_H), float(ROW_H))

func _track_color(track: int) -> Color:
	if track < BASE_COLORS.size():
		return BASE_COLORS[track]
	var k: int = track - BASE_COLORS.size()
	return EXTRA_COLORS[k % EXTRA_COLORS.size()]

#第 i 条样本在 track 轨上的电平（0/1）；固定四轨走 _track_level，其余查位图
func _level_at(i: int, track: int) -> int:
	if track < BASE_TRACKS.size():
		return _track_level(_samples[i], track)
	var k: int = track - BASE_TRACKS.size()
	if i < 0 or i >= _trace_masks.size():
		return 0
	return 1 if ((int(_trace_masks[i]) >> k) & 1) == 1 else 0

func _draw() -> void:
	draw_count += 1
	var font: Font = get_theme_default_font()
	if font == null:
		font = ThemeDB.fallback_font
	var font_size: int = maxi(8, get_theme_default_font_size() - 2)
	var count: int = _track_count()
	var row_h: float = _row_h(count)
	var height: float = TOP_PAD * 2 + row_h * count
	draw_rect(Rect2(Vector2(0, 0), Vector2(size.x, height)), BG_COLOR, true)

	var n: int = _samples.size()
	if n == 0:
		draw_string(font, Vector2(_left_pad, TOP_PAD + 16), "no beat yet",
				HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.65, 0.65, 0.65))
		return

	var cols: int = visible_columns()
	var start: int = maxi(0, n - cols)
	#游标（红线）位置：样本还没填满一屏时随样本数往右长，满了就钉在右端不动。
	#钉住很重要 —— 红线是「现在」的参照物，边沿从右往左流过它才看得清
	var x_now: float = float(_left_pad) + mini(n, cols) * COL_W
	_draw_time_marks(start, n, x_now, height)
	var i: int = start
	while i < n:
		var b: Vector2 = _cell_bounds(i, n, x_now)
		var x0: float = b.x
		var x1: float = b.y
		#窗口最左那一格会被切掉半截：从 _left_pad 起画，别糊到轨道名上
		var xa: float = maxf(x0, float(_left_pad))
		var t: int = 0
		while t < count:
			var y_hi: float = TOP_PAD + t * row_h + 3.0
			#行高被压缩时高低电平仍要分得开：至少留 MIN_ROW_H - 8 的摆幅
			var y_lo: float = y_hi + maxf(4.0, row_h - 8.0)
			var level: int = _level_at(i, t)
			var y: float = y_hi if level == 1 else y_lo
			if xa < x1:
				var color: Color = _track_color(t)
				draw_line(Vector2(xa, y), Vector2(x1, y), color, 2.0)
				#跳变处补一条竖线（所有轨同一画法），波形才不会断成两截。
				#前驱按**全局样本索引**取（i-1）：窗口最左那一格如果是跳变也该有竖线
				if i > 0:
					var prev: int = _level_at(i - 1, t)
					if prev != level:
						var yp: float = y_hi if prev == 1 else y_lo
						draw_line(Vector2(xa, yp), Vector2(xa, y), color, 2.0)
						if t == 0:
							edge_draw_count += 1
			t += 1
		i += 1

	var names: Array = _all_names()
	var t2: int = 0
	while t2 < count:
		var ty: float = TOP_PAD + t2 * row_h + row_h - 3.0
		draw_string(font, Vector2(2, ty), str(names[t2]),
				HORIZONTAL_ALIGNMENT_LEFT, _left_pad - 6, font_size, _track_color(t2))
		t2 += 1

#样本 i 在画布上的左右边界（Vector2(x0, x1)）。
#最新一格（i == n-1）只画已经流过的那部分（宽 _frac * COL_W），右边界钉在游标上：
#样本一到就从红线处冒出来，然后往左流走 —— 上升沿/下降沿都能在红线位置被看到。
#其余格子整格宽，从游标往左依次排开
func _cell_bounds(i: int, n: int, x_now: float) -> Vector2:
	if i >= n - 1:
		return Vector2(x_now - COL_W * _frac, x_now)
	var x1: float = x_now - (_frac + float(n - 2 - i)) * COL_W
	return Vector2(x1 - COL_W, x1)

#时间栅格：每 TICK_EVERY 拍一根刻度线 + 最新一格游标。
#为什么需要这些：clk 轨是周期信号，波形本身很规整，填满一屏后只是整体向左平移，
#没有参照物时肉眼很难看出它在走，容易误以为节拍器停了（底色不再弄交替条纹，
#参照物全部交给刻度线与游标）。
func _draw_time_marks(start: int, n: int, x_now: float, height: float) -> void:
	var i: int = start
	while i < n:
		var b: Vector2 = _cell_bounds(i, n, x_now)
		var xa: float = maxf(b.x, float(_left_pad))
		if xa < b.y:
			#一拍两条样本：全局样本号右移一位才是拍号
			var sample_no: int = _base_seq + i
			var beat_no: int = sample_no >> 1
			#刻度线只画在拍首格，而且必须整根落在画布内（被切掉半截的那格不画）
			if (sample_no & 1) == 0 and beat_no % TICK_EVERY == 0 and b.x >= float(_left_pad):
				draw_line(Vector2(b.x, 0), Vector2(b.x, height), Color(1, 1, 1, 0.12), 1.0)
		i += 1
	#最新一格游标（红线）：钉在「现在」的位置，边沿从右往左流过它
	draw_line(Vector2(x_now, 0), Vector2(x_now, height), Color(1.0, 0.45, 0.35, 0.85), 1.5)

#clk 的上升沿/下降沿**不另加标记**：方波自己的跳变竖线就够看（与其他三轨同一条画法），
#三角/分色会把波形挡得看不清。
#本函数保留的是「这个位置是不是沿」的口径，供测试与诊断用（不再参与绘制）。
#前驱一律按**全局样本索引**取（get_clk_edge 内部看 i-1），不受窗口左边界截断影响。
func get_clk_edge(i: int) -> int:
	if i <= 0 or i >= _samples.size():
		return 0
	var a: int = _track_level(_samples[i - 1], 0)
	var b: int = _track_level(_samples[i], 0)
	if a == b:
		return 0
	return 1 if b == 1 else -1

#窗口里某种边沿出现了几次（测试 / 诊断用）。kind：1 = 上升沿，-1 = 下降沿
func count_clk_edges(kind: int) -> int:
	var c: int = 0
	for i in range(1, _samples.size()):
		if get_clk_edge(i) == kind:
			c += 1
	return c

func _track_level(s: Vector4i, track: int) -> int:
	match track:
		0:
			return 1 if s.x != 0 else 0
		1:
			return 1 if s.y != 0 else 0
		2:
			return 1 if s.z != 0 else 0
	return 1 if s.w != 0 else 0
