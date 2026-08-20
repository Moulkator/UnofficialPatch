# ui_util.gd
# Shared utility for detecting if mouse is over UI panels/popups
# Detects panels dynamically by finding controls anchored to screen edges

var _g
var _left_edge := 0.0
var _right_edge := 99999.0
var _bottom_edge := 99999.0
var _edge_cache_frame := -1

# ═══ Caches PARTAGÉS entre toutes les instances de ui_util ═══════════════════
# Plusieurs mods instancient leur propre copie de ui_util (text_transform,
# text_tool_fix, free_transform, terrain_slots_extended) en plus de l'instance
# de Main. Avant, chaque instance avait ses propres caches → chacune payait le
# walk récursif complet de _has_visible_popup toutes les 3 frames (~7-8 ms sur
# une scène DD chargée), soit ~2,6 ms/frame PAR INSTANCE dans SelectTool.
# Les caches vivent maintenant dans Engine meta (pattern déjà utilisé par
# text_tool_fix pour son listener) : une seule détection sert tout le monde.
#
# En plus du partage, la détection de popup n'est plus un walk d'arbre : un
# registre des Popup/WindowDialog est maintenu via les signaux node_added /
# node_removed du SceneTree (seed initial par un unique walk complet). Le
# check périodique ne parcourt plus que les ~quelques dizaines de popups.
const _UU_CACHE_META := "_uu_shared_cache"   # Dictionary : caches par frame
const _UU_REG_META := "_uu_popup_registry"   # Dictionary : id → Popup/WindowDialog
const _UU_MGR_META := "_uu_popup_manager"    # WeakRef : instance connectée aux signaux
const _UU_STATE_META := "_uu_editor_state"   # Dictionary: per-frame editor state (Main.gd)

# Référence locale au registre (le même Dictionary que dans Engine meta) pour
# que les handlers node_added/removed n'aient pas à refaire get_meta à chaque
# nœud ajouté (ça fire pour TOUS les nœuds, ex. au chargement d'une map).
var _reg_ref = null

func _shared_cache() -> Dictionary:
	if not Engine.has_meta(_UU_CACHE_META):
		Engine.set_meta(_UU_CACHE_META, {})
	return Engine.get_meta(_UU_CACHE_META)


# ── Per-frame editor-state cache ──────────────────────────────────────────
# Main.gd publishes a Dictionary through Engine metadata at the top of its
# update loop: { "active_tool_name": String, "frame": int }. Reading native
# editor properties (ActiveToolName, ...) marshals a fresh GDScript object
# across the C++ boundary on every access; the shared cache reduces that to
# a single read per frame for the whole mod suite.
func editor_state() -> Dictionary:
	if Engine.has_meta(_UU_STATE_META):
		var s = Engine.get_meta(_UU_STATE_META)
		if s is Dictionary:
			return s
	return {}


# Cached ActiveToolName, with a direct-read fallback (safe before the first
# Main.update() tick, or if the cache is ever unavailable).
func active_tool_name(editor) -> String:
	# PRECONDITION: if the caller's editor is not reachable, report "no
	# tool" so it takes its safe early-out — never serve a cached name in
	# a state where editor objects are unsafe to touch (native AV hazard).
	if editor == null:
		return ""
	var s = editor_state()
	var v = s.get("active_tool_name")
	if v is String:
		# Forced copy — never hand out a COW reference to the String stored
		# in the shared Dictionary (native AV hazard, see Main.gd).
		return "%s" % v
	return str(editor.get("ActiveToolName"))

# Cache for find_aso_terrain_window. The full scene-tree scan it performs is
# O(scene nodes) and was being run multiple times per frame by asset_cycle's
# terrain sync (update() → _do_terrain_sync → _is_terrain_window_visible).
# On a loaded map that scan is the dominant cause of the Terrain-tool framerate
# drop. We keep the found window instance and validate it with cheap checks (no
# tree walk); when no ASO window exists we only re-run the full scan every
# _ASO_RESCAN_FRAMES frames instead of every frame.
const _ASO_RESCAN_FRAMES := 60

