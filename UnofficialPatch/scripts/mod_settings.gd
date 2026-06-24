# mod_settings.gd
# Centralized ON/OFF toggles for mod features, grouped by themes.
# Persists state to user://UnofficialPatch/mod_settings.json.
#
# Two patterns supported:
#  - Pattern A (sub-feature flag): no callback, sub-mod queries is_enabled() at runtime.
#  - Pattern B (whole-mod hot load/unload): callback target+method = `func(enabled: bool)`
#    invoked on toggle change; consumer is responsible for load/cleanup.
#
# API:
#   register_section(id, label)
#   register_toggle(id, theme_id, label, tooltip, default,
#                   on_change_target=null, on_change_method="")
#   set_callback(id, target, method)
#   is_enabled(id) -> bool
#   set_enabled(id, value)
#   build_panel()        # call once after all registrations

var _g

const TOOL_CATEGORY  = "Settings"
const TOOL_ID        = "mod_settings"
const TOOL_NAME      = "Unofficial Patch"
const _SETTINGS_FILE = "user://UnofficialPatch/mod_settings.json"

var _themes      := []   # ordered: [{id, label}]
var _theme_ids   := {}   # id -> true
var _toggles     := {}   # id -> { theme, label, tooltip, default, value, cb_target, cb_method, control }
var _saved_state := {}   # loaded from disk before registrations
var _tool_panel   = null
var _panel_built := false

# Reference vers debug_settings (injectee par Main.gd) pour la sync
# bidirectionnelle (toggle settings change -> notifie debug, et inversement).
var debug_settings = null

# Set a true une fois que le bouton du tool debug a ete retire de l'arbre
# (pour ne pas tenter de le retirer plusieurs fois — get_parent() est null
# apres le premier remove_child).
var _debug_btn_removed := false

# Ids des toggles "locked off" : verrouilles a OFF parce qu'au moins un mod
# debug correspondant est OFF. Tant que c'est le cas, l'utilisateur ne peut
# pas les rallumer depuis ce panel — il doit d'abord rallumer les mods debug.
var _locked_off := {}

# === Custom tooltip system ===
# Le hint_tooltip natif de Godot est ajoute au viewport racine sur un
# layer bas — DD's hotbar et autres UI a fort z-index le masquent. On
# implemente notre propre tooltip sur un CanvasLayer.layer=4096 pour
# garantir qu'il s'affiche par dessus tout. Hooke via mouse_entered /
# mouse_exited sur les rows ; positionne pres du curseur en update().
var _tt_layer : CanvasLayer = null
var _tt_panel : PanelContainer = null
var _tt_label : Label = null
var _tt_text  : String = ""
var _tt_hover_time : float = -1.0  # -1 = pas en hover, >=0 = compteur
const _TT_DELAY := 0.5  # s avant affichage (matche le delai natif Godot)


func initialize():
	_load_settings_from_disk()
	_register_tool_panel()
	# Expose for cross-mod runtime queries (Pattern A consumers).
	if _g.get("ModMapData") != null and _g.ModMapData is Dictionary:
		_g.ModMapData["_mod_settings"] = self
	print("[ModSettings] Initialized")


# ── public API ────────────────────────────────────────────────────────────────

func register_section(id, label):
	if _theme_ids.has(id):
		return
	_theme_ids[id] = true
	_themes.append({"id": id, "label": label})


func register_toggle(id, theme_id, label, tooltip, default_value,
					 on_change_target=null, on_change_method="",
					 requires_restart=false, parent_id="", shortcut="",
					 master_skip=false):
	var stored = _saved_state.get(id, default_value)
	_toggles[id] = {
		"theme":     theme_id,
		"label":     label,
		"tooltip":   tooltip,
		"default":   default_value,
		"value":     stored,
		"cb_target": on_change_target,
		"cb_method": on_change_method,
		"requires_restart": requires_restart,
		"parent_id": parent_id,
		"shortcut":  shortcut,
		"master_skip": master_skip,
		"control":   null,
		"row":       null,
	}


func set_callback(id, target, method):
	if not _toggles.has(id):
		return
	_toggles[id]["cb_target"] = target
	_toggles[id]["cb_method"] = method


