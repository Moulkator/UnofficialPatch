# tool_hint.gd
# Adds custom hints to the bottom Infobar (Master/Editor/VPartition/Infobar/Align/Tooltips).
#
# Strategy: to perfectly match DD's visual style (stylebox on keys, grey tint,
# font, spacing), we CLONE existing DD nodes via duplicate() rather than
# building our own from scratch. Each hint we build is assembled by
# duplicating template nodes we find in the native Tooltips tree.
#
# Templates we rely on (all present at DD startup):
#   Default/Zoom/Control    → Label "CTRL" — template for a modifier key
#   Default/Zoom/+          → Label "+"    — template for the plus separator
#   Default/Zoom/Scroll     → TextureRect   — template for scroll icon
#   Default/Zoom/Control2   → Control       — template for spacer between key block and info
#   Default/Zoom/Info       → Label         — template for the description text
#   Object/90DegreeTurn/R-Click → TextureRect — template for RMB icon
#   Default/Pan/Mouse 3     → TextureRect  — template for MMB icon
#
# Public API:
#   add_hint(tool_name, category, hint_id, parts, info, opts)
#     parts: Array of strings/dicts describing the key block, left-to-right:
#       "CTRL", "SHIFT", "ALT", "F", "ENTER", "TAB", ...  → modifier key label
#       "+" or "OR"                                        → separator
#       {"icon": "rclick"|"mclick"|"scroll"}              → mouse icon
#   remove_hint(tool_name, category, hint_id)
#   bind_category(tool_name, category)
#     Force a category visible when this tool is active (DD shows nothing).


var _g
var ui_scaler   # ui_scaler_builtin reference for detecting scale changes

# === state ===
var _last_tool := ""
var _settled_frames := 0
var _initialized := false
var _last_ui_scale := 1.0
# Remember each cloned TextureRect's base texture size so we can rescale it
# as the UI scale changes (base_size = texture size at scale 1.0).
# Key: instance_id, Value: Vector2 (base pixel dimensions)
var _clone_base_sizes := {}
# Cloned "key" Labels (CTRL, SHIFT, G, R, ...) — their StyleBox is captured
# at duplicate() time and doesn't follow UIScaler. We re-sync the stylebox
# and font metrics from the live template on each scale change.
# Value: template ref ("key" or "plus") so we know which template to copy from.
var _cloned_key_labels := {}   # instance_id -> "key" | "plus"

# hints: key "tool|cat" -> Array of { id, parts, info, opts, node }
var _hints := {}
var _tool_category_binding := {}
var _owned_nodes := []

# cached template nodes (resolved lazily)
var _tpl_key : Label = null
var _tpl_plus : Label = null
var _tpl_scroll : TextureRect = null
var _tpl_rclick : TextureRect = null
var _tpl_mclick : TextureRect = null
var _tpl_spacer : Control = null
var _tpl_info : Label = null
var _tpl_tip : Label = null

const SETTLE_FRAMES := 120
const TOOLTIPS_PATH := "Master/Editor/VPartition/Infobar/Align/Tooltips"

var _destroyed := false


# ============================================================================
# LIFECYCLE
# ============================================================================

func initialize() -> void:
	print("[ToolHint] initialized")


func cleanup() -> void:
	_destroyed = true
	# Free all nodes we cloned/added (hints + separators + bound categories)
	for n in _owned_nodes:
		if n != null and is_instance_valid(n):
			n.queue_free()
	_owned_nodes = []
	_hints = {}
	_tool_category_binding = {}
	_clone_base_sizes = {}
	_cloned_key_labels = {}
	_initialized = false
	_settled_frames = 0
	print("[ToolHint] Cleaned up")


# Walk our key/plus label templates to find fonts that UIScaler doesn't
# know about (i.e. DD's hint-bar uses separate DynamicFont instances that
# aren't registered by default). Register them so they follow UI scale.
# Must be called AFTER _resolve_templates() has populated the refs.
func _register_template_fonts_with_uiscaler() -> void:
	if ui_scaler == null or not is_instance_valid(ui_scaler):
		return
	var agent = ui_scaler.get("_ui_scaling_agent")
	if agent == null:
		return
	_resolve_templates()
	# Collect label templates whose fonts we want scaled.
	var label_tpls = []
	if _tpl_key != null: label_tpls.append(_tpl_key)
	if _tpl_plus != null: label_tpls.append(_tpl_plus)
	if _tpl_info != null: label_tpls.append(_tpl_info)
	if _tpl_tip != null: label_tpls.append(_tpl_tip)

	# Get the set of fonts already registered by UIScaler so we don't
	# register the same instance twice (would double-scale it).
	var known_fonts = {}
	var scalers = agent.get("scalers")
	if scalers is Array:
		for sc in scalers:
			var f = sc.get("_font")
			if f != null:
				known_fonts[f.get_instance_id()] = true

	# Current scale: the template's font.size is already-scaled, so we
	# divide by the current scale to get the "default" (scale-1.0) size.
	var cur_scale = _get_ui_scale()
	if cur_scale <= 0.0:
		cur_scale = 1.0

	var fs_class = ui_scaler.get("FontScaler")
	if fs_class == null:
		print("[ToolHint] FontScaler class unreachable, skipping font reg")
		return

	for lbl in label_tpls:
		if lbl == null or not is_instance_valid(lbl):
			continue
		var f = lbl.get_font("font")
		if f == null or not (f is DynamicFont):
			continue
		if known_fonts.has(f.get_instance_id()):
			continue
		known_fonts[f.get_instance_id()] = true
		var base_size = int(round(float(f.size) / cur_scale))
		var scaler = fs_class.new(f, base_size)
		agent.register(scaler)
		scaler.scale(cur_scale)
		print("[ToolHint] Registered font ", f, " (base_size=", base_size, ") with UIScaler")

	# Also register the Infobar container itself so its height shrinks
	# when the UI scale goes below 1.0. UIScaler doesn't track Infobar
	# natively, so without this the bar keeps its nominal height even
	# when all its content shrinks.
	_register_infobar_min_size(agent, cur_scale)


# Register the Infobar + its immediate size-constraining children with
# UIScaler so their rect_min_size follows the UI scale. Without this, the
# bar stays at its nominal height at scale < 1.0.
func _register_infobar_min_size(agent, cur_scale: float) -> void:
	var ps_class = ui_scaler.get("PropertyScaler")
	if ps_class == null:
		return
	if _g == null or _g.Editor == null:
		return
	var tree = _g.Editor.get_tree() if _g.Editor.has_method("get_tree") else null
	if tree == null or tree.root == null:
		return
	var infobar = tree.root.get_node_or_null("Master/Editor/VPartition/Infobar")
	if infobar == null:
		return

	# Any node we register already-scaled needs its stored default divided
	# back out first. We pass explicit default_value = current / scale so
	# PropertyScaler.scale() then multiplies by new_scale correctly.
	var candidates = [infobar]
	# Also handle Align and Tooltips if they carry their own min_size
	var align_node = infobar.get_node_or_null("Align")
	if align_node != null:
		candidates.append(align_node)
	var tt_node = _get_tooltips()
	if tt_node != null:
		candidates.append(tt_node)

	for node in candidates:
		if node == null or not is_instance_valid(node):
			continue
		if node.has_meta("_uphint_min_size_registered"):
			continue
		if not (node is Control):
			continue
		var cur_ms : Vector2 = node.rect_min_size
		# Skip fully-unconstrained nodes — nothing to scale
		if cur_ms.x <= 0 and cur_ms.y <= 0:
			continue
		var base_ms = cur_ms / cur_scale
		var scaler = ps_class.new(node, "rect_min_size", base_ms)
		agent.register(scaler)
		scaler.scale(cur_scale)
		node.set_meta("_uphint_min_size_registered", true)
		print("[ToolHint] Registered rect_min_size on ", node.name,
			" base=", base_ms, " current=", cur_ms)


