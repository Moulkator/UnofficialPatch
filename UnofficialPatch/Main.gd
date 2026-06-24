var script_class = "tool"

# ── Per-mod update() profiler ────────────────────────────────────────────────
# F10 cycle (in-editor):
#   1st press : start profiling
#   2nd press : stop + print to console + show the results overlay in DD
#   3rd press : hide the overlay
#   4th press : start a new test (back to the top)
# Zero cost when off.
var _prof_on := false
var _prof_acc := {}
var _prof_frames := 0
var _prof_key_was := false
var _prof_state := "idle"   # idle → running → shown → (idle)
var _prof_overlay = null
var _prof_running_popup = null
var _prof_copy_btn = null
var _prof_close_btn = null
var _prof_scroll = null
var _prof_panel = null
var _prof_input_node = null
var _prof_mouse_was := false
var _prof_last_lines := []

# UndoLib — shared undo helpers for other sub-modules.
# Registered in _g.ModMapData["_undo_lib"]; consumers look it up there.
var UndoLibScript
var undo_lib

# ModSettings — centralized ON/OFF toggles for mod features (Settings tab).
var ModSettingsScript
var mod_settings
var debug_settings
var welcome_popup

# PrefsLabelFix — always-on, populates an empty Label in Preferences.
var PrefsLabelFixScript
var prefs_label_fix

var PrefabsFixScript
var prefabs_fix

var PortalToolFixScript
var portal_tool_fix

var PortalFlattenCurvesScript
var portal_flatten_curves

var MapResizeFixScript
var map_resize_fix

var ClipboardFixScript
var clipboard_fix

var AltDeselectScript
var alt_deselect

var WaterToolFixScript
var water_tool_fix

var PreviewFixScript
var preview_fix

var SelectFixScript
var select_fix

var ScatterMultiselectFixScript
var scatter_multiselect_fix

var SelectCursorFixScript
var select_cursor_fix

var SelectHighlightFixScript
var select_highlight_fix

var DragSelectFocusFixScript
var drag_select_focus_fix

var SelectLayerPickFixScript
var select_layer_pick_fix

var CompareFixScript
var compare_fix

var PathFixScript
var path_fix

var UIUtilScript
var ui_util

var WallFixScript
var wall_fix

var LightFixScript
var light_fix

var LightToolFixScript
var light_tool_fix

var AssetCycleScript
var asset_cycle

var RotationFixScript
var rotation_fix

var RotationSnapScript
var rotation_snap

var TransformBoxFixScript
var transform_box_fix

var SelectionResizeScript
var selection_resize

var PanFixScript
var pan_fix

var WallAllowLightScript
var wall_allow_light

var DropFixScript
var drop_fix

var PatternFixScript
var pattern_fix

var DropEmbedScript
var drop_embed

var FavoritesScript
var favorites

var PackCacheFixScript
var pack_cache_fix

var RoofSelectScript
var roof_select

var GridFixScript
var grid_fix

var PathDrawFixScript
var path_draw_fix

var PathCurveEditScript
var path_curve_edit

var WallCurveEditScript
var wall_curve_edit

var PatternCurveEditScript
var pattern_curve_edit

var EditPointsUndoScript
var edit_points_undo

var PreserveSelectionUndoScript
var preserve_selection_undo

var PrefabsCloneFixScript
var prefabs_clone_fix

var PrefabsThumbnailsScript
var prefabs_thumbnails

var SaveReminderScript
var save_reminder

var TextToolFixScript
var text_tool_fix

var TextTransformScript
var text_transform

var EyedropperScript
var eyedropper

var ScaleUnlockScript
var scale_unlock

var FreeTransformScript
var free_transform

var FreeTransformDataManagerScript
var free_transform_data_manager

var NoMicroDragScript
var no_micro_drag

var WindowTransparencyFixScript
var window_transparency_fix

var PortalReposUIScript
var portal_reposition_ui

var WallToolPortalFixScript
var wall_tool_portal_fix

var OverlayToolScript
var overlay_tool

var WallMoveScript
var wall_move

var TextSelectStyleScript
var text_select_style

var LevelSettingsFixScript
var level_settings_fix

var LevelSettingsExtraScript
var level_settings_extra

var SplitPathScript
var split_path

var MergePathScript
var merge_path

var DragSelectWallsScript
var drag_select_walls

var PatternPaintBucketScript
var pattern_paint_bucket

var TerrainPaintBucketScript
var terrain_paint_bucket
var TerrainSlotsExtendedScript
var terrain_slots_extended

var ExportTraceImageScript
var export_trace_image
var _eti_pending_start = false
var _eti_started = false

var ZoomUnlockScript
var zoom_unlock

var TraceExtendedScript
var trace_extended

var SelectCollapseScript
var select_collapse

var SelectRotationScript
var select_rotation

var PopupBlurScript
var popup_blur

var GridRulerScript
var grid_ruler

var SelectFilterBarScript
var select_filter_bar

var UIRescalerScript
var ui_rescaler

var GroupAssetsScript
var group_assets

var RightClickUtilScript
var right_click_util
var ft_context
var rotate_context

var MapExplorerScript
var map_explorer

var ArcDrawScript
var arc_draw

var AxisLockScript
var axis_lock

var ToolHintScript
var tool_hint

var EditPointsToggleScript
var edit_points_toggle

# Loading popup
var _loading_popup = null


func _is_mod_loaded(unique_id) -> bool:
	if Global.get("API") == null: return false
	var registry = Global.API.get("ModRegistry") if Global.API != null else null
	if registry == null: return false
	var info = null
	if registry.has_method("get_mod_info"):
		info = registry.get_mod_info(unique_id)
	return info != null


func _show_loading_popup() -> void:
	var root = Global.World.get_tree().root if Global.World else null
	if root == null:
		return

	_loading_popup = Panel.new()
	_loading_popup.name = "UPLoadingOverlay"

	# Semi-transparent dark background covering the entire screen
	_loading_popup.anchor_right = 1.0
	_loading_popup.anchor_bottom = 1.0
	var bg_style = StyleBoxFlat.new()
	bg_style.bg_color = Color(0.08, 0.08, 0.10, 0.95)
	_loading_popup.add_stylebox_override("panel", bg_style)

	var vbox = VBoxContainer.new()
	vbox.anchor_left = 0.5
	vbox.anchor_top = 0.5
	vbox.anchor_right = 0.5
	vbox.anchor_bottom = 0.5
	vbox.margin_left = -200
	vbox.margin_right = 200
	vbox.margin_top = -40
	vbox.margin_bottom = 40
	vbox.set("custom_constants/separation", 12)
	_loading_popup.add_child(vbox)

	var title_lbl = Label.new()
	title_lbl.text = "Patching Dungeondraft, please wait..."
	title_lbl.align = Label.ALIGN_CENTER
	title_lbl.add_font_override("font", title_lbl.get_font("font").duplicate())
	title_lbl.get_font("font").size = 32
	vbox.add_child(title_lbl)

	var sub_lbl = Label.new()
	sub_lbl.text = "This might take a few seconds."
	sub_lbl.align = Label.ALIGN_CENTER
	sub_lbl.modulate = Color(0.7, 0.7, 0.7, 1.0)
	sub_lbl.add_font_override("font", sub_lbl.get_font("font").duplicate())
	sub_lbl.get_font("font").size = 24
	vbox.add_child(sub_lbl)

	# Add at highest z-order so it's above everything
	root.add_child(_loading_popup)
	_loading_popup.raise()
	print("[UnofficialPatch] Loading popup shown")


func _close_loading_popup() -> void:
	if _loading_popup != null and is_instance_valid(_loading_popup):
		_loading_popup.queue_free()
		_loading_popup = null
		print("[UnofficialPatch] Loading popup closed")


