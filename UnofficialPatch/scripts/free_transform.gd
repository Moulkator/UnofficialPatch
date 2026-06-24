# free_transform.gd — v5 (rewrite propre)
# Resize libre (ratio débloqué) pour les Objects (Props) de Dungeondraft.
#
# Bouton ON/OFF dans le panel SelectTool.
# Mode ON : cache la transform box DD, affiche notre overlay vert.
# Modificateurs : SHIFT = verrouille le ratio | ALT = scale depuis le centre
# Layout handles : 0=TL 1=TC 2=TR 3=MR 4=BR 5=BC 6=BL 7=ML  8=ROT (zone extérieure coins)

var _g
var _select_tool    = null
var _ui_util        = null
var _viewport_path  : NodePath
var _anchor_path    : NodePath
var _overlay        : Node = null
var _input_listener : Node = null

# ── Toggle ────────────────────────────────────────────────────────────────
var _enabled    := false
var _toggle_btn : Node = null
# Container UI complet du widget FT (label "Free Transform (Beta)" +
# reset + lock + toggle CheckButton) ajoute au panel SelectTool. Track
# pour pouvoir le cacher en bloc via set_widget_visible.
var _ui_group   : Node = null
# Quand true, force le widget cache meme quand has_selection devient true.
# Mis a true par set_widget_visible(false) (toggle Free Transform = OFF
# dans Settings panel). La logique de visibilite par-frame respecte ce flag.
var _widget_force_hidden := false

# ── Lock mode (autoquit vs forcé) ─────────────────────────────────────────
# _lock_mode = false → autoquit : FT se désactive si on quitte le SelectTool
#                                 ou si la sélection devient exclusivement incompatible
# _lock_mode = true  → forcé    : FT reste ON quoi qu'il arrive
var _lock_btn   : Node = null
var _lock_mode  := false
var _was_select_active := false  # pour détecter la transition SelectTool actif → inactif

# ── Suppression du hover/overlay DD pendant l'édition FT ───────────────────
# Tant que FT édite une sélection, on neutralise le scan de hover du SelectTool
# (HighlightThingAtPoint) en décochant ses filtres : plus aucun survol ni
# sélection d'un autre asset superposé/proche. Restauré dès la sortie.
var _hover_suppressed := false
var _ft_toggled_filter_items : Array = []
var _ft_texts_filter_was = null
var _ft_filter_menu = null

# ── Handles ───────────────────────────────────────────────────────────────
const IDX_ROT              := 8
const IDX_SLIDE            := 9   # glissement perpendiculaire au mur (portals, Alt+drag)
const IDX_WALK             := 10  # glissement le long du mur (portals, drag simple)
const IDX_MOVE             := 11  # déplacement libre (clic dans la bbox, objets normaux)
const CORNER_IDX := [0, 2, 4, 6]
const EDGE_IDX   := [1, 3, 5, 7]


# ── Drag ──────────────────────────────────────────────────────────────────
var _active_handle  := -1
var _drag_start_pos := Vector2.ZERO
var _drag_states    : Array = []
var _group_bbox     := Rect2()
var _walk_prev_wp   := Vector2.ZERO   # wp au frame précédent (IDX_WALK incrémental)

# ── Modificateurs ─────────────────────────────────────────────────────────
var _mod_shift := false
var _mod_alt   := false

# ── Sélection ─────────────────────────────────────────────────────────────
var _selected_objects : Array = []

# ── Cache textures portals (détection de changement de type) ──────────────
var _portal_tex_cache : Dictionary = {}  # instance_id → {tex_w, base_radius}

# ── Cache offsets portals déjà restaurés (évite double-apply) ─────────────
var _portal_offset_applied : Dictionary = {}  # instance_id → true

# ── Verrou de sélection Free Transform (Feature 1) ───────────────────────────
# Tant que FT est actif et verrouillé sur un asset, AUCUN autre asset ne peut
# être sélectionné. set_input_as_handled ne bloque pas DD de façon fiable, donc
# on laisse DD sélectionner puis on RÉTABLIT le verrou dans update(). Seul un
# clic loin de la transform box (désélection volontaire) lâche le verrou.
var _ft_lock : Array = []
var _ft_lock_reassert : int = 0


# ── Curseurs ──────────────────────────────────────────────────────────────
var _cursors         := {}
var _move_cursor_tex = null
var _drag_cursor_h   = null  # drag-cursor-icon-h.png (skew horizontal)
var _drag_cursor_v   = null  # drag-cursor-icon-v.png (skew vertical)
var _cursor_active   := false
var _handle_tex      = null

# ── Mode de transformation ─────────────────────────────────────────────────
# "free"        : comportement actuel (ratio libre)
# "skew"        : déplace un bord le long de son axe (cisaillement), handles de bord uniquement
# "distort"     : déplace un coin librement, les 3 autres sont fixes, handles de coin uniquement
# "perspective" : déplace un coin avec symétrie sur l'axe opposé, handles de coin uniquement
var _transform_mode := "free"

# ── Mode offset portal ─────────────────────────────────────────────────────
# Modes exclusifs pour les portals :
# "scale"  : resize uniquement (handles), pas de déplacement
# "slide"  : déplacement le long du mur uniquement, pas de resize
# "offset" : glissement perpendiculaire au mur uniquement, pas de resize
var _portal_mode := "scale"
var _group_warp_corners : Array = []  # coins du groupe warpé en multi-sélection
var _context_menu   : Node = null
var _pending_mode   : String = ""
var _menu_position  : Vector2 = Vector2.ZERO
var _warning_dialog : Node = null
var _popup_layer    : Node = null
# Matériaux shader distort/perspective — indexés par instance_id (String)
var _ft_materials   : Dictionary = {}

# ── Crop (masque polygonal) ────────────────────────────────────────────────
# Props uniquement. Polygone stocké par node dans ModMapData["_ft_crop"]
# sous forme de floats plats [x0,y0,x1,y1,...] en espace VERTEX du Sprite.
const CROP_MAX_PTS := 64  # plafond de sommets du polygone de crop
var _crop_node        : Node2D = null   # prop en cours d'édition crop
var _crop_points      : Array = []      # buffer édition : Vector2 (espace VERTEX)
var _crop_active_pt   := -1             # index du point en drag (-1 = aucun)
var _crop_drag_before : Dictionary = {} # snapshot unified pour l'undo
var _crop_orig_tex    : Dictionary = {} # key -> {texture, region_enabled, region_rect}
var _ft_shadow_orig   : Dictionary = {} # key -> {material, texture, region_enabled, region_rect} (ombre vanilla = child 0)
# UI slider de dureté (mode soft crop) — intégré au panneau du SelectTool
var _crop_slider_row  : Control = null   # widget (label + ligne slider) sous le bouton ON/OFF
var _crop_slider      : HSlider = null
var _crop_spin        : SpinBox = null
var _crop_slider_label : Label = null
var _crop_slider_syncing := false
var _crop_slider_before : Dictionary = {} # snapshot unified au début d'une rafale de réglage
var _crop_soft_before_node : Node2D = null
# UI slider d'opacité de la partie cropée (crop ET soft crop). 100% = partie
# cropée invisible (défaut), 0% = partie cropée pleinement visible.
var _crop_op_row    : Control = null
var _crop_op_slider : HSlider = null
var _crop_op_spin   : SpinBox = null
var _crop_op_label  : Label = null
var _crop_op_syncing := false
var _crop_feather_dirty_node : Node2D = null
var _crop_feather_dirty_ms := 0
const CROP_SOFT_DEFAULT := 15            # douceur par défaut (%) = dureté 0.85

# ── Edge Crop (érosion du contour, type « shrink selection ») ───────────────
# Props uniquement. Réduit l'asset depuis l'extérieur en suivant son contour
# (alpha), pour retirer une outline trop marquée. Deux réglages stockés par
# node dans ModMapData["_ft_edgecrop"] = { key -> {px:int, hard:float} }.
#   px   : nombre de pixels rognés sur le pourtour
#   hard : 0.0 = bord très doux (fondu large) ... 1.0 = coupe nette
const EDGECROP_PX_DEFAULT := 2
const EDGECROP_PX_MAX := 500
const EDGECROP_HARD_DEFAULT := 0.85
const EDGECROP_SOFT_MULT := 2.5          # largeur max de la bande de fondu (× radius)
const _EDGECROP_ALPHA_THR := 0.03        # alpha <= seuil => pixel « extérieur »
var _edge_px_row     : Control = null
var _edge_px_slider  : HSlider = null
var _edge_px_spin    : SpinBox = null
var _edge_hard_row   : Control = null
var _edge_hard_slider : HSlider = null
var _edge_hard_spin  : SpinBox = null
var _edge_syncing    := false
# Boutons outils (Copy / Paste / Use as Default / Factory) + presse-papier de
# réglages edge crop (session) et défaut utilisateur persistant.
var _edge_tools_row   : Control = null
var _edge_copy_btn    : Button = null
var _edge_paste_btn   : Button = null
var _edge_default_btn : Button = null
var _edge_factory_btn : Button = null
var _edgecrop_clip    : Dictionary = {}
var _edgecrop_default_px := EDGECROP_PX_DEFAULT
var _edgecrop_default_hard := EDGECROP_HARD_DEFAULT
var _edgecrop_default_loaded := false

# ── Shader warp (distort / perspective / skew coins) ─────────────────────
# Warp bilinéaire inverse : 4 coins totalement indépendants.
# Deux variantes : avec et sans custom color (tint_r).

const DISTORT_SHADER_SRC = """shader_type canvas_item;
uniform vec2 corner_tl;
uniform vec2 corner_tr;
uniform vec2 corner_br;
uniform vec2 corner_bl;
uniform vec2 uv_min = vec2(0.0,0.0);
uniform vec2 uv_max = vec2(1.0,1.0);
varying vec2 v_local;
void vertex(){
\tvec2 t=(UV-uv_min)/max(uv_max-uv_min,vec2(0.0001));
\tVERTEX=mix(mix(corner_tl,corner_tr,t.x),mix(corner_bl,corner_br,t.x),t.y);
\tv_local=VERTEX;
}
float cr(vec2 a,vec2 b){return a.x*b.y-a.y*b.x;}
vec2 warp_uv(vec2 p){
\tvec2 a=corner_tl,b=corner_tr,c=corner_br,d=corner_bl;
\tvec2 e=b-a,f=d-a,g=a-b+c-d,h=p-a;
\tfloat k2=cr(g,f),k1=cr(e,f)+cr(h,g),k0=cr(h,e);
\tfloat v;
\tif(abs(k2)<1e-5){v=-k0/k1;}
\telse{
\t\tfloat sq=sqrt(max(k1*k1-4.0*k0*k2,0.0));
\t\tfloat v1=(-k1-sq)/(2.0*k2),v2=(-k1+sq)/(2.0*k2);
\t\tv=(v1>=-0.001&&v1<=1.001)?v1:v2;
\t}
\tvec2 den=e+g*v;
\tfloat u=abs(den.x)>abs(den.y)?(h.x-f.x*v)/den.x:(h.y-f.y*v)/den.y;
\treturn uv_min+clamp(vec2(u,v),0.0,1.0)*(uv_max-uv_min);
}
void fragment(){
\tCOLOR=texture(TEXTURE,warp_uv(v_local));
}
"""

const DISTORT_SHADER_CUSTOM_COLOR_SRC = """shader_type canvas_item;
uniform vec2 corner_tl;
uniform vec2 corner_tr;
uniform vec2 corner_br;
uniform vec2 corner_bl;
uniform vec2 uv_min = vec2(0.0,0.0);
uniform vec2 uv_max = vec2(1.0,1.0);
uniform vec4 tint_r : hint_color;
uniform float min_redness = 0.1;
uniform float red_tolerance = 0.04;
uniform float min_saturation = 0.0;
varying vec2 v_local;
void vertex(){
\tvec2 t=(UV-uv_min)/max(uv_max-uv_min,vec2(0.0001));
\tVERTEX=mix(mix(corner_tl,corner_tr,t.x),mix(corner_bl,corner_br,t.x),t.y);
\tv_local=VERTEX;
}
float cr(vec2 a,vec2 b){return a.x*b.y-a.y*b.x;}
float luma(vec3 col){return dot(col,vec3(0.299,0.587,0.114));}
vec2 warp_uv(vec2 p){
\tvec2 a=corner_tl,b=corner_tr,c=corner_br,d=corner_bl;
\tvec2 e=b-a,f=d-a,g=a-b+c-d,h=p-a;
\tfloat k2=cr(g,f),k1=cr(e,f)+cr(h,g),k0=cr(h,e);
\tfloat v;
\tif(abs(k2)<1e-5){v=-k0/k1;}
\telse{
\t\tfloat sq=sqrt(max(k1*k1-4.0*k0*k2,0.0));
\t\tfloat v1=(-k1-sq)/(2.0*k2),v2=(-k1+sq)/(2.0*k2);
\t\tv=(v1>=-0.001&&v1<=1.001)?v1:v2;
\t}
\tvec2 den=e+g*v;
\tfloat u=abs(den.x)>abs(den.y)?(h.x-f.x*v)/den.x:(h.y-f.y*v)/den.y;
\treturn uv_min+clamp(vec2(u,v),0.0,1.0)*(uv_max-uv_min);
}
void fragment(){
\tvec4 original=texture(TEXTURE,warp_uv(v_local));
\tbool is_red=abs(original.g-original.b)<=red_tolerance;
\tbool in_sat=1.0-((original.g+original.b)*0.5)>=min_saturation;
\tfloat redness=original.r-(original.g+original.b)*0.5;
\tvec3 texel;
\tif(is_red&&in_sat&&redness>min_redness){
\t\ttexel=original.r*tint_r.rgb;
\t\tfloat l=luma(original.rgb);
\t\tif(l>0.333) texel=mix(texel,vec3(1.0),l-0.333);
\t} else {
\t\ttexel=original.rgb;
\t}
\tCOLOR=vec4(texel,original.a);
}
"""


# Shader pour patterns : warp bilinéaire inverse dans le fragment,
# reproduit fidèlement le pipeline DD : textureSize(), rotation UV, wear, COLOR *=.
const PATTERN_DISTORT_SHADER_SRC = """shader_type canvas_item;
uniform vec2 ft_corner_tl;
uniform vec2 ft_corner_tr;
uniform vec2 ft_corner_br;
uniform vec2 ft_corner_bl;
uniform vec2 ft_orig_min;
uniform vec2 ft_orig_size;
uniform sampler2D albedo;
uniform float rotation = 0.0;
uniform bool use_wear = false;
uniform sampler2D wear;
varying vec2 v_local;
vec2 rotate_uv(vec2 uv, float r){
\tfloat mid=0.5;
\treturn vec2(
\t\tcos(r)*(uv.x-mid)+sin(r)*(uv.y-mid)+mid,
\t\tcos(r)*(uv.y-mid)-sin(r)*(uv.x-mid)+mid
\t);
}
void vertex(){
\tv_local=VERTEX;
}
float cr(vec2 a,vec2 b){return a.x*b.y-a.y*b.x;}
vec2 inv_bilinear(vec2 p){
\tvec2 a=ft_corner_tl,b=ft_corner_tr,c=ft_corner_br,d=ft_corner_bl;
\tvec2 e=b-a,f=d-a,g=a-b+c-d,h=p-a;
\tfloat k2=cr(g,f),k1=cr(e,f)+cr(h,g),k0=cr(h,e);
\tfloat v;
\tif(abs(k2)<1e-5){v=-k0/k1;}
\telse{
\t\tfloat sq=sqrt(max(k1*k1-4.0*k0*k2,0.0));
\t\tfloat v1=(-k1-sq)/(2.0*k2),v2=(-k1+sq)/(2.0*k2);
\t\tv=(v1>=-0.001&&v1<=1.001)?v1:v2;
\t}
\tvec2 den=e+g*v;
\tfloat u=abs(den.x)>abs(den.y)?(h.x-f.x*v)/den.x:(h.y-f.y*v)/den.y;
\treturn clamp(vec2(u,v),0.0,1.0);
}
void fragment(){
\tvec2 t=inv_bilinear(v_local);
\tvec2 orig_pos=ft_orig_min+t*ft_orig_size;
\tivec2 size=textureSize(albedo,0);
\tvec2 world_uv=orig_pos;
\tworld_uv.x/=float(size.x);
\tworld_uv.y/=float(size.y);
\tworld_uv=rotate_uv(world_uv,rotation);
\tCOLOR*=texture(albedo,world_uv);
\tif(use_wear){
\t\tivec2 wear_size=textureSize(wear,0)*2;
\t\tvec2 w_uv=orig_pos;
\t\tw_uv.x/=float(wear_size.x);
\t\tw_uv.y/=float(wear_size.y);
\t\tCOLOR.rgb*=texture(wear,w_uv).rgb;
\t}
}
"""

# Variante du shader pattern avec custom color (tint via COLOR du Polygon2D).
# Reproduit le pipeline de DD PatternCustomColor.shader avec le warp bilinéaire.
const PATTERN_DISTORT_SHADER_CUSTOM_COLOR_SRC = """shader_type canvas_item;
uniform vec2 ft_corner_tl;
uniform vec2 ft_corner_tr;
uniform vec2 ft_corner_br;
uniform vec2 ft_corner_bl;
uniform vec2 ft_orig_min;
uniform vec2 ft_orig_size;
uniform sampler2D albedo;
uniform float rotation = 0.0;
uniform bool use_wear = false;
uniform sampler2D wear;
varying vec2 v_local;
vec2 rotate_uv(vec2 uv, float r){
\tfloat mid=0.5;
\treturn vec2(
\t\tcos(r)*(uv.x-mid)+sin(r)*(uv.y-mid)+mid,
\t\tcos(r)*(uv.y-mid)-sin(r)*(uv.x-mid)+mid
\t);
}
void vertex(){
\tv_local=VERTEX;
}
float cr(vec2 a,vec2 b){return a.x*b.y-a.y*b.x;}
vec2 inv_bilinear(vec2 p){
\tvec2 a=ft_corner_tl,b=ft_corner_tr,c=ft_corner_br,d=ft_corner_bl;
\tvec2 e=b-a,f=d-a,g=a-b+c-d,h=p-a;
\tfloat k2=cr(g,f),k1=cr(e,f)+cr(h,g),k0=cr(h,e);
\tfloat v;
\tif(abs(k2)<1e-5){v=-k0/k1;}
\telse{
\t\tfloat sq=sqrt(max(k1*k1-4.0*k0*k2,0.0));
\t\tfloat v1=(-k1-sq)/(2.0*k2),v2=(-k1+sq)/(2.0*k2);
\t\tv=(v1>=-0.001&&v1<=1.001)?v1:v2;
\t}
\tvec2 den=e+g*v;
\tfloat u=abs(den.x)>abs(den.y)?(h.x-f.x*v)/den.x:(h.y-f.y*v)/den.y;
\treturn clamp(vec2(u,v),0.0,1.0);
}
void fragment(){
\tvec2 t=inv_bilinear(v_local);
\tvec2 orig_pos=ft_orig_min+t*ft_orig_size;
\tivec2 size=textureSize(albedo,0);
\tvec2 world_uv=orig_pos;
\tworld_uv.x/=float(size.x);
\tworld_uv.y/=float(size.y);
\tworld_uv=rotate_uv(world_uv,rotation);
\tvec4 original=texture(albedo,world_uv);
\tvec3 texel;
\tfloat redness=original.r-(original.g+original.b)*0.5;
\tif(redness>0.0){
\t\tfloat intensity=smoothstep(0.0,0.5,redness);
\t\ttexel=mix(original.rgb,COLOR.rgb*original.r,intensity);
\t} else {
\t\ttexel=original.rgb;
\t}
\tif(use_wear){
\t\tivec2 wear_size=textureSize(wear,0)*2;
\t\tvec2 w_uv=orig_pos;
\t\tw_uv.x/=float(wear_size.x);
\t\tw_uv.y/=float(wear_size.y);
\t\ttexel*=texture(wear,w_uv).rgb;
\t}
\tCOLOR=vec4(texel,COLOR.a*original.a);
}
"""




# ══ Setup ══════════════════════════════════════════════════════════════════

func initialize() -> void:
	print("[FreeTransform] Initialisation")
	# Register ourselves so other mods can query the enabled state and
	# adapt their UI / input handling accordingly (e.g. select_rotation
	# hides its rotation slider while FT is active).
	if _g.ModMapData != null:
		_g.ModMapData["_free_transform"] = self
	_try_setup(0)


func _try_setup(attempt: int) -> void:
	if attempt > 20:
		print("[FreeTransform] Setup échoué"); return
	var vp     = _g.World.get_tree().root.get_node_or_null("Master/ViewportContainer2D/Viewport2D")
	var anchor = _g.Editor.get_node_or_null("VPartition/Panels/Tools/Anchor")
	if vp == null or anchor == null:
		_g.World.get_tree().create_timer(0.2).connect("timeout", self, "_try_setup", [attempt + 1])
		return
	_do_setup()


func _do_setup() -> void:
	var vp = _g.World.get_tree().root.get_node_or_null("Master/ViewportContainer2D/Viewport2D")
	if vp == null: return
	_viewport_path = vp.get_path()

	var anchor = _g.Editor.get_node_or_null("VPartition/Panels/Tools/Anchor")
	if anchor: _anchor_path = anchor.get_path()

	var tools = _g.Editor.get("Tools")
	if tools != null and tools.has("SelectTool"):
		_select_tool = tools["SelectTool"]

	var uu = ResourceLoader.load(_g.Root + "scripts/ui_util.gd", "GDScript", true)
	if uu: _ui_util = uu.new()

	_load_assets()

	# Overlay Node2D dans World
	# N.B. : on ne fait update() que si FT a besoin de dessiner, sinon le
	# CanvasItem dirty permanent peut déclencher le rebuild de la grille DD
	# et écraser les grilles custom d'autres mods (ex. Snappy Grid).
	var ov = GDScript.new()
	ov.source_code = "extends Node2D\nvar handler = null\nvar _was_drawing = false\nfunc _process(_d):\n\tvar need = handler and handler._needs_overlay()\n\tif need or _was_drawing:\n\t\tupdate()\n\t_was_drawing = need\nfunc _draw():\n\tif handler:\n\t\thandler._draw_overlay(self)\n"
	ov.reload()
	_overlay = Node2D.new()
	_overlay.name = "FreeTransformOverlay"
	# Au-dessus de tout : z absolu maximal (ignore le z des assets sous le curseur).
	_overlay.z_as_relative = false
	_overlay.z_index = VisualServer.CANVAS_ITEM_Z_MAX
	_overlay.set_script(ov)
	_overlay.handler = self
	_g.World.call_deferred("add_child", _overlay)

	# Listener input — reste dans World (nettoyé au changement de map) mais
	# PAS en position 0 : move_child(0) décalait GridMesh et cassait Snappy.
	var il = GDScript.new()
	il.source_code = "extends Node\nvar handler = null\nfunc _input(e):\n\tif handler:\n\t\thandler._on_input(e)\n"
	il.reload()
	_input_listener = Node.new()
	_input_listener.name = "FreeTransformListener"
	_input_listener.set_script(il)
	_input_listener.handler = self
	_g.World.add_child(_input_listener)

	# CanvasLayer pour le menu contextuel (au-dessus de l'UI de DD)
	var pl = CanvasLayer.new()
	pl.name = "FreeTransformPopupLayer"
	pl.layer = 128
	_g.World.get_tree().root.add_child(pl)
	_popup_layer = pl

	print("[FreeTransform] Prêt")
	_try_button_setup(0)
	# Charge les données persistées depuis le fichier JSON (si existant)
	_load_ft_data()


func _load_assets() -> void:
	var files = {
		"resize-nwse": [0, 4], "resize-nesw": [2, 6],
		"resize-ns":   [1, 5], "resize-ew":   [3, 7],
		"rotate":      [8],
	}
	for fname in files.keys():
		var img = Image.new()
		if img.load(_g.Root + "icons/" + fname + ".png") != OK: continue
		var tex = ImageTexture.new()
		tex.create_from_image(img, 0)
		for idx in files[fname]: _cursors[idx] = tex
	print("[FreeTransform] Curseurs : ", _cursors.keys())

	var img2 = Image.new()
	if img2.load(_g.Root + "icons/drag-cursor-icon.png") == OK:
		_move_cursor_tex = ImageTexture.new()
		_move_cursor_tex.create_from_image(img2, 0)

	var img_h = Image.new()
	if img_h.load(_g.Root + "icons/drag-cursor-icon-h.png") == OK:
		_drag_cursor_h = ImageTexture.new()
		_drag_cursor_h.create_from_image(img_h, 0)

	var img_v = Image.new()
	if img_v.load(_g.Root + "icons/drag-cursor-icon-v.png") == OK:
		_drag_cursor_v = ImageTexture.new()
		_drag_cursor_v.create_from_image(img_v, 0)

	var img3 = Image.new()
	if img3.load(_g.Root + "icons/handle_round.png") == OK:
		_handle_tex = ImageTexture.new()
		_handle_tex.create_from_image(img3, 0)


# ══ Persistence save/load + clone level ════════════════════════════════════

# Clé unique de la map courante = hash du chemin fichier (unique par définition).
func _map_save_id() -> String:
	var path = _g.Editor.get("CurrentMapFile")
	if path != null and path is String and path != "":
		return path.sha256_text().substr(0, 16)
	# Fallback pour les maps pas encore sauvées
	var title = _g.World.get("Title")
	if title == null or title == "": title = "untitled"
	var w = _g.World.get("Width")
	var h = _g.World.get("Height")
	var raw = str(title) + "_" + str(w) + "x" + str(h) + "_new"
	return raw.sha256_text().substr(0, 16)


# Stores ModMapData à persister dans le fichier JSON.
const _FT_PERSIST_KEYS = [
	"_ft_distort", "_ft_crop", "_ft_crop_soft", "_ft_crop_feather", "_ft_crop_opacity", "_ft_edgecrop", "_ft_transforms",
	"_ft_pattern_orig", "_ft_pattern_orig_pos", "_ft_pattern_reset", "_ft_pattern_world",
	"_portal_offsets", "_ft_orig_xform",
]
# Single ModMapData key under which we persist a snapshot of all the
# stores listed above. DD persists ModMapData inside the .dungeondraft_map
# file so the data follows the map naturally — no external JSON keyed
# by hash, no rename / save-as breakage.
const FT_DATA_MMD_KEY = "_ft_persisted_data"


func _ft_save_path() -> String:
	# Used by _ft_save_path_legacy for one-time migration from the older
	# external-JSON storage. The current save target is ModMapData (see
	# _save_ft_data).
	var dir = Directory.new()
	if not dir.dir_exists("user://UnofficialPatch"):
		dir.make_dir_recursive("user://UnofficialPatch")
	if not dir.dir_exists("user://UnofficialPatch/free_transform"):
		dir.make_dir_recursive("user://UnofficialPatch/free_transform")
		# Migrate any older saves from user://free_transform/ so the
		# legacy lookup below finds them at the expected location.
		_migrate_old_ft_saves(dir)
	return "user://UnofficialPatch/free_transform/" + _map_save_id() + ".json"


func _migrate_old_ft_saves(dir: Directory) -> void:
	var old_root = "user://free_transform"
	if not dir.dir_exists(old_root):
		return
	var probe = Directory.new()
	if probe.open(old_root) != OK:
		return
	probe.list_dir_begin(true, true)
	var fname = probe.get_next()
	while fname != "":
		if not probe.current_is_dir():
			var src = old_root + "/" + fname
			var dst = "user://UnofficialPatch/free_transform/" + fname
			# Only copy when target doesn't already exist, so re-running
			# this migration doesn't clobber newer data.
			var probe2 = File.new()
			if not probe2.file_exists(dst):
				dir.copy(src, dst)
		fname = probe.get_next()
	probe.list_dir_end()
	print("[FreeTransform] Migrated old saves from user://free_transform/ to user://UnofficialPatch/free_transform/")


func _save_ft_data() -> void:
	# FT data lives inside ModMapData under FT_DATA_MMD_KEY. DD persists
	# ModMapData inside the .dungeondraft_map file, so this:
	#   - automatically follows the map on rename/save-as
	#   - never leaks into a different map that happens to share a name
	#   - removes the need for an external JSON keyed by file hash
	# We still build a snapshot (copy of the side-stores) so future
	# reads see a stable version even if the live stores get edited.
	var data = {}
	for key in _FT_PERSIST_KEYS:
		if _g.ModMapData.has(key):
			var store = _g.ModMapData[key]
			if store is Dictionary and not store.empty():
				data[key] = store
	# Always write — even an empty dict, so a reset/clear gets persisted
	# rather than letting an old snapshot stick.
	_g.ModMapData[FT_DATA_MMD_KEY] = data


func _load_ft_data() -> void:
	# First, opportunistically migrate any pre-existing JSON file from
	# the old external storage. Once migrated we delete the file so we
	# don't pick it up again next time the map loads.
	_migrate_legacy_json_to_mmd()
	# Now load from ModMapData (the canonical source going forward).
	var data = _g.ModMapData.get(FT_DATA_MMD_KEY, null)
	if not (data is Dictionary):
		return
	var loaded_any = false
	for key in _FT_PERSIST_KEYS:
		if data.has(key) and data[key] is Dictionary:
			if not _g.ModMapData.has(key):
				_g.ModMapData[key] = {}
			# Don't overwrite runtime data of a current session.
			var store = _g.ModMapData[key]
			for k in data[key].keys():
				if not store.has(k):
					store[k] = data[key][k]
					loaded_any = true
	if loaded_any:
		print("[FreeTransform] Données FT restaurées depuis la map (ModMapData)")


func _migrate_legacy_json_to_mmd() -> void:
	# Old versions stored FT data per-map in user://UnofficialPatch/free_transform/<hash>.json
	# (and even older: user://free_transform/<hash>.json). The hash was
	# derived from CurrentMapFile, which broke when:
	#   - the map was saved under a new name (hash changes mid-session)
	#   - a different map happened to be saved at the same path
	# We migrate the legacy file (if any) into ModMapData on first load
	# so users don't lose their data, then delete the legacy file.
	var path = _ft_save_path_legacy()
	var file = File.new()
	if not file.file_exists(path):
		return
	if file.open(path, File.READ) != OK:
		return
	var text = file.get_as_text()
	file.close()
	var parsed = JSON.parse(text)
	if parsed.error != OK or not parsed.result is Dictionary:
		return
	# Don't overwrite anything that's already in ModMapData (e.g. if the
	# user saved + reloaded after a partial migration). Merge instead.
	var existing = _g.ModMapData.get(FT_DATA_MMD_KEY, {})
	if not (existing is Dictionary):
		existing = {}
	for key in parsed.result.keys():
		if not existing.has(key):
			existing[key] = parsed.result[key]
	_g.ModMapData[FT_DATA_MMD_KEY] = existing
	# Remove the now-redundant external file.
	var d = Directory.new()
	d.remove(path)
	print("[FreeTransform] Migrated FT data from ", path, " into ModMapData")


func _ft_save_path_legacy() -> String:
	# Legacy path used by older versions of this mod. Only used now to
	# detect & migrate existing data on first load.
	return "user://UnofficialPatch/free_transform/" + _map_save_id() + ".json"

# ── Bouton toggle ─────────────────────────────────────────────────────────

func _ensure_button_alive() -> void:
	# DD reconstruit parfois le panneau du SelectTool (changement de type d'asset,
	# etc.), ce qui détruit notre widget FT (bouton + slider). On le détecte et on
	# le ré-ajoute pour éviter un FT "brické" (bouton disparu, impossible à réactiver).
	if _ui_group != null and is_instance_valid(_ui_group):
		return
	if _input_listener == null or not is_instance_valid(_input_listener):
		return
	var anchor = _input_listener.get_node_or_null(_anchor_path)
	if anchor == null:
		return
	for child in anchor.get_children():
		if str(child.get("ForceTool")) == "SelectTool":
			var align = child.get_node_or_null("Divider/SelectToolPanel/Align")
			if align == null or align.get_child_count() == 0:
				return
			# Nettoie d'éventuels restes (références obsolètes) avant de ré-ajouter.
			for nm in ["FreeTransformGroup", "FreeTransformCropSoftness", "FreeTransformCropOpacity", "FreeTransformEdgeCropPx", "FreeTransformEdgeCropHard", "FreeTransformEdgeCropTools"]:
				var leftover = align.get_node_or_null(nm)
				if leftover != null:
					align.remove_child(leftover)
					leftover.queue_free()
			_toggle_btn = null
			_lock_btn = null
			_ui_group = null
			_crop_slider_row = null
			_crop_slider = null
			_crop_spin = null
			_crop_slider_label = null
			_crop_op_row = null
			_crop_op_slider = null
			_crop_op_spin = null
			_crop_op_label = null
			_edge_px_row = null
			_edge_px_slider = null
			_edge_px_spin = null
			_edge_hard_row = null
			_edge_hard_slider = null
			_edge_hard_spin = null
			_edge_tools_row = null
			_edge_copy_btn = null
			_edge_paste_btn = null
			_edge_default_btn = null
			_edge_factory_btn = null
			_add_button(align)
			# Restaure l'état visuel du toggle selon l'état réel de FT.
			if _toggle_btn != null and is_instance_valid(_toggle_btn) and _toggle_btn.pressed != _enabled:
				_toggle_btn.pressed = _enabled
			return


func _try_button_setup(attempt: int) -> void:
	if attempt > 20: return
	if _input_listener == null or not is_instance_valid(_input_listener):
		_g.World.get_tree().create_timer(0.2).connect("timeout", self, "_try_button_setup", [attempt + 1])
		return
	var anchor = _input_listener.get_node_or_null(_anchor_path)
	if anchor == null:
		_g.World.get_tree().create_timer(0.2).connect("timeout", self, "_try_button_setup", [attempt + 1])
		return
	for child in anchor.get_children():
		if str(child.get("ForceTool")) == "SelectTool":
			var align = child.get_node_or_null("Divider/SelectToolPanel/Align")
			if align != null and align.get_child_count() > 0:
				_add_button(align); return
			break
	_g.World.get_tree().create_timer(0.2).connect("timeout", self, "_try_button_setup", [attempt + 1])


