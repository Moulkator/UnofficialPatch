# ui_rescaler.gd
#
# Per-category UI scale sliders for DD. Adds a "UI Rescaler" tool in the
# Settings tab. Each category multiplier is applied on top of DD's vanilla
# "Enlarge UI" setting, all multiplied by a global Master slider.
#
# Effective scale per category:
#   effective = dd_enlarge_ui * master * category_multiplier
#
# Baselines are captured lazily: for leaf controls (Button, Label,
# TextureRect, CheckButton/Box, Slider) with min_size = 0, we capture
# the rendered rect_size as the effective baseline so the multiplier
# has something to scale against.

var _g
var ui_util

const TOOL_CATEGORY = "Settings"
const TOOL_ID       = "ui_rescaler"
const TOOL_NAME     = "UI Rescaler"

const _SETTINGS_FILE = "user://UnofficialPatch/ui_rescaler.json"

const SLIDER_MIN  = 0.5
const SLIDER_MAX  = 3.0
const SLIDER_STEP = 0.05

const RESCAN_INTERVAL = 999999.0  # disabled: caused lag and didn't help
const MASTER_ID = "_master"

const CATEGORIES = [
	# Asset thumbnails — a SECOND-PASS category that only scales ItemList
	# icon_scale and fixed_icon_size. Nodes here are also claimed by their
	# region's main category (toolbar), which handles their fonts/min_size/etc.
	# The extra_pass flag tells _resolve_claims to ignore this category,
	# and _apply_all runs a dedicated pass for it.
	# Note: terrain popup ItemLists are intentionally NOT included — scaling
	# fixed_icon_size on those breaks the Godot ItemList grid layout
	# (overlapping items). They display at DD's vanilla scale (governed by
	# DD's own Enlarge UI setting, not by our slider).
	{"id": "asset_thumbnails", "label": "Asset Thumbnails",
	 "extra_pass": true, "rules": [
		# Single broad rule covering every ItemList under Panels:
		#   - Tools/Anchor/<each toolbar>/.../itemList (left tool panels)
		#   - HSplit/<various library panels>/.../ItemList (right library)
		#   - <rh_panel> directly under Panels (AdditionalSearchOptions
		#     terrain-search side panel, when its "enable_terrain_search_
		#     in_toolpanel" option is on — its grid_menu is moved here)
		# Note: terrain popup ItemLists are NOT included — they live in
		# Editor/Windows/, and scaling fixed_icon_size on them breaks the
		# Godot ItemList grid layout (overlapping items).
		{"pattern": "Master/Editor/VPartition/Panels",
		 "recursive": true, "type_filter": "ItemList"},
	]},
	{"id": "floatbar", "label": "Floatbar & Hotbar", "rules": [
		{"pattern": "Master/Editor/Floatbar", "recursive": true},
		# SelectFilterBar mod — floating bar toggled from the floatbar; scale
		# it together with the floatbar/hotbar. Lives in its own CanvasLayer
		# at the viewport root, so it's matched from there.
		{"pattern": "SelectFilterBarLayer/SelectFilterBar", "recursive": true},
	]},
	{"id": "infobar", "label": "Hint / Infobar", "rules": [
		{"pattern": "Master/Editor/VPartition/Infobar", "recursive": true},
	]},
	{"id": "top_menu", "label": "Top Menu Bar", "rules": [
		{"pattern": "Master/Editor/VPartition/MenuBar", "recursive": true},
	]},
	{"id": "popups", "label": "Popups / Dialogs", "rules": [
		{"pattern": "_root", "subtree_of_type": "Popup"},
		{"pattern": "_root", "subtree_of_type": "WindowDialog"},
		{"pattern": "_root", "subtree_of_type": "AcceptDialog"},
		{"pattern": "_root", "subtree_of_type": "ConfirmationDialog"},
	]},
	# Left tool panel (title, sliders, buttons, padding, splits).
	# Also includes the left category bar (Toolset) since the user doesn't
	# want a separate slider for it.
	{"id": "toolbar", "label": "Left Panel", "rules": [
		{"pattern": "Master/Editor/VPartition/Panels/Tools/Anchor/Toolset",
		 "recursive": true},
		{"pattern": "Master/Editor/VPartition/Panels/Tools/Anchor/*/Title"},
		{"pattern": "Master/Editor/VPartition/Panels/Tools/Anchor/*"},
		{"pattern": "Master/Editor/VPartition/Panels/Tools/Anchor/*/Divider"},
		{"pattern": "Master/Editor/VPartition/Panels/Tools/Anchor/*/Divider/Buttons",
		 "recursive": true},
		# Default DD layout: Align lives directly under ToolPanel.
		{"pattern": "Master/Editor/VPartition/Panels/Tools/Anchor/*/Divider/*/Align",
		 "recursive": true},
		# ResizeLeftPanel.gd wraps Align inside an extra HBoxContainer for
		# its drag handle. Add a rule that matches Align one level deeper.
		{"pattern": "Master/Editor/VPartition/Panels/Tools/Anchor/*/Divider/*/*/Align",
		 "recursive": true},
		{"pattern": "Master/Editor/VPartition/Panels/HSplit"},
		{"pattern": "Master/Editor/VPartition"},
	]},
]

const TEXT_CLASSES = ["Label", "Button", "CheckBox", "CheckButton",
	"MenuButton", "OptionButton", "LineEdit", "TextEdit", "RichTextLabel",
	"ItemList", "SpinBox", "ToolButton", "ColorPickerButton", "WindowDialog",
	"PopupMenu", "AcceptDialog", "ConfirmationDialog"]

const FONT_SLOTS = ["font", "title_font",
	"normal_font", "bold_font", "italics_font", "bold_italics_font", "mono_font"]

# Committed multipliers (persisted)
var _multipliers = {}
# Pending from sliders (applied on Apply)
var _pending = {}

# Baselines per node: instance_id -> dict
var _baselines = {}
# Font baselines: font instance_id -> {size}
var _font_baselines = {}
# Texture cache for scaled icons: "tex_id:w:h" -> ImageTexture
var _tex_cache = {}
# Per-button persistent scalable icon state: instance_id -> {tex, src_img, default_size}
# The texture instance is reused across scale changes (mutated in-place).
var _scalable_icons = {}
# Fonts modified during the current apply pass, to batch update_changes()
# (avoid calling it per-node-per-slot which floods the message queue).
var _dirty_fonts = {}

var _last_dd_scale = -1.0
var _initial_apply_done = false
# Edge-trigger latch for F12 dump key
var _dump_key_held = false
var _rescan_accum = 0.0

# Exposed for grid_ruler / tool_hint
var _ui_scale_value = 1.0

# UI refs
var _tool_panel  = null
var _sliders     = {}
var _spinboxes   = {}
var _apply_btn   = null
var _apply_btn_top = null

# Sliders mirrored inside Preferences > Interface tab. They act as a
# remote control for the General Scale + Asset Thumbnails categories
# in the main tool. Saving Preferences applies the changes; closing
# without saving reverts them (matching DD's native Preferences UX).
var _prefs_general_slider  = null
var _prefs_general_spinbox = null
var _prefs_thumbs_slider   = null
var _prefs_thumbs_spinbox  = null
var _prefs_setup_done = false
# Refs to the rows we add to Preferences, used to measure their actual
# rendered height for the popup resize (avoids hardcoding an arbitrary
# added_h that leaves gaps or clips depending on theme/font).
var _prefs_added_controls : Array = []
# Remember the multiplier values at the moment Preferences was opened,
# so we can revert if the user closes without pressing Save.
var _prefs_opened_general : float = 1.0
var _prefs_opened_thumbs  : float = 1.0
# Undo/redo stacks for Ctrl+Z / Ctrl+Y inside the Preferences popup.
# Each entry is a snapshot of the multipliers dict, taken right before
# a Save-button press applies new values. Limited depth to avoid bloat.
var _prefs_undo_stack : Array = []
var _prefs_redo_stack : Array = []
const PREFS_UNDO_LIMIT : int = 32

# Re-entrance guards for batched (yield-friendly) _apply_all().
# When _apply_all is in progress (mid-yield), additional calls set
# _apply_pending_rerun = true; the in-flight call honours it on completion.
var _apply_in_progress = false
var _apply_pending_rerun = false

# Per-category change tracking. Stores the multiplier values from the
# previous successful apply so we can skip categories whose multiplier
# is unchanged on subsequent applies. Drastically reduces work when the
# user only nudges a single slider — only nodes claimed by THAT category
# get re-scaled.
var _last_applied_multipliers = {}
var _last_applied_dd_scale = -1.0

# Busy popup (shown during multi-frame _apply_all). PopupPanel — no title
# bar, no close button — modal so the user can't tweak sliders mid-apply.
var _busy_popup = null
var _busy_label = null
var _status_lbl  = null


# ── Lifecycle ────────────────────────────────────────────────────────────

func initialize() -> void:
	_multipliers[MASTER_ID] = 1.0
	_pending[MASTER_ID] = 1.0
	for c in CATEGORIES:
		_multipliers[c.id] = 1.0
		_pending[c.id] = 1.0
	_load_settings()
	_register_tool_panel()
	# Wait longer than before so DD has time to layout all controls.
	var t = _g.World.get_tree().create_timer(2.5)
	t.connect("timeout", self, "_first_apply")
	print("[UIRescaler] Initialized")


func _first_apply() -> void:
	_initial_apply_done = true
	_last_dd_scale = _dd_enlarge_ui()
	_ui_scale_value = _last_dd_scale
	_apply_all(false)
	_setup_terrain_window_centering()


# Connect to TerrainWindow's visibility_changed signal so that we re-center
# the popup whenever it opens. DD's own positioning is computed before our
# UI scaling runs, so the centered position can be wrong (and the popup
# ends up partially off-screen at high scales). Mirrors scaling_api.gd.
var _centering_terrain_window = false


func _setup_terrain_window_centering() -> void:
	var tw = _find_terrain_window()
	if tw == null or not is_instance_valid(tw):
		return
	# Disconnect DD's own about_to_show handler — it computes positioning
	# based on the pre-scaled popup size, so once our scaling kicks in
	# the popup ends up off-center / off-screen. scaling_api.gd does
	# the same. (And: leaving it connected appears to interact with
	# Escape handling in a way that bubbles the close action up to the
	# parent tool — disconnecting fixes that too.)
	if tw.is_connected("about_to_show", tw, "_on_TerrainWindow_about_to_show"):
		tw.disconnect("about_to_show", tw, "_on_TerrainWindow_about_to_show")
	if not tw.is_connected(
			"visibility_changed", self, "_on_terrain_window_visibility_changed"):
		tw.connect("visibility_changed", self,
			"_on_terrain_window_visibility_changed", [tw])


func _find_terrain_window():
	var tree = _g.World.get_tree()
	if tree == null or tree.root == null:
		return null
	var editor = tree.root.get_node_or_null("Master/Editor")
	if editor == null:
		return null
	var windows = editor.get("Windows")
	if windows == null:
		return null
	return windows.get("TerrainWindow")


func _on_terrain_window_visibility_changed(window) -> void:
	if not is_instance_valid(window):
		return
	# Only act on becoming visible (don't fight Escape-to-close).
	if not window.visible:
		return
	if _centering_terrain_window:
		return
	# Set position MANUALLY rather than calling popup_centered(): the latter
	# re-invokes show()-like logic that can race with Escape-to-close and
	# leave the popup flickering open. Just assigning rect_position keeps
	# the popup's visible state alone.
	_centering_terrain_window = true
	var viewport_size = window.get_viewport_rect().size
	var wsz = window.rect_size
	window.rect_position = Vector2(
		max(0, (viewport_size.x - wsz.x) / 2.0),
		max(0, (viewport_size.y - wsz.y) / 2.0))
	_centering_terrain_window = false


func update(delta) -> void:
	if not _initial_apply_done:
		return
	# Lazy setup of the Preferences-tab sliders (remote control for the
	# General Scale + Asset Thumbnails categories). The Preferences node
	# may not exist immediately at boot; we retry every frame until it does.
	if not _prefs_setup_done:
		_try_setup_prefs_sliders()
	# Watchdog: if the busy popup is visible but no apply is in progress,
	# force-hide it. Defensive against any path that exits _apply_all
	# without hitting _hide_busy.
	if is_instance_valid(_busy_popup) and _busy_popup.visible \
			and not _apply_in_progress:
		_busy_popup.visible = false
	# F12 to trigger dump (works even when a popup is open)
	if Input.is_key_pressed(KEY_F12):
		if not _dump_key_held:
			_dump_key_held = true
			print("[UIRescaler] F12 pressed — triggering dump")
			_on_dump_buttons()
	else:
		_dump_key_held = false
	var s = _dd_enlarge_ui()
	if abs(s - _last_dd_scale) > 0.001:
		_last_dd_scale = s
		_ui_scale_value = s
		_baselines.clear()
		_font_baselines.clear()
		_tex_cache.clear()
		_scalable_icons.clear()
		# Force re-applying everything (baseline rebuild required)
		_last_applied_multipliers.clear()
		_last_applied_dd_scale = -1.0
		_apply_all(false)
		return
	_rescan_accum += delta
	if _rescan_accum >= RESCAN_INTERVAL:
		_rescan_accum = 0.0
		_apply_all(true)


# ── DD vanilla scale ─────────────────────────────────────────────────────

func _dd_enlarge_ui() -> float:
	if _g != null and _g.Settings != null:
		var s = _g.Settings
		for prop in ["UIScale", "EnlargeUI", "ScaleUI", "UI_Scale"]:
			var v = s.get(prop)
			if v != null and (v is float or v is int) and float(v) > 0.0:
				return float(v)
	return 1.0


