# overlay_tool.gd

var _g
var ui_util

const TOOL_CATEGORY = "Settings"
const TOOL_ID       = "overlay_tool"
const TOOL_NAME     = "Overlay Settings"

var _walls_enabled = true
var _paths_enabled = true
var _patterns_enabled = true
var _wall_color    = Color(0.337, 0.737, 0.588)
var _path_color    = Color(0.686, 0.973, 1.0)
var _pattern_color = Color("1c043d")
var _wall_opacity  = 0.8
var _path_opacity  = 0.8
var _pattern_opacity = 1.0
# Patterns : shader PARTAGE (comme murs/paths). opacity = vrai fondu entre la
# couleur d'origine du pattern et la teinte verte (0 = pattern d'origine, 1 =
# pleine teinte), contrairement au shader objet ou opacity = intensite de teinte.
# Modes fixes : walls=Luminosity(0), paths=Luminosity(0)
const WALL_MODE = 0
const PATH_MODE = 0

var _wall_material = null
var _path_material = null

var _hover_wall            = null
var _hover_wall_saved_mats = []
var _hover_path            = null
var _hover_path_saved_mats = []
var _hover_pattern   = null
# Couche verte superposee (vrai blend alpha) sur le pattern survole.
var _pattern_overlay = null
var _portal_dragging       = false
# Cache de survol : tant que la souris monde est immobile, la cible survolee ne
# peut pas changer -> on saute les scans O(n) walls+paths (et de couverture).
var _last_hover_mouse = Vector2.INF
var _last_lmb := false
# Things dont on a masque la box de selection visuelle (Prop.Select(false))
# pendant un drag instant, a restaurer au relachement.
var _box_suppressed := []

var _listener       = null
var _input_listener = null
var _tool_panel     = null
var _bar_button     = null
var _destroyed      = false
# Master toggle (Shift+O / floatbar "Overlays"): coupe walls+paths d'un coup.
# Les flags individuels _walls_enabled/_paths_enabled gardent l'intention
# utilisateur (= memoire du setting precedent), l'etat effectif est leur
# conjonction avec _overlays_on.
var _overlays_on    = true
# Refs UI pour sync apres load
var _wall_toggle    = null
var _path_toggle    = null
var _pattern_toggle = null
var _wall_picker_btn = null
var _path_picker_btn = null
var _pattern_picker_btn = null
var _wall_opacity_slider = null
var _path_opacity_slider = null
var _pattern_opacity_slider = null

# ── Objects & Portals hover highlight (remplace la box jaune du SelectTool) ──
# Hover-only : on teinte l'asset survole dans le SelectTool (objets + portails)
# au lieu de dessiner la box jaune vanilla. Boost d'alpha pour reperer meme un
# asset tres transparent (la silhouette devient opaque dans la couleur choisie).
var _obj_enabled   = true
var _obj_color     = Color(0.843, 0.0, 0.373)  # #d7005f
var _obj_strength  = 1.0   # intensite de la teinte / eclaircissement (0..1)
var _obj_min_alpha = 0.0   # plancher d'opacite des texels non-vides (0..1)
var _obj_opacity   = 0.7   # opacite globale de la surbrillance (0..1)
var _obj_mode      = 1     # 0 = teinte, 1 = eclaircissement (Brighten)
var _obj_material  = null
var _obj_warp_material = null   # variante du highlight objet avec déformation FT (distort/skew/perspective)
var _hover_obj            = null   # le Thing (Node2D) actuellement teinte
var _hover_obj_saved_mats = []     # Array de [canvas_item, material_original]
var _last_obj_mouse       = Vector2.INF   # cache pour le picker en Overlay tool
# Refs UI
var _obj_toggle        = null
var _obj_picker_btn    = null
var _obj_strength_slider = null
var _obj_minalpha_slider = null
var _obj_opacity_slider  = null
var _obj_mode_btn      = null

var path_fix    = null
var wall_fix    = null

const _SAVE_KEY       = "OverlayTool"
const _SETTINGS_FILE  = "user://UnofficialPatch/overlay_tool.json"

# Shader de secours du calque pattern, utilise UNIQUEMENT quand le pattern source
# n'a pas de ShaderMaterial exploitable (pattern uni). Pour les patterns textures,
# on clone le shader de DD et on y injecte le brighten (cf. _inject_brighten) afin
# de rendre le motif EXACTEMENT comme DD, sans avoir a reproduire son pipeline.
const _PATTERN_OVERLAY_FALLBACK_SHADER = """shader_type canvas_item;
uniform vec3  _ov_tint    = vec3(0.11, 0.016, 0.24);
uniform float _ov_opacity = 1.0;
void fragment(){
	vec4 tex = texture(TEXTURE, UV);
	vec3 base = tex.rgb * COLOR.rgb;
	float _l = dot(base, vec3(0.299, 0.587, 0.114));
	float _g = _l - smoothstep(0.6, 1.0, _l) * 0.5;
	vec3 _hi = clamp(vec3(_g) + _ov_tint, 0.0, 1.0);
	COLOR = vec4(mix(base, _hi, _ov_opacity), tex.a);
}
"""


func initialize():
	_create_materials()
	_install_listener()
	_install_input_listener()
	_register_tool_panel()
	_load_settings()
	# Synchroniser path_fix avec notre material des le debut
	if path_fix != null and is_instance_valid(path_fix):
		path_fix._external_highlight_material = _path_material if _effective_paths() else null
	_apply_tints()
	call_deferred("_try_inject_bar_button", 0)
	print("[OverlayTool] Initialized")


func cleanup():
	_destroyed = true
	_clear_object_highlight()
	# Restaurer le contour des assets qu'on avait masques pendant un drag instant.
	var _st = _g.Editor.Tools["SelectTool"] if (_g != null and _g.Editor != null) else null
	_restore_suppressed_boxes(_st)
	if _input_listener != null and is_instance_valid(_input_listener):
		_input_listener.handler = null
		_input_listener.queue_free()
	_input_listener = null
	if _bar_button != null and is_instance_valid(_bar_button):
		_bar_button.queue_free()
	_bar_button = null


# ── Etat effectif (master ET intention individuelle) ──────────────────────

func _effective_walls() -> bool:
	return _overlays_on and _walls_enabled


func _effective_paths() -> bool:
	return _overlays_on and _paths_enabled


func _effective_patterns() -> bool:
	return _overlays_on and _patterns_enabled




func _apply_tints():
	_set_tint(_wall_material, _wall_color)
	_set_tint(_path_material, _path_color)
	_set_mode(_wall_material, WALL_MODE)
	_set_mode(_path_material, PATH_MODE)
	_set_opacity(_wall_material, _wall_opacity)
	_set_opacity(_path_material, _path_opacity)
	if path_fix != null and is_instance_valid(path_fix):
		path_fix._external_highlight_material = _path_material if _effective_paths() else null
	# Synchroniser l'UI avec les valeurs chargees
	if _wall_picker_btn and is_instance_valid(_wall_picker_btn):
		_wall_picker_btn.color = _wall_color
	if _path_picker_btn and is_instance_valid(_path_picker_btn):
		_path_picker_btn.color = _path_color
	if _pattern_picker_btn and is_instance_valid(_pattern_picker_btn):
		_pattern_picker_btn.color = _pattern_color
	if _wall_opacity_slider and is_instance_valid(_wall_opacity_slider):
		_wall_opacity_slider.value = _wall_opacity
	if _path_opacity_slider and is_instance_valid(_path_opacity_slider):
		_path_opacity_slider.value = _path_opacity
	if _pattern_opacity_slider and is_instance_valid(_pattern_opacity_slider):
		_pattern_opacity_slider.value = _pattern_opacity
	if _wall_toggle and is_instance_valid(_wall_toggle):
		_wall_toggle.set_pressed_no_signal(_walls_enabled)
	if _path_toggle and is_instance_valid(_path_toggle):
		_path_toggle.set_pressed_no_signal(_paths_enabled)
	if _pattern_toggle and is_instance_valid(_pattern_toggle):
		_pattern_toggle.set_pressed_no_signal(_patterns_enabled)
	# Objets/portails
	_apply_obj_params()
	if _obj_toggle and is_instance_valid(_obj_toggle):
		_obj_toggle.set_pressed_no_signal(_obj_enabled)
	if _obj_picker_btn and is_instance_valid(_obj_picker_btn):
		_obj_picker_btn.color = _obj_color
	if _obj_strength_slider and is_instance_valid(_obj_strength_slider):
		_obj_strength_slider.value = _obj_strength
	if _obj_minalpha_slider and is_instance_valid(_obj_minalpha_slider):
		_obj_minalpha_slider.value = _obj_min_alpha
	if _obj_opacity_slider and is_instance_valid(_obj_opacity_slider):
		_obj_opacity_slider.value = _obj_opacity
	if _obj_mode_btn and is_instance_valid(_obj_mode_btn):
		_obj_mode_btn.selected = _obj_mode

