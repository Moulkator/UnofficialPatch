# free_transform_data_manager.gd
# Gère la persistence des données Free Transform (skew / distort / perspective)
# entre les save/load et les clones de level.
#
# Lit/écrit dans :
#   _g.ModMapData["_ft_transforms"] — cisaillement skew  { "node-id-N": {xx,xy,yx,yy,ox,oy} }
#   _g.ModMapData["_ft_distort"]   — coins distort/persp { "node-id-N": [v2,v2,v2,v2] }
#
# Clé stable : "node-id-" + node.get_meta("node_id")
# Récupération : _g.World.HasNodeID(id) + _g.World.GetNodeByID(id)

var _g

var _applied        := false
var _store_levels   := []
var _clone_btn      : Node = null

# Copy/paste
var _copied_ft          := {"objects": [], "paths": [], "patterns": []}
var _prev_next_id       := -1
var _select_tool        = null
var _ctrl_c_was_pressed := false
var _last_clipboard     := ""    # détecte le Copy bouton via changement du clipboard
var _last_invalid_detected := false  # débounce la détection de refs disposées dans Selected


func initialize() -> void:
	print("[FT DataManager] Initialisé")
	# Utiliser un timer attaché à l'Editor (pas au World) pour survivre
	# aux changements de map. create_timer via le World est dangereux
	# car le World est détruit et recréé à chaque open.
	var tree = _g.World.get_tree()
	var timer1 = Timer.new()
	timer1.one_shot = true
	timer1.autostart = false
	timer1.wait_time = 2.0
	timer1.connect("timeout", self, "_connect_new_level_window")
	timer1.connect("timeout", timer1, "queue_free")
	_g.Editor.add_child(timer1)
	timer1.start()

	var timer2 = Timer.new()
	timer2.one_shot = true
	timer2.autostart = false
	timer2.wait_time = 2.5
	timer2.connect("timeout", self, "_get_select_tool")
	timer2.connect("timeout", timer2, "queue_free")
	_g.Editor.add_child(timer2)
	timer2.start()


func _get_select_tool() -> void:
	if _g.Editor and _g.Editor.get("Tools"):
		_select_tool = _g.Editor.Tools.get("SelectTool")
		print("[FT DataManager] SelectTool récupéré")


var _last_world_ref = null  # pour détecter un changement de World