# Center the ToolsetButton's "Label" child vertically inside its rect.
# Called from apply and via the "resized" signal.
func _recenter_toolset_label(button) -> void:
	if not is_instance_valid(button):
		return
	var label = button.get("label")
	if label == null or not is_instance_valid(label):
		return
	var lh : float = label.rect_size.y
	if lh <= 0:
		lh = label.get_minimum_size().y
	var y_pos = max(0.0, (button.rect_size.y - lh) / 2.0)
	label.rect_position = Vector2(label.rect_position.x, y_pos)


func _on_toolset_btn_resized(button) -> void:
	_recenter_toolset_label(button)


# Helper: get the "native" value of a property on an object, surviving
# mod reloads. On first call, captures the current value and stores it
# as meta on the object. On subsequent calls (after mod reload), returns
# the stored native value, preventing compounding (1.3 × 1.3 = 1.69).
#
# IMPORTANT: the first call for any given key must happen on a fresh,
# never-scaled value. We use a per-node marker "_uir_capture_done" to
# avoid re-capturing already-overridden values when state is rebuilt
# (e.g. mod reload). Any property captured BEFORE the marker is set is
# fine to capture; properties captured AFTER will read from meta.
func _native_value(obj, key: String, current_value):
	if obj == null or not is_instance_valid(obj):
		return current_value
	var meta_key = "_uir_native_" + key
	if obj.has_meta(meta_key):
		return obj.get_meta(meta_key)
	obj.set_meta(meta_key, current_value)
	return current_value


# ── Glob pattern matching ────────────────────────────────────────────────

func _segment_matches(name: String, pattern: String) -> bool:
	if pattern == "*":
		return true
	if pattern.find("*") < 0:
		return name == pattern
	var has_lead = pattern.begins_with("*")
	var has_trail = pattern.ends_with("*")
	var core = pattern.replace("*", "")
	if has_lead and has_trail:
		return name.find(core) >= 0
	if has_lead:
		return name.ends_with(core)
	if has_trail:
		return name.begins_with(core)
	return name == pattern


func _find_nodes_matching(pattern: String) -> Array:
	var tree = _g.World.get_tree() if _g.World else null
	if tree == null or tree.root == null:
		return []
	if pattern == "_root" or pattern == "":
		return [tree.root]
	var parts = pattern.split("/")
	var result = []
	_match_at(tree.root, parts, 0, result)
	return result


func _match_at(node, parts, idx, out) -> void:
	if idx >= parts.size():
		out.append(node)
		return
	var part = parts[idx]
	if part.find("*") >= 0:
		for c in node.get_children():
			if _segment_matches(c.name, part):
				_match_at(c, parts, idx + 1, out)
	else:
		var child = node.get_node_or_null(part)
		if child != null:
			_match_at(child, parts, idx + 1, out)


# ── Claim resolution ─────────────────────────────────────────────────────

func _resolve_claims() -> Dictionary:
	var claims = {}
	for cat in CATEGORIES:
		# extra_pass categories are handled separately, AFTER the main
		# pass, so their nodes aren't claimed here (which would prevent
		# them from receiving their region's font/min_size scaling).
		if cat.get("extra_pass", false):
			continue
		for rule in cat.rules:
			if rule.has("subtree_of_type"):
				_apply_subtree_of_type_rule(rule, cat.id, claims)
				continue
			var recursive = rule.get("recursive", false)
			var exclude_root = rule.get("exclude_root", false)
			var type_filter = rule.get("type_filter", "")
			for root in _find_nodes_matching(rule.pattern):
				if recursive:
					_claim_subtree(root, cat.id, type_filter, exclude_root, claims)
				else:
					_claim_one(root, cat.id, type_filter, claims)
	return claims


func _apply_subtree_of_type_rule(rule, cat_id, claims) -> void:
	var typ = rule.subtree_of_type
	for root in _find_nodes_matching(rule.pattern):
		_find_and_claim_subtrees_of_type(root, typ, cat_id, claims)


func _find_and_claim_subtrees_of_type(node, typ, cat_id, claims) -> void:
	if node is Control and node.is_class(typ):
		_claim_subtree(node, cat_id, "", false, claims)
		return
	for c in node.get_children():
		_find_and_claim_subtrees_of_type(c, typ, cat_id, claims)


func _claim_one(node, cat_id, type_filter, claims) -> void:
	if node == null or not is_instance_valid(node):
		return
	if not (node is Control):
		return
	if type_filter != "" and not node.is_class(type_filter):
		return
	var key = node.get_instance_id()
	if not claims.has(key):
		claims[key] = {"node": node, "cat_id": cat_id}


func _claim_subtree(root, cat_id, type_filter, exclude_root, claims) -> void:
	if not exclude_root:
		_claim_one(root, cat_id, type_filter, claims)
	for c in root.get_children():
		_claim_subtree_recursive(c, cat_id, type_filter, claims)


func _claim_subtree_recursive(node, cat_id, type_filter, claims) -> void:
	_claim_one(node, cat_id, type_filter, claims)
	for c in node.get_children():
		_claim_subtree_recursive(c, cat_id, type_filter, claims)


# ── Apply ────────────────────────────────────────────────────────────────

const APPLY_BATCH_SIZE = 200  # nodes per frame before yielding


# Compute which categories have a different multiplier (or effective scale
# via dd_enlarge_ui) compared to the previous apply. Returns a dict of
# cat_id -> true. Empty dict means no category changed. The "first apply"
# case is signalled by _last_applied_multipliers being empty and is handled
# separately in _apply_all (caller does not use this function's emptiness
# to detect first apply).
func _compute_changed_categories() -> Dictionary:
	var changed : Dictionary = {}
	if _last_applied_multipliers.empty():
		return changed
	# If DD's enlarge_ui changed, every category's effective scale changes.
	var dd_cur = _dd_enlarge_ui()
	if abs(dd_cur - _last_applied_dd_scale) > 0.0001:
		for c in CATEGORIES:
			changed[c.id] = true
		return changed
	# Per-category comparison
	for c in CATEGORIES:
		var old_v = _last_applied_multipliers.get(c.id, -1.0)
		var cur_v = _multipliers.get(c.id, 1.0)
		if abs(old_v - cur_v) > 0.0001:
			changed[c.id] = true
	return changed


func _record_applied_state() -> void:
	_last_applied_multipliers.clear()
	for c in CATEGORIES:
		_last_applied_multipliers[c.id] = _multipliers.get(c.id, 1.0)
	_last_applied_dd_scale = _dd_enlarge_ui()
	# Publish our Asset Thumbnails effective scale as a meta on _g.World,
	# so other mods (notably prefabs_thumbnails.gd, which rebuilds the
	# PrefabTool itemList on every mode/set change) can read it and stay
	# in sync. They poll the meta on a short timer.
	if _g != null and _g.World != null and is_instance_valid(_g.World):
		_g.World.set_meta("uir_asset_thumb_scale",
			_effective_scale("asset_thumbnails"))
		# Also publish the General Scale meta — used by grid_ruler and
		# any other overlay that needs a single "current UI scale" value.
		_g.World.set_meta("uir_general_scale",
			_effective_scale(MASTER_ID))


# True if every category's effective scale (dd_enlarge_ui × multiplier)
# is exactly 1.0 — meaning the apply would be a visual no-op.
func _all_effective_scales_are_one() -> bool:
	for c in CATEGORIES:
		if abs(_effective_scale(c.id) - 1.0) > 0.0001:
			return false
	return true


func _apply_all(incremental: bool) -> void:
	if _g == null or _g.World == null:
		return
	# Re-entrance guard: if a previous _apply_all is still mid-yield
	# (because some categories take multiple frames), mark a re-run
	# instead of overlapping. We'll re-apply once the current one completes.
	if _apply_in_progress:
		_apply_pending_rerun = true
		return
	_apply_in_progress = true
	var claims = _resolve_claims()
	# Compute which categories need re-applying.
	var first_apply : bool = _last_applied_multipliers.empty()
	var changed_cats : Dictionary = _compute_changed_categories()
	# Skip unchanged categories on user-initiated Apply (non-incremental),
	# EXCEPT on the very first apply (when no baseline state exists yet
	# and everything must be processed).
	var skip_unchanged : bool = (not incremental) and (not first_apply)

	# Early exit: if every category's effective scale is exactly 1.0,
	# the apply is a visual no-op — we'd just be setting every property
	# to its native value. Still triggers theme_changed cascades on
	# every touched node though, so skipping saves real work (and the
	# busy popup). Common at startup when the user hasn't changed any
	# slider yet and DD's Enlarge UI is also at 1.0.
	if first_apply and _all_effective_scales_are_one():
		print("[UIRescaler] first apply: all scales at 1.0, skipping work")
		_record_applied_state()
		_apply_in_progress = false
		return
	# Count nodes that will actually be processed, so we can show a busy
	# popup only if the apply is going to span multiple frames.
	var work_count : int = 0
	if skip_unchanged:
		for key in claims:
			var info = claims[key]
			if changed_cats.has(info.cat_id):
				work_count += 1
	else:
		work_count = claims.size()
	var show_busy : bool = work_count > APPLY_BATCH_SIZE
	print("[UIRescaler] apply: work=", work_count,
		" first=", first_apply, " skip_unchanged=", skip_unchanged,
		" show_busy=", show_busy)
	if show_busy:
		_show_busy("Applying UI scale… 0%")
	# Track ToolsetButtons so we can re-finalize them after all labels
	# (which are walked as children) have had their fonts scaled.
	var toolset_buttons : Array = []
	var processed_count : int = 0
	for key in claims:
		var info = claims[key]
		var node = info.node
		if not is_instance_valid(node):
			continue
		# Skip our own UI (the busy popup and friends) — they're tagged
		# with `_uir_skip` and must never be touched by the scaler.
		if node.has_meta("_uir_skip"):
			continue
		# Re-baseline if previous capture was made before properties were ready
		if _baselines.has(key) and _is_baseline_stale(node, _baselines[key]):
			_baselines.erase(key)
		# Skip if this category's multiplier didn't change since last apply
		# AND we already have a baseline for the node (meaning it was
		# already scaled correctly). First-ever encounter still applies.
		if skip_unchanged and _baselines.has(key) \
				and not changed_cats.has(info.cat_id):
			continue
		# Incremental: skip already-baselined nodes EXCEPT Buttons.
		# DD's ToolsetButton/ToolbarButton scripts reset .icon and
		# rect_min_size on hover/toggle/state change. We must re-apply
		# every rescan to keep the scaled icon installed.
		if incremental and _baselines.has(key) and not (node is Button):
			continue
		var scale = _effective_scale(info.cat_id)
		_apply_to_node(node, scale)
		# Remember ToolsetButtons for the deferred re-finalize pass
		if _baselines.has(key) and _baselines[key].get("is_toolset_button", false):
			toolset_buttons.append({"node": node, "scale": scale})
		processed_count += 1
		# Yield every BATCH_SIZE nodes so the engine can drain its event
		# queue (theme_changed / minimum_size_changed cascades). Critical
		# for compatibility with mods that add many UI elements to tool
		# panels (e.g. ColourThings), which would otherwise overflow the
		# 8 MB message queue.
		if processed_count % APPLY_BATCH_SIZE == 0:
			if show_busy and work_count > 0:
				var pct = int(100.0 * processed_count / float(work_count))
				_show_busy("Applying UI scale… " + str(pct) + "%")
			yield(_g.World.get_tree(), "idle_frame")

	# Track whether the main pass actually batched (and thus yielded).
	# If not, we can skip the post-main yields too — the message queue
	# isn't under any pressure.
	var did_yield_in_main : bool = processed_count >= APPLY_BATCH_SIZE

	# Deferred pass: now that ALL nodes (including label children) have
	# been scaled, re-call SetLabelOffset on each ToolsetButton so DD's
	# hover-width calculation sees the up-to-date label.minimum_size.
	for entry in toolset_buttons:
		var n = entry.node
		if not is_instance_valid(n):
			continue
		var b = _baselines.get(n.get_instance_id())
		if b == null:
			continue
		if b.has("label_offset_base") and n.has_method("SetLabelOffset"):
			n.SetLabelOffset(b.label_offset_base * entry.scale)

	# Flush dirty fonts: call update_changes() once per unique font.
	# This notifies all dependents that font dimensions changed and they
	# should re-measure. Yield first ONLY if we yielded during main pass
	# (i.e. the message queue might be filling up); otherwise the queue
	# is empty and an extra yield is wasted time.
	if did_yield_in_main:
		yield(_g.World.get_tree(), "idle_frame")
	for fid in _dirty_fonts:
		var f = _dirty_fonts[fid]
		if f != null and is_instance_valid(f):
			f.update_changes()
	_dirty_fonts.clear()

	# Extra-pass categories (asset_thumbnails, etc.). They don't go through
	# the claim system — their nodes are already claimed by their region's
	# main category for font/min_size. Here we apply ONLY the thumbnail-
	# specific properties (ItemList icon_scale + fixed_icon_size).
	if did_yield_in_main:
		yield(_g.World.get_tree(), "idle_frame")
	print("[UIRescaler] main pass done, starting extra pass")
	if show_busy:
		_show_busy("Applying thumbnails…")
	for cat in CATEGORIES:
		if not cat.get("extra_pass", false):
			continue
		# Skip extra-pass categories whose multiplier hasn't changed.
		if skip_unchanged and not changed_cats.has(cat.id):
			continue
		var scale = _effective_scale(cat.id)
		print("[UIRescaler] extra pass: ", cat.id, " scale=", scale)
		_apply_extra_pass(cat, scale)
	print("[UIRescaler] extra pass complete, recording state")

	# Remember what we just applied, so the next call can diff against it.
	_record_applied_state()

	print("[UIRescaler] hiding busy popup")
	_hide_busy()  # always hide, even if show_busy was false (safety)

	_apply_in_progress = false
	print("[UIRescaler] apply finished")
	# If the Preferences popup is currently open, trigger a resize NOW
	# (after the apply has finished and all sizes are stable). This is
	# the reliable spot to do it — the call_deferred pattern from
	# _on_prefs_save_pressed can race with the apply and time out.
	_resize_prefs_if_open()
	# Honour a re-run requested while we were mid-apply.
	if _apply_pending_rerun:
		_apply_pending_rerun = false
		_apply_all(incremental)


