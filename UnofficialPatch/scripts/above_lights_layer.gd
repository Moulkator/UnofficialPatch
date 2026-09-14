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
#  - every layer-aware tool rebuilds its LayerMenu from Level.Layers in its
#    Enable() (World.UpdateLayerMenu), so the layer shows up natively, in
#    sorted position, the next time a tool is activated.
#
# Presence detection: DD only populates a tool's LayerMenu when that tool is
# enabled, so we must NOT rely on any tool menu (a fresh session where the
# user goes straight to the Path/Pattern/Material tools would otherwise never
# see the layer until the Object Tool had been opened once). Instead we keep a
# private scratch OptionButton and ask World.UpdateLayerMenu() to fill it from
# the current level's Layers — that is the exact native population routine.
#
# Injection details:
#  - LoadLayers() is called with a STRING key ("1100"): its C# loader parses
#    string keys via int.Parse, which is deterministic, whereas a marshaled
#    GDScript int key could box to Int64 and miss the typeof(int) branch.
#  - Layers.Add() throws on duplicate keys, hence the presence check above.
#  - After injection, menus already built for the current level are refreshed
#    natively (UpdateLayerMenu with the tool's own ActiveLayer, so the current
#    selection is preserved).
#  - One injection attempt per level instance per session.

const LAYER_Z := 1100
# Bare name only: World.UpdateLayerMenu() prefixes it with the z value itself.
const LAYER_NAME := "Above Lights"

# Update ticks a level must stay current before we act on it (lets a map load
# / level switch finish; ~0.5 s at 60 fps is a comfortable margin).
const SETTLE_TICKS := 30

# Probe interval (in update ticks) while idle, to keep the per-frame cost of
# native property reads negligible.
const PROBE_EVERY := 10

# Tools known to expose a LayerMenu OptionButton (probed defensively; absent
# or menu-less tools are skipped).
const MENU_TOOLS := ["ObjectTool", "ScatterTool", "PathTool", "PatternShapeTool", "MaterialBrush", "SelectTool", "TextTool"]

var _g

var _done_levels := {}
var _pending_level_id := 0
var _pending_ticks := 0
var _tick := 0

# Scratch menu used only for presence detection (never shown).
var _scratch_menu: OptionButton = null


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
	var present := _level_has_layer(LAYER_Z)
	if present == -1:
		# Could not read the level's layers yet (editor still booting): retry.
		return
	if present == 1:
		# Already present (loaded from a map saved with this submod active,
		# possibly renamed by the user): nothing to do for this level.
		_done_levels[lid] = true
		_pending_level_id = 0
		return
	# Native injection into the level's real layer table.
	lvl.LoadLayers({str(LAYER_Z): LAYER_NAME})
	# Refresh menus already built for this level so the layer is visible at
	# once; tools not yet enabled will build theirs natively on Enable().
	for tool_name in MENU_TOOLS:
		var t = _get_tool(tool_name)
		if t == null:
			continue
		var lm = t.get("LayerMenu")
		if lm == null or not is_instance_valid(lm) or lm.get_item_count() <= 0:
			continue
		var active = t.get("ActiveLayer")
		if typeof(active) != TYPE_INT and typeof(active) != TYPE_REAL:
			active = 100
		_g.World.UpdateLayerMenu(lm, int(active))
	_done_levels[lid] = true
	_pending_level_id = 0
	print("[UnofficialPatch] above_lights_layer: added '%s' (z %d) to level '%s'" % [LAYER_NAME, LAYER_Z, str(lvl.get("Label"))])


# Returns 1 if the current level's Layers contains layer_z, 0 if not,
# -1 if the layers could not be read yet.
func _level_has_layer(layer_z: int) -> int:
	if _scratch_menu == null or not is_instance_valid(_scratch_menu):
		_scratch_menu = OptionButton.new()
	_scratch_menu.clear()
	_g.World.UpdateLayerMenu(_scratch_menu, 100)
	if _scratch_menu.get_item_count() <= 0:
		return -1
	return 1 if _menu_has_layer(_scratch_menu, layer_z) else 0


func _get_tool(tool_name: String):
	if _g.Editor == null or not _g.Editor.Tools.has(tool_name):
		return null
	var t = _g.Editor.Tools[tool_name]
	if t == null or not is_instance_valid(t):
		return null
	return t


func _menu_has_layer(lm, layer_z: int) -> bool:
	for i in range(lm.get_item_count()):
		var md = lm.get_item_metadata(i)
		if typeof(md) == TYPE_INT or typeof(md) == TYPE_REAL:
			if int(md) == layer_z:
				return true
	return false
