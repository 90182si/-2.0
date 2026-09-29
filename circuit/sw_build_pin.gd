class_name SWBuildPin extends Resource

const wire_pin = preload("res://res/电线端子.tres")

@export var cell_offset:Vector2i = Vector2i.ZERO
@export var pin_dir:SwDefine.SW_Dir
@export var pin_define:SwDefine.CircuitPinType
