# trace_extended.gd
# Extends the Trace Image tool's Scale slider beyond its default bounds
# (0.001 to 50) with adaptive scroll steps.
#
# Also works around a Dungeondraft bug where the trace image is lost
# after the 2nd save+reload cycle.
#
# Additional features:
#   - "Snap Top-Left": snaps trace image top-left to map top-left.
#     While active, scaling anchors from top-left instead of center.
#   - "Precise Scaling": fixed step of 0.001 across entire range.
#   - "Trace Layer": z-index slider to place the trace image behind or
#     between map elements (terrain, walls, roofs, etc.).
#     Hides the standalone "Layered Trace Image" mod's UI if present.

var _g
var ui_util

var _trace_tool       = null
var _scale_ctrl       = null
var _input_listener   = null

var _default_min     := 0.0
var _default_max     := 1.0
var _inited          := false
var _bounds_set      := false
var _signal_connected := false

var _target_value    := -1.0
var _force_until     := 0

var _last_world_ref     = null
var _prev_has_texture  := false
var _needs_restore     := false
var _restore_deadline  := 0
var _restoring         := false

var _pending_position  := false
var _pending_pos_x     := 0.0
var _pending_pos_y     := 0.0
var _pending_opacity   := -1.0

var _image_path := ""

# UI
var _ui_added        := false
var _snap_btn        = null
var _fit_ratio_btn   = null
var _fit_stretch_btn = null
var _precise_toggle  = null
var _grid_spinbox    = null
var _grid_match_btn  = null
var _unlock_ratio_toggle = null
var _width_row       = null
var _height_row      = null
var _width_slider    = null
var _height_slider   = null
var _width_spinbox   = null
var _height_spinbox  = null
var _precise_scaling := false
var _anchor_top_left := false
var _stretched       := false   # true when non-uniform scale is active
var _stretch_scale_x := 1.0    # stored stretch scale X
var _stretch_scale_y := 1.0    # stored stretch scale Y

# Layer (z-index)
var _layer_slider    = null
var _layer_spinbox   = null
var _layer_z         := 900    # default: on top of everything (above Roofs@800)
var _syncing_layer   := false
const DEFAULT_LAYER_Z := 900

# Rotation
var _rotation_slider  = null
var _rotation_spinbox = null
var _rotation_deg    := 0.0    # degrees, 0 = no rotation
var _syncing_rotation := false

# Blur (textureLod on mipmapped texture copy)
var _blur_slider     = null
var _blur_spinbox    = null
var _blur_amount     := 0.0    # 0 = no blur, maps to mipmap LOD level
var _syncing_blur    := false
var _blur_material   = null    # ShaderMaterial (combined blur + blend FX)
var _blur_original_texture = null  # original texture before mipmap swap
var _blur_mipmap_texture   = null  # our ImageTexture copy with mipmaps

# Blend mode (composites the trace image against what's drawn below it)
var _blend_option    = null
var _blend_mode      := 0      # index into BLEND_MODE_NAMES; 0 = Normal
var _syncing_blend   := false

# Combined FX shader: blur (mipmap textureLod 9-tap) + blend mode against
# the background (SCREEN_TEXTURE). A canvas item can only carry one material,
# so blur and blend modes share a single shader. blend_mode 0 = Normal (no
# screen read), otherwise the foreground is composited against what was drawn
# below the trace image (respecting the Layer/z-index).
const BLUR_SHADER_CODE = """
shader_type canvas_item;
render_mode blend_mix;

uniform float blur : hint_range(0.0, 12.0) = 0.0;
uniform int blend_mode = 0;

float _lum(vec3 c) { return dot(c, vec3(0.3, 0.59, 0.11)); }

vec3 _clip_color(vec3 c) {
	float l = _lum(c);
	float n = min(min(c.r, c.g), c.b);
	float x = max(max(c.r, c.g), c.b);
	if (n < 0.0) c = l + (c - l) * (l / (l - n));
	if (x > 1.0) c = l + (c - l) * ((1.0 - l) / (x - l));
	return c;
}

vec3 _set_lum(vec3 c, float l) { return _clip_color(c + (l - _lum(c))); }

vec3 _blend(int m, vec3 b, vec3 s) {
	if (m == 1) return b * s;                                   // Multiply
	if (m == 2) return b + s - b * s;                           // Screen
	if (m == 3) return mix(2.0 * b * s, 1.0 - 2.0 * (1.0 - b) * (1.0 - s), step(0.5, b)); // Overlay
	if (m == 4) return min(b, s);                               // Darken
	if (m == 5) return max(b, s);                               // Lighten / Brighten
	if (m == 6) return min(b + s, vec3(1.0));                   // Add (Linear Dodge)
	if (m == 7) return abs(b - s);                              // Difference
	if (m == 8) return mix(2.0 * b * s + b * b * (1.0 - 2.0 * s), 2.0 * b * (1.0 - s) + sqrt(b) * (2.0 * s - 1.0), step(0.5, s)); // Soft Light
	if (m == 9) return mix(1.0 - 2.0 * (1.0 - b) * (1.0 - s), 2.0 * b * s, step(0.5, s)); // Hard Light
	if (m == 10) return min(vec3(1.0), b / max(vec3(1.0) - s, vec3(1e-4)));              // Color Dodge
	if (m == 11) return vec3(1.0) - min(vec3(1.0), (vec3(1.0) - b) / max(s, vec3(1e-4))); // Color Burn
	if (m == 12) return _set_lum(b, _lum(s));                   // Luminosity
	return s;                                                   // Normal
}

void fragment() {
	vec4 fg;
	if (blur > 0.0) {
		// Half-texel offset at current mip level for sub-texel smoothing
		vec2 ps = TEXTURE_PIXEL_SIZE * exp2(blur) * 0.5;
		vec4 col = textureLod(TEXTURE, UV, blur) * 4.0;
		col += textureLod(TEXTURE, UV + vec2( ps.x, 0.0), blur) * 2.0;
		col += textureLod(TEXTURE, UV + vec2(-ps.x, 0.0), blur) * 2.0;
		col += textureLod(TEXTURE, UV + vec2(0.0,  ps.y), blur) * 2.0;
		col += textureLod(TEXTURE, UV + vec2(0.0, -ps.y), blur) * 2.0;
		col += textureLod(TEXTURE, UV + vec2( ps.x,  ps.y), blur) * 1.0;
		col += textureLod(TEXTURE, UV + vec2(-ps.x, -ps.y), blur) * 1.0;
		col += textureLod(TEXTURE, UV + vec2( ps.x, -ps.y), blur) * 1.0;
		col += textureLod(TEXTURE, UV + vec2(-ps.x,  ps.y), blur) * 1.0;
		col /= 16.0;
		fg = col;
	} else {
		fg = texture(TEXTURE, UV);
	}
	if (blend_mode == 0) {
		COLOR = fg * COLOR;
	} else {
		// Tint (modulate.rgb) is folded into the foreground before blending;
		// opacity (modulate.a) scales the composite alpha.
		vec3 bg = texture(SCREEN_TEXTURE, SCREEN_UV).rgb;
		vec3 res = _blend(blend_mode, bg, fg.rgb * COLOR.rgb);
		COLOR = vec4(res, fg.a * COLOR.a);
	}
}
"""

# Blend mode dropdown labels — index must match the shader's blend_mode int.
const BLEND_MODE_NAMES := [
	"Normal", "Multiply", "Screen", "Overlay", "Darken",
	"Lighten", "Add", "Difference", "Soft Light", "Hard Light",
	"Color Dodge", "Color Burn", "Luminosity",
]

# Track the top-left corner position when anchor mode is active
var _anchored_top_left := Vector2.ZERO
# Track previous scale to compute top-left correctly
var _prev_scale      := -1.0
# Track expected position to detect user drag
var _expected_pos    := Vector2.ZERO

const EXTENDED_MIN      := 0.001
const EXTENDED_MAX      := 50.0
const FORCE_DURATION_MS := 200
const RESTORE_FORCE_MS  := 10
const RESTORE_TIMEOUT   := 10
const SAVE_KEY          := "_trace_extended"

# Undo bookkeeping. We snapshot the trace state when a slider drag
# starts (or before a button-driven action) and register a callback
# record on DD's history when the action completes. One record per
# user gesture: a slider drag = 1 record, a button click = 1 record.
# _drag_snapshot is set when a drag opens and consumed when it closes.
# _drag_slider tracks which slider currently owns the drag (to avoid
# treating a stray gui_input from another node as the same gesture).
var _drag_snapshot = null
var _drag_slider = null
# When applying state from undo/redo, suppress recording new history
# (otherwise the apply itself would push another record).
var _applying_undo := false


func initialize() -> void:
	_install_input_listener()


func _install_input_listener() -> void:
	var script = GDScript.new()
	script.source_code = """extends Node
var handler = null
func _ready():
	set_process_input(true)
	set_process_unhandled_input(true)
	process_priority = -200
func _input(event) -> void:
	if handler != null:
		handler._on_scroll(event)
func _unhandled_input(event) -> void:
	if handler != null:
		handler._on_scroll(event)
"""
	script.reload()
	_input_listener = Node.new()
	_input_listener.name = "TraceExtendedListener"
	_input_listener.set_script(script)
	_input_listener.handler = self
	if _g.World and _g.World is Node:
		var tree = _g.World.get_tree()
		if tree and tree.root:
			tree.root.call_deferred("add_child", _input_listener)