# Called after every apply finishes. If the Preferences popup is visible,
# fits its size to the (now stable) content. No-op otherwise.
func _resize_prefs_if_open() -> void:
	if _g == null or _g.Editor == null:
		return
	var prefs = _g.Editor.get_node_or_null("Windows/Preferences")
	if prefs == null or not prefs.visible:
		return
	# Defer one frame so the post-apply layout has fully settled.
	call_deferred("_force_resize_prefs")


func _apply_extra_pass(cat: Dictionary, scale: float) -> void:
	# Collect target nodes from this category's rules.
	var targets : Array = []
	for rule in cat.rules:
		var recursive = rule.get("recursive", false)
		var type_filter = rule.get("type_filter", "")
		if rule.has("subtree_of_type"):
			# Find all subtrees of the given ancestor type (e.g. WindowDialog)
			# anywhere in the tree, then collect type_filter matches within.
			for root in _find_nodes_matching(rule.pattern):
				_find_subtrees_of_type_typed(
					root, rule.subtree_of_type, type_filter, targets)
		else:
			for root in _find_nodes_matching(rule.pattern):
				if recursive:
					_collect_subtree_typed(root, type_filter, targets)
				else:
					if type_filter == "" or root.is_class(type_filter):
						targets.append(root)
	# Deduplicate (overlapping rules can match the same ItemList twice).
	var seen : Dictionary = {}
	var unique_targets : Array = []
	for n in targets:
		if n == null or not is_instance_valid(n):
			continue
		var id = n.get_instance_id()
		if not seen.has(id):
			seen[id] = true
			unique_targets.append(n)
	# Apply ItemList-specific scaling per target.
	for node in unique_targets:
		if not (node is ItemList):
			continue
		var fis_native = _native_value(node, "fixed_icon_size", node.fixed_icon_size)
		var is_native = _native_value(node, "icon_scale", node.icon_scale)
		if fis_native is Vector2 and fis_native.x > 0:
			node.fixed_icon_size = Vector2(fis_native.x * scale, fis_native.y * scale)
		if typeof(is_native) in [TYPE_REAL, TYPE_INT] and is_native > 0:
			node.icon_scale = is_native * scale
		# Override ItemList's rect_min_size scaling by the thumbnails scale,
		# so the ItemList container grows in sync with its thumbnails
		# (keeps the sibling popup-opener buttons aligned via layout).
		var rm_native = _native_value(node, "rect_min_size", node.rect_min_size)
		if rm_native is Vector2:
			node.rect_min_size = Vector2(
				rm_native.x * scale if rm_native.x > 0 else 0,
				rm_native.y * scale if rm_native.y > 0 else 0)
		if node.has_method("update"):
			node.update()
		# Sibling popup-opener buttons (9-squares) get their min_size set
		# to match — though with sfv=1 their layout already follows the
		# ItemList's height via the parent HBoxContainer.
		_scale_thumbnail_sibling_buttons(node, scale)


func _scale_thumbnail_sibling_buttons(itemlist, scale: float) -> void:
	var parent = itemlist.get_parent()
	if parent == null:
		return
	for sibling in parent.get_children():
		if sibling == itemlist:
			continue
		if not (sibling is VBoxContainer):
			continue
		for btn in sibling.get_children():
			if not is_instance_valid(btn) or not (btn is Button):
				continue
			# Use native rect_min_size captured during main pass.
			var native = _native_value(btn, "rect_min_size", btn.rect_min_size)
			if not (native is Vector2):
				continue
			btn.rect_min_size = Vector2(
				native.x * scale if native.x > 0 else 0,
				native.y * scale if native.y > 0 else 0)


func _find_subtrees_of_type_typed(node, ancestor_type: String,
		item_type: String, out: Array) -> void:
	if node == null or not is_instance_valid(node):
		return
	if node is Control and node.is_class(ancestor_type):
		_collect_subtree_typed(node, item_type, out)
		return
	for c in node.get_children():
		_find_subtrees_of_type_typed(c, ancestor_type, item_type, out)


func _collect_subtree_typed(node, type_filter: String, out: Array) -> void:
	if node == null or not is_instance_valid(node):
		return
	if type_filter == "" or (node is Control and node.is_class(type_filter)):
		out.append(node)
	for c in node.get_children():
		_collect_subtree_typed(c, type_filter, out)


func _effective_scale(cat_id: String) -> float:
	# New model: Master is a "set all to X" control, not a multiplier.
	# Each category's effective scale is just its own value (times DD's
	# vanilla Enlarge UI). When the user moves the Master slider, all
	# category sliders are updated to match its value (see _on_slider_changed
	# below); from there, individual categories can be tweaked.
	var dd = _dd_enlarge_ui()
	if cat_id == MASTER_ID:
		return dd * float(_multipliers.get(MASTER_ID, 1.0))
	var cat = float(_multipliers.get(cat_id, 1.0))
	return dd * cat


# True if baseline was captured before the node's properties were ready.
func _is_baseline_stale(node, base) -> bool:
	# Disabled re-capture for Buttons — it was racing with the rescaler
	# itself (rect grows → stale check fires → re-capture → growth baseline → loop).
	# Other types: only trigger if first capture had explicitly null state.
	if node is TextureRect:
		if node.texture != null and node.texture.get_size().x > 0:
			if not base.has("tr_expand"):
				return true
	return false


# Returns the visible icon of a Button: only the explicit .icon property.
# We previously also tried get_icon("icon") as a theme fallback, but that
# returns Godot's default placeholder texture (id 543, 16x16) when no
# real icon is set — leading us to scale and install that placeholder
# on CheckBoxes etc. that don't actually use .icon.
func _get_button_icon(node):
	if not (node is Button):
		return null
	# Skip OptionButton: its visible icon lives in a child TextureRect
	# named "Icon", not in .icon. Scaling its .icon installs a phantom.
	if node is OptionButton:
		return null
	# Skip CheckBox/CheckButton: they render via theme styleboxes/icons,
	# not via .icon. Their indicator is handled via _apply_scalable_theme_icons.
	if node is CheckBox or node is CheckButton:
		return null
	if node.icon != null and node.icon.get_size().x > 0:
		return node.icon
	return null


func _is_sizable_leaf(node) -> bool:
	# Used by _is_baseline_stale to know when to re-capture if rect_size
	# was zero at first scan but is now populated. Kept narrow to avoid
	# locking unrelated controls (Labels, ColorRects, etc.) at their
	# first-rendered size.
	return node is Button or node is CheckButton or node is CheckBox \
		or node is HSlider or node is VSlider


# Capture baseline state.
func _capture_baseline(node) -> Dictionary:
	# Capture rect_min_size via meta so it survives mod reloads
	# (prevents compounding: 512 → 1024 → ... at each reload at scale 2).
	var b = {"min_size": _native_value(node, "rect_min_size", node.rect_min_size)}

	# Sliders/ScrollBars: ensure non-zero baseline on transverse axis
	if node is HSlider or node is HScrollBar:
		if b.min_size.y == 0:
			var nat_h = int(node.get_minimum_size().y)
			b.min_size = Vector2(b.min_size.x, max(nat_h, 16))
	if node is VSlider or node is VScrollBar:
		if b.min_size.x == 0:
			var nat_w = int(node.get_minimum_size().x)
			b.min_size = Vector2(max(nat_w, 16), b.min_size.y)

	# Toolset's internal Spacer (the node that creates the top gap): force
	# a small vanilla-sized gap independent of the user's scale.
	if node.name == "Spacer":
		var sp_parent = node.get_parent()
		if sp_parent != null and sp_parent.get("buttonFullSize") != null:
			b["skip_min_size"] = true

	# Label children of ToolsetButton: skip font scaling (keep native size)
	# and center vertically. Scaling them like scaling_api does breaks
	# layout in our case because we use per-node overrides instead of a
	# global theme scale.
	if node is Label:
		var label_parent = node.get_parent()
		if label_parent != null and label_parent.has_method("SetLabelOffset"):
			b["skip_font_scaling"] = true
			b["center_vertically"] = true

	# Toolset node (the left category bar): capture buttonFullSize and
	# buttonShrunkSize so DD's natural toggle (full ↔ shrunk on tool
	# open/close) uses scaled values. Store NATIVE size via meta so
	# we survive mod reload without compounding.
	if node.get("buttonFullSize") != null and node.get("buttonShrunkSize") != null:
		b["toolset_full_size"] = _native_value(node, "full_size", node.get("buttonFullSize"))
		b["toolset_shrunk_size"] = _native_value(node, "shrunk_size", node.get("buttonShrunkSize"))

	# ToolsetButton (child of Toolset): re-enable rect_min_size scaling
	# (like ui_scaler_builtin / scaling_api.gd). It uses Vector2(0, 48)
	# as the native baseline — x=0 leaves the button free to expand at
	# hover for the label. Using node.rect_min_size (which is 64×48)
	# would lock x to 83 at scale 1.3 and prevent label-hover expansion.
	var parent = node.get_parent()
	if parent != null and parent.get("buttonFullSize") != null:
		b["is_toolset_button"] = true
		if node.has_method("SetLabelOffset"):
			b["label_offset_base"] = 48
		# scaling_api.gd uses Vector2(0, 48) — leave x=0 so DD can expand
		# the button at hover. Y is the icon's natural height (48).
		b["toolset_btn_min_size"] = Vector2(0, 48)

	# Buttons: capture only the visible icon for ScalableImageTexture
	# scaling. We DO NOT override rect_min_size here — DD's ToolbarButton
	# and ToolsetButton scripts dynamically resize themselves when text
	# is hidden (selected state). Locking rect_min_size keeps the button
	# at its largest-ever size, leaving phantom whitespace and preventing
	# the Toolset from shrinking when a tool is active.
	# get_minimum_size() naturally follows the scaled icon + current text,
	# so the layout grows with scale without us locking anything.
	if node is Button:
		var btn_icon = _get_button_icon(node)
		if btn_icon != null and btn_icon.get_size().x > 0:
			b["button_icon"] = {"tex": btn_icon, "size": btn_icon.get_size()}
		# Capture hseparation (spacing between icon and text) so it scales
		# with the icon. Without this, big icons sit flush against the text.
		if node.has_constant("hseparation"):
			b["hseparation"] = _native_value(node, "hseparation", node.get_constant("hseparation"))
		# Capture stylebox content margins so the icon has proper padding
		# inside the button at any scale (otherwise the icon sits flush
		# against the button border at higher scales).
		# CRITICAL: store native values via meta on the stylebox itself
		# (which is a Resource — meta persists across mod reloads).
		b["button_styleboxes"] = {}
		for sb_name in ["normal", "pressed", "hover", "disabled", "focus"]:
			var sb = node.get_stylebox(sb_name)
			if sb != null:
				b.button_styleboxes[sb_name] = {
					"l": _native_value(sb, sb_name + "_cml", sb.content_margin_left),
					"t": _native_value(sb, sb_name + "_cmt", sb.content_margin_top),
					"r": _native_value(sb, sb_name + "_cmr", sb.content_margin_right),
					"b": _native_value(sb, sb_name + "_cmb", sb.content_margin_bottom),
				}
		# DELIBERATELY skip min_size capture for Buttons — leave it at
		# baseline (often 0,0 which lets DD's get_minimum_size drive layout).

	# TextureRect: capture texture natural size + the texture itself
	# for ScalableImageTexture-style scaling. With only rect_min_size
	# scaling + expand=true, the texture stays at native resolution
	# and gets upscaled by the renderer (blurry / small visible icon).
	if node is TextureRect and node.texture != null:
		var tsz = node.texture.get_size()
		if tsz.x > 0 and tsz.y > 0:
			b["tr_expand"] = node.expand
			b["tr_stretch_mode"] = node.stretch_mode
			b["tr_texture"] = {"tex": node.texture, "size": tsz}
			if b.min_size.x == 0:
				b.min_size = Vector2(tsz.x, b.min_size.y)
			if b.min_size.y == 0:
				b.min_size = Vector2(b.min_size.x, tsz.y)

	# (Button rect_size handling above already covers child-icon cases.)

	# Popup containers
	if node is Popup or node is WindowDialog:
		b["rect_size"] = _native_value(node, "rect_size", node.rect_size)

	if node is ItemList:
		b["fixed_icon_size"] = _native_value(node, "fixed_icon_size", node.fixed_icon_size)
		b["icon_scale"] = _native_value(node, "icon_scale", node.icon_scale)

	if node is HBoxContainer or node is VBoxContainer:
		b["separation"] = _native_value(node, "separation", node.get_constant("separation"))

	if node is MarginContainer:
		for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
			b[m] = _native_value(node, m, node.get_constant(m))

	if node is HSplitContainer or node is VSplitContainer:
		b["split_offset"] = _native_value(node, "split_offset", node.split_offset)

	# OptionButton dropdown arrow (theme icon "arrow")
	if node is OptionButton:
		var arrow = node.get_icon("arrow")
		if arrow != null and arrow.get_size().x > 0:
			# Check it's not the placeholder fallback
			var fake = node.get_icon("___not_a_real_slot___")
			if fake == null or fake.get_instance_id() != arrow.get_instance_id():
				b["option_arrow"] = {"tex": arrow, "size": arrow.get_size()}

	# PopupMenu: checkbox indicators in the dropdown items
	if node is PopupMenu:
		b["popup_icons"] = {}
		for nm in ["checked", "unchecked", "radio_checked", "radio_unchecked", "submenu"]:
			var tex = node.get_icon(nm)
			if tex != null and tex.get_size().x > 0:
				var fake = node.get_icon("___not_a_real_slot___")
				if fake == null or fake.get_instance_id() != tex.get_instance_id():
					b.popup_icons[nm] = {"tex": tex, "size": tex.get_size()}

	# CheckButton/CheckBox indicator textures.
	# Slot names differ: CheckButton uses "on"/"off" while CheckBox uses
	# "checked"/"unchecked"/"radio_*". Querying wrong slots returns a
	# placeholder (Godot's missing-icon default) — useless to scale.
	if node is CheckButton or node is CheckBox:
		b["check_icons"] = {}
		var slot_names = []
		if node is CheckButton:
			slot_names = ["on", "off", "on_disabled", "off_disabled",
				"hover", "hover_pressed"]
		else:  # CheckBox
			slot_names = ["checked", "unchecked",
				"checked_disabled", "unchecked_disabled",
				"radio_checked", "radio_unchecked",
				"radio_checked_disabled", "radio_unchecked_disabled",
				"hover", "hover_pressed"]
		for nm in slot_names:
			var tex = node.get_icon(nm)
			# Filter the placeholder fallback (always 16x16, instance id
			# shared across all "missing" slots). Heuristic: skip if the
			# returned texture is shared across multiple slot names —
			# but it's simpler to just skip 16x16 ImageTextures that we
			# suspect are placeholders. Real DD check icons are larger.
			if tex != null and tex.get_size().x >= 16:
				# Quick placeholder detection: if get_icon("foobar_invalid")
				# returns the same instance, it's the placeholder.
				var fake = node.get_icon("___definitely_not_a_real_slot___")
				if fake != null and fake.get_instance_id() == tex.get_instance_id():
					continue  # placeholder
				b.check_icons[nm] = {"tex": tex, "size": tex.get_size()}

	# Slider grabber + groove
	if node is HSlider or node is VSlider:
		b["slider_icons"] = {}
		for nm in ["grabber", "grabber_highlight", "grabber_disabled"]:
			var tex = node.get_icon(nm)
			if tex != null and tex.get_size().x > 0:
				b.slider_icons[nm] = {"tex": tex, "size": tex.get_size()}
		# Capture stylebox expand margins for groove thickness, with meta
		# survival on the stylebox itself.
		b["slider_stylebox"] = {}
		for nm in ["slider", "grabber_area", "grabber_area_highlight"]:
			var sb = node.get_stylebox(nm)
			if sb != null:
				b.slider_stylebox[nm] = {
					"e_top": _native_value(sb, nm + "_emt", sb.expand_margin_top),
					"e_bot": _native_value(sb, nm + "_emb", sb.expand_margin_bottom),
					"e_left": _native_value(sb, nm + "_eml", sb.expand_margin_left),
					"e_right": _native_value(sb, nm + "_emr", sb.expand_margin_right),
				}

	return b


