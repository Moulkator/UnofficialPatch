# Grid Layer Fix
var script_class = "tool"
var _g

var DEFAULT_Z = 649
var current_z = DEFAULT_Z

var layer_slider_ref = null
var layer_spinbox_ref = null
var export_slider_ref = null
var export_spinbox_ref = null

var last_level_id = -1
var last_level_count = -1
var last_world_id = -1
var grid_was_null = false
var map_key_loaded = false

var export_grid_copy = null
var original_material = null

var opacity_slider_ref = null
var opacity_spinbox_ref = null
var current_opacity = 50
var color_picker_ref = null
var color_rect_ref = null
var _syncing_opacity = false
var pre_printer_opacity = null

# Refs UI ajoutee dans MapSettings + Export (necessaires pour cleanup).
var _label_grid_layer_ref = null
var _label_grid_opacity_ref = null
var _z_row_ref = null
var _opacity_row_ref = null
var _export_hbox_ref = null
var _format_dd_ref = null     # ref OptionButton format (PNG/JPG/WEBP) pour cleanup
var _destroyed := false

const CONFIG_PATH = "user://UnofficialPatch/grid_fix_settings.cfg"

const INVISIBLE_SHADER_CODE = """
shader_type canvas_item;
render_mode blend_mix, unshaded;
void fragment() {
  COLOR = vec4(0.0, 0.0, 0.0, 0.0);
}
"""


func get_grid_node():
  return _g.World.find_node("GridMesh", true, false)


func get_current_level():
  return _g.World.levels[_g.World.CurrentLevelId]


# _get_best_parent_and_z : utilisé UNIQUEMENT pour la copie d'export.
# Ne jamais appeler pour repositionner GridMesh lui-même :
# placer GridMesh dans Walls/Roofs/etc. provoque un InvalidCastException
# dans SelectTool.HighlightThingAtPoint (cast de type natif sur nos noeuds).
# La copie d'export n'existe que pendant que la dialog export est ouverte
# (l'utilisateur ne survole pas la map), donc pas de crash de ce cote.
#
# IMPORTANT : on EXCLUT Walls et Portals des parents candidats.
# L'export Universal VTT (.dd2vtt) fait Exporter.ExportForVTT() qui itere
# World.SourceLevel.Walls / Portals / Objects / Pathways / Lights avec des
# casts C# stricts (foreach (Wall child in Walls.GetChildren()), etc.).
# Une copie MeshInstance2D placee sous Walls/Portals y serait castee en
# Wall/Portal -> InvalidCastException -> le bake JSON plante -> DD ne
# supprime pas le PNG intermediaire et n'ecrit pas le .dd2vtt, laissant
# un fichier "<nom>.dd2vtt.png". On ne garde donc que des nœuds rendus mais
# NON serialises par le VTT. Le z visuel reste correct (z_parent + z_relatif).
func _get_best_parent_and_z(level):
  var LEVEL_NODES = [
    ["Terrain",     -500],
    ["CaveMesh",    -300],
    ["FloorShapes", -200],
    ["WaterMesh",      0],
    ["Roofs",        800],
  ]
  var best_parent = level
  var best_node_z = 0
  var best_dist = 99999
  for entry in LEVEL_NODES:
    var node = level.find_node(entry[0], false, false)
    if node != null:
      var dist = abs(current_z - entry[1])
      if dist < best_dist:
        best_dist = dist
        best_node_z = entry[1]
        best_parent = node
  return [best_parent, clamp(current_z - best_node_z, -4096, 4096)]


func apply_to_current_level():
  if _destroyed:
    return
  var grid = get_grid_node()
  if grid == null:
    return

  # On s'assure que GridMesh est toujours directement sous World.
  # On ne le reparente JAMAIS dans Walls, Roofs, Terrain, etc.
  var world = _g.World
  if grid.get_parent() != world:
    grid.get_parent().remove_child(grid)
    world.add_child(grid)

  # Z absolu : current_z est directement la valeur voulue
  # (ex : 649 = entre Walls@600 et Roofs@800, le rendu est identique)
  grid.call("set_z_index", current_z)
  grid.call("set_z_as_relative", false)
  grid.call("_set_on_top", false)

  var c = grid.self_modulate
  c.a = current_opacity / 100.0
  grid.self_modulate = c