func is_enabled(id) -> bool:
	if not _toggles.has(id):
		return true   # fail-open: unregistered ids are treated as enabled
	# Locked off : un mod debug correspondant a ete desactive, donc cette
	# feature est forcee OFF quoi que dise le toggle utilisateur.
	if _locked_off.has(id) and _locked_off[id]:
		return false
	return _toggles[id]["value"]


# Retourne la valeur "brute" du toggle settings, telle que l'utilisateur
# l'a definie sur le panel settings, en IGNORANT le locked_off. Utilise
# par debug_settings pour distinguer "settings OFF = volonte user" (=
# grise les mods debug correspondants) de "settings locked = un mod debug
# est OFF" (= ne grise pas les mods debug, c'est l'inverse de la chaine).
func get_user_value(id) -> bool:
	if not _toggles.has(id):
		return true
	return _toggles[id]["value"]


# Appele par debug_settings._sync_to_mod_settings(sid). Verrouille le toggle
# settings sur OFF tant que locked = true. Affiche un dim visuel + decoche
# la CheckButton + bloque les clics utilisateur. Restore l'etat utilisateur
# quand locked devient false.
func set_locked_off(id: String, locked: bool) -> void:
	if not _toggles.has(id):
		return
	var was_locked = _locked_off.get(id, false)
	if locked == was_locked:
		return
	_locked_off[id] = locked
	var entry = _toggles[id]
	# Met visuellement le bouton OFF si locked (decoche), restore a la
	# valeur utilisateur si on unlock. set_pressed_no_signal pour ne pas
	# refire _on_toggled.
	var ctrl = entry.get("control")
	if ctrl != null and is_instance_valid(ctrl):
		if locked:
			ctrl.set_pressed_no_signal(false)
		else:
			ctrl.set_pressed_no_signal(entry["value"])
	# Refresh visuel : grise le row si locked, restore sinon.
	var row = entry.get("row")
	if row != null and is_instance_valid(row):
		if locked:
			row.modulate = Color(1, 1, 1, 0.4)
		else:
			# Re-applique le grayout enfant si parent OFF, sinon clear.
			var pid = str(entry.get("parent_id", ""))
			if pid != "" and _toggles.has(pid) and not is_enabled(pid):
				row.modulate = Color(1, 1, 1, 0.4)
			else:
				row.modulate = Color(1, 1, 1, 1)
	# Quand on lock, on fire le callback pour "deactivate" la feature (les
	# consumers Pattern A re-liront is_enabled qui renverra false ; les
	# consumers Pattern B doivent recevoir le callback pour cleanup).
	# Quand on unlock, on re-fire pour restore l'etat utilisateur.
	if entry["cb_target"] != null and entry["cb_method"] != "":
		var effective = is_enabled(id)
		entry["cb_target"].call(entry["cb_method"], effective)
	# Cascade sur les enfants : si ce toggle est parent d'autres toggles,
	# leur grayout doit refleter l'etat effectif (locked_off compte).
	_refresh_child_disabled_states()


func set_enabled(id, value):
	if not _toggles.has(id):
		return
	var entry = _toggles[id]
	if entry["value"] == bool(value):
		return
	entry["value"] = bool(value)
	if entry["control"] and is_instance_valid(entry["control"]):
		entry["control"].set_pressed_no_signal(entry["value"])
	_save_settings_to_disk()
	_fire_callback(entry)
	_refresh_child_disabled_states()


