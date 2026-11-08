class_name SWDrawManager extends Node

@onready var color_rect: ColorRect = $TestViewRect

#标准格子大小，如果是地图就需要*2
var _chunkSize:Vector2i = SwDefine.GRID_SIZE*SwDefine.CHUNK_SIZE
#区块实例，每个区块位置对应的区块对象
var _chunkInstance:Dictionary[Vector2i,SwDefine.SWDrawChunkData] = {}
#需要绘制区块的任务列表
var _pending_tasks:Dictionary[int,Dictionary] = {}
#记录当前视口大小（初始化为无限大，避免首次更新前删除所有任务）
var _curViewRect:Rect2 = Rect2(-1e9, -1e9, 2e9, 2e9)
# 缓存有建筑的 chunk 位置（ByContent 模式专用，避免频繁查询）
var _chunkHasBuildCache:Dictionary[Vector2i,bool] = {}
# 上次刷新时的「区块对齐视口」（起始区块 + 区块格数）。
# 视口只要在区块对齐尺度上没变，on_view_rect_changed 的全部副作用就是幂等的：
# _updateChunkCache 结果相同、待加载集合相同、卸载判定（keepRect 由对齐矩形 grow）
# 相同、推给电路的 keep_rect 相同。所以这时可以直接早退。
# 这是「中键拖动卡、WASD 也卡」的主因：以前每个鼠标事件（125~1000Hz）和每渲染帧
# 都把视口覆盖的区块格枚举 2~3 遍（缩到 -40 附近单层就 2600 格），即使一个格都没变。
var _last_begin_chunk:Vector2i = Vector2i(0x7FFFFFFF, 0x7FFFFFFF)
var _last_mmi_count:Vector2i = Vector2i.ZERO
var _view_rect_seeded:bool = false
#缓存是否过期
var _cacheDirty:bool = false
#需要添加到场景的对象
var shouldAddToTree:Array = []
#单纯用来控制每个区块的偏移的缩放
var swTf:SwDefine.SWTransformData

@export var useName:String = ""

var _viewRect:Rect2
#本绘制层的可见状态：作用于所有区块 mesh 实例，并对之后新加载的区块同样生效
var _visible:bool = true

@export var _drawMode:SwDefine.GridDrawMode = SwDefine.GridDrawMode.Tiling
@export_range(0, 8, 1) var preLoadwidth: int = 1
@export_range(1, 128, 1) var max_chunks_per_frame: int = 32
# 异步加载：ByContent 模式分帧加载区块，保证帧率；关闭则一帧加载所有（可能卡顿但立即显示）
var async_loading: bool = true
# 异步模式下 ByContent 每帧最多加载的区块数（需不小于快速移动时单帧轮换的数量）
@export_range(1, 64, 1) var async_chunks_per_frame: int = 12
# 视口外保留的区块圈数：相机在区块边界来回移动时不再反复卸载/重建
@export_range(0, 3, 1) var unload_margin_chunks: int = 1
# 每帧最多卸载的区块数：缩小视角时视口一次覆盖上百个区块，一次全部卸载会在单帧卡顿上百毫秒
@export_range(1, 64, 1) var max_unloads_per_frame: int = 16
# ByContent 模式下卸下后仍保留渲染节点、CPU 缓冲与槽位表的区块数量上限（0 表示不保留）。
# 相机移动时区块边界持续轮换，保留这些状态可免去重新创建节点与整块重建
@export_range(0, 2048, 16) var idle_chunk_cache_size: int = 128
#地图相关：地图资源大小
var _blockSize = Vector2(256,256)
#地图相关：使用建筑物信息指定地图的纹理信息
var mapData:SWBuildItemDefine = null
#地图相关：最终传入绘制数据
var mapDataArray:Array[SWBuildItemDefine] = []
#地图相关：地图资源定义
@export var mapDefine:SWBuildDefine = null

var sw_build_manager:SWBuildManager = null
# 已卸载但保留渲染节点的区块：chunkPos -> 区块数据（仅 ByContent 使用，作为按需淘汰的软缓存）
var _idleChunkCache:Dictionary[Vector2i, SwDefine.SWDrawChunkData] = {}
# 软缓存的插入顺序，用于超限时淘汰最旧的区块
var _idleChunkOrder:Array[Vector2i] = []
# 待卸载队列：只有被标记成 UNLOADING 的区块才在这里，卸载时只遍历这一小撮，
# 不再每帧全量遍历 _chunkInstance（缩远时那里有上千个区块，全量扫本身就是稳态开销）
var _unload_queue:Array[Vector2i] = []
# 队列去重表：相机每帧都在改视口，同一区块会被反复标记，用字典挡掉重复入队
var _unload_pending:Dictionary[Vector2i,bool] = {}
# 软缓存容量基准（编辑器里配的值）：运行时在它与硬顶 256 之间浮动，缩远放大、缩回回落
var _cache_size_base:int = -1
# 本节拍同时在后台构建的区块数，供三个优先级队列共用
var _buildingChunksNow:int = 0
# 方案 2: 降低查询频率
var _queryFrameInterval:int = 1  # 改为每帧更新，消除绘制锯齿感
var _frameCounter:int = 0
# 本帧触发重绘（调用 drawMap 重建 buffer）的区块数与上一帧快照，供性能面板读取
var _redraw_chunks_frame:int = 0
var _redraw_chunks_last:int = 0
# 本帧退回整块重建的区块数：增量补丁失败（槽位/部件数变了）才会走这里，
# 正常情况下应保持接近 0，异常升高说明补丁路径没命中
var _full_rebuilds_frame:int = 0
# 待增量补丁的区块与各区块的待补丁建筑（跨帧累积，幂等）。
# 连线换色不再需要全局 dirty net 集合：每个区块自己按 net.patchStamp 比对
var _patch_queue:Dictionary[Vector2i,bool] = {}
var _patch_builds:Dictionary = {}      # Vector2i -> Dictionary[build,bool]
# 该区块的补丁必须重算颜色（选中/取消选中底色）：LOD 冻结颜色的档位也要放行
var _patch_force_color:Dictionary[Vector2i,bool] = {}
# 内容变了（增删建筑/底色）的区块：槽位表已不可信，必须整块重建而不是增量回写
var _rebuild_queue:Dictionary[Vector2i,bool] = {}
# LOD 档切换后待按当前档位重染的区块（降级：连线统一 high 色；回升：还原真实电平）
var _color_resync_queue:Dictionary[Vector2i,bool] = {}
# 主线程同步构建/补丁的时间预算（微秒）：超出就留到下一帧继续，避免单帧长卡顿。
# 补丁预算每帧会被消费两次（信号级联当帧一次、_process 补一次），所以按半帧的量给
const BUILD_BUDGET_USEC:int = 8000
const PATCH_BUDGET_USEC:int = 4000

