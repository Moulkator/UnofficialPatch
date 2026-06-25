# terrain_slots_extended.gd  —  up-to-24-slot terrain rendering + UI + painting
#
# Vanilla terrain handles at most 8 slots = 2 RGBA splats (splat, splat2) +
# texture_1..8, via the Terrain2.shader / SmoothTerrain2.shader shaders.
# To reach 16 slots we need:
#   - 2 extra splats (splat3, splat4)  → managed HERE, mod-side
#   - texture_9..16                    → managed HERE, mod-side
#   - a shader sampling 4 splats       → generated HERE from the exact
#                                         blend logic of DD's shaders
#
# IMPORTANT (verified C# limits):
#   - Terrain.SetTexture(i) ignores i >= 8 (internal array of 8) → we push
#     texture_9..16 ourselves as shader params.
#   - Terrain.Paint()/Fill() only know 2 splats → painting of slots 9-16 is
#     intercepted by this mod.
#
# 16-slot mode builds on the vanilla expanded mode (ExpandedSlots = true) as a
# base: DD already set splat/splat2/texture_1..8/map_size on the ShaderMaterial;
# we only add splat3/splat4/texture_9..16 and swap the shader. Uniform values
# already set persist across the shader swap as long as the names match.

const META_KEY = "Terrain16Driver"

# Injected by Main.gd (the real DD Global singleton). A bare `Global`
# reference in a Main-loaded helper is NOT the populated singleton, so the
# whole mod uses `_g` instead.
var _g = null

var _proc_node: Node = null

var _height16: Shader = null
var _smooth16: Shader = null

# Mod-side splat buffers (current map; will be keyed per-map for persistence).
var _splat3_img: Image = null
var _splat3_tex: ImageTexture = null
var _splat4_img: Image = null
var _splat4_tex: ImageTexture = null
var _splat5_img: Image = null
var _splat5_tex: ImageTexture = null
var _splat6_img: Image = null
var _splat6_tex: ImageTexture = null
var _zero_splat_tex: ImageTexture = null   # empty splat, bound to splat5/6 when 24-mode is off
var _buffers_for: Object = null   # the Terrain the buffers are valid for
var _active_terrain: Object = null  # (legacy, unused with per-level store)
# Per-level store: terrain instance_id -> {active, active24, expanded, smooth,
# s3..s6 (Image), t3..t6 (ImageTexture), zero}. Each level keeps its own splat
# buffers + texture objects bound to its own material, so all levels render
# extended terrain independently. The working _splat*_/_active vars always
# mirror the CURRENT level; we swap them when the viewed level changes.
var _lv := {}
var _cur_level_terrain: Object = null
# Level-clone support: copy a level's extended state + painted data to its clone.
var _newlevel_hooked := false
var _clone_btn = null
var _clone_levels_snapshot := []

var _active := false              # is our extended shader applied (slots 9-16)?
var _active24 := false            # slots 17-24 also on (requires _active)
var _native_expanded_before := false  # native ExpandedSlots state before we forced it
var _smooth_when_activated := false

# Painting
var _painting := false
var _paint_slot := 8              # current painted slot (0-23). 8 = slot 9 by default.
var _extra_selected := false      # True iff the user last selected a 9-24 slot
# DD's own soft_circle.png sampled into a radial falloff LUT, so the brush profile
# (and therefore the splat gradient, which IS the visible blend in Smooth mode)
# matches vanilla instead of an analytic curve.
var _brush_lut := []              # 256 entries, center(0) -> edge(255), weight 1 -> 0
var _brush_lut_ready := false
# Third-party "Set Terrain Slot" search panel (AdditionalSearchOptions mod).
var _ts_hooked := false
var _ts_btn = null
var _ts_inst = null
var _ts_method := ""
var _ts_hook_timer := 0
var _ui_util = null               # ui_util.gd for the over-UI click guard
var _UndoRecordScript = null

# stroke "before" snapshots for undo
var _stroke_b1: Image = null
var _stroke_b2: Image = null
var _stroke_b3: Image = null
var _stroke_b4: Image = null
var _stroke_b5: Image = null
var _stroke_b6: Image = null

# debug key edge-detection
var _f9_was_down := false
var _f11_was_down := false
var _next_was_down := false   # Page Down / KP+
var _prev_was_down := false   # Page Up / KP-

# temporary HUD (current slot + thumbnail), replaced by the panel UI
var _hud: CanvasLayer = null
var _hl_hint: CanvasLayer = null        # petite etiquette suivant le curseur en mode viewer
var _hl_hint_panel = null               # Control interne (visibilite fiable, cf. CanvasLayer.visible)
var _hl_hint_label = null
var _hud_panel: Control = null
var _hud_label: Label = null
var _hud_thumb: TextureRect = null

# UI injected into the Terrain panel
var _ui_injected := false
var _terrain_panel = null
var _section: VBoxContainer = null
var _toggle_btn: CheckButton = null
var _extra_list: ItemList = null      # slots 9-16 list (native control, vanilla style)
var _picker_btns := []                # 8 "change texture" buttons (9-16)
var _toggle_btn24: CheckButton = null
var _native_fill_btn = null   # DD's own "Fill" button (hidden while our mode is active)
var _fill_btn: Button = null  # our single "Fill" button (below all slots)
# Terrain presets (save/load a full 24-slot palette).
var _preset_dropdown: OptionButton = null
var _preset_name_edit: LineEdit = null
# Per-group (8 slots each) save/load selection checkboxes: g1=1-8, g2=9-16, g3=17-24.
var _save_g1: CheckBox = null
var _save_g2: CheckBox = null
var _save_g3: CheckBox = null
var _load_g1: CheckBox = null
var _load_g2: CheckBox = null
var _load_g3: CheckBox = null
# Copy/paste a group of 8 slots (in-session clipboard).
var _copyio_dropdown: OptionButton = null
var _paste_btn: Button = null
var _clipboard_group := []
var _slot_clipboard = null   # single-slot copy/paste (path) via right-click
var _slot_popup_layer: CanvasLayer = null   # high layer so the menu draws above UI
var _hl_slot := -1   # 0-based slot currently highlighted (-1 = off)
var _section24: VBoxContainer = null
var _wrap: VBoxContainer = null        # bloc injecté complet (toggles + listes + presets...)
var _extra_list24: ItemList = null    # slots 17-24 list
var _picker_btns24 := []              # 8 "change texture" buttons (17-24)
var _vanilla_list: ItemList = null    # primary vanilla list (style + click mapping)
var _vanilla_lists := []              # ALL native terrain ItemLists (deselect targets)
var _extra_paths := [null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null]
var _extra_sizes := []            # native px size of each slot 9-24 texture (per-level, aliases the _lv entry)
var _last_native_size := Vector2(1024, 1024)   # set by _load_image: source size BEFORE the array resize
var _last_tid := -2                    # to detect a vanilla slot change
var _tex_menu_icon = null

# Texture picker (popup)
var _picker_win: WindowDialog = null
var _picker_grid: GridContainer = null
var _picker_scroll: ScrollContainer = null
var _pack_list: ItemList = null
var _picker_slot := -1
var _terrain_paths := []
var _pack_groups := {}        # pack name -> [paths]
var _pack_order := []         # pack display order (native DD order: Default first)
var _thumb_by_path := {}      # path -> thumbnail ALREADY loaded by DD (native window scan)
var _scanned := false
var _thumb_cache := {}        # fallback: thumbnails regenerated if the native scan fails

# Popup Accept / toggle / Cancel bar (asset_cycle style)
var _picker_accept_required := true    # ON (default) = click previews, popup stays open; OFF = click applies + closes
var _picker_original_path = null       # slot's texture at open time, for Cancel
var _picker_was_open := false          # suivi inter-frame : détecte la fermeture du picker (Échap inclus)
# Favorites (shared with the "Favorites" mod). Terrain favorites = type 9.
var _fav_set := {}            # path -> true (terrain favorites only)
var _fav_icon = null          # star icon (fav2.png) reused from the Favorites mod
var _fav_badge_fallback = null  # local fav1.png badge if the Favorites mod is absent
var _fav_ctx_menu = null      # right-click context menu (Add/Remove from Favorites)
var terrain_paint_bucket = null  # sibling mod ref (injected by Main.gd)
var _fav_icon_loaded := false
var _picker_list_groups := [] # ordered groups shown in the pack list (FAV first if any)
var _picker_current_group := ""
var _search_edit: LineEdit = null
var _picker_search := ""
var _picker_accept_btn: Button = null
var _picker_cancel_btn: Button = null
var _picker_toggle_btn: Button = null
var _circle_icon = null

# Persistence (per-map sidecar in user://, since the .dungeondraft_map can't be
# written via the API). Meta JSON keyed by map path: { active, paths[8] }.
# Painted terrain (splat3/splat4) stored as PNGs keyed by a hash of the path.
const EXTRA_TEX_SIZE := 1024   # all slot 9-24 textures resized to this for the array.
                               # The array forces ONE size for every layer, so each
                               # texture is resized to fit. 1024 keeps the cost and
                               # VRAM (16 layers * 1024^2 * 4B = 64 MB per level) low.
                               # Raise to 2048 for sharper HD (>1024) textures, at 4x
                               # the VRAM and a slower first load (cached afterwards).
var _extra_array = null         # TextureArray holding slots 9-24 (1 sampler instead of 16)
var _img_cache := {}            # path -> {img, size}: load+resize each texture once
                                # (toggles/presets re-request the same ones; cache
                                # turns multi-second freezes into instant repeats)
const PERSIST_DIR := "user://UnofficialPatch"
const META_PATH := "user://UnofficialPatch/Terrain Slots Extended/terrain_slots_extended.json"
const PRESETS_PATH := "user://UnofficialPatch/Terrain Slots Extended/terrain_presets.json"
const SPLATS_DIR := "user://UnofficialPatch/Terrain Slots Extended/"
# Portable sidecar kept in user:// (NOT next to the map, to avoid clutter). One
# self-contained "<MapFile>.tslots" per map, keyed by the map's filename so it
# stays portable when shared. Bundles per-level meta + base64-embedded splat PNGs
# and is re-imported (re-keyed to the local full path) on open.
const COMPANION_DIR := "user://UnofficialPatch/Terrain Slots Extended/shared/"
const COMPANION_SUFFIX := ".tslots"
# Copie embarquee DANS la map : DD serialise Global.ModMapData dans le
# .dungeondraft_map et la restitue a l'ouverture (cf. ShadowBakeAll). On y range
# le MEME payload que le companion .tslots -> map auto-suffisante (un seul
# fichier a partager). Le .tslots reste ecrit en filet de securite.
const EMBED_KEY := "terrain_slots_extended"
# Auto-flush differe : DD serialise la map AVANT que nos hooks de save tournent,
# donc l'embed doit deja etre a jour au moment de la save. On reecrit le sidecar
# (qui peuple l'embed) peu apres la fin d'une edition, pour que n'importe quelle
# save (bouton/menu/Ctrl+S) embarque l'etat courant.
var _persist_dirty := false
var _persist_idle := 0
# Signature de contenu (hash) des splats par index de niveau, pour ne reencoder
# en PNG que les niveaux dont la PEINTURE a reellement change depuis la derniere
# ecriture. Reinitialise au changement de map.
var _splat_sig := {}
# Vrai pendant l'application d'un restore : empeche d'armer le flush differe et
# de reecrire/effacer le sidecar tant que l'etat n'est pas charge.
var _restoring := false
var _save_btn_hooked := false
var _save_menu_hooked := false
var _save_pending := -1            # frames countdown to a deferred sidecar write
var _last_world_id := -1           # detect map open/new (World recreated)
var _restore_pending := false
var _restore_frames := 0
var _restore_data_loaded := false
var _restore_entry = null
var _last_seen_map_path := ""
# Re-stamp différé des libellés/icônes natifs : après un restore, ExpandSlots
# fait reconstruire la liste vanilla par DD APRÈS notre set_item_text, écrasant
# nos labels (vide pour les packs manquants). On les repose pendant quelques
# frames pour passer après la reconstruction de DD.
var _nlbl_terrain = null
var _nlbl_frames := 0
var _nlbl_stable := 0   # frames consécutives sans rien à corriger → on arrête

# Default textures assigned to slots 9-16 on activation (changeable via the
# UI). See TerrainBrush.cs for safe vanilla paths.
const DEFAULT_EXTRA_TEXTURES = [
	"res://textures/terrain/terrain_moss.png",
	"res://textures/terrain/terrain_grass.png",
	"res://textures/terrain/terrain_sandstone.png",
	"res://textures/terrain/terrain_rocky.png",
]


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func start() -> void:
	# _g (the populated DD Global) MUST be injected by Main.gd before start():
	#   terrain_slots_extended._g = Global
	# A bare `Global` in a Main-loaded helper is the uninitialized class (Root = null),
	# which would turn every ResourceLoader.load(_g.Root + ...) into load(null).
	if _g == null:
		printerr("[TerrainSlotsExtended] _g was not injected by Main.gd "
			+ "(add `terrain_slots_extended._g = Global` before .start()) — aborting init.")
		return
	Engine.set_meta("terrain_slots_extended_singleton", self)
	_build_shaders()
	_load_helpers()
	_install_proc_node()
	_build_hud()
	print("[Terrain16] Initialized. F9 = toggle 16-slot mode, PageUp/PageDown (or numpad +/-) = slot, left click = paint, F11 = fill, Ctrl+Z = undo.")


func _load_helpers() -> void:
	# ui_util for the over-UI guard (standalone, no _g needed for is_mouse_over_ui).
	var u = ResourceLoader.load(_g.Root + "scripts/ui_util.gd", "GDScript", true)
	if u != null:
		_ui_util = u.new()
	# Undo record lives in library/ (same pattern as the sibling record-loaders,
	# e.g. terrain_paint_bucket). Load it directly: File.file_exists is unreliable
	# for packed mods, and ResourceLoader resolves the path regardless.
	_UndoRecordScript = ResourceLoader.load(_g.Root + "library/terrain_slots_extended_undo_record.gd", "GDScript", true)
	if _UndoRecordScript == null:
		print("[Terrain16] WARNING: could not load library/terrain_slots_extended_undo_record.gd -> undo disabled")


func _install_proc_node() -> void:
	# Standalone tool scripts don't necessarily get _process/_input from DD,
	# so we attach our own Node to the tree (same approach as terrain_paint_bucket).
	if Engine.has_meta(META_KEY):
		var old = Engine.get_meta(META_KEY)
		if is_instance_valid(old):
			old.handler = null
			old.queue_free()
	var node = Node.new()
	node.name = "Terrain16Driver"
	var s = GDScript.new()
	s.source_code = (
		"extends Node\n" +
		"var handler = null\n" +
		"func _process(d):\n" +
		"\tif handler: handler._tick(d)\n" +
		"func _input(e):\n" +
		"\tif handler and handler._on_input(e):\n" +
		"\t\tget_tree().set_input_as_handled()\n"
	)
	s.reload()
	node.set_script(s)
	node.handler = self
	Engine.set_meta(META_KEY, node)
	_g.Editor.get_tree().get_root().call_deferred("add_child", node)
	_proc_node = node


# ── Terrain access ────────────────────────────────────────────────────────────

func _get_terrain():
	if _g == null:
		return null
	var world = _g.get("World")
	if world == null:
		return null
	var level = world.call("GetCurrentLevel")
	if level == null:
		return null
	return level.get("Terrain")


func _get_material(terrain):
	if terrain == null:
		return null
	return terrain.get("material")


# ── Buffers splat3 / splat4 ───────────────────────────────────────────────────

# Write the working splat buffers back into the current level's store entry.
func _stash_current_buffers() -> void:
	if _buffers_for == null or not is_instance_valid(_buffers_for):
		return
	var id = _buffers_for.get_instance_id()
	var e = _lv.get(id, {})
	e["s3"] = _splat3_img; e["s4"] = _splat4_img; e["s5"] = _splat5_img; e["s6"] = _splat6_img
	e["t3"] = _splat3_tex; e["t4"] = _splat4_tex; e["t5"] = _splat5_tex; e["t6"] = _splat6_tex
	e["zero"] = _zero_splat_tex
	_lv[id] = e


func _save_level_state(terrain) -> void:
	if terrain == null or not is_instance_valid(terrain):
		return
	var id = terrain.get_instance_id()
	var e = _lv.get(id, {})
	e["active"] = _active; e["active24"] = _active24
	e["expanded"] = _native_expanded_before; e["smooth"] = _smooth_when_activated
	_lv[id] = e


func _load_level_state(terrain) -> void:
	var e = null
	if terrain != null and is_instance_valid(terrain):
		e = _lv.get(terrain.get_instance_id())
	if e == null:
		_active = false; _active24 = false
		_native_expanded_before = false; _smooth_when_activated = false
		return
	_active = e.get("active", false) == true
	_active24 = e.get("active24", false) == true
	_native_expanded_before = e.get("expanded", false) == true
	_smooth_when_activated = e.get("smooth", false) == true


# Detect when the viewed level changed and swap the working state to it.
func _sync_current_level() -> void:
	var cur = _get_terrain()
	if cur == _cur_level_terrain:
		return
	# Leaving the previous level: persist its state + buffers into the store.
	if _cur_level_terrain != null and is_instance_valid(_cur_level_terrain):
		_save_level_state(_cur_level_terrain)
		_stash_current_buffers()
	_cur_level_terrain = cur
	# Entering the new level: load its saved active flags (buffers load lazily).
	_load_level_state(cur)
	_load_level_palette(cur)   # swap to this level's own slot-texture palette
	# If this level should be active but its material doesn't carry our shader
	# yet (first visit after a reload), set it up now — expand only works while
	# the level is current, so it must happen here rather than at restore time.
	if _active and cur != null:
		var mat = _get_material(cur)
		if mat != null and mat.shader != _height16 and mat.shader != _smooth16:
			var saved_exp = _native_expanded_before
			activate(null, true)
			_native_expanded_before = saved_exp
	_apply_native_palette(cur)   # après l'expansion → 8 lignes pour les labels 5-8


func _ensure_buffers(terrain) -> bool:
	if terrain == null:
		return false
	var src = terrain.get("splatImage")     # base splat, to get the size
	if src == null:
		return false
	var w = src.get_width()
	var h = src.get_height()

	if _buffers_for == terrain and _splat3_img != null \
		and _splat3_img.get_width() == w and _splat3_img.get_height() == h:
		return true   # already the working set, right size

	# Switching levels: stash the level we are leaving so its paint is kept.
	if _buffers_for != null and _buffers_for != terrain:
		_stash_current_buffers()

	var id = terrain.get_instance_id()
	var e = _lv.get(id)
	var have := e != null and e.get("s3") != null \
		and e["s3"].get_width() == w and e["s3"].get_height() == h
	if have:
		# Restore this level's own buffers/textures as the working set.
		_splat3_img = e["s3"]; _splat4_img = e["s4"]; _splat5_img = e["s5"]; _splat6_img = e["s6"]
		_splat3_tex = e["t3"]; _splat4_tex = e["t4"]; _splat5_tex = e["t5"]; _splat6_tex = e["t6"]
		_zero_splat_tex = e["zero"]
		_buffers_for = terrain
	else:
		# New level (or size changed): fresh blank buffers + texture objects.
		_splat3_img = _new_splat(w, h); _splat3_tex = _new_splat_tex(_splat3_img)
		_splat4_img = _new_splat(w, h); _splat4_tex = _new_splat_tex(_splat4_img)
		_splat5_img = _new_splat(w, h); _splat5_tex = _new_splat_tex(_splat5_img)
		_splat6_img = _new_splat(w, h); _splat6_tex = _new_splat_tex(_splat6_img)
		_zero_splat_tex = _new_splat_tex(_new_splat(w, h))
		_buffers_for = terrain
	_stash_current_buffers()   # keep the store entry pointing at these objects
	# Bind the (restored or new) texture objects to THIS level's material.
	_push_extra_splats(_get_material(terrain))
	return true


func _new_splat(w: int, h: int) -> Image:
	var img = Image.new()
	img.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	return img


func _new_splat_tex(img: Image) -> ImageTexture:
	var t = ImageTexture.new()
	t.create_from_image(img, 4)   # flag 4 = FILTER (like DD)
	return t


# slots 9-24 live as layers of a single sampler2DArray, so the shader uses 1
# texture unit for all 16 (8 native + 1 array + 6 splats = 15 units, under the
# GL_MAX_TEXTURE_IMAGE_UNITS=16 floor that 24 separate samplers would blow).
func _new_extra_array():
	var arr = TextureArray.new()
	arr.create(EXTRA_TEX_SIZE, EXTRA_TEX_SIZE, 16, Image.FORMAT_RGBA8, Texture.FLAG_REPEAT | Texture.FLAG_FILTER)
	var blank = Image.new()
	blank.create(EXTRA_TEX_SIZE, EXTRA_TEX_SIZE, false, Image.FORMAT_RGBA8)
	blank.fill(Color(0, 0, 0, 0))
	for l in range(16):
		arr.set_layer_data(blank, l)
	return arr


# Default native sizes (one per slot 9-24). Empty slots fall back to the array
# size; real textures overwrite their entry with the source size on load.
func _default_sizes() -> Array:
	var a = []
	for _i in range(16):
		a.append(Vector2(EXTRA_TEX_SIZE, EXTRA_TEX_SIZE))
	return a


func _ensure_extra_array() -> void:
	if _extra_array != null and is_instance_valid(_extra_array):
		return
	_extra_array = _new_extra_array()
	_store_current_palette()


# The slot->texture palette (paths + the sampler2DArray) is PER LEVEL: each
# level keeps its own in its _lv entry; the working vars alias the current one.
func _store_current_palette() -> void:
	if _cur_level_terrain == null or not is_instance_valid(_cur_level_terrain):
		return
	var id = _cur_level_terrain.get_instance_id()
	var e = _lv.get(id, {})
	e["paths"] = _extra_paths
	e["array"] = _extra_array
	if _extra_sizes.size() == 16:
		e["sizes"] = _extra_sizes
	_lv[id] = e


func _load_level_palette(terrain) -> void:
	if terrain == null:
		return
	var id = terrain.get_instance_id()
	var e = _lv.get(id, {})
	if not (e.get("paths") is Array):
		e["paths"] = [null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null]
	if not (e.get("sizes") is Array) or e["sizes"].size() != 16:
		e["sizes"] = _default_sizes()
	if e.get("array") == null or not is_instance_valid(e["array"]):
		e["array"] = _new_extra_array()
		for i in range(16):
			if e["paths"][i] != null:
				var img = _load_image(e["paths"][i])
				if img != null:
					e["array"].set_layer_data(img, i)
					e["sizes"][i] = _last_native_size
	_lv[id] = e
	_extra_paths = e["paths"]
	_extra_array = e["array"]
	_extra_sizes = e["sizes"]
	_refresh_all_row_icons()


# Load a terrain texture as an Image (RGBA8, resized to the array size). Keeps
# the alpha (heightmap) for height blending. Never returns null.
#
# Cached by path: loading from a pack (decompress) + resizing is expensive, and
# toggling slots on/off or switching presets re-requests the SAME textures every
# time. Without a cache that meant several seconds of freeze per toggle; with it,
# each texture is processed once and every later toggle/preset is near-instant.
func _load_image(path):
	if path != null and _img_cache.has(path):
		var c = _img_cache[path]
		_last_native_size = c["size"]
		return c["img"]
	var img = null
	if path != null:
		var t = ResourceLoader.load(path)
		if t != null and t is Texture:
			img = t.get_data()
		if img == null:
			var im = Image.new()
			if im.load(path) == OK:
				img = im
		if img == null and _thumb_by_path.has(path) and _thumb_by_path[path] != null:
			img = _thumb_by_path[path].get_data()
	if img == null:
		if path != null:
			print("[Terrain16] Could not load terrain texture: ", path)
		img = Image.new()
		img.create(EXTRA_TEX_SIZE, EXTRA_TEX_SIZE, false, Image.FORMAT_RGBA8)
		img.fill(Color(1, 0, 1, 1))   # magenta = load failed (visible, not black)
		_last_native_size = Vector2(EXTRA_TEX_SIZE, EXTRA_TEX_SIZE)
		return img
	img.convert(Image.FORMAT_RGBA8)
	# Native pixel size BEFORE the array resize. The shader tiles this slot at
	# this size (like DD's world_uv/textureSize), so its PPI/scale matches the
	# source asset and the native slots — the storage resize no longer dictates
	# the on-screen scale.
	_last_native_size = Vector2(img.get_width(), img.get_height())
	if img.get_width() != EXTRA_TEX_SIZE or img.get_height() != EXTRA_TEX_SIZE:
		# Lanczos preserves detail when DOWNscaling a >array-size (HD) texture.
		# When UPscaling a smaller source, bilinear is far cheaper and looks the
		# same (upscaling can't add detail), so reserve Lanczos for downscales.
		var interp = Image.INTERPOLATE_LANCZOS
		if img.get_width() <= EXTRA_TEX_SIZE and img.get_height() <= EXTRA_TEX_SIZE:
			interp = Image.INTERPOLATE_BILINEAR
		img.resize(EXTRA_TEX_SIZE, EXTRA_TEX_SIZE, interp)
	if path != null:
		_img_cache[path] = {"img": img, "size": _last_native_size}
	return img


func _refresh_splat3() -> void:
	if _splat3_img != null and _splat3_tex != null:
		_splat3_tex.set_data(_splat3_img)


func _refresh_splat4() -> void:
	if _splat4_img != null and _splat4_tex != null:
		_splat4_tex.set_data(_splat4_img)


func _refresh_splat5() -> void:
	if _splat5_img != null and _splat5_tex != null:
		_splat5_tex.set_data(_splat5_img)


func _refresh_splat6() -> void:
	if _splat6_img != null and _splat6_tex != null:
		_splat6_tex.set_data(_splat6_img)


func _refresh_extra_splats() -> void:
	_refresh_splat3()
	_refresh_splat4()
	if _active24:
		_refresh_splat5()
		_refresh_splat6()


