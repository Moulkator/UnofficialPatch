# popup_blur.gd
# Blur Gaussien des fenêtres Dungeondraft.
#
# Trois modes :
# - "Remplacé" : popups avec BlurScreen natif → gaussien multi-passes.
# - "Injecté (behind)" : WindowDialog sans BlurScreen → blur rects avec
#   show_behind_parent + panel semi-transparent.
# - "Injecté (material)" : AcceptDialog/ConfirmationDialog → shader material
#   sur le popup + overlay toplevel pour la title bar.
#
# La teinte est lue depuis les shaders BlurScreen natifs de DD et appliquée
# uniformément à tous les popups. L'alpha est boostée via une courbe
# non-linéaire par points de contrôle :
#   31% → 62%,  50% → 73%,  70% → 85%,  100% → 98%
# Mise à jour en temps réel via références aux materials natifs DD.
#
# API pour mods externes :
#   popup_blur.register(my_popup)
#   popup_blur.register(my_popup, { "passes": 2, "step_px": 1.5, "sigma": 5.0, "tint": Color(0,0,0,0.4) })

var _g

const EXTRA_PASSES = 8
const STEP_PX      = 1.5
const SIGMA        = 5.0

# Diag : mettre à true pour réactiver des logs verbeux si un bug similaire réapparaît.
const DIAG_ENABLED = false

const GAUSS_CODE = """
shader_type canvas_item;
uniform float step_px    : hint_range(0.5, 10.0) = 3.0;
uniform float sigma      : hint_range(0.5, 8.0)  = 3.0;
uniform vec4  tint_color : hint_color = vec4(0.0, 0.0, 0.0, 0.0);

const int HALF = 6;

void fragment() {
	vec2  ps     = SCREEN_PIXEL_SIZE * step_px;
	vec3  col    = vec3(0.0);
	float total  = 0.0;
	float inv2s2 = 1.0 / (2.0 * sigma * sigma);

	for (int x = -HALF; x <= HALF; x++) {
		for (int y = -HALF; y <= HALF; y++) {
			float w = exp(-float(x * x + y * y) * inv2s2);
			col   += texture(SCREEN_TEXTURE,
				SCREEN_UV + vec2(float(x), float(y)) * ps).rgb * w;
			total += w;
		}
	}

	col /= total;
	COLOR.rgb = mix(col, tint_color.rgb, tint_color.a);
	COLOR.a   = 1.0;
}
"""

var _gauss_shader   = null
var _patched_ids    := {}
var _startup_timer  := 0.0
var _check_timer    := 0.0
const CHECK_INTERVAL = 3.0  # Scan profond moins fréquent (le signal gère le reste)
const NO_TINT        = Color(0.0, 0.0, 0.0, 0.0)
const DEFAULT_TINT   = Color(0.0, 0.0, 0.0, 0.31)

# Hook sur le node Windows pour scan rapide
var _windows_hooked  := false

# Teinte native DD (lue depuis BlurScreen)
var _native_tint     := DEFAULT_TINT

# Références aux materials BlurScreen natifs de DD (pour tracking temps réel).
# Même après remplacement, DD peut les mettre à jour si c'est une ressource partagée.
var _native_blur_refs := []

# Toutes les ShaderMaterial avec teinte (pour mise à jour temps réel)
# [weakref(mat), is_tinted]
var _tinted_mats     := []

# Overlays actifs pour les title bars AcceptDialog
var _title_overlays  := {}


func initialize() -> void:
	var blurscreen = ResourceLoader.load("res://shaders/BlurScreen.shader", "Shader", true)
	if blurscreen == null:
		print("[PopupBlur] ERREUR : BlurScreen.shader introuvable")
		return
	_gauss_shader = blurscreen.duplicate()
	_gauss_shader.code = GAUSS_CODE
	# Charger les settings avant de patcher les popups
	_load_blur_settings()

	# Hook indépendant : idle_frame du SceneTree. Ça garantit qu'update() tourne
	# chaque frame même si un mod antérieur dans Main.update bloque la chaîne.
	var tree = Engine.get_main_loop()
	if tree != null and not tree.is_connected("idle_frame", self, "_on_tree_idle_frame"):
		tree.connect("idle_frame", self, "_on_tree_idle_frame")
		_idle_hooked = true
		print("[PopupBlur] idle_frame hook actif")

	# Exposer self pour que d'autres mods (compare_fix, etc.) puissent appeler
	# register() sur des popups qui ne sont pas dans Master/Editor/Windows.
	Engine.set_meta("popup_blur_singleton", self)

	print("[PopupBlur] initialized — sigma=", _current_sigma)


var _idle_hooked := false
var _last_update_frame := -1
var _last_idle_time_ms := 0
var _last_world_id := -1


func _on_map_changed() -> void:
	# DD a recréé le World. Tous les popups, notre slider Preferences, et nos
	# matériaux gauss attachés à l'ancienne hiérarchie sont freed. Reset complet
	# pour permettre re-patching et re-création du slider sur la nouvelle UI.
	print("[PopupBlur] World changed → reset state")
	_patched_ids.clear()
	_native_blur_refs.clear()
	_native_tint = DEFAULT_TINT
	_windows_hooked = false
	_windows_ref = null
	_prefs_hooked = false
	_prefs_dialog = null
	_sigma_slider = null
	_sigma_spinbox = null
	_window_bg_tint_btn = null
	# Purge weakrefs morts (les nouveaux matériaux seront ré-ajoutés au patching).
	var alive := []
	for entry in _tinted_mats:
		if entry[0].get_ref() != null:
			alive.append(entry)
	_tinted_mats = alive
	# Title overlays : leurs popups sont freed, on nettoie.
	for id in _title_overlays.keys():
		var data = _title_overlays[id]
		if data.has("container") and is_instance_valid(data["container"]):
			data["container"].queue_free()
	_title_overlays.clear()


