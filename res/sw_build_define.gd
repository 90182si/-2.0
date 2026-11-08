class_name SWBuildDefine extends Resource


const atlasBuildBase = preload("res://res/建筑物底座.tres")

@export var atlasIcon:AtlasTexture
@export var atlasTextureOn:AtlasTexture
@export var atlasTextureOff:AtlasTexture
@export var buildName:String
@export var circuit_component_type:SwDefine.CircuitComponentType = 0
# 外部接口元件的默认名称（clk / move / rotation）；非接口元件留空。
# 名称是实例属性（落在建筑实例上并随存档序列化），这里只是放置时的初值
@export var default_io_name:String = ""

@export var build_pin:Array[SWBuildPinDefine]
