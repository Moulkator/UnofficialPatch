# select_filter_bar.gd
# A repositionable horizontal bar of asset-type filter checkboxes for the
# Select Tool. Mirrors the FILTER popup that already lives in the SelectTool
# panel, but keeps every type visible at once as a draggable bar. Only shown
# while the SelectTool is active.
#
# The 7 native types live in selectTool.Filter (dict). "Text" is driven through
# the FILTER popup's "Texts" item, which text_transform.gd polls — so the Text
# checkbox only appears when that mod has registered the item.
#
# Interaction is handled manually via a high-priority input listener: DD's
# SelectTool consumes mouse events in _input (its native "mouse over UI" check
# doesn't know about our floating bar), so we intercept clicks over the bar
# first and drive the checkboxes ourselves.
#
# Toggled from the bottom floatbar ("Filters" button), like Grid Ruler /
# Overlay Tool. Enabled state + position persist to disk.

var _g
var ui_util

const _SETTINGS_FILE = "user://UnofficialPatch/select_filter_bar.json"

# Native filter keys (== selectTool.Filter keys == FILTER popup item texts).
const _FILTER_KEYS = ["Walls", "Portals", "Objects", "Paths", "Lights", "Patterns", "Roofs"]
const _ALL_KEY  = "__ALL__"
const _TEXT_KEY = "Text"          # bar label
const _TEXT_ITEM = "Texts"        # FILTER popup item text (from text_transform)

# ── Colors ──────────────────────────────────────────────────────────────────
const BG_ALPHA = 0.35   # translucency of the themed background (blur shows behind)

# ── State ───────────────────────────────────────────────────────────────────
var _enabled       := false
var _pos           := Vector2(-1, -1)
var _canvas_layer  : CanvasLayer = null
var _panel         : PanelContainer = null
var _grip          : Control = null
var _processor     : Control = null
var _input_listener: Node = null
var _bar_button    : CheckButton = null
var _checks        := {}    # key -> CheckBox  (incl. _ALL_KEY and _TEXT_KEY)
var _filter_menu   : PopupMenu = null
var _dragging      := false
var _drag_offset   := Vector2.ZERO
var _over_bar       := false
var _was_shown      := false
var _applying      := false
var _styled        := false
var _cur_scale     := 1.0
var _destroyed     := false


func initialize() -> void:
	_load_settings()
	_create_bar()
	_install_processor()
	_install_input_listener()
	call_deferred("_try_inject_bar_button", 0)
	print("[SelectFilterBar] Initialized (enabled=%s)" % str(_enabled))


func cleanup() -> void:
	_destroyed = true
	_enabled = false
	_publish_ui_rect(null)
	if _canvas_layer != null and is_instance_valid(_canvas_layer):
		_canvas_layer.queue_free()
	_canvas_layer = null
	_panel = null
	_grip = null
	_checks = {}
	if _processor != null and is_instance_valid(_processor):
		_processor.handler = null
		_processor.queue_free()
	_processor = null
	if _input_listener != null and is_instance_valid(_input_listener):
		_input_listener.handler = null
		_input_listener.queue_free()
	_input_listener = null
	if _bar_button != null and is_instance_valid(_bar_button):
		_bar_button.queue_free()
	_bar_button = null
	print("[SelectFilterBar] Cleaned up")


# ── Bar construction ─────────────────────────────────────────────────────────