func _on_tree_idle_frame() -> void:
	if _gauss_shader == null:
		return
	var now_ms = OS.get_ticks_msec()
	var delta = 0.016
	if _last_idle_time_ms > 0:
		delta = (now_ms - _last_idle_time_ms) / 1000.0
	_last_idle_time_ms = now_ms
	update(delta)


# ── Boost non-linéaire (courbe par points de contrôle) ───────────────────────

func _boost_alpha(a: float) -> float:
	# Points de contrôle :
	#   0.00 → 0.00    (transparent reste transparent)
	#   0.31 → 0.62    (défaut DD doublé)
	#   0.70 → 0.85    (décroissance rapide)
	#   1.00 → 0.98    (jamais totalement opaque)
	if a <= 0.0:
		return 0.0
	if a <= 0.31:
		return lerp(0.0, 0.62, a / 0.31)
	if a <= 0.70:
		return lerp(0.62, 0.85, (a - 0.31) / (0.70 - 0.31))
	return lerp(0.85, 0.98, min((a - 0.70) / 0.30, 1.0))


func _boosted_tint() -> Color:
	return Color(
		_native_tint.r,
		_native_tint.g,
		_native_tint.b,
		_boost_alpha(_native_tint.a)
	)


func _set_native_tint(color: Color) -> void:
	if color.is_equal_approx(_native_tint):
		return
	_native_tint = color
	print("[PopupBlur] Teinte native : ", color, " → boostée : ", _boosted_tint())
	_refresh_all_tints()


func _refresh_all_tints() -> void:
	var boosted = _boosted_tint()
	var alive = []
	for entry in _tinted_mats:
		var mat = entry[0].get_ref()
		if mat == null or not (mat is ShaderMaterial):
			continue
		alive.append(entry)
		if entry[1]:
			mat.set_shader_param("tint_color", boosted)
	_tinted_mats = alive


# ── Tracking teinte native DD ────────────────────────────────────────────────

func _store_native_mat(mat: ShaderMaterial) -> void:
	for ref in _native_blur_refs:
		var m = ref.get_ref()
		if m == mat:
			return
	_native_blur_refs.append(weakref(mat))


func _check_native_mats() -> void:
	# Relire la couleur des materials BlurScreen natifs stockés.
	# DD peut les mettre à jour en temps réel (ressources partagées).
	var alive = []
	for ref in _native_blur_refs:
		var mat = ref.get_ref()
		if mat == null or not (mat is ShaderMaterial):
			continue
		alive.append(ref)
		var color = mat.get_shader_param("color")
		if color is Color:
			_set_native_tint(color)
	_native_blur_refs = alive


# ── API publique ─────────────────────────────────────────────────────────────

func register(popup: Node, options: Dictionary = {}) -> void:
	if not is_instance_valid(popup) or _gauss_shader == null:
		return
	var id = popup.get_instance_id()

	# On ne gate plus sur _patched_ids : si fast_scan a déjà patché en
	# "replaced" (matériau swap sur l'enfant BlurScreen), un caller externe
	# comme compare_fix qui cache l'enfant aurait alors aucun blur. Forcer
	# _inject_blur ajoute en plus nos rects directs (avec meta _no_blur,
	# préservés par les hide loops). _inject_blur reste idempotent grâce
	# aux gates _blur_fallback meta et find_node sur _BlurBase.

	var passes = int(options.get("passes",  EXTRA_PASSES))
	var mapped = _map_intensity(_current_sigma)
	var step   = float(options.get("step_px", mapped[1]))
	var sigma  = float(options.get("sigma",   mapped[0]))
	var tint   = options.get("tint", null)
	if tint == null:
		tint = _boosted_tint()
	else:
		tint = tint as Color

	_inject_blur(popup, passes, step, sigma, tint)
	if not _patched_ids.has(id):
		_patched_ids[id] = "injected"
	print("[PopupBlur] register() : " + popup.name)


# ── Shader helpers ───────────────────────────────────────────────────────────

func _make_mat_custom(step: float, sigma: float, tint: Color, track_tint: bool = false) -> ShaderMaterial:
	var mat = ShaderMaterial.new()
	mat.shader = _gauss_shader
	mat.set_shader_param("step_px",    step)
	mat.set_shader_param("sigma",      sigma)
	mat.set_shader_param("tint_color", tint)
	_tinted_mats.append([weakref(mat), track_tint])
	return mat


func _make_mat(tint: Color, track_tint: bool = false) -> ShaderMaterial:
	var mapped = _map_intensity(_current_sigma)
	return _make_mat_custom(mapped[1], mapped[0], tint, track_tint)


func _map_intensity(intensity: float) -> Array:
	# Retourne [sigma, step_px] depuis l'intensité (0-10)
	# Calibré pour : 5 ≈ valeur originale (sigma=5, step=1.5)
	#                10 = blur maximal sans artefacts
	var sigma = min(intensity * 0.9, 6.0)
	var step  = clamp(0.5 + intensity * 0.225, 0.5, 2.75) if intensity > 0 else 0.0
	return [sigma, step]


func _make_rect(rect_name: String, mat: ShaderMaterial) -> ColorRect:
	var rect = ColorRect.new()
	rect.name         = rect_name
	rect.color        = Color(1.0, 1.0, 1.0, 1.0)
	rect.material     = mat
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.anchor_right  = 1.0
	rect.anchor_bottom = 1.0
	rect.set_meta("_no_blur", true)
	return rect


func _make_behind_rect(rect_name: String, mat: ShaderMaterial) -> ColorRect:
	var rect = _make_rect(rect_name, mat)
	rect.show_behind_parent = true
	return rect


func _get_title_height(popup: Node) -> int:
	if popup.has_constant("title_height", "WindowDialog"):
		return popup.get_constant("title_height", "WindowDialog")
	return 20


