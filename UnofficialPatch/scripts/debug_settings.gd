# debug_settings.gd
# ─────────────────────────────────────────────────────────────────────────────
# Debug tool : permet a l'utilisateur de desactiver individuellement chaque
# fichier charge par Main.gd, pour identifier rapidement le mod qui cause un
# probleme. Chaque toggle est next-launch (le chargement du script est gate
# tres tot dans Main.gd, hot-toggle impossible).
#
# Pilotage :
# - is_mod_enabled(id) -> bool : appele par Main.gd avant chaque load
# - register_mod(id, label, depends_on, settings_id) : appele depuis le
#   constructeur de Main.gd pour declarer la liste des mods. Les dependances
#   sont cascadees off (si on desactive A et B depend de A, B est aussi off).
# - settings_id : si renseigne, lit l'etat du toggle correspondant dans
#   mod_settings ; si OFF, le mod est force OFF dans ce panel et grise.
#
# Persistance : user://UnofficialPatch/debug_settings.json
# Defaut : tous les mods sont ENABLED.

var _g

const TOOL_CATEGORY  = "Settings"
const TOOL_ID        = "mod_debug"
const TOOL_NAME      = "Mod Debug"
const _SETTINGS_FILE = "user://UnofficialPatch/debug_settings.json"

# id -> { "label": str, "depends_on": [ids], "settings_id": str, "enabled": bool, "control": Control, "row": Control }
var _mods := {}
# settings_id -> [mod_ids] : reverse map pour la sync settings → debug.
# Permet de retrouver tous les mods debug qui dependent d'un meme toggle
# mod_settings (ex: "edit_curves" -> ["path_curve_edit", "wall_curve_edit",
# "pattern_curve_edit", "arc_draw", "edit_points_undo"]).
var _settings_id_to_mod_ids := {}
var _saved_state := {}
var _tool_panel = null
var _panel_built := false

# Reference vers mod_settings (injectee par Main.gd) pour la cross-ref
# settings_id -> force OFF.
var mod_settings = null


func initialize():
	_load_state_from_disk()
	_register_tool_panel()
	print("[DebugSettings] Initialized")


# ── Public API ────────────────────────────────────────────────────────────────

func register_mod(id: String, label: String = "", depends_on: Array = [], settings_id = "", tooltip: String = "") -> void:
	if id == "":
		return
	if label == "":
		label = _humanize(id)
	# settings_id peut etre une String (un seul toggle) ou une Array (plusieurs).
	# On normalise en Array pour le reste du code.
	var sids := []
	if settings_id is String:
		if settings_id != "":
			sids.append(settings_id)
	elif settings_id is Array:
		for s in settings_id:
			if s is String and s != "":
				sids.append(s)
	var stored = _saved_state.get(id, true)
	_mods[id] = {
		"label": label,
		"depends_on": depends_on,
		"settings_ids": sids,
		"tooltip": tooltip,
		"enabled": stored,
		"control": null,
		"row": null,
	}
	# Reverse map pour la sync settings → debug : chaque settings_id pointe
	# vers la liste des mods debug qui l'implementent.
	for sid in sids:
		if not _settings_id_to_mod_ids.has(sid):
			_settings_id_to_mod_ids[sid] = []
		_settings_id_to_mod_ids[sid].append(id)


func is_mod_enabled(id: String) -> bool:
	if not _mods.has(id):
		return true  # mod non enregistre = autorise par defaut
	if not _mods[id]["enabled"]:
		return false
	# Pour les mods multi-settings (ex: rotation_fix gere consistent_rotation
	# + one_deg_rotation), on ne considere le mod disable que si TOUS ses
	# settings sont OFF. Tant qu'au moins un est ON, le mod doit tourner
	# pour gerer cette feature (les autres seront runtime-checkees).
	var sids = _mods[id].get("settings_ids", [])
	if sids.empty():
		return true
	if mod_settings == null or not mod_settings.has_method("is_enabled"):
		return true
	for sid in sids:
		if mod_settings.is_enabled(sid):
			return true  # au moins une feature est voulue
	return false  # toutes les features sont OFF


# Pilote par le toggle "Display Debug Panel" du panel mod_settings. OFF
# cache le panel debug. ON le restore. Le bouton du tool debug dans la
# barre verticale est toujours cache (force chaque frame par mod_settings)
# pour eviter d'avoir deux icones empilees.
func set_visible(v: bool) -> void:
	if _tool_panel != null and is_instance_valid(_tool_panel):
		_tool_panel.visible = v


