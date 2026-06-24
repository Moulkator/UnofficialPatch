# favorites.gd  v54 — Dungeondraft Favorites Mod

var _g
var ui_util  # injected by Main.gd — shared helpers (ASO TerrainWindow detection, etc.)

var _custom_dir = ""
# _favorites: {res_path_of_source: {pack_path: String, type: int, color: String}}
var _favorites = {}
var _fav_cache = {}  # {pack_path: PoolByteArray}
var _pack_id = "Favorite_Assets"
var _pack_path = ""
var _f_was_pressed = false
var _search_has_focus = false  # True while any search LineEdit has keyboard focus
var _last_search_text = {}  # key -> last search text applied to overlay
var _icon_star = null      # fav2.png - star icon for CheckButton / add
var _icon_unstar = null    # fav0.png - icon for remove from favorites
var _icon_fav_badge = null  # fav1.png - badge texture (with filtering)
var _icon_fav_badge_img = null  # fav1.png - raw Image for pre-scaling
var _icon_ft = null            # free_transform.png - icon for FT context menu item
var _badged_icons = {}  # src_path -> badged ImageTexture (cache)
var _badge_tex_cache = {}  # badge_size -> pre-scaled ImageTexture
# Optimization: invalidation tracking
var _fav_version = 0  # bumped on any _favorites change — invalidates caches
var _fav_tooltips_cache = {}  # fav_type -> {version: int, tooltips: Dict}
# Per-ItemList caches: keyed by instance id
var _meta_populated_counts = {}  # instance_id -> last populated item_count
var _terrain_meta_populated_counts = {}  # instance_id -> last terrain populated count
var _badge_sigs = {}  # instance_id (target+ctrl_key) -> last signature Array
var _popup_layer = null    # CanvasLayer for popups (ensures z-order above DD UI)
var _pending_rebuild = false
var _pending_rebuild_frame = 0
var _wait_dialog = null
# One-shot flag for the ASO terrain-popup skip diagnostic.
var _terrain_skip_logged = false

# UI tab
var _tab_injected = false

# Badge size (configurable via Preferences slider). Stored as int pixels.
var _badge_size_value: int = 16
var _badge_size_slider = null
var _badge_size_spinbox = null
var _badge_size_preview = null  # TextureRect showing badge at current size
var _badge_size_save_pending_frames: int = 0  # debounce save-to-disk
var _prefs_hooked: bool = false


func _settings_path() -> String:
	return "user://UnofficialPatch/Favorites/settings.json"


func _load_settings():
	var f = File.new()
	if f.open(_settings_path(), File.READ) != OK:
		return
	var text = f.get_as_text()
	f.close()
	var parsed = JSON.parse(text)
	if parsed.error == OK and parsed.result is Dictionary:
		var d = parsed.result
		if d.has("badge_size"):
			var v = int(d["badge_size"])
			if v < 4: v = 4
			if v > 48: v = 48
			_badge_size_value = v


func _save_settings():
	var dir = Directory.new()
	if not dir.dir_exists("user://UnofficialPatch/Favorites"):
		dir.make_dir_recursive("user://UnofficialPatch/Favorites")
	var f = File.new()
	if f.open(_settings_path(), File.WRITE) == OK:
		f.store_string(JSON.print({"badge_size": _badge_size_value}, "\t"))
		f.close()


func _try_hook_preferences() -> void:
	# Inject "Badge size" slider into Preferences > Interface tab, right
	# under UIScaler's UI Scale / Picker Scale sliders. Re-attempts every
	# frame from update() until the Preferences node exists.
	if _prefs_hooked: return
	if not _g.Editor or not is_instance_valid(_g.Editor): return
	var prefs = _g.Editor.get_node_or_null("Windows/Preferences")
	if prefs == null: return
	var interface_vbox = prefs.get_node_or_null("Margins/VAlign/Interface")
	if interface_vbox == null: return
	# Avoid double-injection
	if interface_vbox.get_node_or_null("FavBadgeSizeRow") != null:
		_prefs_hooked = true
		return
	var row = HBoxContainer.new()
	row.name = "FavBadgeSizeRow"
	var lbl = Label.new()
	lbl.text = "Favorite Badge Size"
	lbl.rect_min_size = Vector2(170, 0)
	row.add_child(lbl)
	_badge_size_slider = HSlider.new()
	_badge_size_slider.min_value = 8
	_badge_size_slider.max_value = 48
	_badge_size_slider.step = 1
	_badge_size_slider.value = _badge_size_value
	_badge_size_slider.rect_min_size = Vector2(150, 20)
	_badge_size_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_badge_size_slider.connect("value_changed", self, "_on_badge_size_slider")
	row.add_child(_badge_size_slider)
	_badge_size_spinbox = SpinBox.new()
	_badge_size_spinbox.min_value = 8
	_badge_size_spinbox.max_value = 48
	_badge_size_spinbox.step = 1
	_badge_size_spinbox.value = _badge_size_value
	_badge_size_spinbox.rect_min_size = Vector2(60, 0)
	_badge_size_spinbox.connect("value_changed", self, "_on_badge_size_spinbox")
	row.add_child(_badge_size_spinbox)
	# Live preview of the badge at the current size — sits between the
	# spinbox and the reset button so the user can see the badge change
	# size while dragging the slider, even when the Preferences popup is
	# covering the actual pickers.
	# We put the preview in a fixed-size container so the row layout
	# doesn't shift around as the badge grows/shrinks.
	var preview_box = CenterContainer.new()
	preview_box.rect_min_size = Vector2(56, 56)
	_badge_size_preview = TextureRect.new()
	_badge_size_preview.texture = _icon_fav_badge
	_badge_size_preview.expand = true
	_badge_size_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_badge_size_preview.rect_min_size = Vector2(_badge_size_value, _badge_size_value)
	preview_box.add_child(_badge_size_preview)
	row.add_child(preview_box)
	# Reset button
	var reset_btn = Button.new()
	reset_btn.text = "Reset"
	reset_btn.connect("pressed", self, "_on_badge_size_reset")
	row.add_child(reset_btn)
	interface_vbox.add_child(row)
	_prefs_hooked = true
	print("[Favorites] Badge size slider injected in Preferences (value=", _badge_size_value, ")")


func _on_badge_size_slider(value: float) -> void:
	if _badge_size_spinbox != null and _badge_size_spinbox.value != value:
		_badge_size_spinbox.value = value
	_apply_badge_size(int(value))


func _on_badge_size_spinbox(value: float) -> void:
	if _badge_size_slider != null and _badge_size_slider.value != value:
		_badge_size_slider.value = value
	_apply_badge_size(int(value))


func _on_badge_size_reset() -> void:
	if _badge_size_slider != null: _badge_size_slider.value = 16
	if _badge_size_spinbox != null: _badge_size_spinbox.value = 16
	_apply_badge_size(16)


func _apply_badge_size(size_px: int) -> void:
	if size_px < 8: size_px = 8
	if size_px > 48: size_px = 48
	if size_px == _badge_size_value: return
	_badge_size_value = size_px
	# Debounce save: don't write to disk on every slider tick; wait until
	# the user stops moving the slider (~30 frames of no change ≈ 500ms).
	_badge_size_save_pending_frames = 30
	# Update live preview in the prefs row
	if is_instance_valid(_badge_size_preview):
		_badge_size_preview.rect_min_size = Vector2(size_px, size_px)
	# Push to all live overlays so they rebuild their texture
	for iid in _draw_overlays:
		var ovl = _draw_overlays[iid]
		if is_instance_valid(ovl) and ovl.has_method("set_badge_size"):
			ovl.set_badge_size(size_px)


func initialize():
	_read_custom_dir()
	_load_favorites()
	_load_settings()
	_load_icons()
	# Drop any stale baked icons from a previous load of this mod — earlier
	# bake logic may have cached pre-tinted sources.
	_fav_icon_cache.clear()
	
	if _custom_dir != "":
		_pack_path = _custom_dir.plus_file("Favorite_Assets - PERSONAL USE ONLY - DO NOT REDISTRIBUTE.dungeondraft_pack")
	
	# Load the draw-overlay script (used as a base for Control children attached
	# to each ItemList). The path is relative to the mod root provided by _g.Root.
	if USE_DRAW_OVERLAY:
		var root = ""
		if _g and _g.get("Root") and _g.Root is String:
			root = _g.Root
		if root != "":
			var path = root + "scripts/badge_draw_overlay.gd"
			var f = File.new()
			if f.file_exists(path):
				_draw_overlay_script = load(path)
			else:
				# Fallback locations seen across mod layouts
				for alt in ["badge_draw_overlay.gd", "../badge_draw_overlay.gd"]:
					var p2 = root + alt
					if f.file_exists(p2):
						_draw_overlay_script = load(p2)
						break
			if _draw_overlay_script == null:
				print("[Favorites] WARNING: badge_draw_overlay.gd not found — falling back to TextureRect overlay")
	
	print("[Favorites] initialized v54, ", _favorites.size(), " favorites, icons=", _icon_star != null, "/", _icon_fav_badge != null, " draw_overlay=", _draw_overlay_script != null)
	# Publish ourselves so sibling mods (e.g. terrain16) can share the same
	# favorites data through Engine meta (matches the popup_blur convention).
	Engine.set_meta("favorites_singleton", self)


func _load_icons():
	var root = ""
	if _g and _g.get("Root") and _g.Root is String:
		root = _g.Root
	
	if root == "":
		print("[Favorites] Cannot find mod root path")
		return
	
	var img1 = Image.new()
	if img1.load(root + "icons/fav2.png") == OK:
		var new_w = int(img1.get_width() * 0.75)
		var new_h = int(img1.get_height() * 0.75)
		img1.resize(new_w, new_h, Image.INTERPOLATE_LANCZOS)
		var tex1 = ImageTexture.new()
		tex1.create_from_image(img1, 0)
		_icon_star = tex1
	
	var img0 = Image.new()
	if img0.load(root + "icons/fav0.png") == OK:
		var new_w = int(img0.get_width() * 0.75)
		var new_h = int(img0.get_height() * 0.75)
		img0.resize(new_w, new_h, Image.INTERPOLATE_LANCZOS)
		var tex0 = ImageTexture.new()
		tex0.create_from_image(img0, 0)
		_icon_unstar = tex0
	
	var img2 = Image.new()
	if img2.load(root + "icons/fav1.png") == OK:
		_icon_fav_badge_img = img2
		var tex2 = ImageTexture.new()
		tex2.create_from_image(img2, ImageTexture.FLAG_FILTER)
		_icon_fav_badge = tex2
	
	var img_ft = Image.new()
	if img_ft.load(root + "icons/free_transform.png") == OK:
		var new_w = int(img_ft.get_width() * 0.75)
		var new_h = int(img_ft.get_height() * 0.75)
		img_ft.resize(new_w, new_h, Image.INTERPOLATE_LANCZOS)
		var tex_ft = ImageTexture.new()
		tex_ft.create_from_image(img_ft, 0)
		_icon_ft = tex_ft


# ===== Cache invalidation helpers =====

func _bump_fav_version() -> void:
	# Call after any mutation of _favorites — invalidates downstream caches
	_fav_version += 1
	_fav_tooltips_cache.clear()
	_badge_sigs.clear()
	_invalidate_all_draw_overlays()


func _get_fav_tooltips_for_type(fav_type: int) -> Dictionary:
	# Cached lookup of {basename: true} for all favs matching the given panel type.
	# Rebuilt only when _favorites changes.
	var cached = _fav_tooltips_cache.get(fav_type)
	if cached != null and cached.get("version", -1) == _fav_version:
		return cached["tooltips"]
	var tooltips = {}
	for fav_path in _favorites:
		var info = _favorites[fav_path]
		if info is Dictionary and _types_match(int(info.get("type", 4)), fav_type):
			tooltips[fav_path.get_file().get_basename().to_lower()] = true
	_fav_tooltips_cache[fav_type] = {"version": _fav_version, "tooltips": tooltips}
	return tooltips


func _sort_hits_by_idx(a, b) -> bool:
	# Sort comparator for [idx, path] pairs — keeps overlay in DD's visual order.
	return a[0] < b[0]


# ===== Colorable detection =====
# Cached set of res:// paths that carry the "Colorable" tag in their source
# pack. Rebuilt on map change (world instance id switch).
var _colorable_cache = null
var _colorable_cache_world_id = -1


func _collect_colorable_from_tags_file(tags_path: String, path_prefix: String, out_set: Dictionary) -> void:
	var f = File.new()
	if f.open(tags_path, File.READ) != OK:
		return
	var txt = f.get_as_text()
	f.close()
	var parsed = JSON.parse(txt)
	if parsed.error != OK or not (parsed.result is Dictionary):
		return
	var tags = parsed.result.get("tags", {})
	if not (tags is Dictionary):
		return
	# Case-insensitive match — different sources may capitalize differently.
	var arr = null
	for tag_name in tags:
		if tag_name is String and tag_name.to_lower() == "colorable":
			arr = tags[tag_name]
			break
	if not (arr is Array):
		return
	var added = 0
	for p in arr:
		if not (p is String) or p == "":
			continue
		# Tag files vary: DD's default tags store absolute res:// paths,
		# while custom packs store pack-relative paths like "textures/...".
		# Only prepend the prefix when the path is relative.
		var final_path = p if p.begins_with("res://") else path_prefix + p
		out_set[final_path] = true
		added += 1
	if added > 0:
		print("[Favs] tags from ", tags_path, ": ", added, " colorable")


func _get_colorable_set() -> Dictionary:
	var cur_world_id = -1
	if _g and _g.World and is_instance_valid(_g.World):
		cur_world_id = _g.World.get_instance_id()
	if _colorable_cache != null and _colorable_cache_world_id == cur_world_id:
		return _colorable_cache
	
	_colorable_cache = {}
	_colorable_cache_world_id = cur_world_id
	
	# Track which prefixes we've already processed to avoid duplicate reads.
	var checked_prefixes = {}
	
	# Source 1: DD's built-in default assets. Their res:// paths start with
	# "res://textures/..." (no /packs/ prefix). The tag file typically lives
	# at res://data/default.dungeondraft_tags with pack-relative entries.
	_collect_colorable_from_tags_file("res://data/default.dungeondraft_tags", "res://", _colorable_cache)
	checked_prefixes["res://"] = true
	
	# Source 2: each pack declared in the current map's AssetManifest.
	if _g != null and ("Header" in _g) and _g.Header != null \
			and ("AssetManifest" in _g.Header) and _g.Header.AssetManifest != null:
		for entry in _g.Header.AssetManifest:
			if entry == null or not ("ID" in entry):
				continue
			var pid = entry.ID
			if pid == _pack_id:
				continue
			var prefix = "res://packs/" + pid + "/"
			if checked_prefixes.has(prefix):
				continue
			checked_prefixes[prefix] = true
			_collect_colorable_from_tags_file(prefix + "data/default.dungeondraft_tags", prefix, _colorable_cache)
	
	# Source 3 (fallback): scan every panel's Lookup for pack roots we
	# haven't processed yet. Catches packs loaded by DD but not listed in
	# the current AssetManifest. Cheap: we just extract unique prefixes.
	var discovered = {}
	for key in _panels:
		var il = _panels[key].get("item_list")
		if not is_instance_valid(il):
			continue
		var lookup = il.get("Lookup")
		if not (lookup is Dictionary):
			continue
		for path in lookup:
			if not (path is String):
				continue
			if path.begins_with("res://packs/"):
				var rest = path.substr(len("res://packs/"))
				var slash = rest.find("/")
				if slash > 0:
					var pref = "res://packs/" + rest.substr(0, slash) + "/"
					if not checked_prefixes.has(pref):
						discovered[pref] = true
	for pref in discovered:
		checked_prefixes[pref] = true
		_collect_colorable_from_tags_file(pref + "data/default.dungeondraft_tags", pref, _colorable_cache)
	
	print("[Favorites] colorable set built: ", _colorable_cache.size(), " paths, prefixes checked: ", checked_prefixes.keys())
	return _colorable_cache


# ===== Favorites overlay icon baking =====
# We bake tinted copies of colorable icons in GDScript rather than relying
# on a shader on the overlay Control:
#   - Sharing DD's material whitens text/separators (DD's shader ignores
#     modulate in its else branch — fine because DD's theme is white-on-dark,
#     but in our overlay it paints stylebox borders pure white).
#   - Our own modulate-preserving variant breaks the red-replacement logic
#     because modulate isn't always (1,1,1) for DD's icon draws.
# Baking sidesteps all of it: the overlay is a vanilla ItemList with
# pre-tinted ImageTextures, nothing to fight with.
#
# Cache layout: src_path -> { original: Texture, tint_key: String, tinted: Texture }
# Only the currently-active tint is kept per icon; rebaked on tint change.
var _fav_icon_cache = {}
var _last_polled_tint = Color.white
var _tint_change_pending = false
var _tint_debounce_accum = 0.0
const TINT_DEBOUNCE_SEC = 0.05


func _tint_key_for(c: Color) -> String:
	return "%02x%02x%02x%02x" % [
		int(clamp(c.r, 0.0, 1.0) * 255),
		int(clamp(c.g, 0.0, 1.0) * 255),
		int(clamp(c.b, 0.0, 1.0) * 255),
		int(clamp(c.a, 0.0, 1.0) * 255)
	]


# Cache of per-pack custom_color_overrides {prefix -> {min_redness, red_tolerance, min_saturation}}
# Prefix examples: "res://" for default, "res://packs/LORESP01/" for custom packs.
var _pack_color_overrides = {}
var _pack_color_overrides_world_id = -1

# DD defaults when custom_color_overrides is missing or disabled.
const _DEFAULT_COLOR_OVERRIDES = {
	"min_redness": 0.1,
	"red_tolerance": 0.04,
	"min_saturation": 0.0
}


func _read_pack_color_overrides(pack_json_path: String) -> Dictionary:
	var f = File.new()
	if f.open(pack_json_path, File.READ) != OK:
		return _DEFAULT_COLOR_OVERRIDES
	var txt = f.get_as_text()
	f.close()
	var parsed = JSON.parse(txt)
	if parsed.error != OK or not (parsed.result is Dictionary):
		return _DEFAULT_COLOR_OVERRIDES
	var cco = parsed.result.get("custom_color_overrides", null)
	if not (cco is Dictionary):
		return _DEFAULT_COLOR_OVERRIDES
	# If disabled flag present and false, DD falls back to defaults.
	if cco.has("enabled") and not cco["enabled"]:
		return _DEFAULT_COLOR_OVERRIDES
	return {
		"min_redness": float(cco.get("min_redness", 0.1)),
		"red_tolerance": float(cco.get("red_tolerance", 0.04)),
		"min_saturation": float(cco.get("min_saturation", 0.0))
	}


func _get_overrides_for_path(res_path: String) -> Dictionary:
	# Invalidate cache on map change (same policy as colorable set).
	var cur_world_id = -1
	if _g and _g.World and is_instance_valid(_g.World):
		cur_world_id = _g.World.get_instance_id()
	if _pack_color_overrides_world_id != cur_world_id:
		_pack_color_overrides.clear()
		_pack_color_overrides_world_id = cur_world_id
	
	var prefix = "res://"
	if res_path.begins_with("res://packs/"):
		var rest = res_path.substr(len("res://packs/"))
		var slash = rest.find("/")
		if slash > 0:
			prefix = "res://packs/" + rest.substr(0, slash) + "/"
	
	if _pack_color_overrides.has(prefix):
		return _pack_color_overrides[prefix]
	
	var o: Dictionary
	if prefix == "res://":
		# Default DD pack has no pack.json file exposed at res://pack.json;
		# its thresholds are the Godot shader defaults.
		o = _DEFAULT_COLOR_OVERRIDES
	else:
		o = _read_pack_color_overrides(prefix + "pack.json")
	_pack_color_overrides[prefix] = o
	print("[Favs] overrides for ", prefix, ": ", o)
	return o


func _srgb_to_linear(c: float) -> float:
	# sRGB gamma curve approximation used by Godot when it stores Colors
	# in linear color space for shader uniforms.
	if c <= 0.04045:
		return c / 12.92
	return pow((c + 0.055) / 1.055, 2.4)


func _linear_to_srgb(c: float) -> float:
	if c <= 0.0031308:
		return c * 12.92
	return 1.055 * pow(c, 1.0 / 2.4) - 0.055


var _debug_dumped = false