# Call once after every register_section / register_toggle.
func build_panel():
	if _panel_built or _tool_panel == null:
		return
	_panel_built = true

	# Sticky header (Check All/Uncheck All + restart notice) — placed
	# OUTSIDE the ScrollContainer so it stays visible while scrolling
	# the list of toggles below.
	if _toggles.size() > 0:
		_install_sticky_header()

	var first := true
	for theme in _themes:
		var has_any = false
		for id in _toggles:
			if _toggles[id]["theme"] == theme["id"]:
				has_any = true
				break
		if not has_any:
			continue
		if not first:
			# Divider entre deux grandes parties (avec un peu d'air autour).
			var spacer_top := Control.new()
			spacer_top.rect_min_size = Vector2(0, 8)
			_tool_panel.Align.add_child(spacer_top)
			_tool_panel.Align.add_child(HSeparator.new())
			var spacer_bot := Control.new()
			spacer_bot.rect_min_size = Vector2(0, 8)
			_tool_panel.Align.add_child(spacer_bot)
		first = false
		# Titre de section EN DEHORS de BeginSection. On utilise un
		# RichTextLabel + bbcode [center] pour bypasser le theme DD qui
		# applique du title-case sur les Label "classiques".
		var raw_label := str(theme["label"])
		var rtl := RichTextLabel.new()
		rtl.bbcode_enabled = true
		rtl.bbcode_text = "[center]" + raw_label + "[/center]"
		rtl.fit_content_height = true
		rtl.scroll_active = false
		rtl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rtl.rect_min_size = Vector2(0, 22)
		_tool_panel.Align.add_child(rtl)
		# La section contient uniquement les toggles.
		_tool_panel.BeginSection(false)
		for id in _toggles:
			var entry = _toggles[id]
			if entry["theme"] != theme["id"]:
				continue
			_build_toggle_row(id, entry)
		_tool_panel.EndSection()

	# Spacer terminal : sans ca le dernier toggle finit colle au bord
	# inferieur du tool panel (et est masque par la Floatbar quand elle
	# est visible). 60px donne assez d'air pour que tous les controls
	# restent cliquables meme tout en bas du scroll.
	var spacer_end := Control.new()
	spacer_end.rect_min_size = Vector2(0, 60)
	_tool_panel.Align.add_child(spacer_end)


# ── internals ─────────────────────────────────────────────────────────────────

func _register_tool_panel():
	if not _g.Editor or not _g.Editor.Toolset:
		return
	var icon_path = _g.Root + "icons/mod_settings_button.png"
	_tool_panel = _g.Editor.Toolset.CreateModTool(
		self, TOOL_CATEGORY, TOOL_ID, TOOL_NAME, icon_path)
	if _tool_panel == null:
		push_error("[ModSettings] CreateModTool failed")