# ===== 视口尺度变化后的「追赶窗口」=====
# 缩小一格会让视口覆盖的区块数按面积暴涨，一次要新建几十~几百个区块。
# 常规限流（8ms/帧、12 块/帧）是为保住平移时的帧率，但缩放不是持续操作，
# 玩家此时等的就是「全景铺满」——所以缩放停下后开一个短窗口，把预算与块数上限放大尽快补完；
# 连续滚轮期间不加速，避免滚轮本身也掉帧。
const ZOOM_QUIET_USEC:int = 120000     # 距上次视口尺度变化超过 120ms 视为「缩放已停」
const CATCHUP_USEC:int = 1500000       # 追赶窗口时长（缩放停下后 1.5s）
const CATCHUP_BUDGET_USEC:int = 15000  # 追赶期每帧构建预算（常规 8ms）
const CATCHUP_LIMIT_MULT:int = 6       # 追赶期每帧块数上限倍数
const CATCHUP_UNLOAD_MULT:int = 3      # 追赶期每帧卸载上限倍数
# 最近一次视口尺度（区块格数）变化的时间；初值取得足够早，避免开局就进入追赶
var _scale_changed_usec:int = -100000000

# 缩放已经停下、且还在追赶窗口内：放宽构建预算
func _in_catchup() -> bool:
	var now:int = Time.get_ticks_usec()
	var since:int = now - _scale_changed_usec
	if since < ZOOM_QUIET_USEC:
		return false      # 还在连续缩放（刚变过尺度）
	return since <= CATCHUP_USEC
# 内容变化（放置/删除/连线/加载）整块重建前，先同步信号纹理的回调（由 SWBuildLayer 注入）：
# 电路求值翻转的 net 电平必须写进纹理，否则几何重建后首帧读到旧 texel
var signal_sync_cb: Callable = Callable()
# 视口变化回调（由 SWBuildLayer 注入）：把当前视口范围交给电路侧做视野裁剪，
# 只有视野内的电线与非门跟随电路刷新，视野外的不刷显示也不求值
var view_rect_cb: Callable = Callable()

# 当前视口覆盖的区块范围（世界像素，含卸载余量圈）：电路求值/显示按它做视野裁剪。
# 用卸载余量而不是精确视口：相机在区块边界来回滑时不会忽算忽不算。
func get_keep_rect() -> Rect2:
	if unload_margin_chunks > 0:
		return _curViewRect.grow(_chunkSize.x * unload_margin_chunks)
	return _curViewRect

# 上一帧需要重绘的区块数量
func get_redraw_chunks_per_frame() -> int:
	return _redraw_chunks_last

# 上一帧退回整块重建的区块数（增量补丁未命中）
func get_full_rebuilds_last_frame() -> int:
	return _full_rebuilds_frame
func setBuildManager(buildManager:SWBuildManager) -> void:
	sw_build_manager = buildManager
	# 监听建筑变化，标记缓存过期
	if sw_build_manager.build_changed.is_connected(_on_build_changed) == false:
		sw_build_manager.build_changed.connect(_on_build_changed)

func _on_build_changed() -> void:
	_cacheDirty = true
func updataAllChunks() -> void:
	if not _pending_tasks.has(0):
		_pending_tasks[0] = {}
	# 全量刷新：所有区块都会重建，挂起的增量补丁与累积的脏 net 作废
	_patch_queue.clear()
	_patch_builds.clear()
	_patch_force_color.clear()
	_rebuild_queue.clear()
	_color_resync_queue.clear()
	# 全量重建：让下一次视口刷新完整跑一遍（重新枚举待加载区块）
	_view_rect_seeded = false
	for chunkPos in _chunkInstance.keys():
		if not _chunkInstance.has(chunkPos):
			continue
		if _drawMode == SwDefine.GridDrawMode.ByContent:
			# 内容层原地重建：旧内容先留着，按时间预算分帧换成新内容。
			# 不能走「卸载→重加载」：卸载有每帧上限，期间的加载任务会因为区块还留在
			# _chunkInstance 里被丢掉，区块就一直显示刷新前的旧建筑（换存档后残留）
			_patch_queue[chunkPos] = true
			_rebuild_queue[chunkPos] = true
			continue
		_mark_unloading(chunkPos)
		_pending_tasks[0][chunkPos] = false
	_flush_patches(PATCH_BUDGET_USEC)
#changedBuilds：本次信号变化涉及的元件（门/灯/寄存器/开关）。
#dirtyNets：本次翻转电平的 net 集合（连线换色走批量索引，不逐根进补丁列表）。
#两者都为空表示这是「内容变了」（放置/删除/剪切/选中底色），区块里的建筑集合或
#底色都可能对不上已有槽位，必须整块重建内容；否则走增量补丁。
#patchBudgetUsec：本次补丁的时间预算。选中/取消选中这类只改底色的批量操作可以调大，
#避免颜色分几百帧才铺完。
#forceColor：本次补丁必须写颜色（选中底色）。LOD 档位平时冻结电路颜色，
#但选中高亮不随电路变化，任何档位都要即时生效。
func updataChunks(chunkPosArr:Array[Vector2i], changedBuilds:Array = [], 
	dirtyNets:Dictionary = {}, patchBudgetUsec:int = PATCH_BUDGET_USEC, forceColor:bool = false) -> void:
	# 内容路径进入前先消费本轮求值翻转的 net：信号纹理先就位，几何重建后首帧即可显示正确电平
	if signal_sync_cb.is_valid():
		signal_sync_cb.call()
	if not _pending_tasks.has(0):
		_pending_tasks[0] = {}
	var contentChanged:bool = changedBuilds.is_empty() and dirtyNets.is_empty()
	for build:SWBuildItemDefine in changedBuilds:
		if build == null:
			continue
		var cp:Vector2i = SwCommon.GetChunkPos(build.buildAxisPos)
		var group:Dictionary
		if _patch_builds.has(cp):
			group = _patch_builds[cp]
		else:
			group = {}
			_patch_builds[cp] = group
		group[build] = true
	for chunkPos in chunkPosArr:
		if _chunkInstance.has(chunkPos):
			_patch_queue[chunkPos] = true
			if forceColor:
				_patch_force_color[chunkPos] = true
			if contentChanged:
				_rebuild_queue[chunkPos] = true
			continue
		# 新区块：加入待加载任务
		_pending_tasks[0][chunkPos] = false
		# 该区块此刻可能正躺在软缓存里：其内容已变（状态翻转/增删建筑），
		# 必须失效缓存条目的 builtVersion，否则下次进视口会 reuse 旧 buffer 跳过重绘
		if _idleChunkCache.has(chunkPos):
			_idleChunkCache[chunkPos].mesh_instance.builtVersion = -1
	_flush_patches(patchBudgetUsec)