func _add_button(align: Node) -> void:
	if align.get_node_or_null("FreeTransformGroup") != null: return
	var group = HBoxContainer.new()
	group.name = "FreeTransformGroup"
	group.focus_mode = Control.FOCUS_NONE
	var lbl = Label.new()
	lbl.text = "Free Transform (Beta)"
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.focus_mode = Control.FOCUS_NONE
	var reset_btn = _make_reset_button("Reset to original aspect")
	reset_btn.connect("pressed", self, "_on_reset_scale")
	var lock_btn = _make_lock_button()
	lock_btn.connect("toggled", self, "_on_lock_toggle")
	var btn = CheckButton.new()
	btn.hint_tooltip = "Various transform modes (Right Click to show the dropdown menu)"
	btn.focus_mode = Control.FOCUS_NONE
	btn.connect("toggled", self, "_on_toggle")
	group.add_child(lbl)
	group.add_child(reset_btn)
	group.add_child(lock_btn)
	group.add_child(btn)
	align.add_child(group)
	align.move_child(group, 12)
	# Widget "Soft Crop" : label sur une ligne, puis slider + spinbox + reset.
	# Placé juste sous la ligne Free Transform. Visible seulement en mode soft crop.
	var sbox = VBoxContainer.new()
	sbox.name = "FreeTransformCropSoftness"
	sbox.focus_mode = Control.FOCUS_NONE
	var slbl = Label.new()
	slbl.text = "Soft Crop"
	slbl.focus_mode = Control.FOCUS_NONE
	var srow = HBoxContainer.new()
	srow.focus_mode = Control.FOCUS_NONE
	var sld = HSlider.new()
	sld.min_value = 0
	sld.max_value = 200
	sld.step = 1
	sld.value = CROP_SOFT_DEFAULT
	sld.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sld.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sld.focus_mode = Control.FOCUS_NONE
	sld.rect_min_size = Vector2(110, 0)
	var spin = SpinBox.new()
	spin.min_value = 0
	spin.max_value = 200
	spin.step = 1
	spin.value = CROP_SOFT_DEFAULT
	spin.suffix = "%"
	spin.focus_mode = Control.FOCUS_CLICK
	var rst = _make_reset_button("Reset soft edge")
	rst.connect("pressed", self, "_on_crop_reset_pressed")
	srow.add_child(sld)
	srow.add_child(spin)
	srow.add_child(rst)
	sbox.add_child(slbl)
	sbox.add_child(srow)
	align.add_child(sbox)
	align.move_child(sbox, group.get_index() + 1)
	sbox.visible = false
	sld.connect("value_changed", self, "_on_crop_slider_changed")
	spin.connect("value_changed", self, "_on_crop_spin_changed")
	_crop_slider_row   = sbox
	_crop_slider       = sld
	_crop_spin         = spin
	_crop_slider_label = slbl

	# Widget "Crop opacity" : opacité de la partie cropée. Visible en mode
	# crop ET soft crop. 100% = partie cropée invisible (défaut).
	var obox = VBoxContainer.new()
	obox.name = "FreeTransformCropOpacity"
	obox.focus_mode = Control.FOCUS_NONE
	var olbl = Label.new()
	olbl.text = "Crop opacity"
	olbl.focus_mode = Control.FOCUS_NONE
	var orow = HBoxContainer.new()
	orow.focus_mode = Control.FOCUS_NONE
	var osld = HSlider.new()
	osld.min_value = 0
	osld.max_value = 100
	osld.step = 1
	osld.value = CROP_OPACITY_STRENGTH_DEFAULT
	osld.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	osld.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	osld.focus_mode = Control.FOCUS_NONE
	osld.rect_min_size = Vector2(110, 0)
	var ospin = SpinBox.new()
	ospin.min_value = 0
	ospin.max_value = 100
	ospin.step = 1
	ospin.value = CROP_OPACITY_STRENGTH_DEFAULT
	ospin.suffix = "%"
	ospin.focus_mode = Control.FOCUS_CLICK
	var orst = _make_reset_button("Reset crop opacity")
	orst.connect("pressed", self, "_on_crop_opacity_reset_pressed")
	orow.add_child(osld)
	orow.add_child(ospin)
	orow.add_child(orst)
	obox.add_child(olbl)
	obox.add_child(orow)
	align.add_child(obox)
	align.move_child(obox, group.get_index() + 1)
	obox.visible = false
	osld.connect("value_changed", self, "_on_crop_opacity_changed")
	ospin.connect("value_changed", self, "_on_crop_opacity_spin_changed")
	_crop_op_row    = obox
	_crop_op_slider = osld
	_crop_op_spin   = ospin
	_crop_op_label  = olbl

	# Widget "Edge Crop" : deux lignes (px rognés + dureté). Visibles seulement
	# en mode edge crop. Rognage du contour de l'asset depuis l'extérieur.
	var ebox = VBoxContainer.new()
	ebox.name = "FreeTransformEdgeCropPx"
	ebox.focus_mode = Control.FOCUS_NONE
	var elbl = Label.new()
	elbl.text = "Edge Crop (px)"
	elbl.focus_mode = Control.FOCUS_NONE
	var erow = HBoxContainer.new()
	erow.focus_mode = Control.FOCUS_NONE
	var esld = HSlider.new()
	esld.min_value = 0
	esld.max_value = EDGECROP_PX_MAX
	esld.step = 1
	esld.value = EDGECROP_PX_DEFAULT
	esld.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	esld.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	esld.focus_mode = Control.FOCUS_NONE
	esld.rect_min_size = Vector2(110, 0)
	var espin = SpinBox.new()
	espin.min_value = 0
	espin.max_value = EDGECROP_PX_MAX
	espin.step = 1
	espin.value = EDGECROP_PX_DEFAULT
	espin.suffix = "px"
	espin.focus_mode = Control.FOCUS_CLICK
	var erst = _make_reset_button("Reset edge crop amount")
	erst.connect("pressed", self, "_on_edge_reset_pressed", ["px"])
	erow.add_child(esld)
	erow.add_child(espin)
	erow.add_child(erst)
	ebox.add_child(elbl)
	ebox.add_child(erow)
	align.add_child(ebox)
	align.move_child(ebox, group.get_index() + 1)
	ebox.visible = false
	esld.connect("value_changed", self, "_on_edge_px_changed")
	espin.connect("value_changed", self, "_on_edge_px_changed")
	_edge_px_row    = ebox
	_edge_px_slider = esld
	_edge_px_spin   = espin

	var hbox = VBoxContainer.new()
	hbox.name = "FreeTransformEdgeCropHard"
	hbox.focus_mode = Control.FOCUS_NONE
	var hlbl = Label.new()
	hlbl.text = "Edge Hardness"
	hlbl.focus_mode = Control.FOCUS_NONE
	var hrow = HBoxContainer.new()
	hrow.focus_mode = Control.FOCUS_NONE
	var hsld = HSlider.new()
	hsld.min_value = 0
	hsld.max_value = 100
	hsld.step = 1
	hsld.value = int(round(EDGECROP_HARD_DEFAULT * 100.0))
	hsld.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hsld.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hsld.focus_mode = Control.FOCUS_NONE
	hsld.rect_min_size = Vector2(110, 0)
	var hspin = SpinBox.new()
	hspin.min_value = 0
	hspin.max_value = 100
	hspin.step = 1
	hspin.value = int(round(EDGECROP_HARD_DEFAULT * 100.0))
	hspin.suffix = "%"
	hspin.focus_mode = Control.FOCUS_CLICK
	var hrst = _make_reset_button("Reset edge hardness")
	hrst.connect("pressed", self, "_on_edge_reset_pressed", ["hard"])
	hrow.add_child(hsld)
	hrow.add_child(hspin)
	hrow.add_child(hrst)
	hbox.add_child(hlbl)
	hbox.add_child(hrow)
	align.add_child(hbox)
	align.move_child(hbox, group.get_index() + 2)
	hbox.visible = false
	hsld.connect("value_changed", self, "_on_edge_hard_changed")
	hspin.connect("value_changed", self, "_on_edge_hard_changed")
	_edge_hard_row    = hbox
	_edge_hard_slider = hsld
	_edge_hard_spin   = hspin

	# Ligne d'outils : Copy / Paste (réglages), Use as Default, Factory.
	var tbox = VBoxContainer.new()
	tbox.name = "FreeTransformEdgeCropTools"
	tbox.focus_mode = Control.FOCUS_NONE
	var trow = HBoxContainer.new()
	trow.focus_mode = Control.FOCUS_NONE
	var cbtn = Button.new()
	cbtn.text = "Copy"
	cbtn.hint_tooltip = "Copy this asset's edge crop settings"
	cbtn.focus_mode = Control.FOCUS_NONE
	cbtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cbtn.connect("pressed", self, "_on_edge_copy_pressed")
	var pbtn = Button.new()
	pbtn.text = "Paste"
	pbtn.hint_tooltip = "Paste copied edge crop settings onto this asset"
	pbtn.focus_mode = Control.FOCUS_NONE
	pbtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pbtn.connect("pressed", self, "_on_edge_paste_pressed")
	var dbtn = Button.new()
	dbtn.text = "Default"
	dbtn.hint_tooltip = "Use these settings as the default for new edge crops"
	dbtn.focus_mode = Control.FOCUS_NONE
	dbtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dbtn.connect("pressed", self, "_on_edge_default_pressed")
	var fbtn = Button.new()
	fbtn.text = "Factory"
	fbtn.hint_tooltip = "Restore factory default edge crop settings"
	fbtn.focus_mode = Control.FOCUS_NONE
	fbtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fbtn.connect("pressed", self, "_on_edge_factory_pressed")
	trow.add_child(cbtn)
	trow.add_child(pbtn)
	trow.add_child(dbtn)
	trow.add_child(fbtn)
	tbox.add_child(trow)
	align.add_child(tbox)
	align.move_child(tbox, group.get_index() + 3)
	tbox.visible = false
	_edge_tools_row   = tbox
	_edge_copy_btn    = cbtn
	_edge_paste_btn   = pbtn
	_edge_default_btn = dbtn
	_edge_factory_btn = fbtn

	_toggle_btn = btn
	_lock_btn   = lock_btn
	_ui_group   = group

	print("[FreeTransform] Bouton ajouté")


# Hide ou show l'integralite du widget FT du panel SelectTool (label,
# reset, lock, toggle). Utilise par le toggle "Free Transform" du Settings
# panel via ft_context.gd.
# Met aussi _widget_force_hidden pour que la logique de visibilite par-frame
# (qui re-affiche le group quand has_selection devient true) respecte ce
# choix. Si FT est actif au moment de la desactivation, on le force off
# pour eviter un overlay zombie.
func set_widget_visible(visible: bool) -> void:
	_widget_force_hidden = not visible
	if _ui_group != null and is_instance_valid(_ui_group):
		_ui_group.visible = visible
	if not visible and _crop_slider_row != null and is_instance_valid(_crop_slider_row):
		_crop_slider_row.visible = false
	if not visible and _crop_op_row != null and is_instance_valid(_crop_op_row):
		_crop_op_row.visible = false
	if not visible and _edge_px_row != null and is_instance_valid(_edge_px_row):
		_edge_px_row.visible = false
	if not visible and _edge_hard_row != null and is_instance_valid(_edge_hard_row):
		_edge_hard_row.visible = false
	if not visible and _edge_tools_row != null and is_instance_valid(_edge_tools_row):
		_edge_tools_row.visible = false
	if not visible and _enabled and _toggle_btn != null and is_instance_valid(_toggle_btn):
		_toggle_btn.pressed = false
		_toggle_btn.emit_signal("toggled", false)


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
	btn.focus_mode = Control.FOCUS_NONE
	btn.icon = _load_icon("icons/reset.png", 0.5)
	return btn


func _make_lock_button() -> Button:
	var btn = Button.new()
	btn.focus_mode = Control.FOCUS_NONE
	btn.toggle_mode = true
	btn.icon = _load_icon("icons/unlock.png", 0.65)
	btn.hint_tooltip = "Autoquit: Free Transform turns off automatically\nwhen leaving SelectTool or selecting an incompatible asset.\nClick to lock FT in persistent mode."
	return btn


func _snapshot_orig_xform(nd) -> void:
	# Capture (une seule fois) le transform d'un prop AVANT toute opération FT,
	# pour que "Reset free transform" restaure cet état vanilla (rotation/scale
	# d'origine) au lieu de tout remettre à zéro. Ne fait rien si le node a déjà
	# des données FT (= état pré-FT manqué, ex. asset transformé avant cette maj).
	if nd == null or not is_instance_valid(nd):
		return
	if not _is_plain_prop(nd):
		return
	var key = _ft_node_key(nd)
	if key == "":
		return
	if not _g.ModMapData.has("_ft_orig_xform"):
		_g.ModMapData["_ft_orig_xform"] = {}
	var store = _g.ModMapData["_ft_orig_xform"]
	if store.has(key):
		return
	if _g.ModMapData.get("_ft_transforms", {}).has(key) \
			or _g.ModMapData.get("_ft_distort", {}).has(key) \
			or _g.ModMapData.get("_ft_crop", {}).has(key):
		return
	var t = nd.transform
	store[key] = {
		"xx": t.x.x, "xy": t.x.y,
		"yx": t.y.x, "yy": t.y.y,
		"ox": t.origin.x, "oy": t.origin.y,
	}


func rotate_ft_node(nd, rad: float, pivot: Vector2) -> bool:
	# Tourne un node FT (distort / perspective / skew) EN LOCKSTEP avec sa base
	# stockée, autour de pivot (monde). rotation_fix délègue ici au lieu de
	# sauter ces nodes (sinon seule la box tournait, pas l'asset). Pousse son
	# propre enregistrement d'undo unifié. Retourne true si géré.
	if nd == null or not is_instance_valid(nd):
		return false
	var key = _ft_node_key(nd)
	if key == "":
		return false
	var shear = _g.ModMapData.get("_ft_transforms", {})
	var distort = _g.ModMapData.get("_ft_distort", {})
	if not shear.has(key) and not distort.has(key):
		return false
	var before = _capture_ft_unified([nd])
	var ab0 = _prop_aabb(nd)
	var vc0 = ab0.position + ab0.size * 0.5
	var vct = pivot + (vc0 - pivot).rotated(rad)
	if shear.has(key):
		# Tourne la base stockée ; _reapply_shear_transforms la réappliquera.
		# Les coins distort (stockés en LOCAL) suivent automatiquement.
		var d = shear[key]
		var rb = Transform2D(rad, Vector2.ZERO) * Transform2D(
			Vector2(d.xx, d.xy), Vector2(d.yx, d.yy), Vector2.ZERO)
		nd.transform = Transform2D(rb.x, rb.y, nd.position)
		_store_shear_transform(nd, nd.transform)
	else:
		# Distort sans base shear : rotation simple (coins locaux suivent).
		nd.rotation += rad
	# Orbite : recale le centre visuel pour qu'il tourne autour du pivot.
	var ab1 = _prop_aabb(nd)
	var vc1 = ab1.position + ab1.size * 0.5
	nd.global_position += (vct - vc1)
	if shear.has(key):
		_store_shear_transform(nd, nd.transform)
	_save_ft_data()
	_record_ft_unified_change(before, _capture_ft_unified([nd]))
	return true


func _on_reset_scale() -> void:
	if _selected_objects.empty(): return
	_group_warp_corners = []  # reset la box groupe warpée
	# Choose path. For a simple selection we capture before/after
	# ourselves and push a unified record; for mixed we let DD capture
	# the transforms and we capture the extras alongside.
	var simple = _ft_selection_is_simple(_selected_objects)
	var unified_before = _capture_ft_unified(_selected_objects)
	if not simple and _select_tool != null:
		_select_tool.call("SavePreTransforms")
	for nd in _selected_objects:
		if not is_instance_valid(nd): continue
		if _is_portal(nd):
			# Capture le scale avant reset pour normaliser le Radius
			var old_scale_x = abs(nd.scale.x)
			nd.scale = Vector2(1, 1)
			var sprite = nd.get("Sprite")
			if sprite != null:
				sprite.position = Vector2.ZERO
			if old_scale_x > 0.001:
				nd.set("Radius", nd.get("Radius") / old_scale_x)
			_portal_tex_cache.erase(nd.get_instance_id())
			var wall = _get_portal_wall(nd)
			if wall != null:
				wall.call("RemakeLines")
		elif _is_path(nd):
			nd.scale    = Vector2(1, 1)
			nd.rotation = 0.0
			nd.transform = Transform2D(Vector2(1, 0), Vector2(0, 1), nd.position)
		elif _is_pattern(nd):
			# Restaure la position originale
			var key = _ft_node_key(nd)
			if key != "" and _g.ModMapData.has("_ft_pattern_orig_pos") \
					and _g.ModMapData["_ft_pattern_orig_pos"].has(key):
				var pos = _g.ModMapData["_ft_pattern_orig_pos"][key]
				nd.position = Vector2(pos[0], pos[1])
			# Restaure le vrai polygon original
			if key != "" and _g.ModMapData.has("_ft_pattern_reset") \
					and _g.ModMapData["_ft_pattern_reset"].has(key):
				var flat = _g.ModMapData["_ft_pattern_reset"][key]
				if flat is Array and flat.size() >= 6:
					var pool = PoolVector2Array()
					for i in range(0, flat.size(), 2):
						pool.append(Vector2(flat[i], flat[i + 1]))
					nd.polygon = pool
					var outline = nd.get("Outline")
					if outline != null and outline is Line2D:
						var pts = PoolVector2Array()
						for p in pool:
							pts.append(p)
						if pts.size() > 0:
							pts.append(pts[0])
						outline.points = pts
			nd.scale    = Vector2(1, 1)
			nd.rotation = 0.0
			nd.transform = Transform2D(Vector2(1, 0), Vector2(0, 1), nd.position)
			# Nettoie toutes les données pattern
			if key != "":
				for store_name in ["_ft_pattern_orig", "_ft_pattern_orig_pos", "_ft_pattern_reset", "_ft_pattern_world"]:
					if _g.ModMapData.has(store_name):
						_g.ModMapData[store_name].erase(key)
		else:
			# Restaure l'état pré-FT (rotation/scale vanilla) si capturé, sinon
			# remet à zéro (défaut / assets FT avant cette maj).
			var _okey = _ft_node_key(nd)
			var _orig = _g.ModMapData.get("_ft_orig_xform", {})
			if _okey != "" and _orig.has(_okey):
				var o = _orig[_okey]
				nd.transform = Transform2D(Vector2(o.xx, o.xy), Vector2(o.yx, o.yy), Vector2(o.ox, o.oy))
			else:
				nd.scale    = Vector2(1, 1)
				nd.rotation = 0.0
		# Le snapshot pré-FT n'a plus lieu d'être après reset (un prochain FT
		# re-snapshotera l'état vanilla restauré).
		var _rk = _ft_node_key(nd)
		if _rk != "" and _g.ModMapData.has("_ft_orig_xform"):
			_g.ModMapData["_ft_orig_xform"].erase(_rk)
		_clear_shear_transform(nd)
		_remove_distort_shader(nd)
		_remove_crop(nd)
		_remove_edgecrop(nd)
	if not simple and _select_tool != null:
		_select_tool.call("RecordTransforms")
	# After reset, capture and push a unified record that restores
	# transforms + extras in one shot.
	var unified_after = _capture_ft_unified(_selected_objects)
	_record_ft_unified_change(unified_before, unified_after)
	_save_ft_data()
	print("[FreeTransform] Scale reset")


func _on_toggle(pressed: bool) -> void:
	_enabled = pressed
	_g.ModMapData["_free_transform_active"] = pressed
	if not _enabled:
		_g.ModMapData["_free_transform_portal"] = false
		if _active_handle >= 0:
			_commit_handle_drag()
			_active_handle = -1
		# Restaure tout de suite le hover/filtres DD.
		if _hover_suppressed:
			_ft_restore_filters()
			_hover_suppressed = false
		_g.ModMapData["_ft_hover_block"] = false


func _on_lock_toggle(pressed: bool) -> void:
	_lock_mode = pressed
	if _lock_btn != null and is_instance_valid(_lock_btn):
		if pressed:
			_lock_btn.icon = _load_icon("icons/lock.png", 0.65)
			_lock_btn.hint_tooltip = "Locked: Free Transform stays active regardless of\nselection or active tool.\nClick to restore autoquit mode."
		else:
			_lock_btn.icon = _load_icon("icons/unlock.png", 0.65)
			_lock_btn.hint_tooltip = "Autoquit: Free Transform turns off automatically\nwhen leaving SelectTool or selecting an incompatible asset.\nClick to lock FT in persistent mode."


func _auto_disable_ft(reason: String) -> void:
	if not _enabled: return
	print("[FreeTransform] Auto-disabled: ", reason)
	if _toggle_btn != null and is_instance_valid(_toggle_btn):
		_toggle_btn.pressed = false
	_on_toggle(false)


# ── Suppression hover/overlay DD (repris du mécanisme de pan_fix) ──────────

func _update_hover_suppression(select_active: bool) -> void:
	var want = _enabled and select_active and _selected_objects.size() > 0
	if want and not _hover_suppressed:
		_clear_current_highlight()
		_ft_snapshot_and_clear_filters()
		_hover_suppressed = true
		_g.ModMapData["_ft_hover_block"] = true
	elif not want and _hover_suppressed:
		_ft_restore_filters()
		_hover_suppressed = false
		_g.ModMapData["_ft_hover_block"] = false
	elif want and _hover_suppressed:
		# Garde le hover éteint si DD a réussi à en rallumer un.
		_clear_current_highlight()


func _clear_current_highlight() -> void:
	# Éteint directement la box de hover courante (DD ne l'éteint que dans
	# HighlightThingAtPoint, qu'on neutralise). Mappe le switch Highlight() de DD
	# selon le type de Selectable.
	if _select_tool == null:
		return
	var hl = _select_tool.get("highlighted")
	if hl == null:
		return
	var thing = hl.get("Thing")
	if thing == null or not is_instance_valid(thing):
		return
	var t = hl.get("Type")  # 1=Wall 2=PortalFree 3=PortalWall 4=Object 5=Pathway 6=Light 7=PatternShape 8=Roof
	var w = null
	match t:
		1, 6, 7:
			if thing.has_method("GetWidget"):
				w = thing.call("GetWidget")
		5:
			w = thing.get("Widget")
		2, 3, 4, 8:
			w = thing
	if w != null and is_instance_valid(w) and w.has_method("Highlight"):
		w.call("Highlight", false)


func _ft_find_filter_menu():
	if _ft_filter_menu != null and is_instance_valid(_ft_filter_menu):
		return _ft_filter_menu
	# Réutilise le PopupMenu déjà résolu par text_transform si dispo.
	var ttf = _g.ModMapData.get("_ttf_transform") if _g.ModMapData is Dictionary else null
	if ttf != null and is_instance_valid(ttf):
		var p = ttf.get("_filter_popup")
		if p != null and is_instance_valid(p):
			_ft_filter_menu = p
			return _ft_filter_menu
	if _g.Editor == null:
		return null
	var anchor = _g.Editor.get_node_or_null("VPartition/Panels/Tools/Anchor")
	if anchor == null:
		return null
	for child in anchor.get_children():
		if str(child.get("ForceTool")) != "SelectTool":
			continue
		var align = child.get_node_or_null("Divider/SelectToolPanel/Align")
		if align == null:
			return null
		for ch in align.get_children():
			if ch is MenuButton and str(ch.get("text")) == "FILTER":
				_ft_filter_menu = ch.get_popup()
				return _ft_filter_menu
		return null
	return null


func _ft_snapshot_and_clear_filters() -> void:
	# SetFilterChecked (C#) est un toggle : on ne décoche que les items cochés
	# et on retient ceux qu'on a touchés pour les recocher à la sortie. On saute
	# l'index 0 ("All") et "Texts" (géré séparément).
	_ft_toggled_filter_items = []
	var menu = _ft_find_filter_menu()
	if menu != null:
		for i in range(1, menu.get_item_count()):
			if menu.get_item_text(i) == "Texts":
				continue
			if menu.is_item_checked(i):
				menu.emit_signal("id_pressed", menu.get_item_id(i))
				_ft_toggled_filter_items.append(i)
	# Filtre "Texts" géré par text_transform via son propre flag.
	_ft_texts_filter_was = null
	var ttf = _g.ModMapData.get("_ttf_transform") if _g.ModMapData is Dictionary else null
	if ttf != null and is_instance_valid(ttf):
		_ft_texts_filter_was = ttf.get("_texts_filter_enabled")
		ttf.set("_texts_filter_enabled", false)


func _ft_restore_filters() -> void:
	var menu = _ft_find_filter_menu()
	if menu != null:
		for i in _ft_toggled_filter_items:
			if i < menu.get_item_count():
				menu.emit_signal("id_pressed", menu.get_item_id(i))
	_ft_toggled_filter_items = []
	if _ft_texts_filter_was != null:
		var ttf = _g.ModMapData.get("_ttf_transform") if _g.ModMapData is Dictionary else null
		if ttf != null and is_instance_valid(ttf):
			ttf.set("_texts_filter_enabled", _ft_texts_filter_was)
	_ft_texts_filter_was = null



# ══ Update ═════════════════════════════════════════════════════════════════

func _ensure_world_nodes_alive() -> void:
	# Re-create the overlay Node2D if it was destroyed (typically by a
	# map reload, which queue_frees the entire World subtree).
	if _overlay == null or not is_instance_valid(_overlay):
		var ov = GDScript.new()
		ov.source_code = "extends Node2D\nvar handler = null\nvar _was_drawing = false\nfunc _process(_d):\n\tvar need = handler and handler._needs_overlay()\n\tif need or _was_drawing:\n\t\tupdate()\n\t_was_drawing = need\nfunc _draw():\n\tif handler:\n\t\thandler._draw_overlay(self)\n"
		ov.reload()
		_overlay = Node2D.new()
		_overlay.name = "FreeTransformOverlay"
		# Au-dessus de tout : z absolu maximal.
		_overlay.z_as_relative = false
		_overlay.z_index = VisualServer.CANVAS_ITEM_Z_MAX
		_overlay.set_script(ov)
		_overlay.handler = self
		_g.World.add_child(_overlay)
	# Same for the input listener.
	if _input_listener == null or not is_instance_valid(_input_listener):
		var il = GDScript.new()
		il.source_code = "extends Node\nvar handler = null\nfunc _input(e):\n\tif handler:\n\t\thandler._on_input(e)\n"
		il.reload()
		_input_listener = Node.new()
		_input_listener.name = "FreeTransformListener"
		_input_listener.set_script(il)
		_input_listener.handler = self
		_g.World.add_child(_input_listener)


func update(_delta: float) -> void:
	if _viewport_path.is_empty(): return
	var tree = _g.World.get_tree()
	var select_active = _is_select_tool_active(tree)
	
	# At map reload time, _overlay and _input_listener are children of
	# World and get queue_freed along with the old map's World. Without
	# them, FT silently stops receiving inputs and stops drawing the
	# selection box — the user notices because right-click doesn't open
	# the FT menu anymore. Re-create them when we detect the loss.
	var _ft0 = OS.get_ticks_usec()
	_ensure_world_nodes_alive()
	_ftp("ensure_world", _ft0)
	_ft0 = OS.get_ticks_usec()
	_ensure_button_alive()
	_ftp("ensure_button", _ft0)

	# Neutralise le hover/sélection des autres assets tant que FT édite.
	var _ft1 = OS.get_ticks_usec()
	_update_hover_suppression(select_active)
	_ftp("hover_suppression", _ft1)

	# Slider de dureté (soft crop) : géré chaque frame (gère lui-même show/hide)
	# + cuisson différée quand on relâche/laisse reposer le slider.
	var _ft2 = OS.get_ticks_usec()
	_update_crop_slider_ui()
	_update_crop_opacity_ui()
	_update_edgecrop_ui()
	_ftp("crop_ui", _ft2)
	if _crop_feather_dirty_node != null:
		if not is_instance_valid(_crop_feather_dirty_node):
			_crop_feather_dirty_node = null
		elif _has_edgecrop(_crop_feather_dirty_node) \
				and Input.is_mouse_button_pressed(BUTTON_LEFT):
			# Edge crop : cuissons lourdes (jusqu'à 500px) → on attend le relâché
			# de la souris pour ne pas cuire à chaque pas pendant le drag du slider.
			pass
		elif OS.get_ticks_msec() - _crop_feather_dirty_ms >= 100:
			_flush_crop_feather_bake()
	
	# Detect Ctrl+S that just renamed an untitled map: the save id
	# (derived from CurrentMapFile when set, or a placeholder when not)
	# changes from one frame to the next. If the previous file exists,
	# copy it to the new id so the transform data follows the rename.
	# We re-save afterwards anyway, but copying first ensures the data
	# survives even if no commit happens before the next reload.
	# Keep _free_transform_active synced with the real toggle state.
	# Other mods (right_click_util, favorites) read this flag to decide
	# whether to show their own context menus. After a map reload the
	# flag can persist as `true` from the previous session even though
	# FT is actually disabled, blocking the right-click menu entirely.
	if _g.ModMapData != null:
		var stored = _g.ModMapData.get("_free_transform_active", null)
		if stored != _enabled:
			_g.ModMapData["_free_transform_active"] = _enabled

	# Restaure les offsets au plus tôt — avant le guard SelectTool
	var _ft3 = OS.get_ticks_usec()
	_restore_portal_offsets()
	_ftp("restore_portal_offsets", _ft3)
	# Restaure les transforms/shaders dès que le World est dispo.
	# Pour les patterns, on skip UNIQUEMENT quand PatternShapeTool est actif
	# (sinon la création de nouveaux patterns bugue). Dans tous les autres cas
	# (ouverture de map, SelectTool, ObjectTool, etc.), on restaure normalement.
	var pattern_tool_active = _g.Editor.get("ActiveToolName") == "PatternShapeTool"
	var _ft4 = OS.get_ticks_usec()
	_reapply_shear_transforms(not pattern_tool_active)
	_ftp("reapply_shear", _ft4)
	_ft4 = OS.get_ticks_usec()
	_restore_distort_from_store(not pattern_tool_active)
	_ftp("restore_distort", _ft4)
	_ft4 = OS.get_ticks_usec()
	_restore_crop_from_store(not pattern_tool_active)
	_ftp("restore_crop", _ft4)
	_ft4 = OS.get_ticks_usec()
	_restore_edgecrop_from_store(not pattern_tool_active)
	_ftp("restore_edgecrop", _ft4)

	# Auto-disable FT si on vient de quitter le SelectTool (et qu'on n'est pas locké)
	if _was_select_active and not select_active and _enabled and not _lock_mode:
		_auto_disable_ft("left SelectTool")
	_was_select_active = select_active

	if not select_active:
		_selected_objects.clear()
		_reset_cursor()
		return

	# Idle fast-path : en SelectTool mais rien de sélectionné et hors drag.
	# _collect_selected_props() ci-dessous fait un DFS complet de la carte
	# CHAQUE frame — inutile quand la sélection DD est vide. RawSelectables
	# couvre tous les selectables (props, patterns, paths, portals, walls),
	# donc un test de taille suffit pour court-circuiter sans rien casser.
	if _active_handle < 0:
		var _raw = _select_tool.RawSelectables if _select_tool != null else null
		if _raw == null or _raw.size() == 0:
			# DD a tout désélectionné. Si on est verrouillé et que ce n'est PAS
			# une désélection volontaire (clic loin), on rétablit le verrou.
			if _enabled and _ft_lock.size() > 0:
				if _ft_lock_reassert < 8 and _select_tool != null:
					_ft_lock_reassert += 1
					_select_tool.transformMode = 0
					_select_tool.DeselectAll()
					var _any := false
					for nd in _ft_lock:
						if is_instance_valid(nd):
							_select_tool.SelectThing(nd, true)
							_any = true
					if _any:
						return
				# Trop d'échecs (asset parti, autre level…) → on lâche.
				_ft_lock = []
				_ft_lock_reassert = 0
			# Plus de verrou / désélection volontaire déjà faite à l'input.
			_ft_lock = []
			if _selected_objects.size() > 0:
				_selected_objects.clear()
				_crop_node = null
			if _toggle_btn != null and is_instance_valid(_toggle_btn):
				var _grp = _toggle_btn.get_parent()
				if _grp != null and _grp.visible:
					_grp.visible = false
			if _g.ModMapData != null:
				_g.ModMapData["_free_transform_portal"] = false
			_reset_cursor()
			return

	# Rafraîchit la sélection
	var vp = tree.root.get_node_or_null(_viewport_path)
	if vp == null: return
	var world = vp.get_node_or_null("World")
	if world == null: return
	var fresh : Array = []
	_collect_selected_props(world, fresh, 0)
	# Ajoute les patterns et paths depuis SelectTool.Selected
	if _select_tool != null:
		var sel = _select_tool.get("Selected")
		if sel != null:
			for nd in sel:
				if is_instance_valid(nd) and (_is_pattern(nd) or _is_path(nd)) and not fresh.has(nd):
					fresh.append(nd)
	# Props/portals/patterns/paths seulement (pas les Line2D de walls, pas les roofs, pas les lights)
	var fresh_props : Array = []
	for nd in fresh:
		if _is_roof(nd) or _is_light(nd):
			continue
		if _is_path(nd):
			fresh_props.append(nd)
		elif not (nd is Line2D) and not _is_wall(nd):
			fresh_props.append(nd)

	# ── Verrou de sélection FT (Feature 1) ───────────────────────────────
	# DD a déjà appliqué la sélection. Si elle diffère du verrou, on la
	# rétablit (aucun switch autorisé). La désélection volontaire (clic loin)
	# est gérée directement à l'input (_on_input) : elle vide la sélection et
	# le verrou, donc ici fresh_props sera vide → rien à rétablir.
	if _enabled:
		var _lock_alive := []
		for nd in _ft_lock:
			if is_instance_valid(nd):
				_lock_alive.append(nd)
		_ft_lock = _lock_alive
		if _ft_lock.size() == 0:
			# Pas de verrou : on verrouille sur la sélection compatible courante.
			if fresh_props.size() > 0:
				_ft_lock = fresh_props.duplicate()
				_ft_lock_reassert = 0
		elif not _same_selection(fresh_props, _ft_lock):
			# DD a basculé sur un autre asset → on rétablit le verrou (appels
			# directs, comme DragSelectWalls / alt_deselect).
			if _ft_lock_reassert < 8 and _select_tool != null:
				_ft_lock_reassert += 1
				_select_tool.transformMode = 0
				_select_tool.DeselectAll()
				for nd in _ft_lock:
					if is_instance_valid(nd):
						_select_tool.SelectThing(nd, true)
				fresh = _ft_lock.duplicate()
				fresh_props = _ft_lock.duplicate()
			else:
				_ft_lock = []
				_ft_lock_reassert = 0
		else:
			_ft_lock_reassert = 0
	else:
		_ft_lock = []

	if fresh_props.size() > 0:
		if fresh_props != _selected_objects:
			_group_warp_corners = []  # nouvelle sélection → reset coins groupe
			# Reset _portal_mode only on a *real* selection change — i.e.
			# the new selection isn't just the previous one re-emerging
			# after a transient empty frame. Without this guard,
			# preserve_selection_undo's empty-then-restore cycle around
			# Ctrl+Z would clobber an undone _portal_mode change because
			# both the empty frame and the restore frame look like
			# selection changes here.
			if _selected_objects.size() > 0:
				_portal_mode = "scale"
			_crop_node = null  # force re-ensure du crop sur la nouvelle sélection
		_selected_objects = fresh_props
	else:
		if _active_handle < 0:
			_selected_objects.clear()
			_crop_node = null   # force le rechargement du crop à la prochaine sélection
			# Don't reset _portal_mode here either — the empty selection
			# may be transient (preserve_selection_undo restores 2 frames
			# later). The reset below ("not is_portal_sel") still runs
			# normally for genuine non-portal selections.

	# Vrai état sélectionné = fresh_props (pas _selected_objects qui persiste pour Ctrl+Z)
	var has_selection = fresh_props.size() > 0
	var is_portal_sel = has_selection and _all_portals()

	# Auto-disable FT si la sélection devient exclusivement incompatible
	# (sélection non vide, mais aucun asset compatible — ex : walls seuls, roofs, lights)
	# Cas "rien sélectionné" → on ne désactive pas (l'utilisateur peut re-sélectionner).
	if _enabled and not _lock_mode and fresh.size() > 0 and fresh_props.size() == 0:
		_auto_disable_ft("incompatible selection")

	# Crop / Soft Crop ne supportent qu'UN seul prop simple. Si on sélectionne un
	# asset qui ne supporte pas ce type de transform (autre type, multi-sélection),
	# on sort du mode crop et on désactive FT. Re-sélectionner le même prop simple
	# reste supporté → FT reste actif dans le même mode (cf. bloc "ensure" plus bas).
	if _enabled and not _lock_mode and has_selection and _is_crop_mode() \
			and not (fresh_props.size() == 1 and _is_plain_prop(fresh_props[0])):
		_transform_mode = "free"   # quitte le mode crop pour que le ré-ON soit utilisable
		_auto_disable_ft("crop mode unsupported by selection")

	# Reset le mode portal si la sélection contient autre chose que des
	# portals — but only when the selection isn't empty. An empty
	# selection is treated as transient (see comment above) so we keep
	# the previous _portal_mode until something concrete replaces it.
	if has_selection and not is_portal_sel:
		_portal_mode = "scale"

	# Expose portal selection state for other mods (wall_move, overlay_tool)
	_g.ModMapData["_free_transform_portal"] = _enabled and is_portal_sel

	# Note: si des paths sont en distort/perspective, le warning popup gère la situation

	# Gestion de la box DD :
	# - FT actif → cache la box DD chaque frame (notre overlay remplace)
	# - FT inactif → on ne touche pas à la box DD, on la laisse gérer par DD
	if _enabled and _select_tool != null and fresh.size() > 0:
		_select_tool.call("EnableTransformBox", false)

	# Bouton : visibilité basée sur fresh_props (déselection immédiate).
	# _widget_force_hidden override quand l'utilisateur a desactive le
	# toggle "Free Transform" dans le Settings panel — sinon le group se
	# reaffiche des qu'un asset compatible est selectionne.
	if _toggle_btn != null and is_instance_valid(_toggle_btn):
		var group = _toggle_btn.get_parent()
		if group != null:
			group.visible = has_selection and not _widget_force_hidden


	# Détecte les changements de type de portal et rafraîchit le mur
	_watch_portal_textures()
	# Sauvegarde la rotation des portals sélectionnés si elle a changé
	_watch_portal_rotations()

	# Crop : (re)charge le polygone du prop sélectionné si nécessaire
	if _enabled and _is_crop_mode() and _selected_objects.size() == 1 \
			and _is_plain_prop(_selected_objects[0]):
		if _crop_node != _selected_objects[0] or _crop_points.size() < 3:
			_ensure_crop_for_node(_selected_objects[0])

	# Edge Crop : applique le mode au prop nouvellement sélectionné, sinon les
	# sliders disparaissent jusqu'à ce qu'on resélectionne le mode.
	if _enabled and _transform_mode == "edgecrop" and _selected_objects.size() == 1 \
			and _is_plain_prop(_selected_objects[0]) and not _has_edgecrop(_selected_objects[0]):
		_ensure_edgecrop_for_node(_selected_objects[0])

	# Curseurs — réécrits chaque frame pour gagner sur DD
	if _enabled and vp != null:
		# Curseur normal si le menu est ouvert ou si la souris est sur l'UI
		var menu_open = _context_menu != null and is_instance_valid(_context_menu) and _context_menu.visible
		var over_ui = _ui_util != null and _ui_util.is_mouse_over_ui(_input_listener)
		if menu_open or over_ui:
			_reset_cursor()
		elif _active_handle >= 0:
			var wp = _mouse_world(vp)
			_set_cursor(_active_handle)
		else:
			if _is_crop_mode() and _selected_objects.size() == 1 \
					and _is_plain_prop(_selected_objects[0]):
				_reset_cursor()
				return
			var wp = _mouse_world(vp)
			var resolved = false
			if _selected_objects.size() > 0:
				# Portals : la zone intérieure est toujours grab, handles seulement à l'extérieur
				if _all_portals() and _selection_aabb().has_point(wp):
					if _mod_alt:
						_set_cursor(1)  # NS = glissement perpendiculaire
					else:
						_set_move_cursor()  # drag-cursor-icon = glissement le long du mur
					resolved = true
				else:
					var hit = _hit_handle(wp, vp)
					if hit >= 0:
						_set_cursor(hit)
						resolved = true
					elif _selection_aabb().has_point(wp):
						_set_move_cursor()
						resolved = true
			if not resolved:
				_reset_cursor()
	elif not _enabled:
		_reset_cursor()