func start() -> void:

	# Register with _lib if available (active le verificateur de mise a jour _Lib)
	if Engine.has_signal("_lib_register_mod"):
		Engine.emit_signal("_lib_register_mod", self)
		if "API" in Global and Global.API.has("UpdateChecker"):
			var uc = Global.API.UpdateChecker
			uc.register(uc.builder()\
				.fetcher(uc.github_fetcher("Moulkator", "UnofficialPatch"))\
				.downloader(uc.github_downloader("Moulkator", "UnofficialPatch"))\
				.build())

	# UndoLib — shared undo helpers (loaded first so any later sub-module
	# can grab a ref via _g.ModMapData.get("_undo_lib") from its own init).
	if _debug_enabled("undo_lib"):
		UndoLibScript = ResourceLoader.load(Global.Root + "scripts/undo_lib.gd", "GDScript", true)
	if UndoLibScript != null:
		undo_lib = UndoLibScript.new()
		undo_lib._g = Global
		undo_lib.initialize()

	# ModSettings — centralized ON/OFF toggles for mod features.
	# Loaded before _show_loading_popup so the popup itself can be gated, and
	# before any toggleable sub-mod so they can be conditionally loaded.
	if _debug_enabled("mod_settings"):
		ModSettingsScript = ResourceLoader.load(Global.Root + "scripts/mod_settings.gd", "GDScript", true)
	if ModSettingsScript != null:
		mod_settings = ModSettingsScript.new()
		mod_settings._g = Global
		mod_settings.initialize()

	# DebugSettings — loaded right after mod_settings (before everything else)
	# so it can gate every subsequent ResourceLoader.load. State is read from
	# disk; toggles only take effect on next launch.
	# Toujours charge — meme si "Display Debug Panel" est OFF, on garde
	# debug_settings en memoire pour pouvoir afficher le panel a chaud quand
	# le user toggle ON. Le panel est juste hide au boot si display_debug_tool
	# est false. Le bouton du tool dans la barre verticale est de toute facon
	# force invisible chaque frame par mod_settings.update.
	var DebugSettingsScript = ResourceLoader.load(Global.Root + "scripts/debug_settings.gd", "GDScript", true)
	if DebugSettingsScript != null:
		debug_settings = DebugSettingsScript.new()
		debug_settings._g = Global
		debug_settings.mod_settings = mod_settings
		debug_settings.initialize()
		_register_debug_mods()
		if mod_settings != null:
			mod_settings.debug_settings = debug_settings
		print("[UnofficialPatch] DebugSettings loaded.")

	# WelcomePopup — affiche au premier lancement (jusqu'a ce que l'user
	# coche "Do not show again"). Le show effectif est differe dans
	# update() pour apparaitre apres le Patching DD popup.
	var WelcomePopupScript = ResourceLoader.load(Global.Root + "scripts/welcome_popup.gd", "GDScript", true)
	if WelcomePopupScript != null:
		welcome_popup = WelcomePopupScript.new()
		welcome_popup._g = Global
		welcome_popup.initialize()
		print("[UnofficialPatch] WelcomePopup loaded.")

	if mod_settings != null:
		# Sections + toggles (tooltips en anglais).
		mod_settings.register_section("general", "GENERAL")
		mod_settings.register_section("ui", "UI")
		mod_settings.register_section("controls", "CONTROLS")
		mod_settings.register_section("selection_tool", "SELECTION TOOL")
		mod_settings.register_section("other_tools", "OTHER TOOLS")
		mod_settings.register_section("debug", "DEBUG")
		mod_settings.register_toggle(
			"favorite_assets", "general", "Asset Favorites",
			"Lets you star/favorite individual assets across packs\n(objects, paths, walls, terrains, lights, prefabs) and recolor\nthem. Adds badges, a custom pack, and right-click actions.",
			true,
			null, "",
			true)
		mod_settings.register_toggle(
			"create_pack_from_favorites", "general", "Create Custom Pack from Favorites",
			"When ON, favorited assets are bundled into a private\n'.dungeondraft_pack' file so they appear together as a real\npack you can browse and place.\nWhen OFF, favorites are only marked visually in the UI\n(star badges, recolor) but no pack file is written.",
			false,
			self, "_on_create_pack_from_favorites_toggled",
			false, "favorite_assets")
		mod_settings.register_toggle(
			"drop_embed", "general", "Create Custom Pack from Dropped Files",
			"Lets you drag-and-drop image files (PNG/JPG/WEBP) onto\nthe editor to embed them as placeable assets via a private\npack that travels with the map.\nDisable to ignore image drops.",
			true)
		mod_settings.register_toggle(
			"draw_over_ui", "general", "Draw Over UI",
			"Lets Path, Wall, Pattern, Floor and Roof tools keep\ntracking the cursor when it leaves the map viewport,\nso you can keep drawing while moving over UI panels.",
			true, self, "_on_draw_over_ui_toggled")
		mod_settings.register_toggle(
			"map_gallery", "general", "Map Gallery",
			"Adds a 'Map Gallery' entry in the main menu:\na thumbnail browser for all your saved maps with search,\nsort, folders, favorites, and quick open.",
			true, self, "_on_map_gallery_toggled")
		mod_settings.register_toggle(
			"map_resize_target_size", "general", "Map Resize Target Size",
			"Adds a 'Target Size' alternative mode in the Resize Map\ndialog where you enter the desired final dimensions and\nan anchor instead of per-side offsets.\nBug fixes (200x200 limit, terrain/cave offsets) stay active\neither way.",
			true, self, "_on_map_resize_target_size_toggled")
		mod_settings.register_toggle(
			"pack_cache_popup", "general", "Pack Cache Popup",
			"Shows a confirmation popup when stale asset packs from\na previous map are still cached.\nWith this off, the cleanup runs silently — the fix itself\nstays active.",
			true)
		mod_settings.register_toggle(
			"loading_popup", "general", "Patching DD Popup",
			"Shows a 'Patching Dungeondraft, please wait...' overlay during\nthe unavoidable lag at session start (mainly while Prefab\nThumbnails are generated).\nThe lag itself can be reduced by disabling Prefab Thumbnails.",
			true,
			null, "",
			true)
		mod_settings.register_toggle(
			"save_reminder", "general", "Save Reminder",
			"Pops up a reminder to save when you've been working on\nan unsaved map for a few minutes.\nDelay is configurable in the popup.",
			true, self, "_on_save_reminder_toggled")
		mod_settings.register_toggle(
			"blurred_popup_background", "ui", "Blurred Popup Background",
			"Applies a Gaussian blur behind popups and dialogs for visual depth.",
			true,
			null, "",
			true)
		mod_settings.register_toggle(
			"ruler_guide", "ui", "Ruler Guide",
			"Adds a Photoshop-like ruler overlay around the map viewport\nwith a 'Guides' button next to Grid/Snap/Lighting and a\nCtrl+R shortcut.\nShows live cell coordinates of the cursor.",
			true, self, "_on_ruler_guide_toggled")
		mod_settings.register_toggle(
			"ruler_guide_bar_button", "ui", "Guides Floatbar Button",
			"Shows the 'Guides' toggle button in the bottom floatbar\nnext to Grid/Snap/Lighting.\nThe Ctrl+R shortcut keeps working either way.",
			true, self, "_on_ruler_guide_bar_button_toggled",
			false, "ruler_guide")
		mod_settings.register_toggle(
			"select_filter_bar", "selection_tool", "Filter Bar",
			"Adds a repositionable horizontal bar of asset-type filter\ncheckboxes (Walls, Portals, Objects, ...) that mirrors the\nSelectTool FILTER popup but stays visible at all times.\nOnly shown while the Select Tool is active.",
			true, self, "_on_select_filter_bar_toggled")
		mod_settings.register_toggle(
			"walls_paths_overlay", "ui", "Hovered Assets Overlay",
			"Highlights walls, paths, patterns and objects under the cursor in a\nconfigurable tint, making path selection easier and more\nreliable.\nAdds the 'Overlay Settings' tool to the Settings tab to\ntune colors and opacity.",
			true,
			null, "",
			true)
		mod_settings.register_toggle(
			"overlay_bar_button", "ui", "Overlays Floatbar Button",
			"Shows the 'Overlays' toggle button in the bottom floatbar\nnext to Grid/Snap/Lighting (turns wall+path highlighting\non/off, remembering each one's previous state).\nThe Shift+O shortcut keeps working either way.",
			true, self, "_on_overlay_bar_button_toggled",
			false, "walls_paths_overlay")
		mod_settings.register_toggle(
			"select_filter_bar_bar_button", "ui", "Filters Floatbar Button",
			"Shows the 'Filters' toggle button in the bottom floatbar\nnext to Grid/Snap/Lighting to show/hide the Select Tool\nfilter bar.",
			true, self, "_on_select_filter_bar_bar_button_toggled",
			false, "select_filter_bar")
		mod_settings.register_toggle(
			"one_deg_rotation", "controls", "1° Rotation",
			"Enables Shift+Z+Mousewheel for 1° precision rotation in\nSelectTool, ObjectTool and PortalTool.\nIndependent of Consistent Rotation — works even when the\nother tool steps are left vanilla.",
			true,
			null, "",
			false, "", "SHIFT + Z + MOUSEWHEEL")
		mod_settings.register_toggle(
			"arc_draw", "controls", "Arc",
			"In Path/Wall/Pattern Shape tools, hold Ctrl while drawing\nor editing a curve to draw an arc (90°/180°).\nUse Mousewheel to choose the arc shape;\nShift to swap concave/convex.",
			true, self, "_on_arc_draw_toggled",
			false, "", "CURVE + CTRL")
		mod_settings.register_toggle(
			"axis_lock", "controls", "Axis Lock",
			"In Path/Wall/Pattern/Roof tools, hold Ctrl (Cmd on Mac)\nwhile drawing to constrain the segment to the 8 cardinal/\ndiagonal axes, like Shift in Photoshop.",
			true, self, "_on_axis_lock_toggled",
			false, "", "DRAW + CTRL")
		mod_settings.register_toggle(
			"select_tool_asset_cycle", "controls", "Asset Cycle in Selection Tool",
			"In SelectTool, hovering over an asset list and Shift+Mousewheel cycles items. Disable to let the list scroll naturally instead.",
			true,
			null, "",
			false, "", "SHIFT")
		mod_settings.register_toggle(
			"centered_resize_alt", "controls", "Centered Resize",
			"Holding Alt while dragging a selection's resize handle scales it from its center instead of the opposite corner.",
			true,
			null, "",
			false, "", "HANDLE + ALT")
		mod_settings.register_toggle(
			"consistent_rotation", "controls", "Consistent Rotation Between Tools",
			"Unifies wheel-rotation step sizes across SelectTool,\nObjectTool and PortalTool: normal scroll = 15°, Z+scroll = 5°.\nWith this off, each tool keeps its own vanilla DD step\n(e.g. 30° in SelectTool, 5° in PortalTool).",
			true)
		mod_settings.register_toggle(
			"edit_curves", "controls", "Edit Curves",
			"In Edit Points mode of Path/Wall/Pattern Shape tools, hold\nShift while clicking between two points to create a smooth\ncurve segment.\nMousewheel adjusts the curvature.",
			true, self, "_on_edit_curves_toggled",
			false, "", "EDIT POINTS + SHIFT")
		mod_settings.register_toggle(
			"snap_resize_shift", "controls", "Geometry Resize",
			"Holding Shift while dragging a selection's resize handle\nstretches just the geometry of paths, patterns and walls,\nleaving line widths, textures, and tile sizes unchanged.\nOther assets only reposition. The dragged corner snaps to\nthe grid when DD's 'Snap to Grid' is enabled (uses Custom\nSnap points if that mod is also active).",
			true,
			null, "",
			false, "", "HANDLE + SHIFT")
		mod_settings.register_toggle(
			"zoom_unlock", "controls", "Mousewheel Zoom Unlock",
			"Lets you Ctrl+Mousewheel past Dungeondraft's default zoom limits (down to 0.06% and up to 800%+).",
			true, self, "_on_zoom_unlock_toggled")
		mod_settings.register_toggle(
			"rotation_snap", "controls", "Rotation Snap",
			"Holding Shift while rotating a selection via the transform\nhandle snaps the angle to 45° increments and locks the\ntransform box to its pre-rotation corners.",
			true,
			null, "",
			false, "", "HANDLE + SHIFT")
		mod_settings.register_toggle(
			"tool_hints", "controls", "Tool Hints",
			"Adds custom hints to Dungeondraft's bottom infobar\ndescribing the new shortcuts and gestures introduced by\nthe Patch (Edit Points, Free Transform, Drag-Select Walls,\netc.).",
			true, self, "_on_tool_hints_toggled")
		mod_settings.register_toggle(
			"better_selection", "selection_tool", "Better Selection (No Micro Drag)",
			"Suppresses tiny accidental drags when you click on an\nalready-selected asset (a few pixels of mouse movement no\nlonger reposition the asset).\nClick-and-drag past a small threshold still works normally.",
			true, self, "_on_better_selection_toggled")
		mod_settings.register_toggle(
			"hide_box_on_drag", "selection_tool", "Hide Box While Dragging",
			"While instant-dragging a single asset (click-drag without\nselecting first), hides the selection outline drawn around\nit until you release.\nRequires the Hovered Assets Overlay mod.",
			true,
			null, "",
			false, "walls_paths_overlay")
		mod_settings.register_toggle(
			"collapsable_controls", "selection_tool", "Collapsable Controls",
			"Adds collapse/expand arrows on each section of the\nSelectTool side panel so you can hide groups of controls\nyou don't currently need.",
			true, self, "_on_collapsable_controls_toggled")
		mod_settings.register_toggle(
			"free_transform", "selection_tool", "Free Transform",
			"Adds a 'Free Transform' entry to the right-click menu\nwhen an asset compatible with FT is selected (object, path,\nwall portal, pattern).\nAlso hides the FT toggle button in the SelectTool panel\nwhen off.",
			true, self, "_on_free_transform_toggled")
		mod_settings.register_toggle(
			"group_assets", "selection_tool", "Group Assets",
			"Adds Group / Ungroup actions to the right-click menu in\nSelectTool.\nGrouped assets share a tint and move/rotate/scale as one\n— without going through DD's prefab system.",
			true, self, "_on_group_assets_toggled")
		mod_settings.register_toggle(
			"hide_lights_transform_box", "selection_tool", "Hide Lights Transform Box",
			"When ON: small lights have their transform box hidden\n(they're tiny and the box gets in the way), and normal-size\nlights show a transparent box.\nWith multiple lights selected, the box stays normal so you\ncan move/rotate/scale them as a group.\nWhen OFF: standard transform box for any light selection\n(vanilla DD behavior).",
			true)
		mod_settings.register_toggle(
			"wall_move_transform", "selection_tool", "Move, Transform and Copy Walls",
			"Lets you click-drag walls in the SelectTool to move them,\nincludes them in transform-box operations (move/rotate/scale)\nwhen walls are part of a multi-selection, and allows\ncopy/paste of walls.\nDisable to keep walls strictly stationary and excluded\nfrom the clipboard.",
			true, self, "_on_wall_move_transform_toggled")
		mod_settings.register_toggle(
			"paste_snap", "selection_tool", "Paste Snap",
			"On paste, snaps items to the grid before they appear (no\nvisible jump).\nAlso snaps pasted items at the end of any drag that\nfollows, until the selection is changed.",
			true)
		mod_settings.register_toggle(
			"paste_under_cursor", "selection_tool", "Paste Under Cursor",
			"On Ctrl+V, moves the pasted selection so its center sits\nunder the mouse cursor.\nWith this off, paste behaves like Ctrl+Shift+V (paste in\nplace).",
			true)
		mod_settings.register_toggle(
			"picker_tool_enter", "selection_tool", "Picker Tool",
			"Press Enter while a single asset is selected to switch to\nits source tool (Object/Path/Wall/Pattern/Light/Terrain)\nwith the same asset preselected — like an eyedropper.",
			true, self, "_on_picker_tool_enter_toggled",
			false, "", "ENTER")
		mod_settings.register_toggle(
			"rotation_slider", "selection_tool", "Rotation Slider",
			"Adds a rotation slider + spinbox to the SelectTool side\npanel showing the current selection's angle relative to its\nbaseline.\nMirrors Handle Rotation Snap when Shift is held.",
			true, self, "_on_rotation_slider_toggled")
		mod_settings.register_toggle(
			"undo_preserves_selection", "selection_tool", "Undo Preserves Selection",
			"After Ctrl+Z / Ctrl+Y, restores the SelectTool selection to\nwhat it was just before the action — so you don't have to\nre-click the items you were working on.",
			true, self, "_on_undo_preserves_selection_toggled")
		mod_settings.register_toggle(
			"light_tool_object_like", "other_tools", "Light Tool - Controls from Objects Tool",
			"In LightTool, when ON: ObjectTool-style shortcuts\n(Right Click = +90° rotation, Mousewheel = rotate\n15°/Z=5°/Shift+Z=1°, Shift+wheel = cycle styles,\nAlt+wheel = range).\nWhen OFF: vanilla LightTool feel (Alt+wheel = rotate\n15°/Z=5°, Shift+wheel = scale by 0.1, no plain wheel\nrotation, no right-click rotation).",
			true)
		mod_settings.register_toggle(
			"pattern_right_click_rotation", "other_tools", "Pattern Tool - Right Click Rotation",
			"In PatternShapeTool, right-click rotates the pattern's\nRotation slider by +90°.\nWith this off, right-click is left to DD (no custom\nrotation shortcut).",
			true)
		mod_settings.register_toggle(
			"prefab_preview", "other_tools", "Prefab Tool - Preview",
			"Generates thumbnail previews for every prefab in the\nPrefabTool item list, with multiple display modes\n(small/medium/large grid, list with thumb).\nRenders prefabs offscreen via Viewports, which takes RAM\nand a bit of time at startup.\nDisable to fall back to DD's vanilla text-only prefab list.",
			true,
			null, "",
			true)
		mod_settings.register_toggle(
			"reposition_portals", "other_tools", "Wall Tool - Reposition Portals",
			"In WallTool's Edit Points mode, adds a 'Reposition Portals\n(Beta)' toggle that keeps portals on edited segments and\nrepositions them along the new geometry.\nWith this off, portals on edited walls are removed\n(vanilla DD behavior).",
			true, self, "_on_reposition_portals_toggled",
			false, "", "EDIT POINTS")
		mod_settings.register_toggle(
			"portal_flatten_curves", "other_tools", "Portal Tool - Flatten Curves",
			"In PortalTool, adds a 'Flatten Curves' toggle that lets\nyou place a portal on a curved wall section. While the\ntoggle is ON, hovering a curve previews a cardinal-angle\nchord (matching the portal width); clicking it flattens the\nwall there in a single operation and places the portal on\nthe new straight segment.\nGrid-aligned when DD's Snap to Grid is active.",
			true,
			null, "",
			false, "", "PORTAL TOOL")
		mod_settings.register_toggle(
			"display_debug_tool", "debug", "Display Debug Panel",
			"Shows the 'Mod Debug' panel alongside this one,\nwhere each loadable mod script can be toggled\nindividually (next-launch effect).\nDisable to hide the panel and reset all per-script\ntoggles to ON.",
			false, self, "_on_display_debug_tool_toggled",
			false, "", "",
			true)
		print("[UnofficialPatch] ModSettings loaded.")

	if mod_settings == null or mod_settings.is_enabled("loading_popup"):
		_show_loading_popup()

	# PrefsLabelFix — always loaded, independent of Blurred Background toggle.
	if _debug_enabled("prefs_label_fix"):
		PrefsLabelFixScript = ResourceLoader.load(Global.Root + "scripts/prefs_label_fix.gd", "GDScript", true)
	if PrefsLabelFixScript != null:
		prefs_label_fix = PrefsLabelFixScript.new()
		prefs_label_fix._g = Global
		prefs_label_fix.initialize()
		print("[UnofficialPatch] PrefsLabelFix loaded.")

	if _debug_enabled("prefabs_fix"):
		PrefabsFixScript = ResourceLoader.load(Global.Root + "scripts/prefabs_fix.gd", "GDScript", true)
		prefabs_fix = PrefabsFixScript.new()
		prefabs_fix._g = Global
		prefabs_fix.initialize()

	if _debug_enabled("portal_tool_fix"):
		PortalToolFixScript = ResourceLoader.load(Global.Root + "scripts/portal_tool_fix.gd", "GDScript", true)
		portal_tool_fix = PortalToolFixScript.new()
		portal_tool_fix._g = Global
		portal_tool_fix.initialize()

	if _debug_enabled("map_resize_fix"):
		MapResizeFixScript = ResourceLoader.load(Global.Root + "scripts/map_resize_fix.gd", "GDScript", true)
		map_resize_fix = MapResizeFixScript.new()
		map_resize_fix._g = Global
		map_resize_fix.initialize()

	if _debug_enabled("clipboard_fix"):
		ClipboardFixScript = ResourceLoader.load(Global.Root + "scripts/clipboard_fix.gd", "GDScript", true)
		clipboard_fix = ClipboardFixScript.new()
		clipboard_fix._g = Global
		clipboard_fix.initialize()

	if _debug_enabled("alt_deselect"):
		AltDeselectScript = ResourceLoader.load(Global.Root + "scripts/alt_deselect.gd", "GDScript", true)
		alt_deselect = AltDeselectScript.new()
		alt_deselect._g = Global
		alt_deselect.initialize()

	if _debug_enabled("water_tool_fix"):
		WaterToolFixScript = ResourceLoader.load(Global.Root + "scripts/water_tool_fix.gd", "GDScript", true)
		water_tool_fix = WaterToolFixScript.new()
		water_tool_fix._g = Global
		water_tool_fix.initialize()

	if _debug_enabled("preview_fix"):
		PreviewFixScript = ResourceLoader.load(Global.Root + "scripts/preview_fix.gd", "GDScript", true)
		preview_fix = PreviewFixScript.new()
		preview_fix._g = Global
		preview_fix.initialize()

	if _debug_enabled("select_fix"):
		SelectFixScript = ResourceLoader.load(Global.Root + "scripts/select_fix.gd", "GDScript", true)
		select_fix = SelectFixScript.new()
		select_fix._g = Global
		select_fix.initialize()

	if _debug_enabled("scatter_multiselect_fix"):
		ScatterMultiselectFixScript = ResourceLoader.load(Global.Root + "scripts/scatter_multiselect_fix.gd", "GDScript", true)
		scatter_multiselect_fix = ScatterMultiselectFixScript.new()
		scatter_multiselect_fix._g = Global
		scatter_multiselect_fix.initialize()

	if _debug_enabled("select_cursor_fix"):
		SelectCursorFixScript = ResourceLoader.load(Global.Root + "scripts/select_cursor_fix.gd", "GDScript", true)
		select_cursor_fix = SelectCursorFixScript.new()
		select_cursor_fix._g = Global
		select_cursor_fix.initialize()
		select_cursor_fix.start()

	if _debug_enabled("select_highlight_fix"):
		SelectHighlightFixScript = ResourceLoader.load(Global.Root + "scripts/select_highlight_fix.gd", "GDScript", true)
		select_highlight_fix = SelectHighlightFixScript.new()
		select_highlight_fix._g = Global
		select_highlight_fix.initialize()

	if _debug_enabled("drag_select_focus_fix"):
		DragSelectFocusFixScript = ResourceLoader.load(Global.Root + "scripts/drag_select_focus_fix.gd", "GDScript", true)
		drag_select_focus_fix = DragSelectFocusFixScript.new()
		drag_select_focus_fix._g = Global
		drag_select_focus_fix.initialize()

	if _debug_enabled("select_layer_pick_fix"):
		SelectLayerPickFixScript = ResourceLoader.load(Global.Root + "scripts/select_layer_pick_fix.gd", "GDScript", true)
		select_layer_pick_fix = SelectLayerPickFixScript.new()
		select_layer_pick_fix._g = Global
		select_layer_pick_fix.initialize()

	if _debug_enabled("compare_fix"):
		CompareFixScript = ResourceLoader.load(Global.Root + "scripts/compare_fix.gd", "GDScript", true)
		compare_fix = CompareFixScript.new()
		compare_fix._g = Global
		compare_fix.initialize()

	if _debug_enabled("level_settings_fix"):
		LevelSettingsFixScript = ResourceLoader.load(Global.Root + "scripts/level_settings_fix.gd", "GDScript", true)
		level_settings_fix = LevelSettingsFixScript.new()
		level_settings_fix._g = Global
		level_settings_fix.initialize()

	if _debug_enabled("level_settings_extra"):
		LevelSettingsExtraScript = ResourceLoader.load(Global.Root + "scripts/level_settings_extra.gd", "GDScript", true)
		level_settings_extra = LevelSettingsExtraScript.new()
		level_settings_extra._g = Global
		level_settings_extra.initialize()


	if _debug_enabled("ui_util"):
		UIUtilScript = ResourceLoader.load(Global.Root + "scripts/ui_util.gd", "GDScript", true)
		ui_util = UIUtilScript.new()
		ui_util._g = Global

	# select_layer_pick_fix est enregistre plus haut (avant ui_util) : on lui
	# injecte ui_util ici, une fois ce dernier disponible.
	if select_layer_pick_fix != null:
		select_layer_pick_fix.ui_util = ui_util

	if _debug_enabled("path_fix"):
		PathFixScript = ResourceLoader.load(Global.Root + "scripts/path_fix.gd", "GDScript", true)
		path_fix = PathFixScript.new()
		path_fix._g = Global
		path_fix.ui_util = ui_util
		path_fix.initialize()

	if _debug_enabled("wall_fix"):
		WallFixScript = ResourceLoader.load(Global.Root + "scripts/wall_fix.gd", "GDScript", true)
		wall_fix = WallFixScript.new()
		wall_fix._g = Global
		wall_fix.ui_util = ui_util
		wall_fix.initialize()

	if _debug_enabled("portal_flatten_curves"):
		PortalFlattenCurvesScript = ResourceLoader.load(Global.Root + "scripts/portal_flatten_curves.gd", "GDScript", true)
		if PortalFlattenCurvesScript != null:
			portal_flatten_curves = PortalFlattenCurvesScript.new()
			portal_flatten_curves._g = Global
			portal_flatten_curves.ui_util = ui_util
			portal_flatten_curves.initialize()

	if _debug_enabled("light_fix"):
		LightFixScript = ResourceLoader.load(Global.Root + "scripts/light_fix.gd", "GDScript", true)
		light_fix = LightFixScript.new()
		light_fix._g = Global
		light_fix.initialize()

	if _debug_enabled("light_tool_fix"):
		LightToolFixScript = ResourceLoader.load(Global.Root + "scripts/light_tool_fix.gd", "GDScript", true)
		light_tool_fix = LightToolFixScript.new()
		light_tool_fix._g = Global
		light_tool_fix.ui_util = ui_util
		light_tool_fix.initialize()

	if _debug_enabled("asset_cycle"):
		AssetCycleScript = ResourceLoader.load(Global.Root + "scripts/asset_cycle.gd", "GDScript", true)
		asset_cycle = AssetCycleScript.new()
		asset_cycle._g = Global
		asset_cycle.ui_util = ui_util
		asset_cycle.initialize()
		# Give asset_cycle a ref to portal_flatten_curves so it can
		# suppress shift+wheel cycling while a chord is being tuned.
		if portal_flatten_curves != null:
			asset_cycle.portal_flatten_curves = portal_flatten_curves

	if _debug_enabled("rotation_fix"):
		RotationFixScript = ResourceLoader.load(Global.Root + "scripts/rotation_fix.gd", "GDScript", true)
		rotation_fix = RotationFixScript.new()
		rotation_fix._g = Global
		rotation_fix.ui_util = ui_util
		rotation_fix.initialize()

	if _debug_enabled("rotation_snap"):
		RotationSnapScript = ResourceLoader.load(Global.Root + "scripts/rotation_snap.gd", "GDScript", true)
	if RotationSnapScript != null:
		rotation_snap = RotationSnapScript.new()
		rotation_snap._g = Global
		rotation_snap.ui_util = ui_util
		rotation_snap.initialize()
		print("[UnofficialPatch] RotationSnap loaded.")

	if _debug_enabled("transform_box_fix"):
		TransformBoxFixScript = ResourceLoader.load(Global.Root + "scripts/transform_box_fix.gd", "GDScript", true)
		transform_box_fix = TransformBoxFixScript.new()
		transform_box_fix._g = Global
		transform_box_fix.ui_util = ui_util
		transform_box_fix.initialize()

	if _debug_enabled("selection_resize"):
		SelectionResizeScript = ResourceLoader.load(Global.Root + "scripts/selection_resize.gd", "GDScript", true)
		selection_resize = SelectionResizeScript.new()
		selection_resize._g = Global
		selection_resize.ui_util = ui_util
		selection_resize.initialize()

	if _debug_enabled("pan_fix"):
		PanFixScript = ResourceLoader.load(Global.Root + "scripts/pan_fix.gd", "GDScript", true)
		pan_fix = PanFixScript.new()
		pan_fix._g = Global
		pan_fix.ui_util = ui_util
		pan_fix.initialize()

	if _debug_enabled("wall_allow_light"):
		WallAllowLightScript = ResourceLoader.load(Global.Root + "scripts/wall_allow_light.gd", "GDScript", true)
		wall_allow_light = WallAllowLightScript.new()
		wall_allow_light._g = Global
		wall_allow_light.initialize()

	if _debug_enabled("drop_fix"):
		DropFixScript = ResourceLoader.load(Global.Root + "scripts/drop_fix.gd", "GDScript", true)
		drop_fix = DropFixScript.new()
		drop_fix._g = Global
		drop_fix.initialize()


	if _debug_enabled("pattern_fix"):
		PatternFixScript = ResourceLoader.load(Global.Root + "scripts/pattern_fix.gd", "GDScript", true)
		pattern_fix = PatternFixScript.new()
		pattern_fix._g = Global
		pattern_fix.initialize()
	# Give asset_cycle a ref to pattern_fix so it can delegate pattern cycling safely
	if asset_cycle != null:
		asset_cycle.pattern_fix = pattern_fix

	if _debug_enabled("drop_embed"):
		DropEmbedScript = ResourceLoader.load(Global.Root + "scripts/drop_embed.gd", "GDScript", true)
		drop_embed = DropEmbedScript.new()
		drop_embed._g = Global
		drop_embed.initialize()

	if mod_settings == null or mod_settings.is_enabled("favorite_assets") and _debug_enabled("favorites"):
		FavoritesScript = ResourceLoader.load(Global.Root + "scripts/favorites.gd", "GDScript", true)
		favorites = FavoritesScript.new()
		favorites._g = Global
		favorites.initialize()

	if _debug_enabled("pack_cache_fix"):
		PackCacheFixScript = ResourceLoader.load(Global.Root + "scripts/pack_cache_fix.gd", "GDScript", true)
		pack_cache_fix = PackCacheFixScript.new()
		pack_cache_fix._g = Global
		pack_cache_fix.initialize()

	if _debug_enabled("roof_select"):
		RoofSelectScript = ResourceLoader.load(Global.Root + "scripts/roof_select.gd", "GDScript", true)
		roof_select = RoofSelectScript.new()
		roof_select._g = Global
		roof_select.initialize()

	# grid_fix : toujours charge (multi-feature : custom layer + opacity
	# slider + autres). Pas de toggle settings dedie pour eviter de
	# desactiver tout le mod en meme temps que le custom layer.
	_load_grid_fix()

	if mod_settings == null or mod_settings.is_enabled("draw_over_ui"):
		_load_path_draw_fix()

	if mod_settings == null or mod_settings.is_enabled("edit_curves"):
		_load_curve_edits()

	if _debug_enabled("pattern_paint_bucket"):
		PatternPaintBucketScript = ResourceLoader.load(Global.Root + "scripts/pattern_paint_bucket.gd", "GDScript", true)
		pattern_paint_bucket = PatternPaintBucketScript.new()
		pattern_paint_bucket._g = Global
		pattern_paint_bucket.ui_util = ui_util
		pattern_paint_bucket.initialize()

	if _debug_enabled("terrain_paint_bucket"):
		TerrainPaintBucketScript = ResourceLoader.load(Global.Root + "scripts/terrain_paint_bucket.gd", "GDScript", true)
		terrain_paint_bucket = TerrainPaintBucketScript.new()
		terrain_paint_bucket._g = Global
		terrain_paint_bucket.ui_util = ui_util
		terrain_paint_bucket.initialize()

	if _debug_enabled("terrain_slots_extended"):
		TerrainSlotsExtendedScript = ResourceLoader.load(Global.Root + "scripts/terrain_slots_extended.gd", "GDScript", true)
		terrain_slots_extended = TerrainSlotsExtendedScript.new()
		terrain_slots_extended._g = Global
		terrain_slots_extended.start()
		# Let it defer to the terrain paint bucket (Square/Bucket modes own the click).
		if terrain_paint_bucket != null:
			terrain_slots_extended.terrain_paint_bucket = terrain_paint_bucket

	if _debug_enabled("prefabs_clone_fix"):
		PrefabsCloneFixScript = ResourceLoader.load(Global.Root + "scripts/prefabs_clone_fix.gd", "GDScript", true)
		prefabs_clone_fix = PrefabsCloneFixScript.new()
		prefabs_clone_fix._g = Global
		prefabs_clone_fix.initialize()

	if mod_settings == null or mod_settings.is_enabled("prefab_preview") and _debug_enabled("prefabs_thumbnails"):
		PrefabsThumbnailsScript = ResourceLoader.load(Global.Root + "scripts/prefabs_thumbnails.gd", "GDScript", true)
		prefabs_thumbnails = PrefabsThumbnailsScript.new()
		prefabs_thumbnails._g = Global
		prefabs_thumbnails.initialize()

	if mod_settings == null or mod_settings.is_enabled("save_reminder"):
		_load_save_reminder()

	if _debug_enabled("text_tool_fix"):
		TextToolFixScript = ResourceLoader.load(Global.Root + "scripts/text_tool_fix.gd", "GDScript", true)
		text_tool_fix = TextToolFixScript.new()
		text_tool_fix._g = Global
		text_tool_fix.initialize()

	if _debug_enabled("text_transform"):
		TextTransformScript = ResourceLoader.load(Global.Root + "scripts/text_transform.gd", "GDScript", true)
		text_transform = TextTransformScript.new()
		text_transform._g = Global
		text_transform.initialize()


	if _debug_enabled("text_select_style"):
		TextSelectStyleScript = ResourceLoader.load(Global.Root + "scripts/text_select_style.gd", "GDScript", true)
		text_select_style = TextSelectStyleScript.new()
		text_select_style._g = Global
		text_select_style.text_transform = text_transform
		text_select_style.initialize()

	if _debug_enabled("scale_unlock"):
		ScaleUnlockScript = ResourceLoader.load(Global.Root + "scripts/scale_unlock.gd", "GDScript", true)
		scale_unlock = ScaleUnlockScript.new()
		scale_unlock._g = Global
		scale_unlock.ui_util = ui_util
		scale_unlock.initialize()

	if mod_settings == null or mod_settings.is_enabled("picker_tool_enter"):
		_load_eyedropper()

	if _debug_enabled("free_transform"):
		FreeTransformScript = ResourceLoader.load(Global.Root + "scripts/free_transform.gd", "GDScript", true)
		free_transform = FreeTransformScript.new()
		free_transform._g = Global
		free_transform.initialize()

	if _debug_enabled("free_transform_data_manager"):
		FreeTransformDataManagerScript = ResourceLoader.load(Global.Root + "scripts/free_transform_data_manager.gd", "GDScript", true)
		free_transform_data_manager = FreeTransformDataManagerScript.new()
		free_transform_data_manager._g = Global
		free_transform_data_manager._free_transform = free_transform
		free_transform_data_manager.initialize()

	if mod_settings == null or mod_settings.is_enabled("better_selection"):
		_load_no_micro_drag()

	if _debug_enabled("window_transparency_fix"):
		WindowTransparencyFixScript = ResourceLoader.load(Global.Root + "scripts/window_transparency_fix.gd", "GDScript", true)
		window_transparency_fix = WindowTransparencyFixScript.new()
		window_transparency_fix._g = Global
		window_transparency_fix.initialize()

	if _debug_enabled("portal_reposition_ui"):
		PortalReposUIScript = ResourceLoader.load(Global.Root + "scripts/portal_reposition_ui.gd", "GDScript", true)
		portal_reposition_ui = PortalReposUIScript.new()
		portal_reposition_ui._g = Global
		portal_reposition_ui.initialize()
	# Sync l'etat initial avec le toggle "Reposition Portals" (qui pilote
	# reposition_enabled). Setter directement (pas via set_enabled) car les
	# boutons n'existent pas encore au boot — ils seront crees plus tard
	# par wall_tool_portal_fix avec la valeur courante de reposition_enabled.
	if mod_settings != null:
		portal_reposition_ui.reposition_enabled = mod_settings.is_enabled("reposition_portals")

	WallToolPortalFixScript = ResourceLoader.load(Global.Root + "scripts/wall_tool_portal_fix.gd", "GDScript", true)
	wall_tool_portal_fix = WallToolPortalFixScript.new()
	wall_tool_portal_fix._g = Global
	wall_tool_portal_fix.ui = portal_reposition_ui  # mettre null pour vanilla
	wall_tool_portal_fix.initialize()


	if mod_settings == null or mod_settings.is_enabled("walls_paths_overlay") and _debug_enabled("overlay_tool"):
		OverlayToolScript = ResourceLoader.load(Global.Root + "scripts/overlay_tool.gd", "GDScript", true)
		overlay_tool = OverlayToolScript.new()
		overlay_tool._g = Global
		overlay_tool.ui_util = ui_util
		overlay_tool.path_fix = path_fix
		overlay_tool.wall_fix = wall_fix
		overlay_tool.initialize()
		path_fix.overlay_tool = overlay_tool
		if no_micro_drag != null:
			no_micro_drag.overlay_tool = overlay_tool

	if mod_settings == null or mod_settings.is_enabled("wall_move_transform"):
		_load_wall_move()

	if mod_settings == null or mod_settings.is_enabled("zoom_unlock"):
		_load_zoom_unlock()

	if _debug_enabled("trace_extended"):
		TraceExtendedScript = ResourceLoader.load(Global.Root + "scripts/trace_extended.gd", "GDScript", true)
		trace_extended = TraceExtendedScript.new()
		trace_extended._g = Global
		trace_extended.ui_util = ui_util
		trace_extended.initialize()

	if mod_settings == null or mod_settings.is_enabled("collapsable_controls"):
		_load_select_collapse()

	if mod_settings == null or mod_settings.is_enabled("rotation_slider"):
		_load_select_rotation()

	if _debug_enabled("popup_blur"):
		PopupBlurScript = ResourceLoader.load(Global.Root + "scripts/popup_blur.gd", "GDScript", true)
	if PopupBlurScript != null and (mod_settings == null or mod_settings.is_enabled("blurred_popup_background")):
		popup_blur = PopupBlurScript.new()
		popup_blur._g = Global
		popup_blur.initialize()
	drop_embed.popup_blur = popup_blur
	if save_reminder != null:
		save_reminder.popup_blur = popup_blur

	# UI Rescaler — per-category UI scale sliders (Settings tool)
	if _debug_enabled("ui_rescaler"):
		UIRescalerScript = ResourceLoader.load(Global.Root + "scripts/ui_rescaler.gd", "GDScript", true)
	if UIRescalerScript != null:
		ui_rescaler = UIRescalerScript.new()
		ui_rescaler._g = Global
		ui_rescaler.ui_util = ui_util
		ui_rescaler.initialize()
		print("[UnofficialPatch] UIRescaler loaded.")

	# GridRuler — Photoshop-like grid ruler overlay (toggle with CTRL+R)
	if mod_settings == null or mod_settings.is_enabled("ruler_guide"):
		_load_grid_ruler()

	# SelectFilterBar — repositionable filter-type checkbox bar (SelectTool)
	if mod_settings == null or mod_settings.is_enabled("select_filter_bar"):
		_load_select_filter_bar()

	# GroupAssets — Group/Ungroup sans prefab
	if mod_settings == null or mod_settings.is_enabled("group_assets"):
		_load_group_assets()

	# RightClickUtil — menu contextuel centralisé pour le SelectTool
	if _debug_enabled("right_click_util"):
		RightClickUtilScript = ResourceLoader.load(Global.Root + "scripts/right_click_util.gd", "GDScript", true)
	if RightClickUtilScript != null:
		right_click_util = RightClickUtilScript.new()
		right_click_util._g = Global
		right_click_util.ui_util = ui_util
		if favorites != null:
			right_click_util.register(favorites)
		if group_assets != null:
			right_click_util.register(group_assets)
		# FTContext : toujours charge, fournit l'item "Free Transform" du
		# menu contextuel meme si Favorite Assets est desactive.
		var FTContextScript = ResourceLoader.load(Global.Root + "scripts/ft_context.gd", "GDScript", true)
		if FTContextScript != null:
			ft_context = FTContextScript.new()
			ft_context._g = Global
			ft_context.free_transform = free_transform
			ft_context.initialize()
			right_click_util.register(ft_context)
		# RotateContext : ajoute "Rotate 90°" au menu contextuel et neutralise
		# la rotation auto sur clic droit du mod tiers RotateAndJiggle (Jiggle.gd),
		# qui se declenchait en meme temps que notre menu.
		var RotateContextScript = ResourceLoader.load(Global.Root + "scripts/rotate_context.gd", "GDScript", true)
		if RotateContextScript != null:
			rotate_context = RotateContextScript.new()
			rotate_context._g = Global
			rotate_context.initialize()
			right_click_util.register(rotate_context)
		# PatternScaleBake : test mod — bakes a PatternShape's node.scale
		# into its polygon so DD's snap pipeline (which uses node.position
		# as reference) sees corner positions that match the rendered ones.
		# Manually invoked via right-click; visual rendering may or may
		# not be preserved depending on DD's pattern shader.
		if _debug_enabled("pattern_scale_bake"):
			var PatternScaleBakeScript = ResourceLoader.load(Global.Root + "scripts/pattern_scale_bake.gd", "GDScript", true)
			if PatternScaleBakeScript != null:
				var pattern_scale_bake = PatternScaleBakeScript.new()
				pattern_scale_bake._g = Global
				pattern_scale_bake.ui_util = ui_util
				pattern_scale_bake.initialize()
				right_click_util.register(pattern_scale_bake)
		right_click_util.initialize()
		print("[UnofficialPatch] RightClickUtil loaded.")

	# MapExplorer — Explore saved maps with thumbnails
	if mod_settings == null or mod_settings.is_enabled("map_gallery"):
		_load_map_explorer()

	# ArcDraw — Trace des arcs de cercle (90°/180°) avec Ctrl+Molette
	if mod_settings == null or mod_settings.is_enabled("arc_draw"):
		_load_arc_draw()

	# AxisLock — contrainte d'axe Photoshop (Ctrl/Cmd) en draw/edit points
	if mod_settings == null or mod_settings.is_enabled("axis_lock"):
		_load_axis_lock()
	
	# EditPointsUndo — enregistre dans l'historique les modifications faites
	# en mode Edit Points sur un Pathway (drag, ajout, suppression de point).
	# Injecté avec les refs aux mods qui mutent aussi les paths, pour
	# coordonner et éviter les double records.
	if _debug_enabled("edit_points_undo"):
		EditPointsUndoScript = ResourceLoader.load(Global.Root + "scripts/edit_points_undo.gd", "GDScript", true)
	if EditPointsUndoScript != null:
		edit_points_undo = EditPointsUndoScript.new()
		edit_points_undo._g = Global
		edit_points_undo.path_curve_edit = path_curve_edit
		edit_points_undo.arc_draw = arc_draw
		edit_points_undo.initialize()
		print("[UnofficialPatch] EditPointsUndo loaded.")
	
	# PreserveSelectionUndo — restore SelectTool selection after undo/redo
	# so the user doesn't have to re-click the items they were working on.
	if mod_settings == null or mod_settings.is_enabled("undo_preserves_selection"):
		_load_preserve_selection_undo()

	# Charger SplitPath uniquement si pas deja charge comme mod standalone
	var _sp_already_loaded = false  # priorite a notre version amelioree
	if _sp_already_loaded:
		print("[UnofficialPatch] SplitPath already loaded as standalone mod, skipping.")
	else:
		if _debug_enabled("SplitPath"):
			SplitPathScript = ResourceLoader.load(Global.Root + "scripts/SplitPath.gd", "GDScript", true)
		if SplitPathScript != null:
			split_path = SplitPathScript.new()
			split_path._g = Global
			split_path.start()
			print("[UnofficialPatch] SplitPath loaded.")
		else:
			print("[UnofficialPatch] SplitPath.gd not found, skipping.")

	# MergePath — merges two selected Pathways sharing an endpoint (like vanilla Merge Walls)
	var _mp_already_loaded = false  # priorite a notre version amelioree
	if _mp_already_loaded:
		print("[UnofficialPatch] MergePaths already loaded as standalone mod, skipping.")
	else:
		if _debug_enabled("merge_path"):
			MergePathScript = ResourceLoader.load(Global.Root + "scripts/merge_path.gd", "GDScript", true)
		if MergePathScript != null:
			merge_path = MergePathScript.new()
			merge_path._g = Global
			merge_path.initialize()
			print("[UnofficialPatch] MergePath loaded.")
		else:
			print("[UnofficialPatch] merge_path.gd not found, skipping.")

	# DragSelectWalls — toujours charge si pas pris par un mod externe.
	# Le drag-select des walls ne depend PAS du toggle "Move, Transform
	# and Copy Walls" : on veut pouvoir drag-selectionner les walls meme
	# quand le transform/move/copy est desactive. Le mod peut quand meme
	# etre desactive individuellement via le panel Mod Debug.
	var _dsw_already_loaded = false  # priorite a notre version amelioree
	if _dsw_already_loaded:
		print("[UnofficialPatch] DragSelectWalls already loaded as standalone mod, skipping.")
	else:
		_load_drag_select_walls()

	# ExportTraceImage - toujours charger notre version (elle prend le relais sur le standalone)
	if _debug_enabled("ExportTraceImage"):
		ExportTraceImageScript = ResourceLoader.load(Global.Root + "scripts/ExportTraceImage.gd", "GDScript", true)
	if ExportTraceImageScript != null:
		export_trace_image = ExportTraceImageScript.new()
		export_trace_image._g = Global
		_eti_pending_start = true
		print("[UnofficialPatch] ExportTraceImage pending start.")
	else:
		print("[UnofficialPatch] ExportTraceImage.gd not found, skipping.")

	# ToolHint — EXPLORATION only, remove once hint bar path is identified
	if mod_settings == null or mod_settings.is_enabled("tool_hints"):
		_load_tool_hint()

	# EditPointsToggle — bascule Edit Points <-> derniere shape dans FloorShapeTool et PatternShapeTool
	if _debug_enabled("edit_points_toggle"):
		EditPointsToggleScript = ResourceLoader.load(Global.Root + "scripts/edit_points_toggle.gd", "GDScript", true)
	if EditPointsToggleScript != null:
		edit_points_toggle = EditPointsToggleScript.new()
		edit_points_toggle._g = Global
		edit_points_toggle.pattern_paint_bucket = pattern_paint_bucket
		edit_points_toggle.initialize()
		print("[UnofficialPatch] EditPointsToggle loaded.")

	# Build the Mod Settings panel once every toggle has been registered.
	if mod_settings != null:
		mod_settings.build_panel()
	# Build the Mod Debug panel (full mod list).
	if debug_settings != null:
		debug_settings.build_panel()
		# Visibilite initiale du panel debug : suit "Display Debug Panel".
		# Sans ca, le panel debug serait visible au boot meme quand le
		# toggle est OFF en disque (parce qu'on charge toujours le mod).
		if mod_settings != null and not mod_settings.is_enabled("display_debug_tool"):
			debug_settings.set_visible(false)
		# Sync initial bidirectionnel pour aligner les deux JSON :
		# 1) settings -> debug : pour chaque toggle settings dont la valeur
		#    est false, force OFF les mods debug correspondants. Couvre le
		#    cas ou l'utilisateur a fait Uncheck All sur settings au run
		#    precedent (les deux JSON deviennent coherents au prochain boot).
		# 2) debug -> settings : pour chaque settings_id qui a au moins un
		#    mod debug OFF, lock le toggle settings correspondant.
		# L'ordre est important : d'abord settings -> debug (pour aligner
		# l'etat debug en memoire avant le sync inverse).
		if mod_settings != null:
			for sid in debug_settings._settings_id_to_mod_ids:
				var sval = mod_settings.is_enabled(sid)
				if not sval:
					debug_settings.on_setting_changed(sid, false)
		for sid in debug_settings._settings_id_to_mod_ids:
			debug_settings._sync_to_mod_settings(sid)