func park_grid_in_world():
  if _destroyed:
    return
  var grid = get_grid_node()
  if grid == null:
    return
  var world = _g.World
  if grid.get_parent() != world:
    grid.get_parent().remove_child(grid)
    world.add_child(grid)
  grid.call("set_z_index", 900)
  grid.call("set_z_as_relative", false)
  grid.call("_set_on_top", true)


# Hot-unload : sauve les settings, restore le grid en etat vanilla
# (Z=900, on_top=true, opacity=1.0, materiel original si swap encore actif),
# free l'UI ajoutee dans MapSettings et Export, set _destroyed pour
# court-circuiter les callbacks restants (signals deja connectes restent
# attaches mais no-op via le flag).
func cleanup() -> void:
  save_settings()
  # Si un export grid copy traine encore (ex: cleanup pendant export en cours),
  # on le supprime — ca restore aussi le materiel original sur le grid.
  # On le fait AVANT de set _destroyed, sinon delete_export_grid_copy() est
  # court-circuite par son propre guard.
  delete_export_grid_copy()
  _disconnect_ok_listener()
  _destroyed = true
  # Restore le grid en etat vanilla pour que DD le rende normalement.
  var grid = get_grid_node()
  if grid != null:
    grid.call("set_z_index", 900)
    grid.call("set_z_as_relative", false)
    grid.call("_set_on_top", true)
    var c = grid.self_modulate
    c.a = 1.0
    grid.self_modulate = c
  # Free les UI ajoutees dans MapSettings.
  for ref in [_label_grid_layer_ref, _label_grid_opacity_ref, _z_row_ref, _opacity_row_ref, _export_hbox_ref]:
    if ref != null and is_instance_valid(ref):
      ref.queue_free()
  _label_grid_layer_ref = null
  _label_grid_opacity_ref = null
  _z_row_ref = null
  _opacity_row_ref = null
  _export_hbox_ref = null
  layer_slider_ref = null
  layer_spinbox_ref = null
  opacity_slider_ref = null
  opacity_spinbox_ref = null
  export_slider_ref = null
  export_spinbox_ref = null
  color_picker_ref = null
  color_rect_ref = null
  # Deconnecter le format dropdown si on est encore connectes (le node lui-meme
  # n'est PAS detruit, il appartient a DD - juste deconnecter notre signal).
  if _format_dd_ref != null and is_instance_valid(_format_dd_ref):
    if _format_dd_ref.is_connected("item_selected", self, "_on_export_format_changed"):
      _format_dd_ref.disconnect("item_selected", self, "_on_export_format_changed")
  _format_dd_ref = null
  print("[GF] Cleaned up")


# --- Settings ---

func get_map_key():
  var world = _g.World
  if world == null:
    return null
  var title = world.get("Title")
  if title == null or str(title) == "" or str(title) == "Null":
    return null
  return str(title)


func save_settings():
  var key = get_map_key()
  if key == null or key == "":
    return
  var config = ConfigFile.new()
  config.load(CONFIG_PATH)
  config.set_value(key, "current_z", current_z)
  config.set_value(key, "opacity", current_opacity)
  config.save(CONFIG_PATH)


func load_settings():
  var key = get_map_key()
  if key == null or key == "":
    return
  var config = ConfigFile.new()
  if config.load(CONFIG_PATH) != OK:
    return
  current_z = config.get_value(key, "current_z", DEFAULT_Z)
  current_opacity = config.get_value(key, "opacity", 50)
  _sync_z_ui()
  _sync_opacity_ui()


func _sync_z_ui():
  if layer_slider_ref != null:
    layer_slider_ref.value = current_z
  if layer_spinbox_ref != null:
    layer_spinbox_ref.value = current_z
  if export_slider_ref != null:
    export_slider_ref.value = current_z
  if export_spinbox_ref != null:
    export_spinbox_ref.value = current_z


func _sync_opacity_ui():
  if opacity_slider_ref != null:
    opacity_slider_ref.value = current_opacity
  if opacity_spinbox_ref != null:
    opacity_spinbox_ref.value = current_opacity


# --- Callbacks z ---

var _syncing_z = false

func on_z_reset():
  if _destroyed:
    return
  on_z_changed(DEFAULT_Z)