func _ftp(name: String, t0: int) -> void:
	# Section profiler hook for update(). Accumulates per-section usec into
	# ModMapData["_prof_ft"] when Main's F10 profiler is active. Zero cost off.
	if _g == null or not (_g.ModMapData is Dictionary) or not _g.ModMapData.get("_prof_dsw_on", false):
		return
	var d = _g.ModMapData.get("_prof_ft", null)
	if not (d is Dictionary):
		d = {}
		_g.ModMapData["_prof_ft"] = d
	d[name] = d.get(name, 0) + (OS.get_ticks_usec() - t0)


func _is_select_tool_active(tree) -> bool:
	var anchor = _g.Editor.get_node_or_null("VPartition/Panels/Tools/Anchor")
	if anchor == null: return false
	for child in anchor.get_children():
		if str(child.get("ForceTool")) == "SelectTool":
			return child.visible
	return false


func _collect_selected_props(node: Node, result: Array, depth: int) -> void:
	if depth > 6: return
	for child in node.get_children():
		var is_sel = child.get("isSelected")
		if is_sel != null and bool(is_sel) == true:
			if child is Node2D and not (child is Control):
				if child is Line2D:
					var parent = child.get_parent()
					if parent != null and parent.has_method("RemakeLines") and not result.has(parent):
						result.append(parent)
				elif not result.has(child):   # ← garde doublon
					result.append(child)
			# Ne pas récurser dans un node sélectionné (ses enfants appartiennent à l'asset)
		elif is_sel == null:
			# Seulement si le node n'a pas du tout la propriété isSelected
			# (évite de récurser dans des nodes qui ont isSelected=false)
			if child.get_child_count() > 0:
				_collect_selected_props(child, result, depth + 1)


# ══ Curseurs ═══════════════════════════════════════════════════════════════

func _set_cursor(handle_idx: int) -> void:
	# En mode skew, les bords déplacent le contenu le long de l'arête.
	# On calcule la direction réelle de l'arête depuis les coins actuels (après déformation).
	if _transform_mode == "skew" and handle_idx in EDGE_IDX:
		var c : Array = []
		if _group_warp_corners.size() == 4:
			c = _group_warp_corners
		elif _selected_objects.size() == 1 and is_instance_valid(_selected_objects[0]):
			c = _prop_corners(_selected_objects[0])
		else:
			var bb = _selection_aabb()
			if bb.size.length() > 1.0:
				c = [bb.position, bb.position + Vector2(bb.size.x, 0),
					bb.position + bb.size, bb.position + Vector2(0, bb.size.y)]
		if c.size() == 4:
				var edge_dir : Vector2
				match handle_idx:
					1: edge_dir = c[1] - c[0]  # TC → along top edge (TL→TR)
					5: edge_dir = c[2] - c[3]  # BC → along bottom edge (BL→BR)
					3: edge_dir = c[2] - c[1]  # MR → along right edge (TR→BR)
					7: edge_dir = c[3] - c[0]  # ML → along left edge (TL→BL)
					_: edge_dir = Vector2.RIGHT
				var deg = fmod(rad2deg(edge_dir.angle()), 180.0)
				if deg < 0: deg += 180.0
				var snapped = round(deg / 45.0) * 45.0
				snapped = fmod(snapped, 180.0)
				var tex = null
				if   snapped < 22.5:   tex = _drag_cursor_h      # EW → H
				elif snapped < 67.5:   tex = _cursors.get(0)     # NWSE → diag
				elif snapped < 112.5:  tex = _drag_cursor_v      # NS → V
				else:                  tex = _cursors.get(2)     # NESW → diag
				if tex != null:
					Input.set_custom_mouse_cursor(tex, Input.CURSOR_ARROW, tex.get_size() / 2)
					_cursor_active = true
					return

	# Détermine la rotation de l'objet sélectionné (0 si groupe ou pas de sélection)
	var rot_rad = 0.0
	if _selected_objects.size() == 1 and is_instance_valid(_selected_objects[0]):
		rot_rad = _selected_objects[0].rotation

	# Angle local de l'axe de resize pour chaque handle (en degrés, mod 180)
	var local_deg : float
	match handle_idx:
		1, 5:            local_deg = 90.0   # NS
		3, 7:            local_deg = 0.0    # EW
		0, 4:            local_deg = 45.0   # diagonale TL-BR
		2, 6:            local_deg = 135.0  # diagonale TR-BL
		IDX_SLIDE:       local_deg = 90.0   # perpendiculaire au mur
		IDX_WALK:        local_deg = 0.0    # le long du mur
		IDX_MOVE, IDX_ROT, _:
			if handle_idx == IDX_MOVE:
				_set_move_cursor()
				return
			if _cursors.has(handle_idx):
				var tex = _cursors[handle_idx]
				Input.set_custom_mouse_cursor(tex, Input.CURSOR_ARROW, tex.get_size() / 2)
				_cursor_active = true
			else:
				_reset_cursor()
			return

	# Angle monde = angle local + rotation de l'objet, ramené à [0, 180[
	var world_deg = fmod(local_deg + rad2deg(rot_rad), 180.0)
	if world_deg < 0: world_deg += 180.0

	# Snapping vers le curseur le plus proche parmi {0, 45, 90, 135}
	var snapped = round(world_deg / 45.0) * 45.0
	snapped = fmod(snapped, 180.0)

	# Résolution vers la texture correspondante
	var cursor_idx : int
	if   snapped < 22.5:   cursor_idx = 3   # EW
	elif snapped < 67.5:   cursor_idx = 0   # NWSE
	elif snapped < 112.5:  cursor_idx = 1   # NS
	else:                  cursor_idx = 2   # NESW

	if _cursors.has(cursor_idx):
		var tex = _cursors[cursor_idx]
		Input.set_custom_mouse_cursor(tex, Input.CURSOR_ARROW, tex.get_size() / 2)
		_cursor_active = true
	else:
		_reset_cursor()


func _set_move_cursor() -> void:
	if _move_cursor_tex != null:
		Input.set_custom_mouse_cursor(_move_cursor_tex, Input.CURSOR_ARROW, _move_cursor_tex.get_size() / 2)
		_cursor_active = true
	else:
		_reset_cursor()


func _reset_cursor() -> void:
	if _cursor_active:
		Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)
		_cursor_active = false


# ══ Input ══════════════════════════════════════════════════════════════════

func _on_input(event: InputEvent) -> void:
	if _viewport_path.is_empty(): return
	var tree = _g.World.get_tree()
	if not _is_select_tool_active(tree): return

	# Observe Ctrl+Z pour sauvegarder la sélection — sans jamais consommer
	if event is InputEventKey:
		if event.pressed and not event.echo and event.control and event.scancode == KEY_Z:
			_save_selection_for_undo()
		return

	if not (event is InputEventMouseButton or event is InputEventMouseMotion): return
	_mod_shift = event.shift; _mod_alt = event.alt

	if not _enabled: return
	if _selected_objects.size() == 0 and _active_handle < 0: return
	var vp = tree.root.get_node_or_null(_viewport_path)
	if vp == null: return

	if _ui_util != null and _ui_util.is_mouse_over_ui(_input_listener): return

	var wp = _mouse_world(vp)

	# ── Crop : édition du polygone de masque ──────────────────────────────
	if _is_crop_mode() and _selected_objects.size() == 1 \
			and _is_plain_prop(_selected_objects[0]):
		var cnode = _selected_objects[0]
		if _crop_node != cnode:
			_ensure_crop_for_node(cnode)
		var csprite = _get_sprite_node(cnode)
		if csprite != null:
			if event is InputEventMouseButton and event.button_index == BUTTON_LEFT and event.pressed:
				var vhit = _crop_hit_vertex(wp, vp)
				if vhit >= 0:
					_crop_active_pt = vhit
					_crop_drag_before = _capture_ft_unified([cnode])
					tree.set_input_as_handled()
					return
				var ehit = _crop_hit_edge(wp, vp)
				if not ehit.empty() and _crop_points.size() < CROP_MAX_PTS:
					_crop_drag_before = _capture_ft_unified([cnode])
					_crop_points.insert(ehit["after"] + 1, ehit["lc"])
					_crop_active_pt = ehit["after"] + 1
					_store_crop_points(cnode)
					tree.set_input_as_handled()
					return
				if _selection_aabb().has_point(wp):
					# Clic dans la box → déplacement libre (on consomme).
					_start_handle_drag(IDX_MOVE, wp)
					tree.set_input_as_handled()
					return
				# Clic hors box : MÊME verrou Feature 1 que les autres modes
				# (proche de la box = bloqué ; loin = désélection volontaire),
				# au lieu de se baser sur l'AABB padatée du prop.
				if _active_handle < 0:
					if _click_near_selection(wp, vp):
						tree.set_input_as_handled()
					else:
						if _select_tool != null:
							_select_tool.transformMode = 0
							_select_tool.DeselectAll()
							_select_tool.EnableTransformBox(false)
						_selected_objects.clear()
						_crop_node = null
						_ft_lock = []
						_ft_lock_reassert = 0
						tree.set_input_as_handled()
				return
			elif event is InputEventMouseButton and event.button_index == BUTTON_RIGHT and event.pressed:
				var vhit2 = _crop_hit_vertex(wp, vp)
				if vhit2 >= 0 and _crop_points.size() > 3:
					var cbefore = _capture_ft_unified([cnode])
					_crop_points.remove(vhit2)
					_store_crop_points(cnode)
					_apply_crop(cnode, _crop_points)
					var cafter = _capture_ft_unified([cnode])
					_record_ft_unified_change(cbefore, cafter)
					_save_ft_data()
					tree.set_input_as_handled()
					return
				# sinon → laisse le menu contextuel s'ouvrir (code générique plus bas)
			elif event is InputEventMouseButton and event.button_index == BUTTON_LEFT and not event.pressed:
				if _crop_active_pt >= 0:
					_apply_crop(cnode, _crop_points)
					var cafter2 = _capture_ft_unified([cnode])
					_record_ft_unified_change(_crop_drag_before, cafter2)
					_save_ft_data()
					_crop_active_pt = -1
					tree.set_input_as_handled()
					return
				# sinon (déplacement objet via IDX_MOVE) → code générique plus bas
			elif event is InputEventMouseMotion and _crop_active_pt >= 0:
				var clc = (cnode.transform * csprite.transform).affine_inverse().xform(wp)
				_crop_points[_crop_active_pt] = clc
				_store_crop_points(cnode)
				tree.set_input_as_handled()
				return

	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT and event.pressed:
		var _ft_consumed := false
		# Portals : comportement selon le mode
		if _all_portals():
			var in_box = _selection_aabb().has_point(wp)
			match _portal_mode:
				"slide":
					# Mode slide : déplacement le long du mur uniquement
					if in_box:
						_start_handle_drag(IDX_WALK, wp)
						_ft_consumed = true
				"offset":
					# Mode offset : glissement perpendiculaire au mur uniquement
					if in_box:
						_start_handle_drag(IDX_SLIDE, wp)
						_ft_consumed = true
				_:  # "scale"
					# Mode scale : handles uniquement, pas de drag dans la box
					var hit = _hit_handle(wp, vp)
					if hit >= 0:
						_start_handle_drag(hit, wp)
						_ft_consumed = true
		else:
			# Objets normaux (non-portals)
			var hit = _hit_handle(wp, vp)
			if hit >= 0:
				_start_handle_drag(hit, wp)
				_ft_consumed = true
			elif _selected_objects.size() > 0 and _selection_aabb().has_point(wp):
				# Clic dans la bbox → déplacement libre via IDX_MOVE
				_start_handle_drag(IDX_MOVE, wp)
				_ft_consumed = true

		# Verrou FT (Feature 1). Critère = DISTANCE à la transform box :
		#   - clic PROCHE → on consomme (best-effort). Si DD sélectionne quand
		#     même un autre asset, le verrou dans update() le rétablit.
		#   - clic LOIN   → désélection VOLONTAIRE : on pose un flag traité par
		#     update() (DeselectAll + lâcher le verrou). On ne sélectionne
		#     jamais l'asset éventuellement sous le curseur.
		if not _ft_consumed and _selected_objects.size() > 0 and _active_handle < 0:
			if _click_near_selection(wp, vp):
				# Proche de la box → on bloque (consume). Si DD bascule quand
				# même sur un asset superposé, le verrou dans update() rétablit.
				_ft_consumed = true
			else:
				# Loin de la box → désélection VOLONTAIRE, traitée tout de suite
				# (comme DragSelectWalls) : on vide la sélection et on consomme
				# pour ne PAS sélectionner l'asset sous le curseur. FT reste
				# activé ; la prochaine sélection re-verrouille.
				if _select_tool != null:
					_select_tool.transformMode = 0
					_select_tool.DeselectAll()
					_select_tool.EnableTransformBox(false)
				_selected_objects.clear()
				_crop_node = null
				_ft_lock = []
				_ft_lock_reassert = 0
				_ft_consumed = true

		if _ft_consumed:
			tree.set_input_as_handled()

	elif event is InputEventMouseButton and event.button_index == BUTTON_RIGHT and event.pressed:
		# Menu contextuel du mode de transformation
		if _enabled and _selected_objects.size() > 0 and _active_handle < 0:
			if _ui_util == null or not _ui_util.is_mouse_over_ui(_input_listener):
				_show_transform_menu()
				tree.set_input_as_handled()

	elif event is InputEventMouseButton and event.button_index == BUTTON_LEFT and not event.pressed:
		if _active_handle >= 0:
			_commit_handle_drag()
			_active_handle = -1
			tree.set_input_as_handled()

	elif event is InputEventMouseMotion and _active_handle >= 0:
		_update_handle_drag(wp, vp)
		_sync_portal_radii(false)
		tree.set_input_as_handled()


# ══ Undo des actions FT ═══════════════════════════════════════════════
#
# DD's SavePreTransforms / RecordTransforms records standard transforms
# (position/rotation/scale) for the selection. Free transform also
# mutates two side-stores:
#   - ModMapData["_ft_transforms"][key] : the full Transform2D (with
#     shear) when the user has skewed an asset
#   - ModMapData["_ft_distort"][key]    : 8 floats describing the
#     distort corners (per-corner perspective warp)
#
# If we used DD's RecordTransforms PLUS our own callback record for the
# extras, two consecutive history records would be created per FT
# action, requiring two Ctrl+Z to fully revert (and producing
# half-restored states between them — the symptom the user sees as
# "skew remains after the size came back").
#
# The robust fix, modelled on DragSelectWalls' GroupTransformRecord, is
# to skip DD's record entirely and push a single unified callback that
# captures and restores BOTH the standard transforms AND the extras.
# That requires us to handle every node in the selection ourselves, so
# we only enable this path for selections of "regular" objects — no
# patterns, paths, portals or walls (which have their own state stores
# we don't snapshot here yet). For mixed selections we fall back to
# DD's record-only flow as before.

# Pending capture taken at the start of an FT action.
var _undo_unified_before: Dictionary = {}
var _undo_skip_dd_record: bool = false


func _ft_selection_is_simple(nodes: Array) -> bool:
	# True only when every node in the selection is a "regular" object
	# OR a portal OR a pattern — these three are handled fully by the
	# unified record path. Paths/walls keep the old 2-records flow.
	if nodes.empty():
		return false
	for nd in nodes:
		if not is_instance_valid(nd):
			continue
		if _is_path(nd):
			return false
		# Walls aren't in _selected_objects normally, but guard anyway.
		var t = -1
		if _select_tool != null and _select_tool.has_method("GetSelectableType"):
			t = _select_tool.call("GetSelectableType", nd)
		if t == 1:
			return false
	return true


func _capture_ft_unified(nodes: Array) -> Dictionary:
	# Snapshot per-node: standard transform (pos/rot/scale) + the
	# shear-transform entry + the distort-corners entry. Keyed by
	# ft_node_key so we can resolve the node back via _ft_node_from_key
	# at restore time. For portals we additionally capture Radius,
	# sprite.position and the matching _portal_offsets entry — those
	# aren't covered by DD's transform record but are mutated by FT
	# (scale changes Radius, slide moves sprite.position) and the wall
	# adapts itself around them via RemakeLines.
	# For patterns we capture the polygon (vertices, mutated on commit
	# by _bake_pattern_state) plus every pattern-related ModMapData
	# store (orig polygon, orig pos, reset baseline, world corners).
	var out: Dictionary = {}
	var transforms_store = _g.ModMapData.get("_ft_transforms", {})
	var distort_store = _g.ModMapData.get("_ft_distort", {})
	var crop_store = _g.ModMapData.get("_ft_crop", {})
	var crop_soft_store = _g.ModMapData.get("_ft_crop_soft", {})
	var crop_feather_store = _g.ModMapData.get("_ft_crop_feather", {})
	var crop_opacity_store = _g.ModMapData.get("_ft_crop_opacity", {})
	var edgecrop_store = _g.ModMapData.get("_ft_edgecrop", {})
	var portal_offsets_store = _g.ModMapData.get("_portal_offsets", {})
	var pattern_orig_store = _g.ModMapData.get("_ft_pattern_orig", {})
	var pattern_orig_pos_store = _g.ModMapData.get("_ft_pattern_orig_pos", {})
	var pattern_reset_store = _g.ModMapData.get("_ft_pattern_reset", {})
	var pattern_world_store = _g.ModMapData.get("_ft_pattern_world", {})
	for nd in nodes:
		if not is_instance_valid(nd):
			continue
		var key = _ft_node_key(nd)
		if key == "":
			continue
		var entry: Dictionary = {
			"position": nd.global_position,
			"rotation": nd.global_rotation,
			"scale": nd.global_scale,
		}
		if transforms_store.has(key):
			entry["transform"] = transforms_store[key].duplicate()
		if distort_store.has(key):
			entry["distort"] = distort_store[key].duplicate(true)
		if crop_store.has(key):
			entry["crop"] = crop_store[key].duplicate(true)
		if crop_soft_store.has(key):
			entry["crop_soft"] = crop_soft_store[key]
		if crop_feather_store.has(key):
			entry["crop_feather"] = crop_feather_store[key]
		if crop_opacity_store.has(key):
			entry["crop_opacity"] = crop_opacity_store[key]
		if edgecrop_store.has(key):
			entry["edgecrop"] = edgecrop_store[key].duplicate()
		# Portal-specific extras.
		if _is_portal(nd):
			var radius = nd.get("Radius")
			if radius != null:
				entry["portal_radius"] = radius
			var sprite = nd.get("Sprite")
			if sprite != null:
				entry["portal_sprite_pos"] = sprite.position
			var poff_key = _portal_offset_key(nd)
			if poff_key != "":
				entry["portal_offset_key"] = poff_key
				if portal_offsets_store.has(poff_key):
					entry["portal_offset"] = portal_offsets_store[poff_key].duplicate()
		# Pattern-specific extras.
		if _is_pattern(nd):
			# polygon is a PoolVector2Array — duplicate to detach.
			entry["pattern_polygon"] = PoolVector2Array(nd.polygon)
			# Full local transform (with shear) — pos/rot/scale alone
			# can't reproduce a sheared transform.
			entry["pattern_transform"] = nd.transform
			if pattern_orig_store.has(key):
				entry["pattern_orig"] = pattern_orig_store[key].duplicate(true)
			if pattern_orig_pos_store.has(key):
				entry["pattern_orig_pos"] = pattern_orig_pos_store[key].duplicate()
			if pattern_reset_store.has(key):
				entry["pattern_reset"] = pattern_reset_store[key].duplicate(true)
			if pattern_world_store.has(key):
				entry["pattern_world"] = pattern_world_store[key].duplicate(true)
		out[key] = entry
	return out


func _record_ft_unified_change(before: Dictionary, after: Dictionary) -> void:
	if _ft_unified_equal(before, after):
		return
	var undo_lib = _g.ModMapData.get("_undo_lib")
	if undo_lib == null:
		return
	undo_lib.record_callback(
		self, "_restore_ft_unified", [before],
		self, "_restore_ft_unified", [after])


