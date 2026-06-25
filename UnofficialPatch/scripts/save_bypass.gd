# save_bypass.gd
# ─────────────────────────────────────────────────────────────────────────────
# Robustesse de la sauvegarde / backup face au bug "Dungeondraft is busy"
# (autosave bloque : IsSaving/IsBackingUp restent true a vie -> IsBusy bloque).
#
# On ne peut PAS reecrire les flags statiques (set() = no-op) mais on peut les
# LIRE, appeler des methodes d'instance, et intercepter les declencheurs. Le mod
# n'intervient QUE lorsqu'un blocage est detecte ; le reste du temps tout est
# 100% vanilla.
#
# 1) SAUVEGARDE (Ctrl+S / bouton SAVE / menu "Save As") :
#    - Pas bloque -> natif inchange (dialogue OS natif compris).
#    - Bloque     -> on accroche les declencheurs et on ecrit nous-memes :
#        * Save    : ecrase le fichier courant (atomique temp/backup/rename),
#                    puis OnOpenedOrSaved() (titre + IsModified=false).
#        * Save As : dialogue OS NATIF (OS.ShowSaveDialog / zenity).
#      Si DD se debloque, les connexions natives sont restaurees.
#
# 2) SPINNER "backing up/saving" (Infobar) : s'il tourne depuis >10s (backup
#    bloque qui n'appelle jamais OnSaveEnd), on appelle Infobar.OnSaveEnd()
#    (chemin natif) pour l'arreter proprement.
#
# 3) BACKUPS AUTO : quand DD est bloque (sa boucle Master._Process est gelee
#    par !IsBusy), on prend le relais : on ecrit nous-memes
#    user://backups/backup_<unixtime>.dungeondraft_map a la meme frequence que
#    DD (lue dans user://config.ini), et on purge au-dela de max_backups.
#    Le timer est amorce avec Master.AutoBackupTimer pour rester synchrone.
#
# Aucun flag statique n'est modifie.
# ─────────────────────────────────────────────────────────────────────────────

var _g

# Au-dela de ce temps en etat "busy" (hors export/dialogue), DD est considere
# bloque et on prend la main sur la sauvegarde.
const STUCK_SECONDS = 12.0
# Spinner tournant depuis plus longtemps que ca -> on l'arrete.
const SPINNER_HIDE_SECONDS = 10.0
# Sentinelle hors de portee du switch natif (cases 0..9) pour l'item Save As.
const SAVE_AS_SENTINEL = 90071
# Rafraichissement du cache des preferences (secondes).
const PREFS_REFRESH = 30.0
# Duree d'affichage de l'indicateur "BACKING_UP" avant l'ecriture (secondes),
# pour qu'il soit visible comme en natif.
const BACKUP_SHOW_SECONDS = 0.8

var _master = null
var _listener = null

var _busy_since := -1.0
var _hooked := false
var _stuck_handled := false

# Caches d'accrochage (pour restauration propre).
var _save_btn = null
var _save_btn_native_target = null
var _popup = null
var _save_as_index := -1
var _save_as_orig_id := -1

# Spinner.
var _infobar = null
var _spin_since := -1.0
var _spin_cleared := false

# Backups de secours.
var _backup_accum := -1.0      # < 0 = inactif (DD non bloque)
var _backup_prev_now := -1.0
var _prefs := {"auto": true, "freq": 10, "limit": 50}
var _prefs_at := -1.0

# Backup differe (pour afficher l'indicateur natif avant l'ecriture).
var _pending_backup := false
var _pending_at := -1.0
var _pending_limit := 50

var _file_dialog = null
var _tick_accum := 0.0


func initialize():
	_install_listener()
	_refresh_prefs()
	print("[SaveBypass] Initialized (watchdog only, no hooks yet)")


# ── Localisation Master / Infobar ─────────────────────────────────────────────

func _get_root():
	if _g.Editor and _g.Editor.get_tree():
		return _g.Editor.get_tree().root
	if _g.World and _g.World.get_tree():
		return _g.World.get_tree().root
	return null