func on_z_changed(value):
  if _destroyed:
    return
  if _syncing_z:
    return
  _syncing_z = true
  current_z = int(value)
  _sync_z_ui()
  apply_to_current_level()
  if export_grid_copy != null:
    create_export_grid_copy()
  save_settings()
  _syncing_z = false


# --- Callbacks opacity ---

func on_opacity_changed(value):
  if _destroyed:
    return
  if _syncing_opacity:
    return
  _syncing_opacity = true
  current_opacity = int(value)
  _sync_opacity_ui()
  if color_picker_ref != null:
    var c = color_picker_ref.color
    c.a = current_opacity / 100.0
    color_picker_ref.color = c
  var grid = get_grid_node()
  if grid != null:
    var c = grid.self_modulate
    c.a = current_opacity / 100.0
    grid.self_modulate = c
    if color_rect_ref != null:
      color_rect_ref.color = grid.self_modulate
  save_settings()
  _syncing_opacity = false


func on_grid_color_changed(color: Color):
  if _destroyed:
    return
  if _syncing_opacity:
    return
  var new_opacity = int(round(color.a * 100))
  if new_opacity == current_opacity:
    return
  _syncing_opacity = true
  current_opacity = new_opacity
  _sync_opacity_ui()
  var grid = get_grid_node()
  if grid != null:
    grid.self_modulate = color
  save_settings()
  _syncing_opacity = false


func on_color_popup_shown(popup):
  if _destroyed:
    return
  if color_picker_ref != null:
    return
  var cp = popup.find_node("ColorPicker", true, false)
  if cp == null:
    for child in popup.get_children():
      if child.get_class() == "ColorPicker":
        cp = child
        break
  if cp != null:
    print("[GF] ColorPicker found")
    color_picker_ref = cp
    cp.connect("color_changed", self, "on_grid_color_changed")
    # Sync le ColorPicker vers notre opacité courante (pas l'inverse)
    var c = cp.color
    c.a = current_opacity / 100.0
    cp.color = c
  else:
    print("[GF] ColorPicker NOT found in popup")


func on_camera_filter_changed(index: int, source_node = null):
  if _destroyed:
    return
  var filter_text = ""
  if source_node != null:
    filter_text = source_node.get_item_text(index).to_lower()
  else:
    # Fallback : lire depuis Export ou Map Settings
    var export_dialog = _g.Editor.Windows["Export"]
    if export_dialog != null:
      var cam = export_dialog.find_node("CameraFilterOptions", true, false)
      if cam != null:
        filter_text = cam.get_item_text(cam.selected).to_lower()
    if filter_text == "":
      var map_settings_panel = _g.Editor.Toolset.GetToolPanel("MapSettings")
      if map_settings_panel != null:
        var align = map_settings_panel.find_node("Align", true, false)
        if align != null:
          for child in align.get_children():
            if child.get_class() == "Label" and str(child.get("text")) == "CAMERA_FILTER":
              var next_idx = child.get_index() + 1
              if next_idx < align.get_child_count():
                filter_text = align.get_child(next_idx).get_item_text(
                  align.get_child(next_idx).selected).to_lower()
                break

  if "printer" in filter_text:
    pre_printer_opacity = current_opacity
    current_opacity = 100
    _sync_opacity_ui()
    var grid = get_grid_node()
    if grid != null:
      var c = grid.self_modulate
      c.a = 1.0
      grid.self_modulate = c
    if export_grid_copy != null:
      var ec = export_grid_copy.self_modulate
      ec.a = 1.0
      export_grid_copy.self_modulate = ec
  else:
    if pre_printer_opacity != null:
      current_opacity = pre_printer_opacity
      pre_printer_opacity = null
      _sync_opacity_ui()
      var grid = get_grid_node()
      if grid != null:
        var c = grid.self_modulate
        c.a = current_opacity / 100.0
        grid.self_modulate = c
      if export_grid_copy != null:
        var ec = export_grid_copy.self_modulate
        ec.a = current_opacity / 100.0
        export_grid_copy.self_modulate = ec


# --- Export ---
# Create a copy at the right z-index. The original grid is hidden with
# an invisible shader. When the user clicks OK, we intercept the click,
# wait for DD to rebuild the mesh at export PPI, update the copy, then
# trigger the real export.

var _ok_btn_ref = null

