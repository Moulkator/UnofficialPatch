# edit_points_undo.gd
# Enregistre dans l'historique de DD les modifications faites en mode Edit
# Points sur un path, pour rendre Ctrl+Z utilisable.
#
# Vanilla DD : en mode Edit Points, bouger/ajouter/supprimer un point ne crée
# aucun record. Conséquence : Ctrl+Z saute directement au record précédent
# (qui est souvent la création du path → le path disparaît entièrement).
#
# Stratégie : on ne cherche PAS à identifier "le path en cours d'édition"
# (DD ne l'expose pas de façon fiable ; WorldUI.Vertices n'est peuplé que
# pendant un drag actif). À la place, on maintient un snapshot des points
# de TOUS les paths de la scène, et on détecte les changements via diff.
# Coût : scan de N paths × M points à chaque frame. Négligeable pour les
# tailles de carte typiques.
#
# Types d'action détectés :
#   - drag   : mêmes IDs de paths, un path a des positions différentes
#   - ajout  : un path a size++
#   - suppression : un path a size--
#
# Seulement pour les Pathway (PathTool). Les Wall et PatternShape ne sont
# pas traités ici.


var script_class = "tool"
var _g

# Références aux autres mods qui mutent les paths directement. Injectées
# par Main.gd. Si l'un d'eux est actif (state != IDLE/INACTIVE), on se
# tait pour éviter les double records.
var path_curve_edit = null
var arc_draw = null


# Snapshots de tous les paths de la scène. Clé = InstanceID du path (int
# retourné par get_instance_id), valeur = Array de Vector2 (GlobalEditPoints).
# Mis à jour à l'entrée en mode Edit Points, puis après chaque commit.
var _snapshots: Dictionary = {}

# Path actuellement en cours de modification (détecté parce qu'il diffère
# de son snapshot). Pendant une action, on le fixe à la première détection
# pour que les frames suivantes suivent le même path.
var _active_instance_id: int = -1
var _active_pathway_ref: WeakRef = null

# État pending pendant qu'une action se déroule.
var _pending_pts: Array = []

# `LastIndex` de l'historique DD au moment où on a détecté le début de
# l'action. Sert à savoir si un autre mod a déjà créé un record pour la
# même action (ex: path_curve_edit ou arc_draw mutent le path puis font
# un CreateCustomRecord de leur côté). Si LastIndex a bougé entre la
# détection du changement et le commit, on skip pour éviter le doublon.
var _history_index_at_start: int = -1

# État précédent du mode Edit Points.
var _was_edit_points_active: bool = false

# État précédent du "un autre mod était busy ?". Sert à détecter la
# transition busy → not busy, moment où l'autre mod vient de committer
# son propre record. À cette frame-là, on doit re-snapshoter proprement
# et surtout NE PAS créer de record pour le changement qui correspond
# justement à l'action de l'autre mod.
var _was_other_mod_busy: bool = false

# Dernière valeur connue de Editor.History.LastIndex. Permet de détecter
# qu'un record vient d'être créé par un tiers (SplitPath, curve_edit,
# arc_draw, ou un autre mod/DD lui-même). À chaque fois que cet index
# augmente, un record externe a été poussé → on re-snapshote pour ne
# pas créer de doublon.
var _last_known_history_index: int = -1

# Cache du script de record.
var _PointsRecordScript = null


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func initialize():
	_snapshots = {}
	_active_instance_id = -1
	_active_pathway_ref = null
	_pending_pts = []
	_history_index_at_start = -1
	_was_edit_points_active = false
	_was_other_mod_busy = false
	_last_known_history_index = -1
	print("[EditPointsUndo] initialized")


# ── Update ────────────────────────────────────────────────────────────────────

