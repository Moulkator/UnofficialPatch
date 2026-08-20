# water_tool_fix.gd
# Toggle water animation on/off with persistence
# Fixes black lines at map edges by disabling distortion near map bounds
# Fixes nested island bug: drawing water inside a hole detaches sibling holes
# from their outer polygon (DFS grouping bug in WaterMesh.UpdateMesh_TriangleNet),
# flooding unrelated interiors. Fixed by flattening the PolyTree via Save()/Load().
# Hides the brush cursor while a color picker popup is open: WorldUI already
# supports this (colorPickerActive + OnColorPickerVisible/Hidden handlers) but
# the WaterBrush ColorPalettes never connect their picker popups to it.

var _g

var water_brush = null
var _water_panel = null
var _button = null
var _animation_disabled = false
var _shader = null
var _mat = null
var _settings_path = "user://UnofficialPatch/bugfixes_water_anim.cfg"
var _bounds_set = false
# Watchdog "îlots imbriqués" : signature du mesh par instance, et compteur de stabilité
var _tree_sig = {}
var _tree_stable = {}
var _last_map_w = 0
var _last_map_h = 0
# Color picker popups (PopupPanel) of the panel's ColorPalettes, and the
# instance id of the WorldUI they are currently connected to
var _picker_popups = []
var _picker_hooked_ui_id = 0
var TILE_SIZE = 256.0

# Animated shader: uses map bounds to disable distortion near edges
var animated_shader_code = """shader_type canvas_item;
render_mode blend_mix, unshaded;

uniform sampler2D distortion;
uniform vec2 map_min = vec2(-99999.0);
uniform vec2 map_max = vec2(99999.0);
uniform float edge_margin = 64.0;

varying vec2 world_distort_uv;
varying vec2 world_pos;

float average(in vec3 color)
{
	return (color.r + color.g + color.b) / 3.0;
}

void vertex()
{
	world_pos = VERTEX;
	world_distort_uv = VERTEX;
	ivec2 distort_size = textureSize(distortion, 0) * 2;
	world_distort_uv.x /= float(distort_size.x);
	world_distort_uv.y /= float(distort_size.y);
}

void fragment()
{
	float dist_to_edge = min(
		min(world_pos.x - map_min.x, map_max.x - world_pos.x),
		min(world_pos.y - map_min.y, map_max.y - world_pos.y)
	);
	float edge_blend = smoothstep(0.0, edge_margin, dist_to_edge);

	vec2 distort1 = (texture(distortion, world_distort_uv - TIME * 0.05).rg - 0.5) * 0.005;
	vec2 distort2 = (texture(distortion, world_distort_uv + TIME * 0.05).rg - 0.5) * 0.005;
	vec2 uv_offset = mix(distort1, distort2, 0.5) * edge_blend;
	vec3 distorted_floor = texture(SCREEN_TEXTURE, SCREEN_UV + uv_offset).rgb;
	float avg = average(distorted_floor);
	if (avg < 0.5)
	{
		COLOR.rgb *= smoothstep(0.0, 0.5, avg);
	}
}
"""

# Static shader: no animation, no distortion, original darkening
var static_shader_code = """shader_type canvas_item;
render_mode blend_mix, unshaded;

uniform sampler2D distortion;
varying vec2 world_distort_uv;

float average(in vec3 color)
{
	return (color.r + color.g + color.b) / 3.0;
}

void vertex()
{
	world_distort_uv = VERTEX;
	ivec2 distort_size = textureSize(distortion, 0) * 2;
	world_distort_uv.x /= float(distort_size.x);
	world_distort_uv.y /= float(distort_size.y);
}

void fragment()
{
	vec3 floor_color = textureLod(SCREEN_TEXTURE, SCREEN_UV, 0.0).rgb;
	float avg = average(floor_color);
	if (avg < 0.5)
	{
		COLOR.rgb *= smoothstep(0.0, 0.5, avg);
	}
}
"""

func initialize():
	water_brush = _g.Editor.Tools["WaterBrush"]
	_water_panel = _g.Editor.Toolset.GetToolPanel("WaterBrush")
	_load_setting()
	print("[WaterAnim] initialized, disabled=" + str(_animation_disabled))