func create_export_grid_copy():
  if _destroyed:
    return
  delete_export_grid_copy()

  var grid = get_grid_node()
  if grid == null:
    return

  original_material = grid.material
  var invisible_shader = Shader.new()
  invisible_shader.code = INVISIBLE_SHADER_CODE
  var invisible_mat = ShaderMaterial.new()
  invisible_mat.shader = invisible_shader
  grid.material = invisible_mat

  var copy = MeshInstance2D.new()
  copy.name = "GridExportCopy"
  copy.mesh = grid.mesh
  copy.texture = grid.texture
  copy.material = original_material
  copy.self_modulate = grid.self_modulate
  copy.modulate = grid.modulate
  copy.position = grid.position
  copy.scale = grid.scale

  var level = get_current_level()
  var result = _get_best_parent_and_z(level)
  var best_parent = result[0]
  var z_relative = result[1]
  copy.z_index = z_relative
  copy.z_as_relative = true
  copy.show_on_top = false
  best_parent.add_child(copy)
  export_grid_copy = copy

  var export_dialog = _g.Editor.Windows["Export"]
  if export_dialog != null:
    var grid_check = export_dialog.find_node("GridCheckButton", true, false)
    if grid_check != null and export_grid_copy != null:
      export_grid_copy.visible = grid_check.pressed


func delete_export_grid_copy():
  if _destroyed:
    return
  if original_material != null:
    var grid = get_grid_node()
    if grid != null:
      grid.material = original_material
    original_material = null

  if export_grid_copy != null:
    if export_grid_copy.get_parent() != null:
      export_grid_copy.get_parent().remove_child(export_grid_copy)
    export_grid_copy.queue_free()
    export_grid_copy = null


# On NE touche PAS aux handlers de DD sur OkayButton. On ajoute seulement
# notre propre ecouteur, en plus de ceux de DD. DD gere donc l'export
# normalement (image PNG/JPG/WEBP, UVTT/.dd2vtt, etc.) sans aucun risque
# que le format soit altere. Notre ecouteur se contente de programmer la
# mise a jour de la copie une fois que DD a reconstruit le mesh a la PPI
# d'export (~50 ms apres le clic, avant la capture).
func _connect_ok_listener():
  if _destroyed:
    return
  var export_dialog = _g.Editor.Windows["Export"]
  if export_dialog == null:
    return
  var ok_btn = export_dialog.find_node("OkayButton", true, false)
  if ok_btn == null:
    return
  _ok_btn_ref = ok_btn
  if not ok_btn.is_connected("pressed", self, "_on_ok_pressed"):
    ok_btn.connect("pressed", self, "_on_ok_pressed")


func _disconnect_ok_listener():
  # Pas de guard _destroyed : on veut pouvoir nettoyer notre signal meme
  # pendant un hot-unload. On ne touche que notre propre connexion.
  if _ok_btn_ref == null or not is_instance_valid(_ok_btn_ref):
    _ok_btn_ref = null
    return
  if _ok_btn_ref.is_connected("pressed", self, "_on_ok_pressed"):
    _ok_btn_ref.disconnect("pressed", self, "_on_ok_pressed")
  _ok_btn_ref = null


func _on_ok_pressed():
  if _destroyed:
    return
  # DD effectue l'export. On programme juste la mise a jour de la copie
  # apres que le mesh ait ete reconstruit a la PPI d'export.
  var tree = _g.World.get_tree() if _g.World != null else null
  if tree != null:
    var timer = tree.create_timer(0.05)
    timer.connect("timeout", self, "_post_export_update_copy")


func _post_export_update_copy():
  if _destroyed:
    return
  """Update the export copy mesh from the freshly rebuilt grid."""
  var grid = get_grid_node()
  if grid == null:
    return
  if export_grid_copy != null and is_instance_valid(export_grid_copy):
    export_grid_copy.mesh = grid.mesh
    export_grid_copy.texture = grid.texture
    export_grid_copy.position = grid.position
    export_grid_copy.scale = grid.scale


func on_export_grid_toggled(enabled: bool):
  if _destroyed:
    return
  if export_grid_copy != null:
    export_grid_copy.visible = enabled


func on_export_window_opened():
  if _destroyed:
    return
  apply_to_current_level()
  create_export_grid_copy()
  _connect_ok_listener()
  # Force le resize a l'ouverture : si le format etait deja JPG/WEBP de la
  # session precedente, le quality slider est deja present et la fenetre
  # a sa taille par defaut (trop petite). On differe pour laisser DD
  # construire le layout d'abord.
  call_deferred("_resize_export_window_to_fit")