func _find_master():
	if _master != null and is_instance_valid(_master):
		return _master
	var root = _get_root()
	if root == null:
		return null
	var direct = root.get_node_or_null("Master")
	if direct != null and direct.has_method("QueueBackup"):
		_master = direct
		return _master
	var stack = [root]
	while not stack.empty():
		var n = stack.pop_back()
		if n.has_method("QueueBackup"):
			_master = n
			return _master
		for c in n.get_children():
			stack.push_back(c)
	return null


func _find_infobar():
	if _infobar != null and is_instance_valid(_infobar):
		return _infobar
	if _g.Editor:
		var ib = _g.Editor.get("Infobar")
		if ib != null and is_instance_valid(ib) and ib.has_method("OnSaveEnd"):
			_infobar = ib
			return _infobar
	var root = _get_root()
	if root != null:
		var bypath = root.get_node_or_null("Master/Editor/VPartition/Infobar")
		if bypath != null and bypath.has_method("OnSaveEnd"):
			_infobar = bypath
			return _infobar
	return null


func _flag(name):
	var m = _find_master()
	if m == null:
		return null
	return m.get(name)


func _is_busy():
	return _flag("IsBusy") == true


func _current_file():
	if not _g.Editor:
		return ""
	var cur = _g.Editor.get("CurrentMapFile")
	if cur is String:
		return cur
	return ""


func _now_sec():
	return OS.get_ticks_msec() / 1000.0


# ── Watchdog ──────────────────────────────────────────────────────────────────

func _install_listener():
	_listener = Node.new()
	_listener.name = "SaveBypassListener"
	var s = GDScript.new()
	s.source_code = "extends Node\nvar handler = null\nfunc _process(delta):\n\tif handler != null:\n\t\thandler._on_tick(delta)\n"
	s.reload()
	_listener.set_script(s)
	_listener.handler = self
	if _g.World and _g.World is Node:
		_g.World.call_deferred("add_child", _listener)
	elif _g.Editor and _g.Editor is Node:
		_g.Editor.call_deferred("add_child", _listener)


func _on_tick(delta):
	_tick_accum += delta
	if _tick_accum < 0.25:
		return
	_tick_accum = 0.0

	var busy = _flag("IsBusy")
	if busy == null:
		return  # Master pas encore pret.

	var saving = _flag("IsSaving") == true
	var backing = _flag("IsBackingUp") == true
	var exporting = _flag("IsExporting") == true
	var dialog = _flag("IsSaveDialogOpen") == true
	var editing = _flag("IsEditing") == true
	var unbacked = _flag("HasUnbackedUpChanges") == true
	var now = _now_sec()

	# Duree de l'etat busy.
	if busy == true:
		if _busy_since < 0.0:
			_busy_since = now
	else:
		_busy_since = -1.0
	var held = (now - _busy_since) if (_busy_since >= 0.0) else -1.0
	var stuck = (busy == true) and held > STUCK_SECONDS and not exporting and not dialog

	# (1) Hooks de sauvegarde.
	if stuck and not _hooked:
		_install_hooks()
	elif _hooked and busy == false:
		_restore_hooks()

	# (1b) Autosave immediat a la detection du blocage : la save en cours ne se
	# terminera jamais, on en fait donc une tout de suite (one-shot).
	if stuck and not _stuck_handled:
		_stuck_handled = true
		var p0 = _get_prefs()
		print("[SaveBypass] Blocage detecte -> autosave immediat.")
		_begin_auto_backup(p0["limit"], now)
		_backup_accum = 0.0
		_backup_prev_now = now
	elif not stuck:
		_stuck_handled = false

	# (2) Spinner bloque.
	_tick_spinner(saving or backing, now)

	# (3) Backups de secours (uniquement quand DD est bloque).
	_tick_backup(stuck, editing, unbacked, now)
	_tick_pending_backup(now)


# ── (2) Spinner ───────────────────────────────────────────────────────────────

func _tick_spinner(spinning: bool, now: float):
	if spinning:
		if _spin_since < 0.0:
			_spin_since = now
		if not _spin_cleared and (now - _spin_since) > SPINNER_HIDE_SECONDS:
			_clear_spinner()
			_spin_cleared = true
	else:
		_spin_since = -1.0
		_spin_cleared = false