func _create_materials():
	var shared_shader_code = """shader_type canvas_item;
uniform vec3  tint        = vec3(0.337, 0.737, 0.588);
uniform float opacity     = 0.8;
uniform int   mode        = 0;
void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	// base = couleur reelle du wall (texture * vertex color DD)
	vec3 base = tex.rgb * COLOR.rgb;
	if (tex.a > 0.01) {
		vec3 col;
		float lum = dot(base, vec3(0.299, 0.587, 0.114));
		if (mode == 0) {
			col = tint * (0.5 + lum * 0.5);
		} else if (mode == 1) {
			col = base * tint;
		} else if (mode == 2) {
			col = clamp(base + tint * 0.6, 0.0, 1.0);
		} else if (mode == 3) {
			col = 1.0 - (1.0 - base) * (1.0 - tint);
		} else if (mode == 4) {
			col = mix(2.0 * base * tint,
					1.0 - 2.0 * (1.0 - base) * (1.0 - tint),
					step(0.5, lum));
		} else {
			float tint_lum = dot(tint, vec3(0.299, 0.587, 0.114));
			col = tint_lum > 0.001 ? tint * (lum / tint_lum) : tint;
			col = clamp(col, 0.0, 1.0);
		}
		// opacity : mix entre couleur de base reelle et couleur tintee
		col = mix(base, col, opacity);
		COLOR = vec4(col, min(tex.a + opacity * 0.4, 1.0));
	} else {
		COLOR = tex;
	}
}
"""
	var ws = Shader.new()
	ws.code = shared_shader_code
	_wall_material = ShaderMaterial.new()
	_wall_material.shader = ws

	var ps = Shader.new()
	ps.code = shared_shader_code
	_path_material = ShaderMaterial.new()
	_path_material.shader = ps

	# Shader objets/portails : teinte (mode 0) ou eclaircissement (mode 1) avec
	# boost d'alpha. On ne touche QUE les texels ou la texture a du contenu
	# (tex.a > seuil) pour ne pas remplir la bbox ; on ignore COLOR.a pour le
	# plancher d'alpha afin de reveler un asset place a faible opacite.
	var obj_shader_code = """shader_type canvas_item;
uniform vec3  tint      = vec3(1.0, 0.85, 0.1);
uniform float strength  = 0.6;
uniform float min_alpha = 0.65;
uniform float opacity   = 1.0;
uniform int   mode      = 0;
void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	if (tex.a > 0.02) {
		vec3 base = tex.rgb * COLOR.rgb;
		// On ne garde QUE la luminance de l'asset (son relief), jamais sa teinte
		// (hue) : la couleur de surbrillance vient toujours du choix utilisateur,
		// donc aucune couleur d'asset (ex: rouge) ne peut baver dans le highlight.
		float lum = dot(base, vec3(0.299, 0.587, 0.114));
		vec3 grey = vec3(lum);
		// Couleur de surbrillance pleine (sans hue d'asset).
		vec3 hi;
		if (mode == 0) {
			// teinte : strength = quantite de relief conservee (0 = aplat).
			hi = tint * mix(1.0, 0.35 + lum * 0.65, strength);
		} else {
			// eclaircissement : on part du gris et on ajoute la teinte choisie.
			// Un asset tres clair (lum proche de 1) saturerait en blanc et
			// masquerait la teinte -> on abaisse le gris a haute luminance pour
			// qu'un objet entierement blanc reste colore par la surbrillance.
			float g = lum - smoothstep(0.6, 1.0, lum) * strength * 0.5;
			hi = clamp(vec3(g) + tint * strength, 0.0, 1.0);
		}
		// opacity = intensite de la coloration (gris <-> teinte), couleur only.
		vec3 visible_col = mix(grey, hi, opacity);
		// Partie "revelee" (complement d'alpha jusqu'a min_alpha) : couleur pure
		// choisie, totalement independante de l'asset et des autres reglages.
		float reveal  = max(min_alpha - tex.a, 0.0);
		float total_a = tex.a + reveal;
		vec3 col = (visible_col * tex.a + tint * reveal) / max(total_a, 0.0001);
		COLOR = vec4(col, total_a);
	} else {
		COLOR = vec4(0.0);
	}
}
"""
	var os_ = Shader.new()
	os_.code = obj_shader_code
	_obj_material = ShaderMaterial.new()
	_obj_material.shader = os_

	# Variante « warp » du highlight objet : applique la MÊME déformation que
	# Free Transform (distort / skew / perspective) — mêmes uniformes corner_* /
	# uv_* et même remap de VERTEX que le shader de FT — pour que le highlight
	# épouse la forme transformée. (Le crop, lui, suit déjà car il bake la
	# texture, échantillonnée telle quelle ci-dessous.)
	var obj_warp_code = """shader_type canvas_item;
uniform vec3  tint      = vec3(1.0, 0.85, 0.1);
uniform float strength  = 0.6;
uniform float min_alpha = 0.65;
uniform float opacity   = 1.0;
uniform int   mode      = 0;
uniform vec2 corner_tl;
uniform vec2 corner_tr;
uniform vec2 corner_br;
uniform vec2 corner_bl;
uniform vec2 uv_min = vec2(0.0,0.0);
uniform vec2 uv_max = vec2(1.0,1.0);
varying vec2 v_local;
void vertex(){
	vec2 t=(UV-uv_min)/max(uv_max-uv_min,vec2(0.0001));
	VERTEX=mix(mix(corner_tl,corner_tr,t.x),mix(corner_bl,corner_br,t.x),t.y);
	v_local=VERTEX;
}
float cr(vec2 a,vec2 b){return a.x*b.y-a.y*b.x;}
vec2 warp_uv(vec2 p){
	vec2 a=corner_tl,b=corner_tr,c=corner_br,d=corner_bl;
	vec2 e=b-a,f=d-a,g=a-b+c-d,h=p-a;
	float k2=cr(g,f),k1=cr(e,f)+cr(h,g),k0=cr(h,e);
	float v;
	if(abs(k2)<1e-5){v=-k0/k1;}
	else{
		float sq=sqrt(max(k1*k1-4.0*k0*k2,0.0));
		float v1=(-k1-sq)/(2.0*k2),v2=(-k1+sq)/(2.0*k2);
		v=(v1>=-0.001&&v1<=1.001)?v1:v2;
	}
	vec2 den=e+g*v;
	float u=abs(den.x)>abs(den.y)?(h.x-f.x*v)/den.x:(h.y-f.y*v)/den.y;
	return uv_min+clamp(vec2(u,v),0.0,1.0)*(uv_max-uv_min);
}
void fragment() {
	vec4 tex = texture(TEXTURE, warp_uv(v_local));
	if (tex.a > 0.02) {
		vec3 base = tex.rgb * COLOR.rgb;
		float lum = dot(base, vec3(0.299, 0.587, 0.114));
		vec3 grey = vec3(lum);
		vec3 hi;
		if (mode == 0) {
			hi = tint * mix(1.0, 0.35 + lum * 0.65, strength);
		} else {
			float g = lum - smoothstep(0.6, 1.0, lum) * strength * 0.5;
			hi = clamp(vec3(g) + tint * strength, 0.0, 1.0);
		}
		vec3 visible_col = mix(grey, hi, opacity);
		float reveal  = max(min_alpha - tex.a, 0.0);
		float total_a = tex.a + reveal;
		vec3 col = (visible_col * tex.a + tint * reveal) / max(total_a, 0.0001);
		COLOR = vec4(col, total_a);
	} else {
		COLOR = vec4(0.0);
	}
}
"""
	var ows_ = Shader.new()
	ows_.code = obj_warp_code
	_obj_warp_material = ShaderMaterial.new()
	_obj_warp_material.shader = ows_

	_apply_obj_params()


func _set_tint(mat, c):
	if mat:
		mat.set_shader_param("tint", Vector3(c.r, c.g, c.b))
		if mat == _path_material and path_fix != null and is_instance_valid(path_fix):
			path_fix._external_highlight_material = _path_material


func _set_mode(mat, mode_idx):
	if mat:
		mat.set_shader_param("mode", mode_idx)


func _set_opacity(mat, val):
	if mat:
		mat.set_shader_param("opacity", val)


# ── Objects & Portals hover highlight ─────────────────────────────────────

func _apply_obj_params():
	if _obj_material == null:
		return
	_obj_material.set_shader_param("tint", Vector3(_obj_color.r, _obj_color.g, _obj_color.b))
	_obj_material.set_shader_param("strength", _obj_strength)
	_obj_material.set_shader_param("min_alpha", _obj_min_alpha)
	_obj_material.set_shader_param("opacity", _obj_opacity)
	_obj_material.set_shader_param("mode", _obj_mode)
	if _obj_warp_material != null:
		_obj_warp_material.set_shader_param("tint", Vector3(_obj_color.r, _obj_color.g, _obj_color.b))
		_obj_warp_material.set_shader_param("strength", _obj_strength)
		_obj_warp_material.set_shader_param("min_alpha", _obj_min_alpha)
		_obj_warp_material.set_shader_param("opacity", _obj_opacity)
		_obj_warp_material.set_shader_param("mode", _obj_mode)


# Etat effectif : master Overlays (floatbar/Shift+O) ET toggle de la section.
# Master OFF => on rend la main au hover vanilla (box jaune).
func _effective_objects() -> bool:
	return _overlays_on and _obj_enabled


# Appele en tete de _on_process. Cout negligeable (lecture de highlighted, pas
# de scan O(n)). Remplace la box jaune par une teinte sur l'asset survole.
func _update_object_portal_hover():
	if not _effective_objects():
		_clear_object_highlight()
		return
	if _g == null or _g.Editor == null:
		_clear_object_highlight()
		return
	# Pause pendant pioche couleur / pan / free transform, comme le hover walls/paths.
	if _is_color_picking() or _g.ModMapData.get("_pan_active", false) \
			or _g.ModMapData.get("_ft_hover_block", false):
		_clear_object_highlight()
		return
	# Pendant un drag/transform d'asset (simple ou select+drag) : ne pas teinter
	# l'objet/portail survole sous le curseur, comme pour les patterns.
	if _is_dragging_selection():
		_clear_object_highlight()
		return
	var active = str(_g.Editor.ActiveToolName)
	# Actif dans le SelectTool (DD pilote son propre highlight) ET dans notre
	# Overlay Settings Tool (on pilote le picker de DD nous-memes, comme pour
	# les walls/paths).
	if active != "SelectTool" and active != TOOL_ID:
		_clear_object_highlight()
		return
	# Curseur sur l'UI (panneaux, menus, popups) → ne pas figer la teinte.
	if ui_util and ui_util.is_mouse_over_ui(_listener):
		_clear_object_highlight()
		return
	# Curseur hors du rectangle de la map (zone grise, asset qui deborde).
	if _g.World != null and is_instance_valid(_g.World) and _g.WorldUI != null:
		var rect = _g.World.get("WorldRect")
		if typeof(rect) == TYPE_RECT2 and not rect.has_point(_g.WorldUI.get("MousePosition")):
			_clear_object_highlight()
			return
	# Un path survole et en avant-plan a la priorite : pas de double detection.
	# _hover_path n'est non-nul que si le path n'est PAS couvert par un asset
	# au-dessus (il est donc bien devant l'objet sous le curseur). Dans ce cas on
	# ne teinte pas l'objet du dessous. (Le hover objets tourne chaque frame avant
	# le cache souris, ce garde maintient donc l'etat sans clignotement.)
	if _hover_path != null and is_instance_valid(_hover_path) and _effective_paths():
		_clear_object_highlight()
		return
	# Idem pour un wall survole et en avant-plan (non couvert par un asset au-dessus,
	# cf. _update_wall_hover qui annule best si _is_wall_covered) : le wall est rendu
	# au-dessus, on ne teinte pas l'objet situe dessous.
	if _hover_wall != null and is_instance_valid(_hover_wall) and _effective_walls():
		_clear_object_highlight()
		return
	var st = _g.Editor.Tools["SelectTool"]
	if st == null:
		_clear_object_highlight()
		return
	# Dans l'Overlay tool, le SelectTool n'est pas actif : on declenche son
	# picker manuellement pour que `highlighted` suive le curseur. On ne le fait
	# que sur mouvement souris (HighlightThingAtPoint scanne tous les selectables).
	if active == TOOL_ID and st.has_method("HighlightThingAtPoint"):
		var mp = _g.WorldUI.get("MousePosition") if _g.WorldUI != null else null
		if mp != _last_obj_mouse:
			_last_obj_mouse = mp
			st.HighlightThingAtPoint()
	# highlighted : on passe par get() (acces direct peut crasher avec des lights)
	var h = st.get("highlighted")
	if h == null or typeof(h) != TYPE_OBJECT or not is_instance_valid(h):
		_clear_object_highlight()
		return
	var t = h.get("Type")
	# 2 = PortalFree, 3 = PortalWall, 4 = Object
	if t != 2 and t != 3 and t != 4:
		_clear_object_highlight()
		return
	var thing = h.get("Thing")
	if thing == null or typeof(thing) != TYPE_OBJECT or not is_instance_valid(thing):
		_clear_object_highlight()
		return
	# select_layer_pick_fix : si DD a pioche un objet du dessous, il publie le bon
	# objet a teinter ici (la box trompeuse de DD est deja eteinte de son cote).
	if _g.ModMapData is Dictionary and _g.ModMapData.has("_slpf_true_top"):
		var corrected = _g.ModMapData.get("_slpf_true_top")
		if corrected != null and typeof(corrected) == TYPE_OBJECT and is_instance_valid(corrected):
			thing = corrected
	# Ne pas teinter un asset deja selectionne (DD montre sa transform box).
	var selected = st.get("Selected")
	if selected is Array and selected.has(thing):
		_clear_object_highlight()
		return
	# Nouvelle cible ? On bascule la teinte.
	if thing != _hover_obj:
		_clear_object_highlight()
		_hover_obj = thing
		_apply_object_highlight(thing)
	# Etouffer la box jaune vanilla chaque frame (idempotent). DD la repose au
	# prochain mouvement souris ; on la re-coupe ici.
	if st.has_method("Highlight"):
		st.Highlight(h, false)


func _apply_object_highlight(thing):
	# Pour un objet, on teinte UNIQUEMENT le sprite principal (thing.Sprite).
	# L'ombre vanilla est un Sprite separe (1er enfant du noeud) : la teinter
	# afficherait une copie teintee de l'objet -> on l'exclut.
	var spr = thing.get("Sprite")
	if spr != null and is_instance_valid(spr) and spr is Sprite:
		_tint_node(spr)
		return
	# Portails / cas sans .Sprite : on retombe sur le parcours (en sautant ombres).
	_collect_and_tint(thing)


func _tint_node(node):
	if node == null or not is_instance_valid(node):
		return
	var cur = node.material
	var use_mat = _obj_material
	# Objet déformé par Free Transform (matériau marqué meta "_ft_warp") :
	# on teinte avec la variante warp en recopiant ses coins/UV, pour que le
	# highlight épouse la forme distordue au lieu du quad d'origine.
	if cur is ShaderMaterial and cur.has_meta("_ft_warp") and _obj_warp_material != null:
		for p in ["corner_tl", "corner_tr", "corner_br", "corner_bl", "uv_min", "uv_max"]:
			_obj_warp_material.set_shader_param(p, cur.get_shader_param(p))
		use_mat = _obj_warp_material
	_hover_obj_saved_mats.append([node, cur])
	node.material = use_mat


func _collect_and_tint(node):
	if node == null or not is_instance_valid(node):
		return
	# Teinter les CanvasItem porteurs de texture (Sprite), en sautant les ombres.
	if node is Sprite:
		var nm = String(node.name).to_lower()
		if not ("shadow" in nm):
			_tint_node(node)
	for child in node.get_children():
		# Pas de teinte sur les lumieres/occluders ; on suit l'arbre Node2D.
		if child is Light2D or child is LightOccluder2D:
			continue
		_collect_and_tint(child)