func _create_bar() -> void:
	_canvas_layer = CanvasLayer.new()
	_canvas_layer.name = "SelectFilterBarLayer"
	_canvas_layer.layer = 50

	_panel = PanelContainer.new()
	_panel.name = "SelectFilterBar"
	if _g.get("Theme") != null:
		_panel.theme = _g.Theme
	_apply_panel_style()
	_panel.visible = false

	var hbox = HBoxContainer.new()
	hbox.add_constant_override("separation", 9)
	_panel.add_child(hbox)

	# Drag grip (no font glyph — a styled bar).
	_grip = Control.new()
	_grip.rect_min_size = Vector2(13, 22)
	_grip.size_flags_vertical = Control.SIZE_FILL
	_grip.mouse_default_cursor_shape = Control.CURSOR_MOVE
	var gscript = GDScript.new()
	gscript.source_code = "extends Control\nfunc _draw():\n\tvar c = Color(0.62,0.62,0.68,0.85)\n\tvar w = 3.0\n\tvar x0 = (rect_size.x - 2.0*w - 3.0) * 0.5\n\tfor col in range(2):\n\t\tfor row in range(3):\n\t\t\tvar p = Vector2(x0 + col*(w+3.0), rect_size.y*0.5 - 7.0 + row*7.0)\n\t\t\tdraw_rect(Rect2(p, Vector2(w, w)), c)\n"
	gscript.reload()
	_grip.set_script(gscript)
	hbox.add_child(_grip)

	hbox.add_child(VSeparator.new())

	# "All" toggle.
	_add_check(hbox, _ALL_KEY, "All")
	hbox.add_child(VSeparator.new())

	# Native type toggles.
	for key in _FILTER_KEYS:
		_add_check(hbox, key, key)

	# "Text" toggle — hidden until text_transform registers the popup item.
	_add_check(hbox, _TEXT_KEY, _TEXT_KEY)
	_checks[_TEXT_KEY].visible = false

	_canvas_layer.add_child(_panel)
	_panel.connect("minimum_size_changed", self, "_on_panel_min_changed")

	var tree = _g.World.get_tree() if _g.World else null
	if tree != null and tree.root != null:
		tree.root.call_deferred("add_child", _canvas_layer)


func _add_check(parent: Control, key: String, label: String) -> void:
	var cb = CheckBox.new()
	cb.text = label
	cb.focus_mode = Control.FOCUS_NONE
	cb.pressed = true
	cb.connect("toggled", self, "_on_check_toggled", [key])
	parent.add_child(cb)
	_checks[key] = cb


func _install_processor() -> void:
	_processor = Control.new()
	_processor.name = "SelectFilterBarProc"
	_processor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var script = GDScript.new()
	script.source_code = "extends Control\nvar handler = null\nfunc _ready():\n\tset_process(true)\nfunc _process(_d):\n\tif handler != null:\n\t\thandler._tick()\n"
	script.reload()
	_processor.set_script(script)
	_processor.handler = self
	if _canvas_layer != null:
		_canvas_layer.call_deferred("add_child", _processor)


func _install_input_listener() -> void:
	_input_listener = Node.new()
	_input_listener.name = "SelectFilterBarInput"
	var script = GDScript.new()
	script.source_code = "extends Node\nvar handler = null\nfunc _ready():\n\tset_process_input(true)\n\tprocess_priority = -250\nfunc _input(e):\n\tif handler != null:\n\t\thandler._on_input(e)\n"
	script.reload()
	_input_listener.set_script(script)
	_input_listener.handler = self
	if _g.World:
		_g.World.call_deferred("add_child", _input_listener)


# ── Manual input (intercept clicks over the bar before DD's SelectTool) ──────

func _on_input(event) -> void:
	if _destroyed or _panel == null or not is_instance_valid(_panel) or not _panel.visible:
		return
	if not (event is InputEventMouseButton or event is InputEventMouseMotion):
		return
	var m = _mouse_pos()
	var over = _vis_rect(_panel).has_point(m)

	if event is InputEventMouseMotion:
		if _dragging:
			_update_drag(m)
			_consume()
		elif over:
			_consume()   # block hover-selection under the bar
		return

	# Mouse button
	if event.button_index == BUTTON_LEFT:
		if event.pressed:
			if not over:
				return
			_handle_press(m)
			_consume()
		else:
			if _dragging:
				_dragging = false
				_save_settings()
				_consume()
			elif over:
				_consume()
	elif over:
		_consume()   # swallow other buttons over the bar


func _handle_press(m: Vector2) -> void:
	if _grip != null and _vis_rect(_grip).has_point(m):
		_dragging = true
		_drag_offset = m - _panel.get_global_position()
		return
	for key in _checks.keys():
		var cb = _checks[key]
		if cb != null and is_instance_valid(cb) and cb.visible and _vis_rect(cb).has_point(m):
			cb.pressed = not cb.pressed   # fires toggled -> _on_check_toggled
			return


func _update_drag(m: Vector2) -> void:
	var vp = _viewport_size()
	var size = _panel.rect_size * _cur_scale
	var p = m - _drag_offset
	p.x = clamp(p.x, 0.0, max(0.0, vp.x - size.x))
	p.y = clamp(p.y, 0.0, max(0.0, vp.y - size.y))
	_pos = p
	_panel.rect_position = p


