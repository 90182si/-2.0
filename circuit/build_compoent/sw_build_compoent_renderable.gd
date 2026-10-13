class_name SWBuildCompoentRenderable extends SWBuildCompoent
	
var buildRef:SWBuildItemDefine = null
var buildHasBase:bool = false
var buildHasAtlas:bool = false
var buildAtlasRotable:bool = true
var drawRect:Rect2
func setBuildRef(build:SWBuildItemDefine) -> void:
	buildRef = build
func getRenderParts() -> Array:
	var out:Array = []
	if buildHasBase:
		#非门等符号在图集中为黑色像素，乘法混色无法变红；改染可着色的灰色底板
		var baseColor:Color = Color()
		var baseUseColor:bool = false
		if buildRef.in_loop:
			baseColor = SwCommon.GetLoopColor()
			baseUseColor = true
		out.append({"rect":buildRef.buildDefine.atlasBuildBase.region,"offset":Vector2i.ZERO,"rotation":0,"color":baseColor,"use_color":baseUseColor})
	if buildRef.buildDefine and buildRef.buildDefine.build_pin.size() > 0:
		var wire:bool = false
		if buildRef.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.WIRE:
			var pinShowCount = 4
			for pinDir in 4:
				var net:SWNet = buildRef.getCircuitCompoent().pinNetMap.get(pinDir,null)
				if not net:
					pinShowCount -= 1
			if buildRef.buildState.state != SwDefine.BuildState.HOLDING and pinShowCount!=0:
				wire = true
		for p:SWBuildPinDefine in buildRef.buildDefine.build_pin:
			var net:SWNet = buildRef.getCircuitCompoent().pinNetMap.get(posmod(p.pin_dir+buildRef.rotation,4),null)
			var color:Color
			var useColor = false
			if net:
				useColor = true
				var wireName:String = ""
				if net.wireGroup == null:
					pass
				else:
					wireName = net.wireGroup.wireName
				var colorArr = SwCommon.GetWireColor(wireName)
				if net.curSignal == SwDefine.CircuitSignal.LOW:
					color = colorArr[0]
				elif net.curSignal == SwDefine.CircuitSignal.HIGH:
					color = colorArr[1]
			elif wire == true:
				continue
			#处于循环依赖中的元件/电线，引脚统一着红色
			if buildRef.in_loop:
				color = SwCommon.GetLoopColor()
				useColor = true
			var r:Rect2 = p.wire_pin.region
			out.append({"rect":r,"offset":p.cell_offset,"rotation":posmod(p.pin_dir+buildRef.rotation,4),"color":color,"use_color":useColor})
	if buildHasAtlas:
		##处于循环依赖中的元件，主体贴图着红色
		var atlasColor:Color = Color()
		var atlasUseColor:bool = false
		#if buildRef.in_loop:
			#atlasColor = SwCommon.GetLoopColor()
			#atlasUseColor = true
		if buildAtlasRotable:
			out.append({"rect":drawRect,"offset":Vector2i.ZERO,"rotation":buildRef.rotation,"color":atlasColor,"use_color":atlasUseColor})
		else:
			out.append({"rect":drawRect,"offset":Vector2i.ZERO,"rotation":0,"color":atlasColor,"use_color":atlasUseColor})
	return out
