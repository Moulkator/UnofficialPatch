# right_click_util.gd
# Central right-click context menu for SelectTool selections.
#
# Providers register to contribute items to the context menu.
# Each provider can implement (all optional):
#   check_right_click() -> bool       — return true to intercept the click
#   get_context_items(raw) -> Array   — return [{label, icon, action_id}]
#   on_context_action(action_id, raw) — handle a menu click
#
# An item may carry a `submenu` array of items (same shape, minus submenus):
# the entry then opens a sub-popup instead of firing directly.
#
# Menu layout is decided at registration, not by the providers: register()
# takes an `order` (position in the menu) and a `group` (providers sharing a
# group are listed under the same divider). A `setting` id, when given, gates
# the whole provider on a mod_settings toggle — that is what the "Right Click
# Menu" settings section drives.
#
# Blocking windows: update() polls the RAW mouse state, so Godot's normal GUI
# event consumption inside a mod dialog cannot stop us — a right-click on a
# card of the Map Gallery would open the map context menu straight through the
# window. Mod dialogs therefore register themselves in a shared registry
# (Engine meta "_up_block_windows", an Array of WeakRef) and we skip the whole
# right-click handling while the cursor is inside one of them. The registry
# lives on Engine meta so a mod that only knows the key can feed it without
# holding a reference to this script.
#
# ── Public API for other mods (version 1) ───────────────────────────────────
# Other mods cannot reach this script instance, and their start() may run
# before or after ours, so the API is two Engine meta keys:
#
#   "_up_rcm_host"      (written by us) {world = Global.World, version = 1}
#       Tells a mod that this menu is live for the CURRENT map. Must be tested
#       lazily (at right-click time, not in start()) because of load order.
#   "_up_rcm_providers" (written by them) Array of
#       {id: String, provider: Object, world: Global.World, order: int}
#       Read every time the menu opens, so load order does not matter.
#
# Engine meta survives map changes while mod instances do not, and mods are
# enabled per map: `world` is the session stamp. An entry (or the host flag)
# whose world is freed or is not the current Global.World is stale and ignored.
# Re-registering an `id` replaces the previous entry.
#
# External providers implement get_context_items(raw), optionally
# get_void_context_items(), and on_context_action(action_id, raw) — same
# contract as internal ones, minus check_right_click(). Their items may also
# be {separator = true}, and any item may carry `disabled = true` (greyed out
# but still listed). They get their own divider group and default to
# order 1000 (after the patch entries, which use 10..60).
# Shift + right-click shows each top-level entry's order next to its label.

var _g
var ui_util

var _right_was_pressed := false
var _providers := []  # [{provider, order, group, setting, seq}]
var _context_menu: PopupMenu = null
var _popup_layer: CanvasLayer = null
var _item_map := {}   # menu id -> {provider, action_id}
var _last_raw = null
var _register_seq := 0
var _ext_seen := {}   # external provider ids already logged


const EXT_HOST_META := "_up_rcm_host"
const EXT_PROVIDERS_META := "_up_rcm_providers"
const EXT_API_VERSION := 1
const EXT_DEFAULT_ORDER := 1000
const EXT_SEQ_BASE := 1000000


func initialize() -> void:
	# Public API: advertise the menu for this map session (see header).
	if _g != null and _g.get("World") != null and is_instance_valid(_g.World):
		Engine.set_meta(EXT_HOST_META, {world = _g.World, version = EXT_API_VERSION})
	print("[RightClickUtil] Initialized with ", _providers.size(), " provider(s)")


# order  : position in the menu (ascending). Convention in Main.gd:
#          10 favorites, 20 free transform, 30 prefabs, 40 groups,
#          50 rotate, 60 clipboard.
# group  : divider group; providers sharing a value are listed together with
#          no separator between them (prefabs and groups do). Defaults to the
#          order, i.e. one group per provider.
# setting: mod_settings toggle id gating the provider ("" = always on).
func register(provider, order: int = 1000, group: int = -1, setting: String = "") -> void:
	if _find_entry(provider) != null:
		return
	_register_seq += 1
	_providers.append({
		provider = provider,
		order = order,
		group = (order if group < 0 else group),
		setting = setting,
		seq = _register_seq,
	})