func _clear_object_highlight():
	for entry in _hover_obj_saved_mats:
		if is_instance_valid(entry[0]):
			if entry[0].material == _obj_material or entry[0].material == _obj_warp_material or entry[0].material == null:
				entry[0].material = entry[1]
	_hover_obj_saved_mats = []
	_hover_obj = null


func _install_listener():
	_listener = Node.new()
	_listener.name = "OverlayToolListener"
	var s = GDScript.new()
	s.source_code = "extends Node\nvar handler = null\nfunc _process(delta):\n\tif handler != null:\n\t\thandler._on_process(delta)\n"
	s.reload()
	_listener.set_script(s)
	_listener.handler = self
	if _g.World and _g.World is Node:
		_g.World.call_deferred("add_child", _listener)


func _register_tool_panel():
	if not _g.Editor or not _g.Editor.Toolset:
		return
	var icon_path = _g.Root + "icons/overlay_button.png"
	_tool_panel = _g.Editor.Toolset.CreateModTool(
		self, TOOL_CATEGORY, TOOL_ID, TOOL_NAME, icon_path)
	if _tool_panel == null:
		push_error("[OverlayTool] CreateModTool failed")
		return

	_tool_panel.BeginSection(false)

	_wall_toggle = _make_section_row("-- WALLS --", _walls_enabled, "_on_wall_reset", "_on_walls_toggled")
	_tool_panel.Align.add_child(_with_right_margin(_make_color_picker(_wall_color, "wall")))
	_tool_panel.Align.add_child(_with_right_margin(_make_opacity_slider(_wall_opacity, "wall")))

	_tool_panel.CreateSeparator()

	_path_toggle = _make_section_row("-- PATHS --", _paths_enabled, "_on_path_reset", "_on_paths_toggled")
	_tool_panel.Align.add_child(_with_right_margin(_make_color_picker(_path_color, "path")))
	_tool_panel.Align.add_child(_with_right_margin(_make_opacity_slider(_path_opacity, "path")))

	_tool_panel.CreateSeparator()

	_pattern_toggle = _make_section_row("-- PATTERNS --", _patterns_enabled, "_on_pattern_reset", "_on_patterns_toggled")
	_tool_panel.Align.add_child(_with_right_margin(_make_color_picker(_pattern_color, "pattern")))
	_tool_panel.Align.add_child(_with_right_margin(_make_opacity_slider(_pattern_opacity, "pattern")))

	_tool_panel.CreateSeparator()

	_obj_toggle = _make_section_row("-- OBJECTS & PORTALS --", _obj_enabled, "_on_obj_reset", "_on_obj_toggled")
	_tool_panel.Align.add_child(_with_right_margin(_make_obj_color_picker()))
	_tool_panel.Align.add_child(_with_right_margin(_make_obj_opacity_row()))

	_tool_panel.CreateSeparator()
	_tool_panel.CreateNote("Hover highlight is active on this tool and the Select Tool.")
	_tool_panel.EndSection()


func _make_obj_color_picker():
	var row = HBoxContainer.new()
	var lbl = Label.new()
	lbl.text = "Color"
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)
	var panel = PanelContainer.new()
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0)
	style.border_color = Color(1, 1, 1, 0.8)
	style.set_border_width_all(1)
	panel.add_stylebox_override("panel", style)
	var picker = ColorPickerButton.new()
	picker.color = _obj_color
	picker.rect_min_size = Vector2(60, 22)
	picker.flat = true
	picker.connect("color_changed", self, "_on_obj_color_changed")
	picker.connect("pressed", self, "_on_picker_pressed", [picker])
	_obj_picker_btn = picker
	panel.add_child(picker)
	row.add_child(panel)
	return row


func _make_obj_mode_row():
	var row = HBoxContainer.new()
	var lbl = Label.new()
	lbl.text = "Style"
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)
	var btn = OptionButton.new()
	btn.add_item("Tint", 0)
	btn.add_item("Brighten", 1)
	btn.selected = _obj_mode
	btn.connect("item_selected", self, "_on_obj_mode_changed")
	_obj_mode_btn = btn
	row.add_child(btn)
	return row


func _make_obj_strength_row():
	var row = HBoxContainer.new()
	var lbl = Label.new()
	lbl.text = "Strength"
	lbl.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	row.add_child(lbl)
	var slider = HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.01
	slider.value = _obj_strength
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.connect("value_changed", self, "_on_obj_strength_changed")
	_obj_strength_slider = slider
	row.add_child(slider)
	return row


func _make_obj_minalpha_row():
	var row = HBoxContainer.new()
	var lbl = Label.new()
	lbl.text = "Min visibility"
	lbl.hint_tooltip = "Plancher d'opacite : plus haut = assets transparents plus visibles."
	lbl.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	row.add_child(lbl)
	var slider = HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.01
	slider.value = _obj_min_alpha
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.connect("value_changed", self, "_on_obj_minalpha_changed")
	_obj_minalpha_slider = slider
	row.add_child(slider)
	return row


func _make_obj_opacity_row():
	var row = HBoxContainer.new()
	var lbl = Label.new()
	lbl.text = "Opacity"
	lbl.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	row.add_child(lbl)
	var slider = HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.01
	slider.value = _obj_opacity
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.connect("value_changed", self, "_on_obj_opacity_changed")
	_obj_opacity_slider = slider
	row.add_child(slider)
	return row


func _on_obj_opacity_changed(val):
	_obj_opacity = val
	_apply_obj_params()
	_save_settings()


func _on_obj_toggled(pressed):
	_obj_enabled = pressed
	if not pressed:
		_clear_object_highlight()
	_save_settings()


func _on_obj_color_changed(color):
	_obj_color = color
	_apply_obj_params()
	_save_settings()


func _on_obj_mode_changed(idx):
	_obj_mode = idx
	_apply_obj_params()
	_save_settings()


func _on_obj_strength_changed(val):
	_obj_strength = val
	_apply_obj_params()
	_save_settings()


func _on_obj_minalpha_changed(val):
	_obj_min_alpha = val
	_apply_obj_params()
	_save_settings()


func _on_obj_reset():
	_obj_enabled   = true
	_obj_color     = Color(1.0, 0.85, 0.1)
	_obj_strength  = 0.6
	_obj_min_alpha = 0.65
	_obj_opacity   = 1.0
	_obj_mode      = 0
	_apply_obj_params()
	_clear_object_highlight()
	if _obj_toggle and is_instance_valid(_obj_toggle):
		_obj_toggle.set_pressed_no_signal(_obj_enabled)
	if _obj_picker_btn and is_instance_valid(_obj_picker_btn):
		_obj_picker_btn.color = _obj_color
	if _obj_strength_slider and is_instance_valid(_obj_strength_slider):
		_obj_strength_slider.value = _obj_strength
	if _obj_minalpha_slider and is_instance_valid(_obj_minalpha_slider):
		_obj_minalpha_slider.value = _obj_min_alpha
	if _obj_opacity_slider and is_instance_valid(_obj_opacity_slider):
		_obj_opacity_slider.value = _obj_opacity
	if _obj_mode_btn and is_instance_valid(_obj_mode_btn):
		_obj_mode_btn.selected = _obj_mode
	_save_settings()


func _make_color_picker(color, which):
	var row = HBoxContainer.new()
	var lbl = Label.new()
	lbl.text = "Color"
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)
	var panel = PanelContainer.new()
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0)
	style.border_color = Color(1, 1, 1, 0.8)
	style.set_border_width_all(1)
	panel.add_stylebox_override("panel", style)
	var picker = ColorPickerButton.new()
	picker.color = color
	picker.rect_min_size = Vector2(60, 22)
	picker.flat = true
	if which == "wall":
		picker.connect("color_changed", self, "_on_wall_color_changed")
		_wall_picker_btn = picker
	elif which == "pattern":
		picker.connect("color_changed", self, "_on_pattern_color_changed")
		_pattern_picker_btn = picker
	else:
		picker.connect("color_changed", self, "_on_path_color_changed")
		_path_picker_btn = picker
	picker.connect("pressed", self, "_on_picker_pressed", [picker])
	panel.add_child(picker)
	row.add_child(panel)
	return row


func _make_opacity_slider(current_val, which):
	var row = HBoxContainer.new()
	var lbl = Label.new()
	lbl.text = "Opacity"
	lbl.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	row.add_child(lbl)
	var slider = HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.01
	slider.value = current_val
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if which == "wall":
		slider.connect("value_changed", self, "_on_wall_opacity_changed")
		_wall_opacity_slider = slider
	elif which == "pattern":
		slider.connect("value_changed", self, "_on_pattern_opacity_changed")
		_pattern_opacity_slider = slider
	else:
		slider.connect("value_changed", self, "_on_path_opacity_changed")
		_path_opacity_slider = slider
	row.add_child(slider)
	return row


func _on_wall_opacity_changed(val):
	_wall_opacity = val
	_set_opacity(_wall_material, val)
	_save_settings()


func _on_path_opacity_changed(val):
	_path_opacity = val
	_set_opacity(_path_material, val)
	_save_settings()


func _on_pattern_opacity_changed(val):
	_pattern_opacity = val
	if _pattern_overlay != null and is_instance_valid(_pattern_overlay) and _pattern_overlay.get_parent() != null:
		_update_pattern_overlay_params()
	_save_settings()


func _load_icon(icon_path):
	var image = Image.new()
	image.load(_g.Root + icon_path)
	var texture = ImageTexture.new()
	texture.create_from_image(image)
	return texture


func _make_reset_button(tooltip):
	var btn = Button.new()
	btn.hint_tooltip = tooltip
	# Redimensionner reellement l'image a 16px (fiable, contrairement a
	# expand_icon/rect_scale qui rendaient l'icone invisible ou trop grande).
	var image = Image.new()
	image.load(_g.Root + "icons/reset.png")
	image.resize(16, 16, Image.INTERPOLATE_LANCZOS)
	var tex = ImageTexture.new()
	tex.create_from_image(image)
	btn.icon = tex
	btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return btn


# Enveloppe un controle dans un MarginContainer avec une marge a droite, pour que
# l'UI ne soit pas collee au bord du panneau (Align est un VBoxContainer, donc
# pas de marge native possible).
# Ligne d'entete d'une section : [label (expand) | reset | pastille ON/OFF].
# Le reset se place ainsi ENTRE le label et le toggle ON/OFF. Renvoie le
# CheckButton (sans texte, juste la pastille) pour le stocker.
func _make_section_row(title, pressed, reset_handler, toggle_handler):
	var row = HBoxContainer.new()
	var lbl = Label.new()
	lbl.text = title
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(lbl)
	var reset = _make_reset_button("Reset " + title + " settings")
	reset.connect("pressed", self, reset_handler)
	row.add_child(reset)
	var toggle = CheckButton.new()
	toggle.pressed = pressed
	toggle.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	toggle.connect("toggled", self, toggle_handler)
	row.add_child(toggle)
	_tool_panel.Align.add_child(_with_right_margin(row))
	return toggle


func _with_right_margin(ctrl):
	var mc = MarginContainer.new()
	# Forcer les autres marges a 0 : le theme de DD applique sinon des marges
	# verticales qui ecartent les lignes.
	mc.add_constant_override("margin_left", 0)
	mc.add_constant_override("margin_top", 0)
	mc.add_constant_override("margin_bottom", 0)
	mc.add_constant_override("margin_right", 8)
	mc.add_child(ctrl)
	return mc


func _on_wall_reset():
	_wall_color   = Color(0.337, 0.737, 0.588)
	_wall_opacity = 0.8
	_walls_enabled = true
	_set_tint(_wall_material, _wall_color)
	_set_opacity(_wall_material, _wall_opacity)
	if _wall_picker_btn and is_instance_valid(_wall_picker_btn):
		_wall_picker_btn.color = _wall_color
	if _wall_opacity_slider and is_instance_valid(_wall_opacity_slider):
		_wall_opacity_slider.value = _wall_opacity
	if _wall_toggle and is_instance_valid(_wall_toggle):
		_wall_toggle.pressed = true
	_save_settings()