func _bake_tinted_icon(src_tex, tint: Color, src_path: String = ""):
	# Replicates DD's CustomColors shader pixel-wise on the RAW texture
	# bytes. The ResourceLoader pipeline in Godot/DD may return an already
	# processed/decoded image that doesn't preserve the red marker channel
	# the shader expects. The only reliable way to get the pristine PNG/webp
	# content is to read the file bytes directly — File.open works for
	# resources bundled in DD's PCK and for mounted asset packs.
	var src_img = null
	if src_path != "":
		var f = File.new()
		if f.open(src_path, File.READ) == OK:
			var buf = f.get_buffer(f.get_len())
			f.close()
			if buf.size() > 0:
				var tmp_img = Image.new()
				var ext = src_path.get_extension().to_lower()
				var err = ERR_UNAVAILABLE
				if ext == "png":
					err = tmp_img.load_png_from_buffer(buf)
				elif ext == "webp":
					err = tmp_img.load_webp_from_buffer(buf)
				elif ext == "jpg" or ext == "jpeg":
					err = tmp_img.load_jpg_from_buffer(buf)
				else:
					# Try png first then webp as best-effort
					err = tmp_img.load_png_from_buffer(buf)
					if err != OK:
						err = tmp_img.load_webp_from_buffer(buf)
				if err == OK:
					src_img = tmp_img
				else:
					print("[Favs bake] decode failed (", err, ") for ", src_path, " ext=", ext)
		# Fallback 1: ResourceLoader (may be pre-processed but better than nothing)
		if src_img == null and ResourceLoader.exists(src_path):
			var tex = ResourceLoader.load(src_path)
			if tex != null and tex is Texture and tex.has_method("get_data"):
				src_img = tex.get_data()
				print("[Favs bake] fell back to ResourceLoader for ", src_path)
	if src_img == null:
		print("[Favs bake] could not load source image for ", src_path)
		return null
	var img = Image.new()
	img.copy_from(src_img)
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var w = img.get_width()
	var h = img.get_height()
	var src_bytes = img.get_data()
	var out_bytes = PoolByteArray()
	out_bytes.resize(src_bytes.size())
	var overrides = _get_overrides_for_path(src_path)
	var min_redness = overrides["min_redness"]
	var red_tolerance = overrides["red_tolerance"]
	var min_saturation = overrides["min_saturation"]
	var tr = tint.r
	var tg = tint.g
	var tb = tint.b
	var ta = tint.a
	var i = 0
	var total = src_bytes.size()
	var tinted_pixels = 0
	var logged_sample = false
	while i < total:
		var r = src_bytes[i] / 255.0
		var g = src_bytes[i + 1] / 255.0
		var b = src_bytes[i + 2] / 255.0
		var a = src_bytes[i + 3] / 255.0
		var is_red = abs(g - b) <= red_tolerance
		var sat_ok = 1.0 - (g + b) * 0.5 >= min_saturation
		var redness = r - (g + b) * 0.5
		var nr: float
		var ng: float
		var nb: float
		var na: float
		if is_red and sat_ok and redness > min_redness:
			nr = r * tr
			ng = r * tg
			nb = r * tb
			var l = 0.299 * r + 0.587 * g + 0.114 * b
			if l > 0.333:
				var f = l - 0.333
				nr = nr + (1.0 - nr) * f
				ng = ng + (1.0 - ng) * f
				nb = nb + (1.0 - nb) * f
			na = a * ta
			tinted_pixels += 1
			if not logged_sample:
				logged_sample = true
				print("[Favs bake sample] ", src_path, " px in=(", r, ",", g, ",", b, ") out=(", nr, ",", ng, ",", nb, ") tint=", tint)
		else:
			nr = r
			ng = g
			nb = b
			na = a
		out_bytes.set(i, int(clamp(nr, 0.0, 1.0) * 255))
		out_bytes.set(i + 1, int(clamp(ng, 0.0, 1.0) * 255))
		out_bytes.set(i + 2, int(clamp(nb, 0.0, 1.0) * 255))
		out_bytes.set(i + 3, int(clamp(na, 0.0, 1.0) * 255))
		i += 4
	var out_img = Image.new()
	out_img.create_from_data(w, h, false, Image.FORMAT_RGBA8, out_bytes)
	# Use default ImageTexture flags (FILTER | MIPMAPS | REPEAT) to match how
	# DD's icons render — flags=0 gives nearest-neighbor which looks wrong.
	var tex = ImageTexture.new()
	tex.create_from_image(out_img)
	# One-shot debug dump: save first colorable's source and baked output to
	# user:// so we can inspect them in an image viewer and compare with what
	# DD actually renders on the canvas.
	if not _debug_dumped and tinted_pixels > 0:
		_debug_dumped = true
		var dir = Directory.new()
		if not dir.dir_exists("user://UnofficialPatch/Favorites"):
			dir.make_dir_recursive("user://UnofficialPatch/Favorites")
		var safe = src_path.replace("/", "_").replace(":", "")
		src_img.save_png("user://UnofficialPatch/Favorites/debug_src_" + safe + ".png")
		out_img.save_png("user://UnofficialPatch/Favorites/debug_baked_" + safe + ".png")
		print("[Favs bake DEBUG] dumped source+baked for ", src_path, " to user://UnofficialPatch/Favorites/")
	if tinted_pixels == 0:
		# Nothing matched — either the texture has no red regions, or our
		# thresholds are off. Log once to help diagnose default-asset issues.
		print("[Favs bake] ", src_path, ": no red pixels found in ", w, "x", h, " (format was ", src_img.get_format(), ")")
	return tex


func _get_tinted_icon(src_path: String, src_tex, tint: Color):
	if src_tex == null:
		return null
	var tk = _tint_key_for(tint)
	var entry = _fav_icon_cache.get(src_path)
	if entry != null and entry.get("tint_key", "") == tk:
		var t = entry.get("tinted")
		if t != null and is_instance_valid(t):
			return t
	var baked = _bake_tinted_icon(src_tex, tint, src_path)
	if baked == null:
		return src_tex
	_fav_icon_cache[src_path] = {"original": src_tex, "tint_key": tk, "tinted": baked}
	return baked


func _rebake_active_overlays():
	var tint = _get_dd_tint()
	var examined = 0
	var colorable_found = 0
	var rebaked = 0
	var no_entry = 0
	for key in _panels:
		if not _panels[key].get("in_favs", false):
			continue
		var overlay = _panels[key].get("overlay_list")
		if not is_instance_valid(overlay):
			continue
		for idx in range(overlay.get_item_count()):
			examined += 1
			var meta = overlay.get_item_metadata(idx)
			if not (meta is String):
				continue
			var info = _favorites.get(meta)
			if info == null or not (info is Dictionary):
				continue
			if not info.get("colorable", false):
				continue
			colorable_found += 1
			var entry = _fav_icon_cache.get(meta)
			if entry == null:
				# Never baked yet — grab the current overlay icon as source.
				no_entry += 1
				var cur_icon = overlay.get_item_icon(idx)
				if cur_icon == null:
					continue
				var new_icon = _get_tinted_icon(meta, cur_icon, tint)
				if new_icon != null:
					overlay.set_item_icon(idx, new_icon)
					rebaked += 1
				continue
			var orig = entry.get("original")
			if orig == null or not is_instance_valid(orig):
				continue
			var new_icon2 = _get_tinted_icon(meta, orig, tint)
			if new_icon2 != null:
				overlay.set_item_icon(idx, new_icon2)
				rebaked += 1
	print("[Favs] rebake: examined=", examined, " colorable=", colorable_found, " rebaked=", rebaked, " no_entry=", no_entry)


func _get_dd_tint() -> Color:
	# Scan each panel's item_list AND its ancestor chain for a ShaderMaterial
	# with the tint_r uniform. DD may attach the material not on the ItemList
	# itself but on a wrapping Control (e.g. the Margins container).
	for key in _panels:
		var il = _panels[key].get("item_list")
		if not is_instance_valid(il):
			continue
		var n = il
		var depth = 0
		while n != null and depth < 8:
			if n is CanvasItem:
				var m = n.material
				if m != null and m is ShaderMaterial:
					var t = m.get_shader_param("tint_r")
					if t is Color:
						return t
			n = n.get_parent()
			depth += 1
	return Color.white


func _is_from_favs_pack(res_path: String) -> bool:
	# Detect assets that belong to our own Favorites pack.
	# DD mounts pack assets at res:// paths that include the pack id.
	# Prevents:
	#   - displaying our Favorites pack's copy of a texture alongside its
	#     original during fav-only mode (visual duplicate)
	#   - recursively favoriting assets that are already copies of favorites
	if res_path == null or not (res_path is String) or res_path == "":
		return false
	return _pack_id in res_path


func _is_favs_pack_loaded() -> bool:
	# Returns true if DD currently has our Favorites pack actively loaded
	# for the current map. We can't safely modify favorites while the pack
	# is loaded because DD holds the .dungeondraft_pack file open —
	# rewriting it crashes DD.
	#
	# Authoritative source: _g.Header.AssetManifest lists the packs
	# actively loaded for the current map (same source used by
	# pack_cache_fix to detect which packs are live). A pack present in
	# the assets folder but not enabled for this map sits in AssetPacks
	# only, NOT in AssetManifest — and it's safe to rewrite in that case.
	#
	# IMPORTANT: do NOT check AssetPacks or scan Lookup dicts — both hold
	# stale entries from unloaded packs (which is exactly the bug
	# pack_cache_fix patches), producing false positives.
	if _g == null or not ("Header" in _g) or _g.Header == null:
		return false
	if not ("AssetManifest" in _g.Header) or _g.Header.AssetManifest == null:
		return false
	for entry in _g.Header.AssetManifest:
		if entry == null:
			continue
		if "ID" in entry and entry.ID == _pack_id:
			return true
	return false


func _show_pack_loaded_popup() -> void:
	# Modal dialog shown when the user tries to modify favorites while the
	# Favorites pack is loaded by DD.
	var dlg = AcceptDialog.new()
	dlg.window_title = "Favorites locked"
	dlg.dialog_text = "Impossible to update favorites when the Favorite pack is loaded."
	dlg.popup_exclusive = true
	var layer = _get_popup_layer()
	if layer:
		layer.add_child(dlg)
	else:
		var tree = Engine.get_main_loop()
		if tree and tree is SceneTree and tree.root:
			tree.root.add_child(dlg)
	# Auto-free on close
	dlg.connect("popup_hide", dlg, "queue_free")
	dlg.popup_centered()


var _favs_reapply_cooldown = 0
var _last_favs_shown_count = -1
# Throttle for badge refresh — reduces CPU load on huge lists (200k+ items).
# Badges may lag a few frames behind scroll, which is imperceptible.
var _badge_throttle_counter = 0
const BADGE_THROTTLE_FRAMES = 2  # ~30 Hz — poll is essentially free when scroll doesn't change, so we can afford fast follow
# Per-ItemList scroll idle tracking — when the user is actively scrolling, we
# hide badges and skip ALL badge work to keep frame cost zero. Badges reappear
# once scroll has been still for one throttle cycle.
var _scroll_idle_state = {}  # iid -> {last_scroll, last_size_x, last_size_y, idle}

# === Native _draw() overlay approach ===
# Instead of positioning TextureRect children per visible favorite (which
# requires CPU work tied to scroll), attach a Control child to each ItemList
# with a custom _draw() that uses Godot's native canvas commands. The Control
# auto-redraws when the GridMenu/ItemList does — pixel-perfect, scroll-locked,
# and ~free per frame (only triggered on scroll/repaint events).
const USE_DRAW_OVERLAY = true
var _draw_overlay_script = null  # GDScript instance for the overlay class
var _draw_overlays = {}  # iid (ItemList) -> Control instance

func update(delta):
	if _custom_dir == "":
		_read_custom_dir()
		if _custom_dir != "":
			_pack_path = _custom_dir.plus_file("Favorite_Assets - PERSONAL USE ONLY - DO NOT REDISTRIBUTE.dungeondraft_pack")
		return
	
	if not _g.World or not is_instance_valid(_g.World) or not _g.World.is_inside_tree():
		return
	
	# CPU tint polling/rebake removed: we share DD's shader material on the
	# overlay, so the GPU handles tinting automatically when DD updates its
	# tint_r uniform. Nothing to do here each frame.
	
	# Deferred rebuild: wait 2 frames for wait dialog to render, then rebuild
	if _pending_rebuild:
		_pending_rebuild_frame += 1
		if _pending_rebuild_frame >= 2:
			_rebuild_pack()
			_hide_wait_dialog()
			_pending_rebuild = false
			_refresh_active_panels()
		return
	
	if not _tab_injected:
		_try_inject_tab()
	# Try to hook Preferences dialog (for badge-size slider)
	if _tab_injected and not _prefs_hooked:
		_try_hook_preferences()
	# Debounced save for badge size
	if _badge_size_save_pending_frames > 0:
		_badge_size_save_pending_frames -= 1
		if _badge_size_save_pending_frames == 0:
			_save_settings()
	elif not _panels.has("wall"):
		_wall_scan_timer += 1
		if _wall_scan_timer % 30 == 0:
			var wall_list = _find_wall_item_list()
			if wall_list:
				_inject_wall_panel(wall_list)
	
	if _tab_injected and not _panels.has("pattern"):
		_pattern_scan_timer += 1
		if _pattern_scan_timer % 30 == 0:
			var pattern_menu = _find_pattern_menu()
			if pattern_menu:
				_inject_pattern_panel(pattern_menu)
	
	if _tab_injected and not _panels.has("floor_wall"):
		_floor_scan_timer += 1
		if _floor_scan_timer % 30 == 0:
			_try_inject_floor_panel()
	
	if _tab_injected and not _panels.has("portal"):
		_portal_scan_timer += 1
		if _portal_scan_timer % 30 == 0:
			var portal_menu = _find_portal_menu()
			if portal_menu:
				_inject_portal_panel(portal_menu)
	
	if _tab_injected and not _panels.has("roof"):
		_roof_scan_timer += 1
		if _roof_scan_timer % 30 == 0:
			_try_inject_roof_panel()
	
	if _tab_injected and not _panels.has("terrain"):
		_terrain_scan_timer += 1
		if _terrain_scan_timer % 30 == 0:
			_try_inject_terrain_panel()
	# ASO terrain. Two surfaces: right-side panel (terrain_aso) and popup
	# (terrain_aso_popup). Both get periodically re-checked & re-validated.
	if _tab_injected:
		# Right-side panel
		if _panels.has("terrain_aso"):
			var aso_panel = _panels["terrain_aso"]
			var aso_il = aso_panel.get("item_list")
			var aso_btn = aso_panel.get("fav_btn")
			if not is_instance_valid(aso_il) or not is_instance_valid(aso_btn):
				_panels.erase("terrain_aso")
		if not _panels.has("terrain_aso"):
			if _terrain_scan_timer % 30 == 0:
				_try_inject_terrain_aso_panel()
		# Popup
		if _panels.has("terrain_aso_popup"):
			var pop_panel = _panels["terrain_aso_popup"]
			var pop_il = pop_panel.get("item_list")
			var pop_btn = pop_panel.get("fav_btn")
			if not is_instance_valid(pop_il) or not is_instance_valid(pop_btn):
				_panels.erase("terrain_aso_popup")
		if not _panels.has("terrain_aso_popup"):
			if _terrain_scan_timer % 30 == 0:
				_try_inject_terrain_aso_popup()
	
	# Light panel: check periodically until injected (needs LightTool to be active)
	if _tab_injected and not _panels.has("light"):
		_light_scan_timer += 1
		if _light_scan_timer % 30 == 0:
			_try_inject_light_panel()
	
	# Cave panel — CaveBrush has no textureMenu, need to find ItemList via panel scan
	if _tab_injected and not _panels.has("cave"):
		_cave_scan_timer += 1
		if _cave_scan_timer % 30 == 0:
			_try_inject_cave_panel()
	
	# Material panel
	if _tab_injected and not _panels.has("material"):
		_material_scan_timer += 1
		if _material_scan_timer % 30 == 0:
			var mat_menu = _find_tool_texture_menu("MaterialBrush")
			if mat_menu:
				_inject_tool_panel(mat_menu, "material", 11, "MaterialBrush")
	
	# Try to inject into SelectTool sub-panels (they appear when selecting walls/paths/objects)
	if _tab_injected:
		_select_scan_timer += 1
		if _select_scan_timer % 30 == 0:
			_try_inject_select_panels()
	
	# Cooldown for reapply (wait a few frames after DD takes over)
	if _favs_reapply_cooldown > 0:
		_favs_reapply_cooldown -= 1
		if _favs_reapply_cooldown == 0:
			for key in _panels:
				if _is_panel_toggle_on(key):
					# Reset in_favs so _show_favs_for_panel rebuilds from item_list
					_panels[key]["in_favs"] = false
					_show_favs_for_panel(key)
	
	# Check if DD repopulated its list (tool switch etc)
	if _favs_reapply_cooldown == 0:
		for key in _panels:
			if _is_panel_toggle_on(key):
				var panel = _panels[key]
				var item_list = panel["item_list"]
				if is_instance_valid(item_list):
					var dd_count = item_list.get_item_count()
					if dd_count != panel.get("dd_list_count", -1):
						panel["dd_list_count"] = dd_count
						_favs_reapply_cooldown = 2
						# The index mapping changed but grid geometry hasn't.
						# Just rebuild fav_indices, keep calibration.
						var _d_ovl = _draw_overlays.get(item_list.get_instance_id())
						if _d_ovl != null and is_instance_valid(_d_ovl):
							_d_ovl.invalidate()
						break
	
	# Right-click entièrement géré par right_click_util
	# (qui appelle check_right_click() pour les listes)
	
	# F key toggles favorites for the visible panel
	# (ignore CTRL+F — reserved for Search & Select)
	var f_pressed = Input.is_key_pressed(KEY_F) and not Input.is_key_pressed(KEY_CONTROL)
	if f_pressed and not _f_was_pressed:
		if not _any_lineedit_has_focus():
			_toggle_visible_panel_favs()
	_f_was_pressed = f_pressed
	
	# Poll search bar text for favorites overlay sync (catches Enter key)
	for _sk in _panels:
		if not _panels[_sk].get("in_favs", false): continue
		# Try to find search LineEdit if not yet stored
		var _se = _panels[_sk].get("search_lineedit")
		if _se == null or not is_instance_valid(_se):
			var _lib = _panels[_sk].get("lib_panel")
			if _lib and is_instance_valid(_lib):
				_se = _find_search_lineedit(_lib)
				if _se != null: _panels[_sk]["search_lineedit"] = _se
		if _se == null or not is_instance_valid(_se): continue
		var _st = _se.text
		if _st != _last_search_text.get(_sk, null):
			_last_search_text[_sk] = _st
			# Only filter if overlay is already shown (not mid-construction)
			var _ovl = _panels[_sk].get("overlay_list")
			if _ovl != null and is_instance_valid(_ovl) and _ovl.visible:
				_filter_overlay(_sk, _st)
	# Apply fav badges to DD's native lists — throttled to ~10 Hz to keep
	# CPU low on huge (200k+) lists. Badge has slight visual lag on scroll.
	if _icon_fav_badge:
		_badge_throttle_counter += 1
		if _badge_throttle_counter >= BADGE_THROTTLE_FRAMES:
			_badge_throttle_counter = 0
			_apply_badges_to_dd_lists()
	
	# Sync highlight: if DD's hidden list selection changed, update overlay
	for key in _panels:
		if not _is_panel_toggle_on(key):
			continue
		var panel = _panels[key]
		if not panel.get("in_favs", false):
			continue
		var item_list = panel["item_list"]
		var overlay = panel.get("overlay_list")
		if not is_instance_valid(item_list) or not is_instance_valid(overlay):
			continue
		
		# Sync select_mode (DD changes it when switching to ScatterTool)
		if overlay.select_mode != item_list.select_mode:
			overlay.select_mode = item_list.select_mode
		
		# Sync wall icon colors (user changes Color via color picker)
		if panel.get("type", 0) == 1:
			var fav_map = panel.get("fav_to_dd_index", [])
			for fi in range(fav_map.size()):
				var di = fav_map[fi]
				if di < item_list.get_item_count() and fi < overlay.get_item_count():
					var dd_mod = item_list.get_item_icon_modulate(di)
					if overlay.get_item_icon_modulate(fi) != dd_mod:
						overlay.set_item_icon_modulate(fi, dd_mod)
		
		# Only sync selection for select_* panels (assets selected on map)
		# For tool panels (object, light, wall...) don't touch overlay selection
		if not key.begins_with("select_"):
			# Skip RawSelectables check for tool panels
			pass
		else:
			var _raw = null
			var _st_tool = _g.Editor.Tools.get("SelectTool") if _g.Editor and _g.Editor.Tools is Dictionary else null
			if _st_tool: _raw = _st_tool.RawSelectables
			if _raw == null or _raw.size() == 0:
				overlay.set_block_signals(true)
				for _fi in range(overlay.get_item_count()):
					overlay.unselect(_fi)
				overlay.set_block_signals(false)
				continue
		var dd_selected = item_list.get_selected_items()
		if dd_selected.size() > 0:
			var dd_idx = dd_selected[0]
			# For terrain, fav_map is only valid when the ORIGINAL pack (the
			# one active when fav_map was built) is still loaded. As soon as
			# _forward_overlay_to_dd switches to a custom pack, fav_map's
			# dd_index values point into the previous pack's TextureMenu —
			# syncing overlay off it picks the wrong fav (classic symptom:
			# user clicks first fav of a custom pack, overlay highlights the
			# first default fav because fav_map[0] points to dd index 0).
			# For terrain, match by the res_path metadata on the selected
			# item instead.
			if key == "terrain":
				# On ASO, TextureMenu (item_list) selection is unreliable in
				# fav mode: asset_cycle's shift+scroll previews via
				# SetTextureFromWindow without updating item_list, so
				# dd_selected reflects stale state. The overlay is the source
				# of truth here — skip the sync and let the overlay stay as
				# cycling/clicking leaves it.
				if panel.get("is_aso", false):
					continue
				_populate_terrain_metadata(item_list)
				var dd_meta = null
				if dd_idx >= 0 and dd_idx < item_list.get_item_count():
					dd_meta = item_list.get_item_metadata(dd_idx)
				var terrain_paths = panel.get("terrain_fav_paths", [])
				var found_t = false
				if dd_meta != null:
					for fi in range(terrain_paths.size()):
						if terrain_paths[fi] == dd_meta:
							if not overlay.is_selected(fi):
								overlay.set_block_signals(true)
								overlay.select(fi, false)
								overlay.set_block_signals(false)
								overlay.ensure_current_is_visible()
							found_t = true
							break
				if not found_t:
					overlay.set_block_signals(true)
					for fi in range(overlay.get_item_count()):
						overlay.unselect(fi)
					overlay.set_block_signals(false)
				continue
			var fav_map = panel.get("fav_to_dd_index", [])
			var found = false
			for fi in range(fav_map.size()):
				if fav_map[fi] == dd_idx:
					if not overlay.is_selected(fi):
						overlay.set_block_signals(true)
						overlay.select(fi, false)
						overlay.set_block_signals(false)
						overlay.ensure_current_is_visible()
					found = true
					break
			if not found:
				overlay.set_block_signals(true)
				# Selected item is not a favorite — deselect overlay
				for fi in range(overlay.get_item_count()):
					overlay.unselect(fi)
				overlay.set_block_signals(false)


func _get_viewport_mouse_pos():
	var tree = Engine.get_main_loop()
	if tree and tree is SceneTree and tree.root:
		return tree.root.get_mouse_position()
	return null


func _get_world_mouse_pos():
	if _g.WorldUI and is_instance_valid(_g.WorldUI):
		return _g.WorldUI.get("MousePosition")
	return null


func _show_list_context_popup(global_pos: Vector2):
	var metas = _list_ctx_metas
	if metas.size() == 0:
		return
	
	var all_fav = true
	var any_fav = false
	for m in metas:
		if _favorites.has(m):
			any_fav = true
		else:
			all_fav = false
	
	if _list_ctx_menu and is_instance_valid(_list_ctx_menu):
		_list_ctx_menu.queue_free()
	
	_list_ctx_menu = PopupMenu.new()
	_get_popup_layer().add_child(_list_ctx_menu)
	
	var count_str = " (" + str(metas.size()) + ")" if metas.size() > 1 else ""
	
	if not all_fav:
		_list_ctx_menu.add_item("Add to Favorites" + count_str, 0)
		if _icon_star:
			_list_ctx_menu.set_item_icon(0, _icon_star)
	if any_fav:
		_list_ctx_menu.add_item("Remove from Favorites" + count_str, 1)
		var rem_idx = _list_ctx_menu.get_item_index(1)
		if _icon_unstar:
			_list_ctx_menu.set_item_icon(rem_idx, _icon_unstar)
	
	_list_ctx_menu.connect("id_pressed", self, "_on_list_ctx_pressed")
	_list_ctx_menu.popup(Rect2(global_pos, Vector2(1, 1)))


