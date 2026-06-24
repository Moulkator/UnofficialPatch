extends Control
# FavBadgeOverlay v2 — uses Godot's native ItemList.set_item_tag_icon().
#
# Why this works perfectly:
#   - set_item_tag_icon(idx, texture) attaches a "tag" icon to an ItemList item
#   - Godot's ItemList._draw() renders the tag icon at the correct position
#     for ICON_MODE_TOP (top-left of the thumbnail), automatically — handling
#     cell size, icon_scale, scroll, stretched columns, list mode, all of it.
#   - No calibration. No probing. No position math.
#
# Limitations of Godot's tag_icon:
#   - Always rendered at top-left of the item (in ICON_MODE_TOP).
#   - Rendered at its native texture size (not resized).
# We work around both by preparing per-overlay textures:
#   - For top-right placement: pad the texture on the LEFT with transparent
#     pixels, so the visible badge appears on the right side.
#   - For sizing: pre-resize the base badge texture to the desired size.

const POS_LEFT = "left"
const POS_RIGHT = "right"

var mod = null
var target = null
var fav_type = 4
var badge_tex_base = null  # original badge texture (from mod)
var _prepared_tex = null   # post-processed (resized + optionally padded) texture
var badge_all_items = false
var badge_position = POS_RIGHT
var badge_size_px = 16  # rendered badge size

# Indices we've set a tag_icon on. Maintained so we can clear them when favs change.
var _tagged_indices = {}  # idx -> true

# Detect list changes (filter, repopulate, fav add/remove)
var _last_item_count = -1
var _last_first_icon = null
var _last_first_meta = null
var _last_fav_version = -1
var _last_picker_scale = -1.0  # detect icon_scale changes to rebuild texture

# Defer tag updates a few frames after a fav change to let DD's async pack
# rebuild complete
var _build_defer_frames = 0
var _dirty = false


func _ready():
	mouse_filter = MOUSE_FILTER_IGNORE


func _exit_tree():
	# Clean up any tag icons we set, so they don't persist if our overlay
	# is removed but the ItemList lives on.
	_clear_all_tags()


func setup(p_mod, p_target, p_fav_type, p_badge_tex, p_badge_all = false, p_position = POS_RIGHT, p_size_px = 16):
	mod = p_mod
	target = p_target
	fav_type = p_fav_type
	badge_tex_base = p_badge_tex
	badge_all_items = p_badge_all
	badge_position = p_position
	badge_size_px = p_size_px
	# Clear any existing tags before swapping the texture (else they leak)
	_clear_all_tags()
	_prepared_tex = _prepare_texture()
	_tagged_indices.clear()
	_last_item_count = -1
	_last_first_icon = null
	_last_first_meta = null
	_last_fav_version = -1
	_dirty = true


func _prepare_texture():
	# Build the texture to pass to set_item_tag_icon. For POS_LEFT, just a
	# resized badge. For POS_RIGHT, a padded texture (transparent left, badge
	# right) wide enough that the badge's visible portion lands near the
	# right edge of the thumbnail.
	# Godot does NOT scale the tag_icon by icon_scale (verified empirically),
	# so we apply the picker scale to both the badge size AND the padding
	# width here.
	if badge_tex_base == null:
		return null
	var src_img = badge_tex_base.get_data()
	if src_img == null:
		return badge_tex_base
	# Read picker scale (icon_scale property on the ItemList)
	var picker_scale = 1.0
	if is_instance_valid(target) and "icon_scale" in target:
		picker_scale = target.icon_scale
		if picker_scale <= 0:
			picker_scale = 1.0
	var sz = int(round(float(badge_size_px) * picker_scale))
	if sz < 4:
		sz = 4
	var img = Image.new()
	img.copy_from(src_img)
	img.convert(Image.FORMAT_RGBA8)
	if img.get_width() != sz or img.get_height() != sz:
		img.resize(sz, sz, Image.INTERPOLATE_LANCZOS)
	if badge_position == POS_LEFT:
		var tex = ImageTexture.new()
		tex.create_from_image(img, 0)
		return tex
	# POS_RIGHT: pad the LEFT side with transparent pixels.
	# Effective thumbnail width = fixed_icon_size.x * icon_scale.
	var icon_w = 64
	if is_instance_valid(target):
		var fis = target.fixed_icon_size
		if fis.x > 0:
			icon_w = int(fis.x)
	var effective_icon_w = int(round(float(icon_w) * picker_scale))
	var padded_w = max(effective_icon_w - 2, sz + 1)
	var padded = Image.new()
	padded.create(padded_w, sz, false, Image.FORMAT_RGBA8)
	padded.fill(Color(0, 0, 0, 0))
	padded.blit_rect(img, Rect2(0, 0, sz, sz), Vector2(padded_w - sz, 0))
	var tex2 = ImageTexture.new()
	tex2.create_from_image(padded, 0)
	return tex2


func _clear_all_tags():
	if not is_instance_valid(target):
		_tagged_indices.clear()
		return
	var ic = target.get_item_count()
	for idx in _tagged_indices:
		if idx < ic:
			target.set_item_tag_icon(idx, null)
	_tagged_indices.clear()


func invalidate():
	# Called when favs change. Defer a few frames for DD's pack rebuild.
	_dirty = true
	_build_defer_frames = 3