# Push splat3..6 to the shader. splat5/splat6 carry slots 17-24; when 24-mode is
# off they're bound to an empty texture so those slots read 0 (the painted data
# stays in the buffers for when 24-mode is re-enabled).
# Map resize: DD rebuilds the native splat/splat2 at the new size and repositions
# their content, but it never touches our extended splats (3..6) — so without
# this they keep the old size and the shader stretches them across the new map
# ("spreading"). We mirror DD's transform: blit the old content into a new-size
# image at the Left/Top offset (extend) or cropped (negative Left/Top).
func on_map_resized(left: int, top: int, old_mw: int, old_mh: int) -> void:
	var cur = _get_terrain()
	if cur == null or old_mw == 0 or old_mh == 0:
		return
	var src = cur.get("splatImage")
	if src == null:
		return
	var ntw = src.get_width()
	var nth = src.get_height()
	# Persist the current level's working buffers into its store entry first, so
	# every level (current + others) is resized uniformly below.
	_stash_current_buffers()
	# Map level terrains by id for per-material rebinding.
	var by_id := {}
	for lvl in _all_levels():
		var t = lvl.get("Terrain")
		if t != null:
			by_id[t.get_instance_id()] = t
	for lid in _lv.keys():
		var e = _lv[lid]
		if e.get("s3") == null:
			continue
		var otw = e["s3"].get_width()
		var oth = e["s3"].get_height()
		if otw == 0 or oth == 0:
			continue
		if left == 0 and top == 0 and ntw == otw and nth == oth:
			continue
		var px = float(otw) / float(old_mw)
		var py = float(oth) / float(old_mh)
		var src_x = int(round(max(0, -left) * px))
		var src_y = int(round(max(0, -top) * py))
		var dst_x = int(round(max(0, left) * px))
		var dst_y = int(round(max(0, top) * py))
		var copy_w = min(otw - src_x, ntw - dst_x)
		var copy_h = min(oth - src_y, nth - dst_y)
		for ik in ["s3", "s4", "s5", "s6"]:
			var old_img = e.get(ik)
			if old_img == null:
				continue
			var ni = Image.new()
			ni.create(ntw, nth, false, old_img.get_format())
			ni.fill(Color(0, 0, 0, 0))
			if copy_w > 0 and copy_h > 0:
				ni.blit_rect(old_img, Rect2(src_x, src_y, copy_w, copy_h), Vector2(dst_x, dst_y))
			e[ik] = ni
		e["t3"] = _new_splat_tex(e["s3"])
		e["t4"] = _new_splat_tex(e["s4"])
		e["t5"] = _new_splat_tex(e["s5"])
		e["t6"] = _new_splat_tex(e["s6"])
		e["zero"] = _new_splat_tex(_new_splat(ntw, nth))
		_lv[lid] = e
		# Rebind this level's material to its new texture objects.
		var lt = by_id.get(lid)
		if lt != null:
			var mat = _get_material(lt)
			if mat != null:
				mat.set_shader_param("extra_terrains", _extra_array)
				mat.set_shader_param("splat3", e["t3"])
				mat.set_shader_param("splat4", e["t4"])
				if e.get("active24", false) == true:
					mat.set_shader_param("splat5", e["t5"])
					mat.set_shader_param("splat6", e["t6"])
				else:
					mat.set_shader_param("splat5", e["zero"])
					mat.set_shader_param("splat6", e["zero"])
	# Reload the current level's (now resized) buffers as the working set.
	_buffers_for = null
	_ensure_buffers(cur)


# Push the 16 native-size uniforms (Godot 3.x has no uniform arrays, so these
# are 16 scalar vec2 uniforms extra_size_9..extra_size_24).
func _push_extra_sizes(mat) -> void:
	if mat == null:
		return
	if _extra_sizes.size() != 16:
		_extra_sizes = _default_sizes()
	for i in range(16):
		mat.set_shader_param("extra_size_" + str(9 + i), _extra_sizes[i])


func _push_extra_splats(mat) -> void:
	if mat == null:
		return
	_ensure_extra_array()
	mat.set_shader_param("extra_terrains", _extra_array)
	_push_extra_sizes(mat)
	mat.set_shader_param("splat3", _splat3_tex)
	mat.set_shader_param("splat4", _splat4_tex)
	if _active24:
		mat.set_shader_param("splat5", _splat5_tex)
		mat.set_shader_param("splat6", _splat6_tex)
	else:
		mat.set_shader_param("splat5", _zero_splat_tex)
		mat.set_shader_param("splat6", _zero_splat_tex)
	mat.set_shader_param("hl_on", _hl_slot >= 0)
	mat.set_shader_param("hl_slot", _hl_slot)


# The splat images that painting/fill may touch: 6 in 24-mode, 4 otherwise (so
# painting slots 9-16 never wipes the hidden 17-24 data when 24-mode is off).
func _paint_imgs(s1, s2) -> Array:
	if _active24:
		return [s1, s2, _splat3_img, _splat4_img, _splat5_img, _splat6_img]
	return [s1, s2, _splat3_img, _splat4_img]


# ── Delegation API for terrain_paint_bucket (Square / Bucket on slots 9-24) ──
#
# The bucket computes WHICH splat pixels to paint; when an extended slot is
# active it hands them here so we write into splat3..6 with the same
# normalization our brush uses (instead of the vanilla 2-splat write).

# Slot the paint bucket should target: our active extended slot (>=8) or -1.
func paint_bucket_slot() -> int:
	return _active_extra_slot()


# True when our 16/24-slot mode is on. The bucket/square route ALL paints
# through extra_paint_pixels then (even vanilla slots 0-7), so a vanilla fill
# also clears the extended splats 3..6 under it (otherwise the extended terrain
# shows through, since the shader normalizes by the sum of all channels).
func is_extended_active() -> bool:
	return _active


# Snapshot the 6 splats for undo (mirrors a brush stroke begin) WITHOUT
# starting our continuous brush — the bucket/square owns the painting.
func extra_stroke_begin() -> void:
	_stroke_begin(false)


# Record the 6-splat undo for the just-finished delegated stroke.
func extra_stroke_end() -> void:
	# The delegated (square/bucket) path never sets _painting — extra_stroke_begin
	# calls _stroke_begin(false) so the continuous round brush doesn't run. So we
	# CAN'T route through _stroke_end(), which bails on `if not _painting`
	# (that's why undo was missing for square brush / bucket on slots 9+).
	# Record the snapshot directly here.
	_record_history(_stroke_b1, _stroke_b2, _stroke_b3, _stroke_b4, _stroke_b5, _stroke_b6)
	_stroke_b1 = null
	_stroke_b2 = null
	_stroke_b3 = null
	_stroke_b4 = null
	_stroke_b5 = null
	_stroke_b6 = null


# Apply weighted paint to a set of splat pixels: Array of [x, y, weight].
# weight 1.0 = pure terrain (square brush); fractional = soft edge (bucket).
func extra_paint_pixels(slot: int, pixels: Array) -> void:
	# slot 0-7 writes the vanilla channel in splat/splat2 (and clears 3..6);
	# slot 8-23 writes splat3..6. Either way all other channels are zeroed.
	if slot < 0:
		return
	if _hl_slot >= 0:
		return   # highlight mode: painting (incl. bucket/square) is disabled
	var terrain = _get_terrain()
	if terrain == null or not _ensure_buffers(terrain):
		return
	var s1 = terrain.get("splatImage")
	var s2 = terrain.get("splatImage2")
	if s1 == null or s2 == null:
		return
	var imgs = _paint_imgs(s1, s2)
	var tgt_img = slot / 4
	var tgt_ch = slot % 4
	if tgt_img >= imgs.size():
		return
	var w = s1.get_width()
	var h = s1.get_height()
	for img in imgs:
		img.lock()
	for pp in pixels:
		var x = int(pp[0])
		var y = int(pp[1])
		var t = clamp(float(pp[2]), 0.0, 1.0)
		if t <= 0.0 or x < 0 or y < 0 or x >= w or y >= h:
			continue
		_paint_pixel(imgs, x, y, tgt_img, tgt_ch, t)
	for img in imgs:
		img.unlock()
	terrain.UpdateSplat()
	_refresh_extra_splats()


# Called by the undo record to restore our splats (splat3..6; nulls skipped).
func restore_extra_splats(img3, img4, img5, img6) -> void:
	if img3 != null and _splat3_img != null:
		_splat3_img.copy_from(img3)
	if img4 != null and _splat4_img != null:
		_splat4_img.copy_from(img4)
	if img5 != null and _splat5_img != null:
		_splat5_img.copy_from(img5)
	if img6 != null and _splat6_img != null:
		_splat6_img.copy_from(img6)
	_refresh_splat3()
	_refresh_splat4()
	_refresh_splat5()
	_refresh_splat6()
	var terrain = _get_terrain()
	var mat = _get_material(terrain)
	if mat != null:
		_push_extra_splats(mat)


# ── 16-slot shader activation ─────────────────────────────────────────────────

# The "Unlock 4 more slots" control (a CheckButton). Driving it (instead of
# Terrain.ExpandSlots directly) keeps DD's button state and the vanilla list
# UI in sync — so enabling our extra slots also turns this option ON visibly.
func _expand_slots_button():
	if _g == null or _g.get("Editor") == null:
		return null
	var tb = _g.Editor.Tools["TerrainBrush"]
	if tb == null:
		return null
	var b = tb.Controls["ExpandSlotsButton"]
	if b != null and is_instance_valid(b):
		return b
	return null


func _set_native_expand(on: bool, quiet := false) -> void:
	if quiet:
		# Programmatic (restore / level switch): drive the data directly instead
		# of clicking the tool's UI button, which can wake the brush preview.
		var t = _get_terrain()
		if t != null:
			t.ExpandSlots(on)
		return
	var btn = _expand_slots_button()
	if btn != null:
		if btn.pressed != on:
			btn.pressed = on   # emits "toggled" -> DD expands/collapses + updates UI
		return
	# Fallback: drive the data directly if the button is not reachable.
	var terrain = _get_terrain()
	if terrain != null:
		terrain.ExpandSlots(on)


func activate(terrain, quiet := false) -> bool:
	if terrain == null:
		terrain = _get_terrain()
	if terrain == null:
		return false
	# Extended mode requires the vanilla expanded mode (8 native slots) as a base.
	# Remember the native ExpandedSlots state so we can restore it on deactivate.
	_native_expanded_before = terrain.get("ExpandedSlots") == true
	if not _native_expanded_before:
		_set_native_expand(true, quiet)
	if not _ensure_buffers(terrain):
		return false
	var mat = _get_material(terrain)
	if mat == null:
		return false

	_ensure_extra_array()
	_push_extra_splats(mat)   # also binds the extra_terrains array
	# Unassigned array layers are transparent; combined with a 0 splat channel
	# they contribute nothing.

	_smooth_when_activated = terrain.get("SmoothBlending") == true
	mat.shader = _smooth16 if _smooth_when_activated else _height16
	_active = true
	_active_terrain = terrain
	_assign_default_extra_textures(terrain)
	_post_activate_ui()
	return true


func deactivate(terrain) -> void:
	if terrain == null:
		terrain = _get_terrain()
	_active = false
	_active24 = false
	_extra_selected = false
	_active_terrain = null
	_post_deactivate_ui()
	if terrain == null:
		return
	# Hand the shader back to DD according to the current smooth state.
	terrain.SetSmoothBlending(terrain.get("SmoothBlending") == true)
	# Restore the native "unlock 4 more slots" state we had before activating:
	# if the user only had 4 native slots, collapse back to 4.
	if not _native_expanded_before and terrain.get("ExpandedSlots") == true:
		_set_native_expand(false)


func set_slot_texture(terrain, slot: int, texture: Texture) -> void:
	# slot 8..15 (0-based) → texture_9..16
	if terrain == null:
		terrain = _get_terrain()
	var mat = _get_material(terrain)
	if mat == null:
		return
	if slot < 8 or slot > 15:
		return
	mat.set_shader_param("texture_" + str(slot + 1), texture)


# ── Tick: shader re-assertion ─────────────────────────────────────────────────

func _tick(delta) -> void:
	# Surveillance de la fermeture du picker, indépendante de l'input : si le
	# picker était ouvert puis s'est fermé et que l'outil terrain a été désactivé
	# dans la foulée (DD traite Échap dans son _Input natif et bascule l'outil,
	# ce qu'on ne peut pas bloquer de façon fiable), on rebascule sur TerrainBrush.
	# Pour une fermeture normale (Accept/Cancel/clic/X), l'outil reste TerrainBrush
	# et la restauration est un no-op. call_deferred pour passer après le _process
	# de DD si jamais c'est lui qui bascule l'outil.
	var picker_open_now := is_picker_open()
	if _picker_was_open and not picker_open_now:
		call_deferred("_restore_terrain_tool")
	_picker_was_open = picker_open_now

	_persist_tick()
	_sync_current_level()
	_hook_new_level_window()
	_try_inject_ui()
	_try_hook_set_terrain_slot()
	_handle_debug_keys()
	_sync_panel_to_active()
	if _ui_injected:
		_hide_hud()
	else:
		_update_hud()
	_update_hl_hint()

	# Continuous painting (like TerrainBrush._Update: rate = delta * Intensity).
	if _painting and _hl_slot < 0 and _on_active_terrain() and not _paint_bucket_owns_input():
		var world_ui = _g.get("WorldUI")
		if world_ui != null:
			var over_ui = _ui_util != null and _ui_util.is_mouse_over_ui(_proc_node)
			if not over_ui:
				var mp = world_ui.get("MousePosition")
				if mp != null:
					paint_at(mp, delta * _get_intensity(), _paint_slot)

	# Each active level keeps its own shader on its own material, so every level
	# renders its extended terrain independently. We maintain the CURRENT level
	# here (others persist what was bound when last visited).
	if _active:
		var terrain = _get_terrain()
		if terrain == null:
			return
		var mat = _get_material(terrain)
		if mat == null:
			return
		# Make the working buffers track the current level (fast-path no-op if
		# already correct) so paint/refresh hit this level's textures.
		_ensure_buffers(terrain)
		var smooth_now = terrain.get("SmoothBlending") == true
		var want = _smooth16 if smooth_now else _height16
		if mat.shader != want:
			_push_extra_splats(mat)
			mat.shader = want
			_smooth_when_activated = smooth_now
		if _native_fill_btn != null and is_instance_valid(_native_fill_btn) and _native_fill_btn.visible:
			_native_fill_btn.visible = false
		# Keep the vanilla slot list deselected while an extra slot (9-24) is the
		# active paint slot. Done deferred so it runs AFTER DD's own panel
		# _process, which otherwise re-selects the vanilla slot every frame and
		# undoes an immediate call.
		if _extra_selected:
			call_deferred("_enforce_vanilla_deselect")


func _on_input(e) -> bool:
	# Ctrl+S: schedule a sidecar write (don't consume; DD still saves). Checked
	# before the _active gate so it works even when 16-slot mode is off.
	if e is InputEventKey and e.pressed and not e.echo and e.scancode == KEY_S and e.control:
		_save_pending = 12
		return false

	# Texture picker open: SHIFT+wheel cycles the highlighted texture, and we
	# consume it so the normal slot cycling (asset_cycle) stays disabled while
	# the popup is up (asset_cycle also checks is_picker_open()).
	if is_picker_open():
		if e is InputEventMouseButton and e.pressed and (e.button_index == BUTTON_WHEEL_UP or e.button_index == BUTTON_WHEEL_DOWN):
			if Input.is_key_pressed(KEY_SHIFT) and not Input.is_key_pressed(KEY_CONTROL):
				_cycle_picker_selection(e.button_index == BUTTON_WHEEL_UP)
				return true

	# In 16-slot mode we intercept the terrain brush painting: vanilla Paint()
	# would break on channels 8-15 and ignore splat3/splat4.
	_sync_current_level()

	# Clic droit sur la map : bascule le surlignage des zones peintes pour le slot
	# COURANT (remplace l'ancienne entree du menu contextuel des slots). Un 2e clic
	# droit le coupe. Fonctionne meme depuis le mode vanilla : on active notre
	# shader au besoin pour que le surlignage s'affiche, comme le faisait le menu.
	if e is InputEventMouseButton and e.button_index == BUTTON_RIGHT and e.pressed:
		if _is_terrain_tool_active() and not is_picker_open() and not _over_ui():
			_toggle_map_highlight()
			return true

	if not _active:
		return false
	if not _on_active_terrain():
		return false
	if not _is_terrain_tool_active():
		return false
	# When terrain_paint_bucket is in Square or Bucket mode it owns the click;
	# don't run our normal-brush painting (it would paint over that result).
	if _paint_bucket_owns_input():
		return false

	# Handle RELEASE first, outside the UI guard: end our stroke only if we were
	# painting. Otherwise we do NOT consume the event, so a release that isn't
	# ours (e.g. a scrollbar drag that drifted off the panel) still reaches its
	# control.
	if e is InputEventMouseButton and e.button_index == BUTTON_LEFT and not e.pressed:
		if _painting:
			_stroke_end()
			return true
		return false

	# For press, ignore if the cursor is over any editor UI (incl. the bottom
	# level bar that ui_util's heuristic misses).
	if _over_ui():
		return false
	if e is InputEventMouseButton and e.button_index == BUTTON_LEFT and e.pressed:
		if _hl_slot >= 0:
			return true   # highlight mode: swallow the click, no painting
		_stroke_begin()
		return true
	if e is InputEventMouseMotion and _painting:
		return true   # painting happens in _tick; consume to block DD
	return false


# Mouse over editor UI? ui_util only guards the top bar + side panels, missing
# the bottom level bar (appears with 2+ levels) — clicking it would paint. We
# add a generic hit-test for any visible UI Control under the cursor, ignoring
# the near-fullscreen world canvas.
func _over_ui() -> bool:
	if _ui_util != null and _ui_util.is_mouse_over_ui(_proc_node):
		return true
	return _mouse_over_editor_ui()


func _mouse_over_editor_ui() -> bool:
	if _proc_node == null:
		return false
	var vp = _proc_node.get_viewport()
	if vp == null:
		return false
	var root = vp
	if _g != null and _g.get("Editor") != null:
		root = _g.Editor
	return _hit_editor_ui(root, vp.get_mouse_position(), vp.size)


func _hit_editor_ui(node, mouse, vp_size) -> bool:
	if node is Control:
		if not node.visible:
			return false
		if node.mouse_filter != Control.MOUSE_FILTER_IGNORE:
			var r = node.get_global_rect()
			# Only flag SHORT horizontal bars (top/bottom floatbars). The tall world
			# canvas and side panels are never flagged here (ui_util handles those),
			# so we never suppress painting on the canvas.
			if r.size.x > 0 and r.size.y > 0 and r.has_point(mouse) and r.size.y < vp_size.y * 0.4:
				return true
	for c in node.get_children():
		if _hit_editor_ui(c, mouse, vp_size):
			return true
	return false


# Extended mode is bound to one Terrain (one level). On any other level we
# stay completely inert so that level behaves like vanilla.
func _on_active_terrain() -> bool:
	# Working state always mirrors the current level, so this is just _active.
	return _active


# Keep the panel (checkbox + sections) reflecting whether extended mode is on
# for the CURRENT level, so it reads correctly when switching levels.
func _sync_panel_to_active() -> void:
	# DD réutilise la même colonne d'options (`Align`) d'un outil à l'autre et
	# nettoie SES propres contrôles au changement d'outil, mais pas notre bloc
	# injecté (`_wrap`), qu'il ne connaît pas. Résultat sans garde : le bloc
	# (toggle "Slots 9-16", listes, presets…) reste orphelin et déborde dans le
	# panneau de l'outil suivant. On lie donc sa visibilité à "TerrainBrush actif".
	var terrain_active := _is_terrain_tool_active()
	if _wrap != null and is_instance_valid(_wrap):
		_wrap.visible = terrain_active

	var on = _on_active_terrain()
	if _toggle_btn != null and is_instance_valid(_toggle_btn):
		_toggle_btn.set_pressed_no_signal(on)
	if _section != null and is_instance_valid(_section):
		_section.visible = on
	if _toggle_btn24 != null and is_instance_valid(_toggle_btn24):
		_toggle_btn24.set_pressed_no_signal(on and _active24)
	if _section24 != null and is_instance_valid(_section24):
		_section24.visible = on and _active24


func _is_terrain_tool_active() -> bool:
	if _g == null or _g.get("Editor") == null:
		return false
	return _g.Editor.get("ActiveToolName") == "TerrainBrush"


# True when the terrain_paint_bucket sibling is in Square or Bucket mode, in
# which case it (not our brush) should handle the click.
func _paint_bucket_owns_input() -> bool:
	if terrain_paint_bucket == null or not is_instance_valid(terrain_paint_bucket):
		return false
	if terrain_paint_bucket.get("_square_brush_active") == true:
		return true
	if terrain_paint_bucket.get("_bucket_active") == true:
		return true
	return false


# Optional fine multiplier on the brush rate (1.0 = native strength). The real
# fix for the "feel" is the brush PROFILE below, not intensity — leave at 1.0
# unless you specifically want the brush weaker/stronger than vanilla.
const PAINT_INTENSITY_SCALE := 1.0


func _get_intensity() -> float:
	var tool = _get_terrain_tool()
	if tool != null and tool.get("Intensity") != null:
		return float(tool.get("Intensity")) * PAINT_INTENSITY_SCALE
	return 4.0 * PAINT_INTENSITY_SCALE


func _get_terrain_tool():
	if _g == null or _g.get("Editor") == null:
		return null
	return _g.Editor.Tools["TerrainBrush"]


# ── Debug controls ────────────────────────────────────────────────────────────

func _handle_debug_keys() -> void:
	# F9 is a global shortcut to toggle 16-slot mode
	# (kept in sync with the panel checkbox).
	var f9 = Input.is_key_pressed(KEY_F9)
	if f9 and not _f9_was_down:
		# Toggle extended mode on the CURRENT level (each level is independent).
		if _active:
			deactivate(null)
		else:
			activate(null)
	_f9_was_down = f9


func _assign_default_extra_textures(terrain) -> void:
	var picks = _build_default_paths()
	var n = 16 if _active24 else 8
	for i in range(n):
		# Push every slot's texture to the shader: a restored/chosen path if set,
		# otherwise the default. (Restored choices must be pushed too, e.g. when
		# toggling a mode on after a load.)
		var path = _extra_paths[i] if _extra_paths[i] != null else picks[i]
		_set_extra_slot(8 + i, path)


# Builds the 8 default paths for slots 9-16. Terrains from loaded custom packs
# take priority; any remaining slots fall back to the vanilla defaults.
func _build_default_paths() -> Array:
	var custom = _collect_custom_pack_terrains()
	var result = []
	for i in range(16):
		if i < custom.size():
			result.append(custom[i])
		else:
			result.append(DEFAULT_EXTRA_TEXTURES[i % DEFAULT_EXTRA_TEXTURES.size()])
	return result


# Terrain paths from loaded custom packs (res://packs/...), in catalog order
# (packs alphabetical). Vanilla terrains (res://textures/...) are excluded.
func _collect_custom_pack_terrains() -> Array:
	_ensure_catalog()
	var out = []
	for pack in _pack_order:
		for path in _pack_groups.get(pack, []):
			if path is String and path.begins_with("res://packs/") and not (path in out):
				out.append(path)
	return out


# ── Temporary HUD (current slot + thumbnail) ──────────────────────────────────

func _build_hud() -> void:
	_hud = CanvasLayer.new()
	_hud.layer = 128

	_hud_panel = PanelContainer.new()
	_hud_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_panel.rect_position = Vector2(12, 58)

	var vb = VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_panel.add_child(vb)

	_hud_label = Label.new()
	_hud_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(_hud_label)

	_hud_thumb = TextureRect.new()
	_hud_thumb.rect_min_size = Vector2(96, 96)
	_hud_thumb.expand = true
	_hud_thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_hud_thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(_hud_thumb)

	_hud.add_child(_hud_panel)
	_hud_panel.visible = false
	_g.Editor.get_tree().get_root().call_deferred("add_child", _hud)


func _hide_hud() -> void:
	if _hud_panel != null:
		_hud_panel.visible = false


# Etiquette "right click: exit area viewer" affichee a cote du curseur tant que
# le surlignage des zones peintes est actif (clic droit sur la map).
func _build_hl_hint() -> void:
	_hl_hint = CanvasLayer.new()
	_hl_hint.layer = 128
	var panel = PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.72)
	style.set_border_width_all(1)
	style.border_color = Color(1, 1, 1, 0.25)
	style.content_margin_left = 6
	style.content_margin_right = 6
	style.content_margin_top = 3
	style.content_margin_bottom = 3
	panel.add_stylebox_override("panel", style)
	_hl_hint_label = Label.new()
	_hl_hint_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hl_hint_label.align = Label.ALIGN_CENTER
	_hl_hint_label.text = "Right click to exit\nthe Area Viewer"
	panel.add_child(_hl_hint_label)
	_hl_hint.add_child(panel)
	_hl_hint_panel = panel
	panel.visible = false
	_g.Editor.get_tree().get_root().call_deferred("add_child", _hl_hint)


func _update_hl_hint() -> void:
	var want = _hl_slot >= 0 and _is_terrain_tool_active()
	if _hl_hint == null:
		if not want:
			return
		_build_hl_hint()
	if _hl_hint_panel == null or not is_instance_valid(_hl_hint_panel):
		return
	_hl_hint_panel.visible = want
	if want:
		var mp = _g.Editor.get_tree().get_root().get_mouse_position()
		_hl_hint_panel.rect_position = mp + Vector2(18, 18)


func _update_hud() -> void:
	if _hud_panel == null:
		return
	if not _active:
		_hud_panel.visible = false
		return
	_hud_panel.visible = true
	if _hud_label != null:
		_hud_label.text = "Terrain16 — Slot %d / %d" % [_paint_slot + 1, (24 if _active24 else 16)]
	if _hud_thumb != null:
		_hud_thumb.texture = _current_slot_texture()


func _current_slot_texture():
	var terrain = _get_terrain()
	if terrain == null:
		return null
	if _paint_slot < 8:
		return terrain.GetTexture(_paint_slot)
	return _thumb(_extra_paths[_paint_slot - 8])


# ── Paint engine (16 slots, normalization across 4 splats) ────────────────────
#
# Replicates the vanilla terrain brush semantics: for each splat pixel under the
# brush, push the target channel toward 1 and ALL other channels (across the 4
# splats) toward 0, proportionally to t = falloff * rate. The shader then
# normalizes by the weight sum, so the sum≈1 invariant holds.