func update(delta):
	if _water_panel == null:
		return
	if _shader == null:
		var mesh = water_brush.Mesh
		if mesh != null:
			_mat = mesh.get("material")
			if _mat != null:
				_shader = _mat.get("shader")
				if _shader != null:
					_apply_shader()
	if _button == null and _water_panel.visible:
		_create_button()
	_hook_color_pickers()
	if _mat != null and not _animation_disabled:
		# Detect map size changes
		var world = _g.World
		if world != null:
			var w = world.get("Width")
			var h = world.get("Height")
			if w != null and h != null:
				if w != _last_map_w or h != _last_map_h:
					_bounds_set = false
					_last_map_w = w
					_last_map_h = h
		if not _bounds_set:
			_update_bounds()
	_watch_nested_islands()


# --- Hide brush cursor while a color picker is open ------------------------
# WorldUI._Draw() skips everything when its private colorPickerActive flag is
# set; the flag is toggled by the private handlers OnColorPickerVisible /
# OnColorPickerHidden (connectable by name, like ColorPalette does with its
# own private handlers). We wire the picker PopupPanel of each ColorPalette
# in the water panel to those handlers, and re-wire when WorldUI is recreated
# on map reload (old connections die with the freed instance).

func _hook_color_pickers():
	# Prune popups freed with a rebuilt panel, if that ever happens
	for i in range(_picker_popups.size() - 1, -1, -1):
		if not is_instance_valid(_picker_popups[i]):
			_picker_popups.remove(i)
	if _picker_popups.empty():
		_find_picker_popups(_water_panel)
		if _picker_popups.empty():
			return
	var ui = _g.get("WorldUI")
	if ui == null or not is_instance_valid(ui):
		_picker_hooked_ui_id = 0
		return
	var uid = ui.get_instance_id()
	if uid == _picker_hooked_ui_id:
		return
	for popup in _picker_popups:
		if not popup.is_connected("about_to_show", ui, "OnColorPickerVisible"):
			popup.connect("about_to_show", ui, "OnColorPickerVisible")
		if not popup.is_connected("popup_hide", ui, "OnColorPickerHidden"):
			popup.connect("popup_hide", ui, "OnColorPickerHidden")
	_picker_hooked_ui_id = uid
	print("[WaterFix] %d color picker popup(s) hooked to WorldUI cursor hiding" % _picker_popups.size())


func _find_picker_popups(node):
	# ColorPalette is an HBoxContainer declaring a custom "color_changed"
	# signal; its color picker popup is its only PopupPanel child (the preset
	# list is a plain Popup, the context menu a PopupMenu)
	if node == null:
		return
	for child in node.get_children():
		if child is HBoxContainer and child.has_signal("color_changed"):
			for sub in child.get_children():
				if sub is PopupPanel:
					_picker_popups.append(sub)
		_find_picker_popups(child)


# --- Fix "îlots imbriqués" -------------------------------------------------
# Bug vanilla : UpdateMesh_TriangleNet regroupe les trous avec le DERNIER
# polygone visité en DFS. Un îlot dessiné dans un trou devient enfant de ce
# trou dans le PolyTree ; le DFS le visite avant les trous frères suivants,
# qui se retrouvent alors rattachés à l'îlot -> l'extérieur perd ces trous
# et la triangulation les remplit d'eau (les bordures Line2D restent justes).
# Correctif : aplatir l'arbre (les îlots remontent à la racine, chaque
# extérieur ne garde que ses trous directs) via Save()/Load(). La géométrie
# est inchangée, seul l'ordre de visite DFS est corrigé.

func _watch_nested_islands():
	if water_brush == null:
		return
	var mesh_node = water_brush.Mesh
	if mesh_node == null or not is_instance_valid(mesh_node):
		return
	var array_mesh = mesh_node.get("mesh")
	if array_mesh == null:
		return
	var key = mesh_node.get_instance_id()
	var sig = _mesh_signature(array_mesh)
	if not _tree_sig.has(key) or _tree_sig[key] != sig:
		# Mesh modifié (dessin, undo/redo, chargement) : armer le compteur
		_tree_sig[key] = sig
		_tree_stable[key] = 0
		return
	if not _tree_stable.has(key):
		return
	# Attendre la fin du trait et quelques frames de stabilité
	if Input.is_mouse_button_pressed(BUTTON_LEFT):
		_tree_stable[key] = 0
		return
	_tree_stable[key] += 1
	if _tree_stable[key] < 10:
		return
	_tree_stable.erase(key)
	_fix_nested_islands(mesh_node)
	_tree_sig[key] = _mesh_signature(array_mesh)