func invalidate_full():
	invalidate()


func set_badge_size(new_size_px: int) -> void:
	# Allow caller to change the badge size at runtime (e.g. user moved a
	# slider in Preferences). Rebuilds the prepared texture and re-applies
	# tags.
	if new_size_px < 4:
		new_size_px = 4
	if new_size_px == badge_size_px:
		return
	badge_size_px = new_size_px
	_clear_all_tags()
	_prepared_tex = _prepare_texture()
	_dirty = true


var _last_visible = false

var _poll_count = 0
var _last_diag_ms = 0
# Frame counter for periodic tag-presence verification
var _verify_frame = 0
const VERIFY_INTERVAL_FRAMES = 5  # ~80ms at 60fps — fast recovery from DD clearing our tags

func poll_redraw():
	if not is_instance_valid(target):
		return
	_poll_count += 1
	# Detect visibility transition (tool change, fav-only toggle, etc.)
	var is_vis = target.visible and target.is_visible_in_tree()
	if is_vis and not _last_visible:
		_clear_all_tags()
		_dirty = true
	_last_visible = is_vis
	if not is_vis:
		return
	# Detect DD filter/repopulate
	var cur_count = target.get_item_count()
	var cur_first_icon = null
	var cur_first_meta = null
	if cur_count > 0:
		cur_first_icon = target.get_item_icon(0)
		cur_first_meta = target.get_item_metadata(0)
	if cur_count != _last_item_count or cur_first_icon != _last_first_icon or cur_first_meta != _last_first_meta:
		_last_item_count = cur_count
		_last_first_icon = cur_first_icon
		_last_first_meta = cur_first_meta
		_clear_all_tags()
		_dirty = true
	if mod != null and "_fav_version" in mod:
		var fv = mod._fav_version
		if fv != _last_fav_version:
			_last_fav_version = fv
			_dirty = true
			_build_defer_frames = 3
	# Detect picker_scale (icon_scale) change — rebuild the texture so badge
	# size/padding follow.
	var cur_picker_scale = 1.0
	if "icon_scale" in target:
		cur_picker_scale = target.icon_scale
	if cur_picker_scale != _last_picker_scale:
		_last_picker_scale = cur_picker_scale
		_clear_all_tags()
		_prepared_tex = _prepare_texture()
		_dirty = true
	# Periodic verification: DD sometimes clears tag_icons under our feet
	# (e.g. when toggling fav-only) with no detectable count/icon/meta change.
	# Sample one tagged item to check; if its tag is gone, re-apply all.
	_verify_frame += 1
	if _verify_frame >= VERIFY_INTERVAL_FRAMES and _tagged_indices.size() > 0 and not _dirty:
		_verify_frame = 0
		for idx in _tagged_indices:
			if idx < cur_count:
				if target.get_item_tag_icon(idx) == null:
					_tagged_indices.clear()
					_dirty = true
			break  # only check one
	if _build_defer_frames > 0:
		_build_defer_frames -= 1
		return
	if _dirty:
		_apply_tags()
		_dirty = false


func _apply_tags():
	if not is_instance_valid(target) or _prepared_tex == null or mod == null:
		return
	var item_count = target.get_item_count()
	if item_count <= 0:
		_tagged_indices.clear()
		return
	# Build set of indices that SHOULD be tagged
	var should_be_tagged = {}
	if badge_all_items:
		# Every item gets a badge (fav-only overlay list)
		for i in range(item_count):
			should_be_tagged[i] = true
	else:
		var lookup = target.get("Lookup")
		if lookup is Dictionary:
			for fav_path in mod._favorites:
				var info = mod._favorites[fav_path]
				if not (info is Dictionary):
					continue
				if not mod._types_match(int(info.get("type", 4)), fav_type):
					continue
				if mod._is_from_favs_pack(fav_path):
					continue
				var fav_idx = lookup.get(fav_path)
				if not (fav_idx is int):
					continue
				if fav_idx < 0 or fav_idx >= item_count:
					continue
				should_be_tagged[int(fav_idx)] = true
		else:
			# Fallback: scan metadata (for Wall/Path/FloorShape walls)
			var meta_to_idx = {}
			for i in range(item_count):
				var m = target.get_item_metadata(i)
				if m is String and m != "":
					meta_to_idx[m] = i
			for fav_path in mod._favorites:
				var info = mod._favorites[fav_path]
				if not (info is Dictionary):
					continue
				if not mod._types_match(int(info.get("type", 4)), fav_type):
					continue
				if mod._is_from_favs_pack(fav_path):
					continue
				if meta_to_idx.has(fav_path):
					should_be_tagged[int(meta_to_idx[fav_path])] = true
	# Clear tags from indices that should NOT be tagged
	var to_clear = []
	for idx in _tagged_indices:
		if not should_be_tagged.has(idx):
			to_clear.append(idx)
	for idx in to_clear:
		if idx < item_count:
			target.set_item_tag_icon(idx, null)
		_tagged_indices.erase(idx)
	# Set tags on new indices
	for idx in should_be_tagged:
		if not _tagged_indices.has(idx):
			target.set_item_tag_icon(idx, _prepared_tex)
			_tagged_indices[idx] = true


func _draw():
	pass  # intentionally empty - Godot's ItemList draws the tag_icon natively