func on_export_window_closed():
  if _destroyed:
    return
  _disconnect_ok_listener()
  delete_export_grid_copy()
  apply_to_current_level()


# --- Window auto-resize fix ---
# Bug DD : quand l'utilisateur choisit JPG ou WEBP dans la fenetre d'export,
# un slider "Quality" apparait, ce qui pousse tout le contenu vers le bas.
# La fenetre ne se redimensionne pas, donc OkayButton sort du bas de la fenetre.
# Aggrave par nos ajouts UI (Grid Layer row + Export Trace Image button).
# Fix : on intercepte les changements de format et on resize a la taille
# minimale du contenu (VAlign).

func _find_format_dropdown(root):
  # Cherche l'OptionButton contenant des items "PNG", "JPG" ou "WEBP".
  # Plus robuste que find_node par nom (qu'on ne connait pas avec certitude).
  var stack = [root]
  while not stack.empty():
    var node = stack.pop_back()
    if node is OptionButton:
      for i in range(node.get_item_count()):
        var t = node.get_item_text(i).to_lower()
        if "webp" in t or "jpg" in t or "jpeg" in t:
          return node
    for child in node.get_children():
      stack.push_back(child)
  return null


func _on_export_format_changed(_idx):
  if _destroyed:
    return
  # Differe d'une frame pour laisser DD ajouter/retirer le quality slider
  # avant de mesurer la nouvelle hauteur de contenu.
  call_deferred("_resize_export_window_to_fit")


func _resize_export_window_to_fit():
  if _destroyed:
    return
  var export_dialog = _g.Editor.Windows["Export"]
  if export_dialog == null or not is_instance_valid(export_dialog):
    return
  if not export_dialog.visible:
    return
  var valign = export_dialog.find_node("VAlign", true, false)
  if valign == null:
    return
  # Hauteur naturelle du contenu (somme des min sizes + separations).
  var content_min = valign.get_combined_minimum_size()
  # Margins eventuels autour de VAlign (DD utilise un MarginContainer "Margins").
  var pad_v = 0
  var p = valign.get_parent()
  while p != null and p != export_dialog:
    if p is MarginContainer:
      pad_v += p.get_constant("margin_top") + p.get_constant("margin_bottom")
    p = p.get_parent()
  # Chrome de la WindowDialog : titre + bordure haute.
  var title_h = 30
  var needed_h = content_min.y + pad_v + title_h + 8
  # On ne fait que GRANDIR la fenetre - jamais retrecir (evite les sauts
  # quand le format passe de JPG -> PNG : meme si le quality slider disparait,
  # garder la taille evite un effet de yo-yo, et un peu d'espace en bas
  # ne gene personne).
  if export_dialog.rect_size.y < needed_h:
    export_dialog.rect_size = Vector2(export_dialog.rect_size.x, needed_h)
    # Garder la fenetre a l'ecran si elle deborde en bas
    var screen_h = OS.window_size.y
    var bottom = export_dialog.rect_position.y + needed_h
    if bottom > screen_h:
      export_dialog.rect_position.y = max(0, screen_h - needed_h - 10)