func paint_at(world_pos, rate: float, slot: int) -> void:
	if _hl_slot >= 0:
		return   # highlight mode disables painting
	var terrain = _get_terrain()
	if terrain == null or not _ensure_buffers(terrain):
		return
	var s1 = terrain.get("splatImage")
	var s2 = terrain.get("splatImage2")
	if s1 == null or s2 == null:
		return
	_ensure_brush_lut()
	var w = s1.get_width()
	var h = s1.get_height()

	# Center in splat pixels, with half-pixel compensation (cf. square brush).
	var origin = terrain.TextureToWorld(Vector2.ZERO)
	var one = terrain.TextureToWorld(Vector2(1, 1))
	var px = one - origin
	var center = terrain.WorldToTexture(world_pos - px * 0.5)

	# Rayon en pixels splat = GetBrushRadius() * BlobFactor = Size * 2.
	var size_val = 8.0
	var tool = _get_terrain_tool()
	if tool != null and tool.get("Size") != null:
		size_val = float(tool.get("Size"))
	var r = max(1.0, size_val * 2.0)

	var min_x = int(max(0, floor(center.x - r)))
	var max_x = int(min(w - 1, ceil(center.x + r)))
	var min_y = int(max(0, floor(center.y - r)))
	var max_y = int(min(h - 1, ceil(center.y + r)))
	if min_x > max_x or min_y > max_y:
		return

	var tgt_img = slot / 4     # 0..5 -> which splat holds the slot
	var tgt_ch = slot % 4      # 0..3 -> which channel

	var imgs = _paint_imgs(s1, s2)
	for img in imgs:
		img.lock()
	for y in range(min_y, max_y + 1):
		for x in range(min_x, max_x + 1):
			var dx = (float(x) + 0.5) - center.x
			var dy = (float(y) + 0.5) - center.y
			var d = sqrt(dx * dx + dy * dy) / r
			if d > 1.0:
				continue
			var t = clamp(_brush_weight(d) * rate, 0.0, 1.0)
			if t <= 0.0:
				continue
			_paint_pixel(imgs, x, y, tgt_img, tgt_ch, t)
	for img in imgs:
		img.unlock()

	terrain.UpdateSplat()      # refresh DD's splat / splat2 textures
	_refresh_extra_splats()


func _dup(img):
	return img.duplicate() if img != null else null


func _falloff(d: float) -> float:
	# Soft, wide analytic fallback used only if soft_circle.png can't be loaded.
	# Gaussian-like with a forced zero at the edge: gives a gentle gradient across
	# the whole radius (NOT a broad flat core like smoothstep, which painted hard
	# saturated blocks once the per-frame floor was removed).
	var x = clamp(d, 0.0, 1.0)
	return exp(-3.0 * x * x) * (1.0 - x)


# Build a 256-entry radial falloff LUT from DD's own soft_circle.png so the brush
# profile and effective radius match vanilla exactly. soft_circle is radially
# symmetric, so a 1D center->edge profile is lossless.
func _ensure_brush_lut() -> void:
	if _brush_lut_ready:
		return
	_brush_lut_ready = true   # attempt once; on failure we keep the soft fallback
	var res = load("res://textures/brushes/soft_circle.png")
	var bimg = null
	if res is Image:
		bimg = res
	elif res != null and res is Texture:
		bimg = res.get_data()
	if bimg == null:
		print("[Terrain16] soft_circle.png unavailable; using soft analytic falloff.")
		return
	bimg.convert(Image.FORMAT_RGBA8)
	var bw = bimg.get_width()
	var bh = bimg.get_height()
	if bw < 2 or bh < 2:
		return
	bimg.lock()
	var cx = float(bw) * 0.5
	var cy = float(bh) * 0.5
	var half = min(cx, cy) - 1.0
	# Pick the channel that encodes the falloff: alpha (white-on-transparent) or
	# luminance (grayscale-on-opaque) — whichever drops more from center to edge.
	var c_ctr = bimg.get_pixel(int(cx), int(cy))
	var c_edge = bimg.get_pixel(int(min(cx + half, float(bw - 1))), int(cy))
	var lum_ctr = c_ctr.r * 0.299 + c_ctr.g * 0.587 + c_ctr.b * 0.114
	var lum_edge = c_edge.r * 0.299 + c_edge.g * 0.587 + c_edge.b * 0.114
	var use_alpha = (c_ctr.a - c_edge.a) >= (lum_ctr - lum_edge)
	var lut = []
	lut.resize(256)
	for i in range(256):
		var rf = float(i) / 255.0
		var sx = clamp(cx + rf * half, 0.0, float(bw - 1))
		var c = bimg.get_pixel(int(sx), int(cy))
		var v = c.a if use_alpha else (c.r * 0.299 + c.g * 0.587 + c.b * 0.114)
		lut[i] = clamp(v, 0.0, 1.0)
	bimg.unlock()
	var peak = lut[0]
	if peak > 0.0001:
		for i in range(256):
			lut[i] = clamp(lut[i] / peak, 0.0, 1.0)
	_brush_lut = lut
	print("[Terrain16] soft_circle brush LUT built (channel=%s)." % ("alpha" if use_alpha else "luma"))


# Brush weight at normalized radius d (0 = center, 1 = edge), interpolated from
# the LUT. Falls back to the soft analytic curve if the LUT couldn't be built.
func _brush_weight(d: float) -> float:
	if _brush_lut.size() != 256:
		return _falloff(d)
	var f = clamp(d, 0.0, 1.0) * 255.0
	var i0 = int(f)
	if i0 >= 255:
		return _brush_lut[255]
	return lerp(_brush_lut[i0], _brush_lut[i0 + 1], f - float(i0))


func _chan(c: Color, ch: int) -> float:
	match ch:
		0: return c.r
		1: return c.g
		2: return c.b
		_: return c.a


# Paint one splat pixel across all active splat images: push the target channel
# toward 1 by t and ALL other channels (this image + the others) toward 0 by t.
# Growth is purely lerp(old, 1, t) — no flat per-frame floor, so the deposit
# tracks the (now scaled) rate and the painted base slot keeps the pixel filled.
func _paint_pixel(imgs: Array, x: int, y: int, tgt_img: int, tgt_ch: int, t: float) -> void:
	var old_t = _chan(imgs[tgt_img].get_pixel(x, y), tgt_ch)
	var new_t = lerp(old_t, 1.0, t)
	# Splats are stored as Rgba8 with TRUNCATION. If the target channel can't gain
	# at least one 8-bit step this frame, treat the pixel as a no-op: do NOT erode
	# the other channels either. Otherwise the base would truncate downward while
	# the target stays stuck at 0, collapsing the splat sum to 0 (black) at low
	# intensity. This also reproduces vanilla, where painting below a threshold
	# (~0.9 on the slider) simply does nothing.
	if int(new_t * 255.0) <= int(old_t * 255.0):
		return
	for i in range(imgs.size()):
		var c = imgs[i].get_pixel(x, y)
		var nc = Color(lerp(c.r, 0.0, t), lerp(c.g, 0.0, t), lerp(c.b, 0.0, t), lerp(c.a, 0.0, t))
		if i == tgt_img:
			match tgt_ch:
				0: nc.r = new_t
				1: nc.g = new_t
				2: nc.b = new_t
				_: nc.a = new_t
		imgs[i].set_pixel(x, y, nc)


func _blend_color(c: Color, target_ch: int, t: float) -> Color:
	var rr = 1.0 if target_ch == 0 else 0.0
	var gg = 1.0 if target_ch == 1 else 0.0
	var bb = 1.0 if target_ch == 2 else 0.0
	var aa = 1.0 if target_ch == 3 else 0.0
	return Color(
		lerp(c.r, rr, t),
		lerp(c.g, gg, t),
		lerp(c.b, bb, t),
		lerp(c.a, aa, t))


func _channel_color(ch: int) -> Color:
	match ch:
		0: return Color(1, 0, 0, 0)
		1: return Color(0, 1, 0, 0)
		2: return Color(0, 0, 1, 0)
		3: return Color(0, 0, 0, 1)
	return Color(0, 0, 0, 0)


# ── Fill ──────────────────────────────────────────────────────────────────────

func fill_slot(slot: int) -> void:
	var terrain = _get_terrain()
	if terrain == null or not _ensure_buffers(terrain):
		return
	var s1 = terrain.get("splatImage")
	var s2 = terrain.get("splatImage2")
	if s1 == null or s2 == null:
		return
	var tgt_img = slot / 4
	var tgt_ch = slot % 4
	var imgs = _paint_imgs(s1, s2)
	for i in range(imgs.size()):
		if i == tgt_img:
			imgs[i].fill(_channel_color(tgt_ch))
		else:
			imgs[i].fill(Color(0, 0, 0, 0))
	terrain.UpdateSplat()
	_refresh_extra_splats()


func do_fill(slot: int) -> void:
	var terrain = _get_terrain()
	if terrain == null:
		return
	var b1 = terrain.CloneSplatImage()
	var b2 = terrain.CloneSplatImage2()
	var b3 = _dup(_splat3_img)
	var b4 = _dup(_splat4_img)
	var b5 = _dup(_splat5_img) if _active24 else null
	var b6 = _dup(_splat6_img) if _active24 else null
	fill_slot(slot)
	_record_history(b1, b2, b3, b4, b5, b6)


# ── Stroke / undo ─────────────────────────────────────────────────────────────

func _stroke_begin(set_painting := true) -> void:
	# DD selects a default vanilla terrain via select() on map open (no
	# item_selected signal fires), so sync _paint_slot to the live TerrainID
	# unless the user explicitly picked one of our extended slots — otherwise we
	# would paint a stale slot (e.g. the default slot 9).
	if not _extra_selected:
		var tb = _g.Editor.Tools["TerrainBrush"]
		if tb != null:
			_paint_slot = int(tb.TerrainID)
	var terrain = _get_terrain()
	if terrain == null or not _ensure_buffers(terrain):
		return
	_stroke_b1 = terrain.CloneSplatImage()
	_stroke_b2 = terrain.CloneSplatImage2()
	_stroke_b3 = _dup(_splat3_img)
	_stroke_b4 = _dup(_splat4_img)
	_stroke_b5 = _dup(_splat5_img) if _active24 else null
	_stroke_b6 = _dup(_splat6_img) if _active24 else null
	# When the paint bucket / square brush delegates here it only wants the
	# undo snapshot — NOT to start our continuous round brush (which would
	# feather over the square every frame while the click is held).
	if set_painting:
		_painting = true


func _stroke_end() -> void:
	if not _painting:
		return
	_painting = false
	_mark_persist_dirty()
	_record_history(_stroke_b1, _stroke_b2, _stroke_b3, _stroke_b4, _stroke_b5, _stroke_b6)
	_stroke_b1 = null
	_stroke_b2 = null
	_stroke_b3 = null
	_stroke_b4 = null
	_stroke_b5 = null
	_stroke_b6 = null


func _record_history(b1, b2, b3, b4, b5, b6) -> void:
	var terrain = _get_terrain()
	if terrain == null or _UndoRecordScript == null:
		return
	var hist = _g.Editor.get("History")
	if hist == null or not hist.has_method("CreateCustomRecord"):
		return
	var rec = _UndoRecordScript.new()
	rec.driver = self
	rec.terrain = terrain
	rec.before1 = b1
	rec.before2 = b2
	rec.before3 = b3
	rec.before4 = b4
	rec.before5 = b5
	rec.before6 = b6
	rec.after1 = terrain.CloneSplatImage()
	rec.after2 = terrain.CloneSplatImage2()
	rec.after3 = _dup(_splat3_img)
	rec.after4 = _dup(_splat4_img)
	rec.after5 = _dup(_splat5_img) if _active24 else null
	rec.after6 = _dup(_splat6_img) if _active24 else null
	hist.CreateCustomRecord(rec)


# ── 16-slot shader generation ─────────────────────────────────────────────────
# Extended exactly like Terrain2.shader / SmoothTerrain2.shader: same
# uniforms (splat..splat4, texture_1..16, blend_step, map_size), same texture2uv,
# same blend logic, just 16 terms instead of 8.

func _build_shaders() -> void:
	_height16 = Shader.new()
	_height16.code = _HEIGHT16_CODE
	_smooth16 = Shader.new()
	_smooth16.code = _SMOOTH16_CODE


const _HEIGHT16_CODE = """
shader_type canvas_item;
render_mode blend_mix;

uniform sampler2D texture_1;
uniform sampler2D texture_2;
uniform sampler2D texture_3;
uniform sampler2D texture_4;
uniform sampler2D texture_5;
uniform sampler2D texture_6;
uniform sampler2D texture_7;
uniform sampler2D texture_8;
uniform sampler2DArray extra_terrains;   // slots 9-24 as array layers 0-15
// Native px size of each slot 9-24 texture, used to tile it at its true PPI
// (like DD's world_uv/textureSize). Default = array size, so an unset slot
// tiles like before. NOTE: Godot 3.x has no uniform arrays -> 16 scalars.
uniform vec2 extra_size_9 = vec2(1024.0);
uniform vec2 extra_size_10 = vec2(1024.0);
uniform vec2 extra_size_11 = vec2(1024.0);
uniform vec2 extra_size_12 = vec2(1024.0);
uniform vec2 extra_size_13 = vec2(1024.0);
uniform vec2 extra_size_14 = vec2(1024.0);
uniform vec2 extra_size_15 = vec2(1024.0);
uniform vec2 extra_size_16 = vec2(1024.0);
uniform vec2 extra_size_17 = vec2(1024.0);
uniform vec2 extra_size_18 = vec2(1024.0);
uniform vec2 extra_size_19 = vec2(1024.0);
uniform vec2 extra_size_20 = vec2(1024.0);
uniform vec2 extra_size_21 = vec2(1024.0);
uniform vec2 extra_size_22 = vec2(1024.0);
uniform vec2 extra_size_23 = vec2(1024.0);
uniform vec2 extra_size_24 = vec2(1024.0);
uniform sampler2D splat;
uniform sampler2D splat2;
uniform sampler2D splat3;
uniform sampler2D splat4;
uniform sampler2D splat5;
uniform sampler2D splat6;
uniform float blend_step = 0.04;
uniform vec2 map_size;

// Highlight mode: paint a red/green hatch wherever a chosen slot has any splat
// (so even faint paint shows), dimming everything else. hl_slot is 0-based.
uniform bool hl_on = false;
uniform int hl_slot = -1;
uniform float hl_stripe = 24.0;   // hatch stripe width in world pixels

// ColourAndModifyThings compatibility (slots 1-8): tint / gradient / flip /
// holes (transparency) / per-texture rotation. Neutral defaults so the render
// is identical when that mod is absent; when present, the params it sets on
// the material (which persist across our shader swaps) drive these effects.
uniform vec4 tint_colour_1 = vec4(1.0);
uniform vec4 tint_colour_2 = vec4(1.0);
uniform vec4 tint_colour_3 = vec4(1.0);
uniform vec4 tint_colour_4 = vec4(1.0);
uniform vec4 tint_colour_5 = vec4(1.0);
uniform vec4 tint_colour_6 = vec4(1.0);
uniform vec4 tint_colour_7 = vec4(1.0);
uniform vec4 tint_colour_8 = vec4(1.0);
uniform bool apply_gradient_1 = false;
uniform bool apply_gradient_2 = false;
uniform bool apply_gradient_3 = false;
uniform bool apply_gradient_4 = false;
uniform bool apply_gradient_5 = false;
uniform bool apply_gradient_6 = false;
uniform bool apply_gradient_7 = false;
uniform bool apply_gradient_8 = false;
uniform sampler2D gradient_atlas;
uniform bool flip_x_1 = false;
uniform bool flip_x_2 = false;
uniform bool flip_x_3 = false;
uniform bool flip_x_4 = false;
uniform bool flip_x_5 = false;
uniform bool flip_x_6 = false;
uniform bool flip_x_7 = false;
uniform bool flip_x_8 = false;
uniform bool flip_y_1 = false;
uniform bool flip_y_2 = false;
uniform bool flip_y_3 = false;
uniform bool flip_y_4 = false;
uniform bool flip_y_5 = false;
uniform bool flip_y_6 = false;
uniform bool flip_y_7 = false;
uniform bool flip_y_8 = false;
uniform bool is_hole_1 = false;
uniform bool is_hole_2 = false;
uniform bool is_hole_3 = false;
uniform bool is_hole_4 = false;
uniform bool is_hole_5 = false;
uniform bool is_hole_6 = false;
uniform bool is_hole_7 = false;
uniform bool is_hole_8 = false;
uniform float transparent_threshold_1 = 1.0;
uniform float transparent_threshold_2 = 1.0;
uniform float transparent_threshold_3 = 1.0;
uniform float transparent_threshold_4 = 1.0;
uniform float transparent_threshold_5 = 1.0;
uniform float transparent_threshold_6 = 1.0;
uniform float transparent_threshold_7 = 1.0;
uniform float transparent_threshold_8 = 1.0;
uniform float texture_rotation_1 = 0.0;
uniform float texture_rotation_2 = 0.0;
uniform float texture_rotation_3 = 0.0;
uniform float texture_rotation_4 = 0.0;
uniform float texture_rotation_5 = 0.0;
uniform float texture_rotation_6 = 0.0;
uniform float texture_rotation_7 = 0.0;
uniform float texture_rotation_8 = 0.0;

varying vec2 world_uv;

vec4 sample_gradient(float gray, int index) {
	float rows = 8.0;
	float row_height = 1.0 / rows;
	float y = (float(index) + 0.5) * row_height;
	return texture(gradient_atlas, vec2(gray, y));
}

vec2 rotate_uv(vec2 uv, float r) {
	float mid = 0.5;
	return vec2(
		cos(r) * (uv.x - mid) + sin(r) * (uv.y - mid) + mid,
		cos(r) * (uv.y - mid) - sin(r) * (uv.x - mid) + mid);
}

vec2 texture2uv(sampler2D t, vec2 uv) {
	ivec2 size = textureSize(t, 0);
	if (size.x == 0 || size.y == 0) { return uv; }
	uv.x /= float(size.x);
	uv.y /= float(size.y);
	return uv;
}

// Tile an extended-slot texture at its NATIVE size (not the array's storage
// size), so its PPI/scale matches DD's native slots and the source asset.
vec2 extra_uv(vec2 uv, vec2 native_size) {
	return uv / max(native_size, vec2(1.0));
}

vec4 get_coloured_texture(sampler2D tex, vec2 uv, vec4 tint_colour, bool apply_gradient, int gradient_index, bool flip_x, bool flip_y) {
	if (flip_x) { uv.x = -uv.x; }
	if (flip_y) { uv.y = -uv.y; }
	vec4 color = texture(tex, uv);
	if (apply_gradient) {
		float gray = clamp(dot(color.rgb, vec3(0.299, 0.587, 0.114)), 0.0, 1.0);
		vec4 gradient_color = sample_gradient(gray, gradient_index);
		color = vec4(gradient_color.rgb, color.a);
	}
	return color * vec4(tint_colour.rgb, 1.0);
}

float hl_value(int slot, vec4 a, vec4 b, vec4 c, vec4 d, vec4 e, vec4 f) {
	if (slot == 0) return a.r; if (slot == 1) return a.g; if (slot == 2) return a.b; if (slot == 3) return a.a;
	if (slot == 4) return b.r; if (slot == 5) return b.g; if (slot == 6) return b.b; if (slot == 7) return b.a;
	if (slot == 8) return c.r; if (slot == 9) return c.g; if (slot == 10) return c.b; if (slot == 11) return c.a;
	if (slot == 12) return d.r; if (slot == 13) return d.g; if (slot == 14) return d.b; if (slot == 15) return d.a;
	if (slot == 16) return e.r; if (slot == 17) return e.g; if (slot == 18) return e.b; if (slot == 19) return e.a;
	if (slot == 20) return f.r; if (slot == 21) return f.g; if (slot == 22) return f.b; if (slot == 23) return f.a;
	return 0.0;
}

void vertex() { world_uv = VERTEX; }

void fragment() {
	vec4 s = texture(splat, world_uv / map_size);
	vec4 s2 = texture(splat2, world_uv / map_size);
	vec4 s3 = texture(splat3, world_uv / map_size);
	vec4 s4 = texture(splat4, world_uv / map_size);
	vec4 s5 = texture(splat5, world_uv / map_size);
	vec4 s6 = texture(splat6, world_uv / map_size);

	vec4 t1 = get_coloured_texture(texture_1, rotate_uv(texture2uv(texture_1, world_uv), texture_rotation_1), tint_colour_1, apply_gradient_1, 0, flip_x_1, flip_y_1);
	vec4 t2 = get_coloured_texture(texture_2, rotate_uv(texture2uv(texture_2, world_uv), texture_rotation_2), tint_colour_2, apply_gradient_2, 1, flip_x_2, flip_y_2);
	vec4 t3 = get_coloured_texture(texture_3, rotate_uv(texture2uv(texture_3, world_uv), texture_rotation_3), tint_colour_3, apply_gradient_3, 2, flip_x_3, flip_y_3);
	vec4 t4 = get_coloured_texture(texture_4, rotate_uv(texture2uv(texture_4, world_uv), texture_rotation_4), tint_colour_4, apply_gradient_4, 3, flip_x_4, flip_y_4);
	vec4 t5 = get_coloured_texture(texture_5, rotate_uv(texture2uv(texture_5, world_uv), texture_rotation_5), tint_colour_5, apply_gradient_5, 4, flip_x_5, flip_y_5);
	vec4 t6 = get_coloured_texture(texture_6, rotate_uv(texture2uv(texture_6, world_uv), texture_rotation_6), tint_colour_6, apply_gradient_6, 5, flip_x_6, flip_y_6);
	vec4 t7 = get_coloured_texture(texture_7, rotate_uv(texture2uv(texture_7, world_uv), texture_rotation_7), tint_colour_7, apply_gradient_7, 6, flip_x_7, flip_y_7);
	vec4 t8 = get_coloured_texture(texture_8, rotate_uv(texture2uv(texture_8, world_uv), texture_rotation_8), tint_colour_8, apply_gradient_8, 7, flip_x_8, flip_y_8);
	vec4 t9 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_9), 0.0));
	vec4 t10 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_10), 1.0));
	vec4 t11 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_11), 2.0));
	vec4 t12 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_12), 3.0));
	vec4 t13 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_13), 4.0));
	vec4 t14 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_14), 5.0));
	vec4 t15 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_15), 6.0));
	vec4 t16 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_16), 7.0));
	vec4 t17 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_17), 8.0));
	vec4 t18 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_18), 9.0));
	vec4 t19 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_19), 10.0));
	vec4 t20 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_20), 11.0));
	vec4 t21 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_21), 12.0));
	vec4 t22 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_22), 13.0));
	vec4 t23 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_23), 14.0));
	vec4 t24 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_24), 15.0));

	float h1 = t1.a * s.r;
	float h2 = t2.a * s.g;
	float h3 = t3.a * s.b;
	float h4 = t4.a * s.a;
	float h5 = t5.a * s2.r;
	float h6 = t6.a * s2.g;
	float h7 = t7.a * s2.b;
	float h8 = t8.a * s2.a;
	float h9 = t9.a * s3.r;
	float h10 = t10.a * s3.g;
	float h11 = t11.a * s3.b;
	float h12 = t12.a * s3.a;
	float h13 = t13.a * s4.r;
	float h14 = t14.a * s4.g;
	float h15 = t15.a * s4.b;
	float h16 = t16.a * s4.a;
	float h17 = t17.a * s5.r;
	float h18 = t18.a * s5.g;
	float h19 = t19.a * s5.b;
	float h20 = t20.a * s5.a;
	float h21 = t21.a * s6.r;
	float h22 = t22.a * s6.g;
	float h23 = t23.a * s6.b;
	float h24 = t24.a * s6.a;

	float alpha = 0.0;
	bool set_alpha_zero = false;
	if (is_hole_1) { h1 = 0.0; if (s.r > alpha) { alpha = s.r; } if (s.r > transparent_threshold_1) { set_alpha_zero = true; } }
	if (is_hole_2) { h2 = 0.0; if (s.g > alpha) { alpha = s.g; } if (s.g > transparent_threshold_2) { set_alpha_zero = true; } }
	if (is_hole_3) { h3 = 0.0; if (s.b > alpha) { alpha = s.b; } if (s.b > transparent_threshold_3) { set_alpha_zero = true; } }
	if (is_hole_4) { h4 = 0.0; if (s.a > alpha) { alpha = s.a; } if (s.a > transparent_threshold_4) { set_alpha_zero = true; } }
	if (is_hole_5) { h5 = 0.0; if (s2.r > alpha) { alpha = s2.r; } if (s2.r > transparent_threshold_5) { set_alpha_zero = true; } }
	if (is_hole_6) { h6 = 0.0; if (s2.g > alpha) { alpha = s2.g; } if (s2.g > transparent_threshold_6) { set_alpha_zero = true; } }
	if (is_hole_7) { h7 = 0.0; if (s2.b > alpha) { alpha = s2.b; } if (s2.b > transparent_threshold_7) { set_alpha_zero = true; } }
	if (is_hole_8) { h8 = 0.0; if (s2.a > alpha) { alpha = s2.a; } if (s2.a > transparent_threshold_8) { set_alpha_zero = true; } }

	float hmax = h1;
	hmax = max(hmax, h2);
	hmax = max(hmax, h3);
	hmax = max(hmax, h4);
	hmax = max(hmax, h5);
	hmax = max(hmax, h6);
	hmax = max(hmax, h7);
	hmax = max(hmax, h8);
	hmax = max(hmax, h9);
	hmax = max(hmax, h10);
	hmax = max(hmax, h11);
	hmax = max(hmax, h12);
	hmax = max(hmax, h13);
	hmax = max(hmax, h14);
	hmax = max(hmax, h15);
	hmax = max(hmax, h16);
	hmax = max(hmax, h17);
	hmax = max(hmax, h18);
	hmax = max(hmax, h19);
	hmax = max(hmax, h20);
	hmax = max(hmax, h21);
	hmax = max(hmax, h22);
	hmax = max(hmax, h23);
	hmax = max(hmax, h24);
	// Per-slot "painted?" gate: 1.0 where this slot's splat channel is non-zero,
	// 0.0 otherwise. The splat is 8-bit, so any painted pixel is >= 1/255 and
	// there are no values in (0, 1/255) -> this is an exact present/absent test
	// with no false softness. It zeroes out UNPAINTED slots so they can't leak
	// into the blend when height_start goes negative (low-intensity paint), while
	// leaving every painted slot's weight identical to the original formula.
	float g1 = clamp(s.r * 255.0, 0.0, 1.0);
	float g2 = clamp(s.g * 255.0, 0.0, 1.0);
	float g3 = clamp(s.b * 255.0, 0.0, 1.0);
	float g4 = clamp(s.a * 255.0, 0.0, 1.0);
	float g5 = clamp(s2.r * 255.0, 0.0, 1.0);
	float g6 = clamp(s2.g * 255.0, 0.0, 1.0);
	float g7 = clamp(s2.b * 255.0, 0.0, 1.0);
	float g8 = clamp(s2.a * 255.0, 0.0, 1.0);
	float g9 = clamp(s3.r * 255.0, 0.0, 1.0);
	float g10 = clamp(s3.g * 255.0, 0.0, 1.0);
	float g11 = clamp(s3.b * 255.0, 0.0, 1.0);
	float g12 = clamp(s3.a * 255.0, 0.0, 1.0);
	float g13 = clamp(s4.r * 255.0, 0.0, 1.0);
	float g14 = clamp(s4.g * 255.0, 0.0, 1.0);
	float g15 = clamp(s4.b * 255.0, 0.0, 1.0);
	float g16 = clamp(s4.a * 255.0, 0.0, 1.0);
	float g17 = clamp(s5.r * 255.0, 0.0, 1.0);
	float g18 = clamp(s5.g * 255.0, 0.0, 1.0);
	float g19 = clamp(s5.b * 255.0, 0.0, 1.0);
	float g20 = clamp(s5.a * 255.0, 0.0, 1.0);
	float g21 = clamp(s6.r * 255.0, 0.0, 1.0);
	float g22 = clamp(s6.g * 255.0, 0.0, 1.0);
	float g23 = clamp(s6.b * 255.0, 0.0, 1.0);
	float g24 = clamp(s6.a * 255.0, 0.0, 1.0);

	float height_start = hmax - blend_step;
	float w1 = max(h1 - height_start, 0.0) * g1;
	float w2 = max(h2 - height_start, 0.0) * g2;
	float w3 = max(h3 - height_start, 0.0) * g3;
	float w4 = max(h4 - height_start, 0.0) * g4;
	float w5 = max(h5 - height_start, 0.0) * g5;
	float w6 = max(h6 - height_start, 0.0) * g6;
	float w7 = max(h7 - height_start, 0.0) * g7;
	float w8 = max(h8 - height_start, 0.0) * g8;
	float w9 = max(h9 - height_start, 0.0) * g9;
	float w10 = max(h10 - height_start, 0.0) * g10;
	float w11 = max(h11 - height_start, 0.0) * g11;
	float w12 = max(h12 - height_start, 0.0) * g12;
	float w13 = max(h13 - height_start, 0.0) * g13;
	float w14 = max(h14 - height_start, 0.0) * g14;
	float w15 = max(h15 - height_start, 0.0) * g15;
	float w16 = max(h16 - height_start, 0.0) * g16;
	float w17 = max(h17 - height_start, 0.0) * g17;
	float w18 = max(h18 - height_start, 0.0) * g18;
	float w19 = max(h19 - height_start, 0.0) * g19;
	float w20 = max(h20 - height_start, 0.0) * g20;
	float w21 = max(h21 - height_start, 0.0) * g21;
	float w22 = max(h22 - height_start, 0.0) * g22;
	float w23 = max(h23 - height_start, 0.0) * g23;
	float w24 = max(h24 - height_start, 0.0) * g24;
	float splat_sum = w1+w2+w3+w4+w5+w6+w7+w8+w9+w10+w11+w12+w13+w14+w15+w16+w17+w18+w19+w20+w21+w22+w23+w24;
	splat_sum = max(splat_sum, 0.0001);
	vec3 albedo =
		t1.rgb*w1 +
		t2.rgb*w2 +
		t3.rgb*w3 +
		t4.rgb*w4 +
		t5.rgb*w5 +
		t6.rgb*w6 +
		t7.rgb*w7 +
		t8.rgb*w8 +
		t9.rgb*w9 +
		t10.rgb*w10 +
		t11.rgb*w11 +
		t12.rgb*w12 +
		t13.rgb*w13 +
		t14.rgb*w14 +
		t15.rgb*w15 +
		t16.rgb*w16 +
		t17.rgb*w17 +
		t18.rgb*w18 +
		t19.rgb*w19 +
		t20.rgb*w20 +
		t21.rgb*w21 +
		t22.rgb*w22 +
		t23.rgb*w23 +
		t24.rgb*w24;
	albedo /= splat_sum;

	if (set_alpha_zero) { COLOR = vec4(albedo, 0.0); }
	else { COLOR = vec4(albedo, 1.0 - alpha); }

	if (hl_on && hl_slot >= 0) {
		float hv = hl_value(hl_slot, s, s2, s3, s4, s5, s6);
		if (hv > 0.0039) {
			float stripe = mod(floor((world_uv.x + world_uv.y) / max(hl_stripe, 1.0)), 2.0);
			vec3 hatch = mix(vec3(0.15, 0.85, 0.15), vec3(0.9, 0.15, 0.15), stripe);
			COLOR = vec4(hatch, 1.0);
		} else {
			COLOR = vec4(COLOR.rgb * 0.2, COLOR.a);
		}
	}
}
"""