var _ft_toggle_btn_ref = null  # cached reference to free_transform toggle button


func _find_ft_toggle_button():
	if _ft_toggle_btn_ref != null and is_instance_valid(_ft_toggle_btn_ref):
		return _ft_toggle_btn_ref
	# Search in SelectTool panel recursively for a CheckButton connected to _on_toggle
	var toolset = _g.Editor.get("Toolset") if _g.Editor else null
	if not toolset or not is_instance_valid(toolset): return null
	var sp = toolset.GetToolPanel("SelectTool")
	if not sp: return null
	var result = _find_checkbutton_recursive(sp, 0)
	if result != null:
		_ft_toggle_btn_ref = result
	return result


func _find_checkbutton_recursive(node: Node, depth: int):
	if depth > 8: return null
	if node is CheckButton and node.get_signal_connection_list("toggled").size() > 0:
		return node
	for child in node.get_children():
		if not is_instance_valid(child): continue
		var r = _find_checkbutton_recursive(child, depth + 1)
		if r != null: return r
	return null




# ===== Right-click provider interface (pour right_click_util) =====

func check_right_click() -> bool:
	# Intercepter si Free Transform est actif
	var _ft_toggle = _find_ft_toggle_button()
	if _ft_toggle != null and _ft_toggle.pressed:
		return true  # FT gère son propre menu contextuel
	if _ft_toggle == null and _g.ModMapData.get("_free_transform_active", false):
		return true

	# Intercepter si clic sur un ItemList — afficher le popup de liste
	var mouse_pos = _get_viewport_mouse_pos()
	if mouse_pos != null:
		for key in _panels:
			var il = _panels[key].get("item_list")
			var ovl = _panels[key].get("overlay_list")
			var lists_to_check = []
			if il and is_instance_valid(il) and il.is_visible_in_tree():
				lists_to_check.append(il)
			if ovl and is_instance_valid(ovl) and ovl.visible:
				lists_to_check.append(ovl)
			for check_list in lists_to_check:
				var rect = check_list.get_global_rect()
				if rect.has_point(mouse_pos):
					if key.begins_with("select_"):
						var local_pos = mouse_pos - rect.position
						var idx = check_list.get_item_at_position(local_pos, true)
						if idx >= 0:
							var meta = check_list.get_item_metadata(idx)
							if meta is String and meta != "":
								_list_ctx_metas = [meta]
								_list_ctx_type = _panels[key]["type"]
								_show_list_context_popup(mouse_pos)
					return true
	return false


func get_context_items(raw) -> Array:
	var items = []
	var select_tool = _get_select_tool()
	if select_tool == null:
		return items

	# Analyser la sélection pour favorites
	var all_fav = true
	var any_fav = false
	var has_entries = false
	for s in raw:
		if s == null or not is_instance_valid(s):
			continue
		var thing = s.get("Thing")
		if thing == null or not is_instance_valid(thing):
			continue
		var type = select_tool.GetSelectableType(thing)
		if type >= 1 and type <= 8:
			var tex_path = _get_thing_texture_path(thing, type)
			if tex_path != "":
				has_entries = true
				if _favorites.has(tex_path):
					any_fav = true
				else:
					all_fav = false

	if not has_entries:
		return items

	if not all_fav:
		items.append({label = "Add to Favorites", icon = _icon_star, action_id = "fav_add"})
	if any_fav:
		items.append({label = "Remove from Favorites", icon = _icon_unstar, action_id = "fav_remove"})

	# Note: Free Transform context entry was previously added here; it's
	# now provided by the standalone ft_context.gd provider so it stays
	# available even when Favorite Assets is disabled.

	return items


func on_context_action(action_id: String, raw) -> void:
	var select_tool = _get_select_tool()
	if select_tool == null:
		return

	var entries = []
	for s in raw:
		if s == null or not is_instance_valid(s):
			continue
		var thing = s.get("Thing")
		if thing == null or not is_instance_valid(thing):
			continue
		var type = select_tool.GetSelectableType(thing)
		if type >= 1 and type <= 8:
			var tex_path = _get_thing_texture_path(thing, type)
			if tex_path != "":
				entries.append({"thing": thing, "type": type, "tex_path": tex_path})

	match action_id:
		"fav_add":
			_add_to_favorites(entries)
		"fav_remove":
			_remove_from_favorites(entries)


func _get_select_tool():
	if not _g.Editor or not is_instance_valid(_g.Editor):
		return null
	var tools = _g.Editor.get("Tools")
	if tools == null or not tools is Dictionary:
		return null
	return tools.get("SelectTool")


# ===== Texture Extraction =====

func _get_thing_texture_path(thing, type: int) -> String:
	if not is_instance_valid(thing):
		return ""
	
	# For Pathways (type 5), use Texture property directly
	if type == 5:
		var tex_obj = thing.get("Texture")
		if tex_obj and tex_obj is Texture and tex_obj.resource_path != "":
			return tex_obj.resource_path
		return ""
	
	# PatternShape (type 7) extends Polygon2D — needs special handling.
	# The Polygon2D.texture has no resource_path (DD creates a tiling copy).
	# Do NOT fall through to child search — that finds the shared Outline
	# texture and treats all patterns as identical.
	if type == 7:
		return _get_pattern_texture_path(thing)
	
	# Objects store texture as String path
	var tex_str = thing.get("texture")
	if tex_str is String and tex_str != "" and not tex_str.begins_with("embedded://"):
		return tex_str
	
	# Wall, PatternShape, Roof, Portal, Light — Texture object property
	for prop in ["Texture", "texture", "EndTexture"]:
		var tex_obj = thing.get(prop)
		if tex_obj and tex_obj is Texture and tex_obj.resource_path != "":
			return tex_obj.resource_path
	
	# Sprite on the thing itself
	if thing is Sprite and thing.texture and thing.texture.resource_path != "":
		return thing.texture.resource_path
	
	# Deep search children (portals, lights, etc.)
	var found = _find_texture_in_children(thing, 3)
	if found != "":
		return found
	
	return ""


func _find_texture_in_children(node, depth: int) -> String:
	if depth <= 0:
		return ""
	for i in range(node.get_child_count()):
		var child = node.get_child(i)
		if not is_instance_valid(child):
			continue
		if child is Sprite and child.texture:
			var rp = child.texture.resource_path
			if rp != "" and not rp.begins_with("embedded://"):
				return rp
		if child is Light2D and child.texture:
			var rp = child.texture.resource_path
			if rp != "" and not rp.begins_with("embedded://"):
				return rp
		var tex_obj = child.get("Texture")
		if tex_obj == null:
			tex_obj = child.get("texture")
		if tex_obj and tex_obj is Texture and tex_obj.resource_path != "":
			return tex_obj.resource_path
		var found = _find_texture_in_children(child, depth - 1)
		if found != "":
			return found
	return ""


# Get the default color from a Wall node
func _get_wall_color(thing) -> String:
	if not is_instance_valid(thing):
		return "ffffff"
	var color = thing.get("Color")
	if color == null:
		color = thing.get("color")
	if color and color is Color:
		return color.to_html(false)
	return "ffffff"


# Get the texture resource path from a PatternShape on the map.
# PatternShape extends Polygon2D — the polygon's .texture is a tiling copy
# whose resource_path is empty.  We need the canonical res:// path that DD's
# GridMenu uses as item metadata (format: res://textures/tilesets/simple/...).
func _get_pattern_texture_path(thing) -> String:
	# ---- Strategy 1: Save() returns dict with "texture" key ----
	# Use call() to cross the C# boundary.  The returned object has type 18
	# (Dictionary) but `is Dictionary` can fail on C# wrappers — access
	# keys directly instead.
	var data = thing.call("Save", false)
	if data != null and typeof(data) == TYPE_DICTIONARY:
		var tp = data.get("texture", "")
		if tp is String and tp != "":
			return tp
	
	# ---- Strategy 2: ShaderMaterial.shader_param("albedo") ----
	# DD renders patterns via a ShaderMaterial on the Polygon2D.  The actual
	# texture is in the "albedo" shader parameter, not Polygon2D.texture.
	if thing is CanvasItem and thing.material and thing.material is ShaderMaterial:
		var stex = thing.material.get_shader_param("albedo")
		if stex and stex is Texture and stex.resource_path != "":
			return stex.resource_path
	
	# ---- Strategy 3: match runtime texture against GridMenu Lookup ----
	if thing is CanvasItem and thing.material and thing.material is ShaderMaterial:
		var stex = thing.material.get_shader_param("albedo")
		if stex and stex is Texture:
			var match_path = _match_texture_in_pattern_menu(stex)
			if match_path != "":
				return match_path
	
	print("[Favorites] Pattern: could not extract texture for ", thing)
	return ""


# Compare a runtime texture against all textures in the PatternShapeTool
# GridMenu Lookup by resource_path.  The Lookup dict maps res_path -> index.
func _match_texture_in_pattern_menu(tex: Texture) -> String:
	var tools = _g.Editor.get("Tools")
	if not tools or not tools is Dictionary:
		return ""
	var pt = tools.get("PatternShapeTool")
	if not pt or not is_instance_valid(pt):
		return ""
	var menu = pt.get("textureMenu")
	if not menu or not is_instance_valid(menu):
		return ""
	
	# GridMenu.Lookup is {String res_path : int index}
	var lookup = menu.get("Lookup")
	if not lookup or not lookup is Dictionary:
		return ""
	
	# Get the image from the runtime texture for comparison
	var src_img = tex.get_data()
	if src_img == null:
		return ""
	var src_w = src_img.get_width()
	var src_h = src_img.get_height()
	
	for res_path in lookup:
		if not res_path is String or res_path == "":
			continue
		var candidate = ResourceLoader.load(res_path)
		if not candidate or not candidate is Texture:
			continue
		# Quick check: same texture object (Godot may cache)
		if candidate == tex:
			return res_path
		# Check dimensions match
		var cand_img = candidate.get_data()
		if cand_img == null:
			continue
		if cand_img.get_width() != src_w or cand_img.get_height() != src_h:
			continue
		# Compare a few sample pixels for fast identity check
		if _images_match_sample(src_img, cand_img):
			return res_path
	
	return ""


func _images_match_sample(a: Image, b: Image) -> bool:
	a.lock()
	b.lock()
	var w = a.get_width()
	var h = a.get_height()
	var matched = true
	# Check 9 sample points (corners + center + midpoints)
	var points = [
		Vector2(0, 0), Vector2(w/2, 0), Vector2(w-1, 0),
		Vector2(0, h/2), Vector2(w/2, h/2), Vector2(w-1, h/2),
		Vector2(0, h-1), Vector2(w/2, h-1), Vector2(w-1, h-1)
	]
	for p in points:
		var px = int(clamp(p.x, 0, w - 1))
		var py = int(clamp(p.y, 0, h - 1))
		if a.get_pixel(px, py) != b.get_pixel(px, py):
			matched = false
			break
	a.unlock()
	b.unlock()
	return matched


# DD pack folder structure per type
func _get_pack_path_for(type: int, fname: String) -> String:
	match type:
		1: return "textures/walls/" + fname
		2, 3: return "textures/portals/" + fname
		4: return "textures/objects/Favorites/" + fname
		5: return "textures/paths/" + fname
		6: return "textures/lights/" + fname
		7: return "textures/patterns/" + fname
		8: return "textures/roofs/" + fname
		9: return "textures/terrain/" + fname
		10: return "textures/caves/" + fname
		11: return "textures/materials/" + fname
	return "textures/objects/Favorites/" + fname


# ===== Context Menu =====



func _enable_free_transform():
	var btn = _find_ft_toggle_button()
	if btn != null and is_instance_valid(btn):
		btn.pressed = true
		btn.emit_signal("toggled", true)
		print("[Favorites] Free Transform enabled via context menu")


func _get_popup_layer() -> CanvasLayer:
	if _popup_layer and is_instance_valid(_popup_layer):
		return _popup_layer
	_popup_layer = CanvasLayer.new()
	_popup_layer.name = "FavoritesPopupLayer"
	_popup_layer.layer = 128  # above DD's UI layers
	_g.World.get_tree().root.add_child(_popup_layer)
	return _popup_layer


func _types_match(stored_type: int, panel_type: int) -> bool:
	if stored_type == panel_type:
		return true
	# Portals: type 2 (doors) and 3 (windows) both belong in portal panels
	if (panel_type == 2 or panel_type == 3) and (stored_type == 2 or stored_type == 3):
		return true
	return false


# ===== Add / Remove =====

func _add_to_favorites(entries: Array):
	if _pack_enabled() and _is_favs_pack_loaded():
		_show_pack_loaded_popup()
		return
	var added = 0
	for entry in entries:
		var tex_path = entry["tex_path"]
		var type = entry["type"]
		var thing = entry["thing"]
		
		if _favorites.has(tex_path):
			continue
		
		var result = _read_texture_data(tex_path)
		if result.size() == 0 or not result.has("data"):
			print("[Favorites] Could not read: ", tex_path)
			continue
		
		var fname = tex_path.get_file()
		var base = fname.get_basename()
		var actual_ext = result["ext"]
		var pack_fname = base + "." + actual_ext
		# Roofs: preserve directory (style_name/tiles.png)
		if type == 8 and "/roofs/" in tex_path:
			var roof_rel = tex_path.split("/roofs/")
			if roof_rel.size() > 1:
				# Replace extension with actual
				var rel = roof_rel[1]
				var rel_base = rel.get_basename()
				pack_fname = rel_base + "." + actual_ext
		var pack_path = _get_pack_path_for(type, pack_fname)
		
		# Get wall color
		var color = "ffffff"
		if type == 1:
			color = _get_wall_color(thing)
		
		# Only objects can carry the "Colorable" tag in DD.
		var is_colorable = false
		if type == 4:
			is_colorable = _get_colorable_set().has(tex_path)
		
		_favorites[tex_path] = {
			"pack_path": pack_path,
			"type": type,
			"color": color,
			"colorable": is_colorable
		}
		_fav_cache[pack_path] = result["data"]
		added += 1
		print("[Favorites] Added: ", pack_path, " from ", tex_path)
	
	if added > 0:
		_bump_fav_version()
		_save_favorites()
		_rebuild_or_defer()
		print("[Favorites] +", added, ". Total: ", _favorites.size())


func _remove_from_favorites(entries: Array):
	if _pack_enabled() and _is_favs_pack_loaded():
		_show_pack_loaded_popup()
		return
	var removed = 0
	for entry in entries:
		var tex_path = entry["tex_path"]
		if not _favorites.has(tex_path):
			continue
		var info = _favorites[tex_path]
		_fav_cache.erase(info["pack_path"])
		_favorites.erase(tex_path)
		removed += 1
		print("[Favorites] Removed: ", tex_path)
	
	if removed > 0:
		_bump_fav_version()
		_save_favorites()
		if _favorites.size() > 0:
			_rebuild_or_defer()
		else:
			var dir = Directory.new()
			if _pack_path != "" and dir.file_exists(_pack_path):
				dir.remove(_pack_path)
			_refresh_active_panels()
		print("[Favorites] -", removed, ". Total: ", _favorites.size())


func _read_texture_data(tex_path: String) -> Dictionary:
	var f = File.new()
	var ext = tex_path.get_extension().to_lower()
	
	if f.open(tex_path, File.READ) == OK:
		var data = f.get_buffer(f.get_len())
		f.close()
		if data.size() > 0:
			return {"data": data, "ext": ext}
	
	var tex = ResourceLoader.load(tex_path)
	if tex and tex is Texture:
		var img = tex.get_data()
		if img:
			var tmp = "user://UnofficialPatch/Favorites/tmp.png"
			if img.save_png(tmp) == OK:
				if f.open(tmp, File.READ) == OK:
					var data = f.get_buffer(f.get_len())
					f.close()
					Directory.new().remove(tmp)
					if data.size() > 0:
						return {"data": data, "ext": "png"}
	
	return {}


# ===== Persistence =====

func _load_favorites():
	var f = File.new()
	if f.open("user://UnofficialPatch/Favorites/favorites.json", File.READ) == OK:
		var text = f.get_as_text()
		f.close()
		var parsed = JSON.parse(text)
		if parsed.error == OK and parsed.result is Dictionary:
			_favorites = parsed.result
			_bump_fav_version()


func _save_favorites():
	var dir = Directory.new()
	if not dir.dir_exists("user://UnofficialPatch/Favorites"):
		dir.make_dir_recursive("user://UnofficialPatch/Favorites")
	var f = File.new()
	if f.open("user://UnofficialPatch/Favorites/favorites.json", File.WRITE) == OK:
		f.store_string(JSON.print(_favorites, "\t"))
		f.close()


func _read_custom_dir():
	var f = File.new()
	if f.open("user://config.ini", File.READ) != OK:
		return
	var content = f.get_as_text()
	f.close()
	for line in content.split("\n"):
		line = line.strip_edges()
		if line.begins_with("custom_assets_directory="):
			var val = line.substr(len("custom_assets_directory=")).strip_edges()
			if val.begins_with("\"") and val.ends_with("\""):
				val = val.substr(1, val.length() - 2)
			val = val.replace("\\\\", "\\")
			if val != "":
				_custom_dir = val
			break


# ===== UI Tab Injection =====

var _panels = {}
var _wall_scan_timer = 0
var _pattern_scan_timer = 0
var _floor_scan_timer = 0
var _portal_scan_timer = 0
var _roof_scan_timer = 0
var _cave_scan_timer = 0
var _material_scan_timer = 0
var _terrain_scan_timer = 0
var _terrain_scanning = false
var _light_scan_timer = 0
var _select_scan_timer = 0

func _try_inject_select_panels():
	var toolset = _g.Editor.get("Toolset")
	if not toolset or not is_instance_valid(toolset):
		return
	var select_panel = toolset.GetToolPanel("SelectTool")
	if not select_panel or not is_instance_valid(select_panel):
		return
	
	# Scan for ItemLists inside the SelectTool panel
	var item_lists = []
	_collect_item_lists(select_panel, item_lists, 0)
	
	var found_any = false
	for il in item_lists:
		if il.get_item_count() == 0:
			continue
		# Skip already-injected lists
		var already = false
		for key in _panels:
			if _panels[key].get("item_list") == il:
				already = true
				break
		if already:
			continue
		
		# Determine type from metadata
		var key = ""
		var fav_type = 0
		for idx in range(min(il.get_item_count(), 3)):
			var meta = il.get_item_metadata(idx)
			if meta is String:
				if "walls" in meta:
					key = "select_wall"
					fav_type = 1
					break
				elif "paths" in meta:
					key = "select_path"
					fav_type = 5
					break
				elif "objects" in meta:
					key = "select_object"
					fav_type = 4
					break
				elif "patterns" in meta or "tilesets" in meta:
					key = "select_pattern"
					fav_type = 7
					break
				elif "portals" in meta:
					key = "select_portal"
					fav_type = 2
					break
				elif "roofs" in meta:
					key = "select_roof"
					fav_type = 8
					break
				elif "lights" in meta:
					key = "select_light"
					fav_type = 6
					break
				elif "caves" in meta:
					key = "select_cave"
					fav_type = 10
					break
				elif "materials" in meta:
					key = "select_material"
					fav_type = 11
					break
		
		if key == "" or _panels.has(key):
			continue
		
		var parent = il.get_parent()
		if not parent:
			continue
		
		var fav_btn = CheckButton.new()
		fav_btn.text = "Favorites only"
		fav_btn.name = "SelectFavsButton_" + key
		if _icon_star:
			fav_btn.icon = _icon_star
		
		var list_idx = il.get_index()
		parent.add_child(fav_btn)
		parent.move_child(fav_btn, list_idx)
		
		fav_btn.connect("toggled", self, "_on_favs_toggled", [key])
		
		if not il.is_connected("gui_input", self, "_on_list_gui_input"):
			il.connect("gui_input", self, "_on_list_gui_input", [key])
		
		_panels[key] = {
			"lib_panel": parent,
			"item_list": il,
			"fav_btn": fav_btn,
			"type": fav_type,
			"in_favs": false,
			"last_count": -1,
			"dd_list_count": -1
		}
		
		print("[Favorites] Toggle injected in SelectTool: ", key, " (", il.get_item_count(), " items)")
		found_any = true
	
	# Light style list is NOT under the SelectTool panel — search scene root
	if not _panels.has("select_light"):
		var tree = Engine.get_main_loop()
		if tree and tree is SceneTree and tree.root:
			var light_il = _find_light_style_list(tree.root, 0, 15)
			if light_il and is_instance_valid(light_il) and light_il.is_visible_in_tree():
				# Make sure it's not our LightTool panel list
				var is_known = false
				for key in _panels:
					if _panels[key].get("item_list") == light_il:
						is_known = true
						break
				if not is_known:
					var parent = light_il.get_parent()
					if parent:
						var fav_btn = CheckButton.new()
						fav_btn.text = "Favorites only"
						fav_btn.name = "SelectFavsButton_select_light"
						if _icon_star:
							fav_btn.icon = _icon_star
						var list_idx = light_il.get_index()
						parent.add_child(fav_btn)
						parent.move_child(fav_btn, list_idx)
						fav_btn.connect("toggled", self, "_on_favs_toggled", ["select_light"])
						if not light_il.is_connected("gui_input", self, "_on_list_gui_input"):
							light_il.connect("gui_input", self, "_on_list_gui_input", ["select_light"])
						_panels["select_light"] = {
							"lib_panel": parent,
							"item_list": light_il,
							"fav_btn": fav_btn,
							"type": 6,
							"in_favs": false,
							"last_count": -1,
							"dd_list_count": -1
						}
						print("[Favorites] Toggle injected in SelectTool: select_light (", light_il.get_item_count(), " items)")
	
	# Don't set _select_panels_injected = true since panels appear/disappear dynamically

func _collect_item_lists(node: Node, result: Array, depth: int, max_depth: int = 6):
	if depth > max_depth:
		return
	if node is ItemList:
		result.append(node)
	for i in range(node.get_child_count()):
		var c = node.get_child(i)
		if is_instance_valid(c):
			_collect_item_lists(c, result, depth + 1, max_depth)

func _find_wall_item_list():
	var tools = _g.Editor.get("Tools")
	if not tools or not tools is Dictionary:
		return null
	var wall_tool = tools.get("WallTool")
	if not wall_tool or not is_instance_valid(wall_tool):
		return null
	
	var ep = wall_tool.get("EditPoints")
	if not ep or not is_instance_valid(ep):
		return null
	
	var container = ep.get_parent()
	if not container:
		return null
	
	var result = _find_item_list_in(container, 0)
	if result:
		return result
	
	var gp = container.get_parent()
	if gp:
		result = _find_item_list_in(gp, 0)
	return result