func _on_path_reset():
	_path_color   = Color(0.686, 0.973, 1.0)
	_path_opacity = 0.8
	_paths_enabled = true
	_set_tint(_path_material, _path_color)
	_set_opacity(_path_material, _path_opacity)
	if _path_picker_btn and is_instance_valid(_path_picker_btn):
		_path_picker_btn.color = _path_color
	if _path_opacity_slider and is_instance_valid(_path_opacity_slider):
		_path_opacity_slider.value = _path_opacity
	if _path_toggle and is_instance_valid(_path_toggle):
		_path_toggle.pressed = true
	if path_fix != null and is_instance_valid(path_fix):
		path_fix._external_highlight_material = _path_material
	_save_settings()


func _on_pattern_reset():
	_pattern_color   = Color("1c043d")
	_pattern_opacity = 1.0
	_patterns_enabled = true
	if _pattern_picker_btn and is_instance_valid(_pattern_picker_btn):
		_pattern_picker_btn.color = _pattern_color
	if _pattern_opacity_slider and is_instance_valid(_pattern_opacity_slider):
		_pattern_opacity_slider.value = _pattern_opacity
	if _pattern_toggle and is_instance_valid(_pattern_toggle):
		_pattern_toggle.pressed = true
	if _pattern_overlay != null and is_instance_valid(_pattern_overlay) and _pattern_overlay.get_parent() != null:
		_update_pattern_overlay_params()
	_save_settings()


func _on_picker_pressed(picker):
	var t = _g.World.get_tree().create_timer(0.05)
	t.connect("timeout", self, "_hide_eyedropper", [picker])


func _hide_eyedropper(picker):
	if not is_instance_valid(picker):
		return
	var cp = picker.get_picker()
	if cp == null:
		return
	_hide_in(cp)


func _hide_in(node):
	for child in node.get_children():
		if child is ToolButton or child is Button:
			var tt = child.hint_tooltip.to_lower()
			if "pick" in tt or "eyedrop" in tt:
				child.visible = false
		_hide_in(child)


func _on_wall_color_changed(color):
	_wall_color = color
	_set_tint(_wall_material, color)
	_save_settings()


func _on_path_color_changed(color):
	_path_color = color
	_set_tint(_path_material, color)
	# Synchroniser avec path_fix pour le highlight dans le SelectTool
	if path_fix != null and is_instance_valid(path_fix):
		path_fix._external_highlight_material = _path_material
	_save_settings()


func _on_pattern_color_changed(color):
	_pattern_color = color
	if _pattern_overlay != null and is_instance_valid(_pattern_overlay) and _pattern_overlay.get_parent() != null:
		_update_pattern_overlay_params()
	_save_settings()


func _on_walls_toggled(pressed):
	_walls_enabled = pressed
	# Dans les deux cas, clear complet pour forcer re-detection propre
	for entry in _hover_wall_saved_mats:
		if is_instance_valid(entry[0]):
			if entry[0].material == _wall_material or entry[0].material == null:
				entry[0].material = entry[1]
	_hover_wall_saved_mats = []
	_hover_wall = null
	_save_settings()


func _on_paths_toggled(pressed):
	_paths_enabled = pressed
	_clear_path_highlight()
	# Activer/desactiver le highlight dans le SelectTool (path_fix)
	if path_fix != null and is_instance_valid(path_fix):
		path_fix._external_highlight_material = _path_material if _effective_paths() else null
	_save_settings()


func _on_patterns_toggled(pressed):
	_patterns_enabled = pressed
	_clear_pattern_highlight()
	_save_settings()


func _save_settings():
	var data = {
		"walls_enabled": _walls_enabled,
		"paths_enabled": _paths_enabled,
		"patterns_enabled": _patterns_enabled,
		"overlays_on": _overlays_on,
		"wall_color": [_wall_color.r, _wall_color.g, _wall_color.b],
		"path_color": [_path_color.r, _path_color.g, _path_color.b],
		"wall_opacity": _wall_opacity,
		"path_opacity": _path_opacity,
		"pattern_color": [_pattern_color.r, _pattern_color.g, _pattern_color.b],
		"pattern_opacity": _pattern_opacity,
		"obj_enabled": _obj_enabled,
		"obj_color": [_obj_color.r, _obj_color.g, _obj_color.b],
		"obj_strength": _obj_strength,
		"obj_min_alpha": _obj_min_alpha,
		"obj_opacity": _obj_opacity,
		"obj_mode": _obj_mode,
	}
	# Sauvegarder dans la map
	if _g.ModMapData:
		_g.ModMapData[_SAVE_KEY] = data
	# Sauvegarder globalement pour persister entre maps et sessions
	var dir = Directory.new()
	if not dir.dir_exists("user://UnofficialPatch"):
		dir.make_dir("user://UnofficialPatch")
	var f = File.new()
	if f.open(_SETTINGS_FILE, File.WRITE) == OK:
		f.store_string(JSON.print(data))
		f.close()


func _load_settings():
	# Priorite : fichier global (persiste entre sessions)
	var d = _load_global_settings()
	# Fallback : ModMapData (specifique a la map)
	if d == null and _g.ModMapData and _g.ModMapData.has(_SAVE_KEY):
		d = _g.ModMapData[_SAVE_KEY]
	if d == null or not d is Dictionary:
		return
	if d.has("walls_enabled"):
		_walls_enabled = bool(d["walls_enabled"])
	if d.has("paths_enabled"):
		_paths_enabled = bool(d["paths_enabled"])
	if d.has("patterns_enabled"):
		_patterns_enabled = bool(d["patterns_enabled"])
	if d.has("overlays_on"):
		_overlays_on = bool(d["overlays_on"])
	if d.has("wall_color") and d["wall_color"] is Array and d["wall_color"].size() == 3:
		_wall_color = Color(d["wall_color"][0], d["wall_color"][1], d["wall_color"][2])
		_set_tint(_wall_material, _wall_color)
	if d.has("path_color") and d["path_color"] is Array and d["path_color"].size() == 3:
		_path_color = Color(d["path_color"][0], d["path_color"][1], d["path_color"][2])
		_set_tint(_path_material, _path_color)
	if d.has("wall_opacity"):
		_wall_opacity = float(d["wall_opacity"])
		_set_opacity(_wall_material, _wall_opacity)
	if d.has("path_opacity"):
		_path_opacity = float(d["path_opacity"])
		_set_opacity(_path_material, _path_opacity)
	if d.has("pattern_color") and d["pattern_color"] is Array and d["pattern_color"].size() == 3:
		_pattern_color = Color(d["pattern_color"][0], d["pattern_color"][1], d["pattern_color"][2])
	if d.has("pattern_opacity"):
		_pattern_opacity = float(d["pattern_opacity"])
	if d.has("obj_enabled"):
		_obj_enabled = bool(d["obj_enabled"])
	if d.has("obj_color") and d["obj_color"] is Array and d["obj_color"].size() == 3:
		_obj_color = Color(d["obj_color"][0], d["obj_color"][1], d["obj_color"][2])
	if d.has("obj_strength"):
		_obj_strength = float(d["obj_strength"])
	if d.has("obj_min_alpha"):
		_obj_min_alpha = float(d["obj_min_alpha"])
	if d.has("obj_opacity"):
		_obj_opacity = float(d["obj_opacity"])
	if d.has("obj_mode"):
		_obj_mode = int(d["obj_mode"])
	_apply_obj_params()


func _load_global_settings():
	var f = File.new()
	if f.open(_SETTINGS_FILE, File.READ) != OK:
		return null
	var text = f.get_as_text()
	f.close()
	var parsed = JSON.parse(text)
	if parsed.error != OK:
		return null
	return parsed.result


var _last_active_tool = ""

# Vrai tant qu'un ColorPicker Godot est ouvert (popup visible) — couvre la
# pioche du picker natif DD et celle des mods tiers (Colour and Modify Things).
func _is_color_picking() -> bool:
	if _listener == null or not is_instance_valid(_listener):
		return false
	var tree = _listener.get_tree()
	if tree == null or tree.root == null:
		return false
	# Un ColorPicker n'est visible que dans un popup ouvert. Si aucun popup n'est
	# visible (cas courant a chaque frame), on evite de parcourir tout l'arbre UI
	# -> sortie immediate. ui_util met ce test en cache par frame (partage entre
	# tous les appelants), donc c'est quasi gratuit.
	if ui_util != null and ui_util.has_method("_cached_has_visible_popup"):
		if not ui_util._cached_has_visible_popup(tree):
			return false
	return _find_visible_colorpicker(tree.root)


func _find_visible_colorpicker(node) -> bool:
	if node is ColorPicker and node.is_visible_in_tree():
		return true
	for child in node.get_children():
		# Elague la branche Node2D (carte/objets) : aucun ColorPicker n'y vit.
		if child is Node2D:
			continue
		if _find_visible_colorpicker(child):
			return true
	return false


func _on_process(_delta):
	if not _g.Editor:
		return
	# Hover objets/portails (remplace la box jaune). Independant du master Shift+O
	# et de la logique walls/paths : on le traite en tete, avant les early-returns.
	_update_object_portal_hover()
	# Masquer la box de transform pendant un drag instant (avant les early-returns
	# pour que la restauration au relachement passe toujours).
	_update_drag_box_hide()
	# Free Transform en édition : on coupe aussi les overlays murs/paths.
	if _g.ModMapData.get("_ft_hover_block", false):
		_clear_wall_highlight()
		_clear_path_highlight()
		_clear_pattern_highlight()
		return
	# Pioche couleur active (picker DD natif ou mod tiers) → pas de hover
	# overlay sur les murs ni les paths, sinon ça parasite la pioche.
	if _is_color_picking():
		_clear_wall_highlight()
		_clear_path_highlight()
		_clear_pattern_highlight()
		return
	# Skip hover scans pendant un pan (flag posé par pan_fix). Les scans
	# walls/paths sont O(n) par frame et sont la cause principale du lag
	# de pan sur les maps chargées.
	if _g.ModMapData.get("_pan_active", false):
		return
	# Resync path_fix si son external material a ete perdu (ex: reload map)
	if path_fix != null and is_instance_valid(path_fix):
		var want_mat = _path_material if _effective_paths() else null
		if path_fix._external_highlight_material != want_mat:
			path_fix._external_highlight_material = want_mat
	var active = _g.Editor.ActiveToolName
	if active != _last_active_tool:
		_last_hover_mouse = Vector2.INF
	# Nettoyer quand on quitte vers un outil non-highlight
	if active != TOOL_ID and active != "SelectTool":
		_clear_wall_highlight()
		_clear_path_highlight()
		_clear_pattern_highlight()
		_last_active_tool = active
		return
	_last_active_tool = active
	if not _g.World or not is_instance_valid(_g.World):
		_clear_wall_highlight()
		_clear_path_highlight()
		_clear_pattern_highlight()
		return
	if ui_util and ui_util.is_mouse_over_ui(_listener):
		_clear_wall_highlight()
		_clear_path_highlight()
		_clear_pattern_highlight()
		return
	var mouse_world = _g.WorldUI.get("MousePosition")
	if mouse_world == null:
		return

	# Track portal dragging: if LMB pressed on a portal, block wall hover
	# until LMB is released
	var lmb_down = Input.is_mouse_button_pressed(BUTTON_LEFT)
	# Un changement d'etat du bouton (clic/relache) doit rafraichir le survol
	# meme si la souris n'a pas bouge (ex: selection au clic).
	if lmb_down != _last_lmb:
		_last_hover_mouse = Vector2.INF
		_last_lmb = lmb_down
	if not lmb_down:
		_portal_dragging = false
	elif lmb_down and not _portal_dragging:
		# Check if mouse just pressed on a portal
		if _hover_wall != null and is_instance_valid(_hover_wall):
			if _is_mouse_on_portal(_hover_wall, mouse_world):
				_portal_dragging = true
				_clear_wall_highlight()
		# Also check all walls in current level
		if not _portal_dragging:
			var level_check = _g.World.GetCurrentLevel()
			if level_check != null:
				var walls_check = level_check.get("Walls")
				if walls_check != null:
					for w in walls_check.get_children():
						if _is_mouse_on_portal(w, mouse_world):
							_portal_dragging = true
							_clear_wall_highlight()
							break

	var level = _g.World.GetCurrentLevel()
	if level == null:
		_clear_wall_highlight()
		_clear_path_highlight()
		_clear_pattern_highlight()
		return

	# Masquer la ligne pointillee native de DD (WallWidget/PathwayWidget) sur le
	# wall/path survole tant que l'overlay est actif. DD peut la reposer a chaque
	# frame, donc on le fait AVANT l'early-return d'immobilite (sinon elle
	# reapparait sur un survol statique).
	if _effective_walls():
		_hide_native_widget(_hover_wall)
	if _effective_paths():
		# Robuste : on ne se fie PAS a _hover_path. DD et l'overlay peuvent
		# designer des paths differents (chevauchement, hit-test divergent sur
		# les paths a epaisseur / plats), donc on masque directement TOUT widget
		# de path surligne-mais-non-selectionne, quel que soit celui choisi par DD.
		_suppress_native_path_widgets(level)
	if _effective_patterns():
		# Idem patterns : on masque tout PatternShapeWidget surligne-non-selectionne.
		_suppress_native_pattern_widgets(level)

	# Pendant un drag/transform d'asset : couper l'overlay vert des patterns chaque
	# frame (avant l'early-return d'immobilite, sinon il persisterait au demarrage
	# du drag si la souris ne bouge pas encore).
	if _is_dragging_selection():
		_clear_pattern_highlight()

	# Souris immobile : la cible de survol ne peut pas changer (scene statique).
	# On evite ainsi les scans walls+paths a chaque frame d'immobilite.
	if mouse_world == _last_hover_mouse:
		return
	_last_hover_mouse = mouse_world

	# Don't update wall hover while dragging a portal or while free transform
	# is active on a selected portal
	if _portal_dragging or _is_ft_on_portal():
		_clear_wall_highlight()
	else:
		_update_wall_hover(level, mouse_world)
	_update_path_hover(level, mouse_world)
	_update_pattern_hover(level, mouse_world)