const _SMOOTH16_CODE = """
shader_type canvas_item;
render_mode blend_mix;

uniform sampler2D texture_1;
uniform sampler2D texture_2;
uniform sampler2D texture_3;
uniform sampler2D texture_4;
uniform sampler2D texture_5;
uniform sampler2D texture_6;
uniform sampler2D texture_7;
uniform sampler2D texture_8;
uniform sampler2DArray extra_terrains;   // slots 9-24 as array layers 0-15
// Native px size of each slot 9-24 texture, used to tile it at its true PPI
// (like DD's world_uv/textureSize). Default = array size, so an unset slot
// tiles like before. NOTE: Godot 3.x has no uniform arrays -> 16 scalars.
uniform vec2 extra_size_9 = vec2(1024.0);
uniform vec2 extra_size_10 = vec2(1024.0);
uniform vec2 extra_size_11 = vec2(1024.0);
uniform vec2 extra_size_12 = vec2(1024.0);
uniform vec2 extra_size_13 = vec2(1024.0);
uniform vec2 extra_size_14 = vec2(1024.0);
uniform vec2 extra_size_15 = vec2(1024.0);
uniform vec2 extra_size_16 = vec2(1024.0);
uniform vec2 extra_size_17 = vec2(1024.0);
uniform vec2 extra_size_18 = vec2(1024.0);
uniform vec2 extra_size_19 = vec2(1024.0);
uniform vec2 extra_size_20 = vec2(1024.0);
uniform vec2 extra_size_21 = vec2(1024.0);
uniform vec2 extra_size_22 = vec2(1024.0);
uniform vec2 extra_size_23 = vec2(1024.0);
uniform vec2 extra_size_24 = vec2(1024.0);
uniform sampler2D splat;
uniform sampler2D splat2;
uniform sampler2D splat3;
uniform sampler2D splat4;
uniform sampler2D splat5;
uniform sampler2D splat6;
uniform float blend_step = 0.04;
uniform vec2 map_size;

// Highlight mode: paint a red/green hatch wherever a chosen slot has any splat
// (so even faint paint shows), dimming everything else. hl_slot is 0-based.
uniform bool hl_on = false;
uniform int hl_slot = -1;
uniform float hl_stripe = 24.0;   // hatch stripe width in world pixels

// ColourAndModifyThings compatibility (slots 1-8): tint / gradient / flip /
// holes (transparency) / per-texture rotation. Neutral defaults so the render
// is identical when that mod is absent; when present, the params it sets on
// the material (which persist across our shader swaps) drive these effects.
uniform vec4 tint_colour_1 = vec4(1.0);
uniform vec4 tint_colour_2 = vec4(1.0);
uniform vec4 tint_colour_3 = vec4(1.0);
uniform vec4 tint_colour_4 = vec4(1.0);
uniform vec4 tint_colour_5 = vec4(1.0);
uniform vec4 tint_colour_6 = vec4(1.0);
uniform vec4 tint_colour_7 = vec4(1.0);
uniform vec4 tint_colour_8 = vec4(1.0);
uniform bool apply_gradient_1 = false;
uniform bool apply_gradient_2 = false;
uniform bool apply_gradient_3 = false;
uniform bool apply_gradient_4 = false;
uniform bool apply_gradient_5 = false;
uniform bool apply_gradient_6 = false;
uniform bool apply_gradient_7 = false;
uniform bool apply_gradient_8 = false;
uniform sampler2D gradient_atlas;
uniform bool flip_x_1 = false;
uniform bool flip_x_2 = false;
uniform bool flip_x_3 = false;
uniform bool flip_x_4 = false;
uniform bool flip_x_5 = false;
uniform bool flip_x_6 = false;
uniform bool flip_x_7 = false;
uniform bool flip_x_8 = false;
uniform bool flip_y_1 = false;
uniform bool flip_y_2 = false;
uniform bool flip_y_3 = false;
uniform bool flip_y_4 = false;
uniform bool flip_y_5 = false;
uniform bool flip_y_6 = false;
uniform bool flip_y_7 = false;
uniform bool flip_y_8 = false;
uniform bool is_hole_1 = false;
uniform bool is_hole_2 = false;
uniform bool is_hole_3 = false;
uniform bool is_hole_4 = false;
uniform bool is_hole_5 = false;
uniform bool is_hole_6 = false;
uniform bool is_hole_7 = false;
uniform bool is_hole_8 = false;
uniform float transparent_threshold_1 = 1.0;
uniform float transparent_threshold_2 = 1.0;
uniform float transparent_threshold_3 = 1.0;
uniform float transparent_threshold_4 = 1.0;
uniform float transparent_threshold_5 = 1.0;
uniform float transparent_threshold_6 = 1.0;
uniform float transparent_threshold_7 = 1.0;
uniform float transparent_threshold_8 = 1.0;
uniform float texture_rotation_1 = 0.0;
uniform float texture_rotation_2 = 0.0;
uniform float texture_rotation_3 = 0.0;
uniform float texture_rotation_4 = 0.0;
uniform float texture_rotation_5 = 0.0;
uniform float texture_rotation_6 = 0.0;
uniform float texture_rotation_7 = 0.0;
uniform float texture_rotation_8 = 0.0;

varying vec2 world_uv;

vec4 sample_gradient(float gray, int index) {
	float rows = 8.0;
	float row_height = 1.0 / rows;
	float y = (float(index) + 0.5) * row_height;
	return texture(gradient_atlas, vec2(gray, y));
}

vec2 rotate_uv(vec2 uv, float r) {
	float mid = 0.5;
	return vec2(
		cos(r) * (uv.x - mid) + sin(r) * (uv.y - mid) + mid,
		cos(r) * (uv.y - mid) - sin(r) * (uv.x - mid) + mid);
}

vec2 texture2uv(sampler2D t, vec2 uv) {
	ivec2 size = textureSize(t, 0);
	if (size.x == 0 || size.y == 0) { return uv; }
	uv.x /= float(size.x);
	uv.y /= float(size.y);
	return uv;
}

// Tile an extended-slot texture at its NATIVE size (not the array's storage
// size), so its PPI/scale matches DD's native slots and the source asset.
vec2 extra_uv(vec2 uv, vec2 native_size) {
	return uv / max(native_size, vec2(1.0));
}

vec4 get_coloured_texture(sampler2D tex, vec2 uv, vec4 tint_colour, bool apply_gradient, int gradient_index, bool flip_x, bool flip_y) {
	if (flip_x) { uv.x = -uv.x; }
	if (flip_y) { uv.y = -uv.y; }
	vec4 color = texture(tex, uv);
	if (apply_gradient) {
		float gray = clamp(dot(color.rgb, vec3(0.299, 0.587, 0.114)), 0.0, 1.0);
		vec4 gradient_color = sample_gradient(gray, gradient_index);
		color = vec4(gradient_color.rgb, color.a);
	}
	return color * vec4(tint_colour.rgb, 1.0);
}

float hl_value(int slot, vec4 a, vec4 b, vec4 c, vec4 d, vec4 e, vec4 f) {
	if (slot == 0) return a.r; if (slot == 1) return a.g; if (slot == 2) return a.b; if (slot == 3) return a.a;
	if (slot == 4) return b.r; if (slot == 5) return b.g; if (slot == 6) return b.b; if (slot == 7) return b.a;
	if (slot == 8) return c.r; if (slot == 9) return c.g; if (slot == 10) return c.b; if (slot == 11) return c.a;
	if (slot == 12) return d.r; if (slot == 13) return d.g; if (slot == 14) return d.b; if (slot == 15) return d.a;
	if (slot == 16) return e.r; if (slot == 17) return e.g; if (slot == 18) return e.b; if (slot == 19) return e.a;
	if (slot == 20) return f.r; if (slot == 21) return f.g; if (slot == 22) return f.b; if (slot == 23) return f.a;
	return 0.0;
}

void vertex() { world_uv = VERTEX; }

void fragment() {
	vec4 s = texture(splat, world_uv / map_size);
	vec4 s2 = texture(splat2, world_uv / map_size);
	vec4 s3 = texture(splat3, world_uv / map_size);
	vec4 s4 = texture(splat4, world_uv / map_size);
	vec4 s5 = texture(splat5, world_uv / map_size);
	vec4 s6 = texture(splat6, world_uv / map_size);

	vec4 t1 = get_coloured_texture(texture_1, rotate_uv(texture2uv(texture_1, world_uv), texture_rotation_1), tint_colour_1, apply_gradient_1, 0, flip_x_1, flip_y_1);
	vec4 t2 = get_coloured_texture(texture_2, rotate_uv(texture2uv(texture_2, world_uv), texture_rotation_2), tint_colour_2, apply_gradient_2, 1, flip_x_2, flip_y_2);
	vec4 t3 = get_coloured_texture(texture_3, rotate_uv(texture2uv(texture_3, world_uv), texture_rotation_3), tint_colour_3, apply_gradient_3, 2, flip_x_3, flip_y_3);
	vec4 t4 = get_coloured_texture(texture_4, rotate_uv(texture2uv(texture_4, world_uv), texture_rotation_4), tint_colour_4, apply_gradient_4, 3, flip_x_4, flip_y_4);
	vec4 t5 = get_coloured_texture(texture_5, rotate_uv(texture2uv(texture_5, world_uv), texture_rotation_5), tint_colour_5, apply_gradient_5, 4, flip_x_5, flip_y_5);
	vec4 t6 = get_coloured_texture(texture_6, rotate_uv(texture2uv(texture_6, world_uv), texture_rotation_6), tint_colour_6, apply_gradient_6, 5, flip_x_6, flip_y_6);
	vec4 t7 = get_coloured_texture(texture_7, rotate_uv(texture2uv(texture_7, world_uv), texture_rotation_7), tint_colour_7, apply_gradient_7, 6, flip_x_7, flip_y_7);
	vec4 t8 = get_coloured_texture(texture_8, rotate_uv(texture2uv(texture_8, world_uv), texture_rotation_8), tint_colour_8, apply_gradient_8, 7, flip_x_8, flip_y_8);
	vec4 t9 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_9), 0.0));
	vec4 t10 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_10), 1.0));
	vec4 t11 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_11), 2.0));
	vec4 t12 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_12), 3.0));
	vec4 t13 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_13), 4.0));
	vec4 t14 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_14), 5.0));
	vec4 t15 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_15), 6.0));
	vec4 t16 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_16), 7.0));
	vec4 t17 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_17), 8.0));
	vec4 t18 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_18), 9.0));
	vec4 t19 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_19), 10.0));
	vec4 t20 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_20), 11.0));
	vec4 t21 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_21), 12.0));
	vec4 t22 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_22), 13.0));
	vec4 t23 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_23), 14.0));
	vec4 t24 = texture(extra_terrains, vec3(extra_uv(world_uv, extra_size_24), 15.0));

	float h1 = s.r;
	float h2 = s.g;
	float h3 = s.b;
	float h4 = s.a;
	float h5 = s2.r;
	float h6 = s2.g;
	float h7 = s2.b;
	float h8 = s2.a;
	float h9 = s3.r;
	float h10 = s3.g;
	float h11 = s3.b;
	float h12 = s3.a;
	float h13 = s4.r;
	float h14 = s4.g;
	float h15 = s4.b;
	float h16 = s4.a;
	float h17 = s5.r;
	float h18 = s5.g;
	float h19 = s5.b;
	float h20 = s5.a;
	float h21 = s6.r;
	float h22 = s6.g;
	float h23 = s6.b;
	float h24 = s6.a;

	float alpha = 0.0;
	bool set_alpha_zero = false;
	if (is_hole_1) { h1 = 0.0; if (s.r > alpha) { alpha = s.r; } if (s.r > transparent_threshold_1) { set_alpha_zero = true; } }
	if (is_hole_2) { h2 = 0.0; if (s.g > alpha) { alpha = s.g; } if (s.g > transparent_threshold_2) { set_alpha_zero = true; } }
	if (is_hole_3) { h3 = 0.0; if (s.b > alpha) { alpha = s.b; } if (s.b > transparent_threshold_3) { set_alpha_zero = true; } }
	if (is_hole_4) { h4 = 0.0; if (s.a > alpha) { alpha = s.a; } if (s.a > transparent_threshold_4) { set_alpha_zero = true; } }
	if (is_hole_5) { h5 = 0.0; if (s2.r > alpha) { alpha = s2.r; } if (s2.r > transparent_threshold_5) { set_alpha_zero = true; } }
	if (is_hole_6) { h6 = 0.0; if (s2.g > alpha) { alpha = s2.g; } if (s2.g > transparent_threshold_6) { set_alpha_zero = true; } }
	if (is_hole_7) { h7 = 0.0; if (s2.b > alpha) { alpha = s2.b; } if (s2.b > transparent_threshold_7) { set_alpha_zero = true; } }
	if (is_hole_8) { h8 = 0.0; if (s2.a > alpha) { alpha = s2.a; } if (s2.a > transparent_threshold_8) { set_alpha_zero = true; } }

	float splatSum = h1+h2+h3+h4+h5+h6+h7+h8+h9+h10+h11+h12+h13+h14+h15+h16+h17+h18+h19+h20+h21+h22+h23+h24;
	splatSum = max(splatSum, 0.0001);
	vec3 albedo =
		t1.rgb*h1 +
		t2.rgb*h2 +
		t3.rgb*h3 +
		t4.rgb*h4 +
		t5.rgb*h5 +
		t6.rgb*h6 +
		t7.rgb*h7 +
		t8.rgb*h8 +
		t9.rgb*h9 +
		t10.rgb*h10 +
		t11.rgb*h11 +
		t12.rgb*h12 +
		t13.rgb*h13 +
		t14.rgb*h14 +
		t15.rgb*h15 +
		t16.rgb*h16 +
		t17.rgb*h17 +
		t18.rgb*h18 +
		t19.rgb*h19 +
		t20.rgb*h20 +
		t21.rgb*h21 +
		t22.rgb*h22 +
		t23.rgb*h23 +
		t24.rgb*h24;
	albedo /= splatSum;

	if (set_alpha_zero) { COLOR = vec4(albedo, 0.0); }
	else { COLOR = vec4(albedo, 1.0 - alpha); }

	if (hl_on && hl_slot >= 0) {
		float hv = hl_value(hl_slot, s, s2, s3, s4, s5, s6);
		if (hv > 0.0039) {
			float stripe = mod(floor((world_uv.x + world_uv.y) / max(hl_stripe, 1.0)), 2.0);
			vec3 hatch = mix(vec3(0.15, 0.85, 0.15), vec3(0.9, 0.15, 0.15), stripe);
			COLOR = vec4(hatch, 1.0);
		} else {
			COLOR = vec4(COLOR.rgb * 0.2, COLOR.a);
		}
	}
}
"""


# ── UI: integration into the Terrain Brush panel ──────────────────────────────

func _try_inject_ui() -> void:
	if _ui_injected:
		return
	if _g == null or _g.get("Editor") == null:
		return
	var toolset = _g.Editor.get("Toolset")
	if toolset == null or not toolset.has_method("GetToolPanel"):
		return
	_terrain_panel = toolset.GetToolPanel("TerrainBrush")
	if _terrain_panel == null or not is_instance_valid(_terrain_panel):
		return
	var align = _terrain_panel.get("Align")
	if align == null:
		return
	_build_section(align)
	_ui_injected = true
	print("[Terrain16] UI injected into the Terrain panel.")


func _build_section(align) -> void:
	# Grab the vanilla list BEFORE adding ours, so we can copy its style and do
	# cross-deselection.
	_vanilla_list = _get_vanilla_terrain_list()
	if _vanilla_list != null and not _vanilla_list.is_connected("item_selected", self, "_on_vanilla_item_selected"):
		_vanilla_list.connect("item_selected", self, "_on_vanilla_item_selected")
	if _vanilla_list != null:
		_vanilla_list.allow_rmb_select = true
		if not _vanilla_list.is_connected("item_rmb_selected", self, "_on_vanilla_item_rmb"):
			_vanilla_list.connect("item_rmb_selected", self, "_on_vanilla_item_rmb")

	# DD's native "Fill" button — hidden while our mode is on (our single Fill
	# button below handles both native slots 1-8 and our slots 9-24).
	if _native_fill_btn == null or not is_instance_valid(_native_fill_btn):
		_native_fill_btn = _find_native_fill_button(_terrain_panel)

	_tex_menu_icon = _get_texture_menu_icon()

	# Everything we add goes into a single wrapper so the whole block (toggles +
	# extra slot lists + Fill) stays contiguous and can be glued directly beneath
	# the vanilla terrain list, above "Smooth Blending" / "Unlock 4 more slots".
	var wrap = VBoxContainer.new()
	wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_wrap = wrap

	# 16-slot toggle.
	_toggle_btn = CheckButton.new()
	_toggle_btn.text = "Slots 9-16"
	_toggle_btn.hint_tooltip = "Adds 8 extra terrain slots (9 to 16)."
	_toggle_btn.connect("toggled", self, "_on_toggle")
	_toggle_btn.set_pressed_no_signal(_active)
	wrap.add_child(_toggle_btn)

	# Slots 9-16 section.
	_section = VBoxContainer.new()
	var r16 = _make_slot_row(8, "_on_extra_item_selected")
	_extra_list = r16["list"]
	_picker_btns = r16["btns"]
	_section.add_child(r16["row"])
	wrap.add_child(_section)

	# 24-slot toggle.
	_toggle_btn24 = CheckButton.new()
	_toggle_btn24.text = "Slots 17-24"
	_toggle_btn24.hint_tooltip = "Adds 8 more terrain slots (17 to 24). Turns on 16 slots too."
	_toggle_btn24.connect("toggled", self, "_on_toggle24")
	_toggle_btn24.set_pressed_no_signal(_active24)
	wrap.add_child(_toggle_btn24)

	# Slots 17-24 section.
	_section24 = VBoxContainer.new()
	var r24 = _make_slot_row(16, "_on_extra24_item_selected")
	_extra_list24 = r24["list"]
	_picker_btns24 = r24["btns"]
	_section24.add_child(r24["row"])
	wrap.add_child(_section24)

	# Single "Fill" button, below ALL slot lists (native 1-8 or extended 9-24).
	_fill_btn = Button.new()
	_fill_btn.text = "Fill"
	_fill_btn.connect("pressed", self, "_on_fill_pressed")
	wrap.add_child(_fill_btn)

	# ── Presets: save / load terrain palettes, per group of 8 slots ──────────
	# A preset can hold any of 3 groups: slots 1-8, 9-16, 17-24. The Load row's
	# checkboxes reflect what the chosen preset contains (greyed = not in it, but
	# you may untick a present one to load only part). The Save row's checkboxes
	# choose which groups to store.
	var preset_lbl = Label.new()
	preset_lbl.text = "Terrain presets"
	wrap.add_child(preset_lbl)

	var prow = HBoxContainer.new()
	prow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preset_dropdown = OptionButton.new()
	_preset_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preset_dropdown.hint_tooltip = "Saved terrain palettes."
	_preset_dropdown.connect("item_selected", self, "_on_preset_chosen")
	prow.add_child(_preset_dropdown)
	var apply_btn = Button.new()
	apply_btn.text = "Load"
	apply_btn.hint_tooltip = "Apply the ticked groups of the selected preset."
	apply_btn.connect("pressed", self, "_on_preset_apply")
	prow.add_child(apply_btn)
	var del_btn = Button.new()
	var trash = _trash_icon()
	if trash != null:
		del_btn.icon = trash
	else:
		del_btn.text = "X"
	del_btn.hint_tooltip = "Delete the selected preset."
	del_btn.connect("pressed", self, "_on_preset_delete")
	prow.add_child(del_btn)
	wrap.add_child(prow)

	# Load groups: auto-set from the selected preset; untickable to load part.
	var lcrow = HBoxContainer.new()
	lcrow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_load_g1 = _mk_group_check("1-8", "Load slots 1-8 from the preset.")
	_load_g2 = _mk_group_check("9-16", "Load slots 9-16 from the preset.")
	_load_g3 = _mk_group_check("17-24", "Load slots 17-24 from the preset.")
	lcrow.add_child(_load_g1)
	lcrow.add_child(_load_g2)
	lcrow.add_child(_load_g3)
	wrap.add_child(lcrow)

	var srow = HBoxContainer.new()
	srow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preset_name_edit = LineEdit.new()
	_preset_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preset_name_edit.placeholder_text = "Preset name"
	srow.add_child(_preset_name_edit)
	var save_btn = Button.new()
	save_btn.text = "Save"
	save_btn.hint_tooltip = "Save the ticked groups as a preset (overwrites if the name exists)."
	save_btn.connect("pressed", self, "_on_preset_save")
	srow.add_child(save_btn)
	wrap.add_child(srow)

	# Save groups: choose which groups of 8 slots to store (all on by default).
	var scrow = HBoxContainer.new()
	scrow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_save_g1 = _mk_group_check("1-8", "Include slots 1-8 when saving.")
	_save_g2 = _mk_group_check("9-16", "Include slots 9-16 when saving.")
	_save_g3 = _mk_group_check("17-24", "Include slots 17-24 when saving.")
	_save_g1.pressed = true
	_save_g2.pressed = true
	_save_g3.pressed = true
	scrow.add_child(_save_g1)
	scrow.add_child(_save_g2)
	scrow.add_child(_save_g3)
	wrap.add_child(scrow)

	# ── Copy / paste a group of 8 slots ──────────────────────────────────────
	# Pick a group, Copy it to an in-session clipboard, switch the group, Paste.
	var cprow = HBoxContainer.new()
	cprow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var cp_lbl = Label.new()
	cp_lbl.text = "Copy/paste:"
	cprow.add_child(cp_lbl)
	_copyio_dropdown = OptionButton.new()
	_copyio_dropdown.add_item("1-8")
	_copyio_dropdown.add_item("9-16")
	_copyio_dropdown.add_item("17-24")
	_copyio_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cprow.add_child(_copyio_dropdown)
	var copy_btn = Button.new()
	copy_btn.text = "Copy"
	copy_btn.hint_tooltip = "Copy the selected group of 8 slots."
	copy_btn.connect("pressed", self, "_on_copy_group")
	cprow.add_child(copy_btn)
	_paste_btn = Button.new()
	_paste_btn.text = "Paste"
	_paste_btn.hint_tooltip = "Paste the copied 8 slots into the selected group."
	_paste_btn.disabled = true
	_paste_btn.connect("pressed", self, "_on_paste_group")
	cprow.add_child(_paste_btn)
	wrap.add_child(cprow)

	_refresh_preset_dropdown()
	_update_load_checks()

	_section.visible = _active
	_section24.visible = _active24
	_fill_btn.visible = _active

	# Glue the wrapper right beneath the vanilla terrain list.
	_place_block(align, wrap)
	# Our lists now exist; gather every native terrain list (some panels have
	# more than one) so we can clear their selection while a 9-24 slot is active.
	_collect_native_lists()
	_set_brush_controls_dimmed(_hl_slot >= 0)