# ── Per-frame ────────────────────────────────────────────────────────────

func update(_delta: float) -> void:
	if not _g or not _g.Editor:
		return
	if _g.World == null or not is_instance_valid(_g.World):
		return

	if _g.World != _last_world_ref:
		_last_world_ref = _g.World
		_trace_tool = null
		_scale_ctrl = null
		_inited = false
		_bounds_set = false
		_signal_connected = false
		_ui_added = false
		_target_value = -1.0
		_prev_scale = -1.0
		_pending_position = false
		_restoring = true
		_needs_restore = true
		_restore_deadline = OS.get_ticks_msec() + RESTORE_TIMEOUT
		_layer_z = DEFAULT_LAYER_Z
		_blur_amount = 0.0
		_blend_mode = 0
		_blur_material = null
		_blur_original_texture = null
		_blur_mipmap_texture = null
		_rotation_deg = 0.0
		_prev_has_texture = false

	_ensure_init()
	if _inited and not _bounds_set:
		_extend_bounds()
	if _inited and not _signal_connected:
		_connect_signal()
	if _inited and not _ui_added:
		_add_ui()

	if _target_value >= 0 and OS.get_ticks_msec() < _force_until:
		_force_value(_target_value)
	elif _target_value >= 0 and OS.get_ticks_msec() >= _force_until:
		_target_value = -1.0
		if _pending_position:
			_pending_position = false
			_apply_pending_position()
		if _restoring:
			_restoring = false

	if _needs_restore:
		if OS.get_ticks_msec() > _restore_deadline:
			_needs_restore = false
			_try_reload_trace_image()
		else:
			_try_restore()

	_capture_image_path()

	_ensure_visible_on_load()

	if not _restoring:
		_persist_to_modmapdata()

	# Track current scale for next frame's anchor calculation
	_track_scale()

	# Detect user drag: if anchor is active and position changed unexpectedly, disable anchor
	if _anchor_top_left and not _restoring and _target_value < 0:
		if _g.World != null and is_instance_valid(_g.World):
			var trace_img = _g.World.TraceImage
			if trace_img != null and is_instance_valid(trace_img) and trace_img.texture != null:
				if _expected_pos != Vector2.ZERO and trace_img.position.distance_to(_expected_pos) > 1.0:
					_anchor_top_left = false
				_expected_pos = trace_img.position

	# Re-apply layer z-index if Dungeondraft reset it (e.g. visibility toggle)
	if not _restoring:
		var _ti = _g.World.TraceImage if _g.World != null else null
		if _ti != null and is_instance_valid(_ti) and _ti.z_index != _layer_z:
			_apply_layer_z()
		# Re-apply FX (blur/blend) if Dungeondraft reset material or texture
		if _ti != null and is_instance_valid(_ti):
			var _fx_active = _blur_amount > 0.0 or _blend_mode != 0
			if _fx_active:
				if _blur_material != null and _ti.material != _blur_material:
					_apply_blur()
				elif _blur_amount > 0.0 and _blur_mipmap_texture != null and _ti.texture != _blur_mipmap_texture:
					_ti.texture = _blur_mipmap_texture
			elif not _fx_active and _ti.material == _blur_material:
				_ti.material = null
		# Re-apply rotation if Dungeondraft reset it
		if _ti != null and is_instance_valid(_ti):
			if abs(_ti.rotation_degrees - _rotation_deg) > 0.01:
				_ti.rotation_degrees = _rotation_deg


# ── Init ─────────────────────────────────────────────────────────────────

func _ensure_init() -> void:
	if _inited:
		return
	if _trace_tool == null:
		_trace_tool = _g.Editor.Tools.get("TraceImage")
	if _trace_tool == null:
		return
	_scale_ctrl = _trace_tool.get("Scale")
	if _scale_ctrl == null or not is_instance_valid(_scale_ctrl):
		return
	_default_min = _scale_ctrl.min_value
	_default_max = _scale_ctrl.max_value
	_attach_slider_undo(_scale_ctrl)
	# The native opacity control too (live in DD's tool panel).
	var op_ctrl = _trace_tool.get("Opacity")
	if op_ctrl != null and is_instance_valid(op_ctrl):
		_attach_slider_undo(op_ctrl)
	_inited = true


func _extend_bounds() -> void:
	if _scale_ctrl == null or not is_instance_valid(_scale_ctrl):
		return
	_scale_ctrl.min_value = EXTENDED_MIN
	_scale_ctrl.max_value = EXTENDED_MAX
	_bounds_set = true


func _connect_signal() -> void:
	if _scale_ctrl == null or not is_instance_valid(_scale_ctrl):
		return
	if _scale_ctrl.is_connected("value_changed", self, "_on_scale_changed"):
		_signal_connected = true
		return
	_scale_ctrl.connect("value_changed", self, "_on_scale_changed", [], CONNECT_DEFERRED)
	_signal_connected = true


func _on_scale_changed(val: float) -> void:
	if _anchor_top_left:
		_apply_scale_from_top_left(val)
	elif _stretched:
		_apply_scale_stretched(val)
	else:
		_sync_sprite(val)
	if _stretched:
		_update_wh_sliders()
	if not _restoring:
		_save_scale(val)


# ── Track scale ──────────────────────────────────────────────────────────

func _track_scale() -> void:
	if _g.World == null or not is_instance_valid(_g.World):
		return
	var trace_img = _g.World.TraceImage
	if trace_img != null and is_instance_valid(trace_img) and trace_img.texture != null:
		_prev_scale = trace_img.scale.x


# ── UI ───────────────────────────────────────────────────────────────────

