# ft_context.gd
# Right-click context menu provider for Free Transform.
#
# Extrait de favorites.gd pour que Free Transform reste accessible via le
# menu contextuel meme quand le mod Favorite Assets est desactive. Toujours
# charge (independant du toggle Favorite Assets), enregistre comme provider
# dans right_click_util.

var _g

# Reference vers free_transform.gd (injectee par Main.gd au boot).
# C'est lui qui possede le widget FT (label + reset + lock + toggle) dans
# le panel SelectTool ; c'est donc lui qui sait le cacher proprement.
var free_transform = null

var _icon_ft = null
var _ft_toggle_btn_ref = null
var _initial_sync_frames := 120  # ~2s de retry pour sync initial


func initialize() -> void:
	var img_ft = Image.new()
	if img_ft.load(_g.Root + "icons/free_transform.png") == OK:
		var tex_ft = ImageTexture.new()
		tex_ft.create_from_image(img_ft, 0)
		_icon_ft = tex_ft
	print("[FTContext] Initialized")


# Sync la visibilite du widget FT avec le toggle Free Transform. Le widget
# FT est ajoute par free_transform.gd a son `align.move_child(group, 12)` :
# il n'existe pas tout de suite au boot d'ou la fenetre de retry de ~2s
# qui s'arrete des qu'on a reussi a sync une fois.
func update(_delta: float) -> void:
	if _initial_sync_frames > 0:
		_initial_sync_frames -= 1
		# Considere "pret" des que free_transform expose set_widget_visible
		# ET son _ui_group est instancie (pose dans le panel).
		if free_transform != null and free_transform.has_method("set_widget_visible"):
			var grp = free_transform.get("_ui_group")
			if grp != null and is_instance_valid(grp):
				set_button_visible(_is_enabled())
				_initial_sync_frames = 0


func set_button_visible(visible: bool) -> void:
	# Delegate a free_transform : c'est lui qui possede et sait cacher
	# l'ensemble du widget (pas juste le CheckButton).
	if free_transform != null and free_transform.has_method("set_widget_visible"):
		free_transform.set_widget_visible(visible)


func _get_select_tool():
	if not _g.Editor or not is_instance_valid(_g.Editor):
		return null
	var tools = _g.Editor.get("Tools")
	if tools == null or not (tools is Dictionary):
		return null
	return tools.get("SelectTool")


func _find_ft_toggle_button():
	if _ft_toggle_btn_ref != null and is_instance_valid(_ft_toggle_btn_ref):
		return _ft_toggle_btn_ref
	var toolset = _g.Editor.get("Toolset") if _g.Editor else null
	if not toolset or not is_instance_valid(toolset):
		return null
	var sp = toolset.GetToolPanel("SelectTool")
	if not sp:
		return null
	var result = _find_checkbutton_recursive(sp, 0)
	if result != null:
		_ft_toggle_btn_ref = result
	return result


func _find_checkbutton_recursive(node: Node, depth: int):
	if depth > 8:
		return null
	if node is CheckButton and node.get_signal_connection_list("toggled").size() > 0:
		return node
	for child in node.get_children():
		if not is_instance_valid(child):
			continue
		var r = _find_checkbutton_recursive(child, depth + 1)
		if r != null:
			return r
	return null


func _is_enabled() -> bool:
	if _g == null or _g.get("ModMapData") == null or not (_g.ModMapData is Dictionary):
		return true
	var ms = _g.ModMapData.get("_mod_settings")
	if ms == null or not ms.has_method("is_enabled"):
		return true
	return ms.is_enabled("free_transform")


# ===== Provider interface (right_click_util) =====

func get_context_items(raw) -> Array:
	var items = []
	if not _is_enabled():
		return items
	var select_tool = _get_select_tool()
	if select_tool == null:
		return items

	# FT deja active = on n'offre pas l'item (FT gere son propre menu).
	var ft_btn = _find_ft_toggle_button()
	var ft_is_off = (ft_btn == null or not ft_btn.pressed)
	if not ft_is_off:
		return items

	# Selection compatible avec FT : Objects (4), Pathways (5), PortalFree (2),
	# PortalWall (3), PatternShape (7).
	var ft_compatible = false
	for s in raw:
		if s == null or not is_instance_valid(s):
			continue
		var thing = s.get("Thing")
		if thing == null or not is_instance_valid(thing):
			continue
		var type = select_tool.GetSelectableType(thing)
		if type in [2, 3, 4, 5, 7]:
			ft_compatible = true
			break

	if ft_compatible:
		# Pas de separateur manuel : right_click_util en ajoute un
		# automatiquement entre providers. Si ft_context est seul (favorites
		# et group_assets desactives), pas de leading separator = pas
		# d'espace vide en haut du popup.
		items.append({label = "Free Transform", icon = _icon_ft, action_id = "ft_enable"})
	return items


func on_context_action(action_id: String, raw) -> void:
	if action_id != "ft_enable":
		return
	var btn = _find_ft_toggle_button()
	if btn != null and is_instance_valid(btn):
		btn.pressed = true
		btn.emit_signal("toggled", true)
		print("[FTContext] Free Transform enabled via context menu")