func _build_toggle_row(id, entry):
	var btn := CheckButton.new()
	var lbl_text = str(entry["label"])
	if entry.get("requires_restart", false):
		lbl_text += " *"
	var sc = str(entry.get("shortcut", ""))
	var has_shortcut = sc != ""
	var pid = str(entry.get("parent_id", ""))
	var dim = pid != "" and _toggles.has(pid) and not _toggles[pid]["value"]

	if has_shortcut:
		# Layout custom : RichTextLabel (label + raccourci en plus petit/gris)
		# qui prend toute la place + CheckButton sans texte aligne a droite.
		# Le HBox sert de target pour le modulate (grayout enfant).
		btn.text = ""
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.set("custom_constants/separation", 4)

		var rtl := RichTextLabel.new()
		rtl.bbcode_enabled = true
		rtl.fit_content_height = true
		rtl.scroll_active = false
		rtl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rtl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		# IGNORE pour laisser le HBox row capturer mouse_entered/exited :
		# sinon le RTL (mouse_filter STOP par defaut) intercepte les events
		# de hover et le tooltip ne se declenche que sur le bouton.
		rtl.mouse_filter = Control.MOUSE_FILTER_IGNORE

		# Couleur du label : par defaut RTL hesrite d'une couleur de theme
		# qui peut etre plus sombre que le font_color des CheckButton voisines
		# (rendu visuellement plus terne). On copie le font_color du
		# CheckButton qui est dans la meme ligne pour rester homogene.
		var btn_color = btn.get_color("font_color")
		if btn_color != null:
			rtl.add_color_override("default_color", btn_color)

		# Pour avoir le raccourci en plus petit, on hijack l'italics_font
		# du RichTextLabel : on prend la normal_font (DynamicFont chargee
		# par le theme DD), on la duplique avec une size reduite, et on
		# l'enregistre comme italics_font override. Ainsi le tag bbcode
		# [i]...[/i] rend le texte en plus petit (visuellement plus
		# discret pour les raccourcis), sans dependre d'une vraie italic
		# qui n'est probablement pas presente dans le theme DD.
		var base = rtl.get_font("normal_font")
		if base != null and base is DynamicFont:
			var smaller := DynamicFont.new()
			smaller.font_data = base.font_data
			smaller.size = max(8, base.size - 3)
			rtl.add_font_override("italics_font", smaller)

		# Couleur gris doux + tag [i] (= rendu en plus petit grace a
		# l'override ci-dessus). Pas de crochets autour du raccourci.
		var bb = lbl_text + "  [color=#9C9590][i]" + sc + "[/i][/color]"
		rtl.bbcode_text = bb
		# Tooltip custom (CanvasLayer haut z-index, voir _attach_tooltip).
		# On l'attache au row pour qu'il declenche au survol n'importe ou
		# sur la ligne, et au bouton pour la zone du toggle elle-meme.
		if entry["tooltip"] != null and str(entry["tooltip"]) != "":
			_attach_tooltip(row, str(entry["tooltip"]))
		row.add_child(rtl)

		btn.size_flags_horizontal = Control.SIZE_SHRINK_END
		btn.pressed = entry["value"]
		if entry["tooltip"] != null and str(entry["tooltip"]) != "":
			_attach_tooltip(btn, str(entry["tooltip"]))
		btn.connect("toggled", self, "_on_toggled", [id])
		row.add_child(btn)

		if dim:
			row.modulate = Color(1, 1, 1, 0.4)

		entry["control"] = btn
		entry["row"] = row
		_tool_panel.Align.add_child(row)
	else:
		# Layout classique : juste une CheckButton avec son texte.
		btn.text = lbl_text
		btn.pressed = entry["value"]
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if entry["tooltip"] != null and str(entry["tooltip"]) != "":
			_attach_tooltip(btn, str(entry["tooltip"]))
		if dim:
			btn.modulate = Color(1, 1, 1, 0.4)
		btn.connect("toggled", self, "_on_toggled", [id])
		entry["control"] = btn
		entry["row"] = btn
		_tool_panel.Align.add_child(btn)


# Bouton avec contour blanc 1px (Check All / Uncheck All).
func _make_outlined_button(text: String) -> Button:
	# Bouton en style natif DD + bordure blanche 1px ajoutee par-dessus
	# via le signal "draw" du Control. Cette approche evite tout override
	# de stylebox (qui ramenait une teinte bleue residuelle du theme),
	# et la bordure se dessine APRES le rendu natif → garde le style DD
	# complet en arriere-plan.
	var btn := Button.new()
	btn.text = text
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# focus_mode NONE : le bouton ne prend plus le focus au clic (sinon
	# le theme DD applique son focus state par-dessus).
	btn.focus_mode = Control.FOCUS_NONE
	btn.connect("draw", self, "_draw_button_outline", [btn])
	return btn


# Dessine une bordure blanche 1px autour d'un Control. Connecte au signal
# "draw" : appele apres le rendu natif (qui dessine la stylebox du theme),
# donc l'outline apparait par-dessus.
# 4 draw_line plutot que draw_rect : draw_rect avec width=1 dessine centre
# sur le bord, donc la moitie de la largeur est hors du Control et clippee
# (le bord gauche disparait visuellement). Avec 4 lines aux positions
# exactes (0 et size-1) on garantit que tout reste dans le Control.
func _draw_button_outline(ctrl: Control) -> void:
	if ctrl == null or not is_instance_valid(ctrl):
		return
	var s = ctrl.rect_size
	var c = Color(1, 1, 1, 1)
	# top, bottom, left, right (1px chacun, dans les bounds)
	ctrl.draw_line(Vector2(0, 0), Vector2(s.x, 0), c, 1.0)
	ctrl.draw_line(Vector2(0, s.y - 1), Vector2(s.x, s.y - 1), c, 1.0)
	ctrl.draw_line(Vector2(0, 0), Vector2(0, s.y), c, 1.0)
	ctrl.draw_line(Vector2(s.x - 1, 0), Vector2(s.x - 1, s.y), c, 1.0)


