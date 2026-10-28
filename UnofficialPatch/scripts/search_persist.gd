# ============================================================================
# Search Persist
# ----------------------------------------------------------------------------
# In the Object and Scatter tools, DD keeps the search bar TEXT when you switch
# tools and come back, but it loses the search RESULTS (the list reverts to all
# objects). This submod re-applies the search whenever the object library panel
# becomes visible again, so the filtered results come back.
#
# It re-emits "text_entered" on every non-empty search field in the panel,
# which covers DD's native SearchLineEdit as well as the separate search box
# added by AdditionalSearchOptions (which has its own LineEdit + handler and
# leaves DD's box empty). The Object and Scatter tools share the same
# ObjectLibraryPanel, so handling that one panel covers both.
#
# It also restores, even when the search is empty:
# - the grid (multi)selection, snapshotted per tool from user clicks so the
#   Scatter tool's multi-selection survives the round trip;
# - the Favorites mod's view mode (Show: Favorites / Hidden), which DD's reset
#   knocks back to Show All — delegated to favorites.gd (reapply_panel_mode).
#
# The same reset also happens when switching the panel's filter tabs
# (All / Used / Tags), so entering a tab arms the same reapply window: each
# tab's search lives in its own box (DD's for All, ASO's for Used/Tags) and
# the visible-field rule naturally restores the right one; the selection is
# re-matched, keeping the assets present in the new tab.
#
# Finally, it patches a DD quirk that fights this whole design: the native
# trash button next to the search bar resets the RESULTS but leaves the TEXT
# in the box. Since "text in a visible box" is the persisted search state (for
# this mod, for the Favorites overlay filter and for ASO), the cleared search
# would come back on the next tool return. We hook the trash button to clear
# the text as well.
# ============================================================================

var _g

var _panel = null
var _menu = null
var _last_tool = ""
var _reapply_delay = -1.0
# Per-tool selection snapshots: tool name -> Array of textures. Fed by the
# grid's gui selection signals (which fire for user clicks only, not for
# programmatic select()), so DD's own single-texture restore on tool entry
# never overwrites a saved multi-selection.
var _saved_sel = {}
var _sel_dirty = false
var _sel_hooked = null  # grid menu instance the selection signals are wired to
var _bin_hooked = null  # DD's native clear (trash) button, wired to also clear the text
var _tabs_hooked_panel = null  # panel whose All/Used/Tags buttons are wired

# Delay (seconds) before re-applying after a tool switch. Must stay ABOVE the
# 0.05s timer AdditionalSearchOptions uses in on_toolpanel_visibility_changed
# to re-emit DD's search box itself: whichever re-search runs last rebuilds the
# grid and wipes the other's restored selection/scroll. Firing after ASO at any
# FPS makes our re-search + selection restore the authoritative last pass.
# (A frame count is unusable here: 3 frames is ~12ms at 240fps but ~50ms at
# 60fps, racing ASO's timer in an FPS-dependent order.)
const REAPPLY_DELAY := 0.25


func initialize() -> void:
	pass


func update(delta: float) -> void:
	if _g == null or not ("Editor" in _g) or _g.Editor == null or not is_instance_valid(_g.Editor):
		return
	var active = _g.Editor.get("ActiveToolName")
	# Re-apply whenever we (re)enter the Object or Scatter tool — including
	# switching directly between them, where the shared panel never hides so a
	# visibility check would miss it. DD resets the search on every tool
	# Enable/Load, so we restore it shortly after (see REAPPLY_DELAY).
	_hook_selection_signals()
	_hook_clear_button()
	_hook_filter_tabs()
	if active != _last_tool:
		_last_tool = active
		if active == "ObjectTool" or active == "ScatterTool":
			_reapply_delay = REAPPLY_DELAY
	# Snapshot the selection when the user changed it (signal-driven, cheap:
	# one flag per frame). Skipped during the post-entry settling window where
	# DD/ASO rebuild the list and the state is transient.
	if _sel_dirty:
		_sel_dirty = false
		if _reapply_delay < 0.0 and (active == "ObjectTool" or active == "ScatterTool"):
			_snapshot_selection(active)
	if _reapply_delay >= 0.0:
		_reapply_delay -= delta
		if _reapply_delay < 0.0:
			_reapply_search()