func _add_ui() -> void:
	if _trace_tool == null:
		return
	var controls = _trace_tool.get("Controls")
	if controls == null or not controls is Dictionary:
		return
	if not controls.has("CENTER"):
		return

	var center_btn = controls["CENTER"]
	if center_btn == null or not is_instance_valid(center_btn):
		return
	var parent = center_btn.get_parent()
	if parent == null:
		return

	# Hide the standalone "Layered Trace Image" mod's UI if present
	_hide_layer_mod_ui(parent)

	# ── Add reset buttons to Scale and Opacity rows ──
	var _reset_icon_small = _load_icon_scaled("icons/reset.png", 0.5)
	_add_reset_to_range(_scale_ctrl, _reset_icon_small, "Reset scale to 1.0", "_on_scale_reset")

	var _opacity_ctrl = _trace_tool.get("Opacity")
	if _opacity_ctrl != null and is_instance_valid(_opacity_ctrl):
		_add_reset_to_range(_opacity_ctrl, _reset_icon_small, "Reset opacity to 50%", "_on_opacity_reset")

	# Widen Scale and Opacity SpinBoxes for visual consistency
	if _scale_ctrl != null and is_instance_valid(_scale_ctrl):
		var sc_parent = _scale_ctrl.get_parent()
		if sc_parent != null:
			for child in sc_parent.get_children():
				if child is SpinBox:
					child.rect_min_size.x = 75
	if _opacity_ctrl != null and is_instance_valid(_opacity_ctrl):
		var op_parent = _opacity_ctrl.get_parent()
		if op_parent != null:
			for child in op_parent.get_children():
				if child is SpinBox:
					child.rect_min_size.x = 75

	# Snap Top-Left button with icon
	_snap_btn = Button.new()
	_snap_btn.text = " Snap to Top Left Corner"
	_snap_btn.hint_tooltip = "Snap trace image top-left to map top-left.\nScaling will anchor from this corner.\nMoving the image disables the anchor."
	var icon_tex = _load_icon("icons/snap_corner.png")
	if icon_tex != null:
		_snap_btn.icon = icon_tex
	_snap_btn.connect("pressed", self, "_button_undo_wrap", ["_on_snap_top_left"])
	parent.add_child(_snap_btn)
	parent.move_child(_snap_btn, center_btn.get_index() + 1)

	# Fit to map — keep ratio (smaller side)
	_fit_ratio_btn = Button.new()
	_fit_ratio_btn.text = " Fit to Map (Keep Ratio)"
	_fit_ratio_btn.hint_tooltip = "Scale uniformly so the image fits the smaller map side.\nAspect ratio is preserved."
	var fit_keep_icon = _load_icon("icons/fit_keep.png")
	if fit_keep_icon != null:
		_fit_ratio_btn.icon = fit_keep_icon
	_fit_ratio_btn.connect("pressed", self, "_button_undo_wrap", ["_on_fit_to_map_ratio"])
	parent.add_child(_fit_ratio_btn)
	parent.move_child(_fit_ratio_btn, _snap_btn.get_index() + 1)

	# Fit to map — stretch to both sides
	_fit_stretch_btn = Button.new()
	_fit_stretch_btn.text = " Fit to Map (Stretch)"
	_fit_stretch_btn.hint_tooltip = "Scale non-uniformly so the image covers the entire map.\nAspect ratio may be distorted."
	var fit_stretch_icon = _load_icon("icons/fit_stretch.png")
	if fit_stretch_icon != null:
		_fit_stretch_btn.icon = fit_stretch_icon
	_fit_stretch_btn.connect("pressed", self, "_button_undo_wrap", ["_on_fit_to_map_stretch"])
	parent.add_child(_fit_stretch_btn)
	parent.move_child(_fit_stretch_btn, _fit_ratio_btn.get_index() + 1)

	# ── Grid Match row: label + spinbox + Match button ──
	var grid_row = HBoxContainer.new()
	parent.add_child(grid_row)
	parent.move_child(grid_row, _fit_stretch_btn.get_index() + 1)

	var px_label = Label.new()
	px_label.text = "Grid size (px):"
	px_label.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	grid_row.add_child(px_label)

	_grid_spinbox = SpinBox.new()
	_grid_spinbox.min_value = 0
	_grid_spinbox.max_value = 10000
	_grid_spinbox.step = 1
	_grid_spinbox.value = 0
	_grid_spinbox.rect_min_size.x = 65
	_grid_spinbox.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_grid_spinbox.hint_tooltip = "Size of one grid cell in the trace image, in pixels.\nCommon values: 70, 100, 140, 256."
	grid_row.add_child(_grid_spinbox)
	# Clear the displayed text so it looks empty instead of showing "0"
	var line_edit = _grid_spinbox.get_line_edit()
	if line_edit != null:
		line_edit.placeholder_text = "..."
		line_edit.text = ""

	_grid_match_btn = Button.new()
	_grid_match_btn.text = "Match"
	_grid_match_btn.align = Button.ALIGN_CENTER
	_grid_match_btn.hint_tooltip = "Scale the trace image so its grid matches Dungeondraft's grid.\nAlso snaps to top-left corner."
	# White 1px border with padding
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0)
	style.border_color = Color(1, 1, 1, 1)
	style.set_border_width_all(1)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	_grid_match_btn.add_stylebox_override("normal", style)
	var style_hover = style.duplicate()
	style_hover.bg_color = Color(1, 1, 1, 0.1)
	_grid_match_btn.add_stylebox_override("hover", style_hover)
	var style_pressed = style.duplicate()
	style_pressed.bg_color = Color(1, 1, 1, 0.2)
	_grid_match_btn.add_stylebox_override("pressed", style_pressed)
	_grid_match_btn.connect("pressed", self, "_button_undo_wrap", ["_on_match_grid"])
	grid_row.add_child(_grid_match_btn)

	# Reset Size button
	var reset_btn = Button.new()
	reset_btn.text = " Reset Size"
	reset_btn.hint_tooltip = "Reset scale to 1.0 (original image size)."
	var reset_icon = _load_icon_scaled("icons/reset.png", 0.85)
	if reset_icon != null:
		reset_btn.icon = reset_icon
	reset_btn.connect("pressed", self, "_button_undo_wrap", ["_on_reset_size"])
	parent.add_child(reset_btn)
	parent.move_child(reset_btn, grid_row.get_index() + 1)

	var sep = HSeparator.new()
	sep.add_constant_override("separation", 8)
	parent.add_child(sep)
	parent.move_child(sep, reset_btn.get_index() + 1)

	# ── Unlock Ratio toggle ──
	_unlock_ratio_toggle = CheckButton.new()
	_unlock_ratio_toggle.text = "Unlock Ratio"
	_unlock_ratio_toggle.hint_tooltip = "When ON, allows independent Width and Height scaling."
	_unlock_ratio_toggle.pressed = _stretched
	_unlock_ratio_toggle.connect("toggled", self, "_toggle_undo_wrap", ["_on_unlock_ratio_toggled"])
	parent.add_child(_unlock_ratio_toggle)
	parent.move_child(_unlock_ratio_toggle, sep.get_index() + 1)

	# ── Width/Height sliders (inserted below Scale slider in the tool panel) ──
	_create_wh_sliders()

	# ── Rotation slider (inserted between Scale and Opacity in the tool panel) ──
	_create_rotation_row(_reset_icon_small)

	# ── Precise Scaling toggle ──
	_precise_toggle = CheckButton.new()
	_precise_toggle.text = "Precise Scaling"
	_precise_toggle.hint_tooltip = "Use a fixed step of 0.001 for fine control."
	_precise_toggle.pressed = _precise_scaling
	_precise_toggle.connect("toggled", self, "_on_precise_toggled")
	parent.add_child(_precise_toggle)
	parent.move_child(_precise_toggle, _unlock_ratio_toggle.get_index() + 1)

	# ── Blur ──
	var blur_lbl = Label.new()
	blur_lbl.text = "Blur"
	parent.add_child(blur_lbl)

	var blur_row = HBoxContainer.new()
	var b_slider = HSlider.new()
	b_slider.min_value = 0.0
	b_slider.max_value = 12.0
	b_slider.step = 0.1
	b_slider.value = _blur_amount
	b_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b_slider.connect("value_changed", self, "_on_blur_changed")
	blur_row.add_child(b_slider)
	_blur_slider = b_slider
	_attach_slider_undo(b_slider)

	var b_spinbox = SpinBox.new()
	b_spinbox.min_value = 0.0
	b_spinbox.max_value = 12.0
	b_spinbox.step = 0.1
	b_spinbox.value = _blur_amount
	b_spinbox.rect_min_size.x = 75
	b_spinbox.connect("value_changed", self, "_on_blur_changed")
	blur_row.add_child(b_spinbox)
	_blur_spinbox = b_spinbox

	var blur_reset = Button.new()
	blur_reset.hint_tooltip = "Reset blur to 0 (off)"
	if _reset_icon_small != null:
		blur_reset.icon = _reset_icon_small
	else:
		blur_reset.text = "R"
	blur_reset.connect("pressed", self, "_button_undo_wrap", ["_on_blur_reset"])
	blur_row.add_child(blur_reset)

	parent.add_child(blur_row)

	# ── Blend mode ──
	var blend_lbl = Label.new()
	blend_lbl.text = "Blend Mode"
	parent.add_child(blend_lbl)

	var blend_row = HBoxContainer.new()
	_blend_option = OptionButton.new()
	for i in range(BLEND_MODE_NAMES.size()):
		_blend_option.add_item(BLEND_MODE_NAMES[i], i)
	_blend_option.selected = _blend_mode
	_blend_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_blend_option.hint_tooltip = "Composite the trace image against the map drawn below it.\nUse the Layer slider to control what it blends over.\nNormal = no blending."
	_blend_option.connect("item_selected", self, "_on_blend_changed")
	blend_row.add_child(_blend_option)

	var blend_reset = Button.new()
	blend_reset.hint_tooltip = "Reset blend mode to Normal"
	if _reset_icon_small != null:
		blend_reset.icon = _reset_icon_small
	else:
		blend_reset.text = "R"
	blend_reset.connect("pressed", self, "_on_blend_reset")
	blend_row.add_child(blend_reset)

	parent.add_child(blend_row)

	# Reposition the blend mode UI between the divider and "Unlock Ratio"
	parent.move_child(blend_lbl, sep.get_index() + 1)
	parent.move_child(blend_row, blend_lbl.get_index() + 1)

	var layer_lbl = Label.new()
	layer_lbl.text = "Layer"
	parent.add_child(layer_lbl)

	var layer_row = HBoxContainer.new()
	var l_slider = HSlider.new()
	l_slider.min_value = -501
	l_slider.max_value = 1000
	l_slider.step = 1
	l_slider.value = _layer_z
	l_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	l_slider.connect("value_changed", self, "_on_layer_changed")
	layer_row.add_child(l_slider)
	_layer_slider = l_slider
	_attach_slider_undo(l_slider)

	var l_spinbox = SpinBox.new()
	l_spinbox.min_value = -501
	l_spinbox.max_value = 1000
	l_spinbox.step = 1
	l_spinbox.value = _layer_z
	l_spinbox.rect_min_size.x = 75
	l_spinbox.connect("value_changed", self, "_on_layer_changed")
	var l_line_edit = l_spinbox.get_line_edit()
	if l_line_edit != null:
		l_line_edit.align = LineEdit.ALIGN_CENTER
	layer_row.add_child(l_spinbox)
	_layer_spinbox = l_spinbox

	var layer_reset = Button.new()
	layer_reset.hint_tooltip = "Reset layer to default (on top)"
	if _reset_icon_small != null:
		layer_reset.icon = _reset_icon_small
	else:
		layer_reset.text = "R"
	layer_reset.connect("pressed", self, "_button_undo_wrap", ["_on_layer_reset"])
	layer_row.add_child(layer_reset)

	parent.add_child(layer_row)

	# Move the "The trace image can be toggled..." note to the very end
	for child in parent.get_children():
		if child is Label and "trace image" in str(child.text).to_lower():
			parent.move_child(child, parent.get_child_count() - 1)
			break

	_ui_added = true


func _load_icon(icon_path: String):
	var image = Image.new()
	var err = image.load(_g.Root + icon_path)
	if err != OK:
		return null
	var texture = ImageTexture.new()
	texture.create_from_image(image)
	return texture


func _load_icon_scaled(icon_path: String, scale_factor: float):
	var image = Image.new()
	var err = image.load(_g.Root + icon_path)
	if err != OK:
		return null
	var new_w = int(image.get_width() * scale_factor)
	var new_h = int(image.get_height() * scale_factor)
	if new_w < 1: new_w = 1
	if new_h < 1: new_h = 1
	image.resize(new_w, new_h, Image.INTERPOLATE_LANCZOS)
	var texture = ImageTexture.new()
	texture.create_from_image(image)
	return texture