# Reset tous les mods debug a enabled=true (= state initial). Notifie
# mod_settings de unlock chaque settings_id (puisque plus aucun mod debug
# n'est OFF). Sauvegarde le state. Utilise quand le user disable le
# tool Mod Debug entierement via "Display Debug Tool" : on revient a un
# etat propre comme si le tool n'avait jamais ete touche.
func reset_all_to_enabled() -> void:
	for id in _mods:
		_mods[id]["enabled"] = true
		_saved_state[id] = true
		var ctrl = _mods[id].get("control")
		if ctrl != null and is_instance_valid(ctrl):
			ctrl.set_pressed_no_signal(true)
	_save_state_to_disk()
	# Unlock tous les settings qui etaient locked off.
	if mod_settings != null:
		for sid in _settings_id_to_mod_ids:
			_sync_to_mod_settings(sid)
	_refresh_grayed()


# ── Panel ─────────────────────────────────────────────────────────────────────

func build_panel():
	if _panel_built or _tool_panel == null:
		return
	_panel_built = true

	# Intro
	var intro := RichTextLabel.new()
	intro.bbcode_enabled = true
	intro.bbcode_text = "[center][color=#B0B0B0]Disable individual mod scripts to isolate an issue. Changes apply on next launch.[/color][/center]"
	intro.fit_content_height = true
	intro.scroll_active = false
	intro.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	intro.rect_min_size = Vector2(0, 36)
	_tool_panel.Align.add_child(intro)

	var spacer_intro := Control.new()
	spacer_intro.rect_min_size = Vector2(0, 6)
	_tool_panel.Align.add_child(spacer_intro)

	# Master row : Enable All / Disable All.
	var master_row := HBoxContainer.new()
	master_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	master_row.set("custom_constants/separation", 6)
	var enable_all = _make_outlined_button("Enable All")
	enable_all.connect("pressed", self, "_on_master_toggle", [true])
	master_row.add_child(enable_all)
	var disable_all = _make_outlined_button("Disable All")
	disable_all.connect("pressed", self, "_on_master_toggle", [false])
	master_row.add_child(disable_all)
	# MarginContainer pour donner de l'espace aux bords gauche/droit
	# (sinon le 1er pixel de l'outline du bouton est clippe par le parent).
	var master_margin := MarginContainer.new()
	master_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	master_margin.set("custom_constants/margin_left", 4)
	master_margin.set("custom_constants/margin_right", 4)
	master_margin.add_child(master_row)
	_tool_panel.Align.add_child(master_margin)

	var spacer1 := Control.new()
	spacer1.rect_min_size = Vector2(0, 8)
	_tool_panel.Align.add_child(spacer1)

	# Liste des toggles, triee alphabetiquement par label affiche.
	# (Trier par id mettait les ids CamelCase comme "ColorPickerFix" avant
	# les snake_case parce que ASCII majuscule < minuscule.)
	var ids = _mods.keys()
	ids.sort_custom(self, "_compare_labels")
	for id in ids:
		_build_toggle_row(id, _mods[id])

	# Spacer terminal : sans ca le dernier toggle est colle au bord
	# inferieur du panel et difficilement cliquable.
	var spacer_end := Control.new()
	spacer_end.rect_min_size = Vector2(0, 60)
	_tool_panel.Align.add_child(spacer_end)

	_refresh_grayed()


# Comparator pour trier les ids selon leur label affiche.
func _compare_labels(a: String, b: String) -> bool:
	var la = str(_mods[a].get("label", a)).to_lower()
	var lb = str(_mods[b].get("label", b)).to_lower()
	return la < lb


func _build_toggle_row(id, entry):
	var btn := CheckButton.new()
	btn.text = str(entry["label"])
	btn.pressed = entry["enabled"]
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.connect("toggled", self, "_on_toggled", [id])
	entry["control"] = btn
	entry["row"] = btn
	# Tooltip custom : on reutilise le systeme de mod_settings (PanelContainer
	# sur CanvasLayer haut z-index, delai 0.5s). Le panel debug n'a pas
	# son propre systeme — il piggy-back sur celui du panel settings.
	var tooltip = str(entry.get("tooltip", ""))
	if tooltip != "" and mod_settings != null and mod_settings.has_method("_attach_tooltip"):
		mod_settings._attach_tooltip(btn, tooltip)
	_tool_panel.Align.add_child(btn)