# 图集 LOD 切换通知（SwAtlas 通过 DrawManager 组广播）：
# 颜色已全部由 shader 采样（tint 静态 + 信号纹理 + signalFrozen），LOD 切换无需重染 buffer；
# srcImg/atlas_scale/signalFrozen 由 SwAtlas._apply_to_meshes 统一刷材质参数。
func on_atlas_lod_changed(_level:int) -> void:
	# 手持阴影只在全分辨率显示：切档后已上屏的区块要立刻跟随显隐
	if _drawMode == SwDefine.GridDrawMode.HoldShadow:
		_apply_chunk_visible()
	# 隐藏的软缓存区块：上屏时按当前档位整块重建，重染成本省掉
	for chunkPos:Vector2i in _idleChunkCache.keys():
		_idleChunkCache[chunkPos].mesh_instance.builtVersion = -1

# ========== 缩远简化档（内容 LOD） ==========
# 「越缩越卡」的根因分析（实测数据，见 test_zoom_diag）：
#   区块世界尺寸 = GRID_SIZE(128) * CHUNK_SIZE(16) * 8 = 16384，非常大。
#   即使缩到 level=-36，1920x1080 视口也只覆盖 1~2 个区块 —— **区块数不是瓶颈**。
#   真正的开销是：缩远触发 LOD 切档 → 把已上屏区块全部标记重建 →
#   每个区块重跑 drawMap（几百个实例）→ 每缩一步卡一下。
#
# 因此策略调整：
#   1. 切档时的重建分帧消化（_flush_patches 按预算分批），不一次全建；
#   2. 内容简化档已按产品要求停用：任何 LOD 等级下都全量显示建筑物，
#      基座与电线端子不得丢弃（停用前它能把实例数降到 1/2.35）。
var content_lod:int = 0
# 上一次应用的相机缩放档位：用于判定是否切档（避免每帧重复扫描）
var _applied_scale_level:int = 999999
# 相机档位 → 内容 LOD 的映射。
# 产品要求：任何缩放档位都全量显示建筑部件，所以这里恒返 0。
# 下面两个阈值曾经是简化档的触发点（对齐图集 LOD：-32 起中精度、-39 起最低精度），
# 现在只作档位参照保留；_bakeSimplified / LOD_SIMPLIFY_LEVEL 那条休眠路径永远不会被走到，
# 需要重新拿回远景省开销时，把下面的 return 改回按档位分档即可。
const CONTENT_LOD_LEVEL_1:int = -32   # （已停用）原：开始只画主体
const CONTENT_LOD_LEVEL_2:int = -40   # （已停用）原：只画主体（更高档位）

func _content_lod_for(_scale_level:int) -> int:
	return 0

# 相机缩放档位变化时调用（SWCamera2D._on_zoomCom_zoom）。
# 内容简化停用后 want 恒为 0，这里的档位变化再也不会触发已上屏区块重建。
func set_scale_level(scale_level:int) -> void:
	var want:int = _content_lod_for(scale_level)
	if scale_level == _applied_scale_level:
		return
	_applied_scale_level = scale_level
	if want == content_lod:
		return
	content_lod = want
	_apply_content_lod()

# 把内容 LOD 应用到软缓存与后续新建区块。
#
# ⚠ 关键决策：**不重建已上屏的区块**。
#   实测（test_zoom_diag）：缩远时每次切档若把已上屏区块标记重建，
#   即使只有 1~2 个区块，单次也要 3.59ms，连续缩放就是连续卡顿。
#   而这些区块的几何本来就已经烘好了，重建只为把端子换成不画 —— 收益 2 倍实例，
#   却要付一次完整重建的代价，在「区块数很少」的场景下完全是负收益。
#   正确做法：已上屏的保持原样，只有当区块**重新进入视野**（软缓存复用/新加载）时
#   才按最新档位烘培。随着平移/缩放，远景区块会自然被替换成简化版。
func _apply_content_lod() -> void:
	for chunkPos:Vector2i in _idleChunkCache.keys():
		var mi_ref = _idleChunkCache[chunkPos].mesh_instance
		if mi_ref != null:
			mi_ref.builtVersion = -1
			mi_ref.content_lod = content_lod

# 按当前 LOD 档位重染某一区块；返回 false 表示需要整块重建
func _resync_chunk_colors(chunkPos:Vector2i) -> bool:
	if not _chunkInstance.has(chunkPos):
		return true
	var chunkIns:SwDefine.SWDrawChunkData = _chunkInstance[chunkPos]
	if chunkIns.status != SwDefine.ChunkStatus.FULLY_LOADED:
		return true
	var mi:SWMultiMeshInstance2D = chunkIns.mesh_instance
	if mi == null or not mi.hasCpuBuffer():
		return true
	if not mi.resyncColors(true):
		return false
	mi.flushPatch()
	_redraw_chunks_frame += 1
	return true

# 分帧处理待刷新区块；补丁按「当前状态」回写，重复执行是幂等的，
# 因此跨帧/跨级联累积都安全，未处理完的留到下一帧继续
func _flush_patches(budget_usec:int) -> void:
	if _patch_queue.is_empty() and _color_resync_queue.is_empty():
		return
	var start:int = Time.get_ticks_usec()
	# LOD 恢复后的颜色补齐优先：这是已上屏的陈旧颜色，等不起。
	# 但只能占预算的一部分：整屏补色要几百个区块，独占预算会把信号补丁饿死，
	# 补丁队列越积越多、连线颜色滞后好几拍。
	if not _color_resync_queue.is_empty():
		var resynced:Array[Vector2i] = []
		var resync_budget:int = maxi(budget_usec / 3, 500)
		for chunkPos:Vector2i in _color_resync_queue:
			if Time.get_ticks_usec() - start > resync_budget:
				break
			resynced.append(chunkPos)
			if not _resync_chunk_colors(chunkPos):
				_refreshChunkContent(chunkPos)
		for chunkPos in resynced:
			_color_resync_queue.erase(chunkPos)
	if _patch_queue.is_empty():
		return
	var done:Array[Vector2i] = []
	for chunkPos:Vector2i in _patch_queue:
		if Time.get_ticks_usec() - start > budget_usec:
			break
		done.append(chunkPos)
		var force_color:bool = _patch_force_color.get(chunkPos, false)
		if _rebuild_queue.has(chunkPos):
			_refreshChunkContent(chunkPos)
			continue
		var builds:Dictionary = _patch_builds.get(chunkPos, {})
		_patch_builds.erase(chunkPos)
		if not _patch_chunk(chunkPos, builds, force_color):
			_refreshChunkContent(chunkPos)
	for chunkPos in done:
		_patch_queue.erase(chunkPos)
		_patch_force_color.erase(chunkPos)
		_rebuild_queue.erase(chunkPos)