func _reapply_search() -> void:
	var panel = _get_panel()
	if panel == null or not is_instance_valid(panel):
		return
	# --- Favorites view mode first ---------------------------------------
	# DD's tool Enable resets the panel to Show All. If the Favorites mod is
	# loaded and the panel was in another view (Show: Favorites / Hidden), ask
	# it to re-enter its stored mode: the full mode entry rebuilds the list,
	# its search overlay and its own saved selection — nothing left to do here.
	var fav = _favorites_mod()
	if fav != null:
		var saved = []
		for t in _saved_sel.get(_last_tool, []):
			if t != null and is_instance_valid(t):
				saved.append(t)
		if fav.call("reapply_panel_mode", "object", saved):
			return
	# --- Search ----------------------------------------------------------
	# Re-emit only search fields that are non-empty AND visible. DD hides its
	# native SearchLineEdit (inside `filters`) in Tags/Used mode, and
	# AdditionalSearchOptions hides its own box in All mode — so the visible
	# field is always the active search for the current mode. This avoids firing
	# a hidden field with stale text (e.g. ASO's box in All, which would search
	# with an empty asset list and clear the grid). Empty fields are skipped too
	# (re-emitting "" would make DD Reset() and wipe the results) — but an empty
	# search no longer aborts the whole pass: the selection below is restored
	# either way.
	var active_fields = []
	for le in _find_line_edits(panel):
		if le == null or not is_instance_valid(le):
			continue
		if le.text == null or le.text == "":
			continue
		if not le.is_visible_in_tree():
			continue
		active_fields.append(le)
	# --- Selection -------------------------------------------------------
	# Prefer the per-tool snapshot taken from the user's last clicks before the
	# switch (DD only restores a single texture on tool entry, which loses the
	# Scatter multi-selection). Fall back to whatever DD restored, then to the
	# current tool asset.
	var menu = _get_object_menu()
	var texs = []
	for t in _saved_sel.get(_last_tool, []):
		if t != null and is_instance_valid(t):
			texs.append(t)
	if texs.size() == 0 and menu != null and is_instance_valid(menu):
		var got = menu.call("GetMultiselectedTextures")
		if got != null:
			for t in got:
				if t != null and is_instance_valid(t):
					texs.append(t)
	if texs.size() == 0:
		texs = _current_tool_textures()
	# Re-run the search (DD's and/or ASO's handler picks it up).
	for le in active_fields:
		le.emit_signal("text_entered", le.text)
	# Restore the (multi)selection via DD's own methods (internal Lookup, safe).
	_restore_menu_selection(texs)


func _restore_menu_selection(texs: Array) -> void:
	var menu = _get_object_menu()
	if menu == null or not is_instance_valid(menu) or texs.size() == 0 or menu.get_item_count() == 0:
		return
	if texs.size() == 1:
		menu.call("SelectTexture", texs[0])
	else:
		menu.unselect_all()
		for t in texs:
			if t != null and is_instance_valid(t):
				menu.call("MultiselectTexture", t)
	var sel = menu.get_selected_items()
	if sel.size() > 0:
		# ensure_current_is_visible scrolls to the "current" item, which the
		# C# multiselect path does not set — pin it explicitly.
		menu.select(sel[0], false)
		menu.ensure_current_is_visible()


func _favorites_mod():
	# The Favorites submod publishes itself through Engine metadata (same
	# convention as popup_blur / terrain_slots_extended).
	if not Engine.has_meta("favorites_singleton"):
		return null
	var m = Engine.get_meta("favorites_singleton")
	if m != null and is_instance_valid(m) and m.has_method("reapply_panel_mode"):
		return m
	return null


