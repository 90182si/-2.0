class_name SWDrawData extends Object

#定义需要绘制的数据
var mapDatas:Array[SWBuildItemDefine] = []

func addOneDrawBuildDefine(axisPos:Vector2i,buildDefine:SWBuildDefine) -> void:
	var buildItemDefine:SWBuildItemDefine = SWDefine.SWBuildCreator(axisPos,buildDefine,0)
	mapDatas.append(buildItemDefine)
	pass