func _center_dialog_label(popup: Node) -> void:
	if popup.has_meta("_label_centered"):
		return

	if popup is AcceptDialog:
		# AcceptDialog / ConfirmationDialog : utiliser get_label()
		if popup.has_method("get_label"):
			var lbl = popup.get_label()
			if lbl is Label:
				lbl.align  = Label.ALIGN_CENTER
				lbl.valign = Label.VALIGN_CENTER
				lbl.size_flags_vertical = Control.SIZE_EXPAND_FILL
		popup.set_meta("_label_centered", true)
		return

	# WindowDialog natifs DD avec texte simple (ex: UnsavedChanges)
	if popup is WindowDialog:
		var found = false
		for child in popup.get_children():
			if child is Label:
				child.align  = Label.ALIGN_CENTER
				child.valign = Label.VALIGN_CENTER
				child.size_flags_vertical = Control.SIZE_EXPAND_FILL
				found = true
			# Chercher aussi dans les VBox/HBox enfants
			if child is Container:
				for sub in child.get_children():
					if sub is Label:
						sub.align  = Label.ALIGN_CENTER
						sub.valign = Label.VALIGN_CENTER
						sub.size_flags_vertical = Control.SIZE_EXPAND_FILL
						found = true
		if found:
			popup.set_meta("_label_centered", true)


# ── Title bar overlay (enfant toplevel du popup) ─────────────────────────────

func _create_title_overlay(popup: Node) -> void:
	if not is_instance_valid(popup):
		return
	var id = popup.get_instance_id()
	if _title_overlays.has(id):
		return
	if not popup.visible:
		if popup.has_signal("about_to_show") and not popup.is_connected("about_to_show", self, "_on_accept_show"):
			popup.connect("about_to_show", self, "_on_accept_show", [popup])
		return

	var title_h = _get_title_height(popup)

	var container = Control.new()
	container.name = "_TitleOverlay"
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.set_as_toplevel(true)
	container.set_meta("_no_blur", true)
	popup.add_child(container)

	var panel = Panel.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.set_meta("_no_blur", true)

	var title_style = StyleBoxFlat.new()
	title_style.bg_color = Color(0.24, 0.39, 0.57, 1.0)
	if popup.has_stylebox("title", "WindowDialog"):
		var ts = popup.get_stylebox("title", "WindowDialog")
		if ts is StyleBoxFlat:
			title_style = ts.duplicate()
			title_style.bg_color.a = 1.0
	panel.add_stylebox_override("panel", title_style)
	container.add_child(panel)

	var label = Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.text = popup.window_title
	label.align  = Label.ALIGN_CENTER
	label.valign = Label.VALIGN_CENTER

	var font_color = Color(0.87, 0.87, 0.87, 1.0)
	if popup.has_color("title_color", "WindowDialog"):
		font_color = popup.get_color("title_color", "WindowDialog")
	label.add_color_override("font_color", font_color)
	if popup.has_font("title_font", "WindowDialog"):
		label.add_font_override("font", popup.get_font("title_font", "WindowDialog"))
	container.add_child(label)

	var close_label = Label.new()
	close_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	close_label.text = "×"
	close_label.valign = Label.VALIGN_CENTER
	close_label.align  = Label.ALIGN_CENTER
	close_label.add_color_override("font_color", font_color)
	var close_font = null
	if popup.has_font("title_font", "WindowDialog"):
		close_font = popup.get_font("title_font", "WindowDialog")
	elif popup.has_font("font", "Label"):
		close_font = popup.get_font("font", "Label")
	if close_font is DynamicFont:
		var big = close_font.duplicate()
		big.size = int(close_font.size * 1.8)
		close_label.add_font_override("font", big)
	elif close_font != null:
		close_label.add_font_override("font", close_font)
	container.add_child(close_label)

	_title_overlays[id] = {
		"popup":     weakref(popup),
		"container": container,
		"panel":     panel,
		"label":     label,
		"close":     close_label,
		"title_h":   title_h
	}

	_sync_overlay_position(_title_overlays[id], popup)

	if popup.has_signal("popup_hide") and not popup.is_connected("popup_hide", self, "_remove_title_overlay"):
		popup.connect("popup_hide", self, "_remove_title_overlay", [popup])
	if not popup.is_connected("tree_exiting", self, "_remove_title_overlay"):
		popup.connect("tree_exiting", self, "_remove_title_overlay", [popup])

	print("[PopupBlur] Title overlay créé pour : " + popup.name)


func _sync_overlay_position(data: Dictionary, popup: Node) -> void:
	var pos     = popup.rect_global_position
	var w       = popup.rect_size.x
	var title_h = data["title_h"]
	var title_pos = Vector2(pos.x, pos.y - title_h)

	data["panel"].rect_position = title_pos
	data["panel"].rect_size     = Vector2(w, title_h)

	data["label"].rect_position = Vector2(title_pos.x, title_pos.y)
	data["label"].rect_size     = Vector2(w, title_h)

	var close_rect_h = title_h * 3
	var close_y_offset = (close_rect_h - title_h) / 2
	data["close"].rect_position = Vector2(title_pos.x + w - title_h - 2, title_pos.y - close_y_offset)
	data["close"].rect_size     = Vector2(title_h + 4, close_rect_h)


func _on_accept_show(popup: Node) -> void:
	if not is_instance_valid(popup):
		return
	call_deferred("_create_title_overlay", popup)


func _remove_title_overlay(popup: Node) -> void:
	if not is_instance_valid(popup):
		return
	var id = popup.get_instance_id()
	if _title_overlays.has(id):
		var container = _title_overlays[id]["container"]
		if is_instance_valid(container):
			container.queue_free()
		_title_overlays.erase(id)


