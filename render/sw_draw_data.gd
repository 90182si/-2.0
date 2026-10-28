class_name SWDrawData extends Object

#定义需要绘制的数据
var mapDatas:Array[SWBuildItemDefine] = []

#手持数据只用于绘制，统一按预览建筑创建（不建电路组件）
func addOneDrawBuildDefine(axisPos:Vector2i,buildDefine:SWBuildDefine,rot:SwDefine.SW_Dir=0) -> void:
	var buildItemDefine:SWBuildItemDefine = SwDefine.SWBuildCreator(axisPos,buildDefine,rot,true)
	mapDatas.append(buildItemDefine)
	pass