func _find_item_list_in(node: Node, depth: int):
	if depth > 4:
		return null
	if node is ItemList:
		return node
	for i in range(node.get_child_count()):
		var c = node.get_child(i)
		if is_instance_valid(c):
			var r = _find_item_list_in(c, depth + 1)
			if r:
				return r
	return null

func _inject_wall_panel(wall_list: ItemList):
	var tools = _g.Editor.get("Tools")
	if not tools or not tools is Dictionary:
		return
	var wall_tool = tools.get("WallTool")
	if not wall_tool or not is_instance_valid(wall_tool):
		return
	
	var ep = wall_tool.get("EditPoints")
	if not ep or not is_instance_valid(ep):
		return
	
	var parent = ep.get_parent()
	if not parent:
		return
	
	var fav_btn = CheckButton.new()
	fav_btn.text = "Favorites only"
	fav_btn.name = "WallFavsButton"
	fav_btn.pressed = false
	if _icon_star:
		fav_btn.icon = _icon_star
	
	# Insert after the wall list
	parent.add_child(fav_btn)
	# Place it near the wall list
	var list_idx = wall_list.get_index()
	if wall_list.get_parent() == parent:
		parent.move_child(fav_btn, list_idx)
	
	fav_btn.connect("toggled", self, "_on_favs_toggled", ["wall"])
	
	_panels["wall"] = {
		"lib_panel": parent,
		"item_list": wall_list,
		"fav_btn": fav_btn,
		"type": 1,
		"in_favs": false,
		"last_count": -1,
		"dd_list_count": -1
	}
	
	if not wall_list.is_connected("gui_input", self, "_on_list_gui_input"):
		wall_list.connect("gui_input", self, "_on_list_gui_input", ["wall"])
	
	print("[Favorites] Toggle injected in WallTool panel")


func _find_pattern_menu():
	var tools = _g.Editor.get("Tools")
	if not tools or not tools is Dictionary:
		return null
	var pattern_tool = tools.get("PatternShapeTool")
	if not pattern_tool or not is_instance_valid(pattern_tool):
		return null
	var tex_menu = pattern_tool.get("textureMenu")
	if tex_menu and is_instance_valid(tex_menu) and tex_menu is ItemList:
		return tex_menu
	var ep = pattern_tool.get("EditPoints")
	if not ep or not is_instance_valid(ep):
		return null
	var container = ep.get_parent()
	if not container:
		return null
	var result = _find_item_list_in(container, 0)
	if result:
		return result
	var gp = container.get_parent()
	if gp:
		result = _find_item_list_in(gp, 0)
	return result


func _inject_pattern_panel(pattern_menu):
	var tools = _g.Editor.get("Tools")
	if not tools or not tools is Dictionary:
		return
	var pattern_tool = tools.get("PatternShapeTool")
	if not pattern_tool or not is_instance_valid(pattern_tool):
		return
	var parent = pattern_menu.get_parent()
	if not parent:
		return
	var inject_parent = parent
	if not inject_parent is VBoxContainer:
		var gp = parent.get_parent()
		if gp and gp is VBoxContainer:
			inject_parent = gp
		else:
			inject_parent = parent
	
	var fav_btn = CheckButton.new()
	fav_btn.text = "Favorites only"
	fav_btn.name = "PatternFavsButton"
	fav_btn.pressed = false
	if _icon_star:
		fav_btn.icon = _icon_star
	if pattern_menu.get_parent() == inject_parent:
		var list_idx = pattern_menu.get_index()
		inject_parent.add_child(fav_btn)
		inject_parent.move_child(fav_btn, list_idx)
	else:
		inject_parent.add_child(fav_btn)
		inject_parent.move_child(fav_btn, 0)
	
	fav_btn.connect("toggled", self, "_on_favs_toggled", ["pattern"])
	
	_panels["pattern"] = {
		"lib_panel": inject_parent,
		"item_list": pattern_menu,
		"fav_btn": fav_btn,
		"type": 7,
		"in_favs": false,
		"last_count": -1,
		"dd_list_count": -1
	}
	
	if not pattern_menu.is_connected("gui_input", self, "_on_list_gui_input"):
		pattern_menu.connect("gui_input", self, "_on_list_gui_input", ["pattern"])
	
	print("[Favorites] Toggle injected in PatternShapeTool panel (", pattern_menu.get_item_count(), " items)")


func _find_portal_menu():
	var tools = _g.Editor.get("Tools")
	if not tools or not tools is Dictionary:
		return null
	var portal_tool = tools.get("PortalTool")
	if not portal_tool or not is_instance_valid(portal_tool):
		return null
	var tex_menu = portal_tool.get("textureMenu")
	if tex_menu and is_instance_valid(tex_menu) and tex_menu is ItemList:
		return tex_menu
	return null


func _inject_portal_panel(portal_menu):
	var tools = _g.Editor.get("Tools")
	if not tools or not tools is Dictionary:
		return
	var parent = portal_menu.get_parent()
	if not parent:
		return
	var inject_parent = parent
	if not inject_parent is VBoxContainer:
		var gp = parent.get_parent()
		if gp and gp is VBoxContainer:
			inject_parent = gp
		else:
			inject_parent = parent
	
	var fav_btn = CheckButton.new()
	fav_btn.text = "Favorites only"
	fav_btn.name = "PortalFavsButton"
	fav_btn.pressed = false
	if _icon_star:
		fav_btn.icon = _icon_star
	if portal_menu.get_parent() == inject_parent:
		var list_idx = portal_menu.get_index()
		inject_parent.add_child(fav_btn)
		inject_parent.move_child(fav_btn, list_idx)
	else:
		inject_parent.add_child(fav_btn)
		inject_parent.move_child(fav_btn, 0)
	
	fav_btn.connect("toggled", self, "_on_favs_toggled", ["portal"])
	
	_panels["portal"] = {
		"lib_panel": inject_parent,
		"item_list": portal_menu,
		"fav_btn": fav_btn,
		"type": 2,
		"in_favs": false,
		"last_count": -1,
		"dd_list_count": -1
	}
	
	if not portal_menu.is_connected("gui_input", self, "_on_list_gui_input"):
		portal_menu.connect("gui_input", self, "_on_list_gui_input", ["portal"])
	
	print("[Favorites] Toggle injected in PortalTool panel (", portal_menu.get_item_count(), " items)")


func _try_inject_roof_panel():
	var tools = _g.Editor.get("Tools")
	if not tools or not tools is Dictionary:
		return
	var roof_tool = tools.get("RoofTool")
	if not roof_tool or not is_instance_valid(roof_tool):
		return
	
	var panel = _g.Editor.Toolset.GetToolPanel("RoofTool")
	if not panel:
		return
	
	# Find the roof texture GridMenu
	var all_lists = []
	_collect_item_lists(panel, all_lists, 0)
	
	var roof_list = null
	for il in all_lists:
		if il.get_item_count() == 0:
			continue
		# Identify by metadata containing "roofs"
		for idx in range(min(il.get_item_count(), 3)):
			var meta = il.get_item_metadata(idx)
			if meta is String and "roofs" in meta:
				roof_list = il
				break
		if roof_list:
			break
	
	if roof_list == null:
		return
	
	var parent = roof_list.get_parent()
	if not parent:
		return
	var inject_parent = parent
	if not inject_parent is VBoxContainer:
		var gp = parent.get_parent()
		if gp and gp is VBoxContainer:
			inject_parent = gp
		else:
			inject_parent = parent
	
	var fav_btn = CheckButton.new()
	fav_btn.text = "Favorites only"
	fav_btn.name = "RoofFavsButton"
	fav_btn.pressed = false
	if _icon_star:
		fav_btn.icon = _icon_star
	if roof_list.get_parent() == inject_parent:
		var list_idx = roof_list.get_index()
		inject_parent.add_child(fav_btn)
		inject_parent.move_child(fav_btn, list_idx)
	else:
		inject_parent.add_child(fav_btn)
		inject_parent.move_child(fav_btn, 0)
	
	fav_btn.connect("toggled", self, "_on_favs_toggled", ["roof"])
	
	_panels["roof"] = {
		"lib_panel": inject_parent,
		"item_list": roof_list,
		"fav_btn": fav_btn,
		"type": 8,
		"in_favs": false,
		"last_count": -1,
		"dd_list_count": -1
	}
	
	if not roof_list.is_connected("gui_input", self, "_on_list_gui_input"):
		roof_list.connect("gui_input", self, "_on_list_gui_input", ["roof"])
	
	print("[Favorites] Toggle injected in RoofTool panel (", roof_list.get_item_count(), " items)")


func _try_inject_terrain_panel():
	if not _g.Editor or not is_instance_valid(_g.Editor):
		return
	
	# Always start from the native DD window read out of the Windows dict —
	# that was the pre-ASO behavior and is proven reliable. Only retarget to
	# ASO's window if (a) ui_util is present AND (b) it returns a DIFFERENT
	# instance (i.e. ASO is actually injecting its own clone). This guards
	# against any false-positive ASO detection misfiring when ASO isn't
	# installed, which would silently break injection for every user.
	var windows = _g.Editor.get("Windows")
	if not windows or not windows is Dictionary:
		_terrain_diag_log("no Windows dict")
		return
	var tw = windows.get("TerrainWindow")
	if not tw or not is_instance_valid(tw):
		_terrain_diag_log("no TerrainWindow in dict (size=" + str(windows.size()) + ")")
		return
	
	var is_aso = false
	if ui_util != null:
		var aso_tw = ui_util.find_aso_terrain_window(_g.Editor)
		if aso_tw != null and is_instance_valid(aso_tw) and aso_tw != tw:
			tw = aso_tw
			is_aso = true
	_terrain_diag_log("picked window: ASO=" + str(is_aso) + " path=" + str(tw.get_path()))
	
	# find_node() in Godot 3 defaults to owned=true, which silently returns
	# null for nodes whose owner wasn't set — the case for DD's native
	# TerrainWindow instantiated from C#. Use the known hard-coded path on
	# native (original behavior, always worked), and fall back to find_node
	# with owned=false on ASO's window where Splitter has been restructured
	# and the hard-coded path no longer resolves.
	var tex_menu = null
	var pack_list = null
	if is_aso:
		tex_menu = tw.find_node("TextureMenu", true, false)
		pack_list = tw.find_node("PackList", true, false)
	else:
		if tw.has_node("Margins/Splitter/TextureMenu"):
			tex_menu = tw.get_node("Margins/Splitter/TextureMenu")
		if tw.has_node("Margins/Splitter/PackList"):
			pack_list = tw.get_node("Margins/Splitter/PackList")
	if not tex_menu or not tex_menu is ItemList:
		_terrain_diag_log("no TextureMenu (ASO=" + str(is_aso) + ", has_margins=" + str(tw.has_node("Margins")) + ", has_splitter=" + str(tw.has_node("Margins/Splitter")) + ", children=" + str(tw.get_child_count()) + ")")
		return
	if not pack_list or not pack_list is ItemList:
		_terrain_diag_log("no PackList (ASO=" + str(is_aso) + ")")
		return
	
	# Populate metadata from Lookup
	_populate_terrain_metadata(tex_menu)
	
	# Create a "★ Favorites" button styled like a pack tab, above the PackList.
	# Find Splitter defensively — native uses hard path, ASO may have same
	# layout but find_node is safer.
	var splitter = null
	if tw.has_node("Margins/Splitter"):
		splitter = tw.get_node("Margins/Splitter")
	else:
		splitter = tw.find_node("Splitter", true, false)
	if not splitter:
		_terrain_diag_log("no Splitter found")
		return
	
	var fav_tab = Button.new()
	fav_tab.name = "TerrainFavTab"
	fav_tab.text = "Favorites"
	fav_tab.toggle_mode = true
	fav_tab.pressed = false
	fav_tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fav_tab.rect_min_size = Vector2(0, 28)
	if _icon_star:
		fav_tab.icon = _icon_star
	_style_terrain_fav_tab(fav_tab, pack_list)
	
	if is_aso:
		# ASO strategy: absolutely do not touch the Margins → Splitter →
		# PackList chain. ASO's TerrainWindowUI.gd does
		# terrainwindow.find_node("PackList") with find_node's default
		# owned=true, which stops at any node whose owner != terrainwindow.
		# Any wrapper we insert (even as a sibling of Margins) can break that
		# lookup if it ends up reparenting nodes whose owner tracking Godot
		# then invalidates. The only guaranteed-safe place is DIRECTLY on
		# the WindowDialog as a sibling of Margins, positioned with anchors
		# so it overlays the top band without changing any layout tree.
		
		# Height reserved for our top bar
		var top_bar_h = 32
		
		# Push Margins down by the bar height so content doesn't clip under
		# our button. Margins is a MarginContainer anchored to the window;
		# increasing its margin_top is the right way to move it down.
		var margins = null
		if tw.has_node("Margins"):
			margins = tw.get_node("Margins")
		if margins == null:
			_terrain_diag_log("no Margins found on ASO window")
			return
		# Save original top margin so we don't double-apply on re-injection
		if not margins.has_meta("fav_original_top"):
			margins.set_meta("fav_original_top", margins.margin_top)
		var orig_top = margins.get_meta("fav_original_top")
		margins.margin_top = orig_top + top_bar_h
		
		# Place fav_tab as a sibling of Margins, directly on the WindowDialog.
		# Full width, fixed height, anchored to the top. No second search bar
		# — we hijack ASO's existing search_lineedit while in favorites mode.
		fav_tab.anchor_left = 0
		fav_tab.anchor_right = 1.0
		fav_tab.anchor_top = 0
		fav_tab.anchor_bottom = 0
		fav_tab.margin_left = 8
		fav_tab.margin_right = -8
		fav_tab.margin_top = 4
		fav_tab.margin_bottom = 4 + top_bar_h
		fav_tab.size_flags_horizontal = 0
		fav_tab.rect_min_size = Vector2(0, top_bar_h - 8)
		tw.add_child(fav_tab)
	else:
		# Native DD strategy (unchanged): wrap PackList in a VBox and stack
		# fav_tab on top of it. Works reliably on native because nothing
		# external does find_node("PackList") with owned=true.
		var pack_parent = pack_list.get_parent()
		if not pack_parent:
			return
		var vbox = VBoxContainer.new()
		vbox.name = "FavTerrainPackVBox"
		vbox.size_flags_horizontal = pack_list.size_flags_horizontal
		vbox.size_flags_vertical = pack_list.size_flags_vertical
		vbox.size_flags_stretch_ratio = pack_list.size_flags_stretch_ratio
		vbox.rect_min_size = pack_list.rect_min_size
		var pack_idx = pack_list.get_index()
		pack_parent.remove_child(pack_list)
		pack_parent.add_child(vbox)
		pack_parent.move_child(vbox, pack_idx)
		vbox.add_child(fav_tab)
		vbox.add_child(pack_list)
		pack_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	fav_tab.connect("toggled", self, "_on_terrain_fav_tab_toggled")
	
	# Hook pack_list selection to exit favs mode
	if not pack_list.is_connected("item_selected", self, "_on_terrain_pack_selected"):
		pack_list.connect("item_selected", self, "_on_terrain_pack_selected")
	
	# Register as terrain panel (type 9) — fav_btn = fav_tab
	_panels["terrain"] = {
		"lib_panel": tw,
		"item_list": tex_menu,
		"pack_list": pack_list,
		"fav_btn": fav_tab,
		"type": 9,
		"in_favs": false,
		"last_count": -1,
		"dd_list_count": -1,
		"terrain_window": tw,
		"is_aso": is_aso  # True when hosting window is ASO's custom one
	}
	
	if not tex_menu.is_connected("gui_input", self, "_on_list_gui_input"):
		tex_menu.connect("gui_input", self, "_on_list_gui_input", ["terrain"])
	
	print("[Favorites] Favorites tab injected in TerrainWindow (", tex_menu.get_item_count(), " textures, ", pack_list.get_item_count(), " packs", ", ASO=", is_aso, ")")


func _style_terrain_fav_tab(btn: Button, pack_list: ItemList):
	# Try to match pack_list theme
	var sb = pack_list.get_stylebox("bg")
	if sb and sb is StyleBoxFlat:
		var normal = sb.duplicate()
		normal.bg_color = Color(0.22, 0.22, 0.25, 1.0)
		normal.set_border_width_all(1)
		normal.border_color = Color(0.4, 0.4, 0.4, 0.6)
		normal.content_margin_left = 8
		normal.content_margin_right = 8
		normal.content_margin_top = 4
		normal.content_margin_bottom = 4
		btn.add_stylebox_override("normal", normal)
		
		var pressed = normal.duplicate()
		pressed.bg_color = Color(0.35, 0.35, 0.1, 1.0)
		pressed.border_color = Color(0.8, 0.7, 0.2, 0.8)
		btn.add_stylebox_override("pressed", pressed)
		
		var hover = normal.duplicate()
		hover.bg_color = Color(0.28, 0.28, 0.3, 1.0)
		hover.border_color = Color(0.5, 0.5, 0.5, 0.7)
		btn.add_stylebox_override("hover", hover)
	else:
		# Fallback: just create from scratch
		var normal = StyleBoxFlat.new()
		normal.bg_color = Color(0.22, 0.22, 0.25, 1.0)
		normal.set_border_width_all(1)
		normal.border_color = Color(0.4, 0.4, 0.4, 0.6)
		normal.content_margin_left = 8
		normal.content_margin_right = 8
		normal.content_margin_top = 4
		normal.content_margin_bottom = 4
		btn.add_stylebox_override("normal", normal)
		
		var pressed = normal.duplicate()
		pressed.bg_color = Color(0.35, 0.35, 0.1, 1.0)
		pressed.border_color = Color(0.8, 0.7, 0.2, 0.8)
		btn.add_stylebox_override("pressed", pressed)
		
		var hover = normal.duplicate()
		hover.bg_color = Color(0.28, 0.28, 0.3, 1.0)
		hover.border_color = Color(0.5, 0.5, 0.5, 0.7)
		btn.add_stylebox_override("hover", hover)
	
	# Copy font from pack_list if available
	var font = pack_list.get_font("font")
	if font:
		btn.add_font_override("font", font)


func _on_terrain_fav_tab_toggled(pressed: bool):
	if not _panels.has("terrain"):
		return
	var panel = _panels["terrain"]
	if pressed:
		var tex_menu = panel["item_list"]
		if is_instance_valid(tex_menu):
			_populate_terrain_metadata(tex_menu)
		# Deselect pack list to show we're in favorites.
		var pack_list = panel.get("pack_list")
		if pack_list and is_instance_valid(pack_list):
			pack_list.set_block_signals(true)
			for i in range(pack_list.get_item_count()):
				pack_list.unselect(i)
			pack_list.set_block_signals(false)
		_show_favs_for_panel("terrain")
		# Take over ASO's search bar. Co-existing with ASO's own text_changed
		# handler doesn't work — ASO's handler repopulates TextureMenu from
		# ALL packs (150 items) even when packlist is deselected, wiping our
		# filtered favorites overlay. Disconnect it while in favs mode and
		# stash the connection so we can restore it on exit.
		var aso_search = _find_aso_search_lineedit(panel.get("terrain_window"))
		if aso_search and is_instance_valid(aso_search):
			var saved = []
			for c in aso_search.get_signal_connection_list("text_changed"):
				var tgt = c.get("target")
				var mth = c.get("method")
				if tgt == self and mth == "_on_fav_terrain_search_changed":
					continue  # ours (shouldn't exist yet but skip just in case)
				aso_search.disconnect("text_changed", tgt, mth)
				saved.append({"target": tgt, "method": mth})
			panel["aso_search_saved_conns"] = saved
			if not aso_search.is_connected("text_changed", self, "_on_fav_terrain_search_changed"):
				aso_search.connect("text_changed", self, "_on_fav_terrain_search_changed")
			# Apply existing search text as an initial filter
			if aso_search.text != "":
				_filter_terrain_favs(aso_search.text)
	else:
		# Restore ASO's handler and remove ours.
		var aso_search2 = _find_aso_search_lineedit(panel.get("terrain_window"))
		if aso_search2 and is_instance_valid(aso_search2):
			if aso_search2.is_connected("text_changed", self, "_on_fav_terrain_search_changed"):
				aso_search2.disconnect("text_changed", self, "_on_fav_terrain_search_changed")
			var saved2 = panel.get("aso_search_saved_conns", [])
			for c in saved2:
				var tgt = c.get("target")
				var mth = c.get("method")
				if tgt != null and is_instance_valid(tgt):
					if not aso_search2.is_connected("text_changed", tgt, mth):
						aso_search2.connect("text_changed", tgt, mth)
			panel.erase("aso_search_saved_conns")
		_restore_dd_list_for_panel("terrain")


# Called when user types in ASO's search bar while we're in favorites mode.
# Does nothing if we somehow lost favs state between connect and callback.
func _on_fav_terrain_search_changed(text: String):
	if not _panels.has("terrain"):
		return
	var panel = _panels["terrain"]
	if not panel.get("in_favs", false):
		return
	_filter_terrain_favs(text)


# Rebuild the favorites overlay (TextureMenu) to only show items whose name
# or path contains the query (case-insensitive). Leaves non-fav items out;
# this is the "favorites" view with an additional text filter on top.
# Rebuild the favorites overlay (overlay_list ItemList) to only show items
# whose name or path contains the query (case-insensitive). Leaves non-fav
# items out; this is the "favorites" view with an additional text filter.
# Operates on panel["overlay_list"] (the visible ItemList) — NOT
# panel["item_list"] (the hidden DD TextureMenu).
func _filter_terrain_favs(query: String):
	if not _panels.has("terrain"):
		return
	var panel = _panels["terrain"]
	if not panel.get("in_favs", false):
		return
	var overlay = panel.get("overlay_list")
	if not is_instance_valid(overlay):
		return
	var all_items = panel.get("terrain_all_items", {})
	if all_items.size() == 0:
		return
	
	# Build favorites sets from _favorites (same pattern as _show_favs_for_panel)
	var fav_terrain_paths = {}
	var fav_base_names = {}
	for fav_path in _favorites:
		var info = _favorites[fav_path]
		if not info is Dictionary:
			continue
		var ft = int(info.get("type", 4))
		if ft == 9:
			fav_terrain_paths[fav_path] = true
		if ft == 9 or ft == 7:
			var base = fav_path.get_file().get_basename()
			for prefix in ["terrain_", "tileset_"]:
				if base.begins_with(prefix):
					base = base.substr(prefix.length())
					break
			fav_base_names[base] = true
	
	var q = query.to_lower().strip_edges()
	
	overlay.clear()
	var terrain_fav_paths = []
	var terrain_fav_packs = []
	var fav_map = []
	var added_paths = {}
	for res_path in all_items:
		if added_paths.has(res_path):
			continue
		var is_fav = fav_terrain_paths.has(res_path)
		if not is_fav:
			var base = res_path.get_file().get_basename()
			for prefix in ["terrain_", "tileset_"]:
				if base.begins_with(prefix):
					base = base.substr(prefix.length())
					break
			if fav_base_names.has(base):
				is_fav = true
		if not is_fav:
			continue
		var it = all_items[res_path]
		# Query filter (substring match on name and path)
		if q != "":
			var name_lc = it["name"].to_lower()
			var path_lc = res_path.to_lower()
			if not (q in name_lc or q in path_lc):
				continue
		var fi = overlay.get_item_count()
		overlay.add_item(it["name"], it["icon"], true)
		overlay.set_item_metadata(fi, res_path)
		if it.get("tooltip", "") != "":
			overlay.set_item_tooltip(fi, it["tooltip"])
		terrain_fav_paths.append(res_path)
		terrain_fav_packs.append(it.get("pack_idx", 0))
		fav_map.append(it.get("item_idx", 0))
		added_paths[res_path] = true
	panel["fav_to_dd_index"] = fav_map
	panel["terrain_fav_paths"] = terrain_fav_paths
	panel["terrain_fav_packs"] = terrain_fav_packs