func _hook_selection_signals() -> void:
	# Wire the grid's gui selection signals once (re-wired if the menu node is
	# ever recreated). These fire on user clicks only — programmatic select()
	# calls (DD's tool-entry restore, our own restore) stay silent, so the
	# snapshots always reflect a deliberate user selection.
	if _sel_hooked != null and is_instance_valid(_sel_hooked):
		return
	_sel_hooked = null
	var menu = _get_object_menu()
	if menu == null or not is_instance_valid(menu):
		return
	if not menu.is_connected("item_selected", self, "_on_menu_item_selected"):
		menu.connect("item_selected", self, "_on_menu_item_selected")
	if not menu.is_connected("multi_selected", self, "_on_menu_multi_selected"):
		menu.connect("multi_selected", self, "_on_menu_multi_selected")
	_sel_hooked = menu


func _on_menu_item_selected(_index) -> void:
	_sel_dirty = true


func _on_menu_multi_selected(_index, _selected) -> void:
	_sel_dirty = true


func _snapshot_selection(tool_name: String) -> void:
	# Keep the last non-empty selection per tool (a transient empty read must
	# not wipe a good snapshot).
	var menu = _get_object_menu()
	if menu == null or not is_instance_valid(menu):
		return
	var got = menu.call("GetMultiselectedTextures")
	var texs = []
	if got != null:
		for t in got:
			if t != null and is_instance_valid(t):
				texs.append(t)
	if texs.size() > 0:
		_saved_sel[tool_name] = texs


func note_external_pick(tool_name: String, texs: Array) -> void:
	# Public (called by eyedropper.gd): the tool's asset was just set
	# programmatically. Selection snapshots only follow user clicks in the
	# grid, so without this the reapply pass after the tool switch would
	# restore the previously clicked asset over the picked one (highlight in
	# Show: All, and the tool texture itself in Show: Favorites / Hidden).
	var valid = []
	for t in texs:
		if t != null and is_instance_valid(t) and t is Texture and t.resource_path != "":
			valid.append(t)
	if valid.size() > 0:
		_saved_sel[tool_name] = valid
	else:
		# Nothing matchable: drop the stale snapshot rather than restore it.
		_saved_sel.erase(tool_name)
	_sel_dirty = false


func _hook_clear_button() -> void:
	# Wire DD's native trash button (right of the object search bar) once —
	# re-wired if the node is ever recreated.
	if _bin_hooked != null and is_instance_valid(_bin_hooked):
		return
	_bin_hooked = null
	var panel = _get_panel()
	if panel == null or not is_instance_valid(panel):
		return
	var filters = panel.get("filters")
	if filters == null or not is_instance_valid(filters):
		return
	var hbox = filters.find_node("Search", true, false)
	if hbox == null or not is_instance_valid(hbox):
		return
	var le = hbox.find_node("SearchLineEdit", true, false)
	if le == null or not is_instance_valid(le):
		return
	var btn = _find_clear_button(hbox)
	if btn == null:
		return
	if not btn.is_connected("pressed", self, "_on_dd_clear_pressed"):
		btn.connect("pressed", self, "_on_dd_clear_pressed", [le])
	_bin_hooked = btn


func _find_clear_button(hbox):
	# Identify DD's clear button among the Search hbox children: prefer a
	# Button whose existing "pressed" connection targets a clear/reset handler
	# (DD's own C# callback), fall back to the last plain Button. ASO's search
	# history button is a MenuButton and is skipped either way.
	var fallback = null
	for child in hbox.get_children():
		if not (child is Button) or child is MenuButton:
			continue
		fallback = child
		for conn in child.get_signal_connection_list("pressed"):
			var mth = str(conn.get("method", "")).to_lower()
			if "clear" in mth or "reset" in mth:
				return child
	return fallback


