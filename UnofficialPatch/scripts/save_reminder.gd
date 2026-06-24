# save_reminder.gd
# Sub-mod for BugFixes -- Save reminder for new unsaved maps
#
# On load, waits N minutes then checks CurrentMapFile.
# If null/empty → map was never saved → show reminder.
# The delay is configurable from the popup and persisted to disk.

var _g

# Reference vers welcome_popup (injectee par Main.gd). Le timer ne demarre
# qu'une fois que le welcome popup n'est plus affiche, sinon les deux
# popups se chevauchent et le save_reminder peut bloquer tout l'ecran.
var welcome_popup = null

var _popup_visible := false
var _saved := false
var _delay_minutes := 5
var _config_path := "user://UnofficialPatch/save_reminder_config.json"

# Flag interne : true une fois que le timer a ete arme (apres fermeture
# du welcome popup). Evite d'en armer plusieurs si update() tourne
# pendant que welcome est encore ouvert.
var _timer_started := false


func initialize() -> void:
	_load_config()
	# Le timer est arme dans update() : soit immediatement (si welcome_popup
	# null ou pas active), soit apres fermeture du popup. update() check
	# tout, pas besoin d'armer dans initialize.
	print("[SaveReminder] Initialized — delay = %d minute(s)" % _delay_minutes)


func _start_timer() -> void:
	if _timer_started:
		return
	# Guard : au map load, _g.World ou son tree peuvent etre transitoires.
	# On retente la frame suivante via update() si pas pret.
	if _g == null or _g.World == null or not is_instance_valid(_g.World):
		return
	if not _g.World.is_inside_tree():
		return
	var tree = _g.World.get_tree()
	if tree == null:
		return
	_timer_started = true
	var t = tree.create_timer(float(_delay_minutes) * 60.0)
	t.connect("timeout", self, "_check_map_saved")


func _check_map_saved() -> void:
	var map_file = _g.Editor.get("CurrentMapFile") if _g.Editor else null
	if map_file == null or (map_file is String and map_file == ""):
		_show_save_reminder()
	else:
		# Map sauvee a ce moment T, mais l'utilisateur peut faire File -> New
		# plus tard dans la session. On reset le flag pour que update() reArme
		# un nouveau timer et qu'on re-check periodiquement.
		_timer_started = false
		print("[SaveReminder] Map already saved — will re-check in %d minute(s)" % _delay_minutes)


func update(_delta: float) -> void:
	# Une fois que le welcome popup est ferme, on arme le timer (si pas
	# deja fait). Polling chaque frame jusqu'a ce que welcome se ferme.
	if _timer_started:
		return
	# welcome_popup peut etre une Reference invalidee si quelque chose
	# s'est passe (free indirect). On guard avec is_instance_valid.
	var wp_active := false
	if welcome_popup != null and is_instance_valid(welcome_popup):
		if welcome_popup.has_method("is_active"):
			wp_active = welcome_popup.is_active()
	if not wp_active:
		_start_timer()


# ── Config persistence ────────────────────────────────────────────────────────

func _load_config() -> void:
	var f = File.new()
	if f.file_exists(_config_path):
		if f.open(_config_path, File.READ) == OK:
			var text = f.get_as_text()
			f.close()
			var parsed = JSON.parse(text)
			if parsed.error == OK and parsed.result is Dictionary:
				_delay_minutes = int(parsed.result.get("delay_minutes", 1))
				if _delay_minutes < 1:
					_delay_minutes = 1


func _save_config() -> void:
	var data = {"delay_minutes": _delay_minutes}
	var f = File.new()
	if f.open(_config_path, File.WRITE) == OK:
		f.store_line(JSON.print(data, "\t"))
		f.close()
		print("[SaveReminder] Config saved — delay = %d minute(s)" % _delay_minutes)


# ── Popup ─────────────────────────────────────────────────────────────────────