# Visual (on-screen) rect of a node inside the panel, accounting for the panel's
# rect_scale — get_global_rect() would mix a scaled position with an unscaled
# size and mis-hit.
func _vis_rect(node: Control) -> Rect2:
	return Rect2(node.get_global_position(), node.rect_size * _cur_scale)


func _consume() -> void:
	if _input_listener != null and is_instance_valid(_input_listener):
		var tree = _input_listener.get_tree()
		if tree != null:
			tree.set_input_as_handled()


func _mouse_pos() -> Vector2:
	if _processor != null and is_instance_valid(_processor):
		return _processor.get_viewport().get_mouse_position()
	return Vector2.ZERO


# ── Per-frame: visibility + sync from sources ────────────────────────────────

func _tick() -> void:
	if _destroyed or _panel == null or not is_instance_valid(_panel):
		return
	var show = _enabled and _is_select_active()
	if _panel.visible != show:
		_panel.visible = show
	if not show:
		_over_bar = false
		_was_shown = false
		_publish_ui_rect(null)
		return
	_maybe_finalize_style()
	if not _was_shown:
		_was_shown = true
		call_deferred("_resize_to_content")
	# Scale the whole bar to match the floatbar's current size (this is how it
	# follows ui_rescaler) — a single uniform transform, so it can never clip or
	# garble the labels the way per-node rescaling did.
	_cur_scale = _compute_scale()
	_panel.rect_pivot_offset = Vector2.ZERO
	_panel.rect_scale = Vector2(_cur_scale, _cur_scale)
	if _pos.x < 0:
		_pos = _default_position()
	_panel.rect_position = _pos
	_publish_ui_rect(_vis_rect(_panel))

	# When the cursor enters the bar, clear DD's lingering hover highlight.
	# (Motion over the bar is swallowed in _on_input, so DD never updates it.)
	var over = _vis_rect(_panel).has_point(_mouse_pos())
	if over and not _over_bar:
		_clear_dd_highlight()
	_over_bar = over

	# While panning, pan_fix temporarily blanks selectTool.Filter (to no-op DD's
	# hover scan and save frames). That's invisible to the real state, so don't
	# mirror it onto the checkboxes — leave them as they were until the pan ends.
	if _is_panning():
		return

	_applying = true
	# Native types.
	var all_on = true
	for key in _FILTER_KEYS:
		var v = _filter_state(key)
		_set_check_silent(key, v)
		if not v:
			all_on = false
	# Text (only when the popup item exists).
	var text_idx = _text_item_index()
	var text_cb = _checks.get(_TEXT_KEY)
	if text_cb != null and is_instance_valid(text_cb):
		var has_text = text_idx >= 0
		if text_cb.visible != has_text:
			text_cb.visible = has_text
		if has_text:
			var tv = bool(_filter_menu.is_item_checked(text_idx))
			_set_check_silent(_TEXT_KEY, tv)
			if not tv:
				all_on = false
	_set_check_silent(_ALL_KEY, all_on)
	_applying = false


func _set_check_silent(key: String, v: bool) -> void:
	var cb = _checks.get(key)
	if cb == null or not is_instance_valid(cb):
		return
	if cb.pressed != v:
		cb.set_block_signals(true)
		cb.pressed = v
		cb.set_block_signals(false)


func _default_position() -> Vector2:
	var vp = _viewport_size()
	var w = _panel.get_combined_minimum_size().x * _cur_scale
	return Vector2(max(0.0, (vp.x - w) * 0.5), 70.0)


# Visual scale that matches the floatbar: ratio of a floatbar toggle's current
# (ui_rescaler-adjusted) height to our own checkbox's natural height. Because
# both are themed CheckBoxes, any shared scaling cancels out, leaving exactly
# the extra factor ui_rescaler applied to the floatbar.
func _compute_scale() -> float:
	var ref = null
	if _g.Editor != null and is_instance_valid(_g.Editor):
		ref = _g.Editor.get_node_or_null("Floatbar/Floatbar/Align/GridToggle")
	var mine = _checks.get(_ALL_KEY)
	if ref is Control and is_instance_valid(ref) and mine is Control and is_instance_valid(mine) \
			and ref.rect_size.y > 1.0 and mine.rect_size.y > 1.0:
		return clamp(ref.rect_size.y / mine.rect_size.y, 0.5, 4.0)
	return _cur_scale


func _viewport_size() -> Vector2:
	if _processor != null and is_instance_valid(_processor):
		return _processor.get_viewport_rect().size
	return Vector2(1280, 720)