func _setup_export_ui(export_dialog):
  var valign = export_dialog.find_node("VAlign", true, false)
  if valign == null:
    return
  var render_options = export_dialog.find_node("RenderOptions", true, false)
  if render_options == null:
    return

  var hbox = HBoxContainer.new()
  hbox.name = "GridLayerRow"

  var lbl = Label.new()
  lbl.text = "Grid Layer"
  hbox.add_child(lbl)

  var slider = HSlider.new()
  slider.min_value = -501
  slider.max_value = 901
  slider.step = 1
  slider.value = current_z
  slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
  slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
  slider.connect("value_changed", self, "on_z_changed")
  hbox.add_child(slider)
  export_slider_ref = slider

  var spinbox = SpinBox.new()
  spinbox.min_value = -501
  spinbox.max_value = 901
  spinbox.step = 1
  spinbox.value = current_z
  spinbox.connect("value_changed", self, "on_z_changed")
  hbox.add_child(spinbox)
  export_spinbox_ref = spinbox

  var reset_btn = _make_reset_button("Reset z-index")
  reset_btn.connect("pressed", self, "on_z_reset")
  hbox.add_child(reset_btn)

  var insert_idx = render_options.get_index() + 1
  valign.add_child(hbox)
  valign.move_child(hbox, insert_idx)
  _export_hbox_ref = hbox

  var camera_filter = export_dialog.find_node("CameraFilterOptions", true, false)
  if camera_filter != null:
    camera_filter.connect("item_selected", self, "on_camera_filter_changed", [camera_filter])

  var grid_check = export_dialog.find_node("GridCheckButton", true, false)
  if grid_check != null:
    grid_check.connect("toggled", self, "on_export_grid_toggled")

  # Detection heuristique du dropdown format (PNG/JPG/WEBP) pour ecouter
  # ses changements et redimensionner la fenetre quand le quality slider
  # apparait. C'est un bug DD : la fenetre ne se resize pas quand le
  # quality slider apparait, donc OkayButton sort de la fenetre (aggrave
  # par nos ajouts UI : Grid Layer + Export Trace Image).
  var format_dd = _find_format_dropdown(export_dialog)
  if format_dd != null:
    _format_dd_ref = format_dd
    if not format_dd.is_connected("item_selected", self, "_on_export_format_changed"):
      format_dd.connect("item_selected", self, "_on_export_format_changed")


# --- update() ---

func update(_delta):
  if _destroyed:
    return
  if _g.World == null or _g.World.levels == null or _g.World.levels.size() == 0:
    return

  var current_world_id = _g.World.get_instance_id()
  if current_world_id != last_world_id:
    last_world_id = current_world_id
    last_level_id = -1
    last_level_count = -1
    map_key_loaded = false

  if not map_key_loaded and get_map_key() != null:
    map_key_loaded = true
    load_settings()
    apply_to_current_level()

  var current_level_id = _g.World.CurrentLevelId
  var current_level_count = _g.World.levels.size()
  var grid = get_grid_node()

  if grid_was_null and grid != null:
    grid_was_null = false
    last_level_id = current_level_id
    last_level_count = current_level_count
    apply_to_current_level()
    return

  if grid == null:
    grid_was_null = true
    last_level_id = current_level_id
    last_level_count = current_level_count
    return

  if current_level_id != last_level_id:
    last_level_id = current_level_id
    last_level_count = current_level_count
    apply_to_current_level()

  elif current_level_count != last_level_count:
    last_level_count = current_level_count
    apply_to_current_level()


# --- initialize() ---

func _connect_level_buttons(node, depth):
  if depth > 12:
    return
  if node.get_class() == "Button":
    var txt = str(node.get("text"))
    if txt == "Delete" or txt == "DELETE":
      var parent = node.get_parent()
      if parent != null:
        for s in parent.get_children():
          if s.get_class() == "Button" and str(s.get("text")) in ["Create", "CREATE"]:
            if not node.is_connected("pressed", self, "park_grid_in_world"):
              node.connect("pressed", self, "park_grid_in_world")
              print("[GF] park connected to Delete level button: " + node.name)
            break
    elif txt == "OK" and depth <= 6:
      var parent = node.get_parent()
      if parent != null:
        for s in parent.get_children():
          if s.get_class() == "Button" and str(s.get("text")) == "Cancel":
            if not node.is_connected("pressed", self, "park_grid_in_world"):
              node.connect("pressed", self, "park_grid_in_world")
              print("[GF] park connected to Warning OK: " + node.name)
            break
  for child in node.get_children():
    _connect_level_buttons(child, depth + 1)


func _load_icon(icon_path: String, scale: float = 1.0) -> ImageTexture:
  var image = Image.new()
  image.load(_g.Root + icon_path)
  if scale != 1.0:
    var new_size = Vector2(image.get_width() * scale, image.get_height() * scale)
    image.resize(int(new_size.x), int(new_size.y), Image.INTERPOLATE_LANCZOS)
  var texture = ImageTexture.new()
  texture.create_from_image(image)
  return texture


func _make_reset_button(tooltip: String) -> Button:
  var btn = Button.new()
  btn.hint_tooltip = tooltip
  btn.icon = _load_icon("icons/reset.png", 0.5)
  return btn