func update(_delta: float) -> void:
	if _destroyed:
		return
	if _g == null or _g.Editor == null or _g.World == null:
		return

	if not _initialized:
		_settled_frames += 1
		if _settled_frames < SETTLE_FRAMES:
			return
		_initialized = true
		_last_ui_scale = _get_ui_scale()
		_register_default_hints()
		_register_template_fonts_with_uiscaler()
		_last_tool = _effective_tool_name()
		_apply_for_tool(_last_tool)
		return

	# Detect UI scale changes and resize our cloned nodes in place.
	# We can't just rebuild: DD needs a frame to free old nodes, and doing
	# both free+add in the same frame causes visible flashes. Instead we
	# keep the same nodes and retune their pixel dimensions.
	var cur_scale = _get_ui_scale()
	if abs(cur_scale - _last_ui_scale) > 0.001:
		_last_ui_scale = cur_scale
		_rescale_all_clones(cur_scale)

	# Use effective tool name (includes sub-mode suffix like ":edit" for tools
	# that have an EditPoints toggle)
	var atn = _effective_tool_name()
	if atn != _last_tool:
		_last_tool = atn
		_apply_for_tool(atn)
	else:
		# Re-enforce visibility every frame — DD may re-show a category we
		# hid (e.g. DD natively shows "Default" for PatternShapeTool, but we
		# want "Polygon" visible instead, so we have to override each frame).
		_enforce_bindings_visibility(atn)

	# Keep AssetInfo tooltip in sync with its text (DD updates it dynamically
	# as the cursor hovers different assets). Cheap: a couple of string compares.
	_sync_asset_info_tooltip()


# Read the current UI scale from ui_scaler_builtin. Returns 1.0 if no
# scaler is injected.
func _get_ui_scale() -> float:
	if ui_scaler != null and is_instance_valid(ui_scaler):
		var v = ui_scaler.get("_ui_scale_value")
		if v != null and v is float and v > 0.0:
			return v
	return 1.0


# Walk every clone we own and update its pixel dimensions based on the
# stored base size (captured at clone time, at the scale that was current
# when we cloned). Labels auto-relayout via UIScaler's font sizing; only
# TextureRects and fixed-size Controls need manual intervention.
func _rescale_all_clones(new_scale: float) -> void:
	var dead_keys = []
	for id in _clone_base_sizes.keys():
		var node = instance_from_id(id)
		if node == null or not is_instance_valid(node):
			dead_keys.append(id)
			continue
		var base : Vector2 = _clone_base_sizes[id]
		node.rect_min_size = base * new_scale
	for k in dead_keys:
		_clone_base_sizes.erase(k)

	# Re-sync StyleBox and font overrides on cloned key labels. duplicate()
	# captures these once; UIScaler updates the templates in place but not
	# our clones, so we manually copy the current template overrides each
	# time the scale changes.
	_resolve_templates()
	var dead_keys2 = []
	for id in _cloned_key_labels.keys():
		var node = instance_from_id(id)
		if node == null or not is_instance_valid(node):
			dead_keys2.append(id)
			continue
		var tpl_kind = _cloned_key_labels[id]
		var tpl = _tpl_key if tpl_kind == "key" else _tpl_plus
		if tpl == null or not is_instance_valid(tpl):
			continue
		_sync_label_style_from_template(node, tpl)
	for k in dead_keys2:
		_cloned_key_labels.erase(k)


# Copy the stylebox and font overrides from a live template onto a clone.
# This is how we make our cloned "key" labels follow UI-scale changes: the
# template gets its overrides updated by UIScaler, and we forward them.
func _sync_label_style_from_template(clone: Label, tpl: Label) -> void:
	if clone == null or tpl == null:
		return
	if not is_instance_valid(clone) or not is_instance_valid(tpl):
		return
	# Stylebox override (the grey rounded border around "CTRL", "G", etc.)
	# On Labels the override slot is "normal".
	if tpl.has_stylebox_override("normal"):
		clone.add_stylebox_override("normal", tpl.get_stylebox("normal"))
	# Font override — shares the same DynamicFont as the template, so its
	# size is already being scaled by UIScaler's FontScaler. We still need
	# to re-add the override in case duplicate() captured a null ref.
	if tpl.has_font_override("font"):
		clone.add_font_override("font", tpl.get_font("font"))
	# Theme constants on Label: "line_spacing", "shadow_offset_x", etc.
	for const_name in ["line_spacing", "shadow_offset_x", "shadow_offset_y"]:
		if tpl.has_constant_override(const_name):
			clone.add_constant_override(const_name, tpl.get_constant(const_name))
	# Force a layout recompute
	clone.minimum_size_changed()


# Call at clone time to remember a node's base (scale-1.0) dimensions so we
# can retune them later when the UI scale changes.
func _register_clone_for_rescale(node, base_size: Vector2) -> void:
	if node == null or not is_instance_valid(node):
		return
	if base_size.x <= 0 and base_size.y <= 0:
		return
	_clone_base_sizes[node.get_instance_id()] = base_size


# Lightweight version of the binding logic — just fixes visibility, doesn't
# rebuild hints. Called every frame to counteract DD resetting visibility.
func _enforce_bindings_visibility(tool_name: String) -> void:
	var tt = _get_tooltips()
	if tt == null:
		return
	if _tool_category_binding.has(tool_name):
		var bound_cat = _tool_category_binding[tool_name]
		for cat in tt.get_children():
			if not (cat is CanvasItem):
				continue
			var should_be_visible = (cat.name == bound_cat)
			if cat.visible != should_be_visible:
				cat.visible = should_be_visible


# Returns a composite "tool name" that includes sub-mode for tools with an
# EditPoints toggle. e.g. "PathTool:draw" vs "PathTool:edit".
# For tools without that toggle, returns just the ActiveToolName.
const EDIT_POINTS_TOOLS := ["PathTool", "WallTool", "PatternShapeTool"]

func _effective_tool_name() -> String:
	var atn = _get_active_tool_name()

	# No active tool (e.g. after two Escape presses, or when DD starts).
	# Use a synthetic name so we can bind a custom hint category.
	if atn == "":
		return "NoTool"

	# SelectTool has multiple sub-modes:
	#   :ft                  = Free Transform active with a compatible selection
	#   :none                = No selection
	#   :sel_wall            = Selection contains only walls (no rotate)
	#   :sel_portal_free     = Selection contains only freestanding portals (type 2)
	#   :sel_portal_anchor   = Selection contains only anchored (wall) portals (type 3)
	#   :sel_pattern         = Selection contains only pattern shapes (type 7)
	#   :sel_path            = Selection contains only paths (type 5)
	#   :sel_light           = Selection contains only lights (type 6)
	#   :sel_text            = Text selection (managed separately by text_transform)
	#   :sel                 = Anything else selected (generic catch-all)
	if atn == "SelectTool":
		var md = _g.get("ModMapData")
		if md is Dictionary and md.get("_free_transform_active", false):
			if _has_ft_compatible_selection():
				return "SelectTool:ft"
		# Texts are NOT in RawSelectables — they're tracked by text_transform.
		# Check them first so a pure text selection doesn't fall back to :none.
		var raw_has = _has_any_selection()
		var text_has = _has_text_selection()
		if not raw_has and text_has:
			return "SelectTool:sel_text"
		if raw_has:
			if _selection_is_only_type(1):
				return "SelectTool:sel_wall"
			if _selection_is_only_type(2):
				return "SelectTool:sel_portal_free"
			if _selection_is_only_type(3):
				return "SelectTool:sel_portal_anchor"
			if _selection_is_only_type(7):
				return "SelectTool:sel_pattern"
			if _selection_is_only_type(5):
				return "SelectTool:sel_path"
			if _selection_is_only_type(6):
				return "SelectTool:sel_light"
			return "SelectTool:sel"
		return "SelectTool:none"

	# PortalTool has a Freestanding/Anchored sub-mode
	if atn == "PortalTool":
		var tools_dict = _g.Editor.get("Tools")
		if tools_dict == null:
			return atn
		var tool = tools_dict.get("PortalTool")
		if tool == null:
			return atn
		var free = tool.get("Freestanding")
		if free == null:
			return atn
		return atn + (":free" if free else ":anchor")

	# PathTool/WallTool/PatternShapeTool have an EditPoints toggle
	if atn in EDIT_POINTS_TOOLS:
		var tools_dict = _g.Editor.get("Tools")
		if tools_dict == null:
			return atn
		var tool = tools_dict.get(atn)
		if tool == null:
			return atn
		var btn = tool.get("EditPoints")
		if btn == null:
			return atn
		return atn + (":edit" if btn.get("pressed") else ":draw")

	return atn


