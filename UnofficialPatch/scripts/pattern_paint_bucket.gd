# pattern_paint_bucket.gd
# Paint Bucket pour le PatternShape Tool.
#
# Utilisation :
#   - Dans le PatternShapeTool, cliquer sur l'icône seau dans la barre des formes
#   - Clic gauche n'importe où dans la map → remplit la région contenant le clic.
#     Les bordures d'une région peuvent être un mix de : murs (fermés ou ouverts),
#     paths (fermés ou ouverts), et bords de la map. Les formes fermées internes
#     à la région deviennent des trous (multi-trous supporté).
#   - Shift+clic → inclut aussi les PatternShapes existants comme barrières
#   - Cliquer sur une autre forme (rect/circle/polygon) désactive le mode fill
#
# Implémentation :
#   Le calcul de la région (barrières → union → extraction du morceau cliqué)
#   est DÉLÉGUÉ à library/region_geometry.gd (moteur partagé avec le terrain
#   bucket), avec min_layer = calque-cible du tool (les barrières strictement
#   dessous seront recouvertes par le pattern) et keep_holes = true.
#   Ce fichier ne garde que : l'UI, le curseur, la création de la PatternShape
#   (décomposition en lobes + bridge-cut des trous — PatternShape ne supporte
#   pas les holes nativement).

var _g
var ui_util
var input_listener: Node
var _region_geo = null  # instance de library/region_geometry.gd (moteur partagé)
const _META_KEY = "PatternPaintBucketListener"

# Barre de progression + Annuler (opérations longues)
var _progress_script = null
var _filling := false
# Fill watchdog: if the fill coroutine dies from a runtime error, _filling
# would stay true forever — every canvas click would then be silently swallowed
# by _on_input (the tool looks completely dead) until the mods are reloaded.
# A Timer on the listener node (Timers keep running while modal windows freeze
# the mod update loop) re-arms the bucket after a long silence and force-closes
# any orphaned modal progress dialog.
const FILL_WATCHDOG_MS = 6000
var _fill_started := 0
var _active_progress = null

# UI
var _bucket_button: Button = null
var _bucket_active := false
var _shape_buttons: Array = []
var _shape_hbox = null
var _prev_mode := -1

# Options "Stopped by" (types de barrières qui bloquent le remplissage)
var _opts_hbox = null
var _cb_walls: CheckBox = null
var _cb_paths: CheckBox = null
var _cb_patterns: CheckBox = null

# Curseur
var _bucket_cursor_tex: Texture = null
var _cursor_applied := false

# Géométrie
# Au-delà de N sommets, on saute le test d'auto-intersection O(n²) et on offsette
# directement en bande unique (un path aussi dense est une courbe lisse).


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func initialize():
	_load_cursor_texture()
	# Moteur de géométrie partagé (même instance de code que le terrain bucket —
	# évite le drift entre copies qui a déjà causé des régions non détectées).
	var geo_script = ResourceLoader.load(_g.Root + "library/region_geometry.gd", "GDScript", true)
	if geo_script != null:
		_region_geo = geo_script.new()
		_region_geo._g = _g
	else:
		print("[PatternPaintBucket] WARNING: could not load library/region_geometry.gd; bucket fill disabled")
	_progress_script = ResourceLoader.load(_g.Root + "library/progress_dialog.gd", "GDScript", true)
	if _progress_script == null:
		print("[PatternPaintBucket] WARNING: library/progress_dialog.gd introuvable; pas de barre de progression")
	_inject_ui()
	_install_listener()
	print("[PatternPaintBucket] initialized")


func _new_progress(title: String):
	if _progress_script == null:
		return null
	var pg = _progress_script.new()
	pg._g = _g
	pg.start(title)
	return pg


func _load_cursor_texture():
	var path = _g.Root + "icons/bucket_cursor.png"
	var img = Image.new()
	if img.load(path) != OK:
		print("[PatternPaintBucket] bucket_cursor.png not found at ", path)
		return
	_bucket_cursor_tex = ImageTexture.new()
	_bucket_cursor_tex.create_from_image(img, 0)


func _load_icon_texture(filename: String) -> Texture:
	var path = _g.Root + "icons/" + filename
	var img = Image.new()
	if img.load(path) != OK:
		return null
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)
	return tex


# ── UI Injection ─────────────────────────────────────────────────────────────