func _cached_has_visible_popup(tree: SceneTree) -> bool:
	var cache = _shared_cache()
	var frame = Engine.get_frames_drawn()
	if frame - int(cache.get("popup_frame", -100)) < 3:
		return bool(cache.get("popup_val", false))
	cache["popup_frame"] = frame
	cache["popup_val"] = _registry_has_visible_popup(tree)
	return cache["popup_val"]


# Vérifie la visibilité sur le registre de popups (pas de walk d'arbre).
# Même sémantique que l'ancien _has_visible_popup : un Popup/WindowDialog
# visible n'importe où dans l'arbre → true. is_inside_tree() reproduit le fait
# que l'ancien walk partait de root (un popup hors arbre n'était pas trouvé).
func _registry_has_visible_popup(tree: SceneTree) -> bool:
	_ensure_popup_registry(tree)
	var reg = Engine.get_meta(_UU_REG_META)
	if not (reg is Dictionary):
		return false
	var stale := []
	var found := false
	for id in reg:
		var n = reg[id]
		if n == null or not is_instance_valid(n):
			stale.append(id)
			continue
		if n.visible and n.is_inside_tree():
			found = true
			break
	for id in stale:
		reg.erase(id)
	return found


# Installe (ou réinstalle) le registre : un unique walk complet pour le seed,
# puis maintenance incrémentale via les signaux du SceneTree. Si l'instance
# gestionnaire est libérée (ses connexions tombent avec elle), la prochaine
# instance appelante réinstalle tout — le re-seed complet évite les trous.
func _ensure_popup_registry(tree: SceneTree) -> void:
	if Engine.has_meta(_UU_MGR_META) and Engine.has_meta(_UU_REG_META):
		var wr = Engine.get_meta(_UU_MGR_META)
		if wr is WeakRef and wr.get_ref() != null:
			# Gestionnaire vivant : rafraîchit juste notre référence locale.
			if _reg_ref == null:
				_reg_ref = Engine.get_meta(_UU_REG_META)
			return
	var reg := {}
	_seed_popup_registry(tree.root, reg, 0)
	Engine.set_meta(_UU_REG_META, reg)
	_reg_ref = reg
	if not tree.is_connected("node_added", self, "_on_uu_node_added"):
		tree.connect("node_added", self, "_on_uu_node_added")
	if not tree.is_connected("node_removed", self, "_on_uu_node_removed"):
		tree.connect("node_removed", self, "_on_uu_node_removed")
	Engine.set_meta(_UU_MGR_META, weakref(self))


func _seed_popup_registry(node: Node, reg: Dictionary, depth: int) -> void:
	if depth > 24 or not is_instance_valid(node):
		return
	# WindowDialog hérite de Popup en Godot 3, un seul test suffit.
	if node is Popup:
		reg[node.get_instance_id()] = node
	for i in node.get_child_count():
		_seed_popup_registry(node.get_child(i), reg, depth + 1)


# Handlers de signaux : appelés pour CHAQUE nœud ajouté/retiré de l'arbre —
# doivent rester ultra légers (un test de classe, un accès Dictionary).
func _on_uu_node_added(node: Node) -> void:
	if node is Popup and _reg_ref is Dictionary:
		_reg_ref[node.get_instance_id()] = node


func _on_uu_node_removed(node: Node) -> void:
	if node is Popup and _reg_ref is Dictionary:
		_reg_ref.erase(node.get_instance_id())