# Panel background: the DD theme's own panel colour (the one picked in
# Preferences), made translucent. Not a flat grey — it follows the chosen theme
# and lets the map show through.
func _apply_panel_style() -> void:
	if _panel == null or not is_instance_valid(_panel):
		return
	var style = _get_theme_panel_style()
	style.content_margin_left = 8
	style.content_margin_right = 10
	style.content_margin_top = 5
	style.content_margin_bottom = 5
	_panel.add_stylebox_override("panel", style)


# A StyleBoxFlat in the current DD theme's panel colour, alpha lowered so the
# background is translucent. Falls back to a neutral translucent box.
func _get_theme_panel_style() -> StyleBoxFlat:
	var src = _theme_panel_stylebox()
	var style : StyleBoxFlat
	if src != null:
		style = src.duplicate()
		style.bg_color.a = BG_ALPHA
	else:
		style = StyleBoxFlat.new()
		style.bg_color = Color(0.13, 0.14, 0.17, BG_ALPHA)
		style.set_corner_radius_all(6)
	return style


func _theme_panel_stylebox():
	if _g.get("Theme") == null:
		return null
	var th = _g.Theme
	for type in ["PanelContainer", "Panel", "TooltipPanel", "WindowDialog"]:
		if th.has_stylebox("panel", type):
			var sb = th.get_stylebox("panel", type)
			if sb is StyleBoxFlat:
				return sb
	return null


func _theme_panel_color() -> Color:
	var sb = _theme_panel_stylebox()
	if sb != null:
		return sb.bg_color
	return Color(0.13, 0.14, 0.17, 1.0)


# One-shot: DD theme + a frosted (blurred) backdrop tinted with the theme
# colour, then our translucent themed stylebox on top. Deferred until the bar
# first shows, so the theme/floatbar are ready.
func _maybe_finalize_style() -> void:
	if _styled or _panel == null or not is_instance_valid(_panel):
		return
	if not _panel.is_inside_tree():
		return
	if _g.get("Theme") != null:
		_panel.theme = _g.Theme
	# Pin each checkbox's font to a private copy so DD's Enlarge UI / ui_rescaler
	# (which mutate fonts) can't change our internal layout — we do all visual
	# scaling ourselves via rect_scale, keeping the content size constant.
	for cb in _checks.values():
		if is_instance_valid(cb):
			var tf = cb.get_font("font")
			if tf is DynamicFont:
				cb.add_font_override("font", tf.duplicate())
	if Engine.has_meta("popup_blur_singleton"):
		var pb = Engine.get_meta("popup_blur_singleton")
		if pb != null and is_instance_valid(pb) and pb.has_method("register"):
			var tc = _theme_panel_color()
			pb.register(_panel, {"tint": Color(tc.r, tc.g, tc.b, 0.30)})
	_apply_panel_style()   # themed translucent stylebox, over popup_blur's
	_styled = true
	call_deferred("_resize_to_content")


# Resize the panel to its content. Always deferred so it runs AFTER layout (and
# after ui_rescaler has finished adjusting the checkboxes), never racing the
# baseline capture — which is what left the background stuck at the wrong size.
func _resize_to_content() -> void:
	if _panel != null and is_instance_valid(_panel) and _panel.visible:
		_panel.rect_size = _panel.get_combined_minimum_size()


func _on_panel_min_changed() -> void:
	call_deferred("_resize_to_content")


# Register (or clear) the bar's screen rect in a shared registry so that
# ui_util.is_mouse_over_ui — and therefore overlay_tool's hover highlights and
# any other mod that respects it — treats the bar as UI.
func _publish_ui_rect(rect) -> void:
	var mmd = _g.get("ModMapData") if _g != null else null
	if mmd == null or not (mmd is Dictionary):
		return
	if not mmd.has("_extra_ui_rects") or not (mmd["_extra_ui_rects"] is Dictionary):
		mmd["_extra_ui_rects"] = {}
	if rect == null:
		mmd["_extra_ui_rects"].erase("select_filter_bar")
	else:
		mmd["_extra_ui_rects"]["select_filter_bar"] = rect


# ── Filter source read/write ─────────────────────────────────────────────────

func _on_check_toggled(pressed: bool, key: String) -> void:
	if _applying:
		return
	if key == _ALL_KEY:
		_apply_all(pressed)
		return
	if key == _TEXT_KEY:
		_set_text_filter(pressed)
		return
	_set_native_filter(key, pressed)


