# portal_reposition_ui.gd
# UI optionnelle : bouton "Reposition Portals" + overlay visuel coloré.
#
# Si ce fichier est absent (ou ui mis à null dans Main.gd),
# wall_tool_portal_fix et floor_shape_portal_fix reviennent
# au comportement vanilla DD (portals supprimés à l'édition).

var _g

var reposition_enabled = true

const COLOR_KEPT         = Color(0.4, 1.0, 0.4, 0.8)
const COLOR_DROPPED      = Color(1.0, 0.4, 0.4, 0.8)
const COLOR_REPOSITIONED = Color(1.0, 0.7, 0.2, 0.8)

var _overlay     = null
var _marker_data = []
var _buttons     = []  # CheckButtons créés (pour sync de pressed)
var _ep_buttons  = []  # parallel array : ep_button correspondant a chaque _buttons[i]


func initialize():
	print("[PortalReposUI] initialized")


# Pilote par le toggle "Reposition Portals" du Settings panel. OFF =
# desactivation totale : reposition_enabled=false (wall_tool_portal_fix
# tombe en vanilla, portals supprimes a l'edition) ET les boutons
# "Reposition Portals (Beta)" sont caches dans le panel WallTool.
# ON : reposition_enabled=true, boutons re-affiches selon l'etat
# Edit Points en cours (sync depuis l'ep_button correspondant).
func set_enabled(v: bool) -> void:
	reposition_enabled = v
	for i in range(_buttons.size()):
		var btn = _buttons[i]
		if not is_instance_valid(btn):
			continue
		if not v:
			btn.visible = false
			# Sync l'etat pressed du repo button avec le flag, sans
			# re-emettre le signal (sinon on toggle en boucle).
			if btn.pressed != v:
				btn.disconnect("toggled", self, "_on_reposition_toggled")
				btn.pressed = v
				btn.connect("toggled", self, "_on_reposition_toggled")
		else:
			# ON : re-sync pressed = true, et la visibilite suit l'etat
			# Edit Points (visible si EP est presse).
			if btn.pressed != v:
				btn.disconnect("toggled", self, "_on_reposition_toggled")
				btn.pressed = v
				btn.connect("toggled", self, "_on_reposition_toggled")
			var ep = _ep_buttons[i] if i < _ep_buttons.size() else null
			if ep != null and is_instance_valid(ep):
				btn.visible = ep.pressed


# Crée et retourne un CheckButton "Reposition Portals (Beta)"
# placé juste après ep_button dans son parent.
# Appelé par wall_tool_portal_fix et floor_shape_portal_fix.
func create_button_for(ep_button):
	if ep_button == null:
		return null
	var parent = ep_button.get_parent()
	if parent == null:
		return null
	var ep_idx = -1
	for i in range(parent.get_child_count()):
		if parent.get_child(i) == ep_button:
			ep_idx = i
			break
	var btn = CheckButton.new()
	btn.text = "Reposition Portals (Beta)"
	btn.hint_tooltip = "On: portals on edited segments are repositioned.\nOff: vanilla behavior (portals removed)."
	btn.pressed = reposition_enabled
	btn.visible = false
	btn.connect("toggled", self, "_on_reposition_toggled")
	parent.add_child(btn)
	if ep_idx >= 0:
		parent.move_child(btn, ep_idx + 1)
	_buttons.append(btn)
	_ep_buttons.append(ep_button)
	return btn


func _on_reposition_toggled(pressed):
	reposition_enabled = pressed
	# Synchronise tous les boutons enregistrés
	for btn in _buttons:
		if is_instance_valid(btn) and btn.pressed != pressed:
			btn.disconnect("toggled", self, "_on_reposition_toggled")
			btn.pressed = pressed
			btn.connect("toggled", self, "_on_reposition_toggled")
	print("[PortalReposUI] reposition_enabled=" + str(pressed))


# ── Overlay ───────────────────────────────────────────────────────────────────

func create_overlay(level):
	if _overlay != null and is_instance_valid(_overlay):
		return
	_overlay = Node2D.new()
	_overlay.z_index = 1000
	_overlay.z_as_relative = false
	_overlay.connect("draw", self, "_on_overlay_draw")
	if level != null:
		level.add_child(_overlay)


func destroy_overlay():
	if _overlay != null and is_instance_valid(_overlay):
		_overlay.queue_free()
	_overlay = null
	_marker_data = []


func set_marker_data(data):
	_marker_data = data


func refresh_overlay():
	if _overlay != null and is_instance_valid(_overlay):
		_overlay.update()


func _on_overlay_draw():
	if _overlay == null:
		return
	for m in _marker_data:
		var tex = m.get("tex_object")
		if tex == null or not (tex is Texture):
			continue
		var pos = m["draw_position"]
		var rot = m["draw_rotation"]
		var sc  = m["scale"]
		var col = m["color"]
		var t   = Transform2D(rot, pos)
		t = t.scaled(sc)
		_overlay.draw_set_transform_matrix(t)
		_overlay.draw_texture(tex, -tex.get_size() / 2.0, col)
		_overlay.draw_set_transform_matrix(Transform2D.IDENTITY)