func _update_title_overlays() -> void:
	var to_remove = []
	for id in _title_overlays:
		var data  = _title_overlays[id]
		var ref   = data["popup"]
		var popup = ref.get_ref() if ref != null else null
		if popup == null or not is_instance_valid(popup) or not popup.visible:
			if is_instance_valid(data["container"]):
				data["container"].queue_free()
			to_remove.append(id)
			continue
		_sync_overlay_position(data, popup)
	for id in to_remove:
		_title_overlays.erase(id)


# ── Injection ────────────────────────────────────────────────────────────────

func _ensure_backbuffer(popup: Node) -> void:
	# Force un refresh du backbuffer juste avant le dessin du popup, pour
	# que SCREEN_TEXTURE contienne les popups déjà ouverts derrière — et
	# pas uniquement la carte.
	#
	# Sans ce nœud, Godot ne capture le backbuffer qu'une seule fois par
	# frame (avant le premier shader qui le lit), donc le blur du popup
	# du dessus voit le même contenu que le blur du popup du dessous.
	if not is_instance_valid(popup):
		return
	if popup.find_node("_BlurBackBuffer", false, false) != null:
		return
	var bb = BackBufferCopy.new()
	bb.name = "_BlurBackBuffer"
	bb.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	bb.show_behind_parent = true
	bb.set_meta("_no_blur", true)
	popup.add_child(bb)
	# Index 0 : s'exécute avant tout autre enfant behind_parent.
	popup.move_child(bb, 0)
	if DIAG_ENABLED:
		print("[PopupBlur:DIAG] _ensure_backbuffer: ", popup.name,
			" (", popup.get_class(), ") → bb inséré, popup a ",
			popup.get_child_count(), " enfants")


func _inject_blur(popup: Node, passes: int, step: float, sigma: float, tint: Color) -> void:
	if popup.has_meta("_blur_fallback"):
		return

	_ensure_backbuffer(popup)

	if popup is AcceptDialog:
		popup.material = _make_mat_custom(step, sigma, tint, true)
		popup.set_meta("_blur_fallback", true)
		_center_dialog_label(popup)
		call_deferred("_create_title_overlay", popup)
		return

	var base_name = "_BlurBase"
	if popup.find_node(base_name, false, false) != null:
		return

	_make_panel_translucent(popup)

	var base_rect = _make_behind_rect(base_name, _make_mat_custom(step, sigma, NO_TINT, false))
	popup.add_child(base_rect)

	for i in range(passes - 1):
		var r = _make_behind_rect("_BlurPass" + str(i + 2), _make_mat_custom(step, sigma, NO_TINT, false))
		popup.add_child(r)

	var last = _make_behind_rect("_BlurPassFinal", _make_mat_custom(step, sigma, tint, true))
	popup.add_child(last)

	popup.set_meta("_blur_fallback", true)


func _make_panel_translucent(popup: Node) -> void:
	if not (popup is Control):
		return
	var existing = popup.get("custom_styles/panel")
	if existing == null and popup.has_method("get_stylebox"):
		existing = popup.get_stylebox("panel")
	if existing is StyleBoxFlat:
		var style = existing.duplicate()
		style.bg_color.a = 0.15
		popup.add_stylebox_override("panel", style)
	else:
		var style = StyleBoxFlat.new()
		style.bg_color = Color(0.08, 0.10, 0.14, 0.15)
		popup.add_stylebox_override("panel", style)


# ── Scan initial du node Windows ─────────────────────────────────────────────

func _hook_windows_node() -> void:
	if _windows_hooked:
		return
	var tree = Engine.get_main_loop()
	if tree == null:
		return
	var root = tree.root
	if not is_instance_valid(root):
		return

	var windows_node = root.get_node_or_null("Master/Editor/Windows")
	if windows_node == null:
		return

	# Patcher immédiatement les enfants existants
	for child in windows_node.get_children():
		if is_instance_valid(child) and child is Control:
			_patch_window(child)

	_windows_hooked = true
	print("[PopupBlur] Windows scanné : ", windows_node.get_child_count(), " enfants")

	# Intégration Preferences
	var prefs = windows_node.get_node_or_null("Preferences")
	if prefs != null:
		_setup_preferences(prefs)


# ── Preferences integration ──────────────────────────────────────────────────

var _prefs_dialog = null
var _window_bg_tint_btn = null
var _sigma_slider = null
var _sigma_spinbox = null
var _prefs_hooked = false
const SETTINGS_PATH = "user://UnofficialPatch/popup_blur.json"