# ignore_popups: skip the "ANY visible Popup anywhere in the tree" veto and
# answer purely on geometry (toolbar / panel edges / registered extra rects).
# The veto is the right default for mods that must freeze while a modal is up,
# but it is far too broad for wheel-driven map interactions: Godot 3 tooltips
# are Popups, so a tooltip left showing over the toolbar (or any hidden-but-
# "visible" WindowDialog) makes this return true while the cursor is plainly
# over the map. Callers that only need "is the cursor over a UI surface"
# should pass true and hit-test the popup under the cursor separately with
# is_mouse_over_popup().
# macOS Retina : Viewport.get_mouse_position() renvoie des PIXELS physiques
# alors que les rects GUI (get_global_rect des panneaux, edges) sont en POINTS
# logiques -- facteur 2 sur Retina. Toute comparaison souris/rect GUI doit donc
# normaliser par OS.get_screen_scale() (2.0 sur Retina, 1.0 partout ailleurs :
# non implemente hors macOS en Godot 3). Diagnostique via [TTF-DIAG] :
# event.pos=(813,676) vs vp.mouse=(1626,1352), edges=(284,1673,1104).
func gui_mouse(vp) -> Vector2:
	var m = vp.get_mouse_position()
	if OS.has_method("get_screen_scale"):
		var sc = OS.get_screen_scale()
		if sc > 1.01:
			return m / sc
	return m


func is_mouse_over_ui(listener_node: Node, ignore_popups: bool = false) -> bool:
	# Profiler hook: when Main's F10 profiler is active, accumulate this
	# (per-frame-cached) UI walk so we can see its true cost separately —
	# it's shared across ~20 callers and otherwise charged to whichever mod
	# calls it first in the frame.
	if _g == null or not (_g.ModMapData is Dictionary) or not _g.ModMapData.get("_prof_dsw_on", false):
		return _is_mouse_over_ui_impl(listener_node, ignore_popups)
	var _t0 := OS.get_ticks_usec()
	var _r := _is_mouse_over_ui_impl(listener_node, ignore_popups)
	_g.ModMapData["_prof_umou_usec"] = _g.ModMapData.get("_prof_umou_usec", 0) + (OS.get_ticks_usec() - _t0)
	return _r


func _is_mouse_over_ui_impl(listener_node: Node, ignore_popups: bool = false) -> bool:
	# Frame-scoped RESULT cache, shared across all instances and callers.
	# ~20 submods call is_mouse_over_ui at least once per frame; the result
	# only depends on the mouse position and UI state, both constant within a
	# frame. Without this, every caller re-ran the checks and the extra-rects
	# loop below — O(callers × 60fps) work and allocations.
	# The two variants answer different questions, so they get their own
	# frame slot — sharing one would let whichever ran first poison the other.
	var cache = _shared_cache()
	var frame = Engine.get_frames_drawn()
	var key_frame = "umou_np_frame" if ignore_popups else "umou_frame"
	var key_val = "umou_np_val" if ignore_popups else "umou_val"
	if int(cache.get(key_frame, -100)) == frame:
		return bool(cache.get(key_val, true))

	var tree = listener_node.get_tree()
	if not ignore_popups:
		if tree and _cached_has_visible_popup(tree):
			cache[key_frame] = frame
			cache[key_val] = true
			return true

	var vp = listener_node.get_viewport()
	if vp == null:
		# Listener-specific degenerate case — don't poison the shared cache.
		return true
	var mouse = gui_mouse(vp)
	var vp_size = vp.size
	var over := false

	# Toolbar
	if mouse.y < 50:
		over = true

	if not over:
		# Dynamic left/right panel edges
		_update_panel_edges(tree, vp_size)
		if mouse.x < _left_edge or mouse.x > _right_edge:
			over = true
		# Bottom bar (floatbar / status bar)
		elif mouse.y > _bottom_edge:
			over = true

	# Extra UI rects registered by floating mod panels (e.g. SelectFilterBar),
	# which the edge/toolbar checks above don't cover. Iterate the Dictionary
	# keys directly: values() allocated a fresh Array on EVERY call, i.e. once
	# per caller per frame across the whole mod suite.
	if not over and _g != null:
		var mmd = _g.get("ModMapData")
		if mmd is Dictionary and mmd.has("_extra_ui_rects"):
			var rects = mmd["_extra_ui_rects"]
			if rects is Dictionary:
				for k in rects:
					var r = rects[k]
					if r is Rect2 and r.has_point(mouse):
						over = true
						break

	cache[key_frame] = frame
	cache[key_val] = over
	return over