func _add_reset_to_range(range_ctrl, icon, tooltip: String, callback: String) -> void:
	"""Add a small reset button at the end of a Range control's parent HBox."""
	var hbox = range_ctrl.get_parent()
	if hbox == null:
		return
	# Avoid adding twice
	for child in hbox.get_children():
		if child is Button and child.hint_tooltip == tooltip:
			return
	var btn = Button.new()
	btn.hint_tooltip = tooltip
	if icon != null:
		btn.icon = icon
	else:
		btn.text = "R"
	btn.connect("pressed", self, "_button_undo_wrap", [callback])
	hbox.add_child(btn)


func _on_reset_size() -> void:
	if _g.World == null or not is_instance_valid(_g.World):
		return
	var trace_img = _g.World.TraceImage
	if trace_img == null or not is_instance_valid(trace_img):
		return

	var reset_scale = 1.0
	_stretched = false
	_anchor_top_left = false
	_stretch_scale_x = 1.0
	_stretch_scale_y = 1.0

	trace_img.scale = Vector2(reset_scale, reset_scale)

	if _scale_ctrl != null and is_instance_valid(_scale_ctrl):
		_scale_ctrl.set_block_signals(true)
		_scale_ctrl.value = reset_scale
		_scale_ctrl.set_block_signals(false)

	# Hide W/H sliders
	if _unlock_ratio_toggle != null and is_instance_valid(_unlock_ratio_toggle):
		_unlock_ratio_toggle.set_pressed_no_signal(false)
	if _width_row != null:
		_width_row.visible = false
	if _height_row != null:
		_height_row.visible = false

	if not _restoring:
		_save_scale(reset_scale)


func _create_wh_sliders() -> void:
	# Insert Width and Height rows right below the Scale slider's parent row
	if _scale_ctrl == null or not is_instance_valid(_scale_ctrl):
		return
	var scale_hbox = _scale_ctrl.get_parent()
	if scale_hbox == null:
		return
	var panel_parent = scale_hbox.get_parent()
	if panel_parent == null:
		return
	var insert_idx = scale_hbox.get_index() + 1

	# Width row
	_width_row = HBoxContainer.new()
	var w_label = Label.new()
	w_label.text = "Width"
	w_label.rect_min_size.x = 46
	w_label.align = Label.ALIGN_RIGHT
	_width_row.add_child(w_label)
	_width_slider = HSlider.new()
	_width_slider.min_value = EXTENDED_MIN
	_width_slider.max_value = EXTENDED_MAX
	_width_slider.step = 0.01
	_width_slider.value = 1.0
	_width_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_width_slider.rect_min_size.y = 31
	_width_row.add_child(_width_slider)
	_width_spinbox = SpinBox.new()
	_width_spinbox.min_value = EXTENDED_MIN
	_width_spinbox.max_value = EXTENDED_MAX
	_width_spinbox.step = 0.01
	_width_spinbox.value = 1.0
	_width_spinbox.rect_min_size.x = 75
	_width_row.add_child(_width_spinbox)
	_width_slider.share(_width_spinbox)
	_width_slider.connect("value_changed", self, "_on_width_changed")
	_attach_slider_undo(_width_slider)
	panel_parent.add_child(_width_row)
	panel_parent.move_child(_width_row, insert_idx)

	# Height row
	_height_row = HBoxContainer.new()
	var h_label = Label.new()
	h_label.text = "Height"
	h_label.rect_min_size.x = 46
	h_label.align = Label.ALIGN_RIGHT
	_height_row.add_child(h_label)
	_height_slider = HSlider.new()
	_height_slider.min_value = EXTENDED_MIN
	_height_slider.max_value = EXTENDED_MAX
	_height_slider.step = 0.01
	_height_slider.value = 1.0
	_height_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_height_slider.rect_min_size.y = 31
	_height_row.add_child(_height_slider)
	_height_spinbox = SpinBox.new()
	_height_spinbox.min_value = EXTENDED_MIN
	_height_spinbox.max_value = EXTENDED_MAX
	_height_spinbox.step = 0.01
	_height_spinbox.value = 1.0
	_height_spinbox.rect_min_size.x = 75
	_height_row.add_child(_height_spinbox)
	_height_slider.share(_height_spinbox)
	_height_slider.connect("value_changed", self, "_on_height_changed")
	_attach_slider_undo(_height_slider)
	panel_parent.add_child(_height_row)
	panel_parent.move_child(_height_row, _width_row.get_index() + 1)

	# Start hidden
	_width_row.visible = _stretched
	_height_row.visible = _stretched


func _create_rotation_row(reset_icon) -> void:
	"""Insert a Rotation label + slider row between Scale and Opacity in the tool panel."""
	if _scale_ctrl == null or not is_instance_valid(_scale_ctrl):
		return
	var scale_hbox = _scale_ctrl.get_parent()
	if scale_hbox == null:
		return
	var panel_parent = scale_hbox.get_parent()
	if panel_parent == null:
		return

	# Find the Opacity label to insert before it
	var _opacity_ctrl = _trace_tool.get("Opacity")
	if _opacity_ctrl == null or not is_instance_valid(_opacity_ctrl):
		return
	var opacity_hbox = _opacity_ctrl.get_parent()
	if opacity_hbox == null:
		return
	var opacity_idx = opacity_hbox.get_index()
	# The label is the sibling just before the Opacity HBox
	var insert_idx = opacity_idx
	if insert_idx > 0:
		var prev = panel_parent.get_child(insert_idx - 1)
		if prev is Label:
			insert_idx = prev.get_index()

	# Label
	var rot_lbl = Label.new()
	rot_lbl.text = "Rotation"
	panel_parent.add_child(rot_lbl)
	panel_parent.move_child(rot_lbl, insert_idx)

	# Row: slider + spinbox + reset
	var rot_row = HBoxContainer.new()
	var r_slider = HSlider.new()
	r_slider.min_value = 0.0
	r_slider.max_value = 360.0
	r_slider.step = 1.0
	r_slider.value = _rotation_deg
	r_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	r_slider.connect("value_changed", self, "_on_rotation_changed")
	rot_row.add_child(r_slider)
	_rotation_slider = r_slider
	_attach_slider_undo(r_slider)

	var r_spinbox = SpinBox.new()
	r_spinbox.min_value = 0.0
	r_spinbox.max_value = 360.0
	r_spinbox.step = 1.0
	r_spinbox.value = _rotation_deg
	r_spinbox.rect_min_size.x = 75
	r_spinbox.suffix = "°"
	r_spinbox.connect("value_changed", self, "_on_rotation_changed")
	rot_row.add_child(r_spinbox)
	_rotation_spinbox = r_spinbox

	var rot_reset = Button.new()
	rot_reset.hint_tooltip = "Reset rotation to 0°"
	if reset_icon != null:
		rot_reset.icon = reset_icon
	else:
		rot_reset.text = "R"
	rot_reset.connect("pressed", self, "_button_undo_wrap", ["_on_rotation_reset"])
	rot_row.add_child(rot_reset)

	panel_parent.add_child(rot_row)
	panel_parent.move_child(rot_row, rot_lbl.get_index() + 1)


func _on_unlock_ratio_toggled(pressed: bool) -> void:
	_stretched = pressed
	_width_row.visible = pressed
	_height_row.visible = pressed

	if pressed:
		# Sync sliders with current sprite scale
		if _g.World != null and is_instance_valid(_g.World):
			var trace_img = _g.World.TraceImage
			if trace_img != null and is_instance_valid(trace_img):
				_stretch_scale_x = trace_img.scale.x
				_stretch_scale_y = trace_img.scale.y
				_width_slider.set_block_signals(true)
				_width_slider.value = _stretch_scale_x
				_width_slider.set_block_signals(false)
				_height_slider.set_block_signals(true)
				_height_slider.value = _stretch_scale_y
				_height_slider.set_block_signals(false)
	else:
		# Lock ratio: set uniform scale from current X
		if _g.World != null and is_instance_valid(_g.World):
			var trace_img = _g.World.TraceImage
			if trace_img != null and is_instance_valid(trace_img):
				var uniform = trace_img.scale.x
				trace_img.scale = Vector2(uniform, uniform)
				_stretch_scale_x = uniform
				_stretch_scale_y = uniform
				if _scale_ctrl != null and is_instance_valid(_scale_ctrl):
					_scale_ctrl.set_block_signals(true)
					_scale_ctrl.value = uniform
					_scale_ctrl.set_block_signals(false)
				_sync_sprite(uniform)
				if not _restoring:
					_save_scale(uniform)


func _on_width_changed(val: float) -> void:
	if not _stretched:
		return
	_stretch_scale_x = val
	if _g.World == null or not is_instance_valid(_g.World):
		return
	var trace_img = _g.World.TraceImage
	if trace_img == null or not is_instance_valid(trace_img):
		return
	trace_img.scale.x = val
	if _anchor_top_left:
		var tex_size = trace_img.texture.get_size() if trace_img.texture != null else Vector2.ZERO
		trace_img.position = _anchored_top_left + (tex_size * trace_img.scale) / 2.0
		_expected_pos = trace_img.position
	# Update main slider to show width
	if _scale_ctrl != null and is_instance_valid(_scale_ctrl):
		_scale_ctrl.set_block_signals(true)
		_scale_ctrl.value = val
		_scale_ctrl.set_block_signals(false)
	if not _restoring:
		_save_scale(val)