func _mesh_signature(array_mesh):
	# Signature bon marché : nombre de surfaces + tailles des tableaux de sommets
	var sig = [array_mesh.get_surface_count()]
	for i in range(array_mesh.get_surface_count()):
		sig.append(array_mesh.surface_get_array_len(i))
	return sig


func _fix_nested_islands(mesh_node):
	var data = mesh_node.call("Save")
	if data == null or not (data is Dictionary) or not data.has("tree"):
		return
	var tree = data["tree"]
	if not (tree is Dictionary):
		return
	var roots = tree.get("children")
	if not (roots is Array):
		return
	var new_roots = []
	var changed = [false]
	for outer in roots:
		_flatten_poly_node(outer, new_roots, changed)
	if not changed[0]:
		return
	tree["children"] = new_roots
	mesh_node.call("Load", data)
	print("[WaterFix] Nested island detected: PolyTree flattened (%d root polygons)" % new_roots.size())


func _flatten_poly_node(outer, roots, changed):
	# Ajoute 'outer' à la racine, garde ses trous directs, remonte
	# récursivement les îlots (enfants de trous) au niveau racine
	if not (outer is Dictionary):
		return
	roots.append(outer)
	var children = outer.get("children")
	if not (children is Array):
		return
	var holes = []
	for hole in children:
		holes.append(hole)
		if not (hole is Dictionary):
			continue
		var islands = hole.get("children")
		if islands is Array and islands.size() > 0:
			changed[0] = true
			for island in islands:
				_flatten_poly_node(island, roots, changed)
			hole["children"] = []
	outer["children"] = holes


func _update_bounds():
	var world = _g.World
	if world == null:
		return
	var w = world.get("Width")
	var h = world.get("Height")
	if w == null or h == null:
		return
	var min_px = Vector2(0, 0)
	var max_px = Vector2(float(w) * TILE_SIZE, float(h) * TILE_SIZE)
	_mat.set_shader_param("map_min", min_px)
	_mat.set_shader_param("map_max", max_px)
	_mat.set_shader_param("edge_margin", 64.0)
	_bounds_set = true


func _apply_shader():
	if _shader == null:
		return
	_bounds_set = false
	if _animation_disabled:
		_shader.set_code(static_shader_code)
		print("[WaterAnim] Applied: static")
	else:
		_shader.set_code(animated_shader_code)
		print("[WaterAnim] Applied: animated (edge-aware)")


func _create_button():
	var align = null
	for child in _water_panel.get_children():
		if child is VBoxContainer:
			align = child
			break
	if align == null:
		return
	var disable_border_idx = -1
	var idx = 0
	for child in align.get_children():
		if child is CheckButton and child.text == "DISABLE_BORDER":
			disable_border_idx = idx
		idx += 1
	if disable_border_idx < 0:
		return
	_button = CheckButton.new()
	_button.text = "Disable Animation"
	_button.pressed = _animation_disabled
	_button.connect("toggled", self, "_on_toggle")
	align.add_child(_button)
	align.move_child(_button, disable_border_idx + 1)
	print("[WaterAnim] Button added")


func _on_toggle(pressed):
	_animation_disabled = pressed
	_save_setting()
	_apply_shader()


func _save_setting():
	var file = File.new()
	file.open(_settings_path, File.WRITE)
	file.store_line(to_json({"disable_animation": _animation_disabled}))
	file.close()


func _load_setting():
	var file = File.new()
	if not file.file_exists(_settings_path):
		return
	file.open(_settings_path, File.READ)
	var text = file.get_as_text()
	file.close()
	var data = JSON.parse(text).result
	if data != null and data is Dictionary:
		_animation_disabled = data.get("disable_animation", false)