func _clear_spinner():
	var ib = _find_infobar()
	if ib != null:
		ib.call("OnSaveEnd")
		print("[SaveBypass] Spinner bloque -> Infobar.OnSaveEnd() appele.")


# ── (3) Backups de secours ────────────────────────────────────────────────────

func _refresh_prefs():
	var cf = ConfigFile.new()
	if cf.load("user://config.ini") == OK:
		_prefs["auto"] = bool(cf.get_value("Preferences", "automatic_backup", true))
		_prefs["freq"] = int(cf.get_value("Preferences", "backup_frequency", 10))
		_prefs["limit"] = int(cf.get_value("Preferences", "max_backups", 50))
	_prefs_at = _now_sec()


func _get_prefs():
	if _prefs_at < 0.0 or (_now_sec() - _prefs_at) > PREFS_REFRESH:
		_refresh_prefs()
	return _prefs


func _tick_backup(stuck: bool, editing: bool, unbacked: bool, now: float):
	if not stuck:
		_backup_accum = -1.0
		_backup_prev_now = -1.0
		return
	if _pending_backup:
		return
	var p = _get_prefs()
	if not p["auto"] or p["freq"] <= 0 or not editing:
		return
	# Amorcage a l'entree du blocage : on reprend le temps deja ecoule cote DD.
	if _backup_accum < 0.0:
		var dd_timer = _flag("AutoBackupTimer")
		_backup_accum = float(dd_timer) if (dd_timer != null) else 0.0
		_backup_prev_now = now
		return
	_backup_accum += (now - _backup_prev_now)
	_backup_prev_now = now
	if unbacked and _backup_accum >= float(p["freq"]) * 60.0:
		_begin_auto_backup(p["limit"], now)
		_backup_accum = 0.0


func _begin_auto_backup(limit: int, now: float):
	# Affiche l'indicateur natif "BACKING_UP" ; l'ecriture suit apres un court
	# delai (voir _tick_pending_backup) pour qu'il soit visible.
	_pending_backup = true
	_pending_at = now
	_pending_limit = limit
	var ib = _find_infobar()
	if ib != null:
		ib.call("OnBackupBegin")


func _tick_pending_backup(now: float):
	if not _pending_backup:
		return
	if (now - _pending_at) < BACKUP_SHOW_SECONDS:
		return
	_write_auto_backup(_pending_limit)
	var ib = _find_infobar()
	if ib != null:
		ib.call("OnSaveEnd")
	_pending_backup = false


func _write_auto_backup(limit: int):
	var res = _serialize_map()
	if not res[0]:
		print("[SaveBypass] Backup secours: serialisation impossible (" + str(res[2]) + ")")
		return
	var d = Directory.new()
	d.make_dir_recursive("user://backups")
	var path = "user://backups/backup_" + str(OS.get_unix_time()) + ".dungeondraft_map"
	var f = File.new()
	if f.open(path, File.WRITE) != OK:
		print("[SaveBypass] Backup secours: ouverture impossible.")
		return
	f.store_line(JSON.print(res[1], "\t"))
	f.close()
	print("[SaveBypass] Backup de secours ecrit : " + path)
	_clean_backups(limit)


func _clean_backups(limit: int):
	# Purge ciblee sur nos backups auto (backup_*.dungeondraft_map), tries par
	# nom (le unixtime croissant = ordre chronologique).
	var dir_path = "user://backups/"
	var d = Directory.new()
	if d.open(dir_path) != OK:
		return
	var files := []
	d.list_dir_begin(true, true)
	var fn = d.get_next()
	while fn != "":
		if not d.current_is_dir() and fn.begins_with("backup_") and fn.ends_with(".dungeondraft_map"):
			files.append(fn)
		fn = d.get_next()
	d.list_dir_end()
	if limit < 0:
		limit = 0
	if files.size() > limit:
		files.sort()
		var excess = files.size() - limit
		for i in range(excess):
			d.remove(dir_path + files[i])


# ── (1) Accrochage / restauration ─────────────────────────────────────────────