func _mk_group_check(text: String, tip: String) -> CheckBox:
	var cb = CheckBox.new()
	cb.text = text
	cb.hint_tooltip = tip
	cb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return cb


# Collect every ItemList under a node.
func _all_item_lists(node) -> Array:
	var out = []
	if node == null:
		return out
	var stack = [node]
	while not stack.empty():
		var nn = stack.pop_back()
		if nn is ItemList:
			out.append(nn)
		for c in nn.get_children():
			stack.push_back(c)
	return out


# The real vanilla terrain list is the populated one (most items); any other
# ItemList in the panel (secondary/hidden) has fewer items or none.
func _pick_terrain_list(node):
	var best = null
	var best_n = -1
	for l in _all_item_lists(node):
		var cnt = l.get_item_count()
		if cnt > best_n:
			best_n = cnt
			best = l
	return best


# Every native terrain ItemList = all panel lists except our two extra lists.
# DD's authoritative vanilla terrain slot list (also used by the third-party
# search mod). Using it directly avoids mistaking the search grid (an ItemList
# with many items) for the vanilla slots.
func _get_vanilla_terrain_list():
	# terrainList is a PRIVATE C# field (not reachable from GDScript). The
	# public route is Controls["TerrainID"] — the real vanilla terrain slot list.
	# We must NOT fall back to a generic "most items" search, because the
	# third-party search grid is also an ItemList (with many items).
	if _g == null or _g.get("Editor") == null:
		return null
	var tb = _g.Editor.Tools["TerrainBrush"]
	if tb == null:
		return null
	var tl = tb.Controls["TerrainID"]
	if tl != null and is_instance_valid(tl):
		return tl
	return null


func _collect_native_lists() -> void:
	_vanilla_lists = []
	var tl = _get_vanilla_terrain_list()
	if tl != null and is_instance_valid(tl):
		_vanilla_lists.append(tl)
		if not tl.is_connected("item_selected", self, "_on_vanilla_item_selected"):
			tl.connect("item_selected", self, "_on_vanilla_item_selected")


# Keep our block inside `align` (visible). Position it just before the native
# Fill button, which DD places directly under the vanilla terrain list.
func _place_block(align, wrap) -> void:
	# IMPORTANT: keep the block inside `align`. Reparenting it into the vanilla
	# list's own container makes it invisible (that subtree doesn't render added
	# children here). `align` is the visible options column.
	align.add_child(wrap)
	# Position it directly beneath the vanilla terrain list. DD puts the native
	# "Fill" button right under that list, so inserting just before Fill places
	# us between the vanilla list and Fill / Smooth Blending / Unlock.
	var anchor_idx = -1
	var fb = _native_fill_btn
	if fb != null and is_instance_valid(fb) and fb.get_parent() == align:
		anchor_idx = fb.get_index()
	if anchor_idx < 0 and _vanilla_list != null and is_instance_valid(_vanilla_list):
		var node = _vanilla_list
		while node != null and node.get_parent() != align:
			node = node.get_parent()
		if node != null and node.get_parent() == align:
			anchor_idx = node.get_index() + 1
	if anchor_idx >= 0:
		align.move_child(wrap, anchor_idx)


# Builds one slot row (ItemList styled like vanilla + a column of picker
# buttons). base_slot is the first slot (8 for 9-16, 16 for 17-24).
func _make_slot_row(base_slot: int, sel_cb: String) -> Dictionary:
	var row = HBoxContainer.new()
	var lst = ItemList.new()
	lst.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lst.rect_min_size = Vector2(0, 552)   # 8 rows, like vanilla expanded
	if _vanilla_list != null:
		lst.icon_mode = _vanilla_list.icon_mode
		lst.fixed_icon_size = _vanilla_list.fixed_icon_size
		lst.max_columns = _vanilla_list.max_columns
		lst.fixed_column_width = _vanilla_list.fixed_column_width
		lst.same_column_width = _vanilla_list.same_column_width
	else:
		lst.icon_mode = ItemList.ICON_MODE_LEFT
		lst.fixed_icon_size = Vector2(64, 64)
		lst.max_columns = 1
	for i in range(8):
		var pth = _extra_paths[base_slot - 8 + i]
		lst.add_item(_display_name(pth), _thumb(pth))
	lst.connect("item_selected", self, sel_cb)
	lst.allow_rmb_select = true
	lst.connect("item_rmb_selected", self, "_on_slot_row_rmb", [base_slot])
	row.add_child(lst)

	var pbox = VBoxContainer.new()
	pbox.add_constant_override("separation", 0)   # no separation: 8 buttons = list height
	row.add_child(pbox)
	var btns = []
	for i in range(8):
		var pick = Button.new()
		pick.rect_min_size = Vector2(38, 0)
		pick.size_flags_vertical = Control.SIZE_EXPAND_FILL
		pick.hint_tooltip = "Change this slot's texture"
		if _tex_menu_icon != null:
			pick.icon = _tex_menu_icon
			pick.expand_icon = true
		else:
			pick.text = "..."
		pick.connect("pressed", self, "_open_picker", [base_slot + i])
		pbox.add_child(pick)
		btns.append(pick)
	return {"row": row, "list": lst, "btns": btns}


# Climb from the native terrain list up to the node that is a direct child of
# `align`, and return its index within `align`. -1 if the native list is
# unknown (e.g. it couldn't be found) — caller then leaves _section in place.
func _section_align_index(align):
	if _vanilla_list == null or not is_instance_valid(_vanilla_list):
		return -1
	var node = _vanilla_list
	while node != null and node.get_parent() != align:
		node = node.get_parent()
	if node == null:
		return -1
	return node.get_index()


# Find DD's native Fill button: a Button whose "pressed" signal is connected to
# a method named "Fill" (case-insensitive). Falls back to a text match.
func _find_native_fill_button(node):
	if node == null:
		return null
	var by_text = null
	var stack = [node]
	while not stack.empty():
		var n = stack.pop_back()
		if n is Button:
			for c in n.get_signal_connection_list("pressed"):
				var m = str(c.get("method"))
				if m == "Fill" or m.to_lower().find("fill") != -1:
					return n
			if n.text != null and str(n.text).strip_edges().to_lower() == "fill":
				by_text = n
		for c in n.get_children():
			stack.push_back(c)
	return by_text


# Find the first Button with the given text under a node.
func _find_button_with_text(node, txt):
	if node == null:
		return null
	var stack = [node]
	while not stack.empty():
		var n = stack.pop_back()
		if n is Button and n.text == txt:
			return n
		for c in n.get_children():
			stack.push_back(c)
	return null


# Find the first ItemList under a node (the vanilla terrain list).
func _find_item_list(node):
	if node == null:
		return null
	var stack = [node]
	while not stack.empty():
		var n = stack.pop_back()
		if n is ItemList:
			return n
		for c in n.get_children():
			stack.push_back(c)
	return null


# Texture-menu icon (white squares). Prefer the theme, otherwise reuse the
# icon already used by the vanilla picker buttons (the most repeated one).
func _get_texture_menu_icon():
	var t = _g.get("Theme")
	if t != null and t.has_method("has_icon") and t.has_icon("Texture Menu", "Icons"):
		return t.get_icon("Texture Menu", "Icons")
	return _find_repeated_button_icon(_terrain_panel)


func _find_repeated_button_icon(node):
	if node == null:
		return null
	var counts = {}
	var stack = [node]
	while not stack.empty():
		var n = stack.pop_back()
		if n is Button and n.icon != null:
			counts[n.icon] = counts.get(n.icon, 0) + 1
		for c in n.get_children():
			stack.push_back(c)
	var best = null
	var best_n = 1
	for k in counts.keys():
		if counts[k] > best_n:
			best_n = counts[k]
			best = k
	return best


func _display_name(path) -> String:
	if path == null:
		return "(empty)"
	# Drop the file extension (.png/.webp/.jpg/...) explicitly, then capitalize()
	# turns "terrain_cracked_earth" into "Terrain Cracked Earth".
	var n = path.get_file()
	var dot = n.rfind(".")
	if dot > 0:
		n = n.substr(0, dot)
	return n.capitalize()


func _on_toggle(pressed: bool) -> void:
	# Per-level toggle: affects only the current level.
	_mark_persist_dirty()
	if pressed:
		activate(null)
	else:
		deactivate(null)


func _post_activate_ui() -> void:
	if _toggle_btn != null:
		_toggle_btn.set_pressed_no_signal(true)
	if _section != null:
		_section.visible = true
	if _native_fill_btn != null and is_instance_valid(_native_fill_btn):
		_native_fill_btn.visible = false
	if _fill_btn != null and is_instance_valid(_fill_btn):
		_fill_btn.visible = true
	_ensure_catalog()
	_refresh_all_row_icons()


func _post_deactivate_ui() -> void:
	if _toggle_btn != null and is_instance_valid(_toggle_btn):
		_toggle_btn.set_pressed_no_signal(false)
	if _toggle_btn24 != null and is_instance_valid(_toggle_btn24):
		_toggle_btn24.set_pressed_no_signal(false)
	if _section != null and is_instance_valid(_section):
		_section.visible = false
	if _section24 != null and is_instance_valid(_section24):
		_section24.visible = false
	if _native_fill_btn != null and is_instance_valid(_native_fill_btn):
		_native_fill_btn.visible = true
	if _fill_btn != null and is_instance_valid(_fill_btn):
		_fill_btn.visible = false


func _on_toggle24(pressed: bool) -> void:
	_mark_persist_dirty()
	if pressed:
		if not _active:
			if not activate(null):
				if _toggle_btn24 != null and is_instance_valid(_toggle_btn24):
					_toggle_btn24.set_pressed_no_signal(false)
				return
			if _toggle_btn != null and is_instance_valid(_toggle_btn):
				_toggle_btn.set_pressed_no_signal(true)
		_active24 = true
		var terrain = _get_terrain()
		if terrain != null and _ensure_buffers(terrain):
			_push_extra_splats(_get_material(terrain))
		_assign_default_extra_textures(terrain)   # assigns/pushes 17-24
		if _section24 != null and is_instance_valid(_section24):
			_section24.visible = true
		_refresh_all_row_icons()
	else:
		_active24 = false
		_push_extra_splats(_get_material(_get_terrain()))   # binds zero -> hides 17-24
		if _section24 != null and is_instance_valid(_section24):
			_section24.visible = false
		if _paint_slot >= 16:
			_paint_slot = 8
			_extra_selected = true
			if _extra_list != null and is_instance_valid(_extra_list) and _extra_list.get_item_count() > 0:
				_extra_list.select(0)
			_deselect_other_lists(_extra_list)


# ── Current slot selection (cross signals: vanilla list / extra list) ─────────

func _on_extra_item_selected(index: int) -> void:
	_clear_highlight()
	_paint_slot = 8 + index
	_extra_selected = true
	_deselect_other_lists(_extra_list)


func _on_extra24_item_selected(index: int) -> void:
	_clear_highlight()
	_paint_slot = 16 + index
	_extra_selected = true
	_deselect_other_lists(_extra_list24)


func _on_vanilla_item_selected(index: int) -> void:
	_clear_highlight()
	_paint_slot = index
	_extra_selected = false
	# A vanilla slot is now active -> clear only OUR extra lists. We don't touch
	# the native lists (we don't know which one was clicked, and DD owns them).
	_deselect_extra_lists()


func _hide_hl_hint() -> void:
	if _hl_hint_panel != null and is_instance_valid(_hl_hint_panel):
		_hl_hint_panel.visible = false


func _clear_highlight() -> void:
	if _hl_slot >= 0:
		_hl_slot = -1
		_apply_highlight_params()
		_hide_hl_hint()


func _deselect_extra_lists() -> void:
	if _extra_list != null and is_instance_valid(_extra_list):
		_extra_list.unselect_all()
	if _extra_list24 != null and is_instance_valid(_extra_list24):
		_extra_list24.unselect_all()


func _deselect_other_lists(keep) -> void:
	var natives = _vanilla_lists if not _vanilla_lists.empty() else [_vanilla_list]
	for l in natives:
		if l != null and is_instance_valid(l) and l != keep:
			l.unselect_all()
	for l in [_extra_list, _extra_list24]:
		if l != null and is_instance_valid(l) and l != keep:
			l.unselect_all()


# ===== Third-party "Set Terrain Slot" compatibility =====
# The AdditionalSearchOptions mod applies the selected search thumbnail to
# TerrainBrush.TerrainID (a vanilla slot). When one of OUR slots (9-24) is the
# active selection, route the apply to that slot instead; otherwise delegate to
# the third-party's own handler so vanilla behaviour is unchanged.
func _try_hook_set_terrain_slot() -> void:
	if _ts_hooked:
		if _ts_btn != null and is_instance_valid(_ts_btn) and _ts_btn.is_connected("pressed", self, "_on_set_terrain_slot"):
			return
		_ts_hooked = false   # connection lost -> re-hook
	_ts_hook_timer += 1
	if _ts_hook_timer % 30 != 0 or _ts_hook_timer > 30 * 120:
		return
	if _g == null or _g.get("Editor") == null:
		return
	# Find the button by its "pressed" connection to the third-party handler,
	# NOT by text (CreateButton text/styling is unreliable).
	var btn = null
	var inst = null
	var stack = [_g.Editor]
	while not stack.empty():
		var n = stack.pop_back()
		if n is Button:
			for c in n.get_signal_connection_list("pressed"):
				if str(c.get("method")) == "on_set_terrain_slot_button_pressed":
					btn = n
					inst = c.get("target")
					break
		if btn != null:
			break
		for ch in n.get_children():
			stack.push_back(ch)
	if btn == null or inst == null:
		return
	btn.disconnect("pressed", inst, "on_set_terrain_slot_button_pressed")
	btn.connect("pressed", self, "_on_set_terrain_slot")
	_ts_btn = btn
	_ts_inst = inst
	_ts_method = "on_set_terrain_slot_button_pressed"
	_ts_hooked = true
	print("[Terrain16] Hooked third-party 'Set Terrain Slot' button.")


func _ts_selected_path():
	if _ts_inst == null or not is_instance_valid(_ts_inst):
		return null
	var cfg = _ts_inst.get("ui_config")
	if not (cfg is Dictionary) or not cfg.has("TerrainBrush"):
		return null
	var tb = cfg["TerrainBrush"]
	if not (tb is Dictionary) or not tb.has("main"):
		return null
	var m = tb["main"]
	if not (m is Dictionary) or not m.has("grid_menu"):
		return null
	var grid = m["grid_menu"]
	if grid == null or not is_instance_valid(grid):
		return null
	var sel = grid.get("Selected")
	if sel == null or not (sel is Texture):
		return null
	return sel.resource_path


func _reselect_active_extra() -> void:
	if _paint_slot >= 16:
		if _extra_list24 != null and is_instance_valid(_extra_list24) and (_paint_slot - 16) < _extra_list24.get_item_count():
			_extra_list24.select(_paint_slot - 16)
		_deselect_other_lists(_extra_list24)
	elif _paint_slot >= 8:
		if _extra_list != null and is_instance_valid(_extra_list) and (_paint_slot - 8) < _extra_list.get_item_count():
			_extra_list.select(_paint_slot - 8)
		_deselect_other_lists(_extra_list)


# Returns 8..23 if one of our extra slots is the active target, else -1.
func _active_extra_slot() -> int:
	if not _active:
		return -1
	if _extra_list24 != null and is_instance_valid(_extra_list24):
		var s = _extra_list24.get_selected_items()
		if s.size() > 0:
			return 16 + s[0]
	if _extra_list != null and is_instance_valid(_extra_list):
		var s2 = _extra_list.get_selected_items()
		if s2.size() > 0:
			return 8 + s2[0]
	if _extra_selected and _paint_slot >= 8:
		return _paint_slot
	return -1


func _on_set_terrain_slot() -> void:
	# Route to our extra slot (9-24) when one is the active target.
	var slot = _active_extra_slot()
	if slot >= 8:
		var path = _ts_selected_path()
		if path != null and path != "":
			_paint_slot = slot
			_extra_selected = true
			_set_extra_slot(slot, path)
			_reselect_active_extra()
			return
	# Vanilla / fallback: run the third-party's own handler unchanged.
	if _ts_inst != null and is_instance_valid(_ts_inst) and _ts_method != "" and _ts_inst.has_method(_ts_method):
		_ts_inst.call(_ts_method)


# Runs deferred from _tick. Re-checks the active slot at execution time so a
# fresh vanilla click (which sets _paint_slot < 8) is never clobbered.
func _enforce_vanilla_deselect() -> void:
	if not _extra_selected:
		return
	var natives = _vanilla_lists if not _vanilla_lists.empty() else [_vanilla_list]
	for l in natives:
		if l != null and is_instance_valid(l) and l.get_selected_items().size() > 0:
			l.unselect_all()


# ── Extra slot textures ───────────────────────────────────────────────────────

func _set_extra_slot(slot: int, path) -> void:
	var i = slot - 8
	if i < 0 or i > 15:
		return
	_extra_paths[i] = path
	_ensure_extra_array()
	if _extra_sizes.size() != 16:
		_extra_sizes = _default_sizes()
	var img = _load_image(path)
	if img != null and _extra_array != null:
		_extra_array.set_layer_data(img, i)
	_extra_sizes[i] = _last_native_size if path != null else Vector2(EXTRA_TEX_SIZE, EXTRA_TEX_SIZE)
	var mat = _get_material(_get_terrain())
	if mat != null:
		mat.set_shader_param("extra_terrains", _extra_array)
		_push_extra_sizes(mat)
	_refresh_row_icon(i)
	_mark_persist_dirty()


# Loads the REAL (tileable) texture for the shader. ResourceLoader fails on some
# pack assets (.webp) -> fall back to Image.load (reads png/webp from the virtual
# FS, packs included), then as a last resort DD's thumbnail.
func _load_texture(path):
	if path == null:
		return _fallback_tex()
	var t = ResourceLoader.load(path)
	if t != null and t is Texture:
		return t
	var img = Image.new()
	if img.load(path) == OK:
		var it = ImageTexture.new()
		it.create_from_image(img, 6)   # FLAG_REPEAT | FLAG_FILTER (like DD for terrain)
		return it
	if _thumb_by_path.has(path) and _thumb_by_path[path] != null:
		return _thumb_by_path[path]
	# Last resort: a visible solid texture (never null -> a null sampler can read
	# as black/white and break the height blend). Magenta = "texture failed to
	# load", so it's obvious in-editor rather than a confusing black.
	print("[Terrain16] Could not load terrain texture: ", path)
	return _fallback_tex()


var _fallback_tex_cache = null
func _fallback_tex():
	if _fallback_tex_cache != null and is_instance_valid(_fallback_tex_cache):
		return _fallback_tex_cache
	var img = Image.new()
	img.create(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 0, 1, 1))   # magenta, fully opaque (alpha = full height)
	var tex = ImageTexture.new()
	tex.create_from_image(img, 6)
	_fallback_tex_cache = tex
	return tex


func _refresh_row_icon(i: int) -> void:
	var lst = null
	var row = -1
	if i >= 0 and i < 8:
		lst = _extra_list; row = i
	elif i >= 8 and i < 16:
		lst = _extra_list24; row = i - 8
	if lst == null or not is_instance_valid(lst):
		return
	if row < 0 or row >= lst.get_item_count():
		return
	var path = _extra_paths[i]
	lst.set_item_text(row, _display_name(path))
	lst.set_item_icon(row, _thumb(path))


func _refresh_all_row_icons() -> void:
	for i in range(16):
		_refresh_row_icon(i)


func _get_thumb(path):
	if path == null:
		return null
	if _thumb_cache.has(path):
		return _thumb_cache[path]
	var full = load(path)
	var img = null
	if full != null and full is Texture:
		img = full.get_data()
	if img == null:
		# Pack non chargé avec la map : ResourceLoader échoue. On lit les pixels
		# bruts du .webp/.png via Image.load (FS virtuel, packs inclus) pour
		# générer la miniature nous-mêmes au lieu d'une icône vide.
		var im = Image.new()
		if im.load(path) == OK:
			img = im
	if img == null:
		return full
	img = img.duplicate()
	img.resize(150, 150)
	var th = ImageTexture.new()
	th.create_from_image(img, 0)
	_thumb_cache[path] = th
	return th


# ── Fill ──────────────────────────────────────────────────────────────────────

func _on_fill_pressed() -> void:
	if _active:
		do_fill(_paint_slot)


var _trash_icon_cache = null
func _trash_icon():
	if _trash_icon_cache != null and is_instance_valid(_trash_icon_cache):
		return _trash_icon_cache
	var root = ""
	if _g != null and _g.get("Root") != null and _g.Root is String:
		root = _g.Root
	if root == "":
		return null
	var img = Image.new()
	if img.load(root + "icons/trash.png") != OK:
		return null
	img.resize(18, 18, Image.INTERPOLATE_LANCZOS)   # small button icon
	var tex = ImageTexture.new()
	tex.create_from_image(img, ImageTexture.FLAG_FILTER)
	_trash_icon_cache = tex
	return tex


# ── Terrain presets ───────────────────────────────────────────────────────────
# A preset is the full 24-slot palette: 8 native paths + 16 extended paths.
# Stored as JSON: { "Name": { "native": [8 paths], "extra": [16 paths] }, ... }.
# A null entry = "leave that slot untouched" when applying (non-destructive).

func _presets_load_all() -> Dictionary:
	var f = File.new()
	if not f.file_exists(PRESETS_PATH):
		return {}
	if f.open(PRESETS_PATH, File.READ) != OK:
		return {}
	var t = f.get_as_text()
	f.close()
	var parsed = JSON.parse(t)
	if parsed.error != OK or not (parsed.result is Dictionary):
		return {}
	return parsed.result


func _presets_save_all(all: Dictionary) -> void:
	_ensure_persist_dir()
	var f = File.new()
	if f.open(PRESETS_PATH, File.WRITE) == OK:
		f.store_string(JSON.print(all, "\t"))
		f.close()


# Snapshot the current palette into the groups ticked on the Save row. A group
# is only stored if ticked AND it actually holds at least one texture. Format:
# { "g1": [8 native paths], "g2": [8 paths 9-16], "g3": [8 paths 17-24] } with
# any subset of keys present.
func _capture_preset() -> Dictionary:
	var out = {}
	if _save_g1 != null and _save_g1.pressed:
		var native = []
		var terrain = _get_terrain()
		for i in range(8):
			var p = null
			if terrain != null:
				var tex = terrain.GetTexture(i)
				if tex != null and tex.resource_path != "":
					p = tex.resource_path
			native.append(p)
		if _group_present(native):
			out["g1"] = native
	if _save_g2 != null and _save_g2.pressed:
		var g2 = []
		for j in range(8):
			g2.append(_extra_paths[j] if j < _extra_paths.size() else null)
		if _group_present(g2):
			out["g2"] = g2
	if _save_g3 != null and _save_g3.pressed:
		var g3 = []
		for j in range(8):
			g3.append(_extra_paths[8 + j] if (8 + j) < _extra_paths.size() else null)
		if _group_present(g3):
			out["g3"] = g3
	return out


# Normalises a preset (new group format OR the old {native, extra} format) into
# { "g1", "g2", "g3" } arrays (or null when a group is absent).
func _preset_groups(p: Dictionary) -> Dictionary:
	var g1 = p["g1"] if p.has("g1") else (p["native"] if p.has("native") else null)
	var g2 = p["g2"] if p.has("g2") else null
	var g3 = p["g3"] if p.has("g3") else null
	if (g2 == null and g3 == null) and p.has("extra") and p["extra"] is Array:
		var ex = p["extra"]
		if ex.size() >= 8:
			g2 = ex.slice(0, 7)
		if ex.size() >= 16:
			g3 = ex.slice(8, 15)
	return {"g1": g1, "g2": g2, "g3": g3}


# True if a group holds at least one real (non-null/non-empty) texture path.
func _group_present(arr) -> bool:
	if not (arr is Array):
		return false
	for x in arr:
		if x != null and x != "":
			return true
	return false


func _apply_native_slot(i: int, path) -> void:
	var terrain = _get_terrain()
	if not _apply_native_slot_on(terrain, i, path):
		return
	# Mémorise le chemin posé pour ce slot natif : DD ne sauvegarde les slots
	# 1-8 que par référence d'asset, donc au reload sans le pack chargé il ne
	# les résout plus (blanc). On garde nous-mêmes le chemin pour les ré-appliquer
	# au restore via le fallback Image.load (comme les presets).
	_track_native_path(terrain, i, path)
	_mark_persist_dirty()


# Pose une texture sur un slot natif (1-8) d'un terrain DONNÉ (pas forcément le
# niveau courant). Retourne true si appliqué. Met à jour la liste vanilla
# uniquement si le terrain visé est le niveau actuellement affiché.
func _apply_native_slot_on(terrain, i: int, path) -> bool:
	if path == null or path == "":
		return false
	if terrain == null or not is_instance_valid(terrain):
		return false
	var tex = _load_texture(path)
	if tex == null:
		return false
	# Les slots natifs 1-8 sont relus par TerrainBrush.Enable() de DD, qui fait
	# Library["Terrain"].Reverse[tex.ResourcePath] SANS garde. Une texture issue du
	# fallback runtime (_load_texture -> Image.load / _fallback_tex) a un
	# resource_path vide -> Reverse[""] lève une KeyNotFoundException. Cette
	# exception remonte dans ToolbarButton._Toggled et l'avorte AVANT le
	# ModalStack.Push(this) : le bouton du sous-outil n'est jamais empilé, donc au
	# switch de sous-outil suivant le panneau Terrain n'est pas masqué (bug du
	# panneau collé). On rattache donc le chemin d'origine sur ces textures runtime.
	if tex.resource_path == "":
		if _thumb_by_path.has(path):
			# DD connaît ce chemin (présent dans Reverse) : take_over_path -> Reverse[path]
			# résout. Uniquement sur une texture runtime à path vide -> aucune ressource
			# partagée touchée, pas de casse de cache (cf. note free_transform).
			tex.take_over_path(path)
		else:
			# DD ne connaît pas ce chemin : Reverse[path] planterait aussi. Mieux vaut
			# laisser le slot natif tel quel (blanc) que faire planter Enable().
			return false
	terrain.SetTexture(tex, i)   # DD ignores i >= its native slot count
	if terrain == _get_terrain():
		var lst = _get_vanilla_terrain_list()
		if lst != null and is_instance_valid(lst) and i < lst.get_item_count():
			lst.set_item_icon(i, _thumb(path))
			lst.set_item_text(i, _display_name(path))
	return true