# ── ModSettings hot load/unload helpers ──────────────────────────────────────

func _load_save_reminder() -> void:
	if save_reminder != null:
		return
	if _debug_enabled("save_reminder"):
		SaveReminderScript = ResourceLoader.load(Global.Root + "scripts/save_reminder.gd", "GDScript", true)
	if SaveReminderScript == null:
		return
	save_reminder = SaveReminderScript.new()
	save_reminder._g = Global
	if popup_blur != null:
		save_reminder.popup_blur = popup_blur
	# Injection welcome_popup : save_reminder differe son timer tant que
	# le welcome popup est encore affiche (sinon les deux popups se
	# chevauchent et bloquent l'ecran).
	save_reminder.welcome_popup = welcome_popup
	save_reminder.initialize()
	print("[UnofficialPatch] SaveReminder loaded.")


func _unload_save_reminder() -> void:
	if save_reminder == null:
		return
	if save_reminder.has_method("cleanup"):
		save_reminder.cleanup()
	save_reminder = null
	print("[UnofficialPatch] SaveReminder unloaded.")


func _on_save_reminder_toggled(enabled) -> void:
	if enabled:
		_load_save_reminder()
	else:
		_unload_save_reminder()


func _load_zoom_unlock() -> void:
	if zoom_unlock != null:
		return
	if _debug_enabled("zoom_unlock"):
		ZoomUnlockScript = ResourceLoader.load(Global.Root + "scripts/zoom_unlock.gd", "GDScript", true)
	if ZoomUnlockScript == null:
		return
	zoom_unlock = ZoomUnlockScript.new()
	zoom_unlock._g = Global
	zoom_unlock.ui_util = ui_util
	zoom_unlock.initialize()
	print("[UnofficialPatch] ZoomUnlock loaded.")


