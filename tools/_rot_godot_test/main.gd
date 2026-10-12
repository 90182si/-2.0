extends Node2D

func _fill(buf: PackedFloat32Array, bi: int, t: Transform2D, rect: Rect2) -> void:
	var b := bi * 16
	buf[b + 0] = t.x.x
	buf[b + 1] = t.x.y
	buf[b + 2] = 0
	buf[b + 3] = t.origin.x
	buf[b + 4] = t.x.y
	buf[b + 5] = t.y.y
	buf[b + 6] = 0
	buf[b + 7] = t.origin.y
	buf[b + 8] = 1.0
	buf[b + 9] = 1.0
	buf[b + 10] = 1.0
	buf[b + 11] = 1.0
	buf[b + 12] = rect.position.x
	buf[b + 13] = rect.position.y
	buf[b + 14] = rect.size.x
	buf[b + 15] = rect.size.y

func _ready() -> void:
	RenderingServer.set_default_clear_color(Color(0.15, 0.15, 0.18, 1.0))
	var atlas: Texture2D
	var img := Image.new()
	var err := img.load("J:/godot/无限地图/tools/_rot_godot_test/图集4.png")
	if err != OK:
		print("ATLAS LOAD FAIL err=", err)
		get_tree().quit()
		return
	atlas = ImageTexture.create_from_image(img)
	var mmi := MultiMeshInstance2D.new()
	var mm := MultiMesh.new()
	var quad := QuadMesh.new()
	quad.set_size(Vector2(128, -128))   # 与真实项目一致的负Y尺寸
	mm.mesh = quad
	mm.use_colors = true
	mm.instance_count = 8
	mmi.multimesh = mm
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shader.gdshader")
	mat.set_shader_parameter("srcImg", atlas)
	mmi.material = mat
	add_child(mmi)

	var not_rect := Rect2(384, 0, 128, 128)     # 非门 off
	var tunnel_rect := Rect2(896, 0, 128, 128)  # 隧道 off
	var buf := PackedFloat32Array()
	buf.resize(8 * 16)

	# 第0行: 非门  rot0 / rot1(+90)
	_fill(buf, 0, Transform2D(deg_to_rad(0),    Vector2(128, 128)), not_rect)
	_fill(buf, 1, Transform2D(deg_to_rad(1*90), Vector2(512, 128)), not_rect)
	# 第1行: 隧道  rot0 / rot1(+90)
	_fill(buf, 2, Transform2D(deg_to_rad(0),    Vector2(128, 512)), tunnel_rect)
	_fill(buf, 3, Transform2D(deg_to_rad(1*90), Vector2(512, 512)), tunnel_rect)

	mm.buffer = buf
	mm.visible_instance_count = 4

	# 说明文字
	var labels := [
		["非门 rot0", 128, 40], ["非门 rot1(+90)", 512, 40],
		["隧道 rot0", 128, 424], ["隧道 rot1(+90)", 512, 424],
	]
	for l in labels:
		var lb := Label.new()
		lb.text = l[0]
		lb.position = Vector2(l[1] - 90, l[2])
		lb.add_theme_color_override("font_color", Color(1, 1, 0.4))
		add_child(lb)

	# 延迟截图
	await get_tree().create_timer(0.3).timeout
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://out.png")
	print("SAVED out.png size=", img.get_size())
	get_tree().quit()