func _on_terrain_pack_selected(_index: int):
	# Ignore during pack scanning
	if _terrain_scanning:
		return
	# User clicked a real pack — exit favorites mode
	if not _panels.has("terrain"):
		return
	var panel = _panels["terrain"]
	var fav_tab = panel["fav_btn"]
	if fav_tab and is_instance_valid(fav_tab) and fav_tab.pressed:
		# Disconnect signal temporarily to avoid re-triggering
		fav_tab.set_block_signals(true)
		fav_tab.pressed = false
		fav_tab.set_block_signals(false)
		_restore_dd_list_for_panel("terrain")


func _populate_terrain_metadata(tex_menu, force := false):
	# Always re-populate from Lookup — DD may rebuild the list at any time
	var lookup = tex_menu.get("Lookup")
	if not lookup or not lookup is Dictionary:
		return
	# Skip if already populated for this item_count (unless force=true, needed
	# during the terrain pack-cycling scan where item_count can coincide across
	# packs but contents differ).
	var iid = tex_menu.get_instance_id()
	var cur_count = tex_menu.get_item_count()
	if not force and _terrain_meta_populated_counts.get(iid, -1) == cur_count and cur_count > 0:
		return
	for path in lookup:
		var idx = lookup[path]
		if idx is int and idx >= 0 and idx < cur_count:
			tex_menu.set_item_metadata(idx, path)
	_terrain_meta_populated_counts[iid] = cur_count


# Locate ASO's search LineEdit within its custom TerrainWindow. ASO puts
# exactly one LineEdit in a search_hbox that wraps the TextureMenu inside
# Splitter. Native DD's TerrainWindow has no LineEdit at all, so a simple
# "first LineEdit descendant" search is safe — returns null on native.
func _find_aso_search_lineedit(tw):
	if tw == null or not is_instance_valid(tw):
		return null
	return _find_first_lineedit(tw)


func _find_first_lineedit(node):
	if not is_instance_valid(node):
		return null
	if node is LineEdit:
		return node
	for child in node.get_children():
		var r = _find_first_lineedit(child)
		if r != null:
			return r
	return null


# Deduped diagnostic log for terrain window injection failures. Same message
# fires at most once — enough to confirm why injection is stuck without
# flooding the console (update loop polls every 30 frames).
var _terrain_diag_last_msg = ""
func _terrain_diag_log(msg: String) -> void:
	if msg == _terrain_diag_last_msg:
		return
	_terrain_diag_last_msg = msg
	print("[Favorites] TerrainWindow injection skipped: ", msg)


func _try_inject_terrain_aso_panel() -> void:
	# ASO has TWO surfaces where users browse terrains:
	#  1. The popup window ASOTerrainWindow (handled in _try_inject_terrain_aso_popup)
	#  2. A grid that ASO injects into the TerrainBrush tool panel on the right
	# This function handles surface #2: the right-side panel grid.
	if not _g.Editor or not is_instance_valid(_g.Editor): return
	var toolset = _g.Editor.get("Toolset")
	if not toolset or not is_instance_valid(toolset): return
	var tp = toolset.GetToolPanel("TerrainBrush")
	if not tp or not is_instance_valid(tp): return
	# Find an ItemList with terrain texture metadata (added by ASO)
	var terrain_list = null
	var all_lists = []
	_collect_item_lists(tp, all_lists, 0)
	for il in all_lists:
		if il.get_item_count() == 0: continue
		# Check for terrain metadata
		for idx in range(min(il.get_item_count(), 3)):
			var m = il.get_item_metadata(idx)
			if m is String and "terrain" in m:
				terrain_list = il
				break
		# Also check via Lookup
		if terrain_list == null:
			var lk = il.get("Lookup")
			if lk is Dictionary and lk.size() > 0:
				var first_key = lk.keys()[0]
				if first_key is String and "terrain" in first_key:
					terrain_list = il
		if terrain_list != null: break
	if terrain_list == null: return
	# Populate metadata
	_populate_metadata_from_lookup(terrain_list)
	var parent = terrain_list.get_parent()
	if not parent: return
	var inject_parent = parent
	if not inject_parent is VBoxContainer:
		var gp = parent.get_parent()
		if gp and gp is VBoxContainer: inject_parent = gp
	# Avoid double-injection if the button is already there
	var fav_btn = null
	for child in inject_parent.get_children():
		if child is CheckButton and child.name == "TerrainASOFavsButton":
			fav_btn = child
			break
	if fav_btn == null:
		fav_btn = CheckButton.new()
		fav_btn.text = "Favorites only"
		fav_btn.name = "TerrainASOFavsButton"
		fav_btn.pressed = false
		if _icon_star: fav_btn.icon = _icon_star
		if terrain_list.get_parent() == inject_parent:
			var list_idx = terrain_list.get_index()
			inject_parent.add_child(fav_btn)
			inject_parent.move_child(fav_btn, list_idx)
		else:
			inject_parent.add_child(fav_btn)
			inject_parent.move_child(fav_btn, 0)
		fav_btn.connect("toggled", self, "_on_favs_toggled", ["terrain_aso"])
	_panels["terrain_aso"] = {
		"lib_panel": inject_parent,
		"item_list": terrain_list,
		"fav_btn": fav_btn,
		"type": 9,
		"in_favs": false,
		"last_count": -1,
		"dd_list_count": -1
	}
	if not terrain_list.is_connected("gui_input", self, "_on_list_gui_input"):
		terrain_list.connect("gui_input", self, "_on_list_gui_input", ["terrain_aso"])
	print("[Favorites] Toggle injected in ASO TerrainBrush right panel (", terrain_list.get_item_count(), " items)")


func _try_inject_terrain_aso_popup() -> void:
	# Inject fav-only button DIRECTLY into the ASO TerrainWindow popup
	# (named "ASOTerrainWindow"), placed in the ASO_VBox right above the
	# TextureMenu ItemList. This is registered as panel "terrain_aso_popup"
	# (distinct from "terrain_aso" which is the right-side panel grid).
	if not _g.Editor or not is_instance_valid(_g.Editor): return
	# Find the ASO popup window
	var aso_win = null
	if ui_util != null and ui_util.has_method("find_aso_terrain_window"):
		aso_win = ui_util.find_aso_terrain_window(_g.Editor)
	if aso_win == null:
		# Fallback: scan Windows for any node named "ASOTerrainWindow"
		var windows_node = _g.Editor.get_child("Windows") if _g.Editor.has_method("get_child") else null
		if windows_node != null and is_instance_valid(windows_node):
			for child in windows_node.get_children():
				if child.name == "ASOTerrainWindow":
					aso_win = child
					break
	if aso_win == null or not is_instance_valid(aso_win):
		return
	# Inside the popup, find ASO_VBox + TextureMenu (ItemList)
	var aso_vbox = aso_win.find_node("ASO_VBox", true, false)
	if aso_vbox == null or not is_instance_valid(aso_vbox):
		return
	var terrain_list = aso_win.find_node("TextureMenu", true, false)
	if terrain_list == null or not is_instance_valid(terrain_list):
		# fallback: any ItemList inside the vbox
		for child in aso_vbox.get_children():
			if child is ItemList:
				terrain_list = child
				break
	if terrain_list == null or not is_instance_valid(terrain_list):
		return
	# Avoid re-injecting the button if it's already there
	var fav_btn = null
	for child in aso_vbox.get_children():
		if child is CheckButton and child.name == "TerrainASOPopupFavsButton":
			fav_btn = child
			break
	if fav_btn == null:
		fav_btn = CheckButton.new()
		fav_btn.text = "Favorites only"
		fav_btn.name = "TerrainASOPopupFavsButton"
		fav_btn.pressed = false
		if _icon_star: fav_btn.icon = _icon_star
		aso_vbox.add_child(fav_btn)
		var menu_idx = terrain_list.get_index() if terrain_list.get_parent() == aso_vbox else aso_vbox.get_child_count() - 1
		aso_vbox.move_child(fav_btn, menu_idx)
		fav_btn.connect("toggled", self, "_on_favs_toggled", ["terrain_aso_popup"])
	_populate_metadata_from_lookup(terrain_list)
	_panels["terrain_aso_popup"] = {
		"lib_panel": aso_vbox,
		"item_list": terrain_list,
		"fav_btn": fav_btn,
		"type": 9,
		"in_favs": false,
		"last_count": -1,
		"dd_list_count": -1
	}
	if not terrain_list.is_connected("gui_input", self, "_on_list_gui_input"):
		terrain_list.connect("gui_input", self, "_on_list_gui_input", ["terrain_aso_popup"])
	print("[Favorites] Toggle injected in ASO TerrainWindow popup (", terrain_list.get_item_count(), " items)")


func _find_align_vbox(node: Node, depth: int):
	if depth > 4:
		return null
	for child in node.get_children():
		if child is VBoxContainer and child.name == "Align":
			return child
		var result = _find_align_vbox(child, depth + 1)
		if result != null:
			return result
	return null


func _try_inject_floor_panel():
	var tools = _g.Editor.get("Tools")
	if not tools or not tools is Dictionary:
		return
	var fst = tools.get("FloorShapeTool")
	if not fst or not is_instance_valid(fst):
		return
	
	var panel = _g.Editor.Toolset.GetToolPanel("FloorShapeTool")
	if not panel:
		return
	
	# Find ALL ItemLists in the panel
	var all_lists = []
	_collect_item_lists(panel, all_lists, 0)
	
	var wall_list = null
	var tileset_list = null
	
	# First pass: identify by metadata
	for il in all_lists:
		if il.get_item_count() == 0:
			continue
		for idx in range(min(il.get_item_count(), 5)):
			var meta = il.get_item_metadata(idx)
			if meta is String:
				if "walls" in meta and wall_list == null:
					wall_list = il
					break
				elif ("tilesets" in meta or "patterns" in meta) and tileset_list == null:
					tileset_list = il
					break
	
	# Second pass: the floor tile list has NULL metadata — it's the large
	# unidentified list.  Populate its metadata from TileMap.GetUsedTileTextures().
	if tileset_list == null:
		for il in all_lists:
			if il == wall_list or il.get_item_count() == 0:
				continue
			# Check if metadata is all null
			var has_real_meta = false
			for idx in range(min(il.get_item_count(), 3)):
				var m = il.get_item_metadata(idx)
				if m is String and m != "":
					has_real_meta = true
					break
			if has_real_meta:
				continue
			
			# This is likely the floor tile list — populate metadata
			var tile_textures = null
			if _g.World and _g.World.Level:
				var tilemap = _g.World.Level.get("TileMap")
				if tilemap:
					tile_textures = tilemap.call("GetUsedTileTextures")
			
			if tile_textures and tile_textures is Dictionary and tile_textures.size() == il.get_item_count():
				var populated = 0
				for tile_id in tile_textures:
					if tile_id is int and tile_id >= 0 and tile_id < il.get_item_count():
						var tex = tile_textures[tile_id]
						if tex is Texture and tex.resource_path != "":
							il.set_item_metadata(tile_id, tex.resource_path)
							populated += 1
				if populated > 0:
					tileset_list = il
					print("[Favorites] Populated ", populated, "/", il.get_item_count(), " floor tile metadata from TileMap")
			break
	
	if wall_list == null and tileset_list == null:
		return
	
	# Find inject parent (VBoxContainer named "Align") — search recursively
	# because ResizeLeftPanel may have wrapped Align in an intermediate HBoxContainer.
	var inject_parent = _find_align_vbox(panel, 0)
	if inject_parent == null:
		inject_parent = panel
	
	# Create one shared button
	var fav_btn = CheckButton.new()
	fav_btn.text = "Favorites only"
	fav_btn.name = "FloorFavsButton"
	fav_btn.pressed = false
	if _icon_star:
		fav_btn.icon = _icon_star
	
	# Insert button above the label that precedes the floor tileset list
	var first_list = tileset_list if tileset_list else wall_list
	var btn_index = 0
	if first_list.get_parent() == inject_parent:
		btn_index = first_list.get_index()
		# Walk backwards past Labels/HBoxContainers to find the section start
		while btn_index > 0:
			var prev = inject_parent.get_child(btn_index - 1)
			if prev is Label or prev is HBoxContainer:
				btn_index -= 1
			else:
				break
	inject_parent.add_child(fav_btn)
	inject_parent.move_child(fav_btn, btn_index)
	
	fav_btn.connect("toggled", self, "_on_favs_toggled", ["floor"])
	
	# Register wall sub-panel
	if wall_list:
		_panels["floor_wall"] = {
			"lib_panel": inject_parent,
			"item_list": wall_list,
			"fav_btn": fav_btn,
			"type": 1,
			"in_favs": false,
			"last_count": -1,
			"dd_list_count": -1
		}
		if not wall_list.is_connected("gui_input", self, "_on_list_gui_input"):
			wall_list.connect("gui_input", self, "_on_list_gui_input", ["floor_wall"])
	
	# Register tileset sub-panel
	if tileset_list:
		_panels["floor_pattern"] = {
			"lib_panel": inject_parent,
			"item_list": tileset_list,
			"fav_btn": fav_btn,
			"type": 7,
			"in_favs": false,
			"last_count": -1,
			"dd_list_count": -1
		}
		if not tileset_list.is_connected("gui_input", self, "_on_list_gui_input"):
			tileset_list.connect("gui_input", self, "_on_list_gui_input", ["floor_pattern"])
	
	var parts = []
	if wall_list:
		parts.append(str(wall_list.get_item_count()) + " walls")
	if tileset_list:
		parts.append(str(tileset_list.get_item_count()) + " tilesets")
	print("[Favorites] Toggle injected in FloorShapeTool panel (", PoolStringArray(parts).join(", "), ")")


func _populate_floor_tile_metadata(item_list):
	# Check if metadata already populated
	for idx in range(min(item_list.get_item_count(), 3)):
		var m = item_list.get_item_metadata(idx)
		if m is String and m != "":
			return  # already populated
	
	if not _g.World or not _g.World.Level:
		return
	var tilemap = _g.World.Level.get("TileMap")
	if not tilemap:
		return
	var tile_textures = tilemap.call("GetUsedTileTextures")
	if not tile_textures or not tile_textures is Dictionary:
		return
	if tile_textures.size() != item_list.get_item_count():
		return
	
	for tile_id in tile_textures:
		if tile_id is int and tile_id >= 0 and tile_id < item_list.get_item_count():
			var tex = tile_textures[tile_id]
			if tex is Texture and tex.resource_path != "":
				item_list.set_item_metadata(tile_id, tex.resource_path)

func _try_inject_tab():
	if not _g.Editor or not is_instance_valid(_g.Editor):
		return
	
	var injected_count = 0
	
	# Inject into ObjectLibraryPanel
	if not _panels.has("object"):
		var ok = _inject_into_panel("ObjectLibraryPanel", "ObjectsMenu", "object", 4)
		if ok:
			injected_count += 1
	else:
		injected_count += 1
	
	# Inject into PathLibraryPanel
	if not _panels.has("path"):
		var ok = _inject_into_panel("PathLibraryPanel", "PathsMenu", "path", 5)
		if ok:
			injected_count += 1
	else:
		injected_count += 1
	
	# Inject into Wall panel (left side, inside MapWizard)
	if not _panels.has("wall"):
		var wall_list = _find_wall_item_list()
		if wall_list:
			_inject_wall_panel(wall_list)
			injected_count += 1
	else:
		injected_count += 1
	
	# Inject into PatternShapeTool panel
	if not _panels.has("pattern"):
		var pattern_menu = _find_pattern_menu()
		if pattern_menu:
			_inject_pattern_panel(pattern_menu)
			injected_count += 1
	else:
		injected_count += 1
	
	# Inject into FloorShapeTool panel (one button for walls + patterns)
	if not _panels.has("floor_wall"):
		_try_inject_floor_panel()
		if _panels.has("floor_wall"):
			injected_count += 1
	else:
		injected_count += 1
	
	# Inject into PortalTool panel
	if not _panels.has("portal"):
		var portal_menu = _find_portal_menu()
		if portal_menu:
			_inject_portal_panel(portal_menu)
			injected_count += 1
	else:
		injected_count += 1
	
	# Inject into RoofTool panel
	if not _panels.has("roof"):
		_try_inject_roof_panel()
		if _panels.has("roof"):
			injected_count += 1
	else:
		injected_count += 1
	
	# Inject into TerrainWindow
	if not _panels.has("terrain"):
		_try_inject_terrain_panel()
		if _panels.has("terrain"):
			injected_count += 1
	else:
		injected_count += 1
	
	# Inject into CaveBrush panel
	if not _panels.has("cave"):
		_try_inject_cave_panel()
		if _panels.has("cave"):
			injected_count += 1
	else:
		injected_count += 1
	
	# Inject into MaterialBrush panel
	if not _panels.has("material"):
		var mat_menu = _find_tool_texture_menu("MaterialBrush")
		if mat_menu:
			_inject_tool_panel(mat_menu, "material", 11, "MaterialBrush")
			injected_count += 1
	else:
		injected_count += 1
	
	if injected_count >= 1:
		_tab_injected = true


func _inject_into_panel(panel_name: String, menu_name: String, key: String, fav_type: int) -> bool:
	var lib_panel = _g.Editor.get(panel_name)
	if lib_panel == null:
		return false
	
	# Find VAlign
	var valign = _find_node_by_name(lib_panel, "VAlign")
	if valign == null:
		# Try direct children that are VBoxContainer
		for i in range(lib_panel.get_child_count()):
			var child = lib_panel.get_child(i)
			if child is VBoxContainer:
				valign = child
				break
		# Try one level deeper (MarginContainer > VBoxContainer)
		if valign == null:
			for i in range(lib_panel.get_child_count()):
				var child = lib_panel.get_child(i)
				for j in range(child.get_child_count()):
					var grandchild = child.get_child(j)
					if grandchild is VBoxContainer:
						valign = grandchild
						break
				if valign:
					break
	if valign == null:
		print("[Favorites] Could not find VAlign in ", panel_name)
		return false
	
	# Find button bar (Align HBoxContainer) — may not exist (e.g. PathLibraryPanel)
	var align = _find_node_by_name(lib_panel, "Align")
	
	# Find ItemList — try given name, then search for first ItemList
	var item_list = null
	if menu_name != "":
		item_list = _find_node_by_name(lib_panel, menu_name)
	if item_list == null:
		item_list = _find_node_of_class(lib_panel, "ItemList")
	if item_list == null:
		print("[Favorites] Could not find ItemList in ", panel_name)
		return false
	
	# Get reference button for font (if Align exists)
	var all_btn = null
	if align:
		all_btn = _find_node_by_name(align, "AllButton")
	
	# Create Favs CheckButton
	var fav_btn = CheckButton.new()
	fav_btn.name = "FavsButton"
	fav_btn.text = "Favorites only"
	fav_btn.hint_tooltip = "Show only favorited assets"
	if _icon_star:
		fav_btn.icon = _icon_star
	
	if all_btn and is_instance_valid(all_btn):
		var font = all_btn.get_font("font")
		if font:
			fav_btn.add_font_override("font", font)
		fav_btn.add_color_override("font_color", all_btn.get_color("font_color"))
	
	fav_btn.connect("toggled", self, "_on_favs_toggled", [key])
	
	# Insert into VAlign — before Align if it exists, otherwise before Filters or ItemList
	if align:
		var align_idx = align.get_index()
		valign.add_child(fav_btn)
		valign.move_child(fav_btn, align_idx)
	else:
		# Insert before Filters or before ItemList
		var filters = _find_node_by_name(lib_panel, "Filters")
		if filters:
			var filters_idx = filters.get_index()
			valign.add_child(fav_btn)
			valign.move_child(fav_btn, filters_idx)
		else:
			var list_idx = item_list.get_index()
			valign.add_child(fav_btn)
			valign.move_child(fav_btn, list_idx)
	
	# Hook DD buttons if they exist
	if align:
		if all_btn and is_instance_valid(all_btn):
			all_btn.connect("pressed", self, "_on_other_tab_pressed", [key])
		var used_btn = _find_node_by_name(align, "UsedButton")
		if used_btn and is_instance_valid(used_btn):
			used_btn.connect("pressed", self, "_on_other_tab_pressed", [key])
		var tags_btn = _find_node_by_name(align, "TagsButton")
		if tags_btn and is_instance_valid(tags_btn):
			tags_btn.connect("pressed", self, "_on_other_tab_pressed", [key])
	
	_panels[key] = {
		"lib_panel": lib_panel,
		"item_list": item_list,
		"fav_btn": fav_btn,
		"type": fav_type,
		"in_favs": false,
		"last_count": -1
	}
	
	# Connect right-click on item list for add/remove fav
	if not item_list.is_connected("gui_input", self, "_on_list_gui_input"):
		item_list.connect("gui_input", self, "_on_list_gui_input", [key])
	
	print("[Favorites] Toggle injected in ", panel_name)
	return true
func _on_favs_toggled(pressed: bool, key: String = "object"):
	# "floor" is a composite key: toggle both floor_wall and floor_pattern
	if key == "floor":
		for sub_key in ["floor_wall", "floor_pattern"]:
			if _panels.has(sub_key):
				if pressed:
					_show_favs_for_panel(sub_key)
				else:
					_restore_dd_list_for_panel(sub_key)
		return
	if pressed:
		_show_favs_for_panel(key)
	else:
		_restore_dd_list_for_panel(key)


