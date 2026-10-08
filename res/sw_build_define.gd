class_name SWBuildDefine extends Resource


const atlasBuildBase = preload("res://res/建筑物底座.tres")

@export var atlasIcon:AtlasTexture
@export var atlasTextureOn:AtlasTexture
@export var atlasTextureOff:AtlasTexture
@export var buildName:String
@export var circuit_component_type:SwDefine.CircuitComponentType = 0

@export var build_pin:Array[SWBuildPinDefine]