# Comme is_mouse_over_ui, mais ajoute un hit-test direct des Controls interactifs du
# HUD sous la souris (floatbar, boutons flottants, sliders…), en excluant les Controls
# quasi plein écran (le canvas). Filet de sécurité pour les outils custom (bucket,
# square brush) au cas où un élément flottant échapperait aux heuristiques de bords.
func is_mouse_over_hud(listener_node: Node) -> bool:
	if is_mouse_over_ui(listener_node):
		return true
	var cache = _shared_cache()
	var frame = Engine.get_frames_drawn()
	if frame == int(cache.get("hud_frame", -100)):
		return bool(cache.get("hud_val", false))
	cache["hud_frame"] = frame
	cache["hud_val"] = false
	var vp = listener_node.get_viewport()
	var tree = listener_node.get_tree()
	if vp == null or tree == null:
		return false
	var mouse = gui_mouse(vp)
	cache["hud_val"] = _find_hud_control_at(tree.root, mouse, vp.size, 0) != null
	return cache["hud_val"]


# DFS : le Control interactif le plus profond sous la souris gagne. Exclut le canvas
# (Controls quasi plein écran) et les Controls en MOUSE_FILTER_IGNORE.
func _find_hud_control_at(node: Node, mouse: Vector2, vp_size: Vector2, depth: int):
	if depth > 8 or not is_instance_valid(node):
		return null
	if node is CanvasItem and not node.is_visible_in_tree():
		return null
	for i in node.get_child_count():
		var found = _find_hud_control_at(node.get_child(i), mouse, vp_size, depth + 1)
		if found != null:
			return found
	if node is Control and node.mouse_filter != Control.MOUSE_FILTER_IGNORE:
		if node is Panel or node is PanelContainer or node is BaseButton \
			or node is Slider or node is OptionButton or node is SpinBox \
			or node is LineEdit:
			var rect = node.get_global_rect()
			var area = rect.size.x * rect.size.y
			if rect.size.x > 4.0 and rect.size.y > 4.0 \
				and area < vp_size.x * vp_size.y * 0.8 \
				and rect.has_point(mouse):
				return node
	return null


# Check if mouse is directly over a popup/window dialog
func is_mouse_over_popup(listener_node: Node) -> bool:
	return get_popup_under_mouse(listener_node) != null


# Get the popup/window dialog under the mouse (if any)
func get_popup_under_mouse(listener_node: Node):
	var vp = listener_node.get_viewport()
	if vp == null:
		return null
	var mouse = gui_mouse(vp)
	var tree = listener_node.get_tree()
	if tree == null:
		return null
	return _find_popup_at(tree.root, mouse)


# Scroll the popup under the mouse (returns true if scrolled)
func scroll_popup_under_mouse(listener_node: Node, up: bool) -> bool:
	var vp = listener_node.get_viewport()
	if vp == null:
		return false
	var mouse = gui_mouse(vp)
	
	# First find the popup under the mouse
	var tree = listener_node.get_tree()
	if tree == null:
		return false
	
	var popup = _find_popup_at(tree.root, mouse)
	if popup == null:
		return false
	
	# Now find ScrollContainer within this popup
	var scroll = _find_scroll_in_node(popup, mouse)
	if scroll == null:
		return false
	
	# Use the scrollbar for more reliable scrolling
	var vbar = scroll.get_v_scrollbar()
	if vbar != null:
		var step = 50.0
		if up:
			vbar.value -= step
		else:
			vbar.value += step
	else:
		# Fallback to direct property
		var amount = 50 if up else -50
		scroll.scroll_vertical -= amount
	
	return true


func _find_popup_at(node: Node, mouse: Vector2):
	if not is_instance_valid(node):
		return null
	
	# Check if this node is a visible popup under the mouse
	if (node is WindowDialog or node is Popup):
		if node.visible and node.is_visible_in_tree():
			var rect = node.get_global_rect()
			if rect.has_point(mouse):
				return node
	
	# Check children
	for i in node.get_child_count():
		var found = _find_popup_at(node.get_child(i), mouse)
		if found != null:
			return found
	
	return null