func _apply_to_node(node, scale: float) -> void:
	if not (node is Control):
		return
	var key = node.get_instance_id()
	if not _baselines.has(key):
		_baselines[key] = _capture_baseline(node)
	var base = _baselines[key]

	# Note: at scale=1.0, _scale_font_slot mutates existing overrides to
	# native size in place (rather than removing) — that's the most
	# reliable way to propagate the change to DD's C# rendering.

	# rect_min_size — preserve zero axes
	# For ToolsetButton, use the captured native size via meta.
	# For Toolset's Spacer, force a small vanilla-sized gap.
	if base.get("skip_min_size", false):
		# Spacer case: force a small vanilla-sized gap (scaled).
		node.rect_min_size = Vector2(0, 16.0 * scale)
	elif base.get("is_toolset_button", false) and base.has("toolset_btn_min_size"):
		var btn_native : Vector2 = base.toolset_btn_min_size
		node.rect_min_size = Vector2(
			btn_native.x * scale if btn_native.x > 0 else 0,
			btn_native.y * scale if btn_native.y > 0 else 0)
	else:
		var ms : Vector2 = base.get("min_size", Vector2())
		node.rect_min_size = Vector2(
			ms.x * scale if ms.x > 0 else 0,
			ms.y * scale if ms.y > 0 else 0)

	# Toolset properties: scale buttonFullSize / buttonShrunkSize.
	# Also set rect_min_size to (current button size, 0) — exactly like
	# scaling_api.gd's ToolsetScaler. Y MUST be 0; preserving a non-zero
	# y would prevent the Toolset from filling its parent vertically and
	# create a visible gap above the icons.
	if base.has("toolset_full_size"):
		node.set("buttonFullSize", base.toolset_full_size * scale)
	if base.has("toolset_shrunk_size"):
		node.set("buttonShrunkSize", base.toolset_shrunk_size * scale)
		# Match scaling_api line 646-648: rect_min_size depends on IsShrunk.
		if node.get("IsShrunk") != null and node.get("IsShrunk"):
			node.rect_min_size = Vector2(node.get("buttonShrunkSize"), 0)
		else:
			node.rect_min_size = Vector2(node.get("buttonFullSize"), 0)

	# Popup: also scale rect_size
	if (node is Popup or node is WindowDialog) and base.has("rect_size"):
		var rs : Vector2 = base.rect_size
		if rs.x > 0 and rs.y > 0:
			node.rect_size = Vector2(rs.x * scale, rs.y * scale)

	# ItemList icons (fixed_icon_size + icon_scale): handled by the
	# asset_thumbnails extra-pass, NOT here. Keeping it out of the main
	# pass means the ItemList still gets font/min_size scaling from its
	# region's claim category, while its thumbnails scale with their own
	# independent slider.

	# Container spacing / margins
	if (node is HBoxContainer or node is VBoxContainer) and base.has("separation"):
		node.add_constant_override("separation",
			int(round(base.separation * scale)))
	if node is MarginContainer:
		for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
			if base.has(m):
				node.add_constant_override(m, int(round(base[m] * scale)))

	# Split offset
	if (node is HSplitContainer or node is VSplitContainer) and base.has("split_offset"):
		node.split_offset = int(round(base.split_offset * scale))

	# Button icon: install/update a ScalableImageTexture that mutates
	# its content in-place. This is the only approach that survives
	# DD's ToolbarButton.cs custom rendering (working as verified in
	# ui_scaler_builtin.gd which uses the same technique).
	if node is Button and base.has("button_icon"):
		_apply_scalable_button_icon(node, base.button_icon, scale)

	# Button icon-to-text spacing — scale the theme constant so big icons
	# don't sit flush against the text.
	if node is Button and base.has("hseparation"):
		node.add_constant_override("hseparation",
			int(round(base.hseparation * scale)))

	# Button stylebox content margins — scale internal padding so the
	# icon doesn't sit flush against the button border at high scales.
	if node is Button and base.has("button_styleboxes"):
		for sb_name in base.button_styleboxes.keys():
			var orig = base.button_styleboxes[sb_name]
			var src = node.get_stylebox(sb_name)
			if src == null:
				continue
			var sb
			if node.has_stylebox_override(sb_name):
				sb = node.get_stylebox(sb_name)
			else:
				sb = src.duplicate()
				node.add_stylebox_override(sb_name, sb)
			sb.content_margin_left = orig.l * scale
			sb.content_margin_top = orig.t * scale
			sb.content_margin_right = orig.r * scale
			sb.content_margin_bottom = orig.b * scale

	# TextureRect texture: scale physically (vs just min_size)
	if node is TextureRect and base.has("tr_texture"):
		_apply_scalable_property_icon(node, "texture", base.tr_texture, scale)
	# TextureRect expand — only force when we captured a real texture
	if node is TextureRect and base.has("tr_expand"):
		if abs(scale - 1.0) < 0.001:
			node.expand = base.tr_expand
		else:
			node.expand = true

	# OptionButton dropdown arrow
	if node is OptionButton and base.has("option_arrow"):
		_apply_scalable_theme_icons(node, {"arrow": base.option_arrow}, scale)

	# PopupMenu indicators (checked/unchecked/radio_*)
	if node is PopupMenu and base.has("popup_icons"):
		_apply_scalable_theme_icons(node, base.popup_icons, scale)

	# CheckButton/CheckBox indicator: use the ScalableImageTexture approach
	# (same as ToolbarButton icons) — it survives DD's custom rendering
	# better than texture-replacement.
	if (node is CheckButton or node is CheckBox) and base.has("check_icons"):
		_apply_scalable_theme_icons(node, base.check_icons, scale)

	# Slider grabber + groove
	if node is HSlider or node is VSlider:
		if base.has("slider_icons"):
			_apply_scalable_theme_icons(node, base.slider_icons, scale)
		if base.has("slider_stylebox"):
			_scale_slider_styleboxes(node, base.slider_stylebox, scale)

	# Vertical centering for ToolsetButton hover labels — we position the
	# label vertically centered inside its button parent. The anchors
	# approach didn't work (DD overrides them), so we go direct: set
	# rect_position.y manually, and connect to the button's "resized"
	# signal so the label is re-centered whenever the button size changes
	# (notably on hover, when DD expands the button).
	if base.get("center_vertically", false) and node is Label:
		node.valign = Label.VALIGN_CENTER
		var parent_btn = node.get_parent()
		if parent_btn != null and parent_btn is Control:
			_recenter_toolset_label(parent_btn)
			# Connect once
			if not parent_btn.is_connected("resized", self, "_on_toolset_btn_resized"):
				parent_btn.connect("resized", self, "_on_toolset_btn_resized", [parent_btn])

	# Font (multi-slot). ToolsetButton hover labels are kept at native
	# size (skip_font_scaling=true), forcing scale=1.0 for their fonts.
	if _is_text_node(node):
		var fscale = scale
		if base.get("skip_font_scaling", false):
			fscale = 1.0
		for slot in FONT_SLOTS:
			_scale_font_slot(node, slot, fscale)

	# ToolsetButton label offset (fixed default × scale, like ui_scaler_builtin)
	# Done LAST, after font scaling, so DD's hover-width calculation
	# sees the up-to-date label.minimum_size after we changed the font.
	if base.has("label_offset_base") and node.has_method("SetLabelOffset"):
		node.SetLabelOffset(base.label_offset_base * scale)
		# Also poke the label so its cached minimum size is invalidated
		if node.get("label") != null and node.label.has_method("minimum_size_changed"):
			node.label.minimum_size_changed()


# Build a scaled ImageTexture from the original button icon and install
# it as an "icon" override. At scale=1.0 we still install the original
# (a no-op override is fine — keeps logic uniform). Uses _tex_cache to
# avoid regenerating textures across nodes that share the same source.
# Install a scaled icon by REPLACING node.icon directly. Button uses
# node.icon property, not add_icon_override("icon"), so the override
# approach was silently ignored on buttons that had .icon set.
#
# At scale=1.0, restore the original. Original texture is preserved in
# the baseline (entry.tex), so we can restore on demand.
# Apply a scaled icon by installing/reusing a ScalableImageTexture
# (a subclass of ImageTexture that holds the source Image and can be
# rescaled in-place). Critical: the SAME texture instance is reused
# across scale changes — DD's ToolbarButton.cs apparently caches some
# state related to icon identity, so swapping textures doesn't trigger
# its redraw. Re-assigning the same instance + calling update() does.
# Apply scaled theme icons (CheckButton on/off, Slider grabber, etc.)
# using the same persistent-texture trick as buttons: one texture
# instance per slot, mutated in-place + re-installed + update().
func _apply_scalable_theme_icons(node, icons_dict: Dictionary, scale: float) -> void:
	var key_base = node.get_instance_id()
	for name in icons_dict.keys():
		var entry = icons_dict[name]
		var orig_tex = entry.tex
		if orig_tex == null or not is_instance_valid(orig_tex):
			continue
		var slot_key = "%d:%s" % [key_base, name]
		var sit = _scalable_icons.get(slot_key)
		if sit == null:
			# Reload-safe: detect existing scaled override via meta
			var existing = null
			if node.has_icon_override(name):
				var ov = node.get_icon(name)
				if ov != null and ov.has_meta("_uir_native_size"):
					existing = ov
			if existing != null:
				sit = {
					"tex": existing,
					"default_size": existing.get_meta("_uir_native_size"),
				}
			else:
				var src_tex = orig_tex
				if src_tex is AtlasTexture:
					src_tex = src_tex.atlas
					if src_tex == null:
						continue
				var src_img = src_tex.get_data()
				if src_img == null:
					continue
				if src_img.is_compressed():
					if src_img.decompress() != OK:
						continue
				if src_img.get_width() <= 0 or src_img.get_height() <= 0:
					continue
				var tex = ImageTexture.new()
				tex.create_from_image(src_img)
				tex.set_meta("_uir_native_size", entry.size)
				sit = {
					"tex": tex,
					"default_size": entry.size,
				}
			_scalable_icons[slot_key] = sit
		var ds = sit.default_size
		sit.tex.set_size_override(Vector2(ds.x * scale, ds.y * scale))
		node.add_icon_override(name, sit.tex)
	if node.has_method("update"):
		node.update()
	if node.has_method("minimum_size_changed"):
		node.minimum_size_changed()