func _setup_preferences(prefs: Node) -> void:
	if _prefs_hooked:
		return
	_prefs_dialog = prefs

	var interface_vbox = prefs.get_node_or_null("Margins/VAlign/Interface")
	if interface_vbox == null:
		print("[PopupBlur] Interface tab not found in Preferences")
		return

	# ── Fix: Label3 manquant pour WindowBGTint ────────────────────────────
	var bg_tints = interface_vbox.get_node_or_null("BGTints")
	if bg_tints != null:
		var label3 = bg_tints.get_node_or_null("Label3")
		if label3 is Label and label3.text == "":
			label3.text = "Window BG Tint"

		# Hook WindowBGTint pour tracking temps réel de la teinte
		_window_bg_tint_btn = bg_tints.get_node_or_null("WindowBGTint")
		if _window_bg_tint_btn != null and _window_bg_tint_btn.has_signal("color_changed"):
			if not _window_bg_tint_btn.is_connected("color_changed", self, "_on_window_bg_tint_changed"):
				_window_bg_tint_btn.connect("color_changed", self, "_on_window_bg_tint_changed")
			# On NE LIT PAS la valeur initiale du bouton. Sur map 2+, DD recrée
			# le bouton WindowBGTint qui s'initialise à (0,0,0,1) avant que
			# le setting sauvegardé de l'user ne soit appliqué. La courbe de
			# boost transformerait α=1 → α=0.98 = teinte quasi opaque noire,
			# rendant tous les popups noirs. _native_tint reste au DEFAULT
			# (0,0,0,0.31) → boosté 0,0,0,0.62, jusqu'à ce que l'user change
			# explicitement la teinte (color_changed signal).
			print("[PopupBlur] WindowBGTint signal connected (initial value ignored)")

		# Remplacer l'icône du bouton reset natif
		var reset_btn = bg_tints.get_node_or_null("BGTintResetButton")
		if reset_btn is Button:
			var reset_tex = _load_reset_icon()
			if reset_tex != null:
				reset_btn.icon = reset_tex

	# ── Séparateur + section Popup Blur ───────────────────────────────────
	# Si la Preferences popup persiste entre les maps (DD ne la recrée pas
	# toujours), notre row peut déjà exister. Ré-acquérir les refs plutôt
	# que d'ajouter des doublons.
	var existing_row = interface_vbox.get_node_or_null("BlurIntensity")
	if existing_row != null:
		for c in existing_row.get_children():
			if c is HSlider:
				_sigma_slider = c
				if not c.is_connected("value_changed", self, "_on_sigma_changed"):
					c.connect("value_changed", self, "_on_sigma_changed")
			elif c is SpinBox:
				_sigma_spinbox = c
				if not c.is_connected("value_changed", self, "_on_sigma_spinbox_changed"):
					c.connect("value_changed", self, "_on_sigma_spinbox_changed")
		_load_blur_settings()
		_prefs_hooked = true
		print("[PopupBlur] Preferences slider re-acquired (existing row)")
		return

	var sep = HSeparator.new()
	sep.name = "BlurSep"
	interface_vbox.add_child(sep)

	# Blur Intensity (sigma)
	var sigma_row = HBoxContainer.new()
	sigma_row.name = "BlurIntensity"

	var sigma_lbl = Label.new()
	sigma_lbl.text = "BG Blur Intensity"
	sigma_lbl.rect_min_size = Vector2(170, 0)
	sigma_row.add_child(sigma_lbl)

	_sigma_slider = HSlider.new()
	_sigma_slider.min_value = 0.0
	_sigma_slider.max_value = 10.0
	_sigma_slider.step = 0.5
	_sigma_slider.value = _current_sigma
	_sigma_slider.rect_min_size = Vector2(150, 20)
	_sigma_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_sigma_slider.connect("value_changed", self, "_on_sigma_changed")
	sigma_row.add_child(_sigma_slider)

	_sigma_spinbox = SpinBox.new()
	_sigma_spinbox.min_value = 0.0
	_sigma_spinbox.max_value = 10.0
	_sigma_spinbox.step = 0.5
	_sigma_spinbox.value = _current_sigma
	_sigma_spinbox.rect_min_size = Vector2(60, 0)
	_sigma_spinbox.connect("value_changed", self, "_on_sigma_spinbox_changed")
	sigma_row.add_child(_sigma_spinbox)

	var reset_btn = Button.new()
	reset_btn.hint_tooltip = "Reset"
	reset_btn.rect_min_size = Vector2(28, 28)
	var reset_tex = _load_reset_icon()
	if reset_tex != null:
		reset_btn.icon = reset_tex
	else:
		reset_btn.text = "R"
	_style_icon_button_hover(reset_btn)
	reset_btn.connect("pressed", self, "_reset_blur_intensity")
	sigma_row.add_child(reset_btn)

	interface_vbox.add_child(sigma_row)

	# Charger les settings sauvegardés
	_load_blur_settings()

	_prefs_hooked = true
	print("[PopupBlur] Preferences integration done")


# ── Settings dynamiques ──────────────────────────────────────────────────────

var _current_sigma  = SIGMA
var _syncing_sigma  = false

func _on_window_bg_tint_changed(color: Color) -> void:
	_set_native_tint(color)


func _on_sigma_changed(value: float) -> void:
	if _syncing_sigma:
		return
	_syncing_sigma = true
	_current_sigma = value
	if _sigma_spinbox != null:
		_sigma_spinbox.value = value
	_apply_blur_intensity(value)
	_save_blur_settings()
	_syncing_sigma = false


func _on_sigma_spinbox_changed(value: float) -> void:
	if _syncing_sigma:
		return
	_syncing_sigma = true
	_current_sigma = value
	if _sigma_slider != null:
		_sigma_slider.value = value
	_apply_blur_intensity(value)
	_save_blur_settings()
	_syncing_sigma = false


func _apply_blur_intensity(intensity: float) -> void:
	var mapped = _map_intensity(intensity)
	var sigma  = mapped[0]
	var step   = mapped[1]
	for entry in _tinted_mats:
		var mat = entry[0].get_ref()
		if mat != null and mat is ShaderMaterial:
			mat.set_shader_param("sigma", sigma)
			mat.set_shader_param("step_px", step)


func _load_reset_icon() -> ImageTexture:
	var path = _g.Root + "icons/reset.png"
	var img = Image.new()
	if img.load(path) != OK:
		return null
	img.resize(16, 16, Image.INTERPOLATE_LANCZOS)
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)
	return tex


func _style_icon_button_hover(btn: Button) -> void:
	for state in ["normal", "hover", "pressed"]:
		var sb = StyleBoxFlat.new()
		if state == "hover":
			sb.bg_color = Color(1, 1, 1, 0.15)
		elif state == "pressed":
			sb.bg_color = Color(1, 1, 1, 0.25)
		else:
			sb.bg_color = Color(0, 0, 0, 0)
		sb.set_corner_radius_all(3)
		sb.content_margin_left = 4
		sb.content_margin_right = 4
		sb.content_margin_top = 4
		sb.content_margin_bottom = 4
		btn.add_stylebox_override(state, sb)
	btn.add_stylebox_override("focus", StyleBoxEmpty.new())


