# above_lights_layer.gd
# Adds a default "Above Lights" user layer (z-index 1100) to every level.
#
# Vanilla default user layers stop at 900 ("Above Roofs"); DD's lighting pass
# renders above that, so nothing placed through the vanilla layer list can sit
# on top of the light render. This submod injects an extra user layer at 1100
# into Level.Layers through the native LoadLayers() path (the same code path
# used when a saved map restores its custom layers), so DD treats it exactly
# like a user-created layer:
#  - it is saved with the map (SaveLayers exports all non-locked layers) and
#    reloads natively on subsequent opens (this submod then no-ops);
#  - it can be renamed like any user layer; we key on the z value (1100), not
#    the name, so a renamed layer is left alone;
#  - any layer menu DD rebuilds afterwards (level switch, tool refresh) picks
#    it up natively, in sorted position, with correct index<->layer mapping.
#
# For immediate visibility we also append the entry to the already-built
# LayerMenu OptionButtons of the known layer-aware tools (item metadata =
# layer z, matching DD's own population; cf. eyedropper's SetLayer handling).
#
# Injection details:
#  - LoadLayers() is called with a STRING key ("1100"): its C# loader parses
#    string keys via int.Parse, which is deterministic, whereas a marshaled
#    GDScript int key could box to Int64 and miss the typeof(int) branch.
#  - Layers.Add() throws on duplicate keys, so we first check for presence via
#    the ObjectTool LayerMenu metadata (always populated from the current
#    level's Layers). A settle delay after each level change lets DD rebuild
#    the menus before we trust them.
#  - One injection attempt per level instance per session.

const LAYER_Z := 1100
const LAYER_NAME := "1100: Above Lights"

# Update ticks a level must stay current before we trust the layer menus to
# reflect it (level switches rebuild the menus almost immediately; ~0.5 s at
# 60 fps is a comfortable margin).
const SETTLE_TICKS := 30

# Probe interval (in update ticks) while idle, to keep the per-frame cost of
# native property reads negligible.
const PROBE_EVERY := 10

# Tools known to expose a LayerMenu OptionButton (probed defensively; absent
# or menu-less tools are skipped).
const MENU_TOOLS := ["ObjectTool", "ScatterTool", "PathTool", "PatternShapeTool", "SelectTool", "TextTool"]

var _g

var _done_levels := {}
var _pending_level_id := 0
var _pending_ticks := 0
var _tick := 0


func initialize() -> void:
	pass


func update(_delta) -> void:
	_tick += 1
	if _tick % PROBE_EVERY != 0 and _pending_level_id == 0:
		return
	if _g == null or _g.World == null or not is_instance_valid(_g.World):
		return
	var lvl = _g.World.GetCurrentLevel()
	if lvl == null or not is_instance_valid(lvl) or not lvl.is_inside_tree():
		_pending_level_id = 0
		return
	var lid = lvl.get_instance_id()
	if _done_levels.has(lid):
		_pending_level_id = 0
		return
	if lid != _pending_level_id:
		_pending_level_id = lid
		_pending_ticks = 0
		return
	_pending_ticks += 1
	if _pending_ticks < SETTLE_TICKS:
		return
	# Reference menu for presence detection: ObjectTool's, which DD populates
	# from the current level's Layers. Empty/missing menu -> editor still
	# booting, keep waiting.
	var ref_menu = _get_layer_menu("ObjectTool")
	if ref_menu == null or ref_menu.get_item_count() <= 0:
		return
	if _menu_has_layer(ref_menu, LAYER_Z):
		# Already present (loaded from a map saved with this submod active,
		# possibly renamed by the user): nothing to do for this level.
		_done_levels[lid] = true
		_pending_level_id = 0
		return
	# Native injection into the level's real layer table.
	lvl.LoadLayers({str(LAYER_Z): LAYER_NAME})
	# Immediate visibility in the menus already built for this level. Appending
	# is order-correct here: 1100 sorts after every vanilla layer, and DD's own
	# rebuilds will take over with native sorted population anyway.
	for tool_name in MENU_TOOLS:
		var lm = _get_layer_menu(tool_name)
		if lm == null or lm.get_item_count() <= 0:
			continue
		if _menu_has_layer(lm, LAYER_Z):
			continue
		lm.add_item(LAYER_NAME)
		lm.set_item_metadata(lm.get_item_count() - 1, LAYER_Z)
	_done_levels[lid] = true
	_pending_level_id = 0
	print("[UnofficialPatch] above_lights_layer: added '%s' (z %d) to level '%s'" % [LAYER_NAME, LAYER_Z, str(lvl.get("Label"))])


func _get_layer_menu(tool_name: String):
	if _g.Editor == null or not _g.Editor.Tools.has(tool_name):
		return null
	var t = _g.Editor.Tools[tool_name]
	if t == null:
		return null
	var lm = t.get("LayerMenu")
	if lm == null or not is_instance_valid(lm):
		return null
	return lm


func _menu_has_layer(lm, layer_z: int) -> bool:
	for i in range(lm.get_item_count()):
		var md = lm.get_item_metadata(i)
		if typeof(md) == TYPE_INT or typeof(md) == TYPE_REAL:
			if int(md) == layer_z:
				return true
	return false