func _inject_ui():
	var pat_tool = _g.Editor.Tools["PatternShapeTool"]
	if pat_tool == null:
		print("[PatternPaintBucket] PatternShapeTool not found")
		return

	var tool_panel = _g.Editor.Toolset.GetToolPanel("PatternShapeTool")
	if tool_panel == null:
		print("[PatternPaintBucket] PatternShapeTool panel not found")
		return

	var align = tool_panel.get("Align")
	if align == null:
		print("[PatternPaintBucket] Align not found")
		return

	# Chercher le HBoxContainer contenant les boutons de forme (toggle group)
	_shape_hbox = null
	for child in align.get_children():
		if child is HBoxContainer:
			var has_toggles = false
			for btn in child.get_children():
				if btn is Button and btn.toggle_mode:
					has_toggles = true
					break
			if has_toggles:
				_shape_hbox = child
				break

	if _shape_hbox == null:
		print("[PatternPaintBucket] Shape buttons HBox not found, inserting before EditPoints")
		var ep_btn = pat_tool.get("EditPoints")
		if ep_btn != null:
			_shape_hbox = ep_btn.get_parent()

	if _shape_hbox == null:
		print("[PatternPaintBucket] Cannot find a place to inject button")
		return

	_shape_buttons = []
	for child in _shape_hbox.get_children():
		if child is Button and child.toggle_mode:
			_shape_buttons.append(child)
			if not child.is_connected("pressed", self, "_on_shape_button_pressed"):
				child.connect("pressed", self, "_on_shape_button_pressed")

	_bucket_button = Button.new()
	_bucket_button.toggle_mode = true
	_bucket_button.hint_tooltip = "Paint Bucket: click any region bounded by the enabled barrier types (see the Stopped by options).\nNote: walls, paths and patterns below the target layer are ignored (the pattern covers them), so set the active layer as high as possible before filling to speed up the computation."
	var icon = _load_icon_texture("bucket.png")
	if icon != null:
		_bucket_button.icon = icon
	_bucket_button.connect("toggled", self, "_on_bucket_toggled")

	_shape_hbox.add_child(_bucket_button)

	_build_options_row(align)

	print("[PatternPaintBucket] Bucket button injected in shape buttons row (%d existing buttons)" % _shape_buttons.size())


# Rangée "Stopped by: [x] Walls [x] Paths [ ] Patterns", visible uniquement quand
# l'outil bucket est actif.
func _build_options_row(align):
	# Label sur sa propre ligne, cases à cocher sur la ligne suivante.
	_opts_hbox = VBoxContainer.new()
	_opts_hbox.visible = false

	var lbl = Label.new()
	lbl.text = "Stopped by:"
	_opts_hbox.add_child(lbl)

	var cb_row = HBoxContainer.new()
	_opts_hbox.add_child(cb_row)

	_cb_walls = CheckBox.new()
	_cb_walls.text = "Walls"
	_cb_walls.pressed = true
	cb_row.add_child(_cb_walls)

	_cb_paths = CheckBox.new()
	_cb_paths.text = "Paths"
	_cb_paths.pressed = true
	cb_row.add_child(_cb_paths)

	_cb_patterns = CheckBox.new()
	_cb_patterns.text = "Patterns"
	_cb_patterns.pressed = false
	cb_row.add_child(_cb_patterns)

	# Insérer la rangée juste SOUS la rangée des boutons de forme/bucket.
	var parent = _shape_hbox.get_parent()
	parent.add_child(_opts_hbox)
	parent.move_child(_opts_hbox, _shape_hbox.get_index() + 1)


# ── Quand l'utilisateur clique un bouton de forme DD (rect/circle/polygon) ───

func _on_shape_button_pressed():
	if _bucket_active:
		_prev_mode = -1
		_bucket_button.pressed = false


# ── Quand le bucket est toggled ──────────────────────────────────────────────

func _on_bucket_toggled(pressed: bool):
	_bucket_active = pressed
	if _opts_hbox != null:
		_opts_hbox.visible = pressed

	var pat_tool = _g.Editor.Tools["PatternShapeTool"]
	if pat_tool == null: return

	if pressed:
		_prev_mode = pat_tool.get("Mode") if pat_tool.get("Mode") != null else 0
		for btn in _shape_buttons:
			if is_instance_valid(btn):
				btn.pressed = false

		var ep = pat_tool.get("EditPoints")
		if ep != null and ep.get("pressed") == true:
			ep.set("pressed", false)

		_apply_cursor()
		_hide_preview()
	else:
		if _prev_mode >= 0 and _prev_mode < _shape_buttons.size():
			if is_instance_valid(_shape_buttons[_prev_mode]):
				_shape_buttons[_prev_mode].pressed = true

		_remove_cursor()
		_show_preview()

	print("[PatternPaintBucket] Bucket mode: ", pressed)