func _on_height_changed(val: float) -> void:
	if not _stretched:
		return
	_stretch_scale_y = val
	if _g.World == null or not is_instance_valid(_g.World):
		return
	var trace_img = _g.World.TraceImage
	if trace_img == null or not is_instance_valid(trace_img):
		return
	trace_img.scale.y = val
	if _anchor_top_left:
		var tex_size = trace_img.texture.get_size() if trace_img.texture != null else Vector2.ZERO
		trace_img.position = _anchored_top_left + (tex_size * trace_img.scale) / 2.0
		_expected_pos = trace_img.position
	if not _restoring:
		_save_scale(_stretch_scale_x)


func _update_wh_sliders() -> void:
	"""Sync Width/Height sliders with current stretch values."""
	if _width_slider == null or _height_slider == null:
		return
	if not is_instance_valid(_width_slider) or not is_instance_valid(_height_slider):
		return
	_width_slider.set_block_signals(true)
	_width_slider.value = _stretch_scale_x
	_width_slider.set_block_signals(false)
	_height_slider.set_block_signals(true)
	_height_slider.value = _stretch_scale_y
	_height_slider.set_block_signals(false)


func _on_snap_top_left() -> void:
	if _g.World == null or not is_instance_valid(_g.World):
		return
	var trace_img = _g.World.TraceImage
	if trace_img == null or not is_instance_valid(trace_img):
		return
	if trace_img.texture == null:
		return

	var map_top_left = _g.World.WorldRect.position
	var tex_size = trace_img.texture.get_size()
	var sc = trace_img.scale

	trace_img.position = map_top_left + (tex_size * sc) / 2.0
	_expected_pos = trace_img.position

	_anchored_top_left = map_top_left
	_anchor_top_left = true
	_prev_scale = sc.x

	if not _restoring:
		_save_scale(sc.x)


func _on_fit_to_map_ratio() -> void:
	if _g.World == null or not is_instance_valid(_g.World):
		return
	var trace_img = _g.World.TraceImage
	if trace_img == null or not is_instance_valid(trace_img):
		return
	if trace_img.texture == null:
		return

	var tex_size = trace_img.texture.get_size()
	if tex_size.x <= 0 or tex_size.y <= 0:
		return

	var map_rect = _g.World.WorldRect
	var map_size = map_rect.size

	# Fit to smaller side — uniform scale, ratio preserved
	var scale_x = map_size.x / tex_size.x
	var scale_y = map_size.y / tex_size.y
	var fit_scale = min(scale_x, scale_y)

	if _scale_ctrl != null and is_instance_valid(_scale_ctrl):
		_scale_ctrl.min_value = EXTENDED_MIN
		_scale_ctrl.max_value = max(EXTENDED_MAX, fit_scale)
		_scale_ctrl.set_block_signals(true)
		_scale_ctrl.value = fit_scale
		_scale_ctrl.set_block_signals(false)
	trace_img.scale = Vector2(fit_scale, fit_scale)

	# Snap top-left
	trace_img.position = map_rect.position + (tex_size * Vector2(fit_scale, fit_scale)) / 2.0
	_expected_pos = trace_img.position
	_anchored_top_left = map_rect.position
	_anchor_top_left = true
	_stretched = false
	_prev_scale = fit_scale

	# Deactivate Unlock Ratio UI
	if _unlock_ratio_toggle != null and is_instance_valid(_unlock_ratio_toggle):
		_unlock_ratio_toggle.set_pressed_no_signal(false)
	if _width_row != null:
		_width_row.visible = false
	if _height_row != null:
		_height_row.visible = false

	if not _restoring:
		_save_scale(fit_scale)


func _on_fit_to_map_stretch() -> void:
	if _g.World == null or not is_instance_valid(_g.World):
		return
	var trace_img = _g.World.TraceImage
	if trace_img == null or not is_instance_valid(trace_img):
		return
	if trace_img.texture == null:
		return

	var tex_size = trace_img.texture.get_size()
	if tex_size.x <= 0 or tex_size.y <= 0:
		return

	var map_rect = _g.World.WorldRect
	var map_size = map_rect.size

	# Fit to both sides — non-uniform scale
	var scale_x = map_size.x / tex_size.x
	var scale_y = map_size.y / tex_size.y

	trace_img.scale = Vector2(scale_x, scale_y)

	# Position so top-left matches map top-left
	trace_img.position = map_rect.position + (tex_size * Vector2(scale_x, scale_y)) / 2.0
	_expected_pos = trace_img.position

	# Store stretch state
	var ratios_differ = abs(scale_x - scale_y) > 0.0001
	_stretched = ratios_differ
	_stretch_scale_x = scale_x
	_stretch_scale_y = scale_y
	_anchored_top_left = map_rect.position
	_anchor_top_left = true

	# Slider shows the X scale as reference
	var display_scale = scale_x
	if _scale_ctrl != null and is_instance_valid(_scale_ctrl):
		_scale_ctrl.min_value = EXTENDED_MIN
		_scale_ctrl.max_value = max(EXTENDED_MAX, display_scale)
		_scale_ctrl.set_block_signals(true)
		_scale_ctrl.value = display_scale
		_scale_ctrl.set_block_signals(false)

	_prev_scale = display_scale

	# Activate Unlock Ratio UI only if ratios actually differ
	if _unlock_ratio_toggle != null and is_instance_valid(_unlock_ratio_toggle):
		if ratios_differ:
			_unlock_ratio_toggle.pressed = true
		else:
			_unlock_ratio_toggle.set_pressed_no_signal(false)
	if _width_row != null:
		_width_row.visible = ratios_differ
	if _height_row != null:
		_height_row.visible = ratios_differ
	if ratios_differ:
		_update_wh_sliders()

	if not _restoring:
		_save_scale(display_scale)


func _on_precise_toggled(pressed: bool) -> void:
	_precise_scaling = pressed
	var step = 0.001 if _precise_scaling else 0.01
	if _scale_ctrl != null and is_instance_valid(_scale_ctrl):
		_scale_ctrl.step = step
	if _width_slider != null and is_instance_valid(_width_slider):
		_width_slider.step = step
	if _width_spinbox != null and is_instance_valid(_width_spinbox):
		_width_spinbox.step = step
	if _height_slider != null and is_instance_valid(_height_slider):
		_height_slider.step = step
	if _height_spinbox != null and is_instance_valid(_height_spinbox):
		_height_spinbox.step = step


# ── Layer (z-index) ─────────────────────────────────────────────────────

func _on_scale_reset() -> void:
	_on_reset_size()


func _on_opacity_reset() -> void:
	var opacity_ctrl = _trace_tool.get("Opacity")
	if opacity_ctrl != null and is_instance_valid(opacity_ctrl):
		opacity_ctrl.value = 0.5


# ── Rotation ────────────────────────────────────────────────────────────

func _apply_rotation() -> void:
	if _g.World == null or not is_instance_valid(_g.World):
		return
	var trace_img = _g.World.TraceImage
	if trace_img == null or not is_instance_valid(trace_img):
		return
	trace_img.rotation_degrees = _rotation_deg


func _on_rotation_changed(value) -> void:
	if _syncing_rotation:
		return
	_syncing_rotation = true
	_rotation_deg = stepify(value, 1.0)
	_sync_rotation_ui()
	_apply_rotation()
	if not _restoring:
		_save_scale(_scale_ctrl.value if _scale_ctrl != null and is_instance_valid(_scale_ctrl) else 1.0)
	_syncing_rotation = false


func _on_rotation_reset() -> void:
	_on_rotation_changed(0.0)


func _sync_rotation_ui() -> void:
	if _rotation_slider != null and is_instance_valid(_rotation_slider):
		_rotation_slider.value = _rotation_deg
	if _rotation_spinbox != null and is_instance_valid(_rotation_spinbox):
		_rotation_spinbox.value = _rotation_deg


func _hide_layer_mod_ui(align_container) -> void:
	"""Hide the standalone Layered Trace Image mod's Label + OptionButton."""
	for i in range(align_container.get_child_count()):
		var child = align_container.get_child(i)
		if child is Label and child.text == "Layer":
			child.visible = false
			# The dropdown is the next sibling
			var next_idx = i + 1
			if next_idx < align_container.get_child_count():
				var dropdown = align_container.get_child(next_idx)
				if dropdown is OptionButton:
					dropdown.visible = false
			break


func _apply_layer_z() -> void:
	if _g.World == null or not is_instance_valid(_g.World):
		return
	var trace_img = _g.World.TraceImage
	if trace_img == null or not is_instance_valid(trace_img):
		return
	trace_img.call("set_z_index", _layer_z)
	trace_img.call("set_z_as_relative", false)


func _on_layer_changed(value) -> void:
	if _syncing_layer:
		return
	_syncing_layer = true
	_layer_z = int(value)
	_sync_layer_ui()
	_apply_layer_z()
	if not _restoring:
		_save_scale(_scale_ctrl.value if _scale_ctrl != null and is_instance_valid(_scale_ctrl) else 1.0)
	_syncing_layer = false


func _on_layer_reset() -> void:
	_on_layer_changed(DEFAULT_LAYER_Z)


func _sync_layer_ui() -> void:
	if _layer_slider != null and is_instance_valid(_layer_slider):
		_layer_slider.value = _layer_z
	if _layer_spinbox != null and is_instance_valid(_layer_spinbox):
		_layer_spinbox.value = _layer_z


