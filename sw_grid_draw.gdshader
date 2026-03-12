shader_type canvas_item;
uniform sampler2D srcImg;
varying vec4 custom_data;

void vertex() {
	custom_data = INSTANCE_CUSTOM;
}

void fragment() {
	vec4 color = custom_data;
	float beginX = custom_data.x;
	float beginY = custom_data.y;
	float width = custom_data.z;
	float height = custom_data.w;
	float textureWidth = float(textureSize(srcImg, 0).x);
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
	float endPreX = (beginX + width  - pad_x) / textureWidth;
	float endPreY = (beginY + height - pad_y) / textureHeight;

	vec2 my_uv = UV;
	my_uv.x = mix(beginPreX, endPreX, my_uv.x);
	my_uv.y = mix(beginPreY, endPreY, my_uv.y);

	vec4 srcColor = texture(srcImg, my_uv);
	COLOR = srcColor;
}