# Cache des bbox de murs. Les Wall n'exposent pas de GlobalRect : on borne via
# leur tableau Points (deja en coordonnees monde). Rafraichi periodiquement pour
# suivre les editions. Permet de culler les murs loin du curseur sans relire
# leurs Points C# a chaque frame.
var _wall_aabb := {}
var _wall_aabb_frame := -10000
const _WALL_AABB_TTL := 20


func _wall_aabb_for(wall) -> Rect2:
	var f = Engine.get_frames_drawn()
	if f - _wall_aabb_frame > _WALL_AABB_TTL:
		_wall_aabb_frame = f
		_wall_aabb.clear()
	var id = wall.get_instance_id()
	if _wall_aabb.has(id):
		return _wall_aabb[id]
	var r = Rect2()
	var pts = wall.get("Points")
	if pts != null and pts.size() > 0:
		var minp = pts[0]
		var maxp = pts[0]
		for p in pts:
			if p.x < minp.x: minp.x = p.x
			if p.y < minp.y: minp.y = p.y
			if p.x > maxp.x: maxp.x = p.x
			if p.y > maxp.y: maxp.y = p.y
		r = Rect2(minp, maxp - minp)
	_wall_aabb[id] = r
	return r


func _wall_aabb_miss(wall, mouse_world: Vector2, margin: float) -> bool:
	var r = _wall_aabb_for(wall)
	if r.size.x > 0.0 or r.size.y > 0.0:
		return not r.grow(margin).has_point(mouse_world)
	return false


func _aabb_miss(node, mouse_world: Vector2, margin: float) -> bool:
	# Vrai uniquement si on peut PROUVER que le curseur est hors de la bbox
	# monde (+ marge) -> on saute le test exact (lecture Points / IsMouseWithin).
	# Si pas de GlobalRect fiable, on ne culle pas (comportement inchange).
	var r = node.get("GlobalRect")
	if r is Rect2 and (r.size.x > 0.0 or r.size.y > 0.0):
		return not r.grow(margin).has_point(mouse_world)
	return false


func _is_mouse_on_wall(wall, mouse_world: Vector2) -> bool:
	# Les Points C# sont deja en coordonnees monde (global_position = 0,0)
	var pts = wall.get("Points")
	if pts == null or pts.size() < 2:
		return false
	# Trouver la largeur du wall via son Line2D principal
	var half_w = 40.0  # fallback
	for child in wall.get_children():
		if child is Line2D and child.points.size() >= 2:
			if child.width * 0.5 > half_w or half_w == 40.0:
				half_w = child.width * 0.5
	var is_loop = wall.call("get_Loop") == true if wall.has_method("get_Loop") else false
	return _is_mouse_near_polyline(pts, mouse_world, half_w, is_loop)


func _is_mouse_near_polyline(pts, mouse_world: Vector2, half_w: float, loop: bool = false) -> bool:
	var seg_count = pts.size() - 1
	if loop: seg_count = pts.size()  # segment supplementaire ferme la boucle
	for i in range(seg_count):
		var a = pts[i]
		var b = pts[(i + 1) % pts.size()]
		var ab = b - a
		var len_sq = ab.length_squared()
		var t = 0.0
		if len_sq > 0.001:
			t = clamp((mouse_world - a).dot(ab) / len_sq, 0.0, 1.0)
		var proj = a + ab * t
		if mouse_world.distance_to(proj) <= half_w:
			return true
	return false


func _update_wall_hover(level, mouse_world):
	# Respecter le filter du SelectTool quand il est actif
	if _g.Editor.ActiveToolName == "SelectTool":
		var st = _g.Editor.Tools["SelectTool"]
		var filter = st.get("Filter") if st != null else null
		if filter is Dictionary and not bool(filter.get("Walls", true)):
			_clear_wall_highlight()
			return
	# Ne pas interferer si path_fix est en train de dragger
	if path_fix != null and is_instance_valid(path_fix):
		if path_fix._is_dragging() or (path_fix._left_pressed and path_fix._drag_threshold_passed):
			_clear_wall_highlight()
			return
	var walls = level.get("Walls")
	if walls == null:
		_clear_wall_highlight()
		return
	var best = null
	for child in walls.get_children():
		# Skip cave walls (Type 2) — they are generated by CaveMesh,
		# not user-drawn, and should not receive the overlay highlight.
		var wtype = child.get("Type")
		if wtype != null and int(wtype) == 2:
			continue
		if _wall_aabb_miss(child, mouse_world, 96.0):
			continue
		if _is_mouse_on_wall(child, mouse_world):
			# Don't highlight wall if mouse is on one of its portals
			if _is_mouse_on_portal(child, mouse_world):
				continue
			best = child
			break
	# Ne pas surligner le wall (ni l'exposer comme hover) s'il est couvert par
	# un asset rendu au-dessus : laisser DD gerer le survol/selection de l'asset.
	if best != null and path_fix != null and is_instance_valid(path_fix) \
	and path_fix.has_method("_is_wall_covered") and path_fix._is_wall_covered(best):
		best = null
	# Toujours mettre a jour _hover_wall (wall_move en a besoin meme si disabled)
	if best != null:
		if best != _hover_wall:
			_clear_wall_highlight()
			_hover_wall = best
			if _effective_walls():
				# Le 1er enfant Line2D est le WallWidget natif (ligne pointillee de
				# survol DD) : on ne le tinte pas et on le masque a la place.
				var wwidget = _get_native_widget(best)
				for sub in best.get_children():
					if sub is Line2D and sub != wwidget:
						_hover_wall_saved_mats.append([sub, sub.material])
						sub.material = _wall_material
				_hide_native_widget(best)
				# Wall en avant-plan : couper toute teinte d'objet posee plus tot ce
				# frame (le hover objets tourne avant le hover walls dans la frame).
				_clear_object_highlight()
			elif not _effective_walls():
				# S'assurer qu'aucun Line2D n'a notre material (residus eventuels)
				for sub in best.get_children():
					if sub is Line2D and sub.material == _wall_material:
						sub.material = null
	else:
		_clear_wall_highlight()


func _clear_wall_highlight():
	for entry in _hover_wall_saved_mats:
		if is_instance_valid(entry[0]):
			# Restaurer seulement si notre material est encore la
			# Sinon wall_fix a deja pris le relais, ne pas ecraser
			if entry[0].material == _wall_material or entry[0].material == null:
				entry[0].material = entry[1]
	_hover_wall_saved_mats = []
	_hover_wall = null


func invalidate_wall_hover():
	_hover_wall_saved_mats = []
	_hover_wall = null
	_last_hover_mouse = Vector2.INF


func _is_mouse_on_portal(wall, mouse_world: Vector2) -> bool:
	var portals = wall.get("Portals")
	if portals == null:
		return false
	# Marge d'exclusion = demi-epaisseur du mur (au lieu d'une tuile entiere),
	# pour ne masquer que l'ouverture du portal et pas le mur autour.
	var half_w = 40.0
	for child in wall.get_children():
		if child is Line2D and child.points.size() >= 2:
			if child.width * 0.5 > half_w or half_w == 40.0:
				half_w = child.width * 0.5
	for portal in portals:
		if not is_instance_valid(portal):
			continue
		var rect = _get_portal_world_rect(portal, half_w)
		if rect.has_point(mouse_world):
			return true
	return false


func _get_portal_world_rect(portal, margin: float = 24.0) -> Rect2:
	var rect = Rect2()
	var found = false
	for child in portal.get_children():
		if child is Sprite and child.texture != null:
			var tex_size = child.texture.get_size()
			var s = child.global_scale.abs()
			var world_size = tex_size * s
			var child_rect = Rect2(child.global_position - world_size * 0.5, world_size)
			if not found:
				rect = child_rect
				found = true
			else:
				rect = rect.merge(child_rect)
	if not found:
		rect = Rect2(portal.global_position - Vector2(40, 40), Vector2(80, 80))
	return rect.grow(margin)


func _is_ft_on_portal() -> bool:
	if _g.get("ModMapData") == null or not (_g.ModMapData is Dictionary):
		return false
	var ft = _g.ModMapData.get("_free_transform_active")
	if ft == null or not bool(ft):
		return false
	var mouse_world = _g.WorldUI.get("MousePosition")
	if mouse_world == null:
		return false
	var level = _g.World.GetCurrentLevel() if _g.World != null else null
	if level == null:
		return false
	var walls = level.get("Walls")
	if walls == null:
		return false
	for wall in walls.get_children():
		if _is_mouse_on_portal(wall, mouse_world):
			return true
	return false


var _texture_image_cache = {}
var _visible_range_cache = {}
# Cache widget natif par path (instance_id -> PathwayWidget) pour eviter de
# rescanner les enfants a chaque frame dans la suppression robuste ci-dessous.
var _path_widget_cache = {}
# Idem pour les patterns (instance_id -> PatternShapeWidget).
var _pattern_widget_cache = {}


func _get_texture_image(tex):
	if _texture_image_cache.has(tex):
		return _texture_image_cache[tex]
	var img = tex.get_data()
	if img:
		img.lock()
		_texture_image_cache[tex] = img
	return img




func _get_visible_range(tex, img):
	if _visible_range_cache.has(tex):
		return _visible_range_cache[tex]
	var tex_h = img.get_height()
	var tex_w = img.get_width()
	var min_uv = 1.0
	var max_uv = 0.0
	var step_x = max(tex_w / 64, 1)
	for y in range(tex_h):
		var opaque = 0
		var total = 0
		for x in range(0, tex_w, step_x):
			total += 1
			if img.get_pixel(x, y).a > 0.1:
				opaque += 1
		if opaque > total * 0.05:
			var uv = float(y) / float(tex_h)
			if uv < min_uv: min_uv = uv
			if uv > max_uv: max_uv = uv
	if min_uv > max_uv:
		min_uv = 0.0
		max_uv = 1.0
	min_uv = max(min_uv - 0.01, 0.0)
	max_uv = min(max_uv + 0.01, 1.0)
	_visible_range_cache[tex] = [min_uv, max_uv]
	return [min_uv, max_uv]