# Stocke par niveau le chemin assigné à un slot natif (0-7).
func _track_native_path(terrain, i: int, path) -> void:
	if terrain == null or not is_instance_valid(terrain):
		return
	if i < 0 or i >= 8:
		return
	var id = terrain.get_instance_id()
	var e = _lv.get(id, {})
	if not (e.get("npaths") is Array) or e["npaths"].size() != 8:
		e["npaths"] = ["", "", "", "", "", "", "", ""]
	e["npaths"][i] = path if (path is String) else ""
	_lv[id] = e


# Ré-applique les chemins natifs mémorisés à un terrain, UNE seule fois après un
# reload (drapeau "need_native"). One-shot pour ne pas écraser une édition que
# l'utilisateur ferait ensuite via l'UI vanilla de DD (les slots 1-8 restent à
# DD ; on ne fait que réparer le cas pack-manquant au chargement).
func _apply_native_palette(terrain) -> void:
	if terrain == null or not is_instance_valid(terrain):
		return
	var id = terrain.get_instance_id()
	var e = _lv.get(id)
	if e == null or not e.get("need_native", false):
		return
	var np = e.get("npaths")
	if np is Array:
		for i in range(min(8, np.size())):
			var p = np[i]
			if p is String and p != "":
				_apply_native_slot_on(terrain, i, p)
	e["need_native"] = false
	_lv[id] = e
	# DD reconstruit / re-vide la liste vanilla APRÈS nous (timing inconnu : la
	# repopulation post-reload peut tomber bien après ExpandSlots). On arme un
	# re-stamp qui ne réécrit QUE les libellés vides et s'auto-arrête une fois
	# stabilisé — il rattrape ainsi le moment où DD blanchit les slots de pack
	# manquant, quel qu'il soit.
	_nlbl_terrain = terrain
	_nlbl_frames = 600   # plafond de sécurité (~10 s)
	_nlbl_stable = 0


# Repose le texte + l'icône des slots natifs (depuis npaths) sur la liste
# vanilla. DD repopule sa liste après le reload et laisse les slots de pack
# manquant sans le bon nom (placeholder vide/non résolu) : on impose le nom
# voulu. On ne traite QUE les slots assignés par le mod (npaths) → on ne combat
# jamais un slot vanilla posé par l'utilisateur. Idempotent : on n'écrit que si
# le libellé courant diffère du nom voulu. Ne touche jamais la texture.
# Retour : -1 = liste pas prête (ligne attendue absente), 0 = rien à corriger
# (stabilisé), 1 = au moins un libellé corrigé.
func _refresh_native_labels(terrain) -> int:
	if terrain == null or not is_instance_valid(terrain):
		return -1
	if terrain != _get_terrain():
		return -1
	var e = _lv.get(terrain.get_instance_id())
	if e == null:
		return 0
	var np = e.get("npaths")
	if not (np is Array):
		return 0
	var lst = _get_vanilla_terrain_list()
	if lst == null or not is_instance_valid(lst):
		return -1
	var cnt = lst.get_item_count()
	var changed := false
	var pending := false   # un slot à corriger existe mais sa ligne n'est pas encore là
	for i in range(min(8, np.size())):
		var p = np[i]
		if not (p is String and p != ""):
			continue
		if i >= cnt:
			pending = true   # liste pas encore étendue à 8 → on réessaiera
			continue
		var want = _display_name(p)
		if lst.get_item_text(i) != want:
			lst.set_item_text(i, want)
			lst.set_item_icon(i, _thumb(p))
			changed = true
	if changed:
		return 1
	if pending:
		return -1
	return 0


# Apply only the groups that are present in the preset AND ticked on the Load row.
func _apply_preset(p: Dictionary) -> void:
	_mark_persist_dirty()
	var g = _preset_groups(p)
	var do_g1 = _load_g1 != null and _load_g1.pressed and _group_present(g["g1"])
	var do_g2 = _load_g2 != null and _load_g2.pressed and _group_present(g["g2"])
	var do_g3 = _load_g3 != null and _load_g3.pressed and _group_present(g["g3"])
	# Turn on the modes the load actually needs before assigning extended slots.
	if do_g2 and not _active:
		_on_toggle(true)
	if do_g3 and not _active24:
		_on_toggle24(true)
	if do_g1:
		for i in range(min(8, g["g1"].size())):
			_apply_native_slot(i, g["g1"][i])
	if do_g2:
		for j in range(min(8, g["g2"].size())):
			var ep = g["g2"][j]
			if ep != null and ep != "":
				_set_extra_slot(8 + j, ep)
	if do_g3:
		for j in range(min(8, g["g3"].size())):
			var ep3 = g["g3"][j]
			if ep3 != null and ep3 != "":
				_set_extra_slot(16 + j, ep3)
	_refresh_all_row_icons()


# Capture/apply one group of 8 slots by index: 0 = slots 1-8 (native), 1 = 9-16,
# 2 = 17-24. Shared by the copy/paste clipboard.
func _capture_group(gi: int) -> Array:
	var out = []
	if gi == 0:
		var terrain = _get_terrain()
		for i in range(8):
			var p = null
			if terrain != null:
				var tex = terrain.GetTexture(i)
				if tex != null and tex.resource_path != "":
					p = tex.resource_path
			out.append(p)
	elif gi == 1:
		for j in range(8):
			out.append(_extra_paths[j] if j < _extra_paths.size() else null)
	else:
		for j in range(8):
			out.append(_extra_paths[8 + j] if (8 + j) < _extra_paths.size() else null)
	return out


func _apply_group(gi: int, paths) -> void:
	if not (paths is Array):
		return
	if gi == 0:
		for i in range(min(8, paths.size())):
			_apply_native_slot(i, paths[i])
	elif gi == 1:
		if not _active:
			_on_toggle(true)
		for j in range(min(8, paths.size())):
			var p = paths[j]
			if p != null and p != "":
				_set_extra_slot(8 + j, p)
	else:
		if not _active24:
			_on_toggle24(true)
		for j in range(min(8, paths.size())):
			var p3 = paths[j]
			if p3 != null and p3 != "":
				_set_extra_slot(16 + j, p3)
	_refresh_all_row_icons()


# ── Single-slot copy/paste via right-click on a slot ──────────────────────────
func _capture_slot(slot: int):
	if slot >= 0 and slot < 8:
		var terrain = _get_terrain()
		if terrain != null:
			var tex = terrain.GetTexture(slot)
			if tex != null and tex.resource_path != "":
				return tex.resource_path
		return null
	var k = slot - 8
	if k >= 0 and k < _extra_paths.size():
		return _extra_paths[k]
	return null


func _apply_slot(slot: int, path) -> void:
	if path == null or path == "":
		return
	if slot >= 0 and slot < 8:
		_apply_native_slot(slot, path)
	elif slot >= 8 and slot < 16:
		if not _active:
			_on_toggle(true)
		_set_extra_slot(slot, path)
	elif slot >= 16 and slot < 24:
		if not _active24:
			_on_toggle24(true)
		_set_extra_slot(slot, path)
	_refresh_all_row_icons()


# Right-click handlers: native list item index == slot; extended lists add base.
func _on_vanilla_item_rmb(index: int, _at_pos = null) -> void:
	_show_slot_context_menu(index)


func _on_slot_row_rmb(index: int, _at_pos, base_slot: int) -> void:
	_show_slot_context_menu(base_slot + index)


func _show_slot_context_menu(slot: int) -> void:
	if _g == null or _g.get("Editor") == null:
		return
	var menu = PopupMenu.new()
	menu.add_item("Copy slot", 0)
	menu.add_item("Paste slot", 1)
	if _slot_clipboard == null or _slot_clipboard == "":
		menu.set_item_disabled(menu.get_item_index(1), true)
	menu.connect("id_pressed", self, "_on_slot_menu_id", [slot])
	menu.connect("popup_hide", menu, "queue_free")
	_get_popup_layer().add_child(menu)
	var mp = _g.Editor.get_tree().get_root().get_mouse_position()
	menu.popup(Rect2(mp, Vector2(1, 1)))


# A high CanvasLayer so our context menu draws above DD's UI (which sits on its
# own layer); adding the menu straight to the root viewport puts it underneath.
func _get_popup_layer() -> CanvasLayer:
	if _slot_popup_layer != null and is_instance_valid(_slot_popup_layer):
		return _slot_popup_layer
	_slot_popup_layer = CanvasLayer.new()
	_slot_popup_layer.name = "Terrain16SlotPopupLayer"
	_slot_popup_layer.layer = 128
	_g.Editor.get_tree().get_root().add_child(_slot_popup_layer)
	return _slot_popup_layer


func _on_slot_menu_id(id: int, slot: int) -> void:
	if id == 0:
		_slot_clipboard = _capture_slot(slot)
		print("[Terrain16] Copied slot ", slot + 1)
	elif id == 1:
		_apply_slot(slot, _slot_clipboard)
		print("[Terrain16] Pasted into slot ", slot + 1)


# Push the highlight uniforms onto the current level's terrain material.
func _apply_highlight_params() -> void:
	var mat = _get_material(_get_terrain())
	if mat != null:
		mat.set_shader_param("hl_on", _hl_slot >= 0)
		mat.set_shader_param("hl_slot", _hl_slot)
	_set_brush_controls_dimmed(_hl_slot >= 0)


# Slot que le pinceau peindrait actuellement : le slot etendu selectionne si
# l'utilisateur en a choisi un, sinon le TerrainID natif courant.
func _current_paint_slot() -> int:
	if not _extra_selected and _g != null and _g.get("Editor") != null:
		var tools = _g.Editor.get("Tools")
		if tools != null and tools.has("TerrainBrush"):
			var tb = tools["TerrainBrush"]
			if tb != null:
				_paint_slot = int(tb.get("TerrainID"))
	return _paint_slot


# Bascule le surlignage du slot courant depuis un clic droit sur la map.
func _toggle_map_highlight() -> void:
	if _hl_slot >= 0:
		_hl_slot = -1
		_hide_hl_hint()
	else:
		var slot = _current_paint_slot()
		if slot < 0:
			return
		_hl_slot = slot
		# Le surlignage exige notre shader actif ; les slots 17-24 exigent le mode 24
		# (leur splat n'est lie qu'a ce moment-la).
		if slot >= 16 and not _active24:
			_on_toggle24(true)
		elif not _active:
			_on_toggle(true)
	_apply_highlight_params()


# Grey out AND block DD's brush controls (tool buttons, Brush Size, Intensity)
# while highlight mode is on, since painting is disabled. They sit in `align`
# BEFORE the terrain list, so we walk those children only — the slot list and
# our own UI stay interactive. Disabling (editable/disabled) gives the theme's
# native greyed look and blocks input; labels are dimmed via modulate. All
# original values are remembered so we can restore them exactly.
var _brush_dim_state := []

func _set_brush_controls_dimmed(on: bool) -> void:
	# Restore any previously changed controls first (idempotent).
	for entry in _brush_dim_state:
		var n = entry[0]
		if is_instance_valid(n):
			n.set(entry[1], entry[2])
	_brush_dim_state = []
	if not on:
		return
	if _terrain_panel == null or not is_instance_valid(_terrain_panel):
		return
	var align = _terrain_panel.get("Align")
	if align == null or not is_instance_valid(align):
		return
	var list_idx = _section_align_index(align)
	if list_idx < 0:
		return
	for i in range(list_idx):
		_dim_subtree(align.get_child(i))


func _dim_subtree(node) -> void:
	if node == null or not is_instance_valid(node):
		return
	if node is Slider or node is SpinBox:   # HSlider / SpinBox: block + theme-grey
		_remember(node, "editable", node.editable)
		node.editable = false
		_remember(node, "modulate", node.modulate)
		node.modulate = Color(0.5, 0.5, 0.5, 1.0)
	elif node is LineEdit:
		_remember(node, "editable", node.editable)
		node.editable = false
	elif node is BaseButton:     # tool-mode buttons, checkboxes
		_remember(node, "disabled", node.disabled)
		node.disabled = true
	elif node is Label:
		_remember(node, "modulate", node.modulate)
		node.modulate = Color(0.5, 0.5, 0.5, 1.0)
	for c in node.get_children():
		_dim_subtree(c)


func _remember(node, prop: String, val) -> void:
	_brush_dim_state.append([node, prop, val])


func _on_copy_group() -> void:
	if _copyio_dropdown == null or not is_instance_valid(_copyio_dropdown):
		return
	var gi = _copyio_dropdown.selected
	if gi < 0:
		gi = 0
	_clipboard_group = _capture_group(gi)
	if _paste_btn != null and is_instance_valid(_paste_btn):
		_paste_btn.disabled = not _group_present(_clipboard_group)
	print("[Terrain16] Copied slots ", _copyio_dropdown.get_item_text(gi))


func _on_paste_group() -> void:
	if _copyio_dropdown == null or not is_instance_valid(_copyio_dropdown):
		return
	if not (_clipboard_group is Array) or _clipboard_group.empty():
		return
	var gi = _copyio_dropdown.selected
	if gi < 0:
		gi = 0
	_apply_group(gi, _clipboard_group)
	print("[Terrain16] Pasted into slots ", _copyio_dropdown.get_item_text(gi))


# Set the Load-row checkboxes to match the selected preset's contents: present
# groups are ticked + enabled (untickable for partial load), absent groups are
# unticked + greyed out (can't be ticked).
func _update_load_checks() -> void:
	var g = {"g1": null, "g2": null, "g3": null}
	var pname = _selected_preset_name()
	if pname != "":
		var all = _presets_load_all()
		if all.has(pname) and all[pname] is Dictionary:
			g = _preset_groups(all[pname])
	_set_load_check(_load_g1, _group_present(g["g1"]))
	_set_load_check(_load_g2, _group_present(g["g2"]))
	_set_load_check(_load_g3, _group_present(g["g3"]))


func _set_load_check(cb: CheckBox, present: bool) -> void:
	if cb == null or not is_instance_valid(cb):
		return
	cb.disabled = not present
	cb.pressed = present


func _refresh_preset_dropdown() -> void:
	if _preset_dropdown == null or not is_instance_valid(_preset_dropdown):
		return
	var keep = _preset_dropdown.get_item_count() > 0 and _preset_dropdown.selected >= 0
	var prev = _preset_dropdown.get_item_text(_preset_dropdown.selected) if keep else ""
	_preset_dropdown.clear()
	var all = _presets_load_all()
	var names = all.keys()
	names.sort()
	for n in names:
		_preset_dropdown.add_item(n)
	# Restore previous selection if it still exists.
	for idx in range(_preset_dropdown.get_item_count()):
		if _preset_dropdown.get_item_text(idx) == prev:
			_preset_dropdown.select(idx)
			break


func _selected_preset_name() -> String:
	if _preset_dropdown == null or not is_instance_valid(_preset_dropdown):
		return ""
	if _preset_dropdown.get_item_count() == 0 or _preset_dropdown.selected < 0:
		return ""
	return _preset_dropdown.get_item_text(_preset_dropdown.selected)


func _on_preset_chosen(_index: int) -> void:
	# Mirror the chosen name into the name field for easy overwrite/delete.
	if _preset_name_edit != null and is_instance_valid(_preset_name_edit):
		_preset_name_edit.text = _selected_preset_name()
	_update_load_checks()


func _on_preset_save() -> void:
	var pname = ""
	if _preset_name_edit != null and is_instance_valid(_preset_name_edit):
		pname = _preset_name_edit.text.strip_edges()
	if pname == "":
		pname = _selected_preset_name()
	if pname == "":
		print("[Terrain16] Preset save: please type a name first.")
		return
	var all = _presets_load_all()
	all[pname] = _capture_preset()
	_presets_save_all(all)
	_refresh_preset_dropdown()
	# Select the just-saved preset.
	for idx in range(_preset_dropdown.get_item_count()):
		if _preset_dropdown.get_item_text(idx) == pname:
			_preset_dropdown.select(idx)
			break
	_update_load_checks()
	print("[Terrain16] Saved terrain preset: ", pname)


func _on_preset_apply() -> void:
	var pname = _selected_preset_name()
	if pname == "":
		return
	var all = _presets_load_all()
	if not all.has(pname) or not (all[pname] is Dictionary):
		return
	_apply_preset(all[pname])
	print("[Terrain16] Loaded terrain preset: ", pname)


func _on_preset_delete() -> void:
	var pname = _selected_preset_name()
	if pname == "":
		return
	if _g == null or _g.get("Editor") == null:
		return
	var dlg = WindowDialog.new()
	dlg.window_title = "Delete preset"
	dlg.rect_min_size = Vector2(320, 0)

	var vbox = VBoxContainer.new()
	vbox.anchor_right = 1.0
	vbox.anchor_bottom = 1.0
	vbox.margin_left = 14
	vbox.margin_right = -14
	vbox.margin_top = 10
	vbox.margin_bottom = -8
	vbox.set("custom_constants/separation", 14)
	dlg.add_child(vbox)

	var msg = Label.new()
	msg.text = "Delete preset \"" + pname + "\"?"
	msg.align = Label.ALIGN_CENTER
	vbox.add_child(msg)

	var row = HBoxContainer.new()
	row.alignment = BoxContainer.ALIGN_CENTER
	row.set("custom_constants/separation", 20)
	vbox.add_child(row)

	var ok_btn = Button.new()
	ok_btn.text = "Delete"
	ok_btn.rect_min_size = Vector2(110, 32)
	ok_btn.connect("pressed", self, "_do_preset_delete", [pname])
	ok_btn.connect("pressed", dlg, "hide")
	_add_button_border(ok_btn)
	row.add_child(ok_btn)

	var cancel_btn = Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.rect_min_size = Vector2(110, 32)
	cancel_btn.connect("pressed", dlg, "hide")
	_add_button_border(cancel_btn)
	row.add_child(cancel_btn)

	dlg.connect("popup_hide", dlg, "queue_free")
	_g.Editor.get_tree().get_root().add_child(dlg)
	# Background blur via the Popup Blur mod (if present). Our window isn't under
	# Master/Editor/Windows, so it isn't patched automatically -> register it.
	if Engine.has_meta("popup_blur_singleton"):
		var pb = Engine.get_meta("popup_blur_singleton")
		if pb != null and pb.has_method("register"):
			pb.register(dlg)
	yield(_g.Editor.get_tree(), "idle_frame")
	var h = vbox.rect_size.y + dlg.get_constant("title_height", "WindowDialog") + 16
	dlg.rect_size = Vector2(320, h)
	dlg.popup_centered()


# Native DD button look + a crisp 1px white border on every interactive state.
# Duplicating the theme's StyleBoxFlat keeps DD's background/corners; we only add
# the border. "disabled" is left untouched so greyed-out buttons stay greyed.
func _add_button_border(btn: Button) -> void:
	for state in ["normal", "hover", "pressed", "focus"]:
		var existing = btn.get_stylebox(state, "Button")
		var sb = StyleBoxFlat.new()
		if existing != null and existing is StyleBoxFlat:
			sb = existing.duplicate()
		sb.border_width_top = 1
		sb.border_width_bottom = 1
		sb.border_width_left = 1
		sb.border_width_right = 1
		sb.border_color = Color.white
		btn.add_stylebox_override(state, sb)


func _do_preset_delete(pname: String) -> void:
	if pname == "":
		return
	var all = _presets_load_all()
	if all.has(pname):
		all.erase(pname)
		_presets_save_all(all)
		_refresh_preset_dropdown()
		_update_load_checks()
		print("[Terrain16] Deleted terrain preset: ", pname)



# ── Texture picker (popup) ────────────────────────────────────────────────────

# ===== Favorites integration =====
# Shares the sibling "Favorites" mod data. When that mod is loaded we go
# through its singleton so adds/removes stay consistent with its in-memory
# state, its favorites.json and its generated pack. When it is not loaded we
# read/write the shared favorites.json directly (display + persistence still
# work standalone). Terrain favorites use the mod type id 9.
const FAV_GROUP := "Favorites"
const ALL_GROUP := "All"
const FAV_JSON := "user://UnofficialPatch/Favorites/favorites.json"


func _favorites_mod():
	if not Engine.has_meta("favorites_singleton"):
		return null
	var m = Engine.get_meta("favorites_singleton")
	if m != null and is_instance_valid(m) and m.has_method("_add_to_favorites"):
		return m
	return null


func _ensure_fav_icon() -> void:
	if _fav_icon_loaded:
		return
	_fav_icon_loaded = true
	var root = ""
	if _g != null and _g.get("Root") != null and _g.Root is String:
		root = _g.Root
	if root == "":
		return
	var img = Image.new()
	if img.load(root + "icons/fav2.png") == OK:
		var t = ImageTexture.new()
		t.create_from_image(img, 0)
		_fav_icon = t


# Badge size (px) and texture, matching favorites.gd exactly: fav1.png
# resized with INTERPOLATE_LANCZOS + create_from_image(FLAG_FILTER), at the
# mod's configurable badge size. Reuses the live Favorites instance when
# present so size/quality stay in sync.
func _fav_badge_size() -> int:
	var m = _favorites_mod()
	if m != null and m.get("_badge_size_value") != null:
		return int(m._badge_size_value)
	return 16


func _fav_badge_tex():
	var m = _favorites_mod()
	if m != null and m.has_method("_get_scaled_badge"):
		return m._get_scaled_badge(_fav_badge_size())
	# Fallback: load + scale fav1.png ourselves (same method).
	if _fav_badge_fallback != null:
		return _fav_badge_fallback
	var root = ""
	if _g != null and _g.get("Root") != null and _g.Root is String:
		root = _g.Root
	if root == "":
		return null
	var img = Image.new()
	if img.load(root + "icons/fav1.png") != OK:
		return null
	var sz = _fav_badge_size()
	img.resize(sz, sz, Image.INTERPOLATE_LANCZOS)
	var tex = ImageTexture.new()
	tex.create_from_image(img, ImageTexture.FLAG_FILTER)
	_fav_badge_fallback = tex
	return tex


func _read_fav_json() -> Dictionary:
	var f = File.new()
	if f.open(FAV_JSON, File.READ) != OK:
		return {}
	var txt = f.get_as_text()
	f.close()
	var pr = JSON.parse(txt)
	if pr.error == OK and pr.result is Dictionary:
		return pr.result
	return {}


func _reload_fav_set() -> void:
	_fav_set = {}
	var favs = null
	var m = _favorites_mod()
	if m != null:
		favs = m.get("_favorites")
	if favs == null or not (favs is Dictionary):
		favs = _read_fav_json()
	if favs is Dictionary:
		for k in favs.keys():
			var info = favs[k]
			if info is Dictionary and int(info.get("type", -1)) == 9:
				_fav_set[k] = true


func _is_fav(path) -> bool:
	return path != null and _fav_set.has(path)


func _sorted_fav_paths() -> Array:
	var arr = _fav_set.keys()
	arr.sort()
	return arr


# Favorites whose texture is actually loaded. Favorites pointing at packs
# that are not currently loaded are skipped (their thumbnails are missing).
func _loaded_fav_paths() -> Array:
	var loaded = {}
	for g in _pack_order:
		for pp in _pack_groups.get(g, []):
			loaded[pp] = true
	var out = []
	for pp in _fav_set.keys():
		if loaded.has(pp) or _thumb_by_path.has(pp):
			out.append(pp)
	out.sort()
	return out


func _list_index_for_group(gname) -> int:
	for i in range(_picker_list_groups.size()):
		if _picker_list_groups[i] == gname:
			return i
	return -1


func _toggle_fav_file(path, want_add: bool) -> void:
	var favs = _read_fav_json()
	if want_add:
		var base = path.get_file().get_basename()
		var ext = path.get_extension()
		favs[path] = {
			"pack_path": "textures/terrain/" + base + "." + ext,
			"type": 9,
			"color": "ffffff",
			"colorable": false
		}
	elif favs.has(path):
		favs.erase(path)
	var dir = Directory.new()
	if not dir.dir_exists("user://UnofficialPatch/Favorites"):
		dir.make_dir_recursive("user://UnofficialPatch/Favorites")
	var f = File.new()
	if f.open(FAV_JSON, File.WRITE) == OK:
		f.store_string(JSON.print(favs, "\t"))
		f.close()


func _toggle_fav(path) -> void:
	if path == null:
		return
	var want_add = not _is_fav(path)
	var had_any = not _loaded_fav_paths().empty()
	var m = _favorites_mod()
	if m != null:
		if want_add:
			m._add_to_favorites([{"tex_path": path, "type": 9, "thing": null}])
		else:
			m._remove_from_favorites([{"tex_path": path}])
	else:
		_toggle_fav_file(path, want_add)
	_reload_fav_set()
	var has_any = not _loaded_fav_paths().empty()
	# Rebuild list+grid when the Favorites row appears/disappears or we are
	# viewing it; otherwise rebuild the current grid so badges update.
	if _picker_current_group == FAV_GROUP or had_any != has_any:
		var keep = _picker_current_group
		_populate_pack_list()
		var li = _list_index_for_group(keep)
		if li < 0:
			li = 0
		if _pack_list.get_item_count() > 0:
			_pack_list.select(li)
			_populate_grid(_picker_list_groups[li])
	else:
		_populate_grid(_picker_current_group)