# FT-compatible Selectable types: Object, PortalFree, PortalWall, Pathway, PatternShape
# (list from favorites.gd line 695 which uses the same criterion)
const FT_COMPATIBLE_TYPES := [2, 3, 4, 5, 7]

func _has_ft_compatible_selection() -> bool:
	var tools_dict = _g.Editor.get("Tools")
	if tools_dict == null:
		return false
	var sel_tool = tools_dict.get("SelectTool")
	if sel_tool == null:
		return false
	var raw = sel_tool.get("RawSelectables")
	if raw == null or raw.size() == 0:
		return false
	# RawSelectables is an Array of Selectable objects with a .Type property
	for s in raw:
		if s == null:
			continue
		var t = s.get("Type")
		if t != null and int(t) in FT_COMPATIBLE_TYPES:
			return true
	return false


func _has_any_selection() -> bool:
	var tools_dict = _g.Editor.get("Tools")
	if tools_dict == null:
		return false
	var sel_tool = tools_dict.get("SelectTool")
	if sel_tool == null:
		return false
	var raw = sel_tool.get("RawSelectables")
	return raw != null and raw.size() > 0


# Text selection is tracked separately by text_transform.gd — not in RawSelectables
func _has_text_selection() -> bool:
	var md = _g.get("ModMapData")
	if not (md is Dictionary):
		return false
	var tt = md.get("_ttf_transform")
	if tt == null:
		return false
	var texts = tt.get("_selected_texts")
	return texts != null and texts.size() > 0


# True iff every selected item has the given Selectable type.
# Types: 1=Wall, 2=PortalFree, 3=PortalWall, 4=Object, 5=Pathway,
#        6=Light, 7=PatternShape, 8=Roof
func _selection_is_only_type(type_int: int) -> bool:
	var tools_dict = _g.Editor.get("Tools")
	if tools_dict == null:
		return false
	var sel_tool = tools_dict.get("SelectTool")
	if sel_tool == null:
		return false
	var raw = sel_tool.get("RawSelectables")
	if raw == null or raw.size() == 0:
		return false
	for s in raw:
		if s == null:
			continue
		var t = s.get("Type")
		if t == null or int(t) != type_int:
			return false
	return true


# ============================================================================
# PUBLIC API
# ============================================================================

func add_hint(tool_name: String, category: String, hint_id: String,
		parts: Array, info: String, opts: Dictionary = {}) -> void:
	var key = _hk(tool_name, category)
	if not _hints.has(key):
		_hints[key] = []
	for h in _hints[key]:
		if h.id == hint_id:
			return
	_hints[key].append({
		"id": hint_id,
		"parts": parts,
		"info": info,
		"opts": opts,
		"node": null,
	})
	if _initialized and (tool_name == "" or tool_name == _last_tool):
		_apply_for_tool(_last_tool)


func remove_hint(tool_name: String, category: String, hint_id: String) -> void:
	var key = _hk(tool_name, category)
	if not _hints.has(key):
		return
	var arr = _hints[key]
	for i in range(arr.size() - 1, -1, -1):
		if arr[i].id == hint_id:
			if arr[i].node != null and is_instance_valid(arr[i].node):
				arr[i].node.queue_free()
			_owned_nodes.erase(arr[i].node)
			arr.remove(i)


func bind_category(tool_name: String, category: String) -> void:
	_tool_category_binding[tool_name] = category
	if _initialized and tool_name == _last_tool:
		_apply_for_tool(_last_tool)


# ============================================================================
# APPLY
# ============================================================================

func _apply_for_tool(tool_name: String) -> void:
	var tt = _get_tooltips()
	if tt == null:
		return

	# Compress native + custom spacers for a tighter, less sprawling bar
	_compress_spacers(tt)

	# Hide Position display + clip AssetInfo text so long names don't overlap hints
	_customize_corner()

	# Build/rebuild hints for each (tool, cat). This may create new custom
	# categories — we need to do it BEFORE applying visibility so the binding
	# loop finds them.
	for key in _hints.keys():
		var split_parts = key.split("|", true, 1)
		var h_tool = split_parts[0]
		var h_cat = split_parts[1]
		if h_tool != "" and h_tool != tool_name:
			continue
		var cat_node = tt.get_node_or_null(h_cat)
		if cat_node == null:
			cat_node = _create_custom_category(tt, h_cat)
			if cat_node == null:
				continue
		for hint in _hints[key]:
			if hint.node == null or not is_instance_valid(hint.node):
				if cat_node.get_child_count() > 0:
					var sep = _make_inter_hint_separator(h_cat)
					if sep != null:
						cat_node.add_child(sep)
						_owned_nodes.append(sep)
				hint.node = _build_hint(hint.id, hint.parts, hint.info)
				if hint.node != null:
					cat_node.add_child(hint.node)
					_owned_nodes.append(hint.node)

	# Explicit bindings override DD's default visibility
	if _tool_category_binding.has(tool_name):
		var bound_cat = _tool_category_binding[tool_name]
		for cat in tt.get_children():
			if not (cat is CanvasItem):
				continue
			cat.visible = (cat.name == bound_cat)
	else:
		# No binding for this tool — DD manages its own category visibility.
		# But we may have previously forced some categories visible (via
		# another tool's binding). Explicitly hide any category that we've
		# ever bound, so it doesn't stay visible on unrelated tools.
		# DD will then set its own category visible right after.
		var our_bound_cats := {}
		for v in _tool_category_binding.values():
			our_bound_cats[v] = true
		for cat in tt.get_children():
			if not (cat is CanvasItem):
				continue
			if our_bound_cats.has(cat.name) and cat.visible:
				cat.visible = false


# ============================================================================
# HINT BUILDING — clone from templates
# ============================================================================

func _build_hint(hint_id: String, parts: Array, info: String) -> HBoxContainer:
	_resolve_templates()

	var hbox = HBoxContainer.new()
	hbox.name = "UPHint_" + hint_id
	# Tighten spacing between parts (icons, + separators, key labels).
	# DD's theme default is ~4px which leaves too much air around "+" signs.
	hbox.add_constant_override("separation", 0)

	# Build each part by cloning the appropriate template
	for p in parts:
		var node = _clone_part(p)
		if node != null:
			hbox.add_child(node)

	# Spacer clone (the "Control2" between key block and info)
	if _tpl_spacer != null:
		var sp = _tpl_spacer.duplicate()
		sp.name = "Spacer"
		# Spacer has a fixed rect_min_size that was scaled by UIScaler on
		# the template; capture the base width so it follows scale changes.
		_capture_spacer_base(sp)
		hbox.add_child(sp)

	# Info clone
	if _tpl_info != null:
		var info_node = _tpl_info.duplicate()
		info_node.name = "Info"
		info_node.text = info
		hbox.add_child(info_node)

	return hbox