# Same persistent-texture trick but for an arbitrary property name
# (e.g. TextureRect.texture). Mutates the texture in-place so the node
# sees a "same" texture instance with a new internal size.
func _apply_scalable_property_icon(node, property: String, entry: Dictionary, scale: float) -> void:
	var orig_tex = entry.tex
	if orig_tex == null or not is_instance_valid(orig_tex):
		return
	var key = "%d:%s" % [node.get_instance_id(), property]
	var sit = _scalable_icons.get(key)
	if sit == null:
		var current = node.get(property)
		if current != null and current.has_meta("_uir_native_size"):
			sit = {
				"tex": current,
				"default_size": current.get_meta("_uir_native_size"),
			}
			_scalable_icons[key] = sit
		else:
			var src_tex = orig_tex
			if src_tex is AtlasTexture:
				src_tex = src_tex.atlas
				if src_tex == null:
					return
			var src_img = src_tex.get_data()
			if src_img == null:
				return
			if src_img.is_compressed():
				if src_img.decompress() != OK:
					return
			if src_img.get_width() <= 0 or src_img.get_height() <= 0:
				return
			var tex = ImageTexture.new()
			tex.create_from_image(src_img)
			tex.set_meta("_uir_native_size", entry.size)
			sit = {
				"tex": tex,
				"default_size": entry.size,
			}
			_scalable_icons[key] = sit
	var ds = sit.default_size
	sit.tex.set_size_override(Vector2(ds.x * scale, ds.y * scale))
	node.set(property, sit.tex)
	if node.has_method("update"):
		node.update()
	if node.has_method("minimum_size_changed"):
		node.minimum_size_changed()


func _apply_scalable_button_icon(node, entry: Dictionary, scale: float) -> void:
	var orig_tex = entry.tex
	if orig_tex == null or not is_instance_valid(orig_tex):
		return
	var key = node.get_instance_id()
	var sit = _scalable_icons.get(key)
	if sit == null:
		# Check meta survival across reload
		var current_icon = node.icon
		if current_icon != null and current_icon.has_meta("_uir_native_size"):
			sit = {
				"tex": current_icon,
				"default_size": current_icon.get_meta("_uir_native_size"),
			}
			_scalable_icons[key] = sit
		else:
			var src_tex = orig_tex
			if src_tex is AtlasTexture:
				src_tex = src_tex.atlas
				if src_tex == null:
					return
			var src_img = src_tex.get_data()
			if src_img == null:
				return
			if src_img.is_compressed():
				if src_img.decompress() != OK:
					return
			if src_img.get_width() <= 0 or src_img.get_height() <= 0:
				return
			# Create texture from NATIVE-size image. We never resize the
			# underlying image; set_size_override controls reported size,
			# matching the ScalableImageTexture behavior of scaling_api.gd.
			var tex = ImageTexture.new()
			tex.create_from_image(src_img)
			tex.set_meta("_uir_native_size", entry.size)
			sit = {
				"tex": tex,
				"default_size": entry.size,
			}
			_scalable_icons[key] = sit
	# Set the displayed size via override (no image resize).
	# This emits the "changed" signal that DD's C# button code listens for.
	var ds = sit.default_size
	sit.tex.set_size_override(Vector2(ds.x * scale, ds.y * scale))
	node.icon = sit.tex
	if node.has_method("update"):
		node.update()
	if node.has_method("minimum_size_changed"):
		node.minimum_size_changed()


# Keep old name as alias in case anything external references it.
func _apply_button_icon(node, entry: Dictionary, scale: float) -> void:
	var orig_tex = entry.tex
	if orig_tex == null or not is_instance_valid(orig_tex):
		return
	var orig_size = entry.size
	var w = int(max(1, round(orig_size.x * scale)))
	var h = int(max(1, round(orig_size.y * scale)))
	var cache_key = "%d:%d:%d" % [orig_tex.get_instance_id(), w, h]
	var scaled = _tex_cache.get(cache_key)
	if scaled == null:
		if abs(scale - 1.0) < 0.001:
			# Reuse the original texture directly at scale 1.0
			scaled = orig_tex
		else:
			var img = orig_tex.get_data()
			if img == null:
				return
			img = img.duplicate()
			img.resize(w, h, Image.INTERPOLATE_BILINEAR)
			scaled = ImageTexture.new()
			scaled.create_from_image(img, orig_tex.flags)
		_tex_cache[cache_key] = scaled
	node.add_icon_override("icon", scaled)


func _scale_theme_icons(node, icons_dict: Dictionary, scale: float) -> void:
	for name in icons_dict.keys():
		var entry = icons_dict[name]
		var orig_tex = entry.tex
		if orig_tex == null or not is_instance_valid(orig_tex):
			continue
		var orig_size = entry.size
		var w = int(max(1, round(orig_size.x * scale)))
		var h = int(max(1, round(orig_size.y * scale)))
		var cache_key = "%d:%d:%d" % [orig_tex.get_instance_id(), w, h]
		var scaled = _tex_cache.get(cache_key)
		if scaled == null:
			var img = orig_tex.get_data()
			if img == null:
				continue
			img = img.duplicate()
			img.resize(w, h, Image.INTERPOLATE_BILINEAR)
			scaled = ImageTexture.new()
			scaled.create_from_image(img, orig_tex.flags)
			_tex_cache[cache_key] = scaled
		node.add_icon_override(name, scaled)


func _scale_slider_styleboxes(node, sb_baselines: Dictionary, scale: float) -> void:
	var extra = max(0.0, scale - 1.0) * 6.0
	for nm in sb_baselines.keys():
		var orig = sb_baselines[nm]
		var src = node.get_stylebox(nm)
		if src == null:
			continue
		var sb
		if node.has_stylebox_override(nm):
			sb = node.get_stylebox(nm)
		else:
			sb = src.duplicate()
			node.add_stylebox_override(nm, sb)
		if node is HSlider:
			sb.expand_margin_top = orig.e_top + extra
			sb.expand_margin_bottom = orig.e_bot + extra
			sb.expand_margin_left = orig.e_left
			sb.expand_margin_right = orig.e_right
		else:
			sb.expand_margin_left = orig.e_left + extra
			sb.expand_margin_right = orig.e_right + extra
			sb.expand_margin_top = orig.e_top
			sb.expand_margin_bottom = orig.e_bot


func _is_text_node(node) -> bool:
	for cls in TEXT_CLASSES:
		if node.is_class(cls):
			return true
	return false


# Scale one font override slot if the node has a DynamicFont in that slot.
# CRITICAL: stores the native size via set_meta on the font itself, so that
# on mod reload (where the override from a previous session persists), we
# read the true native size instead of treating the already-scaled size as
# baseline (which would cause compounding: 32 → 41 → 53 → 69 ...).
func _scale_font_slot(node, slot: String, scale: float) -> void:
	# Strategy: maintain a single override font per slot, never remove it.
	# Mutate its size in place to (native_size * scale). At scale=1.0,
	# this sets the override back to the native size (visually identical
	# to no override). This is way more robust than remove/re-add since
	# DD's C# code seems to cache override identity, and remove cycles
	# can fail to propagate properly.
	var ov = null
	if node.has_font_override(slot):
		ov = node.get_font(slot)

	# If no existing override, get the theme font to clone from.
	if ov == null:
		var theme_font = node.get_font(slot)
		if theme_font == null or not (theme_font is DynamicFont):
			return
		# Capture native size on theme_font via meta (survives reloads).
		var native_size : int
		if theme_font.has_meta("_uir_native_font_size"):
			native_size = theme_font.get_meta("_uir_native_font_size")
		else:
			native_size = theme_font.size
			theme_font.set_meta("_uir_native_font_size", native_size)
		# Don't create an override at scale 1.0 — no point.
		if abs(scale - 1.0) < 0.001:
			return
		ov = theme_font.duplicate()
		ov.set_meta("_uir_native_font_size", native_size)
		node.add_font_override(slot, ov)

	if not (ov is DynamicFont):
		return

	# Determine native size. Prefer meta on the override (set when we
	# created it). Fall back to theme font meta. Last resort: use current
	# size (but that's risky — could be already scaled).
	var native_size_2 : int
	if ov.has_meta("_uir_native_font_size"):
		native_size_2 = ov.get_meta("_uir_native_font_size")
	else:
		# Pre-existing override without meta (older mod version):
		# read theme font's meta if available, else snapshot now.
		var tf = node.get_font(slot)
		# Note: get_font with the override still installed returns the
		# OVERRIDE, not the theme. We need to peek under it.
		# Temporarily remove to read theme.
		node.remove_font_override(slot)
		tf = node.get_font(slot)
		node.add_font_override(slot, ov)
		if tf != null and tf.has_meta("_uir_native_font_size"):
			native_size_2 = tf.get_meta("_uir_native_font_size")
		elif tf != null and tf is DynamicFont:
			native_size_2 = tf.size
		else:
			native_size_2 = ov.size  # last resort
		ov.set_meta("_uir_native_font_size", native_size_2)

	# Mutate size in place. At scale=1.0 this resets to native.
	ov.size = int(max(1, round(native_size_2 * scale)))
	# Mark for batched update_changes() at end of _apply_all pass.
	_dirty_fonts[ov.get_instance_id()] = ov


# ── Settings tool panel ──────────────────────────────────────────────────

func _register_tool_panel() -> void:
	if not _g.Editor or not _g.Editor.Toolset:
		return
	var icon_path = _g.Root + "icons/ui_rescaler.png"
	var f = File.new()
	if not f.file_exists(icon_path):
		icon_path = _g.Root + "icons/overlay_button.png"
		if not f.file_exists(icon_path):
			icon_path = ""

	_tool_panel = _g.Editor.Toolset.CreateModTool(
		self, TOOL_CATEGORY, TOOL_ID, TOOL_NAME, icon_path)
	if _tool_panel == null:
		push_error("[UIRescaler] CreateModTool failed")
		return

	_setup_busy_popup()

	_tool_panel.BeginSection(false)
	_tool_panel.CreateNote("Per-category UI scale multipliers.\nApplied on top of DD's vanilla Enlarge UI.")
	_tool_panel.CreateSeparator()

	var master_label = Label.new()
	master_label.text = "General Scale"
	master_label.hint_tooltip = "Multiplies every category."
	_tool_panel.Align.add_child(master_label)
	_add_slider_row(MASTER_ID)
	# Reminder buttons row under General Scale (duplicates the bottom row)
	var top_btn_row = HBoxContainer.new()
	_apply_btn_top = Button.new()
	_apply_btn_top.text = "Apply"
	_apply_btn_top.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_apply_btn_top.connect("pressed", self, "_on_apply")
	_apply_btn_top.disabled = true
	_outline_button(_apply_btn_top)
	top_btn_row.add_child(_apply_btn_top)
	var top_reset_btn = Button.new()
	top_reset_btn.text = "Reset All"
	top_reset_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_reset_btn.hint_tooltip = "Reset every multiplier to 1.0 and apply."
	top_reset_btn.connect("pressed", self, "_on_reset_all")
	_outline_button(top_reset_btn)
	top_btn_row.add_child(top_reset_btn)
	_tool_panel.Align.add_child(top_btn_row)
	# Extra vertical space below the top button row (a little breathing
	# room before the per-category sliders begin)
	var spacer_top = Control.new()
	spacer_top.rect_min_size = Vector2(0, 8)
	_tool_panel.Align.add_child(spacer_top)
	_tool_panel.CreateSeparator()
	var spacer_below = Control.new()
	spacer_below.rect_min_size = Vector2(0, 8)
	_tool_panel.Align.add_child(spacer_below)

	# "Advanced" section header above the per-category sliders.
	var advanced_lbl = Label.new()
	advanced_lbl.text = "Advanced"
	advanced_lbl.align = Label.ALIGN_CENTER
	_tool_panel.Align.add_child(advanced_lbl)

	for c in CATEGORIES:
		var lbl = Label.new()
		lbl.text = c.label
		var tip = "Targets:"
		for r in c.rules:
			if r.has("subtree_of_type"):
				tip += "\n  " + r.pattern + " (find " + r.subtree_of_type + ")"
			else:
				tip += "\n  " + r.pattern
		lbl.hint_tooltip = tip
		_tool_panel.Align.add_child(lbl)
		_add_slider_row(c.id)

	_tool_panel.CreateSeparator()

	var btn_row = HBoxContainer.new()
	_apply_btn = Button.new()
	_apply_btn.text = "Apply"
	_apply_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_apply_btn.connect("pressed", self, "_on_apply")
	_apply_btn.disabled = true
	_outline_button(_apply_btn)
	btn_row.add_child(_apply_btn)

	var reset_btn = Button.new()
	reset_btn.text = "Reset All"
	reset_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reset_btn.hint_tooltip = "Reset every multiplier to 1.0 and apply."
	reset_btn.connect("pressed", self, "_on_reset_all")
	_outline_button(reset_btn)
	btn_row.add_child(reset_btn)
	_tool_panel.Align.add_child(btn_row)

	_status_lbl = Label.new()
	_status_lbl.align = Label.ALIGN_CENTER
	_status_lbl.modulate = Color(0.7, 0.7, 0.7, 1)
	_status_lbl.text = ""
	_tool_panel.Align.add_child(_status_lbl)

	_tool_panel.EndSection()