func _open_picker(slot: int) -> void:
	_picker_slot = slot
	# Like asset_cycle (_on_terrain_settings_pressed): clicking a slot's settings
	# button also selects it as the painted slot.
	if slot >= 8:
		_paint_slot = slot
		_extra_selected = true
		_picker_original_path = _extra_paths[slot - 8]
		var li = (slot - 8) % 8
		var lst = _extra_list if slot < 16 else _extra_list24
		if lst != null and is_instance_valid(lst) and li < lst.get_item_count():
			lst.select(li)
		_deselect_other_lists(lst)
	else:
		_picker_original_path = null
	_ensure_picker()
	if _search_edit != null and is_instance_valid(_search_edit):
		_search_edit.text = ""
	_picker_search = ""
	_ensure_catalog()
	_populate_pack_list()
	var cur = _extra_paths[slot - 8] if slot >= 8 else null
	var grp = ""
	if cur != null and not _pack_order.empty():
		grp = _pack_order[_group_index_for_path(cur)]
	var li = _list_index_for_group(grp)
	if li < 0:
		li = 0
	if _pack_list.get_item_count() > 0:
		_pack_list.select(li)
		_populate_grid(_picker_list_groups[li])
	_picker_win.popup_centered(Vector2(1040, 700))


func _ensure_picker() -> void:
	if _picker_win != null and is_instance_valid(_picker_win):
		return
	_picker_win = WindowDialog.new()
	_picker_win.window_title = "Choose a terrain texture"
	_picker_win.rect_min_size = Vector2(1040, 700)

	var root = VBoxContainer.new()
	root.anchor_right = 1.0
	root.anchor_bottom = 1.0
	root.margin_left = 8
	root.margin_top = 8
	root.margin_right = -8
	root.margin_bottom = -8
	_picker_win.add_child(root)

	# Search bar (filters thumbnails by name across all packs).
	var search_row = HBoxContainer.new()
	var search_lbl = Label.new()
	search_lbl.text = "Search"
	search_row.add_child(search_lbl)
	_search_edit = LineEdit.new()
	_search_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search_edit.placeholder_text = "Filter terrains by name…"
	_search_edit.connect("text_changed", self, "_on_picker_search")
	search_row.add_child(_search_edit)
	root.add_child(search_row)

	# Content: packs (left) + grid (right)
	var content = HBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(content)

	_pack_list = ItemList.new()
	_pack_list.rect_min_size = Vector2(190, 0)
	_pack_list.connect("item_selected", self, "_on_pack_selected")
	content.add_child(_pack_list)

	_picker_scroll = ScrollContainer.new()
	_picker_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_picker_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(_picker_scroll)

	_picker_grid = GridContainer.new()
	_picker_grid.columns = 5
	_picker_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_picker_scroll.add_child(_picker_grid)

	# Button bar (bottom): Accept | circle toggle | Cancel
	var bar = HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGN_CENTER
	bar.set("custom_constants/separation", 16)
	bar.rect_min_size = Vector2(0, 48)
	root.add_child(bar)

	_picker_accept_btn = Button.new()
	_picker_accept_btn.text = "Accept"
	_picker_accept_btn.rect_min_size = Vector2(120, 34)
	_add_btn_border(_picker_accept_btn)
	_picker_accept_btn.connect("pressed", self, "_picker_accept")
	bar.add_child(_picker_accept_btn)

	_picker_toggle_btn = Button.new()
	_picker_toggle_btn.toggle_mode = true
	_picker_toggle_btn.pressed = _picker_accept_required
	_picker_toggle_btn.rect_min_size = Vector2(44, 34)
	_picker_toggle_btn.hint_tooltip = "On: a click applies the texture but keeps the popup open (Accept confirms, Cancel reverts). Off: a click applies and closes."
	_circle_icon = _make_circle_icon(18)
	if _circle_icon != null:
		_picker_toggle_btn.icon = _circle_icon
	else:
		_picker_toggle_btn.text = "O"
	_picker_toggle_btn.connect("toggled", self, "_on_picker_toggle")
	bar.add_child(_picker_toggle_btn)

	_picker_cancel_btn = Button.new()
	_picker_cancel_btn.text = "Cancel"
	_picker_cancel_btn.rect_min_size = Vector2(120, 34)
	_add_btn_border(_picker_cancel_btn)
	_picker_cancel_btn.connect("pressed", self, "_picker_cancel")
	bar.add_child(_picker_cancel_btn)

	_set_picker_buttons_enabled(_picker_accept_required)

	_g.Editor.get_tree().get_root().add_child(_picker_win)

	# Background blur via the Popup Blur mod (if present). Our window isn't under
	# Master/Editor/Windows, so Popup Blur won't patch it automatically -> we
	# register explicitly through its singleton.
	if Engine.has_meta("popup_blur_singleton"):
		var pb = Engine.get_meta("popup_blur_singleton")
		if pb != null and pb.has_method("register"):
			pb.register(_picker_win)


func _list_terrain_paths() -> Array:
	var arr = []
	var list = Script.GetAssetList("Terrain")
	if list != null:
		for p in list:
			arr.append(p)
	return arr


func _get_asset_packs():
	var ed = _g.get("Editor")
	if ed != null and ed.get("owner") != null and ("AssetPacks" in ed.owner):
		return ed.owner.AssetPacks
	return {}


func _pack_name(packs, pid) -> String:
	var p = packs[pid]
	if p != null:
		var n = p.get("Name")
		if n != null and str(n) != "":
			return str(n)
	return str(pid)


# Texture catalog: first scan DD's native Terrain window (thumbnails already
# loaded + loadable paths, packs included). Fall back to GetAssetList if the
# scan fails.
func _ensure_catalog() -> void:
	if not _pack_groups.empty():
		return
	_ensure_scanned()
	if _pack_groups.empty():
		_build_groups_fallback()


func _thumb(path):
	if path == null:
		return null
	if _thumb_by_path.has(path):
		return _thumb_by_path[path]
	return _get_thumb(path)   # fallback (rare)


func _ensure_scanned() -> void:
	if _scanned:
		return
	if _scan_native_terrain():
		_scanned = true


func _find_item_list_named(node, name):
	if node == null:
		return null
	var stack = [node]
	while not stack.empty():
		var n = stack.pop_back()
		if n is ItemList and name in n.name:
			return n
		for c in n.get_children():
			stack.push_back(c)
	return null


# Reads the native TerrainWindow: for each pack, ask DD to populate its grid,
# then read paths + thumbnails from its Lookup dictionary.
func _scan_native_terrain() -> bool:
	var ed = _g.get("Editor")
	if ed == null:
		return false
	var windows = ed.get("Windows")
	if windows == null or not windows is Dictionary:
		return false
	var tw = windows.get("TerrainWindow")
	if tw == null or not is_instance_valid(tw):
		return false

	var tex_menu = null
	var pack_list = null
	if tw.has_node("Margins/Splitter/TextureMenu"):
		tex_menu = tw.get_node("Margins/Splitter/TextureMenu")
	if tw.has_node("Margins/Splitter/PackList"):
		pack_list = tw.get_node("Margins/Splitter/PackList")
	if tex_menu == null:
		tex_menu = _find_item_list_named(tw, "TextureMenu")
	if pack_list == null:
		pack_list = _find_item_list_named(tw, "PackList")
	if tex_menu == null or pack_list == null:
		return false

	_pack_groups = {}
	_pack_order = []
	_thumb_by_path = {}

	var prev_sel = -1
	var sel = pack_list.get_selected_items()
	if sel.size() > 0:
		prev_sel = sel[0]

	var pack_count = pack_list.get_item_count()
	for pi in range(pack_count):
		var pname = pack_list.get_item_text(pi)
		# Ask DD to rebuild the grid for this pack.
		pack_list.select(pi)
		pack_list.emit_signal("item_selected", pi)
		var lookup = tex_menu.get("Lookup")
		if lookup == null or not lookup is Dictionary:
			continue
		var count = tex_menu.get_item_count()
		if not _pack_groups.has(pname):
			_pack_groups[pname] = []
			_pack_order.append(pname)
		for path in lookup:
			var idx = lookup[path]
			if not (idx is int) or idx < 0 or idx >= count:
				continue
			_thumb_by_path[path] = tex_menu.get_item_icon(idx)
			if not (path in _pack_groups[pname]):
				_pack_groups[pname].append(path)

	# Restore the original pack selection (leave the native window in a clean state).
	if prev_sel >= 0 and prev_sel < pack_count:
		pack_list.select(prev_sel)
		pack_list.emit_signal("item_selected", prev_sel)
	elif pack_count > 0:
		pack_list.select(0)
		pack_list.emit_signal("item_selected", 0)

	for g in _pack_groups.keys():
		_pack_groups[g].sort()
	return _pack_order.size() > 0


func _build_groups_fallback() -> void:
	if not _pack_order.empty():
		return   # already built (cached)
	if _terrain_paths.empty():
		_terrain_paths = _list_terrain_paths()
	var packs = _get_asset_packs()
	_pack_groups = {"Default": []}
	for path in _terrain_paths:
		var gname = "Default"
		for pid in packs.keys():
			if str(pid) in path:
				gname = _pack_name(packs, pid)
				break
		if not _pack_groups.has(gname):
			_pack_groups[gname] = []
		_pack_groups[gname].append(path)
	# Order: Default first, then packs sorted alphabetically.
	var rest = []
	for g in _pack_groups.keys():
		if g != "Default":
			rest.append(g)
	rest.sort()
	_pack_order = ["Default"] + rest
	# Sort textures by name within each group.
	for g in _pack_groups.keys():
		_pack_groups[g].sort()


func _group_index_for_path(path) -> int:
	if path == null:
		return 0
	for i in range(_pack_order.size()):
		if _pack_groups[_pack_order[i]].has(path):
			return i
	return 0


func _populate_pack_list() -> void:
	_reload_fav_set()
	var have_favs = not _loaded_fav_paths().empty()
	_picker_list_groups = []
	if have_favs:
		_picker_list_groups.append(FAV_GROUP)
	_picker_list_groups.append(ALL_GROUP)
	for g in _pack_order:
		_picker_list_groups.append(g)
	_pack_list.clear()
	for g in _picker_list_groups:
		_pack_list.add_item(g)
	if have_favs:
		_ensure_fav_icon()
		if _fav_icon != null:
			_pack_list.set_item_icon(0, _fav_icon)


func _on_pack_selected(idx: int) -> void:
	if idx >= 0 and idx < _picker_list_groups.size():
		_populate_grid(_picker_list_groups[idx])


func _on_picker_search(text: String) -> void:
	_picker_search = text.strip_edges()
	if _picker_search == "":
		_populate_grid(_picker_current_group)
	else:
		_fill_grid(_filtered_paths(_picker_current_group, _picker_search))


func _make_sel_style() -> StyleBoxFlat:
	var sb = StyleBoxFlat.new()
	sb.bg_color = Color(0.55, 0.45, 0.05, 0.25)
	sb.set_border_width_all(3)
	sb.border_color = Color(1.0, 0.85, 0.1)
	return sb


func _populate_grid(group_name: String) -> void:
	_picker_current_group = group_name
	if _picker_search != "":
		_fill_grid(_filtered_paths(group_name, _picker_search))
	else:
		_fill_grid(_paths_for_group(group_name))


func _paths_for_group(group_name: String) -> Array:
	if group_name == FAV_GROUP:
		return _loaded_fav_paths()
	if group_name == ALL_GROUP:
		return _all_paths()
	return _pack_groups.get(group_name, [])


# Every terrain from every pack, deduped and sorted.
func _all_paths() -> Array:
	var seen = {}
	var out = []
	for g in _pack_order:
		for path in _pack_groups.get(g, []):
			if not seen.has(path):
				seen[path] = true
				out.append(path)
	out.sort()
	return out


# Filter the ACTIVE group/tab by display name.
func _filtered_paths(group_name: String, q: String) -> Array:
	var ql = q.to_lower()
	var out = []
	for path in _paths_for_group(group_name):
		if _display_name(path).to_lower().find(ql) >= 0:
			out.append(path)
	return out


func _fill_grid(paths) -> void:
	if _picker_grid == null:
		return
	for c in _picker_grid.get_children():
		c.queue_free()
	_ensure_fav_icon()
	var cur = _extra_paths[_picker_slot - 8] if _picker_slot >= 8 else null
	for path in paths:
		var cell = VBoxContainer.new()
		cell.set_meta("tex_path", path)

		# Thumbnail with an overlaid star, stacked in a fixed-size frame.
		var frame = Control.new()
		frame.rect_min_size = Vector2(150, 150)

		var b = Button.new()
		b.expand_icon = true
		b.anchor_right = 1.0
		b.anchor_bottom = 1.0
		b.icon = _thumb(path)
		b.hint_tooltip = _display_name(path)
		b.set_meta("tex_path", path)
		cell.set_meta("thumb_btn", b)
		b.connect("pressed", self, "_choose_texture", [path])
		b.connect("gui_input", self, "_on_thumb_gui_input", [path])
		if path == cur:
			_apply_sel_style(b)
		frame.add_child(b)

		# Favorite badge (fav1.png, scaled like favorites.gd) — shown ONLY on
		# favorites. Add/remove a favorite via right-click on the thumbnail.
		if _is_fav(path):
			var bs = _fav_badge_size()
			var badge = TextureRect.new()
			badge.texture = _fav_badge_tex()
			badge.expand = true
			badge.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
			badge.rect_min_size = Vector2(bs, bs)
			badge.anchor_left = 1.0
			badge.anchor_right = 1.0
			badge.margin_left = -(bs + 4)
			badge.margin_right = -4
			badge.margin_top = 4
			badge.margin_bottom = 4 + bs
			frame.add_child(badge)

		cell.add_child(frame)

		var lbl = Label.new()
		lbl.text = _display_name(path)
		lbl.align = Label.ALIGN_CENTER
		lbl.clip_text = true
		lbl.rect_min_size = Vector2(150, 0)
		cell.add_child(lbl)

		_picker_grid.add_child(cell)


func _on_thumb_gui_input(event, path) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == BUTTON_RIGHT:
		_show_fav_context_menu(event.global_position, path)


# Right-click context menu, mirroring the Favorites mod: a single "Add to
# Favorites" / "Remove from Favorites" entry with the same fav2/fav0 icons.
func _show_fav_context_menu(global_pos: Vector2, path) -> void:
	if path == null:
		return
	if _fav_ctx_menu != null and is_instance_valid(_fav_ctx_menu):
		_fav_ctx_menu.queue_free()
	_fav_ctx_menu = PopupMenu.new()
	if _picker_win != null and is_instance_valid(_picker_win):
		_picker_win.add_child(_fav_ctx_menu)
	elif _g != null and _g.get("Editor") != null:
		_g.Editor.get_tree().get_root().add_child(_fav_ctx_menu)
	else:
		return
	var m = _favorites_mod()
	if _is_fav(path):
		_fav_ctx_menu.add_item("Remove from Favorites", 1)
		if m != null and m.get("_icon_unstar") != null:
			_fav_ctx_menu.set_item_icon(0, m._icon_unstar)
	else:
		_fav_ctx_menu.add_item("Add to Favorites", 0)
		if m != null and m.get("_icon_star") != null:
			_fav_ctx_menu.set_item_icon(0, m._icon_star)
	_fav_ctx_menu.connect("id_pressed", self, "_on_fav_ctx_pressed", [path])
	_fav_ctx_menu.popup(Rect2(global_pos, Vector2(1, 1)))


func _on_fav_ctx_pressed(_id: int, path) -> void:
	_toggle_fav(path)


func _choose_texture(path) -> void:
	if _picker_slot >= 8:
		_set_extra_slot(_picker_slot, path)
		_update_grid_selection_highlight()
	# Preview mode (toggle ON): apply but keep the popup open.
	# Default mode (toggle OFF): apply and close.
	if not _picker_accept_required:
		if _picker_win != null:
			_picker_win.hide()


func _picker_accept() -> void:
	# The current texture is already applied -> just close.
	if _picker_win != null:
		_picker_win.hide()


func _picker_cancel() -> void:
	# Restore the slot's original texture, then close.
	if _picker_slot >= 8:
		_set_extra_slot(_picker_slot, _picker_original_path)
	if _picker_win != null:
		_picker_win.hide()


func _on_picker_toggle(pressed: bool) -> void:
	_picker_accept_required = pressed
	_set_picker_buttons_enabled(pressed)


func _set_picker_buttons_enabled(enabled: bool) -> void:
	if _picker_accept_btn != null and is_instance_valid(_picker_accept_btn):
		_picker_accept_btn.disabled = not enabled
	if _picker_cancel_btn != null and is_instance_valid(_picker_cancel_btn):
		_picker_cancel_btn.disabled = not enabled


func _apply_sel_style(btn: Button) -> void:
	var sb = _make_sel_style()
	for st in ["normal", "hover", "pressed", "focus"]:
		btn.add_stylebox_override(st, sb)


func _clear_sel_style(btn: Button) -> void:
	for st in ["normal", "hover", "pressed", "focus"]:
		btn.add_stylebox_override(st, null)


func is_picker_open() -> bool:
	return _picker_win != null and is_instance_valid(_picker_win) and _picker_win.visible


# Rebascule sur TerrainBrush si DD a basculé l'outil suite à un Échap pendant que
# le picker était ouvert. Appelé en différé (call_deferred) pour s'exécuter après
# que DD ait traité l'évènement. No-op si l'outil est déjà TerrainBrush.
func _restore_terrain_tool() -> void:
	if _g == null or _g.get("Editor") == null:
		return
	if str(_g.Editor.get("ActiveToolName")) == "TerrainBrush":
		return
	var ts = _g.Editor.get("Toolset")
	if ts != null and ts.has_method("Quickswitch"):
		ts.Quickswitch("TerrainBrush")


# SHIFT+wheel: move the yellow selection to the next/previous thumbnail in the
# grid's current order and apply it (preview), wrapping around.
func _cycle_picker_selection(up: bool) -> void:
	if _picker_grid == null or _picker_slot < 8:
		return
	var cells = _picker_grid.get_children()
	var n = cells.size()
	if n == 0:
		return
	var paths = []
	for cell in cells:
		paths.append(cell.get_meta("tex_path") if cell.has_meta("tex_path") else null)
	var idx = paths.find(_extra_paths[_picker_slot - 8])
	var nxt = 0 if idx < 0 else ((idx + (-1 if up else 1)) % n + n) % n
	var path = paths[nxt]
	if path == null:
		return
	_set_extra_slot(_picker_slot, path)
	_update_grid_selection_highlight()
	if _picker_scroll != null and is_instance_valid(_picker_scroll) and _picker_scroll.has_method("ensure_control_visible"):
		_picker_scroll.ensure_control_visible(cells[nxt])


func _update_grid_selection_highlight() -> void:
	if _picker_grid == null:
		return
	var cur = _extra_paths[_picker_slot - 8] if _picker_slot >= 8 else null
	for cell in _picker_grid.get_children():
		if not cell.has_meta("thumb_btn"):
			continue
		var btn = cell.get_meta("thumb_btn")
		if btn == null or not is_instance_valid(btn):
			continue
		var pth = cell.get_meta("tex_path") if cell.has_meta("tex_path") else null
		if pth == cur:
			_apply_sel_style(btn)
		else:
			_clear_sel_style(btn)


func _add_btn_border(btn: Button) -> void:
	# White 1px border on active states (asset_cycle button look).
	for st in ["normal", "hover", "pressed", "focus"]:
		var existing = btn.get_stylebox(st, "Button")
		var sb = StyleBoxFlat.new()
		if existing != null and existing is StyleBoxFlat:
			sb = existing.duplicate()
		sb.border_width_top = 1
		sb.border_width_bottom = 1
		sb.border_width_left = 1
		sb.border_width_right = 1
		sb.border_color = Color(1, 1, 1, 1)
		btn.add_stylebox_override(st, sb)


func _make_circle_icon(_size := 18):
	# Same icon asset_cycle uses: white-circle-icon.png from the mod's /icons folder.
	var root = ""
	if _g != null and _g.get("Root") != null and _g.Root is String:
		root = _g.Root
	if root == "":
		return null
	var img = Image.new()
	if img.load(root + "icons/white-circle-icon.png") != OK:
		return null
	var tex = ImageTexture.new()
	tex.create_from_image(img, Texture.FLAG_FILTER)
	return tex


# ── Persistence ───────────────────────────────────────────────────────────────
# No API writes into the .dungeondraft_map, so state is stored in a user://
# sidecar keyed to the map's file path (same convention as group_assets).

func _persist_tick() -> void:
	_hook_save_controls()

	# Map open / new map: World is recreated. Reset per-map state and schedule
	# a restore for the new map.
	var world = _g.get("World")
	if world != null and is_instance_valid(world):
		var wid = world.get_instance_id()
		if wid != _last_world_id:
			_last_world_id = wid
			_on_world_changed()

	# Re-stamp différé des libellés natifs (passe après la reconstruction de
	# liste déclenchée par ExpandSlots au restore).
	# Re-stamp différé des libellés natifs : DD repopule sa liste après le reload
	# (timing variable) et y laisse les slots de pack manquant sans bon nom. On
	# réimpose le nom voulu jusqu'à stabilisation. Les frames « pas prêt » (liste
	# pas encore à 8 lignes) ne comptent PAS comme stables, pour ne pas s'arrêter
	# avant que DD ait fini d'étendre la liste.
	if _nlbl_frames > 0:
		_nlbl_frames -= 1
		var st = _refresh_native_labels(_nlbl_terrain)
		if st == 0:
			_nlbl_stable += 1
			if _nlbl_stable >= 30:
				_nlbl_frames = 0
		else:
			_nlbl_stable = 0
		if _nlbl_frames == 0:
			_nlbl_terrain = null

	# Deferred sidecar write (lets a Save As settle CurrentMapFile first).
	if _save_pending > 0:
		_save_pending -= 1
		if _save_pending == 0:
			_write_sidecar()

	# Auto-flush differe : peu apres la fin d'une edition (hors peinture active),
	# on reecrit le sidecar -> ce qui met aussi l'embed ModMapData a jour, pour
	# que la prochaine save de DD embarque l'etat courant (DD serialise la map
	# avant que nos hooks de save tournent, d'ou ce pre-flush).
	if _persist_dirty and not _painting and not _restore_pending:
		if _persist_idle > 0:
			_persist_idle -= 1
		if _persist_idle == 0:
			_persist_dirty = false
			if _map_path() != "":
				_write_sidecar()

	# Restore attempts (waits for map path + terrain to be ready).
	if _restore_pending:
		if _restore_frames > 0:
			_restore_frames -= 1
			_restoring = true
			var done = _try_restore()
			_restoring = false
			if done:
				_restore_pending = false
		else:
			_restore_pending = false   # timed out (e.g. brand-new unsaved map)

	# Save As: when CurrentMapFile changes to a new path outside a load, let the
	# active data follow the new file.
	if not _restore_pending:
		var pth = _map_path()
		if pth != _last_seen_map_path:
			_last_seen_map_path = pth
			_splat_sig = {}   # nouvelle cle de fichier -> forcer un reencodage
			if pth != "" and _splat3_img != null:
				_save_pending = 8


func _on_world_changed() -> void:
	_active = false
	_active24 = false
	_native_expanded_before = false
	_painting = false
	_nlbl_terrain = null
	_nlbl_frames = 0
	_nlbl_stable = 0
	_buffers_for = null
	_lv = {}
	_cur_level_terrain = null
	_splat3_img = null
	_splat3_tex = null
	_splat4_img = null
	_splat4_tex = null
	_splat5_img = null
	_splat5_tex = null
	_splat6_img = null
	_splat6_tex = null
	_zero_splat_tex = null
	_extra_array = null
	_extra_paths = [null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null]
	_extra_sizes = _default_sizes()
	_last_tid = -2
	_splat_sig = {}
	# Invalidate the texture catalog so the new map's loaded packs are picked up.
	_pack_groups = {}
	_pack_order = []
	_thumb_by_path = {}
	_thumb_cache = {}
	_scanned = false
	# Tool panels persist across map loads, so our injected UI usually survives.
	# If it was freed (panel recreated), force a re-inject; otherwise reset its
	# state to reflect the cleared mode.
	if _section == null or not is_instance_valid(_section):
		_ui_injected = false
		_section = null
		_toggle_btn = null
		_extra_list = null
		_vanilla_list = null
		_vanilla_lists = []
		_picker_btns = []
		_section24 = null
		_toggle_btn24 = null
		_extra_list24 = null
		_picker_btns24 = []
		_native_fill_btn = null
		_fill_btn = null
	else:
		if _toggle_btn != null and is_instance_valid(_toggle_btn):
			_toggle_btn.set_pressed_no_signal(false)
		_section.visible = false
		_refresh_all_row_icons()
	# Annule tout flush differe herite de la map precedente : il s'executerait
	# sur la NOUVELLE map avant le restore, avec _lv vide, et effacerait ses
	# donnees sauvegardees.
	_persist_dirty = false
	_persist_idle = 0
	# Schedule restore for the new map.
	_restore_pending = true
	_restore_frames = 120
	_restore_data_loaded = false
	_restore_entry = null
	_last_seen_map_path = ""