func _make_z_row():
  var row = HBoxContainer.new()

  var slider = HSlider.new()
  slider.min_value = -501
  slider.max_value = 901
  slider.step = 1
  slider.value = current_z
  slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
  slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
  slider.connect("value_changed", self, "on_z_changed")
  row.add_child(slider)

  var spinbox = SpinBox.new()
  spinbox.min_value = -501
  spinbox.max_value = 901
  spinbox.step = 1
  spinbox.value = current_z
  spinbox.connect("value_changed", self, "on_z_changed")
  row.add_child(spinbox)

  var reset_btn = _make_reset_button("Reset z-index")
  reset_btn.connect("pressed", self, "on_z_reset")
  row.add_child(reset_btn)

  return [row, slider, spinbox]


func initialize():
  var map_settings_panel = _g.Editor.Toolset.GetToolPanel("MapSettings")
  if map_settings_panel == null:
    return

  # Label + slider z
  map_settings_panel.CreateLabel("Grid Layer")
  var label = map_settings_panel.Align.get_children()[map_settings_panel.Align.get_child_count() - 1]
  _label_grid_layer_ref = label

  var z_row_data = _make_z_row()
  var z_row = z_row_data[0]
  layer_slider_ref = z_row_data[1]
  layer_spinbox_ref = z_row_data[2]
  map_settings_panel.Align.add_child(z_row)
  _z_row_ref = z_row

  # Label + slider opacité
  map_settings_panel.CreateLabel("Grid Opacity")
  var opacity_label = map_settings_panel.Align.get_children()[map_settings_panel.Align.get_child_count() - 1]
  _label_grid_opacity_ref = opacity_label

  var opacity_row = HBoxContainer.new()
  var slider = HSlider.new()
  slider.min_value = 0
  slider.max_value = 100
  slider.step = 1
  slider.value = current_opacity
  slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
  slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
  slider.connect("value_changed", self, "on_opacity_changed")
  opacity_row.add_child(slider)
  var spinbox = SpinBox.new()
  spinbox.min_value = 0
  spinbox.max_value = 100
  spinbox.step = 1
  spinbox.value = current_opacity
  spinbox.suffix = "%"
  spinbox.connect("value_changed", self, "on_opacity_changed")
  opacity_row.add_child(spinbox)
  map_settings_panel.Align.add_child(opacity_row)
  _opacity_row_ref = opacity_row

  opacity_slider_ref = slider
  opacity_spinbox_ref = spinbox

  map_settings_panel.Align.move_child(label, 0)
  map_settings_panel.Align.move_child(z_row, 1)
  map_settings_panel.Align.move_child(opacity_label, 2)
  map_settings_panel.Align.move_child(opacity_row, 3)

  # Camera Filter + ColorPicker popup dans Map Settings
  var ms_align = map_settings_panel.find_node("Align", true, false)
  if ms_align != null:
    for child in ms_align.get_children():
      if child.get_class() == "Label" and str(child.get("text")) == "CAMERA_FILTER":
        var next_idx = child.get_index() + 1
        if next_idx < ms_align.get_child_count():
          var cam_opt = ms_align.get_child(next_idx)
          if cam_opt.get_class() == "OptionButton":
            cam_opt.connect("item_selected", self, "on_camera_filter_changed", [cam_opt])
      if child.get_class() == "HBoxContainer":
        for hchild in child.get_children():
          if hchild.get_class() == "Button":
            for bchild in hchild.get_children():
              if bchild.get_class() == "ColorRect":
                color_rect_ref = bchild
                for sibling in child.get_children():
                  if sibling.get_class() == "PopupPanel":
                    sibling.connect("about_to_show", self, "on_color_popup_shown", [sibling])
                    print("[GF] Color PopupPanel found and connected")
                    break

  var export_dialog = _g.Editor.Windows["Export"]
  if export_dialog != null:
    export_dialog.connect("about_to_show", self, "on_export_window_opened")
    export_dialog.connect("popup_hide", self, "on_export_window_closed")
    _setup_export_ui(export_dialog)

  var grid = get_grid_node()
  if grid != null and grid.has_signal("_update_callback"):
    grid.connect("_update_callback", self, "apply_to_current_level")

  _connect_level_buttons(_g.Editor, 0)

  last_level_id = _g.World.CurrentLevelId
  last_level_count = _g.World.levels.size()
  load_settings()
  apply_to_current_level()