# Header (Check All/Uncheck All + restart notice) en haut d'Align : ce
# sont juste des enfants normaux du VBoxContainer, ils scrollent avec le
# reste des toggles. Pas de comportement sticky.
func _install_sticky_header() -> void:
	if _tool_panel == null or _tool_panel.Align == null:
		return

	# Petit texte d'intro : informe l'utilisateur que ces toggles ne
	# couvrent qu'une partie des fixes du mod (les autres tournent en
	# tache de fond et ne sont pas pilotables).
	var intro := RichTextLabel.new()
	intro.bbcode_enabled = true
	intro.bbcode_text = "[center][color=#B0B0B0]Below is a small subset of the fixes\nincluded in the Unofficial Patch.[/color][/center]"
	intro.fit_content_height = true
	intro.scroll_active = false
	intro.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	intro.rect_min_size = Vector2(0, 36)
	_tool_panel.Align.add_child(intro)

	# Petit espace entre l'intro et les boutons master.
	var spacer_intro := Control.new()
	spacer_intro.rect_min_size = Vector2(0, 6)
	_tool_panel.Align.add_child(spacer_intro)

	var master_row := HBoxContainer.new()
	master_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	master_row.set("custom_constants/separation", 6)
	var check_all = _make_outlined_button("Check All")
	check_all.connect("pressed", self, "_on_master_toggle", [true])
	master_row.add_child(check_all)
	var uncheck_all = _make_outlined_button("Uncheck All")
	uncheck_all.connect("pressed", self, "_on_master_toggle", [false])
	master_row.add_child(uncheck_all)
	# Wrap dans un MarginContainer : sans ca les bords gauche/droit des
	# boutons SIZE_EXPAND_FILL sont colles au bord du panel et le 1er
	# pixel de la bordure dessinee est clippe.
	var master_margin := MarginContainer.new()
	master_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	master_margin.set("custom_constants/margin_left", 4)
	master_margin.set("custom_constants/margin_right", 4)
	master_margin.add_child(master_row)
	_tool_panel.Align.add_child(master_margin)

	var has_restart_toggle := false
	for id in _toggles:
		if _toggles[id].get("requires_restart", false):
			has_restart_toggle = true
			break
	if has_restart_toggle:
		var spacer_hdr := Control.new()
		spacer_hdr.rect_min_size = Vector2(0, 4)
		_tool_panel.Align.add_child(spacer_hdr)
		var notice := RichTextLabel.new()
		notice.bbcode_enabled = true
		notice.bbcode_text = "[center][color=#FFCB33]*takes effect on next launch[/color][/center]"
		notice.fit_content_height = true
		notice.scroll_active = false
		notice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		notice.rect_min_size = Vector2(0, 20)
		_tool_panel.Align.add_child(notice)

	# Petit espace avant la premiere section.
	var spacer := Control.new()
	spacer.rect_min_size = Vector2(0, 6)
	_tool_panel.Align.add_child(spacer)