func _try_restore() -> bool:
	var path = _map_path()
	if path == "":
		return false   # map not identified yet — retry
	if not _restore_data_loaded:
		_restore_entry = _resolve_restore_entry(path)
		_restore_data_loaded = true
	if _restore_entry == null:
		return true    # nothing saved for this map — done
	var cur = _get_terrain()
	if cur == null:
		return false   # terrain not ready — retry
	var levels = _all_levels()
	if levels.empty():
		return false   # levels not ready — retry

	# Old format stored a single shared palette at the top of the entry; in the
	# new format each level carries its own "paths" in its level meta.
	var legacy_paths = _restore_entry.get("paths", [])

	# Per-level metadata. Back-compat: the old format stored one level's state at
	# the top of the entry (no "levels" dict) with splats keyed without "_L".
	var lv_meta = _restore_entry.get("levels", {})
	var legacy := false
	if not (lv_meta is Dictionary) or lv_meta.empty():
		lv_meta = {}
		if _restore_entry.get("active", false) or _has_legacy_splats(path):
			lv_meta["0"] = {"active": _restore_entry.get("active", false) == true, "active24": _restore_entry.get("active24", false) == true, "expanded": _restore_entry.get("expanded", false) == true}
			legacy = true

	# Load every saved level's painted data into its own store entry.
	var key = path.sha256_text()
	for i in range(levels.size()):
		var skey = str(i)
		if not lv_meta.has(skey):
			continue
		var terrain = levels[i].get("Terrain")
		if terrain == null:
			continue
		if not _ensure_buffers(terrain):   # blank buffers bound to this material
			continue
		var pfx = (SPLATS_DIR + key) if legacy else (SPLATS_DIR + key + "_L" + skey)
		_load_splat_png(pfx + ".s3.png", _splat3_img); _refresh_splat3()
		_load_splat_png(pfx + ".s4.png", _splat4_img); _refresh_splat4()
		_load_splat_png(pfx + ".s5.png", _splat5_img); _refresh_splat5()
		_load_splat_png(pfx + ".s6.png", _splat6_img); _refresh_splat6()
		var m = lv_meta[skey]
		var lid = terrain.get_instance_id()
		var e = _lv.get(lid, {})
		e["active"] = m.get("active", false) == true
		e["active24"] = m.get("active24", false) == true
		e["expanded"] = m.get("expanded", false) == true
		var mp = m.get("paths")
		if not (mp is Array) and legacy and skey == "0":
			mp = legacy_paths
		var lvpaths = [null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null]
		if mp is Array:
			for k in range(16):
				var pp = mp[k] if k < mp.size() else ""
				lvpaths[k] = pp if (pp is String and pp != "") else null
		e["paths"] = lvpaths
		# Slots natifs mémorisés + drapeau de réparation one-shot.
		var mnp = m.get("npaths")
		var nplist = ["", "", "", "", "", "", "", ""]
		var need_nat := false
		if mnp is Array:
			for k in range(8):
				var npv = mnp[k] if k < mnp.size() else ""
				if npv is String and npv != "":
					nplist[k] = npv
					need_nat = true
		e["npaths"] = nplist
		e["need_native"] = need_nat
		_lv[lid] = e
		_stash_current_buffers()

	# Settle on the current level and apply our shader to it now (full setup,
	# incl. native expand). Other active levels set up when first visited.
	if not _ensure_buffers(cur):
		return false
	_cur_level_terrain = cur
	_load_level_state(cur)
	_load_level_palette(cur)   # alias + build this level's slot-texture array
	if _active:
		var saved_expanded = _native_expanded_before
		if not activate(null, true):
			return false   # material not ready — retry
		_native_expanded_before = saved_expanded
		_push_extra_splats(_get_material(cur))
	# APRÈS activate : il force ExpandedSlots → la liste vanilla passe à 8 lignes.
	# Avant, les slots 5-8 n'existaient pas encore et ne recevaient ni texture
	# ni label de leur slot.
	_apply_native_palette(cur)

	if _toggle_btn != null and is_instance_valid(_toggle_btn):
		_toggle_btn.set_pressed_no_signal(_active)
	if _toggle_btn24 != null and is_instance_valid(_toggle_btn24):
		_toggle_btn24.set_pressed_no_signal(_active24)
	if _section != null and is_instance_valid(_section):
		_section.visible = _active
	if _section24 != null and is_instance_valid(_section24):
		_section24.visible = _active24
	_refresh_all_row_icons()
	_last_seen_map_path = path
	return true


func _restore_splats(path: String) -> void:
	var key = path.sha256_text()
	_load_splat_png(SPLATS_DIR + key + ".s3.png", _splat3_img)
	_refresh_splat3()
	_load_splat_png(SPLATS_DIR + key + ".s4.png", _splat4_img)
	_refresh_splat4()
	_load_splat_png(SPLATS_DIR + key + ".s5.png", _splat5_img)
	_refresh_splat5()
	_load_splat_png(SPLATS_DIR + key + ".s6.png", _splat6_img)
	_refresh_splat6()


func _load_splat_png(file: String, dst) -> void:
	if dst == null:
		return
	var f = File.new()
	if not f.file_exists(file):
		return
	var img = Image.new()
	if img.load(file) != OK:
		return
	img.convert(Image.FORMAT_RGBA8)
	if img.get_width() != dst.get_width() or img.get_height() != dst.get_height():
		img.resize(dst.get_width(), dst.get_height())
	dst.copy_from(img)


# ── Level clone ───────────────────────────────────────────────────────────────
# DD's clone copies the native splat but not our extended slots (they live in
# our store, not in the Terrain). Mirror free_transform: snapshot the levels
# when the New Level window opens, and after OK copy the source level's entry
# to the freshly created clone.
func _hook_new_level_window() -> void:
	if _newlevel_hooked:
		return
	var ed = _g.get("Editor")
	if ed == null or ed.get("Windows") == null:
		return
	var win = ed.Windows.get("NewLevel")
	if win == null:
		return
	if not win.is_connected("about_to_show", self, "_on_new_level_shown"):
		win.connect("about_to_show", self, "_on_new_level_shown")
	var valign = win.get_node_or_null("Margins/VAlign")
	if valign == null:
		return
	var ok_btn = valign.get_node_or_null("Buttons/OkayButton")
	var clone_opt = valign.get_node_or_null("CloneLevel/CloneLevelOptionButton")
	if ok_btn != null and not ok_btn.is_connected("pressed", self, "_on_new_level_ok"):
		ok_btn.connect("pressed", self, "_on_new_level_ok")
	if clone_opt != null:
		_clone_btn = clone_opt
	_newlevel_hooked = true


func _on_new_level_shown() -> void:
	if _g.World == null or not is_instance_valid(_g.World):
		return
	_clone_levels_snapshot = _g.World.levels.duplicate(false)


func _on_new_level_ok() -> void:
	if _clone_btn == null or not is_instance_valid(_clone_btn) or _clone_btn.selected <= 0:
		return
	var source_idx = _clone_btn.selected
	var timer = Timer.new()
	timer.one_shot = true
	timer.wait_time = 1.0
	timer.connect("timeout", self, "_copy_level_data_to_clone", [source_idx])
	timer.connect("timeout", timer, "queue_free")
	_g.Editor.add_child(timer)
	timer.start()


func _copy_level_data_to_clone(source_idx: int) -> void:
	if _g.World == null or not is_instance_valid(_g.World):
		return
	var source_level = _g.World.TryGetLevel(source_idx)
	if source_level == null:
		return
	var src_terrain = source_level.get("Terrain")
	if src_terrain == null:
		return
	var src_e = _lv.get(src_terrain.get_instance_id())
	if src_e == null:
		return   # source level has no extended data to copy
	# The clone is the level present now but absent from the pre-clone snapshot.
	var new_level = null
	for lvl in _g.World.levels:
		if not (lvl in _clone_levels_snapshot):
			new_level = lvl
			break
	if new_level == null:
		return
	var nt = new_level.get("Terrain")
	if nt == null:
		return
	# Fresh entry holding COPIES of the source data (independent of the source).
	var ne = {}
	ne["active"] = src_e.get("active", false) == true
	ne["active24"] = src_e.get("active24", false) == true
	ne["expanded"] = src_e.get("expanded", false) == true
	ne["smooth"] = src_e.get("smooth", false) == true
	var ww = 0
	var hh = 0
	for ik in ["s3", "s4", "s5", "s6"]:
		var img = src_e.get(ik)
		if img == null:
			continue
		var ci = Image.new()
		ci.copy_from(img)
		ne[ik] = ci
		ne["t" + ik.substr(1)] = _new_splat_tex(ci)
		ww = ci.get_width(); hh = ci.get_height()
	if ww > 0 and hh > 0:
		ne["zero"] = _new_splat_tex(_new_splat(ww, hh))
	# Copy the per-level slot-texture palette (independent array + paths).
	var src_paths = src_e.get("paths")
	var np = [null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null]
	var narr = _new_extra_array()
	var nsizes = _default_sizes()
	if src_paths is Array:
		for i in range(16):
			var pp = src_paths[i] if i < src_paths.size() else null
			np[i] = pp
			if pp != null:
				var pimg = _load_image(pp)
				if pimg != null:
					narr.set_layer_data(pimg, i)
					nsizes[i] = _last_native_size
	ne["paths"] = np
	ne["array"] = narr
	ne["sizes"] = nsizes
	_lv[nt.get_instance_id()] = ne
	# If we are now on the clone (DD switches to it), force a re-sync so its
	# shader/expand get applied; otherwise it sets up when first visited.
	if _get_terrain() == nt:
		_buffers_for = null
		_cur_level_terrain = null


func _mark_persist_dirty() -> void:
	# Arme un flush differe (~2 s) pour garder le sidecar + l'embed ModMapData a
	# jour sans reecrire a chaque frame ni pendant la peinture. Re-arme a chaque
	# changement, donc ne se declenche qu'apres une pause d'edition.
	# Ignore pendant un restore : les set_extra_slot/activate du restore
	# appelleraient ceci sinon, declenchant un flush inutile juste apres l'ouverture.
	if _restoring:
		return
	_persist_dirty = true
	_persist_idle = 120


func _write_sidecar() -> void:
	# Garde-fou : ne jamais ecrire NI effacer tant qu'un restore est en attente.
	# Sinon _lv est vide/partiel et on detruirait les donnees du disque que le
	# restore n'a pas encore lues.
	if _restore_pending:
		return
	var path = _map_path()
	if path == "":
		return
	# Flush the current level's live state into the store before serializing.
	if _cur_level_terrain != null and is_instance_valid(_cur_level_terrain):
		_save_level_state(_cur_level_terrain)
		_stash_current_buffers()
	var all = _load_meta()
	var levels = _all_levels()
	var key = path.sha256_text()

	var lv_meta := {}
	var any := false
	var painted_idx := {}   # indices de niveaux peints, conserves sur disque
	for i in range(levels.size()):
		var terrain = levels[i].get("Terrain")
		if terrain == null:
			continue
		var e = _lv.get(terrain.get_instance_id())
		if e == null:
			continue
		var has_paint = e.get("s3") != null
		var act = e.get("active", false) == true
		var lp = e.get("paths")
		var lpaths = []
		var has_palette = false
		for k in range(16):
			var pv = lp[k] if (lp is Array and k < lp.size() and lp[k] != null) else ""
			if pv != "":
				has_palette = true
			lpaths.append(pv)
		# Slots natifs 1-8 (hybride) : on prend le resource_path résolu par DD
		# quand il existe, sinon le chemin qu'on a mémorisé en le posant (le
		# fallback Image.load crée un ImageTexture sans resource_path → "" côté
		# DD, donc seul le suivi mod capture le cas pack-manquant). On ne
		# persiste les natifs que si le mod en a réellement assigné au moins un.
		var trk = e.get("npaths")
		var nplist = []
		var has_native = false
		for k in range(8):
			var tracked = ""
			if trk is Array and k < trk.size() and trk[k] is String:
				tracked = trk[k]
			if tracked != "":
				has_native = true
			var rp = ""
			if terrain != null:
				var tx = terrain.GetTexture(k)
				if tx != null and tx.resource_path != "":
					rp = tx.resource_path
			nplist.append(rp if rp != "" else tracked)
		if not (act or has_paint or has_palette or has_native):
			continue
		any = true
		lv_meta[str(i)] = {"active": act, "active24": e.get("active24", false) == true, "expanded": e.get("expanded", false) == true, "paths": lpaths, "npaths": nplist}
		if has_paint:
			_ensure_splat_dir()
			painted_idx[i] = true
			var pfx = SPLATS_DIR + key + "_L" + str(i)
			# Reencode CE niveau uniquement si sa peinture a change (signature de
			# contenu) ou si ses PNG manquent sur disque. Les niveaux non modifies
			# gardent leurs PNG -> companion/embed restent corrects sans tout
			# reencoder a chaque flush.
			var sig = _level_splat_sig(e)
			if _splat_sig.get(i) != sig or not _level_splats_on_disk(pfx, e):
				_save_level_splats(pfx, e)
				_splat_sig[i] = sig

	if not any:
		if all.has(path):
			all.erase(path)
			_save_meta(all)
		_delete_splats(path)
		_delete_companion(path)
		_clear_map_embed()
		return

	# Supprime les PNG des niveaux qui ne sont plus peints (paint efface / niveau
	# supprime), sans toucher a ceux qu'on vient de conserver.
	_delete_level_splats_except(path, painted_idx)

	var now = OS.get_unix_time()
	all[path] = {"levels": lv_meta, "saved_at": now}
	_save_meta(all)
	# Mirror into the portable companion in user:// (for sharing).
	_write_companion(path, lv_meta, key, now)


# ── Portable companion (stored in user://, keyed by the map's filename) ───────
# Lets a shared map carry its extended-terrain data WITHOUT cluttering the map's
# folder. On save we write a single self-contained companion (per-level meta +
# base64-embedded splat PNGs) into a clean user:// subfolder, named
# "<MapFile>.<hash8>.tslots" where hash8 = first 8 hex of sha256(full path).
# The hash makes the filename unique so two maps that share the same filename
# (in different folders) never clobber each other locally.
#
# On open we locate the companion by the map's *filename* (portable across
# machines): exact-hash match first (our own machine), else any companion whose
# map name matches; if several match (≥2 shared maps with the same name), the
# newest wins. The chosen file is re-imported into user:// re-keyed to the LOCAL
# full path, so the sha256-of-path scheme keeps working everywhere.
#
# Sharing: send the .dungeondraft_map + its "<MapFile>.<hash8>.tslots" (found in
# COMPANION_DIR). The recipient drops the .tslots into the same COMPANION_DIR;
# opening the map (same filename) auto-imports it.

func _ensure_companion_dir() -> void:
	var d = Directory.new()
	if not d.dir_exists(COMPANION_DIR):
		d.make_dir_recursive(COMPANION_DIR)


func _companion_path(map_path: String) -> String:
	# Exact, unique-per-path companion name for THIS machine's map path.
	if map_path == "":
		return ""
	var base = map_path.get_file()   # e.g. "MyMap.dungeondraft_map"
	if base == "":
		return ""
	return COMPANION_DIR + base + "." + map_path.sha256_text().substr(0, 8) + COMPANION_SUFFIX


func _find_companion(map_path: String) -> String:
	# Resolve which companion file belongs to this map (handles shared maps and
	# duplicate filenames). Returns a full path or "".
	if map_path == "":
		return ""
	var base = map_path.get_file()
	if base == "":
		return ""
	# 1. Exact match: same machine, same full path.
	var exact = _companion_path(map_path)
	var f = File.new()
	if f.file_exists(exact):
		return exact
	# 2. Shared map: any companion named "<base>.*.tslots".
	_ensure_companion_dir()
	var d = Directory.new()
	if d.open(COMPANION_DIR) != OK:
		return ""
	var prefix = base + "."
	var cands := []
	d.list_dir_begin(true, true)
	var fn = d.get_next()
	while fn != "":
		if fn.begins_with(prefix) and fn.ends_with(COMPANION_SUFFIX):
			cands.append(COMPANION_DIR + fn)
		fn = d.get_next()
	d.list_dir_end()
	if cands.empty():
		return ""
	if cands.size() == 1:
		return cands[0]
	# Ambiguous (several same-named maps): newest wins.
	var best = ""
	var best_at = -1
	for c in cands:
		var at = _companion_saved_at(c)
		if at > best_at:
			best_at = at
			best = c
	return best


func _read_file_bytes(fp: String):
	var f = File.new()
	if f.open(fp, File.READ) != OK:
		return null
	var b = f.get_buffer(f.get_len())
	f.close()
	return b


func _write_companion(map_path: String, lv_meta: Dictionary, key: String, saved_at: int) -> void:
	var cp = _companion_path(map_path)
	if cp == "":
		return
	# Embed each level's splat PNGs (the ones we just wrote to user://) as base64.
	var splats := {}
	var d = Directory.new()
	for skey in lv_meta.keys():
		var pfx = SPLATS_DIR + key + "_L" + skey
		var entry := {}
		for suf in ["s3", "s4", "s5", "s6"]:
			var fp = pfx + "." + suf + ".png"
			if d.file_exists(fp):
				var b = _read_file_bytes(fp)
				if b != null:
					entry[suf] = Marshalls.raw_to_base64(b)
		if not entry.empty():
			splats[skey] = entry
	var data := {"v": 2, "map_name": map_path.get_file(), "path_sha": map_path.sha256_text(), "saved_at": saved_at, "levels": lv_meta, "splats": splats}
	_ensure_companion_dir()
	var f = File.new()
	if f.open(cp, File.WRITE) == OK:
		f.store_string(JSON.print(data))
		f.close()
	# Meme payload embarque DANS la map via ModMapData (DD le serialise et le
	# restitue a l'ouverture) -> map auto-suffisante, un seul fichier a partager.
	_write_map_embed(data)


func _write_map_embed(data: Dictionary) -> void:
	if _g == null or _g.get("ModMapData") == null or not (_g.ModMapData is Dictionary):
		return
	_g.ModMapData[EMBED_KEY] = data


func _clear_map_embed() -> void:
	if _g == null or _g.get("ModMapData") == null or not (_g.ModMapData is Dictionary):
		return
	if _g.ModMapData.has(EMBED_KEY):
		_g.ModMapData.erase(EMBED_KEY)


func _delete_companion(map_path: String) -> void:
	var cp = _companion_path(map_path)
	if cp == "":
		return
	var d = Directory.new()
	if d.file_exists(cp):
		d.remove(cp)


func _companion_saved_at(cp: String) -> int:
	var f = File.new()
	if f.open(cp, File.READ) != OK:
		return 0
	var t = f.get_as_text()
	f.close()
	var parsed = JSON.parse(t)
	if parsed.error != OK or not (parsed.result is Dictionary):
		return 0
	return int(parsed.result.get("saved_at", 0))


func _import_companion(map_path: String, cp: String):
	# Extract the companion's embedded PNGs into the LOCAL user:// store (keyed by
	# sha256 of THIS path) and register the meta, so the normal restore path +
	# future saves work unchanged. Returns the meta entry, or null.
	if cp == "":
		return null
	var f = File.new()
	if not f.file_exists(cp):
		return null
	if f.open(cp, File.READ) != OK:
		return null
	var t = f.get_as_text()
	f.close()
	var parsed = JSON.parse(t)
	if parsed.error != OK or not (parsed.result is Dictionary):
		return null
	var imported = _import_payload(map_path, parsed.result)
	if imported != null:
		print("[Terrain16] Imported companion sidecar for shared map: ", cp)
	return imported


# Decode un payload (companion .tslots OU embed ModMapData) vers le store local
# user:// : ecrit les PNG de splat sur disque (cle = sha256 du chemin local) et
# enregistre la meta, pour que le chemin de restore normal fonctionne tel quel.
func _import_payload(map_path: String, data):
	if not (data is Dictionary):
		return null
	var lv_meta = data.get("levels", {})
	if not (lv_meta is Dictionary):
		return null
	var key = map_path.sha256_text()
	_ensure_splat_dir()
	var splats = data.get("splats", {})
	if splats is Dictionary:
		for skey in splats.keys():
			var entry = splats[skey]
			if not (entry is Dictionary):
				continue
			for suf in ["s3", "s4", "s5", "s6"]:
				if entry.has(suf):
					var raw = Marshalls.base64_to_raw(entry[suf])
					var of = File.new()
					if of.open(SPLATS_DIR + key + "_L" + skey + "." + suf + ".png", File.WRITE) == OK:
						of.store_buffer(raw)
						of.close()
	var entry_meta := {"levels": lv_meta, "saved_at": int(data.get("saved_at", 0))}
	var all = _load_meta()
	all[map_path] = entry_meta
	_save_meta(all)
	return entry_meta


# Importe l'embed stocke DANS la map (ModMapData) -> cas d'une map partagee en
# un seul fichier (pas de .tslots local a cote).
func _import_embed(map_path: String):
	if _g == null or _g.get("ModMapData") == null or not (_g.ModMapData is Dictionary):
		return null
	var data = _g.ModMapData.get(EMBED_KEY)
	if not (data is Dictionary):
		return null
	var imported = _import_payload(map_path, data)
	if imported != null:
		print("[Terrain16] Imported embedded terrain data from map.")
	return imported


func _embed_saved_at() -> int:
	if _g == null or _g.get("ModMapData") == null or not (_g.ModMapData is Dictionary):
		return 0
	var data = _g.ModMapData.get(EMBED_KEY)
	if data is Dictionary:
		return int(data.get("saved_at", 0))
	return 0


func _resolve_restore_entry(map_path: String):
	# Trois sources possibles, on prend la plus recente (saved_at) :
	#   - l'entree locale user://
	#   - le companion portable .tslots
	#   - l'embed stocke DANS la map (ModMapData)
	# L'embed permet a une map partagee en UN SEUL fichier de se restaurer sans
	# .tslots a cote.
	var local = _read_entry(map_path)
	var local_at = 0
	if local is Dictionary:
		local_at = int(local.get("saved_at", 0))
	var cp = _find_companion(map_path)
	var comp_at = _companion_saved_at(cp) if cp != "" else 0
	var emb_at = _embed_saved_at()

	# Pas d'entree locale : prends ce qui existe (companion d'abord, sinon embed).
	if local == null:
		if cp != "":
			var ic0 = _import_companion(map_path, cp)
			if ic0 != null:
				return ic0
		var ie0 = _import_embed(map_path)
		if ie0 != null:
			return ie0
		return null

	# Entree locale presente : n'importe une source distante que si strictement
	# plus recente (map mise a jour recue d'ailleurs).
	if cp != "" and comp_at > local_at and comp_at >= emb_at:
		var ic = _import_companion(map_path, cp)
		if ic != null:
			return ic
	if emb_at > local_at and emb_at > comp_at:
		var ie = _import_embed(map_path)
		if ie != null:
			return ie
	return local


# Signature de contenu des 4 splats d'un niveau (presence + dimensions + hash des
# pixels). Sert a sauter le reencodage PNG quand rien n'a change. Valable pour la
# session uniquement (pas besoin de stabilite inter-lancements).
func _level_splat_sig(e) -> int:
	var h := 0
	for ik in ["s3", "s4", "s5", "s6"]:
		var img = e.get(ik)
		if img == null:
			h = hash([h, ik, 0])
		else:
			h = hash([h, ik, img.get_width(), img.get_height(), hash(img.get_data())])
	return h


# Vrai si tous les splats PRESENTS de ce niveau existent sur disque (sinon il faut
# reencoder, p.ex. apres un Save As qui a change la cle de fichier).
func _level_splats_on_disk(pfx: String, e) -> bool:
	var f = File.new()
	for ik in ["s3", "s4", "s5", "s6"]:
		if e.get(ik) != null and not f.file_exists(pfx + "." + ik + ".png"):
			return false
	return true


# Ecrit les splats presents, supprime les PNG des splats absents (p.ex. s5/s6
# retires apres avoir desactive les slots 17-24) pour ne pas laisser de stale.
func _save_level_splats(pfx: String, e) -> void:
	var d = Directory.new()
	for ik in ["s3", "s4", "s5", "s6"]:
		var img = e.get(ik)
		var fp = pfx + "." + ik + ".png"
		if img != null:
			img.save_png(fp)
		elif d.file_exists(fp):
			d.remove(fp)


# Supprime les PNG de tous les niveaux SAUF ceux gardes (indices dans keep), et
# oublie leur signature pour qu'un futur repaint les reencode.
func _delete_level_splats_except(path: String, keep: Dictionary) -> void:
	var key = path.sha256_text()
	var d = Directory.new()
	for i in range(64):
		if keep.has(i):
			continue
		if _splat_sig.has(i):
			_splat_sig.erase(i)
		for suf in [".s3.png", ".s4.png", ".s5.png", ".s6.png"]:
			var fp = SPLATS_DIR + key + "_L" + str(i) + suf
			if d.file_exists(fp):
				d.remove(fp)


func _delete_splats(path: String) -> void:
	var key = path.sha256_text()
	var d = Directory.new()
	for suf in [".s3.png", ".s4.png", ".s5.png", ".s6.png"]:
		var fp = SPLATS_DIR + key + suf
		if d.file_exists(fp):
			d.remove(fp)
	_delete_level_splats(path)


func _delete_level_splats(path: String) -> void:
	var key = path.sha256_text()
	var d = Directory.new()
	for i in range(64):
		for suf in [".s3.png", ".s4.png", ".s5.png", ".s6.png"]:
			var fp = SPLATS_DIR + key + "_L" + str(i) + suf
			if d.file_exists(fp):
				d.remove(fp)


func _has_legacy_splats(path: String) -> bool:
	var f = File.new()
	return f.file_exists(SPLATS_DIR + path.sha256_text() + ".s3.png")


func _all_levels() -> Array:
	if _g == null:
		return []
	var w = _g.get("World")
	if w == null or not is_instance_valid(w):
		return []
	var a = w.call("get_AllLevels")
	return a if (a is Array) else []


func _map_path() -> String:
	var ed = _g.get("Editor")
	if ed == null:
		return ""
	var p = ed.get("CurrentMapFile")
	if p is String and p != "":
		return p
	return ""


func _read_entry(path: String):
	var all = _load_meta()
	if all.has(path) and all[path] is Dictionary:
		return all[path]
	return null


func _load_meta() -> Dictionary:
	var f = File.new()
	if not f.file_exists(META_PATH):
		return {}
	if f.open(META_PATH, File.READ) != OK:
		return {}
	var t = f.get_as_text()
	f.close()
	var parsed = JSON.parse(t)
	if parsed.error != OK or not (parsed.result is Dictionary):
		return {}
	return parsed.result


func _save_meta(all: Dictionary) -> void:
	_ensure_persist_dir()
	var f = File.new()
	if f.open(META_PATH, File.WRITE) == OK:
		f.store_string(JSON.print(all))
		f.close()


func _ensure_persist_dir() -> void:
	var d = Directory.new()
	if not d.dir_exists(PERSIST_DIR):
		d.make_dir_recursive(PERSIST_DIR)


func _ensure_splat_dir() -> void:
	var d = Directory.new()
	if not d.dir_exists("user://UnofficialPatch/Terrain Slots Extended"):
		d.make_dir_recursive("user://UnofficialPatch/Terrain Slots Extended")


# Hook the save controls (toolbar button + menu "Save"). Idempotent.
func _hook_save_controls() -> void:
	if _save_btn_hooked and _save_menu_hooked:
		return
	var ed = _g.get("Editor")
	if ed == null:
		return
	if not _save_btn_hooked:
		var sb = ed.get("saveButton")
		if sb != null and is_instance_valid(sb) and sb is BaseButton:
			if not sb.is_connected("pressed", self, "_on_save_detected"):
				sb.connect("pressed", self, "_on_save_detected")
			_save_btn_hooked = true
	if not _save_menu_hooked:
		var mb = ed.get("menuBar")
		if mb != null and is_instance_valid(mb):
			var popups = []
			_collect_popup_menus(mb, popups)
			for pm in popups:
				if not pm.is_connected("id_pressed", self, "_on_save_menu_id"):
					pm.connect("id_pressed", self, "_on_save_menu_id")
			if popups.size() > 0:
				_save_menu_hooked = true


func _collect_popup_menus(node, out) -> void:
	if node is PopupMenu:
		out.append(node)
	for c in node.get_children():
		_collect_popup_menus(c, out)


func _on_save_detected() -> void:
	_save_pending = 12


func _on_save_menu_id(id: int) -> void:
	# id 1 = File > Save in DD's menu (same convention drop_embed uses).
	if id == 1:
		_save_pending = 12