func _is_mouse_on_path(line, world_pos):
	var local_pos = line.get_global_transform().affine_inverse().xform(world_pos)
	var pts = line.points
	if pts.size() < 2: return false

	# Longueur cumulee le long de la polyligne
	var cum = [0.0]
	var total_len = 0.0
	for i in range(pts.size() - 1):
		total_len += (pts[i + 1] - pts[i]).length()
		cum.append(total_len)

	# Segment le plus proche + distance perpendiculaire signee + debordement
	var best_score = INF
	var best_seg = 0
	var best_t = 0.0
	var best_perp = 0.0
	var best_along_past_start = 0.0
	var best_along_past_end = 0.0
	var best_arc = 0.0
	for i in range(pts.size() - 1):
		var pa = pts[i]
		var pb = pts[i + 1]
		var ab = pb - pa
		var seg_len = ab.length()
		if seg_len < 0.001:
			continue
		var dir = ab / seg_len
		var perp_n = Vector2(-dir.y, dir.x)
		var rel = local_pos - pa
		var along = rel.dot(dir)
		var perp_d = rel.dot(perp_n)
		var t = clamp(along / seg_len, 0.0, 1.0)
		var proj = pa + dir * (t * seg_len)
		var dist = (local_pos - proj).length()
		if dist < best_score:
			best_score = dist
			best_seg = i
			best_t = t
			best_perp = perp_d
			best_along_past_start = max(0.0, -along)
			best_along_past_end = max(0.0, along - seg_len)
			best_arc = cum[i] + t * seg_len

	var half_w = line.width * 0.5

	# Reject perpendiculaire strict
	if abs(best_perp) > half_w:
		return false

	# Reject extremite, cap-aware
	if best_t <= 0.001 and best_seg == 0:
		var bcm = line.begin_cap_mode
		var max_past = 0.5 if bcm == 0 else half_w
		if best_along_past_start > max_past:
			return false
		if bcm == 2:
			if best_along_past_start * best_along_past_start + best_perp * best_perp > half_w * half_w:
				return false
	if best_t >= 0.999 and best_seg == pts.size() - 2:
		var ecm = line.end_cap_mode
		var max_past2 = 0.5 if ecm == 0 else half_w
		if best_along_past_end > max_past2:
			return false
		if ecm == 2:
			if best_along_past_end * best_along_past_end + best_perp * best_perp > half_w * half_w:
				return false

	# V en UV: 0 = un bord, 1 = l'autre
	var v_uv = best_perp / line.width + 0.5

	var tex = line.texture
	if tex == null: return v_uv >= 0.0 and v_uv <= 1.0
	var img = _get_texture_image(tex)
	if img == null: return v_uv >= 0.0 and v_uv <= 1.0

	var tex_w = img.get_width()
	var tex_h = img.get_height()

	# U en UV selon texture_mode
	var u_uv = 0.0
	var tmode = line.texture_mode
	if tmode == Line2D.LINE_TEXTURE_TILE:
		var tile_len = line.width * (float(tex_w) / float(tex_h))
		if tile_len < 0.001:
			return v_uv >= 0.0 and v_uv <= 1.0
		u_uv = fmod(best_arc / tile_len, 1.0)
		if u_uv < 0.0:
			u_uv += 1.0
	elif tmode == Line2D.LINE_TEXTURE_STRETCH:
		if total_len < 0.001:
			return v_uv >= 0.0 and v_uv <= 1.0
		u_uv = best_arc / total_len
	else:
		return v_uv >= 0.0 and v_uv <= 1.0

	var px = int(clamp(u_uv * tex_w, 0, tex_w - 1))
	var py = int(clamp(v_uv * tex_h, 0, tex_h - 1))
	return img.get_pixel(px, py).a > 0.1


func _update_path_hover(level, mouse_world):
	# Par defaut, ne pas masquer le highlight natif de DD (repose a true plus
	# bas uniquement si un path est devant un asset).
	if path_fix != null and is_instance_valid(path_fix):
		path_fix._hovered_path = null
	# Si un wall est survole (overlay du wall actif, donc le wall est rendu
	# au-dessus de ce point), ne pas afficher de hoverbox de path/pattern en
	# dessous. Les paths au-dessus du wall l'auraient deja couvert (=> _hover_wall
	# nul), donc si _hover_wall est present, le wall est bien devant.
	if _hover_wall != null and is_instance_valid(_hover_wall) and _effective_walls():
		_clear_path_highlight()
		return
	# Respecter le filter du SelectTool quand il est actif
	if _g.Editor.ActiveToolName == "SelectTool":
		var st = _g.Editor.Tools["SelectTool"]
		var filter = st.get("Filter") if st != null else null
		if filter is Dictionary and not bool(filter.get("Paths", true)):
			_clear_path_highlight()
			return
	# Ne pas interferer si path_fix est en train de dragger
	if path_fix != null and is_instance_valid(path_fix):
		if path_fix._is_dragging() or (path_fix._left_pressed and path_fix._drag_threshold_passed):
			_clear_path_highlight()
			return
	var pathways = level.get("Pathways")
	if pathways == null:
		_clear_path_highlight()
		return
	# Trouver le path selectionne (pour exposer _hover_path a path_fix)
	var selected_path = null
	if path_fix != null and is_instance_valid(path_fix):
		selected_path = path_fix._flat_line
	var best = null
	var children = pathways.get_children()
	for i in range(children.size() - 1, -1, -1):
		var child = children[i]
		if not (child is Line2D):
			continue
		# La GlobalRect d'un path ne borne que sa ligne centrale (largeur ignoree).
		# La marge de cull doit donc couvrir la demi-largeur du path, sinon on
		# rejette a tort les bords (tres visible sur les paths verticaux/horizontaux
		# dont la bbox est un trait d'epaisseur nulle).
		var cull_margin = 64.0
		if child.get("width") != null:
			cull_margin = max(64.0, child.width * 0.5 + 16.0)
		if _aabb_miss(child, mouse_world, cull_margin):
			continue
		if _is_mouse_on_path(child, mouse_world):
			best = child
			break
	# Le path est-il couvert par un element au-dessus (objet, light, pattern,
	# portal, roof) ? Si oui, c'est lui le candidat : pas d'overlay path et
	# _hover_path nul pour ne pas parasiter la selection. Sinon (path devant),
	# on demande a path_fix de masquer le highlight natif de l'asset du dessous.
	var path_covered = false
	var on_select = _g.Editor.ActiveToolName == "SelectTool"
	if best != null and on_select \
	and path_fix != null and is_instance_valid(path_fix) \
	and path_fix.has_method("_is_path_covered"):
		path_covered = path_fix._is_path_covered(best)
	if path_fix != null and is_instance_valid(path_fix):
		path_fix._hovered_path = (best if (best != null and on_select) else null)
	if path_covered:
		_clear_path_highlight()
		return
	# Si le path hovered est deja selectionne, laisser DD gerer les curseurs
	# mais mettre quand meme _hover_path a jour pour la selection
	if best != null and best == selected_path:
		# Path deja selectionne : ne pas toucher au cursor, DD gere la transform box
		if _hover_path != best:
			_clear_path_highlight()
		_hover_path = best
		# Path en avant-plan : couper toute teinte d'objet posee plus tot ce frame.
		if _effective_paths():
			_clear_object_highlight()
		return
	# Toujours mettre a jour _hover_path (path_fix en a besoin pour la selection)
	if best != null:
		if best != _hover_path:
			_clear_path_highlight()
			_hover_path = best
			if _effective_paths():
				var applied = _build_path_highlight_material(best)
				_hover_path_saved_mats.append([best, best.material, applied])
				best.material = applied
				_hide_native_widget(best)
		# Path en avant-plan : couper toute teinte d'objet posee plus tot ce frame
		# (le hover objets tourne avant le hover paths dans la meme frame).
		if _effective_paths():
			_clear_object_highlight()
		# Curseur gere uniquement par path_fix._update_cursor_only (source unique)
	else:
		_clear_path_highlight()


# Construit le material de surbrillance d'un path. Si le path porte deja un
# ShaderMaterial etranger (ex. mod Modify Paths : offset / flip vertical de la
# texture), on le CLONE et on injecte la teinte par-dessus son fragment(), au lieu
# de le remplacer par _path_material — sinon l'overlay reaffiche la texture sans
# l'offset/flip. Sans shader etranger, on garde le material partage _path_material.
func _build_path_highlight_material(line):
	var src = line.material
	if src is ShaderMaterial and src.shader != null and src != _path_material:
		var mat = src.duplicate()
		var inj = Shader.new()
		inj.code = _inject_path_tint(src.shader.code)
		mat.shader = inj
		mat.set_shader_param("_ov_ptint", Vector3(_path_color.r, _path_color.g, _path_color.b))
		mat.set_shader_param("_ov_popacity", _path_opacity)
		return mat
	return _path_material


# Injecte la teinte path (mode 0) dans un shader canvas_item etranger : ajoute les
# uniformes _ov_* apres la 1ere ";", puis post-traite COLOR juste avant l'accolade
# fermante finale (fragment() etant la derniere fonction). On ne teinte que les
# texels ayant du contenu (COLOR.a > seuil) pour ne pas remplir la bbox.
func _inject_path_tint(code: String) -> String:
	var uni = "\nuniform vec3 _ov_ptint = vec3(0.686, 0.973, 1.0);\nuniform float _ov_popacity = 0.8;\n"
	var decl = code.find(";")
	if decl != -1:
		code = code.substr(0, decl + 1) + uni + code.substr(decl + 1)
	var tint = "\n\t{\n\t\tif (COLOR.a > 0.01) {\n\t\t\tvec3 _ovb = COLOR.rgb;\n\t\t\tfloat _ovl = dot(_ovb, vec3(0.299, 0.587, 0.114));\n\t\t\tvec3 _ovc = _ov_ptint * (0.5 + _ovl * 0.5);\n\t\t\tCOLOR.rgb = mix(_ovb, _ovc, _ov_popacity);\n\t\t\tCOLOR.a = min(COLOR.a + _ov_popacity * 0.4, 1.0);\n\t\t}\n\t}\n"
	var last = code.rfind("}")
	if last != -1:
		code = code.substr(0, last) + tint + code.substr(last)
	return code


func _clear_path_highlight():
	for entry in _hover_path_saved_mats:
		if is_instance_valid(entry[0]):
			var applied = entry[2] if entry.size() > 2 else _path_material
			if entry[0].material == applied or entry[0].material == null:
				entry[0].material = entry[1]
	_hover_path_saved_mats = []
	_hover_path = null
	# Curseur gere uniquement par path_fix._update_cursor_only (source unique)


# ── Patterns : hover overlay (vert clair) ─────────────────────────────────
# PatternShape etend Polygon2D et expose IsMouseWithin() (hit-test natif) +
# GlobalRect (pre-filtre bbox). Les patterns sont SOUS murs/paths/objets : on ne
# teinte que si rien au-dessus n'est survole, pour eviter une double surbrillance.

# Vrai si l'utilisateur deplace/transforme activement une selection (clic gauche
# maintenu). Couvre le drag simple/instant d'un asset (manualAction != None :
# MoveThing/MovePortal/AttenuateLight) ET le select+drag via la box de selection
# (transformMode != None : Move/Rotate/Scale), plus le trace d'une box. On exige
# le bouton gauche enfonce car transformMode est aussi pose au simple survol de la
# box : sans cette garde on couperait l'overlay hors drag.
func _is_dragging_selection() -> bool:
	if not Input.is_mouse_button_pressed(BUTTON_LEFT):
		return false
	var st = _g.Editor.Tools["SelectTool"] if _g.Editor else null
	if st == null:
		return false
	var ma = st.get("manualAction")
	if ma != null and int(ma) != 0:
		return true
	var tm = st.get("transformMode")
	if tm != null and int(tm) != 0:
		return true
	if st.get("isDrawing") == true:
		return true
	return false


# Drag instant uniquement (clic gauche + manualAction MoveThing/MovePortal).
# Contrairement au select+drag (transformMode), l'asset bouge directement ici :
# masquer la box ne casse donc pas le deplacement.
func _is_instant_drag() -> bool:
	if not Input.is_mouse_button_pressed(BUTTON_LEFT):
		return false
	var st = _g.Editor.Tools["SelectTool"] if _g.Editor else null
	if st == null:
		return false
	var ma = st.get("manualAction")
	# 1 = MoveThing, 2 = MovePortal (3 = AttenuateLight : pas un deplacement).
	return ma != null and (int(ma) == 1 or int(ma) == 2)


