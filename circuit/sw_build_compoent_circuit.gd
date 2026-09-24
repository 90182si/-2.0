class_name SWBuildCompoentCircuit extends SWBuildCompoent

#var expr:String = ""
#0b1111代表四边都有连接
var pinConBit:int = 0
#0b1111代表四边都是输出口
#0b1xxxx代表是电线
var pinDefineBit:int = 0
#0b1111代表四边都输出高电平
var pinValueBit:int = 0

var linkedPort:int = 0

var pinNetMap:Dictionary[SwDefine.SW_Dir,SWNet] = {}
var pinExprMap:Dictionary[SwDefine.SW_Dir,SwDefine.SWCircuitStruct] = {}

func _init() -> void:
	#pinExprMap = SwDefine.SWCircuitStruct.new()
	pass

func iterate_bracket_text(swBuildManager:SWBuildManager,input: String) -> void:
	var regex = RegEx.create_from_string(r"\[(.*?)\]")
	var rmatch: RegExMatch
	
	while true:
		rmatch = regex.search(input, 0)
		if rmatch == null:
			break
		var content = int(rmatch.get_string(1))
		var contentID = content.split(":")[0]
		var contentDir = content.split(":")[1]
		print("找到：", content)
		var build = swBuildManager.getBuildById(contentID)
		if build:
			var value = build.getValue(contentDir)
			if value == SwDefine.CircuitSignal.LOW or value == SwDefine.CircuitSignal.NONE:
				input.replace(content,"0")
			elif value == SwDefine.CircuitSignal.HIGH:
				input.replace(content,"1")
		# 下一次搜索从本次匹配结束位置往后走
		#start_pos = rmatch.get_end()
	print(input)
		
func getValue(dir:SwDefine.SW_Dir) -> SwDefine.CircuitSignal:
	var sig:SwDefine.CircuitSignal = SwDefine.CircuitSignal.NONE
	if not pinExprMap.has(dir):
		return sig
	var cirStr:SwDefine.SWCircuitStruct = pinExprMap[dir]
	var v = SwCommon.EvalStruct(cirStr)
	if v == 1:
		sig = SwDefine.CircuitSignal.HIGH
	else:
		sig = SwDefine.CircuitSignal.LOW
	return sig

func ff(cirStruct:SwDefine.SWCircuitStruct,visited:Dictionary = {}) -> Array:
	var result:Array = []
	if cirStruct == null or visited.has(cirStruct):
		return result
	visited[cirStruct]=true
	for arg in cirStruct.args:
		if arg is SwDefine.SWBuildPinStruct:
			#叶子：直接依赖的引脚
			result.append(arg.build.id)
		elif arg is SwDefine.SWCircuitStruct:
			#子树：继续向下递归
			result.append_array(ff(arg,visited))
	return result
		
func getDependBuildIds() -> Array[int]:
	var ids:Array[int] = []
	for dir in range(3,-1,-1):
		if pinExprMap.has(dir):
			ids.append_array(ff(pinExprMap[dir]))
	return ids

func setPinDefine(pinDir:SwDefine.SW_Dir,define:SwDefine.CircuitPinType) -> void:
	if define == SwDefine.CircuitPinType.INPUT:
		pinDefineBit = pinDefineBit & (0b11111-(1<<pinDir))
	elif define == SwDefine.CircuitPinType.OUTPUT:
		pinDefineBit = pinDefineBit | (1<<pinDir)
	elif define == SwDefine.CircuitPinType.WIRE:
		pinDefineBit = 0b10000
	pinConBit = pinConBit | (1<<pinDir)
	
func setPinValue(pinDir:SwDefine.SW_Dir,value:SwDefine.CircuitSignal) -> void:
	if value == SwDefine.CircuitSignal.HIGH:
		pinValueBit = pinValueBit & (1<<(3-pinDir))
	elif value == SwDefine.CircuitSignal.LOW or value == SwDefine.CircuitSignal.NONE:
		pinValueBit = pinValueBit & (0b11111-(1<<(3-pinDir)))

func isPort(rotation:SwDefine.SW_Dir,value:int) -> bool:
	value = posmod(value-rotation,4)
	return pinConBit&(1<<value) > 0

func portIsOutput(rotation:SwDefine.SW_Dir,value:int) -> bool:
	var newValue = posmod(value - rotation, 4)
	if not isPort(rotation,value):
		return false
	if pinDefineBit >= 16:
		return true
	return pinDefineBit&(1<<newValue) > 0
	
func portIsInput(rotation:SwDefine.SW_Dir,value:int) -> bool:
	var newValue = posmod(value - rotation, 4)
	if not isPort(rotation,value):
		return false
	if pinDefineBit >= 16:
		return true
	return pinDefineBit&(1<<newValue) == 0

func isLinkedPort(rotation:SwDefine.SW_Dir,dir:SwDefine.SW_Dir) -> bool:
	var newValue = posmod(dir - rotation, 4)
	return (linkedPort&(1<<newValue)) > 0

func setLinkedPort(rotation:SwDefine.SW_Dir,dir:SwDefine.SW_Dir) -> void:
	var newValue = posmod(dir - rotation, 4)
	linkedPort|=(1<<newValue)
	
func resetPortState() -> void:
	linkedPort = 0
	pinNetMap = {}
	pinExprMap = {}