# No-op : conserve pour compatibilite avec Main.gd qui appelle
# mod_settings.update(delta). Pilote le custom tooltip system :
# - timer pour delai d'affichage avant show
# - repositionnement par-frame pour suivre le curseur
func update(delta: float) -> void:
	# Force le bouton du tool debug a etre toujours invisible dans la barre
	# verticale, et force le panel debug a etre visible quand le tool
	# mod_settings est actif (si display_debug_tool est ON). Sans ca :
	# (1) il y aurait deux icones empilees dans la barre (Mod Settings et
	# Mod Debug) ce que le user ne veut pas, et (2) DD cache le panel
	# debug a chaque switch de tool, le user devait toggle off/on pour
	# le faire reapparaitre. Faire ca chaque frame est OK : ce sont juste
	# des assignments qui no-op si deja dans l'etat voulu.
	if debug_settings != null and _g != null and _g.Editor != null and is_instance_valid(_g.Editor):
		# (1) Boutons tool debug : retires de la hierarchie une fois pour
		# toutes. DD enregistre potentiellement plusieurs representations
		# du tool button (barre verticale principale + liste de la
		# categorie "Settings" qu'on voit en cliquant sur l'icone Settings).
		# Setter btn.visible = false n'etait pas fiable (parent Container
		# override). On retire directement les nodes de l'arbre — le panel
		# (debug_settings._tool_panel) reste valide en memoire.
		if not _debug_btn_removed:
			_remove_debug_buttons()
		# (2) Panel debug : visible si display_debug_tool ON et qu'on est
		# sur le tool mod_settings. Sinon cache (DD ne le cache pas
		# automatiquement puisque mod_debug n'est jamais le tool actif —
		# son bouton a ete retire de l'arbre).
		var atn = _g.Editor.get("ActiveToolName")
		var dpanel = debug_settings._tool_panel
		var debug_panel_visible := false
		if dpanel != null and is_instance_valid(dpanel):
			var should_show = atn == TOOL_ID and is_enabled("display_debug_tool")
			if should_show:
				if not dpanel.visible:
					dpanel.visible = true
				dpanel.raise()
				debug_panel_visible = true
			elif dpanel.visible:
				dpanel.visible = false
		# Cache la Floatbar (= la barre Grid/Snap/Lighting/zoom/layers en
		# bas) tant que le Debug Panel est affiche, parce qu'elle masque
		# le bas de ce panel. Quand le Debug Panel n'est pas affiche (autre
		# tool, ou Display Debug Panel OFF), on remet la Floatbar visible.
		var floatbar = _g.Editor.get_node_or_null("Floatbar")
		if floatbar != null and is_instance_valid(floatbar):
			var fb_should_show = not debug_panel_visible
			if floatbar.visible != fb_should_show:
				floatbar.visible = fb_should_show
	# Tooltip system :
	if _tt_layer == null or not is_instance_valid(_tt_layer):
		return
	if _tt_panel == null or not is_instance_valid(_tt_panel):
		return
	if _tt_hover_time < 0.0:
		return  # pas en hover
	# Compte le delai avant affichage
	if _tt_hover_time < _TT_DELAY:
		_tt_hover_time += delta
		if _tt_hover_time >= _TT_DELAY:
			_tt_label.text = _tt_text
			# Force le recalcul de la taille minimale du label puis du
			# PanelContainer : sans ca, le panel garde la taille du tooltip
			# precedent (plus grand) ou affiche du blanc autour. On reset
			# rect_min_size + rect_size a 0 pour laisser Godot recalculer
			# selon le contenu reel.
			_tt_label.rect_min_size = Vector2.ZERO
			_tt_label.rect_size = Vector2.ZERO
			_tt_panel.rect_min_size = Vector2.ZERO
			_tt_panel.rect_size = Vector2.ZERO
			_tt_panel.visible = true
	if _tt_panel.visible:
		# Position : 16px a droite + 20px en bas du curseur, avec
		# clamping pour ne pas sortir du viewport.
		var vp = _tt_layer.get_viewport()
		if vp == null:
			return
		var mp = vp.get_mouse_position()
		var vps = vp.size
		var ts = _tt_panel.rect_size
		var pos = mp + Vector2(16, 20)
		if pos.x + ts.x > vps.x - 4:
			pos.x = max(4.0, mp.x - ts.x - 8)
		if pos.y + ts.y > vps.y - 4:
			pos.y = max(4.0, mp.y - ts.y - 8)
		_tt_panel.rect_position = pos