func update(delta: float) -> void:
	# Garde : World doit être valide
	if _g.World == null or not is_instance_valid(_g.World):
		return

	# SAFETY PROACTIF : DD laisse parfois traîner des Props disposés dans les
	# collections internes du SelectTool après un undo. Si on touche Selected
	# avec une de ces refs (node.has_meta, node.position, etc.), GDScript crashe
	# avec ObjectDisposedException ; et DD lui-même crashe sur le prochain
	# SelectTool.Copy() pour la même raison. On force DeselectAllEx pour vider
	# l'état interne C# de DD dès qu'on détecte un ref invalide.
	#
	# Note : DeselectAllEx ne vide pas forcément la collection Selected telle
	# que GDScript la voit (l'état sale persiste tant que l'utilisateur ne
	# reclique pas). On débouncer via _last_invalid_detected pour n'agir
	# qu'une fois par épisode, sinon on spamme à chaque frame.
	var _has_invalid := false
	if _select_tool != null and is_instance_valid(_select_tool):
		var _sel = _select_tool.get("Selected")
		if _sel != null and _sel.size() > 0:
			for _nd in _sel:
				if _nd == null or not is_instance_valid(_nd):
					_has_invalid = true
					break
	if _has_invalid and not _last_invalid_detected:
		print("[FT DataManager] Refs disposées dans Selected → DeselectAllEx")
		if _select_tool.has_method("DeselectAllEx"):
			_select_tool.DeselectAllEx()
	_last_invalid_detected = _has_invalid

	# Détecte un changement de World (map rechargée)
	if _g.World != _last_world_ref:
		if _last_world_ref != null:
			print("[FT DataManager] World changé, reset _applied")
		_last_world_ref = _g.World
		_applied = false
		_prev_next_id = -1

	# Restaure le skew dès que le World est prêt
	if not _applied:
		if _g.World == null or not is_instance_valid(_g.World): return
		if not _g.ModMapData is Dictionary: return
		if not _g.World.has_method("HasNodeID"): return
		_applied = true
		_restore_shear()
		_prev_next_id = _g.World.nextNodeID
		return

	# Détecte une copie (Ctrl+C ou bouton Copy) via le changement de clipboard
	# OU via la combinaison de touches Ctrl+C (couvre le cas où le clipboard
	# ne change pas, ex: même pattern copié après un reopen).
	# Le clipboard DD a une signature JSON reconnaissable : on filtre là-dessus
	# pour ignorer les copies extérieures (logs, navigateur, etc.). Pour la
	# branche Ctrl+C, le polling d'Input ne se met à jour que quand DD a le
	# focus clavier, donc elle est déjà implicitement restreinte à DD.
	#
	# On ne poll le clipboard que si DD a le focus fenêtre ET SelectTool actif :
	# évite la contention Windows ("Unable to open clipboard") quand le user
	# copie depuis une autre app pendant que DD tourne en tâche de fond.
	var ctrl_c_now = Input.is_key_pressed(KEY_CONTROL) and Input.is_key_pressed(KEY_C)
	var should_poll_clipboard = OS.is_window_focused() \
			and _g.Editor.get("ActiveToolName") == "SelectTool"

	if should_poll_clipboard:
		var clip = OS.get_clipboard()
		var clip_is_dd = clip.find("dungeondraft_clipboard") >= 0
		if clip != _last_clipboard:
			_last_clipboard = clip
			if clip_is_dd:
				if not _ctrl_c_was_pressed:
					print("[FT DataManager] Bouton Copy détecté")
				_store_copy_ft_data()
		elif ctrl_c_now and not _ctrl_c_was_pressed:
			# Ctrl+C appuyé mais clipboard identique → stocke quand même les données FT
			print("[FT DataManager] Ctrl+C détecté (clipboard inchangé)")
			_store_copy_ft_data()

	_ctrl_c_was_pressed = ctrl_c_now

	# Détecte un paste : nextNodeID a augmenté pendant que SelectTool est actif.
	# Ça couvre Ctrl+V ET le bouton Paste de l'UI.
	# Exclut les faux positifs (ex: dessiner un pattern dans PatternShapeTool)
	# car la création de nodes hors SelectTool ne déclenche pas ce bloc.
	var is_select_active = _g.Editor.get("ActiveToolName") == "SelectTool"
	if is_select_active and _select_tool != null and is_instance_valid(_select_tool):
		var has_pastable = _select_tool.get("HasPastable")
		var cur_id = _g.World.nextNodeID
		if has_pastable and _prev_next_id >= 0 and cur_id > _prev_next_id:
			print("[FT DataManager] Paste détecté : IDs ", _prev_next_id, " → ", cur_id)
			_apply_ft_to_pasted_nodes(_prev_next_id, cur_id)
	_prev_next_id = _g.World.nextNodeID


# ══ Restore après save/load ════════════════════════════════════════════════

func _restore_shear() -> void:
	if not _g.ModMapData.has("_ft_transforms"): return
	var store = _g.ModMapData["_ft_transforms"]
	if not store is Dictionary: return
	var dead = []
	for key in store.keys():
		if not key is String or not key.begins_with("node-id-"):
			dead.append(key); continue
		var nd = _node_from_key(key)
		if nd == null:
			dead.append(key); continue
		var d = store[key]
		if not d is Dictionary: dead.append(key); continue
		nd.transform = Transform2D(
			Vector2(d.xx, d.xy),
			Vector2(d.yx, d.yy),
			nd.position)
	for key in dead:
		store.erase(key)
	print("[FT DataManager] Restauration skew terminée")



# ══ Copy / Paste ═══════════════════════════════════════════════════════════