func _add_slider_row(id) -> void:
	var row = HBoxContainer.new()

	var slider = HSlider.new()
	slider.min_value = SLIDER_MIN
	slider.max_value = SLIDER_MAX
	slider.step = SLIDER_STEP
	slider.value = _multipliers.get(id, 1.0)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Center slider on its row vertically (otherwise it sits at the top
	# of an oversized HBoxContainer because the SpinBox + reset button
	# are taller).
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.connect("value_changed", self, "_on_slider_changed", [id])
	row.add_child(slider)
	_sliders[id] = slider

	var spin = SpinBox.new()
	spin.min_value = SLIDER_MIN
	spin.max_value = SLIDER_MAX
	spin.step = SLIDER_STEP
	spin.value = _multipliers.get(id, 1.0)
	spin.rect_min_size = Vector2(70, 0)
	spin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	spin.connect("value_changed", self, "_on_spin_changed", [id])
	row.add_child(spin)
	_spinboxes[id] = spin

	var reset = Button.new()
	var reset_icon = _load_mod_icon("icons/reset.png", 0.5)
	if reset_icon != null:
		reset.icon = reset_icon
	else:
		reset.text = "↺"  # fallback if icon file not found
	reset.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	reset.hint_tooltip = "Reset to 1.0"
	reset.connect("pressed", self, "_on_reset_one", [id])
	row.add_child(reset)

	_tool_panel.Align.add_child(row)


func _on_slider_changed(val, id) -> void:
	_pending[id] = val
	if _spinboxes.has(id) and is_instance_valid(_spinboxes[id]):
		_spinboxes[id].set_block_signals(true)
		_spinboxes[id].value = val
		_spinboxes[id].set_block_signals(false)
	# Master propagates: set every category's pending value to the master's.
	# Individual sliders can still be tweaked afterwards.
	if id == MASTER_ID:
		_propagate_master_to_categories(val)
	# Mirror to prefs row if this slider has a remote control.
	_mirror_to_prefs(id, val)
	_refresh_apply_state()


func _on_spin_changed(val, id) -> void:
	_pending[id] = val
	if _sliders.has(id) and is_instance_valid(_sliders[id]):
		_sliders[id].set_block_signals(true)
		_sliders[id].value = val
		_sliders[id].set_block_signals(false)
	if id == MASTER_ID:
		_propagate_master_to_categories(val)
	_mirror_to_prefs(id, val)
	_refresh_apply_state()


# Mirror a tool-side change to the Preferences-side slider/spinbox.
func _mirror_to_prefs(id, val) -> void:
	var slider = null
	var spin   = null
	if id == MASTER_ID:
		slider = _prefs_general_slider
		spin   = _prefs_general_spinbox
	elif id == "asset_thumbnails":
		slider = _prefs_thumbs_slider
		spin   = _prefs_thumbs_spinbox
	else:
		return
	if slider != null and is_instance_valid(slider):
		slider.set_block_signals(true)
		slider.value = val
		slider.set_block_signals(false)
	if spin != null and is_instance_valid(spin):
		spin.set_block_signals(true)
		spin.value = val
		spin.set_block_signals(false)


func _propagate_master_to_categories(val: float) -> void:
	for c in CATEGORIES:
		var cid = c.id
		_pending[cid] = val
		if _sliders.has(cid) and is_instance_valid(_sliders[cid]):
			_sliders[cid].set_block_signals(true)
			_sliders[cid].value = val
			_sliders[cid].set_block_signals(false)
		if _spinboxes.has(cid) and is_instance_valid(_spinboxes[cid]):
			_spinboxes[cid].set_block_signals(true)
			_spinboxes[cid].value = val
			_spinboxes[cid].set_block_signals(false)
		# Also mirror to the prefs Asset Thumbnails slider (the only
		# category beyond Master that has a prefs row).
		_mirror_to_prefs(cid, val)


func _on_reset_one(id) -> void:
	_pending[id] = 1.0
	if _sliders.has(id) and is_instance_valid(_sliders[id]):
		_sliders[id].set_block_signals(true)
		_sliders[id].value = 1.0
		_sliders[id].set_block_signals(false)
	if _spinboxes.has(id) and is_instance_valid(_spinboxes[id]):
		_spinboxes[id].set_block_signals(true)
		_spinboxes[id].value = 1.0
		_spinboxes[id].set_block_signals(false)
	_refresh_apply_state()


func _refresh_apply_state() -> void:
	var dirty = false
	for k in _pending:
		if abs(_pending[k] - _multipliers.get(k, 1.0)) > 0.001:
			dirty = true
			break
	if _apply_btn != null and is_instance_valid(_apply_btn):
		_apply_btn.disabled = not dirty
	if _apply_btn_top != null and is_instance_valid(_apply_btn_top):
		_apply_btn_top.disabled = not dirty
	if _status_lbl != null and is_instance_valid(_status_lbl):
		_status_lbl.text = "Unsaved changes" if dirty else ""


# Load an icon from disk. Tries multiple candidate paths derived from
# _g.Root so we don't print engine errors on a missing file. Pattern
# borrowed from light_tool_fix.gd; the file_exists() probe avoids the
# noisy "Error loading image" prints from Image.load() on missing files.
func _load_mod_icon(rel_path: String, scale: float = 1.0):
	var f = File.new()
	var candidates : Array = []
	if _g != null:
		var root = _g.Root
		if root != null:
			candidates.append(root + rel_path)
			candidates.append(root.rstrip("/") + "/" + rel_path)
	candidates.append("res://" + rel_path)
	var found = ""
	for p in candidates:
		if f.file_exists(p):
			found = p
			break
	if found == "":
		print("[UIRescaler] icon not found: ", rel_path,
			" (tried: ", candidates, ")")
		return null
	var image = Image.new()
	if image.load(found) != OK:
		return null
	if scale != 1.0:
		image.resize(int(image.get_width() * scale),
			int(image.get_height() * scale),
			Image.INTERPOLATE_LANCZOS)
	var tex = ImageTexture.new()
	tex.create_from_image(image)
	return tex


# Build the "busy" overlay shown during long _apply_all passes. We use a
# CanvasLayer with a fullscreen ColorRect (semi-transparent backdrop) and a
# centered Panel with status text. Everything tagged `_uir_skip` so the
# scaler never touches it. CanvasLayer guarantees rendering on top of all
# DD UI regardless of where we attach it.
#
# IMPORTANT: in Godot 3, CanvasLayer does NOT have a `visible` property
# (it's a Node, not a CanvasItem). To hide the overlay we must toggle
# visibility on the ColorRect child (or any CanvasItem descendant).
# `_busy_popup` stores the ColorRect; the parent CanvasLayer stays in the
# tree as the rendering context.
func _setup_busy_popup() -> void:
	if _g == null:
		return
	if is_instance_valid(_busy_popup):
		return  # already set up
	var root = _g.World.get_tree().root
	if root == null:
		return

	var layer = CanvasLayer.new()
	layer.name = "UIRescalerBusyLayer"
	layer.layer = 1000  # above DD UI
	layer.set_meta("_uir_skip", true)

	# Fullscreen dim + input blocker. This is the actual visibility toggle
	# target (CanvasLayer has no visible property in Godot 3).
	var bg = ColorRect.new()
	bg.name = "UIRescalerBusyBG"
	bg.set_meta("_uir_skip", true)
	bg.color = Color(0, 0, 0, 0.45)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	bg.visible = false
	layer.add_child(bg)

	# Centered panel
	var panel = PanelContainer.new()
	panel.set_meta("_uir_skip", true)
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.margin_left = -220
	panel.margin_top = -50
	panel.margin_right = 220
	panel.margin_bottom = 50
	# Solid dark background so the status text stays readable regardless
	# of what's behind it (the screen-dim ColorRect alone leaves the
	# panel translucent).
	var sb = StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.08, 0.10, 1.0)
	sb.border_width_left = 1
	sb.border_width_right = 1
	sb.border_width_top = 1
	sb.border_width_bottom = 1
	sb.border_color = Color(0.4, 0.4, 0.4, 1.0)
	sb.corner_radius_top_left = 4
	sb.corner_radius_top_right = 4
	sb.corner_radius_bottom_left = 4
	sb.corner_radius_bottom_right = 4
	panel.add_stylebox_override("panel", sb)
	bg.add_child(panel)

	var margin = MarginContainer.new()
	margin.set_meta("_uir_skip", true)
	margin.add_constant_override("margin_left", 24)
	margin.add_constant_override("margin_right", 24)
	margin.add_constant_override("margin_top", 18)
	margin.add_constant_override("margin_bottom", 18)
	panel.add_child(margin)

	var vbox = VBoxContainer.new()
	vbox.set_meta("_uir_skip", true)
	margin.add_child(vbox)

	var title = Label.new()
	title.set_meta("_uir_skip", true)
	title.text = "UI Rescaler"
	title.align = Label.ALIGN_CENTER
	vbox.add_child(title)

	_busy_label = Label.new()
	_busy_label.set_meta("_uir_skip", true)
	_busy_label.text = "Applying UI scale…"
	_busy_label.align = Label.ALIGN_CENTER
	vbox.add_child(_busy_label)

	root.add_child(layer)
	_busy_popup = bg  # toggle visibility on the ColorRect, not the layer
	print("[UIRescaler] Busy overlay ready")


func _show_busy(text: String) -> void:
	if not is_instance_valid(_busy_popup):
		return
	if is_instance_valid(_busy_label):
		_busy_label.text = text
	_busy_popup.visible = true


func _hide_busy() -> void:
	if is_instance_valid(_busy_popup):
		_busy_popup.visible = false


# ── Preferences > Interface tab integration ──────────────────────────────
#
# Inserts a "General Scale" and "Asset Thumbnails" slider into the
# Interface tab of DD's Preferences popup. They act as a remote control
# for the matching categories in our main tool: moving them updates the
# tool sliders (and vice versa). The "Apply" / "Save" button of
# Preferences applies the change just like our tool's Apply button does.
# Closing Preferences without saving reverts to the values that were
# active when the window was opened.

func _try_setup_prefs_sliders() -> void:
	if _g == null or _g.Editor == null:
		return
	var prefs = _g.Editor.get_node_or_null("Windows/Preferences")
	if prefs == null:
		return
	var interface_vbox = prefs.get_node_or_null("Margins/VAlign/Interface")
	if interface_vbox == null:
		# Diagnostic: dump what IS in prefs to help us find the right path
		print("[UIRescaler] prefs found but Margins/VAlign/Interface missing")
		print("[UIRescaler] prefs children: ")
		_dump_subtree(prefs, 0, 3)
		_prefs_setup_done = true  # stop retrying — log once
		return
	# Got it — build the UI once.
	_prefs_setup_done = true
	print("[UIRescaler] Building prefs sliders — interface_vbox=",
		interface_vbox, " children=", interface_vbox.get_child_count())
	_build_prefs_sliders(prefs, interface_vbox)


func _dump_subtree(node, depth: int, max_depth: int) -> void:
	if depth > max_depth or node == null:
		return
	var indent = ""
	for i in range(depth):
		indent += "  "
	print(indent, node.name, " [", node.get_class(), "]")
	for c in node.get_children():
		_dump_subtree(c, depth + 1, max_depth)