# Cherche dans toute la hierarchie sous _g.Editor les Button / ToolButton
# qui representent le tool Mod Debug (matching name == TOOL_ID OU text ==
# TOOL_NAME) et les retire de leur parent. Couvre les deux representations
# connues : la barre verticale principale (ToolsetButtons) et la liste
# de la categorie "Settings". BFS plafonne a quelques milliers de noeuds
# pour eviter une iteration interminable au cas ou.
func _remove_debug_buttons() -> void:
	if debug_settings == null:
		return
	var root = _g.Editor
	if root == null:
		return
	var target_id = str(debug_settings.TOOL_ID)
	var target_name = str(debug_settings.TOOL_NAME)
	var queue := [root]
	var visited := 0
	var max_visit := 5000
	var found_any := false
	# Collecte AVANT remove pour ne pas modifier l'arbre pendant l'iter.
	var to_remove := []
	while queue.size() > 0 and visited < max_visit:
		var node = queue.pop_front()
		visited += 1
		if node == null or not is_instance_valid(node):
			continue
		# Matching multi-critere : DD enregistre les boutons du tool a
		# differents endroits (barre verticale, sous-panel "Settings", etc.)
		# avec parfois name=="mod_debug", parfois text=="Mod Debug",
		# parfois juste hint_tooltip=="Mod Debug". On match les 3 pour ne
		# rater aucune representation. Limite aux Button/ToolButton pour
		# eviter les faux positifs sur d'autres types de Control.
		if (node is Button or node is ToolButton):
			var matches := false
			if str(node.name) == target_id:
				matches = true
			elif "text" in node and str(node.text) == target_name:
				matches = true
			elif "hint_tooltip" in node and str(node.hint_tooltip) == target_name:
				matches = true
			if matches:
				to_remove.append(node)
				continue  # pas la peine d'iterer ses enfants
		for c in node.get_children():
			queue.append(c)
	for n in to_remove:
		if n != null and is_instance_valid(n):
			var p = n.get_parent()
			if p != null:
				p.remove_child(n)
				found_any = true
	if found_any:
		_debug_btn_removed = true


func _ensure_tooltip_layer() -> void:
	if _tt_layer != null and is_instance_valid(_tt_layer):
		return
	if _tool_panel == null or _tool_panel.get_tree() == null:
		return
	_tt_layer = CanvasLayer.new()
	_tt_layer.name = "ModSettingsTooltipLayer"
	_tt_layer.layer = 4096

	_tt_panel = PanelContainer.new()
	_tt_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tt_panel.visible = false
	# Stylebox legere pour le fond du tooltip — couleur alignee sur les
	# popups DD (warm dark gray semi-opaque, fine bordure claire).
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.118, 0.106, 0.094, 0.96)
	sb.border_color = Color(0.6, 0.55, 0.5, 0.7)
	sb.set_border_width_all(1)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 5
	sb.content_margin_bottom = 5
	_tt_panel.add_stylebox_override("panel", sb)

	_tt_label = Label.new()
	_tt_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tt_label.add_color_override("font_color", Color(0.93, 0.93, 0.93))
	_tt_panel.add_child(_tt_label)
	_tt_layer.add_child(_tt_panel)
	_tool_panel.get_tree().root.add_child(_tt_layer)


# Attache notre tooltip custom a un Control. Effet : hint_tooltip natif
# desactive (sinon double tooltip), signaux mouse_entered/exited connectes
# pour piloter notre panel.
func _attach_tooltip(control: Control, text: String) -> void:
	if control == null or text == "":
		return
	control.hint_tooltip = ""
	control.mouse_filter = Control.MOUSE_FILTER_STOP
	if not control.is_connected("mouse_entered", self, "_on_tt_enter"):
		control.connect("mouse_entered", self, "_on_tt_enter", [text])
		control.connect("mouse_exited", self, "_on_tt_exit")


func _on_tt_enter(text: String) -> void:
	_ensure_tooltip_layer()
	_tt_text = text
	_tt_hover_time = 0.0
	if _tt_panel != null:
		_tt_panel.visible = false  # cache pendant le delai


func _on_tt_exit() -> void:
	_tt_hover_time = -1.0
	if _tt_panel != null:
		_tt_panel.visible = false


func _on_toggled(value, id):
	if not _toggles.has(id):
		return
	var entry = _toggles[id]
	# Locked off : l'utilisateur ne peut pas le toggle, on revert le clic.
	if _locked_off.get(id, false):
		if entry["control"] and is_instance_valid(entry["control"]):
			entry["control"].set_pressed_no_signal(entry["value"])
		return
	# Si c'est un toggle enfant et que le parent est OFF (value OU locked),
	# on ignore le clic et on remet le checkbutton dans son etat memorise.
	var pid = str(entry.get("parent_id", ""))
	if pid != "" and _toggles.has(pid) and not is_enabled(pid):
		if entry["control"] and is_instance_valid(entry["control"]):
			entry["control"].set_pressed_no_signal(entry["value"])
		return
	entry["value"] = bool(value)
	_save_settings_to_disk()
	_fire_callback(entry)
	_refresh_child_disabled_states()
	# Notifie debug_settings : settings -> debug. Les mods debug lies a ce
	# settings_id sont force-OFF si on coche, restored si on coche.
	if debug_settings != null and debug_settings.has_method("on_setting_changed"):
		debug_settings.on_setting_changed(str(id), bool(value))


