# layer_jump.gd
# Adds two small buttons (icons/up.png, icons/down.png) right after the
# Layer dropdown of the tools that expose one: Pattern Shape Tool,
# Material Brush, Path Tool, Object Tool, Scatter Tool and Select Tool.
# "Up" jumps to the next higher z-index layer, "Down" to the next lower one.
#
# The buttons are added as CHILDREN of the native OptionButton (anchored to
# its right edge) and the dropdown arrow is shifted left through the
# "arrow_margin" theme constant. The OptionButton itself is never moved, so
# the panel tree stays vanilla: other mods that look up the dropdown as the
# sibling following the "Layer" label (e.g. Minor Utils' layer hotkeys) keep
# working whatever the mod load order.
# The jump goes through the tool's native HotChangeLayer(int) when it exists
# (same path as the 1/2/3/4 hotkeys) — otherwise it selects the item and
# emits item_selected so the tool applies the change itself.
#
# Select Tool special case: when the selection spans several layers, every
# selected object / path / pattern jumps ONE step in its own direction, so
# the layer gap between them is preserved (the native dropdown would flatten
# them all onto a single layer). If any of them is already at the top (or
# bottom) layer, nothing moves. One undo step, via UndoLib.record_callback.
# Everything is restored in cleanup().

var _g

const _TOOL_NAMES = [
	"PatternShapeTool", "MaterialBrush", "PathTool",
	"ObjectTool", "ScatterTool", "SelectTool",
]

const _BUTTON_WIDTH = 27
const _BUTTON_GAP = 2

# tool_name -> { "tool", "menu", "hbox", "arrow_margin" }
var _entries := {}
var _tex_up = null
var _tex_down = null


func initialize() -> void:
	_tex_up = _load_icon_tex("icons/up.png")
	_tex_down = _load_icon_tex("icons/down.png")
	for name in _TOOL_NAMES:
		_inject(name)
	print("[LayerJump] initialized (%d tools)" % _entries.size())


func cleanup() -> void:
	for name in _entries.keys():
		var e = _entries[name]
		var menu = e["menu"]
		var hbox = e["hbox"]
		if is_instance_valid(menu):
			menu.add_constant_override("arrow_margin", e["arrow_margin"])
			if is_instance_valid(hbox) and hbox.get_parent() == menu:
				menu.remove_child(hbox)
		if is_instance_valid(hbox):
			hbox.queue_free()
	_entries.clear()
	print("[LayerJump] cleaned up")


# ── UI Injection ─────────────────────────────────────────────────────────────

func _inject(tool_name: String) -> void:
	if _g == null or _g.Editor == null:
		return
	var tools = _g.Editor.Tools
	if tools == null or not tools.has(tool_name):
		print("[LayerJump] tool not found: %s" % tool_name)
		return
	var dd_tool = tools[tool_name]
	var menu = dd_tool.get("LayerMenu")
	if menu == null or not (menu is OptionButton):
		print("[LayerJump] %s: LayerMenu not found" % tool_name)
		return

	# Full-rect, click-through row: only the two buttons catch the mouse, the
	# rest of the dropdown still opens the popup.
	var hbox = HBoxContainer.new()
	hbox.name = "LayerJumpRow"
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.alignment = BoxContainer.ALIGN_END
	hbox.add_constant_override("separation", _BUTTON_GAP)
	menu.add_child(hbox)
	hbox.set_anchors_and_margins_preset(Control.PRESET_WIDE)

	var up = _make_button(_tex_up, "▲", "Jump to the layer above")
	up.connect("pressed", self, "_on_jump", [tool_name, 1])
	hbox.add_child(up)
	var down = _make_button(_tex_down, "▼", "Jump to the layer below")
	down.connect("pressed", self, "_on_jump", [tool_name, -1])
	hbox.add_child(down)

	# Move the dropdown arrow out from under the buttons.
	var arrow_margin = menu.get_constant("arrow_margin")
	menu.add_constant_override("arrow_margin",
		arrow_margin + _BUTTON_WIDTH * 2 + _BUTTON_GAP * 2)

	_entries[tool_name] = {
		"tool": dd_tool, "menu": menu, "hbox": hbox, "arrow_margin": arrow_margin,
	}


func _make_button(tex, fallback_text: String, tip: String) -> Button:
	var b = Button.new()
	b.hint_tooltip = tip
	b.focus_mode = Control.FOCUS_NONE
	b.rect_min_size = Vector2(_BUTTON_WIDTH, 0)
	b.size_flags_vertical = Control.SIZE_FILL
	if tex != null:
		b.icon = tex
	else:
		b.text = fallback_text
	return b


func _load_icon_tex(rel: String) -> ImageTexture:
	if _g == null or _g.Root == null:
		return null
	var img = Image.new()
	if img.load(_g.Root + rel) != OK:
		print("[LayerJump] icon not found: %s" % rel)
		return null
	var tex = ImageTexture.new()
	tex.create_from_image(img, Texture.FLAG_FILTER)
	return tex


# ── Jump logic ───────────────────────────────────────────────────────────────