# Injecte un faux release pour chaque bouton souris actuellement enfonce.
# Sinon, popup_exclusive=true capte tous les inputs et l'outil sous-jacent
# (terrain paint, wall draw, etc) ne recoit jamais le release et reste
# "coince" en mode press jusqu'au prochain clic.
func _release_held_mouse_buttons() -> void:
	if _g == null or _g.World == null or not is_instance_valid(_g.World):
		return
	var vp = _g.World.get_viewport()
	if vp == null:
		return
	var mpos = vp.get_mouse_position()
	for btn in [BUTTON_LEFT, BUTTON_RIGHT, BUTTON_MIDDLE]:
		if Input.is_mouse_button_pressed(btn):
			var ev = InputEventMouseButton.new()
			ev.button_index = btn
			ev.pressed = false
			ev.position = mpos
			ev.global_position = mpos
			Input.parse_input_event(ev)


func _show_save_reminder() -> void:
	if _popup_visible:
		return
	if not _g.World or not is_instance_valid(_g.World) or not _g.World.is_inside_tree():
		# World en transition (changement de map). On ne peut pas afficher
		# maintenant — reset le flag pour que update() reArme et retente.
		_timer_started = false
		return

	_popup_visible = true
	print("[SaveReminder] Showing popup")

	var dialog = WindowDialog.new()
	dialog.window_title = "Save Reminder"

	var vbox = VBoxContainer.new()
	vbox.set("custom_constants/separation", 10)
	dialog.add_child(vbox)

	# -- Line 1 --
	var lbl_title = Label.new()
	lbl_title.text = "DON'T FORGET TO SAVE YOUR MAP!"
	lbl_title.align = Label.ALIGN_CENTER
	vbox.add_child(lbl_title)

	# -- Line 2 --
	var lbl_sub = Label.new()
	lbl_sub.text = "(auto backup settings in Menu/Preferences)"
	lbl_sub.align = Label.ALIGN_CENTER
	vbox.add_child(lbl_sub)

	# -- Separator --
	vbox.add_child(HSeparator.new())

	# -- Settings row --
	var settings_row = HBoxContainer.new()
	settings_row.alignment = BoxContainer.ALIGN_CENTER
	settings_row.set("custom_constants/separation", 6)

	var lbl_before = Label.new()
	lbl_before.text = "Remind me after"
	settings_row.add_child(lbl_before)

	var spinbox = SpinBox.new()
	spinbox.min_value = 1
	spinbox.max_value = 60
	spinbox.value = _delay_minutes
	spinbox.step = 1
	spinbox.rounded = true
	settings_row.add_child(spinbox)

	var lbl_after = Label.new()
	lbl_after.text = "minute(s) on an unsaved map"
	settings_row.add_child(lbl_after)

	vbox.add_child(settings_row)
	
	
	# -- Separator --
	vbox.add_child(HSeparator.new())

	# -- Buttons --
	var btn_row = HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGN_CENTER
	btn_row.set("custom_constants/separation", 40)

	var save_btn = Button.new()
	save_btn.text = "Save"
	save_btn.connect("pressed", self, "_on_reminder_save", [dialog, spinbox])
	btn_row.add_child(save_btn)

	var dismiss_btn = Button.new()
	dismiss_btn.text = "Dismiss"
	dismiss_btn.connect("pressed", self, "_on_reminder_dismiss", [dialog, spinbox])
	btn_row.add_child(dismiss_btn)

	vbox.add_child(btn_row)

	dialog.connect("popup_hide", self, "_on_reminder_hide", [dialog, spinbox])

	# Libere tout bouton souris enfonce AVANT d'afficher le popup, sinon
	# l'outil sous-jacent (peinture terrain, etc) reste coince apres
	# fermeture du popup.
	_release_held_mouse_buttons()

	_add_dialog(dialog)
	dialog.popup_exclusive = true

	# Let Godot compute the content size, then center
	yield(_g.World.get_tree(), "idle_frame")
	var content_min = vbox.get_combined_minimum_size()
	var title_h = dialog.get_constant("title_height", "WindowDialog")
	var w = content_min.x + 32   # 16px margin each side
	var h = content_min.y + title_h + 20   # top/bottom margins
	dialog.rect_size = Vector2(w, h)

	# Maintenant appliquer les anchors pour que le vbox remplisse le dialog
	vbox.anchor_right = 1.0
	vbox.anchor_bottom = 1.0
	vbox.margin_left = 16
	vbox.margin_right = -16
	vbox.margin_top = 12
	vbox.margin_bottom = -8

	dialog.popup_centered(Vector2(w, h))

	_deferred_style(dialog)