func _reset_blur_intensity() -> void:
	_syncing_sigma = true
	_current_sigma = SIGMA
	if _sigma_slider != null:
		_sigma_slider.value = SIGMA
	if _sigma_spinbox != null:
		_sigma_spinbox.value = SIGMA
	_apply_blur_intensity(SIGMA)
	_save_blur_settings()
	_syncing_sigma = false


func _save_blur_settings() -> void:
	var dir = Directory.new()
	if not dir.dir_exists("user://UnofficialPatch"):
		dir.make_dir("user://UnofficialPatch")
	var f = File.new()
	if f.open(SETTINGS_PATH, File.WRITE) == OK:
		f.store_string(JSON.print({
			"sigma": _current_sigma
		}))
		f.close()


func _load_blur_settings() -> void:
	var f = File.new()
	if f.open(SETTINGS_PATH, File.READ) != OK:
		return
	var text = f.get_as_text()
	f.close()
	var parsed = JSON.parse(text)
	if parsed.error != OK or not (parsed.result is Dictionary):
		return
	var data = parsed.result
	if data.has("sigma"):
		_current_sigma = float(data["sigma"])
		if _sigma_slider != null:
			_sigma_slider.value = _current_sigma
		if _sigma_spinbox != null:
			_sigma_spinbox.value = _current_sigma
		_apply_blur_intensity(_current_sigma)
	print("[PopupBlur] Settings chargés : sigma=", _current_sigma)


# ── Polling (fallback + tint tracking) ───────────────────────────────────────

var _windows_ref = null  # weakref au node Windows pour scan rapide

func update(delta: float) -> void:
	if _gauss_shader == null:
		return

	# Anti double-call : Main.update() ET idle_frame peuvent appeler update()
	# la même frame. On ne fait le travail qu'une fois.
	var current_frame = Engine.get_idle_frames()
	if current_frame == _last_update_frame:
		return
	_last_update_frame = current_frame

	# Détection changement de map : DD recrée World (et tous les popups,
	# notre slider Preferences, etc.). Convention partagée avec drop_embed.
	if _g != null and _g.World != null and is_instance_valid(_g.World):
		var wid = _g.World.get_instance_id()
		if wid != _last_world_id:
			if _last_world_id != -1:
				_on_map_changed()
			_last_world_id = wid

	# Watchdog (fallback) : si la détection via World ID rate, on détecte
	# directement que notre slider Preferences a été freed (DD a recréé
	# la popup). Permet de ré-injecter le slider.
	if _prefs_hooked and not is_instance_valid(_sigma_slider):
		print("[PopupBlur] slider Preferences invalide → reset")
		_on_map_changed()

	_diag_heartbeat(delta)
	_diag_periodic(delta)

	if _title_overlays.size() > 0:
		_update_title_overlays()

	# Tracking teinte DD chaque frame (très léger)
	if _native_blur_refs.size() > 0:
		_check_native_mats()

	if _startup_timer > 0.0:
		_startup_timer -= delta
		if _startup_timer <= 0.0:
			_hook_windows_node()
		return

	# Essayer de hooker si pas encore fait
	if not _windows_hooked:
		_hook_windows_node()

	# Hook exploration Preferences (temporaire)
	_hook_preferences_debug()

	# Scan rapide des enfants de Windows chaque frame
	# (très léger : juste une boucle sur ~10-20 nodes, skip si déjà patché)
	_fast_scan_windows()

	# Scan profond périodique (filet de sécurité pour popups hors Windows)
	_check_timer -= delta
	if _check_timer > 0.0:
		return
	_check_timer = CHECK_INTERVAL

	var tree = Engine.get_main_loop()
	if tree == null:
		return
	var root = tree.root
	if not is_instance_valid(root):
		return

	_scan_for_replaceable(root, 0)


func _fast_scan_windows() -> void:
	var windows = null
	if _windows_ref != null:
		windows = _windows_ref.get_ref()
	if windows == null or not is_instance_valid(windows):
		var tree = Engine.get_main_loop()
		if tree == null:
			if DIAG_ENABLED:
				print("[PopupBlur:DIAG] _fast_scan_windows: pas de main loop")
			return
		var root = tree.root
		if not is_instance_valid(root):
			return
		windows = root.get_node_or_null("Master/Editor/Windows")
		if windows == null:
			if DIAG_ENABLED:
				print("[PopupBlur:DIAG] _fast_scan_windows: Windows introuvable")
			return
		_windows_ref = weakref(windows)

	# Log diag des enfants vus quand il y en a des nouveaux non patchés
	if DIAG_ENABLED:
		var new_kids := []
		for child in windows.get_children():
			if not is_instance_valid(child) or not (child is Control):
				continue
			if child is PopupMenu:
				continue
			if _patched_ids.has(child.get_instance_id()):
				continue
			new_kids.append(child.name + "(" + child.get_class()
				+ ",vis=" + str(child.visible)
				+ ",no_blur=" + str(child.has_meta("_no_blur")) + ")")
		if new_kids.size() > 0:
			print("[PopupBlur:DIAG] _fast_scan_windows: ", windows.get_child_count(),
				" enfants total, nouveaux non-patchés : ", new_kids)

	for child in windows.get_children():
		if not is_instance_valid(child) or not (child is Control):
			continue
		if child.has_meta("_no_blur") or child is PopupMenu:
			continue
		var id = child.get_instance_id()
		var state = _patched_ids.get(id)
		if state == null:
			_patch_window(child)
		elif state == "replaced":
			# DD peut restaurer le BlurScreen natif sur les popups après un
			# rechargement de map. _replace_existing_blur est idempotent : il
			# ne fait du travail que s'il retrouve un matériau BlurScreen.
			_replace_existing_blur(child, 0)

	# Retry hook Preferences (sur map 2+, _hook_windows_node peut avoir tourné
	# avant que la nouvelle Preferences ne soit dans l'arbre).
	if not _prefs_hooked:
		var prefs = windows.get_node_or_null("Preferences")
		if prefs != null:
			_setup_preferences(prefs)