func unregister(provider) -> void:
	var entry = _find_entry(provider)
	if entry != null:
		_providers.erase(entry)


func _find_entry(provider):
	for e in _providers:
		if e.provider == provider:
			return e
	return null


# sort_custom is unstable in Godot 3, hence the registration-order tiebreak.
func _sort_entries(a: Dictionary, b: Dictionary) -> bool:
	if a.order != b.order:
		return a.order < b.order
	return a.seq < b.seq


func _setting_enabled(setting: String) -> bool:
	if setting == "":
		return true
	if _g == null or _g.get("ModMapData") == null or not (_g.ModMapData is Dictionary):
		return true
	var ms = _g.ModMapData.get("_mod_settings")
	if ms == null or not ms.has_method("is_enabled"):
		return true
	return ms.is_enabled(setting)


func update(_delta: float) -> void:
	var right_now = Input.is_mouse_button_pressed(BUTTON_RIGHT)
	if right_now and not _right_was_pressed:
		_on_right_click()
	_right_was_pressed = right_now


const BLOCK_WINDOWS_META := "_up_block_windows"
# Node meta set on a registered window that behaves like a modal: while it is
# visible, right-clicks are swallowed everywhere, not only over its rect. Used
# by the Map Gallery, which is an exclusive popup — the map underneath receives
# no input at all, so our context menus must not appear either.
const BLOCK_ALL_META := "_up_block_all"


# Register a Control (WindowDialog / Popup / panel) that must swallow
# right-clicks while the cursor is over it.
func register_blocking_window(node) -> void:
	if node == null or not (node is Control):
		return
	var arr := []
	if Engine.has_meta(BLOCK_WINDOWS_META):
		var stored = Engine.get_meta(BLOCK_WINDOWS_META)
		if stored is Array:
			arr = stored
	for wr in arr:
		if wr is WeakRef and wr.get_ref() == node:
			return
	arr.append(weakref(node))
	Engine.set_meta(BLOCK_WINDOWS_META, arr)


# True when the cursor is inside a registered, visible blocking window.
# Uses get_local_mouse_position() rather than get_global_rect(): the mod
# dialogs live under the (scaled) UI canvas, so raw viewport coordinates do
# not line up with their global rects, whereas local coordinates always do.
func is_mouse_over_blocking_window() -> bool:
	if not Engine.has_meta(BLOCK_WINDOWS_META):
		return false
	var arr = Engine.get_meta(BLOCK_WINDOWS_META)
	if not (arr is Array) or arr.empty():
		return false
	var alive := []
	var over := false
	for wr in arr:
		if not (wr is WeakRef):
			continue
		var w = wr.get_ref()
		if w == null or not is_instance_valid(w) or not (w is Control):
			continue
		alive.append(wr)
		if over or not w.is_visible_in_tree():
			continue
		if w.has_meta(BLOCK_ALL_META) and bool(w.get_meta(BLOCK_ALL_META)):
			over = true
		elif Rect2(Vector2.ZERO, w.rect_size).has_point(w.get_local_mouse_position()):
			over = true
	if alive.size() != arr.size():
		Engine.set_meta(BLOCK_WINDOWS_META, alive)
	return over