func _store_copy_ft_data() -> void:
	if _select_tool == null:
		print("[FT DataManager] _store_copy_ft_data: select_tool null"); return
	var selected = _select_tool.get("Selected")
	if selected == null or selected.size() == 0:
		print("[FT DataManager] _store_copy_ft_data: rien de sélectionné"); return

	_copied_ft = {"objects": [], "paths": [], "patterns": []}
	var count = {"objects": 0, "paths": 0, "patterns": 0}
	var found = 0

	for node in selected:
		# SAFETY : ignore les refs disposées (DD peut en laisser traîner dans
		# Selected après un undo). Accéder à has_meta/position sur un Prop
		# disposé crashe avec ObjectDisposedException.
		if node == null or not is_instance_valid(node): continue
		if not node.has_meta("node_id"):
			print("[FT DataManager] node sans node_id: ", node); continue
		var node_id = node.get_meta("node_id")
		var key = "node-id-" + str(node_id)
		var type = _get_node_type(node)
		if not count.has(type): continue

		var data = {"index": count[type]}
		# Stocke la position du node source pour ajuster au paste
		if node is Node2D:
			data["src_position"] = [node.position.x, node.position.y]
		if _g.ModMapData.has("_ft_transforms") and _g.ModMapData["_ft_transforms"].has(key):
			data["shear"] = _g.ModMapData["_ft_transforms"][key].duplicate()
		if _g.ModMapData.has("_ft_distort") and _g.ModMapData["_ft_distort"].has(key):
			data["distort"] = _g.ModMapData["_ft_distort"][key].duplicate()
		if _g.ModMapData.has("_ft_pattern_orig") and _g.ModMapData["_ft_pattern_orig"].has(key):
			data["pattern_orig"] = _g.ModMapData["_ft_pattern_orig"][key].duplicate()
		if _g.ModMapData.has("_ft_pattern_orig_pos") and _g.ModMapData["_ft_pattern_orig_pos"].has(key):
			data["pattern_orig_pos"] = _g.ModMapData["_ft_pattern_orig_pos"][key].duplicate()
		if _g.ModMapData.has("_ft_pattern_reset") and _g.ModMapData["_ft_pattern_reset"].has(key):
			data["pattern_reset"] = _g.ModMapData["_ft_pattern_reset"][key].duplicate()
		if _g.ModMapData.has("_ft_pattern_world") and _g.ModMapData["_ft_pattern_world"].has(key):
			data["pattern_world"] = _g.ModMapData["_ft_pattern_world"][key].duplicate()
		# Crop / Soft Crop (props simples uniquement). Points en espace local du
		# sprite → indépendants de la position, rien à décaler.
		if _g.ModMapData.has("_ft_crop") and _g.ModMapData["_ft_crop"].has(key):
			data["crop"] = _g.ModMapData["_ft_crop"][key].duplicate()
		if _g.ModMapData.has("_ft_crop_soft") and _g.ModMapData["_ft_crop_soft"].has(key):
			data["crop_soft"] = _g.ModMapData["_ft_crop_soft"][key]
		if _g.ModMapData.has("_ft_crop_feather") and _g.ModMapData["_ft_crop_feather"].has(key):
			data["crop_feather"] = _g.ModMapData["_ft_crop_feather"][key]

		if data.has("distort"):
			pass
		if data.has("shear") or data.has("distort") or data.has("pattern_orig") \
				or data.has("pattern_orig_pos") or data.has("pattern_reset") or data.has("pattern_world") \
				or data.has("crop"):
			_copied_ft[type].append(data)
			found += 1
		count[type] += 1

	print("[FT DataManager] Données FT copiées : ", found, " nodes, ft_transforms keys=", _g.ModMapData.get("_ft_transforms", {}).keys())


func _apply_ft_to_pasted_nodes_deferred() -> void:
	_apply_ft_to_pasted_nodes(-1, -1)