func _on_toggled(value, id):
	if not _mods.has(id):
		return
	var entry = _mods[id]
	entry["enabled"] = value
	_saved_state[id] = value
	# Cascade : si on disable, on disable aussi tous les dependants.
	if not value:
		_cascade_disable(id)
	# Sync vers mod_settings : si ce mod a un settings_id, on lock/unlock
	# le toggle correspondant.
	for sid in entry.get("settings_ids", []):
		_sync_to_mod_settings(sid)
	_save_state_to_disk()
	_refresh_grayed()


# ── Sync settings ↔ debug ────────────────────────────────────────────────────

# Pour un settings_id donne, regarde l'etat de tous les mods debug qui y
# sont lies. Si au moins un est OFF, on lock le toggle mod_settings sur
# OFF. Sinon, on unlock (l'utilisateur reprend le controle).
func _sync_to_mod_settings(sid: String) -> void:
	if mod_settings == null:
		return
	if not _settings_id_to_mod_ids.has(sid):
		return
	# IMPORTANT : on lit _saved_state (volonte utilisateur explicite sur le
	# panel debug), pas _mods[id]["enabled"] (qui peut etre force-OFF par
	# un side-effect du toggle settings via on_setting_changed). Sans ca,
	# desactiver un settings -> force-OFF du mod debug en memoire -> le
	# sync au boot ou hot lock le settings, et impossible de delock sans
	# action manuelle. _saved_state default true = considere ON tant que
	# l'user n'a pas explicitement decoche dans le panel debug.
	var any_disabled := false
	for mod_id in _settings_id_to_mod_ids[sid]:
		if not _saved_state.get(mod_id, true):
			any_disabled = true
			break
	if mod_settings.has_method("set_locked_off"):
		mod_settings.set_locked_off(sid, any_disabled)


# Appele par mod_settings._on_toggled quand l'utilisateur change un toggle
# settings. Pour les mods multi-features (ex: rotation_fix gere a la fois
# consistent_rotation et one_deg_rotation), on ne force OFF le mod que si
# TOUS ses settings_ids sont OFF (= aucune feature voulue, le mod n'a plus
# rien a faire). Tant qu'au moins un settings est ON, le mod reste enabled
# pour gerer cette feature en runtime.
# IMPORTANT : on ne sauvegarde PAS sur disque ici. Le force-OFF est derive
# du toggle settings — il sera reconstruit au boot via le sync settings->
# debug dans Main.gd.
func on_setting_changed(sid: String, value: bool) -> void:
	if not _settings_id_to_mod_ids.has(sid):
		return
	for mod_id in _settings_id_to_mod_ids[sid]:
		if not _mods.has(mod_id):
			continue
		var mod_sids = _mods[mod_id].get("settings_ids", [])
		# Le mod doit etre force-OFF uniquement si TOUS ses settings_ids
		# sont OFF cote settings. Sinon il garde sa valeur utilisateur
		# (depuis _saved_state) parce qu'il a encore au moins une feature
		# active a gerer.
		var all_settings_off := true
		for s in mod_sids:
			if mod_settings != null and mod_settings.has_method("get_user_value"):
				if mod_settings.get_user_value(s):
					all_settings_off = false
					break
			else:
				all_settings_off = false
				break
		if all_settings_off:
			_mods[mod_id]["enabled"] = false
		else:
			# Restore l'etat persiste de l'utilisateur. Au moins une feature
			# du mod est encore desiree, donc le mod doit tourner (sauf si
			# l'user a explicitement decoche le mod en debug).
			_mods[mod_id]["enabled"] = _saved_state.get(mod_id, true)
	_refresh_grayed()


func _cascade_disable(disabled_id: String) -> void:
	# BFS sur _mods : chaque mod dont depends_on contient disabled_id (ou
	# un id deja desactive cette passe) est mis a false.
	var queue := [disabled_id]
	var visited := {}
	while queue.size() > 0:
		var current = queue.pop_front()
		if visited.has(current):
			continue
		visited[current] = true
		for other_id in _mods:
			if visited.has(other_id):
				continue
			var deps = _mods[other_id].get("depends_on", [])
			if not (deps is Array):
				continue
			if current in deps and _mods[other_id]["enabled"]:
				_mods[other_id]["enabled"] = false
				_saved_state[other_id] = false
				if _mods[other_id]["control"] != null and is_instance_valid(_mods[other_id]["control"]):
					_mods[other_id]["control"].set_pressed_no_signal(false)
				queue.append(other_id)