func _apply_all(v: bool) -> void:
	for key in _FILTER_KEYS:
		_set_native_filter(key, v)
	if _text_item_index() >= 0:
		_set_text_filter(v)


func _filter_state(key: String) -> bool:
	var st = _select_tool()
	if st == null:
		return true
	var filter = st.get("Filter")
	if filter != null and filter.has(key):
		return bool(filter[key])
	return true


# The C# SelectTool.Filter dict reaches GDScript only as a copy, so writing it
# here doesn't stick. Instead we fire the FILTER popup's "id_pressed" signal,
# which runs DD's own SetFilterChecked handler and mutates the real C# dict.
func _set_native_filter(key: String, v: bool) -> void:
	var idx = _native_item_index(key)
	if idx < 0:
		return
	if bool(_filter_menu.is_item_checked(idx)) != v:
		_filter_menu.emit_signal("id_pressed", idx)


func _set_text_filter(v: bool) -> void:
	# text_transform.gd polls the popup checkmark directly — set it, don't emit
	# (emitting would add a stray "Texts" key to DD's native filter dict).
	var idx = _text_item_index()
	if idx >= 0:
		_filter_menu.set_item_checked(idx, v)


func _native_item_index(key: String) -> int:
	var menu = _get_filter_menu()
	if menu == null:
		return -1
	for i in range(menu.get_item_count()):
		if menu.get_item_text(i) == key:
			return i
	return -1


# Clear DD's current hover highlight without changing the user's filter state:
# momentarily blank the native filters, run one DD motion (clears + finds
# nothing), then restore. Used when the cursor moves onto the bar.
func _clear_dd_highlight() -> void:
	var st = _select_tool()
	if st == null or not st.has_method("_ContentInput"):
		return
	var menu = _get_filter_menu()
	var restore := []
	if menu != null:
		for key in _FILTER_KEYS:
			var idx = _native_item_index(key)
			if idx >= 0 and bool(menu.is_item_checked(idx)):
				menu.emit_signal("id_pressed", idx)
				restore.append(idx)
	st._ContentInput(InputEventMouseMotion.new())
	for idx in restore:
		menu.emit_signal("id_pressed", idx)


func _text_item_index() -> int:
	var menu = _get_filter_menu()
	if menu == null:
		return -1
	for i in range(menu.get_item_count()):
		if menu.get_item_text(i) == _TEXT_ITEM:
			return i
	return -1


func _get_filter_menu() -> PopupMenu:
	if _filter_menu != null and is_instance_valid(_filter_menu):
		return _filter_menu
	var toolset = _g.Editor.get("Toolset") if _g.Editor else null
	if toolset == null or not toolset.has_method("GetToolPanel"):
		return null
	var panel = toolset.GetToolPanel("SelectTool")
	if panel == null or not is_instance_valid(panel):
		return null
	_filter_menu = _find_filter_menu(panel)
	return _filter_menu


func _find_filter_menu(node):
	if node is MenuButton and str(node.text) == "FILTER":
		return node.get_popup()
	for child in node.get_children():
		var found = _find_filter_menu(child)
		if found != null:
			return found
	return null


# ── Tool detection ───────────────────────────────────────────────────────────

func _is_select_active() -> bool:
	if _g.Editor == null or not is_instance_valid(_g.Editor):
		return false
	return str(_g.Editor.get("ActiveToolName")) == "SelectTool"


# True while pan_fix is panning the map (it sets this shared flag).
func _is_panning() -> bool:
	var mmd = _g.get("ModMapData") if _g != null else null
	return mmd is Dictionary and bool(mmd.get("_pan_active", false))


func _select_tool():
	if _g.Editor == null or not is_instance_valid(_g.Editor):
		return null
	var tools = _g.Editor.get("Tools")
	if tools == null:
		return null
	return tools.get("SelectTool")


# ── Floatbar button (clone of a labelled toggle next to Grid/Snap) ──────────