func _unload_zoom_unlock() -> void:
	if zoom_unlock == null:
		return
	if zoom_unlock.has_method("cleanup"):
		zoom_unlock.cleanup()
	zoom_unlock = null
	print("[UnofficialPatch] ZoomUnlock unloaded.")


func _on_zoom_unlock_toggled(enabled) -> void:
	if enabled:
		_load_zoom_unlock()
	else:
		_unload_zoom_unlock()


func _load_map_explorer() -> void:
	if map_explorer != null:
		return
	if _debug_enabled("map_explorer"):
		MapExplorerScript = ResourceLoader.load(Global.Root + "scripts/map_explorer.gd", "GDScript", true)
	if MapExplorerScript == null:
		return
	map_explorer = MapExplorerScript.new()
	map_explorer._g = Global
	map_explorer.initialize()
	print("[UnofficialPatch] MapExplorer loaded.")


func _unload_map_explorer() -> void:
	if map_explorer == null:
		return
	if map_explorer.has_method("cleanup"):
		map_explorer.cleanup()
	map_explorer = null
	print("[UnofficialPatch] MapExplorer unloaded.")


func _on_map_gallery_toggled(enabled) -> void:
	if enabled:
		_load_map_explorer()
	else:
		_unload_map_explorer()


func _on_create_pack_from_favorites_toggled(enabled) -> void:
	# Affiche un warning uniquement quand on passe OFF -> ON, pour rappeler
	# que le pack genere est a usage personnel et ne doit pas etre redistribue.
	if enabled:
		_show_pack_redistribution_warning()