func update(_delta):
	if _g == null:
		return
	var editor = _g.get("Editor")
	if editor == null:
		return
	
	# On ne travaille qu'en mode PathTool + Edit Points actif.
	if editor.ActiveToolName != "PathTool":
		_on_mode_exit()
		return
	
	var path_tool = editor.Tools["PathTool"]
	if path_tool == null:
		_on_mode_exit()
		return
	
	if not path_tool.get_EditPoints().pressed:
		_on_mode_exit()
		return
	
	# Si un autre mod est en train de modifier un path (curve preview ou
	# arc preview), on se tait. Ces mods créent leur propre record au
	# moment du commit, et nos snapshots ne doivent pas enregistrer les
	# états intermédiaires.
	var busy_now = _is_other_mod_busy()
	
	if busy_now:
		# Reset pending si on avait commencé quelque chose juste avant
		# que l'autre mod prenne la main. On ne touche PAS aux snapshots
		# pendant la preview : ils restent sur l'état d'AVANT la preview,
		# pour que quand l'autre mod finit et crée son record, notre
		# snapshot matche encore son état "before" et on ne détecte pas
		# de changement parasite.
		_reset_pending()
		_was_other_mod_busy = true
		return
	
	# Transition busy → not busy : l'autre mod vient de finir. Il a
	# probablement créé son propre record (celui qui nous intéresse) ou
	# a cancel. Dans les deux cas, on re-snapshote TOUS les paths sur
	# leur état actuel pour repartir proprement sans enregistrer ce
	# qu'il a fait (ce serait un doublon).
	if _was_other_mod_busy:
		_was_other_mod_busy = false
		_take_snapshots()
		return
	
	# Transition inactif → actif : prendre un snapshot initial de tous les
	# paths de la scène pour pouvoir détecter la première modif.
	if not _was_edit_points_active:
		_was_edit_points_active = true
		_take_snapshots()
		_last_known_history_index = _get_history_index()
		return
	
	# Un record a été créé dans DD depuis la dernière frame ? Si oui, c'est
	# qu'un autre mod/action a déjà enregistré quelque chose (SplitPath,
	# arc_draw à la transition précédente, etc.). On re-snapshote pour
	# matcher le nouvel état et on skip cette frame. Ça couvre SplitPath
	# qui fait son travail en une seule frame sans passer par la détection
	# "busy" (il n'a pas d'état persistant).
	var current_history_index = _get_history_index()
	if current_history_index > _last_known_history_index:
		_last_known_history_index = current_history_index
		_reset_pending()
		_take_snapshots()
		return
	_last_known_history_index = current_history_index
	
	# Trouve le path qui a changé par rapport à son snapshot. En pratique
	# il n'y a qu'un seul path modifiable à la fois en Edit Points (celui
	# sélectionné par l'utilisateur), donc au plus un path diffère.
	var changed = _find_changed_path()
	var mouse_down = Input.is_mouse_button_pressed(BUTTON_LEFT)
	
	if changed == null:
		# Aucun changement détecté cette frame.
		# Si on avait une action en cours :
		#   - si le bouton est relâché → l'action est finie, commit.
		#   - sinon → l'utilisateur est peut-être en pause au milieu d'un
		#     drag, on attend.
		# Cas DEL/Backspace (action instantanée, pas de bouton maintenu) :
		# détecté par mouse_down=false dès la frame suivante → commit OK.
		if _active_instance_id != -1 and _pending_pts.size() > 0:
			if not mouse_down:
				_commit_pending()
		return
	
	var pathway = changed["pathway"]
	var iid = changed["iid"]
	var current_pts = changed["pts"]
	
	# Première détection du changement : on capture le pathway, le pending
	# et l'index d'historique DD au moment du démarrage. L'index servira à
	# détecter si un autre mod a créé un record entre-temps, auquel cas
	# on skip notre commit (évite le double record).
	if _active_instance_id == -1:
		_active_instance_id = iid
		_active_pathway_ref = weakref(pathway)
		_pending_pts = current_pts
		_history_index_at_start = _get_history_index()
		return
	
	# Si un autre path change alors qu'on avait déjà commencé à en suivre
	# un, on commit le précédent et on bascule.
	if iid != _active_instance_id:
		_commit_pending()
		_active_instance_id = iid
		_active_pathway_ref = weakref(pathway)
		_pending_pts = current_pts
		_history_index_at_start = _get_history_index()
		return
	
	# Même path : on met à jour pending au dernier état vu. Commit différé
	# au relâchement du bouton souris (géré dans la branche changed==null).
	_pending_pts = current_pts
	
	# Cas particulier : bouton non pressé alors qu'un changement arrive
	# (DEL/Backspace appliqué, le path change sans drag). On peut commit
	# immédiatement puisque l'action est instantanée.
	if not mouse_down:
		_commit_pending()


# ── Snapshot management ───────────────────────────────────────────────────────

func _take_snapshots() -> void:
	_snapshots = {}
	var world = _g.get("World")
	if world == null:
		return
	var level = world.GetCurrentLevel()
	if level == null:
		return
	var pathways = level.Pathways
	if pathways == null:
		return
	for pw in pathways.get_children():
		if not is_instance_valid(pw):
			continue
		var ep = pw.get("GlobalEditPoints")
		if ep == null:
			continue
		_snapshots[pw.get_instance_id()] = _poolarray_to_array(ep)


func _find_changed_path():
	# Parcourt les paths de la scène et compare chacun à son snapshot.
	# Retourne {iid, pathway, pts} pour le premier qui diffère, ou null.
	# Les paths nouveaux (ex: issus d'un split) sont ajoutés au snapshot
	# silencieusement — on ne les compte pas comme un changement utilisateur.
	var world = _g.get("World")
	if world == null: return null
	var level = world.GetCurrentLevel()
	if level == null: return null
	var pathways = level.Pathways
	if pathways == null: return null
	
	var result = null
	for pw in pathways.get_children():
		if not is_instance_valid(pw):
			continue
		var ep = pw.get("GlobalEditPoints")
		if ep == null:
			continue
		var iid = pw.get_instance_id()
		var current = _poolarray_to_array(ep)
		if not _snapshots.has(iid):
			# Nouveau path apparu. On l'enregistre mais on ne le considère
			# pas comme un changement utilisateur.
			_snapshots[iid] = current
			continue
		var baseline = _snapshots[iid]
		if not _pts_equal(current, baseline):
			if result == null:
				result = {"iid": iid, "pathway": pw, "pts": current}
	return result


