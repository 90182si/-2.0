# 性能测试脚本
# 运行方式：在Godot编辑器中创建一个Node并附加此脚本

extends Node

@onready var test_button = Button.new()

func _ready():
	# 创建测试按钮
	test_button.text = "测试 getBuildsByRect 性能"
	test_button.position = Vector2(50, 50)
	test_button.size = Vector2(200, 50)
	test_button.pressed.connect(_on_test_button_pressed)
	add_child(test_button)
	
	print("性能测试脚本已准备就绪")
	print("点击按钮或按 T 键开始测试")

func _on_test_button_pressed():
	perform_performance_test()

func perform_performance_test():
	print("\n=== 开始 getBuildsByRect 性能测试 ===")
	
	# 获取SWBuildManager实例
	var build_manager = SWDefine.SWBuildManager.new()
	
	# 创建一些测试数据
	print("正在创建测试数据...")
	var start_time = Time.get_ticks_msec()
	
	# 模拟添加一些建筑
	for i in range(100):
		var pos = Vector2i(randi() % 2048, randi() % 2048)
		var build_def = SWDefine.SWBuildDefine.new()
		build_def.buildName = "测试建筑_" + str(i)
		var build = SWDefine.SWBuildItemDefine.new(pos, build_def)
		build_manager.addBuild(build)
	
	var setup_time = Time.get_ticks_msec() - start_time
	print("测试数据创建完成，耗时: ", setup_time, "ms")
	print("总建筑数量: ", build_manager.chunkMap.size())
	
	# 测试不同大小的区域
	var test_regions = [
		Rect2i(Vector2i(0, 0), Vector2i(256, 256)),    # 小区域
		Rect2i(Vector2i(0, 0), Vector2i(512, 512)),    # 中等区域
		Rect2i(Vector2i(0, 0), Vector2i(1024, 1024)),  # 大区域
	]
	
	for region in test_regions:
		build_manager.test_getBuildsByRect_performance(region)
	
	print("=== 性能测试完成 ===\n")

func _input(event):
	if event.is_action_pressed("TEST_PERFORMANCE"):
		perform_performance_test()