# ── Blur ────────────────────────────────────────────────────────────────

func _ensure_blur_material() -> void:
	if _blur_material != null:
		return
	var shader = Shader.new()
	shader.code = BLUR_SHADER_CODE
	_blur_material = ShaderMaterial.new()
	_blur_material.shader = shader


func _ensure_mipmap_texture(trace_img) -> void:
	"""Swap the trace texture for an ImageTexture copy with mipmaps generated."""
	if _blur_mipmap_texture != null:
		# Already swapped — but check if user loaded a new image
		if trace_img.texture != _blur_mipmap_texture and trace_img.texture != _blur_original_texture:
			# User loaded a new image, reset
			_blur_original_texture = trace_img.texture
			_blur_mipmap_texture = null
		else:
			return

	var tex = trace_img.texture
	if tex == null:
		return

	_blur_original_texture = tex

	var img = tex.get_data()
	if img == null:
		return
	if img.is_compressed():
		img.decompress()

	_blur_mipmap_texture = ImageTexture.new()
	_blur_mipmap_texture.create_from_image(img, Texture.FLAG_MIPMAPS | Texture.FLAG_FILTER)
	trace_img.texture = _blur_mipmap_texture
	print("[TE] Mipmap texture created: ", img.get_width(), "x", img.get_height())


func _apply_blur() -> void:
	# Applies the combined FX material (blur + blend mode). The material is
	# attached whenever either effect is active. Mipmaps are only needed for
	# blur; a pure blend mode keeps the original texture.
	if _g.World == null or not is_instance_valid(_g.World):
		return
	var trace_img = _g.World.TraceImage
	if trace_img == null or not is_instance_valid(trace_img):
		return
	var fx_active = _blur_amount > 0.0 or _blend_mode != 0
	if fx_active:
		_ensure_blur_material()
		if _blur_material == null:
			return
		if _blur_amount > 0.0:
			_ensure_mipmap_texture(trace_img)
		else:
			# Blend-only: ensure we're on the original (non-mipmap) texture
			if _blur_original_texture != null and trace_img.texture == _blur_mipmap_texture:
				trace_img.texture = _blur_original_texture
				_blur_mipmap_texture = null
		if trace_img.material != _blur_material:
			trace_img.material = _blur_material
		_blur_material.set_shader_param("blur", _blur_amount)
		_blur_material.set_shader_param("blend_mode", _blend_mode)
	else:
		if trace_img.material == _blur_material:
			trace_img.material = null
		# Restore original texture
		if _blur_original_texture != null and trace_img.texture == _blur_mipmap_texture:
			trace_img.texture = _blur_original_texture
			_blur_mipmap_texture = null


func _on_blur_changed(value) -> void:
	if _syncing_blur:
		return
	_syncing_blur = true
	_blur_amount = stepify(value, 0.1)
	_sync_blur_ui()
	_apply_blur()
	if not _restoring:
		_save_scale(_scale_ctrl.value if _scale_ctrl != null and is_instance_valid(_scale_ctrl) else 1.0)
	_syncing_blur = false


func _on_blur_reset() -> void:
	_on_blur_changed(0.0)


func _sync_blur_ui() -> void:
	if _blur_slider != null and is_instance_valid(_blur_slider):
		_blur_slider.value = _blur_amount
	if _blur_spinbox != null and is_instance_valid(_blur_spinbox):
		_blur_spinbox.value = _blur_amount


# ── Blend mode ──────────────────────────────────────────────────────────

func _on_blend_changed(index) -> void:
	if _syncing_blend:
		return
	_syncing_blend = true
	var before = _snapshot_state()
	_blend_mode = int(index)
	_sync_blend_ui()
	_apply_blur()
	if not _restoring and not _applying_undo:
		var after = _snapshot_state()
		if not _states_equal(before, after):
			_record_undo(before, after)
		_save_scale(_scale_ctrl.value if _scale_ctrl != null and is_instance_valid(_scale_ctrl) else 1.0)
	_syncing_blend = false


func _on_blend_reset() -> void:
	_on_blend_changed(0)


func _sync_blend_ui() -> void:
	if _blend_option != null and is_instance_valid(_blend_option):
		_blend_option.selected = _blend_mode


func _on_match_grid() -> void:
	if _g.World == null or not is_instance_valid(_g.World):
		return
	var trace_img = _g.World.TraceImage
	if trace_img == null or not is_instance_valid(trace_img):
		return
	if trace_img.texture == null:
		return
	if _grid_spinbox == null or not is_instance_valid(_grid_spinbox):
		return

	var image_grid_px = _grid_spinbox.value
	if image_grid_px <= 0:
		return

	# DD's grid cell size in world units
	var dd_grid = _g.World.GridCellSize
	if dd_grid == null:
		return
	var dd_cell_size = dd_grid.x  # grid cells are square

	# Scale = world_units_per_cell / image_pixels_per_cell
	var match_scale = dd_cell_size / image_grid_px

	# Apply uniform scale
	_stretched = false
	if _scale_ctrl != null and is_instance_valid(_scale_ctrl):
		_scale_ctrl.min_value = EXTENDED_MIN
		_scale_ctrl.max_value = max(EXTENDED_MAX, match_scale)
		_scale_ctrl.set_block_signals(true)
		_scale_ctrl.value = match_scale
		_scale_ctrl.set_block_signals(false)
	trace_img.scale = Vector2(match_scale, match_scale)

	# Snap to top-left
	var map_top_left = _g.World.WorldRect.position
	var tex_size = trace_img.texture.get_size()
	trace_img.position = map_top_left + (tex_size * Vector2(match_scale, match_scale)) / 2.0
	_expected_pos = trace_img.position
	_anchored_top_left = map_top_left
	_anchor_top_left = true
	_prev_scale = match_scale

	if not _restoring:
		_save_scale(match_scale)


# ── Scale from top-left anchor ───────────────────────────────────────────

func _apply_scale_from_top_left(new_scale_val: float) -> void:
	if _g.World == null or not is_instance_valid(_g.World):
		return
	var trace_img = _g.World.TraceImage
	if trace_img == null or not is_instance_valid(trace_img):
		return
	if trace_img.texture == null:
		return

	var tex_size = trace_img.texture.get_size()
	var new_scale: Vector2

	if _stretched and _stretch_scale_x > 0:
		# Maintain the stretch ratio: scale both axes proportionally
		var ratio = new_scale_val / _stretch_scale_x
		new_scale = Vector2(_stretch_scale_x * ratio, _stretch_scale_y * ratio)
		# Update stored stretch scales
		_stretch_scale_x = new_scale.x
		_stretch_scale_y = new_scale.y
	else:
		new_scale = Vector2(new_scale_val, new_scale_val)

	trace_img.scale = new_scale
	trace_img.position = _anchored_top_left + (tex_size * new_scale) / 2.0
	_expected_pos = trace_img.position


func _apply_scale_stretched(new_scale_val: float) -> void:
	"""Scale while maintaining the stretch ratio, without anchor."""
	if _g.World == null or not is_instance_valid(_g.World):
		return
	var trace_img = _g.World.TraceImage
	if trace_img == null or not is_instance_valid(trace_img):
		return
	if _stretch_scale_x <= 0:
		return

	var ratio = new_scale_val / _stretch_scale_x
	var new_scale = Vector2(_stretch_scale_x * ratio, _stretch_scale_y * ratio)
	_stretch_scale_x = new_scale.x
	_stretch_scale_y = new_scale.y
	trace_img.scale = new_scale


# ── Image path capture ───────────────────────────────────────────────────

# ── Visibility-on-load fix ───────────────────────────────────────────────
# Vanilla DD bug: after a save + reopen, World.TraceImageVisible stays
# false, so a freshly loaded trace image remains hidden until the user
# presses T. DD's native Reset button works around it by forcing visibility
# back on. We replicate that here: whenever a trace texture appears
# (null -> present), force the sprite and the World.TraceImageVisible flag
# back to visible — mirroring exactly what a fresh load on a new map does.
func _ensure_visible_on_load() -> void:
	if _g.World == null or not is_instance_valid(_g.World):
		_prev_has_texture = false
		return
	var trace_img = _g.World.TraceImage
	var has_tex = trace_img != null and is_instance_valid(trace_img) and trace_img.texture != null
	if has_tex and not _prev_has_texture:
		# Fresh load detected. Force visible (matches native Reset behaviour).
		if not bool(_g.World.TraceImageVisible) or not trace_img.visible:
			trace_img.visible = true
			_g.World.TraceImageVisible = true
	_prev_has_texture = has_tex


func _capture_image_path() -> void:
	if _g.World == null or not is_instance_valid(_g.World):
		return
	var trace_img = _g.World.TraceImage
	if trace_img == null or not is_instance_valid(trace_img):
		return
	# Use original texture when blur is active (mipmap copy has no resource_path)
	var tex = _blur_original_texture if _blur_original_texture != null else trace_img.texture
	if tex != null:
		var rp = tex.resource_path
		if rp != null and rp is String and rp != "":
			_image_path = rp
	if _image_path == "":
		var saved = _get_saved_state()
		if saved != null and saved.has("image") and saved["image"] != "":
			_image_path = saved["image"]