# 返回 false 表示该区块无法增量回写（无 CPU buffer / 槽位对不上），需要整块重建
# force_color 参数保留兼容旧调用：纹理化后补丁只回写 8..11 tint 列（选中/环路底色），
# 信号颜色与 LOD 冻结全由 shader 采样处理，不再受此参数影响。
func _patch_chunk(chunkPos:Vector2i, builds:Dictionary, force_color:bool = false) -> bool:
	if not _chunkInstance.has(chunkPos):
		return true
	var chunkIns:SwDefine.SWDrawChunkData = _chunkInstance[chunkPos]
	if chunkIns.status != SwDefine.ChunkStatus.FULLY_LOADED:
		return true
	var mi:SWMultiMeshInstance2D = chunkIns.mesh_instance
	if not mi.hasCpuBuffer():
		return false
	var touched:bool = false
	if not builds.is_empty():
		if not mi.patchBuilds(builds.keys(), force_color):
			return false
		touched = true
	if touched:
		mi.flushPatch()
		_redraw_chunks_frame += 1
	return true

# 直接刷新已有区块的绘制内容（不卸载、不隐藏，旧内容继续显示直到新buffer就绪）
func _refreshChunkContent(chunkPos:Vector2i) -> void:
	if not _chunkInstance.has(chunkPos):
		return
	var chunkIns:SwDefine.SWDrawChunkData = _chunkInstance[chunkPos]
	
	if _drawMode == SwDefine.GridDrawMode.ByContent:
		var dirtyBuilds = sw_build_manager.getBuildsByChunkPos(chunkPos)
		if dirtyBuilds.size() == 0:
			# 区块已经没有建筑了：只隐藏，状态保持 FULLY_LOADED。
			# 这里若转成 UNLOADING，视口内的区块会被 on_view_rect_changed 复活，
			# 旧建筑的 buffer 又原样显示出来（换存档后残留的根因之一）。
			# builtVersion 故意不动：卸载进软缓存后必须失效，否则重新进视口会复用旧 buffer
			chunkIns.mesh_instance.visible = false
			return
		# 主线程同步重建并提交 buffer，失败路径与新区块加载完全一致
		_redraw_chunks_frame += 1
		_full_rebuilds_frame += 1
		# 缩远简化档：重建前必须把当前档位同步给 mesh，
		# 否则切档后的重建仍然按旧档位烘培（表现为「切了档但画面没变」）
		chunkIns.mesh_instance.content_lod = content_lod
		chunkIns.mesh_instance.drawMap(dirtyBuilds)
		chunkIns.mesh_instance.builtVersion = sw_build_manager.version + SWMultiMeshInstance2D.BUFFER_LAYOUT_VERSION
		# 之前可能因为区块被清空而隐藏，重建出内容后恢复上屏
		chunkIns.mesh_instance.visible = _chunk_visible()
	else:
		# Tiling等其他模式：保持原有卸载→重加载逻辑
		_mark_unloading(chunkPos)
		if not _pending_tasks.has(0):
			_pending_tasks[0] = {}
		_pending_tasks[0][chunkPos] = false
#TODO _blockSize根据mapDefine来设置



func initDrawMap() -> void:
	_chunkSize=SwDefine.GRID_SIZE*SwDefine.CHUNK_SIZE*8
	_blockSize = SwDefine.GRID_SIZE*8
	if not mapData:
		mapData = SwDefine.SWBuildCreator(Vector2i(0,0),mapDefine)
		mapData.rotation = SwDefine.SW_Dir.UP#SwCommon.GetAngleBySWDir(SwDefine.SW_Dir.UP)
		mapDataArray.append(mapData)
	
func initDrawContent() -> void:
	_chunkSize=SwDefine.GRID_SIZE*SwDefine.CHUNK_SIZE
	_blockSize = SwDefine.GRID_SIZE
	pass
	
func setDrawMode(drawMode:SwDefine.GridDrawMode) -> void:
	_drawMode = drawMode
	# 换模式后区块尺寸/对齐都变了，上次的视口快照作废
	_view_rect_seeded = false
	if _drawMode == SwDefine.GridDrawMode.Tiling:
		initDrawMap()
	else:
		initDrawContent()
	pass
	
func set_visible(enable:bool) -> void:
	_visible = enable
	_apply_chunk_visible()

# 手持阴影在低分辨率 LOD 档位不显示：缩远时预览不需要投影，也省一批实例
func _lod_hides_layer() -> bool:
	return _drawMode == SwDefine.GridDrawMode.HoldShadow and SwAtlas.is_lod_active()

func _chunk_visible() -> bool:
	return _visible and not _lod_hides_layer()

func _apply_chunk_visible() -> void:
	var vis:bool = _chunk_visible()
	for chunkIns:SwDefine.SWDrawChunkData in _chunkInstance.values():
		if chunkIns.mesh_instance:
			chunkIns.mesh_instance.visible = vis

func is_visible() -> bool:
	return _visible

# 当前已上屏（可见）的区块数量，供性能面板统计
func get_visible_chunk_count() -> int:
	var count:int = 0
	for chunkPos:Vector2i in _chunkInstance:
		var chunkIns:SwDefine.SWDrawChunkData = _chunkInstance[chunkPos]
		if chunkIns.mesh_instance != null and chunkIns.mesh_instance.visible:
			count += 1
	return count

# 待处理任务数（加载/重建/卸载），供任务系统判断手持预览是否已生成完毕
func get_pending_task_count() -> int:
	var count:int = 0
	for tasks:Dictionary in _pending_tasks.values():
		count += tasks.size()
	return count

# 没有待处理任务、也没有区块停在卸载中：手持预览只有在这个状态下才算可以上屏
func is_idle() -> bool:
	if get_pending_task_count() > 0:
		return false
	# 卸载中的区块都在队列里（见 _mark_unloading）：查队列比全量遍历 _chunkInstance 便宜得多
	return _unload_queue.is_empty()

# 已加载（在 _chunkInstance 中）的区块坐标，供渲染压测/调试统计
func get_loaded_chunk_positions() -> Array[Vector2i]:
	var arr:Array[Vector2i] = []
	for k in _chunkInstance.keys():
		arr.append(k)
	return arr

func _ready() -> void:
	add_to_group("DrawManager")
	if not mapDefine:
		assert(false, "mapDefine未定义")
	swTf = SwDefine.SWTransformData.new()
	setDrawMode(_drawMode)

