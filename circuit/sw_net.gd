class_name SWNet extends RefCounted

var curSignal:SwDefine.CircuitSignal
var netId:int = -1
var paintedSignal: int = -999  # 上次写入纹理的电平，-999=未画
#输入
var wireGroup:SwDefine.SWWireGroup = null
#{SWBuildItemDefine,SwDefine.SW_Dir}
var _drivers:Array = []
#输出
#{SWBuildItemDefine,SwDefine.SW_Dir}
var _loads:Array = []

#func setWireGroup
func _init() -> void:
	wireGroup = SwDefine.SWWireGroup.new()

func getDrivers() -> Array:
	return _drivers

func getLoads() -> Array:
	return _loads

func addDriver(driver:Dictionary) -> void:
	_drivers.append(driver)
	setBuildNet([driver])
	
func addLoader(load:Dictionary) -> void:
	_loads.append(load)
	setBuildNet([load])
	
func setBuildNet(driversAndLoads:Array) -> void:
	for driver:Dictionary in driversAndLoads:
		var build = driver.get_or_add("build",null)
		var pinDir = driver.get_or_add("pinDir",null)
		if not build:
			continue
		var circuitCompoent:SWBuildCompoentCircuit = build.getCircuitCompoent()
		if circuitCompoent:
			circuitCompoent.pinNetMap[pinDir] = self
			
func setNet(drivers:Array,loads:Array) -> void:
	_drivers.append_array(drivers)
	_loads.append_array(loads)
	setBuildNet(drivers)
	setBuildNet(loads)
	pass