# direction: +1 = next higher z-index, -1 = next lower z-index.
# Works on item metadata (the z-index) rather than item order, so it does not
# depend on how DD sorts the dropdown.
func _on_jump(tool_name: String, direction: int) -> void:
	if not _entries.has(tool_name):
		return
	var e = _entries[tool_name]
	var menu = e["menu"]
	var dd_tool = e["tool"]
	if not is_instance_valid(menu) or dd_tool == null:
		return

	var count = menu.get_item_count()
	if count == 0:
		return
	var sel = menu.selected
	var current = null
	if sel >= 0 and sel < count:
		current = menu.get_item_metadata(sel)
	if current == null:
		current = dd_tool.get("ActiveLayer")
	if current == null:
		return
	current = int(current)

	# Pick the closest layer strictly above/below the current one.
	var best = null
	var best_index = -1
	for i in range(count):
		if menu.is_item_disabled(i) or menu.is_item_separator(i):
			continue
		var meta = menu.get_item_metadata(i)
		if meta == null:
			continue
		var z = int(meta)
		if direction > 0 and z > current and (best == null or z < best):
			best = z
			best_index = i
		elif direction < 0 and z < current and (best == null or z > best):
			best = z
			best_index = i
	if best == null:
		return

	if tool_name == "SelectTool" and _jump_selection(dd_tool, menu, direction):
		return

	if dd_tool.has_method("HotChangeLayer"):
		dd_tool.HotChangeLayer(best)
	else:
		menu.select(best_index)
		menu.emit_signal("item_selected", best_index)


# ── Select Tool: multi-layer selection ───────────────────────────────────────

# Returns true when it handled the jump (selection spanning 2+ layers).
# Returns false to let the caller fall back to the native single-layer path.
func _jump_selection(dd_tool, menu: OptionButton, direction: int) -> bool:
	var selected = dd_tool.get("Selected")
	if selected == null:
		return false

	# Only the types the native Layer dropdown handles.
	var nodes := []
	var layers := {}
	for nd in selected:
		if nd == null or not is_instance_valid(nd):
			continue
		var layer = _get_node_layer(nd)
		if layer == null:
			continue
		nodes.append(nd)
		layers[int(layer)] = true
	if nodes.size() < 2 or layers.size() < 2:
		return false

	# Available layers (z-index) from the dropdown.
	var avail := []
	for i in range(menu.get_item_count()):
		if menu.is_item_disabled(i) or menu.is_item_separator(i):
			continue
		var meta = menu.get_item_metadata(i)
		if meta != null:
			avail.append(int(meta))
	if avail.empty():
		return false

	# Compute each node's target; abort if any of them cannot move.
	var before := []
	var after := []
	for nd in nodes:
		var cur = int(_get_node_layer(nd))
		var target = _closest_layer(avail, cur, direction)
		if target == null:
			print("[LayerJump] selection cannot move %s: an asset is already on the extreme layer"
				% ("up" if direction > 0 else "down"))
			return true
		before.append([weakref(nd), cur])
		after.append([weakref(nd), target])

	_apply_layers(after)

	# Reflect the topmost asset's new layer in the dropdown.
	var shown = null
	for e in after:
		if shown == null or e[1] > shown:
			shown = e[1]
	if shown != null:
		if _g.World != null and _g.World.has_method("UpdateLayerMenu"):
			_g.World.UpdateLayerMenu(menu, shown)
		dd_tool.set("ActiveLayer", shown)

	var undo = _g.ModMapData.get("_undo_lib") if _g.ModMapData != null else null
	if undo != null and undo.has_method("record_callback"):
		undo.record_callback(self, "_apply_layers", [before], self, "_apply_layers", [after])
	else:
		print("[LayerJump] UndoLib not available; layer change not undoable")
	return true


# Closest layer strictly above (direction > 0) or below (direction < 0) `cur`.
func _closest_layer(avail: Array, cur: int, direction: int):
	var best = null
	for z in avail:
		if direction > 0 and z > cur and (best == null or z < best):
			best = z
		elif direction < 0 and z < cur and (best == null or z > best):
			best = z
	return best


# entries: [[WeakRef, layer], ...] — also used as undo/redo callback.
func _apply_layers(entries: Array) -> void:
	var objects = null
	if _g != null and _g.World != null and _g.World.has_method("GetCurrentLevel"):
		var level = _g.World.GetCurrentLevel()
		if level != null:
			objects = level.get("Objects")
	for e in entries:
		var nd = e[0].get_ref()
		if nd == null or not is_instance_valid(nd):
			continue
		var layer = int(e[1])
		if _is_pattern(nd):
			nd.SetLayer(layer)
		elif _is_prop(nd):
			# Same dance as the native SetLayer: the search table is keyed
			# by layer, so the prop has to be re-registered.
			if objects != null and objects.has_method("RemoveFromSearchTable"):
				objects.RemoveFromSearchTable(nd)
				nd.z_index = layer
				objects.AddToSearchTable(nd, false)
			else:
				nd.z_index = layer
		else:
			nd.z_index = layer


# Layer of a layerable node (prop, pathway, pattern shape) or null otherwise.
func _get_node_layer(nd: Node):
	if _is_pattern(nd):
		return nd.GetLayer()
	if _is_path(nd) or _is_prop(nd):
		return nd.z_index
	return null


func _is_pattern(nd: Node) -> bool:
	return nd is Polygon2D and nd.get("GlobalPolygon") != null and nd.has_method("SetLayer")


func _is_path(nd: Node) -> bool:
	return nd is Line2D and nd.get("FadeIn") != null


# Props expose HasShadow; portals also do but carry a Radius/WallID.
func _is_prop(nd: Node) -> bool:
	return nd.get("HasShadow") != null and nd.get("Radius") == null and nd.get("WallID") == null
