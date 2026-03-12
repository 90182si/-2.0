class_name SWDrawData extends Object

#定义需要绘制的数据
var mapDatas:Array[SWDefine.SWBuildItemDefine] = []

func addOneDrawBuildDefine(axisPos:Vector2i,buildDefine:SWBuildDefine) -> void:
	var buildItemDefine:SWDefine.SWBuildItemDefine = SWDefine.SWBuildItemDefine.new(axisPos,buildDefine,0)
	mapDatas.append(buildItemDefine)
	pass
