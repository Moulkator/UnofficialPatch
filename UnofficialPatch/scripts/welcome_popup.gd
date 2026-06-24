# welcome_popup.gd
# ─────────────────────────────────────────────────────────────────────────────
# Popup de bienvenue affiche au premier lancement du mod (et a chaque
# lancement tant que l'utilisateur n'a pas coche "Do not show again").
#
# Implemente comme WindowDialog popup_exclusive (= popup natif DD/Godot)
# pour s'inscrire correctement dans la stack popup. Cela permet aux autres
# popups (vanilla DD ou autres mods) de passer devant proprement quand
# necessaire, sans bloquer les inputs ni geler l'ecran. L'utilisateur ferme
# le popup au-dessus, puis reprend l'interaction avec welcome en arriere.
#
# Persistance : user://UnofficialPatch/welcome.json
#   { "shown": bool }

var _g

const _SETTINGS_FILE = "user://UnofficialPatch/welcome.json"

var _dialog : WindowDialog = null
var _check  : CheckBox = null
var _shown  := false  # flag interne : popup actuellement affiche
var _seen   := false  # state disque : user a coche "Do not show again"


func initialize() -> void:
	_load_state_from_disk()
	print("[WelcomePopup] Initialized (seen=%s)" % str(_seen))


# Retourne true tant que le popup est actuellement affiche a l'ecran.
# Utilise par save_reminder pour ne pas armer son timer tant que le
# welcome popup n'a pas ete ferme par l'utilisateur.
func is_active() -> bool:
	return _dialog != null and is_instance_valid(_dialog) and _dialog.visible


# Show le popup si l'utilisateur ne l'a pas encore marque comme vu.
# No-op si deja affiche, si seen=true, ou si _g.Editor pas pret.
func show_if_first_time() -> void:
	if _seen or _shown:
		return
	if _g == null or _g.Editor == null or not is_instance_valid(_g.Editor):
		return
	_build_popup()
	_shown = true


# ── Build UI ──────────────────────────────────────────────────────────────────