func _on_right_click() -> void:
	# Right-click inside a textbox: the LineEdit/TextEdit shows its own native
	# copy/paste menu, ours must not stack on top of it. update() polls the RAW
	# mouse state, so the GUI consuming the click cannot stop us — we check the
	# focus owner instead. Godot processed the click (focus grab + native menu)
	# during input handling, BEFORE this _process poll, so the focused control
	# already tells us the click belongs to the textbox.
	if _is_mouse_in_text_edit():
		return

	# A mod dialog (Map Gallery and friends) is under the cursor: it handles
	# its own right-click menu, we must stay out of the way.
	if is_mouse_over_blocking_window():
		return

	# Let providers intercept (e.g. favorites list click).
	# Providers run regardless of active tool — their asset panels are
	# visible everywhere (WallTool, PathTool, etc.).
	for e in _providers:
		var p = e.provider
		if p.has_method("check_right_click") and p.check_right_click():
			return

	# The selection-based context menu only makes sense when SelectTool is
	# active. Calling SelectTool.GetSelectionRect() from another tool
	# CRASHES when DD's internal selection store contains disposed C#
	# nodes — the state DD leaves after a Ctrl+Z that removed a selected
	# asset. preserve_selection_undo.gd can clean those dead refs, but
	# only while SelectTool is the active tool; if the user Ctrl+Z's and
	# immediately switches to WallTool/PathTool, cleanup doesn't run and
	# the next right-click (e.g. to close a wall) would crash here.
	if _g == null:
		return
	var editor = _g.Editor
	if editor == null or not is_instance_valid(editor):
		return
	if editor.get("ActiveToolName") != "SelectTool":
		return

	# Don't show context menu when Free Transform is active
	if _g.ModMapData is Dictionary and _g.ModMapData.get("_free_transform_active", false):
		return

	# Get select tool + selection
	var select_tool = _get_select_tool()
	if select_tool == null:
		return
	var raw = select_tool.RawSelectables

	# Two flavours of context menu:
	#   near_selection = true  -> right-click on/near the selection box:
	#       providers contribute via get_context_items(raw) (Favorites, FT,
	#       Copy/Cut/Delete, Paste...).
	#   near_selection = false -> right-click in empty space (no selection,
	#       or selection far away): providers contribute via
	#       get_void_context_items() (Paste / Paste in Place only). This is
	#       what lets the user paste into the void.
	var near_selection := false
	if raw != null and raw.size() > 0:
		# Defense in depth: if the selection contains dead entries (edge
		# case where cleanup hasn't run yet on this frame), bail out.
		# GetSelectionRect() would crash on them.
		if _raw_has_dead(raw):
			return
		# Near the selection box? (256px screen space)
		near_selection = _is_mouse_near_selection(select_tool)

	# Ask each provider for items, in menu order
	var all_items := []
	_last_raw = raw

	var entries := []
	for e in _providers:
		entries.append(e)
	for e in _external_entries():
		entries.append(e)
	entries.sort_custom(self, "_sort_entries")

	# Groups are compared as strings: internal ones are ints, external ones
	# are "ext:<id>", and Godot 3 errors on int != String.
	var last_group := ""
	# Shift + right-click: suffix every top-level entry with its provider's
	# order, so users / modders can see where a given `order` value lands.
	var show_order := Input.is_key_pressed(KEY_SHIFT)
	for e in entries:
		if not _setting_enabled(e.setting):
			continue
		var p = e.provider
		var items = null
		if near_selection:
			if p.has_method("get_context_items"):
				items = p.get_context_items(raw)
		else:
			if p.has_method("get_void_context_items"):
				items = p.get_void_context_items()
		# Sanitized copies: a malformed item from another mod must not abort
		# the whole menu (a missing Dictionary key is a hard error in GDScript).
		items = _normalize_items(items, p, true)
		if items.size() == 0:
			continue
		# Separator between divider groups only, and never leading.
		var gkey := str(e.group)
		if all_items.size() > 0 and gkey != last_group:
			all_items.append({label = "", icon = null, action_id = "", _sep = true})
		last_group = gkey
		for item in items:
			# Items are sanitized copies: relabeling never touches the provider's data.
			if show_order and not item.get("_sep", false):
				item.label = "%s  [%d]" % [item.label, int(e.order)]
			all_items.append(item)

	if all_items.size() == 0:
		return

	_show_popup(all_items)