func _apply_ft_to_pasted_nodes(from_id: int, to_id: int, attempt: int = 0) -> void:
	if _copied_ft["objects"].empty() and _copied_ft["paths"].empty() and _copied_ft["patterns"].empty(): return

	# Retrouve les nouveaux nodes par type dans l'ordre de création
	var new_nodes = {"objects": [], "paths": [], "patterns": []}

	if from_id >= 0 and to_id > from_id:
		# Détection automatique via nextNodeID
		for nid in range(from_id, to_id):
			if not _g.World.HasNodeID(nid): continue
			var nd = _g.World.GetNodeByID(nid)
			if nd == null: continue
			var type = _get_node_type(nd)
			if new_nodes.has(type):
				new_nodes[type].append(nd)
	else:
		# Fallback : prend les nodes sélectionnés actuels
		if _select_tool == null: return
		var selected = _select_tool.get("Selected")
		if selected == null: return
		for nd in selected:
			if nd == null or not is_instance_valid(nd): continue
			var type = _get_node_type(nd)
			if new_nodes.has(type):
				new_nodes[type].append(nd)

	# Si des patterns étaient copiés mais aucun pattern trouvé dans les nouveaux nodes,
	# DD n'a peut-être pas encore initialisé GlobalPolygon. Réessayer après un court délai.
	if not _copied_ft["patterns"].empty() and new_nodes["patterns"].empty() and attempt < 5:
		print("[FT DataManager] Paste: 0 patterns trouvés — retry ", attempt + 1, "/5 dans 0.3s")
		var timer = Timer.new()
		timer.one_shot = true
		timer.autostart = false
		timer.wait_time = 0.3
		timer.connect("timeout", self, "_apply_ft_to_pasted_nodes", [from_id, to_id, attempt + 1])
		timer.connect("timeout", timer, "queue_free")
		_g.Editor.add_child(timer)
		timer.start()
		return


	# Applique les données FT aux nouveaux nodes par index
	for type in ["objects", "paths", "patterns"]:
		for data in _copied_ft[type]:
			var idx = data.get("index", -1)
			if idx < 0 or idx >= new_nodes[type].size(): continue
			var nd = new_nodes[type][idx]
			if not nd.has_meta("node_id"): continue
			var new_key = "node-id-" + str(nd.get_meta("node_id"))

			# Delta = difference de node.position entre source et destination.
			# Pour les patterns, DD copie les vertices à l'identique et change
			# node.position pour placer le pattern ailleurs. Le delta sert
			# uniquement pour les données en coords monde (pattern_world, shear origin).
			# Les données en espace local (pattern_orig, distort, pattern_reset)
			# ne changent PAS car les vertices sont les mêmes.
			var src_pos = Vector2.ZERO
			if data.has("src_position"):
				src_pos = Vector2(data["src_position"][0], data["src_position"][1])
			var dst_pos = nd.position if nd is Node2D else Vector2.ZERO
			var pos_delta = dst_pos - src_pos
			if nd is Polygon2D and nd.polygon.size() > 0:
				var _pp = nd.polygon

			if data.has("shear"):
				if not _g.ModMapData.has("_ft_transforms"):
					_g.ModMapData["_ft_transforms"] = {}
				var shear = data["shear"].duplicate()
				shear.ox = shear.ox + pos_delta.x
				shear.oy = shear.oy + pos_delta.y
				_g.ModMapData["_ft_transforms"][new_key] = shear
			if data.has("distort"):
				if not _g.ModMapData.has("_ft_distort"):
					_g.ModMapData["_ft_distort"] = {}
				# Coins distort = en espace local (wc - node.position) → pas de shift
				_g.ModMapData["_ft_distort"][new_key] = data["distort"].duplicate()
			if data.has("pattern_orig"):
				if not _g.ModMapData.has("_ft_pattern_orig"):
					_g.ModMapData["_ft_pattern_orig"] = {}
				# Polygon original en espace local → pas de shift
				_g.ModMapData["_ft_pattern_orig"][new_key] = data["pattern_orig"].duplicate()
			# NE PAS stocker pattern_orig_pos ici — DD n'a pas encore finalisé
			# la position du node collé. _store_orig_polygon le créera avec la
			# bonne node.position au moment de l'installation du shader.
			if data.has("pattern_reset"):
				if not _g.ModMapData.has("_ft_pattern_reset"):
					_g.ModMapData["_ft_pattern_reset"] = {}
				# Polygon reset en espace local → pas de shift
				_g.ModMapData["_ft_pattern_reset"][new_key] = data["pattern_reset"].duplicate()
			if data.has("crop"):
				# Points en espace local du sprite → pas de décalage. free_transform
				# (_restore_crop_from_store) re-cuira la texture du node collé.
				if not _g.ModMapData.has("_ft_crop"):
					_g.ModMapData["_ft_crop"] = {}
				_g.ModMapData["_ft_crop"][new_key] = data["crop"].duplicate()
				if data.has("crop_soft"):
					if not _g.ModMapData.has("_ft_crop_soft"):
						_g.ModMapData["_ft_crop_soft"] = {}
					_g.ModMapData["_ft_crop_soft"][new_key] = data["crop_soft"]
				if data.has("crop_feather"):
					if not _g.ModMapData.has("_ft_crop_feather"):
						_g.ModMapData["_ft_crop_feather"] = {}
					_g.ModMapData["_ft_crop_feather"][new_key] = data["crop_feather"]
			# NE PAS stocker pattern_world ici — _restore_distort_from_store
			# le recalcule depuis distort + node.position actuel.

	print("[FT DataManager] Données FT appliquées au paste")
	# Signale à free_transform.gd de sauvegarder les données JSON
	_g.ModMapData["_ft_needs_save"] = true