func _build_prefs_sliders(prefs, interface_vbox) -> void:
	_prefs_added_controls.clear()

	var sep = HSeparator.new()
	interface_vbox.add_child(sep)
	_prefs_added_controls.append(sep)

	_prefs_general_slider = HSlider.new()
	_prefs_general_spinbox = SpinBox.new()
	var general_row = _make_prefs_row(interface_vbox, "General Scale",
		_prefs_general_slider, _prefs_general_spinbox, MASTER_ID,
		_multipliers.get(MASTER_ID, 1.0))
	_prefs_added_controls.append(general_row)
	_prefs_general_slider.connect("value_changed", self,
		"_on_prefs_slider_changed", [MASTER_ID])
	_prefs_general_spinbox.connect("value_changed", self,
		"_on_prefs_spin_changed", [MASTER_ID])

	_prefs_thumbs_slider = HSlider.new()
	_prefs_thumbs_spinbox = SpinBox.new()
	var thumbs_row = _make_prefs_row(interface_vbox, "Asset Thumbnails",
		_prefs_thumbs_slider, _prefs_thumbs_spinbox, "asset_thumbnails",
		_multipliers.get("asset_thumbnails", 1.0))
	_prefs_added_controls.append(thumbs_row)
	_prefs_thumbs_slider.connect("value_changed", self,
		"_on_prefs_slider_changed", ["asset_thumbnails"])
	_prefs_thumbs_spinbox.connect("value_changed", self,
		"_on_prefs_spin_changed", ["asset_thumbnails"])

	# Note pointing to the tool for more options.
	var note = Label.new()
	note.text = "More scale options are available in the UI Rescaler tool (Settings tab)."
	note.autowrap = true
	# Godot 3 Labels with autowrap=true return their SINGLE-LINE min_size
	# on the first layout pass — that breaks our popup-resize measurement
	# at the first popup open after a restart. Reserving a 2-line minimum
	# guarantees we count the wrapped height correctly even on frame 1.
	note.rect_min_size = Vector2(0, 50)
	interface_vbox.add_child(note)
	_prefs_added_controls.append(note)

	# Hook DD's Save button to apply our pending values.
	var save_btn = prefs.get_node_or_null("Margins/VAlign/Buttons/SaveButton")
	if save_btn != null and not save_btn.is_connected(
			"pressed", self, "_on_prefs_save_pressed"):
		save_btn.connect("pressed", self, "_on_prefs_save_pressed")

	# Snapshot values on open, revert on close-without-save.
	if not prefs.is_connected("about_to_show", self, "_on_prefs_opened"):
		prefs.connect("about_to_show", self, "_on_prefs_opened")
	if prefs.has_signal("popup_hide") and not prefs.is_connected(
			"popup_hide", self, "_on_prefs_closed"):
		prefs.connect("popup_hide", self, "_on_prefs_closed")
	# When the user switches tabs inside Preferences, the Interface tab's
	# visibility flips. If it becomes visible AFTER the popup was opened
	# on another tab (e.g. General), the popup is still sized for that
	# tab's content. Re-resize whenever Interface becomes visible so our
	# rows fit and the Buttons row stays inside the popup.
	if not interface_vbox.is_connected(
			"visibility_changed", self, "_on_interface_tab_visibility"):
		interface_vbox.connect("visibility_changed", self,
			"_on_interface_tab_visibility")

	# Inject a Node into Preferences whose _unhandled_key_input forwards
	# Ctrl+Z / Ctrl+Y to our internal undo/redo. Godot routes key events
	# to the focused widget rather than to DD when a popup is open, so
	# DD's own undo handler doesn't see them. This listener catches them
	# at the Preferences level.
	if prefs.get_node_or_null("UIRescalerUndoListener") == null:
		var listener_script = GDScript.new()
		listener_script.source_code = """extends Node
var owner_mod = null
func _ready():
	set_process_unhandled_key_input(true)
func _unhandled_key_input(event):
	if event.pressed and event.control and not event.echo:
		if event.scancode == KEY_Z:
			if owner_mod != null and owner_mod.has_method('_prefs_undo'):
				if owner_mod._prefs_undo():
					get_tree().set_input_as_handled()
		elif event.scancode == KEY_Y:
			if owner_mod != null and owner_mod.has_method('_prefs_redo'):
				if owner_mod._prefs_redo():
					get_tree().set_input_as_handled()
"""
		var err = listener_script.reload()
		if err == OK:
			var listener = Node.new()
			listener.set_script(listener_script)
			listener.name = "UIRescalerUndoListener"
			listener.set("owner_mod", self)
			prefs.add_child(listener)

	# Resize popup happens in _on_prefs_opened (the popup's size may be
	# reset between hides, so doing it once at setup isn't enough).

	print("[UIRescaler] Preferences sliders installed")


func _make_prefs_row(parent, label_text, slider, spinbox, id, initial_val):
	var row = HBoxContainer.new()
	var lbl = Label.new()
	lbl.text = label_text
	lbl.rect_min_size = Vector2(170, 0)
	row.add_child(lbl)
	slider.min_value = SLIDER_MIN
	slider.max_value = SLIDER_MAX
	slider.step = SLIDER_STEP
	slider.value = initial_val
	slider.rect_min_size = Vector2(150, 20)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(slider)
	spinbox.min_value = SLIDER_MIN
	spinbox.max_value = SLIDER_MAX
	spinbox.step = SLIDER_STEP
	spinbox.value = initial_val
	spinbox.rect_min_size = Vector2(60, 0)
	spinbox.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(spinbox)
	# Reset button (same icon as the tool's per-slider reset)
	var reset_btn = Button.new()
	var reset_icon = _load_mod_icon("icons/reset.png", 0.5)
	if reset_icon != null:
		reset_btn.icon = reset_icon
	else:
		reset_btn.text = "↺"
	reset_btn.hint_tooltip = "Reset to 1.0"
	reset_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	reset_btn.connect("pressed", self, "_on_prefs_reset", [id])
	row.add_child(reset_btn)
	parent.add_child(row)
	return row


func _on_prefs_reset(id) -> void:
	# Sets the slider+spinbox+pending value back to 1.0 and propagates
	# (if id == MASTER_ID this resets every category to 1.0 too).
	_apply_prefs_value(id, 1.0)


func _on_prefs_slider_changed(val, id) -> void:
	# Mirror to spinbox in prefs
	var spin = _prefs_general_spinbox if id == MASTER_ID else _prefs_thumbs_spinbox
	if spin != null and is_instance_valid(spin):
		spin.set_block_signals(true)
		spin.value = val
		spin.set_block_signals(false)
	_apply_prefs_value(id, val)


func _on_prefs_spin_changed(val, id) -> void:
	var slider = _prefs_general_slider if id == MASTER_ID else _prefs_thumbs_slider
	if slider != null and is_instance_valid(slider):
		slider.set_block_signals(true)
		slider.value = val
		slider.set_block_signals(false)
	_apply_prefs_value(id, val)


# Push value into the tool's pending state + reflect on the tool's slider.
# (Doesn't actually run _apply_all — that happens when the user presses
# Save in Preferences, or Apply in the tool.)
func _apply_prefs_value(id, val) -> void:
	_pending[id] = val
	# Update the prefs slider/spinbox for this row (block_signals makes
	# this a no-op when called from a value_changed signal that already
	# set them; for resets and external updates this is the only place
	# they get updated).
	_mirror_to_prefs(id, val)
	# Update the tool's main-panel slider/spinbox.
	if _sliders.has(id) and is_instance_valid(_sliders[id]):
		_sliders[id].set_block_signals(true)
		_sliders[id].value = val
		_sliders[id].set_block_signals(false)
	if _spinboxes.has(id) and is_instance_valid(_spinboxes[id]):
		_spinboxes[id].set_block_signals(true)
		_spinboxes[id].value = val
		_spinboxes[id].set_block_signals(false)
	# Master propagates to every category (same behaviour as tool slider).
	if id == MASTER_ID:
		_propagate_master_to_categories(val)
	_refresh_apply_state()


func _on_interface_tab_visibility() -> void:
	# Triggered when Interface tab visibility flips. Only act when it's
	# becoming visible (no need to resize when hidden — other tabs will
	# fit fine in the smaller content area).
	if _g == null or _g.Editor == null:
		return
	var prefs = _g.Editor.get_node_or_null("Windows/Preferences")
	if prefs == null or not prefs.visible:
		return
	var iface = prefs.get_node_or_null("Margins/VAlign/Interface")
	if iface == null or not iface.visible:
		return
	call_deferred("_force_resize_prefs")
	call_deferred("_delayed_second_resize")


func _on_prefs_opened() -> void:
	# Snapshot current multipliers so we can revert if user closes without
	# saving. Also refresh slider values from current state (the multipliers
	# might have been changed via the tool since the last open).
	_prefs_opened_general = _multipliers.get(MASTER_ID, 1.0)
	_prefs_opened_thumbs  = _multipliers.get("asset_thumbnails", 1.0)
	_sync_prefs_to_state()
	# Resize the popup to fit our added rows. Deferred so it runs AFTER
	# popup_centered() has computed its own size, letting us override it.
	call_deferred("_force_resize_prefs")
	# Also schedule a second resize a few frames later — at first open
	# after a restart, autowrap Labels and other auto-sized controls may
	# need extra frames before reporting their final min_size.
	call_deferred("_delayed_second_resize")


func _delayed_second_resize() -> void:
	for i in range(3):
		yield(_g.World.get_tree(), "idle_frame")
	_force_resize_prefs()


var _resize_retry_count = 0
const MAX_RESIZE_RETRIES = 30  # ~0.5s at 60fps before giving up


func _force_resize_prefs() -> void:
	# If an _apply_all is currently in progress (it yields across frames),
	# our content size measurements would be inconsistent — some children
	# already scaled, others not. Reschedule until apply finishes, but
	# cap retries so a stuck apply can't spam the deferred queue forever.
	if _apply_in_progress:
		_resize_retry_count += 1
		if _resize_retry_count > MAX_RESIZE_RETRIES:
			_resize_retry_count = 0
			print("[UIRescaler] resize giving up after max retries")
			return
		call_deferred("_force_resize_prefs")
		return
	_resize_retry_count = 0
	if _g == null or _g.Editor == null:
		return
	var prefs = _g.Editor.get_node_or_null("Windows/Preferences")
	if prefs == null:
		return
	# If the popup got closed in the meantime (e.g. user closed it while
	# we were waiting for apply to finish), don't resize.
	if not prefs.visible:
		return
	var valign = prefs.get_node_or_null("Margins/VAlign")
	if valign == null:
		return
	var sep = 4.0
	if valign.has_method("get_constant"):
		var s = valign.get_constant("separation")
		if s > 0:
			sep = float(s)
	var total = 0.0
	var visible_count = 0
	for child in valign.get_children():
		if not (child is Control):
			continue
		if not child.visible:
			continue
		total += child.get_combined_minimum_size().y
		visible_count += 1
	if visible_count > 1:
		total += sep * float(visible_count - 1)
	# Chrome = title bar + top/bottom margins of the MarginContainer.
	# These come from the DD theme; using them avoids both clipping
	# (chrome too small) and ugly gap (chrome too big).
	var chrome = 0.0
	# WindowDialog title bar height
	if prefs.has_method("get_constant"):
		var title_h = prefs.get_constant("title_height", "WindowDialog")
		if title_h > 0:
			chrome += float(title_h)
		else:
			chrome += 36.0  # reasonable fallback
	# MarginContainer top/bottom padding
	var margins = prefs.get_node_or_null("Margins")
	if margins != null and margins.has_method("get_constant"):
		var mt = margins.get_constant("margin_top")
		var mb = margins.get_constant("margin_bottom")
		if mt > 0: chrome += float(mt)
		if mb > 0: chrome += float(mb)
	# Small safety margin so the last control doesn't touch the bottom edge.
	chrome += 12.0
	var target_h = total + chrome
	var vp = prefs.get_viewport_rect().size
	target_h = max(300.0, min(target_h, vp.y * 0.95))
	var content_w = valign.get_combined_minimum_size().x
	var target_w = max(prefs.rect_size.x, max(content_w + 40.0, 640.0))
	target_w = min(target_w, vp.x * 0.95)
	if abs(prefs.rect_size.y - target_h) > 2.0 \
			or abs(prefs.rect_size.x - target_w) > 2.0:
		prefs.rect_size = Vector2(target_w, target_h)
		prefs.rect_position = Vector2(
			max(0, (vp.x - prefs.rect_size.x) / 2.0),
			max(0, (vp.y - prefs.rect_size.y) / 2.0))
		print("[UIRescaler] Preferences resized to ", prefs.rect_size)


func _on_prefs_save_pressed() -> void:
	# Snapshot the current applied multipliers BEFORE we overwrite them,
	# so Ctrl+Z can roll back to this state.
	_prefs_undo_stack.append(_snapshot_multipliers())
	if _prefs_undo_stack.size() > PREFS_UNDO_LIMIT:
		_prefs_undo_stack.pop_front()
	_prefs_redo_stack.clear()
	_on_apply()
	_prefs_opened_general = _multipliers.get(MASTER_ID, 1.0)
	_prefs_opened_thumbs  = _multipliers.get("asset_thumbnails", 1.0)
	# Note: no resize call here. _apply_all triggers _resize_prefs_if_open()
	# at its end, which is the only timing that reliably has stable sizes.


# Capture the current multipliers as a plain dict (the engine returns
# Dictionary by value here, but explicit duplicate guards against later
# in-place mutation invalidating the snapshot).
func _snapshot_multipliers() -> Dictionary:
	return _multipliers.duplicate(true)


# Ctrl+Z handler — pop one snapshot off the undo stack, restore those
# multipliers (and re-apply), and push the current state onto the redo
# stack. Returns true if undo did something (so the listener can swallow
# the key event).
func _prefs_undo() -> bool:
	if _prefs_undo_stack.empty():
		return false
	_prefs_redo_stack.append(_snapshot_multipliers())
	if _prefs_redo_stack.size() > PREFS_UNDO_LIMIT:
		_prefs_redo_stack.pop_front()
	var snap = _prefs_undo_stack.pop_back()
	_restore_multipliers_snapshot(snap)
	return true


func _prefs_redo() -> bool:
	if _prefs_redo_stack.empty():
		return false
	_prefs_undo_stack.append(_snapshot_multipliers())
	if _prefs_undo_stack.size() > PREFS_UNDO_LIMIT:
		_prefs_undo_stack.pop_front()
	var snap = _prefs_redo_stack.pop_back()
	_restore_multipliers_snapshot(snap)
	return true


func _restore_multipliers_snapshot(snap: Dictionary) -> void:
	for k in snap.keys():
		_multipliers[k] = snap[k]
		_pending[k] = snap[k]
	# Reflect everywhere
	_sync_tool_to_state()
	_sync_prefs_to_state()
	# Also update the "opened" snapshot so close-without-save doesn't
	# revert past the undone state.
	_prefs_opened_general = _multipliers.get(MASTER_ID, 1.0)
	_prefs_opened_thumbs  = _multipliers.get("asset_thumbnails", 1.0)
	# Re-apply scaling for the new state.
	_apply_all(false)
	_save_settings()
	_refresh_apply_state()


func _on_prefs_closed() -> void:
	# If the multipliers don't match what they were at open, the user
	# closed without saving — revert.
	var cur_general = _pending.get(MASTER_ID, 1.0)
	var cur_thumbs  = _pending.get("asset_thumbnails", 1.0)
	if abs(cur_general - _prefs_opened_general) > 0.0001 \
			or abs(cur_thumbs - _prefs_opened_thumbs) > 0.0001:
		_pending[MASTER_ID] = _prefs_opened_general
		_pending["asset_thumbnails"] = _prefs_opened_thumbs
		# If master changed during the session, the propagation should be
		# undone too: reset every category's pending to its applied value.
		for c in CATEGORIES:
			_pending[c.id] = _multipliers.get(c.id, 1.0)
		_sync_prefs_to_state()
		_sync_tool_to_state()
		_refresh_apply_state()