func _show_pack_redistribution_warning() -> void:
	var dialog := WindowDialog.new()
	dialog.window_title = "Unofficial Patch — Warning"
	dialog.popup_exclusive = true

	var margin := MarginContainer.new()
	margin.set("custom_constants/margin_left", 18)
	margin.set("custom_constants/margin_right", 18)
	margin.set("custom_constants/margin_top", 14)
	margin.set("custom_constants/margin_bottom", -10)
	margin.anchor_right = 1.0
	margin.anchor_bottom = 1.0
	dialog.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.set("custom_constants/separation", 15)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "Personal Use Only"
	title.align = Label.ALIGN_CENTER
	var base_font = title.get_font("font")
	if base_font != null and base_font is DynamicFont:
		var big := DynamicFont.new()
		big.font_data = base_font.font_data
		big.size = base_font.size + 6
		title.add_font_override("font", big)
	vbox.add_child(title)

	var body := RichTextLabel.new()
	body.bbcode_enabled = true
	body.fit_content_height = true
	body.scroll_active = false
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.rect_min_size = Vector2(520, 0)
	body.bbcode_text = (
		"[fill]Next time you update your favorites list, all the content will "
		+ "be copied into a [b].dungeondraft_pack[/b] file that you can use "
		+ "independently from the original packs.\n\n"
		+ "This pack is for [b][color=#FFB454]personal use only[/color][/b]. "
		+ "[b]Any redistribution is strictly forbidden[/b], as it may contain "
		+ "assets you do not have the right to share.\n\n"
		+ "By enabling this option you agree to keep the generated pack "
		+ "private.[/fill]"
	)
	vbox.add_child(body)

	vbox.add_child(HSeparator.new())

	var footer := HBoxContainer.new()
	footer.set("custom_constants/separation", 12)
	footer.alignment = BoxContainer.ALIGN_CENTER
	var ok_btn := Button.new()
	ok_btn.text = "I understand"
	ok_btn.rect_min_size = Vector2(250, 0)
	# Contour blanc 1px : on override les styleboxes normal/hover/pressed
	# avec un StyleBoxFlat (fond sombre semi-transparent + bordure blanche).
	for state in ["normal", "hover", "pressed"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.15, 0.14, 0.13, 0.6 if state == "normal" else 0.85)
		sb.border_color = Color(1, 1, 1, 1)
		sb.set_border_width_all(1)
		sb.content_margin_left = 10
		sb.content_margin_right = 10
		sb.content_margin_top = 6
		sb.content_margin_bottom = 6
		ok_btn.add_stylebox_override(state, sb)
	ok_btn.connect("pressed", dialog, "hide")
	footer.add_child(ok_btn)
	vbox.add_child(footer)

	dialog.connect("popup_hide", dialog, "queue_free")

	var windows = Global.Editor.get_node_or_null("Windows") if Global.Editor else null
	if windows != null:
		windows.add_child(dialog)
	elif Global.World != null and is_instance_valid(Global.World):
		Global.World.get_tree().root.add_child(dialog)
	else:
		return

	yield(Global.World.get_tree(), "idle_frame")
	if not is_instance_valid(dialog):
		return
	var content_min = margin.get_combined_minimum_size()
	var title_h = dialog.get_constant("title_height", "WindowDialog")
	var w = max(540.0, content_min.x)
	var h = content_min.y + title_h
	dialog.popup_centered(Vector2(w, h))


func _on_map_resize_target_size_toggled(enabled) -> void:
	if map_resize_fix != null and map_resize_fix.has_method("set_target_size_visible"):
		map_resize_fix.set_target_size_visible(enabled)


# --- Eyedropper / Picker Tool ENTER ---
func _load_eyedropper() -> void:
	if eyedropper != null:
		return
	if _debug_enabled("eyedropper"):
		EyedropperScript = ResourceLoader.load(Global.Root + "scripts/eyedropper.gd", "GDScript", true)
	if EyedropperScript == null:
		return
	eyedropper = EyedropperScript.new()
	eyedropper._g = Global
	eyedropper.scale_unlock = scale_unlock
	eyedropper._main = self
	eyedropper.ui_util = ui_util
	eyedropper.initialize()
	print("[UnofficialPatch] Eyedropper loaded.")


func _unload_eyedropper() -> void:
	if eyedropper == null:
		return
	if eyedropper.has_method("cleanup"):
		eyedropper.cleanup()
	eyedropper = null
	print("[UnofficialPatch] Eyedropper unloaded.")


func _on_picker_tool_enter_toggled(enabled) -> void:
	if enabled:
		_load_eyedropper()
	else:
		_unload_eyedropper()


# --- NoMicroDrag / Better Selection ---
func _load_no_micro_drag() -> void:
	if no_micro_drag != null:
		return
	if _debug_enabled("no_micro_drag"):
		NoMicroDragScript = ResourceLoader.load(Global.Root + "scripts/no_micro_drag.gd", "GDScript", true)
	if NoMicroDragScript == null:
		return
	no_micro_drag = NoMicroDragScript.new()
	no_micro_drag._g = Global
	no_micro_drag.initialize()
	# Re-wire les refs croisees si les autres mods sont la.
	if overlay_tool != null:
		no_micro_drag.overlay_tool = overlay_tool
	if wall_move != null:
		no_micro_drag.wall_move = wall_move
	print("[UnofficialPatch] NoMicroDrag loaded.")


func _unload_no_micro_drag() -> void:
	if no_micro_drag == null:
		return
	if no_micro_drag.has_method("cleanup"):
		no_micro_drag.cleanup()
	no_micro_drag = null
	print("[UnofficialPatch] NoMicroDrag unloaded.")


func _on_better_selection_toggled(enabled) -> void:
	if enabled:
		_load_no_micro_drag()
	else:
		_unload_no_micro_drag()


# --- SelectCollapse / Collapsable Controls ---
func _load_select_collapse() -> void:
	if select_collapse != null:
		return
	if _debug_enabled("select_collapse"):
		SelectCollapseScript = ResourceLoader.load(Global.Root + "scripts/select_collapse.gd", "GDScript", true)
	if SelectCollapseScript == null:
		return
	select_collapse = SelectCollapseScript.new()
	select_collapse._g = Global
	select_collapse.initialize()
	print("[UnofficialPatch] SelectCollapse loaded.")


func _unload_select_collapse() -> void:
	if select_collapse == null:
		return
	if select_collapse.has_method("cleanup"):
		select_collapse.cleanup()
	select_collapse = null
	print("[UnofficialPatch] SelectCollapse unloaded.")


func _on_collapsable_controls_toggled(enabled) -> void:
	if enabled:
		_load_select_collapse()
	else:
		_unload_select_collapse()


# --- SelectRotation / Rotation Slider ---
func _load_select_rotation() -> void:
	if select_rotation != null:
		return
	if _debug_enabled("select_rotation"):
		SelectRotationScript = ResourceLoader.load(Global.Root + "scripts/select_rotation.gd", "GDScript", true)
	if SelectRotationScript == null:
		return
	select_rotation = SelectRotationScript.new()
	select_rotation._g = Global
	select_rotation.ui_util = ui_util
	select_rotation.rotation_snap = rotation_snap
	select_rotation.initialize()
	print("[UnofficialPatch] SelectRotation loaded.")


func _unload_select_rotation() -> void:
	if select_rotation == null:
		return
	if select_rotation.has_method("cleanup"):
		select_rotation.cleanup()
	select_rotation = null
	print("[UnofficialPatch] SelectRotation unloaded.")


func _on_rotation_slider_toggled(enabled) -> void:
	if enabled:
		_load_select_rotation()
	else:
		_unload_select_rotation()


# --- PreserveSelectionUndo / Undo Preserves Selection ---
func _load_preserve_selection_undo() -> void:
	if preserve_selection_undo != null:
		return
	if _debug_enabled("preserve_selection_undo"):
		PreserveSelectionUndoScript = ResourceLoader.load(Global.Root + "scripts/preserve_selection_undo.gd", "GDScript", true)
	if PreserveSelectionUndoScript == null:
		return
	preserve_selection_undo = PreserveSelectionUndoScript.new()
	preserve_selection_undo._g = Global
	preserve_selection_undo.initialize()
	print("[UnofficialPatch] PreserveSelectionUndo loaded.")


func _unload_preserve_selection_undo() -> void:
	if preserve_selection_undo == null:
		return
	if preserve_selection_undo.has_method("cleanup"):
		preserve_selection_undo.cleanup()
	preserve_selection_undo = null
	print("[UnofficialPatch] PreserveSelectionUndo unloaded.")


func _on_undo_preserves_selection_toggled(enabled) -> void:
	if enabled:
		_load_preserve_selection_undo()
	else:
		_unload_preserve_selection_undo()


# --- GroupAssets ---
func _load_group_assets() -> void:
	if group_assets != null:
		return
	if _debug_enabled("group_assets"):
		GroupAssetsScript = ResourceLoader.load(Global.Root + "scripts/group_assets.gd", "GDScript", true)
	if GroupAssetsScript == null:
		return
	group_assets = GroupAssetsScript.new()
	group_assets._g = Global
	group_assets.initialize()
	# Re-register avec le menu contextuel s'il est deja la (hot-toggle ON
	# apres le boot initial — ordre normal : group_assets est registered
	# au boot avant right_click_util.initialize, mais en hot-toggle on est
	# post-boot donc on register a chaud).
	if right_click_util != null and right_click_util.has_method("register"):
		right_click_util.register(group_assets)
	print("[UnofficialPatch] GroupAssets loaded.")


func _unload_group_assets() -> void:
	if group_assets == null:
		return
	if right_click_util != null and right_click_util.has_method("unregister"):
		right_click_util.unregister(group_assets)
	if group_assets.has_method("cleanup"):
		group_assets.cleanup()
	group_assets = null
	print("[UnofficialPatch] GroupAssets unloaded.")


func _on_group_assets_toggled(enabled) -> void:
	if enabled:
		_load_group_assets()
	else:
		_unload_group_assets()


# --- GridFix / Custom Grid Layer ---
func _load_grid_fix() -> void:
	if grid_fix != null:
		return
	if _debug_enabled("grid_fix"):
		GridFixScript = ResourceLoader.load(Global.Root + "scripts/grid_fix.gd", "GDScript", true)
	if GridFixScript == null:
		return
	grid_fix = GridFixScript.new()
	grid_fix._g = Global
	grid_fix.initialize()
	print("[UnofficialPatch] GridFix loaded.")


func _unload_grid_fix() -> void:
	if grid_fix == null:
		return
	if grid_fix.has_method("cleanup"):
		grid_fix.cleanup()
	grid_fix = null
	print("[UnofficialPatch] GridFix unloaded.")


func _on_custom_grid_layer_toggled(enabled) -> void:
	if enabled:
		_load_grid_fix()
	else:
		_unload_grid_fix()


# --- PathDrawFix / Draw Over UI ---
# Permet a path/wall/pattern (et autres tools de dessin) de continuer a
# tracker la souris quand le curseur sort du viewport, pour pouvoir
# dessiner par-dessus l'UI.
func _load_path_draw_fix() -> void:
	if path_draw_fix != null:
		return
	if _debug_enabled("path_draw_fix"):
		PathDrawFixScript = ResourceLoader.load(Global.Root + "scripts/path_draw_fix.gd", "GDScript", true)
	if PathDrawFixScript == null:
		return
	path_draw_fix = PathDrawFixScript.new()
	path_draw_fix._g = Global
	path_draw_fix.initialize()
	print("[UnofficialPatch] PathDrawFix loaded.")


func _unload_path_draw_fix() -> void:
	if path_draw_fix == null:
		return
	if path_draw_fix.has_method("cleanup"):
		path_draw_fix.cleanup()
	path_draw_fix = null
	print("[UnofficialPatch] PathDrawFix unloaded.")


func _on_draw_over_ui_toggled(enabled) -> void:
	if enabled:
		_load_path_draw_fix()
	else:
		_unload_path_draw_fix()


# --- ArcDraw / Arc [Curve+Ctrl] ---
func _load_arc_draw() -> void:
	if arc_draw != null:
		return
	if _debug_enabled("arc_draw"):
		ArcDrawScript = ResourceLoader.load(Global.Root + "scripts/arc_draw.gd", "GDScript", true)
	if ArcDrawScript == null:
		return
	arc_draw = ArcDrawScript.new()
	arc_draw._g = Global
	arc_draw.path_curve_edit = path_curve_edit
	arc_draw.wall_curve_edit = wall_curve_edit
	arc_draw.pattern_curve_edit = pattern_curve_edit
	arc_draw.initialize()
	print("[UnofficialPatch] ArcDraw loaded.")


func _unload_arc_draw() -> void:
	if arc_draw == null:
		return
	if arc_draw.has_method("cleanup"):
		arc_draw.cleanup()
	arc_draw = null
	print("[UnofficialPatch] ArcDraw unloaded.")


func _on_arc_draw_toggled(enabled) -> void:
	if enabled:
		_load_arc_draw()
	else:
		_unload_arc_draw()


# --- AxisLock / Axis constraint [Draw or Edit Points + Ctrl] ---
func _load_axis_lock() -> void:
	if axis_lock != null:
		return
	if _debug_enabled("axis_lock"):
		AxisLockScript = ResourceLoader.load(Global.Root + "scripts/axis_lock.gd", "GDScript", true)
	if AxisLockScript == null:
		return
	axis_lock = AxisLockScript.new()
	axis_lock._g = Global
	axis_lock.initialize()
	print("[UnofficialPatch] AxisLock loaded.")


func _unload_axis_lock() -> void:
	if axis_lock == null:
		return
	if axis_lock.has_method("cleanup"):
		axis_lock.cleanup()
	axis_lock = null
	print("[UnofficialPatch] AxisLock unloaded.")


func _on_axis_lock_toggled(enabled) -> void:
	if enabled:
		_load_axis_lock()
	else:
		_unload_axis_lock()


# --- Free Transform : runtime gate du context-menu + hide/show du
# bouton FT du SelectTool panel. ft_context.gd reste toujours charge,
# c'est lui qui implemente les deux. ---
func _on_free_transform_toggled(enabled) -> void:
	if ft_context != null and ft_context.has_method("set_button_visible"):
		ft_context.set_button_visible(enabled)