# 设置异步加载模式
func set_async_loading(enabled: bool) -> void:
	async_loading = enabled

func _process(_delta: float) -> void:
	# 方案 2: 降低查询频率，每 3 帧执行一次
	_frameCounter += 1
	if _frameCounter % _queryFrameInterval != 0:
		return
	# 重置本帧重绘计数，处理完成后快照给性能面板
	_redraw_chunks_frame = 0
	_full_rebuilds_frame = 0
	# 上一帧没处理完的信号补丁继续处理
	_flush_patches(PATCH_BUDGET_USEC)
	process_unload_chunk()
	shouldAddToTree.clear()
	process_load_chunk(0)
	process_load_chunk(1)
	process_load_chunk(2,false)
	for ins in shouldAddToTree:
		add_child(ins)
	_redraw_chunks_last = _redraw_chunks_frame
	pass
	
func process_load_chunk(priority:int,remove:bool = true) -> void:
	if not _pending_tasks.has(priority):
		return
	var tasks: Dictionary = _pending_tasks[priority]
	var count = 0
	var fast_count = 0
	var fast_limit:int = _get_per_frame_limit() * 4
	var keys := tasks.keys()
	var originalMapDataArray = mapDataArray
	# 内容层区块构建已在主线程同步完成：用时间预算兜底，单帧不会因为一次加载
	# 大量区块而长时间卡住（块数上限仍在，两者取先到者）
	var budget_start:int = Time.get_ticks_usec()
	var build_budget:int = CATCHUP_BUDGET_USEC if _in_catchup() else BUILD_BUDGET_USEC
	for chunkPos in keys:
		if not _curViewRect.has_point(chunkPos) and (_drawMode != SwDefine.GridDrawMode.ByHold and _drawMode != SwDefine.GridDrawMode.HoldShadow):
			_pending_tasks[priority].erase(chunkPos)
			continue
		var chunkMapDataArray = originalMapDataArray
		if _chunkInstance.has(chunkPos):
			var loadedIns:SwDefine.SWDrawChunkData = _chunkInstance[chunkPos]
			if loadedIns.status == SwDefine.ChunkStatus.UNLOADING:
				# 旧区块还没轮到大卸（卸载每帧限流）：任务必须留着，等它退出 _chunkInstance
				# 再按新内容重建；直接删任务会让区块永远停在重建前的旧内容上
				continue
			tasks.erase(chunkPos)
			continue
		# 缓存命中且建筑内容未变：上屏只是恢复可见性，不做任何构建，不受构建限流约束
		var fast_hit:bool = _isCachedContentValid(chunkPos)
		if fast_hit:
			if fast_count >= fast_limit:
				break
			fast_count += 1
		else:
			if count >= _get_per_frame_limit():
				break
			if Time.get_ticks_usec() - budget_start > build_budget:
				break
		if _drawMode == SwDefine.GridDrawMode.ByContent:
			var chunkBuilds = sw_build_manager.getBuildsByChunkPos(chunkPos)
			if chunkBuilds.size() == 0:
				tasks.erase(chunkPos)
				continue
			chunkMapDataArray = chunkBuilds
		elif _drawMode == SwDefine.GridDrawMode.ByHold or _drawMode == SwDefine.GridDrawMode.HoldShadow:
			var filteredArray:Array[SWBuildItemDefine] = []
			for build in originalMapDataArray:
				var buildChunkPos = SwCommon.GetChunkPos(build.buildAxisPos)
				if buildChunkPos == chunkPos:
					filteredArray.append(build)
			if filteredArray.size() == 0:
				tasks.erase(chunkPos)
				continue
			chunkMapDataArray = filteredArray
			
		count+=1
		# 优先复用软缓存中保留的区块节点：省去节点创建与整块重建，CPU 缓冲与槽位表也还在
		var chunkIns:SwDefine.SWDrawChunkData = _takeCachedChunk(chunkPos)
		var fromCache:bool = chunkIns != null
		if chunkIns == null:
			chunkIns = SWObjectPool.GetSWChunkDataObject(_drawMode)
		chunkIns.chunk_pos = chunkPos
		if _drawMode == SwDefine.GridDrawMode.ByContent:
			swTf.offset = Vector2(0,0)
		elif _drawMode == SwDefine.GridDrawMode.ByHold or _drawMode == SwDefine.GridDrawMode.HoldShadow:
			swTf.offset = lastMousePos - _center_offset
		else:
			swTf.offset = Vector2(chunkPos.x,chunkPos.y)
			
		chunkIns.mesh_instance.setMeshSize(_blockSize)
		chunkIns.mesh_instance.resetOffsetAndScale(swTf)
		chunkIns.mesh_instance.setDrawMode(_drawMode)
		# 缩远简化档：新区块按当前档位烘培（只画主体部件）
		chunkIns.mesh_instance.content_lod = content_lod
		# 来自软缓存且建筑内容自上次构建后没变：MultiMesh 里的 buffer 与实例数仍然有效，直接上屏，
		# 不必重建 320+ 个实例数据，也不必回传 98KB buffer 到渲染服务器
		var reuse_content:bool = fromCache \
				and _drawMode == SwDefine.GridDrawMode.ByContent \
				and chunkIns.mesh_instance.builtVersion == sw_build_manager.version + SWMultiMeshInstance2D.BUFFER_LAYOUT_VERSION
		if not reuse_content:
			_redraw_chunks_frame += 1
			if _drawMode == SwDefine.GridDrawMode.ByContent and chunkIns.mesh_instance.multimesh:
				chunkIns.mesh_instance.multimesh.visible_instance_count = 0
			chunkIns.mesh_instance.drawMap(chunkMapDataArray)
			chunkIns.mesh_instance.builtVersion = sw_build_manager.version + SWMultiMeshInstance2D.BUFFER_LAYOUT_VERSION if sw_build_manager else -1
		
		_chunkInstance[chunkPos] = chunkIns
		var mi: SWMultiMeshInstance2D = chunkIns.mesh_instance
		var mi_parent: Node = mi.get_parent()
		if mi_parent != null and mi_parent != self:
			mi_parent.remove_child(mi)
			mi_parent = null
		if mi_parent == null:
			shouldAddToTree.append(mi)
		mi.visible = _chunk_visible()
		mi.set_process(true)
		chunkIns.status = SwDefine.ChunkStatus.FULLY_LOADED
		tasks.erase(chunkPos)
	mapDataArray = originalMapDataArray
	if tasks.is_empty() and not _draging:
		_pending_tasks.erase(priority)

