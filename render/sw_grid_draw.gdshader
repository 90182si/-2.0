shader_type canvas_item;
uniform sampler2D srcImg;
// 实例自带的图集 rect 是「全分辨率像素」坐标；换 LOD 图集时等比放大 rect 坐标。
// 只改这个 uniform 不会动实例缓冲，建筑不会重绘。
uniform float atlas_scale = 1.0;
// 图集 rect 纹理：2×N RGBAF，texel[styleId, row] = (x, y, w, h)，row0=off/低帧、row1=on/高帧。
uniform sampler2D styleTex;
// 信号电平纹理：TEX_COLS×TEX_ROWS R8，texel[netId] = 0/1。custom_data.y 即 net_id。
uniform sampler2D signalBits;
// 调色板纹理：2×P RGBA8，texel(level, palette_id) = low/high 绝对色。custom_data.z 即 palette_id。
uniform sampler2D paletteTex;
uniform int signalCols = 4096;   // 必须与 SWSignalTexture.TEX_COLS 逐字一致
// LOD 冻结开关：1.0 时连线统一 HIGH 色（等价旧 LOD 冻结语义，由 SwAtlas 按 is_lod_active 设置）。
// 仅作用于非帧分支（连线/端子信号色）；帧建筑（LED/寄存器/非门/按钮）不冻结，任何 LOD 下显示最新电平。
uniform float signalFrozen = 0.0;
varying vec4 custom_data;

void vertex() {
	custom_data = INSTANCE_CUSTOM;
}

void fragment() {
	vec4 color = COLOR;
	// custom_data = [style_id, net_id, palette_id, flags]
	// 判负必须用原始 float 符号（int(-1.0+0.5)==0 会绕过哨兵判定，曾踩坑）
	float stylef = custom_data.x;
	float netf = custom_data.y;
	// flags 位 0：帧部件（LED/寄存器/非门/按钮的亮灭主体）。
	// 帧选择电平来自信号纹理帧槽（custom_data.y），颜色不乘调色板（图集帧自带绝对色）
	bool is_frame = mod(custom_data.w, 2.0) > 0.5;
	if (stylef < 0.0) {
		// 未登记的 style 哨兵（惰性注册下正常路径不会出现）
		COLOR = vec4(1.0, 0.0, 1.0, 0.5);
	} else {
		int sid = int(stylef + 0.5);
		vec4 rect;
		if (is_frame) {
			// 帧选择：帧槽电平 → 选 on(1)/off(0) 行。
			// 帧切换零上传（只写 64KB 信号纹理），LOD 冻结不适用于帧建筑：
			// 寄存器/LED/非门/按钮必须任何 LOD 下都显示最新电平（与「冻结期间信号纹理照常更新」一致）。
			int fid = int(netf + 0.5);
			float lv = texelFetch(signalBits, ivec2(fid % signalCols, fid / signalCols), 0).r;
			int row = int(lv + 0.5);
			rect = texelFetch(styleTex, ivec2(sid, row), 0);
		} else {
			rect = texelFetch(styleTex, ivec2(sid, 0), 0);
			// 信号色：net_id >= 0 时最终显示色 = 图集像素 × palette[level] × 实例 COLOR
			// 三层里只有 palette 是绝对色（GetWireColor），实例 COLOR 烘焙为 tint（白/选中/环路），不得再乘绝对色。
			if (netf >= 0.0) {
				int nid = int(netf + 0.5);
				float lv = signalFrozen > 0.5 ? 1.0 : texelFetch(signalBits, ivec2(nid % signalCols, nid / signalCols), 0).r;
				int level = int(lv + 0.5);
				int pal = int(custom_data.z + 0.5);
				vec4 sig = texelFetch(paletteTex, ivec2(level, pal), 0);
				color = sig * COLOR;
			}
		}
		float beginX = rect.x / atlas_scale;
		float beginY = rect.y / atlas_scale;
		float width = rect.z / atlas_scale;
		float height = rect.w / atlas_scale;
		float textureWidth = float(textureSize(srcImg, 0).x);
		float textureHeight = float(textureSize(srcImg, 0).y);

		// Avoid sampling bleeding from neighboring tiles (atlas seams):
		// shrink the sampling rect by a small padding (in pixels) on all sides.
		// 0.5 px is usually enough for linear filtering; increase to 1.0~2.0 if needed.
		float pad_px = 0.5 * atlas_scale;

		// Clamp padding so it never inverts the rect.
		float pad_x = min(pad_px, max(0.0, (width  * 0.5) - 0.001));
		float pad_y = min(pad_px, max(0.0, (height * 0.5) - 0.001));

		float beginPreX = (beginX + pad_x) / textureWidth;
		float beginPreY = (beginY + pad_y) / textureHeight;
		float endPreX = (beginX + width  - pad_x) / textureWidth;
		float endPreY = (beginY + height - pad_y) / textureHeight;

		vec2 my_uv = UV;
		my_uv.x = mix(beginPreX, endPreX, my_uv.x);
		my_uv.y = mix(beginPreY, endPreY, my_uv.y);

		vec4 srcColor = texture(srcImg, my_uv);
		srcColor.rgb = srcColor.rgb*color.rgb;
		srcColor.a = srcColor.a*color.a;
		COLOR = srcColor;
	}
}