func _ft_unified_equal(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for key in a:
		if not b.has(key):
			return false
		var ea = a[key]
		var eb = b[key]
		# Standard transforms.
		if ea.get("position") != eb.get("position"):
			return false
		if ea.get("rotation") != eb.get("rotation"):
			return false
		if ea.get("scale") != eb.get("scale"):
			return false
		# Shear transform entry.
		if ea.has("transform") != eb.has("transform"):
			return false
		if ea.has("transform"):
			for k in ea["transform"]:
				if not eb["transform"].has(k) or ea["transform"][k] != eb["transform"][k]:
					return false
		# Distort corners.
		if ea.has("distort") != eb.has("distort"):
			return false
		if ea.has("distort"):
			var da = ea["distort"]
			var db = eb["distort"]
			if da.size() != db.size():
				return false
			for i in range(da.size()):
				if da[i] != db[i]:
					return false
		# Crop polygon.
		if ea.has("crop") != eb.has("crop"):
			return false
		if ea.has("crop"):
			var ca = ea["crop"]
			var cb = eb["crop"]
			if ca.size() != cb.size():
				return false
			for i in range(ca.size()):
				if ca[i] != cb[i]:
					return false
		if ea.has("crop_soft") != eb.has("crop_soft"):
			return false
		if ea.has("crop_soft") and ea["crop_soft"] != eb["crop_soft"]:
			return false
		if ea.has("crop_feather") != eb.has("crop_feather"):
			return false
		if ea.has("crop_feather") and ea["crop_feather"] != eb["crop_feather"]:
			return false
		if ea.has("crop_opacity") != eb.has("crop_opacity"):
			return false
		if ea.has("crop_opacity") and ea["crop_opacity"] != eb["crop_opacity"]:
			return false
		if ea.has("edgecrop") != eb.has("edgecrop"):
			return false
		if ea.has("edgecrop"):
			var ga = ea["edgecrop"]
			var gb = eb["edgecrop"]
			if ga.get("px") != gb.get("px") or ga.get("hard") != gb.get("hard"):
				return false
		# Portal extras.
		if ea.get("portal_radius") != eb.get("portal_radius"):
			return false
		if ea.get("portal_sprite_pos") != eb.get("portal_sprite_pos"):
			return false
		if ea.has("portal_offset") != eb.has("portal_offset"):
			return false
		if ea.has("portal_offset"):
			var oa = ea["portal_offset"]
			var ob = eb["portal_offset"]
			for k in oa:
				if not ob.has(k) or oa[k] != ob[k]:
					return false
		# Pattern extras.
		if ea.has("pattern_polygon") != eb.has("pattern_polygon"):
			return false
		if ea.has("pattern_polygon"):
			var pa = ea["pattern_polygon"]
			var pb = eb["pattern_polygon"]
			if pa.size() != pb.size():
				return false
			for i in range(pa.size()):
				if pa[i] != pb[i]:
					return false
		if ea.get("pattern_transform") != eb.get("pattern_transform"):
			return false
		# pattern_orig / orig_pos / reset / world: compare presence
		# (their content is already inferred by polygon/transform; if
		# either of those changed we already returned false). For
		# safety though, treat presence mismatch as a real change.
		for fld in ["pattern_orig", "pattern_orig_pos", "pattern_reset", "pattern_world"]:
			if ea.has(fld) != eb.has(fld):
				return false
	return true


func _restore_ft_unified(state: Dictionary) -> void:
	# Re-apply each captured entry: standard transforms on the live
	# node, side-stores in ModMapData, and invalidate any cached
	# ShaderMaterial so the next _restore_distort_from_store rebuilds
	# from the now-correct distort entry. For portals we also restore
	# Radius / sprite.position / _portal_offsets, then call RemakeLines
	# on each affected wall so it re-fits the restored portal.
	# For patterns we restore the polygon vertices + the full transform
	# (with shear) + every pattern-related ModMapData store.
	if not _g.ModMapData.has("_ft_transforms"):
		_g.ModMapData["_ft_transforms"] = {}
	if not _g.ModMapData.has("_ft_distort"):
		_g.ModMapData["_ft_distort"] = {}
	if not _g.ModMapData.has("_ft_crop"):
		_g.ModMapData["_ft_crop"] = {}
	if not _g.ModMapData.has("_portal_offsets"):
		_g.ModMapData["_portal_offsets"] = {}
	if not _g.ModMapData.has("_ft_pattern_orig"):
		_g.ModMapData["_ft_pattern_orig"] = {}
	if not _g.ModMapData.has("_ft_pattern_orig_pos"):
		_g.ModMapData["_ft_pattern_orig_pos"] = {}
	if not _g.ModMapData.has("_ft_pattern_reset"):
		_g.ModMapData["_ft_pattern_reset"] = {}
	if not _g.ModMapData.has("_ft_pattern_world"):
		_g.ModMapData["_ft_pattern_world"] = {}
	var transforms_store = _g.ModMapData["_ft_transforms"]
	var distort_store = _g.ModMapData["_ft_distort"]
	if not _g.ModMapData.has("_ft_crop_soft"):
		_g.ModMapData["_ft_crop_soft"] = {}
	var crop_store = _g.ModMapData["_ft_crop"]
	if not _g.ModMapData.has("_ft_crop_feather"):
		_g.ModMapData["_ft_crop_feather"] = {}
	if not _g.ModMapData.has("_ft_crop_opacity"):
		_g.ModMapData["_ft_crop_opacity"] = {}
	var crop_soft_store = _g.ModMapData["_ft_crop_soft"]
	var crop_feather_store = _g.ModMapData["_ft_crop_feather"]
	var crop_opacity_store = _g.ModMapData["_ft_crop_opacity"]
	if not _g.ModMapData.has("_ft_edgecrop"):
		_g.ModMapData["_ft_edgecrop"] = {}
	var edgecrop_store = _g.ModMapData["_ft_edgecrop"]
	var portal_offsets_store = _g.ModMapData["_portal_offsets"]
	var pattern_orig_store = _g.ModMapData["_ft_pattern_orig"]
	var pattern_orig_pos_store = _g.ModMapData["_ft_pattern_orig_pos"]
	var pattern_reset_store = _g.ModMapData["_ft_pattern_reset"]
	var pattern_world_store = _g.ModMapData["_ft_pattern_world"]
	# Track walls to remake at the end — one RemakeLines per wall is
	# enough even if multiple portals share it.
	var walls_to_remake: Array = []
	for key in state:
		var entry = state[key]
		var nd = _ft_node_from_key(key)
		if nd != null and is_instance_valid(nd):
			# For patterns, the visual rendering depends on a ShaderMaterial
			# (_ft_materials cache) that warps the polygon's interior. If
			# we just restored the polygon vertices the OUTLINE / SHAPE
			# would change but the interior pixels would keep the warped
			# rendering of the previous transform — exactly the "shape
			# revert but pattern looks cropped/warped" symptom.
			#
			# So for patterns we delegate visual rebuild to
			# _apply_distort_pattern when the captured state had a
			# distort active, or strip the FT material entirely otherwise.
			# In both cases we set the transform first because both
			# helpers read from node.transform / node.position.
			if _is_pattern(nd):
				if entry.has("pattern_transform"):
					nd.transform = entry["pattern_transform"]
				# Make sure the stores _apply_distort_pattern reads from
				# carry the captured values BEFORE we call it (it reads
				# _ft_pattern_orig via _get_orig_polygon).
				if entry.has("pattern_orig"):
					pattern_orig_store[key] = entry["pattern_orig"].duplicate(true)
				else:
					pattern_orig_store.erase(key)
				if entry.has("pattern_world"):
					# Distort was active — rebuild it. Compute world corners
					# from the stored local corners + current node.position.
					var lwc = entry["pattern_world"]
					if lwc is Array and lwc.size() == 8:
						var wc = [
							Vector2(lwc[0], lwc[1]) + nd.position,
							Vector2(lwc[2], lwc[3]) + nd.position,
							Vector2(lwc[4], lwc[5]) + nd.position,
							Vector2(lwc[6], lwc[7]) + nd.position,
						]
						var orig_poly = []
						if entry.has("pattern_orig"):
							var flat = entry["pattern_orig"]
							for i in range(0, flat.size(), 2):
								orig_poly.append(Vector2(flat[i], flat[i + 1]))
						_apply_distort_pattern(nd, wc, orig_poly if orig_poly.size() >= 3 else null)
				else:
					# No distort in the captured state — strip the FT
					# material if present and restore the raw polygon
					# from the snapshot.
					if _ft_materials.has(key):
						nd.material = _ft_materials[key].get("original", null)
						_ft_materials.erase(key)
					if entry.has("pattern_polygon"):
						nd.polygon = entry["pattern_polygon"]
						# Sync the outline so it matches the polygon.
						var outline = nd.get("Outline")
						if outline != null and outline is Line2D:
							var pts = PoolVector2Array()
							for p in entry["pattern_polygon"]:
								pts.append(p)
							if pts.size() > 0:
								pts.append(pts[0])
							outline.points = pts
			else:
				# Non-pattern node: standard transform restore (or full
				# transform when shear is captured for paths/etc).
				if entry.has("pattern_transform"):
					nd.transform = entry["pattern_transform"]
				else:
					nd.global_position = entry["position"]
					nd.global_rotation = entry["rotation"]
					nd.global_scale = entry["scale"]
			# Portal extras: Radius and sprite.position.
			if entry.has("portal_radius") and nd.get("Radius") != null:
				nd.set("Radius", entry["portal_radius"])
				# Refresh the cached base_radius so _watch_portal_textures
				# doesn't immediately overwrite the value we just restored.
				var pid = nd.get_instance_id()
				if _portal_tex_cache.has(pid):
					var sc = abs(nd.scale.x)
					if sc > 0.001:
						_portal_tex_cache[pid].base_radius = entry["portal_radius"] / sc
			if entry.has("portal_sprite_pos"):
				var sprite = nd.get("Sprite")
				if sprite != null:
					sprite.position = entry["portal_sprite_pos"]
			# Mark the wall for RemakeLines if this is a portal.
			if _is_portal(nd):
				var wall = _get_portal_wall(nd)
				if wall != null and not wall in walls_to_remake:
					walls_to_remake.append(wall)
		# Side-stores: set or erase to mirror the captured presence/absence.
		if entry.has("transform"):
			transforms_store[key] = entry["transform"].duplicate()
		else:
			transforms_store.erase(key)
		if entry.has("distort"):
			distort_store[key] = entry["distort"].duplicate(true)
		else:
			distort_store.erase(key)
		if entry.has("crop_soft"):
			crop_soft_store[key] = entry["crop_soft"]
		else:
			crop_soft_store.erase(key)
		if entry.has("crop_feather"):
			crop_feather_store[key] = entry["crop_feather"]
		else:
			crop_feather_store.erase(key)
		if entry.has("crop_opacity"):
			crop_opacity_store[key] = entry["crop_opacity"]
		else:
			crop_opacity_store.erase(key)
		var _had_edge_prev = edgecrop_store.has(key)
		if entry.has("edgecrop"):
			edgecrop_store[key] = entry["edgecrop"].duplicate()
		else:
			edgecrop_store.erase(key)
		# Crop polygonal et edge crop sont exclusifs : on choisit la cuisson finale
		# selon l'entrée présente, sinon on dé-cuit si l'un des deux était actif.
		if entry.has("crop"):
			crop_store[key] = entry["crop"].duplicate(true)
			if nd != null and is_instance_valid(nd) and _is_plain_prop(nd):
				var _cpts = _load_crop_points(nd)
				if _cpts.size() >= 3:
					_bake_crop_texture(nd, _cpts)
		elif entry.has("edgecrop"):
			crop_store.erase(key)
			if nd != null and is_instance_valid(nd) and _is_plain_prop(nd):
				_bake_edgecrop_texture(nd)
		else:
			var _had_crop = crop_store.has(key)
			crop_store.erase(key)
			crop_soft_store.erase(key)
			crop_feather_store.erase(key)
			crop_opacity_store.erase(key)
			if (_had_crop or _had_edge_prev) and nd != null and is_instance_valid(nd):
				_unbake_crop_texture(nd)
		# Pattern stores.
		if entry.has("pattern_orig"):
			pattern_orig_store[key] = entry["pattern_orig"].duplicate(true)
		else:
			pattern_orig_store.erase(key)
		if entry.has("pattern_orig_pos"):
			pattern_orig_pos_store[key] = entry["pattern_orig_pos"].duplicate()
		else:
			pattern_orig_pos_store.erase(key)
		if entry.has("pattern_reset"):
			pattern_reset_store[key] = entry["pattern_reset"].duplicate(true)
		else:
			pattern_reset_store.erase(key)
		if entry.has("pattern_world"):
			pattern_world_store[key] = entry["pattern_world"].duplicate(true)
		else:
			pattern_world_store.erase(key)
		# _portal_offsets is keyed differently (wall_id_idx_dist), not by
		# ft_node_key. We stored the relevant key inside the entry.
		if entry.has("portal_offset_key"):
			var poff_key = entry["portal_offset_key"]
			if entry.has("portal_offset"):
				portal_offsets_store[poff_key] = entry["portal_offset"].duplicate()
			else:
				portal_offsets_store.erase(poff_key)
		# Drop any cached ShaderMaterial for this key so the next
		# _restore_distort_from_store cycle rebuilds it from scratch
		# using the now-restored distort_store entry. Without this,
		# the visible warp would lag the data.
		# EXCEPTION: for patterns whose distort we just rebuilt via
		# _apply_distort_pattern, the freshly registered _ft_materials
		# entry IS the correct one — clearing it would orphan the live
		# material on the node.
		var skip_material_clear = false
		if nd != null and is_instance_valid(nd) and _is_pattern(nd) and entry.has("pattern_world"):
			skip_material_clear = true
		if not skip_material_clear and _ft_materials.has(key):
			if nd != null and is_instance_valid(nd):
				var sprite = _get_sprite_node(nd)
				if sprite != null:
					sprite.material = _ft_materials[key].get("original", null)
			_ft_materials.erase(key)
	# Force walls to re-fit the restored portals.
	for wall in walls_to_remake:
		if is_instance_valid(wall) and wall.has_method("RemakeLines"):
			wall.call("RemakeLines")
	# Crop : resynchronise le buffer d'édition avec le store restauré.
	if _crop_node != null and is_instance_valid(_crop_node):
		_crop_points = _load_crop_points(_crop_node)
		_crop_active_pt = -1


# ══ Undo sélection ═════════════════════════════════════════════════════════

var _undo_saved_sel : Array = []

func _save_selection_for_undo() -> void:
	if _selected_objects.empty(): return
	_undo_saved_sel.clear()
	for nd in _selected_objects:
		if is_instance_valid(nd): _undo_saved_sel.append(nd)
	if _undo_saved_sel.empty(): return
	var t = _g.World.get_tree().create_timer(0.1)
	t.connect("timeout", self, "_restore_selection_after_undo")


func _restore_selection_after_undo() -> void:
	if _select_tool == null or _undo_saved_sel.empty(): return
	# Don't blindly re-enable DD's transform box: other systems own its
	# display in specific cases and forcing it on here makes DD's native
	# box flicker for one frame before they re-hide it.
	#   - FT enabled        → its update() hides the box every frame
	#   - DragSelectWalls   → it draws its own custom box for wall +
	#                         non-wall selections, fights us if we
	#                         re-enable DD's
	#   - Portal in selection → portal_tool_fix expects handles hidden
	if not _enabled and not _other_mod_owns_box():
		_select_tool.call("EnableTransformBox", true)
	_undo_saved_sel.clear()
	# update() remettra EnableTransformBox(false) au frame suivant si _enabled


func _other_mod_owns_box() -> bool:
	# DragSelectWalls owns the box display when its custom overlay is up.
	var dsw = null
	if _g.ModMapData != null:
		dsw = _g.ModMapData.get("_drag_select_walls")
	if dsw != null and dsw.has_method("_is_custom_active"):
		if dsw.call("_is_custom_active"):
			return true
	# Portals in selection → portal_tool_fix wants handles hidden.
	if _select_tool != null:
		var sel = _select_tool.get("Selected")
		if sel != null and _select_tool.has_method("GetSelectableType"):
			for node in sel:
				if node == null or not is_instance_valid(node):
					continue
				var type = _select_tool.call("GetSelectableType", node)
				if type == 2 or type == 3:
					return true
	return false


func _all_portals() -> bool:
	for nd in _selected_objects:
		if is_instance_valid(nd) and not _is_portal(nd):
			return false
	return true


func _has_any_path() -> bool:
	for nd in _selected_objects:
		if is_instance_valid(nd) and _is_path(nd):
			return true
	return false


func _all_paths() -> bool:
	for nd in _selected_objects:
		if is_instance_valid(nd) and not _is_path(nd):
			return false
	return true


# ══ Portals ════════════════════════════════════════════════════════════════

# Un Portal DD expose les propriétés "Radius" et "WallID" — on s'en sert
# comme signature pour le distinguer d'un Prop ordinaire.
func _watch_portal_textures() -> void:
	# Nettoie les portals qui ne sont plus sélectionnés
	var active_ids = {}
	for nd in _selected_objects:
		if is_instance_valid(nd) and _is_portal(nd):
			active_ids[nd.get_instance_id()] = true
	for id in _portal_tex_cache.keys():
		if not active_ids.has(id):
			_portal_tex_cache.erase(id)

	# Cache : instance_id → {tex_w, base_radius}
	# base_radius = Radius quand scale.x == 1.0 (radius "naturel" de la texture)
	# On enforce chaque frame : Radius = base_radius * abs(scale.x)
	var refreshed_walls = []
	for nd in _selected_objects:
		if not is_instance_valid(nd) or not _is_portal(nd): continue
		if _active_handle >= 0: continue  # pendant un drag, c'est _sync_portal_radii qui gère

		var id     = nd.get_instance_id()
		var sprite = nd.get("Sprite")
		if sprite == null: continue
		var tex = sprite.get("texture")
		if tex == null: continue
		var tex_w     = tex.get_size().x
		var cur_scale = abs(nd.scale.x)

		if not _portal_tex_cache.has(id):
			# Premier frame : déduit base_radius depuis l'état actuel
			var base_r = nd.get("Radius") / cur_scale if cur_scale > 0.001 else nd.get("Radius")
			_portal_tex_cache[id] = {"tex_w": tex_w, "base_radius": base_r}
			continue

		var cached = _portal_tex_cache[id]

		if tex_w != cached.tex_w:
			# Nouveau type : DD a posé le radius naturel de la nouvelle texture (sans scale).
			# On stocke ce radius naturel comme nouvelle base.
			cached.tex_w       = tex_w
			cached.base_radius = nd.get("Radius")  # valeur naturelle posée par DD

		# Enforce : Radius doit toujours être base_radius * scale
		var expected = cached.base_radius * cur_scale
		if abs(nd.get("Radius") - expected) > 0.1:
			nd.set("Radius", expected)
			var wall = _get_portal_wall(nd)
			if wall != null and not wall in refreshed_walls:
				refreshed_walls.append(wall)
				wall.call("RemakeLines")


func _watch_portal_rotations() -> void:
	if _selected_objects.empty(): return
	if not _g.ModMapData.has("_portal_offsets"):
		_g.ModMapData["_portal_offsets"] = {}
	var store = _g.ModMapData["_portal_offsets"]
	for nd in _selected_objects:
		if not is_instance_valid(nd) or not _is_portal(nd): continue
		var key = _portal_offset_key(nd)
		if key == "": continue
		var rot = nd.rotation
		var rot_mod = fmod(abs(rot), PI * 2)
		var has_rot = rot_mod > 0.01 and rot_mod < PI * 2 - 0.01
		var sprite = nd.get("Sprite")
		var spos = sprite.position if sprite != null else Vector2.ZERO
		if has_rot or spos != Vector2.ZERO:
			# Format v2 : stocke rot_offset relatif à la direction du mur.
			# Voir _save_portal_offsets pour le détail.
			var wall_dir = _portal_wall_dir_angle(nd)
			var rot_offset = rot - wall_dir
			var entry = store.get(key, null)
			var prev_offset = null
			if entry is Dictionary:
				if entry.get("v", 1) >= 2:
					prev_offset = entry.get("rot_offset", null)
				elif entry.has("rot"):
					# Legacy v1: convert old absolute rot to offset for comparison
					prev_offset = float(entry["rot"]) - wall_dir
			if prev_offset == null or abs(float(prev_offset) - rot_offset) > 0.001:
				store[key] = {"x": spos.x, "y": spos.y, "rot_offset": rot_offset, "v": 2}


func _apply_portal_radius_correction(nd: Node, old_radius: float, old_tex_w: float, new_tex_w: float) -> void:
	pass  # remplacé par l'enforcement continu dans _watch_portal_textures


func _is_portal(nd: Node) -> bool:
	return nd.get("Radius") != null and nd.get("WallID") != null


func _is_wall(nd: Node) -> bool:
	return nd.get("Points") != null and nd.has_method("RemakeLines") and nd.get("Radius") == null


func _is_pattern(nd: Node) -> bool:
	return nd is Polygon2D and nd.get("GlobalPolygon") != null


func _is_path(nd: Node) -> bool:
	return nd is Line2D and nd.get("FadeIn") != null


func _is_roof(nd: Node) -> bool:
	var level = _g.World.GetCurrentLevel() if _g.World else null
	if level == null: return false
	var roofs_node = level.get("Roofs")
	if roofs_node == null: return false
	var p = nd.get_parent()
	return p == roofs_node or (p != null and p.get_parent() == roofs_node)


func _is_light(nd: Node) -> bool:
	var level = _g.World.GetCurrentLevel() if _g.World else null
	if level == null: return false
	var lights_node = level.get("Lights")
	if lights_node == null: return false
	var p = nd.get_parent()
	return p == lights_node or (p != null and p.get_parent() == lights_node)


func _get_path_edit_points_local(node: Node2D) -> Array:
	var pts = node.get("EditPoints")
	if pts == null: return []
	var result = []
	for p in pts:
		result.append(p)
	return result


func _get_path_local_aabb(node: Node2D) -> Rect2:
	var pts = _get_path_edit_points_local(node)
	if pts.empty(): return Rect2(Vector2.ZERO, Vector2(128, 128))
	var mn = pts[0]; var mx = pts[0]
	for p in pts:
		mn.x = min(mn.x, p.x); mn.y = min(mn.y, p.y)
		mx.x = max(mx.x, p.x); mx.y = max(mx.y, p.y)
	var sz = mx - mn
	if sz.length() < 1.0: return Rect2(mn, Vector2(128, 128))
	# Pour les paths droits (horizontaux/verticaux), on ajoute un padding
	# basé sur la largeur visuelle du path pour que la box soit manipulable.
	var min_dim = max(node.width * 0.5, 48.0) if node is Line2D else 48.0
	if sz.x < min_dim:
		var pad = (min_dim - sz.x) * 0.5
		mn.x -= pad; sz.x = min_dim
	if sz.y < min_dim:
		var pad = (min_dim - sz.y) * 0.5
		mn.y -= pad; sz.y = min_dim
	return Rect2(mn, sz)


func _get_path_center(node: Node2D) -> Vector2:
	var bb = _get_path_local_aabb(node)
	return bb.position + bb.size * 0.5


func _get_pattern_local_aabb(node: Node2D) -> Rect2:
	var poly = node.polygon
	if poly == null or poly.size() == 0: return Rect2(Vector2.ZERO, Vector2(128, 128))
	var mn = poly[0]; var mx = poly[0]
	for p in poly:
		mn.x = min(mn.x, p.x); mn.y = min(mn.y, p.y)
		mx.x = max(mx.x, p.x); mx.y = max(mx.y, p.y)
	return Rect2(mn, mx - mn)


func _get_pattern_center(node: Node2D) -> Vector2:
	var bb = _get_pattern_local_aabb(node)
	return bb.position + bb.size * 0.5


func _get_visual_offset(node: Node2D) -> Vector2:
	if _is_pattern(node):
		return _get_pattern_center(node)
	if _is_path(node):
		return _get_path_center(node)
	var sprite = node.get("Sprite")
	return sprite.position if sprite != null else Vector2.ZERO


func _normalize_pattern_position(node: Node2D) -> void:
	# Pas besoin de centrer le polygon — _get_visual_offset retourne le centre
	# de l'AABB et le code de scale/transform l'utilise comme offset.
	# Ne PAS toucher node.position pour ne pas casser le tracking DD.
	_store_orig_polygon(node)


func _bake_path_transform(node: Node2D) -> void:
	# Absorbe node.transform (scale, skew) dans les EditPoints.
	var t = node.transform
	var is_id = abs(t.x.x - 1.0) < 0.001 and abs(t.x.y) < 0.001 \
			and abs(t.y.x) < 0.001 and abs(t.y.y - 1.0) < 0.001
	if is_id: return
	var pts = _get_path_edit_points_local(node)
	if pts.empty(): return
	var world_pts = []
	for p in pts:
		world_pts.append(t.xform(p))
	node.transform = Transform2D(Vector2(1, 0), Vector2(0, 1), t.origin)
	node.call("SetEditPoints", world_pts)
	node.call("Smooth")
	var key = _ft_node_key(node)
	if key != "" and _g.ModMapData.has("_ft_transforms"):
		_g.ModMapData["_ft_transforms"].erase(key)


func _bake_pattern_state(node: Node2D) -> void:
	# Fusionne toute transformation (scale, shear, distort, perspective) dans le polygon.
	# Appelé uniquement quand le transform est non-identity.
	var key = _ft_node_key(node)

	# Calcule les positions monde des vertices.
	var world_pts = []
	var has_world_corners = key != "" and _g.ModMapData.has("_ft_pattern_world") \
			and _g.ModMapData["_ft_pattern_world"].has(key)
	var orig = _get_orig_polygon(node)

	if has_world_corners and orig.size() >= 3:
		var wraw = _g.ModMapData["_ft_pattern_world"][key]
		var wc = [Vector2(wraw[0], wraw[1]), Vector2(wraw[2], wraw[3]),
		          Vector2(wraw[4], wraw[5]), Vector2(wraw[6], wraw[7])]
		# AABB du polygon original
		var mn = orig[0]; var mx = orig[0]
		for p in orig:
			mn.x = min(mn.x, p.x); mn.y = min(mn.y, p.y)
			mx.x = max(mx.x, p.x); mx.y = max(mx.y, p.y)
		var src_size = mx - mn
		if src_size.x > 0.1 and src_size.y > 0.1:
			for p in orig:
				var u = (p.x - mn.x) / src_size.x
				var v = (p.y - mn.y) / src_size.y
				var top    = wc[0].linear_interpolate(wc[1], u)
				var bottom = wc[3].linear_interpolate(wc[2], u)
				world_pts.append(top.linear_interpolate(bottom, v))
		else:
			for p in node.polygon:
				world_pts.append(node.transform.xform(p))
	else:
		var t = node.transform
		for p in node.polygon:
			world_pts.append(t.xform(p))

	# Supprime le shader distort (restaure le material original)
	if _ft_materials.has(key):
		node.material = _ft_materials[key].get("original", null)
		_ft_materials.erase(key)

	# Nettoie les données FT de transformation (garde _ft_pattern_orig pour Reset)
	if _g.ModMapData.has("_ft_transforms"):
		_g.ModMapData["_ft_transforms"].erase(key)
	if _g.ModMapData.has("_ft_distort"):
		_g.ModMapData["_ft_distort"].erase(key)
	if _g.ModMapData.has("_ft_pattern_world"):
		_g.ModMapData["_ft_pattern_world"].erase(key)

	# Remet le transform à identity en gardant la position DD intacte
	var orig_pos = node.position
	node.transform = Transform2D(Vector2(1, 0), Vector2(0, 1), orig_pos)

	# Reconvertit les vertices monde en 4 coins locaux (relatif à node.position).
	# On garde les 4 coins bilinéairement warpés, pas l'AABB (qui serait plus grand).
	var new_poly = PoolVector2Array()
	if world_pts.size() == 4:
		for p in world_pts:
			new_poly.append(p - orig_pos)
	else:
		# Plus de 4 vertices (subdivisé) → prend juste les 4 coins AABB
		var bmn = world_pts[0]; var bmx = world_pts[0]
		for p in world_pts:
			bmn.x = min(bmn.x, p.x); bmn.y = min(bmn.y, p.y)
			bmx.x = max(bmx.x, p.x); bmx.y = max(bmx.y, p.y)
		new_poly.append(Vector2(bmn.x, bmn.y) - orig_pos)
		new_poly.append(Vector2(bmx.x, bmn.y) - orig_pos)
		new_poly.append(Vector2(bmx.x, bmx.y) - orig_pos)
		new_poly.append(Vector2(bmn.x, bmx.y) - orig_pos)
	node.polygon = new_poly
	node.uv = PoolVector2Array()
	# Stocke ces 4 coins comme nouveau working original
	if key != "":
		if not _g.ModMapData.has("_ft_pattern_orig"):
			_g.ModMapData["_ft_pattern_orig"] = {}
		var flat = []
		for p in new_poly:
			flat.append(p.x); flat.append(p.y)
		_g.ModMapData["_ft_pattern_orig"][key] = flat
		if not _g.ModMapData.has("_ft_pattern_orig_pos"):
			_g.ModMapData["_ft_pattern_orig_pos"] = {}
		_g.ModMapData["_ft_pattern_orig_pos"][key] = [orig_pos.x, orig_pos.y]

	# Met à jour l'Outline
	var outline = node.get("Outline")
	if outline != null and outline is Line2D:
		var pts = PoolVector2Array()
		for p in new_poly:
			pts.append(p)
		if pts.size() > 0:
			pts.append(pts[0])
		outline.points = pts




func _soft_bake_pattern(node: Node2D) -> void:
	# Absorbe le scale/rotation dans les données distort SANS supprimer le shader.
	var key = _ft_node_key(node)
	var t = node.transform

	# 1. Transforme les coins distort par le transform du node
	if _g.ModMapData.has("_ft_distort") and _g.ModMapData["_ft_distort"].has(key):
		var raw = _g.ModMapData["_ft_distort"][key]
		if raw is Array and raw.size() == 8:
			var new_corners = []
			for i in range(0, 8, 2):
				var lc = Vector2(raw[i], raw[i + 1])
				var wc = t.xform(lc)
				new_corners.append(wc.x - t.origin.x)
				new_corners.append(wc.y - t.origin.y)
			_g.ModMapData["_ft_distort"][key] = new_corners

	# 2. Transforme le polygon original par le scale
	if _g.ModMapData.has("_ft_pattern_orig") and _g.ModMapData["_ft_pattern_orig"].has(key):
		var flat = _g.ModMapData["_ft_pattern_orig"][key]
		if flat is Array and flat.size() >= 6:
			var new_flat = []
			for i in range(0, flat.size(), 2):
				var p = Vector2(flat[i], flat[i + 1])
				var wp = t.xform(p)
				new_flat.append(wp.x - t.origin.x)
				new_flat.append(wp.y - t.origin.y)
			_g.ModMapData["_ft_pattern_orig"][key] = new_flat

	# 3. Transforme le polygon actuel du node
	var new_poly = PoolVector2Array()
	for p in node.polygon:
		var wp = t.xform(p)
		new_poly.append(Vector2(wp.x - t.origin.x, wp.y - t.origin.y))
	node.polygon = new_poly
	node.uv = PoolVector2Array()

	# 4. Met a jour l Outline
	var outline = node.get("Outline")
	if outline != null and outline is Line2D:
		var pts = PoolVector2Array()
		for p in new_poly:
			pts.append(p)
		if pts.size() > 0:
			pts.append(pts[0])
		outline.points = pts

	# 5. Remet le transform a identity (tout est absorbe)
	node.transform = Transform2D(Vector2(1, 0), Vector2(0, 1), t.origin)

	# 6. Met a jour la position de reference
	if key != "":
		if not _g.ModMapData.has("_ft_pattern_orig_pos"):
			_g.ModMapData["_ft_pattern_orig_pos"] = {}
		_g.ModMapData["_ft_pattern_orig_pos"][key] = [t.origin.x, t.origin.y]


# Construit les infos d'arc pour un portal : points du mur, longueurs cumulées, arc initial.
func _build_wall_arc(portal: Node) -> Dictionary:
	var wall = _get_portal_wall(portal)
	if wall == null: return {}
	var points = wall.get("Points")
	if points == null or points.size() < 2: return {}
	# Longueurs cumulées
	var cum : Array = [0.0]
	for i in range(points.size() - 1):
		cum.append(cum[i] + points[i].distance_to(points[i + 1]))
	var total : float = cum[cum.size() - 1]
	# Position arc initiale : projection de portal.position sur le segment le plus proche
	var arc : float = _project_pos_to_arc(portal.position, points, cum)
	var init_seg = _arc_segment(points, cum, arc)
	return {"points": points, "cum": cum, "arc": arc, "total": total, "seg_idx": init_seg.idx}


# Projette un point monde sur l'arc du mur, retourne la distance arc.
func _project_pos_to_arc(pos: Vector2, points: Array, cum: Array) -> float:
	var best_arc  : float = 0.0
	var best_dist : float = INF
	for i in range(points.size() - 1):
		var a   = points[i]
		var b   = points[i + 1]
		var ab      = b - a
		var seg_len = ab.length()
		if seg_len < 0.001: continue
		var t       = clamp((pos - a).dot(ab) / (seg_len * seg_len), 0.0, 1.0)
		var closest = a + ab * t
		var d       = pos.distance_to(closest)
		if d < best_dist:
			best_dist = d
			best_arc  = cum[i] + t * seg_len
	return best_arc


# Retourne la direction (et position de début) du segment de mur à la position arc donnée.
func _arc_segment(points: Array, cum: Array, arc: float) -> Dictionary:
	for i in range(cum.size() - 1):
		if arc < cum[i + 1] - 0.001:
			var dir = (points[i + 1] - points[i]).normalized()
			return {"dir": dir, "idx": i}
	var last = points.size() - 1
	return {"dir": (points[last] - points[last - 1]).normalized(), "idx": last - 1}


# Convertit une position arc en position monde + rotation.
func _arc_to_world(points: Array, cum: Array, arc: float) -> Dictionary:
	var seg = _arc_segment(points, cum, arc)
	var i   = seg.idx
	var t   = arc - cum[i]
	var pos = points[i] + seg.dir * t
	var rot = atan2(seg.dir.y, seg.dir.x)
	return {"pos": pos, "rot": rot}


# Convertit une position arc en {WallPointIndex, WallDistance} pour DD.
func _arc_to_wall_params(cum: Array, arc: float) -> Dictionary:
	for i in range(cum.size() - 1):
		if arc <= cum[i + 1] + 0.001:
			return {"idx": i, "dist": arc - cum[i]}
	var last = cum.size() - 1
	return {"idx": last - 1, "dist": arc - cum[last - 1]}
# Stratégie 1 : le parent direct est le Wall (cas le plus courant dans DD).
# Stratégie 2 : recherche par WallID dans les murs du niveau courant.
func _get_portal_wall(portal: Node) -> Node:
	var p = portal.get_parent()
	if p != null and p.has_method("RemakeLines"):
		return p
	# Fallback : chercher dans tous les murs du niveau
	var vp = _g.World.get_tree().root.get_node_or_null(_viewport_path)
	if vp == null: return null
	var world = vp.get_node_or_null("World")
	if world == null: return null
	var level = world.get_node_or_null("Level")
	if level == null:
		# Essaie le premier enfant qui s'appelle "Level"
		for child in world.get_children():
			if "Level" in child.name:
				level = child; break
	if level == null: return null
	var wall_id = portal.get("WallID")
	if wall_id == null or wall_id == -1: return null
	var walls_node = level.get("Walls")
	if walls_node == null: return null
	for wall in walls_node.get_children():
		if wall.get_instance_id() == wall_id:
			return wall
	return null


# ══ Géométrie ══════════════════════════════════════════════════════════════

func _mouse_world(vp: Node) -> Vector2:
	return vp.canvas_transform.affine_inverse().xform(vp.get_mouse_position())


func _get_tex_size(node: Node2D) -> Vector2:
	if _is_pattern(node):
		var bb = _get_pattern_local_aabb(node)
		return bb.size
	if _is_path(node):
		var bb = _get_path_local_aabb(node)
		return bb.size
	var PADDING = 48.0
	for ch in node.get_children():
		if not (ch is Sprite): continue
		var tex = ch.get("texture")
		if tex == null: continue
		var sz = tex.get_size()
		var rr = ch.get("region_rect")
		if rr is Rect2 and rr.size.length() > 0.0: sz = rr.size
		return sz + Vector2(PADDING, PADDING)
	return Vector2(128.0, 128.0) + Vector2(PADDING, PADDING)


func _local_to_world(node: Node2D, local_pt: Vector2) -> Vector2:
	# Utilise node.transform directement pour supporter les cisaillements
	# (skew / distort / perspective stockent un Transform2D complet)
	return node.transform.xform(local_pt)


func _prop_corners(node: Node2D) -> Array:
	# Retourne les coins monde depuis les coins locaux stockés si disponibles.
	if _g.ModMapData.has("_ft_distort"):
		var id = _ft_node_key(node)
		if _g.ModMapData["_ft_distort"].has(id):
			var raw = _g.ModMapData["_ft_distort"][id]

			# Reconvertit depuis le format flat float array (JSON-safe)
			var lc: Array
			if raw.size() == 8:
				lc = [Vector2(raw[0],raw[1]), Vector2(raw[2],raw[3]),
				      Vector2(raw[4],raw[5]), Vector2(raw[6],raw[7])]
			elif raw.size() == 4 and raw[0] is Vector2:
				lc = raw
			else:
				lc = raw

			if _is_pattern(node):
				# Patterns : les coins locaux dans _ft_distort correspondent aux
				# vertices du polygon. On les transforme via node.transform courant
				# pour obtenir les coins monde (fonctionne avec move, scale, identity).
				var to_world = node.transform
				return [
					to_world.xform(lc[0]), to_world.xform(lc[1]),
					to_world.xform(lc[2]), to_world.xform(lc[3]),
				]
			else:
				# Props : coins en espace local Sprite, ratio padding inverse
				var sprite = _get_sprite_node(node)
				var to_world = node.transform * (sprite.transform if sprite != null else Transform2D.IDENTITY)

				var tex = null; var rr = null
				if sprite != null:
					tex = sprite.get("texture")
					rr  = sprite.get("region_rect")
				var real_w: float; var real_h: float
				if tex != null and rr is Rect2 and rr.size.length() > 0.0:
					real_w = rr.size.x; real_h = rr.size.y
				elif tex != null:
					real_w = tex.get_size().x; real_h = tex.get_size().y
				else:
					real_w = 128.0; real_h = 128.0
				var PADDING_C = 48.0
				var ix = (real_w + PADDING_C) / real_w
				var iy = (real_h + PADDING_C) / real_h

				return [
					to_world.xform(Vector2(lc[0].x * ix, lc[0].y * iy)),
					to_world.xform(Vector2(lc[1].x * ix, lc[1].y * iy)),
					to_world.xform(Vector2(lc[2].x * ix, lc[2].y * iy)),
					to_world.xform(Vector2(lc[3].x * ix, lc[3].y * iy)),
				]

	var ts = _get_tex_size(node)
	var sw = ts.x * 0.5; var sh = ts.y * 0.5
	var soff = _get_visual_offset(node)
	return [
		_local_to_world(node, Vector2(-sw, -sh) + soff),
		_local_to_world(node, Vector2( sw, -sh) + soff),
		_local_to_world(node, Vector2( sw,  sh) + soff),
		_local_to_world(node, Vector2(-sw,  sh) + soff),
	]


func _prop_aabb(node: Node2D) -> Rect2:
	var corners = _prop_corners(node)
	var mn = corners[0]; var mx = corners[0]
	for c in corners:
		mn.x = min(mn.x, c.x); mn.y = min(mn.y, c.y)
		mx.x = max(mx.x, c.x); mx.y = max(mx.y, c.y)
	return Rect2(mn, mx - mn)


func _selection_aabb() -> Rect2:
	var mn = Vector2(INF, INF); var mx = Vector2(-INF, -INF)
	for nd in _selected_objects:
		if not is_instance_valid(nd): continue
		var bb = _prop_aabb(nd)
		mn.x = min(mn.x, bb.position.x); mn.y = min(mn.y, bb.position.y)
		mx.x = max(mx.x, bb.end.x);      mx.y = max(mx.y, bb.end.y)
	if mn.x == INF: return Rect2()
	return Rect2(mn, mx - mn)


# Vrai si wp est dans la bbox de la sélection élargie d'une marge (en pixels
# écran convertis en monde). Sert à « verrouiller » la zone autour de l'asset
# en cours d'édition : tout clic dans cette zone est consommé par Free
# Transform afin que DD ne sélectionne pas un autre asset superposé/proche.
const _CLICK_LOCK_MARGIN_PX := 60.0
func _click_near_selection(wp: Vector2, vp: Node) -> bool:
	var box = _selection_aabb()
	if box.size == Vector2.ZERO: return false
	var zoom = vp.canvas_transform.get_scale().x
	var m = _CLICK_LOCK_MARGIN_PX / max(zoom, 0.0001)
	return box.grow(m).has_point(wp)


func _single_handle_positions(node: Node2D) -> Array:
	var ts = _get_tex_size(node)
	var sw = ts.x * 0.5; var sh = ts.y * 0.5
	var soff = _get_visual_offset(node)
	return [
		_local_to_world(node, Vector2(-sw, -sh) + soff),  # 0 TL
		_local_to_world(node, Vector2(  0, -sh) + soff),  # 1 TC
		_local_to_world(node, Vector2( sw, -sh) + soff),  # 2 TR
		_local_to_world(node, Vector2( sw,   0) + soff),  # 3 MR
		_local_to_world(node, Vector2( sw,  sh) + soff),  # 4 BR
		_local_to_world(node, Vector2(  0,  sh) + soff),  # 5 BC
		_local_to_world(node, Vector2(-sw,  sh) + soff),  # 6 BL
		_local_to_world(node, Vector2(-sw,   0) + soff),  # 7 ML
	]


func _bbox_handle_positions(bb: Rect2) -> Array:
	var o = bb.position; var w = bb.size.x; var h = bb.size.y
	return [
		o,                          o + Vector2(w*0.5, 0),
		o + Vector2(w, 0),          o + Vector2(w, h*0.5),
		o + Vector2(w, h),          o + Vector2(w*0.5, h),
		o + Vector2(0, h),          o + Vector2(0, h*0.5),
	]


func _current_handle_positions(vp: Node) -> Array:
	if _selected_objects.size() == 0: return []
	# Pendant un drag non-free, utilise _group_warp_corners comme source de vérité
	# (évite les décalages si node.transform est modifié entre frames)
	if _transform_mode != "free" and _group_warp_corners.size() == 4 and _active_handle >= 0:
		return _group_corners_to_handles(_group_warp_corners)
	if _selected_objects.size() == 1:
		var nd = _selected_objects[0]
		if not is_instance_valid(nd): return []
		if _transform_mode in ["distort", "perspective", "skew"] and _has_distort_corners(nd):
			return _distort_handle_positions(nd)
		if _transform_mode == "free" and _has_distort_corners(nd):
			return _bbox_handle_positions(_prop_aabb(nd))
		return _single_handle_positions(nd)
	# Multi-sélection : utilise les coins warpés du groupe si disponibles
	if _transform_mode != "free" and _group_warp_corners.size() == 4:
		return _group_corners_to_handles(_group_warp_corners)
	return _bbox_handle_positions(_selection_aabb())


# Handle positions pour distort/perspective — coins + milieux des arêtes
func _distort_handle_positions(node: Node2D) -> Array:
	var c = _prop_corners(node)  # [TL(0), TR(1), BR(2), BL(3)]
	return [
		c[0],                        # 0 TL
		(c[0] + c[1]) * 0.5,         # 1 TC
		c[1],                        # 2 TR
		(c[1] + c[2]) * 0.5,         # 3 MR
		c[2],                        # 4 BR
		(c[2] + c[3]) * 0.5,         # 5 BC
		c[3],                        # 6 BL
		(c[3] + c[0]) * 0.5,         # 7 ML
	]


func _group_corners_to_handles(c: Array) -> Array:
	return [
		c[0],                        # 0 TL
		(c[0] + c[1]) * 0.5,         # 1 TC
		c[1],                        # 2 TR
		(c[1] + c[2]) * 0.5,         # 3 MR
		c[2],                        # 4 BR
		(c[2] + c[3]) * 0.5,         # 5 BC
		c[3],                        # 6 BL
		(c[3] + c[0]) * 0.5,         # 7 ML
	]


func _has_warp(node) -> bool:
	# Vrai si l'asset a une déformation Skew / Distort / Perspective active.
	# (mutuellement exclusif avec Crop / Soft Crop)
	if node == null or not is_instance_valid(node):
		return false
	if _has_distort_corners(node):
		return true   # distort / perspective / skew par les coins (shader)
	return _is_node_skewed(node)   # skew par les bords (transform cisaillé)


func _is_node_skewed(node) -> bool:
	var key = _ft_node_key(node)
	if key == "" or not _g.ModMapData.has("_ft_transforms"):
		return false
	if not _g.ModMapData["_ft_transforms"].has(key):
		return false
	var d = _g.ModMapData["_ft_transforms"][key]
	var cx = Vector2(d.xx, d.xy)
	var cy = Vector2(d.yx, d.yy)
	if cx.length() < 0.0001 or cy.length() < 0.0001:
		return false
	# Colonnes non perpendiculaires → cisaillement. Un simple scale / rotation /
	# flip garde les colonnes perpendiculaires (donc pas considéré comme skew).
	return abs(cx.normalized().dot(cy.normalized())) > 0.02


func _crop_is_modified(node) -> bool:
	# Vrai seulement si le crop est une VRAIE modif : polygone différent du
	# cadre plein (un sommet déplacé), ou douceur / opacité non-défaut.
	# Un crop « plein cadre » — créé automatiquement à l'entrée en mode Crop ou
	# re-créé par update() après un Reset (qui efface le crop mais laisse le
	# mode "crop" actif) — n'est PAS considéré comme une modif → pas de warning.
	if not _has_crop(node):
		return false
	if _crop_is_soft(node) and abs(_crop_hardness(node) - CROP_HARDNESS_DEFAULT) > 0.001:
		return true
	if _crop_keep_alpha(node) > 0.001:
		return true
	var sprite = _get_sprite_node(node)
	if sprite == null:
		return true  # par prudence, on prévient
	var full = _init_crop_corners(sprite)
	var pts = _load_crop_points(node)
	if pts.size() != full.size():
		return true
	for i in range(pts.size()):
		if pts[i].distance_to(full[i]) > 0.5:
			return true
	return false


func _has_distort_corners(node: Node2D) -> bool:
	if not _g.ModMapData.has("_ft_distort"): return false
	return _g.ModMapData["_ft_distort"].has(_ft_node_key(node))


func _hit_handle(wp: Vector2, vp: Node) -> int:
	var hs = _current_handle_positions(vp)
	if hs.empty(): return -1
	var zoom    = vp.canvas_transform.get_scale().x
	var thr_out = 65.0 / zoom

	# Handles autorisés selon le mode courant
	var allowed = _allowed_handle_indices()

	if _all_portals():
		var thr_in = 0.0
		var short_edges = _portal_short_edge_indices()
		for k in short_edges:
			if not k in allowed: continue
			var d = wp.distance_to(hs[k])
			if d >= thr_in and d < thr_out: return k
		for k in EDGE_IDX:
			if k in short_edges: continue
			if not k in allowed: continue
			var d = wp.distance_to(hs[k])
			if d >= thr_in and d < thr_out: return k
		for k in CORNER_IDX:
			if not k in allowed: continue
			var d = wp.distance_to(hs[k])
			if d >= thr_in and d < thr_out: return k
	else:
		var thr_in = 40.0 / zoom
		for k in range(hs.size()):
			if not k in allowed: continue
			if wp.distance_to(hs[k]) < thr_in: return k

	return -1


# Retourne les indices des edges des faces les plus courtes du portal sélectionné.
# Handles latéraux (3=MR, 7=ML) si l'asset est plus haut que large, sinon haut/bas (1=TC, 5=BC).
func _portal_short_edge_indices() -> Array:
	if _selected_objects.size() != 1: return [1, 5]
	var nd = _selected_objects[0]
	if not is_instance_valid(nd): return [1, 5]
	var ts = _get_tex_size(nd)
	# ts est en espace local non-scalé — compare largeur vs hauteur
	if ts.x * abs(nd.scale.x) <= ts.y * abs(nd.scale.y):
		return [1, 5]  # asset plus haut que large → faces courtes = haut et bas
	else:
		return [3, 7]  # asset plus large que haut → faces courtes = gauche et droite


func _pivot_local_unscaled(handle_idx: int, sw: float, sh: float) -> Vector2:
	match handle_idx:
		0: return Vector2( sw,  sh)
		2: return Vector2(-sw,  sh)
		4: return Vector2(-sw, -sh)
		6: return Vector2( sw, -sh)
		1: return Vector2(  0,  sh)
		5: return Vector2(  0, -sh)
		3: return Vector2(-sw,   0)
		7: return Vector2( sw,   0)
	return Vector2.ZERO


func _pivot_world_group(handle_idx: int) -> Vector2:
	if _mod_alt: return _group_bbox.position + _group_bbox.size * 0.5
	var o = _group_bbox.position; var w = _group_bbox.size.x; var h = _group_bbox.size.y
	match handle_idx:
		0: return o + Vector2(w, h)
		2: return o + Vector2(0, h)
		4: return o
		6: return o + Vector2(w, 0)
		1: return o + Vector2(w*0.5, h)
		5: return o + Vector2(w*0.5, 0)
		3: return o + Vector2(0, h*0.5)
		7: return o + Vector2(w, h*0.5)
	return _group_bbox.position + _group_bbox.size * 0.5


# ══ Drag ═══════════════════════════════════════════════════════════════════

func _start_handle_drag(handle_idx: int, wp: Vector2) -> void:
	# Ré-applique les cisaillements AVANT SavePreTransforms
	_reapply_shear_transforms()
	_group_warp_corners = []  # reset les coins warpés du drag précédent

	# Snapshot de l'état pré-FT (idempotent) pour un "Reset" qui restaure le
	# vanilla plutôt que de tout zéroter.
	for _sn in _selected_objects:
		_snapshot_orig_xform(_sn)

	# Patterns : bake si le node a un transform non-identity (scale/position changé).
	# Le bake fusionne tout dans le polygon pour repartir d'une base propre.
	# Exception : pas de bake si on est en distort et que le transform est identity
	# (= on enchaîne des distorts sans scale entre).
	for nd in _selected_objects:
		if is_instance_valid(nd) and _is_pattern(nd):
			# Invalide les données périmées AVANT tout (une seule fois au début du drag)
			_invalidate_stale_pattern_data(nd)
			var t = nd.transform
			var is_identity = abs(t.x.x - 1.0) < 0.001 and abs(t.x.y) < 0.001 \
					and abs(t.y.x) < 0.001 and abs(t.y.y - 1.0) < 0.001
			var has_distort = _has_distort_corners(nd)
			var key = _ft_node_key(nd)
			if not is_identity:
				if has_distort:
					_soft_bake_pattern(nd)
				else:
					_bake_pattern_state(nd)
			_normalize_pattern_position(nd)

	# Choose the undo path based on whether the selection is fully
	# manageable by us. If yes, we skip DD's SavePreTransforms entirely
	# and capture a unified before-snapshot ourselves; we'll push a
	# single record on commit. If not (any wall/portal/pattern/path),
	# we fall back to DD's flow + an extras-only callback.
	_undo_skip_dd_record = _ft_selection_is_simple(_selected_objects)
	if _undo_skip_dd_record:
		_undo_unified_before = _capture_ft_unified(_selected_objects)
	else:
		_undo_unified_before = _capture_ft_unified(_selected_objects)
		if _select_tool != null:
			_select_tool.call("SavePreTransforms")
	_active_handle  = handle_idx
	_drag_start_pos = wp
	_drag_states.clear()
	for nd in _selected_objects:
		if not is_instance_valid(nd): continue
		var wall_arc = _build_wall_arc(nd) if _is_portal(nd) else null
		var arc_rot_start = 0.0
		if wall_arc != null and not wall_arc.empty():
			var seg = _arc_segment(wall_arc.points, wall_arc.cum, wall_arc.arc)
			arc_rot_start = atan2(seg.dir.y, seg.dir.x)
		_drag_states.append({
			"node": nd, "pos": nd.position, "rot": nd.rotation,
			"scale": nd.scale, "tex_size": _get_tex_size(nd),
			"corners": _prop_corners(nd),
			"node_transform": nd.transform,
			"portal_radius": nd.get("Radius") if _is_portal(nd) else null,
			"sprite_pos": nd.get("Sprite").position if nd.get("Sprite") != null else null,
			"visual_offset": _get_visual_offset(nd),
			"orig_polygon": Array(nd.polygon) if _is_pattern(nd) else null,
			"is_pattern": _is_pattern(nd),
			"is_path": _is_path(nd),
			"wall_arc": wall_arc,
			"arc_rot_start": arc_rot_start,
		})
	_group_bbox = _prop_aabb(_drag_states[0].node) if _drag_states.size() == 1 else _selection_aabb()
	_walk_prev_wp = wp

	# Initialise les coins du groupe pour le cadre FT pendant le drag
	if _transform_mode != "free" and _drag_states.size() > 0:
		_group_warp_corners = _drag_states[0].corners.duplicate()

	# Pour les coins skew : initialise _ft_distort tout de suite depuis les coins actuels,
	# sinon _has_distort_corners == false pendant le premier frame de drag
	# et les handles ne suivent pas.
	if _transform_mode == "skew" and handle_idx in CORNER_IDX \
			and _drag_states.size() == 1 and not _is_portal(_drag_states[0].node):
		var nd = _drag_states[0].node
		if not _has_distort_corners(nd):
			if _is_pattern(nd):
				_apply_distort_pattern(nd, _drag_states[0].corners, _drag_states[0].get("orig_polygon"))
			else:
				_apply_distort_shader(nd, _drag_states[0].corners)

	# Patterns en mode free : initialise les coins distort pour que le scale
	# passe par _apply_distort_pattern. Le shader FT est nécessaire même en
	# mode free car DD utilise un shader de tiling (VERTEX/textureSize) — sans
	# le shader FT, changer les vertices ne fait qu'exposer plus/moins de tuiles.
	if _transform_mode == "free" and handle_idx in (CORNER_IDX + EDGE_IDX):
		for st in _drag_states:
			if not is_instance_valid(st.node): continue
			if _is_pattern(st.node) and not _has_distort_corners(st.node):
				_apply_distort_pattern(st.node, st.corners, st.get("orig_polygon"))


func _update_handle_drag(wp: Vector2, vp: Node) -> void:
	if _drag_states.empty(): return
	var is_single = (_selected_objects.size() == 1)
	var delta = wp - _drag_start_pos


	# ── Rotation ─────────────────────────────────────────────────────────
	if _active_handle == IDX_ROT:
		var pivot = _group_bbox.position + _group_bbox.size * 0.5
		var a0 = rad2deg(atan2(_drag_start_pos.y - pivot.y, _drag_start_pos.x - pivot.x))
		var a1 = rad2deg(atan2(wp.y - pivot.y, wp.x - pivot.x))
		var da = a1 - a0
		if _mod_shift:
			var base  = rad2deg(_drag_states[0].rot) if _drag_states.size() > 0 else 0.0
			var abs_r = round((base + da) / 15.0) * 15.0
			da = abs_r - base
		var rad = deg2rad(da)
		for st in _drag_states:
			if not is_instance_valid(st.node): continue
			st.node.position = st.pos
			st.node.rotation = st.rot
			var aabb_before = _prop_aabb(st.node)
			var vc_before = aabb_before.position + aabb_before.size * 0.5
			var vc_target = pivot + (vc_before - pivot).rotated(rad)
			st.node.rotation = st.rot + rad
			var aabb_natural = _prop_aabb(st.node)
			var vc_natural = aabb_natural.position + aabb_natural.size * 0.5
			st.node.position = st.pos + (vc_target - vc_natural)
		return

	# ── Glissement perpendiculaire au mur (portals, Alt) ─────────────────────
	if _active_handle == IDX_SLIDE:
		for st in _drag_states:
			if not is_instance_valid(st.node): continue
			var sprite = st.node.get("Sprite")
			if sprite == null: continue
			var ly   = Vector2(-sin(st.rot), cos(st.rot))
			var proj = delta.dot(ly)
			var sprite_start = st.get("sprite_pos")
			if sprite_start == null: continue
			sprite.position = sprite_start + Vector2(0, proj / max(abs(st.node.scale.y), 0.001))
		return

	# ── Glissement le long du mur (portals, drag simple) ──────────────────────
	if _active_handle == IDX_WALK:
		var d_wp = wp - _walk_prev_wp
		_walk_prev_wp = wp
		for st in _drag_states:
			if not is_instance_valid(st.node): continue
			var arc_info = st.get("wall_arc")
			if arc_info == null or arc_info.empty():
				var lx = Vector2(cos(st.rot), sin(st.rot))
				st.node.position = st.pos + lx * (wp - _drag_start_pos).dot(lx)
			else:
				var portal_radius = max(abs(st.node.get("Radius")), 16.0)
				var seg     = _arc_segment(arc_info.points, arc_info.cum, arc_info.arc)
				var proj    = d_wp.dot(seg.dir)
				# Bornes fixes du segment initial — ne change pas en cours de drag
				var seg_min = arc_info.cum[arc_info.seg_idx]
				var seg_max = arc_info.cum[arc_info.seg_idx + 1]
				arc_info.arc = clamp(arc_info.arc + proj, seg_min, seg_max)

				var result = _arc_to_world(arc_info.points, arc_info.cum, arc_info.arc)
				st.node.position = result.pos
				# Préserve le décalage de rotation (ex: Rotate 180 de portal_tool_fix)
				var rot_offset = st.rot - st.get("arc_rot_start", st.rot)
				st.node.rotation = result.rot + rot_offset
				# Note : on NE touche PAS à WallDistance / WallPointIndex —
				# expérimentalement, ça fait disparaître le mur au second
				# save/reload (DD semble recalculer ces propriétés en
				# interne, nos écritures accumulent un état corrompu).
				# On laisse DD persister depuis portal.position.
			var wall = _get_portal_wall(st.node)
			if wall != null:
				wall.call("RemakeLines")
		return

	# ── Déplacement libre (clic dans la bbox, objets normaux) ────────────────
	if _active_handle == IDX_MOVE:
		for st in _drag_states:
			if not is_instance_valid(st.node): continue
			var new_pos = st.pos + delta
			var move_id = _ft_node_key(st.node)
			# Pour les paths/patterns avec shear, on doit setter le transform complet
			# (node.position = x décompose le transform → perd le shear)
			if (st.get("is_path", false) or st.get("is_pattern", false)) \
					and _g.ModMapData.has("_ft_transforms") \
					and _g.ModMapData["_ft_transforms"].has(move_id):
				var d = _g.ModMapData["_ft_transforms"][move_id]
				st.node.transform = Transform2D(
					Vector2(d.xx, d.xy),
					Vector2(d.yx, d.yy),
					new_pos
				)
				d.ox = new_pos.x
				d.oy = new_pos.y
			else:
				st.node.position = new_pos
				if _g.ModMapData.has("_ft_transforms") and _g.ModMapData["_ft_transforms"].has(move_id):
					var d = _g.ModMapData["_ft_transforms"][move_id]
					d.ox = new_pos.x
					d.oy = new_pos.y
			# Déplace les coins monde stockés des patterns
			if st.get("is_pattern", false) and _g.ModMapData.has("_ft_pattern_world") \
					and _g.ModMapData["_ft_pattern_world"].has(move_id):
				var wraw = _g.ModMapData["_ft_pattern_world"][move_id]
				if wraw is Array and wraw.size() == 8:
					var new_wc = []
					for i in range(0, 8, 2):
						new_wc.append(wraw[i] + delta.x)
						new_wc.append(wraw[i + 1] + delta.y)
					_g.ModMapData["_ft_pattern_world"][move_id] = new_wc
		return

	# ── Modes spéciaux : skew / distort / perspective ────────────────────
	# Utilise _drag_states.size() (fixé au début du drag) et non _selected_objects
	# qui peut être réécrit à chaque frame par update() pendant le drag.
	if _transform_mode != "free" \
			and not (_active_handle in [IDX_ROT, IDX_SLIDE, IDX_WALK, IDX_MOVE]) \
			and not _all_portals():
		_update_transform_mode(wp)
		return

	# ── Scale ─────────────────────────────────────────────────────────────
	var rx := 1.0; var ry := 1.0
	var fw  = _group_bbox.size.x; var fh = _group_bbox.size.y

	if _active_handle in CORNER_IDX:
		var dx = delta.x; var dy = delta.y
		if is_single and _drag_states.size() > 0:
			var rot = _drag_states[0].rot
			dx = delta.dot(Vector2(cos(rot), sin(rot)))
			dy = delta.dot(Vector2(-sin(rot), cos(rot)))
		if _active_handle == 0 or _active_handle == 6: dx = -dx
		if _active_handle == 0 or _active_handle == 2: dy = -dy
		var dw = fw * 0.5 if _mod_alt else fw
		var dh = fh * 0.5 if (_mod_alt or _all_portals()) else fh
		if dw < 0.5 or dh < 0.5: return
		rx = max(0.1, 1.0 + dx / dw)
		ry = max(0.1, 1.0 + dy / dh)
		if _mod_shift:
			var r = (rx + ry) * 0.5; rx = r; ry = r
	else:
		var is_vert = (_active_handle == 1 or _active_handle == 5)
		var proj: float
		if is_single and _drag_states.size() > 0:
			var rot = _drag_states[0].rot
			proj = delta.dot(Vector2(-sin(rot), cos(rot))) if is_vert else delta.dot(Vector2(cos(rot), sin(rot)))
		else:
			proj = delta.y if is_vert else delta.x
		var dir  = -1.0 if (_active_handle == 1 or _active_handle == 7) else 1.0
		var full = fh if is_vert else fw
		var div  = full * 0.5 if (_mod_alt or (is_vert and _all_portals())) else full
		if div < 0.5: return
		var ratio = max(0.1, 1.0 + dir * proj / div)
		if _mod_shift and not _all_portals():
			if is_vert: rx = ratio
			else:       ry = ratio
		elif _mod_shift and _all_portals() and is_vert:
			# Portals : Shift sur handle haut/bas verrouille le ratio
			rx = ratio
		if is_vert: ry = ratio
		else:       rx = ratio

	# ── Applique ──────────────────────────────────────────────────────────
	if is_single and _drag_states.size() == 1:
		var st = _drag_states[0]
		if not is_instance_valid(st.node): return

		# ── Scale sur pattern : modifie les coins via _apply_distort_pattern ──
		# Le shader FT est nécessaire car DD utilise un shader de tiling
		# (VERTEX/textureSize) — modifier les vertices seuls ne rescale pas.
		if st.get("is_pattern", false):
			# Pivot = coin opposé au handle, en coordonnées monde
			var pivot: Vector2
			if _mod_alt:
				pivot = (st.corners[0] + st.corners[2]) * 0.5
			else:
				match _active_handle:
					0: pivot = st.corners[2]  # BR
					2: pivot = st.corners[3]  # BL
					4: pivot = st.corners[0]  # TL
					6: pivot = st.corners[1]  # TR
					1: pivot = (st.corners[2] + st.corners[3]) * 0.5  # BC
					5: pivot = (st.corners[0] + st.corners[1]) * 0.5  # TC
					3: pivot = (st.corners[0] + st.corners[3]) * 0.5  # ML
					7: pivot = (st.corners[1] + st.corners[2]) * 0.5  # MR
					_: pivot = (st.corners[0] + st.corners[2]) * 0.5
			# Scale chaque coin autour du pivot (rx/ry sont en world space
			# car rotation = 0 après le bake au début du drag)
			var new_corners = []
			for c in st.corners:
				var off = c - pivot
				new_corners.append(pivot + Vector2(off.x * rx, off.y * ry))
			_apply_distort_pattern(st.node, new_corners, st.get("orig_polygon"))
			return

		# ── Scale sur path : position + scale autour du pivot ────────────
		if st.get("is_path", false):
			var pivot: Vector2
			if _mod_alt:
				pivot = (st.corners[0] + st.corners[2]) * 0.5
			else:
				match _active_handle:
					0: pivot = st.corners[2]
					2: pivot = st.corners[3]
					4: pivot = st.corners[0]
					6: pivot = st.corners[1]
					1: pivot = (st.corners[2] + st.corners[3]) * 0.5
					5: pivot = (st.corners[0] + st.corners[1]) * 0.5
					3: pivot = (st.corners[0] + st.corners[3]) * 0.5
					7: pivot = (st.corners[1] + st.corners[2]) * 0.5
					_: pivot = (st.corners[0] + st.corners[2]) * 0.5
			var offset = st.pos - pivot
			var new_pos = pivot + Vector2(offset.x * rx, offset.y * ry)
			var new_sc = Vector2(st.scale.x * rx, st.scale.y * ry)
			# Préserve le shear éventuel
			var key = _ft_node_key(st.node)
			if _g.ModMapData.has("_ft_transforms") and _g.ModMapData["_ft_transforms"].has(key):
				var d = _g.ModMapData["_ft_transforms"][key]
				var col_x = Vector2(d.xx, d.xy)
				var col_y = Vector2(d.yx, d.yy)
				# Recalcule les colonnes avec le nouveau scale
				var old_sx = col_x.length()
				var old_sy = col_y.length()
				var new_col_x = col_x * (abs(new_sc.x) / max(old_sx, 0.001))
				var new_col_y = col_y * (abs(new_sc.y) / max(old_sy, 0.001))
				st.node.transform = Transform2D(new_col_x, new_col_y, new_pos)
				_store_shear_transform(st.node, st.node.transform)
			else:
				st.node.position = new_pos
				st.node.scale = new_sc
			return

		# ── Scale sur objet cisaillé (skew) ──────────────────────────────
		var shear_id = _ft_node_key(st.node)
		var has_shear = _g.ModMapData.has("_ft_transforms") \
				and _g.ModMapData["_ft_transforms"].has(shear_id)
		if has_shear:
			var col_x0 = st.node_transform.x   # colonnes au début du drag
			var col_y0 = st.node_transform.y
			var ts   = st.tex_size
			var hw   = ts.x * 0.5
			var hh   = ts.y * 0.5
			var soff = st.get("visual_offset", Vector2.ZERO)

			# Recalcule rx/ry depuis les axes réels (colonnes cisaillées), pas st.rot
			var lx_real = col_x0.normalized()
			var ly_real = col_y0.normalized()
			var fw2 = _group_bbox.size.x; var fh2 = _group_bbox.size.y
			if _active_handle in CORNER_IDX:
				var dx = delta.dot(lx_real)
				var dy = delta.dot(ly_real)
				if _active_handle == 0 or _active_handle == 6: dx = -dx
				if _active_handle == 0 or _active_handle == 2: dy = -dy
				var dw2 = fw2 * 0.5 if _mod_alt else fw2
				var dh2 = fh2 * 0.5 if _mod_alt else fh2
				if dw2 < 0.5 or dh2 < 0.5: return
				rx = max(0.1, 1.0 + dx / dw2)
				ry = max(0.1, 1.0 + dy / dh2)
				if _mod_shift:
					var r = (rx + ry) * 0.5; rx = r; ry = r
			else:
				var is_vert2 = (_active_handle == 1 or _active_handle == 5)
				var proj2 = delta.dot(ly_real) if is_vert2 else delta.dot(lx_real)
				var dir2  = -1.0 if (_active_handle == 1 or _active_handle == 7) else 1.0
				var full2 = fh2 if is_vert2 else fw2
				var div2  = full2 * 0.5 if _mod_alt else full2
				if div2 < 0.5: return
				var ratio2 = max(0.1, 1.0 + dir2 * proj2 / div2)
				if is_vert2: ry = ratio2
				else:        rx = ratio2

			# Nouvelles colonnes = colonnes initiales × facteur de scale
			var new_col_x = col_x0 * rx
			var new_col_y = col_y0 * ry

			# Pivot monde et local selon Alt et handle
			var pivot_world: Vector2
			var pivot_local: Vector2
			if _mod_alt:
				# Alt = scale depuis le centre
				pivot_world = st.node_transform.origin
				pivot_local = Vector2(-soff.x, -soff.y)
			else:
				match _active_handle:
					0:
						pivot_world = st.corners[2]
						pivot_local = Vector2(hw - soff.x, hh - soff.y)
					2:
						pivot_world = st.corners[3]
						pivot_local = Vector2(-hw - soff.x, hh - soff.y)
					4:
						pivot_world = st.corners[0]
						pivot_local = Vector2(-hw - soff.x, -hh - soff.y)
					6:
						pivot_world = st.corners[1]
						pivot_local = Vector2(hw - soff.x, -hh - soff.y)
					1:
						pivot_world = (st.corners[2] + st.corners[3]) * 0.5
						pivot_local = Vector2(-soff.x, hh - soff.y)
					5:
						pivot_world = (st.corners[0] + st.corners[1]) * 0.5
						pivot_local = Vector2(-soff.x, -hh - soff.y)
					3:
						pivot_world = (st.corners[0] + st.corners[3]) * 0.5
						pivot_local = Vector2(-hw - soff.x, -soff.y)
					7:
						pivot_world = (st.corners[1] + st.corners[2]) * 0.5
						pivot_local = Vector2(hw - soff.x, -soff.y)
					_:
						pivot_world = st.node_transform.origin
						pivot_local = Vector2(-soff.x, -soff.y)

			# Nouvelle origin = pivot_world - new_col_x * pivot_local.x - new_col_y * pivot_local.y
			var new_origin = pivot_world - new_col_x * pivot_local.x - new_col_y * pivot_local.y

			var t = Transform2D(new_col_x, new_col_y, new_origin)
			st.node.transform = t
			_store_shear_transform(st.node, t)
			return

		var rot    = st.rot
		var lx     = Vector2(cos(rot), sin(rot))
		var ly     = Vector2(-sin(rot), cos(rot))
		var new_sc = Vector2(st.scale.x * rx, st.scale.y * ry)
		var ts     = st.tex_size
		var old_sw = ts.x * abs(st.scale.x) * 0.5; var old_sh = ts.y * abs(st.scale.y) * 0.5
		var new_sw = ts.x * abs(new_sc.x) * 0.5;   var new_sh = ts.y * abs(new_sc.y) * 0.5
		if _mod_alt:
			st.node.scale    = new_sc
			st.node.position = st.pos
		else:
			var pls   = _pivot_local_unscaled(_active_handle, old_sw, old_sh)
			# Portals : ancrage vertical centré — coins et handles haut/bas
			var is_vert_handle = (_active_handle == 1 or _active_handle == 5)
			if (_active_handle in CORNER_IDX or is_vert_handle) and _is_portal(st.node):
				pls.y = 0.0
			var pivot = st.pos + pls.x * lx + pls.y * ly
			st.node.scale    = new_sc
			st.node.position = pivot - Vector2(pls.x / old_sw * new_sw if old_sw > 0 else 0,
			                                   pls.y / old_sh * new_sh if old_sh > 0 else 0).x * lx \
			                        - Vector2(pls.x / old_sw * new_sw if old_sw > 0 else 0,
			                                   pls.y / old_sh * new_sh if old_sh > 0 else 0).y * ly
			# Simplifié : pivot + dir * new_half
			var dir2 = -pls.normalized() if pls.length() > 0 else Vector2.ZERO
			var nsw  = new_sw if abs(pls.x) > 0 else 0
			var nsh  = new_sh if abs(pls.y) > 0 else 0
			st.node.position = pivot + sign(dir2.x) * nsw * lx + sign(dir2.y) * nsh * ly
	else:
		var pivot = _pivot_world_group(_active_handle)
		# Portals : ancrage vertical centré (coins et handles haut/bas)
		var is_vert_handle = (_active_handle == 1 or _active_handle == 5)
		if (_active_handle in CORNER_IDX or is_vert_handle) and _all_portals():
			pivot.y = _group_bbox.position.y + _group_bbox.size.y * 0.5
		for st in _drag_states:
			if not is_instance_valid(st.node): continue
			if st.get("is_pattern", false):
				# Pattern multi-sélection : scale via coins
				var new_corners = []
				for c in st.corners:
					var off = c - pivot
					new_corners.append(pivot + Vector2(off.x * rx, off.y * ry))
				_apply_distort_pattern(st.node, new_corners, st.get("orig_polygon"))
			else:
				var offset = st.pos - pivot
				var new_pos = pivot + Vector2(offset.x * rx, offset.y * ry)
				var new_sc = Vector2(st.scale.x * rx, st.scale.y * ry)
				# Paths : préserve le shear
				var p_key = _ft_node_key(st.node)
				if st.get("is_path", false) and _g.ModMapData.has("_ft_transforms") \
						and _g.ModMapData["_ft_transforms"].has(p_key):
					var d = _g.ModMapData["_ft_transforms"][p_key]
					var col_x = Vector2(d.xx, d.xy)
					var col_y = Vector2(d.yx, d.yy)
					var old_sx = col_x.length()
					var old_sy = col_y.length()
					var nc_x = col_x * (abs(new_sc.x) / max(old_sx, 0.001))
					var nc_y = col_y * (abs(new_sc.y) / max(old_sy, 0.001))
					st.node.transform = Transform2D(nc_x, nc_y, new_pos)
					_store_shear_transform(st.node, st.node.transform)
				else:
					st.node.position = new_pos
					st.node.scale    = new_sc


func _sync_portal_radii(final: bool = false) -> void:
	var refreshed_walls = []
	for st in _drag_states:
		if st.get("portal_radius") == null: continue
		if not is_instance_valid(st.node): continue
		var rx_acc = abs(st.node.scale.x) / max(abs(st.scale.x), 0.001)
		st.node.set("Radius", st.portal_radius * rx_acc)
		if final:
			var wall = _get_portal_wall(st.node)
			if wall != null and not wall in refreshed_walls:
				refreshed_walls.append(wall)
				wall.call("RemakeLines")


func _commit_handle_drag() -> void:
	_sync_portal_radii(true)
	_save_portal_offsets()
	# Persiste le transform des patterns et paths (DD peut le reset entre les frames)
	for st in _drag_states:
		if not is_instance_valid(st.node): continue
		if st.get("is_pattern", false) or st.get("is_path", false):
			var t = st.node.transform
			var is_identity = abs(t.x.x - 1.0) < 0.001 and abs(t.x.y) < 0.001 \
					and abs(t.y.x) < 0.001 and abs(t.y.y - 1.0) < 0.001
			if is_identity:
				# DD a peut-être reseté le transform pendant le drag.
				# Restaure le shear stocké si existant.
				var key = _ft_node_key(st.node)
				if key != "" and _g.ModMapData.has("_ft_transforms") \
						and _g.ModMapData["_ft_transforms"].has(key):
					var d = _g.ModMapData["_ft_transforms"][key]
					t = Transform2D(
						Vector2(d.xx, d.xy),
						Vector2(d.yx, d.yy),
						st.node.position
					)
					st.node.transform = t
					is_identity = false
			if not is_identity:
				_store_shear_transform(st.node, t)
	# Build the post-state list for the unified snapshot.
	var nodes_for_after: Array = []
	for st in _drag_states:
		if is_instance_valid(st.node):
			nodes_for_after.append(st.node)
	var unified_after = _capture_ft_unified(nodes_for_after)
	
	if _undo_skip_dd_record:
		# All-regular-objects path: push our single unified record.
		# DD's record was deliberately skipped at start_handle_drag.
		_record_ft_unified_change(_undo_unified_before, unified_after)
	else:
		# Mixed-selection path: DD captures the standard transforms via
		# RecordTransforms, we push an extras-only record alongside.
		# That still produces two history records — the user needs two
		# Ctrl+Z — but at least both halves are restored cleanly. Future
		# work: extend the unified path to cover patterns/paths/portals.
		if _select_tool != null:
			_select_tool.call("RecordTransforms")
		_record_ft_unified_change(_undo_unified_before, unified_after)
	_undo_unified_before = {}
	_undo_skip_dd_record = false
	_drag_states.clear()
	_group_warp_corners = []
	_save_ft_data()
	print("[FreeTransform] Transform validé")


func _has_any_extras_now() -> bool:
	# Quick check used to decide whether to bother capturing the after-
	# state when the before-snapshot was empty. If nothing's there now
	# either, no record is needed.
	var t = _g.ModMapData.get("_ft_transforms", {})
	var d = _g.ModMapData.get("_ft_distort", {})
	var cr = _g.ModMapData.get("_ft_crop", {})
	return t.size() > 0 or d.size() > 0 or cr.size() > 0


func _portal_offset_key(portal: Node) -> String:
	var wall_id = portal.get("WallID")
	var dist    = portal.get("WallDistance")
	var idx     = portal.get("WallPointIndex")
	if wall_id == null: return ""
	return str(wall_id) + "_" + str(idx) + "_" + str(stepify(float(dist), 0.1))


# Renvoie l'angle (en radians) du segment du mur à la position du portal.
# Utilisé pour stocker la rotation comme offset relatif à la direction du
# mur — ainsi la rotation reste correcte après une rotation du mur via
# DragSelectWalls ou wall_move (qui rotatent portal.rotation par le même
# angle, donc l'offset reste constant).
func _portal_wall_dir_angle(portal: Node) -> float:
	var wall = _get_portal_wall(portal)
	if wall == null: return 0.0
	var points = wall.get("Points")
	if points == null or points.size() < 2: return 0.0
	var cum : Array = [0.0]
	for i in range(points.size() - 1):
		cum.append(cum[i] + points[i].distance_to(points[i + 1]))
	var arc = _project_pos_to_arc(portal.position, points, cum)
	var seg = _arc_segment(points, cum, arc)
	return atan2(seg.dir.y, seg.dir.x)


func _save_portal_offsets() -> void:
	if not _g.ModMapData.has("_portal_offsets"):
		_g.ModMapData["_portal_offsets"] = {}
	var store = _g.ModMapData["_portal_offsets"]
	for st in _drag_states:
		if not is_instance_valid(st.node): continue
		if not _is_portal(st.node): continue
		var key = _portal_offset_key(st.node)
		if key == "": continue
		var sprite = st.node.get("Sprite")
		var spos = sprite.position if sprite != null else Vector2.ZERO
		var rot = st.node.rotation
		var rot_mod = fmod(abs(rot), PI * 2)
		var has_rot = rot_mod > 0.01 and rot_mod < PI * 2 - 0.01
		if spos == Vector2.ZERO and not has_rot:
			store.erase(key)
		else:
			# Format v2 : on stocke rot_offset (relatif à la direction du
			# segment du mur), pas la rotation absolue. Ça survit aux
			# rotations ultérieures du mur (DragSelectWalls), parce que
			# DragSelectWalls modifie portal.rotation du même delta que la
			# direction du mur — donc rot_offset reste constant.
			var wall_dir = _portal_wall_dir_angle(st.node)
			var rot_offset = rot - wall_dir
			store[key] = {"x": spos.x, "y": spos.y, "rot_offset": rot_offset, "v": 2}


# Throttle + give-up state for the portal-offset restore walk.
# _restore_portals_in_node does a full DFS of the World subtree (every
# level), so doing it each frame scales with map size. Some stored keys can
# never be matched — a portal's key (wall_id_idx_dist) changes when it moves,
# leaving the old entry orphaned in the store — so _portal_offset_applied
# never reaches store.size() and the walk would run forever. We therefore:
#   1. only walk every _PORTAL_RESTORE_INTERVAL frames, and
#   2. stop once the applied set has stopped growing for a few passes,
#      re-arming only when the store grows (a new offset was saved).
const _PORTAL_RESTORE_INTERVAL := 20
const _PORTAL_RESTORE_GIVEUP_PASSES := 5
var _portal_restore_done := false
var _portal_restore_frame := -1000
var _portal_restore_last_store := -1
var _portal_restore_last_applied := -1
var _portal_restore_stable := 0

func _restore_portal_offsets() -> void:
	if not _g.ModMapData.has("_portal_offsets"): return
	var store = _g.ModMapData["_portal_offsets"]
	if store.empty(): return
	# Une fois tous les keys restaurés, on arrête
	if _portal_offset_applied.size() >= store.size(): return
	# Re-arm whenever a new offset is saved (store grew).
	if store.size() != _portal_restore_last_store:
		_portal_restore_last_store = store.size()
		_portal_restore_done = false
		_portal_restore_stable = 0
		_portal_restore_last_applied = -1
	if _portal_restore_done: return
	# Throttle the full-World DFS.
	var frame = Engine.get_frames_drawn()
	if frame - _portal_restore_frame < _PORTAL_RESTORE_INTERVAL: return
	_portal_restore_frame = frame
	var world_node = _g.World.get_tree().root.get_node_or_null("Master/ViewportContainer2D/Viewport2D/World")
	if world_node == null: return
	_restore_portals_in_node(world_node, store, 0)
	# Give up once no new key has been applied for several passes — the
	# remaining stored keys are orphaned and will never match a live portal.
	if _portal_offset_applied.size() == _portal_restore_last_applied:
		_portal_restore_stable += 1
		if _portal_restore_stable >= _PORTAL_RESTORE_GIVEUP_PASSES:
			_portal_restore_done = true
	else:
		_portal_restore_stable = 0
	_portal_restore_last_applied = _portal_offset_applied.size()


func _restore_portals_in_node(node: Node, store: Dictionary, depth: int) -> void:
	if depth > 8: return
	for child in node.get_children():
		if _is_portal(child):
			var key = _portal_offset_key(child)
			if key != "" and store.has(key) and not _portal_offset_applied.has(key):
				var sprite = child.get("Sprite")
				var off = store[key]
				if sprite != null:
					sprite.position = Vector2(off.get("x", 0.0), off.get("y", 0.0))
				# Format v2 : rot_offset relatif à la direction du mur ;
				# on additionne la direction courante. Fallback v1 : rot
				# absolue (peut être faux si le mur a été pivoté entre
				# le save d'origine et maintenant — mais on ne peut rien
				# faire de mieux pour les vieilles données).
				if off.get("v", 1) >= 2 and off.has("rot_offset"):
					var wall_dir = _portal_wall_dir_angle(child)
					child.rotation = wall_dir + float(off["rot_offset"])
				elif off.has("rot"):
					child.rotation = float(off["rot"])
				_portal_offset_applied[key] = true
		elif child.get_child_count() > 0:
			_restore_portals_in_node(child, store, depth + 1)


# ══ Overlay ════════════════════════════════════════════════════════════════

func _needs_overlay() -> bool:
	return _enabled and _selected_objects.size() > 0

func _draw_overlay(overlay: Node2D) -> void:
	if not _enabled: return
	if _viewport_path.is_empty(): return
	var tree = _g.World.get_tree()
	if not _is_select_tool_active(tree): return
	if _selected_objects.size() == 0: return
	var vp = tree.root.get_node_or_null(_viewport_path)
	if vp == null: return

	var zoom        = vp.canvas_transform.get_scale().x
	var zf          = sqrt(zoom)
	var lw          = 5.0 / zf
	var hr          = 6.0 / zf
	var BOX_COL     = Color(0.0, 0.851, 0.6, 0.95)
	var FILL_COL    = Color(0.0, 0.851, 0.6, 0.92)
	var EDGE_COL    = Color(1.0, 1.0,   1.0, 0.95)

	# ── Crop : polygone de masque + handles ───────────────────────────────
	if _is_crop_mode() and _selected_objects.size() == 1 \
			and _is_plain_prop(_selected_objects[0]):
		if _crop_node != _selected_objects[0]:
			return  # (re)chargé par update() au prochain frame
		var wpts = _crop_world_points()
		if wpts.size() >= 2:
			for i in range(wpts.size()):
				overlay.draw_line(wpts[i], wpts[(i + 1) % wpts.size()], BOX_COL, lw)
			for cp in wpts:
				_draw_handle(overlay, cp, zoom)
		var bb_c = _selection_aabb()
		if bb_c.size.length() > 1.0:
			var font_c : Font = null
			if _toggle_btn != null and is_instance_valid(_toggle_btn):
				font_c = _toggle_btn.get_font("font")
			if font_c != null:
				var clabel = "SOFT CROP" if _crop_is_soft(_selected_objects[0]) else "CROP"
				var tw = font_c.get_string_size(clabel).x / zoom
				var fs = 1.4 / sqrt(zoom)
				var fp = Vector2(bb_c.position.x + bb_c.size.x * 0.5 - (tw * fs * 0.5),
					bb_c.position.y - 18.0 / sqrt(zoom))
				overlay.draw_set_transform(fp, 0.0, Vector2(fs, fs))
				overlay.draw_string(font_c, Vector2.ZERO, clabel, Color(1.0, 1.0, 1.0, 0.95), -1)
				overlay.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		return

	# ── Edge Crop : cadre simple + label (pas de handles, mode paramétrique) ──
	if _transform_mode == "edgecrop" and _selected_objects.size() == 1 \
			and _is_plain_prop(_selected_objects[0]):
		var ndx = _selected_objects[0]
		if is_instance_valid(ndx):
			var ce = _prop_corners(ndx)
			overlay.draw_line(ce[0], ce[1], BOX_COL, lw)
			overlay.draw_line(ce[1], ce[2], BOX_COL, lw)
			overlay.draw_line(ce[2], ce[3], BOX_COL, lw)
			overlay.draw_line(ce[3], ce[0], BOX_COL, lw)
			var bb_e = _selection_aabb()
			if bb_e.size.length() > 1.0:
				var font_e : Font = null
				if _toggle_btn != null and is_instance_valid(_toggle_btn):
					font_e = _toggle_btn.get_font("font")
				if font_e != null:
					var elabel = "EDGE CROP"
					var twe = font_e.get_string_size(elabel).x / zoom
					var fse = 1.4 / sqrt(zoom)
					var fpe = Vector2(bb_e.position.x + bb_e.size.x * 0.5 - (twe * fse * 0.5),
						bb_e.position.y - 18.0 / sqrt(zoom))
					overlay.draw_set_transform(fpe, 0.0, Vector2(fse, fse))
					overlay.draw_string(font_e, Vector2.ZERO, elabel, Color(1.0, 1.0, 1.0, 0.95), -1)
					overlay.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		return

	# ── Cadre ────────────────────────────────────────────────────────────
	if _selected_objects.size() == 1:
		var nd = _selected_objects[0]
		if not is_instance_valid(nd): return
		# Pendant un drag non-free, utilise _group_warp_corners (source de vérité)
		if _transform_mode != "free" and _group_warp_corners.size() == 4 and _active_handle >= 0:
			var c = _group_warp_corners
			overlay.draw_line(c[0], c[1], BOX_COL, lw)
			overlay.draw_line(c[1], c[2], BOX_COL, lw)
			overlay.draw_line(c[2], c[3], BOX_COL, lw)
			overlay.draw_line(c[3], c[0], BOX_COL, lw)
		# En free avec shader actif : cadre AABB pour matcher les handles bbox
		elif _transform_mode == "free" and _has_distort_corners(nd):
			var bb = _prop_aabb(nd)
			if bb.size.length() < 1.0: return
			var tl = bb.position; var tr = bb.position + Vector2(bb.size.x, 0)
			var br = bb.end;      var bl = bb.position + Vector2(0, bb.size.y)
			overlay.draw_line(tl, tr, BOX_COL, lw)
			overlay.draw_line(tr, br, BOX_COL, lw)
			overlay.draw_line(br, bl, BOX_COL, lw)
			overlay.draw_line(bl, tl, BOX_COL, lw)
		else:
			var c = _prop_corners(nd)
			overlay.draw_line(c[0], c[1], BOX_COL, lw)
			overlay.draw_line(c[1], c[2], BOX_COL, lw)
			overlay.draw_line(c[2], c[3], BOX_COL, lw)
			overlay.draw_line(c[3], c[0], BOX_COL, lw)
	else:
		# Multi-sélection : cadre warpé si coins de groupe disponibles
		if _transform_mode != "free" and _group_warp_corners.size() == 4:
			var c = _group_warp_corners
			overlay.draw_line(c[0], c[1], BOX_COL, lw)
			overlay.draw_line(c[1], c[2], BOX_COL, lw)
			overlay.draw_line(c[2], c[3], BOX_COL, lw)
			overlay.draw_line(c[3], c[0], BOX_COL, lw)
		else:
			var bb = _selection_aabb()
			if bb.size.length() < 1.0: return
			var tl = bb.position; var tr = bb.position + Vector2(bb.size.x, 0)
			var br = bb.end;      var bl = bb.position + Vector2(0, bb.size.y)
			overlay.draw_line(tl, tr, BOX_COL, lw)
			overlay.draw_line(tr, br, BOX_COL, lw)
			overlay.draw_line(br, bl, BOX_COL, lw)
			overlay.draw_line(bl, tl, BOX_COL, lw)

	# ── Handles ───────────────────────────────────────────────────────────
	var hs = _current_handle_positions(vp)
	if hs.empty(): return
	var allowed = _allowed_handle_indices()
	for k in range(hs.size()):
		if not k in allowed: continue
		_draw_handle(overlay, hs[k], zoom)

	# ── Label du mode de transformation ───────────────────────────────────
	if _selected_objects.size() > 0:
		var mode_labels = {
			"free":        "SCALE",
			"skew":        "SKEW",
			"distort":     "DISTORT",
			"perspective": "PERSPECTIVE",
		}
		var portal_labels = {
			"scale":  "SCALE",
			"slide":  "SLIDE",
			"offset": "OFFSET",
		}
		# For portal selections the active mode is _portal_mode, not
		# _transform_mode (which keeps the value from the previous non-
		# portal selection and would mislabel the box).
		var lbl: String
		if _all_portals():
			lbl = portal_labels.get(_portal_mode, "")
		else:
			lbl = mode_labels.get(_transform_mode, "")
		if lbl != "":
			var bb = _selection_aabb()
			if bb.size.length() > 1.0:
				var font : Font = null
				if _toggle_btn != null and is_instance_valid(_toggle_btn):
					font = _toggle_btn.get_font("font")
				if font != null:
					# Calcule la largeur du texte pour le centrer au-dessus de la box
					var text_w = font.get_string_size(lbl).x / zoom
					var box_center_x = bb.position.x + bb.size.x * 0.5
					var font_scale = 1.4 / sqrt(zoom)
					var font_pos = Vector2(box_center_x - (text_w * font_scale * 0.5),
						bb.position.y - 18.0 / sqrt(zoom))
					overlay.draw_set_transform(font_pos, 0.0, Vector2(font_scale, font_scale))
					overlay.draw_string(font, Vector2.ZERO, lbl,
						Color(1.0, 1.0, 1.0, 0.95), -1)
					overlay.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_handle(overlay: Node2D, center: Vector2, zoom: float) -> void:
	if _handle_tex != null:
		# Taille réelle de la texture en unités monde
		var sz = _handle_tex.get_size() / sqrt(zoom)
		overlay.draw_texture_rect(_handle_tex, Rect2(center - sz * 0.5, sz), false)
	else:
		var r = 6.0 / sqrt(zoom)
		var pts = PoolVector2Array([
			center + Vector2(-r,-r), center + Vector2(r,-r),
			center + Vector2( r, r), center + Vector2(-r, r),
		])
		overlay.draw_colored_polygon(pts, Color(0.0, 0.851, 0.6, 0.92))

# ══ Modes de transformation ════════════════════════════════════════════════

# Retourne les indices de handles actifs selon le mode courant.
# Indices : 0=TL 1=TC 2=TR 3=MR 4=BR 5=BC 6=BL 7=ML  8=IDX_ROT
func _allowed_handle_indices() -> Array:
	# Portals : handles uniquement en mode "scale"
	if _all_portals() and _portal_mode != "scale":
		return []
	match _transform_mode:
		"skew":
			if _has_any_path() and _all_paths():
				return [1, 3, 5, 7]  # bords uniquement pour sélection de paths exclusivement
			return [0, 1, 2, 3, 4, 5, 6, 7]   # coins + bords
		"distort", "perspective":
			return [0, 2, 4, 6]          # coins uniquement
		"crop", "softcrop":
			return []                    # handles gérés séparément (polygone dynamique)
		"edgecrop":
			return []                    # paramétrique (sliders), cadre inerte
		_:  # "free"
			return [0, 1, 2, 3, 4, 5, 6, 7]


# Applique la transformation affine pour les modes skew / distort / perspective.
# Travaille en coordonnées monde à partir des coins initiaux stockés dans drag state.
func _update_transform_mode(wp: Vector2) -> void:
	if _drag_states.empty(): return

	# ── Coins du groupe de référence au début du drag ──────────────────────
	# Pour single : coins réels du node.
	# Pour multi  : coins de la group_bbox (axe-aligned rectangle).
	var gc: Array  # [TL, TR, BR, BL] groupe monde au début du drag
	if _drag_states.size() == 1:
		var st0 = _drag_states[0]
		if not is_instance_valid(st0.node): return
		gc = st0.corners.duplicate()
	else:
		var bb = _group_bbox
		gc = [
			bb.position,
			bb.position + Vector2(bb.size.x, 0),
			bb.position + bb.size,
			bb.position + Vector2(0, bb.size.y),
		]

	# Axes du groupe
	var lx = (gc[1] - gc[0]).normalized()
	var ly = (gc[3] - gc[0]).normalized()
	var delta = wp - _drag_start_pos

	# ── Calcule les nouveaux coins du groupe après transformation ──────────
	var new_gc = gc.duplicate()

	match _transform_mode:
		"skew":
			match _active_handle:
				1:
					var shift = delta.dot(lx) * lx
					new_gc[0] += shift; new_gc[1] += shift
				5:
					var lx_bot = (new_gc[2] - new_gc[3]).normalized()
					var shift = delta.dot(lx_bot) * lx_bot
					new_gc[2] += shift; new_gc[3] += shift
				3:
					var ly_r = (new_gc[2] - new_gc[1]).normalized()
					var shift = delta.dot(ly_r) * ly_r
					new_gc[1] += shift; new_gc[2] += shift
				7:
					var shift = delta.dot(ly) * ly
					new_gc[0] += shift; new_gc[3] += shift
				0, 2, 4, 6:
					match _active_handle:
						0:
							var d_lx = delta.dot(lx); var d_ly = delta.dot(ly)
							new_gc[0] += d_lx * lx if abs(d_lx) >= abs(d_ly) else d_ly * ly
						2:
							var ly_r = (gc[2] - gc[1]).normalized()
							var d_lx = delta.dot(lx); var d_ly = delta.dot(ly_r)
							new_gc[1] += d_lx * lx if abs(d_lx) >= abs(d_ly) else d_ly * ly_r
						4:
							var lx_bot = (gc[2] - gc[3]).normalized()
							var ly_r   = (gc[2] - gc[1]).normalized()
							var d_lx = delta.dot(lx_bot); var d_ly = delta.dot(ly_r)
							new_gc[2] += d_lx * lx_bot if abs(d_lx) >= abs(d_ly) else d_ly * ly_r
						6:
							var lx_bot = (gc[2] - gc[3]).normalized()
							var d_lx = delta.dot(lx_bot); var d_ly = delta.dot(ly)
							new_gc[3] += d_lx * lx_bot if abs(d_lx) >= abs(d_ly) else d_ly * ly

		"distort":
			match _active_handle:
				0: new_gc[0] = wp
				2: new_gc[1] = wp
				4: new_gc[2] = wp
				6: new_gc[3] = wp

		"perspective":
			var d_lx = delta.dot(lx); var d_ly = delta.dot(ly)
			var use_x = abs(d_lx) >= abs(d_ly)
			match _active_handle:
				0:
					if use_x:
						new_gc[0] += d_lx * lx
						new_gc[1] += (-d_lx) * lx
					else:
						new_gc[0] += d_ly * ly
						new_gc[3] += (-d_ly) * ly
				2:
					var ly_r = (gc[2] - gc[1]).normalized()
					var d_ly_r = delta.dot(ly_r)
					if use_x:
						new_gc[1] += d_lx * lx
						new_gc[0] += (-d_lx) * lx
					else:
						new_gc[1] += d_ly_r * ly_r
						new_gc[2] += (-d_ly_r) * ly_r
				4:
					var lx_bot = (gc[2] - gc[3]).normalized()
					var ly_r2  = (gc[2] - gc[1]).normalized()
					var d_lx_b = delta.dot(lx_bot)
					var d_ly_r2 = delta.dot(ly_r2)
					if abs(d_lx_b) >= abs(d_ly_r2):
						new_gc[2] += d_lx_b * lx_bot
						new_gc[3] += (-d_lx_b) * lx_bot
					else:
						new_gc[2] += d_ly_r2 * ly_r2
						new_gc[1] += (-d_ly_r2) * ly_r2
				6:
					var lx_bot = (gc[2] - gc[3]).normalized()
					var d_lx_b = delta.dot(lx_bot)
					if abs(d_lx_b) >= abs(d_ly):
						new_gc[3] += d_lx_b * lx_bot
						new_gc[2] += (-d_lx_b) * lx_bot
					else:
						new_gc[3] += d_ly * ly
						new_gc[0] += (-d_ly) * ly

	# Sauvegarde les coins warpés du groupe pour l'overlay et les handles
	_group_warp_corners = new_gc.duplicate()

	# ── Applique la transformation à chaque node du groupe ─────────────────
	for st in _drag_states:
		if not is_instance_valid(st.node): continue
		if _is_portal(st.node): continue

		if _transform_mode in ["distort", "perspective"] or \
				(_transform_mode == "skew" and _active_handle in CORNER_IDX):
			# Pour un seul node, les coins du node == les coins du groupe,
			# donc le mapping bilinéaire est l'identité → on passe new_gc directement.
			# Pour multi-sélection, on interpole via _map_node_corners_to_group.
			var nc: Array
			if _drag_states.size() == 1:
				nc = new_gc
			else:
				nc = _map_node_corners_to_group(st.corners, gc, new_gc)

			if st.get("is_pattern", false):
				_apply_distort_pattern(st.node, nc, st.get("orig_polygon"))
			elif st.get("is_path", false):
				# Paths en distort/perspective : applique le transform AABB (affine best-effort)
				var ts = st.tex_size
				var hw = ts.x * 0.5; var hh = ts.y * 0.5
				if hw > 0.1 and hh > 0.1:
					var p_mn = nc[0]; var p_mx = nc[0]
					for ci in range(1, 4):
						p_mn.x = min(p_mn.x, nc[ci].x); p_mn.y = min(p_mn.y, nc[ci].y)
						p_mx.x = max(p_mx.x, nc[ci].x); p_mx.y = max(p_mx.y, nc[ci].y)
					var aabb_sz = p_mx - p_mn
					var aabb_ct = p_mn + aabb_sz * 0.5
					var sx = aabb_sz.x / (2.0 * hw)
					var sy = aabb_sz.y / (2.0 * hh)
					var soff = st.get("visual_offset", Vector2.ZERO)
					var origin = aabb_ct - Vector2(sx * soff.x, sy * soff.y)
					st.node.transform = Transform2D(Vector2(sx, 0), Vector2(0, sy), origin)
					_store_shear_transform(st.node, st.node.transform)
			else:
				# Prop (Sprite) : met à jour node.transform AABB + shader
				var ts = st.tex_size
				var hw = ts.x * 0.5; var hh = ts.y * 0.5
				if hw > 0.1 and hh > 0.1:
					var mn = nc[0]; var mx = nc[0]
					for ci in range(1, 4):
						mn.x = min(mn.x, nc[ci].x); mn.y = min(mn.y, nc[ci].y)
						mx.x = max(mx.x, nc[ci].x); mx.y = max(mx.y, nc[ci].y)
					var aabb_size = mx - mn
					var aabb_center = mn + aabb_size * 0.5
					var sx = aabb_size.x / (2.0 * hw)
					var sy = aabb_size.y / (2.0 * hh)
					var soff = st.get("visual_offset", Vector2.ZERO)
					var origin = aabb_center - Vector2(sx * soff.x, sy * soff.y)
					var t = Transform2D(Vector2(sx, 0), Vector2(0, sy), origin)
					st.node.transform = t
					_store_shear_transform(st.node, t)
				_apply_distort_shader(st.node, nc)
		else:
			# Skew affine (edges)
			var nc: Array
			if _drag_states.size() == 1:
				nc = new_gc
			else:
				nc = _map_node_corners_to_group(st.corners, gc, new_gc)

			if st.get("is_pattern", false):
				# Pattern : même chemin que distort (shader + polygon warp)
				_apply_distort_pattern(st.node, nc, st.get("orig_polygon"))
			else:
				# Prop : reconstruit le Transform2D
				var ts = st.tex_size
				var hw = ts.x * 0.5; var hh = ts.y * 0.5
				if hw < 0.1 or hh < 0.1: continue
				var soff = st.get("visual_offset", Vector2.ZERO)
				var col_x = (nc[1] - nc[0]) / (2.0 * hw)
				var col_y = (nc[3] - nc[0]) / (2.0 * hh)
				var origin = nc[0] + col_x * (hw - soff.x) + col_y * (hh - soff.y)
				var t = Transform2D(col_x, col_y, origin)
				st.node.transform = t
				_store_shear_transform(st.node, t)


func _map_node_corners_to_group(node_corners: Array, group_src: Array, group_dst: Array) -> Array:
	# Calcule la position bilinéaire de chaque coin du node dans le groupe source,
	# puis interpole dans le groupe destination pour obtenir les nouveaux coins monde.
	var result = []
	for nc in node_corners:
		# Coordonnées (u,v) du coin dans le groupe source (0→1)
		var gs = group_src
		var e = gs[1]-gs[0]; var f = gs[3]-gs[0]
		var len_e = e.length(); var len_f = f.length()
		var u = 0.5; var v = 0.5
		if len_e > 0.1: u = (nc - gs[0]).dot(e.normalized()) / len_e
		if len_f > 0.1: v = (nc - gs[0]).dot(f.normalized()) / len_f
		u = clamp(u, 0.0, 1.0); v = clamp(v, 0.0, 1.0)
		# Interpole dans le groupe destination
		var gd = group_dst
		result.append(lerp(lerp(gd[0], gd[1], u), lerp(gd[3], gd[2], u), v))
	return result

# ══ Persistance des transforms cisaillés ══════════════════════════════════
# Godot 3 : node.transform = T décompose T en pos/rot/scale.
# Si DD (ou Godot) réécrit ensuite position/rotation/scale (SelectThing,
# SavePreTransforms, EnableTransformBox…), _xform_dirty passe à true et
# le prochain get_transform() reconstruit la matrice sans cisaillement.
# Solution : stocker le Transform2D complet dans ModMapData et le réappliquer
# à chaque frame et avant tout calcul de coins.

func _ft_node_key(node: Node2D) -> String:
	# ID stable DD — persisté dans le fichier map, identique après save/load
	if node.has_meta("node_id"):
		return "node-id-" + str(node.get_meta("node_id"))
	return ""   # node sans ID DD (pas un asset de map)


func _ft_node_id(node: Node2D) -> int:
	if node.has_meta("node_id"):
		return int(node.get_meta("node_id"))
	return -1


func _ft_node_from_key(key: String) -> Node2D:
	if not key.begins_with("node-id-"): return null
	var node_id = int(key.substr(8))
	if not _g.World.HasNodeID(node_id): return null
	return _g.World.GetNodeByID(node_id) as Node2D


func _store_shear_transform(node: Node2D, t: Transform2D) -> void:
	var key = _ft_node_key(node)
	if key == "": return   # node sans ID DD, pas persistable
	if not _g.ModMapData.has("_ft_transforms"):
		_g.ModMapData["_ft_transforms"] = {}
	_g.ModMapData["_ft_transforms"][key] = {
		"xx": t.x.x, "xy": t.x.y,
		"yx": t.y.x, "yy": t.y.y,
		"ox": t.origin.x, "oy": t.origin.y,
	}


func _clear_shear_transform(node: Node2D) -> void:
	if _g.ModMapData.has("_ft_transforms"):
		_g.ModMapData["_ft_transforms"].erase(_ft_node_key(node))


func _reapply_shear_transforms(select_active: bool = true) -> void:
	if not _g.ModMapData.has("_ft_transforms"): return
	var store = _g.ModMapData["_ft_transforms"]
	if store.empty(): return
	var dead_keys = []
	for key in store.keys():
		var nd = _ft_node_from_key(key)
		if nd == null or not is_instance_valid(nd):
			dead_keys.append(key)
			continue
		# Patterns : ne pas réappliquer quand PatternShapeTool est actif.
		# DD a besoin de travailler avec le pattern propre pour la création.
		# Dans tous les autres cas (ouverture de map, SelectTool, etc.), on restaure.
		if _is_pattern(nd) and not select_active:
			continue
		# Ne pas interférer avec un node en cours de drag
		if _active_handle >= 0:
			var is_dragged = false
			for st in _drag_states:
				if st.node == nd:
					is_dragged = true; break
			if is_dragged: continue
		var d = store[key]
		# FT OFF : autoriser l'édition NATIVE (rotation/scale via la box ou le
		# slider DD). Au lieu de reverter la base du node vers le store, on
		# REPLIE tout changement de base dans le store (les coins distort, en
		# LOCAL, suivent automatiquement), SAUF si DD a remis la base à
		# l'identité — auquel cas on restaure le skew/distort stocké. Les
		# patterns gardent le comportement strict.
		if not _enabled and not _is_pattern(nd):
			var cur = nd.transform
			var ident = abs(cur.x.x - 1.0) < 0.001 and abs(cur.x.y) < 0.001 \
					and abs(cur.y.x) < 0.001 and abs(cur.y.y - 1.0) < 0.001
			var same = abs(cur.x.x - d.xx) < 0.0001 and abs(cur.x.y - d.xy) < 0.0001 \
					and abs(cur.y.x - d.yx) < 0.0001 and abs(cur.y.y - d.yy) < 0.0001
			if same:
				d.ox = cur.origin.x
				d.oy = cur.origin.y
				continue
			if ident:
				nd.transform = Transform2D(Vector2(d.xx, d.xy), Vector2(d.yx, d.yy), nd.position)
				d.ox = nd.position.x
				d.oy = nd.position.y
				continue
			# Édition native détectée → on replie la nouvelle base dans le store.
			d.xx = cur.x.x; d.xy = cur.x.y
			d.yx = cur.y.x; d.yy = cur.y.y
			d.ox = cur.origin.x; d.oy = cur.origin.y
			continue
		# Pour les patterns, DD peut reset la position — on utilise la position stockée
		var origin = nd.position
		if _is_pattern(nd):
			origin = Vector2(d.ox, d.oy)
			nd.position = origin
		nd.transform = Transform2D(
			Vector2(d.xx, d.xy),
			Vector2(d.yx, d.yy),
			origin
		)
		d.ox = origin.x
		d.oy = origin.y
	for key in dead_keys:
		store.erase(key)




# ══ Shader distort / perspective ══════════════════════════════════════════
# Les coins sont stockés en espace LOCAL du Sprite (pas monde).
# Avantage : quand le node se déplace, les params shader n'ont pas besoin d'être
# mis à jour — les vertices bougent naturellement avec le Sprite.
# On n'appelle set_shader_param QUE pendant le drag, jamais dans update().
# ModMapData["_ft_distort"] = { id_str : [TL, TR, BR, BL] } (local Sprite)

func _get_shadow_sprite(node):
	# Ombre vanilla d'un prop = premier enfant (un Sprite) : copie noire/
	# transparente, élargie, placée derrière. C'est un frère du sprite principal
	# (les deux enfants du node). Les transforms du node (scale, rotation, skew
	# par les bords) la suivent déjà via l'héritage ; seuls les effets au niveau
	# du sprite (shader distort, texture cropée) doivent lui être appliqués ici.
	if node == null or not is_instance_valid(node):
		return null
	if not _is_plain_prop(node):
		return null
	if node.get_child_count() < 1:
		return null
	var sh = node.get_child(0)
	if sh == null or not (sh is Sprite):
		return null
	if sh == _get_sprite_node(node):
		return null
	return sh


func _shadow_capture_orig(node, shadow) -> void:
	# Sauvegarde l'état d'origine de l'ombre (une seule fois) pour restauration.
	var key = _ft_node_key(node)
	if key == "" or shadow == null:
		return
	if _ft_shadow_orig.has(key):
		return
	_ft_shadow_orig[key] = {
		"material": shadow.material,
		"texture": shadow.texture,
		"region_enabled": shadow.region_enabled,
		"region_rect": shadow.region_rect,
	}


func _shadow_restore(node) -> void:
	var key = _ft_node_key(node)
	if key == "" or not _ft_shadow_orig.has(key):
		return
	var shadow = _get_shadow_sprite(node)
	if shadow != null and is_instance_valid(shadow):
		var o = _ft_shadow_orig[key]
		shadow.material = o.get("material", null)
		shadow.texture = o.get("texture", null)
		shadow.region_enabled = o.get("region_enabled", false)
		if o.get("region_rect", null) is Rect2:
			shadow.region_rect = o["region_rect"]
	_ft_shadow_orig.erase(key)


func _get_sprite_node(node: Node2D):
	# Les assets DD exposent leur Sprite via la propriété "Sprite", pas comme enfant direct.
	var s = node.get("Sprite")
	if s != null and s is Sprite: return s
	# Fallback : cherche un Sprite parmi les enfants directs
	for ch in node.get_children():
		if ch is Sprite: return ch
	return null


func _store_distort_corners(node: Node2D, local_corners: Array) -> void:
	var key = _ft_node_key(node)
	if key == "": return
	if not _g.ModMapData.has("_ft_distort"):
		_g.ModMapData["_ft_distort"] = {}
	# Stocke comme floats (JSON-safe) — Vector2 devient dict après sérialisation
	_g.ModMapData["_ft_distort"][key] = [
		local_corners[0].x, local_corners[0].y,
		local_corners[1].x, local_corners[1].y,
		local_corners[2].x, local_corners[2].y,
		local_corners[3].x, local_corners[3].y,
	]


# ── Pattern distort : warp bilinéaire des vertices du polygon ────────────

func _invalidate_stale_pattern_data(node: Node2D) -> void:
	# Appelée UNE SEULE FOIS au début d'un drag (dans _start_handle_drag).
	# Vérifie que _ft_pattern_orig correspond toujours au polygon actuel du node.
	# Si non (node_id réutilisé, pattern reconfiguré par DD, etc.), invalide tout.
	var key = _ft_node_key(node)
	if key == "": return
	if not _g.ModMapData.has("_ft_pattern_orig"): return
	if not _g.ModMapData["_ft_pattern_orig"].has(key): return

	# Skip si le node a un distort ou shear actif — le polygon est warpé, pas périmé
	var has_active_distort = _g.ModMapData.has("_ft_distort") \
			and _g.ModMapData["_ft_distort"].has(key)
	var has_active_shear = _g.ModMapData.has("_ft_transforms") \
			and _g.ModMapData["_ft_transforms"].has(key)
	if has_active_distort or has_active_shear: return

	var poly = node.polygon
	if poly == null or poly.size() == 0: return

	# Compare l'AABB du stored vs le polygon actuel
	var stored_flat = _g.ModMapData["_ft_pattern_orig"][key]
	if not stored_flat is Array or stored_flat.size() < 6: return

	var s_mn = Vector2(stored_flat[0], stored_flat[1])
	var s_mx = s_mn
	for i in range(0, stored_flat.size(), 2):
		var px = stored_flat[i]; var py = stored_flat[i + 1]
		s_mn.x = min(s_mn.x, px); s_mn.y = min(s_mn.y, py)
		s_mx.x = max(s_mx.x, px); s_mx.y = max(s_mx.y, py)
	var c_mn = poly[0]; var c_mx = poly[0]
	for p in poly:
		c_mn.x = min(c_mn.x, p.x); c_mn.y = min(c_mn.y, p.y)
		c_mx.x = max(c_mx.x, p.x); c_mx.y = max(c_mx.y, p.y)

	var tol = 1.0
	if abs(s_mn.x - c_mn.x) > tol or abs(s_mn.y - c_mn.y) > tol \
			or abs(s_mx.x - c_mx.x) > tol or abs(s_mx.y - c_mx.y) > tol:
		for store_name in ["_ft_pattern_orig", "_ft_pattern_orig_pos", "_ft_pattern_reset", "_ft_pattern_world"]:
			if _g.ModMapData.has(store_name):
				_g.ModMapData[store_name].erase(key)


func _store_orig_polygon(node: Node2D) -> void:
	var key = _ft_node_key(node)
	if key == "": return
	var poly = node.polygon
	if poly == null or poly.size() == 0: return
	var flat = []
	for p in poly:
		flat.append(p.x); flat.append(p.y)

	# Working original (utilisé par _apply_distort_pattern comme base du warp)
	# Peut être mis à jour par _bake_pattern_state
	if not _g.ModMapData.has("_ft_pattern_orig"):
		_g.ModMapData["_ft_pattern_orig"] = {}
	if not _g.ModMapData["_ft_pattern_orig"].has(key):
		_g.ModMapData["_ft_pattern_orig"][key] = flat

	# Vrai original pour Reset (jamais écrasé)
	if not _g.ModMapData.has("_ft_pattern_reset"):
		_g.ModMapData["_ft_pattern_reset"] = {}
	if not _g.ModMapData["_ft_pattern_reset"].has(key):
		_g.ModMapData["_ft_pattern_reset"][key] = flat.duplicate()

	# Position originale (jamais écrasée — pour Reset)
	if not _g.ModMapData.has("_ft_pattern_orig_pos"):
		_g.ModMapData["_ft_pattern_orig_pos"] = {}
	if not _g.ModMapData["_ft_pattern_orig_pos"].has(key):
		_g.ModMapData["_ft_pattern_orig_pos"][key] = [node.position.x, node.position.y]


func _get_orig_polygon(node: Node2D) -> Array:
	var key = _ft_node_key(node)
	if key != "" and _g.ModMapData.has("_ft_pattern_orig"):
		var flat = _g.ModMapData["_ft_pattern_orig"].get(key)
		if flat is Array and flat.size() >= 6:
			var pts = []
			for i in range(0, flat.size(), 2):
				pts.append(Vector2(flat[i], flat[i + 1]))
			return pts
	return []


func _apply_distort_pattern(node: Node2D, world_corners: Array, orig_polygon = null) -> void:
	var _dbg_key = _ft_node_key(node)
	_store_orig_polygon(node)

	# Toujours utiliser le vrai polygon original (stocké au premier drag).
	var orig = _get_orig_polygon(node)
	if orig.size() < 3:
		orig = orig_polygon if orig_polygon != null and orig_polygon.size() >= 3 else Array(node.polygon)
	if orig.size() < 3: return

	# AABB du polygon original (en espace local original = relatif à orig_pos)
	var mn = orig[0]; var mx = orig[0]
	for p in orig:
		mn.x = min(mn.x, p.x); mn.y = min(mn.y, p.y)
		mx.x = max(mx.x, p.x); mx.y = max(mx.y, p.y)
	var src_size = mx - mn
	if src_size.x < 0.1 or src_size.y < 0.1: return

	# Position originale du node (fixe, sauvée au premier drag)
	var orig_pos = node.position
	var id = _ft_node_key(node)
	if id != "" and _g.ModMapData.has("_ft_pattern_orig_pos") \
			and _g.ModMapData["_ft_pattern_orig_pos"].has(id):
		var sp = _g.ModMapData["_ft_pattern_orig_pos"][id]
		orig_pos = Vector2(sp[0], sp[1])


	# Stocke les coins monde (source de vérité pour _prop_corners)
	if id != "":
		if not _g.ModMapData.has("_ft_pattern_world"):
			_g.ModMapData["_ft_pattern_world"] = {}
		_g.ModMapData["_ft_pattern_world"][id] = [
			world_corners[0].x, world_corners[0].y,
			world_corners[1].x, world_corners[1].y,
			world_corners[2].x, world_corners[2].y,
			world_corners[3].x, world_corners[3].y,
		]

	# Coins en espace local du node (relatif à node.position actuelle)
	var lc = []
	for wc in world_corners:
		lc.append(wc - node.position)

	# Stocke les coins locaux pour _prop_corners (relatif à node.position)
	_store_distort_corners(node, lc)

	# ── Shader ────────────────────────────────────────────────────────────
	# Recrée le shader si DD l'a supprimé
	var need_shader = not _ft_materials.has(id)
	if not need_shader and node.material != _ft_materials[id].get("warp"):
		need_shader = true

	if need_shader:
		var orig_mat = node.material
		if orig_mat is ShaderMaterial and orig_mat.has_meta("_ft_warp") and orig_mat.get_meta("_ft_warp"):
			orig_mat = null
		if _ft_materials.has(id) and _ft_materials[id].has("original"):
			orig_mat = _ft_materials[id]["original"]

		# Detect if the pattern uses a custom color shader (PatternCustomColor.shader)
		var has_custom_color = false
		var src_mat_detect = node.material if node.material is ShaderMaterial else orig_mat
		if src_mat_detect is ShaderMaterial and src_mat_detect.shader != null:
			var src_code = src_mat_detect.shader.code
			if "redness" in src_code and "smoothstep" in src_code:
				has_custom_color = true

		var mat = ShaderMaterial.new()
		var sh  = Shader.new()
		sh.code = PATTERN_DISTORT_SHADER_CUSTOM_COLOR_SRC if has_custom_color else PATTERN_DISTORT_SHADER_SRC
		mat.shader = sh
		mat.set_meta("_ft_warp", true)

		var src_mat = node.material if node.material is ShaderMaterial else orig_mat
		if src_mat is ShaderMaterial and src_mat.shader != null:
			# Copie albedo depuis le shader DD
			var albedo_tex = src_mat.get_shader_param("albedo")
			if albedo_tex == null and orig_mat is ShaderMaterial and orig_mat != src_mat:
				albedo_tex = orig_mat.get_shader_param("albedo")
			if albedo_tex != null:
				mat.set_shader_param("albedo", albedo_tex)
				if albedo_tex is Texture:
					pass
			else:
				pass
			# Copie rotation du tiling (DD calcule rotate_uv dans le fragment)
			var dd_rot = src_mat.get_shader_param("rotation")
			if dd_rot == null and orig_mat is ShaderMaterial and orig_mat != src_mat:
				dd_rot = orig_mat.get_shader_param("rotation")
			if dd_rot != null:
				mat.set_shader_param("rotation", dd_rot)
			# Copie wear (overlay d'usure)
			var dd_use_wear = src_mat.get_shader_param("use_wear")
			if dd_use_wear == null and orig_mat is ShaderMaterial and orig_mat != src_mat:
				dd_use_wear = orig_mat.get_shader_param("use_wear")
			if dd_use_wear != null:
				mat.set_shader_param("use_wear", dd_use_wear)
			var dd_wear = src_mat.get_shader_param("wear")
			if dd_wear == null and orig_mat is ShaderMaterial and orig_mat != src_mat:
				dd_wear = orig_mat.get_shader_param("wear")
			if dd_wear != null:
				mat.set_shader_param("wear", dd_wear)

		_ft_materials[id] = {"warp": mat, "original": orig_mat}
		node.material = mat

	var mat = _ft_materials[id]["warp"]
	if node.material != mat:
		node.material = mat

	# Shader params — mis à jour CHAQUE FRAME (pas seulement à la création)
	# Les coins correspondent aux vertices warpés du polygon (en local courant)
	mat.set_shader_param("ft_corner_tl", lc[0])
	mat.set_shader_param("ft_corner_tr", lc[1])
	mat.set_shader_param("ft_corner_br", lc[2])
	mat.set_shader_param("ft_corner_bl", lc[3])
	# AABB du polygon original — en espace local (même espace que VERTEX dans le shader DD).
	# Le shader DD fait world_uv = VERTEX / textureSize, donc ft_orig_min doit être en
	# coordonnées polygon, PAS en coordonnées monde. Pas de compensation de position.
	mat.set_shader_param("ft_orig_min", mn)
	mat.set_shader_param("ft_orig_size", src_size)

	# ── Polygon warp (forme + clipping) ──────────────────────────────────
	# Subdivise les arêtes du polygon pour que la triangulation de Godot
	# approxime mieux la surface bilinéaire (sinon un quad 4-vertex produit
	# 2 triangles → le shader inv_bilinear diverge pour les quads non-parallelogrammes).
	var SUBDIV = 8  # subdivisions par arête
	var new_poly = PoolVector2Array()
	var n_pts = orig.size()
	for edge_i in range(n_pts):
		var p0 = orig[edge_i]
		var p1 = orig[(edge_i + 1) % n_pts]
		for sub in range(SUBDIV):
			var t_sub = float(sub) / float(SUBDIV)
			var p = p0.linear_interpolate(p1, t_sub)
			var u = (p.x - mn.x) / src_size.x
			var v = (p.y - mn.y) / src_size.y
			var top    = lc[0].linear_interpolate(lc[1], u)
			var bottom = lc[3].linear_interpolate(lc[2], u)
			new_poly.append(top.linear_interpolate(bottom, v))
	node.polygon = new_poly
	node.uv = PoolVector2Array()

	# ── Outline ──────────────────────────────────────────────────────────
	var outline = node.get("Outline")
	if outline != null and outline is Line2D:
		var pts = PoolVector2Array()
		for p in new_poly:
			pts.append(p)
		if pts.size() > 0:
			pts.append(pts[0])
		outline.points = pts


func _scale_pattern_geometry(node: Node2D, world_corners: Array, orig_polygon = null) -> void:
	# Warpe le polygon et l'outline SANS remplacer le shader DD.
	# NE PAS appeler _store_orig_polygon ici — l'orig est déjà stocké au début
	# du drag dans _start_handle_drag → _normalize_pattern_position.

	var orig = _get_orig_polygon(node)
	if orig.size() < 3:
		orig = orig_polygon if orig_polygon != null and orig_polygon.size() >= 3 else Array(node.polygon)
	if orig.size() < 3: return

	# AABB du polygon original
	var mn = orig[0]; var mx = orig[0]
	for p in orig:
		mn.x = min(mn.x, p.x); mn.y = min(mn.y, p.y)
		mx.x = max(mx.x, p.x); mx.y = max(mx.y, p.y)
	var src_size = mx - mn
	if src_size.x < 0.1 or src_size.y < 0.1: return

	# Coins en local (relatif à node.position)
	var lc = []
	for wc in world_corners:
		lc.append(wc - node.position)

	# ── Polygon warp (subdivise pour meilleure approximation) ────────────
	var SUBDIV = 8
	var new_poly = PoolVector2Array()
	var n_pts = orig.size()
	for edge_i in range(n_pts):
		var p0 = orig[edge_i]
		var p1 = orig[(edge_i + 1) % n_pts]
		for sub in range(SUBDIV):
			var t_sub = float(sub) / float(SUBDIV)
			var p = p0.linear_interpolate(p1, t_sub)
			var u = (p.x - mn.x) / src_size.x
			var v = (p.y - mn.y) / src_size.y
			var top    = lc[0].linear_interpolate(lc[1], u)
			var bottom = lc[3].linear_interpolate(lc[2], u)
			new_poly.append(top.linear_interpolate(bottom, v))
	node.polygon = new_poly
	node.uv = PoolVector2Array()

	# ── Outline ──────────────────────────────────────────────────────────
	var outline = node.get("Outline")
	if outline != null and outline is Line2D:
		var pts = PoolVector2Array()
		for p in new_poly:
			pts.append(p)
		if pts.size() > 0:
			pts.append(pts[0])
		outline.points = pts


func _remove_distort_pattern(node: Node2D) -> void:
	var key = _ft_node_key(node)
	# Restaure le matériau original
	if _ft_materials.has(key):
		node.material = _ft_materials[key].get("original", null)
		_ft_materials.erase(key)
	# Restaure le polygon depuis le vrai original (reset)
	if key != "" and _g.ModMapData.has("_ft_pattern_reset") \
			and _g.ModMapData["_ft_pattern_reset"].has(key):
		var flat = _g.ModMapData["_ft_pattern_reset"][key]
		if flat is Array and flat.size() >= 6:
			var pool = PoolVector2Array()
			for i in range(0, flat.size(), 2):
				pool.append(Vector2(flat[i], flat[i + 1]))
			node.polygon = pool
			node.uv = PoolVector2Array()  # efface les UVs custom
			var outline = node.get("Outline")
			if outline != null and outline is Line2D:
				var pts = PoolVector2Array()
				for p in pool:
					pts.append(p)
				if pts.size() > 0:
					pts.append(pts[0])
				outline.points = pts
	# Nettoie toutes les données pattern
	if key != "":
		for store_name in ["_ft_pattern_orig", "_ft_pattern_orig_pos", "_ft_pattern_reset", "_ft_pattern_world"]:
			if _g.ModMapData.has(store_name):
				_g.ModMapData[store_name].erase(key)
	if _g.ModMapData.has("_ft_distort"):
		_g.ModMapData["_ft_distort"].erase(key)


# Convertit des coins monde → espace local Sprite, puis applique le shader.
# Utilise VisualServer.canvas_item_set_material() pour éviter d'émettre
# _change_notify("material") qui fait crasher SelectTool.get_Selectables().
func _apply_distort_shader(node: Node2D, world_corners: Array) -> void:
	# Crop et distort sont mutuellement exclusifs sur un même node.
	var _ck = _ft_node_key(node)
	if _ck != "" and _g.ModMapData.has("_ft_crop") and _g.ModMapData["_ft_crop"].has(_ck):
		_remove_crop(node)
	_remove_edgecrop(node)
	var sprite = _get_sprite_node(node)
	if sprite == null: return

	# Coins monde → espace local du Sprite (coordonnées paddées)
	var sprite_world_inv = (node.transform * sprite.transform).affine_inverse()
	var lc_padded = []
	for wc in world_corners:
		lc_padded.append(sprite_world_inv.xform(wc))

	# Le vertex shader Godot mappe UV 0→1 sur les vertices du Sprite qui sont à ±real_size/2.
	# Nos coins locaux sont à ±(real+48)/2 (padding de _get_tex_size).
	# Il faut réduire les coins locaux par le ratio real/total pour que les vertices
	# correspondent à la zone de texture réelle et non à la zone paddée.
	var tex = sprite.get("texture")
	var rr  = sprite.get("region_rect")
	var real_w: float
	var real_h: float
	if tex != null and rr is Rect2 and rr.size.length() > 0.0:
		real_w = rr.size.x; real_h = rr.size.y
	elif tex != null:
		real_w = tex.get_size().x; real_h = tex.get_size().y
	else:
		real_w = 128.0; real_h = 128.0
	var PADDING = 48.0
	var sx = real_w / (real_w + PADDING)   # ratio X : réel / total
	var sy = real_h / (real_h + PADDING)   # ratio Y : réel / total

	# Dans l'espace local du Sprite, le centre est toujours (0,0).
	# lc_shader[i] = lc_padded[i] * (real/total) — réduit vers le centre.
	var lc = []
	for p in lc_padded:
		lc.append(Vector2(p.x * sx, p.y * sy))

	# Récupère ou crée le ShaderMaterial
	# On stocke le mat dans une variable GDScript propre au script pour éviter
	# de passer par sprite.material (qui émet des signaux de scène).
	var id = _ft_node_key(node)
	if not _ft_materials.has(id):
		var mat = ShaderMaterial.new()
		var sh  = Shader.new()

		# Sauvegarde le matériau original pour pouvoir le restaurer
		var original_mat = sprite.material
		# (ne pas sauvegarder notre propre shader si on re-installe pour un autre mode)
		if original_mat is ShaderMaterial and original_mat.has_meta("_ft_warp") and original_mat.get_meta("_ft_warp") == true:
			original_mat = null

		# Détecte si le sprite a déjà un shader custom color (tint_r)
		var has_custom_color = false
		var tint_r_val  = Color(1, 0, 0, 1)
		var min_redness = 0.1
		var red_tol     = 0.04
		var min_sat     = 0.0
		if original_mat is ShaderMaterial and original_mat.shader != null:
			var src = original_mat.shader.code
			if "tint_r" in src:
				has_custom_color = true
				tint_r_val  = original_mat.get_shader_param("tint_r")
				var mr = original_mat.get_shader_param("min_redness")
				if mr != null: min_redness = mr
				var rt = original_mat.get_shader_param("red_tolerance")
				if rt != null: red_tol = rt
				var ms = original_mat.get_shader_param("min_saturation")
				if ms != null: min_sat = ms

		sh.code = DISTORT_SHADER_CUSTOM_COLOR_SRC if has_custom_color else DISTORT_SHADER_SRC
		mat.shader = sh
		mat.set_meta("_ft_warp", true)

		if has_custom_color:
			mat.set_shader_param("tint_r",        tint_r_val)
			mat.set_shader_param("min_redness",   min_redness)
			mat.set_shader_param("red_tolerance", red_tol)
			mat.set_shader_param("min_saturation",min_sat)

		# UV région : texture réelle (ou region_rect si sprite sheet)
		var uv_tex = sprite.get("texture")
		var uv_rr  = sprite.get("region_rect")
		if uv_tex != null and uv_rr is Rect2 and uv_rr.size.length() > 0.0:
			var ts = uv_tex.get_size()
			mat.set_shader_param("uv_min", Vector2(uv_rr.position.x / ts.x, uv_rr.position.y / ts.y))
			mat.set_shader_param("uv_max", Vector2((uv_rr.position.x + uv_rr.size.x) / ts.x,
			                                       (uv_rr.position.y + uv_rr.size.y) / ts.y))
		else:
			mat.set_shader_param("uv_min", Vector2.ZERO)
			mat.set_shader_param("uv_max", Vector2.ONE)

		_ft_materials[id] = {"warp": mat, "original": original_mat}
		sprite.material = mat

	var mat = _ft_materials[id]["warp"]
	mat.set_shader_param("corner_tl", lc[0])
	mat.set_shader_param("corner_tr", lc[1])
	mat.set_shader_param("corner_br", lc[2])
	mat.set_shader_param("corner_bl", lc[3])

	# Stocke les coins en local pour persistance entre drags
	_store_distort_corners(node, lc)

	# L'ombre vanilla (child 0) suit la distorsion. On NE partage PAS le matériau
	# du prop (il sortirait l'ombre en couleurs) : on lui met un matériau de warp
	# DÉDIÉ qui déforme la même géométrie mais sort en NOIR avec l'alpha de la
	# texture → l'aspect « ombre noire transparente » est conservé. L'opacité
	# vient du modulate/self_modulate de l'ombre (inchangés).
	var _shadow_d = _get_shadow_sprite(node)
	if _shadow_d != null:
		_shadow_capture_orig(node, _shadow_d)
		var smat = _ft_materials[id].get("shadow_warp", null)
		if smat == null or not (smat is ShaderMaterial):
			smat = ShaderMaterial.new()
			var ssh = Shader.new()
			# Reproduit le ObjectShadow.shader vanilla (noir pur, alpha de la
			# texture * 0.18) mais avec la déformation warp appliquée.
			ssh.code = DISTORT_SHADER_SRC.replace(
				"COLOR=texture(TEXTURE,warp_uv(v_local));",
				"COLOR=vec4(0.0,0.0,0.0,texture(TEXTURE,warp_uv(v_local)).a*0.18);")
			smat.shader = ssh
			# UV calculée depuis la texture de l'ombre elle-même.
			var s_tex = _shadow_d.get("texture")
			var s_rr = _shadow_d.get("region_rect")
			if s_tex != null and s_rr is Rect2 and s_rr.size.length() > 0.0:
				var sts = s_tex.get_size()
				smat.set_shader_param("uv_min", Vector2(s_rr.position.x / sts.x, s_rr.position.y / sts.y))
				smat.set_shader_param("uv_max", Vector2((s_rr.position.x + s_rr.size.x) / sts.x,
				                                        (s_rr.position.y + s_rr.size.y) / sts.y))
			else:
				smat.set_shader_param("uv_min", Vector2.ZERO)
				smat.set_shader_param("uv_max", Vector2.ONE)
			_ft_materials[id]["shadow_warp"] = smat
			_shadow_d.material = smat
		smat.set_shader_param("corner_tl", lc[0])
		smat.set_shader_param("corner_tr", lc[1])
		smat.set_shader_param("corner_br", lc[2])
		smat.set_shader_param("corner_bl", lc[3])


func _remove_distort_shader(node: Node2D) -> void:
	if _is_pattern(node):
		_remove_distort_pattern(node)
		return
	var sprite = _get_sprite_node(node)
	var id = _ft_node_key(node)
	if sprite != null and _ft_materials.has(id):
		sprite.material = _ft_materials[id].get("original", null)
	_ft_materials.erase(id)
	_shadow_restore(node)
	if _g.ModMapData.has("_ft_distort"):
		_g.ModMapData["_ft_distort"].erase(id)



func _restore_distort_from_store(select_active: bool = true) -> void:
	if not _g.ModMapData.has("_ft_distort"): return
	var store = _g.ModMapData["_ft_distort"]
	if store.empty(): return
	var dead_keys = []
	for key in store.keys():
		var nd = _ft_node_from_key(key)
		if nd == null or not is_instance_valid(nd):
			dead_keys.append(key)
			continue
		var raw = store[key]
		if not raw is Array or raw.size() != 8:
			dead_keys.append(key); continue
		var lc = [
			Vector2(raw[0], raw[1]),
			Vector2(raw[2], raw[3]),
			Vector2(raw[4], raw[5]),
			Vector2(raw[6], raw[7]),
		]

		if _is_pattern(nd):
			# Ne PAS restaurer pendant un drag actif — _update_transform_mode gère le warp
			if _active_handle >= 0:
				var is_dragged = false
				for st in _drag_states:
					if st.node == nd:
						is_dragged = true; break
				if is_dragged:
					continue
			# Vérifie si le shader est encore sur le node (DD peut le réinitialiser)
			if _ft_materials.has(key):
				var expected_mat = _ft_materials[key].get("warp")
				if nd.material == expected_mat:
					continue  # shader encore en place
				_ft_materials.erase(key)
			# Ne réinstalle le shader pattern que si PatternShapeTool n'est pas actif.
			# Sinon, DD a besoin de travailler avec le pattern propre pour la création.
			if not select_active:
				continue
			# Utilise les coins locaux stockés + position courante du node
			var wc = []
			for c in lc:
				wc.append(c + nd.position)
			_apply_distort_pattern(nd, wc)
		else:
			if _ft_materials.has(key): continue  # shader déjà installé
			var sprite = _get_sprite_node(nd)
			if sprite == null: continue
			var to_world = nd.transform * sprite.transform
			var wc = []
			for c in lc:
				wc.append(to_world.xform(c))
			_apply_distort_shader(nd, wc)
	for key in dead_keys:
		store.erase(key)
		_ft_materials.erase(key)


# ══ Crop (masque polygonal) ════════════════════════════════════════════════
# Props uniquement. Le polygone est stocké en espace VERTEX du Sprite (±real/2),
# converti en monde via (node.transform * sprite.transform). Le masque est CUIT
# dans la texture du Sprite (pixels hors polygone -> transparents) : on ne touche
# jamais au material, donc les mods de couleur/ombre restent compatibles.
# Crop et distort restent mutuellement exclusifs.

func _is_plain_prop(nd: Node) -> bool:
	if nd == null or not is_instance_valid(nd): return false
	if _is_portal(nd) or _is_wall(nd) or _is_pattern(nd) or _is_path(nd): return false
	if _is_roof(nd) or _is_light(nd): return false
	return _get_sprite_node(nd) != null


func _is_crop_mode() -> bool:
	return _transform_mode == "crop" or _transform_mode == "softcrop"


func _crop_is_soft(node: Node2D) -> bool:
	var key = _ft_node_key(node)
	if key == "": return false
	var store = _g.ModMapData.get("_ft_crop_soft", {})
	return store.has(key) and store[key] == true


func _set_crop_soft(node: Node2D, soft: bool) -> void:
	var key = _ft_node_key(node)
	if key == "": return
	if not _g.ModMapData.has("_ft_crop_soft"):
		_g.ModMapData["_ft_crop_soft"] = {}
	if soft:
		_g.ModMapData["_ft_crop_soft"][key] = true
	else:
		_g.ModMapData["_ft_crop_soft"].erase(key)


const CROP_HARDNESS_DEFAULT := 0.85

func _crop_hardness(node: Node2D) -> float:
	# 0.0 = bord très doux (large feather) ... 1.0 = bord net (feather ~1px)
	var key = _ft_node_key(node)
	if key == "": return CROP_HARDNESS_DEFAULT
	var st = _g.ModMapData.get("_ft_crop_feather", {})
	if st.has(key):
		return float(st[key])
	return CROP_HARDNESS_DEFAULT


func _set_crop_hardness(node: Node2D, h: float) -> void:
	var key = _ft_node_key(node)
	if key == "": return
	if not _g.ModMapData.has("_ft_crop_feather"):
		_g.ModMapData["_ft_crop_feather"] = {}
	_g.ModMapData["_ft_crop_feather"][key] = clamp(h, -1.0, 1.0)


func _crop_feather_px(node: Node2D, W: int, H: int) -> float:
	var h = _crop_hardness(node)
	var maxf = 0.35 * float(min(W, H))
	return max(1.0, lerp(maxf, 1.0, h))


# ── Widget Soft Crop (label + slider + spinbox + reset, dans le SelectTool) ──

func _crop_soft_target() -> Node2D:
	var nd = _crop_node
	if (nd == null or not is_instance_valid(nd)) and _selected_objects.size() == 1:
		nd = _selected_objects[0]
	if nd != null and is_instance_valid(nd) and _is_plain_prop(nd):
		return nd
	return null


func _update_crop_slider_ui() -> void:
	if _crop_slider_row == null or not is_instance_valid(_crop_slider_row):
		return
	var show = _enabled and not _widget_force_hidden and _transform_mode == "softcrop" \
			and _selected_objects.size() == 1 and _is_plain_prop(_selected_objects[0]) \
			and _crop_is_soft(_selected_objects[0])
	_crop_slider_row.visible = show
	if not show:
		return
	# Repositionne le widget sous la ligne Free Transform et sous la ligne
	# Crop opacity (qui occupe gi+1) → soft crop en gi+2.
	var parent = _crop_slider_row.get_parent()
	if parent != null and _ui_group != null and is_instance_valid(_ui_group) \
			and _ui_group.get_parent() == parent:
		var gi = _ui_group.get_index()
		if _crop_slider_row.get_index() != gi + 2:
			parent.move_child(_crop_slider_row, gi + 2)
	var nd = _selected_objects[0]
	var sv = int(round((1.0 - _crop_hardness(nd)) * 100.0))   # douceur %
	_crop_slider_syncing = true
	if int(_crop_slider.value) != sv:
		_crop_slider.value = sv
	if _crop_spin != null and int(_crop_spin.value) != sv:
		_crop_spin.value = sv
	_crop_slider_syncing = false


func _on_crop_slider_changed(value) -> void:
	_apply_soft_from_ui(value)


func _on_crop_spin_changed(value) -> void:
	_apply_soft_from_ui(value)


func _apply_soft_from_ui(value) -> void:
	if _crop_slider_syncing:
		return
	var nd = _crop_soft_target()
	if nd == null:
		return
	# Capture l'état AVANT la rafale de réglage (pour un seul undo).
	if _crop_slider_before.empty():
		_crop_slider_before = _capture_ft_unified([nd])
		_crop_soft_before_node = nd
	_set_crop_hardness(nd, 1.0 - float(value) / 100.0)   # slider/spin = douceur
	# Synchronise l'autre contrôle.
	_crop_slider_syncing = true
	if _crop_slider != null and int(_crop_slider.value) != int(value):
		_crop_slider.value = value
	if _crop_spin != null and int(_crop_spin.value) != int(value):
		_crop_spin.value = value
	_crop_slider_syncing = false
	# Re-cuisson différée (au repos du contrôle) pour ne pas cuire chaque pas.
	_crop_feather_dirty_node = nd
	_crop_feather_dirty_ms = OS.get_ticks_msec()


func _on_crop_reset_pressed() -> void:
	var nd = _crop_soft_target()
	if nd == null:
		return
	var before = _capture_ft_unified([nd])
	_set_crop_hardness(nd, 1.0 - float(CROP_SOFT_DEFAULT) / 100.0)
	_crop_slider_syncing = true
	if _crop_slider != null: _crop_slider.value = CROP_SOFT_DEFAULT
	if _crop_spin != null: _crop_spin.value = CROP_SOFT_DEFAULT
	_crop_slider_syncing = false
	var pts = _crop_points if (_crop_node == nd and _crop_points.size() >= 3) else _load_crop_points(nd)
	if pts.size() >= 3:
		_bake_crop_texture(nd, pts)
	_record_ft_unified_change(before, _capture_ft_unified([nd]))
	_save_ft_data()
	# Annule une rafale en cours pour éviter un double enregistrement.
	_crop_slider_before = {}
	_crop_feather_dirty_node = null


# ── Widget Crop opacity (opacité de la partie cropée, crop ET soft crop) ──

const CROP_OPACITY_STRENGTH_DEFAULT := 100   # % d'opacité retirée (100 = invisible)

func _has_crop(node: Node2D) -> bool:
	var key = _ft_node_key(node)
	if key == "": return false
	var st = _g.ModMapData.get("_ft_crop", {})
	return st.has(key)


func _crop_keep_alpha(node: Node2D) -> float:
	# Fraction d'alpha conservée dans la partie cropée (0 = invisible, 1 = pleine).
	var key = _ft_node_key(node)
	if key == "": return 0.0
	var st = _g.ModMapData.get("_ft_crop_opacity", {})
	if st.has(key):
		return clamp(float(st[key]), 0.0, 1.0)
	return 0.0


func _set_crop_keep_alpha(node: Node2D, k: float) -> void:
	var key = _ft_node_key(node)
	if key == "": return
	if not _g.ModMapData.has("_ft_crop_opacity"):
		_g.ModMapData["_ft_crop_opacity"] = {}
	_g.ModMapData["_ft_crop_opacity"][key] = clamp(k, 0.0, 1.0)


func _update_crop_opacity_ui() -> void:
	if _crop_op_row == null or not is_instance_valid(_crop_op_row):
		return
	var show = _enabled and not _widget_force_hidden and _is_crop_mode() \
			and _selected_objects.size() == 1 and _is_plain_prop(_selected_objects[0]) \
			and _has_crop(_selected_objects[0])
	_crop_op_row.visible = show
	if not show:
		return
	# Ligne Crop opacity juste sous le groupe FT (gi+1).
	var parent = _crop_op_row.get_parent()
	if parent != null and _ui_group != null and is_instance_valid(_ui_group) \
			and _ui_group.get_parent() == parent:
		var gi = _ui_group.get_index()
		if _crop_op_row.get_index() != gi + 1:
			parent.move_child(_crop_op_row, gi + 1)
	var nd = _selected_objects[0]
	var sv = int(round((1.0 - _crop_keep_alpha(nd)) * 100.0))   # force (%) retirée
	_crop_op_syncing = true
	if int(_crop_op_slider.value) != sv:
		_crop_op_slider.value = sv
	if _crop_op_spin != null and int(_crop_op_spin.value) != sv:
		_crop_op_spin.value = sv
	_crop_op_syncing = false


func _on_crop_opacity_changed(value) -> void:
	_apply_opacity_from_ui(value)


func _on_crop_opacity_spin_changed(value) -> void:
	_apply_opacity_from_ui(value)


func _apply_opacity_from_ui(value) -> void:
	if _crop_op_syncing:
		return
	var nd = _crop_soft_target()
	if nd == null:
		return
	if _crop_slider_before.empty():
		_crop_slider_before = _capture_ft_unified([nd])
		_crop_soft_before_node = nd
	# value = % d'opacité retirée → keep = 1 - value/100.
	_set_crop_keep_alpha(nd, 1.0 - float(value) / 100.0)
	_crop_op_syncing = true
	if _crop_op_slider != null and int(_crop_op_slider.value) != int(value):
		_crop_op_slider.value = value
	if _crop_op_spin != null and int(_crop_op_spin.value) != int(value):
		_crop_op_spin.value = value
	_crop_op_syncing = false
	# Re-cuisson différée (réutilise le même mécanisme que le soft edge).
	_crop_feather_dirty_node = nd
	_crop_feather_dirty_ms = OS.get_ticks_msec()


func _on_crop_opacity_reset_pressed() -> void:
	var nd = _crop_soft_target()
	if nd == null:
		return
	var before = _capture_ft_unified([nd])
	_set_crop_keep_alpha(nd, 0.0)   # 100% → partie cropée invisible
	_crop_op_syncing = true
	if _crop_op_slider != null: _crop_op_slider.value = CROP_OPACITY_STRENGTH_DEFAULT
	if _crop_op_spin != null: _crop_op_spin.value = CROP_OPACITY_STRENGTH_DEFAULT
	_crop_op_syncing = false
	var pts = _crop_points if (_crop_node == nd and _crop_points.size() >= 3) else _load_crop_points(nd)
	if pts.size() >= 3:
		_bake_crop_texture(nd, pts)
	_record_ft_unified_change(before, _capture_ft_unified([nd]))
	_save_ft_data()
	_crop_slider_before = {}
	_crop_feather_dirty_node = null


func _flush_crop_feather_bake() -> void:
	var nd = _crop_feather_dirty_node
	_crop_feather_dirty_node = null
	if nd != null and is_instance_valid(nd):
		if _has_edgecrop(nd):
			_bake_edgecrop_texture(nd)
		else:
			var pts = _crop_points if (_crop_node == nd and _crop_points.size() >= 3) else _load_crop_points(nd)
			if pts.size() >= 3:
				_bake_crop_texture(nd, pts)
	# Enregistre l'undo de la rafale terminée (un seul Ctrl+Z).
	if not _crop_slider_before.empty() and _crop_soft_before_node != null \
			and is_instance_valid(_crop_soft_before_node):
		_record_ft_unified_change(_crop_slider_before, _capture_ft_unified([_crop_soft_before_node]))
		_save_ft_data()
	_crop_slider_before = {}
	_crop_soft_before_node = null


func _crop_real_size(sprite) -> Vector2:
	var tex = sprite.get("texture")
	var rr  = sprite.get("region_rect")
	if tex != null and rr is Rect2 and rr.size.length() > 0.0:
		return rr.size
	if tex != null:
		return tex.get_size()
	return Vector2(128.0, 128.0)


func _init_crop_corners(sprite) -> Array:
	var sz = _crop_real_size(sprite)
	var hw = sz.x * 0.5
	var hh = sz.y * 0.5
	return [
		Vector2(-hw, -hh), Vector2(hw, -hh),
		Vector2( hw,  hh), Vector2(-hw,  hh),
	]


func _crop_world_points() -> Array:
	var out = []
	if _crop_node == null or not is_instance_valid(_crop_node): return out
	var sprite = _get_sprite_node(_crop_node)
	if sprite == null: return out
	var to_world = _crop_node.transform * sprite.transform
	for p in _crop_points:
		out.append(to_world.xform(p))
	return out


func _ensure_crop_for_node(node: Node2D) -> void:
	if node == null or not is_instance_valid(node): return
	var sprite = _get_sprite_node(node)
	if sprite == null: return
	_crop_node = node
	var key = _ft_node_key(node)
	if key != "" and _g.ModMapData.has("_ft_crop") and _g.ModMapData["_ft_crop"].has(key):
		_crop_points = _load_crop_points(node)
		if _crop_points.size() < 3:
			_crop_points = _init_crop_corners(sprite)
			_store_crop_points(node)
		# Le crop existe déjà : le mode affiché suit la dureté mémorisée de l'objet
		# (on ne force pas la dureté depuis le mode courant).
		_transform_mode = "softcrop" if _crop_is_soft(node) else "crop"
		# Si la texture est déjà cuite ET que la signature correspond aux données
		# (re-sélection sans changement), inutile de re-cuire. Sinon on laisse
		# _apply_crop re-cuire avec les bonnes données.
		if sprite.texture != null and sprite.texture.has_meta("_ft_crop_baked") \
				and sprite.texture.get_meta("_ft_crop_sig", "") == _crop_baked_sig(node, _crop_points):
			return
	else:
		# Mutuellement exclusif avec le distort et l'edge crop.
		_remove_edgecrop(node)
		_remove_distort_shader(node)
		_crop_points = _init_crop_corners(sprite)
		# Nouveau crop : la dureté provient du mode courant.
		_set_crop_soft(node, _transform_mode == "softcrop")
		_store_crop_points(node)
	_apply_crop(node, _crop_points)


func _store_crop_points(node: Node2D) -> void:
	var key = _ft_node_key(node)
	if key == "": return
	if not _g.ModMapData.has("_ft_crop"):
		_g.ModMapData["_ft_crop"] = {}
	var flat = []
	for p in _crop_points:
		flat.append(p.x)
		flat.append(p.y)
	_g.ModMapData["_ft_crop"][key] = flat


func _load_crop_points(node: Node2D) -> Array:
	var out = []
	var key = _ft_node_key(node)
	if key != "" and _g.ModMapData.has("_ft_crop") and _g.ModMapData["_ft_crop"].has(key):
		var flat = _g.ModMapData["_ft_crop"][key]
		if flat is Array:
			var i = 0
			while i + 1 < flat.size():
				out.append(Vector2(flat[i], flat[i + 1]))
				i += 2
	return out


func _crop_baked_sig(node: Node2D, points: Array) -> String:
	return str(points) + "|" + str(_crop_is_soft(node)) + "|" + str(_crop_hardness(node)) + "|" + str(_crop_keep_alpha(node))


func _apply_crop(node: Node2D, points: Array) -> void:
	# Cuit le masque polygonal dans la texture du Sprite (sans toucher au material).
	_bake_crop_texture(node, points)


func _remove_crop(node: Node2D) -> void:
	if node == null: return
	_unbake_crop_texture(node)
	var id = _ft_node_key(node)
	if _g.ModMapData.has("_ft_crop"):
		_g.ModMapData["_ft_crop"].erase(id)
	if _g.ModMapData.has("_ft_crop_soft"):
		_g.ModMapData["_ft_crop_soft"].erase(id)
	if _g.ModMapData.has("_ft_crop_feather"):
		_g.ModMapData["_ft_crop_feather"].erase(id)
	if _g.ModMapData.has("_ft_crop_opacity"):
		_g.ModMapData["_ft_crop_opacity"].erase(id)
	if _crop_node == node:
		_crop_node = null
		_crop_points = []
		_crop_active_pt = -1


func _bake_crop_texture(node: Node2D, points: Array) -> void:
	var sprite = _get_sprite_node(node)
	if sprite == null: return
	var key = _ft_node_key(node)
	if key == "": return
	_snapshot_orig_xform(node)
	if points.size() < 3: return
	var prep = _crop_prepare_work(node, sprite, key)
	if prep.empty(): return
	var work : Image = prep["work"]
	var W : int = prep["W"]
	var H : int = prep["H"]
	var orig_tex = prep["orig_tex"]
	# Sortie : la partie cropée reçoit l'opacité résiduelle (keep), 0 = invisible.
	var out = Image.new()
	out.create(W, H, false, Image.FORMAT_RGBA8)
	var keep = _crop_keep_alpha(node)
	if keep > 0.0:
		_fill_image_alpha_scaled(out, work, W, H, keep)
	else:
		out.fill(Color(0, 0, 0, 0))
	if _crop_is_soft(node):
		var feather = _crop_feather_px(node, W, H)
		_bake_fill_soft(out, work, points, W, H, feather, keep)
	else:
		_bake_fill_hard(out, work, points, W, H)
	_finalize_crop_texture(node, sprite, orig_tex, out, _crop_baked_sig(node, points))


func _crop_prepare_work(node: Node2D, sprite, key: String) -> Dictionary:
	# Décode la texture originale du Sprite en RGBA8, en extrait la sous-image
	# visible (région si présente). Met en cache l'originale dans _crop_orig_tex
	# (partagée entre crop polygonal et edge crop, mutuellement exclusifs).
	# Retourne {} en cas d'échec, sinon {orig_tex, work, W, H}.
	var orig_tex
	var orig_region_enabled
	var orig_region_rect
	if _crop_orig_tex.has(key):
		orig_tex            = _crop_orig_tex[key]["texture"]
		orig_region_enabled = _crop_orig_tex[key]["region_enabled"]
		orig_region_rect    = _crop_orig_tex[key]["region_rect"]
	else:
		orig_tex            = sprite.texture
		orig_region_enabled = sprite.region_enabled
		orig_region_rect    = sprite.region_rect
		if orig_tex == null: return {}
		_crop_orig_tex[key] = {
			"texture": orig_tex,
			"region_enabled": orig_region_enabled,
			"region_rect": orig_region_rect,
		}
	if orig_tex == null: return {}
	var img = orig_tex.get_data()
	if img == null: return {}
	if img.get_format() >= Image.FORMAT_DXT1:
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	var work : Image
	var W : int
	var H : int
	if orig_region_enabled and orig_region_rect is Rect2 \
			and orig_region_rect.size.x >= 1.0 and orig_region_rect.size.y >= 1.0:
		W = int(orig_region_rect.size.x)
		H = int(orig_region_rect.size.y)
		work = Image.new()
		work.create(W, H, false, Image.FORMAT_RGBA8)
		work.blit_rect(img, orig_region_rect, Vector2.ZERO)
	else:
		work = img
		W = img.get_width()
		H = img.get_height()
	return {"orig_tex": orig_tex, "work": work, "W": W, "H": H}


func _finalize_crop_texture(node: Node2D, sprite, orig_tex, out: Image, sig: String) -> void:
	# Crée l'ImageTexture cuite, reprend le path de l'originale (cf. infra),
	# l'affecte au Sprite (région désactivée) et partage la texture à l'ombre.
	var new_tex = ImageTexture.new()
	var flags = orig_tex.flags if orig_tex is Texture else Texture.FLAG_FILTER
	new_tex.create_from_image(out, flags)
	new_tex.set_meta("_ft_crop_baked", true)
	# Signature des données cuites : permet de détecter qu'un re-cuisson est
	# nécessaire quand le store change après une cuisson.
	new_tex.set_meta("_ft_crop_sig", sig)
	# CRUCIAL : DD identifie l'asset par le resource_path de sa texture
	# (Infobar.SetAssetInfo fait dict[texture.resource_path]). Une ImageTexture
	# créée à la volée a un path vide "" → KeyNotFoundException qui plante
	# SelectTool.Select à la re-sélection. On reprend le path de l'originale
	# pour que le lookup retrouve l'asset. take_over_path ne touche pas la
	# base d'assets de DD (placement de nouveaux props inchangé).
	var orig_path = orig_tex.resource_path if orig_tex is Resource else ""
	if orig_path != "":
		new_tex.take_over_path(orig_path)
	sprite.region_enabled = false
	sprite.texture = new_tex
	# L'ombre vanilla (child 0) suit le crop : on lui partage la texture cropée.
	var _shadow_c = _get_shadow_sprite(node)
	if _shadow_c != null:
		_shadow_capture_orig(node, _shadow_c)
		_shadow_c.region_enabled = false
		_shadow_c.texture = new_tex


# ── Edge Crop : érosion du contour (alpha) ──────────────────────────────────

func _has_edgecrop(node) -> bool:
	var key = _ft_node_key(node)
	if key == "": return false
	var st = _g.ModMapData.get("_ft_edgecrop", {})
	return st.has(key)


func _edgecrop_px(node) -> int:
	var key = _ft_node_key(node)
	if key == "": return EDGECROP_PX_DEFAULT
	var st = _g.ModMapData.get("_ft_edgecrop", {})
	if st.has(key):
		return int(st[key].get("px", EDGECROP_PX_DEFAULT))
	return EDGECROP_PX_DEFAULT


func _edgecrop_hardness(node) -> float:
	var key = _ft_node_key(node)
	if key == "": return EDGECROP_HARD_DEFAULT
	var st = _g.ModMapData.get("_ft_edgecrop", {})
	if st.has(key):
		return clamp(float(st[key].get("hard", EDGECROP_HARD_DEFAULT)), 0.0, 1.0)
	return EDGECROP_HARD_DEFAULT


func _set_edgecrop(node, px: int, hard: float) -> void:
	var key = _ft_node_key(node)
	if key == "": return
	if not _g.ModMapData.has("_ft_edgecrop"):
		_g.ModMapData["_ft_edgecrop"] = {}
	_g.ModMapData["_ft_edgecrop"][key] = {
		"px": int(clamp(px, 0, EDGECROP_PX_MAX)),
		"hard": clamp(hard, 0.0, 1.0),
	}


func _edgecrop_baked_sig(node) -> String:
	return "edge|" + str(_edgecrop_px(node)) + "|" + str(_edgecrop_hardness(node))


func _edgecrop_target() -> Node2D:
	if _selected_objects.size() == 1 and is_instance_valid(_selected_objects[0]) \
			and _is_plain_prop(_selected_objects[0]):
		return _selected_objects[0]
	return null


func _ensure_edgecrop_for_node(node: Node2D) -> void:
	if node == null or not is_instance_valid(node): return
	var sprite = _get_sprite_node(node)
	if sprite == null: return
	# Exclusif avec le crop polygonal et le distort.
	if _has_crop(node):
		_remove_crop(node)
	_remove_distort_shader(node)
	if not _has_edgecrop(node):
		_ensure_edgecrop_default_loaded()
		_set_edgecrop(node, _edgecrop_default_px, _edgecrop_default_hard)
	# Déjà cuit avec la bonne signature ? inutile de re-cuire.
	if sprite.texture != null and sprite.texture.has_meta("_ft_crop_baked") \
			and sprite.texture.get_meta("_ft_crop_sig", "") == _edgecrop_baked_sig(node):
		return
	_bake_edgecrop_texture(node)


func _remove_edgecrop(node: Node2D) -> void:
	if node == null: return
	if not _has_edgecrop(node):
		return
	_unbake_crop_texture(node)
	var id = _ft_node_key(node)
	if _g.ModMapData.has("_ft_edgecrop"):
		_g.ModMapData["_ft_edgecrop"].erase(id)


func _bake_edgecrop_texture(node: Node2D) -> void:
	var sprite = _get_sprite_node(node)
	if sprite == null: return
	var key = _ft_node_key(node)
	if key == "": return
	_snapshot_orig_xform(node)
	var prep = _crop_prepare_work(node, sprite, key)
	if prep.empty(): return
	var work : Image = prep["work"]
	var W : int = prep["W"]
	var H : int = prep["H"]
	var orig_tex = prep["orig_tex"]
	var radius = _edgecrop_px(node)
	var hard = _edgecrop_hardness(node)
	var out = _erode_alpha_image(work, W, H, radius, hard)
	_finalize_crop_texture(node, sprite, orig_tex, out, _edgecrop_baked_sig(node))


func _erode_alpha_image(work: Image, W: int, H: int, radius: int, hardness: float) -> Image:
	# Rogne l'asset depuis l'extérieur en suivant son contour. Travail sur les
	# octets RGBA8 bruts (PoolByteArray) — pas de get_pixel/set_pixel (qui
	# allouent un Color par pixel et dominent le coût). Distance transform
	# chamfer (1 / √2) sur l'alpha, puis fondu de l'alpha selon la distance.
	var src = work.get_data()           # RGBA8, taille W*H*4
	var out_img = Image.new()
	if radius <= 0 or W <= 0 or H <= 0:
		out_img.create_from_data(W, H, false, Image.FORMAT_RGBA8, src)
		return out_img
	var n = W * H
	# f = demi-largeur de la bande de fondu. hardness=1 → ~0.5px (net) ;
	# hardness=0 → EDGECROP_SOFT_MULT × radius (très doux).
	var f = max(0.5, (1.0 - hardness) * float(radius) * EDGECROP_SOFT_MULT)
	# BIG doit dépasser la distance max réelle ET le sommet de la bande
	# (radius + f), pour que l'intérieur profond sature bien à alpha plein.
	var BIG = max(float(W + H), float(radius) + f) * 2.0 + 16.0
	var thr = int(_EDGECROP_ALPHA_THR * 255.0)
	var d2 = 1.41421356
	var dist = PoolRealArray()
	dist.resize(n)
	# Init : 0 si extérieur (alpha <= seuil), BIG sinon.
	for i in range(n):
		dist[i] = 0.0 if src[i * 4 + 3] <= thr else BIG
	# Passe avant (haut-gauche → bas-droite).
	for y in range(H):
		var row = y * W
		for x in range(W):
			var i = row + x
			var v = dist[i]
			if v == 0.0:
				continue
			if x > 0 and dist[i - 1] + 1.0 < v:
				v = dist[i - 1] + 1.0
			if y > 0:
				var up = i - W
				if dist[up] + 1.0 < v:
					v = dist[up] + 1.0
				if x > 0 and dist[up - 1] + d2 < v:
					v = dist[up - 1] + d2
				if x < W - 1 and dist[up + 1] + d2 < v:
					v = dist[up + 1] + d2
			if v < dist[i]:
				dist[i] = v
	# Passe arrière (bas-droite → haut-gauche).
	for y in range(H - 1, -1, -1):
		var row2 = y * W
		for x in range(W - 1, -1, -1):
			var i2 = row2 + x
			var v2 = dist[i2]
			if v2 == 0.0:
				continue
			if x < W - 1 and dist[i2 + 1] + 1.0 < v2:
				v2 = dist[i2 + 1] + 1.0
			if y < H - 1:
				var dn = i2 + W
				if dist[dn] + 1.0 < v2:
					v2 = dist[dn] + 1.0
				if x > 0 and dist[dn - 1] + d2 < v2:
					v2 = dist[dn - 1] + d2
				if x < W - 1 and dist[dn + 1] + d2 < v2:
					v2 = dist[dn + 1] + d2
			if v2 < dist[i2]:
				dist[i2] = v2
	# Écriture : copie des octets puis modulation de l'alpha. Fondu centré sur
	# « radius » ; au-delà de radius+f l'alpha est plein (skip), en deçà nul.
	var rf = float(radius)
	var inv2f = 1.0 / (2.0 * f)
	var dst = PoolByteArray()
	dst = src
	for i in range(n):
		var d = dist[i]
		var amul = 0.5 + (d - rf) * inv2f
		if amul >= 1.0:
			continue
		var ai = i * 4 + 3
		if amul <= 0.0:
			dst[ai] = 0
		else:
			dst[ai] = int(src[ai] * amul)
	out_img.create_from_data(W, H, false, Image.FORMAT_RGBA8, dst)
	return out_img


func _restore_edgecrop_from_store(select_active: bool = true) -> void:
	if not select_active: return
	if not _g.ModMapData.has("_ft_edgecrop"): return
	var store = _g.ModMapData["_ft_edgecrop"]
	if store.empty(): return
	var dead_keys = []
	for key in store.keys():
		var nd = _ft_node_from_key(key)
		if nd == null or not is_instance_valid(nd):
			dead_keys.append(key)
			continue
		if not _is_plain_prop(nd): continue
		# Ne pas re-cuire pendant qu'une cuisson est différée pour ce node.
		if _crop_feather_dirty_node == nd and is_instance_valid(nd): continue
		var sprite = _get_sprite_node(nd)
		if sprite == null: continue
		var cur = sprite.texture
		if cur != null and cur.has_meta("_ft_crop_baked"):
			if cur.get_meta("_ft_crop_sig", "") == _edgecrop_baked_sig(nd):
				continue
		_bake_edgecrop_texture(nd)
	for key in dead_keys:
		store.erase(key)
		_crop_orig_tex.erase(key)


# ── Widget Edge Crop (px rognés + dureté, dans le SelectTool) ───────────────

func _update_edgecrop_ui() -> void:
	if _edge_px_row == null or not is_instance_valid(_edge_px_row):
		return
	var show = _enabled and not _widget_force_hidden and _transform_mode == "edgecrop" \
			and _selected_objects.size() == 1 and _is_plain_prop(_selected_objects[0]) \
			and _has_edgecrop(_selected_objects[0])
	_edge_px_row.visible = show
	if _edge_hard_row != null and is_instance_valid(_edge_hard_row):
		_edge_hard_row.visible = show
	if _edge_tools_row != null and is_instance_valid(_edge_tools_row):
		_edge_tools_row.visible = show
	if not show:
		return
	# Place px en gi+1, dureté en gi+2, outils en gi+3 sous la ligne Free Transform.
	var parent = _edge_px_row.get_parent()
	if parent != null and _ui_group != null and is_instance_valid(_ui_group) \
			and _ui_group.get_parent() == parent:
		var gi = _ui_group.get_index()
		if _edge_px_row.get_index() != gi + 1:
			parent.move_child(_edge_px_row, gi + 1)
		if _edge_hard_row != null and is_instance_valid(_edge_hard_row) \
				and _edge_hard_row.get_index() != gi + 2:
			parent.move_child(_edge_hard_row, gi + 2)
		if _edge_tools_row != null and is_instance_valid(_edge_tools_row) \
				and _edge_tools_row.get_index() != gi + 3:
			parent.move_child(_edge_tools_row, gi + 3)
	if _edge_paste_btn != null and is_instance_valid(_edge_paste_btn):
		_edge_paste_btn.disabled = _edgecrop_clip.empty()
	var nd = _selected_objects[0]
	var pv = _edgecrop_px(nd)
	var hv = int(round(_edgecrop_hardness(nd) * 100.0))
	_edge_syncing = true
	if int(_edge_px_slider.value) != pv:
		_edge_px_slider.value = pv
	if _edge_px_spin != null and int(_edge_px_spin.value) != pv:
		_edge_px_spin.value = pv
	if int(_edge_hard_slider.value) != hv:
		_edge_hard_slider.value = hv
	if _edge_hard_spin != null and int(_edge_hard_spin.value) != hv:
		_edge_hard_spin.value = hv
	_edge_syncing = false


func _on_edge_px_changed(value) -> void:
	if _edge_syncing:
		return
	_edge_syncing = true
	if _edge_px_spin != null and int(_edge_px_spin.value) != int(value):
		_edge_px_spin.value = value
	if _edge_px_slider != null and int(_edge_px_slider.value) != int(value):
		_edge_px_slider.value = value
	_edge_syncing = false
	_apply_edge_from_ui()


func _on_edge_hard_changed(value) -> void:
	if _edge_syncing:
		return
	_edge_syncing = true
	if _edge_hard_spin != null and int(_edge_hard_spin.value) != int(value):
		_edge_hard_spin.value = value
	if _edge_hard_slider != null and int(_edge_hard_slider.value) != int(value):
		_edge_hard_slider.value = value
	_edge_syncing = false
	_apply_edge_from_ui()


func _apply_edge_from_ui() -> void:
	var nd = _edgecrop_target()
	if nd == null:
		return
	# Capture l'état AVANT la rafale de réglage (pour un seul undo).
	if _crop_slider_before.empty():
		_crop_slider_before = _capture_ft_unified([nd])
		_crop_soft_before_node = nd
	var px = int(_edge_px_slider.value)
	var hard = float(_edge_hard_slider.value) / 100.0
	_set_edgecrop(nd, px, hard)
	# Re-cuisson différée (au repos du contrôle) — réutilise le debounce du
	# soft crop (_crop_feather_dirty_node / _flush_crop_feather_bake).
	_crop_feather_dirty_node = nd
	_crop_feather_dirty_ms = OS.get_ticks_msec()


func _on_edge_reset_pressed(which: String) -> void:
	var nd = _edgecrop_target()
	if nd == null:
		return
	var before = _capture_ft_unified([nd])
	var px = _edgecrop_px(nd)
	var hard = _edgecrop_hardness(nd)
	_ensure_edgecrop_default_loaded()
	if which == "px":
		px = _edgecrop_default_px
	else:
		hard = _edgecrop_default_hard
	_set_edgecrop(nd, px, hard)
	_edge_syncing = true
	if _edge_px_slider != null: _edge_px_slider.value = px
	if _edge_px_spin != null: _edge_px_spin.value = px
	if _edge_hard_slider != null: _edge_hard_slider.value = int(round(hard * 100.0))
	if _edge_hard_spin != null: _edge_hard_spin.value = int(round(hard * 100.0))
	_edge_syncing = false
	_bake_edgecrop_texture(nd)
	_record_ft_unified_change(before, _capture_ft_unified([nd]))
	_save_ft_data()
	_crop_slider_before = {}
	_crop_feather_dirty_node = null


# ── Edge Crop : Copy / Paste / Default / Factory ────────────────────────────

func _on_edge_copy_pressed() -> void:
	var nd = _edgecrop_target()
	if nd == null or not _has_edgecrop(nd):
		return
	_edgecrop_clip = {"px": _edgecrop_px(nd), "hard": _edgecrop_hardness(nd)}


func _on_edge_paste_pressed() -> void:
	var nd = _edgecrop_target()
	if nd == null or _edgecrop_clip.empty():
		return
	var before = _capture_ft_unified([nd])
	var px = int(_edgecrop_clip.get("px", _edgecrop_default_px))
	var hard = float(_edgecrop_clip.get("hard", _edgecrop_default_hard))
	_set_edgecrop(nd, px, hard)
	_edge_syncing = true
	if _edge_px_slider != null: _edge_px_slider.value = px
	if _edge_px_spin != null: _edge_px_spin.value = px
	if _edge_hard_slider != null: _edge_hard_slider.value = int(round(hard * 100.0))
	if _edge_hard_spin != null: _edge_hard_spin.value = int(round(hard * 100.0))
	_edge_syncing = false
	_bake_edgecrop_texture(nd)
	_record_ft_unified_change(before, _capture_ft_unified([nd]))
	_save_ft_data()
	_crop_slider_before = {}
	_crop_feather_dirty_node = null


func _on_edge_default_pressed() -> void:
	var nd = _edgecrop_target()
	if nd == null or not _has_edgecrop(nd):
		return
	_ensure_edgecrop_default_loaded()
	_edgecrop_default_px = _edgecrop_px(nd)
	_edgecrop_default_hard = _edgecrop_hardness(nd)
	_save_edgecrop_default()
	print("[FreeTransform] Edge crop default set: %dpx / %d%%" \
			% [_edgecrop_default_px, int(round(_edgecrop_default_hard * 100.0))])


func _on_edge_factory_pressed() -> void:
	_ensure_edgecrop_default_loaded()
	_edgecrop_default_px = EDGECROP_PX_DEFAULT
	_edgecrop_default_hard = EDGECROP_HARD_DEFAULT
	_save_edgecrop_default()
	print("[FreeTransform] Edge crop default reset to factory")


func _edgecrop_default_path() -> String:
	var dir = Directory.new()
	if not dir.dir_exists("user://UnofficialPatch"):
		dir.make_dir_recursive("user://UnofficialPatch")
	if not dir.dir_exists("user://UnofficialPatch/free_transform"):
		dir.make_dir_recursive("user://UnofficialPatch/free_transform")
	return "user://UnofficialPatch/free_transform/edgecrop_default.json"


func _ensure_edgecrop_default_loaded() -> void:
	if _edgecrop_default_loaded:
		return
	_edgecrop_default_loaded = true
	var path = _edgecrop_default_path()
	var file = File.new()
	if not file.file_exists(path):
		return
	if file.open(path, File.READ) != OK:
		return
	var text = file.get_as_text()
	file.close()
	var parsed = JSON.parse(text)
	if parsed.error != OK or not (parsed.result is Dictionary):
		return
	var d = parsed.result
	if d.has("px"):
		_edgecrop_default_px = int(clamp(int(d["px"]), 0, EDGECROP_PX_MAX))
	if d.has("hard"):
		_edgecrop_default_hard = clamp(float(d["hard"]), 0.0, 1.0)


func _save_edgecrop_default() -> void:
	var file = File.new()
	if file.open(_edgecrop_default_path(), File.WRITE) != OK:
		return
	file.store_string(JSON.print({"px": _edgecrop_default_px, "hard": _edgecrop_default_hard}))
	file.close()


func _bake_fill_hard(out: Image, work: Image, points: Array, W: int, H: int) -> void:
	# Remplissage net (scanline even-odd) : copie ligne par ligne l'intérieur.
	var hw = W * 0.5
	var hh = H * 0.5
	var n = points.size()
	for py in range(H):
		var ly = float(py) + 0.5 - hh
		var xs = []
		for i in range(n):
			var a = points[i]
			var b = points[(i + 1) % n]
			if (a.y <= ly and b.y > ly) or (b.y <= ly and a.y > ly):
				var t = (ly - a.y) / (b.y - a.y)
				xs.append(a.x + t * (b.x - a.x))
		xs.sort()
		var j = 0
		while j + 1 < xs.size():
			var px0 = int(round(xs[j] + hw - 0.5))
			var px1 = int(round(xs[j + 1] + hw - 0.5))
			j += 2
			if px1 < 0 or px0 > W - 1:
				continue
			if px0 < 0: px0 = 0
			if px1 > W - 1: px1 = W - 1
			if px1 >= px0:
				out.blit_rect(work, Rect2(px0, py, px1 - px0 + 1, 1), Vector2(px0, py))


func _dist2_point_seg(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab = b - a
	var l2 = ab.length_squared()
	if l2 < 0.000001:
		return p.distance_squared_to(a)
	var t = (p - a).dot(ab) / l2
	t = clamp(t, 0.0, 1.0)
	return p.distance_squared_to(a + ab * t)


func _bake_fill_soft(out: Image, work: Image, points: Array, W: int, H: int, feather: float, keep: float = 0.0) -> void:
	# Bord adouci. Optimisation : l'intérieur profond est plein (amul=1) et le
	# lointain extérieur reste à l'opacité résiduelle (keep) — seul un liseré
	# autour des arêtes a un dégradé. On remplit donc l'intérieur d'un coup
	# (scanline rapide), puis on ne recalcule le dégradé que dans la bande autour
	# de chaque arête, et on n'écrit que les pixels réellement dans le dégradé
	# (0 < amul < 1).
	if feather <= 0.0:
		_bake_fill_hard(out, work, points, W, H)
		return
	# 1) Intérieur plein.
	_bake_fill_hard(out, work, points, W, H)
	# 2) Dégradé dans la bande des arêtes uniquement.
	var hw = W * 0.5
	var hh = H * 0.5
	var n = points.size()
	var inv2f = 1.0 / (2.0 * feather)
	var fpx = int(ceil(feather)) + 1
	work.lock()
	out.lock()
	for i in range(n):
		var a = points[i]
		var b = points[(i + 1) % n]
		# Bbox pixel de l'arête, élargie du feather.
		var ex0 = int(floor(min(a.x, b.x) + hw - fpx))
		var ex1 = int(ceil(max(a.x, b.x) + hw + fpx))
		var ey0 = int(floor(min(a.y, b.y) + hh - fpx))
		var ey1 = int(ceil(max(a.y, b.y) + hh + fpx))
		ex0 = int(clamp(ex0, 0, W - 1)); ex1 = int(clamp(ex1, 0, W - 1))
		ey0 = int(clamp(ey0, 0, H - 1)); ey1 = int(clamp(ey1, 0, H - 1))
		for py in range(ey0, ey1 + 1):
			var ly = float(py) + 0.5 - hh
			for px in range(ex0, ex1 + 1):
				var lx = float(px) + 0.5 - hw
				var P = Vector2(lx, ly)
				# inside (even-odd) + distance² mini aux arêtes (min GLOBAL).
				var inside = false
				var mind2 = 1.0e20
				for k in range(n):
					var a2 = points[k]
					var b2 = points[(k + 1) % n]
					if (a2.y > ly) != (b2.y > ly):
						if lx < (b2.x - a2.x) * (ly - a2.y) / (b2.y - a2.y) + a2.x:
							inside = not inside
					var d2 = _dist2_point_seg(P, a2, b2)
					if d2 < mind2: mind2 = d2
				var dist = sqrt(mind2)
				var signed = dist if inside else -dist
				var amul = clamp(0.5 + signed * inv2f, 0.0, 1.0)
				# Hors dégradé : intérieur plein déjà fait, extérieur déjà à keep.
				if amul <= 0.0 or amul >= 1.0:
					continue
				var col = work.get_pixel(px, py)
				# Dégradé entre l'opacité résiduelle (extérieur) et plein (intérieur).
				col.a = col.a * (keep + (1.0 - keep) * amul)
				out.set_pixel(px, py, col)
	work.unlock()
	out.unlock()


func _fill_image_alpha_scaled(out: Image, work: Image, W: int, H: int, keep: float) -> void:
	# Recopie toute l'image source dans out avec l'alpha multiplié par keep.
	# Sert de couche « partie cropée » conservée à une opacité réduite.
	work.lock()
	out.lock()
	for y in range(H):
		for x in range(W):
			var c = work.get_pixel(x, y)
			c.a = c.a * keep
			out.set_pixel(x, y, c)
	out.unlock()
	work.unlock()


func _unbake_crop_texture(node: Node2D) -> void:
	if node == null: return
	var sprite = _get_sprite_node(node)
	var key = _ft_node_key(node)
	if sprite != null and _crop_orig_tex.has(key):
		var o = _crop_orig_tex[key]
		sprite.texture = o["texture"]
		sprite.region_enabled = o["region_enabled"]
		if o["region_rect"] is Rect2:
			sprite.region_rect = o["region_rect"]
	_crop_orig_tex.erase(key)
	_shadow_restore(node)


func _restore_crop_from_store(select_active: bool = true) -> void:
	if not select_active: return
	if not _g.ModMapData.has("_ft_crop"): return
	var store = _g.ModMapData["_ft_crop"]
	if store.empty(): return
	var dead_keys = []
	for key in store.keys():
		var nd = _ft_node_from_key(key)
		if nd == null or not is_instance_valid(nd):
			dead_keys.append(key)
			continue
		if not _is_plain_prop(nd): continue
		# Ne pas re-cuire pendant un drag actif (la cuisson a lieu au relâché).
		if _crop_active_pt >= 0 and _crop_node == nd: continue
		# Ni pendant qu'une cuisson feather (slider dureté) est différée pour ce
		# node : _flush_crop_feather_bake s'en chargera (sinon on annule le debounce).
		if _crop_feather_dirty_node == nd and is_instance_valid(nd): continue
		var sprite = _get_sprite_node(nd)
		if sprite == null: continue
		var pts = _load_crop_points(nd)
		# Déjà cuite ? On ne saute que si la signature correspond aux données
		# stockées ; sinon (store modifié après cuisson) on re-cuit.
		var cur = sprite.texture
		if cur != null and cur.has_meta("_ft_crop_baked"):
			if cur.get_meta("_ft_crop_sig", "") == _crop_baked_sig(nd, pts):
				continue
		if pts.size() >= 3:
			_bake_crop_texture(nd, pts)
			if _crop_node == nd:
				_crop_points = pts
	for key in dead_keys:
		store.erase(key)
		_crop_orig_tex.erase(key)


func _crop_hit_vertex(wp: Vector2, vp: Node) -> int:
	var wpts = _crop_world_points()
	if wpts.empty(): return -1
	var zoom = vp.canvas_transform.get_scale().x
	var thr  = 20.0 / zoom
	var best = -1
	var bd   = thr
	for i in range(wpts.size()):
		var d = wp.distance_to(wpts[i])
		if d < bd:
			bd = d
			best = i
	return best


func _crop_hit_edge(wp: Vector2, vp: Node) -> Dictionary:
	var wpts = _crop_world_points()
	if wpts.size() < 2: return {}
	var zoom = vp.canvas_transform.get_scale().x
	var thr  = 12.0 / zoom
	var best = {}
	var bd   = thr
	for i in range(wpts.size()):
		var a = wpts[i]
		var b = wpts[(i + 1) % wpts.size()]
		var ab = b - a
		var len2 = ab.length_squared()
		if len2 < 0.0001: continue
		var t = clamp((wp - a).dot(ab) / len2, 0.0, 1.0)
		var proj = a + ab * t
		var d = wp.distance_to(proj)
		if d < bd:
			bd = d
			var lc_a = _crop_points[i]
			var lc_b = _crop_points[(i + 1) % _crop_points.size()]
			best = {"after": i, "lc": lc_a.linear_interpolate(lc_b, t)}
	return best


# ══ Menu contextuel ════════════════════════════════════════════════════════

func _show_path_warning_popup() -> void:
	if _warning_dialog != null and is_instance_valid(_warning_dialog):
		_warning_dialog.queue_free()

	var dialog = WindowDialog.new()
	dialog.window_title = "Free Transform"
	dialog.rect_min_size = Vector2(380, 0)

	var vbox = VBoxContainer.new()
	vbox.anchor_right = 1.0
	vbox.margin_left = 16
	vbox.margin_right = -16
	vbox.margin_top = 12
	vbox.set("custom_constants/separation", 10)
	dialog.add_child(vbox)

	var lbl_warn = Label.new()
	lbl_warn.text = "WARNING!"
	lbl_warn.align = Label.ALIGN_CENTER
	vbox.add_child(lbl_warn)

	var lbl_msg = Label.new()
	lbl_msg.text = "Paths don't properly work\nwith Distort or Perspective."
	lbl_msg.align = Label.ALIGN_CENTER
	lbl_msg.autowrap = true
	vbox.add_child(lbl_msg)

	vbox.add_child(HSeparator.new())

	var btn_continue = Button.new()
	btn_continue.text = "Continue anyway"
	btn_continue.connect("pressed", self, "_on_path_warning_choice", [0])
	vbox.add_child(btn_continue)

	var btn_deselect = Button.new()
	btn_deselect.text = "Deselect paths from selection"
	btn_deselect.connect("pressed", self, "_on_path_warning_choice", [1])
	vbox.add_child(btn_deselect)

	var btn_back = Button.new()
	btn_back.text = "Choose another transform mode"
	btn_back.connect("pressed", self, "_on_path_warning_choice", [2])
	vbox.add_child(btn_back)

	dialog.connect("popup_hide", self, "_on_warning_dialog_hide")

	# Ajoute au même endroit que save_reminder (Editor/Windows)
	var windows = _g.Editor.get_node_or_null("Windows") if _g.Editor else null
	if windows != null:
		windows.add_child(dialog)
	else:
		_g.World.get_tree().root.add_child(dialog)

	_warning_dialog = dialog
	dialog.popup_centered(Vector2(380, 260))

	# Style les boutons après un court délai (comme save_reminder)
	var timer = Timer.new()
	timer.wait_time = 0.1
	timer.one_shot = true
	timer.connect("timeout", self, "_style_warning_buttons", [dialog, timer])
	_g.World.get_tree().root.add_child(timer)
	timer.start()


func _style_warning_buttons(dialog: Node, timer: Timer) -> void:
	timer.queue_free()
	if not is_instance_valid(dialog): return
	for child in _find_all_buttons(dialog):
		var existing = child.get_stylebox("normal")
		if existing != null and existing is StyleBoxFlat:
			var style = existing.duplicate()
			style.border_color = Color(0.6, 0.6, 0.6, 0.7)
			style.set_border_width_all(1)
			style.content_margin_left  = 20
			style.content_margin_right = 20
			child.add_stylebox_override("normal", style)


func _find_all_buttons(node: Node) -> Array:
	var result = []
	if node is Button:
		result.append(node)
	for child in node.get_children():
		result += _find_all_buttons(child)
	return result


func _apply_mode_switch(new_mode: String) -> void:
	var _mb = _capture_mode()
	_transform_mode = new_mode
	_record_mode_change(_mb, _capture_mode())
	if new_mode in ["crop", "softcrop"] and _selected_objects.size() == 1 \
			and _is_plain_prop(_selected_objects[0]):
		var _cn = _selected_objects[0]
		var _bU = _capture_ft_unified([_cn])
		_set_crop_soft(_cn, new_mode == "softcrop")
		_ensure_crop_for_node(_cn)
		var _aU = _capture_ft_unified([_cn])
		_record_ft_unified_change(_bU, _aU)
		_save_ft_data()
	elif new_mode == "edgecrop" and _selected_objects.size() == 1 \
			and _is_plain_prop(_selected_objects[0]):
		var _en = _selected_objects[0]
		var _ebU = _capture_ft_unified([_en])
		_ensure_edgecrop_for_node(_en)
		var _eaU = _capture_ft_unified([_en])
		_record_ft_unified_change(_ebU, _eaU)
		_save_ft_data()


func _dismiss_transform_menu_for_warning() -> void:
	# Ferme le menu contextuel sans déclencher _on_transform_menu_closed
	# (qui tuerait le popup de warning qu'on s'apprête à montrer).
	if _context_menu != null and is_instance_valid(_context_menu):
		if _context_menu.is_connected("popup_hide", self, "_on_transform_menu_closed"):
			_context_menu.disconnect("popup_hide", self, "_on_transform_menu_closed")
		_context_menu.queue_free()
		_context_menu = null


func _show_crop_warp_warning_popup(leaving_crop: bool) -> void:
	if _warning_dialog != null and is_instance_valid(_warning_dialog):
		_warning_dialog.queue_free()

	var dialog = WindowDialog.new()
	dialog.window_title = "Free Transform"
	dialog.rect_min_size = Vector2(380, 0)

	var vbox = VBoxContainer.new()
	vbox.anchor_right = 1.0
	vbox.margin_left = 16
	vbox.margin_right = -16
	vbox.margin_top = 12
	vbox.set("custom_constants/separation", 10)
	dialog.add_child(vbox)

	var lbl_warn = Label.new()
	lbl_warn.text = "WARNING!"
	lbl_warn.align = Label.ALIGN_CENTER
	vbox.add_child(lbl_warn)

	var lbl_msg = Label.new()
	if leaving_crop:
		lbl_msg.text = "This asset is cropped.\nSwitching to Skew / Distort / Perspective\nwill remove the crop."
	else:
		lbl_msg.text = "This asset is distorted.\nSwitching to Crop / Soft Crop\nwill remove the distortion."
	lbl_msg.align = Label.ALIGN_CENTER
	lbl_msg.autowrap = true
	vbox.add_child(lbl_msg)

	vbox.add_child(HSeparator.new())

	var btn_continue = Button.new()
	btn_continue.text = "Continue anyway"
	btn_continue.connect("pressed", self, "_on_crop_warp_warning_choice", [0])
	vbox.add_child(btn_continue)

	var btn_cancel = Button.new()
	btn_cancel.text = "Cancel"
	btn_cancel.connect("pressed", self, "_on_crop_warp_warning_choice", [1])
	vbox.add_child(btn_cancel)

	dialog.connect("popup_hide", self, "_on_warning_dialog_hide")

	var windows = _g.Editor.get_node_or_null("Windows") if _g.Editor else null
	if windows != null:
		windows.add_child(dialog)
	else:
		_g.World.get_tree().root.add_child(dialog)

	_warning_dialog = dialog
	dialog.popup_centered(Vector2(380, 240))

	var timer = Timer.new()
	timer.wait_time = 0.1
	timer.one_shot = true
	timer.connect("timeout", self, "_style_warning_buttons", [dialog, timer])
	_g.World.get_tree().root.add_child(timer)
	timer.start()


func _on_crop_warp_warning_choice(id: int) -> void:
	if _warning_dialog != null and is_instance_valid(_warning_dialog):
		if _warning_dialog.is_connected("popup_hide", self, "_on_warning_dialog_hide"):
			_warning_dialog.disconnect("popup_hide", self, "_on_warning_dialog_hide")
		_warning_dialog.queue_free()
	_warning_dialog = null
	if id == 0:
		# Continue : on applique le changement (l'autre modif sera retirée par
		# _ensure_crop_for_node / _apply_distort_* selon le cas).
		_apply_mode_switch(_pending_mode)
	_pending_mode = ""


func _on_warning_dialog_hide() -> void:
	if _warning_dialog != null and is_instance_valid(_warning_dialog):
		_warning_dialog.queue_free()
	_warning_dialog = null
	_pending_mode = ""


func _on_path_warning_choice(id: int) -> void:
	if _warning_dialog != null and is_instance_valid(_warning_dialog):
		if _warning_dialog.is_connected("popup_hide", self, "_on_warning_dialog_hide"):
			_warning_dialog.disconnect("popup_hide", self, "_on_warning_dialog_hide")
		_warning_dialog.queue_free()
	_warning_dialog = null

	match id:
		0:
			var _mode_before5 = _capture_mode()
			_transform_mode = _pending_mode
			_record_mode_change(_mode_before5, _capture_mode())
		1:
			var non_paths = []
			for nd in _selected_objects:
				if is_instance_valid(nd) and not _is_path(nd):
					non_paths.append(nd)
			if non_paths.size() > 0:
				if _select_tool != null:
					_select_tool.call("DeselectAll")
					for nd in non_paths:
						_select_tool.call("SelectThing", nd, true)
			var _mode_before6 = _capture_mode()
			_transform_mode = _pending_mode
			_record_mode_change(_mode_before6, _capture_mode())
		2:
			# Rouvre le menu à la position d'origine
			_show_transform_menu_at(_menu_position)

	_pending_mode = ""


func _show_transform_menu() -> void:
	var mouse_pos = _g.World.get_tree().root.get_mouse_position()
	_show_transform_menu_at(mouse_pos)


func _show_transform_menu_at(pos: Vector2) -> void:
	# Signale au mod Favorites de ne pas afficher son propre menu
	_g.ModMapData["_free_transform_active"] = true

	if _context_menu != null and is_instance_valid(_context_menu):
		_context_menu.queue_free()

	var menu = PopupMenu.new()

	var is_portal_sel = _all_portals()

	if is_portal_sel:
		# Menu pour les portals : Scale, Slide, Offset
		var scale_prefix = "» " if _portal_mode == "scale" else "  "
		var slide_prefix = "» " if _portal_mode == "slide" else "  "
		var offset_prefix = "» " if _portal_mode == "offset" else "  "
		menu.add_item(scale_prefix + "Scale", 0)
		menu.add_item(slide_prefix + "Slide", 13)
		menu.add_item(offset_prefix + "Offset", 12)
		# Symétries (flip local : le long du mur / perpendiculaire au mur)
		menu.add_separator()
		menu.add_item("Horizontal Symmetry", 20)
		menu.add_item("Vertical Symmetry", 21)
		# Séparateur + Reset
		menu.add_separator()
		menu.add_item("Reset transform", 10)
	else:
		# En-tête non-cliquable (centré avec padding)
		menu.add_item("    Transform Mode", 99)
		menu.set_item_disabled(menu.get_item_index(99), true)
		menu.add_separator()

		# Items de mode avec marqueur devant le mode actif
		var mode_to_id = {"free": 0, "skew": 1, "distort": 2, "perspective": 3, "crop": 4, "softcrop": 5, "edgecrop": 6}
		var cur_id = mode_to_id.get(_transform_mode, 0)
		var labels = {0: "Scale", 1: "Skew", 2: "Distort", 3: "Perspective", 4: "Crop", 5: "Soft Crop", 6: "Edge Crop"}
		var has_path = _has_any_path()
		var all_paths = has_path and _all_paths()
		var modes = [0, 1] if all_paths else [0, 1, 2, 3]
		# Crop : props simples uniquement (un seul objet sélectionné)
		if not all_paths and _selected_objects.size() == 1 and _is_plain_prop(_selected_objects[0]):
			modes = [0, 1, 2, 3, 4, 5, 6]
		for mid in modes:
			var prefix = "» " if mid == cur_id else "  "
			menu.add_item(prefix + labels[mid], mid)

		# Symétries (flip immédiat, réversible) — appliquées à toute la
		# sélection d'un bloc autour du centre de la box.
		menu.add_separator()
		menu.add_item("Horizontal Symmetry", 20)
		menu.add_item("Vertical Symmetry", 21)

		# Séparateur + Reset
		menu.add_separator()
		menu.add_item("Reset transform", 10)

	# Séparateur + Close Free Transform
	menu.add_separator()
	menu.add_item("Close Free Transform", 11)

	menu.connect("id_pressed",   self, "_on_transform_menu_id")
	menu.connect("popup_hide",   self, "_on_transform_menu_closed")

	var layer = _popup_layer
	if layer == null or not is_instance_valid(layer):
		layer = CanvasLayer.new()
		layer.name = "FreeTransformPopupLayer"
		layer.layer = 128
		_g.World.get_tree().root.add_child(layer)
		_popup_layer = layer

	layer.add_child(menu)
	_context_menu = menu

	_menu_position = pos
	menu.popup(Rect2(pos, Vector2(1, 1)))


func _record_mode_change(before: Dictionary, after: Dictionary) -> void:
	# Skip no-ops.
	if before.get("transform_mode") == after.get("transform_mode") \
			and before.get("portal_mode") == after.get("portal_mode"):
		return
	var undo_lib = _g.ModMapData.get("_undo_lib")
	if undo_lib == null:
		return
	undo_lib.record_callback(
		self, "_restore_mode", [before],
		self, "_restore_mode", [after])


func _restore_mode(state: Dictionary) -> void:
	if state.has("transform_mode"):
		_transform_mode = state["transform_mode"]
	if state.has("portal_mode"):
		_portal_mode = state["portal_mode"]


func _capture_mode() -> Dictionary:
	return {
		"transform_mode": _transform_mode,
		"portal_mode": _portal_mode,
	}


func _same_selection(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for nd in a:
		if not (nd in b):
			return false
	return true


func _flip_selection(horizontal: bool) -> void:
	# Flip immédiat (miroir) de TOUTE la sélection d'un bloc, autour du centre
	# de la transform box. Réversible : ré-appliquer le même flip annule.
	# - Props / patterns / paths : réflexion du global_transform autour du centre
	#   de la box (miroir monde), persistée dans _ft_transforms.
	# - Portals : flip dans le repère LOCAL (le node est aligné au mur) en
	#   négativant scale.x (H = le long du mur) ou scale.y (V = perpendiculaire),
	#   pour rester collé au mur. abs(scale.x) sert au Radius → taille inchangée.
	# Tout est persisté via _reapply_shear_transforms et annulable (undo unifié).
	var flippable := []
	for nd in _selected_objects:
		if is_instance_valid(nd):
			flippable.append(nd)
	if flippable.empty():
		return
	var box = _selection_aabb()
	if box.size == Vector2.ZERO:
		return
	var center = box.position + box.size * 0.5

	# Capture AVANT : on s'assure que le transform complet courant est dans
	# _ft_transforms pour que l'undo restaure une réflexion proprement (en
	# Godot 3, pos/rot/scale seuls ne représentent pas un déterminant négatif
	# de façon fiable).
	for nd in flippable:
		_snapshot_orig_xform(nd)
		_store_shear_transform(nd, nd.transform)
	var before = _capture_ft_unified(flippable)

	# Réflexion monde autour de l'axe vertical (H) ou horizontal (V) passant
	# par le centre du groupe.
	var R: Transform2D
	if horizontal:
		R = Transform2D(Vector2(-1.0, 0.0), Vector2(0.0, 1.0), Vector2(2.0 * center.x, 0.0))
	else:
		R = Transform2D(Vector2(1.0, 0.0), Vector2(0.0, -1.0), Vector2(0.0, 2.0 * center.y))

	for nd in flippable:
		if not is_instance_valid(nd):
			continue
		if _is_portal(nd):
			# Portal : flip LOCAL (reste collé au mur). H → scale.x, V → scale.y.
			# Le Radius utilise abs(scale.x), donc la taille ne change pas.
			var sc = nd.scale
			if horizontal:
				sc.x = -sc.x
			else:
				sc.y = -sc.y
			nd.scale = sc
		else:
			# Miroir monde : la base reflétée (déterminant négatif) produit le
			# miroir.
			nd.global_transform = R * nd.global_transform
		# Persiste la base ; _reapply_shear_transforms la réappliquera chaque
		# frame même si DD reset le scale.
		_store_shear_transform(nd, nd.transform)

	_save_ft_data()
	_record_ft_unified_change(before, _capture_ft_unified(flippable))
	_save_ft_data()
	print("[FreeTransform] Symmetry %s appliquée" % ("Horizontal" if horizontal else "Vertical"))


func _on_transform_menu_id(id: int) -> void:
	if id == 20 or id == 21:
		_flip_selection(id == 20)
		if _context_menu != null and is_instance_valid(_context_menu):
			_context_menu.queue_free()
		_context_menu = null
		return

	if id == 10:
		_on_reset_scale()
		if _context_menu != null and is_instance_valid(_context_menu):
			_context_menu.queue_free()
		_context_menu = null
		return

	if id == 11:
		# Close Free Transform — désactive le toggle
		if _toggle_btn != null and is_instance_valid(_toggle_btn):
			_toggle_btn.pressed = false
		_on_toggle(false)
		if _context_menu != null and is_instance_valid(_context_menu):
			_context_menu.queue_free()
		_context_menu = null
		return

	if id == 12:
		# Active le mode Offset pour les portals
		var _mode_before = _capture_mode()
		_portal_mode = "offset"
		_record_mode_change(_mode_before, _capture_mode())
		if _context_menu != null and is_instance_valid(_context_menu):
			_context_menu.queue_free()
		_context_menu = null
		return

	if id == 13:
		# Active le mode Slide pour les portals
		var _mode_before2 = _capture_mode()
		_portal_mode = "slide"
		_record_mode_change(_mode_before2, _capture_mode())
		if _context_menu != null and is_instance_valid(_context_menu):
			_context_menu.queue_free()
		_context_menu = null
		return

	# Pour les portals, ID 0 (Scale) active le mode scale
	if id == 0 and _all_portals():
		var _mode_before3 = _capture_mode()
		_portal_mode = "scale"
		_record_mode_change(_mode_before3, _capture_mode())
		if _context_menu != null and is_instance_valid(_context_menu):
			_context_menu.queue_free()
		_context_menu = null
		return

	var id_to_mode = {0: "free", 1: "skew", 2: "distort", 3: "perspective", 4: "crop", 5: "softcrop", 6: "edgecrop"}
	var new_mode = id_to_mode.get(id, "free")

	# Warning si distort/perspective avec des paths dans la sélection
	if new_mode in ["distort", "perspective"] and _has_any_path():
		_pending_mode = new_mode
		# Déconnecte popup_hide de l'ancien menu AVANT de montrer le warning,
		# sinon la fermeture de l'ancien menu tue le nouveau popup.
		if _context_menu != null and is_instance_valid(_context_menu):
			if _context_menu.is_connected("popup_hide", self, "_on_transform_menu_closed"):
				_context_menu.disconnect("popup_hide", self, "_on_transform_menu_closed")
			_context_menu.queue_free()
			_context_menu = null
		_show_path_warning_popup()
		return

	# Crop et Skew/Distort/Perspective sont mutuellement exclusifs : passer de
	# l'un à l'autre EFFACE la modif existante. On prévient l'utilisateur si une
	# modif réelle du type qu'on quitte existe (sinon, aucun warning).
	if _selected_objects.size() == 1 and is_instance_valid(_selected_objects[0]):
		var _nd0 = _selected_objects[0]
		var _to_crop = new_mode in ["crop", "softcrop", "edgecrop"]
		var _to_warp = new_mode in ["skew", "distort", "perspective"]
		if _to_warp and (_crop_is_modified(_nd0) or _has_edgecrop(_nd0)):
			_pending_mode = new_mode
			_dismiss_transform_menu_for_warning()
			_show_crop_warp_warning_popup(true)
			return
		if _to_crop and _has_warp(_nd0):
			_pending_mode = new_mode
			_dismiss_transform_menu_for_warning()
			_show_crop_warp_warning_popup(false)
			return

	_apply_mode_switch(new_mode)

	if _context_menu != null and is_instance_valid(_context_menu):
		_context_menu.queue_free()
	_context_menu = null


func _on_transform_menu_closed() -> void:
	if _context_menu != null and is_instance_valid(_context_menu):
		_context_menu.queue_free()
	_context_menu = null
	# Idem : _free_transform_active est sous la responsabilité de _on_toggle uniquement