# 根据当前模式和异步开关计算每帧加载上限
func _get_per_frame_limit() -> int:
	if _drawMode == SwDefine.GridDrawMode.Tiling:
		return max_chunks_per_frame
	elif _drawMode == SwDefine.GridDrawMode.ByContent:
		if async_loading:
			# 缩放停下后的追赶期：块数上限放大，尽快把新视口铺满
			if _in_catchup():
				return async_chunks_per_frame * CATCHUP_LIMIT_MULT
			return async_chunks_per_frame
		else:
			return 99999  # 同步模式不限制，一帧加载全部
	return 99999
		

# 只有随相机移动轮换的区块才值得保留节点：内容层（建筑）与地图平铺层都适用
func _use_chunk_cache() -> bool:
	if idle_chunk_cache_size <= 0:
		return false
	return _drawMode == SwDefine.GridDrawMode.ByContent or _drawMode == SwDefine.GridDrawMode.Tiling

# 软缓存中已存在且建筑内容未变的区块：上屏无需重建 buffer
func _isCachedContentValid(chunkPos:Vector2i) -> bool:
	if not _use_chunk_cache() or sw_build_manager == null:
		return false
	if not _idleChunkCache.has(chunkPos):
		return false
	return _idleChunkCache[chunkPos].mesh_instance.builtVersion == sw_build_manager.version + SWMultiMeshInstance2D.BUFFER_LAYOUT_VERSION

# 把卸载的区块放进软缓存；超过上限时按最久未使用顺序真正销毁。
# 注意两点：
# 1) 保留 MultiMeshInstance2D 的 CPU buffer 与 GPU buffer 不变——复活路径（_takeCachedChunk）
#    会直接上屏而不重走 drawMap，提前释放 buffer 会表现为「区块标记已加载但画面空白」；
# 2) 节点必须「摘出场景树」再缓存。以前只把 visible 设成 false，节点还挂在树里，
#    缩远时视口覆盖上千个区块，这些隐藏节点每帧都要过一遍画布遍历与视锥裁剪，
#    是「缩远后静止也一直比之前卡」的主要来源。复活时由 _takeCachedChunk 重新 add_child。
# 内存靠 idle_chunk_cache_size 硬顶控制（上限 256）。
func _cacheChunkNode(chunkPos:Vector2i, chunkIns:SwDefine.SWDrawChunkData) -> void:
	if _idleChunkCache.has(chunkPos):
		_evictChunkNode(_idleChunkCache[chunkPos])
	var mi:SWMultiMeshInstance2D = chunkIns.mesh_instance
	if mi != null and mi.get_parent() != null:
		mi.get_parent().remove_child(mi)
	_idleChunkCache[chunkPos] = chunkIns
	_idleChunkOrder.append(chunkPos)
	_trim_idle_cache()

# 按当前 idle_chunk_cache_size 淘汰最久未用的缓存区块（容量回落时也要立刻瘦身）
func _trim_idle_cache() -> void:
	while _idleChunkOrder.size() > idle_chunk_cache_size:
		var oldest:Vector2i = _idleChunkOrder.pop_front()
		if _idleChunkCache.has(oldest):
			_evictChunkNode(_idleChunkCache[oldest])
			_idleChunkCache.erase(oldest)

# 从软缓存取出区块节点，未命中返回 null
func _takeCachedChunk(chunkPos:Vector2i) -> SwDefine.SWDrawChunkData:
	if not _use_chunk_cache() or not _idleChunkCache.has(chunkPos):
		return null
	var chunkIns:SwDefine.SWDrawChunkData = _idleChunkCache[chunkPos]
	_idleChunkCache.erase(chunkPos)
	_idleChunkOrder.erase(chunkPos)
	chunkIns.status = SwDefine.ChunkStatus.EMPTY
	if chunkIns.mesh_instance.get_parent() == null:
		add_child(chunkIns.mesh_instance)
	# 缓存期间节点不在场景树里，也就不在 MESH_GROUP 中：换图集/LOD/纹理扩容时
	# SwAtlas 的批量刷新会漏掉它，所以上屏前必须自己重刷一遍 shader uniform
	chunkIns.mesh_instance._resetShaderUniforms()
	return chunkIns

# 全量清图/换存档时调用：属于上一份世界的区块必须彻底扔掉。
# 软缓存里的节点连同它们的 curMapData（每块几十个建筑引用）与 _cpuBuffer 一起销毁，
# 已上屏的区块则只释放 CPU 缓冲与建筑引用，节点留着等新内容重建（不清就会
# 把上一份世界的建筑继续钉在内存里，换几次存档就是几万个建筑）。
func clearChunkCaches() -> void:
	# 清图后区块内容全变，上次的视口快照不能再当作「已处理过」
	_view_rect_seeded = false
	for chunkPos:Vector2i in _idleChunkOrder:
		if _idleChunkCache.has(chunkPos):
			_evictChunkNode(_idleChunkCache[chunkPos])
	_idleChunkCache.clear()
	_idleChunkOrder.clear()
	_unload_queue.clear()
	_unload_pending.clear()
	for chunkIns:SwDefine.SWDrawChunkData in _chunkInstance.values():
		if chunkIns.mesh_instance == null:
			continue
		# 停在 UNLOADING 的区块必须拉回已加载：卸载队列已清空，状态不重置的话
		# _mark_unloading 会因 UNLOADING 早退，这批区块就再也不会被卸载也不会被重建
		if chunkIns.status == SwDefine.ChunkStatus.UNLOADING:
			chunkIns.status = SwDefine.ChunkStatus.FULLY_LOADED
			chunkIns.mesh_instance.set_process(true)
		chunkIns.mesh_instance.curMapData = []
		chunkIns.mesh_instance.freeCpuBuffer()

# 真正销毁区块节点：摘出场景树（触发工作线程 join）并归还对象池
func _evictChunkNode(chunkIns:SwDefine.SWDrawChunkData) -> void:
	if chunkIns.mesh_instance.get_parent() != null:
		chunkIns.mesh_instance.get_parent().remove_child(chunkIns.mesh_instance)
	SWObjectPool.DelSWChunkDataObject(chunkIns)

# 标记区块待卸载：只把坐标推进卸载队列，真正的卸载由 process_unload_chunk 分帧做。
# 相机每帧都在改视口，同一区块会被反复标记，靠 _unload_pending 挡掉重复入队。
func _mark_unloading(chunkPos:Vector2i) -> void:
	var ins:SwDefine.SWDrawChunkData = _chunkInstance.get(chunkPos, null)
	if ins == null or ins.status == SwDefine.ChunkStatus.UNLOADING:
		return
	ins.status = SwDefine.ChunkStatus.UNLOADING
	if not _unload_pending.has(chunkPos):
		_unload_pending[chunkPos] = true
		_unload_queue.append(chunkPos)

