class_name SWDrawData extends Object

#定义需要绘制的数据
var mapDatas:Array[SWBuildItemDefine] = []

func addOneDrawBuildDefine(axisPos:Vector2i,buildDefine:SWBuildDefine,rot:SwDefine.SW_Dir=0) -> void:
	var buildItemDefine:SWBuildItemDefine = SwDefine.SWBuildCreator(axisPos,buildDefine,rot)
	mapDatas.append(buildItemDefine)
	pass