func _clone_part(spec):
	if spec is String:
		var s = str(spec)
		if s == "+":
			if _tpl_plus == null:
				return null
			var d = _tpl_plus.duplicate()
			d.name = "Plus"
			d.text = "+"
			_cloned_key_labels[d.get_instance_id()] = "plus"
			return d
		# Any other string -> modifier key label
		if _tpl_key == null:
			return null
		var key = _tpl_key.duplicate()
		# DD pads keys with surrounding spaces (" CTRL ", " SHIFT ", " ALT ")
		key.text = " " + s.to_upper() + " "
		key.name = s.capitalize()
		_cloned_key_labels[key.get_instance_id()] = "key"
		return key

	if spec is Dictionary and spec.has("icon"):
		var kind = str(spec.icon)
		var tpl = _icon_template(kind)
		if tpl == null:
			return null
		var d = tpl.duplicate()
		d.name = kind.capitalize()
		# lclick: DD has no LMB icon, so we reuse the RMB one flipped horizontally
		if kind == "lclick" and d is TextureRect:
			d.flip_h = true
		# Capture the icon's current pixel size as a base (scale-1.0) value,
		# so _rescale_all_clones() can resize it later when UIScale changes.
		_capture_icon_base(d)
		return d

	if spec is Dictionary and spec.has("tip"):
		# Small "tip"-style prefix like DD's "Hold" / "or" labels.
		# Cloned from Object/Mirror/Hold which is a small muted Label.
		if _tpl_tip == null:
			return null
		var t = _tpl_tip.duplicate()
		t.name = "Tip"
		t.text = str(spec.tip)
		return t

	return null


# Store an icon TextureRect's base (scale-1.0) size so we can later resize
# it when UIScale changes. We derive the base by dividing the current size
# by the current scale — this works because the template was natively sized
# by DD (UIScaler already applied the current scale to it).
func _capture_icon_base(node) -> void:
	if node == null or not is_instance_valid(node):
		return
	var cur_scale = _get_ui_scale()
	if cur_scale <= 0.0:
		cur_scale = 1.0
	var size : Vector2 = node.rect_min_size
	if size.x <= 0 and size.y <= 0 and node is TextureRect and node.texture != null:
		size = node.texture.get_size()
	if size.x <= 0 and size.y <= 0:
		return
	var base : Vector2 = size / cur_scale
	_register_clone_for_rescale(node, base)
	# Apply the current scale right away in case the template's rect_min_size
	# hadn't yet been updated by UIScaler (e.g. we're mid-startup).
	node.rect_min_size = base * cur_scale


# Same idea as _capture_icon_base but for spacer Controls (sized blank
# Controls used for padding between key-block and info text).
func _capture_spacer_base(node) -> void:
	if node == null or not is_instance_valid(node):
		return
	var cur_scale = _get_ui_scale()
	if cur_scale <= 0.0:
		cur_scale = 1.0
	var size : Vector2 = node.rect_min_size
	if size.x <= 0 and size.y <= 0:
		return
	var base : Vector2 = size / cur_scale
	_register_clone_for_rescale(node, base)
	node.rect_min_size = base * cur_scale


func _icon_template(kind: String):
	match kind:
		"scroll": return _tpl_scroll
		"rclick": return _tpl_rclick
		"lclick": return _tpl_rclick  # mirrored at paint time via flip_h
		"mclick": return _tpl_mclick
	return null


# ============================================================================
# TEMPLATE RESOLUTION
# ============================================================================

func _resolve_templates() -> void:
	var tt = _get_tooltips()
	if tt == null:
		return

	if _tpl_key == null or not is_instance_valid(_tpl_key):
		var n = tt.get_node_or_null("Default/Zoom/Control")
		if n is Label:
			_tpl_key = n

	if _tpl_plus == null or not is_instance_valid(_tpl_plus):
		var n = tt.get_node_or_null("Default/Zoom/+")
		if n is Label:
			_tpl_plus = n

	if _tpl_scroll == null or not is_instance_valid(_tpl_scroll):
		var n = tt.get_node_or_null("Default/Zoom/Scroll")
		if n is TextureRect:
			_tpl_scroll = n

	if _tpl_rclick == null or not is_instance_valid(_tpl_rclick):
		# Multiple candidates — any with a non-null texture is fine
		for p in ["Object/90DegreeTurn/R-Click", "Line/RemovePoint/R-Click", "Wall/RemovePoint/R-Click"]:
			var n = tt.get_node_or_null(p)
			if n is TextureRect and n.texture != null:
				_tpl_rclick = n
				break

	if _tpl_mclick == null or not is_instance_valid(_tpl_mclick):
		var n = tt.get_node_or_null("Default/Pan/Mouse 3")
		if n is TextureRect:
			_tpl_mclick = n

	if _tpl_spacer == null or not is_instance_valid(_tpl_spacer):
		# Prefer a Spacer from an actual icon-hint since they're sized to
		# separate icon from text. Object/Rotate/Spacer is a known good one.
		# Fall back to Control2 from Default/Zoom if nothing else works.
		var candidates = [
			"Object/Rotate/Spacer",
			"Brush/BrushSize/Spacer",
			"Default/Pan/Spacer",
			"Default/Zoom/Control2",
		]
		for p in candidates:
			var n = tt.get_node_or_null(p)
			if n != null and (n is Control) and not (n is Label) and not (n is TextureRect):
				_tpl_spacer = n
				break

	if _tpl_info == null or not is_instance_valid(_tpl_info):
		var n = tt.get_node_or_null("Default/Zoom/Info")
		if n is Label:
			_tpl_info = n

	if _tpl_tip == null or not is_instance_valid(_tpl_tip):
		# Small tip-style label (lowercase, muted). DD uses this for "Hold" / "or".
		# Object/Mirror/Hold is present when Object category is loaded.
		var candidates = [
			"Object/Mirror/Hold",
			"Polygon/Erase/Hold",
			"Line/RemovePoint/or",
			"Default/Pan/or",
		]
		for p in candidates:
			var n = tt.get_node_or_null(p)
			if n is Label:
				_tpl_tip = n
				break


# Create a new category HBoxContainer by cloning the structure of an existing
# native one (Default is a good template — always present). We duplicate and
# strip all children so it starts empty. Visibility is handled by the binding
# logic so it only shows when the bound tool is active.
func _create_custom_category(tooltips: Node, cat_name: String) -> HBoxContainer:
	var template = tooltips.get_node_or_null("Default")
	if template == null or not (template is HBoxContainer):
		return null
	var new_cat = template.duplicate()
	new_cat.name = cat_name
	# Remove all duplicated children — we want an empty category
	var to_remove = []
	for c in new_cat.get_children():
		to_remove.append(c)
	for c in to_remove:
		new_cat.remove_child(c)
		c.queue_free()
	new_cat.visible = false  # hidden until tool is active
	tooltips.add_child(new_cat)
	_owned_nodes.append(new_cat)
	return new_cat


# Clone a category-level "Space:Control" separator (the padding DD puts
# between two consecutive hints within the same category). We try the
# target category first, then fall back to any known working sample.
func _make_inter_hint_separator(category_name: String) -> Control:
	var tt = _get_tooltips()
	if tt == null:
		return null
	var candidates = [
		category_name + "/Space",
		category_name + "/Space2",
		"Object/Space",
		"Object/Space2",
		"Polygon/Space",
		"Wall/Space",
	]
	for p in candidates:
		var n = tt.get_node_or_null(p)
		if n != null and (n is Control) and not (n is Label) and not (n is TextureRect) and not (n is Container):
			var dup = n.duplicate()
			dup.name = "UPSep"
			# Pre-compress our own separators (native ones are compressed
			# by _compress_spacers) to match.
			_shrink_control(dup, SEP_TARGET_W)
			return dup
	return null