# Vrai si un autre mod possede deja l'affichage de la box (meme garde que
# free_transform._other_mod_owns_box) : on ne touche alors pas a la box pour
# eviter une guerre de re-activation d'une frame.
func _box_owned_by_other() -> bool:
	# FT actif : sa update() cache la box chaque frame, il en est proprietaire.
	if _g.ModMapData != null and _g.ModMapData.get("_free_transform_active", false):
		return true
	# DragSelectWalls : dessine sa propre box quand son overlay custom est actif.
	var dsw = _g.ModMapData.get("_drag_select_walls") if _g.ModMapData != null else null
	if dsw != null and dsw.has_method("_is_custom_active"):
		if dsw.call("_is_custom_active"):
			return true
	# Portails dans la selection : portal_tool_fix veut les handles caches.
	var st = _g.Editor.Tools["SelectTool"] if _g.Editor else null
	if st != null:
		var sel = st.get("Selected")
		if sel != null and st.has_method("GetSelectableType"):
			for node in sel:
				if node == null or not is_instance_valid(node):
					continue
				var type = st.call("GetSelectableType", node)
				if type == 2 or type == 3:
					return true
	return false


# Lit le toggle settings "Hide Box While Dragging" (pattern A). Fail-open si
# mod_settings absent.
func _drag_box_hide_enabled() -> bool:
	var ms = null
	if _g != null and _g.get("ModMapData") != null and _g.ModMapData is Dictionary:
		ms = _g.ModMapData.get("_mod_settings")
	if ms == null or not ms.has_method("is_enabled"):
		return true
	return ms.is_enabled("hide_box_on_drag")


# Cache la box de selection visuelle des assets deplaces pendant un drag instant
# (le contour dessine par DD via borderColor/SelectRect quand isSelected/
# isHighlighted). On agit sur Prop.Select(false)/Highlight(false) : purement
# visuel, sans toucher la selection reelle du SelectTool. Restauree au relachement.
# On respecte _box_owned_by_other pour les cas portails / FT / DragSelectWalls.
func _update_drag_box_hide() -> void:
	var st = _g.Editor.Tools["SelectTool"] if _g.Editor else null
	if st == null or not _drag_box_hide_enabled():
		_restore_suppressed_boxes(st)
		return
	var instant = _is_instant_drag()
	if instant and not _box_owned_by_other():
		# Les things en cours de deplacement pendant un instant-drag ; fallback
		# sur la selection si la liste n'est pas peuplee.
		var things = st.get("movableThings")
		if things == null or (things is Array and things.empty()):
			things = st.get("Selected")
		if things != null:
			for t in things:
				if t == null or not is_instance_valid(t):
					continue
				# (Re)pose false chaque frame : DD redessine le contour sinon.
				if t.has_method("Select"):
					t.call("Select", false)
				if t.has_method("Highlight"):
					t.call("Highlight", false)
				if not _box_suppressed.has(t):
					_box_suppressed.append(t)
	elif not instant and not _box_suppressed.empty():
		_restore_suppressed_boxes(st)


# Restaure le contour des things qu'on avait masques, uniquement s'ils sont
# encore selectionnes dans le SelectTool (sinon Select(true) dessinerait une box
# sur un asset non selectionne).
func _restore_suppressed_boxes(st) -> void:
	var selected = st.get("Selected") if st != null else null
	for t in _box_suppressed:
		if t == null or not is_instance_valid(t):
			continue
		if selected != null and selected.has(t) and t.has_method("Select"):
			t.call("Select", true)
	_box_suppressed = []


func _update_pattern_hover(level, mouse_world):
	if not _effective_patterns():
		_clear_pattern_highlight()
		return
	# Pendant un drag/transform d'asset (simple ou select+drag), ne pas teinter
	# les patterns survoles non selectionnes : l'overlay vert clignoterait sous le
	# curseur a chaque pattern traverse.
	if _is_dragging_selection():
		_clear_pattern_highlight()
		return
	if (_hover_wall != null and is_instance_valid(_hover_wall)) \
	or (_hover_path != null and is_instance_valid(_hover_path)) \
	or (_hover_obj != null and is_instance_valid(_hover_obj)):
		_clear_pattern_highlight()
		return
	# Respecter le filter du SelectTool (si la cle existe).
	if _g.Editor.ActiveToolName == "SelectTool":
		var st = _g.Editor.Tools["SelectTool"]
		var filter = st.get("Filter") if st != null else null
		if filter is Dictionary and filter.has("Patterns") and not bool(filter["Patterns"]):
			_clear_pattern_highlight()
			return
	# PatternShapes range ses enfants par LAYER (get_children() = noeuds de couche,
	# pas les shapes). GetShapes() renvoie la liste a plat de tous les PatternShape.
	var shapes = level.get("PatternShapes")
	if shapes == null or not shapes.has_method("GetShapes"):
		_clear_pattern_highlight()
		return
	var list = shapes.GetShapes()
	if list == null:
		_clear_pattern_highlight()
		return
	# Plafond de calque impose par la selection sous le curseur : un pattern n'est
	# survolable que s'il est dessine STRICTEMENT au-dessus de l'objet/portail
	# selectionne qui couvre ce point. Sinon le pattern est cache derriere l'asset
	# selectionne (rendu au-dessus) et ne doit pas se teinter. null = aucune
	# selection ne couvre le point -> pas de filtrage.
	var sel_ceiling = _selection_cover_layer(mouse_world)
	var best = null
	for i in range(list.size() - 1, -1, -1):
		var sh = list[i]
		if sh == null or not is_instance_valid(sh) or not (sh is Polygon2D):
			continue
		var gr = sh.get("GlobalRect")
		if gr is Rect2 and not gr.grow(2.0).has_point(mouse_world):
			continue
		# Test precis : point-dans-polygone sur la forme reelle (GlobalPolygon, deja
		# en coords monde). IsMouseWithin de DD ne teste que la bbox, donc un pattern
		# concave (ex: en L) etait surligne dans son creux "dans le vide". GlobalPolygon
		# gere correctement le concave. Fallback sur IsMouseWithin s'il est indisponible.
		var inside = false
		var gpoly = sh.get("GlobalPolygon")
		if gpoly != null and gpoly.size() >= 3:
			inside = Geometry.is_point_in_polygon(mouse_world, gpoly)
		elif sh.has_method("IsMouseWithin"):
			inside = sh.IsMouseWithin(mouse_world)
		if not inside:
			continue
		# Filtre calque : pattern au meme calque ou sous la selection -> ignore
		# (rang pattern < rang objet, donc a calque egal l'objet est au-dessus).
		# On poursuit le scan : un pattern plus haut sous le curseur reste eligible.
		if sel_ceiling != null:
			var plz = sh.GetLayer() if sh.has_method("GetLayer") else _effective_z(sh)
			if int(plz) <= int(sel_ceiling):
				continue
		best = sh
		break
	if best != null:
		if best != _hover_pattern:
			_clear_pattern_highlight()
			_hover_pattern = best
			_show_pattern_overlay(best)
	else:
		_clear_pattern_highlight()


# Calque "plafond" impose par la selection sous le curseur : plus haut effective-z
# parmi les objets/portails SELECTIONNES dont l'empreinte contient le point souris.
# Un pattern n'est survolable que s'il est dessine strictement au-dessus de ce
# plafond. Renvoie null si aucun asset selectionne ne couvre le point (= pas de
# filtrage). Pixel-perfect pour les objets (comme path_fix), IsMouseWithin pour
# les portails ; les autres types selectionnes (pattern, wall, path...) sont ignores.
func _selection_cover_layer(mouse_world):
	var st = _g.Editor.Tools["SelectTool"] if _g.Editor else null
	if st == null:
		return null
	var sel = st.get("Selected")
	if not (sel is Array) or sel.empty():
		return null
	var has_type = st.has_method("GetSelectableType")
	var ceiling = null
	for thing in sel:
		if thing == null or not is_instance_valid(thing) or not (thing is CanvasItem):
			continue
		var ttype = int(st.call("GetSelectableType", thing)) if has_type else 4
		var hit = false
		if ttype == 4:
			# Object : test pixel-perfect sur le sprite principal.
			var spr = thing.get("Sprite")
			if spr != null and is_instance_valid(spr) and spr.has_method("is_pixel_opaque"):
				hit = spr.is_pixel_opaque(spr.to_local(mouse_world))
		elif ttype == 2 or ttype == 3:
			# Portail.
			if thing.has_method("IsMouseWithin"):
				hit = thing.IsMouseWithin()
		else:
			continue
		if not hit:
			continue
		var lz = _effective_z(thing)
		if ceiling == null or lz > ceiling:
			ceiling = lz
	return ceiling


# z effectif d'un CanvasItem : somme des z_index le long de la chaine parente
# tant que z_as_relative est vrai (meme modele que path_fix._effective_z).
func _effective_z(ci) -> int:
	var z = 0
	var n = ci
	while n != null and n is CanvasItem:
		z += n.z_index
		if not n.z_as_relative:
			break
		n = n.get_parent()
	return z


# Calque de surbrillance superpose au pattern survole, ajoute comme ENFANT du
# PatternShape (herite de sa transform, se dessine PAR-DESSUS son remplissage).
# Son material est un CLONE de celui du pattern (meme shader DD + memes params :
# albedo, rotation, wear, custom-color...) dans lequel on injecte l'etape brighten
# -> le motif est rendu a l'identique par le shader de DD, puis eclairci vers la
# teinte. opacity : 0 = pattern intact, 1 = pleine surbrillance.
func _show_pattern_overlay(shape) -> void:
	if _pattern_overlay == null or not is_instance_valid(_pattern_overlay):
		_pattern_overlay = Polygon2D.new()
		_pattern_overlay.antialiased = false
	if _pattern_overlay.get_parent() != null:
		_pattern_overlay.get_parent().remove_child(_pattern_overlay)
	_pattern_overlay.polygon = shape.polygon
	# Repliquer d'eventuels trous (Polygon2D.polygons / internal_vertex_count).
	_pattern_overlay.polygons = shape.get("polygons")
	_pattern_overlay.internal_vertex_count = shape.get("internal_vertex_count")
	# Material : clone du shader DD + brighten injecte (sinon fallback uni). Le
	# shader source pouvant differer d'un pattern a l'autre, on le rebuild a chaque
	# survol.
	_pattern_overlay.material = _build_pattern_overlay_material(shape)
	# Couleur de fond (vertex color) de la source : le shader DD la multiplie
	# (COLOR *= texture), donc on la reproduit pour un rendu fidele.
	var _scol = shape.get("color")
	_pattern_overlay.color = _scol if _scol != null else Color(1, 1, 1, 1)
	_update_pattern_overlay_params()
	shape.add_child(_pattern_overlay)
	_pattern_overlay.show()


# Construit le material du calque : clone du ShaderMaterial du pattern source avec
# le brighten injecte dans son fragment(). Si la source n'a pas de ShaderMaterial
# exploitable (pattern uni), retombe sur un shader simple base sur TEXTURE/COLOR.
func _build_pattern_overlay_material(shape):
	var src = shape.material
	if src is ShaderMaterial and src.shader != null:
		# duplicate() conserve le shader ET les valeurs de params (albedo, etc.) ;
		# on remplace ensuite le shader par sa version brighten — les params dont
		# le nom est inchange restent appliques.
		var mat = src.duplicate()
		var inj = Shader.new()
		inj.code = _inject_brighten(src.shader.code)
		mat.shader = inj
		return mat
	var sh = Shader.new()
	sh.code = _PATTERN_OVERLAY_FALLBACK_SHADER
	var m = ShaderMaterial.new()
	m.shader = sh
	return m


# Injecte l'etape brighten dans le code d'un shader pattern DD : ajoute les
# uniformes _ov_* apres la declaration shader_type, et insere le post-traitement de
# COLOR juste avant l'accolade fermante finale (fragment() est la derniere
# fonction des shaders pattern de DD).
func _inject_brighten(code: String) -> String:
	var uni = "\nuniform vec3 _ov_tint = vec3(0.11, 0.016, 0.24);\nuniform float _ov_opacity = 1.0;\n"
	var decl = code.find(";")
	if decl != -1:
		code = code.substr(0, decl + 1) + uni + code.substr(decl + 1)
	var brighten = "\n\t{\n\t\tfloat _l = dot(COLOR.rgb, vec3(0.299, 0.587, 0.114));\n\t\tfloat _g = _l - smoothstep(0.6, 1.0, _l) * 0.5;\n\t\tvec3 _hi = clamp(vec3(_g) + _ov_tint, 0.0, 1.0);\n\t\tCOLOR.rgb = mix(COLOR.rgb, _hi, _ov_opacity);\n\t}\n"
	var last = code.rfind("}")
	if last != -1:
		code = code.substr(0, last) + brighten + code.substr(last)
	return code


