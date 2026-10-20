class_name SWBuildCompoentRenderable extends SWBuildCompoent

# ========== 性能计数器（static，不持久化） ==========
static var s_get_render_parts_call_count: int = 0

var buildRef:SWBuildItemDefine = null
var buildHasBase:bool = false
var buildHasAtlas:bool = false
var buildAtlasRotable:bool = true
var drawRect:Rect2

var drawIndex:int = 0

# ========== 渲染部件缓存 ==========
# 区块重绘时块内所有建筑都会调用 getRenderParts()，但绝大多数建筑本次并未变化。
# 用脏标记缓存部件列表，只有当该建筑的渲染状态（信号/旋转/环路/连接等）变化时才重建。
var _renderPartsCache: Array = []
var _renderPartsDirty: bool = true
# R3.2：主体贴图（drawRect）切换只需覆写 body part，不必重建引脚/底座/主体整份数组
var _bodyRectDirty: bool = false
# R3.4：style 补丁已下发但缓存里的 body style 仍是旧值——整块重填前须用 _applyBodyRect 纠正
var _bodyStylePending: bool = false
# _buildRenderParts 记录的主体 part 区间（[start, count)，-1 表示该建筑没有主体 part）
var _bodyPartsStart: int = -1
var _bodyPartsCount: int = 0

func markRenderPartsDirty() -> void:
	_renderPartsDirty = true
	# 整份重建会读当前 drawRect，视觉补丁标记随之作废
	_bodyRectDirty = false
	_bodyStylePending = false

## R3.2：主体贴图换了（LED 亮灭、非门/寄存器/按钮换 on/off 图）——只做原地补丁
func markBodyRectDirty() -> void:
	if _renderPartsDirty or _bodyPartsCount == 0:
		return
	_bodyRectDirty = true

#供信号变化路径查询：仅当渲染缓存已失效（drawRect 等视觉状态真变化）时才需要重建几何层
func isRenderPartsDirty() -> bool:
	return _renderPartsDirty or _bodyRectDirty

## R3.4：只换了主体贴图（结构未变）时，随补丁下发 [style_id, bodyStart, bodyCount]，
## 主线程不再复制 parts 数组与部件字典。返回 [] 表示不可走该快速通道，须下发 parts 快照。
## 下发后缓存里的 body style 仍是旧值，但不会读错：整块重填经 getRenderParts()
## 看到 _bodyStylePending 会先补写，而补丁路径只按这里的 style_id 覆写缓冲中那几行。
func getStylePatch() -> Array:
	if _renderPartsDirty or not _bodyRectDirty or _bodyPartsCount == 0:
		return []
	var style_tex: SWStyleTexture = SWStyleTexture.instance
	var new_style_id: int = style_tex.get_style_id(drawRect) if style_tex else -1
	if new_style_id < 0:
		return []
	_bodyRectDirty = false
	_bodyStylePending = true
	return [new_style_id, _bodyPartsStart, _bodyPartsCount]

## 已发布的 parts 数组及其部件字典一律视为只读：工作线程可能正在读上一份快照。
## 因此视觉补丁采用 copy-on-write——复制指针数组、只为 body part 新建字典。
func getRenderParts() -> Array:
	if not _renderPartsDirty:
		if _bodyRectDirty or _bodyStylePending:
			_applyBodyRect()
		return _renderPartsCache
	_renderPartsCache = _buildRenderParts()
	_renderPartsDirty = false
	_bodyRectDirty = false
	_bodyStylePending = false
	return _renderPartsCache

## R3.2：把新的 drawRect 写进 body part 区间，引脚/底座 part 原样复用。
## R3.4 后换贴图不再走这里（改由 getStylePatch 下发单个 style），
## 只有整块重填读到待补的 body 时才会执行这次 copy-on-write。
func _applyBodyRect() -> void:
	_bodyRectDirty = false
	_bodyStylePending = false
	var style_tex: SWStyleTexture = SWStyleTexture.instance
	var new_style_id: int = style_tex.get_style_id(drawRect) if style_tex else -1
	var flags: int = 0
	if buildRef.in_loop:
		flags |= 1
	if buildRef.buildState.state == SwDefine.BuildState.HOLDING:
		flags |= 2
	var body_rot: int = buildRef.rotation if buildAtlasRotable else 0
	var next: Array = _renderPartsCache.duplicate()
	for k in range(_bodyPartsCount):
		var idx: int = _bodyPartsStart + k
		if idx >= next.size():
			break
		var old: Dictionary = next[idx]
		var part: Dictionary = old.duplicate()
		part["rect"] = drawRect
		part["style_id"] = new_style_id
		part["rotation"] = body_rot
		part["flags"] = flags
		next[idx] = part
	_renderPartsCache = next