# --- Curve Edits (path/wall/pattern) hot-toggle ---
func _load_curve_edits() -> void:
	if path_curve_edit == null:
		if _debug_enabled("path_curve_edit"):
			PathCurveEditScript = ResourceLoader.load(Global.Root + "scripts/path_curve_edit.gd", "GDScript", true)
		if PathCurveEditScript != null:
			path_curve_edit = PathCurveEditScript.new()
			path_curve_edit._g = Global
			path_curve_edit.initialize()
	if wall_curve_edit == null:
		if _debug_enabled("wall_curve_edit"):
			WallCurveEditScript = ResourceLoader.load(Global.Root + "scripts/wall_curve_edit.gd", "GDScript", true)
		if WallCurveEditScript != null:
			wall_curve_edit = WallCurveEditScript.new()
			wall_curve_edit._g = Global
			wall_curve_edit.initialize()
	if pattern_curve_edit == null:
		if _debug_enabled("pattern_curve_edit"):
			PatternCurveEditScript = ResourceLoader.load(Global.Root + "scripts/pattern_curve_edit.gd", "GDScript", true)
		if PatternCurveEditScript != null:
			pattern_curve_edit = PatternCurveEditScript.new()
			pattern_curve_edit._g = Global
			pattern_curve_edit.initialize()
	# Re-wire les refs croisees (arc_draw partage les 3 curve_edits, et
	# edit_points_undo aussi).
	if arc_draw != null:
		arc_draw.path_curve_edit = path_curve_edit
		arc_draw.wall_curve_edit = wall_curve_edit
		arc_draw.pattern_curve_edit = pattern_curve_edit
	if edit_points_undo != null:
		edit_points_undo.path_curve_edit = path_curve_edit
	print("[UnofficialPatch] CurveEdits loaded.")


func _unload_curve_edits() -> void:
	if path_curve_edit != null and path_curve_edit.has_method("cleanup"):
		path_curve_edit.cleanup()
	path_curve_edit = null
	if wall_curve_edit != null and wall_curve_edit.has_method("cleanup"):
		wall_curve_edit.cleanup()
	wall_curve_edit = null
	if pattern_curve_edit != null and pattern_curve_edit.has_method("cleanup"):
		pattern_curve_edit.cleanup()
	pattern_curve_edit = null
	# Clear les refs croisees.
	if arc_draw != null:
		arc_draw.path_curve_edit = null
		arc_draw.wall_curve_edit = null
		arc_draw.pattern_curve_edit = null
	if edit_points_undo != null:
		edit_points_undo.path_curve_edit = null
	print("[UnofficialPatch] CurveEdits unloaded.")


func _on_edit_curves_toggled(enabled) -> void:
	if enabled:
		_load_curve_edits()
	else:
		_unload_curve_edits()


# --- Wall Move + DragSelectWalls hot-toggle ---
# Les deux mods bossent ensemble pour permettre de bouger les walls dans
# le SelectTool (clic-drag d'un wall via wall_move, et inclusion des walls
# dans les multi-selections via DragSelectWalls). On les active/desactive
# ensemble derriere le meme toggle.
func _load_wall_move() -> void:
	if wall_move == null:
		if _debug_enabled("wall_move"):
			WallMoveScript = ResourceLoader.load(Global.Root + "scripts/wall_move.gd", "GDScript", true)
		if WallMoveScript != null:
			wall_move = WallMoveScript.new()
			wall_move._g = Global
			wall_move.overlay_tool = overlay_tool
			wall_move.ui_util = ui_util
			wall_move.initialize()
			# Re-wire vers no_micro_drag s'il est la.
			if no_micro_drag != null:
				no_micro_drag.wall_move = wall_move
			print("[UnofficialPatch] WallMove loaded.")


func _unload_wall_move() -> void:
	if wall_move != null:
		if wall_move.has_method("cleanup"):
			wall_move.cleanup()
		wall_move = null
		# Clear ref dans no_micro_drag.
		if no_micro_drag != null:
			no_micro_drag.wall_move = null
		print("[UnofficialPatch] WallMove unloaded.")


func _load_drag_select_walls() -> void:
	if drag_select_walls != null:
		return
	# Priorite a notre version amelioree : on ne cede plus a uchideshi34.
	if _debug_enabled("DragSelectWalls"):
		DragSelectWallsScript = ResourceLoader.load(Global.Root + "scripts/DragSelectWalls.gd", "GDScript", true)
	if DragSelectWallsScript == null:
		return
	drag_select_walls = DragSelectWallsScript.new()
	drag_select_walls._g = Global
	drag_select_walls.ui_util = ui_util
	drag_select_walls.start()
	if rotation_fix != null:
		rotation_fix.drag_select_walls = drag_select_walls
	print("[UnofficialPatch] DragSelectWalls loaded.")


func _unload_drag_select_walls() -> void:
	if drag_select_walls == null:
		return
	if drag_select_walls.has_method("cleanup"):
		drag_select_walls.cleanup()
	drag_select_walls = null
	if rotation_fix != null:
		rotation_fix.drag_select_walls = null
	print("[UnofficialPatch] DragSelectWalls unloaded.")


func _on_wall_move_transform_toggled(enabled) -> void:
	# Note : drag_select_walls n'est PAS controle par ce toggle. Il reste
	# toujours actif (sauf desactivation manuelle dans Mod Debug). Le
	# toggle ne pilote que wall_move (= la transform box / move / copy
	# sur walls). Le drag-select reste utile independamment.
	if enabled:
		_load_wall_move()
	else:
		_unload_wall_move()


# --- Reposition Portals : runtime flag, delegate a portal_reposition_ui
# qui sait synchroniser ses boutons "Reposition Portals (Beta)" avec
# l'etat. wall_tool_portal_fix lit le flag a chaque edit pour faire
# le reposition ou tomber sur le comportement vanilla. ---
func _on_reposition_portals_toggled(enabled) -> void:
	if portal_reposition_ui != null and portal_reposition_ui.has_method("set_enabled"):
		portal_reposition_ui.set_enabled(enabled)


# Toggle "Display Debug Tool" (haut du panel mod_settings).
# OFF (hot effect) :
#   - Hide le panel debug et son bouton dans la barre d'outils Settings
#   - Reset tous les mods debug a enabled=true (= state initial propre)
#   - Unlock tous les locked_off de mod_settings (puisque plus aucun mod
#     debug n'est OFF)
# ON :
#   - Re-show le panel + bouton (le tool est deja loaded — il est juste
#     cache).
# Si debug_settings n'a jamais ete loaded au boot (display_debug_tool
# etait OFF en disque), on ne fait rien : le toggle prend effet au
# prochain launch via le gate dans start().
func _on_display_debug_tool_toggled(enabled) -> void:
	if debug_settings == null:
		return
	if not enabled:
		debug_settings.reset_all_to_enabled()
	debug_settings.set_visible(enabled)


func _load_grid_ruler() -> void:
	if grid_ruler != null:
		return
	if _debug_enabled("grid_ruler"):
		GridRulerScript = ResourceLoader.load(Global.Root + "scripts/grid_ruler.gd", "GDScript", true)
	if GridRulerScript == null:
		return
	grid_ruler = GridRulerScript.new()
	grid_ruler._g = Global
	grid_ruler.ui_util = ui_util
	grid_ruler.initialize()
	print("[UnofficialPatch] GridRuler loaded.")


func _unload_grid_ruler() -> void:
	if grid_ruler == null:
		return
	if grid_ruler.has_method("cleanup"):
		grid_ruler.cleanup()
	grid_ruler = null
	print("[UnofficialPatch] GridRuler unloaded.")


func _on_ruler_guide_toggled(enabled) -> void:
	if enabled:
		_load_grid_ruler()
	else:
		_unload_grid_ruler()


func _on_ruler_guide_bar_button_toggled(enabled) -> void:
	if grid_ruler != null and grid_ruler.has_method("set_bar_button_enabled"):
		grid_ruler.set_bar_button_enabled(enabled)


func _load_select_filter_bar() -> void:
	if select_filter_bar != null:
		return
	if _debug_enabled("select_filter_bar"):
		SelectFilterBarScript = ResourceLoader.load(Global.Root + "scripts/select_filter_bar.gd", "GDScript", true)
	if SelectFilterBarScript == null:
		return
	select_filter_bar = SelectFilterBarScript.new()
	select_filter_bar._g = Global
	select_filter_bar.ui_util = ui_util
	select_filter_bar.initialize()
	print("[UnofficialPatch] SelectFilterBar loaded.")


func _unload_select_filter_bar() -> void:
	if select_filter_bar == null:
		return
	if select_filter_bar.has_method("cleanup"):
		select_filter_bar.cleanup()
	select_filter_bar = null
	print("[UnofficialPatch] SelectFilterBar unloaded.")


func _on_select_filter_bar_toggled(enabled) -> void:
	if enabled:
		_load_select_filter_bar()
	else:
		_unload_select_filter_bar()


func _on_select_filter_bar_bar_button_toggled(enabled) -> void:
	if select_filter_bar != null and select_filter_bar.has_method("set_bar_button_enabled"):
		select_filter_bar.set_bar_button_enabled(enabled)


func _on_overlay_bar_button_toggled(enabled) -> void:
	if overlay_tool != null and overlay_tool.has_method("set_bar_button_enabled"):
		overlay_tool.set_bar_button_enabled(enabled)


func _load_tool_hint() -> void:
	if tool_hint != null:
		return
	if _debug_enabled("tool_hint"):
		ToolHintScript = ResourceLoader.load(Global.Root + "scripts/tool_hint.gd", "GDScript", true)
	if ToolHintScript == null:
		return
	tool_hint = ToolHintScript.new()
	tool_hint._g = Global
	tool_hint.initialize()
	print("[UnofficialPatch] ToolHint loaded.")


func _unload_tool_hint() -> void:
	if tool_hint == null:
		return
	if tool_hint.has_method("cleanup"):
		tool_hint.cleanup()
	tool_hint = null
	print("[UnofficialPatch] ToolHint unloaded.")


func _on_tool_hints_toggled(enabled) -> void:
	if enabled:
		_load_tool_hint()
	else:
		_unload_tool_hint()


func update(delta) -> void:
	# ── Profiler (press F10 to start, F10 again to print results to console) ──
	var _pk := Input.is_key_pressed(KEY_F10)
	if _pk and not _prof_key_was:
		_prof_toggle()
	_prof_key_was = _pk
	if _prof_on:
		_prof_frames += 1
	# Detect clicks on the overlay buttons via polling so they keep working
	# even when an exclusive modal (e.g. Save Reminder) is grabbing GUI input.
	if _prof_state == "shown" and _prof_overlay != null and is_instance_valid(_prof_overlay):
		var _mb := Input.is_mouse_button_pressed(BUTTON_LEFT)
		if _mb and not _prof_mouse_was:
			var mp = Global.World.get_viewport().get_mouse_position() if Global.World else Vector2()
			if _prof_close_btn != null and is_instance_valid(_prof_close_btn) and _prof_close_btn.get_global_rect().has_point(mp):
				_prof_hide_overlay()
			elif _prof_copy_btn != null and is_instance_valid(_prof_copy_btn) and _prof_copy_btn.get_global_rect().has_point(mp):
				_prof_copy_results()
		_prof_mouse_was = _mb
	else:
		_prof_mouse_was = false
	# Keep loading popup visible until prefabs_thumbnails has finished generating
	if _loading_popup != null:
		if prefabs_thumbnails == null or prefabs_thumbnails._prefetch_done:
			_close_loading_popup()
			# Loading popup vient de fermer : c'est le moment d'afficher le
			# welcome popup pour les nouveaux utilisateurs (no-op si l'user
			# a deja coche "Do not show again").
			if welcome_popup != null and welcome_popup.has_method("show_if_first_time"):
				welcome_popup.show_if_first_time()
		else:
			# Keep the popup on top while thumbnails are generating
			if is_instance_valid(_loading_popup):
				_loading_popup.raise()
			return
	else:
		# Pas de loading popup (toggle desactive) : on tente d'afficher le
		# welcome popup direct. show_if_first_time est idempotent — il
		# no-op si deja affiche ou si l'user l'a marque comme vu.
		if welcome_popup != null and welcome_popup.has_method("show_if_first_time"):
			welcome_popup.show_if_first_time()
	_pu("alt_deselect", alt_deselect, delta)
	_pu("prefs_label_fix", prefs_label_fix, delta)
	_pu("mod_settings", mod_settings, delta)
	_pu("ft_context", ft_context, delta)
	_pu("rotate_context", rotate_context, delta)
	_pu("selection_resize", selection_resize, delta)
	_pu("water_tool_fix", water_tool_fix, delta)
	_pu("preview_fix", preview_fix, delta)
	_pu("select_fix", select_fix, delta)
	_pu("scatter_multiselect_fix", scatter_multiselect_fix, delta)
	_pu("select_cursor_fix", select_cursor_fix, delta)
	_pu("select_highlight_fix", select_highlight_fix, delta)
	_pu("drag_select_focus_fix", drag_select_focus_fix, delta)
	_pu("select_layer_pick_fix", select_layer_pick_fix, delta)
	_pu("select_layer_pick_fix", select_layer_pick_fix, delta)
	_pu("compare_fix", compare_fix, delta)
	_pu("level_settings_fix", level_settings_fix, delta)
	_pu("level_settings_extra", level_settings_extra, delta)
	_pu("light_fix", light_fix, delta)
	_pu("light_tool_fix", light_tool_fix, delta)
	_pu("asset_cycle", asset_cycle, delta)
	_pu("drop_fix", drop_fix, delta)
	_pu("drop_embed", drop_embed, delta)
	_pu("pattern_fix", pattern_fix, delta)
	_pu("favorites", favorites, delta)
	_pu("pack_cache_fix", pack_cache_fix, delta)
	_pu("roof_select", roof_select, delta)
	_pu("grid_fix", grid_fix, delta)
	_pu("path_draw_fix", path_draw_fix, delta)
	_pu("path_curve_edit", path_curve_edit, delta)
	_pu("wall_curve_edit", wall_curve_edit, delta)
	_pu("pattern_curve_edit", pattern_curve_edit, delta)
	_pu("edit_points_undo", edit_points_undo, delta)
	_pu("preserve_selection_undo", preserve_selection_undo, delta)
	_pu("pattern_paint_bucket", pattern_paint_bucket, delta)
	_pu("terrain_paint_bucket", terrain_paint_bucket, delta)
	_pu("prefabs_thumbnails", prefabs_thumbnails, delta)
	_pu("save_reminder", save_reminder, delta)
	_pu("text_tool_fix", text_tool_fix, delta)
	_pu("text_transform", text_transform, delta)
	_pu("scale_unlock", scale_unlock, delta)
	_pu("eyedropper", eyedropper, delta)
	_pu("free_transform", free_transform, delta)
	_pu("free_transform_data_manager", free_transform_data_manager, delta)
	_pu("no_micro_drag", no_micro_drag, delta)
	_pu("text_select_style", text_select_style, delta)
	_pu("split_path", split_path, delta)
	_pu("merge_path", merge_path, delta)
	if drag_select_walls != null:
		# Assigner dsw au listener apres add_child
		if drag_select_walls._pending_emitter != null and is_instance_valid(drag_select_walls._pending_emitter):
			drag_select_walls._pending_emitter.dsw = drag_select_walls
			drag_select_walls._pending_emitter = null
			print("[UnofficialPatch] DragSelectWalls emitter assigned")
	if export_trace_image != null:
		if _eti_pending_start and not _eti_started:
			_eti_pending_start = false
			export_trace_image.start()
			print("[UnofficialPatch] ExportTraceImage started.")
			_eti_started = true
		_pu("export_trace_image", export_trace_image, delta)
	_pu("trace_extended", trace_extended, delta)
	_pu("window_transparency_fix", window_transparency_fix, delta)
	_pu("select_collapse", select_collapse, delta)
	_pu("rotation_snap", rotation_snap, delta)
	_pu("select_rotation", select_rotation, delta)
	_pu("popup_blur", popup_blur, delta)
	_pu("right_click_util", right_click_util, delta)
	_pu("map_explorer", map_explorer, delta)
	_pu("ui_rescaler", ui_rescaler, delta)
	_pu("arc_draw", arc_draw, delta)
	_pu("tool_hint", tool_hint, delta)