# Shrink every spacing Control in the Tooltips tree to tighten the bar.
# Targets:
#   - Category-level "Space*" nodes (between hints)
#   - Intra-hint "Spacer" / "Control2" nodes (between key block and info)
# We only shrink, never expand. Uses metadata to avoid re-shrinking (or
# shrinking an already-customized node).
func _compress_spacers(tooltips: Node) -> void:
	for cat in tooltips.get_children():
		if not (cat is Node):
			continue
		# Category-level separators between hints
		for child in cat.get_children():
			if _is_plain_spacer(child):
				_shrink_control(child, SEP_TARGET_W)
		# Intra-hint spacers
		for hint in cat.get_children():
			if hint is HBoxContainer:
				for hchild in hint.get_children():
					if _is_plain_spacer(hchild):
						# Slightly larger than inter-hint sep since it
						# separates the key block from the description
						_shrink_control(hchild, INTRA_TARGET_W)


func _is_plain_spacer(n: Node) -> bool:
	# A "spacer" is a plain Control (not Label, TextureRect, Container, HBox…)
	return n is Control \
		and not (n is Label) \
		and not (n is TextureRect) \
		and not (n is Container) \
		and not (n is Button)


func _shrink_control(c: Control, target_w: float) -> void:
	if c.has_meta("up_shrunk"):
		return
	# Capture current min for safety (diagnostic; not used to expand back)
	c.set_meta("up_orig_min", c.rect_min_size)
	var cur = c.rect_min_size
	var new_x = min(cur.x, target_w) if cur.x > 0 else target_w
	c.rect_min_size = Vector2(new_x, cur.y)
	c.set_meta("up_shrunk", true)


# Customize the right-side Corner of the Infobar:
#   - CornerLabel (cursor position display) → hidden
#   - AssetInfo (pack name) → right-aligned, clipped, tooltip-synced
#
# Layout context (from runtime inspection):
#   Corner is a fixed-width HBoxContainer (200px at x=1720 in a 1920 window).
#   Both AssetInfo and CornerLabel used to have min_size.x=200 which is exactly
#   the Corner width — they were shown exclusively (DD toggles their visibility).
#   After hiding CornerLabel, AssetInfo fills the whole 200px and floats to the
#   right edge. We want it right-aligned (so clipping cuts the "Pack:" prefix
#   not the asset name) and the Corner to shrink so it doesn't take 200px when
#   the text is short.
func _customize_corner() -> void:
	var corner = _get_corner()
	if corner == null:
		return

	for c in corner.get_children():
		# CornerLabel visibility is managed per-frame by _sync_asset_info_tooltip
		# (it shows save status messages, hides during normal position display).
		if c is Label and c.name == "AssetInfo":
			if not c.has_meta("up_clipped"):
				c.clip_text = true
				c.align = Label.ALIGN_RIGHT
				c.rect_min_size = Vector2(ASSET_INFO_WIDTH, c.rect_min_size.y)
				c.mouse_filter = Control.MOUSE_FILTER_PASS
				c.set_meta("up_clipped", true)


# Called every frame. DD rewrites AssetInfo.text whenever the hovered/selected
# asset changes. We:
#   - Capture the original text as authoritative (stored in "up_orig_text" meta
#     and also in hint_tooltip for user hover).
#   - Measure its width with the label's font. If it exceeds the reserved width,
#     truncate from the END and append "[...]" so the start is preserved.
#   - The result is written back into text; but since DD might write again on
#     the next frame, we detect "DD-rewrote" by comparing text to our last
#     displayed output.
var _asset_info_node = null
var _corner_label_node = null

func _sync_asset_info_tooltip() -> void:
	# Resolve nodes lazily
	if _asset_info_node == null or not is_instance_valid(_asset_info_node) \
			or _corner_label_node == null or not is_instance_valid(_corner_label_node):
		var corner = _get_corner()
		if corner == null:
			return
		_asset_info_node = corner.get_node_or_null("AssetInfo")
		_corner_label_node = corner.get_node_or_null("CornerLabel")
		if _asset_info_node == null:
			return

	# --- CornerLabel: show temporarily when it holds a non-position status ---
	# DD reuses CornerLabel to display "Saving...", "Saved", etc. We detect
	# that by checking if the text starts with "Position" (the normal case).
	# When it holds a status message, we swap: show CornerLabel, hide AssetInfo.
	if _corner_label_node != null and is_instance_valid(_corner_label_node):
		var cl_text = _corner_label_node.text
		var is_position = cl_text.begins_with("Position")
		if is_position:
			# Normal: asset info visible, position hidden
			if _corner_label_node.visible:
				_corner_label_node.visible = false
			if not _asset_info_node.visible:
				_asset_info_node.visible = true
		else:
			# Status message present: swap
			if not _corner_label_node.visible:
				_corner_label_node.visible = true
			if _asset_info_node.visible:
				_asset_info_node.visible = false
			# Nothing more to do for AssetInfo while it's hidden
			return

	# --- AssetInfo: keep tooltip and ellipsis-truncation in sync ---
	var c = _asset_info_node
	var last_display = c.get_meta("up_last_display") if c.has_meta("up_last_display") else ""
	# If current text equals what we wrote last time, DD hasn't changed anything.
	if c.text == last_display and c.has_meta("up_orig_text"):
		return

	# DD wrote new text. Capture it as the original.
	var orig = c.text
	c.set_meta("up_orig_text", orig)
	c.hint_tooltip = orig

	# Compute display: truncate with [...] if too wide
	var display = _fit_with_ellipsis(c, orig, ASSET_INFO_WIDTH)
	c.text = display
	c.set_meta("up_last_display", display)


# Truncate `s` with "[...]" appended so that the rendered width fits in `max_w`.
# Binary-searches the longest prefix that fits.
func _fit_with_ellipsis(label: Label, s: String, max_w: float) -> String:
	if s == "":
		return s
	var font = label.get_font("font")
	if font == null:
		return s
	# If the full string fits, no truncation needed
	if font.get_string_size(s).x <= max_w:
		return s
	var ell = "[...]"
	var ell_w = font.get_string_size(ell).x
	# Binary search the max prefix length such that width(prefix)+width(ell) <= max_w
	var lo = 0
	var hi = s.length()
	while lo < hi:
		var mid = (lo + hi + 1) / 2
		var w = font.get_string_size(s.substr(0, mid)).x + ell_w
		if w <= max_w:
			lo = mid
		else:
			hi = mid - 1
	if lo <= 0:
		return ell
	return s.substr(0, lo) + ell


func _get_corner() -> Node:
	if _g.World == null:
		return null
	return _g.World.get_tree().root.get_node_or_null(CORNER_PATH)


# Target widths (tweak here to taste)
const SEP_TARGET_W := 35.0      # between two hints
const INTRA_TARGET_W := 0.0     # between key block and info inside a hint
const ASSET_INFO_WIDTH := 435.0 # reserved width for asset name on the right
const CORNER_PATH := "Master/Editor/VPartition/Infobar/Align/Corner"


# ============================================================================
# UTIL
# ============================================================================

func _get_tooltips() -> Node:
	if _g.World == null:
		return null
	return _g.World.get_tree().root.get_node_or_null(TOOLTIPS_PATH)


func _get_active_tool_name() -> String:
	var atn = _g.Editor.get("ActiveToolName")
	return "" if atn == null else str(atn)


func _hk(tool_name: String, category: String) -> String:
	return tool_name + "|" + category


# ============================================================================
# DEFAULT HINTS
# ============================================================================