func _install_hooks():
	var ok_btn = _hook_save_button()
	var ok_menu = _hook_menu()
	if ok_btn or ok_menu:
		_hooked = true
		print("[SaveBypass] Editeur bloque -> hooks save installes (btn=%s menu=%s)." % [str(ok_btn), str(ok_menu)])


func _hook_save_button() -> bool:
	if not _g.Editor:
		return false
	var btn = _g.Editor.get("saveButton")
	if btn == null or not (btn is BaseButton):
		return false
	_save_btn = btn
	_save_btn_native_target = null
	for c in btn.get_signal_connection_list("pressed"):
		if str(c.get("method", "")) == "_on_SaveButton_pressed":
			_save_btn_native_target = c.get("target")
			if _save_btn_native_target != null:
				btn.disconnect("pressed", _save_btn_native_target, "_on_SaveButton_pressed")
	if not btn.is_connected("pressed", self, "_on_save_pressed"):
		btn.connect("pressed", self, "_on_save_pressed")
	return true


func _hook_menu() -> bool:
	var root = _get_root()
	if root == null:
		return false
	var menu_btn = root.get_node_or_null("Master/Editor/VPartition/MenuBar/MenuAlign/MenuButton")
	if menu_btn == null or not (menu_btn is MenuButton):
		return false
	var popup = menu_btn.get_popup()
	if popup == null or popup.get_item_count() == 0:
		return false
	_popup = popup
	_save_as_index = -1
	for i in range(popup.get_item_count()):
		var t = str(popup.get_item_text(i))
		if t == "Save As" or t == "Save As..." or t == "SAVE_AS" or ("Save As" in t):
			_save_as_index = i
			_save_as_orig_id = popup.get_item_id(i)
			popup.set_item_id(i, SAVE_AS_SENTINEL)
			break
	if _save_as_index < 0:
		return false
	if not popup.is_connected("id_pressed", self, "_on_menu_id"):
		popup.connect("id_pressed", self, "_on_menu_id")
	return true


func _restore_hooks():
	if _save_btn != null and is_instance_valid(_save_btn):
		if _save_btn.is_connected("pressed", self, "_on_save_pressed"):
			_save_btn.disconnect("pressed", self, "_on_save_pressed")
		if _save_btn_native_target != null and is_instance_valid(_save_btn_native_target):
			if not _save_btn.is_connected("pressed", _save_btn_native_target, "_on_SaveButton_pressed"):
				_save_btn.connect("pressed", _save_btn_native_target, "_on_SaveButton_pressed")
	if _popup != null and is_instance_valid(_popup):
		if _save_as_index >= 0 and _save_as_orig_id >= 0:
			_popup.set_item_id(_save_as_index, _save_as_orig_id)
		if _popup.is_connected("id_pressed", self, "_on_menu_id"):
			_popup.disconnect("id_pressed", self, "_on_menu_id")
	_hooked = false
	_save_btn = null
	_save_btn_native_target = null
	_popup = null
	_save_as_index = -1
	_save_as_orig_id = -1
	print("[SaveBypass] DD debloque -> hooks restaures (natif).")


# ── Declencheurs (actifs uniquement en mode bloque) ───────────────────────────

func _on_save_pressed():
	var cur = _current_file()
	if cur == "":
		_do_save_as()
		return
	if _is_busy():
		print("[SaveBypass] Busy -> ecriture sur le fichier courant.")
		_emergency_write(cur)
	else:
		_g.Editor.call("SaveMap", false, null)


func _on_menu_id(id):
	if id == SAVE_AS_SENTINEL:
		_do_save_as()


func _do_save_as():
	if not _is_busy():
		_g.Editor.call("SaveMap", true, null)
		return
	var dir = _save_dir()
	var os_name = OS.get_name()
	if os_name == "X11":
		var output = []
		OS.execute("zenity", ["--file-selection", "--modal", "--title", "Save Map", "--save", "--confirm-overwrite", "--file-filter", "*.dungeondraft_map"], true, output)
		if output.size() > 0:
			var p = str(output[0]).strip_edges()
			if p != "":
				_emergency_write(p)
		return
	if OS.has_method("ShowSaveDialog"):
		var path = OS.ShowSaveDialog("Save Map", _map_filter(), dir)
		if path is String and path != "":
			_emergency_write(path)
		return
	_open_save_dialog()