func _update_image_label(path: String) -> void:
	if _trace_tool == null:
		return
	var controls = _trace_tool.get("Controls")
	if controls == null or not controls is Dictionary:
		return
	if not controls.has("Image"):
		return
	var line_edit = controls["Image"]
	if line_edit != null and is_instance_valid(line_edit):
		line_edit.text = path


# ── Save ─────────────────────────────────────────────────────────────────

func _save_scale(val: float) -> void:
	var state = {}
	state["scale"] = val
	if _image_path != "":
		state["image"] = _image_path
	if _g.World != null and is_instance_valid(_g.World):
		var trace_img = _g.World.TraceImage
		if trace_img != null and is_instance_valid(trace_img) and trace_img.texture != null:
			state["position_x"] = trace_img.position.x
			state["position_y"] = trace_img.position.y
	if _trace_tool != null and _trace_tool.get("Opacity") != null:
		state["opacity"] = _trace_tool.Opacity.value
	state["anchor_top_left"] = _anchor_top_left
	if _anchor_top_left:
		state["anchor_x"] = _anchored_top_left.x
		state["anchor_y"] = _anchored_top_left.y
	state["stretched"] = _stretched
	if _stretched:
		state["stretch_x"] = _stretch_scale_x
		state["stretch_y"] = _stretch_scale_y
	state["layer_z"] = _layer_z
	state["blur"] = _blur_amount
	state["blend"] = _blend_mode
	state["rotation"] = _rotation_deg
	if _g.get("ModMapData") != null and _g.ModMapData is Dictionary:
		_g.ModMapData[SAVE_KEY] = state


func _persist_to_modmapdata() -> void:
	if _g.get("ModMapData") == null or not (_g.ModMapData is Dictionary):
		return
	if not _g.ModMapData.has(SAVE_KEY):
		return
	var state = _g.ModMapData[SAVE_KEY]
	if not state is Dictionary:
		return
	if _image_path != "":
		state["image"] = _image_path
	if _g.World != null and is_instance_valid(_g.World):
		var trace_img = _g.World.TraceImage
		if trace_img != null and is_instance_valid(trace_img) and trace_img.texture != null:
			state["position_x"] = trace_img.position.x
			state["position_y"] = trace_img.position.y
	if _trace_tool != null and _trace_tool.get("Opacity") != null:
		state["opacity"] = _trace_tool.Opacity.value
	state["anchor_top_left"] = _anchor_top_left
	if _anchor_top_left:
		state["anchor_x"] = _anchored_top_left.x
		state["anchor_y"] = _anchored_top_left.y
	state["stretched"] = _stretched
	if _stretched:
		state["stretch_x"] = _stretch_scale_x
		state["stretch_y"] = _stretch_scale_y
	state["layer_z"] = _layer_z
	state["blur"] = _blur_amount
	state["blend"] = _blend_mode
	state["rotation"] = _rotation_deg


func _get_saved_state():
	if _g.get("ModMapData") == null or not (_g.ModMapData is Dictionary):
		return null
	if not _g.ModMapData.has(SAVE_KEY):
		return null
	var d = _g.ModMapData[SAVE_KEY]
	return d if d is Dictionary else null


# ── Restore ──────────────────────────────────────────────────────────────

func _try_restore() -> void:
	if _g.World == null or not is_instance_valid(_g.World):
		return
	var trace_img = _g.World.TraceImage
	if trace_img == null or not is_instance_valid(trace_img):
		return
	if trace_img.texture == null:
		return

	_needs_restore = false
	var saved = _get_saved_state()
	if saved == null:
		_restoring = false
		return

	if saved.has("image") and saved["image"] != "":
		_image_path = saved["image"]
		_update_image_label(_image_path)

	if saved.has("anchor_top_left"):
		_anchor_top_left = bool(saved["anchor_top_left"])
	if saved.has("anchor_x") and saved.has("anchor_y"):
		_anchored_top_left = Vector2(saved["anchor_x"], saved["anchor_y"])
	if saved.has("stretched"):
		_stretched = bool(saved["stretched"])
	if saved.has("stretch_x") and saved.has("stretch_y"):
		_stretch_scale_x = float(saved["stretch_x"])
		_stretch_scale_y = float(saved["stretch_y"])

	if saved.has("layer_z"):
		_layer_z = int(saved["layer_z"])
		_sync_layer_ui()
		_apply_layer_z()

	if saved.has("blur"):
		_blur_amount = float(saved["blur"])
		_sync_blur_ui()
		_apply_blur()

	if saved.has("blend"):
		_blend_mode = int(saved["blend"])
		_sync_blend_ui()
		_apply_blur()

	if saved.has("rotation"):
		_rotation_deg = float(saved["rotation"])
		_sync_rotation_ui()
		_apply_rotation()

	if _scale_ctrl != null and is_instance_valid(_scale_ctrl):
		_scale_ctrl.min_value = EXTENDED_MIN
		_scale_ctrl.max_value = EXTENDED_MAX

	var sc = saved.get("scale", -1.0)
	if sc > 0:
		_target_value = sc
		_force_until = OS.get_ticks_msec() + RESTORE_FORCE_MS
		_force_value(sc)

	if saved.has("position_x") and saved.has("position_y"):
		_pending_position = true
		_pending_pos_x = saved["position_x"]
		_pending_pos_y = saved["position_y"]
		_pending_opacity = saved.get("opacity", -1.0)


func _apply_pending_position() -> void:
	if _g.World == null or not is_instance_valid(_g.World):
		return
	var trace_img = _g.World.TraceImage
	if trace_img == null or not is_instance_valid(trace_img):
		return
	trace_img.position = Vector2(_pending_pos_x, _pending_pos_y)
	if _pending_opacity >= 0 and _trace_tool != null and _trace_tool.has_method("SetOpacity"):
		_trace_tool.SetOpacity(_pending_opacity)


func _try_reload_trace_image() -> void:
	var saved = _get_saved_state()
	if saved == null:
		_restoring = false
		return
	var image_path = saved.get("image", "")
	if image_path == "" or image_path == null:
		_restoring = false
		return
	var f = File.new()
	if not f.file_exists(image_path):
		_restoring = false
		return
	if _trace_tool != null and _trace_tool.has_method("OnFileSelected"):
		_trace_tool.OnFileSelected("", image_path)
		_update_image_label(image_path)
	_needs_restore = true
	_restore_deadline = OS.get_ticks_msec() + 5000


# ── Force value ──────────────────────────────────────────────────────────

func _force_value(val: float) -> void:
	if _scale_ctrl == null or not is_instance_valid(_scale_ctrl):
		return
	if _scale_ctrl.min_value > val:
		_scale_ctrl.min_value = val
	if _scale_ctrl.max_value < val:
		_scale_ctrl.max_value = val
	if abs(_scale_ctrl.value - val) > 0.0001:
		_scale_ctrl.set_block_signals(true)
		_scale_ctrl.value = val
		_scale_ctrl.set_block_signals(false)
	if _anchor_top_left:
		_apply_scale_from_top_left(val)
	elif _stretched:
		_apply_scale_stretched(val)
	else:
		_sync_sprite(val)


func _sync_sprite(val: float) -> void:
	if _g.World == null or not is_instance_valid(_g.World):
		return
	var trace_img = _g.World.TraceImage
	if trace_img != null and is_instance_valid(trace_img):
		trace_img.scale = Vector2(val, val)


# ── Adaptive step sizes ─────────────────────────────────────────────────

func _get_step(val: float) -> float:
	if _precise_scaling:
		return 0.001
	if val < 0.01:  return 0.001
	if val < 0.1:   return 0.005
	if val < 0.5:   return 0.01
	if val < 1.0:   return 0.025
	if val < 2.0:   return 0.05
	if val < 5.0:   return 0.1
	if val < 10.0:  return 0.25
	if val < 20.0:  return 0.5
	return 1.0


# ── Scroll handling ──────────────────────────────────────────────────────

func _on_scroll(event: InputEvent) -> void:
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	if event.button_index != BUTTON_WHEEL_UP and event.button_index != BUTTON_WHEEL_DOWN:
		return
	if Input.is_key_pressed(KEY_CONTROL) or Input.is_key_pressed(KEY_SHIFT) or Input.is_key_pressed(KEY_ALT) or Input.is_key_pressed(KEY_Z):
		return
	if not _g.Editor or _g.Editor.ActiveToolName != "TraceImage":
		return
	# Don't intercept scroll when a SpinBox has focus (user is editing a value)
	var vp = _input_listener.get_viewport()
	if vp != null:
		var focused = vp.gui_get_focus_owner()
		if focused != null:
			if focused is SpinBox:
				return
			if focused is LineEdit and focused.get_parent() is SpinBox:
				return
	if ui_util and ui_util.is_mouse_over_ui(_input_listener):
		return
	if _g.World == null or not is_instance_valid(_g.World):
		return
	if _g.World.TraceImage == null or not is_instance_valid(_g.World.TraceImage):
		return
	_ensure_init()
	if _scale_ctrl == null or not is_instance_valid(_scale_ctrl):
		return

	var current = _target_value if _target_value >= 0 else _scale_ctrl.value
	var step = _get_step(current)
	var direction = 1.0 if event.button_index == BUTTON_WHEEL_UP else -1.0
	var new_val = current + step * direction
	new_val = stepify(new_val, step)
	new_val = clamp(new_val, EXTENDED_MIN, EXTENDED_MAX)

	_target_value = new_val
	_force_until = OS.get_ticks_msec() + FORCE_DURATION_MS
	_force_value(new_val)
	_save_scale(new_val)
	_input_listener.get_tree().set_input_as_handled()