func _fire_callback(entry):
	var t = entry["cb_target"]
	var m = entry["cb_method"]
	if t == null or m == "":
		return
	if not is_instance_valid(t):
		return
	if not t.has_method(m):
		return
	t.call(m, entry["value"])


# Master toggle : applique value a tous les toggles, fait un seul save disque,
# fire les callbacks pour ceux dont l'etat a change.
func _on_master_toggle(value: bool) -> void:
	for id in _toggles:
		var entry = _toggles[id]
		# Skip les toggles "master_skip" (ex: Display Debug Tool) : ils ne
		# sont pas affectes par Check All / Uncheck All.
		if entry.get("master_skip", false):
			continue
		# Skip les toggles locked off (par debug) : on n'a pas le droit de
		# les rallumer ici, ils restent verrouilles tant que les mods debug
		# correspondants sont OFF.
		if value and _locked_off.get(id, false):
			continue
		if entry["value"] == value:
			continue
		entry["value"] = value
		if entry["control"] and is_instance_valid(entry["control"]):
			entry["control"].set_pressed_no_signal(value)
		_fire_callback(entry)
		# Notifie debug_settings pour cette ligne aussi : settings → debug.
		# Sans ca, Uncheck All ne synchronisait pas debug, et au reboot les
		# deux JSON etaient incoherents → certains loads skip → crash sur
		# refs non gardees.
		if debug_settings != null and debug_settings.has_method("on_setting_changed"):
			debug_settings.on_setting_changed(str(id), value)
	_save_settings_to_disk()
	_refresh_child_disabled_states()


# Iter sur les toggles avec un parent_id et grise/dégrise leur row via
# modulate selon la valeur du parent. On evite .disabled qui ecrase la
# stylebox custom des CheckButton de DD.
func _refresh_child_disabled_states() -> void:
	for id in _toggles:
		var entry = _toggles[id]
		var pid = str(entry.get("parent_id", ""))
		if pid == "" or not _toggles.has(pid):
			continue
		var row = entry.get("row")
		var ctrl = entry.get("control")
		# is_enabled prend en compte locked_off, donc un parent locked OFF
		# (force par debug) grise aussi ses enfants ET les met visuellement
		# OFF. Quand le parent est unlock, on restore l'etat utilisateur.
		var parent_on = is_enabled(pid)
		if row != null and is_instance_valid(row):
			row.modulate = Color(1, 1, 1, 1) if parent_on else Color(1, 1, 1, 0.4)
		if ctrl != null and is_instance_valid(ctrl):
			ctrl.set_pressed_no_signal(entry["value"] if parent_on else false)


# ── persistence ───────────────────────────────────────────────────────────────

func _load_settings_from_disk():
	var f := File.new()
	if not f.file_exists(_SETTINGS_FILE):
		return
	if f.open(_SETTINGS_FILE, File.READ) != OK:
		return
	var text = f.get_as_text()
	f.close()
	var parsed = JSON.parse(text)
	if parsed.error == OK and parsed.result is Dictionary:
		for k in parsed.result:
			_saved_state[k] = bool(parsed.result[k])


func _save_settings_to_disk():
	var dir := Directory.new()
	if not dir.dir_exists("user://UnofficialPatch"):
		dir.make_dir_recursive("user://UnofficialPatch")
	var data := {}
	for id in _toggles:
		data[id] = _toggles[id]["value"]
	var f := File.new()
	if f.open(_SETTINGS_FILE, File.WRITE) == OK:
		f.store_line(JSON.print(data, "\t"))
		f.close()