func _map_filter() -> String:
	if OS.get_name() == "OSX":
		return "dungeondraft_map"
	return "Map (*.dungeondraft_map),*.dungeondraft_map"


func _save_dir() -> String:
	var cur = _current_file()
	if cur != "":
		return cur.get_base_dir()
	return OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)


# ── Ecriture independante ─────────────────────────────────────────────────────

func _serialize_map():
	var data = {}
	if not _g.Header or not _g.Header.has_method("Save"):
		return [false, {}, "Header.Save() indisponible."]
	var header = _g.Header.call("Save")
	if not (header is Dictionary):
		return [false, {}, "Header.Save() invalide."]
	data["header"] = header
	if not _g.World or not _g.World.has_method("Save"):
		return [false, {}, "World.Save() indisponible."]
	var world = _g.World.call("Save")
	if not (world is Dictionary):
		return [false, {}, "World.Save() invalide."]
	data["world"] = world
	var mod_data = _g.ModMapData if ("ModMapData" in _g) else null
	data["mod"] = mod_data if (mod_data is Dictionary) else {}
	return [true, data, ""]


func _atomic_write(path: String, data: Dictionary) -> Array:
	if path.get_extension() != "dungeondraft_map":
		path = path.get_basename() + ".dungeondraft_map"
	var filename = path.get_file()
	var backup_path = OS.get_user_data_dir() + "/backups/" + filename
	var tmp_path = path.get_basename() + ".temporary"

	var file = File.new()
	var err = file.open(tmp_path, File.WRITE)
	if err != OK:
		return [false, "Ouverture temp impossible (err %d)" % err, path]
	file.store_line(JSON.print(data, "\t"))
	file.close()

	var d = Directory.new()
	if d.file_exists(path):
		if d.file_exists(backup_path):
			d.remove(backup_path)
		d.rename(path, backup_path)
	if d.rename(tmp_path, path) != OK:
		return [false, "Bascule du fichier final impossible.", path]
	return [true, "", path]


func _emergency_write(target_path: String):
	var res = _serialize_map()
	if not res[0]:
		print("[SaveBypass] ECHEC serialisation : " + str(res[2]))
		_warn("Echec sauvegarde", "Serialisation impossible :\n" + str(res[2]))
		return
	var w = _atomic_write(target_path, res[1])
	if not w[0]:
		print("[SaveBypass] ECHEC ecriture : " + str(w[1]))
		_warn("Echec sauvegarde", str(w[1]))
		return
	var final_path = w[2]
	print("[SaveBypass] Map sauvegardee : " + final_path)
	if _g.Editor and _g.Editor.has_method("OnOpenedOrSaved"):
		_g.Editor.call("OnOpenedOrSaved", final_path)
	# Feedback visuel + arret d'un eventuel spinner bloque.
	_clear_spinner()


func _warn(title, msg):
	if _g.Editor and _g.Editor.has_method("Warn"):
		_g.Editor.call("Warn", title, msg)


# ── Fallback Godot (rarement utilise) ─────────────────────────────────────────

func _open_save_dialog():
	if _file_dialog == null or not is_instance_valid(_file_dialog):
		_file_dialog = FileDialog.new()
		_file_dialog.name = "SaveBypassFileDialog"
		_file_dialog.mode = FileDialog.MODE_SAVE_FILE
		_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_file_dialog.add_filter("*.dungeondraft_map ; Dungeondraft Map")
		_file_dialog.connect("file_selected", self, "_on_save_as_selected")
		var parent = _g.Editor if (_g.Editor and _g.Editor is Node) else _g.World
		if parent and parent is Node:
			parent.add_child(_file_dialog)
	var cur = _current_file()
	if cur != "":
		_file_dialog.current_dir = cur.get_base_dir()
		_file_dialog.current_path = cur
	_file_dialog.popup_centered_ratio(0.6)


func _on_save_as_selected(path: String):
	if path != "":
		_emergency_write(path)