# 区块又回到保留范围：撤销待卸载（队列里残留的坐标由 process_unload_chunk 按状态跳过）
func _cancel_unloading(chunkPos:Vector2i) -> void:
	_unload_pending.erase(chunkPos)

# 队列驱动的分帧卸载：只遍历「被标记成 UNLOADING」的区块。
# 以前每帧全量遍历 _chunkInstance（缩远时有上千个区块，等于每帧白扫一遍）。
func process_unload_chunk() -> void:
	if _unload_queue.is_empty():
		return
	var remain:Array[Vector2i] = []
	var unloaded:int = 0
	# 追赶期同步放大卸载速度：缩小后旧区块要尽快退出，否则它们会一直占着队列与节点
	var unload_limit:int = max_unloads_per_frame * CATCHUP_UNLOAD_MULT if _in_catchup() else max_unloads_per_frame
	for chunkPos:Vector2i in _unload_queue:
		if not _unload_pending.has(chunkPos):
			continue   # 标记期间被撤销（区块又回到保留范围）
		# 分帧卸载：每帧只处理固定数量，避免相机快速移动时单帧卸载上百个区块造成长卡顿
		if unloaded >= unload_limit:
			remain.append(chunkPos)
			continue
		_unload_pending.erase(chunkPos)
		unloaded += 1
		if not _chunkInstance.has(chunkPos):
			continue
		var chunkIns:SwDefine.SWDrawChunkData = _chunkInstance[chunkPos]
		if chunkIns.status != SwDefine.ChunkStatus.UNLOADING:
			continue   # 已就地复活，不能再卸
		chunkIns.status = SwDefine.ChunkStatus.UNVISIBLE
		chunkIns.mesh_instance.set_process(false)
		chunkIns.mesh_instance.visible = false
		# 先从表里摘掉再入缓存：边遍历 _chunkInstance 边删不安全
		_chunkInstance.erase(chunkPos)
		if _use_chunk_cache():
			# 只隐藏并保留节点与 buffer，相机移回来时可直接复用，避免反复 join 工作线程
			_cacheChunkNode(chunkPos, chunkIns)
		else:
			_evictChunkNode(chunkIns)
	_unload_queue = remain

func _updateChunkCache(viewRect:Rect2) -> void:
	if _drawMode != SwDefine.GridDrawMode.ByContent:
		return
	## 只在缓存过期时更新
	#if not _cacheDirty:
		#return
	#_cacheDirty = false
	_chunkHasBuildCache.clear()
	var mmiCount = getNeedCountOfMMI(viewRect)
	var bPos = (viewRect.position/Vector2(_chunkSize))
	var beginChunkPos:Vector2i = floor(bPos)*Vector2(_chunkSize)
	# 只查询视口内的 chunk，批量获取
	for x in range(mmiCount.x):
		for y in range(mmiCount.y):
			var chunkPos = Vector2i(beginChunkPos.x+x*_chunkSize.x,beginChunkPos.y+y*_chunkSize.y)
			if sw_build_manager.getBuildCountByChunkPos(chunkPos) > 0:
				_chunkHasBuildCache[chunkPos] = true

func on_view_rect_changed(viewRect:Rect2 = color_rect.get_rect(),speedVec:Vector2 = Vector2.ZERO) -> void:
	color_rect.position = viewRect.position
	color_rect.size = viewRect.size
	var mmiCount = getNeedCountOfMMI(viewRect)
	var bPos = (viewRect.position/Vector2(_chunkSize))
	var beginChunkPos:Vector2i = floor(bPos)*Vector2(_chunkSize)
	# 区块对齐的视口没变、建筑内容也没变：下面所有工作都是幂等的，整段跳过。
	# 相机在区块内部平移（绝大多数鼠标事件）就落在这里，不再白扫一遍区块格。
	if _view_rect_seeded and beginChunkPos == _last_begin_chunk \
			and mmiCount == _last_mmi_count and not _cacheDirty:
		return
	_view_rect_seeded = true
	_last_begin_chunk = beginChunkPos
	if mmiCount != _last_mmi_count:
		# 视口尺度变了（缩放 / 窗口尺寸变化）：记下时间，供追赶窗口判定
		_scale_changed_usec = Time.get_ticks_usec()
	_last_mmi_count = mmiCount
	# 建筑变化的脏标记在本次全量重扫里已经消费掉
	_cacheDirty = false
	var showInsRect = Rect2(beginChunkPos,Vector2(mmiCount)*Vector2(_chunkSize))
	if _use_chunk_cache():
		# 软缓存只保留 MultiMeshInstance2D 节点（CPU buffer 已在入缓存时 freeCpuBuffer 释放），
		# 容量按视口需求扩，但硬顶 256：缩远时视口覆盖上千 chunk 也不跟着膨胀到几百 MB。
		# 256 足够覆盖"相机在边界来回滑动"的回退窗口；超出的最久未用节点直接销毁。
		# 容量必须可回落：以前只增不减，缩远一次就永久顶到 256，缩回来也白养着几百个缓存区块。
		if _cache_size_base < 0:
			_cache_size_base = idle_chunk_cache_size
		var need_cache:int = mmiCount.x * mmiCount.y * 2
		idle_chunk_cache_size = clampi(need_cache, _cache_size_base, maxi(_cache_size_base, 256))
		_trim_idle_cache()
	if _drawMode == SwDefine.GridDrawMode.ByHold or _drawMode == SwDefine.GridDrawMode.HoldShadow:
		return
	#_curViewRect = showInsRect
	if not _pending_tasks.has(0):
		_pending_tasks[0] = {}
	if not _pending_tasks.has(1):
		_pending_tasks[1] = {}
	# 更新缓存（只在 ByContent 模式且缓存过期时查询）
	_updateChunkCache(viewRect)
	for x in range(mmiCount.x):
		for y in range(mmiCount.y):
			var chunkPos = Vector2i(beginChunkPos.x+x*_chunkSize.x,beginChunkPos.y+y*_chunkSize.y)
			if not _chunkInstance.has(chunkPos):
				if _drawMode == SwDefine.GridDrawMode.ByContent:
					# 使用缓存，避免重复查询
					if _chunkHasBuildCache.has(chunkPos):
						_pending_tasks[0][chunkPos]=false
				else:
					_pending_tasks[0][chunkPos]=false
	
	if _drawMode == SwDefine.GridDrawMode.Tiling:
		# 预加载范围按“区块圈数”扩展，而不是按“视口像素尺寸倍数”扩展
		var preloadBeginChunkPos: Vector2 = beginChunkPos - mmiCount*_chunkSize*preLoadwidth#Vector2(preLoadwidth * _chunkSize.x, preLoadwidth * _chunkSize.y)
		var preloadMmiCount: Vector2i = mmiCount*(1+2*preLoadwidth)# + Vector2i(2 * preLoadwidth, 2 * preLoadwidth)
		
		var speedVecTmp = speedVec#.normalized()
		#speedVecTmp/=speedVecTmp
		if speedVecTmp.x != 0:
			speedVecTmp.x/=abs(speedVecTmp.x)
		if speedVecTmp.y != 0:
			speedVecTmp.y/=abs(speedVecTmp.y)
		preloadMmiCount+=Vector2i(speedVecTmp)*mmiCount
		for x in range(preloadMmiCount.x):
			for y in range(preloadMmiCount.y):
				#var chunkPos = Vector2i(preloadBeginChunkPos.x+(x+speedVecTmp.x)*_chunkSize.x,preloadBeginChunkPos.y+(y+speedVecTmp.y)*_chunkSize.y)
				var chunkPos = Vector2i(preloadBeginChunkPos.x+(x)*_chunkSize.x,preloadBeginChunkPos.y+(y)*_chunkSize.y)
				if not _chunkInstance.has(chunkPos) and not _pending_tasks[0].has(chunkPos):
					_pending_tasks[1][chunkPos]=false
					#print("Preload: ", chunkPos)
		var delShowInsRect = Rect2(showInsRect.position-showInsRect.size,showInsRect.size*3)
		_curViewRect = delShowInsRect
		# 直接迭代字典键：keys() 会为上千个区块分配一整份新数组，而这里只读不删
		for chunkPos:Vector2i in _chunkInstance:
			if not delShowInsRect.has_point(chunkPos):
				_mark_unloading(chunkPos)
	else:
		var delShowInsRect = Rect2(showInsRect.position,showInsRect.size)
		_curViewRect = delShowInsRect
		# 把新的视口范围推给电路侧（只有 ByContent 层有建筑电路：ByHold 已提前 return，Tiling 走上面分支）
		if view_rect_cb.is_valid():
			view_rect_cb.call()
		# 卸载判定向外扩一圈区块：相机在边界附近移动时不反复卸载/重建
		var keepRect:Rect2 = delShowInsRect
		if unload_margin_chunks > 0:
			keepRect = delShowInsRect.grow(_chunkSize.x * unload_margin_chunks)
		for chunkPos:Vector2i in _chunkInstance:
			var chunkIns:SwDefine.SWDrawChunkData = _chunkInstance[chunkPos]
			if not keepRect.has_point(chunkPos):
				_mark_unloading(chunkPos)
			elif chunkIns.status == SwDefine.ChunkStatus.UNLOADING:
				# 挂着全量重建任务的区块不能就地复活：它必须退场后按新内容重建，
				# 否则复活的是重建前的旧 buffer
				if _pending_tasks.has(0) and _pending_tasks[0].has(chunkPos):
					continue
				# 相机又移回保留范围：撤销卸载，避免白白重建一遍
				chunkIns.status = SwDefine.ChunkStatus.FULLY_LOADED
				_cancel_unloading(chunkPos)
				chunkIns.mesh_instance.visible = _chunk_visible()
				chunkIns.mesh_instance.set_process(true)
	pass