# Push the current pending state into the prefs sliders/spinboxes.
func _sync_prefs_to_state() -> void:
	var g_val = _pending.get(MASTER_ID, _multipliers.get(MASTER_ID, 1.0))
	var t_val = _pending.get("asset_thumbnails",
		_multipliers.get("asset_thumbnails", 1.0))
	for ctrl in [_prefs_general_slider, _prefs_general_spinbox]:
		if ctrl != null and is_instance_valid(ctrl):
			ctrl.set_block_signals(true)
			ctrl.value = g_val
			ctrl.set_block_signals(false)
	for ctrl in [_prefs_thumbs_slider, _prefs_thumbs_spinbox]:
		if ctrl != null and is_instance_valid(ctrl):
			ctrl.set_block_signals(true)
			ctrl.value = t_val
			ctrl.set_block_signals(false)


# Push the current pending state into the tool's sliders/spinboxes (used
# after a Preferences revert to keep the tool UI consistent).
func _sync_tool_to_state() -> void:
	for id in _pending.keys():
		var v = _pending[id]
		if _sliders.has(id) and is_instance_valid(_sliders[id]):
			_sliders[id].set_block_signals(true)
			_sliders[id].value = v
			_sliders[id].set_block_signals(false)
		if _spinboxes.has(id) and is_instance_valid(_spinboxes[id]):
			_spinboxes[id].set_block_signals(true)
			_spinboxes[id].value = v
			_spinboxes[id].set_block_signals(false)


# Add a 1-pixel white outline to all stylebox states of a Button. We
# duplicate the theme's stylebox per state so the existing background
# color/padding is preserved; we just add a border on top.
func _outline_button(btn) -> void:
	if btn == null or not is_instance_valid(btn):
		return
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		var src = btn.get_stylebox(state)
		if src == null:
			continue
		var sbox = src.duplicate()
		if sbox is StyleBoxFlat:
			sbox.border_width_left = 1
			sbox.border_width_right = 1
			sbox.border_width_top = 1
			sbox.border_width_bottom = 1
			sbox.border_color = Color(1, 1, 1, 1)
		btn.add_stylebox_override(state, sbox)


func _on_dump_buttons() -> void:
	print("\n===== [UIRescaler] Tool Buttons Dump =====")
	var tree = _g.World.get_tree()
	if tree == null or tree.root == null:
		print("  (no tree)")
		return
	# Walk every Toolbar's Buttons VBox
	for tb in _find_nodes_matching("Master/Editor/VPartition/Panels/Tools/Anchor/*"):
		var divider = tb.get_node_or_null("Divider")
		if divider == null:
			continue
		var buttons = divider.get_node_or_null("Buttons")
		if buttons == null:
			continue
		print("\n-- Toolbar: ", tb.name, " (visible=", tb.visible, ")")
		var title = tb.get_node_or_null("Title")
		if title != null:
			print("   Title text: '", title.text, "'")
		for b in buttons.get_children():
			_dump_button(b, "   ")

	# Dump ancestry of Toolset (Anchor → its parents) — useful for the
	# "gap above icons" investigation. We print rect_position/size of
	# each ancestor + each child of the Anchor.
	print("\n-- Toolset Anchor ancestry --")
	var anchor = tree.root.get_node_or_null(
		"Master/Editor/VPartition/Panels/Tools/Anchor")
	if anchor != null:
		var cur = anchor
		while cur != null and cur.name != "root":
			var line = "   "
			line += cur.get_class() + " " + cur.name
			line += " pos=" + str(cur.rect_position) if cur is Control else ""
			line += " size=" + str(cur.rect_size) if cur is Control else ""
			line += " min=" + str(cur.rect_min_size) if cur is Control else ""
			print(line)
			cur = cur.get_parent()
		# Now list all children of Anchor with their rect_position+size
		print("   Children of Anchor:")
		for c in anchor.get_children():
			if c is Control:
				print("     ", c.get_class(), " ", c.name, " pos=",
					c.rect_position, " size=", c.rect_size, " vis=", c.visible)

	# Toolset
	print("\n-- Toolset (left category bar) --")
	var toolset = tree.root.get_node_or_null(
		"Master/Editor/VPartition/Panels/Tools/Anchor/Toolset")
	if toolset != null:
		print("   Toolset pos=", toolset.rect_position, " size=", toolset.rect_size,
			" min=", toolset.rect_min_size,
			" sflags_h=", toolset.size_flags_horizontal,
			" sflags_v=", toolset.size_flags_vertical,
			" alignment=", toolset.alignment if toolset.get("alignment") != null else "n/a")
		var prev_y = 0
		for b in toolset.get_children():
			if b is Button:
				print("     ", b.name, " pos=", b.rect_position, " size=", b.rect_size,
					" sflags_v=", b.size_flags_vertical)
				prev_y = b.rect_position.y + b.rect_size.y
		_dump_button(toolset.get_child(0), "   ") if toolset.get_child_count() > 0 else null

	# Floatbar
	print("\n-- Floatbar (bottom) --")
	var fb_align = tree.root.get_node_or_null("Master/Editor/Floatbar/Floatbar/Align")
	if fb_align != null:
		print("   Align parent constants:")
		if fb_align.has_constant("separation"):
			print("     separation = ", fb_align.get_constant("separation"))
		for c in fb_align.get_children():
			_dump_button(c, "   ")

	# Visible toolbar full dump (recursive) — to identify thumbnail-aligned
	# Buttons in tools like TerrainBrush.
	print("\n-- Visible Toolbar full dump --")
	for tb_root in _find_nodes_matching("Master/Editor/VPartition/Panels/Tools/Anchor/*"):
		if tb_root is Control and tb_root.visible:
			print("\n   Toolbar: ", tb_root.name)
			_dump_ctrl_chain(tb_root, "   ", 0)

	# Terrain popup window dump
	print("\n-- TerrainWindow (popup) --")
	var tw = tree.root.get_node_or_null("Master/TerrainWindow")
	if tw == null:
		# Try popping in Editor.Windows
		var editor_node = tree.root.get_node_or_null("Master/Editor")
		if editor_node != null and editor_node.get("Windows") != null:
			tw = editor_node.Windows.get("TerrainWindow")
	if tw != null and is_instance_valid(tw):
		print("   Found, visible=", tw.visible)
		_dump_ctrl_chain(tw, "   ", 0)
	else:
		print("   (not found)")

	# Right panel (asset picker / library) — chain of nodes determining
	# its visible width.
	print("\n-- Right panel (Library / asset picker) --")
	var panels = tree.root.get_node_or_null(
		"Master/Editor/VPartition/Panels")
	if panels != null:
		print("\n   All Panels children:")
		for c in panels.get_children():
			if c is Control:
				print("     ", c.get_class(), " ", c.name,
					" pos=", c.rect_position, " size=", c.rect_size,
					" min=", c.rect_min_size, " vis=", c.visible)
		# Recurse into HSplit and its right child to find the asset picker
		var hsplit = panels.get_node_or_null("HSplit")
		if hsplit != null:
			print("\n   HSplit recursive dump (max 6 levels):")
			_dump_ctrl_chain(hsplit, "   ", 0)
	print("\n===== End dump =====\n")
	if _status_lbl != null and is_instance_valid(_status_lbl):
		_status_lbl.text = "Dumped to console."


func _dump_ctrl_chain(node, indent: String, depth: int) -> void:
	if not (node is Control):
		return
	var line = indent
	line += node.get_class() + " " + node.name
	line += " pos=" + str(node.rect_position)
	line += " size=" + str(node.rect_size)
	line += " min=" + str(node.rect_min_size)
	line += " vis=" + str(node.visible)
	if node is HSplitContainer or node is VSplitContainer:
		line += " split_offset=" + str(node.split_offset)
	if node.size_flags_horizontal != 0 or node.size_flags_vertical != 0:
		line += " sfh=" + str(node.size_flags_horizontal) + " sfv=" + str(node.size_flags_vertical)
	print(line)
	if depth < 6:  # don't go too deep
		for c in node.get_children():
			_dump_ctrl_chain(c, indent + "  ", depth + 1)


func _dump_button(b, indent: String) -> void:
	if not (b is Control):
		print(indent, "[non-Control] ", b.name, " (", b.get_class(), ")")
		return
	var is_btn = b is Button
	var line = indent
	line += "[" + b.get_class() + "] "
	line += b.name
	if is_btn and b.text != "":
		line += " text='" + b.text + "'"
	line += " visible=" + str(b.visible)
	line += " min=" + str(b.rect_min_size)
	line += " rect=" + str(b.rect_size)
	line += " getMinSize=" + str(b.get_minimum_size())
	print(line)
	if is_btn:
		# .icon property (explicit)
		if b.icon != null:
			print(indent, "    .icon       = ", b.icon, " size=", b.icon.get_size(), " class=", b.icon.get_class())
		else:
			print(indent, "    .icon       = null")
		# get_icon("icon") — theme/override
		var theme_icon = b.get_icon("icon")
		if theme_icon != null:
			print(indent, "    get_icon    = ", theme_icon, " size=", theme_icon.get_size(), " class=", theme_icon.get_class())
		# Icon override (set by our mod)
		var has_icon_override = b.has_icon_override("icon")
		print(indent, "    has_icon_override = ", has_icon_override)
		if has_icon_override:
			var ov = b.get_icon("icon")  # returns override when present
			if ov != null:
				print(indent, "      override size = ", ov.get_size(), " class=", ov.get_class())
		print(indent, "    expand_icon = ", b.expand_icon)
		print(indent, "    flat        = ", b.flat)
		print(indent, "    toggle_mode = ", b.toggle_mode)
		print(indent, "    pressed     = ", b.pressed)
		print(indent, "    disabled    = ", b.disabled)
		print(indent, "    size_flags  = h:", b.size_flags_horizontal, " v:", b.size_flags_vertical)
		# Theme constants that affect icon rendering
		for cname in ["icon_max_width", "hseparation", "vseparation"]:
			if b.has_constant(cname):
				print(indent, "    const ", cname, " = ", b.get_constant(cname))
		# Stylebox content margins (limit content rect inside button)
		for sname in ["normal", "pressed", "hover", "disabled", "focus"]:
			var sb = b.get_stylebox(sname)
			if sb != null:
				print(indent, "    sbox ", sname, " content margins l=",
					sb.content_margin_left, " t=", sb.content_margin_top,
					" r=", sb.content_margin_right, " b=", sb.content_margin_bottom)
				break  # one is enough to see the pattern
		# Has my mod captured a baseline for this node?
		var key = b.get_instance_id()
		if _baselines.has(key):
			print(indent, "    [mod] baseline = ", _baselines[key])
		else:
			print(indent, "    [mod] NO baseline captured")
		# Script attached?
		var scr = b.get_script()
		if scr != null:
			print(indent, "    script      = ", scr.resource_path)
	# Children
	if b.get_child_count() > 0:
		print(indent, "    children:")
		for c in b.get_children():
			var cline = indent + "      - [" + c.get_class() + "] " + c.name
			if c is TextureRect and c.texture != null:
				cline += " texture=" + str(c.texture) + " texsize=" + str(c.texture.get_size())
				cline += " expand=" + str(c.expand) + " stretch=" + str(c.stretch_mode)
			if c is Sprite and c.texture != null:
				cline += " texture=" + str(c.texture)
			if c is Control:
				cline += " min=" + str(c.rect_min_size) + " rect=" + str(c.rect_size) + " vis=" + str(c.visible)
			print(cline)


func _on_apply() -> void:
	for k in _pending:
		_multipliers[k] = _pending[k]
	_apply_all(false)
	_save_settings()
	_refresh_apply_state()
	if _status_lbl != null and is_instance_valid(_status_lbl):
		_status_lbl.text = "Applied."


func _on_reset_all() -> void:
	for k in _multipliers.keys():
		_multipliers[k] = 1.0
		_pending[k] = 1.0
		if _sliders.has(k) and is_instance_valid(_sliders[k]):
			_sliders[k].set_block_signals(true)
			_sliders[k].value = 1.0
			_sliders[k].set_block_signals(false)
		if _spinboxes.has(k) and is_instance_valid(_spinboxes[k]):
			_spinboxes[k].set_block_signals(true)
			_spinboxes[k].value = 1.0
			_spinboxes[k].set_block_signals(false)
	_apply_all(false)
	_save_settings()
	_refresh_apply_state()


# ── Persistence ──────────────────────────────────────────────────────────

func _save_settings() -> void:
	var d = {}
	for k in _multipliers:
		d[k] = _multipliers[k]
	var dir = Directory.new()
	if not dir.dir_exists("user://UnofficialPatch"):
		dir.make_dir("user://UnofficialPatch")
	var f = File.new()
	if f.open(_SETTINGS_FILE, File.WRITE) == OK:
		f.store_string(JSON.print(d))
		f.close()


func _load_settings() -> void:
	var f = File.new()
	if f.open(_SETTINGS_FILE, File.READ) != OK:
		return
	var text = f.get_as_text()
	f.close()
	var parsed = JSON.parse(text)
	if parsed.error != OK or not parsed.result is Dictionary:
		return
	for k in parsed.result:
		if _multipliers.has(k):
			var v = float(parsed.result[k])
			_multipliers[k] = clamp(v, SLIDER_MIN, SLIDER_MAX)
			_pending[k] = _multipliers[k]
