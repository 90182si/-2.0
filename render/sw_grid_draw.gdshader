shader_type canvas_item;
uniform sampler2D srcImg;
uniform sampler2D styleTex;    // texel[styleId] = (x, y, w, h)
uniform sampler2D signalTex;   // signalTex[texel(nid)] = rgba 颜色（4096 列 × 16 行网格，兼容 16384 边长上限的 GPU）
uniform int signalCols : hint_range(1, 65536) = 4096;  // 须与 SWSignalTexture.TEX_COLS 一致
varying vec4 custom_data;

void vertex() {
	custom_data = INSTANCE_CUSTOM;
}

void fragment() {
	// 1. 从 INSTANCE_CUSTOM.x 解码 styleId
	//    注意：GLSL 的 int() 向零截断，int(-1.0 + 0.5) == 0 会绕过负数哨兵判定，
	//    因此必须用原始 float 的符号判断 -1（未登记）。
	float stylef = custom_data.x;
	int sid = int(stylef + 0.5);

	// 保护：style_id < 0 表示未登记，输出品红色半透明便于视觉排查
	if (stylef < 0.0) {
		COLOR = vec4(1.0, 0.0, 1.0, 0.5);
	} else {
		// 2. 从 styleTex 查找图集 rect
		vec4 rect = texelFetch(styleTex, ivec2(sid, 0), 0);

		float beginX = rect.x;
		float beginY = rect.y;
		float width  = rect.z;
		float height = rect.w;
		float textureWidth  = float(textureSize(srcImg, 0).x);
		float textureHeight = float(textureSize(srcImg, 0).y);

		// Avoid sampling bleeding from neighboring tiles (atlas seams):
		// shrink the sampling rect by a small padding (in pixels) on all sides.
		// 0.5 px is usually enough for linear filtering; increase to 1.0~2.0 if needed.
		float pad_px = 0.5;

		// Clamp padding so it never inverts the rect.
		float pad_x = min(pad_px, max(0.0, (width  * 0.5) - 0.001));
		float pad_y = min(pad_px, max(0.0, (height * 0.5) - 0.001));

		float beginPreX = (beginX + pad_x) / textureWidth;
		float beginPreY = (beginY + pad_y) / textureHeight;
		float endPreX   = (beginX + width  - pad_x) / textureWidth;
		float endPreY   = (beginY + height - pad_y) / textureHeight;

		vec2 my_uv = UV;
		my_uv.x = mix(beginPreX, endPreX, my_uv.x);
		my_uv.y = mix(beginPreY, endPreY, my_uv.y);

		vec4 srcColor = texture(srcImg, my_uv);

		// 5. 从 INSTANCE_CUSTOM.y 解码 netId，信号着色
		//    同样用 float 符号判断 -1 哨兵（地图/本体/底座无信号），避免 int 截断把 -0.5 变成 0。
		float netf = custom_data.y;
		int nid = int(netf + 0.5);
		vec4 color;
		if (netf >= 0.0) {
			color = texelFetch(signalTex, ivec2(nid % signalCols, nid / signalCols), 0) * COLOR;
		} else {
			color = COLOR;
		}

		// 7. 乘法混色语义不变
		srcColor.rgb *= color.rgb;
		// 8. alpha 合并公式原样保留
		srcColor.a = srcColor.a * color.a;

		COLOR = srcColor;
	}
}