# ══ Clone de level ═════════════════════════════════════════════════════════

func _connect_new_level_window() -> void:
	if not _g.Editor or not _g.Editor.get("Windows"): return
	var win = _g.Editor.Windows.get("NewLevel")
	if win == null:
		print("[FT DataManager] Fenêtre NewLevel introuvable"); return
	if not win.is_connected("about_to_show", self, "_on_new_level_window_opened"):
		win.connect("about_to_show", self, "_on_new_level_window_opened")
	var valign = win.get_node_or_null("Margins/VAlign")
	if valign == null: return
	var ok_btn   = valign.get_node_or_null("Buttons/OkayButton")
	var clone_opt = valign.get_node_or_null("CloneLevel/CloneLevelOptionButton")
	if ok_btn and not ok_btn.is_connected("pressed", self, "_on_new_level_ok_pressed"):
		ok_btn.connect("pressed", self, "_on_new_level_ok_pressed")
	if clone_opt:
		_clone_btn = clone_opt
	print("[FT DataManager] Connexion fenêtre NewLevel OK")


func _on_new_level_window_opened() -> void:
	if _g.World == null or not is_instance_valid(_g.World): return
	_store_levels = _g.World.levels.duplicate(false)


func _on_new_level_ok_pressed() -> void:
	if _clone_btn == null or not is_instance_valid(_clone_btn) or _clone_btn.selected <= 0: return
	if _g.World == null or not is_instance_valid(_g.World): return
	var source_idx = _clone_btn.selected
	var timer = Timer.new()
	timer.one_shot = true
	timer.autostart = false
	timer.wait_time = 1.5
	timer.connect("timeout", self, "_copy_ft_data_to_new_level", [source_idx])
	timer.connect("timeout", timer, "queue_free")
	_g.Editor.add_child(timer)
	timer.start()


func _find_new_level():
	for level in _g.World.levels:
		if not level in _store_levels:
			return level
	return null


