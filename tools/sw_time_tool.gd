extends Node

var start_us:int = 0
var itemGapTimeMap:Dictionary = {}
var itemGapTimeMapBegin:Dictionary = {}

func getTime() -> int:
	start_us = Time.get_ticks_usec()
	return start_us

func getGapTime(us:int = start_us) -> float:
	var end_us := Time.get_ticks_usec()
	var cost_us := end_us - us
	var cost_ms := cost_us / 1000.0
	var cost_s := cost_us / 1000000.0
	start_us = Time.get_ticks_usec()
	return cost_s

func addItemGapTimeBegin(name:String) -> void:
	itemGapTimeMapBegin[name]=getTime()
	if not itemGapTimeMap.has(name):
		itemGapTimeMap[name] = 0
	
func addItemGapTimeEnd(name:String) -> void:
	if not itemGapTimeMapBegin.has(name):
		assert(false,"[%1]没有添加起始时间"%[name])
		return
	itemGapTimeMap[name]+=getGapTime(itemGapTimeMapBegin[name])
	
func printGapTimes() -> void:
	for name in itemGapTimeMap.keys():
		print("[%s]耗时:%.6f s"%[name,itemGapTimeMap[name]])
	itemGapTimeMap.clear()