func _find_scroll_in_node(node: Node, mouse: Vector2) -> ScrollContainer:
	# Find ScrollContainer under mouse within this node's subtree
	if not is_instance_valid(node):
		return null
	if node is CanvasItem and not node.is_visible_in_tree():
		return null
	
	var result: ScrollContainer = null
	
	# If this node is a ScrollContainer under the mouse, it's a candidate
	if node is ScrollContainer:
		var rect = node.get_global_rect()
		if rect.has_point(mouse):
			result = node
	
	# Check children for a more specific (deeper) ScrollContainer
	for i in node.get_child_count():
		var found = _find_scroll_in_node(node.get_child(i), mouse)
		if found != null:
			result = found  # Deeper one wins
	
	return result


func _update_panel_edges(tree: SceneTree, vp_size: Vector2) -> void:
	# Cache partagé : une seule instance fait le scan toutes les 12 frames,
	# les autres relisent les bords calculés.
	var cache = _shared_cache()
	var frame = Engine.get_frames_drawn()
	if frame - int(cache.get("edge_frame", -100)) < 12:
		_left_edge = float(cache.get("edge_left", 0.0))
		_right_edge = float(cache.get("edge_right", vp_size.x))
		_bottom_edge = float(cache.get("edge_bottom", vp_size.y))
		return
	cache["edge_frame"] = frame

	_left_edge = 0.0
	_right_edge = vp_size.x
	_bottom_edge = vp_size.y

	_scan_edge_panels(tree.root, vp_size, 0)

	cache["edge_left"] = _left_edge
	cache["edge_right"] = _right_edge
	cache["edge_bottom"] = _bottom_edge


func _scan_edge_panels(node: Node, vp_size: Vector2, depth: int) -> void:
	if depth > 5:
		return
	for i in node.get_child_count():
		var child = node.get_child(i)
		# Floating windows are never screen-edge HUD panels: skip the whole
		# subtree, visible or not. (WindowDialog inherits Popup.)
		if child is Popup:
			continue
		# is_visible_in_tree(), NOT .visible: inner panels of a hidden dialog
		# keep visible=true. Without the width cap (removed for
		# ResizeLeftPanel), such a panel can pass the height filter once
		# "Enlarge UI" scales everything up, and corrupt both edges -- the
		# guard then classifies the WHOLE screen as UI (total wheel block).
		# Skip the node AND its subtree, same pattern as grid_ruler.
		if child is Control and not child.is_visible_in_tree():
			continue
		if child is Control and child.visible:
			var rect = child.get_global_rect()
			# Real side panels: tall (>80% viewport). No width cap (see above).
			# Must be Panel or PanelContainer (not generic containers)
			if (child is Panel or child is PanelContainer) and rect.size.y > vp_size.y * 0.8 and rect.size.x > 50:
				var left_x = rect.position.x
				var right_x = rect.position.x + rect.size.x
				# Panneau gauche : collé au bord gauche mais SANS atteindre le bord
				# droit (un fond plein écran, lui, l'atteint et doit rester exclu).
				# Volontairement indépendant de la largeur pour qu'un panneau élargi
				# par ResizeLeftPanel au-delà de l'ancien plafond 25% du viewport
				# reste reconnu comme UI.
				if left_x < 5 and right_x < vp_size.x - 5:
					if right_x > _left_edge:
						_left_edge = right_x
				# Panneau droit : collé au bord droit mais ne partant pas du bord
				# gauche.
				if right_x > vp_size.x - 5 and left_x > 5:
					if left_x < _right_edge:
						_right_edge = left_x
			# Barre du bas : large (>50% largeur), courte (<20% hauteur), collée au
			# bas du viewport. Détectée seulement si présente (sinon pas de marge).
			if (child is Panel or child is PanelContainer) and rect.size.x > vp_size.x * 0.5 and rect.size.y < vp_size.y * 0.2 and rect.position.y + rect.size.y > vp_size.y - 5:
				if rect.position.y < _bottom_edge:
					_bottom_edge = rect.position.y
		_scan_edge_panels(child, vp_size, depth + 1)