func _try_inject_bar_button(attempt: int) -> void:
	if not _bar_button_setting_enabled():
		return
	if attempt > 25:
		print("[SelectFilterBar] Bar button injection gave up after 25 attempts")
		return
	if _bar_button != null and is_instance_valid(_bar_button):
		return

	var zoom_opts = _g.Editor.get("ZoomOptions") if _g.Editor else null
	if zoom_opts == null or not is_instance_valid(zoom_opts):
		_retry_inject_bar_button(attempt)
		return
	var parent = zoom_opts.get_parent()
	if parent == null or not is_instance_valid(parent):
		_retry_inject_bar_button(attempt)
		return

	var zoom_idx : int = zoom_opts.get_index()
	var insert_idx : int = zoom_idx
	var reference_btn : Node = null
	for i in range(zoom_idx - 1, -1, -1):
		var child = parent.get_child(i)
		if child is BaseButton and child.get("toggle_mode") == true:
			var txt = str(child.get("text")) if child.get("text") != null else ""
			if txt != "":
				reference_btn = child
				insert_idx = i + 1
				break

	if reference_btn != null:
		_bar_button = reference_btn.duplicate()
		_disconnect_all_signals(_bar_button)
		if _bar_button.get("icon") != null:
			_bar_button.set("icon", null)
		if _bar_button.get("shortcut") != null:
			_bar_button.set("shortcut", null)
	else:
		_bar_button = CheckButton.new()

	_bar_button.text = "Filters"
	_bar_button.hint_tooltip = "Select Tool filter bar"
	_bar_button.pressed = _enabled
	_bar_button.focus_mode = Control.FOCUS_NONE
	_bar_button.connect("toggled", self, "_on_bar_button_toggled")
	parent.add_child(_bar_button)
	parent.move_child(_bar_button, insert_idx)
	print("[SelectFilterBar] Bar button injected at index %d" % insert_idx)


func _disconnect_all_signals(n: Object) -> void:
	if n == null:
		return
	for sig in n.get_signal_list():
		var conns = n.get_signal_connection_list(sig.name)
		for c in conns:
			if n.is_connected(sig.name, c.target, c.method):
				n.disconnect(sig.name, c.target, c.method)


func set_bar_button_enabled(on: bool) -> void:
	if on:
		if _bar_button == null or not is_instance_valid(_bar_button):
			_try_inject_bar_button(0)
	else:
		if _bar_button != null and is_instance_valid(_bar_button):
			_bar_button.queue_free()
		_bar_button = null


func _bar_button_setting_enabled() -> bool:
	var ms = null
	if _g.get("ModMapData") != null and _g.ModMapData is Dictionary:
		ms = _g.ModMapData.get("_mod_settings")
	if ms == null or not ms.has_method("is_enabled"):
		return true
	return ms.is_enabled("select_filter_bar_bar_button")


func _retry_inject_bar_button(attempt: int) -> void:
	var tree = _g.World.get_tree() if _g.World else null
	if tree == null:
		return
	var t = tree.create_timer(0.3)
	t.connect("timeout", self, "_try_inject_bar_button", [attempt + 1])


func _on_bar_button_toggled(pressed: bool) -> void:
	if pressed == _enabled:
		return
	_toggle()


func _toggle() -> void:
	_enabled = not _enabled
	_sync_bar_button()
	_save_settings()
	print("[SelectFilterBar] %s" % ("enabled" if _enabled else "disabled"))


func _sync_bar_button() -> void:
	if _bar_button == null or not is_instance_valid(_bar_button):
		return
	if _bar_button.pressed == _enabled:
		return
	if _bar_button.has_method("set_pressed_no_signal"):
		_bar_button.set_pressed_no_signal(_enabled)
	else:
		_bar_button.set_block_signals(true)
		_bar_button.pressed = _enabled
		_bar_button.set_block_signals(false)


# ── Settings persistence ─────────────────────────────────────────────────────

func _save_settings() -> void:
	var data = {"enabled": _enabled, "pos_x": _pos.x, "pos_y": _pos.y}
	var dir = Directory.new()
	if not dir.dir_exists("user://UnofficialPatch"):
		dir.make_dir_recursive("user://UnofficialPatch")
	var f = File.new()
	if f.open(_SETTINGS_FILE, File.WRITE) == OK:
		f.store_string(JSON.print(data))
		f.close()


func _load_settings() -> void:
	var f = File.new()
	if f.open(_SETTINGS_FILE, File.READ) != OK:
		return
	var text = f.get_as_text()
	f.close()
	var parsed = JSON.parse(text)
	if parsed.error != OK or not (parsed.result is Dictionary):
		return
	var d : Dictionary = parsed.result
	if d.has("enabled"):
		_enabled = bool(d["enabled"])
	if d.has("pos_x") and d.has("pos_y"):
		_pos = Vector2(float(d["pos_x"]), float(d["pos_y"]))