# ── Preview pointer (le pointeur jaune sur la map) ──────────────────────────

var _saved_cursor_mode := -1


func _hide_preview():
	var world_ui = _g.get("WorldUI")
	if world_ui == null: return
	var cur = world_ui.get("CursorMode")
	if cur != null and cur != 0:
		_saved_cursor_mode = cur
	world_ui.set("CursorMode", 0)


func _show_preview():
	var world_ui = _g.get("WorldUI")
	if world_ui == null: return
	if _saved_cursor_mode >= 0:
		world_ui.set("CursorMode", _saved_cursor_mode)
		_saved_cursor_mode = -1
	else:
		world_ui.set("CursorMode", 1)


# ── Listener ─────────────────────────────────────────────────────────────────

func _install_listener():
	if Engine.has_meta(_META_KEY):
		var old = Engine.get_meta(_META_KEY)
		if is_instance_valid(old):
			old.handler = null
			old.queue_free()
	var node = Node.new()
	node.name = "PatternPaintBucketListener"
	var s = GDScript.new()
	s.source_code = "extends Node\nvar handler = null\nfunc _input(e):\n\tif handler == null: return\n\tif handler._on_input(e):\n\t\tget_tree().set_input_as_handled()\n"
	s.reload()
	node.set_script(s)
	node.handler = self
	Engine.set_meta(_META_KEY, node)
	# Watchdog timer (child of the listener so it lives in the SceneTree and
	# keeps ticking even when DD freezes the mod update loop behind a modal).
	var wt = Timer.new()
	wt.wait_time = 2.0
	wt.autostart = true
	node.add_child(wt)
	wt.connect("timeout", self, "_watchdog_tick")
	_g.Editor.get_tree().get_root().call_deferred("add_child", node)
	input_listener = node


# Failsafe: a healthy fill reports activity continuously (the progress object
# is pumped on every loop iteration, and synchronous stretches block this timer
# anyway). A long silence while _filling is set means the coroutine is dead:
# reset the flag and force the orphaned modal dialog closed.
func _watchdog_tick():
	if not _filling:
		return
	var alive = _fill_started
	if _active_progress != null:
		alive = max(alive, _active_progress.last_activity)
	if OS.get_ticks_msec() - alive < FILL_WATCHDOG_MS:
		return
	print("[PatternPaintBucket] WARNING: fill watchdog fired — the fill coroutine died (check the errors above). Bucket re-armed.")
	_filling = false
	if _active_progress != null:
		if _active_progress.has_method("force_close"):
			_active_progress.force_close()
		_active_progress = null


# ── Curseur ──────────────────────────────────────────────────────────────────

func _apply_cursor():
	if _bucket_cursor_tex != null:
		Input.set_custom_mouse_cursor(_bucket_cursor_tex, Input.CURSOR_ARROW, Vector2(0, 0))
		_cursor_applied = true


func _remove_cursor():
	if _cursor_applied:
		Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)
		_cursor_applied = false


# ── Détection du PatternShapeTool actif ──────────────────────────────────────

func _is_pattern_tool_active() -> bool:
	if _g == null: return false
	var editor = _g.get("Editor")
	if editor == null: return false
	var tool_name = editor.get("ActiveToolName")
	return tool_name == "PatternShapeTool"


# ── Accès aux données du niveau ──────────────────────────────────────────────

func _get_current_level():
	if _g == null: return null
	var world = _g.get("World")
	if world == null: return null
	return world.call("GetCurrentLevel")


# ── Géométrie ────────────────────────────────────────────────────────────────