# Met a jour la teinte et l'opacite du calque de surbrillance pattern.
# opacity 0 = pattern intact, 1 = pleine surbrillance (teinte + relief conserve).
func _update_pattern_overlay_params() -> void:
	if _pattern_overlay == null or not is_instance_valid(_pattern_overlay):
		return
	var m = _pattern_overlay.material
	if m is ShaderMaterial:
		m.set_shader_param("_ov_tint", Vector3(_pattern_color.r, _pattern_color.g, _pattern_color.b))
		m.set_shader_param("_ov_opacity", _pattern_opacity)


func _clear_pattern_highlight():
	if _pattern_overlay != null and is_instance_valid(_pattern_overlay):
		if _pattern_overlay.get_parent() != null:
			_pattern_overlay.get_parent().remove_child(_pattern_overlay)
		_pattern_overlay.hide()
	_hover_pattern = null


# ── Masquage de la ligne pointillee native de DD ──────────────────────────
# Le WallWidget / PathwayWidget est le 1er enfant (Line2D) du Wall/Pathway et
# expose Highlight()/Select(). On ne lit PAS select_tool.highlighted (crash
# possible quand des lumieres existent) : on attaque le widget directement.

func _get_native_widget(node):
	if node == null or not is_instance_valid(node):
		return null
	# Certains Things exposent une propriete Widget ; on l'utilise si presente.
	var w = node.get("Widget")
	if w != null and is_instance_valid(w) and w.has_method("Highlight"):
		return w
	# Sinon : le WallWidget/PathwayWidget est un enfant Line2D exposant a la fois
	# Highlight() ET Select() (+ champs isHighlighted/isSelected). On NE suppose
	# PAS qu'il est en position 0 : d'autres mods (edition de courbe, points...)
	# peuvent inserer des enfants Line2D avant lui sur les paths -> c'etait la
	# cause du masquage intermittent.
	for c in node.get_children():
		if c is Line2D and c.has_method("Highlight") and c.has_method("Select"):
			return c
	return null


func _hide_native_widget(node) -> void:
	var w = _get_native_widget(node)
	if w == null or not is_instance_valid(w):
		return
	# call_deferred : passer APRES le Highlight pose par DD dans la frame.
	# Highlight(false) ne touche que le flag de survol : une selection
	# (isSelected) reste affichee normalement.
	w.call_deferred("Highlight", false)


func _path_widget_of(path):
	if path == null or not is_instance_valid(path):
		return null
	var id = path.get_instance_id()
	var w = _path_widget_cache.get(id)
	if w != null and is_instance_valid(w) and w.get_parent() == path:
		return w
	w = _get_native_widget(path)
	if w != null:
		_path_widget_cache[id] = w
	return w


func _suppress_native_path_widgets(level) -> void:
	var pathways = level.get("Pathways") if level != null else null
	if pathways == null:
		return
	for p in pathways.get_children():
		if not (p is Line2D):
			continue
		var w = _path_widget_of(p)
		if w == null or not is_instance_valid(w):
			continue
		# Garde sur `visible` (propriete Godot native, toujours lisible) : on ne
		# touche que les widgets effectivement affiches. Puis on ne masque que le
		# survol (isHighlighted) sans toucher la selection (isSelected). Les `==
		# true`/`!= true` rendent la condition sure meme si un champ n'est pas
		# expose (renvoie null) -> au pire no-op, jamais de selection masquee.
		if w.visible and w.get("isHighlighted") == true and w.get("isSelected") != true:
			w.call_deferred("Highlight", false)


func _pattern_widget_of(shape):
	if shape == null or not is_instance_valid(shape):
		return null
	var id = shape.get_instance_id()
	var w = _pattern_widget_cache.get(id)
	if w != null and is_instance_valid(w) and w.get_parent() == shape:
		return w
	w = _get_native_widget(shape)
	if w != null:
		_pattern_widget_cache[id] = w
	return w


func _suppress_native_pattern_widgets(level) -> void:
	var shapes = level.get("PatternShapes") if level != null else null
	if shapes == null or not shapes.has_method("GetShapes"):
		return
	var list = shapes.GetShapes()
	if list == null:
		return
	for sh in list:
		if sh == null or not is_instance_valid(sh) or not (sh is Polygon2D):
			continue
		var w = _pattern_widget_of(sh)
		if w == null or not is_instance_valid(w):
			continue
		if w.visible and w.get("isHighlighted") == true and w.get("isSelected") != true:
			w.call_deferred("Highlight", false)


# ── Master toggle (Shift+O / floatbar "Overlays") ─────────────────────────

func _toggle_overlays() -> void:
	_set_overlays_on(not _overlays_on)


func _set_overlays_on(on: bool) -> void:
	if on == _overlays_on:
		return
	_overlays_on = on
	_last_hover_mouse = Vector2.INF
	# Clear immediat pour que l'etat prenne effet sans attendre un re-hover.
	_clear_wall_highlight()
	_clear_path_highlight()
	_clear_pattern_highlight()
	# Objets/portails : repasse en hover vanilla (box jaune) si master OFF,
	# revient a notre teinte au prochain hover si master ON.
	_clear_object_highlight()
	# Retirer tout residu de notre material sur le wall encore hovered.
	if _hover_wall != null and is_instance_valid(_hover_wall):
		for sub in _hover_wall.get_children():
			if sub is Line2D and sub.material == _wall_material:
				sub.material = null
	_hover_wall = null
	# Sync path_fix (highlight dans le SelectTool).
	if path_fix != null and is_instance_valid(path_fix):
		path_fix._external_highlight_material = _path_material if _effective_paths() else null
	_sync_bar_button()
	_save_settings()
	print("[OverlayTool] overlays %s" % ("on" if _overlays_on else "off"))


# ── Input: Shift+O toggle ─────────────────────────────────────────────────

func _install_input_listener() -> void:
	_input_listener = Node.new()
	_input_listener.name = "OverlayToolInputListener"
	var script = GDScript.new()
	script.source_code = "extends Node\nvar handler = null\nfunc _ready():\n\tset_process_input(true)\n\tprocess_priority = -200\nfunc _input(e):\n\tif handler != null:\n\t\thandler._on_input(e)\n"
	script.reload()
	_input_listener.set_script(script)
	_input_listener.handler = self
	if _g.World:
		_g.World.call_deferred("add_child", _input_listener)


func _on_input(event) -> void:
	if _destroyed:
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	# Shift + O, sans Ctrl/Alt pour ne pas voler d'autres raccourcis.
	if event.scancode != KEY_O or not event.shift or event.control or event.alt:
		return
	if _is_text_focused():
		return
	_toggle_overlays()
	_input_listener.get_tree().set_input_as_handled()


func _find_focused_control(node):
	# Cherche le focus dans TOUS les viewports, pas seulement le viewport racine.
	# Certains panneaux UI de DD (ex: ObjectLibraryPanel) peuvent vivre dans un
	# sous-viewport, invisible pour root.gui_get_focus_owner().
	if node is Viewport:
		var f = node.gui_get_focus_owner()
		if f != null:
			return f
	for c in node.get_children():
		var r = _find_focused_control(c)
		if r != null:
			return r
	return null


func _is_text_focused() -> bool:
	var tree = null
	if _input_listener != null and is_instance_valid(_input_listener):
		tree = _input_listener.get_tree()
	if tree == null and _g != null and _g.World != null and is_instance_valid(_g.World):
		tree = _g.World.get_tree()
	if tree == null or tree.root == null:
		return false

	var editor = _g.Editor if _g != null else null
	if editor == null:
		editor = tree.root.get_node_or_null("Master/Editor")

	# Drapeau posé par Search&Select (et tout mod qui l'expose).
	if editor != null and editor.get("SearchHasFocus"):
		return true

	# Méthode canonique de DD : Global.Editor.GetFocus().
	# Plus fiable que gui_get_focus_owner() (cf. Layer Panel, ObjectLibraryPanel).
	var focused = null
	if editor != null and editor.has_method("GetFocus"):
		focused = editor.GetFocus()
	# Fallback : balayage de tous les viewports.
	if focused == null:
		focused = _find_focused_control(tree.root)
	if focused == null:
		return false

	# LineEdit / TextEdit directs, OU SpinBox (le focus peut être sur le SpinBox
	# lui-même et pas son LineEdit interne selon le clic/tab).
	if focused is LineEdit or focused is TextEdit or focused is SpinBox:
		return true

	# Focus à l'intérieur d'un Popup/Dialog visible : saisie en cours.
	var n = focused
	while n != null and n is Control:
		if n is Popup and n.visible:
			return true
		n = n.get_parent()

	return false


# ── Floatbar button ("Overlays", next to Grid/Snap/Lighting) ──────────────

func set_bar_button_enabled(on: bool) -> void:
	if on:
		if _bar_button == null or not is_instance_valid(_bar_button):
			_try_inject_bar_button(0)
	else:
		if _bar_button != null and is_instance_valid(_bar_button):
			_bar_button.queue_free()
		_bar_button = null


func _bar_button_setting_enabled() -> bool:
	var ms = null
	if _g.get("ModMapData") != null and _g.ModMapData is Dictionary:
		ms = _g.ModMapData.get("_mod_settings")
	if ms == null or not ms.has_method("is_enabled"):
		return true
	return ms.is_enabled("overlay_bar_button")


func _try_inject_bar_button(attempt: int) -> void:
	if _destroyed:
		return
	if not _bar_button_setting_enabled():
		return
	if attempt > 25:
		print("[OverlayTool] Bar button injection gave up after 25 attempts")
		return
	if _bar_button != null and is_instance_valid(_bar_button):
		return

	var zoom_opts = _g.Editor.get("ZoomOptions") if _g.Editor else null
	if zoom_opts == null or not is_instance_valid(zoom_opts):
		_retry_inject_bar_button(attempt)
		return
	var parent = zoom_opts.get_parent()
	if parent == null or not is_instance_valid(parent):
		_retry_inject_bar_button(attempt)
		return

	# Clone a labelled toggle button (Grid/Snap/Lighting) to inherit DD's
	# theme; skip icon-only toggles (native Ruler Tool).
	var zoom_idx : int = zoom_opts.get_index()
	var insert_idx : int = zoom_idx
	var reference_btn : Node = null
	for i in range(zoom_idx - 1, -1, -1):
		var child = parent.get_child(i)
		if child is BaseButton and child.get("toggle_mode") == true:
			var txt = str(child.get("text")) if child.get("text") != null else ""
			if txt != "":
				reference_btn = child
				insert_idx = i + 1
				break

	if reference_btn != null:
		_bar_button = reference_btn.duplicate()
		_disconnect_all_signals(_bar_button)
		if _bar_button.get("icon") != null:
			_bar_button.set("icon", null)
		if _bar_button.get("shortcut") != null:
			_bar_button.set("shortcut", null)
	else:
		_bar_button = CheckButton.new()

	_bar_button.text = "Overlays"
	_bar_button.hint_tooltip = "(Shift + O)"
	_bar_button.pressed = _overlays_on
	_bar_button.focus_mode = Control.FOCUS_NONE
	_bar_button.connect("toggled", self, "_on_bar_button_toggled")
	parent.add_child(_bar_button)
	parent.move_child(_bar_button, insert_idx)
	print("[OverlayTool] Bar button injected at index %d" % insert_idx)


func _disconnect_all_signals(n: Object) -> void:
	if n == null:
		return
	for sig in n.get_signal_list():
		var conns = n.get_signal_connection_list(sig.name)
		for c in conns:
			if n.is_connected(sig.name, c.target, c.method):
				n.disconnect(sig.name, c.target, c.method)


func _retry_inject_bar_button(attempt: int) -> void:
	var tree = _g.World.get_tree() if _g.World else null
	if tree == null:
		return
	var t = tree.create_timer(0.3)
	t.connect("timeout", self, "_try_inject_bar_button", [attempt + 1])


func _on_bar_button_toggled(pressed: bool) -> void:
	if pressed == _overlays_on:
		return
	_set_overlays_on(pressed)


func _sync_bar_button() -> void:
	if _bar_button == null or not is_instance_valid(_bar_button):
		return
	if _bar_button.pressed == _overlays_on:
		return
	if _bar_button.has_method("set_pressed_no_signal"):
		_bar_button.set_pressed_no_signal(_overlays_on)
	else:
		_bar_button.set_block_signals(true)
		_bar_button.pressed = _overlays_on
		_bar_button.set_block_signals(false)