# Ancien walk récursif complet — plus utilisé par is_mouse_over_ui (remplacé
# par le registre), conservé pour compat API si un mod l'importe directement.
func _has_visible_popup(node: Node, depth: int = 0) -> bool:
	if depth > 16:
		return false
	if node is Popup and node.visible:
		return true
	if node is WindowDialog and node.visible:
		return true
	for i in node.get_child_count():
		if _has_visible_popup(node.get_child(i), depth + 1):
			return true
	return false


# =============================================================================
# TerrainWindow detection (compatibility with Additional Search Options mod)
# =============================================================================
# The native DD TerrainWindow lives at editor.Windows["TerrainWindow"]. ASO
# instantiates a SECOND TerrainWindow from the same .tscn and attaches it as a
# sibling under the Editor/Windows container node, then hides the native one
# every time a terrain slot button is pressed. Both share the node name
# "TerrainWindow" and the same internal structure (PackList, TextureMenu), but
# ASO additionally wraps TextureMenu in a VBoxContainer alongside its own
# search HBox, and its window lacks DD C# methods like OnPackSelected and the
# `sets` dictionary.

# =============================================================================
# TerrainWindow detection (compatibility with Additional Search Options mod)
# =============================================================================
# The native DD TerrainWindow lives at editor.Windows["TerrainWindow"]. ASO
# instantiates a SECOND TerrainWindow from the same .tscn and attaches it as a
# SIBLING of the native one (same parent: the Editor/Windows container node),
# then hides the native one every time a terrain slot button is pressed. Both
# share the node name "TerrainWindow" and the same internal structure
# (PackList, TextureMenu), but ASO additionally wraps TextureMenu in a
# VBoxContainer alongside its own search HBox, and its window lacks DD C#
# methods like OnPackSelected and the `sets` dictionary.
#
# Detection strategy: only look at SIBLINGS of the native window. Avoids false
# positives from unrelated "TerrainWindow"-named nodes elsewhere in the tree
# (template scenes loaded into pack caches, hidden preview nodes, etc.).


# Returns the native DD TerrainWindow (read straight from the Windows dict).
# Matches the pre-patch behavior of callers that did this lookup inline.
func get_native_terrain_window(editor):
	if editor == null:
		return null
	var windows_dict = editor.get("Windows")
	if not (windows_dict is Dictionary):
		return null
	if not windows_dict.has("TerrainWindow"):
		return null
	var tw = windows_dict["TerrainWindow"]
	if tw == null or not is_instance_valid(tw):
		return null
	return tw


# Returns ASO's TerrainWindow clone if ASO is installed, else null.
#
# Detection by structural signature, scanning the entire scene tree — ASO does
# NOT place its window as a sibling of the native one. In practice ASO attaches
# its clone under Editor/VPartition (somewhere, unspecified), while DD's native
# lives under Editor/Windows. So any strategy that limits itself to a known
# parent will miss it.
#
# The discriminating signature we rely on:
#   - is a WindowDialog (filters out regular controls)
#   - has a PackList descendant (filters out other WindowDialogs like Export)
#   - has a TextureMenu descendant (same — drops Welcome, Help, etc.)
#   - has a LineEdit descendant (ASO's search bar — DD's native TerrainWindow
#     has zero LineEdit anywhere in its hierarchy)
#   - is NOT the instance referenced by editor.Windows["TerrainWindow"]
#
# Note: DD's NewTemplateWindow also has PackList+TextureMenu+LineEdit, so the
# "not native" check is what nails it down — ASO's clone is the *extra* window
# that has all three markers.
func find_aso_terrain_window(editor):
	if editor == null:
		return null

	# Shared cache: the found window AND the rescan throttle are per-process,
	# not per-instance — private ui_util instances (free_transform, text_*,
	# terrain_slots_extended) no longer each run their own full-tree scan.
	var cache = _shared_cache()

	# Fast path: a previously found ASO window, validated with cheap checks
	# only (instance validity + not the native window). No tree walk here, so
	# this is what keeps the Terrain tool from scanning the scene every frame.
	var cached_win = cache.get("aso_win", null)
	if cached_win != null and is_instance_valid(cached_win):
		var native_now = get_native_terrain_window(editor)
		if cached_win != native_now:
			return cached_win
		# Cached node has become the native window (rare) — drop and rescan.
		cache["aso_win"] = null

	# Throttle the expensive full-tree scan. When no ASO window currently
	# exists we only rescan periodically instead of on every call/frame. ASO
	# injects its window once at load, so a coarse interval is more than enough
	# to pick it up.
	var frame = Engine.get_frames_drawn()
	if cache.get("aso_win", null) == null and frame - int(cache.get("aso_scan_frame", -100000)) < _ASO_RESCAN_FRAMES:
		return null
	cache["aso_scan_frame"] = frame

	var native = get_native_terrain_window(editor)
	# We still need a tree to scan. Use the native's tree if we have one,
	# otherwise try the editor's.
	var tree_root = null
	if native != null and native.is_inside_tree():
		tree_root = native.get_tree().root
	elif editor.has_method("is_inside_tree") and editor.is_inside_tree():
		tree_root = editor.get_tree().root
	if tree_root == null:
		return null

	var candidates = []
	_collect_aso_candidates(tree_root, native, candidates, 0)
	# Prefer an exact name match if multiple structurally-valid candidates
	# exist (minimises odds of picking a misidentified similar-shaped window).
	var found = null
	for c in candidates:
		if c.name == "TerrainWindow":
			found = c
			break
	if found == null and candidates.size() > 0:
		found = candidates[0]

	cache["aso_win"] = found
	return found