func _point_in_polygon(point: Vector2, polygon: Array) -> bool:
	var n = polygon.size()
	if n < 3: return false
	var inside = false
	var j = n - 1
	for i in range(n):
		var pi = polygon[i]
		var pj = polygon[j]
		if ((pi.y > point.y) != (pj.y > point.y)) and \
			(point.x < (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x):
			inside = not inside
		j = i
	return inside


func _polygon_area(pts: Array) -> float:
	var area = 0.0
	var n = pts.size()
	for i in range(n):
		var j = (i + 1) % n
		area += pts[i].x * pts[j].y
		area -= pts[j].x * pts[i].y
	return abs(area) * 0.5


# ── Construction des barriers ────────────────────────────────────────────────

# Layer où le PatternShapeTool posera la prochaine forme. null si indéterminable.
func _get_pattern_target_layer():
	var pat_tool = _g.Editor.Tools["PatternShapeTool"]
	if pat_tool == null: return null
	var al = pat_tool.get("ActiveLayer")
	if al == null: return null
	return int(al)


# ── Élimination de trous robuste (façon earcut) ──────────────────────────────
# Convertit un outer + N trous en UN seul polygone simple non auto-intersectant.
# Le pont de chaque trou relie son sommet le plus à gauche à un sommet VISIBLE de
# l'outer (rayon vers la gauche + raffinement par sommets réflexes), ce qui
# garantit des ponts qui ne se croisent pas — contrairement au pontage par
# projection qui, avec beaucoup de trous, produisait des polygones
# auto-intersectants refusés par DrawPolygon ("Bad Polygon").
# Tout le calcul se fait en coords y-inversées (convention math d'earcut : outer
# CCW / trous CW), puis on ré-inverse le résultat.
func _eliminate_holes(outer_in: Array, holes_in: Array) -> Array:
	if holes_in.size() == 0:
		return outer_in
	var outer = _flip_y(outer_in)
	if _ring_signed_area(outer) < 0.0:
		outer.invert()  # outer en CCW (aire signée positive)
	var prepared = []
	for h in holes_in:
		var hp = _flip_y(h)
		if _ring_signed_area(hp) > 0.0:
			hp.invert()  # trous en CW (aire signée négative)
		prepared.append(hp)
	prepared.sort_custom(self, "_sort_rings_by_leftmost_x")
	for hole in prepared:
		outer = _eliminate_hole(outer, hole)
	return _flip_y(outer)


func _flip_y(ring: Array) -> Array:
	var r = []
	for p in ring:
		r.append(Vector2(p.x, -p.y))
	return r


func _ring_signed_area(ring: Array) -> float:
	var a = 0.0
	var n = ring.size()
	for i in range(n):
		var j = (i + 1) % n
		a += ring[i].x * ring[j].y - ring[j].x * ring[i].y
	return a * 0.5


func _sort_rings_by_leftmost_x(a, b) -> bool:
	return _ring_min_x(a) < _ring_min_x(b)


func _ring_min_x(ring: Array) -> float:
	var mx = INF
	for p in ring:
		if p.x < mx: mx = p.x
	return mx


func _eliminate_hole(outer: Array, hole: Array) -> Array:
	var hi = 0
	var minx = INF
	for i in range(hole.size()):
		if hole[i].x < minx:
			minx = hole[i].x
			hi = i
	var bi = _find_hole_bridge(outer, hole, hi)
	if bi < 0:
		# Repli : sommet le plus proche (peut se croiser mais évite tout crash)
		var bd = INF
		bi = 0
		for i in range(outer.size()):
			var d = outer[i].distance_squared_to(hole[hi])
			if d < bd:
				bd = d; bi = i
	# Splice : outer[0..bi] + boucle complète du trou depuis hi + retour outer[bi]
	var res = []
	for k in range(bi + 1):
		res.append(outer[k])
	var n = hole.size()
	for k in range(n + 1):
		res.append(hole[(hi + k) % n])
	res.append(outer[bi])
	for k in range(bi + 1, outer.size()):
		res.append(outer[k])
	return res


func _signed_area3(p: Vector2, q: Vector2, r: Vector2) -> float:
	return (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y)


func _point_in_triangle(a: Vector2, b: Vector2, c: Vector2, p: Vector2) -> bool:
	return (c.x - p.x) * (a.y - p.y) - (a.x - p.x) * (c.y - p.y) >= 0.0 and \
		(a.x - p.x) * (b.y - p.y) - (b.x - p.x) * (a.y - p.y) >= 0.0 and \
		(b.x - p.x) * (c.y - p.y) - (c.x - p.x) * (b.y - p.y) >= 0.0


func _locally_inside(outer: Array, ai: int, b: Vector2) -> bool:
	var n = outer.size()
	var a = outer[ai]
	var aprev = outer[(ai - 1 + n) % n]
	var anext = outer[(ai + 1) % n]
	if _signed_area3(aprev, a, anext) < 0.0:
		return _signed_area3(a, b, anext) >= 0.0 and _signed_area3(a, aprev, b) >= 0.0
	else:
		return _signed_area3(a, b, aprev) < 0.0 or _signed_area3(a, anext, b) < 0.0


# Port d'earcut findHoleBridge : trouve l'index du sommet de `outer` auquel relier
# le sommet `hi` (le plus à gauche) de `hole`. Retourne -1 si rien trouvé.
func _find_hole_bridge(outer: Array, hole: Array, hi: int) -> int:
	var hx = hole[hi].x
	var hy = hole[hi].y
	var qx = -INF
	var m = -1
	var n = outer.size()
	# Rayon horizontal vers la gauche : arête traversée, endpoint de x max <= hx
	for i in range(n):
		var p = outer[i]
		var pnext = outer[(i + 1) % n]
		if hy <= p.y and hy >= pnext.y and pnext.y != p.y:
			var x = p.x + (hy - p.y) * (pnext.x - p.x) / (pnext.y - p.y)
			if x <= hx and x > qx:
				qx = x
				m = i if p.x < pnext.x else (i + 1) % n
				if x == hx:
					return m
	if m < 0:
		return -1
	# Raffinement : parmi les sommets réflexes dans le triangle (hole, intersection,
	# m), choisir celui de tangente minimale et localement visible.
	var mx = outer[m].x
	var my = outer[m].y
	var tan_min = INF
	var best = m
	for i in range(n):
		var pv = outer[i]
		if hx >= pv.x and pv.x >= mx and hx != pv.x:
			var a: Vector2
			var c: Vector2
			if hy < my:
				a = Vector2(hx, hy); c = Vector2(qx, hy)
			else:
				a = Vector2(qx, hy); c = Vector2(hx, hy)
			if _point_in_triangle(a, Vector2(mx, my), c, pv):
				var tanv = abs(hy - pv.y) / (hx - pv.x)
				if (tanv < tan_min or (tanv == tan_min and pv.x > outer[best].x)) and _locally_inside(outer, i, hole[hi]):
					best = i
					tan_min = tanv
	return best


# ── Création du pattern shape ────────────────────────────────────────────────

func _draw_pattern_poly(ps_node, pts: Array, invert: bool, rot: float) -> bool:
	var node_id = _g.World.nextNodeID
	ps_node.DrawPolygon(pts, invert)
	if _g.World.HasNodeID(node_id):
		var shape = _g.World.GetNodeByID(node_id)
		if shape.has_method("SetNewRotation"):
			shape.SetNewRotation(rot)
		_g.World.AssignNodeID(shape)
		return true
	return false


# Dédoublonne les sommets consécutifs et supprime les « darts » (pointes de
# largeur nulle : le contour part et revient sur la même direction), artefacts
# des fusions Clipper des quads de segments. Ne modifie pas la forme utile.
func _clean_ring_basic(poly: Array) -> Array:
	var pts = []
	for p in poly:
		if pts.size() == 0 or pts[pts.size() - 1].distance_to(p) > 0.03:
			pts.append(p)
	while pts.size() >= 2 and pts[0].distance_to(pts[pts.size() - 1]) <= 0.03:
		pts.pop_back()
	var changed = true
	while changed and pts.size() >= 3:
		changed = false
		var n = pts.size()
		for i in range(n):
			var b = pts[i]
			var ab = (pts[(i - 1 + n) % n] - b)
			var cb = (pts[(i + 1) % n] - b)
			if ab.length() < 0.03 or cb.length() < 0.03:
				pts.remove(i)
				changed = true
				break
			# pointe : les deux arêtes repartent quasi dans la même direction
			if ab.normalized().dot(cb.normalized()) > 0.999:
				pts.remove(i)
				changed = true
				break
	return pts


# Décompose un anneau qui repasse par (quasi) le même sommet — pincement,
# artefact fréquent des fusions Clipper — en sous-anneaux strictement simples.
func _split_pinched_ring(pts: Array) -> Array:
	var n = pts.size()
	if n < 3: return []
	for i in range(n):
		for j in range(i + 2, n):
			if i == 0 and j == n - 1: continue
			if pts[i].distance_to(pts[j]) <= 0.03:
				var r1 = []
				for k in range(i, j): r1.append(pts[k])
				var r2 = []
				for k in range(j, n): r2.append(pts[k])
				for k in range(0, i): r2.append(pts[k])
				return _split_pinched_ring(r1) + _split_pinched_ring(r2)
	return [pts]


# Nettoie un anneau et le rend triangulable : dédoublonnage + darts, et si la
# triangulation échoue encore, décomposition des pincements en lobes (chaque
# lobe sera dessiné comme un pattern à part — une région pincée EST deux zones
# reliées par un point). Renvoie la liste des anneaux exploitables.
func _ring_to_lobes(poly: Array) -> Array:
	var c = _clean_ring_basic(poly)
	if c.size() < 3: return []
	if Geometry.triangulate_polygon(PoolVector2Array(c)).size() >= 3:
		return [c]
	var lobes = []
	for r in _split_pinched_ring(c):
		var rc = _clean_ring_basic(r)
		if rc.size() >= 3 and _polygon_area(rc) > 1.0 \
				and Geometry.triangulate_polygon(PoolVector2Array(rc)).size() >= 3:
			lobes.append(rc)
	if lobes.size() == 0:
		lobes = [c]  # dernier recours : DrawPolygon avertira
	return lobes


func _create_pattern_at(points: Array, holes: Array = [], click_pt = null):
	var pat_tool = _g.Editor.Tools["PatternShapeTool"]
	if pat_tool == null: return

	var level = _get_current_level()
	if level == null: return
	var ps_node = level.get("PatternShapes")
	if ps_node == null: return

	# Rotation courante du tool. On l'applique via SetNewRotation (qui ne touche
	# NI la texture NI la couleur), pas via SetOptions.
	var rotation_val = 0.0
	var rot_ctrl = pat_tool.get("Rotation")
	if rot_ctrl != null and rot_ctrl.has_method("get_value"):
		rotation_val = deg2rad(rot_ctrl.get_value())

	# DrawPolygon hérite de la texture/couleur/rotation COURANTES du tool. Les
	# anneaux issus de Clipper peuvent être « faiblement simples » (darts,
	# pincements) : nettoyés/décomposés en lobes triangulables. Les trous sont
	# PONTÉS dans leur lobe via _eliminate_holes (ponts earcut non-croisants).
	# NE PAS utiliser DrawPolygon(h, invertAction=true) : PatternShapes.AddPolygon
	# IGNORE ce flag (la découpe vit dans PatternShapeTool) → chaque « trou »
	# créait un 2e pattern PLEIN par-dessus.
	var lobes = _ring_to_lobes(points)
	if lobes.size() == 0:
		print("[PatternPaintBucket] Erreur: région dégénérée")
		return
	var parts = []
	for l in lobes:
		parts.append({"outer": l, "holes": []})
	for h in holes:
		for hl in _ring_to_lobes(h):
			var cen = _ring_centroid(hl)
			for part in parts:
				if _point_in_polygon(cen, part.outer):
					part.holes.append(hl)
					break
	var made = 0
	var total_holes = 0
	for part in parts:
		var poly = part.outer
		if part.holes.size() > 0:
			poly = _eliminate_holes(part.outer, part.holes)
		if _draw_pattern_poly(ps_node, poly, false, rotation_val):
			made += 1
			total_holes += part.holes.size()
	if made == 0:
		print("[PatternPaintBucket] Erreur: impossible de créer le pattern")
		return
	print("[PatternPaintBucket] Pattern créé : %d forme(s), %d trou(s) ponté(s)" % [made, total_holes])


# ── Fill ─────────────────────────────────────────────────────────────────────

func _do_fill(mouse_world: Vector2, stop_walls: bool, stop_paths: bool, stop_patterns: bool):
	if _region_geo == null:
		print("[PatternPaintBucket] region_geometry unavailable; fill disabled")
		return
	if _filling:
		return
	_filling = true
	_fill_started = OS.get_ticks_msec()
	var progress = _new_progress("Filling pattern…")
	_active_progress = progress
	if progress != null:
		# Yield une frame pour que le 0 % soit réellement AFFICHÉ (sinon la
		# première frame rendue arrive au premier pump(), déjà à quelques %).
		progress.set_progress(0.0, "Computing fill region\u2026")
		yield(_g.Editor.get_tree(), "idle_frame")
	var t_start = OS.get_ticks_msec()

	# Délégué à region_geometry : min_layer = calque-cible du tool (les barrières
	# strictement dessous seront recouvertes par le pattern), keep_holes = true
	# (le pontage par lobes est fait ici dans _create_pattern_at).
	var region = _region_geo.compute_region_async(mouse_world, stop_walls, stop_paths, stop_patterns, progress, 0.0, 0.9, _get_pattern_target_layer(), true)
	if region is GDScriptFunctionState:
		region = yield(region, "completed")

	if progress != null and region.get("cancelled") == true:
		progress.close()
		print("[PatternPaintBucket] Remplissage annulé par l'utilisateur")
		_filling = false
		_active_progress = null
		return

	var t_compute = OS.get_ticks_msec() - t_start
	if region.outer.size() < 3:
		if progress != null: progress.close()
		print("[PatternPaintBucket] Aucune région trouvée (clic sur un mur ?) — %d ms" % t_compute)
		_filling = false
		_active_progress = null
		return

	if progress != null:
		# Jalon rendu avant le pontage + DrawPolygon.
		progress.set_progress(0.95, "Creating pattern\u2026")
		yield(_g.Editor.get_tree(), "idle_frame")

	print("[PatternPaintBucket] Région : %d points — calcul %d ms" % [region.outer.size(), t_compute])
	_create_pattern_at(region.outer, region.get("holes", []), mouse_world)
	if progress != null:
		# Deux frames pour que le 100 % soit visible avant fermeture.
		progress.set_progress(1.0, "Done")
		yield(_g.Editor.get_tree(), "idle_frame")
		yield(_g.Editor.get_tree(), "idle_frame")
		progress.close()
	_filling = false
	_active_progress = null


# ── Input ─────────────────────────────────────────────────────────────────────

func _on_input(event) -> bool:
	if not _bucket_active: return false
	if not _is_pattern_tool_active(): return false
	if not (event is InputEventMouseButton): return false
	if not event.pressed: return false
	if event.button_index != BUTTON_LEFT: return false

	if ui_util != null and ui_util.is_mouse_over_hud(input_listener):
		return false

	var world_ui = _g.get("WorldUI")
	if world_ui == null: return false
	# macOS fix: use DD's reference world mouse position; converting
	# event.position by hand drifts on Retina/DPI/UI scaling.
	var mouse_world: Vector2 = world_ui.MousePosition

	var stop_walls = _cb_walls.pressed if _cb_walls != null else true
	var stop_paths = _cb_paths.pressed if _cb_paths != null else true
	var stop_patterns = _cb_patterns.pressed if _cb_patterns != null else false
	_do_fill(mouse_world, stop_walls, stop_paths, stop_patterns)
	return true


# ── Update ────────────────────────────────────────────────────────────────────

func update(_delta):
	if _bucket_button == null: return

	if _bucket_active and not _is_pattern_tool_active():
		_remove_cursor()
		_saved_cursor_mode = -1
		return

	if _bucket_active and _is_pattern_tool_active():
		_hide_preview()
		# Seau uniquement sur le canvas ; souris normale au-dessus de l'UI (menus,
		# panneaux, floatbar, popups). On peut peindre partout, donc plus de curseur
		# « croix » et plus de test de zone fillable.
		if ui_util != null and ui_util.is_mouse_over_hud(input_listener):
			_remove_cursor()
		else:
			if not _cursor_applied:
				_apply_cursor()

	if _bucket_active:
		var pat_tool = _g.Editor.Tools["PatternShapeTool"]
		if pat_tool != null:
			var ep = pat_tool.get("EditPoints")
			if ep != null and ep.get("pressed") == true:
				_bucket_active = false
				_bucket_button.pressed = false
				_remove_cursor()
				_show_preview()
				return

	if _bucket_active:
		for btn in _shape_buttons:
			if is_instance_valid(btn) and btn.pressed:
				_bucket_active = false
				_bucket_button.pressed = false
				_remove_cursor()
				_show_preview()
				return


# Simplification Ramer–Douglas–Peucker. Les points lissés (Chaikin) des paths
# sont quasi colinéaires : les décimer avant l'offset réduit fortement la
# taille des polygones manipulés par Clipper (tolérance invisible < 1 px vs
# une bande de ±2 px), donc le coût des fusions sur les grosses maps.

func _ring_centroid(ring: Array) -> Vector2:
	var c = Vector2(0, 0)
	for p in ring:
		c += p
	if ring.size() > 0:
		c /= ring.size()
	return c