func _register_default_hints() -> void:
	# NoTool — shown when no tool is active (fresh open, double Escape).
	# Global editor toggles that work in every tool but are most discoverable
	# here. Uses a custom category since DD shows nothing natively.
	bind_category("NoTool", "NoToolUP")
	add_hint("NoTool", "NoToolUP", "pan",
		[{"icon": "mclick"}, {"tip": "or"}, "SPACE"], "Pan")
	add_hint("NoTool", "NoToolUP", "zoom",
		["CTRL", "+", {"icon": "scroll"}], "Zoom")
	add_hint("NoTool", "NoToolUP", "grid",
		["G"], "Grid")
	add_hint("NoTool", "NoToolUP", "snap",
		["S"], "Snap")
	add_hint("NoTool", "NoToolUP", "ruler",
		["R"], "Ruler")
	add_hint("NoTool", "NoToolUP", "align",
		["H"], "Align Tool")
	add_hint("NoTool", "NoToolUP", "lights",
		["L"], "Lights")
	add_hint("NoTool", "NoToolUP", "trace",
		["T"], "Show/Hide Trace Image")
	add_hint("NoTool", "NoToolUP", "compare",
		["C"], "Compare Levels")
	add_hint("NoTool", "NoToolUP", "guides",
		["CTRL", "+", "R"], "Guides")

	# ObjectTool (order matters — appears left-to-right in the bar)
	add_hint("ObjectTool", "Object", "fine_rotate",
		["SHIFT", "+", "Z", "+", {"icon": "scroll"}], "1° Rotate")
	add_hint("ObjectTool", "Object", "fav_toggle",
		["F"], "Favorites")
	add_hint("ObjectTool", "Object", "ctx_menu",
		[{"tip": "list"}, {"icon": "rclick"}], "Context Menu")

	# ScatterTool
	add_hint("ScatterTool", "Scatter", "fav_toggle",
		["F"], "Favorites")
	add_hint("ScatterTool", "Scatter", "ctx_menu",
		[{"tip": "list"}, {"icon": "rclick"}], "Context Menu")

	# PrefabTool — no native category, we create a custom one and bind it
	bind_category("PrefabTool", "PrefabUP")
	add_hint("PrefabTool", "PrefabUP", "scale",
		["ALT", "+", {"icon": "scroll"}], "Scale")
	add_hint("PrefabTool", "PrefabUP", "rotate",
		[{"icon": "scroll"}], "Rotate")
	add_hint("PrefabTool", "PrefabUP", "rotate_5deg",
		["Z", "+", {"icon": "scroll"}], "5° Rotate")
	add_hint("PrefabTool", "PrefabUP", "rotate_1deg",
		["SHIFT", "+", "Z", "+", {"icon": "scroll"}], "1° Rotate")
	add_hint("PrefabTool", "PrefabUP", "rotate_90",
		[{"icon": "rclick"}], "90° Rotate")
	add_hint("PrefabTool", "PrefabUP", "forget",
		[{"tip": "list"}, {"icon": "rclick"}], "Forget")

	# PathTool — two sub-modes: draw and edit points. Sub-mode is auto-detected
	# via EditPoints button (see _effective_tool_name).
	# DRAW mode: DD shows "Line" category (RemovePoint, Curve, UndoPoint). We add arc cycling.
	add_hint("PathTool:draw", "Line", "arc_mode",
		[{"tip": "curve"}, "CTRL"], "Arc")
	add_hint("PathTool:draw", "Line", "cycle_asset",
		[{"tip": "list"}, "SHIFT", "+", {"icon": "scroll"}], "Cycle Asset")
	add_hint("PathTool:draw", "Line", "ctx_menu",
		[{"tip": "list"}, {"icon": "rclick"}], "Context Menu")
	# EDIT POINTS mode: DD shows "Points" category (DEL or BKSP → Remove Point).
	# We add split, curve/flatten shortcuts, arc cycling.
	add_hint("PathTool:edit", "Points", "split",
		[{"tip": "between points"}, "DEL", {"tip": "or"}, "BKSP"], "Split")
	add_hint("PathTool:edit", "Points", "curve",
		["SHIFT"], "Add/Edit Curve")
	add_hint("PathTool:edit", "Points", "flatten",
		["SHIFT", "+", "ALT"], "Flatten")
	add_hint("PathTool:edit", "Points", "arc_mode",
		[{"tip": "curve"}, "CTRL"], "Arc")

	# WallTool — same two sub-modes as PathTool.
	# DRAW mode: DD shows "Wall" category (RemovePoint, Curve, UndoPoint, ExtendExisting).
	#   Note: CTRL has a double use — on the first click it triggers DD's "Extend Existing"
	#   (native), and during drawing (polyline >= 1 point) it activates our arc preview.
	add_hint("WallTool:draw", "Wall", "arc_mode",
		[{"tip": "curve"}, "CTRL"], "Arc")
	add_hint("WallTool:draw", "Wall", "ctx_menu",
		[{"tip": "list"}, {"icon": "rclick"}], "Context Menu")
	# EDIT POINTS mode: DD shows "Points" category (DEL or BKSP → Remove Point).
	#   SplitPath mod doesn't operate on walls, but DD itself natively splits
	#   walls when you DEL/BKSP between points, so we surface that.
	add_hint("WallTool:edit", "Points", "split",
		[{"tip": "between points"}, "DEL", {"tip": "or"}, "BKSP"], "Split")
	add_hint("WallTool:edit", "Points", "curve",
		["SHIFT"], "Add/Edit Curve")
	add_hint("WallTool:edit", "Points", "flatten",
		["SHIFT", "+", "ALT"], "Flatten")
	add_hint("WallTool:edit", "Points", "arc_mode",
		[{"tip": "curve"}, "CTRL"], "Arc")

	# PatternShapeTool — same draw/edit split.
	#   DD natively shows the "Default" category for this tool (Pan/Zoom only),
	#   which isn't useful for drawing. We bind "Polygon" instead so the native
	#   RemovePoint/Curve/UndoPoint hints appear, then add our own.
	bind_category("PatternShapeTool:draw", "Polygon")
	add_hint("PatternShapeTool:draw", "Polygon", "rotate_90_tex",
		[{"icon": "rclick"}], "90° Rotate Texture")
	add_hint("PatternShapeTool:draw", "Polygon", "arc_mode",
		[{"tip": "curve"}, "CTRL"], "Arc")
	add_hint("PatternShapeTool:draw", "Polygon", "ctx_menu",
		[{"tip": "list"}, {"icon": "rclick"}], "Context Menu")
	# EDIT POINTS mode: cat "Points" with native RemovePoint.
	add_hint("PatternShapeTool:edit", "Points", "curve",
		["SHIFT"], "Add/Edit Curve")
	add_hint("PatternShapeTool:edit", "Points", "flatten",
		["SHIFT", "+", "ALT"], "Flatten")
	add_hint("PatternShapeTool:edit", "Points", "arc_mode",
		[{"tip": "curve"}, "CTRL"], "Arc")

	# PortalTool — two sub-modes: anchored (default, snaps to walls) and
	# freestanding (place anywhere). Detected via PortalTool.Freestanding.
	# No native DD category shown for this tool → we create custom ones.
	bind_category("PortalTool:anchor", "PortalAnchorUP")
	add_hint("PortalTool:anchor", "PortalAnchorUP", "cycle_asset",
		["SHIFT", "+", {"icon": "scroll"}], "Cycle Asset")
	add_hint("PortalTool:anchor", "PortalAnchorUP", "ctx_menu",
		[{"tip": "list"}, {"icon": "rclick"}], "Context Menu")

	bind_category("PortalTool:free", "PortalFreeUP")
	add_hint("PortalTool:free", "PortalFreeUP", "rotate_15",
		[{"icon": "scroll"}], "15° Rotate")
	add_hint("PortalTool:free", "PortalFreeUP", "rotate_5",
		["Z", "+", {"icon": "scroll"}], "5° Rotate")
	add_hint("PortalTool:free", "PortalFreeUP", "rotate_1",
		["SHIFT", "+", "Z", "+", {"icon": "scroll"}], "1° Rotate")
	add_hint("PortalTool:free", "PortalFreeUP", "cycle_asset",
		["SHIFT", "+", {"icon": "scroll"}], "Cycle Asset")
	add_hint("PortalTool:free", "PortalFreeUP", "ctx_menu",
		[{"tip": "list"}, {"icon": "rclick"}], "Context Menu")

	# LightTool — no sub-mode. We replace the native "Light" category (which
	# shows stale vanilla hints: scroll=Range, Alt+scroll=Rotate) with a custom
	# one matching the patched behavior (scroll=Rotate, Alt+scroll=Range).
	bind_category("LightTool", "LightUP")
	add_hint("LightTool", "LightUP", "rotate_15",
		[{"icon": "scroll"}], "15° Rotate")
	add_hint("LightTool", "LightUP", "rotate_5",
		["Z", "+", {"icon": "scroll"}], "5° Rotate")
	add_hint("LightTool", "LightUP", "rotate_1",
		["SHIFT", "+", "Z", "+", {"icon": "scroll"}], "1° Rotate")
	add_hint("LightTool", "LightUP", "range",
		["ALT", "+", {"icon": "scroll"}], "Range")
	add_hint("LightTool", "LightUP", "cycle_asset",
		["SHIFT", "+", {"icon": "scroll"}], "Cycle Asset")
	add_hint("LightTool", "LightUP", "rotate_90",
		[{"icon": "rclick"}], "90° Rotate")
	add_hint("LightTool", "LightUP", "favorites",
		["F"], "Favorites")
	add_hint("LightTool", "LightUP", "ctx_menu",
		[{"tip": "list"}, {"icon": "rclick"}], "Context Menu")

	# TerrainBrush — DD's native "Terrain" category already shows BrushSize ([scroll]).
	# We add popup-related hints (Favorites, Context Menu, Cycle Texture) that
	# only work when the Terrain popup is open.
	add_hint("TerrainBrush", "Terrain", "popup_favorites",
		[{"tip": "popup"}, "F"], "Favorites")
	add_hint("TerrainBrush", "Terrain", "popup_cycle",
		[{"tip": "popup"}, "SHIFT", "+", {"icon": "scroll"}], "Cycle Texture")
	add_hint("TerrainBrush", "Terrain", "popup_ctx_menu",
		[{"tip": "popup"}, {"icon": "rclick"}], "Context Menu")

	# CaveBrush — uses DD's "Brush" category (Hold ALT → Erase, [scroll] → Brush Size).
	# Adds style cycling, favorites, context menu.
	add_hint("CaveBrush", "Brush", "favorites",
		["F"], "Favorites")
	add_hint("CaveBrush", "Brush", "cycle_style",
		[{"tip": "list"}, "SHIFT", "+", {"icon": "scroll"}], "Cycle Style")
	add_hint("CaveBrush", "Brush", "ctx_menu",
		[{"tip": "list"}, {"icon": "rclick"}], "Context Menu")

	# SelectTool — Free Transform sub-mode.
	# Active when the FT toggle in SelectTool panel is pressed. Detected via
	# ModMapData["_free_transform_active"] (set by free_transform.gd).
	bind_category("SelectTool:ft", "FreeTransformUP")
	add_hint("SelectTool:ft", "FreeTransformUP", "ft_options",
		[{"icon": "rclick"}], "Transform Options")
	add_hint("SelectTool:ft", "FreeTransformUP", "ft_ratio",
		[{"tip": "scale mode"}, "SHIFT"], "Locked Ratio")
	add_hint("SelectTool:ft", "FreeTransformUP", "ft_center",
		[{"tip": "scale mode"}, "ALT"], "Centered Transform")

	# TextTool — no native DD category. Custom category with text-specific hints.
	bind_category("TextTool", "TextUP")
	add_hint("TextTool", "TextUP", "new_text",
		[{"icon": "lclick"}], "New Text")
	add_hint("TextTool", "TextUP", "cycle_font",
		[{"tip": "font selector"}, {"icon": "scroll"}], "Cycle Font")
	add_hint("TextTool", "TextUP", "line_break",
		["ENTER"], "Line Break (New Text)")

	# SelectTool — sub-modes :none (empty), :sel (selection), :ft (free transform).
	# NONE: no selection, show discovery-friendly basics.
	bind_category("SelectTool:none", "SelectNoneUP")
	add_hint("SelectTool:none", "SelectNoneUP", "prev_tool",
		["X"], "Previous Tool")
	add_hint("SelectTool:none", "SelectNoneUP", "eyedropper",
		[{"tip": "hover"}, "ENTER"], "Eyedropper")
	add_hint("SelectTool:none", "SelectNoneUP", "zoom",
		["CTRL", "+", {"icon": "scroll"}], "Zoom")
	add_hint("SelectTool:none", "SelectNoneUP", "pan",
		[{"icon": "mclick"}, {"tip": "or"}, "SPACE"], "Pan")
	add_hint("SelectTool:none", "SelectNoneUP", "cut",
		["CTRL", "+", "X"], "Cut")
	add_hint("SelectTool:none", "SelectNoneUP", "paste_in_place",
		["CTRL", "+", "SHIFT", "+", "V"], "Paste in place")
	add_hint("SelectTool:none", "SelectNoneUP", "remove_sel",
		["ALT"], "Remove from Selection")

	# SEL: something selected (any type). Currently tuned for Objects; will
	# likely need type-conditional additions later (e.g. style cycling for
	# lights, rotation slider for patterns, etc.).
	bind_category("SelectTool:sel", "SelectSelUP")
	add_hint("SelectTool:sel", "SelectSelUP", "rotate_5",
		["Z", "+", {"icon": "scroll"}], "5° Rotate")
	add_hint("SelectTool:sel", "SelectSelUP", "rotate_1",
		["SHIFT", "+", "Z", "+", {"icon": "scroll"}], "1° Rotate")
	add_hint("SelectTool:sel", "SelectSelUP", "deselect",
		["ALT", "+", {"icon": "lclick"}], "Deselect")
	add_hint("SelectTool:sel", "SelectSelUP", "ctx_menu",
		[{"icon": "rclick"}], "Context Menu")
	add_hint("SelectTool:sel", "SelectSelUP", "eyedropper",
		[{"tip": "hover"}, "ENTER"], "Eyedropper")
	add_hint("SelectTool:sel", "SelectSelUP", "cut",
		["CTRL", "+", "X"], "Cut")
	add_hint("SelectTool:sel", "SelectSelUP", "paste_in_place",
		["CTRL", "+", "SHIFT", "+", "V"], "Paste in place")

	# SEL_WALL: selection is walls only. Walls have no rotation, so we drop
	# the rotate-scroll hints and add wall-specific ones (drag-to-move, list
	# cycling, favorites, context menu).
	bind_category("SelectTool:sel_wall", "SelectSelWallUP")
	add_hint("SelectTool:sel_wall", "SelectSelWallUP", "move",
		[{"tip": "drag"}, {"icon": "lclick"}], "Move")
	add_hint("SelectTool:sel_wall", "SelectSelWallUP", "cycle_asset",
		[{"tip": "list"}, "SHIFT", "+", {"icon": "scroll"}], "Cycle Asset")
	add_hint("SelectTool:sel_wall", "SelectSelWallUP", "favorites",
		["F"], "Favorites")
	add_hint("SelectTool:sel_wall", "SelectSelWallUP", "ctx_menu",
		[{"icon": "rclick"}], "Context Menu")
	add_hint("SelectTool:sel_wall", "SelectSelWallUP", "eyedropper",
		[{"tip": "hover"}, "ENTER"], "Eyedropper")

	# SEL_PORTAL_ANCHOR: selection is only anchored (wall-bound) portals.
	# Rotation doesn't apply (portal orients with the wall), no cut/paste
	# needed because anchored portals require a wall.
	bind_category("SelectTool:sel_portal_anchor", "SelectSelPortalAnchorUP")
	add_hint("SelectTool:sel_portal_anchor", "SelectSelPortalAnchorUP", "cycle_asset",
		[{"tip": "list"}, "SHIFT", "+", {"icon": "scroll"}], "Cycle Asset")
	add_hint("SelectTool:sel_portal_anchor", "SelectSelPortalAnchorUP", "favorites",
		["F"], "Favorites")
	add_hint("SelectTool:sel_portal_anchor", "SelectSelPortalAnchorUP", "ctx_menu",
		[{"icon": "rclick"}], "Context Menu")
	add_hint("SelectTool:sel_portal_anchor", "SelectSelPortalAnchorUP", "eyedropper",
		[{"tip": "hover"}, "ENTER"], "Eyedropper")
	add_hint("SelectTool:sel_portal_anchor", "SelectSelPortalAnchorUP", "deselect",
		["ALT", "+", {"icon": "lclick"}], "Deselect")

	# SEL_PORTAL_FREE: selection is only freestanding portals. Rotation and
	# clipboard apply since these are placed anywhere.
	bind_category("SelectTool:sel_portal_free", "SelectSelPortalFreeUP")
	add_hint("SelectTool:sel_portal_free", "SelectSelPortalFreeUP", "rotate_5",
		["Z", "+", {"icon": "scroll"}], "5° Rotate")
	add_hint("SelectTool:sel_portal_free", "SelectSelPortalFreeUP", "rotate_1",
		["SHIFT", "+", "Z", "+", {"icon": "scroll"}], "1° Rotate")
	add_hint("SelectTool:sel_portal_free", "SelectSelPortalFreeUP", "cycle_asset",
		[{"tip": "list"}, "SHIFT", "+", {"icon": "scroll"}], "Cycle Asset")
	add_hint("SelectTool:sel_portal_free", "SelectSelPortalFreeUP", "favorites",
		["F"], "Favorites")
	add_hint("SelectTool:sel_portal_free", "SelectSelPortalFreeUP", "ctx_menu",
		[{"icon": "rclick"}], "Context Menu")
	add_hint("SelectTool:sel_portal_free", "SelectSelPortalFreeUP", "eyedropper",
		[{"tip": "hover"}, "ENTER"], "Eyedropper")
	add_hint("SelectTool:sel_portal_free", "SelectSelPortalFreeUP", "deselect",
		["ALT", "+", {"icon": "lclick"}], "Deselect")

	# SEL_PATTERN: selection is only pattern shapes (type 7).
	# Rotation uses RotateTransformBox like objects. Pattern-specific label
	# "Cycle Pattern" (rather than "Cycle Asset") since that's what the list
	# represents here.
	bind_category("SelectTool:sel_pattern", "SelectSelPatternUP")
	add_hint("SelectTool:sel_pattern", "SelectSelPatternUP", "rotate_5",
		["Z", "+", {"icon": "scroll"}], "5° Rotate")
	add_hint("SelectTool:sel_pattern", "SelectSelPatternUP", "rotate_1",
		["SHIFT", "+", "Z", "+", {"icon": "scroll"}], "1° Rotate")
	add_hint("SelectTool:sel_pattern", "SelectSelPatternUP", "cycle_pattern",
		[{"tip": "list"}, "SHIFT", "+", {"icon": "scroll"}], "Cycle Pattern")
	add_hint("SelectTool:sel_pattern", "SelectSelPatternUP", "favorites",
		["F"], "Favorites")
	add_hint("SelectTool:sel_pattern", "SelectSelPatternUP", "ctx_menu",
		[{"icon": "rclick"}], "Context Menu")
	add_hint("SelectTool:sel_pattern", "SelectSelPatternUP", "eyedropper",
		[{"tip": "hover"}, "ENTER"], "Eyedropper")
	add_hint("SelectTool:sel_pattern", "SelectSelPatternUP", "deselect",
		["ALT", "+", {"icon": "lclick"}], "Deselect")

	# SEL_PATH: selection is only paths (type 5). Same set as patterns/objects
	# but with "Cycle Path" label for the asset list.
	bind_category("SelectTool:sel_path", "SelectSelPathUP")
	add_hint("SelectTool:sel_path", "SelectSelPathUP", "rotate_5",
		["Z", "+", {"icon": "scroll"}], "5° Rotate")
	add_hint("SelectTool:sel_path", "SelectSelPathUP", "rotate_1",
		["SHIFT", "+", "Z", "+", {"icon": "scroll"}], "1° Rotate")
	add_hint("SelectTool:sel_path", "SelectSelPathUP", "cycle_path",
		[{"tip": "list"}, "SHIFT", "+", {"icon": "scroll"}], "Cycle Path")
	add_hint("SelectTool:sel_path", "SelectSelPathUP", "favorites",
		["F"], "Favorites")
	add_hint("SelectTool:sel_path", "SelectSelPathUP", "ctx_menu",
		[{"icon": "rclick"}], "Context Menu")
	add_hint("SelectTool:sel_path", "SelectSelPathUP", "eyedropper",
		[{"tip": "hover"}, "ENTER"], "Eyedropper")
	add_hint("SelectTool:sel_path", "SelectSelPathUP", "deselect",
		["ALT", "+", {"icon": "lclick"}], "Deselect")

	# SEL_LIGHT: selection is only lights (type 6). Rotation works via
	# light_fix's own handles. Shift+scroll is hijacked by light_fix to
	# cycle style (hence the "Cycle Style" label to match the LightTool).
	bind_category("SelectTool:sel_light", "SelectSelLightUP")
	add_hint("SelectTool:sel_light", "SelectSelLightUP", "rotate_5",
		["Z", "+", {"icon": "scroll"}], "5° Rotate")
	add_hint("SelectTool:sel_light", "SelectSelLightUP", "rotate_1",
		["SHIFT", "+", "Z", "+", {"icon": "scroll"}], "1° Rotate")
	add_hint("SelectTool:sel_light", "SelectSelLightUP", "cycle_style",
		[{"tip": "list"}, "SHIFT", "+", {"icon": "scroll"}], "Cycle Style")
	add_hint("SelectTool:sel_light", "SelectSelLightUP", "favorites",
		["F"], "Favorites")
	add_hint("SelectTool:sel_light", "SelectSelLightUP", "ctx_menu",
		[{"icon": "rclick"}], "Context Menu")
	add_hint("SelectTool:sel_light", "SelectSelLightUP", "eyedropper",
		[{"tip": "hover"}, "ENTER"], "Eyedropper")
	add_hint("SelectTool:sel_light", "SelectSelLightUP", "deselect",
		["ALT", "+", {"icon": "lclick"}], "Deselect")

	# SEL_TEXT: text selection. Texts are not in RawSelectables — they're
	# tracked by text_transform.gd. Rotation/cycle/favorites don't apply.
	bind_category("SelectTool:sel_text", "SelectSelTextUP")
	add_hint("SelectTool:sel_text", "SelectSelTextUP", "unlock_ratio",
		["SHIFT", "+", {"tip": "drag"}, {"icon": "lclick"}], "Unlock Ratio")
	add_hint("SelectTool:sel_text", "SelectSelTextUP", "from_center",
		["ALT", "+", {"tip": "drag"}, {"icon": "lclick"}], "Transform from Center")
	add_hint("SelectTool:sel_text", "SelectSelTextUP", "ctx_menu",
		[{"icon": "rclick"}], "Context Menu")
	add_hint("SelectTool:sel_text", "SelectSelTextUP", "scroll_fonts",
		[{"tip": "font"}, {"icon": "scroll"}], "Scroll Fonts")
	add_hint("SelectTool:sel_text", "SelectSelTextUP", "cut",
		["CTRL", "+", "X"], "Cut")

	# TraceImage — single toggle. Custom category (DD shows nothing useful
	# natively for this tool beyond Pan/Zoom).
	bind_category("TraceImage", "TraceImageUP")
	add_hint("TraceImage", "TraceImageUP", "toggle",
		["T"], "Show/Hide Trace Image")

	print("[ToolHint] default hints registered")