func _show_popup(items: Array) -> void:
	if _context_menu and is_instance_valid(_context_menu):
		_context_menu.queue_free()
		_context_menu = null

	_context_menu = PopupMenu.new()
	_item_map = {}
	var next_id := 0

	for item in items:
		if item.get("_sep", false):
			_context_menu.add_separator()
			continue
		var submenu = item.get("submenu", null)
		if submenu is Array and submenu.size() > 0:
			var sub = PopupMenu.new()
			sub.name = "rcu_sub_%d" % next_id
			for sub_item in submenu:
				if sub_item.get("_sep", false):
					sub.add_separator()
					continue
				sub.add_item(sub_item.label, next_id)
				if sub_item.get("icon", null) != null:
					sub.set_item_icon(sub.get_item_index(next_id), sub_item.icon)
				if sub_item.get("disabled", false):
					sub.set_item_disabled(sub.get_item_index(next_id), true)
				_item_map[next_id] = {provider = item["_provider"], action_id = sub_item.action_id}
				next_id += 1
			sub.connect("id_pressed", self, "_on_item_pressed")
			_context_menu.add_child(sub)
			# A submenu parent never emits id_pressed, so it needs no mapping.
			_context_menu.add_submenu_item(item.label, sub.name, next_id)
			if item.get("icon", null) != null:
				_context_menu.set_item_icon(_context_menu.get_item_index(next_id), item.icon)
			# A disabled submenu parent stays listed but does not open.
			if item.get("disabled", false):
				_context_menu.set_item_disabled(_context_menu.get_item_index(next_id), true)
			next_id += 1
			continue
		_context_menu.add_item(item.label, next_id)
		if item.get("icon", null) != null:
			_context_menu.set_item_icon(_context_menu.get_item_index(next_id), item.icon)
		if item.get("disabled", false):
			_context_menu.set_item_disabled(_context_menu.get_item_index(next_id), true)
		_item_map[next_id] = {provider = item["_provider"], action_id = item.action_id}
		next_id += 1

	_context_menu.connect("id_pressed", self, "_on_item_pressed")
	_context_menu.connect("popup_hide", self, "_on_popup_closed")

	_get_popup_layer().add_child(_context_menu)
	var mouse_pos = _g.World.get_tree().root.get_mouse_position()
	_context_menu.popup(Rect2(mouse_pos, Vector2(1, 1)))


func _on_item_pressed(id: int) -> void:
	if _context_menu and is_instance_valid(_context_menu):
		_context_menu.queue_free()
		_context_menu = null

	if not _item_map.has(id):
		return
	var mapping = _item_map[id]
	var provider = mapping.provider
	if provider != null and is_instance_valid(provider) and provider.has_method("on_context_action"):
		provider.on_context_action(mapping.action_id, _last_raw)


func _on_popup_closed() -> void:
	if _context_menu and is_instance_valid(_context_menu):
		_context_menu.queue_free()
		_context_menu = null


# ── Public API (other mods) ──────────────────────────────────────────────────

# Providers registered by other mods for the current map session, shaped like
# _providers entries. Stale entries (previous map) are pruned from the meta.
func _external_entries() -> Array:
	var out := []
	if _g == null or not Engine.has_meta(EXT_PROVIDERS_META):
		return out
	var arr = Engine.get_meta(EXT_PROVIDERS_META)
	if not (arr is Array) or arr.empty():
		return out
	var world = _g.World
	var by_id := {}  # last registration of an id wins
	for d in arr:
		if not (d is Dictionary):
			continue
		var p = d.get("provider")
		var w = d.get("world")
		if p == null or not is_instance_valid(p):
			continue
		if w == null or not is_instance_valid(w) or w != world:
			continue
		var id = d.get("id")
		if not (id is String) or id == "":
			continue
		by_id[id] = d
	var kept: Array = by_id.values()
	if kept.size() != arr.size():
		Engine.set_meta(EXT_PROVIDERS_META, kept)
	var i := 0
	for key in by_id:
		var entry: Dictionary = by_id[key]
		var order = entry.get("order")
		if typeof(order) != TYPE_INT and typeof(order) != TYPE_REAL:
			order = EXT_DEFAULT_ORDER
		out.append({
			provider = entry.provider,
			order = int(order),
			group = "ext:" + key,
			setting = "",
			seq = EXT_SEQ_BASE + i,
		})
		i += 1
		if not _ext_seen.has(key):
			_ext_seen[key] = true
			print("[RightClickUtil] External provider registered: ", key)
	return out