func _hook_filter_tabs() -> void:
	# Wire the panel's All/Used/Tags filter buttons once (re-wired if the
	# panel is ever recreated).
	if _tabs_hooked_panel != null and is_instance_valid(_tabs_hooked_panel):
		return
	_tabs_hooked_panel = null
	var panel = _get_panel()
	if panel == null or not is_instance_valid(panel):
		return
	var any = false
	for prop in ["allButton", "usedButton", "tagsButton"]:
		var b = panel.get(prop)
		if b != null and is_instance_valid(b) and b.has_signal("toggled"):
			if not b.is_connected("toggled", self, "_on_filter_tab_toggled"):
				b.connect("toggled", self, "_on_filter_tab_toggled")
			any = true
	if any:
		_tabs_hooked_panel = panel


func _on_filter_tab_toggled(pressed: bool) -> void:
	# Entering a filter tab repopulates the list, dropping that tab's search
	# results and selection — same reset as a tool switch, same cure. The
	# previously active tab also emits toggled(false): ignored.
	if not pressed:
		return
	if _last_tool == "ObjectTool" or _last_tool == "ScatterTool":
		_reapply_delay = REAPPLY_DELAY


func _on_dd_clear_pressed(le) -> void:
	# Runs after DD's own handler (our connection was added later): DD has
	# reset the results, we kill the leftover text so nothing resurrects the
	# search. Programmatic text assignment emits no text_changed, so ASO's
	# live-search handler stays quiet; the Favorites overlay poll compares
	# text per frame and re-shows the full overlay by itself.
	if le != null and is_instance_valid(le) and le.text != "":
		le.text = ""
	# DD's reset rebuilt the full list and dropped the selection the user made
	# in the search results — schedule a short reapply pass (text is now
	# empty, so it only restores the selection; in a Favorites/Hidden view it
	# goes through the mode re-entry with the saved selection).
	_reapply_delay = 0.05


func _current_tool_textures() -> Array:
	# The current asset texture, read from the active tool's Preview (Preview has
	# a getter, and Prop.Texture is readable — unlike ObjectTool.Texture /
	# ScatterTool.Textures which are write-only and crash on get). Its
	# resource_path matches the results Lookup keys.
	var out = []
	if _g == null or not ("Editor" in _g) or _g.Editor == null or not is_instance_valid(_g.Editor):
		return out
	var editor = _g.Editor
	var tools = editor.get("Tools")
	if not (tools is Dictionary):
		return out
	var active = editor.get("ActiveToolName")
	var tool = null
	if active == "ScatterTool":
		tool = tools.get("ScatterTool")
	else:
		tool = tools.get("ObjectTool")
	if tool == null or not is_instance_valid(tool):
		return out
	var preview = tool.get("Preview")
	if preview == null or not is_instance_valid(preview):
		return out
	var tex = preview.get("Texture")
	if tex != null and is_instance_valid(tex):
		out.append(tex)
	return out


func _get_object_menu():
	if _menu != null and is_instance_valid(_menu):
		return _menu
	var panel = _get_panel()
	if panel == null or not is_instance_valid(panel):
		return null
	_menu = _find_grid_menu(panel)
	return _menu


func _find_grid_menu(root):
	# The object GridMenu is the ItemList that owns a Lookup dictionary.
	if root == null or not is_instance_valid(root):
		return null
	if root is ItemList:
		var lk = root.get("Lookup")
		if lk is Dictionary:
			return root
	for child in root.get_children():
		var found = _find_grid_menu(child)
		if found != null:
			return found
	return null


func _get_panel():
	if _panel != null and is_instance_valid(_panel):
		return _panel
	_menu = null
	if _g == null or not ("Editor" in _g) or _g.Editor == null or not is_instance_valid(_g.Editor):
		return null
	var p = _g.Editor.get("ObjectLibraryPanel")
	if p == null or not is_instance_valid(p):
		p = _g.Editor.get_node_or_null("VPartition/Panels/HSplit/ObjectLibraryPanel")
	_panel = p
	return _panel


func _find_line_edits(root, out = null):
	# Collect every LineEdit under the panel (DD's SearchLineEdit + any added by
	# other mods such as AdditionalSearchOptions).
	if out == null:
		out = []
	if root == null or not is_instance_valid(root):
		return out
	if root is LineEdit:
		out.append(root)
	for child in root.get_children():
		_find_line_edits(child, out)
	return out
