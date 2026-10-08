class_name SWBuildCompoentRenderable extends SWBuildCompoent
	
var buildRef:SWBuildItemDefine = null
var buildHasBase:bool = false
var buildHasAtlas:bool = false
var drawRect:Rect2
func setBuildRef(build:SWBuildItemDefine) -> void:
	buildRef = build
func getRenderParts() -> Array:
	var out:Array = []
	if buildHasBase:
		out.append({"rect":buildRef.buildDefine.atlasBuildBase.region,"offset":Vector2i.ZERO,"rotation":0,"color":Color(),"use_color":false})
	if buildRef.buildDefine and buildRef.buildDefine.build_pin.size() > 0:
		for p:SWBuildPinDefine in buildRef.buildDefine.build_pin:
			var r:Rect2 = p.wire_pin.region
			#SwCommon.getWireColor
			out.append({"rect":r,"offset":p.cell_offset,"rotation":posmod(p.pin_dir+buildRef.rotation,4),"color":Color(),"use_color":false})
	if buildHasAtlas:
		out.append({"rect":drawRect,"offset":Vector2i.ZERO,"rotation":buildRef.rotation,"color":Color(),"use_color":false})
	return out