func _scan_for_replaceable(node: Node, depth: int) -> void:
	if depth > 15 or not is_instance_valid(node):
		return
	if (node is Popup or node is WindowDialog) and not (node is PopupMenu):
		if not node.has_meta("_no_blur"):
			var id = node.get_instance_id()
			var state = _patched_ids.get(id)
			if state == null:
				if _replace_existing_blur(node, 0):
					_patched_ids[id] = "replaced"
					_ensure_backbuffer(node)
					_center_dialog_label(node)
			elif state == "replaced":
				# Idem _fast_scan_windows : re-patch si DD a restauré BlurScreen.
				_replace_existing_blur(node, 0)
	for child in node.get_children():
		_scan_for_replaceable(child, depth + 1)


func _patch_window(popup: Node) -> void:
	if not is_instance_valid(popup):
		return
	if popup.has_meta("_no_blur"):
		return
	if popup is PopupMenu:
		return

	var id = popup.get_instance_id()
	if _patched_ids.get(id) == "replaced":
		# Déjà remplacé, mais appliquer le style si pas encore fait
		_center_dialog_label(popup)
		return

	if not _patched_ids.has(id):
		if _replace_existing_blur(popup, 0):
			_patched_ids[id] = "replaced"
			_ensure_backbuffer(popup)
			_center_dialog_label(popup)
			return

	if _gauss_shader != null and not _patched_ids.has(id):
		var tint = _boosted_tint()
		var mapped = _map_intensity(_current_sigma)
		_inject_blur(popup, EXTRA_PASSES, mapped[1], mapped[0], tint)
		print("[PopupBlur] Injecté (fallback) : " + popup.name + " tint=" + str(tint))
		_patched_ids[id] = "injected"
		_center_dialog_label(popup)

		if popup.has_signal("about_to_show") and not popup.is_connected("about_to_show", self, "_on_fallback_show"):
			popup.connect("about_to_show", self, "_on_fallback_show", [popup])


func _on_fallback_show(popup: Node) -> void:
	if not is_instance_valid(popup) or _gauss_shader == null:
		return
	if not popup.has_meta("_blur_fallback"):
		var tint = _boosted_tint()
		var mapped = _map_intensity(_current_sigma)
		_inject_blur(popup, EXTRA_PASSES, mapped[1], mapped[0], tint)
		print("[PopupBlur] Ré-injecté (about_to_show) : " + popup.name)


func _replace_existing_blur(node: Node, depth: int) -> bool:
	if depth > 6 or not is_instance_valid(node):
		return false

	if node is CanvasItem:
		var mat = node.get_material()
		if mat is ShaderMaterial and mat.shader != null:
			if "BlurScreen" in mat.shader.resource_path:
				if _gauss_shader == null:
					return true

				# Stocker le material natif DD + lire sa teinte
				_store_native_mat(mat)
				var native_color = mat.get_shader_param("color")
				if native_color is Color:
					_set_native_tint(native_color)

				var boosted = _boosted_tint()

				node.set_material(_make_mat(NO_TINT, false))

				for i in range(EXTRA_PASSES - 1):
					if node.find_node("_BlurPass" + str(i + 2), false, false) != null:
						continue
					node.add_child(_make_rect("_BlurPass" + str(i + 2), _make_mat(NO_TINT, false)))

				var last = "_BlurPass" + str(EXTRA_PASSES + 1)
				if node.find_node(last, false, false) == null:
					node.add_child(_make_rect(last, _make_mat(boosted, true)))

				print("[PopupBlur] Remplacé : " + node.get_parent().name)
				return true

	for child in node.get_children():
		if _replace_existing_blur(child, depth + 1):
			return true

	return false

# ── Diagnostic ───────────────────────────────────────────────────────────────
# Dump l'état des popups visibles à chaque changement de l'ensemble visible.
# Utile pour diagnostiquer les cas où un popup du dessus perd son blur.
# Grep dans le log de DD :   [PopupBlur:DIAG]

var _diag_last_visible_ids := []
var _diag_time_since_check := 0.0
var _diag_dumped_structure := {}  # ids des popups dont on a déjà dumpé la structure
var _diag_heartbeat_timer  := 0.0


func _diag_heartbeat(delta: float) -> void:
	if not DIAG_ENABLED:
		return
	_diag_heartbeat_timer += delta
	if _diag_heartbeat_timer < 3.0:
		return
	_diag_heartbeat_timer = 0.0
	var windows = _diag_get_windows()
	if windows == null:
		print("[PopupBlur:DIAG] heartbeat: update() actif mais Windows introuvable")
		return
	var total = windows.get_child_count()
	var visible = 0
	var names := []
	for c in windows.get_children():
		if is_instance_valid(c) and c is Control and c.visible and not (c is PopupMenu):
			visible += 1
			names.append(c.name)
	print("[PopupBlur:DIAG] heartbeat: ", total, " enfants Windows, ",
		visible, " visibles : ", names)

	# Scan profond : chercher TOUS les WindowDialog/Popup visibles dans l'arbre,
	# peu importe où ils se trouvent. Sert à localiser Export si elle vit
	# ailleurs que sous Master/Editor/Windows.
	var tree = Engine.get_main_loop()
	if tree == null or not is_instance_valid(tree.root):
		return
	var found := []
	_diag_deep_find_popups(tree.root, found, 0)
	if found.size() > 0:
		print("[PopupBlur:DIAG]   popups visibles dans tout l'arbre :")
		for entry in found:
			print("[PopupBlur:DIAG]     ", entry)