# ── Public API ───────────────────────────────────────────────────────────

func set_value(val: float) -> void:
	_ensure_init()
	if _scale_ctrl == null or not is_instance_valid(_scale_ctrl):
		return
	val = clamp(val, EXTENDED_MIN, EXTENDED_MAX)
	_target_value = val
	_force_until = OS.get_ticks_msec() + FORCE_DURATION_MS
	_force_value(val)
	_save_scale(val)


func restore_bounds() -> void:
	if _scale_ctrl == null or not is_instance_valid(_scale_ctrl):
		return
	_scale_ctrl.min_value = _default_min
	_scale_ctrl.max_value = _default_max
	_target_value = -1.0


func get_current_scale() -> float:
	if _target_value >= 0:
		return _target_value
	_ensure_init()
	if _scale_ctrl == null or not is_instance_valid(_scale_ctrl):
		return 1.0
	return _scale_ctrl.value


# ── UNDO ────────────────────────────────────────────────────────────────

func _snapshot_state() -> Dictionary:
	# Capture every piece of trace state that any of our actions can
	# modify. Stored as plain values so the dict survives even if the
	# sprite gets recreated.
	var state := {
		"scale_value": (_scale_ctrl.value if _scale_ctrl != null and is_instance_valid(_scale_ctrl) else 1.0),
		"rotation_deg": _rotation_deg,
		"blur_amount": _blur_amount,
		"blend_mode": _blend_mode,
		"layer_z": _layer_z,
		"stretched": _stretched,
		"stretch_x": _stretch_scale_x,
		"stretch_y": _stretch_scale_y,
		"anchor_top_left": _anchor_top_left,
		"anchored_tl": _anchored_top_left,
	}
	# Capture the sprite's live transform too — position can drift
	# from the controls when the user drags the trace directly, so we
	# snapshot the actual node values rather than just the slider state.
	if _g.World != null and is_instance_valid(_g.World):
		var trace_img = _g.World.TraceImage
		if trace_img != null and is_instance_valid(trace_img):
			state["pos"] = trace_img.position
			state["sprite_scale"] = trace_img.scale
			state["sprite_rot"] = trace_img.rotation
			state["sprite_z"] = trace_img.z_index
			state["sprite_modulate"] = trace_img.modulate
	# Native opacity control (separate from the modulate — DD's tool
	# tracks its slider explicitly).
	if _trace_tool != null and is_instance_valid(_trace_tool):
		var op = _trace_tool.get("Opacity")
		if op != null and is_instance_valid(op):
			state["opacity_value"] = op.value
	return state


func _apply_state(state) -> void:
	# Restore every field captured by _snapshot_state. Mirrors the
	# logic of the various _on_*_changed handlers but bypasses signal
	# emission (we set values via set_block_signals so we don't echo
	# more records into history).
	if not (state is Dictionary):
		return
	_applying_undo = true
	# Restore internal flags first so any signal sync uses the right mode.
	_stretched = state.get("stretched", false)
	_stretch_scale_x = state.get("stretch_x", 1.0)
	_stretch_scale_y = state.get("stretch_y", 1.0)
	_anchor_top_left = state.get("anchor_top_left", false)
	_anchored_top_left = state.get("anchored_tl", Vector2.ZERO)
	_rotation_deg = state.get("rotation_deg", 0.0)
	_blur_amount = state.get("blur_amount", 0.0)
	_blend_mode = state.get("blend_mode", 0)
	_layer_z = state.get("layer_z", DEFAULT_LAYER_Z)
	# Apply directly to the sprite — this is the source of truth.
	if _g.World != null and is_instance_valid(_g.World):
		var trace_img = _g.World.TraceImage
		if trace_img != null and is_instance_valid(trace_img):
			if state.has("pos"):
				trace_img.position = state["pos"]
			if state.has("sprite_scale"):
				trace_img.scale = state["sprite_scale"]
			if state.has("sprite_rot"):
				trace_img.rotation = state["sprite_rot"]
			if state.has("sprite_z"):
				trace_img.z_index = state["sprite_z"]
			if state.has("sprite_modulate"):
				trace_img.modulate = state["sprite_modulate"]
	# Sync native scale slider without firing _on_scale_changed.
	if _scale_ctrl != null and is_instance_valid(_scale_ctrl) and state.has("scale_value"):
		_scale_ctrl.set_block_signals(true)
		_scale_ctrl.value = state["scale_value"]
		_scale_ctrl.set_block_signals(false)
	# Native opacity. DD's slider triggers the tool's internal apply
	# logic which we can't reach by setting the slider value with
	# signals blocked — TraceImage.SetOpacity on the tool is the
	# right entry point.
	if state.has("opacity_value"):
		var target_op = state["opacity_value"]
		# Sync the slider for the UI.
		if _trace_tool != null and is_instance_valid(_trace_tool):
			var op = _trace_tool.get("Opacity")
			if op != null and is_instance_valid(op):
				op.set_block_signals(true)
				op.value = target_op
				op.set_block_signals(false)
			if _trace_tool.has_method("SetOpacity"):
				_trace_tool.SetOpacity(target_op)
	# Sync our custom slider/spinbox UI.
	_sync_rotation_ui()
	_sync_blur_ui()
	_sync_blend_ui()
	_sync_layer_ui()
	_update_wh_sliders()
	# Reapply the blur shader effect (shader uniform may need update).
	_apply_blur()
	# Re-apply z-index in case sprite_z wasn't in state.
	_apply_layer_z()
	# Re-toggle the unlock-ratio button to match _stretched.
	if _unlock_ratio_toggle != null and is_instance_valid(_unlock_ratio_toggle):
		_unlock_ratio_toggle.set_pressed_no_signal(_stretched)
		if _width_row != null: _width_row.visible = _stretched
		if _height_row != null: _height_row.visible = _stretched
	_persist_to_modmapdata()
	_applying_undo = false


func _record_undo(before, after) -> void:
	# Push a callback record on DD's history. Caller is responsible for
	# making sure before and after actually differ — we don't want
	# zero-delta records polluting the stack.
	if before == null or after == null:
		return
	var undo_lib = null
	if _g != null and _g.get("ModMapData") != null:
		undo_lib = _g.ModMapData.get("_undo_lib")
	if undo_lib == null:
		return
	undo_lib.record_callback(
		self, "_apply_state", [before],
		self, "_apply_state", [after])


func _states_equal(a, b) -> bool:
	# Cheap-enough equality check to skip recording a no-op.
	if not (a is Dictionary) or not (b is Dictionary):
		return false
	for k in a:
		if not b.has(k):
			return false
		if a[k] != b[k]:
			return false
	for k in b:
		if not a.has(k):
			return false
	return true


# ── Slider drag tracking ────────────────────────────────────────────────

func _attach_slider_undo(slider) -> void:
	# Hook a slider so we open a drag snapshot on mouse-down and close
	# it (registering a record) on mouse-up. Using gui_input is
	# the most reliable way to bracket a drag — value_changed fires
	# many times during the gesture but doesn't tell us when it ends.
	if slider == null or not is_instance_valid(slider):
		return
	if slider.is_connected("gui_input", self, "_on_slider_gui_input"):
		return
	slider.connect("gui_input", self, "_on_slider_gui_input", [slider])


func _on_slider_gui_input(event, slider) -> void:
	if not (event is InputEventMouseButton):
		return
	if event.button_index != BUTTON_LEFT:
		return
	if event.pressed:
		# Drag starts. Snapshot now if no drag is already open.
		if _drag_snapshot == null:
			_drag_snapshot = _snapshot_state()
			_drag_slider = slider
	else:
		# Drag ends. Record the diff and clear the snapshot.
		if _drag_snapshot != null and _drag_slider == slider:
			var after = _snapshot_state()
			if not _states_equal(_drag_snapshot, after):
				_record_undo(_drag_snapshot, after)
			_drag_snapshot = null
			_drag_slider = null


# ── Button action wrapper ───────────────────────────────────────────────

func _button_undo_wrap(callable_name: String) -> void:
	# connect-friendly: snapshot before calling the named handler,
	# then record on history. Use it as: btn.connect("pressed",
	# self, "_button_undo_wrap", ["_on_xxx"]).
	var before = _snapshot_state()
	call(callable_name)
	if _applying_undo:
		return
	var after = _snapshot_state()
	if not _states_equal(before, after):
		_record_undo(before, after)


func _toggle_undo_wrap(pressed: bool, callable_name: String) -> void:
	# Same as _button_undo_wrap but for "toggled(bool)" signals.
	var before = _snapshot_state()
	call(callable_name, pressed)
	if _applying_undo:
		return
	var after = _snapshot_state()
	if not _states_equal(before, after):
		_record_undo(before, after)


func _wrap_button_undo(callable_name: String) -> void:
	# Helper: snapshot state, call the named method, then record.
	# Used by buttons whose handlers don't return anything we care
	# about and which produce a single discrete change.
	var before = _snapshot_state()
	call(callable_name)
	if _applying_undo:
		return
	var after = _snapshot_state()
	if not _states_equal(before, after):
		_record_undo(before, after)