func _copy_ft_data_to_new_level(source_level_index: int) -> void:
	var source_level = _g.World.TryGetLevel(source_level_index)
	if source_level == null: return
	var new_level = _find_new_level()
	if new_level == null:
		print("[FT DataManager] Clone : nouveau level introuvable"); return

	var count = 0

	# Tous les stores FT à copier lors d'un clone de level (clés "node-id-*" uniquement)
	# Note : _portal_offsets utilise un format de clé différent (wallID_idx_dist)
	# et les portals clonés ont de nouveaux WallIDs, donc pas besoin de le copier ici.
	var store_keys = [
		"_ft_transforms", "_ft_distort",
		"_ft_pattern_orig", "_ft_pattern_orig_pos", "_ft_pattern_reset", "_ft_pattern_world",
		"_ft_crop", "_ft_crop_soft", "_ft_crop_feather",
	]

	for store_name in store_keys:
		if not _g.ModMapData.has(store_name): continue
		var store = _g.ModMapData[store_name].duplicate(true)
		for key in store.keys():
			if not key is String or not key.begins_with("node-id-"): continue
			var node_id = int(key.substr(8))
			if not _g.World.HasNodeID(node_id): continue
			var src = _g.World.GetNodeByID(node_id)
			if src == null: continue
			if not _is_node_on_level(src, source_level): continue
			var cloned = _get_cloned_node(src, new_level)
			if cloned == null or not cloned.has_meta("node_id"): continue
			var new_key = "node-id-" + str(cloned.get_meta("node_id"))
			var val = store[key]
			# _ft_crop_soft (bool) / _ft_crop_feather (float) n'ont pas de
			# méthode duplicate() : on les copie tels quels (types valeur).
			if val is Dictionary or val is Array:
				_g.ModMapData[store_name][new_key] = val.duplicate()
			else:
				_g.ModMapData[store_name][new_key] = val
			count += 1

	print("[FT DataManager] Clone : ", count, " transforms copiés vers ", new_level.Label)
	# Signale à free_transform.gd de sauvegarder les données JSON
	if count > 0:
		_g.ModMapData["_ft_needs_save"] = true


# ══ Utilitaires ════════════════════════════════════════════════════════════

func _get_node_type(node: Node) -> String:
	if node.get("WallID") != null: return "portals"
	if node.get("Sprite") != null: return "objects"
	if node.get("FadeIn") != null: return "paths"
	if node is Polygon2D and node.get("GlobalPolygon") != null: return "patterns"
	return ""


func _node_from_key(key: String) -> Node2D:
	if not key.begins_with("node-id-"): return null
	var node_id = int(key.substr(8))
	if not _g.World.HasNodeID(node_id): return null
	return _g.World.GetNodeByID(node_id) as Node2D


func _is_node_on_level(node: Node, level) -> bool:
	if node == null or not is_instance_valid(node): return false
	# Remonte l'arbre de nodes pour vérifier si le node est un descendant du Level.
	# Fonctionne pour tous les types (objects, patterns, portals, paths).
	var current = node
	while current != null:
		if current == level:
			return true
		current = current.get_parent()
	return false


func _get_cloned_node(src: Node, new_level) -> Node:
	var wall_id = src.get("WallID")
	var sprite  = src.get("Sprite")
	# Object
	if sprite != null and wall_id == null:
		if new_level.get("Objects"):
			var idx = src.get_index()
			if idx >= 0 and idx < new_level.Objects.get_child_count():
				return new_level.Objects.get_child(idx)
	# Path
	if src.get("FadeIn") != null:
		if new_level.get("Pathways"):
			var idx = src.get_index()
			if idx >= 0 and idx < new_level.Pathways.get_child_count():
				return new_level.Pathways.get_child(idx)
	# Pattern / Portal / anything else : chemin relatif depuis le level source
	# On remonte l'arbre du node jusqu'au level source pour construire le chemin,
	# puis on cherche le même chemin + child index dans le nouveau level.
	var src_level = _find_level_of(src)
	if src_level != null:
		var parent = src.get_parent()
		if parent != null and parent != src_level:
			var rel_path = src_level.get_path_to(parent)
			var new_parent = new_level.get_node_or_null(rel_path)
			if new_parent != null:
				var idx = src.get_index()
				if idx >= 0 and idx < new_parent.get_child_count():
					return new_parent.get_child(idx)
	return null


func _find_level_of(node: Node):
	# Remonte l'arbre jusqu'à trouver le Level (un node dans _g.World.levels)
	var current = node
	while current != null:
		for lvl in _g.World.levels:
			if current == lvl:
				return lvl
		current = current.get_parent()
	return null