func _on_master_toggle(value: bool) -> void:
	for id in _mods:
		_mods[id]["enabled"] = value
		_saved_state[id] = value
		if _mods[id]["control"] != null and is_instance_valid(_mods[id]["control"]):
			_mods[id]["control"].set_pressed_no_signal(value)
	# Sync tous les settings_id concernes vers mod_settings (en bloc).
	if mod_settings != null:
		for sid in _settings_id_to_mod_ids:
			_sync_to_mod_settings(sid)
	_save_state_to_disk()
	_refresh_grayed()


# ── Force-disabled (cross-ref mod_settings → debug) ───────────────────────────

# Returns true si TOUS les settings_ids du mod ont ete decoches par
# l'utilisateur via le panel settings. Dans ce cas le mod n'a plus aucune
# feature a gerer → on le grise. Si au moins UN settings est ON, le mod
# doit rester actif pour cette feature (cas mod multi-feature comme
# rotation_fix qui gere consistent_rotation + one_deg_rotation).
# On lit get_user_value pour eviter le grisage circulaire (locked_off vs
# user-decoche).
func _is_force_disabled(id: String) -> bool:
	if not _mods.has(id):
		return false
	var sids = _mods[id].get("settings_ids", [])
	if sids.empty():
		return false
	if mod_settings == null or not mod_settings.has_method("get_user_value"):
		return false
	# Force OFF seulement si TOUS les settings_ids sont OFF.
	for sid in sids:
		if mod_settings.get_user_value(sid):
			return false
	return true


func _refresh_grayed() -> void:
	for id in _mods:
		var entry = _mods[id]
		var ctrl = entry.get("control")
		if ctrl == null or not is_instance_valid(ctrl):
			continue
		var force_off = _is_force_disabled(id)
		ctrl.set_pressed_no_signal(entry["enabled"] and not force_off)
		if force_off:
			ctrl.modulate = Color(1, 1, 1, 0.4)
		else:
			ctrl.modulate = Color(1, 1, 1, 1)


# ── Persistance ───────────────────────────────────────────────────────────────

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
	_saved_state = parsed.result


func _save_state_to_disk() -> void:
	var dir := Directory.new()
	if not dir.dir_exists("user://UnofficialPatch"):
		dir.make_dir_recursive("user://UnofficialPatch")
	var data := {}
	for id in _mods:
		data[id] = _mods[id]["enabled"]
	var f := File.new()
	if f.open(_SETTINGS_FILE, File.WRITE) != OK:
		return
	# Indent "\t" pour produire un JSON lisible (une cle par ligne) au
	# lieu d'une seule ligne compacte. JSON.parse au load gere les deux.
	f.store_string(JSON.print(data, "\t"))
	f.close()


# ── Tool registration ─────────────────────────────────────────────────────────

func _register_tool_panel():
	if not _g.Editor or not _g.Editor.Toolset:
		return
	var icon_path = _g.Root + "icons/mod_debug_button.png"
	# Fallback sur l'icone mod_settings si on n'a pas d'icone debug dedie.
	var f := File.new()
	if not f.file_exists(icon_path):
		icon_path = _g.Root + "icons/mod_settings_button.png"
	_tool_panel = _g.Editor.Toolset.CreateModTool(
		self, TOOL_CATEGORY, TOOL_ID, TOOL_NAME, icon_path)
	if _tool_panel == null:
		push_error("[DebugSettings] CreateModTool failed")


# ── Helpers ───────────────────────────────────────────────────────────────────

func _humanize(id: String) -> String:
	var parts = id.split("_")
	var out = ""
	for p in parts:
		if p == "":
			continue
		if out != "":
			out += " "
		out += p.substr(0, 1).to_upper() + p.substr(1)
	return out


# Bouton avec contour blanc 1px (Enable All / Disable All).
# Style natif DD + outline 1px dessinee par-dessus via le signal "draw"
# (cf. mod_settings._make_outlined_button pour les details).
func _make_outlined_button(text: String) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.focus_mode = Control.FOCUS_NONE
	btn.connect("draw", self, "_draw_button_outline", [btn])
	return btn


func _draw_button_outline(ctrl: Control) -> void:
	if ctrl == null or not is_instance_valid(ctrl):
		return
	var s = ctrl.rect_size
	var c = Color(1, 1, 1, 1)
	ctrl.draw_line(Vector2(0, 0), Vector2(s.x, 0), c, 1.0)
	ctrl.draw_line(Vector2(0, s.y - 1), Vector2(s.x, s.y - 1), c, 1.0)
	ctrl.draw_line(Vector2(0, 0), Vector2(0, s.y), c, 1.0)
	ctrl.draw_line(Vector2(s.x - 1, 0), Vector2(s.x - 1, s.y), c, 1.0)