func _try_inject_light_panel():
	if _panels.has("light"):
		return
	
	# Find the light style ItemList by searching from scene root
	var tree = Engine.get_main_loop()
	if not tree or not tree is SceneTree:
		return
	var root = tree.root
	if root == null:
		return
	
	var light_list = _find_light_style_list(root, 0, 15)
	if light_list == null:
		return
	
	var parent = light_list.get_parent()
	if not parent:
		return
	var inject_parent = parent
	if not inject_parent is VBoxContainer:
		var gp = parent.get_parent()
		if gp and gp is VBoxContainer:
			inject_parent = gp
		else:
			inject_parent = parent
	
	var fav_btn = CheckButton.new()
	fav_btn.text = "Favorites only"
	fav_btn.name = "LightFavsButton"
	fav_btn.pressed = false
	if _icon_star:
		fav_btn.icon = _icon_star
	if light_list.get_parent() == inject_parent:
		var list_idx = light_list.get_index()
		inject_parent.add_child(fav_btn)
		inject_parent.move_child(fav_btn, list_idx)
	else:
		inject_parent.add_child(fav_btn)
		inject_parent.move_child(fav_btn, 0)
	
	fav_btn.connect("toggled", self, "_on_favs_toggled", ["light"])
	
	_panels["light"] = {
		"lib_panel": inject_parent,
		"item_list": light_list,
		"fav_btn": fav_btn,
		"type": 6,
		"in_favs": false,
		"last_count": -1,
		"dd_list_count": -1
	}
	
	if not light_list.is_connected("gui_input", self, "_on_list_gui_input"):
		light_list.connect("gui_input", self, "_on_list_gui_input", ["light"])
	
	print("[Favorites] Toggle injected in LightTool panel (", light_list.get_item_count(), " items)")


func _find_light_style_list(node, depth: int, max_depth: int):
	if depth > max_depth:
		return null
	if node is ItemList and node.get_item_count() >= 2:
		# Check if metadata contains light texture paths
		for i in range(min(node.get_item_count(), 3)):
			var m = node.get_item_metadata(i)
			if m is String and "textures/lights/" in m:
				return node
	for i in range(node.get_child_count()):
		var c = node.get_child(i)
		if is_instance_valid(c):
			var result = _find_light_style_list(c, depth + 1, max_depth)
			if result:
				return result
	return null


func _get_panel_key_for_list(il) -> String:
	for key in _panels:
		if _panels[key].get("item_list") == il:
			return key
	return ""


func _try_inject_cave_panel():
	if _panels.has("cave"):
		return
	
	# CaveBrush has no textureMenu property — find the ItemList via ToolPanel
	var tp = _g.Editor.get("Toolset")
	if not tp or not is_instance_valid(tp) or not tp.has_method("GetToolPanel"):
		return
	var cpanel = tp.GetToolPanel("CaveBrush")
	if not cpanel or not is_instance_valid(cpanel):
		return
	
	# Find the ItemList with cave texture metadata
	var cave_list = _find_cave_item_list(cpanel, 0, 5)
	if not cave_list:
		return
	
	var parent = cave_list.get_parent()
	if not parent:
		return
	var inject_parent = parent
	if not inject_parent is VBoxContainer:
		var gp = parent.get_parent()
		if gp and gp is VBoxContainer:
			inject_parent = gp
		else:
			inject_parent = parent
	
	var fav_btn = CheckButton.new()
	fav_btn.text = "Favorites only"
	fav_btn.name = "CaveFavsButton"
	fav_btn.pressed = false
	if _icon_star:
		fav_btn.icon = _icon_star
	
	if cave_list.get_parent() == inject_parent:
		var list_idx = cave_list.get_index()
		inject_parent.add_child(fav_btn)
		inject_parent.move_child(fav_btn, list_idx)
	else:
		inject_parent.add_child(fav_btn)
	
	fav_btn.connect("toggled", self, "_on_favs_toggled", ["cave"])
	
	_panels["cave"] = {
		"lib_panel": inject_parent,
		"item_list": cave_list,
		"fav_btn": fav_btn,
		"type": 10,
		"in_favs": false,
		"last_count": -1,
		"dd_list_count": -1
	}
	
	if not cave_list.is_connected("gui_input", self, "_on_list_gui_input"):
		cave_list.connect("gui_input", self, "_on_list_gui_input", ["cave"])
	
	print("[Favorites] Toggle injected in CaveBrush panel (", cave_list.get_item_count(), " items)")


func _find_cave_item_list(node, depth: int, max_depth: int):
	if depth > max_depth:
		return null
	if node is ItemList and node.get_item_count() > 0:
		var m = node.get_item_metadata(0)
		if m is String and "caves" in m:
			return node
	for i in range(node.get_child_count()):
		var c = node.get_child(i)
		if is_instance_valid(c):
			var result = _find_cave_item_list(c, depth + 1, max_depth)
			if result:
				return result
	return null


func _find_tool_texture_menu(tool_name: String):
	var tools = _g.Editor.get("Tools")
	if not tools or not tools is Dictionary:
		return null
	var t = tools.get(tool_name)
	if not t or not is_instance_valid(t):
		return null
	var tex_menu = t.get("textureMenu")
	if tex_menu and is_instance_valid(tex_menu) and tex_menu is ItemList:
		return tex_menu
	return null


func _inject_tool_panel(tex_menu, key: String, fav_type: int, tool_name: String):
	if _panels.has(key):
		return
	
	var parent = tex_menu.get_parent()
	if not parent:
		return
	var inject_parent = parent
	if not inject_parent is VBoxContainer:
		var gp = parent.get_parent()
		if gp and gp is VBoxContainer:
			inject_parent = gp
		else:
			inject_parent = parent
	
	var fav_btn = CheckButton.new()
	fav_btn.text = "Favorites only"
	fav_btn.name = key.capitalize() + "FavsButton"
	fav_btn.pressed = false
	if _icon_star:
		fav_btn.icon = _icon_star
	if tex_menu.get_parent() == inject_parent:
		var list_idx = tex_menu.get_index()
		inject_parent.add_child(fav_btn)
		inject_parent.move_child(fav_btn, list_idx)
	else:
		inject_parent.add_child(fav_btn)
		inject_parent.move_child(fav_btn, 0)
	
	fav_btn.connect("toggled", self, "_on_favs_toggled", [key])
	
	_panels[key] = {
		"lib_panel": inject_parent,
		"item_list": tex_menu,
		"fav_btn": fav_btn,
		"type": fav_type,
		"in_favs": false,
		"last_count": -1,
		"dd_list_count": -1
	}
	
	if not tex_menu.is_connected("gui_input", self, "_on_list_gui_input"):
		tex_menu.connect("gui_input", self, "_on_list_gui_input", [key])
	
	print("[Favorites] Toggle injected in ", tool_name, " panel (", tex_menu.get_item_count(), " items)")


func _populate_metadata_from_lookup(item_list) -> void:
	# GridMenu exposes a Lookup dict {res_path: index} - use it to fill metadata
	var lookup = item_list.get("Lookup")
	if not lookup or not lookup is Dictionary: return
	# Skip if already populated for this item_count (metadata persists unless DD rebuilds the list)
	var iid = item_list.get_instance_id()
	var cur_count = item_list.get_item_count()
	if _meta_populated_counts.get(iid, -1) == cur_count and cur_count > 0:
		return
	for path in lookup:
		if not path is String or path == "": continue
		var idx = lookup[path]
		if idx is int and idx >= 0 and idx < cur_count:
			item_list.set_item_metadata(idx, path)
	_meta_populated_counts[iid] = cur_count


func _show_favs_deferred(key: String) -> void:
	yield(_g.World.get_tree(), "idle_frame")
	if not _panels.has(key) or not _is_panel_toggle_on(key): return
	_show_favs_for_panel(key)


func _show_favs_for_panel(key: String):
	if not _panels.has(key):
		return
	var panel = _panels[key]
	var item_list = panel["item_list"]
	if not is_instance_valid(item_list):
		return
	
	# Floor tiles have no native metadata — re-populate from TileMap each time
	if key == "floor_pattern":
		_populate_floor_tile_metadata(item_list)
	
	# Terrain textures have no native metadata — re-populate from Lookup each time
	if key == "terrain":
		_populate_terrain_metadata(item_list)
	
	# NOTE: We used to call _populate_metadata_from_lookup here, but the
	# non-terrain path below now reads directly from DD's Lookup dict, so
	# pre-populating 200k set_item_metadata calls is unnecessary.
	
	var fav_type = panel["type"]
	# Debug: print favs matching this type
	panel["in_favs"] = true
	
	# Migrate colorable flag for any object favs missing it. Runs each time
	# the overlay opens so late-loaded packs get picked up.
	if fav_type == 4:
		# Drop any previously-baked icons so we re-bake from the newly-chosen
		# source-loading strategy each time we enter fav mode. Cheap: 17 or
		# so entries max. Avoids "stuck" icons when the bake logic changes.
		_fav_icon_cache.clear()
		var cset = _get_colorable_set()
		var migrated = 0
		var colorable_count = 0
		var fav_obj_count = 0
		var sample_unmatched = []
		var sample_matched = []
		for fpath in _favorites:
			var finfo = _favorites[fpath]
			if not (finfo is Dictionary): continue
			if int(finfo.get("type", 4)) != 4: continue
			fav_obj_count += 1
			var prev = finfo.get("colorable", null)
			var now = cset.has(fpath)
			if prev != now:
				finfo["colorable"] = now
				migrated += 1
			if now:
				colorable_count += 1
				if sample_matched.size() < 2:
					sample_matched.append(fpath)
			else:
				if sample_unmatched.size() < 3:
					sample_unmatched.append(fpath)
		if migrated > 0:
			_save_favorites()
		print("[Favs] migrate object favs: ", fav_obj_count, " total, ", colorable_count, " colorable, ", migrated, " updated")
		if sample_unmatched.size() > 0:
			print("[Favs] sample unmatched favs: ", sample_unmatched)
		if sample_matched.size() > 0:
			print("[Favs] sample matched favs: ", sample_matched)
		# Show a few paths from the set for comparison
		var set_sample = []
		for p in cset:
			if set_sample.size() >= 3: break
			set_sample.append(p)
		print("[Favs] sample colorable set paths: ", set_sample)
	
	# Create overlay ItemList if not already done
	if not panel.has("overlay_list"):
		var overlay = ItemList.new()
		overlay.name = "FavsOverlay"
		overlay.focus_mode = Control.FOCUS_NONE
		# Match DD list properties
		overlay.rect_min_size = item_list.rect_min_size
		overlay.size_flags_horizontal = item_list.size_flags_horizontal
		overlay.size_flags_vertical = item_list.size_flags_vertical
		overlay.max_columns = item_list.max_columns
		overlay.icon_mode = item_list.icon_mode
		overlay.fixed_icon_size = item_list.fixed_icon_size
		overlay.same_column_width = item_list.same_column_width
		overlay.fixed_column_width = item_list.fixed_column_width
		overlay.select_mode = item_list.select_mode
		overlay.icon_scale = item_list.icon_scale  # match picker scale
		overlay.rect_min_size = Vector2(0, 100)
		# Mirror DD's theme so separators, font colors, and stylebox match.
		# Just copying a few constant overrides isn't enough — separator lines
		# between items come from the ItemList stylebox which lives in theme.
		if item_list.theme != null:
			overlay.theme = item_list.theme
		for c in ["vseparation", "hseparation", "icon_margin"]:
			var v = item_list.get_constant(c)
			if v != 0:
				overlay.add_constant_override(c, v)
		# Also mirror stylebox overrides DD may have set directly on its list
		for sb_name in ["bg", "bg_focus", "selected", "selected_focus", "cursor", "cursor_unfocused"]:
			var sb = item_list.get_stylebox(sb_name) if item_list.has_stylebox_override(sb_name) else null
			if sb != null:
				overlay.add_stylebox_override(sb_name, sb)
		# Mirror guide_color — the line drawn between rows. Default theme
		# uses a gray color, but when the DD shader material is attached the
		# shader paints these lines white (shader ignores modulate in the
		# else branch). Make them transparent to hide.
		overlay.add_color_override("guide_color", Color(0, 0, 0, 0))
		# Insert right after DD's list in the same parent
		var parent = item_list.get_parent()
		var idx = item_list.get_index()
		parent.add_child(overlay)
		parent.move_child(overlay, idx + 1)
		
		# Connect selection signal to forward to DD
		overlay.connect("item_selected", self, "_on_overlay_selected", [key])
		overlay.connect("item_activated", self, "_on_overlay_activated", [key])
		overlay.connect("multi_selected", self, "_on_overlay_multi_selected", [key])
		overlay.connect("gui_input", self, "_on_list_gui_input", [key])
		
		panel["overlay_list"] = overlay
	
	var overlay = panel["overlay_list"]
	overlay.clear()
	# Share DD's shader material on the overlay so the GPU does the tinting
	# in realtime — same as DD's own list. CPU baking was too slow (17 icons
	# re-processed on every color change).
	# This may cause text/separator colors to look different if DD's shader
	# doesn't preserve modulate, but the tradeoff is instant tinting.
	if is_instance_valid(item_list):
		overlay.material = item_list.material
	else:
		overlay.material = null
	
	# === TERRAIN: build overlay from ALL favorites, not just current pack ===
	if key == "terrain":
		var fav_map = []
		var terrain_fav_paths = []  # overlay_index -> res:// path
		var terrain_fav_packs = []  # overlay_index -> pack index in PackList
		var pack_list = panel.get("pack_list")
		
		# Build set of favorited terrain paths and cross-match base names
		var fav_terrain_paths = {}
		var fav_base_names = {}
		for fav_path in _favorites:
			var info = _favorites[fav_path]
			if not info is Dictionary:
				continue
			var ft = int(info.get("type", 4))
			if ft == 9:
				fav_terrain_paths[fav_path] = true
			if ft == 9 or ft == 7:
				var base = fav_path.get_file().get_basename()
				for prefix in ["terrain_", "tileset_"]:
					if base.begins_with(prefix):
						base = base.substr(prefix.length())
						break
				fav_base_names[base] = true
		
		# Scan all packs ONCE and cache results; reuse cache on subsequent calls
		if not panel.has("terrain_all_items") or panel.get("terrain_cache_dirty", true):
			var all_items = {}  # res_path -> { icon, name, tooltip, pack_idx, item_idx }
			
			# ASO hosts its own search LineEdit that filters TextureMenu on the
			# pack_list.item_selected signal via ASO's _on_pack_list_item_selected
			# → _on_new_search_text(search_lineedit.text). If the user had text
			# in it when toggling Favorites on, every scanned pack would be
			# filtered and most assets would silently drop from the scan. Clear
			# it during the scan and restore after.
			var aso_search = null
			var saved_search_text = ""
			if panel.get("is_aso", false):
				aso_search = _find_aso_search_lineedit(panel.get("terrain_window"))
				if aso_search != null and is_instance_valid(aso_search):
					saved_search_text = aso_search.text
					aso_search.set_block_signals(true)
					aso_search.text = ""
					aso_search.set_block_signals(false)
			
			if pack_list and is_instance_valid(pack_list):
				var pack_count = pack_list.get_item_count()
				_terrain_scanning = true
				
				# Block signals so pack selection changes don't fire any handlers
				pack_list.set_block_signals(true)
				
				for pi in range(pack_count):
					pack_list.select(pi)
					# Call DD's handler directly by emitting on the list
					# We need DD to rebuild TextureMenu - emit with signals unblocked on DD side
					pack_list.set_block_signals(false)
					pack_list.emit_signal("item_selected", pi)
					pack_list.set_block_signals(true)
					
					# force=true: pack cycling swaps list contents in-place; same
					# item_count across packs would otherwise trigger a stale-cache skip.
					_populate_terrain_metadata(item_list, true)
					
					for ti in range(item_list.get_item_count()):
						var meta = item_list.get_item_metadata(ti)
						if not meta is String or meta == "":
							continue
						# Exclude assets that belong to our own Favorites pack —
						# otherwise they'd appear a second time in fav-only mode
						# alongside their original-pack counterpart.
						if _is_from_favs_pack(meta):
							continue
						if all_items.has(meta):
							continue
						all_items[meta] = {
							"icon": item_list.get_item_icon(ti),
							"name": item_list.get_item_text(ti),
							"tooltip": item_list.get_item_tooltip(ti),
							"pack_idx": pi,
							"item_idx": ti
						}
				
				pack_list.set_block_signals(false)
				_terrain_scanning = false
				
				# Deselect all packs visually (block signals to prevent handlers)
				pack_list.set_block_signals(true)
				for i in range(pack_list.get_item_count()):
					pack_list.unselect(i)
				pack_list.set_block_signals(false)
			
			# Restore ASO search text (don't re-emit — user toggled favs, they'll
			# get current filter back when they toggle off).
			if aso_search != null and is_instance_valid(aso_search):
				aso_search.set_block_signals(true)
				aso_search.text = saved_search_text
				aso_search.set_block_signals(false)
			
			panel["terrain_all_items"] = all_items
			panel["terrain_cache_dirty"] = false
		
		var all_items = panel["terrain_all_items"]
		
		# Build overlay from cached items matching current favorites
		var added_paths = {}
		for res_path in all_items:
			if added_paths.has(res_path):
				continue
			
			var is_fav = fav_terrain_paths.has(res_path)
			
			if not is_fav:
				var base = res_path.get_file().get_basename()
				for prefix in ["terrain_", "tileset_"]:
					if base.begins_with(prefix):
						base = base.substr(prefix.length())
						break
				if fav_base_names.has(base):
					is_fav = true
			
			if is_fav:
				var it = all_items[res_path]
				var fi = overlay.get_item_count()
				overlay.add_item(it["name"], it["icon"], true)
				overlay.set_item_metadata(fi, res_path)
				if it["tooltip"] != "":
					overlay.set_item_tooltip(fi, it["tooltip"])
				terrain_fav_paths.append(res_path)
				terrain_fav_packs.append(it["pack_idx"])
				fav_map.append(it["item_idx"])
				added_paths[res_path] = true
		
		panel["fav_to_dd_index"] = fav_map
		panel["terrain_fav_paths"] = terrain_fav_paths
		panel["terrain_fav_packs"] = terrain_fav_packs
		panel["dd_list_count"] = item_list.get_item_count()
		
		item_list.visible = false
		overlay.visible = true
		
		var kept = overlay.get_item_count()
		panel["last_count"] = kept
		print("[Favorites] Showing ", kept, " terrain favorites (from ", all_items.size(), " cached textures)")
		return
	
	# === NORMAL (non-terrain) panels ===
	# Use DD's Lookup dict {path: index} to go straight from favorites to list indices.
	# Avoids iterating 200k items to find ~200 favs.
	var fav_map = []  # overlay_index -> dd_index
	var lookup_main = item_list.get("Lookup")
	var lookup_ok = lookup_main is Dictionary and lookup_main.size() > 0
	var dd_count = item_list.get_item_count()
	if lookup_ok:
		# Collect (dd_idx, path) pairs for matching favs, then sort by dd_idx to
		# preserve DD's visual order in the overlay.
		var hits = []
		for fav_path in _favorites:
			var info = _favorites[fav_path]
			if not (info is Dictionary): continue
			if not _types_match(int(info.get("type", 4)), fav_type): continue
			# Defensive: skip any stray Favorites-pack paths that might be in _favorites.
			if _is_from_favs_pack(fav_path): continue
			var fav_idx = lookup_main.get(fav_path)
			if fav_idx == null or not (fav_idx is int): continue
			if fav_idx < 0 or fav_idx >= dd_count: continue
			hits.append([fav_idx, fav_path])
		hits.sort_custom(self, "_sort_hits_by_idx")
		var logged_mod = false
		for h in hits:
			var i = h[0]
			var meta = h[1]
			var fi = overlay.get_item_count()
			var src_icon = item_list.get_item_icon(i)
			var info2 = _favorites.get(meta, {})
			var is_colorable_i = info2 is Dictionary and info2.get("colorable", false)
			var dd_modulate = item_list.get_item_icon_modulate(i)
			if not logged_mod and is_colorable_i:
				logged_mod = true
				print("[Favs] first colorable: ", meta, " dd_item_modulate=", dd_modulate)
			# No CPU bake: we share DD's shader material on the overlay, so the
			# GPU does the tinting exactly like DD does on its own list.
			overlay.add_item(item_list.get_item_text(i), src_icon, true)
			overlay.set_item_metadata(fi, meta)
			if item_list.get_item_tooltip(i) != "":
				overlay.set_item_tooltip(fi, item_list.get_item_tooltip(i))
			if dd_modulate != Color(1, 1, 1, 1):
				overlay.set_item_icon_modulate(fi, dd_modulate)
			fav_map.append(i)
	else:
		# Fallback: no Lookup — iterate items (original O(N) path, for lists we can't optimize)
		var cur_tint2 = _get_dd_tint()
		for i in range(dd_count):
			var meta_raw = item_list.get_item_metadata(i)
			if meta_raw == null: continue
			var meta = str(meta_raw)
			if meta == "" or meta == "Null": continue
			
			var is_fav = false
			if _favorites.has(meta):
				var info = _favorites[meta]
				if info is Dictionary and _types_match(int(info.get("type", 4)), fav_type):
					is_fav = true
			
			if is_fav:
				var fi = overlay.get_item_count()
				var src_icon2 = item_list.get_item_icon(i)
				overlay.add_item(item_list.get_item_text(i), src_icon2, true)
				overlay.set_item_metadata(fi, meta)
				if item_list.get_item_tooltip(i) != "":
					overlay.set_item_tooltip(fi, item_list.get_item_tooltip(i))
				var icon_mod = item_list.get_item_icon_modulate(i)
				if icon_mod != Color(1, 1, 1, 1):
					overlay.set_item_icon_modulate(fi, icon_mod)
				fav_map.append(i)
	
	panel["fav_to_dd_index"] = fav_map
	panel["overlay_all_fav_map"] = fav_map.duplicate()
	panel["dd_list_count"] = dd_count
	# Store all overlay items for search filtering
	var all_items_snap = []
	for i in range(overlay.get_item_count()):
		all_items_snap.append({"name": overlay.get_item_text(i), "icon": overlay.get_item_icon(i), "meta": overlay.get_item_metadata(i), "tooltip": overlay.get_item_tooltip(i)})
	panel["overlay_all_items"] = all_items_snap
	# Hide DD list, show overlay first
	item_list.visible = false
	overlay.visible = true
	# Hook search bar AFTER overlay is visible (prevents premature text_changed)
	var search_edit = _find_search_lineedit(panel["lib_panel"])
	if search_edit != null:
		panel["search_lineedit"] = search_edit
		if not search_edit.is_connected("focus_entered", self, "_on_search_focus_entered"):
			search_edit.connect("focus_entered", self, "_on_search_focus_entered")
		if not search_edit.is_connected("focus_exited", self, "_on_search_focus_exited"):
			search_edit.connect("focus_exited", self, "_on_search_focus_exited")
		# Sync poll baseline so poll doesn't immediately re-filter
		_last_search_text[key] = search_edit.text
	
	var kept = overlay.get_item_count()
	panel["last_count"] = kept
	if key == "object":
		_last_favs_shown_count = kept
	
	print("[Favorites] Showing ", kept, " ", key, " favorites")