func setBuildRef(build:SWBuildItemDefine) -> void:
	buildRef = build
func _buildRenderParts() -> Array:
	var out:Array = []
	var flags: int = 0
	if buildRef.in_loop:
		flags |= 1  # bit0 = in_loop
	if buildRef.buildState.state == SwDefine.BuildState.HOLDING:
		flags |= 2  # bit1 = holding
	var style_tex: SWStyleTexture = SWStyleTexture.instance
	# ---- T3.5: 多格铺格 — 获取 footprint ----
	var fp: Vector2i = buildRef.getFootprint() if buildRef else Vector2i.ONE
	# ========== 1. 引脚 part（端子组，先于主体） ==========
	if buildRef.buildDefine and buildRef.buildDefine.build_pin.size() > 0:
		var wire:bool = false
		if buildRef.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.WIRE:
			var pinShowCount = 4
			for pinDir in 4:
				var net:SWNet = buildRef.getCircuitCompoent().pinNetMap.get(pinDir,null)
				if not net:
					pinShowCount -= 1
			if buildRef.buildState.state != SwDefine.BuildState.HOLDING and pinShowCount!=0:
				wire = true
		for p:SWBuildPinDefine in buildRef.buildDefine.build_pin:
			var net:SWNet = buildRef.getCircuitCompoent().pinNetMap.get(posmod(p.pin_dir+buildRef.rotation,4),null)
			var color:Color
			var useColor = false
			var net_id: int = -1
			if net:
				useColor = true
				net_id = net.netId
				var wireName:String = ""
				if net.wireGroup == null:
					pass
				else:
					wireName = net.wireGroup.wireName
				var colorArr = SwCommon.GetWireColor(wireName)
				# T1.4: 端子 color 改为烘焙 tint（mask 色，即 wireGroup 默认色/LOW 色）
				color = colorArr[0]
			elif wire == true:
				continue
			#处于循环依赖中的元件/电线，引脚统一着红色
			if buildRef.in_loop:
				color = SwCommon.GetLoopColor()
				useColor = true
			var r:Rect2 = p.wire_pin.region
			var pin_style_id: int = style_tex.get_style_id(r) if style_tex else -1
			# T3.5: 引脚 offset 改用旋转后 cell 偏移（1×1 时恒为 ZERO，向后兼容）
			var pin_offset: Vector2i = buildRef.getRotatedCellOffset(p)
			out.append({"rect":r,"offset":pin_offset,"rotation":posmod(p.pin_dir+buildRef.rotation,4),"color":color,"use_color":useColor,"net_id":net_id,"style_id":pin_style_id,"flags":flags})
	# ========== 2. 底座 part（多格展开） ==========
	if buildHasBase:
		#非门等符号在图集中为黑色像素，乘法混色无法变红；改染可着色的灰色底板
		var baseColor:Color = Color()
		var baseUseColor:bool = false
		if buildRef.in_loop:
			baseColor = SwCommon.GetLoopColor()
			baseUseColor = true
		var base_rect: Rect2 = buildRef.buildDefine.atlasBuildBase.region
		var base_style_id: int = style_tex.get_style_id(base_rect) if style_tex else -1
		for j in range(fp.y):
			for i in range(fp.x):
				out.append({"rect":base_rect,"offset":Vector2i(i,j),"rotation":0,"color":baseColor,"use_color":baseUseColor,"net_id":-1,"style_id":base_style_id,"flags":flags})
	# ========== 3. 主体 part（多格展开） ==========
	_bodyPartsStart = out.size()
	_bodyPartsCount = 0
	if buildHasAtlas:
		##处于循环依赖中的元件，主体贴图着红色
		var atlasColor:Color = Color()
		var atlasUseColor:bool = false
		#if buildRef.in_loop:
			#atlasColor = SwCommon.GetLoopColor()
			#atlasUseColor = true
		var body_style_id: int = style_tex.get_style_id(drawRect) if style_tex else -1
		var body_rot: int = buildRef.rotation if buildAtlasRotable else 0
		for j in range(fp.y):
			for i in range(fp.x):
				out.append({"rect":drawRect,"offset":Vector2i(i,j),"rotation":body_rot,"color":atlasColor,"use_color":atlasUseColor,"net_id":-1,"style_id":body_style_id,"flags":flags})
		_bodyPartsCount = out.size() - _bodyPartsStart
	else:
		_bodyPartsStart = -1
	# ========== 4. 容量监控 ==========
	if out.size() > SwDefine.MAX_RENDER_PARTS:
		push_warning("SWBuildCompoentRenderable: build '%s' produced %d parts (MAX_RENDER_PARTS=%d), may be truncated" % [buildRef.buildDefine.buildName if buildRef.buildDefine else "?", out.size(), SwDefine.MAX_RENDER_PARTS])
	return out