# ── Debug Settings : registration of all loadable mods ───────────────────────
# Liste passee a debug_settings.register_mod(id, label, depends_on, settings_id).
# - id : nom du fichier sans .gd (matche aussi le nom de var dans Main.gd)
# - depends_on : autres mods requis ; cascade-off si le parent est disable
# - settings_id : si renseigne, lit le toggle correspondant dans mod_settings ;
#   quand ce toggle est OFF, le mod est force OFF dans le panel debug et grise

func _register_debug_mods() -> void:
	if debug_settings == null:
		return
	# Ordre d'enregistrement sans importance — debug_settings trie alpha.
	# Format : register_mod(id, label, depends_on, settings_id, tooltip)
	# Foundations
	debug_settings.register_mod("ui_util", "", [], "",
		"Shared UI helpers used by many other mods.\nDisabling this will break most of them.")
	# Always-loaded core fixes (no settings_id)
	debug_settings.register_mod("prefs_label_fix", "", [], "",
		"Fixes the missing 'Window BG Tint' label in Preferences.")
	debug_settings.register_mod("prefabs_fix", "", [], "",
		"Auto-saves prefab backups when copying or saving the\nmap, and restores them if a prefab gets corrupted.")
	debug_settings.register_mod("portal_tool_fix", "", [], "",
		"Adds 'Above Walls' and 'Rotate 180°' buttons to the\nPortal Tool, plus a fix for portal selection issues.")
	debug_settings.register_mod("portal_flatten_curves", "", ["ui_util"], "portal_flatten_curves",
		"Adds a 'Flatten Curves' toggle to the Portal Tool that\nlets you place portals on curved walls by flattening a\nminimal cardinal-aligned chord under the cursor.")
	debug_settings.register_mod("water_tool_fix", "", [], "",
		"Animates water and lava materials in the editor view\nso you see them moving like in exports.")
	debug_settings.register_mod("preview_fix", "", [], "",
		"Fixes the asset preview that sometimes stayed stuck\non screen after switching tools.")
	debug_settings.register_mod("select_fix", "", [], "",
		"Various selection-related quirks fixes (offset bugs,\nstale highlights, edge cases).")
	debug_settings.register_mod("scatter_multiselect_fix", "Scatter Multiselect Fix", [], "",
		"Fixes the multi-second freeze when Shift-selecting a large\nrange of assets in the Scatter Tool's object library.")
	debug_settings.register_mod("select_cursor_fix", "", [], "",
		"Fixes the cursor staying stuck on a resize/move/rotate\nshape when leaving SelectTool via a keyboard shortcut\nwhile hovering or manipulating a transform handle.")
	debug_settings.register_mod("select_highlight_fix", "", [], "",
		"Clears the SelectTool hover highlight when the cursor\nleaves the map canvas (side panels, top menu, popups,\nor another window), instead of leaving it stuck on.")
	debug_settings.register_mod("drag_select_focus_fix", "", [], "",
		"Recovers a drag-select box left stuck when the window\nloses focus mid-drag (Alt+Tab while holding the click),\nby finalizing the orphaned selection on return.")
	debug_settings.register_mod("select_layer_pick_fix", "", [], "",
		"Fixes a vanilla bug where an object stacked under another\non the same layer stops being hover-detectable after the\ntop object's layer is changed and changed back.")
	debug_settings.register_mod("compare_fix", "", [], "",
		"Fixes the 'Compare' window behavior when toggling\nbetween before/after states.")
	debug_settings.register_mod("level_settings_fix", "", [], "",
		"Lets the Levels list in the Level Settings panel grow\nto fill the panel height, instead of being a small fixed\nbox you have to scroll through once you add a few levels.")
	debug_settings.register_mod("level_settings_extra", "", [], "",
		"Adds a right-click 'Clone' option in the Level Settings list\nto duplicate the pointed level, and highlights the current\nlevel in the list.")
	debug_settings.register_mod("path_fix", "", [], "",
		"Fixes various path-tool drawing and editing bugs.")
	debug_settings.register_mod("wall_fix", "", [], "",
		"Fixes various wall-tool drawing and editing bugs.")
	debug_settings.register_mod("transform_box_fix", "", [], "",
		"Fixes the SelectTool transform box (resize handles,\nrotation handle, edge cases).")
	debug_settings.register_mod("pan_fix", "", [], "",
		"Fixes camera pan glitches when middle-clicking or\nholding space during certain actions.")
	debug_settings.register_mod("wall_allow_light", "", [], "",
		"Adds a per-wall toggle to let light pass through\nspecific walls (useful for windows, archways).")
	debug_settings.register_mod("drop_fix", "", [], "",
		"Fixes file-drop behavior (image embedding, prefab\nfiles, etc.).")
	debug_settings.register_mod("pattern_fix", "", [], "",
		"Fixes pattern-tool drawing and selection quirks.")
	debug_settings.register_mod("alt_deselect", "", [], "",
		"Lets you Alt+click to deselect individual items from\nthe current selection.")
	debug_settings.register_mod("text_tool_fix", "", [], "",
		"Adds alignment buttons, font selector, and various\nfixes to the Text Tool.")
	debug_settings.register_mod("text_select_style", "", [], "",
		"Adds font, size, and color editing for selected texts\nfrom the SelectTool panel.")
	debug_settings.register_mod("text_transform", "", [], "",
		"Lets you move, scale, and rotate text objects with\nthe SelectTool transform box.")
	debug_settings.register_mod("trace_extended", "", [], "",
		"Extends the Trace Tool with extra options and fixes.")
	debug_settings.register_mod("scale_unlock", "", [], "",
		"Removes the asset scale limits (was capped at 5x);\nlets you scale assets to extreme sizes.")
	debug_settings.register_mod("ui_rescaler", "UI Rescaler", [], "",
		"Per-category UI scale sliders (Settings tool).\nMultipliers stack on top of DD's vanilla Enlarge UI.")
	debug_settings.register_mod("window_transparency_fix", "", [], "",
		"Fixes transparency rendering for windows and other\ntranslucent assets.")
	debug_settings.register_mod("path_draw_fix", "", [], "draw_over_ui",
		"Keeps Path/Wall/Pattern/Floor/Roof tools tracking the\ncursor when it leaves the map viewport, so you can\ndraw while moving over UI panels.")
	debug_settings.register_mod("prefabs_clone_fix", "", [], "",
		"Fixes prefab cloning when duplicating levels or\nsaving with unsaved changes.")
	debug_settings.register_mod("roof_select", "", [], "",
		"Lets you click roofs to select them in the SelectTool\n(roofs were previously unselectable).")
	debug_settings.register_mod("merge_path", "", [], "",
		"Adds a 'Merge Paths' action to combine two selected\npaths sharing an endpoint (like vanilla Merge Walls).")
	debug_settings.register_mod("SplitPath", "Split Path", [], "",
		"Adds a 'Split Path' action to break a path into two\nat a chosen point.")
	debug_settings.register_mod("terrain_paint_bucket", "", [], "",
		"Adds a flood-fill paint bucket to the Terrain Tool.")
	debug_settings.register_mod("terrain_slots_extended", "Terrain Slots Extended", [], "",
		"Expands the Terrain Brush from 8 to up to 24 terrain slots,\nwith a custom texture picker (search, favorites, All tab).")
	debug_settings.register_mod("pattern_paint_bucket", "", [], "",
		"Adds a flood-fill paint bucket to the Pattern Tool.")
	debug_settings.register_mod("edit_points_toggle", "", [], "",
		"Adds a quick toggle to switch in/out of point-edit\nmode for floor and pattern shapes.")
	debug_settings.register_mod("right_click_util", "", [], "",
		"Shared right-click context menu used by Favorites,\nGroup Assets, and FT Context.")
	debug_settings.register_mod("ColorPickerFix", "Color Picker Fix", [], "",
		"Replaces the eyedropper cursor and fixes color picker\nbehavior in various dialogs.")
	debug_settings.register_mod("ExportTraceImage", "Export Trace Image", [], "",
		"Adds an 'Export Trace Image' option to save the\ncurrent trace as a separate image file.")
	debug_settings.register_mod("trace_tool_webp_fix", "", [], "",
		"Fixes WEBP image loading in the Trace Tool.")
	# Settings-tied : 1 mod = 1 settings
	debug_settings.register_mod("save_reminder", "", [], "save_reminder",
		"Pops up a reminder after a few minutes if you haven't\nsaved your map yet.")
	debug_settings.register_mod("pack_cache_fix", "", [], "pack_cache_popup",
		"Adds a popup at startup offering to clean stale entries\nfrom DD's pack cache.")
	debug_settings.register_mod("map_explorer", "Map Explorer", [], "map_gallery",
		"Adds the 'Map Gallery' menu entry: a thumbnail browser\nfor all your saved maps.")
	debug_settings.register_mod("drop_embed", "", [], "drop_embed",
		"Lets you drag-and-drop image files onto the editor to\nembed them as placeable assets.")
	debug_settings.register_mod("map_resize_fix", "", [], "map_resize_target_size",
		"Fixes Resize Map dialog (200x200 limit, terrain/cave\noffsets) and adds an optional 'Target Size' mode.")
	debug_settings.register_mod("favorites", "", [], "favorite_assets",
		"Asset favoriting system: star/recolor assets, custom\npack of favorites, right-click actions.")
	debug_settings.register_mod("grid_ruler", "", [], "ruler_guide",
		"Photoshop-like ruler overlay around the map viewport\nwith a 'Guides' button (Ctrl+R).")
	debug_settings.register_mod("select_filter_bar", "", [], "select_filter_bar",
		"Repositionable horizontal bar of asset-type filter\ncheckboxes for the Select Tool ('Filters' floatbar button).")
	debug_settings.register_mod("overlay_tool", "", [], "walls_paths_overlay",
		"Toggleable overlay that highlights all walls and paths\non the map for easier review.")
	debug_settings.register_mod("grid_fix", "", [], "",
		"Adds Grid Layer (Z-order) and Grid Opacity sliders to\nMap Settings, plus various grid-related fixes.")
	debug_settings.register_mod("tool_hint", "", [], "tool_hints",
		"Adds in-tool hints/cheat-sheets that explain shortcuts\nand modifiers for each tool.")
	debug_settings.register_mod("zoom_unlock", "", [], "zoom_unlock",
		"Removes the mousewheel zoom limit (was capped); lets\nyou zoom much further in/out.")
	debug_settings.register_mod("rotation_snap", "", [], "rotation_snap",
		"Holding Shift while dragging the rotation handle snaps\nto 45° increments with hysteresis.")
	debug_settings.register_mod("group_assets", "", [], "group_assets",
		"Lets you group selected assets together so they move,\nrotate, and scale as a unit.")
	debug_settings.register_mod("select_collapse", "", [], "collapsable_controls",
		"Adds collapse arrows to SelectTool panel sections so\nyou can hide controls you don't use.")
	debug_settings.register_mod("eyedropper", "", [], "picker_tool_enter",
		"Pressing Enter in the Picker Tool selects the asset\nunder the cursor (instead of needing a click).")
	debug_settings.register_mod("preserve_selection_undo", "", [], "undo_preserves_selection",
		"Undo/redo restores the previous selection state\ninstead of clearing it.")
	debug_settings.register_mod("light_fix", "", [], "hide_lights_transform_box",
		"Hides the SelectTool transform box on lights (lights\nare typically positioned, not transformed).")
	debug_settings.register_mod("light_tool_fix", "", [], "light_tool_object_like",
		"Gives the Light Tool the same controls as the Object\nTool (rotation, scale via wheel modifiers).")
	debug_settings.register_mod("portal_reposition_ui", "", [], "reposition_portals",
		"Lets you reposition portals along their wall while in\nEdit Points mode.")
	debug_settings.register_mod("prefabs_thumbnails", "", [], "prefab_preview",
		"Generates thumbnail previews for every prefab with\nmultiple display modes.")
	debug_settings.register_mod("popup_blur", "", [], "blurred_popup_background",
		"Blurs the editor background behind dialog popups.")
	# Settings-tied : 1 mod = plusieurs settings (Array)
	debug_settings.register_mod("rotation_fix", "", [], ["consistent_rotation", "one_deg_rotation"],
		"Unifies rotation step (15°/Z=5°) across all tools, plus\nadds Shift+Z+wheel for 1° rotation.")
	debug_settings.register_mod("asset_cycle", "", [], ["select_tool_asset_cycle", "pattern_right_click_rotation"],
		"Shift+wheel cycles assets in SelectTool, plus\nright-click rotates patterns by 90°.")
	debug_settings.register_mod("selection_resize", "", [], ["centered_resize_alt", "snap_resize_shift"],
		"Alt+resize-handle = centered resize. Shift+resize\n= snap to grid.")
	debug_settings.register_mod("clipboard_fix", "", [], ["paste_under_cursor", "paste_snap"],
		"Pastes assets at the cursor position with optional\ngrid-snap support.")
	# With dependencies
	debug_settings.register_mod("free_transform_data_manager", "", [], "free_transform",
		"Backend storage for Free Transform's per-asset deform\nstate. Required by Free Transform.")
	debug_settings.register_mod("free_transform", "", ["free_transform_data_manager"], "free_transform",
		"Lets you skew, perspective-warp, and otherwise non-\nuniformly transform assets via a 4-corner widget.")
	debug_settings.register_mod("ft_context", "FT Context", ["free_transform"], "free_transform",
		"Adds 'Free Transform' to the right-click context menu\nin the SelectTool.")
	debug_settings.register_mod("rotate_context", "Rotate Context", [], "",
		"Adds 'Rotate 90°' to the right-click context menu and\ndisables RotateAndJiggle's right-click auto-rotation.")
	debug_settings.register_mod("no_micro_drag", "", ["overlay_tool"], "better_selection",
		"Distinguishes click vs drag better : ignores tiny\nmouse movements that vanilla treats as drags.")
	debug_settings.register_mod("wall_move", "", ["overlay_tool"], "wall_move_transform",
		"Lets you move, rotate, scale, and copy walls using\nthe SelectTool transform box.")
	debug_settings.register_mod("DragSelectWalls", "Drag Select Walls", [], "",
		"Lets you drag-select walls (vanilla only allowed click-\nto-select).")
	debug_settings.register_mod("path_curve_edit", "", [], "edit_curves",
		"Curve editing for paths in Edit Points mode.")
	debug_settings.register_mod("wall_curve_edit", "", [], "edit_curves",
		"Curve editing for walls in Edit Points mode.")
	debug_settings.register_mod("pattern_curve_edit", "", [], "edit_curves",
		"Curve editing for patterns in Edit Points mode.")
	debug_settings.register_mod("arc_draw", "", ["path_curve_edit", "wall_curve_edit", "pattern_curve_edit"], "arc_draw",
		"Hold Ctrl while drawing a path/wall/pattern curve to\nproduce a perfect arc.")
	debug_settings.register_mod("axis_lock", "", [], "axis_lock",
		"Hold Ctrl (Cmd on Mac) while drawing in Path/Wall/\nPattern/Roof tools to lock the segment to the 8\ncardinal/diagonal axes (Photoshop-style).")
	debug_settings.register_mod("edit_points_undo", "", ["path_curve_edit"], "",
		"Adds undo/redo support for edit-points operations.")
	debug_settings.register_mod("wall_tool_portal_fix", "", ["portal_reposition_ui"], "",
		"Fixes portal placement bugs when using the Wall Tool\nin Edit Points mode.")
	debug_settings.register_mod("select_rotation", "", ["rotation_snap"], "rotation_slider",
		"Adds a rotation slider/spinbox in the SelectTool panel\nfor precise asset rotation.")
	debug_settings.register_mod("pattern_scale_bake", "Pattern Scale Bake", [], "",
		"Adds a 'Bake Pattern Scale' option to the right-click\nmenu for selected patterns whose scale isn't (1, 1).\nBakes node.scale into the polygon vertices so DD's snap\npipeline (which references node.position) aligns with\nthe rendered corner positions.\nUse after a vanilla resize if the pattern no longer\nsnaps the way you expect.")