func _apply_badges_to_itemlist(target: ItemList, panel: Dictionary, ctrl_key: String) -> void:
	if not is_instance_valid(target): return
	if target.rect_size.x < 1 or target.rect_size.y < 1: return
	# NOTE: We do NOT populate metadata here anymore. With 200k+ items,
	# set_item_metadata() 200k times freezes DD. Instead we use DD's own
	# Lookup dict {path: index} directly to match favorites by path.
	# Signature-based early-out: skip the whole scan when nothing changed since last frame.
	var sig_key = str(target.get_instance_id()) + ":" + ctrl_key
	var scroll_v = 0.0
	var vs = target.get_v_scroll() if target.has_method("get_v_scroll") else null
	if vs != null and is_instance_valid(vs):
		scroll_v = vs.value
	# Scroll-idle gate: if the user is actively scrolling/resizing, hide the
	# badge overlay and skip all work this frame. With huge lists (200k+),
	# this guarantees our mod adds ZERO cost during scroll — any remaining
	# slowness is purely DD/Godot's ItemList rendering.
	var _iid = target.get_instance_id()
	var _state = _scroll_idle_state.get(_iid)
	if _state == null:
		_state = {"last_scroll": -1e9, "last_size_x": -1, "last_size_y": -1, "idle": 0}
		_scroll_idle_state[_iid] = _state
	var _moved = abs(_state["last_scroll"] - scroll_v) > 0.5 \
			or _state["last_size_x"] != int(target.rect_size.x) \
			or _state["last_size_y"] != int(target.rect_size.y)
	_state["last_scroll"] = scroll_v
	_state["last_size_x"] = int(target.rect_size.x)
	_state["last_size_y"] = int(target.rect_size.y)
	if _moved:
		_state["idle"] = 0
		# Hide stale badges and bail. Invalidate sig so next idle visit runs.
		if panel.has(ctrl_key) and is_instance_valid(panel.get(ctrl_key)):
			panel[ctrl_key].visible = false
		_badge_sigs.erase(sig_key)
		return
	_state["idle"] += 1
	# Wait one more idle cycle before doing heavy work — debounces single-pixel
	# scroll jitter from triggering a full refresh.
	if _state["idle"] < 1:
		return
	var cur_sig = [
		target.get_item_count(),
		int(target.rect_size.x),
		int(target.rect_size.y),
		int(scroll_v),
		_fav_version,
		target.max_columns,
		int(target.fixed_icon_size.x),
		int(target.fixed_icon_size.y)
	]
	if _badge_sigs.get(sig_key) == cur_sig:
		if panel.has(ctrl_key) and is_instance_valid(panel.get(ctrl_key)):
			panel[ctrl_key].visible = true
		return
	# Create/reuse a Control child for badge sprites
	if not panel.has(ctrl_key) or not is_instance_valid(panel.get(ctrl_key)):
		var ctrl = Control.new()
		ctrl.name = "BadgeCtrl_" + ctrl_key
		ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		target.add_child(ctrl)
		panel[ctrl_key] = ctrl
		panel[ctrl_key + "_pool"] = []
	var ctrl = panel[ctrl_key]
	ctrl.visible = true
	ctrl.rect_position = Vector2.ZERO
	ctrl.rect_size = target.rect_size
	var icon_size = target.fixed_icon_size
	if icon_size.x <= 0 or icon_size.y <= 0:
		for i in range(min(target.get_item_count(), 5)):
			var ic = target.get_item_icon(i)
			if ic: icon_size = ic.get_size(); break
	if icon_size.x <= 0 or icon_size.y <= 0: icon_size = Vector2(64, 64)
	var is_grid = target.max_columns != 1
	var badge_size = max(int(icon_size.y * (0.13 if is_grid else 0.22)), 8)
	var lw = int(target.rect_size.x)
	var lh = int(target.rect_size.y)
	var fav_type = panel.get("type", 4)
	var is_overlay = (ctrl_key == "overlay_badge")  # all items are favs

	# === Fast path: large lists with a Lookup dict use direct cell math ===
	# Avoids the viewport scan entirely (get_item_at_position is O(N) in Godot 3,
	# so on a 200k list it costs ~200k ops per call). We sample 2-3 points to
	# calibrate cell width/height, then compute fav positions arithmetically.
	# O(|_favorites|) instead of O(viewport_area × N).
	var lookup = target.get("Lookup")
	var positions = []
	var use_fast_path = (not is_overlay) and (lookup is Dictionary) and target.get_item_count() > 0
	if use_fast_path:
		# Sample top-left item (exact mode so we get the true rect boundary)
		var idx_tl = target.get_item_at_position(Vector2(2, 2), true)
		if idx_tl < 0:
			# (2,2) may be in the stylebox margin — try a deeper sample
			idx_tl = target.get_item_at_position(Vector2(int(icon_size.x / 2) + 4, int(icon_size.y / 2) + 4), true)
		if idx_tl < 0:
			# List not laid out yet — record signature and return
			_badge_sigs[sig_key] = cur_sig
			return
		# Derive number of columns
		var cols = 1
		var cell_w = float(lw)
		if is_grid:
			if target.max_columns > 0:
				cols = target.max_columns
			else:
				var idx_tr = target.get_item_at_position(Vector2(max(lw - 2, 4), 2), true)
				if idx_tr < 0:
					idx_tr = target.get_item_at_position(Vector2(max(lw - int(icon_size.x / 2) - 4, 4), int(icon_size.y / 2) + 4), true)
				if idx_tr > idx_tl:
					cols = idx_tr - idx_tl + 1
				elif idx_tr == idx_tl:
					cols = 1
			cell_w = float(lw) / float(cols)
		# Derive cell height by sampling bottom of viewport
		var cell_h = float(icon_size.y) + 20.0  # fallback
		var idx_bl = target.get_item_at_position(Vector2(2, max(lh - 2, 4)), true)
		if idx_bl < 0:
			idx_bl = target.get_item_at_position(Vector2(int(icon_size.x / 2) + 4, max(lh - int(icon_size.y / 2) - 4, 4)), true)
		if idx_bl > idx_tl:
			var rows_v = (idx_bl - idx_tl) / cols + 1
			if rows_v > 0:
				cell_h = float(lh) / float(rows_v)
		# Refine top of row containing idx_tl by walking back a few pixels.
		# Bounded to ~cell_h/4 calls (~12 for typical 50px cells).
		var tl_row_top_y = 2
		var step = 4
		var probe_y = 2 - step
		var max_walk = int(cell_h) + step
		while probe_y > -max_walk:
			var idx_probe = target.get_item_at_position(Vector2(2, probe_y if probe_y >= 0 else 0), true)
			if idx_probe == idx_tl:
				tl_row_top_y = probe_y if probe_y >= 0 else 0
				if probe_y <= 0: break
				probe_y -= step
			else:
				break
		var tl_row = idx_tl / cols
		# Now compute positions for every fav of this type that falls in viewport
		for fav_path in _favorites:
			var info = _favorites[fav_path]
			if not (info is Dictionary): continue
			if not _types_match(int(info.get("type", 4)), fav_type): continue
			if _is_from_favs_pack(fav_path): continue
			var fav_idx = lookup.get(fav_path)
			if fav_idx == null or not (fav_idx is int): continue
			var row = fav_idx / cols
			var col = fav_idx % cols
			var rel_row = row - tl_row
			var y = float(rel_row) * cell_h + float(tl_row_top_y)
			# Viewport visibility (with margin for partial rows)
			if y + cell_h < 0 or y > float(lh): continue
			var x = float(col) * cell_w
			positions.append(Vector2(int(x) + 1, int(y) + 1))
	else:
		# === Original viewport-scan path (overlay or no Lookup) ===
		var step_x = max(int(icon_size.x * 0.8), 30)
		var step_y = max(int(icon_size.y * 0.8), 20)
		var found = {}
		if not is_grid:
			for yp in range(step_y / 2, lh, step_y):
				var idx = target.get_item_at_position(Vector2(lw / 2, yp), true)
				if idx >= 0 and not found.has(idx): found[idx] = Vector2(lw / 2, yp)
		else:
			for yp in range(step_y / 2, lh, step_y):
				for xp in range(step_x / 2, lw, step_x):
					var idx = target.get_item_at_position(Vector2(xp, yp), true)
					if idx >= 0 and not found.has(idx): found[idx] = Vector2(xp, yp)
		var fav_idx_set = {}
		if is_overlay:
			for idx in found:
				fav_idx_set[idx] = true
		else:
			# Lookup is None or invalid — fall back to metadata match
			for idx in found:
				var meta = target.get_item_metadata(idx)
				if meta is String and _favorites.has(meta):
					var info2 = _favorites[meta]
					if info2 is Dictionary and _types_match(int(info2.get("type", 4)), fav_type):
						fav_idx_set[idx] = true
		for idx in fav_idx_set:
			var pos = found[idx]
			# Walk back from scan position to find item's true top-left.
			var lx = int(pos.x)
			for x in range(int(pos.x), -1, -4):
				if target.get_item_at_position(Vector2(x, pos.y), true) != idx: break
				lx = x
			var ty = int(pos.y)
			for y in range(int(pos.y), -1, -4):
				if target.get_item_at_position(Vector2(pos.x, y), true) != idx: break
				ty = y
			positions.append(Vector2(lx + 1, ty + 1))
	var pool = panel[ctrl_key + "_pool"]
	for j in range(positions.size(), pool.size()):
		if is_instance_valid(pool[j]): pool[j].visible = false
	var badge_tex = _get_scaled_badge(badge_size)
	for j in range(positions.size()):
		var tr
		if j < pool.size() and is_instance_valid(pool[j]):
			tr = pool[j]
		else:
			tr = TextureRect.new()
			tr.expand = false
			tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
			ctrl.add_child(tr)
			if j < pool.size(): pool[j] = tr
			else: pool.append(tr)
		tr.visible = true
		tr.texture = badge_tex
		tr.rect_position = positions[j]
		tr.rect_size = Vector2(badge_size, badge_size)
	# Record signature so next frame can short-circuit if nothing changed
	_badge_sigs[sig_key] = cur_sig


func _snapshot_full_list(panel: Dictionary, item_list: ItemList) -> void:
	var snap = []
	for i in range(item_list.get_item_count()):
		snap.append({
			"text": item_list.get_item_text(i),
			"icon": item_list.get_item_icon(i),
			"meta": item_list.get_item_metadata(i),
			"tooltip": item_list.get_item_tooltip(i),
			"modulate": item_list.get_item_icon_modulate(i)
		})
	panel["full_list_snapshot"] = snap


func _any_lineedit_has_focus() -> bool:
	# Check all known search LineEdits from panels
	for key in _panels:
		var le = _panels[key].get("search_lineedit")
		if le != null and is_instance_valid(le) and le.has_focus():
			return true
	# Also scan the panel libs directly in case we haven't hooked them yet
	for key in _panels:
		var lib = _panels[key].get("lib_panel")
		if lib == null or not is_instance_valid(lib): continue
		var le = _find_search_lineedit(lib)
		if le != null and is_instance_valid(le) and le.has_focus():
			return true
	return false


func _on_search_focus_entered() -> void:
	_search_has_focus = true
	if _g.Editor: _g.Editor.set("SearchHasFocus", true)


func _on_search_focus_exited() -> void:
	_search_has_focus = false
	if _g.Editor: _g.Editor.set("SearchHasFocus", false)


func _on_fav_search_entered(text: String, key: String) -> void:
	# Enter key pressed in search bar while in favorites mode
	if not _panels.has(key): return
	if not _panels[key].get("in_favs", false): return
	_filter_overlay(key, text)


func _on_fav_search_changed(text: String, key: String) -> void:
	if not _panels.has(key): return
	if not _panels[key].get("in_favs", false): return
	_filter_overlay(key, text)


func _on_overlay_selected(index: int, key: String):
	_forward_overlay_to_dd(index, key)

func _on_overlay_activated(index: int, key: String):
	_forward_overlay_to_dd(index, key)

func _on_overlay_multi_selected(index: int, selected: bool, key: String):
	_forward_overlay_to_dd(index, key)

func _forward_overlay_to_dd(overlay_index: int, key: String):
	if not _panels.has(key):
		return
	var panel = _panels[key]
	var fav_map = panel.get("fav_to_dd_index", [])
	if overlay_index < 0 or overlay_index >= fav_map.size():
		return
	var dd_index = fav_map[overlay_index]
	
	# terrain_aso: ASO GridMenu — use select() + OnItemSelected
	if key == "terrain_aso":
		var item_list_aso = panel["item_list"]
		if not is_instance_valid(item_list_aso): return
		# select() triggers OnItemSelected internally via C# -- block it
		item_list_aso.set_block_signals(true)
		item_list_aso.select(dd_index)
		item_list_aso.set_block_signals(false)
		item_list_aso.emit_signal("item_selected", dd_index)
		return
	
	# Terrain: switch to correct pack and select correct item
	if key == "terrain":
		var terrain_packs = panel.get("terrain_fav_packs", [])
		var terrain_paths = panel.get("terrain_fav_paths", [])
		if overlay_index >= terrain_packs.size():
			return
		var pack_idx = terrain_packs[overlay_index]
		var pack_list = panel.get("pack_list")
		var item_list = panel["item_list"]
		if not is_instance_valid(item_list):
			return
		
		# Switch to the correct pack silently (DD rebuilds TextureMenu)
		if pack_list and is_instance_valid(pack_list):
			_terrain_scanning = true
			pack_list.set_block_signals(true)
			pack_list.select(pack_idx)
			pack_list.set_block_signals(false)
			pack_list.emit_signal("item_selected", pack_idx)
			_terrain_scanning = false
			# force=true: pack swapped in-place
			_populate_terrain_metadata(item_list, true)
			# Deselect packs visually — we're still in favs mode
			pack_list.set_block_signals(true)
			for i in range(pack_list.get_item_count()):
				pack_list.unselect(i)
			pack_list.set_block_signals(false)
		
		# Find the item in the rebuilt TextureMenu by matching metadata
		var target_path = terrain_paths[overlay_index]
		for ti in range(item_list.get_item_count()):
			var meta = item_list.get_item_metadata(ti)
			if meta == target_path:
				item_list.select(ti)
				item_list.emit_signal("item_selected", ti)
				break
		return
	
	var item_list = panel["item_list"]
	if not is_instance_valid(item_list):
		return
	
	var overlay = panel.get("overlay_list")
	if overlay and is_instance_valid(overlay) and overlay.select_mode == ItemList.SELECT_MULTI:
		item_list.unselect_all()
		var selected = overlay.get_selected_items()
		for si in selected:
			if si >= 0 and si < fav_map.size():
				item_list.select(fav_map[si], false)
		# Set ScatterTool.textures directly
		var tools = _g.Editor.get("Tools")
		if tools and tools is Dictionary:
			var st = tools.get("ScatterTool")
			if st and is_instance_valid(st):
				var tex_array = []
				for si in selected:
					if si >= 0 and si < fav_map.size():
						var di = fav_map[si]
						var meta = item_list.get_item_metadata(di)
						if meta is String:
							var tex = ResourceLoader.load(meta)
							if tex and tex is Texture:
								tex_array.append(tex)
				if tex_array.size() > 0:
					st.set("textures", tex_array)
					st.set("texture", tex_array[0])
		# Also emit multi_selected to DD
		item_list.emit_signal("multi_selected", dd_index, true)
	else:
		item_list.select(dd_index)
		item_list.emit_signal("item_selected", dd_index)
		# GridMenu.OnItemSelected sets the tool's Texture — call it explicitly
		if item_list.has_method("OnItemSelected"):
			item_list.OnItemSelected(dd_index)
		# For pattern lists: also sync Texture property directly
		if key in ["pattern", "select_pattern", "floor_pattern"]:
			_sync_pattern_tool_texture(item_list, dd_index)


func _is_panel_toggle_on(key: String) -> bool:
	if not _panels.has(key):
		return false
	var fav_btn = _panels[key]["fav_btn"]
	return fav_btn and is_instance_valid(fav_btn) and fav_btn.pressed


func _sync_pattern_tool_texture(item_list, dd_index: int):
	var meta = item_list.get_item_metadata(dd_index)
	if not meta is String or meta == "":
		return
	var tex = ResourceLoader.load(meta)
	if not tex or not tex is Texture:
		return
	var tools = _g.Editor.get("Tools")
	if not tools or not tools is Dictionary:
		return
	# Sync to whichever pattern tool is relevant
	for tool_name in ["PatternShapeTool", "FloorShapeTool"]:
		var pt = tools.get(tool_name)
		if pt and is_instance_valid(pt):
			pt.set("Texture", tex)


func _is_favs_toggle_on() -> bool:
	return _is_panel_toggle_on("object")


func _on_other_tab_pressed(key: String = "object"):
	if _is_panel_toggle_on(key):
		_favs_reapply_cooldown = 2


func _restore_dd_list_for_panel(key: String):
	if not _panels.has(key):
		return
	var panel = _panels[key]
	var item_list = panel["item_list"]
	
	panel["in_favs"] = false
	panel["last_count"] = -1
	panel.erase("fav_to_dd_index")
	panel.erase("overlay_all_items")
	panel.erase("overlay_all_fav_map")
	_last_search_text.erase(key)
	# Disconnect search filter
	var search_edit = panel.get("search_lineedit")
	if key == "object":
		_last_favs_shown_count = -1
	
	# Show DD list, hide overlay
	if is_instance_valid(item_list):
		item_list.visible = true
	if panel.has("overlay_list") and is_instance_valid(panel["overlay_list"]):
		panel["overlay_list"].visible = false
	
	# Terrain: restore to pack containing the active texture and select it
	if key == "terrain":
		var pack_list = panel.get("pack_list")
		if pack_list and is_instance_valid(pack_list):
			var sel = pack_list.get_selected_items()
			if sel.size() == 0:
				# Find which pack has the last selected texture
				var target_pack = 0
				var target_path = ""
				var all_items = panel.get("terrain_all_items", {})
				var overlay = panel.get("overlay_list")
				if overlay and is_instance_valid(overlay):
					var ov_sel = overlay.get_selected_items()
					if ov_sel.size() > 0:
						var ov_meta = overlay.get_item_metadata(ov_sel[0])
						if ov_meta is String and all_items.has(ov_meta):
							target_pack = all_items[ov_meta].get("pack_idx", 0)
							target_path = ov_meta
				if target_pack >= 0 and target_pack < pack_list.get_item_count():
					pack_list.select(target_pack)
					_terrain_scanning = true
					pack_list.emit_signal("item_selected", target_pack)
					_terrain_scanning = false
				# Re-select the active texture in the rebuilt TextureMenu
				if target_path != "":
					# force=true: pack changed in-place, cache may be stale
					_populate_terrain_metadata(item_list, true)
					for ti in range(item_list.get_item_count()):
						var meta = item_list.get_item_metadata(ti)
						if meta == target_path:
							item_list.select(ti)
							break
		return
	
	# For ObjectLibraryPanel, press AllButton to refresh
	var align = _find_node_by_name(panel["lib_panel"], "Align")
	if align:
		var all_btn = _find_node_by_name(align, "AllButton")
		if all_btn and is_instance_valid(all_btn):
			all_btn.emit_signal("pressed")


func _refresh_active_panels():
	_badged_icons.clear()
	for key in _panels:
		if _is_panel_toggle_on(key):
			_show_favs_for_panel(key)


func _toggle_visible_panel_favs():
	var toggled_btn = null
	for key in _panels:
		var panel = _panels[key]
		var fav_btn = panel["fav_btn"]
		if not fav_btn or not is_instance_valid(fav_btn) or not fav_btn.is_visible_in_tree():
			continue
		# Skip if we already toggled this same button (floor_wall/floor_pattern share one)
		if fav_btn == toggled_btn:
			continue
		var item_list = panel["item_list"]
		var overlay = panel.get("overlay_list")
		var list_visible = is_instance_valid(item_list) and item_list.visible and item_list.is_visible_in_tree()
		var overlay_visible = overlay and is_instance_valid(overlay) and overlay.visible and overlay.is_visible_in_tree()
		if list_visible or overlay_visible:
			fav_btn.pressed = not fav_btn.pressed
			toggled_btn = fav_btn
			return


func _get_or_create_draw_overlay(target: ItemList, fav_type: int, badge_all: bool = false, panel_key: String = ""):
	# Returns the BadgeDrawOverlay Control attached to `target`, creating it
	# on demand. Returns null if the feature is disabled or the script failed
	# to load (caller should fall back to TextureRect path).
	if not USE_DRAW_OVERLAY or _draw_overlay_script == null:
		return null
	var iid = target.get_instance_id()
	# Determine badge position by panel: wall and path tools want top-left,
	# everything else wants top-right.
	var pos = "right"
	if panel_key == "wall" or panel_key == "path" or panel_key == "floor_wall" \
		or panel_key == "select_wall" or panel_key == "select_path":
		pos = "left"
	var badge_sz = _badge_size_value
	var ovl = _draw_overlays.get(iid)
	if ovl != null and is_instance_valid(ovl):
		# Reuse but resetup if anything changed (badge_all, position, fav_type)
		var needs_resetup = (
			ovl.fav_type != fav_type or
			ovl.badge_all_items != badge_all or
			ovl.badge_position != pos
		)
		if needs_resetup:
			ovl.setup(self, target, fav_type, _icon_fav_badge, badge_all, pos, badge_sz)
		return ovl
	# Create new
	var ctrl = Control.new()
	ctrl.set_script(_draw_overlay_script)
	ctrl.name = "FavBadgeDrawOverlay"
	target.add_child(ctrl)
	ctrl.setup(self, target, fav_type, _icon_fav_badge, badge_all, pos, badge_sz)
	_draw_overlays[iid] = ctrl
	return ctrl


func _free_draw_overlay(target: ItemList) -> void:
	if target == null:
		return
	var iid = target.get_instance_id()
	var ovl = _draw_overlays.get(iid)
	if ovl != null and is_instance_valid(ovl):
		ovl.queue_free()
	_draw_overlays.erase(iid)


