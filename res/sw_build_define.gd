class_name SWBuildDefine extends Resource


const atlasBuildBase = preload("res://res/建筑物底座.tres")

@export var atlasIcon:AtlasTexture
@export var atlasTextureOn:AtlasTexture
@export var atlasTextureOff:AtlasTexture
@export var buildName:String
@export var circuit_component_type:SwDefine.CircuitComponentType = 0
@export var size:Vector2i = Vector2i(1, 1)  # 逻辑格尺寸（未旋转基准），缺省 1×1 兼容旧 .tres

@export var build_pin:Array[SWBuildPinDefine]