# Helper called by every conditional load site in start(). Returns true (= go
# ahead and load) if debug_settings is not yet loaded or the mod is enabled.
func _debug_enabled(id: String) -> bool:
	if debug_settings == null:
		return true
	return debug_settings.is_mod_enabled(id)

# ── Profiler helpers ─────────────────────────────────────────────────────────
func _pu(n, ref, delta) -> void:
	if ref == null:
		return
	if not _prof_on:
		ref.update(delta)
		return
	var t0 := OS.get_ticks_usec()
	ref.update(delta)
	_prof_acc[n] = _prof_acc.get(n, 0) + (OS.get_ticks_usec() - t0)


func _prof_toggle() -> void:
	match _prof_state:
		"idle":
			_prof_start()
		"running":
			_prof_stop()
		"shown":
			_prof_hide_overlay()
		_:
			_prof_start()


func _prof_start() -> void:
	# Clear any leftover overlay before starting a fresh test
	if _prof_overlay != null and is_instance_valid(_prof_overlay):
		_prof_overlay.queue_free()
	_prof_overlay = null
	_prof_on = true
	_prof_state = "running"
	_prof_acc = {}
	_prof_frames = 0
	if Global.ModMapData is Dictionary:
		Global.ModMapData["_prof_dsw_usec"] = 0
		Global.ModMapData["_prof_umou_usec"] = 0
		Global.ModMapData["_prof_ft"] = {}
		Global.ModMapData["_prof_dsw_on"] = true
	_prof_show_running()
	print("[PROF] ON — reproduce the lag (stay still in SelectTool), then press F10 again")


func _prof_stop() -> void:
	_prof_on = false
	_prof_state = "shown"
	if Global.ModMapData is Dictionary:
		Global.ModMapData["_prof_dsw_on"] = false
	_prof_hide_running()
	_prof_dump()
	_prof_show_overlay()
	print("[PROF] F10 again to close the overlay")


func _prof_show_running() -> void:
	var root = Global.World.get_tree().root if Global.World else null
	if root == null:
		return
	if _prof_running_popup != null and is_instance_valid(_prof_running_popup):
		_prof_running_popup.queue_free()
		_prof_running_popup = null

	# High CanvasLayer so our popup keeps priority above the editor UI
	# (Library, docks) and any modal dialog such as Save Reminder.
	var canvas := CanvasLayer.new()
	canvas.name = "UPProfRunning"
	canvas.layer = 128

	var panel := Panel.new()
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.45, 0.12, 0.12, 0.92)
	bg.set_border_width_all(1)
	bg.border_color = Color(1.0, 0.5, 0.5, 0.8)
	bg.set_corner_radius_all(4)
	bg.content_margin_left = 12
	bg.content_margin_right = 12
	bg.content_margin_top = 6
	bg.content_margin_bottom = 6
	panel.add_stylebox_override("panel", bg)
	canvas.add_child(panel)

	var lbl := Label.new()
	lbl.text = "Profiler running…   F10 to stop"
	lbl.add_color_override("font_color", Color(1, 1, 1))
	lbl.align = Label.ALIGN_CENTER
	lbl.valign = Label.VALIGN_CENTER
	var f = lbl.get_font("font").duplicate()
	f.size = 15
	lbl.add_font_override("font", f)
	lbl.anchor_right = 1.0
	lbl.anchor_bottom = 1.0
	panel.add_child(lbl)

	var sz = f.get_string_size(lbl.text)
	var w = sz.x + 24.0
	var h = sz.y + 12.0
	var win = OS.window_size
	panel.rect_position = Vector2((win.x - w) / 2.0, (win.y - h) / 2.0)
	panel.rect_size = Vector2(w, h)

	root.add_child(canvas)
	_prof_running_popup = canvas


func _prof_hide_running() -> void:
	if _prof_running_popup != null and is_instance_valid(_prof_running_popup):
		_prof_running_popup.queue_free()
	_prof_running_popup = null


func _prof_show_overlay() -> void:
	var root = Global.World.get_tree().root if Global.World else null
	if root == null:
		return
	if _prof_overlay != null and is_instance_valid(_prof_overlay):
		_prof_overlay.queue_free()
		_prof_overlay = null

	# High CanvasLayer so the results stay above the editor UI (Library, docks)
	# and any modal dialog such as Save Reminder.
	var canvas := CanvasLayer.new()
	canvas.name = "UPProfOverlay"
	canvas.layer = 128

	var panel := Panel.new()
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.05, 0.05, 0.07, 0.95)
	bg.set_border_width_all(1)
	bg.border_color = Color(0.4, 0.7, 1.0, 0.6)
	bg.set_corner_radius_all(4)
	panel.add_stylebox_override("panel", bg)
	canvas.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.anchor_right = 1.0
	vbox.anchor_bottom = 1.0
	vbox.margin_left = 8
	vbox.margin_top = 6
	vbox.margin_right = -8
	vbox.margin_bottom = -8
	vbox.set("custom_constants/separation", 6)
	panel.add_child(vbox)

	var topbar := HBoxContainer.new()
	topbar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(topbar)

	var title := Label.new()
	title.text = "Profiler results"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	topbar.add_child(title)

	var copy_btn := Button.new()
	copy_btn.text = "Copy results"
	var b_normal := StyleBoxFlat.new()
	b_normal.bg_color = Color(0.20, 0.52, 0.92, 1.0)
	b_normal.set_corner_radius_all(4)
	b_normal.content_margin_left = 14
	b_normal.content_margin_right = 14
	b_normal.content_margin_top = 5
	b_normal.content_margin_bottom = 5
	var b_hover = b_normal.duplicate()
	b_hover.bg_color = Color(0.32, 0.63, 1.0, 1.0)
	var b_pressed = b_normal.duplicate()
	b_pressed.bg_color = Color(0.14, 0.40, 0.75, 1.0)
	copy_btn.add_stylebox_override("normal", b_normal)
	copy_btn.add_stylebox_override("hover", b_hover)
	copy_btn.add_stylebox_override("pressed", b_pressed)
	copy_btn.add_color_override("font_color", Color(1, 1, 1))
	copy_btn.add_color_override("font_color_hover", Color(1, 1, 1))
	copy_btn.add_color_override("font_color_pressed", Color(1, 1, 1))
	topbar.add_child(copy_btn)
	_prof_copy_btn = copy_btn

	var close_btn := Button.new()
	close_btn.text = "X"
	close_btn.hint_tooltip = "Close (F10)"
	var x_normal := StyleBoxFlat.new()
	x_normal.bg_color = Color(0.55, 0.18, 0.18, 1.0)
	x_normal.set_corner_radius_all(4)
	x_normal.content_margin_left = 8
	x_normal.content_margin_right = 8
	x_normal.content_margin_top = 5
	x_normal.content_margin_bottom = 5
	var x_hover = x_normal.duplicate()
	x_hover.bg_color = Color(0.80, 0.25, 0.25, 1.0)
	var x_pressed = x_normal.duplicate()
	x_pressed.bg_color = Color(0.40, 0.12, 0.12, 1.0)
	close_btn.add_stylebox_override("normal", x_normal)
	close_btn.add_stylebox_override("hover", x_hover)
	close_btn.add_stylebox_override("pressed", x_pressed)
	close_btn.add_color_override("font_color", Color(1, 1, 1))
	close_btn.add_color_override("font_color_hover", Color(1, 1, 1))
	close_btn.add_color_override("font_color_pressed", Color(1, 1, 1))
	topbar.add_child(close_btn)
	_prof_close_btn = close_btn

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)
	_prof_scroll = scroll

	var lbl := Label.new()
	lbl.text = PoolStringArray(_prof_last_lines).join("\n")
	var f = lbl.get_font("font").duplicate()
	f.size = 15
	lbl.add_font_override("font", f)
	scroll.add_child(lbl)

	# Centered box, 10% vertical margins (= 80% of window height)
	var max_w := 0.0
	for line in _prof_last_lines:
		var w = f.get_string_size(line).x
		if w > max_w:
			max_w = w
	var win = OS.window_size
	var margin_y = win.y * 0.1
	var height = win.y - margin_y * 2.0
	var width = min(max_w + 60.0, 460.0)
	panel.rect_position = Vector2((win.x - width) / 2.0, margin_y)
	panel.rect_size = Vector2(width, height)

	root.add_child(canvas)
	_prof_overlay = canvas
	_prof_panel = panel
	_prof_ensure_input_listener()
	print("[PROF] overlay shown — F10 to hide")


func _prof_ensure_input_listener() -> void:
	# A tiny Node whose _input() runs before GUI handling, so we can scroll the
	# results with the wheel even while an exclusive modal grabs GUI input.
	if _prof_input_node != null and is_instance_valid(_prof_input_node):
		return
	if Global.World == null or not is_instance_valid(Global.World):
		return
	var s = GDScript.new()
	s.source_code = "extends Node\nvar handler = null\nfunc _ready():\n\tset_process_input(true)\nfunc _input(e):\n\tif handler != null:\n\t\thandler._prof_on_input(e)\n"
	s.reload()
	var node = Node.new()
	node.set_script(s)
	node.set("handler", self)
	Global.World.get_tree().root.add_child(node)
	_prof_input_node = node


func _prof_on_input(e) -> void:
	if _prof_state != "shown":
		return
	if _prof_scroll == null or not is_instance_valid(_prof_scroll):
		return
	if _prof_panel == null or not is_instance_valid(_prof_panel):
		return
	if not (e is InputEventMouseButton) or not e.pressed:
		return
	if e.button_index != BUTTON_WHEEL_UP and e.button_index != BUTTON_WHEEL_DOWN:
		return
	var mp = Global.World.get_viewport().get_mouse_position() if Global.World else Vector2()
	if not _prof_panel.get_global_rect().has_point(mp):
		return
	var step := 40
	if e.button_index == BUTTON_WHEEL_UP:
		_prof_scroll.scroll_vertical -= step
	else:
		_prof_scroll.scroll_vertical += step
	if Global.World != null and is_instance_valid(Global.World):
		Global.World.get_tree().set_input_as_handled()


func _prof_copy_results() -> void:
	OS.clipboard = PoolStringArray(_prof_last_lines).join("\n")
	print("[PROF] results copied to clipboard")


func _prof_hide_overlay() -> void:
	_prof_state = "idle"
	if _prof_overlay != null and is_instance_valid(_prof_overlay):
		_prof_overlay.queue_free()
	_prof_overlay = null
	_prof_panel = null
	_prof_scroll = null
	_prof_copy_btn = null
	_prof_close_btn = null
	print("[PROF] overlay hidden — F10 to run a new test")


func _prof_dump() -> void:
	# Fold in DragSelectWalls listener time (runs outside Main's dispatch)
	if Global.ModMapData is Dictionary:
		var dsw_us = Global.ModMapData.get("_prof_dsw_usec", 0)
		if dsw_us > 0:
			_prof_acc["DragSelectWalls.on_process (listener)"] = dsw_us
		Global.ModMapData["_prof_dsw_usec"] = 0
		var umou_us = Global.ModMapData.get("_prof_umou_usec", 0)
		if umou_us > 0:
			_prof_acc["is_mouse_over_ui (shared, all callers)"] = umou_us
		Global.ModMapData["_prof_umou_usec"] = 0
		var ft_d = Global.ModMapData.get("_prof_ft", null)
		if ft_d is Dictionary:
			for ft_k in ft_d:
				_prof_acc["  free_transform::" + str(ft_k)] = ft_d[ft_k]
		Global.ModMapData["_prof_ft"] = {}
	var frames = int(max(_prof_frames, 1))
	var rows = []
	var total := 0.0
	for k in _prof_acc:
		var avg := float(_prof_acc[k]) / float(frames)
		total += avg
		rows.append([k, avg])
	rows.sort_custom(self, "_prof_sort")
	_prof_last_lines = []
	var header := "===== avg us/frame over %d frames (worst first) =====" % frames
	print("[PROF] " + header)
	_prof_last_lines.append(header)
	for r in rows:
		if r[1] < 1.0:
			continue
		var line := "%9.1f us   %s" % [r[1], r[0]]
		print("[PROF] " + line)
		_prof_last_lines.append(line)
	var footer1 := "----- total measured: %.1f us/frame -----" % total
	var footer2 := "(~%.1f%% of the 16666us 60fps budget)" % (total / 16666.0 * 100.0)
	print("[PROF] " + footer1)
	print("[PROF] " + footer2)
	_prof_last_lines.append(footer1)
	_prof_last_lines.append(footer2)


func _prof_sort(a, b):
	return a[1] > b[1]