func _build_popup() -> void:
	_dialog = WindowDialog.new()
	_dialog.window_title = "Unofficial Patch"
	_dialog.popup_exclusive = true

	# MarginContainer pour donner un padding interne au contenu (sans ca le
	# RichTextLabel et le footer collent aux bords du WindowDialog).
	var margin := MarginContainer.new()
	margin.set("custom_constants/margin_left", 18)
	margin.set("custom_constants/margin_right", 18)
	margin.set("custom_constants/margin_top", 14)
	margin.set("custom_constants/margin_bottom", -10)
	margin.anchor_right = 1.0
	margin.anchor_bottom = 1.0
	_dialog.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.set("custom_constants/separation", 15)
	margin.add_child(vbox)

	# Titre centre, grand : Label avec font override de taille augmentee.
	# RichTextLabel ne supporte pas [size=...] en Godot 3, donc Label.
	var title := Label.new()
	title.text = "Welcome to Dungeondraft's Unofficial Patch!"
	title.align = Label.ALIGN_CENTER
	var base_font = title.get_font("font")
	if base_font != null and base_font is DynamicFont:
		var big := DynamicFont.new()
		big.font_data = base_font.font_data
		big.size = base_font.size + 6
		title.add_font_override("font", big)
	vbox.add_child(title)

	# Petit espace entre titre et body.
	var sp := Control.new()
	sp.rect_min_size = Vector2(0, 4)
	vbox.add_child(sp)

	# Body : RichTextLabel avec bbcode pour le contenu enrichi.
	# [fill]...[/fill] justifie le texte (alignement par etirement des
	# espaces). "Settings tab" et "Mod Debug panel" en gras pour reperer
	# rapidement les references aux outils.
	var body := RichTextLabel.new()
	body.bbcode_enabled = true
	body.fit_content_height = true
	body.scroll_active = false
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.rect_min_size = Vector2(600, 0)
	body.bbcode_text = (
		"[fill]Thanks for trying out the [b]Unofficial Patch[/b]! "
		+ "This modpack aims to make your Dungeondraft experience even better.\n\n" 
		+ "Through the years, I've gathered all the feedback, "
		+ "bug reports and suggestions from the community, and tried to answer to most of them with this work.\n\n"
		+ "[b]A few examples of what's included:[/b]\n"
		+ "• [color=#9CC2FF]40+ bug fixes[/color]: crazy walls, stuck prefabs, pack cache cleanup, map resize issues, transparency issues, "
		+ "buggy selection, tools being stuck...\n"
		+ "• [color=#9CC2FF]50+ consistency features[/color]: move walls, unified rotation steps "
		+ "across tools, paste snap, new trace options, better text tool...\n"
		+ "• [color=#9CC2FF]50+ new features[/color]: free transform, "
		+ "pattern paint bucket, edit curves, asset favorites, "
		+ "in-place asset cycling, prefab thumbnails...\n\n"
		+ "For a breakdown of the major fixes and features, check out my "
		+ "[url=https://www.youtube.com/@moulk-map-lab][color=#9CC2FF][u]youtube channel[/u][/color][/url].\n\n"
		+ "Not needing a specific feature?\n"
		+ "Open the [color=#9CC2FF]Unofficial Patch Tool[/color] in the [color=#9CC2FF]Settings Tab[/color] "
		+ "to tweak which features are active. \nThe [color=#9CC2FF]Mod Debug Panel[/color] "
		+ "(hidden by default) lets you disable individual scripts if a mod "
		+ "ever misbehaves.\n\n"
		+ "If you have feedback, suggestions, or bug reports, ping me "
		+ "on Megasploot's Discord, I'm always happy to hear from "
		+ "users.\n\n"
		+ "[i]- Moulk -[/i][/fill]"
	)
	vbox.add_child(body)
	body.connect("meta_clicked", self, "_on_meta_clicked")

	vbox.add_child(HSeparator.new())

	# Footer : checkbox a gauche, OK a droite.
	var footer := HBoxContainer.new()
	footer.set("custom_constants/separation", 12)

	_check = CheckBox.new()
	_check.text = "Do not show again"
	_check.pressed = false
	_check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(_check)

	var ok_btn := Button.new()
	ok_btn.text = "OK"
	ok_btn.rect_min_size = Vector2(250, 0)
	ok_btn.connect("pressed", self, "_on_ok_pressed")
	footer.add_child(ok_btn)

	vbox.add_child(footer)

	_dialog.connect("popup_hide", self, "_on_popup_hide")

	# Add au noeud "Windows" si dispo (cf save_reminder), sinon a la racine.
	var windows = _g.Editor.get_node_or_null("Windows") if _g.Editor else null
	if windows != null:
		windows.add_child(_dialog)
	elif _g.World != null and is_instance_valid(_g.World):
		_g.World.get_tree().root.add_child(_dialog)
	else:
		return

	# Compute size after layout, then center.
	yield(_g.World.get_tree(), "idle_frame")
	if _dialog == null or not is_instance_valid(_dialog):
		return
	# get_combined_minimum_size sur le MarginContainer inclut son padding.
	var content_min = margin.get_combined_minimum_size()
	var title_h = _dialog.get_constant("title_height", "WindowDialog")
	var w = max(540.0, content_min.x)
	var h = content_min.y + title_h
	_dialog.popup_centered(Vector2(w, h))


# ── Actions ──────────────────────────────────────────────────────────────────

func _on_ok_pressed() -> void:
	if _check != null and is_instance_valid(_check) and _check.pressed:
		_seen = true
		_save_state_to_disk()
	if _dialog != null and is_instance_valid(_dialog):
		_dialog.hide()  # declenche popup_hide -> _on_popup_hide cleanup


# Appele quand l'utilisateur clique sur un tag [url=...] dans le body.
# On ouvre l'URL dans le navigateur par defaut de l'OS.
func _on_meta_clicked(meta) -> void:
	OS.shell_open(str(meta))


# Appele par signal popup_hide (clic OK, ESC, click hors popup, etc.).
# On free le dialog ici pour nettoyer l'arbre. _shown reste a true pour
# empecher la re-affichage cette session (Main.gd appelle
# show_if_first_time chaque frame tant que _loading_popup est null).
func _on_popup_hide() -> void:
	if _dialog != null and is_instance_valid(_dialog):
		_dialog.queue_free()
	_dialog = null
	_check = null
	# _shown reste a true pour bloquer toute re-affichage cette session.


# ── Persistance ──────────────────────────────────────────────────────────────

func _load_state_from_disk() -> void:
	var f := File.new()
	if not f.file_exists(_SETTINGS_FILE):
		return
	if f.open(_SETTINGS_FILE, File.READ) != OK:
		return
	var text = f.get_as_text()
	f.close()
	var parsed = JSON.parse(text)
	if parsed.error != OK or not (parsed.result is Dictionary):
		return
	_seen = bool(parsed.result.get("shown", false))


func _save_state_to_disk() -> void:
	var dir := Directory.new()
	if not dir.dir_exists("user://UnofficialPatch"):
		dir.make_dir_recursive("user://UnofficialPatch")
	var f := File.new()
	if f.open(_SETTINGS_FILE, File.WRITE) != OK:
		return
	f.store_string(JSON.print({"shown": _seen}))
	f.close()
