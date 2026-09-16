class_name SWNet extends RefCounted

#输入
var wireGroup:SWDefine.SWWireGroup = null
#{SWBuildItemDefine,SWDefine.SW_Dir}
var _drivers:Array = []
#输出
#{SWBuildItemDefine,SWDefine.SW_Dir}
var _loads:Array = []

#func setWireGroup
func _init() -> void:
	wireGroup = SWDefine.SWWireGroup.new()

func addWireBuild(build:SWBuildWire) -> void:
	wireGroup.addWireBuild(build)
	build.net = self
	
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
		var circuitCompoent:SWBuildCompoentCircuit = build.getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
		if circuitCompoent:
			circuitCompoent.pinNetMap[pinDir] = self
			
func setNet(drivers:Array,loads:Array) -> void:
	_drivers.append_array(drivers)
	_loads.append_array(loads)
	setBuildNet(drivers)
	setBuildNet(loads)
	pass