# Returns clean {label, icon, action_id, disabled, _provider[, submenu]} / separator
# items. Accepts the internal `_sep` and the public `separator` spelling.
func _normalize_items(items, provider, allow_submenu: bool) -> Array:
	var out := []
	if not (items is Array):
		return out
	for item in items:
		if not (item is Dictionary):
			continue
		if item.get("separator", false) or item.get("_sep", false):
			# Never leading, never doubled.
			if out.size() > 0 and not out[out.size() - 1].get("_sep", false):
				out.append({label = "", icon = null, action_id = "", _sep = true})
			continue
		var label = item.get("label")
		if not (label is String) or label == "":
			continue
		var icon = item.get("icon")
		if not (icon is Texture):
			icon = null
		var clean := {
			label = label,
			icon = icon,
			action_id = item.get("action_id", ""),
			disabled = (true if item.get("disabled", false) else false),
			_provider = provider,
		}
		if allow_submenu:
			var sub = _normalize_items(item.get("submenu"), provider, false)
			if sub.size() > 0:
				clean["submenu"] = sub
		out.append(clean)
	# Never trailing.
	while out.size() > 0 and out[out.size() - 1].get("_sep", false):
		out.pop_back()
	return out


# ── Helpers ──────────────────────────────────────────────────────────────────

# True when the right-click landed inside a focused text-editing control.
# Focus owner is read through the SelectTool panel (any Control of the editor
# UI viewport works — get_focus_owner() is viewport-wide). The mouse-inside-
# rect test uses local coordinates, like is_mouse_over_blocking_window(), so
# UI scaling cannot skew it. A textbox merely KEEPING focus while the user
# right-clicks elsewhere on the map does not suppress the menu (rect test).
func _is_mouse_in_text_edit() -> bool:
	if _g == null or _g.get("Editor") == null:
		return false
	var editor = _g.Editor
	if not is_instance_valid(editor) or editor.get("Toolset") == null:
		return false
	var panel = editor.Toolset.GetToolPanel("SelectTool")
	if panel == null or not is_instance_valid(panel) or not panel.is_inside_tree():
		return false
	var focus = panel.get_focus_owner()
	if focus == null or not is_instance_valid(focus):
		return false
	if not (focus is LineEdit or focus is TextEdit):
		return false
	if not focus.is_visible_in_tree():
		return false
	return Rect2(Vector2.ZERO, focus.rect_size).has_point(focus.get_local_mouse_position())

func _get_select_tool():
	if not _g.Editor or not is_instance_valid(_g.Editor):
		return null
	var tools = _g.Editor.get("Tools")
	if tools == null or not tools is Dictionary:
		return null
	return tools.get("SelectTool")


func _raw_has_dead(raw) -> bool:
	# Mirror of preserve_selection_undo._raw_has_dead(): returns true if
	# any entry in SelectTool.RawSelectables refers to a disposed or
	# detached node. Touching GetSelectionRect() in that state crashes.
	if raw == null:
		return false
	for s in raw:
		if s == null or not is_instance_valid(s):
			return true
		var thing = s.get("Thing")
		if thing == null or not is_instance_valid(thing):
			return true
		if not thing.is_inside_tree() or thing.get_parent() == null:
			return true
	return false


func _is_mouse_near_selection(select_tool) -> bool:
	var world_mouse = _g.WorldUI.get("MousePosition") if _g.WorldUI and is_instance_valid(_g.WorldUI) else null
	if world_mouse == null:
		return true  # can't check, allow
	if not select_tool.has_method("GetSelectionRect"):
		return true
	var sel_rect = select_tool.GetSelectionRect()
	if not sel_rect or not sel_rect is Rect2 or sel_rect.size.length() == 0:
		return true
	var cam = _g.Editor.get("Camera") if _g.Editor else null
	var zoom_factor = 1.0
	if cam and is_instance_valid(cam) and cam is Camera2D:
		zoom_factor = cam.zoom.x
	var margin = 256.0 * max(zoom_factor, 0.2)
	var expanded = sel_rect.grow(margin)
	return expanded.has_point(world_mouse)


func _get_popup_layer() -> CanvasLayer:
	if _popup_layer and is_instance_valid(_popup_layer):
		return _popup_layer
	# Cross-session guard: free a popup layer left over from a previous mod
	# instance still parented to the persistent tree root.
	if Engine.has_meta("rcu_popup_layer"):
		var _old_pl = Engine.get_meta("rcu_popup_layer")
		if is_instance_valid(_old_pl):
			_old_pl.queue_free()
	_popup_layer = CanvasLayer.new()
	_popup_layer.name = "RightClickPopupLayer"
	_popup_layer.layer = 128
	Engine.set_meta("rcu_popup_layer", _popup_layer)
	_g.World.get_tree().root.add_child(_popup_layer)
	return _popup_layer