func _invalidate_all_draw_overlays() -> void:
	# Called whenever favorites set changes — triggers redraw of all overlays
	for iid in _draw_overlays:
		var ovl = _draw_overlays[iid]
		if is_instance_valid(ovl):
			ovl.invalidate()


func _apply_badges_to_dd_lists():
	for key in _panels:
		var panel = _panels[key]
		var item_list = panel["item_list"]
		if not is_instance_valid(item_list):
			continue
		var overlay_list = panel.get("overlay_list")
		# Mirror picker scale (icon_scale) from DD's list to our overlay list.
		# UIScaler picker_scaling_agent scales item_list.icon_scale directly;
		# our overlay isn't registered with the agent, so we sync it manually.
		if overlay_list != null and is_instance_valid(overlay_list):
			if overlay_list.icon_scale != item_list.icon_scale:
				overlay_list.icon_scale = item_list.icon_scale
		var overlay_visible = overlay_list != null and is_instance_valid(overlay_list) and overlay_list.visible and overlay_list.is_visible_in_tree()
		var fav_type_b = panel["type"]
		if not item_list.visible or not item_list.is_visible_in_tree():
			# Hide dd badge overlay when item_list hidden
			if panel.has("badge_overlay") and is_instance_valid(panel.get("badge_overlay")):
				panel["badge_overlay"].visible = false
			# Hide draw-overlay too
			var d_ovl = _draw_overlays.get(item_list.get_instance_id())
			if d_ovl != null and is_instance_valid(d_ovl):
				d_ovl.visible = false
			# Apply badges to overlay_list if it's visible (favorites mode).
			# Use the same BadgeDrawOverlay system as the main DD list for
			# visual consistency between Fav Only and normal modes.
			if overlay_visible:
				# badge_all=true: every item in the Fav Only list IS a favorite,
				# so badge all visible items (no Lookup needed)
				var ovl_draw = _get_or_create_draw_overlay(overlay_list, fav_type_b, true, key)
				if ovl_draw != null:
					# Hide legacy TextureRect overlay badge — superseded by draw overlay
					if panel.has("overlay_badge") and is_instance_valid(panel.get("overlay_badge")):
						panel["overlay_badge"].visible = false
					ovl_draw.visible = true
					ovl_draw.poll_redraw()
				else:
					# Fallback if draw_overlay not available
					_apply_badges_to_itemlist(overlay_list, panel, "overlay_badge")
			else:
				if panel.has("overlay_badge") and is_instance_valid(panel.get("overlay_badge")):
					panel["overlay_badge"].visible = false
				# Hide overlay_list's draw_overlay too if it exists
				if overlay_list != null and is_instance_valid(overlay_list):
					var ovl_draw_h = _draw_overlays.get(overlay_list.get_instance_id())
					if ovl_draw_h != null and is_instance_valid(ovl_draw_h):
						ovl_draw_h.visible = false
			continue
		# Main DD list is visible — hide overlay badges
		if panel.has("overlay_badge") and is_instance_valid(panel.get("overlay_badge")):
			panel["overlay_badge"].visible = false
		# Hide overlay_list's draw_overlay if it exists
		if overlay_list != null and is_instance_valid(overlay_list):
			var ovl_draw_h2 = _draw_overlays.get(overlay_list.get_instance_id())
			if ovl_draw_h2 != null and is_instance_valid(ovl_draw_h2):
				ovl_draw_h2.visible = false
		if item_list.rect_size.x < 1 or item_list.rect_size.y < 1:
			continue
		
		# Floor tiles need metadata re-populated (DD doesn't set it natively)
		if key == "floor_pattern":
			_populate_floor_tile_metadata(item_list)
		elif key == "terrain":
			_populate_terrain_metadata(item_list)
		
		var fav_type = panel["type"]
		
		# Prefer native draw_texture_rect overlay when available (pixel-perfect,
		# scroll-locked, ~free CPU). Falls back to TextureRect viewport-scan
		# otherwise.
		var draw_ovl = _get_or_create_draw_overlay(item_list, fav_type, false, key)
		if draw_ovl != null:
			# Hide the old TextureRect badge overlay (might be left over from
			# a previous frame before draw_overlay was active)
			if panel.has("badge_overlay") and is_instance_valid(panel.get("badge_overlay")):
				panel["badge_overlay"].visible = false
			draw_ovl.visible = true
			draw_ovl.poll_redraw()
		else:
			# Apply badges to DD item_list using shared helper (fallback)
			_apply_badges_to_itemlist(item_list, panel, "badge_overlay")

func _get_scaled_badge(size: int) -> Texture:
	if _badge_tex_cache.has(size):
		return _badge_tex_cache[size]
	if _icon_fav_badge_img == null:
		return _icon_fav_badge
	var scaled = _icon_fav_badge_img.duplicate()
	scaled.resize(size, size, Image.INTERPOLATE_LANCZOS)
	var tex = ImageTexture.new()
	tex.create_from_image(scaled, ImageTexture.FLAG_FILTER)
	_badge_tex_cache[size] = tex
	return tex


var _list_ctx_menu = null
var _list_ctx_metas = []  # list of metadata strings for selected items
var _list_ctx_type = 4

func _on_list_gui_input(event: InputEvent, key: String):
	if not event is InputEventMouseButton:
		return
	if not event.pressed or event.button_index != BUTTON_RIGHT:
		return
	
	if not _panels.has(key):
		return
	var panel = _panels[key]
	var fav_type = panel["type"]
	
	# Re-populate metadata for lists that lose it (floor tiles, terrain)
	if key == "floor_pattern":
		_populate_floor_tile_metadata(panel["item_list"])
	elif key == "terrain":
		_populate_terrain_metadata(panel["item_list"])
	
	# Determine which list received the click
	var item_list = panel["item_list"]
	var overlay = panel.get("overlay_list")
	var click_list = item_list
	if panel.get("in_favs", false) and overlay and is_instance_valid(overlay) and overlay.visible:
		click_list = overlay
	
	# Find item under cursor
	var local_pos = event.position
	var idx = click_list.get_item_at_position(local_pos, true)
	if idx < 0:
		return
	
	# Gather metadata: use item under cursor as primary target
	var metas = []
	var clicked_meta = click_list.get_item_metadata(idx)
	# Lookup fallback: DD may not have populated metadata for this item yet
	# (we no longer pre-populate to avoid the 200k set_item_metadata freeze).
	if (clicked_meta == null or not (clicked_meta is String) or clicked_meta == ""):
		var ck_lookup = click_list.get("Lookup")
		if ck_lookup is Dictionary:
			for p in ck_lookup:
				if ck_lookup[p] == idx:
					clicked_meta = p
					click_list.set_item_metadata(idx, p)
					break
	
	# For multi-select (scatter), include all selected IF clicked item is in the selection
	if click_list.select_mode == ItemList.SELECT_MULTI:
		var selected = click_list.get_selected_items()
		var clicked_in_sel = false
		for si in selected:
			if si == idx:
				clicked_in_sel = true
				break
		if clicked_in_sel and selected.size() > 1:
			var sel_lookup = click_list.get("Lookup")
			for si in selected:
				var m = click_list.get_item_metadata(si)
				if not (m is String) or m == "":
					# Lookup fallback for each selected item
					if sel_lookup is Dictionary:
						for p in sel_lookup:
							if sel_lookup[p] == si:
								m = p
								click_list.set_item_metadata(si, p)
								break
				if m is String and m != "":
					metas.append(m)
	
	# Default: just the clicked item
	if metas.size() == 0:
		if clicked_meta is String and clicked_meta != "":
			metas.append(clicked_meta)
	
	if metas.size() == 0:
		return
	
	_list_ctx_metas = metas
	_list_ctx_type = fav_type
	
	# Check fav status of selection
	var all_fav = true
	var any_fav = false
	for m in metas:
		if _favorites.has(m):
			any_fav = true
		else:
			all_fav = false
	
	# Create popup menu
	if _list_ctx_menu and is_instance_valid(_list_ctx_menu):
		_list_ctx_menu.queue_free()
	
	_list_ctx_menu = PopupMenu.new()
	_get_popup_layer().add_child(_list_ctx_menu)
	
	var count_str = " (" + str(metas.size()) + ")" if metas.size() > 1 else ""
	
	if not all_fav:
		_list_ctx_menu.add_item("Add to Favorites" + count_str, 0)
		if _icon_star:
			_list_ctx_menu.set_item_icon(0, _icon_star)
	if any_fav:
		_list_ctx_menu.add_item("Remove from Favorites" + count_str, 1)
		var rem_idx = _list_ctx_menu.get_item_index(1)
		if _icon_unstar:
			_list_ctx_menu.set_item_icon(rem_idx, _icon_unstar)
	
	_list_ctx_menu.connect("id_pressed", self, "_on_list_ctx_pressed")
	_list_ctx_menu.popup(Rect2(click_list.rect_global_position + local_pos, Vector2(1, 1)))


func _on_list_ctx_pressed(id: int):
	if _list_ctx_metas.size() == 0:
		return
	
	# Block all add/remove while the Favorites pack is loaded — DD holds
	# the .dungeondraft_pack open and rewriting it would crash DD.
	if _pack_enabled() and _is_favs_pack_loaded():
		_show_pack_loaded_popup()
		_list_ctx_metas = []
		return
	
	if id == 1:
		# Remove all
		var removed_count = 0
		for meta in _list_ctx_metas:
			if _favorites.has(meta):
				var info = _favorites[meta]
				if info is Dictionary and info.has("pack_path"):
					_fav_cache.erase(info["pack_path"])
				_favorites.erase(meta)
				_badged_icons.erase(meta)
				removed_count += 1
		_badge_tex_cache.clear()
		if removed_count > 0:
			_bump_fav_version()
			_save_favorites()
			# Rebuild the .dungeondraft_pack so the removed asset actually
			# disappears from the Favorites pack (not just the UI).
			if _favorites.size() > 0:
				_rebuild_or_defer()
			else:
				var dir = Directory.new()
				if _pack_path != "" and dir.file_exists(_pack_path):
					dir.remove(_pack_path)
				_refresh_active_panels()
		else:
			_refresh_active_panels()
		print("[Favorites] Removed ", _list_ctx_metas.size(), " from list")
	elif id == 0:
		# Add all
		var added_count = 0
		for meta in _list_ctx_metas:
			if _favorites.has(meta):
				continue
			var fname = meta.get_file()
			# Roofs: metadata is res://textures/roofs/style_name/tiles.png
			# Need to preserve the directory (style_name/tiles.png)
			if _list_ctx_type == 8 and "/roofs/" in meta:
				var roof_rel = meta.split("/roofs/")
				if roof_rel.size() > 1:
					fname = roof_rel[1]  # e.g. "diamond_slate_gray/tiles.png"
			var pack_path = _get_pack_path_for(_list_ctx_type, fname)
			# Only objects can carry the "Colorable" tag in DD.
			var is_colorable = false
			if _list_ctx_type == 4:
				var cset = _get_colorable_set()
				is_colorable = cset.has(meta)
				print("[Favs] add: ", meta, " colorable=", is_colorable, " (set size=", cset.size(), ")")
			_favorites[meta] = {
				"pack_path": pack_path,
				"type": _list_ctx_type,
				"color": "ffffff",
				"colorable": is_colorable
			}
			added_count += 1
		if added_count > 0:
			_bump_fav_version()
			_save_favorites()
			_rebuild_or_defer()
		print("[Favorites] Added ", added_count, " from list (", _list_ctx_metas.size(), " attempted)")
	
	_list_ctx_metas = []


func _find_search_lineedit(lib_panel: Node):
	if lib_panel == null: return null
	for child in lib_panel.get_children():
		var r = _find_lineedit_recursive(child, 0)
		if r != null: return r
	return null


func _find_lineedit_recursive(node: Node, depth: int):
	if depth > 6: return null
	if node is LineEdit: return node
	for child in node.get_children():
		if not is_instance_valid(child): continue
		var r = _find_lineedit_recursive(child, depth + 1)
		if r != null: return r
	return null


func _filter_overlay(key: String, text: String) -> void:
	if not _panels.has(key): return
	var panel = _panels[key]
	var overlay = panel.get("overlay_list")
	if not is_instance_valid(overlay): return
	var all_items = panel.get("overlay_all_items", [])
	if all_items.size() == 0: return
	print("[Favs] _filter_overlay clearing overlay for key=", key, " text='", text, "' all_items=", all_items.size())
	overlay.clear()
	var fav_map = []
	var all_fav_map = panel.get("overlay_all_fav_map", [])
	var q = text.to_lower().strip_edges()
	for i in range(all_items.size()):
		var it = all_items[i]
		if q == "" or q in it["name"].to_lower() or q in it.get("tooltip", "").to_lower():
			var fi = overlay.get_item_count()
			overlay.add_item(it["name"], it["icon"], true)
			overlay.set_item_metadata(fi, it["meta"])
			if it.get("tooltip", "") != "":
				overlay.set_item_tooltip(fi, it["tooltip"])
			if i < all_fav_map.size():
				fav_map.append(all_fav_map[i])
	panel["fav_to_dd_index"] = fav_map


func _find_node_by_name(root: Node, node_name: String):
	if not is_instance_valid(root):
		return null
	if root.name == node_name:
		return root
	for i in range(root.get_child_count()):
		var child = root.get_child(i)
		if not is_instance_valid(child):
			continue
		var found = _find_node_by_name(child, node_name)
		if found:
			return found
	return null


func _find_node_of_class(root: Node, cls: String):
	if not is_instance_valid(root):
		return null
	if root.get_class() == cls:
		return root
	# Also check by is keyword
	if cls == "TabContainer" and root is TabContainer:
		return root
	for i in range(root.get_child_count()):
		var child = root.get_child(i)
		if not is_instance_valid(child):
			continue
		var found = _find_node_of_class(child, cls)
		if found:
			return found
	return null


# Retourne true si l'option "Create Custom Pack from Favorites" est ON
# (ou si mod_settings est introuvable -> fail-open). Lu via le mod_settings
# expose par Main.gd dans _g.ModMapData["_mod_settings"].
func _pack_enabled() -> bool:
	if _g == null:
		return true
	var md = _g.get("ModMapData")
	if md is Dictionary and md.has("_mod_settings"):
		var ms = md["_mod_settings"]
		if ms != null and is_instance_valid(ms) and ms.has_method("is_enabled"):
			return ms.is_enabled("create_pack_from_favorites")
	return true


func _rebuild_or_defer():
	# Respecte le reglage "Create Custom Pack from Favorites". Si OFF, on ne
	# (re)construit pas le .dungeondraft_pack : les favoris restent marques
	# visuellement (badges/recolor) mais aucun fichier pack n'est ecrit.
	if not _pack_enabled():
		return
	# If cache is cold (first rebuild), show a wait dialog and defer to next frames
	var uncached = 0
	for src_path in _favorites:
		var info = _favorites[src_path]
		if info is Dictionary:
			var pp = info.get("pack_path", "")
			if pp != "" and not _fav_cache.has(pp):
				uncached += 1
	
	if uncached > 2:
		_show_wait_dialog()
		_pending_rebuild = true
		_pending_rebuild_frame = 0
	else:
		_rebuild_pack()
		_refresh_active_panels()


func _show_wait_dialog():
	if _wait_dialog and is_instance_valid(_wait_dialog):
		_wait_dialog.popup_centered()
		return
	
	_wait_dialog = AcceptDialog.new()
	_wait_dialog.window_title = "Favorites"
	_wait_dialog.dialog_text = ""
	_wait_dialog.get_ok().visible = false
	_wait_dialog.get_label().visible = false
	
	var vbox = VBoxContainer.new()
	vbox.alignment = VBoxContainer.ALIGN_CENTER
	vbox.rect_min_size = Vector2(350, 0)
	
	var line1 = Label.new()
	line1.text = "Building favorites cache, please wait a few seconds..."
	line1.align = Label.ALIGN_CENTER
	vbox.add_child(line1)
	
	var line2 = Label.new()
	line2.text = "(needed only once per active map)"
	line2.align = Label.ALIGN_CENTER
	line2.modulate = Color(0.7, 0.7, 0.7)
	vbox.add_child(line2)
	
	_wait_dialog.add_child(vbox)
	
	var layer = _get_popup_layer()
	if layer:
		layer.add_child(_wait_dialog)
	else:
		var tree = Engine.get_main_loop()
		if tree and tree is SceneTree and tree.root:
			tree.root.add_child(_wait_dialog)
	
	_wait_dialog.popup_centered()


func _hide_wait_dialog():
	if _wait_dialog and is_instance_valid(_wait_dialog):
		_wait_dialog.hide()


func _rebuild_pack() -> bool:
	if _custom_dir == "" or _pack_path == "":
		return false
	
	# Collect texture data
	var tex_data = {}  # {pack_path: PoolByteArray}
	var wall_data = []  # [{name, pack_path, color}] for .dungeondraft_wall files
	var missing = []
	
	for src_path in _favorites:
		var info = _favorites[src_path]
		if not info is Dictionary:
			missing.append(src_path)
			continue
		# Purge any stale self-referential entries from older sessions.
		if _is_from_favs_pack(src_path):
			missing.append(src_path)
			continue
		var pack_path = info["pack_path"]
		var type = int(info.get("type", 4))
		var color = info.get("color", "ffffff")
		
		if _fav_cache.has(pack_path):
			tex_data[pack_path] = _fav_cache[pack_path]
		else:
			var result = _read_texture_data(src_path)
			if result.size() > 0 and result.has("data"):
				tex_data[pack_path] = result["data"]
				_fav_cache[pack_path] = result["data"]
			else:
				missing.append(src_path)
				continue
		
		# Wall types need .dungeondraft_wall data files
		if type == 1:
			wall_data.append({
				"name": pack_path.get_file().get_basename(),
				"pack_path": pack_path,
				"color": color
			})
	
	for m in missing:
		_favorites.erase(m)
		_fav_cache.erase(m)
	if missing.size() > 0:
		_bump_fav_version()
		_save_favorites()
	
	if tex_data.size() == 0:
		return false
	
	var pack_json = JSON.print({
		"name": "Favorite Assets",
		"id": _pack_id, "version": "1",
		"author": "Unofficial Patch", "keywords": "",
		"allow_3rd_party_mapping_software_to_read": true,
		"custom_color_overrides": {
			"enabled": false, "min_redness": 0.1,
			"min_saturation": 0, "red_tolerance": 0.04
		}
	})
	var pjb = pack_json.to_utf8()
	
	var pck_files = []
	pck_files.append({"path": "res://packs/" + _pack_id + ".json", "data": pjb})
	pck_files.append({"path": "res://packs/" + _pack_id + "/pack.json", "data": pjb})
	
	# Tags — only for objects (other types don't use tags).
	# We tag every object fav with "Favorites Mod" (mod bookkeeping), and
	# additionally with "Colorable" when its source pack flagged it as such.
	# Old _favorites entries may lack the "colorable" field; migrate on the
	# fly using the live colorable set (best effort — works if the source
	# pack is currently loaded).
	var tag_paths = []
	var colorable_paths = []
	var colorable_set = _get_colorable_set()
	var favs_dirty = false
	for src_path in _favorites:
		var finfo = _favorites[src_path]
		if not (finfo is Dictionary): continue
		if int(finfo.get("type", 4)) != 4: continue
		var pp = finfo.get("pack_path", "")
		if pp == "" or not tex_data.has(pp): continue
		if not pp.begins_with("textures/objects/"): continue
		tag_paths.append(pp)
		# Migration: infer colorable for legacy favs that predate the field.
		var colorable = finfo.get("colorable", null)
		if colorable == null:
			colorable = colorable_set.has(src_path)
			finfo["colorable"] = colorable
			favs_dirty = true
		if colorable:
			colorable_paths.append(pp)
	if favs_dirty:
		_save_favorites()
	if tag_paths.size() > 0:
		var tags_data = {"tags": {"Favorites Mod": tag_paths}, "sets": {}}
		if colorable_paths.size() > 0:
			tags_data["tags"]["Colorable"] = colorable_paths
		tags_data["sets"]["Favorites Mod"] = ["Favorites Mod"]
		print("[Favs] rebuild tags: ", tag_paths.size(), " objects (", colorable_paths.size(), " colorable)")
		pck_files.append({"path": "res://packs/" + _pack_id + "/data/default.dungeondraft_tags",
			"data": JSON.print(tags_data, "\t").to_utf8()})
	
	# Wall/Roof data files
	for wd in wall_data:
		var wall_json = JSON.print({
			"path": wd["pack_path"],
			"name": wd["name"],
			"color": wd["color"]
		})
		var data_path = "data/walls/" + wd["name"] + ".dungeondraft_wall"
		pck_files.append({
			"path": "res://packs/" + _pack_id + "/" + data_path,
			"data": wall_json.to_utf8()
		})
	
	# Texture files
	for pack_path in tex_data:
		pck_files.append({
			"path": "res://packs/" + _pack_id + "/" + pack_path,
			"data": tex_data[pack_path]
		})
	
	var ok = _write_pck(_pack_path, pck_files)
	if ok:
		print("[Favorites] Pack rebuilt: ", tex_data.size(), " textures, ", wall_data.size(), " wall defs -> ", _pack_path.get_file())
	return ok


func _write_pck(path: String, files: Array) -> bool:
	var f = File.new()
	if f.open(path, File.WRITE) != OK:
		return false
	f.store_buffer("GDPC".to_ascii())
	f.store_32(1)
	f.store_32(3)
	f.store_32(4)
	f.store_32(2)
	for _i in range(16):
		f.store_32(0)
	f.store_32(files.size())
	
	var entries_size = 0
	for entry in files:
		entries_size += 4 + entry["path"].to_utf8().size() + 8 + 8 + 16
	
	var data_start = 88 + entries_size
	var data_offset = 0
	for entry in files:
		var pb = entry["path"].to_utf8()
		var edata = entry["data"]
		f.store_32(pb.size())
		f.store_buffer(pb)
		f.store_64(data_start + data_offset)
		f.store_64(edata.size())
		f.store_buffer(_compute_md5(edata))
		data_offset += edata.size()
	
	for entry in files:
		f.store_buffer(entry["data"])
	f.close()
	return true


func _compute_md5(data: PoolByteArray) -> PoolByteArray:
	var tmp = "user://UnofficialPatch/Favorites/md5_tmp"
	var f = File.new()
	if f.open(tmp, File.WRITE) == OK:
		f.store_buffer(data)
		f.close()
		var md5_str = f.get_md5(tmp)
		var md5_bytes = PoolByteArray()
		for i in range(0, md5_str.length(), 2):
			md5_bytes.append(("0x" + md5_str.substr(i, 2)).hex_to_int())
		Directory.new().remove(tmp)
		return md5_bytes
	var zeros = PoolByteArray()
	zeros.resize(16)
	return zeros