func getNeedCountOfMMI(rect:Rect2) -> Vector2i:
	var bPos = (rect.position/Vector2(_chunkSize))
	var beginChunkPos = floor(bPos)*Vector2(_chunkSize)
	var endChunkPos = (rect.end/Vector2(_chunkSize)).ceil()*Vector2(_chunkSize)
	var size = (endChunkPos-beginChunkPos)/Vector2(_chunkSize)
	return size

var _drawData:SWDrawData = null
var _draging:bool = false
var _center_offset:Vector2
func getHoldBuild() -> SWDrawData:
	return _drawData
func getHoldCenter() -> Vector2:
	return _center_offset

func recalcHoldCenter() -> void:
	if not _drawData:
		return
	var centerRect:Rect2=Rect2(0,0,0,0)
	var caled = false
	var mapDataArray = _drawData.mapDatas
	var minPos:Vector2
	var maxPos:Vector2
	for mapData in mapDataArray:
		if not caled:
			caled = true
			minPos = Vector2(mapData.buildAxisPos)
			maxPos = Vector2(mapData.buildAxisPos)+Vector2(_blockSize)
		else:
			minPos.x = min(mapData.buildAxisPos.x,minPos.x)
			minPos.y = min(mapData.buildAxisPos.y,minPos.y)
			maxPos.x = max(mapData.buildAxisPos.x+_blockSize.x,maxPos.x)
			maxPos.y = max(mapData.buildAxisPos.y+_blockSize.y,maxPos.y)
	centerRect.position = minPos
	centerRect.end = maxPos
	_center_offset = centerRect.get_center()
	
func setHoldBuild(drawData:SWDrawData) -> void:
	for chunkPos in _chunkInstance.keys():
		_mark_unloading(chunkPos)
	_drawData = drawData
	var centerRect:Rect2=Rect2(0,0,0,0)
	var caled = false
	if _drawData:
		_draging = true
		
		if not _pending_tasks.has(2):
			_pending_tasks[2] = {}
		mapDataArray = drawData.mapDatas
		var maxPos:Vector2
		var minPos:Vector2
		for mapData:SWBuildItemDefine in mapDataArray:
			mapData.buildState.state = SwDefine.BuildState.HOLDING
			var chunkPos = SwCommon.GetChunkPos(mapData.buildAxisPos)
			_pending_tasks[2][chunkPos] = false
			if not caled:
				caled = true
				minPos = Vector2(mapData.buildAxisPos)
				maxPos = Vector2(mapData.buildAxisPos)+Vector2(_blockSize)
			else:
				minPos.x = min(mapData.buildAxisPos.x,minPos.x)
				minPos.y = min(mapData.buildAxisPos.y,minPos.y)
				maxPos.x = max(mapData.buildAxisPos.x+_blockSize.x,maxPos.x)
				maxPos.y = max(mapData.buildAxisPos.y+_blockSize.y,maxPos.y)
		centerRect.position = minPos
		centerRect.end = maxPos
		_center_offset = centerRect.get_center()
	else:
		_draging = false
		_pending_tasks.clear()
	pass
var lastMousePos:Vector2 = Vector2(0,0)
func setHoldBuildsPos(mousePos:Vector2) -> void:
	if not _draging:
		return
	lastMousePos = mousePos
	for chunkIns:SwDefine.SWDrawChunkData in _chunkInstance.values():
		swTf.offset = mousePos - _center_offset
		if _drawMode == SwDefine.GridDrawMode.HoldShadow:
			swTf.offset = SwCommon.GetGridPos(swTf.offset+Vector2(_blockSize/2))
		chunkIns.mesh_instance.resetOffsetAndScale(swTf)
		pass
	pass