# ── Commit ────────────────────────────────────────────────────────────────────

func _commit_pending() -> void:
	if _active_instance_id == -1:
		return
	
	var pathway = null
	if _active_pathway_ref != null:
		pathway = _active_pathway_ref.get_ref()
	
	if pathway == null or not is_instance_valid(pathway):
		_reset_pending()
		return
	
	var before_pts = _snapshots.get(_active_instance_id, [])
	var after_pts = _pending_pts
	
	if before_pts.size() == 0 or after_pts.size() == 0:
		_reset_pending()
		return
	
	if _pts_equal(before_pts, after_pts):
		_reset_pending()
		return
	
	# Garde anti-doublon : si un autre mod a créé un record dans DD entre
	# le moment où on a détecté le début de l'action et maintenant, on
	# considère qu'il a pris le relais. Skip notre commit, mais mets
	# quand même à jour le snapshot pour ne pas re-détecter la même modif.
	var current_index = _get_history_index()
	if current_index != _history_index_at_start:
		_snapshots[_active_instance_id] = after_pts.duplicate()
		_reset_pending()
		return
	
	_load_record_script()
	if _PointsRecordScript == null:
		_reset_pending()
		return
	
	var history = _g.Editor.get("History")
	if history == null:
		_reset_pending()
		return
	
	var record = _PointsRecordScript.new()
	record.main_script = self
	record.node = pathway
	record.points_before = before_pts.duplicate()
	record.points_after = after_pts.duplicate()
	history.CreateCustomRecord(record)
	
	print("[EditPointsUndo] record : %d -> %d pts" \
		% [before_pts.size(), after_pts.size()])
	
	# Met à jour le snapshot pour ce path (nouveau baseline).
	_snapshots[_active_instance_id] = after_pts.duplicate()
	
	# Synchronise l'index suivi : notre propre CreateCustomRecord vient
	# d'augmenter LastIndex; sans cette ligne, la frame suivante verrait
	# ça comme "un record externe" et ferait un reset inutile.
	_last_known_history_index = _get_history_index()
	
	_reset_pending()


func _reset_pending() -> void:
	_active_instance_id = -1
	_active_pathway_ref = null
	_pending_pts = []
	_history_index_at_start = -1


func _get_history_index() -> int:
	var history = _g.Editor.get("History")
	if history == null:
		return -1
	if not history.has_method("get_LastIndex"):
		return -1
	return history.call("get_LastIndex")


func _is_other_mod_busy() -> bool:
	# path_curve_edit : State.IDLE = 0, tout autre valeur = preview actif.
	if path_curve_edit != null:
		var s = path_curve_edit.get("_state")
		if s != null and s != 0:
			return true
	# arc_draw : State.INACTIVE = 0, tout autre = preview d'arc actif.
	if arc_draw != null:
		var s = arc_draw.get("_state")
		if s != null and s != 0:
			return true
	return false


func _on_mode_exit() -> void:
	# Sortie du mode Edit Points : si une action était en cours, on la
	# commit maintenant (utilisateur a quitté pendant un drag).
	if _active_instance_id != -1 and _pending_pts.size() > 0:
		_commit_pending()
	_snapshots = {}
	_reset_pending()
	_was_edit_points_active = false
	_was_other_mod_busy = false
	_last_known_history_index = -1


# ── Record script loading ─────────────────────────────────────────────────────

func _load_record_script() -> void:
	if _PointsRecordScript != null:
		return
	_PointsRecordScript = ResourceLoader.load(
		_g.Root + "library/points_history_record.gd", "GDScript", true)
	if _PointsRecordScript == null:
		print("[EditPointsUndo] WARN: library/points_history_record.gd not found")


# Dispatcher attendu par points_history_record.undo/redo.
# On ne gère que les Pathway ici (pas Wall, pas PatternShape).
func _write_pts(node, pts: Array):
	if node == null or not is_instance_valid(node):
		return
	if node.get("GlobalEditPoints") == null:
		return
	var pool = PoolVector2Array()
	for p in pts:
		pool.append(p)
	node.call("SetEditPoints", pool)
	# Après SetEditPoints, on resynchronise le snapshot de ce path pour
	# éviter que le prochain scan ne voie ce changement comme une nouvelle
	# action utilisateur à enregistrer.
	var iid = node.get_instance_id()
	_snapshots[iid] = pts.duplicate()


# ── Utilities ─────────────────────────────────────────────────────────────────

func _poolarray_to_array(pool) -> Array:
	var out = []
	if pool == null:
		return out
	for v in pool:
		out.append(v)
	return out


func _pts_equal(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if a[i].distance_squared_to(b[i]) > 0.01:
			return false
	return true