func _read_and_save_delay(spinbox) -> void:
	if spinbox and is_instance_valid(spinbox):
		_delay_minutes = int(spinbox.value)
		print("[SaveReminder] Delay read from spinbox: %d minute(s)" % _delay_minutes)
	_save_config()


func _on_reminder_save(dialog: Node, spinbox) -> void:
	_saved = true
	_read_and_save_delay(spinbox)
	var save_btn = _g.Editor.get("saveButton") if _g.Editor else null
	if save_btn != null and is_instance_valid(save_btn):
		save_btn.emit_signal("pressed")
	print("[SaveReminder] User chose to save")
	if is_instance_valid(dialog):
		dialog.hide()


func _on_reminder_dismiss(dialog: Node, spinbox) -> void:
	_read_and_save_delay(spinbox)
	if is_instance_valid(dialog):
		dialog.hide()


func _on_reminder_hide(dialog: Node, spinbox) -> void:
	_read_and_save_delay(spinbox)
	_popup_visible = false
	if is_instance_valid(dialog):
		dialog.call_deferred("queue_free")
	# Reset _timer_started dans tous les cas : update() reArmera un timer
	# au prochain frame. Pour le cas dismiss, on re-arme tout de suite ici
	# (sinon update() le ferait quand meme, juste avec une frame de delai).
	# GDScript est single-thread, pas de race avec update().
	_timer_started = false
	if not _saved:
		_start_timer()
		print("[SaveReminder] Dismissed — will remind again in %d minute(s)" % _delay_minutes)
	else:
		print("[SaveReminder] Saved — will re-check in %d minute(s)" % _delay_minutes)
	_saved = false


# ── UI helpers ────────────────────────────────────────────────────────────────

func _add_dialog(dialog: Node) -> void:
	var windows = _g.Editor.get_node_or_null("Windows") if _g.Editor else null
	if windows != null:
		windows.add_child(dialog)
	else:
		_g.World.get_tree().root.add_child(dialog)


func _deferred_style(dialog: Node) -> void:
	if not _g.World or not is_instance_valid(_g.World) or not _g.World.is_inside_tree():
		return
	var timer = Timer.new()
	timer.wait_time = 0.1
	timer.one_shot = true
	timer.connect("timeout", self, "_style_dialog", [dialog, timer])
	_g.World.get_tree().root.add_child(timer)
	timer.start()


func _style_dialog(dialog: Node, timer: Timer) -> void:
	timer.queue_free()
	if not is_instance_valid(dialog):
		return
	# Style all buttons
	for btn in _find_buttons(dialog):
		_style_button(btn)


func _find_buttons(node: Node) -> Array:
	var result = []
	if node is Button:
		result.append(node)
	for child in node.get_children():
		result += _find_buttons(child)
	return result


func _style_button(btn: Button) -> void:
	var existing = btn.get_stylebox("normal")
	if existing != null and existing is StyleBoxFlat:
		var style = existing.duplicate()
		style.border_color = Color(0.6, 0.6, 0.6, 0.7)
		style.set_border_width_all(1)
		style.content_margin_left  = 20
		style.content_margin_right = 20
		btn.add_stylebox_override("normal", style)