func _collect_aso_candidates(node: Node, native, out: Array, depth: int) -> void:
	if depth > 20 or not is_instance_valid(node):
		return
	if node is WindowDialog and node != native:
		# Skip DD's own scripted windows — if it has a C# script, it's a
		# first-party DD window (Export, Preferences, ...), not ASO's clone.
		# ASO's window has no attached script on the root — it's a vanilla
		# scene instance with behavior wired in from TerrainWindowUI.gd.
		var s = node.get_script()
		var is_dd_scripted = false
		if s != null:
			var rp = s.resource_path
			if rp is String and rp.begins_with("res://"):
				is_dd_scripted = true
		if not is_dd_scripted \
				and _has_descendant_class(node, "LineEdit") \
				and _has_descendant_named(node, "PackList") \
				and _has_descendant_named(node, "TextureMenu"):
			out.append(node)
	for i in node.get_child_count():
		_collect_aso_candidates(node.get_child(i), native, out, depth + 1)


func _has_descendant_class(node: Node, cls: String) -> bool:
	if not is_instance_valid(node):
		return false
	if node.get_class() == cls:
		return true
	for i in node.get_child_count():
		if _has_descendant_class(node.get_child(i), cls):
			return true
	return false


func _has_descendant_named(node: Node, target: String) -> bool:
	if not is_instance_valid(node):
		return false
	if node.name == target:
		return true
	for i in node.get_child_count():
		if _has_descendant_named(node.get_child(i), target):
			return true
	return false


# Old helper, unused now but kept for API compat if anyone imports it.
func _has_lineedit_descendant(node: Node) -> bool:
	return _has_descendant_class(node, "LineEdit")


# The terrain window the user actually sees when clicking a terrain slot —
# ASO's custom window if ASO is installed, else the native one.
func get_active_terrain_window(editor):
	var aso = find_aso_terrain_window(editor)
	if aso != null:
		return aso
	return get_native_terrain_window(editor)


# True if `window` is ASO's clone (as opposed to DD's native instance).
func is_aso_terrain_window(editor, window) -> bool:
	if window == null:
		return false
	var aso = find_aso_terrain_window(editor)
	return aso != null and aso == window


# Shortcut: is ASO installed and has it injected its custom window?
func aso_terrain_window_present(editor) -> bool:
	return find_aso_terrain_window(editor) != null


# Back-compat shim for callers that used the earlier array-returning helper.
func find_terrain_windows(editor) -> Array:
	return [get_native_terrain_window(editor), find_aso_terrain_window(editor)]