func _diag_deep_find_popups(node: Node, out: Array, depth: int) -> void:
	if depth > 15 or not is_instance_valid(node):
		return
	if (node is Popup or node is WindowDialog) and not (node is PopupMenu):
		if node is Control and node.visible:
			var pid = node.get_instance_id()
			var patch_state = str(_patched_ids.get(pid, "NO"))
			var bb = node.find_node("_BlurBackBuffer", false, false)
			var bb_info = "MISSING"
			if bb != null:
				bb_info = "idx=" + str(bb.get_index())
			out.append(node.name + " @ " + str(node.get_path())
				+ " class=" + node.get_class()
				+ " patch=" + patch_state + " bb=" + bb_info)
	for c in node.get_children():
		_diag_deep_find_popups(c, out, depth + 1)


func _diag_get_windows() -> Node:
	if _windows_ref != null:
		var w = _windows_ref.get_ref()
		if w != null and is_instance_valid(w):
			return w
	var tree = Engine.get_main_loop()
	if tree == null or not is_instance_valid(tree.root):
		return null
	return tree.root.get_node_or_null("Master/Editor/Windows")


func _diag_scan_oddities(node: Node, depth: int, out: Array) -> void:
	# Détecte les nœuds qui peuvent casser la chaîne SCREEN_TEXTURE :
	# Viewport (pipeline de rendu isolé) et CanvasLayer (nouvelle couche).
	if depth > 5 or not is_instance_valid(node):
		return
	if node is Viewport or node is CanvasLayer or node is ViewportContainer:
		out.append(node.get_class() + "@" + node.name)
	for c in node.get_children():
		_diag_scan_oddities(c, depth + 1, out)


func _diag_popup_line(p: Node, idx: int) -> String:
	var pid = p.get_instance_id()
	var patch_state = str(_patched_ids.get(pid, "NO"))

	var bb_info = "MISSING"
	var bb = p.find_node("_BlurBackBuffer", false, false)
	if bb != null and is_instance_valid(bb):
		bb_info = "idx=" + str(bb.get_index()) + "/" + str(p.get_child_count())

	var mat_info = "no"
	if p is CanvasItem:
		var m = p.get_material()
		if m is ShaderMaterial:
			var sh = m.shader
			if sh != null:
				mat_info = "yes(" + sh.resource_path.get_file() + ")"
			else:
				mat_info = "yes(no-shader)"

	var oddities := []
	_diag_scan_oddities(p, 0, oddities)
	var odd_str = "none"
	if oddities.size() > 0:
		odd_str = str(oddities)

	var has_blur_children = "no"
	if p.find_node("_BlurBase", false, false) != null \
			or p.find_node("_BlurPass2", false, false) != null \
			or p.find_node("_BlurPassFinal", false, false) != null:
		has_blur_children = "yes"
	# Cas replacement (shader direct, pas de rects injectés en tant qu'enfants du popup)
	if p.find_node("_BlurPass9", false, false) != null:
		has_blur_children = "yes(replaced)"

	return "[%d] %s (%s) patch=%s bb=%s mat=%s blurs=%s oddities=%s" % [
		idx, p.name, p.get_class(), patch_state, bb_info,
		mat_info, has_blur_children, odd_str
	]


func _diag_dump_structure(p: Node) -> void:
	# Dump une seule fois par popup : liste ses enfants directs.
	var pid = p.get_instance_id()
	if _diag_dumped_structure.has(pid):
		return
	_diag_dumped_structure[pid] = true
	var lines := []
	for i in range(p.get_child_count()):
		var c = p.get_child(i)
		if not is_instance_valid(c):
			continue
		var tags = []
		if c is CanvasItem and c.show_behind_parent:
			tags.append("behind")
		if c is CanvasItem and c.is_set_as_toplevel():
			tags.append("toplevel")
		if c is Viewport or c is CanvasLayer:
			tags.append("!!" + c.get_class())
		var tag_str = ""
		if tags.size() > 0:
			tag_str = " [" + PoolStringArray(tags).join(",") + "]"
		lines.append(str(i) + ":" + c.name + "(" + c.get_class() + ")" + tag_str)
	print("[PopupBlur:DIAG]   structure ", p.name, " → ", lines)


func _diag_dump(reason: String) -> void:
	if not DIAG_ENABLED:
		return
	var windows = _diag_get_windows()
	if windows == null:
		print("[PopupBlur:DIAG] dump(", reason, "): Windows introuvable")
		return

	print("[PopupBlur:DIAG] ===== dump : ", reason, " =====")
	var visible_any = false
	for i in range(windows.get_child_count()):
		var c = windows.get_child(i)
		if not is_instance_valid(c) or not (c is Control):
			continue
		if c is PopupMenu:
			continue
		if not c.visible:
			continue
		visible_any = true
		print("[PopupBlur:DIAG]   ", _diag_popup_line(c, i))
		_diag_dump_structure(c)
	if not visible_any:
		print("[PopupBlur:DIAG]   (aucun popup visible)")
	print("[PopupBlur:DIAG] ===== fin dump =====")


func _diag_periodic(delta: float) -> void:
	if not DIAG_ENABLED:
		return
	_diag_time_since_check += delta
	if _diag_time_since_check < 0.3:
		return
	_diag_time_since_check = 0.0

	var windows = _diag_get_windows()
	if windows == null:
		return

	var ids := []
	for c in windows.get_children():
		if is_instance_valid(c) and c is Control and c.visible and not (c is PopupMenu):
			ids.append(c.get_instance_id())

	if ids == _diag_last_visible_ids:
		return
	var prev_count = _diag_last_visible_ids.size()
	_diag_last_visible_ids = ids

	# Dump quand on passe à 2+ popups visibles, ou qu'on retire un popup du haut.
	if ids.size() >= 2 or (prev_count >= 2 and ids.size() < prev_count):
		_diag_dump("visible set changed (" + str(prev_count) + " → " + str(ids.size()) + ")")
