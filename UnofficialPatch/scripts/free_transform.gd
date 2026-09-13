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
# Walls actuellement sélectionnés (cache rafraîchi chaque frame dans
# update() depuis DragSelectWalls). Utilisé par l'overlay (box verte
# englobant les walls) et _selection_aabb sans re-scanner RawSelectables
# à chaque appel.
var _walls_in_selection : Array = []
# Lights actuellement sélectionnées (cache rafraîchi chaque frame dans
# update() depuis RawSelectables). Utilisé par l'overlay (box verte les
# englobant), _selection_aabb et la visibilité du groupe de boutons FT.
var _lights_in_selection : Array = []
# Drag de groupe lights-only via la box verte FT (DD déplace sa sélection
# via sa transform box, qu'on cache justement en lights-only — FT fournit
# donc son propre move, comme IDX_MOVE pour les props). Undo unifié.
var _light_drag_active := false
var _light_drag_start := Vector2.ZERO
var _light_drag_nodes := []
var _light_drag_origins := []
var _light_drag_before := {}
# État du drag de walls via les handles FT (move / rotate / scale, comme
# la custom box de DragSelectWalls). Snapshots pris au début du drag,
# transformation affine appliquée chaque frame via l'API de DSW.
var _wall_drag_active := false
var _wall_drag_walls := []
var _wall_drag_snaps := {}
var _wall_drag_before := []
# Coins source (AABB monde des Points au début du drag) par wall — quad de
# référence pour le warp skew/distort/perspective.
var _wall_drag_corners := {}
# Largeur variable : profil pré-drag {wall: entry|null}, fractions d'arc
# des points de chaque Line2D enfant {wall: {child: [fr]}} calculées une
# fois au début du drag, et dernier quad destination appliqué {wall: nc}
# (sert au commit pour figer le profil final).
var _wall_drag_wprofile := {}
# Points ORIGINAUX décimés par enfant {wall: {child: [pts]}} : après un
# premier warp les lignes visuelles sont denses (≤384 pts) et les warper
# par frame coûte des milliers d'inversions bilinéaires → on drague sur
# une version décimée (~64 pts), la pleine qualité est reconstruite au
# commit (RemakeLines + rebuild).
var _wall_drag_childpts := {}
var _wall_drag_childfr := {}
var _wall_drag_lastnc := {}
# Signatures de réapplication des largeurs par point {key: [n, w]}
var _width_applied_sig := {}
# Rotation accumulée à la molette pendant un drag IDX_MOVE de walls
# (walls-only). Appliquée autour du centre courant de la sélection.
var _wall_wheel_rot := 0.0

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
# World.nextNodeID when the lock was (re)taken: any selected node with an id
# at or above it was created afterwards (paste, duplicate) — DD selected it
# on purpose, so the lock follows instead of fighting it.
var _ft_lock_next_id := -1
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
# Cache des shaders fusionnés (compat CMT) : hash du code source -> Shader
# compilé. CMT crée un NOUVEAU ShaderMaterial à chaque changement de réglage,
# mais le Shader sous-jacent est partagé — sans cache on recompilerait le
# shader fusionné à chaque tick de slider.
var _ft_merged_shader_cache : Dictionary = {}

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
# ── Prompt de confirmation : changement de texture externe (mod tiers) ───────
# Quand un mod tiers (ex. ChangeObjectTexture via SetTexture) remplace la texture
# d'un prop qui porte un crop / edge crop, on demande à l'utilisateur :
#   OK     = reset du crop, on garde la nouvelle texture
#   Cancel = on annule le changement de texture (la texture/crop d'origine revient)
var _tex_swap_dialog = null
var _tex_swap_keys : Array = []   # keys de props en attente de décision
var _tex_swap_confirmed := false
var _tex_swap_resolving := false
var _tex_swap_new : Dictionary = {}   # key -> {texture,region_enabled,region_rect} (nouvelle texture mémorisée)
var _ft_geo_tex_ref : Dictionary = {}   # key distort -> {texture,size,region_enabled,region_rect} (réf. pré-swap)
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

# ── Blur (Gaussian + motion) ─────────────────────────────────────────────────
# Props only. Lives in the FT ShaderMaterial of the Sprite (the same material
# as the warp) — see FT_BLUR_HEADER / _ft_inject_blur. Stored per node in
# ModMapData["_ft_blur"] = { key -> {r: float, m: float, a: float} }.
#   r : Gaussian radius (texture px)
#   m : motion blur length (texture px)
#   a : motion angle (degrees, world/screen space, 0 = right, 90 = down)
# A zero entry (r == 0 and m == 0) is never stored: no entry = no blur.
const BLUR_RADIUS_MAX := 32.0
const BLUR_MOTION_MAX := 256.0
const BLUR_STEP := 0.5
const FT_BLUR_TEX_PAD := 192         # transparent padding (px) of the premultiplied copy: >= r + m/2 + 2 sigma
var _blur_r_row     : Control = null
var _blur_r_slider  : HSlider = null
var _blur_r_spin    : SpinBox = null
# Motion blur: circular dial (same widget as Soft Shadows' projected mode):
# handle direction = motion direction (screen angle, 0 = right, 90 = down),
# handle radius (non-linear, BLUR_DIAL_EXP) = motion length. Corner snap
# buttons lock the angle; the spins mirror the dial.
const BLUR_DIAL_EXP := 2.0
var _blur_m_row     : Control = null   # header (spins) + dial
var _blur_m_spin    : SpinBox = null
var _blur_a_spin    : SpinBox = null
var _blur_dial      : Control = null
var _blur_snap_btns : Dictionary = {}  # key -> TextureButton
var _blur_tools_row : Control = null
var _blur_copy_btn  : Button = null
var _blur_paste_btn : Button = null
var _blur_syncing   := false
var _blur_before    : Dictionary = {}   # unified snapshot at the start of a slider burst
var _blur_before_node : Node2D = null
var _blur_dirty_ms  := 0
var _blur_clip      : Dictionary = {}   # session clipboard for Copy / Paste
# Premultiplied + mipmapped copies of the sampled textures, keyed by the
# source texture's instance id: { id -> {src: WeakRef, tex: ImageTexture} }.
# Shared DD asset textures -> one copy per asset, whatever the prop count.
var _ft_blur_tex_cache : Dictionary = {}

# ── Shader warp (distort / perspective / skew coins) ─────────────────────
# Warp bilinéaire inverse : 4 coins totalement indépendants.
# Deux variantes : avec et sans custom color (tint_r).

# NOTE numérique (tous les shaders warp ci-dessous) : l'inversion
# bilinéaire résout un polynôme quadratique. En float32 GPU, avec des
# coins à l'échelle monde et un quad quasi-parallélogramme (cas typique
# après skew puis scale : g = a-b+c-d minuscule mais non nul), la forme
# naïve (-k1±sq)/(2 k2) subit une annulation catastrophique (k1² ~ 1e10,
# 7 chiffres significatifs) → (u,v) bruités → texture en rayures denses
# et bandes noires. Correctif : (1) normalisation des coordonnées
# (centrées/réduites, invariant pour les coordonnées bilinéaires),
# (2) forme quadratique stable q = -(k1 + signe(k1)·sq)/2, v = q/k2 ou
# k0/q. Vérifié par simulation float32 : erreur 0.53 → 0.0.
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
\tvec2 nrm_ctr=(a+b+c+d)*0.25;
\tfloat nrm_s=max(max(length(b-a),length(d-a)),1e-3);
\ta=(a-nrm_ctr)/nrm_s;b=(b-nrm_ctr)/nrm_s;c=(c-nrm_ctr)/nrm_s;d=(d-nrm_ctr)/nrm_s;p=(p-nrm_ctr)/nrm_s;
\tvec2 e=b-a,f=d-a,g=a-b+c-d,h=p-a;
\tfloat k2=cr(g,f),k1=cr(e,f)+cr(h,g),k0=cr(h,e);
\tfloat v;
\tif(abs(k2)<1e-5){v=-k0/k1;}
\telse{
\t\tfloat sq=sqrt(max(k1*k1-4.0*k0*k2,0.0));
\t\tfloat qq=-0.5*(k1+(k1>=0.0?sq:-sq));
\t\tfloat v1=qq/k2;
\t\tfloat v2=abs(qq)>1e-12?k0/qq:v1;
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
\tvec2 nrm_ctr=(a+b+c+d)*0.25;
\tfloat nrm_s=max(max(length(b-a),length(d-a)),1e-3);
\ta=(a-nrm_ctr)/nrm_s;b=(b-nrm_ctr)/nrm_s;c=(c-nrm_ctr)/nrm_s;d=(d-nrm_ctr)/nrm_s;p=(p-nrm_ctr)/nrm_s;
\tvec2 e=b-a,f=d-a,g=a-b+c-d,h=p-a;
\tfloat k2=cr(g,f),k1=cr(e,f)+cr(h,g),k0=cr(h,e);
\tfloat v;
\tif(abs(k2)<1e-5){v=-k0/k1;}
\telse{
\t\tfloat sq=sqrt(max(k1*k1-4.0*k0*k2,0.0));
\t\tfloat qq=-0.5*(k1+(k1>=0.0?sq:-sq));
\t\tfloat v1=qq/k2;
\t\tfloat v2=abs(qq)>1e-12?k0/qq:v1;
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


# ── Fusion warp <-> shaders étrangers (compat Colour and Modify Things) ─────
# Quand le sprite porte déjà un ShaderMaterial de CMT (universalshader ou
# colorable_hsl), remplacer le material tuerait les réglages couleur/HSL.
# On injecte donc le warp bilinéaire DANS le code du shader étranger :
#   1. uniforms/varying/fonctions ci-dessous (tout est préfixé ft_ pour
#      éviter les collisions de noms),
#   2. VERTEX warpé en tête de vertex() (créé s'il n'existe pas),
#   3. dans fragment(), chaque lecture de UV est remplacée par l'UV warpé
#      (calculé une seule fois en tête de fonction).
# Mêmes maths que DISTORT_SHADER_SRC.
const FT_WARP_MERGE_HEADER = """uniform vec2 ft_corner_tl;
uniform vec2 ft_corner_tr;
uniform vec2 ft_corner_br;
uniform vec2 ft_corner_bl;
uniform vec2 ft_uv_min = vec2(0.0,0.0);
uniform vec2 ft_uv_max = vec2(1.0,1.0);
varying vec2 ft_v_local;
float ft_cr(vec2 a,vec2 b){return a.x*b.y-a.y*b.x;}
vec2 ft_warp_uv(vec2 p){
\tvec2 a=ft_corner_tl,b=ft_corner_tr,c=ft_corner_br,d=ft_corner_bl;
\tvec2 nrm_ctr=(a+b+c+d)*0.25;
\tfloat nrm_s=max(max(length(b-a),length(d-a)),1e-3);
\ta=(a-nrm_ctr)/nrm_s;b=(b-nrm_ctr)/nrm_s;c=(c-nrm_ctr)/nrm_s;d=(d-nrm_ctr)/nrm_s;p=(p-nrm_ctr)/nrm_s;
\tvec2 e=b-a,f=d-a,g=a-b+c-d,h=p-a;
\tfloat k2=ft_cr(g,f),k1=ft_cr(e,f)+ft_cr(h,g),k0=ft_cr(h,e);
\tfloat v;
\tif(abs(k2)<1e-5){v=-k0/k1;}
\telse{
\t\tfloat sq=sqrt(max(k1*k1-4.0*k0*k2,0.0));
\t\tfloat qq=-0.5*(k1+(k1>=0.0?sq:-sq));
\t\tfloat v1=qq/k2;
\t\tfloat v2=abs(qq)>1e-12?k0/qq:v1;
\t\tv=(v1>=-0.001&&v1<=1.001)?v1:v2;
\t}
\tvec2 den=e+g*v;
\tfloat u=abs(den.x)>abs(den.y)?(h.x-f.x*v)/den.x:(h.y-f.y*v)/den.y;
\treturn ft_uv_min+clamp(vec2(u,v),0.0,1.0)*(ft_uv_max-ft_uv_min);
}
"""

const FT_WARP_MERGE_VERTEX_BODY = """
\tvec2 ft_t=(UV-ft_uv_min)/max(ft_uv_max-ft_uv_min,vec2(0.0001));
\tVERTEX=mix(mix(ft_corner_tl,ft_corner_tr,ft_t.x),mix(ft_corner_bl,ft_corner_br,ft_t.x),ft_t.y);
\tft_v_local=VERTEX;
"""

const FT_WARP_MERGE_VERTEX_FN = "void vertex(){" + FT_WARP_MERGE_VERTEX_BODY + "}\n"


# ── Blur (Gaussian + motion) : injected into ANY FT shader ────────────────────
# The blur lives in the FT material of the Sprite (the same one as the warp),
# so it composes with distort / custom color / CMT merge / the vanilla shadow.
# _ft_inject_blur rewrites a shader source:
#   1. FT_BLUR_HEADER (uniforms + ft_blur_* functions) goes before vertex(),
#   2. vertex(): the quad is grown by ft_blur_margin around its centre so the
#      halo can spill outside the Sprite rect,
#   3. warp_uv(): the [0,1] clamp is dropped (outside the quad -> uv outside
#      [uv_min, uv_max]),
#   4. every texture(TEXTURE, uv) of fragment() becomes ft_blur_sample(...),
#      which returns transparent for any tap outside [uv_min, uv_max].
# Sampling is done in PREMULTIPLIED alpha from ft_blur_tex: a premultiplied
# + mipmapped copy of the sprite texture built on the CPU (see
# _ft_blur_get_premul_texture). Without it, mip levels of a straight-alpha
# texture average colour with transparent black and the halo turns dark /
# dirty. TEXTURE itself is left untouched (DD's asset lookup relies on it).
# The copy is padded with FT_BLUR_TEX_PAD transparent px on every side so
# taps near the texture border read real transparency instead of the
# clamped border column (no streaks); ft_blur_uvmap maps TEXTURE uvs onto
# the padded copy. Gaussian: grid over +-r (up to 15x15), sigma = r/2.
# Motion: up to 21 taps along ft_blur_dir over +-(m/2 + 2 sigma) with a
# softened box profile (~ box convolved with the Gaussian), up to 11
# across. Tap spacing = an exact power of two = the texel size of the mip
# level read (integer lod, no trilinear mix): the bilinear tents of
# neighbouring taps then sum to a perfectly flat response, so no ripple /
# moire shows through, whatever the radius. When no copy could
# be built (ft_blur_has_tex = 0) the shader falls back to TEXTURE and
# premultiplies per tap (lower quality). {P} = uv_min / uv_max prefix.
const FT_BLUR_HEADER = """uniform float ft_blur_radius = 0.0;
uniform float ft_blur_motion = 0.0;
uniform vec2 ft_blur_dir = vec2(1.0,0.0);
uniform vec2 ft_blur_margin = vec2(0.0,0.0);
uniform float ft_blur_lod_max = 0.0;
uniform sampler2D ft_blur_tex;
uniform float ft_blur_has_tex = 0.0;
uniform vec4 ft_blur_uvmap = vec4(1.0,1.0,0.0,0.0);
uniform vec2 ft_blur_pad_uv = vec2(0.0,0.0);
bool ft_blur_out(vec2 uv){
\treturn uv.x<{P}uv_min.x-ft_blur_pad_uv.x||uv.y<{P}uv_min.y-ft_blur_pad_uv.y||uv.x>{P}uv_max.x+ft_blur_pad_uv.x||uv.y>{P}uv_max.y+ft_blur_pad_uv.y;
}
vec4 ft_blur_tap(sampler2D tex,vec2 uv,float lod){
\tif(ft_blur_out(uv)) return vec4(0.0);
\tif(ft_blur_has_tex>0.5) return textureLod(ft_blur_tex,uv*ft_blur_uvmap.xy+ft_blur_uvmap.zw,lod);
\tvec4 c=textureLod(tex,uv,lod);
\treturn vec4(c.rgb*c.a,c.a);
}
vec4 ft_blur_sample(sampler2D tex,vec2 ps,vec2 uv){
\tfloat r=ft_blur_radius;
\tfloat m=ft_blur_motion;
\tif(r<0.05&&m<0.05){
\t\tif(uv.x<{P}uv_min.x||uv.y<{P}uv_min.y||uv.x>{P}uv_max.x||uv.y>{P}uv_max.y) return vec4(0.0);
\t\treturn textureLod(tex,uv,0.0);
\t}
\tvec2 ax=ft_blur_dir;
\tvec2 ay=vec2(-ax.y,ax.x);
\tfloat sig=max(r*0.5,0.35);
\tfloat s2=2.0*sig*sig;
\tvec4 acc=vec4(0.0);
\tfloat ws=0.0;
\tif(m<0.05){
\t\tfloat sp=exp2(ceil(log2(max(r/7.0,1.0))));
\t\tfloat lod=clamp(log2(sp),0.0,ft_blur_lod_max);
\t\tint n=int(min(ceil(r/sp),7.0));
\t\tfor(int i=-7;i<=7;i++){
\t\t\tif(i<-n||i>n) continue;
\t\t\tfor(int j=-7;j<=7;j++){
\t\t\t\tif(j<-n||j>n) continue;
\t\t\t\tvec2 o=vec2(float(i),float(j))*sp;
\t\t\t\tfloat w=exp(-dot(o,o)/s2);
\t\t\t\tacc+=ft_blur_tap(tex,uv+o*ps,lod)*w;
\t\t\t\tws+=w;
\t\t\t}
\t\t}
\t}else{
\t\tfloat hm=m*0.5;
\t\tfloat ea=hm+2.0*sig;
\t\tfloat sp=exp2(ceil(log2(max(max(ea/10.0,r/5.0),1.0))));
\t\tfloat lod=clamp(log2(sp),0.0,ft_blur_lod_max);
\t\tint na=int(min(ceil(ea/sp),10.0));
\t\tint nc=int(min(ceil(r/sp),5.0));
\t\tfor(int i=-10;i<=10;i++){
\t\t\tif(i<-na||i>na) continue;
\t\t\tfloat x=float(i)*sp;
\t\t\tfloat wa=smoothstep(-hm-2.0*sig,-hm+2.0*sig,x)*(1.0-smoothstep(hm-2.0*sig,hm+2.0*sig,x));
\t\t\tfor(int j=-5;j<=5;j++){
\t\t\t\tif(j<-nc||j>nc) continue;
\t\t\t\tfloat y=float(j)*sp;
\t\t\t\tfloat w=wa*exp(-y*y/s2);
\t\t\t\tacc+=ft_blur_tap(tex,uv+(ax*x+ay*y)*ps,lod)*w;
\t\t\t\tws+=w;
\t\t\t}
\t\t}
\t}
\tif(ws<=0.0||acc.a<=0.0) return vec4(0.0);
\treturn vec4(acc.rgb/acc.a,acc.a/ws);
}
"""


# ── Blur for TILED samplers (patterns, walls, paths) ─────────────────────────
# Same kernels as FT_BLUR_HEADER but for a repeating texture sampled in its
# own uv space (pattern albedo, wall albedo, Line2D TEXTURE): no quad growth,
# no padding, taps wrap with the sampler. Coarse mip levels are reconstructed
# with a cubic B-spline (4 bilinear fetches) so no texel grid shows through.
# {S} is a suffix so a shader can carry two independent instances (wall:
# albedo = "", line texture = "2"). ft_blur_px_scale{S} = texels per world
# px; ft_blur_vclamp{S} = v range outside which taps are transparent (Line2D:
# 0..1, so the edges of a path / wall fade instead of smearing).
const FT_BLUR_TILE_HEADER = """uniform float ft_blur_radius{S} = 0.0;
uniform float ft_blur_motion{S} = 0.0;
uniform vec2 ft_blur_dir{S} = vec2(1.0,0.0);
uniform float ft_blur_px_scale{S} = 1.0;
uniform vec2 ft_blur_vclamp{S} = vec2(-1.0e9,1.0e9);
uniform sampler2D ft_blur_tex{S};
uniform float ft_blur_has_tex{S} = 0.0;
uniform float ft_blur_lod_max{S} = 0.0;
vec4 ft_blur_cubic{S}(sampler2D tex,vec2 uv,float lod){
\tvec2 ts=max(vec2(textureSize(tex,0))/exp2(lod),vec2(1.0));
\tvec2 tc=uv*ts-0.5;
\tvec2 f=fract(tc);
\ttc-=f;
\tvec2 f2=f*f;
\tvec2 f3=f2*f;
\tvec2 w0=(1.0-3.0*f+3.0*f2-f3)/6.0;
\tvec2 w1=(4.0-6.0*f2+3.0*f3)/6.0;
\tvec2 w2=(1.0+3.0*f+3.0*f2-3.0*f3)/6.0;
\tvec2 w3=f3/6.0;
\tvec2 s0=w0+w1;
\tvec2 s1=w2+w3;
\tvec2 t0=(tc-1.0+w1/s0+0.5)/ts;
\tvec2 t1=(tc+1.0+w3/s1+0.5)/ts;
\treturn (textureLod(tex,vec2(t0.x,t0.y),lod)*s0.x+textureLod(tex,vec2(t1.x,t0.y),lod)*s1.x)*s0.y+(textureLod(tex,vec2(t0.x,t1.y),lod)*s0.x+textureLod(tex,vec2(t1.x,t1.y),lod)*s1.x)*s1.y;
}
vec4 ft_blur_tile_tap{S}(sampler2D tex,vec2 uv,float lod){
\tif(uv.y<ft_blur_vclamp{S}.x||uv.y>ft_blur_vclamp{S}.y) return vec4(0.0);
\tvec4 c;
\tif(ft_blur_has_tex{S}>0.5){
\t\tc=(lod>0.5)?ft_blur_cubic{S}(ft_blur_tex{S},uv,lod):textureLod(ft_blur_tex{S},uv,0.0);
\t\treturn c;
\t}
\tc=(lod>0.5)?ft_blur_cubic{S}(tex,uv,lod):textureLod(tex,uv,0.0);
\treturn vec4(c.rgb*c.a,c.a);
}
vec4 ft_blur_tile{S}(sampler2D tex,vec2 uv){
\tfloat r=ft_blur_radius{S}*ft_blur_px_scale{S};
\tfloat m=ft_blur_motion{S}*ft_blur_px_scale{S};
\tif(r<0.05&&m<0.05) return texture(tex,uv);
\tvec2 ps=1.0/vec2(textureSize(tex,0));
\tvec2 ax=ft_blur_dir{S};
\tvec2 ay=vec2(-ax.y,ax.x);
\tfloat sig=max(r*0.5,0.35);
\tfloat s2=2.0*sig*sig;
\tvec4 acc=vec4(0.0);
\tfloat ws=0.0;
\tif(m<0.05){
\t\tfloat sp=exp2(ceil(log2(max(r/7.0,1.0))));
\t\tfloat lod=clamp(log2(sp),0.0,ft_blur_lod_max{S});
\t\tint n=int(min(ceil(r/sp),7.0));
\t\tfor(int i=-7;i<=7;i++){
\t\t\tif(i<-n||i>n) continue;
\t\t\tfor(int j=-7;j<=7;j++){
\t\t\t\tif(j<-n||j>n) continue;
\t\t\t\tvec2 o=vec2(float(i),float(j))*sp;
\t\t\t\tfloat w=exp(-dot(o,o)/s2);
\t\t\t\tacc+=ft_blur_tile_tap{S}(tex,uv+o*ps,lod)*w;
\t\t\t\tws+=w;
\t\t\t}
\t\t}
\t}else{
\t\tfloat hm=m*0.5;
\t\tfloat ea=hm+2.0*sig;
\t\tfloat sp=exp2(ceil(log2(max(max(ea/10.0,r/5.0),1.0))));
\t\tfloat lod=clamp(log2(sp),0.0,ft_blur_lod_max{S});
\t\tint na=int(min(ceil(ea/sp),10.0));
\t\tint nc=int(min(ceil(r/sp),5.0));
\t\tfor(int i=-10;i<=10;i++){
\t\t\tif(i<-na||i>na) continue;
\t\t\tfloat x=float(i)*sp;
\t\t\tfloat wa=smoothstep(-hm-2.0*sig,-hm+2.0*sig,x)*(1.0-smoothstep(hm-2.0*sig,hm+2.0*sig,x));
\t\t\tfor(int j=-5;j<=5;j++){
\t\t\t\tif(j<-nc||j>nc) continue;
\t\t\t\tfloat y=float(j)*sp;
\t\t\t\tfloat w=wa*exp(-y*y/s2);
\t\t\t\tacc+=ft_blur_tile_tap{S}(tex,uv+(ax*x+ay*y)*ps,lod)*w;
\t\t\t\tws+=w;
\t\t\t}
\t\t}
\t}
\tif(ws<=0.0||acc.a<=0.0) return vec4(0.0);
\treturn vec4(acc.rgb/acc.a,acc.a/ws);
}
"""

# Plain Line2D (paths have no material): the default canvas shader with the
# blurred TEXTURE read.
const FT_BLUR_LINE_SHADER_SRC = "shader_type canvas_item;\n{H}\nvoid fragment(){\n\tCOLOR*=ft_blur_tile2(TEXTURE,UV);\n}\n"


func _ft_inject_tile_blur(code: String, sampler_names: Array, suffixes = null) -> String:
	# Rewrites a shader so the given samplers are read through the tiled
	# blur. sampler_names[i] uses instance suffix suffixes[i] (default: ""
	# for the first, "2" for the second). Returns "" when the structure is
	# not recognised.
	var vp = code.find("void vertex")
	var fp = code.find("void fragment")
	if fp < 0:
		return ""
	var header = ""
	for i in range(sampler_names.size()):
		var sfx = (suffixes[i] if suffixes is Array and i < suffixes.size() else ("" if i == 0 else "2"))
		var rx = RegEx.new()
		if rx.compile("\\btexture\\s*\\(\\s*" + sampler_names[i] + "\\s*,") != OK:
			return ""
		code = rx.sub(code, "ft_blur_tile" + sfx + "(" + sampler_names[i] + ",", true)
		header += FT_BLUR_TILE_HEADER.replace("{S}", sfx) + "\n"
	vp = code.find("void vertex")
	fp = code.find("void fragment")
	var ins = fp if (vp < 0 or fp < vp) else vp
	return code.insert(ins, header)


func _ft_inject_blur(code: String, pfx: String) -> String:
	# Rewrites an FT shader source to carry the blur (see FT_BLUR_HEADER).
	# pfx = "" for FT's own shaders, "ft_" for a merged (CMT) shader.
	# Returns "" when the expected structure is not found.
	var vp = code.find("void vertex")
	var fp = code.find("void fragment")
	if fp < 0:
		return ""
	# 3. warp_uv: no clamp any more (the halo spills outside the quad).
	code = code.replace("clamp(vec2(u,v),0.0,1.0)", "vec2(u,v)")
	# Outside the quad both roots can fall outside [0,1]: pick the one closest
	# to the quad instead of the in-range test (which would flip branches).
	code = code.replace("v=(v1>=-0.001&&v1<=1.001)?v1:v2;", "v=abs(v1-0.5)<=abs(v2-0.5)?v1:v2;")
	# 2. Grow the quad in vertex(), right before v_local is captured (t is
	# the 0..1 quad coordinate computed by the warp vertex body).
	var anchor = "\t" + pfx + "v_local=VERTEX;"
	if code.find(anchor) < 0:
		return ""
	code = code.replace(anchor, "\tVERTEX+=(" + pfx + "t-0.5)*2.0*ft_blur_margin;\n" + anchor)
	# 4. TEXTURE reads -> ft_blur_sample. TEXTURE_PIXEL_SIZE is passed as an
	# argument: shader builtins are not visible inside custom functions.
	var rx = RegEx.new()
	if rx.compile("\\btexture\\s*\\(\\s*TEXTURE\\s*,") != OK:
		return ""
	code = rx.sub(code, "ft_blur_sample(TEXTURE,TEXTURE_PIXEL_SIZE,", true)
	# 1. Header before the first main function (ft_blur_margin is read by
	# vertex(); uv_min / uv_max are declared at the very top by the warp).
	vp = code.find("void vertex")
	fp = code.find("void fragment")
	var ins = fp if (vp < 0 or fp < vp) else vp
	code = code.insert(ins, FT_BLUR_HEADER.replace("{P}", pfx) + "\n")
	return code


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
\tvec2 nrm_ctr=(a+b+c+d)*0.25;
\tfloat nrm_s=max(max(length(b-a),length(d-a)),1e-3);
\ta=(a-nrm_ctr)/nrm_s;b=(b-nrm_ctr)/nrm_s;c=(c-nrm_ctr)/nrm_s;d=(d-nrm_ctr)/nrm_s;p=(p-nrm_ctr)/nrm_s;
\tvec2 e=b-a,f=d-a,g=a-b+c-d,h=p-a;
\tfloat k2=cr(g,f),k1=cr(e,f)+cr(h,g),k0=cr(h,e);
\tfloat v;
\tif(abs(k2)<1e-5){v=-k0/k1;}
\telse{
\t\tfloat sq=sqrt(max(k1*k1-4.0*k0*k2,0.0));
\t\tfloat qq=-0.5*(k1+(k1>=0.0?sq:-sq));
\t\tfloat v1=qq/k2;
\t\tfloat v2=abs(qq)>1e-12?k0/qq:v1;
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
\tvec2 nrm_ctr=(a+b+c+d)*0.25;
\tfloat nrm_s=max(max(length(b-a),length(d-a)),1e-3);
\ta=(a-nrm_ctr)/nrm_s;b=(b-nrm_ctr)/nrm_s;c=(c-nrm_ctr)/nrm_s;d=(d-nrm_ctr)/nrm_s;p=(p-nrm_ctr)/nrm_s;
\tvec2 e=b-a,f=d-a,g=a-b+c-d,h=p-a;
\tfloat k2=cr(g,f),k1=cr(e,f)+cr(h,g),k0=cr(h,e);
\tfloat v;
\tif(abs(k2)<1e-5){v=-k0/k1;}
\telse{
\t\tfloat sq=sqrt(max(k1*k1-4.0*k0*k2,0.0));
\t\tfloat qq=-0.5*(k1+(k1>=0.0?sq:-sq));
\t\tfloat v1=qq/k2;
\t\tfloat v2=abs(qq)>1e-12?k0/qq:v1;
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
	print("[FreeTransform] Initialisation [BUILD: CMT-DISABLE-HEAL-1]")
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
	# Cross-session guard: this node lives on the tree root, which persists
	# across map reloads. Free the previous instance's node before creating
	# ours -- otherwise one leaks on every reload.
	if Engine.has_meta("up_ft_popup_layer"):
		var _old_n = Engine.get_meta("up_ft_popup_layer")
		if is_instance_valid(_old_n):
			_old_n.set("handler", null)
			_old_n.queue_free()
	var pl = CanvasLayer.new()
	pl.name = "FreeTransformPopupLayer"
	Engine.set_meta("up_ft_popup_layer", pl)
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
	"_ft_distort", "_ft_crop", "_ft_crop_soft", "_ft_crop_feather", "_ft_crop_opacity", "_ft_edgecrop", "_ft_blur", "_ft_transforms",
	"_ft_pattern_orig", "_ft_pattern_orig_pos", "_ft_pattern_reset", "_ft_pattern_world",
	"_portal_offsets", "_ft_orig_xform", "_ft_width_warp", "_ft_wall_reset",
	"_ft_path_reset",
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

	# Widget "Blur": three rows (Gaussian radius, motion length, motion angle)
	# + a Copy / Paste tools row. Visible only in blur mode.
	var br = _make_blur_row(align, "Blur (px)", BLUR_RADIUS_MAX, BLUR_STEP, "px",
		"_on_blur_r_changed", "r", "Reset blur", group.get_index() + 1)
	_blur_r_row = br["row"]; _blur_r_slider = br["slider"]; _blur_r_spin = br["spin"]
	_blur_m_row = _make_blur_motion_widget(align, group.get_index() + 2)

	var bt = VBoxContainer.new()
	bt.name = "FreeTransformBlurTools"
	bt.focus_mode = Control.FOCUS_NONE
	var btr = HBoxContainer.new()
	btr.focus_mode = Control.FOCUS_NONE
	var bcbtn = Button.new()
	bcbtn.text = "Copy"
	bcbtn.hint_tooltip = "Copy this asset's blur settings"
	bcbtn.focus_mode = Control.FOCUS_NONE
	bcbtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bcbtn.connect("pressed", self, "_on_blur_copy_pressed")
	var bpbtn = Button.new()
	bpbtn.text = "Paste"
	bpbtn.hint_tooltip = "Paste copied blur settings onto this asset"
	bpbtn.focus_mode = Control.FOCUS_NONE
	bpbtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bpbtn.connect("pressed", self, "_on_blur_paste_pressed")
	btr.add_child(bcbtn)
	btr.add_child(bpbtn)
	bt.add_child(btr)
	align.add_child(bt)
	align.move_child(bt, group.get_index() + 3)
	bt.visible = false
	_blur_tools_row = bt
	_blur_copy_btn  = bcbtn
	_blur_paste_btn = bpbtn

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
	if not visible:
		for brow in [_blur_r_row, _blur_m_row, _blur_tools_row]:
			if brow != null and is_instance_valid(brow):
				brow.visible = false
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


# Builds one "label / slider + spinbox + reset" row for the blur widget.
func _make_blur_row(align: Node, title: String, maxv: float, step: float, suffix: String,
		cb: String, which: String, reset_tip: String, index: int) -> Dictionary:
	var box = VBoxContainer.new()
	box.name = "FreeTransformBlur_" + which
	box.focus_mode = Control.FOCUS_NONE
	var lbl = Label.new()
	lbl.text = title
	lbl.focus_mode = Control.FOCUS_NONE
	var row = HBoxContainer.new()
	row.focus_mode = Control.FOCUS_NONE
	var sld = HSlider.new()
	sld.min_value = 0
	sld.max_value = maxv
	sld.step = step
	sld.value = 0
	sld.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sld.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sld.focus_mode = Control.FOCUS_NONE
	sld.rect_min_size = Vector2(110, 0)
	var spin = SpinBox.new()
	spin.min_value = 0
	spin.max_value = maxv
	spin.step = step
	spin.value = 0
	spin.suffix = suffix
	spin.focus_mode = Control.FOCUS_CLICK
	var rst = _make_reset_button(reset_tip)
	rst.connect("pressed", self, "_on_blur_reset_pressed", [which])
	row.add_child(sld)
	row.add_child(spin)
	row.add_child(rst)
	box.add_child(lbl)
	box.add_child(row)
	align.add_child(box)
	align.move_child(box, index)
	box.visible = false
	sld.connect("value_changed", self, cb)
	spin.connect("value_changed", self, cb)
	return {"row": box, "slider": sld, "spin": spin}


# Motion blur widget: header [Length spin + reset | Angle spin + reset] then
# the dial. Same look and behaviour as the Soft Shadows projected-shadow dial.
func _make_blur_motion_widget(align: Node, index: int) -> Control:
	var box = VBoxContainer.new()
	box.name = "FreeTransformBlurMotion"
	box.focus_mode = Control.FOCUS_NONE
	var title = Label.new()
	title.text = "Motion Blur"
	title.focus_mode = Control.FOCUS_NONE
	box.add_child(title)

	var header = HBoxContainer.new()
	header.focus_mode = Control.FOCUS_NONE
	var mlbl = Label.new()
	mlbl.text = "Length"
	mlbl.focus_mode = Control.FOCUS_NONE
	header.add_child(mlbl)
	var mspin = SpinBox.new()
	mspin.min_value = 0
	mspin.max_value = BLUR_MOTION_MAX
	mspin.step = BLUR_STEP
	mspin.value = 0
	mspin.suffix = "px"
	mspin.focus_mode = Control.FOCUS_CLICK
	mspin.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	mspin.rect_min_size.x = 72
	mspin.connect("value_changed", self, "_on_blur_m_changed")
	header.add_child(mspin)
	var mrst = _make_reset_button("Reset motion length")
	mrst.connect("pressed", self, "_on_blur_reset_pressed", ["m"])
	header.add_child(mrst)
	var albl = Label.new()
	albl.text = "Angle"
	albl.focus_mode = Control.FOCUS_NONE
	header.add_child(albl)
	var aspin = SpinBox.new()
	aspin.min_value = 0
	aspin.max_value = 359
	aspin.step = 1
	aspin.value = 0
	aspin.suffix = "°"
	aspin.allow_greater = false
	aspin.allow_lesser = false
	aspin.focus_mode = Control.FOCUS_CLICK
	aspin.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	aspin.rect_min_size.x = 60
	aspin.connect("value_changed", self, "_on_blur_a_changed")
	header.add_child(aspin)
	var arst = _make_reset_button("Reset motion angle")
	arst.connect("pressed", self, "_on_blur_reset_pressed", ["a"])
	header.add_child(arst)
	box.add_child(header)

	var dial_container = CenterContainer.new()
	dial_container.rect_clip_content = false
	var dial_margin = MarginContainer.new()
	dial_margin.rect_clip_content = false
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		dial_margin.add_constant_override(side, 8)
	var dial = _make_blur_dial(90)
	dial_margin.add_child(dial)
	dial_container.add_child(dial_margin)
	box.add_child(dial_container)

	align.add_child(box)
	align.move_child(box, index)
	box.visible = false
	_blur_m_spin = mspin
	_blur_a_spin = aspin
	_blur_dial = dial
	return box


func _make_blur_dial(dial_size: int) -> Control:
	# Concentric rings, diagonal guides, crosshair, handle and four corner
	# snap buttons (angle locks). Handle = motion direction, radius = length.
	var dial = Control.new()
	dial.name = "BlurDial"
	dial.rect_min_size = Vector2(dial_size, dial_size)
	dial.rect_size = Vector2(dial_size, dial_size)
	dial.focus_mode = Control.FOCUS_NONE

	var bg_sprite = TextureRect.new()
	bg_sprite.texture = _ft_make_circle_texture(dial_size, Color(0.12, 0.12, 0.12, 1.0))
	bg_sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(bg_sprite)

	for ring_frac in [0.25, 0.5, 0.75]:
		var ring_size = int(dial_size * ring_frac)
		var ring_rect = TextureRect.new()
		ring_rect.texture = _ft_make_ring_texture(ring_size, Color(0.22, 0.22, 0.22, 1.0))
		ring_rect.rect_position = Vector2((dial_size - ring_size) / 2.0, (dial_size - ring_size) / 2.0)
		ring_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		dial.add_child(ring_rect)

	for diag_angle in [45.0, 135.0, 225.0, 315.0]:
		var diag_rad = deg2rad(diag_angle)
		var dx = cos(diag_rad)
		var dy = sin(diag_rad)
		var line_len = dial_size / 2.0 - 2.0
		for sd in range(4, int(line_len), 3):
			var dot_line = ColorRect.new()
			dot_line.color = Color(0.20, 0.20, 0.20, 0.5)
			dot_line.rect_min_size = Vector2(1, 1)
			dot_line.rect_position = Vector2(dial_size / 2.0 + dx * sd, dial_size / 2.0 + dy * sd)
			dot_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
			dial.add_child(dot_line)

	var h_line = ColorRect.new()
	h_line.color = Color(0.25, 0.25, 0.25, 0.6)
	h_line.rect_position = Vector2(0, dial_size / 2.0 - 0.5)
	h_line.rect_min_size = Vector2(dial_size, 1)
	h_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(h_line)
	var v_line = ColorRect.new()
	v_line.color = Color(0.25, 0.25, 0.25, 0.6)
	v_line.rect_position = Vector2(dial_size / 2.0 - 0.5, 0)
	v_line.rect_min_size = Vector2(1, dial_size)
	v_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(v_line)

	var center_dot = ColorRect.new()
	center_dot.color = Color(0.4, 0.4, 0.4, 1.0)
	center_dot.rect_min_size = Vector2(3, 3)
	center_dot.rect_position = Vector2(dial_size / 2.0 - 1.5, dial_size / 2.0 - 1.5)
	center_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(center_dot)

	var handle = ColorRect.new()
	handle.name = "Handle"
	handle.color = Color(0.95, 0.6, 0.1, 1.0)
	handle.rect_min_size = Vector2(10, 10)
	handle.rect_position = Vector2(dial_size / 2.0 - 5, dial_size / 2.0 - 5)
	handle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(handle)

	var snap_btn_size = 12
	var snap_inactive_color = Color(0.3, 0.3, 0.3, 0.8)
	var snap_active_color = Color(0.353, 0.698, 1.0, 1.0)
	var snap_positions = {
		"snap_315": Vector2(dial_size - 8, -4),
		"snap_45":  Vector2(dial_size - 8, dial_size - 8),
		"snap_135": Vector2(-4, dial_size - 8),
		"snap_225": Vector2(-4, -4),
	}
	var snap_angles = {"snap_315": 315.0, "snap_45": 45.0, "snap_135": 135.0, "snap_225": 225.0}
	var snap_tooltips = {"snap_315": "Lock angle: up-right", "snap_45": "Lock angle: down-right",
		"snap_135": "Lock angle: down-left", "snap_225": "Lock angle: up-left"}
	_blur_snap_btns = {}
	for key in snap_positions.keys():
		var snap_btn = TextureButton.new()
		snap_btn.name = key
		snap_btn.texture_normal = _ft_make_circle_texture(snap_btn_size, snap_inactive_color)
		snap_btn.texture_pressed = _ft_make_circle_texture(snap_btn_size, snap_active_color)
		snap_btn.toggle_mode = true
		snap_btn.pressed = false
		snap_btn.rect_position = snap_positions[key]
		snap_btn.rect_min_size = Vector2(snap_btn_size, snap_btn_size)
		snap_btn.hint_tooltip = snap_tooltips[key]
		snap_btn.focus_mode = Control.FOCUS_NONE
		snap_btn.connect("toggled", self, "_on_blur_snap_toggled", [key, snap_angles[key]])
		dial.add_child(snap_btn)
		_blur_snap_btns[key] = snap_btn

	dial.set_meta("dial_size", dial_size)
	dial.set_meta("dragging", false)
	dial.set_meta("snap_angle", -1.0)
	dial.rect_clip_content = false
	dial.connect("gui_input", self, "_on_blur_dial_input", [dial])
	return dial


func _ft_make_circle_texture(size: int, color: Color) -> ImageTexture:
	var img = Image.new()
	img.create(size, size, false, Image.FORMAT_RGBA8)
	img.lock()
	var center = Vector2(size / 2.0, size / 2.0)
	var radius = size / 2.0
	for y in range(size):
		for x in range(size):
			if Vector2(x, y).distance_to(center) <= radius:
				img.set_pixel(x, y, color)
			else:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
	img.unlock()
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)
	return tex


func _ft_make_ring_texture(size: int, color: Color) -> ImageTexture:
	var img = Image.new()
	img.create(size, size, false, Image.FORMAT_RGBA8)
	img.lock()
	var center = Vector2(size / 2.0, size / 2.0)
	var radius = size / 2.0
	for y in range(size):
		for x in range(size):
			if abs(Vector2(x, y).distance_to(center) - radius) < 1.0:
				img.set_pixel(x, y, color)
			else:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
	img.unlock()
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)
	return tex


func _blur_len_from_frac(frac: float) -> float:
	# Dial radius fraction (0..1) -> motion length, non-linear (BLUR_DIAL_EXP).
	return pow(clamp(frac, 0.0, 1.0), BLUR_DIAL_EXP) * BLUR_MOTION_MAX


func _blur_frac_from_len(length: float) -> float:
	if BLUR_MOTION_MAX <= 0.0:
		return 0.0
	return pow(clamp(length / BLUR_MOTION_MAX, 0.0, 1.0), 1.0 / BLUR_DIAL_EXP)


func _blur_set_dial_handle(v: Vector2) -> void:
	# v = direction * radius fraction, in [-1,1]².
	if _blur_dial == null or not is_instance_valid(_blur_dial):
		return
	var dial_size = float(_blur_dial.get_meta("dial_size"))
	var radius = dial_size / 2.0
	var handle = _blur_dial.get_node_or_null("Handle")
	if handle == null:
		return
	handle.rect_position = Vector2(dial_size / 2.0 + v.x * radius - 5, dial_size / 2.0 + v.y * radius - 5)


func _blur_sync_dial(m: float, a: float) -> void:
	# Places the handle from the current length / angle values.
	var frac = _blur_frac_from_len(m)
	var rad = deg2rad(a)
	_blur_set_dial_handle(Vector2(cos(rad), sin(rad)) * frac)


func _on_blur_dial_input(event: InputEvent, dial: Control) -> void:
	if event is InputEventMouseButton:
		if event.button_index == BUTTON_LEFT:
			dial.set_meta("dragging", event.pressed)
			if event.pressed:
				_blur_update_dial_from_mouse(event.position, dial)
	elif event is InputEventMouseMotion:
		if dial.get_meta("dragging"):
			_blur_update_dial_from_mouse(event.position, dial)


func _blur_update_dial_from_mouse(pos: Vector2, dial: Control) -> void:
	var dial_size = float(dial.get_meta("dial_size"))
	var radius = dial_size / 2.0
	var delta = pos - Vector2(radius, radius)
	if delta.length() > radius:
		delta = delta.normalized() * radius
	var frac = delta.length() / radius
	var length = _blur_len_from_frac(frac)
	length = stepify(length, BLUR_STEP)
	var snap = float(dial.get_meta("snap_angle"))
	_blur_syncing = true
	_blur_m_spin.value = length
	if snap >= 0.0:
		# Snap active: the angle is locked, dragging only changes the length.
		var sr = deg2rad(snap)
		_blur_set_dial_handle(Vector2(cos(sr), sin(sr)) * _blur_frac_from_len(length))
	else:
		_blur_set_dial_handle(delta / radius)
		if delta.length() > 0.5:
			var ang = rad2deg(atan2(delta.y, delta.x))
			if ang < 0.0:
				ang += 360.0
			_blur_a_spin.value = round(ang)
	_blur_syncing = false
	_apply_blur_from_ui()


func _on_blur_snap_toggled(pressed: bool, key: String, angle: float) -> void:
	if _blur_syncing:
		return
	if pressed:
		_blur_syncing = true
		for k in _blur_snap_btns.keys():
			if k != key and is_instance_valid(_blur_snap_btns[k]):
				_blur_snap_btns[k].pressed = false
		_blur_a_spin.value = round(angle)
		_blur_syncing = false
		if _blur_dial != null and is_instance_valid(_blur_dial):
			_blur_dial.set_meta("snap_angle", angle)
		_blur_sync_dial(float(_blur_m_spin.value), angle)
		_apply_blur_from_ui()
	elif _blur_dial != null and is_instance_valid(_blur_dial):
		_blur_dial.set_meta("snap_angle", -1.0)


func _blur_deactivate_snaps() -> void:
	var prev = _blur_syncing
	_blur_syncing = true
	for k in _blur_snap_btns.keys():
		if is_instance_valid(_blur_snap_btns[k]):
			_blur_snap_btns[k].pressed = false
	_blur_syncing = prev
	if _blur_dial != null and is_instance_valid(_blur_dial):
		_blur_dial.set_meta("snap_angle", -1.0)


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
			# Warp distort/perspective : restaure les EditPoints d'origine
			# et efface le profil de largeur (le warp vit dans les points,
			# pas dans le transform).
			var pkey = _ft_node_key(nd)
			if pkey != "" and _g.ModMapData.has("_ft_path_reset") \
					and _g.ModMapData["_ft_path_reset"].has(pkey):
				var pflat = _g.ModMapData["_ft_path_reset"][pkey]
				if pflat is Array and pflat.size() >= 4:
					var ppts = []
					for i in range(0, pflat.size(), 2):
						ppts.append(Vector2(pflat[i], pflat[i + 1]))
					nd.call("SetEditPoints", ppts)
					if nd.has_method("Smooth"):
						nd.call("Smooth")
				_g.ModMapData["_ft_path_reset"].erase(pkey)
			if pkey != "" and _g.ModMapData.has("_ft_width_warp") \
					and _g.ModMapData["_ft_width_warp"].has(pkey):
				_g.ModMapData["_ft_width_warp"].erase(pkey)
				_width_applied_sig.erase(pkey)
				_apply_path_point_widths(nd, null)
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
		_remove_blur(nd)
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
	# Pendant une drag box DD, la sélection oscille (assets qui entrent/
	# sortent du rectangle) → snapshot/clear puis restore des filtres à
	# répétition, visible dans l'UI. On gèle l'état courant jusqu'au
	# relâchement ; la frame suivante re-converge sur la sélection finale.
	if _select_tool != null and _select_tool.isDrawing:
		return
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
			# "Walls" reste coché : DragSelectWalls lit ce filtre pour
			# l'ajout différé (+2 frames) des walls après une drag box ;
			# le décocher ici créait une course qui excluait les walls de
			# toute multi-sélection quand FT était actif. Les clics près
			# de la box FT restent consommés par le verrou de toute façon.
			if menu.get_item_text(i) == "Walls":
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
	_update_blur_ui()
	_ftp("crop_ui", _ft2)
	# Blur: one undo record per slider burst (recorded once the mouse is
	# released and the controls have been idle for a moment).
	if not _blur_before.empty():
		if _blur_before_node == null or not is_instance_valid(_blur_before_node):
			_blur_before = {}
			_blur_before_node = null
		elif not Input.is_mouse_button_pressed(BUTTON_LEFT) \
				and OS.get_ticks_msec() - _blur_dirty_ms >= 250:
			_record_ft_unified_change(_blur_before, _capture_ft_unified([_blur_before_node]))
			_save_ft_data()
			_blur_before = {}
			_blur_before_node = null
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
	_reapply_width_warp()
	_ftp("restore_distort", _ft4)
	_ft4 = OS.get_ticks_usec()
	_restore_crop_from_store(not pattern_tool_active)
	_ftp("restore_crop", _ft4)
	_ft4 = OS.get_ticks_usec()
	_restore_edgecrop_from_store(not pattern_tool_active)
	_ftp("restore_edgecrop", _ft4)
	_ft4 = OS.get_ticks_usec()
	_restore_blur_from_store(not pattern_tool_active)
	_ftp("restore_blur", _ft4)
	_ft4 = OS.get_ticks_usec()
	_ft_watch_geometric(not pattern_tool_active)
	_ftp("watch_geo", _ft4)

	# Auto-disable FT si on vient de quitter le SelectTool (et qu'on n'est pas locké)
	if _was_select_active and not select_active and _enabled and not _lock_mode:
		_auto_disable_ft("left SelectTool")
	_was_select_active = select_active

	if not select_active:
		_selected_objects.clear()
		_walls_in_selection = []
		_lights_in_selection = []
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
			_walls_in_selection = []
			_lights_in_selection = []
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
				_ft_lock_next_id = _ft_world_next_id()
		elif not _same_selection(fresh_props, _ft_lock):
			# Sélection walls-only : switch DÉLIBÉRÉ vers un wall (compatible
			# symétrie) → on lâche le verrou au lieu de le rétablir, sinon le
			# wall serait immédiatement désélectionné au profit des props.
			if fresh_props.size() == 0 and _selected_walls().size() > 0:
				_ft_lock = []
				_ft_lock_reassert = 0
			# Paste / duplicate: DD deselected the locked asset and selected
			# NEW nodes. Reasserting the lock here would leave the pasted
			# copies at their spawn point and hand the original to
			# clipboard_fix's cursor move — the lock follows the new
			# selection instead.
			elif _ft_selection_has_new_nodes(fresh_props):
				_ft_lock = fresh_props.duplicate()
				_ft_lock_reassert = 0
				_ft_lock_next_id = _ft_world_next_id()
			# DD a basculé sur un autre asset → on rétablit le verrou (appels
			# directs, comme DragSelectWalls / alt_deselect).
			elif _ft_lock_reassert < 8 and _select_tool != null:
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

	# Walls sélectionnés : compatibles avec FT depuis l'ajout de la symétrie
	# des walls (menu réduit). Sert à ne pas auto-désactiver, à garder le
	# widget visible, à ne pas rétablir le verrou sur une sélection
	# walls-only, et à dessiner la box verte autour des walls (cache
	# _walls_in_selection consommé par l'overlay et _selection_aabb).
	var sel_walls_now := _selected_walls()
	_walls_in_selection = sel_walls_now
	_lights_in_selection = _selected_lights()

	# Auto-disable FT si la sélection devient exclusivement incompatible
	# (sélection non vide, mais aucun asset compatible — ex : roofs).
	# Les walls seuls ne sont PLUS incompatibles : la symétrie s'y applique.
	# Les lights non plus (symétrie du menu contextuel) — testées en
	# dernier : _selected_lights() ne scanne RawSelectables que si tout
	# le reste conclurait à la désactivation (court-circuit).
	# Cas "rien sélectionné" → on ne désactive pas (l'utilisateur peut re-sélectionner).
	if _enabled and not _lock_mode and fresh.size() > 0 and fresh_props.size() == 0 \
			and sel_walls_now.size() == 0 and _selected_lights().size() == 0:
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
	# - FT actif → cache la box DD chaque frame (notre overlay remplace,
	#   y compris pour les walls : la box verte les englobe désormais et
	#   la custom box de DragSelectWalls est coupée quand FT est actif)
	# - FT inactif → on ne touche pas à la box DD, on la laisse gérer par DD
	if _enabled and _select_tool != null \
			and (fresh_props.size() > 0 or sel_walls_now.size() > 0):
		_select_tool.call("EnableTransformBox", false)
	elif _enabled and _select_tool != null and fresh.size() > 0 \
			and _selected_lights().size() > 0:
		# Lights-only : pas de handles FT, mais la box DD (et ses curseurs
		# de resize) n'a rien à faire là non plus — seul le widget flamme
		# reste. Testé en dernier (court-circuit) : le scan RawSelectables
		# ne tourne que sur les sélections sans props ni walls.
		_select_tool.call("EnableTransformBox", false)

	# Bouton : visibilité basée sur fresh_props (déselection immédiate) OU
	# une sélection de walls (symétrie disponible via le menu réduit).
	# _widget_force_hidden override quand l'utilisateur a desactive le
	# toggle "Free Transform" dans le Settings panel — sinon le group se
	# reaffiche des qu'un asset compatible est selectionne.
	if _toggle_btn != null and is_instance_valid(_toggle_btn):
		var group = _toggle_btn.get_parent()
		if group != null:
			group.visible = (has_selection or sel_walls_now.size() > 0 \
					or _lights_in_selection.size() > 0) and not _widget_force_hidden


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
			if _selected_objects.size() > 0 or _walls_in_selection.size() > 0:
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
	if _selected_objects.size() == 0 and _active_handle < 0:
		# Sélection walls-only (un ou plusieurs murs, aucun prop FT) : on
		# laisse passer les événements souris — la box verte FT porte les
		# handles move/rotate/scale des walls et le menu des symétries.
		if _walls_in_selection.size() == 0:
			# Lights-only : clic droit (menu des symétries) + drag gauche
			# dans la box verte (move groupé — DD déplace via sa transform
			# box, cachée en lights-only). Tout le reste passe à DD.
			if _lights_in_selection.size() == 0 and not _light_drag_active:
				return
			if event is InputEventMouseButton and event.button_index == BUTTON_LEFT:
				var vp_l = tree.root.get_node_or_null(_viewport_path)
				if vp_l == null:
					return
				if event.pressed:
					if _ui_util != null and _ui_util.is_mouse_over_ui(_input_listener):
						return
					var wp_l = _mouse_world(vp_l)
					var box_l = _selection_aabb()
					if box_l.size != Vector2.ZERO and box_l.has_point(wp_l):
						_light_drag_active = true
						_light_drag_start = wp_l
						_light_drag_nodes = []
						_light_drag_origins = []
						for l in _lights_in_selection:
							if is_instance_valid(l):
								_light_drag_nodes.append(l)
								_light_drag_origins.append(l.global_position)
						_light_drag_before = _capture_ft_unified(_light_drag_nodes)
						tree.set_input_as_handled()
					# Clic hors box : DD gère (désélection / marquee).
				elif _light_drag_active:
					_light_drag_active = false
					_record_ft_unified_change(_light_drag_before,
							_capture_ft_unified(_light_drag_nodes))
					_light_drag_nodes = []
					_light_drag_origins = []
					_light_drag_before = {}
					tree.set_input_as_handled()
				return
			elif event is InputEventMouseMotion:
				if _light_drag_active:
					var vp_m = tree.root.get_node_or_null(_viewport_path)
					if vp_m != null:
						var delta_l = _mouse_world(vp_m) - _light_drag_start
						for i in range(_light_drag_nodes.size()):
							var ln = _light_drag_nodes[i]
							if is_instance_valid(ln):
								ln.global_position = _light_drag_origins[i] + delta_l
						tree.set_input_as_handled()
				return
			if not (event is InputEventMouseButton \
					and event.button_index == BUTTON_RIGHT and event.pressed):
				return
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

	# Molette pendant un drag IDX_MOVE de walls (walls-only) : rotation
	# par pas de 15° (5° avec Shift), composée dans la translation.
	# Hors drag, la molette appartient à rotation_fix (qui route les
	# walls via DragSelectWalls et skippe pendant nos drags de handle).
	if event is InputEventMouseButton and event.pressed \
			and (event.button_index == BUTTON_WHEEL_UP or event.button_index == BUTTON_WHEEL_DOWN) \
			and _active_handle == IDX_MOVE and _wall_drag_active and _drag_states.empty():
		var wheel_step = deg2rad(5.0) if _mod_shift else deg2rad(15.0)
		if event.button_index == BUTTON_WHEEL_UP:
			wheel_step = -wheel_step
		_wall_wheel_rot += wheel_step
		print("[FreeTransform] Wheel (drag) : %.0f°" % rad2deg(_wall_wheel_rot))
		_update_handle_drag(wp, vp)
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
			elif (_selected_objects.size() > 0 or _walls_in_selection.size() > 0) \
					and _selection_aabb().has_point(wp):
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
		# Menu contextuel du mode de transformation. Ouvert aussi pour une
		# sélection ne contenant QUE des walls (menu réduit : symétries).
		if _enabled and (_selected_objects.size() > 0 or _walls_in_selection.size() > 0 or _selected_lights().size() > 0) and _active_handle < 0:
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
	var blur_store = _g.ModMapData.get("_ft_blur", {})
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
		# Paths : EditPoints (coordonnées monde) — mutés par le warp
		# distort/perspective (baké dans les points, invisible pour le
		# record DD RecordTransforms).
		if _is_path(nd):
			var ppts = _get_path_edit_points_world(nd)
			if ppts.size() > 0:
				entry["path_points"] = ppts
			var wprof = _ft_width_profile_copy(nd)
			if wprof != null:
				entry["path_width_warp"] = wprof
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
		if blur_store.has(key):
			entry["blur"] = blur_store[key].duplicate()
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
			# Texture rotation: mutated by the bake compensation (folding a
			# rotated basis moves the angle from the node onto the shader
			# uniform) — must round-trip through undo.
			var tex_rot = nd.get("_Rotation")
			if tex_rot != null:
				entry["pattern_tex_rot"] = float(tex_rot)
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
		if ea.has("blur") != eb.has("blur"):
			return false
		if ea.has("blur"):
			var ba = ea["blur"]
			var bb = eb["blur"]
			if ba.get("r") != bb.get("r") or ba.get("m") != bb.get("m") or ba.get("a") != bb.get("a"):
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
		if ea.get("pattern_tex_rot") != eb.get("pattern_tex_rot"):
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
	if not _g.ModMapData.has("_ft_blur"):
		_g.ModMapData["_ft_blur"] = {}
	var blur_store = _g.ModMapData["_ft_blur"]
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
			# Paths : les path_points capturés sont MONDE (GlobalEditPoints)
			# et SetEditPoints (C#) suppose une base IDENTITÉ — il pose
			# Position = points[0] et stocke des deltas parent-space, sans
			# tenir compte de rotation/scale. On neutralise donc la base
			# AVANT SetEditPoints (Position est posé par SetEditPoints
			# lui-même, Smooth() y est inclus). Sans points capturés,
			# fallback transform standard.
			if _is_path(nd):
				if entry.has("path_points") and entry["path_points"].size() > 1:
					nd.rotation = 0.0
					nd.scale = Vector2.ONE
					nd.call("SetEditPoints", entry["path_points"])
					_refresh_path_widget(nd)
				elif entry.has("transform"):
					var dt = entry["transform"]
					nd.transform = Transform2D(
						Vector2(dt.xx, dt.xy),
						Vector2(dt.yx, dt.yy),
						Vector2(dt.ox, dt.oy)
					)
				else:
					nd.global_position = entry["position"]
					nd.global_rotation = entry["rotation"]
					nd.global_scale = entry["scale"]
			if _is_path(nd):
				# Profil de largeur : restaure ou efface (état capturé sans
				# profil) — application par point (moteur DD).
				if not _g.ModMapData.has("_ft_width_warp"):
					_g.ModMapData["_ft_width_warp"] = {}
				if entry.has("path_width_warp"):
					var wprof = entry["path_width_warp"]
					_g.ModMapData["_ft_width_warp"][key] = wprof.duplicate(true)
					_apply_path_point_widths(nd, wprof)
				else:
					_g.ModMapData["_ft_width_warp"].erase(key)
					_apply_path_point_widths(nd, null)
				_width_applied_sig.erase(key)
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
				if entry.has("pattern_tex_rot"):
					_set_pattern_texture_rotation(nd, entry["pattern_tex_rot"])
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
				# Paths : déjà restaurés EXACTEMENT plus haut (avant
				# SetEditPoints) — ne pas ré-écraser via pos/rot/scale
				# (perdrait le det<0 d'une symétrie).
				if _is_path(nd):
					pass
				elif entry.has("pattern_transform"):
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
		# Blur: the store is mirrored here; the material itself is dropped
		# below and rebuilt (with or without blur) by the restore loops.
		if entry.has("blur"):
			blur_store[key] = entry["blur"].duplicate()
		else:
			blur_store.erase(key)
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
				var _mk = _ft_materials[key].get("kind", "prop")
				if _mk == "path":
					_ft_line_restore(nd)
				elif _mk == "pattern":
					if nd.material == _ft_materials[key].get("warp"):
						nd.material = _ft_materials[key].get("original", null)
				else:
					var sprite = _get_sprite_node(nd)
					if sprite != null:
						sprite.material = _ft_materials[key].get("original", null)
					_ft_reset_shadow_material(nd)
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


func _selection_has_pattern() -> bool:
	for nd in _selected_objects:
		if is_instance_valid(nd) and _is_pattern(nd):
			return true
	return false


# True when nd is a portal anchored to one of the walls captured for the
# current handle drag. Such portals are driven BY their wall and must not be
# transformed independently.
func _is_portal_of_dragged_wall(nd: Node) -> bool:
	if not _wall_drag_active: return false
	if not _is_portal(nd): return false
	if _is_freestanding_portal(nd): return false
	var wall = _get_portal_wall(nd)
	if wall == null: return false
	for w in _wall_drag_walls:
		if w == wall: return true
	return false


# ── Wall.Points ↔ Wall.pointsClosed ────────────────────────────────────────
# DD keeps a second copy of a LOOPED wall's outline in the private
# `pointsClosed` array (Points + Points[0] appended). It is built only by
# Wall.Set() and shifted by Wall.Offset() — RemakeLines() does NOT rebuild
# it. PortalTool.FindBestLocation() → Wall.FindPortalSpot() reads
# `Loop ? pointsClosed : Points`, so once we write Points directly the
# PortalTool keeps snapping new portals onto the wall's OLD outline.
# Every direct Points write must go through this helper. Godot's Mono
# property bridge reaches private auto-properties, so we can write the
# cache back ourselves; non-looped walls need nothing.
func _set_wall_points(wall, pts) -> void:
	wall.set("Points", pts)
	if wall.get("Loop") != true:
		return
	if pts == null or pts.size() < 2:
		return
	var closed := PoolVector2Array()
	for p in pts:
		closed.append(p)
	closed.append(pts[0])
	wall.set("pointsClosed", closed)
	# One-shot sanity check: if the private property turns out to be
	# unreachable, say so once instead of silently leaving portals
	# snapping to stale geometry.
	if not Engine.has_meta("_up_pointsclosed_checked"):
		Engine.set_meta("_up_pointsclosed_checked", true)
		var back = wall.get("pointsClosed")
		if back == null or back.size() != closed.size():
			printerr("[UnofficialPatch] Wall.pointsClosed is not writable from GDScript; ")
			printerr("[UnofficialPatch] portals may snap to stale geometry on looped walls.")


func _all_portals() -> bool:
	# Sélection vide (ex: walls-only) → false, sinon les branches
	# portals (hit test, handles, pivots) s'appliqueraient à tort.
	if _selected_objects.empty():
		return false
	# Idem quand des walls accompagnent les portals : c'est une sélection
	# de GROUPE, pas une sélection de portals. Les modes dédiés
	# (walk/slide/offset) et la suppression de la bande de rotation n'ont
	# alors plus de sens — l'utilisateur veut transformer l'ensemble, et
	# le portal suit son mur.
	if not _walls_in_selection.empty():
		return false
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


# A freestanding portal is a portal that isn't anchored to a wall (WallID == -1).
# It behaves like a regular prop: it owns its world position and rotation, and
# nothing re-fits it to a wall. Wall-anchored portals, by contrast, are driven by
# their wall (RemakeLines re-places and re-orients them), which is why the two
# kinds must be transformed differently.
func _is_freestanding_portal(nd: Node) -> bool:
	if not _is_portal(nd):
		return false
	var wall_id = nd.get("WallID")
	return wall_id == null or int(wall_id) == -1


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


# EditPoints en coordonnées MONDE. DD expose EditPoints (locaux au node)
# et GlobalEditPoints (monde) ; SetEditPoints attend du MONDE — convention
# validée par SplitPath (lit GlobalEditPoints, repasse tel quel à
# SetEditPoints). Fallback : transforme les locaux par node.transform.
func _get_path_edit_points_world(node: Node2D) -> Array:
	var pts = node.get("GlobalEditPoints")
	if pts != null:
		var out = []
		for p in pts:
			out.append(p)
		return out
	var out2 = []
	for p in _get_path_edit_points_local(node):
		out2.append(node.transform.xform(p))
	return out2


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


# Inversion bilinéaire CPU (float64) : coordonnées (u,v) de p dans le quad
# [tl, tr, br, bl]. Forme quadratique numériquement stable (même correctif
# que les shaders warp). Pas de clamp : l'extrapolation reste continue pour
# les points en bordure du padding de la box des paths fins.
func _inv_bilinear_cpu(p: Vector2, quad: Array) -> Vector2:
	var a: Vector2 = quad[0]; var b: Vector2 = quad[1]
	var c: Vector2 = quad[2]; var d: Vector2 = quad[3]
	var e = b - a; var f = d - a; var g = a - b + c - d; var h = p - a
	var k2 = g.cross(f)
	var k1 = e.cross(f) + h.cross(g)
	var k0 = h.cross(e)
	var v: float
	if abs(k2) < 1e-9 * (abs(k1) + 1.0):
		v = -k0 / k1 if abs(k1) > 0.000000000001 else 0.0
	else:
		var sq = sqrt(max(k1 * k1 - 4.0 * k0 * k2, 0.0))
		var qq = -0.5 * (k1 + (sq if k1 >= 0.0 else -sq))
		var v1 = qq / k2
		var v2 = k0 / qq if abs(qq) > 0.000000000001 else v1
		v = v1 if (v1 >= -0.001 and v1 <= 1.001) else v2
	var den = e + g * v
	var u: float
	if abs(den.x) > abs(den.y):
		u = (h.x - f.x * v) / den.x if abs(den.x) > 0.000000000001 else 0.0
	else:
		u = (h.y - f.y * v) / den.y if abs(den.y) > 0.000000000001 else 0.0
	return Vector2(u, v)


# Distort/Perspective d'un path : remappe chaque EditPoint (monde, capturé
# au début du drag) du quad source vers le quad destination, puis Smooth.
func _apply_distort_path(st: Dictionary, nc: Array) -> void:
	var node = st.node
	if not is_instance_valid(node): return
	var pts0 = st.get("path_pts_world")
	if pts0 == null or pts0.size() == 0: return
	var src = st.corners
	if not (src is Array) or src.size() != 4: return
	var new_pts = []
	for p in pts0:
		new_pts.append(_warp_point(p, src, nc))
	node.call("SetEditPoints", new_pts)
	if node.has_method("Smooth"):
		node.call("Smooth")

	# Largeur variable : facteur perpendiculaire du warp à chaque point,
	# composé avec le profil d'avant le drag (recalcul absolu depuis les
	# snapshots chaque frame — pas de dérive). Store écrit au fil de l'eau
	# (persisté par _save_ft_data au commit).
	var ploop = bool(node.get("loop")) if node.get("loop") != null else false
	var fr0 = _polyline_arc_fractions(pts0, ploop)
	var pre = st.get("path_width_profile")
	var new_fr = _polyline_arc_fractions(new_pts, ploop)
	var new_fa = []
	for i in range(pts0.size()):
		new_fa.append(_sample_width_profile(pre, fr0[i]) * _area_warp_factor(pts0[i], src, nc))
	var key = _ft_node_key(node)
	if key != "":
		if not _g.ModMapData.has("_ft_width_warp"):
			_g.ModMapData["_ft_width_warp"] = {}
		_g.ModMapData["_ft_width_warp"][key] = {"fr": new_fr, "fa": new_fa, "cl": ploop}
	if node is Line2D:
		_apply_path_point_widths(node, {"fr": new_fr, "fa": new_fa, "cl": ploop})



func _set_pattern_texture_rotation(node: Node2D, rot: float) -> void:
	# Route the texture rotation through DD's own SetNewRotation so the C#
	# model (_Rotation, persisted by PatternShape.Save) stays in sync, then
	# mirror the uniform onto whichever cached material (FT warp / DD
	# original) is NOT currently on the node — SetNewRotation only writes
	# the param on node.material.
	if node.has_method("SetNewRotation"):
		node.call("SetNewRotation", rot)
	var key = _ft_node_key(node)
	if _ft_materials.has(key):
		for mkey in ["warp", "original"]:
			var m = _ft_materials[key].get(mkey)
			if m is ShaderMaterial and m != node.material:
				m.set_shader_param("rotation", rot)


func _bake_pattern_texture_rotation(node: Node2D, basis_t: Transform2D) -> void:
	# DD stores a pattern's SHAPE rotation on the node (PatternShape.Save:
	# "shape_rotation" = Rotation) and Pattern.shader samples in LOCAL space
	# (world_uv = VERTEX / textureSize), so the texture rotates with the
	# node. When we fold a rotated basis into the polygon and reset the
	# basis to identity, sampling becomes axis-aligned again and the
	# texture snaps back to its original angle. Compensate by adding the
	# basis rotation to the "rotation" uniform: DD's rotate_uv applies
	# R(-r) to the sampling coords, exactly like the inverse basis R(-theta)
	# did — same angle, up to a tiling phase offset (invisible on seamless
	# tiles). For a reflected basis (det < 0, legacy repair) the x column
	# of R(theta)*diag(1,-1) is still (cos, sin) — the angle is right, the
	# chirality is carried by the mirrored points.
	var theta = atan2(basis_t.x.y, basis_t.x.x)
	if abs(theta) < 0.0005:
		return
	var cur = node.get("_Rotation")
	if cur == null:
		return  # Null texture: no shader material, nothing to rotate
	_set_pattern_texture_rotation(node, float(cur) + theta)


func _bake_pattern_state(node: Node2D) -> void:
	# Fusionne toute transformation (scale, shear, distort, perspective) dans le polygon.
	# Appelé uniquement quand le transform est non-identity.
	var key = _ft_node_key(node)

	# Calcule les positions monde des vertices.
	var world_pts = []
	var basis_folded = false
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
			basis_folded = true
	else:
		var t = node.transform
		for p in node.polygon:
			world_pts.append(t.xform(p))
		basis_folded = true

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

	# Compensate the texture angle BEFORE resetting the basis: DD carries
	# the shape rotation on the node and the texture follows it (see
	# _bake_pattern_texture_rotation). Only when the basis really got
	# folded into the points (not the world-corners path, which ignores
	# the basis).
	if basis_folded:
		_bake_pattern_texture_rotation(node, node.transform)

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
		# N vertices (arbitrary polygon) → keep EVERY transformed vertex.
		# The old collapse to the 4 AABB corners destroyed the shape of any
		# non-rectangular pattern (symptom: "the pattern fills its whole
		# transform box" after baking a non-identity basis).
		for p in world_pts:
			new_poly.append(p - orig_pos)
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

	# 2. NE PAS toucher au polygon original (_ft_pattern_orig).
	# C'est la référence FIXE de l'espace texture : le shader échantillonne
	# via ft_orig_min/ft_orig_size (fenêtre de texture) et le warp calcule
	# ses (u,v) par rapport à l'AABB de l'original. Le transformer changeait
	# la taille de la fenêtre (fréquence de texture fausse → rayures denses)
	# et désalignait les 4 points de leur AABB (paramétrisation (u,v)
	# repliée → triangulation qui se chevauche, bandes noires) — visible en
	# enchaînant skew puis scale. L'interpolation bilinéaire étant
	# équivariante aux transformations affines, absorber le transform dans
	# les coins (étape 1) et le polygon (étape 3) suffit et reste exact.

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
	# Texture-angle compensation (the basis — rotation included — was just
	# folded into corners + polygon): see _bake_pattern_texture_rotation.
	_bake_pattern_texture_rotation(node, t)
	node.transform = Transform2D(Vector2(1, 0), Vector2(0, 1), t.origin)

	# 6. Met a jour la position de reference
	if key != "":
		if not _g.ModMapData.has("_ft_pattern_orig_pos"):
			_g.ModMapData["_ft_pattern_orig_pos"] = {}
		_g.ModMapData["_ft_pattern_orig_pos"][key] = [t.origin.x, t.origin.y]

	# 7. The basis is now IDENTITY (everything absorbed): sync any stored
	# _ft_transforms entry, otherwise _reapply_shear_transforms would
	# re-impose next frame the basis we just baked ON TOP of the baked
	# geometry (double application: the pattern drifted away or vanished —
	# typical case: symmetry then move).
	if key != "" and _g.ModMapData.has("_ft_transforms") \
			and _g.ModMapData["_ft_transforms"].has(key):
		_store_shear_transform(node, node.transform)


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
	# macOS fix: prefer DD's reference world mouse position; the manual
	# conversion (viewport mouse + inverse canvas transform) drifts by a
	# screen offset on some configs (Retina/DPI/UI scaling).
	if _g != null and _g.get("WorldUI") != null:
		return _g.WorldUI.MousePosition
	return vp.canvas_transform.affine_inverse().xform(vp.get_mouse_position())


func _get_tex_size(node: Node2D) -> Vector2:
	if _is_pattern(node):
		var bb = _get_pattern_local_aabb(node)
		return bb.size
	if _is_path(node):
		var bb = _get_path_local_aabb(node)
		return bb.size
	var PADDING = 48.0
	# IMPÉRATIF : passer par la propriété C# "Sprite" du Prop, pas par « le
	# premier enfant Sprite ». Les mods d'ombres (DropShadowObjects) insèrent
	# leur sprite d'ombre en child 0 (move_child(shadow, 0)) et peuvent lui
	# donner une texture bakée de taille différente : la box FT était alors
	# calculée sur l'ombre, d'où un asset qui saute ou change de taille dès
	# qu'on tire une poignée.
	var main = _get_sprite_node(node)
	if main != null:
		var mtex = main.get("texture")
		if mtex != null:
			var msz = mtex.get_size()
			var mrr = main.get("region_rect")
			if mrr is Rect2 and mrr.size.length() > 0.0: msz = mrr.size
			return msz + Vector2(PADDING, PADDING)
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


# Coins en espace NODE, dans le même ordre que _prop_corners (tl, tr, br, bl)
# et surtout dérivés de la MÊME source : si le node porte des coins distort,
# ceux-ci décrivent un quadrilatère qui n'est plus le rectangle ±hw/±hh.
# Utilisé par le scale d'un objet cisaillé, qui doit apparier un pivot monde
# (pris dans st.corners) avec son pivot local — les mélanger reposait l'asset
# ailleurs dès qu'un distort/perspective/skew avait précédé le scale.
func _prop_local_corners(node: Node2D) -> Array:
	if _g.ModMapData.has("_ft_distort"):
		var id = _ft_node_key(node)
		if _g.ModMapData["_ft_distort"].has(id):
			var raw = _g.ModMapData["_ft_distort"][id]
			var lc: Array
			if raw.size() == 8:
				lc = [Vector2(raw[0],raw[1]), Vector2(raw[2],raw[3]),
				      Vector2(raw[4],raw[5]), Vector2(raw[6],raw[7])]
			else:
				lc = raw
			if _is_pattern(node):
				return [lc[0], lc[1], lc[2], lc[3]]
			var sprite = _get_sprite_node(node)
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
			var PADDING_L = 48.0
			var ix = (real_w + PADDING_L) / real_w
			var iy = (real_h + PADDING_L) / real_h
			var soff_d = _get_visual_offset(node)
			return [
				Vector2(lc[0].x * ix, lc[0].y * iy) + soff_d,
				Vector2(lc[1].x * ix, lc[1].y * iy) + soff_d,
				Vector2(lc[2].x * ix, lc[2].y * iy) + soff_d,
				Vector2(lc[3].x * ix, lc[3].y * iy) + soff_d,
			]
	var ts = _get_tex_size(node)
	var sw = ts.x * 0.5; var sh = ts.y * 0.5
	var soff = _get_visual_offset(node)
	return [
		Vector2(-sw, -sh) + soff,
		Vector2( sw, -sh) + soff,
		Vector2( sw,  sh) + soff,
		Vector2(-sw,  sh) + soff,
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
	# Étend aux walls sélectionnés : la box verte FT les englobe (visuel
	# seul — les handles ne transforment que les props, les walls passent
	# par la symétrie du menu contextuel).
	for w in _walls_in_selection:
		if not is_instance_valid(w): continue
		var pts = w.get("Points")
		if pts == null: continue
		for p in pts:
			mn.x = min(mn.x, p.x); mn.y = min(mn.y, p.y)
			mx.x = max(mx.x, p.x); mx.y = max(mx.y, p.y)
	# Étend aux lights sélectionnées : position ± pad (le widget flamme
	# fait ~128 px locaux ; 64 unités monde donnent une box lisible sans
	# englober tout le rayon lumineux).
	var light_pad := 64.0
	for l in _lights_in_selection:
		if not is_instance_valid(l): continue
		var lp = l.global_position
		mn.x = min(mn.x, lp.x - light_pad); mn.y = min(mn.y, lp.y - light_pad)
		mx.x = max(mx.x, lp.x + light_pad); mx.y = max(mx.y, lp.y + light_pad)
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
	if _selected_objects.size() == 0:
		# Walls-only : handles sur la bbox fusionnée (move/rotate/scale
		# en free ; coins/bords warpés en skew/distort/perspective).
		if _walls_in_selection.size() > 0 \
				and _transform_mode in ["free", "skew", "distort", "perspective"]:
			return _bbox_handle_positions(_selection_aabb())
		return []
	# Pendant un drag non-free, utilise _group_warp_corners comme source de vérité
	# (évite les décalages si node.transform est modifié entre frames)
	if _transform_mode != "free" and _group_warp_corners.size() == 4 and _active_handle >= 0:
		return _group_corners_to_handles(_group_warp_corners)
	if _selected_objects.size() == 1 and _walls_in_selection.size() == 0:
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

	# Bande de rotation autour de la box (même geste que la custom box de
	# DragSelectWalls) — en mode free, hors des handles de scale.
	# Exclusions :
	# - sélections 100% portals (leurs modes slide/offset/scale priment,
	#   et une rotation libre les décollerait du mur) ;
	# - sélections contenant un pattern : DD reset les transforms des
	#   patterns (node.rotation est inopérant) et stocker une base
	#   tournée dans _ft_transforms épinglait le pattern (box qui bouge
	#   sans le pattern). La molette de rotation_fix, qui passe par
	#   rotate_ft_node, reste le chemin supporté pour eux.
	if _transform_mode == "free" and not _all_portals() \
			and not _selection_has_pattern() \
			and (_selected_objects.size() > 0 or _walls_in_selection.size() > 0):
		var bb = _selection_aabb()
		if bb.size != Vector2.ZERO and not bb.has_point(wp):
			var nearest = Vector2(clamp(wp.x, bb.position.x, bb.end.x),
					clamp(wp.y, bb.position.y, bb.end.y))
			if wp.distance_to(nearest) < 65.0 / zoom:
				return IDX_ROT

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

	# Walls : snapshot pour move / rotate / scale (mode free) — identique
	# à la custom box de DragSelectWalls, via son API. Les modes
	# skew / distort / perspective / crop ne s'appliquent PAS aux walls
	# (seuls la symétrie et les transformations affines sont supportées).
	_wall_drag_active = false
	_wall_drag_walls = []
	_wall_drag_snaps = {}
	_wall_drag_before = []
	_wall_drag_corners = {}
	_wall_drag_wprofile = {}
	_wall_drag_childpts = {}
	_wall_drag_childfr = {}
	_wall_drag_lastnc = {}
	var _dsw = _g.ModMapData.get("_drag_select_walls")
	if _walls_in_selection.size() > 0 and _dsw != null \
			and _dsw.has_method("_apply_transform_to_wall") \
			and (handle_idx == IDX_MOVE or handle_idx == IDX_ROT \
			or (_transform_mode in ["free", "skew", "distort", "perspective"] \
			and handle_idx in (CORNER_IDX + EDGE_IDX))):
		for _w in _walls_in_selection:
			if not is_instance_valid(_w):
				continue
			_store_wall_reset(_w)
			var _wsnap = _dsw._snapshot_wall(_w)
			_wall_drag_walls.append(_w)
			_wall_drag_snaps[_w] = _wsnap
			_wall_drag_corners[_w] = _wall_aabb_corners(_wsnap.get("pts", []))
			_wall_drag_wprofile[_w] = _ft_width_profile_copy(_w)
			var _cfr = {}
			var _cdec = {}
			var _wloop2 = bool(_w.get("Loop")) if _w.get("Loop") != null else false
			for _child in _wsnap.get("children", {}):
				var _cdata = _wsnap["children"][_child]
				if _cdata.has("points"):
					var _cpts = _decimate_polyline(_cdata["points"], 64)
					_cdec[_child] = _cpts
					_cfr[_child] = _arc_fractions_on_polyline(_wsnap.get("pts", []), _cpts, _wloop2)
			_wall_drag_childpts[_w] = _cdec
			_wall_drag_childfr[_w] = _cfr
			_wall_drag_before.append({
				"wall": _w,
				"snap": _wsnap,
				"portal_scales": _capture_portal_scales(_w),
				"width_warp": _ft_width_profile_copy(_w),
			})
		_wall_drag_active = _wall_drag_walls.size() > 0
	_wall_wheel_rot = 0.0

	# Distort / Perspective sur paths : absorbe d'abord tout transform du
	# node dans les EditPoints (bake éprouvé du flux skew→free), pour que
	# le warp travaille en coordonnées monde pures et que la capture
	# d'undo reflète l'état post-bake (visuellement identique).
	if _transform_mode in ["distort", "perspective"]:
		for _pnd in _selected_objects:
			if is_instance_valid(_pnd) and _is_path(_pnd):
				_bake_path_transform(_pnd)
				_store_path_reset(_pnd)

	# Choose the undo path based on whether the selection is fully
	# manageable by us. If yes, we skip DD's SavePreTransforms entirely
	# and capture a unified before-snapshot ourselves; we'll push a
	# single record on commit. If not (any wall/portal/pattern/path),
	# we fall back to DD's flow + an extras-only callback.
	# Sélection walls-only : rien à enregistrer côté DD (les walls sont
	# couverts par notre record combiné) → chemin unifié.
	_undo_skip_dd_record = _ft_selection_is_simple(_selected_objects) \
			or _selected_objects.empty()
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
		# Portal anchored to a wall we're about to drag: skip it. The wall
		# transform already moves and re-orients its child portals
		# (_apply_transform_to_wall), so keeping the portal in _drag_states
		# applied the same rotation/translation a second time — it spun and
		# orbited at double speed while the wall turned once.
		if _is_portal_of_dragged_wall(nd): continue
		var wall_arc = _build_wall_arc(nd) if _is_portal(nd) else null
		var arc_rot_start = 0.0
		if wall_arc != null and not wall_arc.empty():
			var seg = _arc_segment(wall_arc.points, wall_arc.cum, wall_arc.arc)
			arc_rot_start = atan2(seg.dir.y, seg.dir.x)
		_drag_states.append({
			"node": nd, "pos": nd.position, "rot": nd.rotation,
			"scale": nd.scale, "tex_size": _get_tex_size(nd),
			"corners": _prop_corners(nd),
			"local_corners": _prop_local_corners(nd),
			"node_transform": nd.transform,
			"portal_radius": nd.get("Radius") if _is_portal(nd) else null,
			"sprite_pos": nd.get("Sprite").position if nd.get("Sprite") != null else null,
			"visual_offset": _get_visual_offset(nd),
			"orig_polygon": Array(nd.polygon) if _is_pattern(nd) else null,
			"is_pattern": _is_pattern(nd),
			"is_path": _is_path(nd),
			"path_pts_world": _get_path_edit_points_world(nd) if _is_path(nd) else null,
			"path_width_profile": _ft_width_profile_copy(nd) if _is_path(nd) else null,
			"wall_arc": wall_arc,
			"arc_rot_start": arc_rot_start,
		})
	_group_bbox = _prop_aabb(_drag_states[0].node) \
			if (_drag_states.size() == 1 and not _wall_drag_active) else _selection_aabb()
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
	if _drag_states.empty() and not _wall_drag_active: return
	var is_single = (_selected_objects.size() == 1) and not _wall_drag_active
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
			# Défensif : jamais de node.rotation sur un pattern (cf. bande).
			if st.get("is_pattern", false): continue
			st.node.position = st.pos
			st.node.rotation = st.rot
			var aabb_before = _prop_aabb(st.node)
			var vc_before = aabb_before.position + aabb_before.size * 0.5
			var vc_target = pivot + (vc_before - pivot).rotated(rad)
			st.node.rotation = st.rot + rad
			var aabb_natural = _prop_aabb(st.node)
			var vc_natural = aabb_natural.position + aabb_natural.size * 0.5
			st.node.position = st.pos + (vc_target - vc_natural)
			_sync_store_basis(st.node)
		# Walls : rotation monde autour du même pivot, via DragSelectWalls.
		if _wall_drag_active:
			var Wr = Transform2D(rad, Vector2.ZERO)
			Wr.origin = pivot - Wr.basis_xform(pivot)
			_apply_walls_drag_transform(Wr)
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
		# Walls : translation identique via DragSelectWalls, composée avec
		# la rotation molette (autour du centre courant de la sélection).
		if _wall_drag_active:
			var Wm = Transform2D(0.0, delta)
			if abs(_wall_wheel_rot) > 0.0001:
				var c = _group_bbox.position + _group_bbox.size * 0.5 + delta
				var Rw = Transform2D(_wall_wheel_rot, Vector2.ZERO)
				Rw.origin = c - Rw.basis_xform(c)
				Wm = Rw * Wm
			_apply_walls_drag_transform(Wm)
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
				# Pivot local pris dans le MÊME quadrilatère que le pivot monde.
				# Avec des coins distort le contour n'est plus le rectangle
				# ±hw/±hh : apparier st.corners (déformé) avec un pivot local
				# rectangulaire décalait new_origin, d'où l'asset qui se
				# repose ailleurs quand on tire un côté en Scale après un
				# skew/distort/perspective.
				var lcn = st.get("local_corners", [])
				var use_lcn = lcn is Array and lcn.size() == 4
				match _active_handle:
					0:
						pivot_world = st.corners[2]
						pivot_local = lcn[2] if use_lcn else Vector2(hw - soff.x, hh - soff.y)
					2:
						pivot_world = st.corners[3]
						pivot_local = lcn[3] if use_lcn else Vector2(-hw - soff.x, hh - soff.y)
					4:
						pivot_world = st.corners[0]
						pivot_local = lcn[0] if use_lcn else Vector2(-hw - soff.x, -hh - soff.y)
					6:
						pivot_world = st.corners[1]
						pivot_local = lcn[1] if use_lcn else Vector2(hw - soff.x, -hh - soff.y)
					1:
						pivot_world = (st.corners[2] + st.corners[3]) * 0.5
						pivot_local = ((lcn[2] + lcn[3]) * 0.5) if use_lcn else Vector2(-soff.x, hh - soff.y)
					5:
						pivot_world = (st.corners[0] + st.corners[1]) * 0.5
						pivot_local = ((lcn[0] + lcn[1]) * 0.5) if use_lcn else Vector2(-soff.x, -hh - soff.y)
					3:
						pivot_world = (st.corners[0] + st.corners[3]) * 0.5
						pivot_local = ((lcn[0] + lcn[3]) * 0.5) if use_lcn else Vector2(-hw - soff.x, -soff.y)
					7:
						pivot_world = (st.corners[1] + st.corners[2]) * 0.5
						pivot_local = ((lcn[1] + lcn[2]) * 0.5) if use_lcn else Vector2(hw - soff.x, -soff.y)
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
		_sync_store_basis(st.node)
	else:
		var pivot = _pivot_world_group(_active_handle)
		# Portals : ancrage vertical centré (coins et handles haut/bas)
		var is_vert_handle = (_active_handle == 1 or _active_handle == 5)
		if (_active_handle in CORNER_IDX or is_vert_handle) and _all_portals():
			pivot.y = _group_bbox.position.y + _group_bbox.size.y * 0.5
		# Walls : scale monde autour du pivot groupe, via DragSelectWalls
		# (positions seules — l'épaisseur du wall ne change pas, comme la
		# custom box).
		if _wall_drag_active:
			var Ws = Transform2D(Vector2(rx, 0.0), Vector2(0.0, ry), Vector2.ZERO)
			Ws.origin = pivot - Ws.basis_xform(pivot)
			_apply_walls_drag_transform(Ws)
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
					_sync_store_basis(st.node)


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
	# Walls dragués via les handles FT : RemakeLines final (différé
	# pendant le drag pour la performance, cf. _apply_walls_drag_transform)
	# puis snapshots d'après pour le record combiné.
	var wall_entries_after := []
	if _wall_drag_active:
		var _dsw = _g.ModMapData.get("_drag_select_walls")
		for _w in _wall_drag_walls:
			if not is_instance_valid(_w):
				continue
			# Largeur variable : fige le profil final dans le store (facteurs
			# aux points du wall, composés avec le profil pré-drag) AVANT le
			# RemakeLines — qui recrée les Line2D — puis reconstruit leurs
			# width_curve depuis le store APRÈS.
			var _wkey = _ft_node_key(_w)
			if _wkey != "" and _wall_drag_lastnc.has(_w) \
					and _wall_drag_corners.has(_w) and _wall_drag_snaps.has(_w):
				var _osrc = _wall_drag_corners[_w]
				var _onc = _wall_drag_lastnc[_w]
				var _opts = _wall_drag_snaps[_w].get("pts", [])
				var _wloop = bool(_w.get("Loop")) if _w.get("Loop") != null else false
				if _opts.size() >= 2:
					var _ofr = _polyline_arc_fractions(_opts, _wloop)
					var _pre = _wall_drag_wprofile.get(_w)
					var _newpts = []
					for _p in _opts:
						_newpts.append(_warp_point(_p, _osrc, _onc))
					var _nfa = []
					var _changed = _pre != null
					for _i in range(_opts.size()):
						var _f = _sample_width_profile(_pre, _ofr[_i]) \
								* _area_warp_factor(_opts[_i], _osrc, _onc)
						_nfa.append(_f)
						if abs(_f - 1.0) > 0.01:
							_changed = true
					if _changed:
						if not _g.ModMapData.has("_ft_width_warp"):
							_g.ModMapData["_ft_width_warp"] = {}
						var _sfr = _polyline_arc_fractions(_newpts, _wloop)
						_g.ModMapData["_ft_width_warp"][_wkey] = {
							"fr": _sfr,
							"fa": _nfa,
							"cl": _wloop,
						}
			if _w.has_method("RemakeLines"):
				_w.RemakeLines()
			_rebuild_wall_width_curves(_w)
			if _dsw != null and _dsw.has_method("_snapshot_wall"):
				wall_entries_after.append({
					"wall": _w,
					"snap": _dsw._snapshot_wall(_w),
					"portal_scales": _capture_portal_scales(_w),
					"width_warp": _ft_width_profile_copy(_w),
				})

	# Build the post-state list for the unified snapshot.
	var nodes_for_after: Array = []
	for st in _drag_states:
		if is_instance_valid(st.node):
			nodes_for_after.append(st.node)
	var unified_after = _capture_ft_unified(nodes_for_after)
	
	if _undo_skip_dd_record:
		# All-regular-objects path: push our single unified record.
		# DD's record was deliberately skipped at start_handle_drag.
		# Avec des walls : record combiné (état FT + walls) → UN Ctrl+Z.
		_record_ft_with_walls(_undo_unified_before, unified_after,
				_wall_drag_before, wall_entries_after)
	else:
		# Mixed-selection path: DD captures the standard transforms via
		# RecordTransforms, we push an extras-only record alongside.
		# That still produces two history records — the user needs two
		# Ctrl+Z — but at least both halves are restored cleanly. Future
		# work: extend the unified path to cover patterns/paths/portals.
		# Les walls dragués sont inclus dans notre moitié du record.
		if _select_tool != null:
			_select_tool.call("RecordTransforms")
		_record_ft_with_walls(_undo_unified_before, unified_after,
				_wall_drag_before, wall_entries_after)
	_undo_unified_before = {}
	_undo_skip_dd_record = false
	_drag_states.clear()
	_group_warp_corners = []
	_wall_drag_active = false
	_wall_drag_walls = []
	_wall_drag_snaps = {}
	_wall_drag_before = []
	_wall_drag_corners = {}
	_wall_drag_wprofile = {}
	_wall_drag_childpts = {}
	_wall_drag_childfr = {}
	_wall_drag_lastnc = {}
	_width_applied_sig = {}
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
	# Freestanding portals (WallID == -1) share the same WallDistance /
	# WallPointIndex defaults, so they would all collapse onto one key and
	# clobber each other's stored rotation. They also don't need the store:
	# nothing re-fits them to a wall, and portal_tool_fix already persists
	# their rotation across save/load. Keep them out entirely.
	if int(wall_id) == -1: return ""
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
	# Inclut les lights : sans elles, l'overlay cesse de se redessiner dès
	# que la sélection est lights-only — le DERNIER dessin (box verte)
	# reste alors gelé à l'écran après désélection ou FT off. Avec elles,
	# need retombe à false à la désélection et le _was_drawing du script
	# overlay déclenche l'update() de nettoyage.
	return _enabled and (_selected_objects.size() > 0 \
			or _walls_in_selection.size() > 0 or _lights_in_selection.size() > 0)

func _draw_overlay(overlay: Node2D) -> void:
	if not _enabled: return
	if _viewport_path.is_empty(): return
	var tree = _g.World.get_tree()
	if not _is_select_tool_active(tree): return
	# Pendant une drag box DD (marquee), la sélection live entre/sort des
	# assets à chaque frame → la box verte clignoterait. On la masque
	# jusqu'au relâchement. (isDrawing : champ C# privé mais exposé par
	# Mono — même accès que DragSelectWalls.)
	if _select_tool != null and _select_tool.isDrawing: return
	var walls_selected = _walls_in_selection.size() > 0
	var lights_selected = _lights_in_selection.size() > 0
	if _selected_objects.size() == 0 and not walls_selected and not lights_selected: return
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

	# ── Edge Crop / Blur : cadre simple + label (pas de handles, mode paramétrique) ──
	if (_transform_mode == "edgecrop" or _transform_mode == "blur") and _selected_objects.size() == 1 \
			and _is_plain_prop(_selected_objects[0]):
		var ndx = _selected_objects[0]
		if is_instance_valid(ndx):
			var ce = _prop_corners(ndx)
			overlay.draw_line(ce[0], ce[1], BOX_COL, lw)
			overlay.draw_line(ce[1], ce[2], BOX_COL, lw)
			overlay.draw_line(ce[2], ce[3], BOX_COL, lw)
			overlay.draw_line(ce[3], ce[0], BOX_COL, lw)
			# Blur: motion direction arrow through the centre (world angle).
			if _transform_mode == "blur":
				var bp = _blur_params(ndx)
				if bp["m"] > 0.0:
					var bc = (ce[0] + ce[1] + ce[2] + ce[3]) * 0.25
					var bd = _blur_world_dir(bp["a"])
					var bl = max(bp["m"] * 0.5, 20.0 / zoom)
					var b0 = bc - bd * bl
					var b1 = bc + bd * bl
					overlay.draw_line(b0, b1, BOX_COL, lw)
					var ah = 8.0 / sqrt(zoom)
					overlay.draw_line(b1, b1 - bd.rotated(0.5) * ah, BOX_COL, lw)
					overlay.draw_line(b1, b1 - bd.rotated(-0.5) * ah, BOX_COL, lw)
			var bb_e = _selection_aabb()
			if bb_e.size.length() > 1.0:
				var font_e : Font = null
				if _toggle_btn != null and is_instance_valid(_toggle_btn):
					font_e = _toggle_btn.get_font("font")
				if font_e != null:
					var elabel = "BLUR" if _transform_mode == "blur" else "EDGE CROP"
					var twe = font_e.get_string_size(elabel).x / zoom
					var fse = 1.4 / sqrt(zoom)
					var fpe = Vector2(bb_e.position.x + bb_e.size.x * 0.5 - (twe * fse * 0.5),
						bb_e.position.y - 18.0 / sqrt(zoom))
					overlay.draw_set_transform(fpe, 0.0, Vector2(fse, fse))
					overlay.draw_string(font_e, Vector2.ZERO, elabel, Color(1.0, 1.0, 1.0, 0.95), -1)
					overlay.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		return

	# ── Cadre ────────────────────────────────────────────────────────────
	# Sélection walls-only : _selected_objects est vide, on tombe dans la
	# branche multi ci-dessous qui trace le rect de _selection_aabb()
	# (walls inclus) ; les handles bbox portent move/rotate/scale.
	if _selected_objects.size() == 1 and not walls_selected:
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
		"edgecrop", "blur":
			return []                    # paramétrique (sliders), cadre inerte
		_:  # "free"
			return [0, 1, 2, 3, 4, 5, 6, 7]


# Applique la transformation affine pour les modes skew / distort / perspective.
# Travaille en coordonnées monde à partir des coins initiaux stockés dans drag state.
func _update_transform_mode(wp: Vector2) -> void:
	if _drag_states.empty() and not _wall_drag_active: return

	# ── Coins du groupe de référence au début du drag ──────────────────────
	# Pour single : coins réels du node.
	# Pour multi  : coins de la group_bbox (axe-aligned rectangle).
	var gc: Array  # [TL, TR, BR, BL] groupe monde au début du drag
	if _drag_states.size() == 1 and not _wall_drag_active:
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
				# Path : vrai warp bilinéaire des EditPoints (monde), du quad
				# source (coins au début du drag) vers le quad warpé. Pas de
				# shader — la texture suit la courbe. Tout est baké dans les
				# points, les drags successifs composent naturellement.
				_apply_distort_path(st, nc)
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

	# ── Walls : warp bilinéaire des Points + portals ─────────────────────
	# Le skew (affine) est un cas particulier du warp — un seul chemin
	# couvre skew, distort et perspective. RemakeLines différé au commit ;
	# les Line2D enfants sont warpées point à point pour le retour visuel.
	if _wall_drag_active:
		for w in _wall_drag_walls:
			if not is_instance_valid(w) or not _wall_drag_snaps.has(w):
				continue
			var w_src = _wall_drag_corners.get(w)
			if w_src == null or w_src.size() != 4:
				continue
			# Coins du wall mappés dans le groupe warpé (identité si le
			# wall est seul : ses coins == gc).
			var w_nc = _map_node_corners_to_group(w_src, gc, new_gc)
			_wall_drag_lastnc[w] = w_nc
			_apply_warp_to_wall(w, _wall_drag_snaps[w], w_src, w_nc)


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
		# Lights : self-heal des entrées ROTATION-PURE (det > 0, colonnes
		# orthonormées) — produites par la composition de deux symétries
		# (H puis V = R(180°)) dans d'anciennes sessions. Une rotation
		# pure est entièrement représentable par position + rotation DD :
		# l'entrée est inutile, et NUISIBLE — l'heuristique ident du
		# repli FT-OFF snap le node en arrière dès que la rotation
		# native fait traverser 0° à la base (blocage à 360°). Purge.
		if _is_light(nd):
			var slx = Vector2(d.xx, d.xy)
			var sly = Vector2(d.yx, d.yy)
			if (slx.x * sly.y - slx.y * sly.x) > 0.0 \
					and abs(slx.length() - 1.0) < 0.001 \
					and abs(sly.length() - 1.0) < 0.001 \
					and abs(slx.dot(sly)) < 0.001:
				dead_keys.append(key)
				continue
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
			# Lights : au chargement de map, DD recrée la light avec la
			# rotation DÉCOMPOSÉE de la base miroir (SaveLight ne persiste
			# pas le scale) — base courante = rotation pure R(θdec) avec
			# θdec = atan2 de la colonne x stockée. Dans ce cas précis,
			# restaure la base miroir stockée. Toute autre base (rotation
			# native vers un autre angle, resize) suit le repli standard.
			if _is_light(nd):
				var lcx = Vector2(cur.x.x, cur.x.y)
				var lcy = Vector2(cur.y.x, cur.y.y)
				var cur_rot_pure = abs(lcx.length() - 1.0) < 0.001 \
						and abs(lcy.length() - 1.0) < 0.001 \
						and abs(lcx.dot(lcy)) < 0.001 \
						and (lcx.x * lcy.y - lcx.y * lcy.x) > 0.0
				var drot = atan2(d.xy, d.xx)
				var crot = atan2(cur.x.y, cur.x.x)
				if cur_rot_pure and abs(wrapf(crot - drot, -PI, PI)) < 0.01:
					nd.transform = Transform2D(
						Vector2(d.xx, d.xy),
						Vector2(d.yx, d.yy),
						nd.position
					)
					d.ox = nd.position.x
					d.oy = nd.position.y
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
		# Auto-réparation : une base stockée qui est une ROTATION PURE
		# (colonnes orthonormées, det ≈ +1, non identité) sur un pattern
		# n'est jamais un état FT légitime (les entrées légitimes portent
		# du shear ou du scale — flips are now baked into the distort
		# corners, never into the basis). C'est un artefact de
		# l'ancien bug "bande de rotation sur pattern" : on purge
		# l'entrée et on remet la base à l'identité pour libérer le
		# pattern (il redevient déplaçable/éditable normalement).
		if _is_pattern(nd):
			var cx = Vector2(d.xx, d.xy)
			var cy = Vector2(d.yx, d.yy)
			var det = cx.x * cy.y - cx.y * cy.x
			var is_ident = abs(d.xx - 1.0) < 0.001 and abs(d.xy) < 0.001 \
					and abs(d.yx) < 0.001 and abs(d.yy - 1.0) < 0.001
			# EXCEPTION : diag(-1,-1) (rotation 180° exacte) est un état FT
			# LÉGITIME — c'est la composition de deux symétries d'axes
			# différents (H puis V). La purger téléportait le pattern loin
			# (base identité + origin (2cx, 2cy) hérité des réflexions).
			var is_180 = abs(d.xx + 1.0) < 0.001 and abs(d.xy) < 0.001 \
					and abs(d.yx) < 0.001 and abs(d.yy + 1.0) < 0.001
			if not is_ident and not is_180 and abs(cx.length() - 1.0) < 0.001 \
					and abs(cy.length() - 1.0) < 0.001 \
					and abs(cx.dot(cy)) < 0.001 and det > 0.0:
				print("[FreeTransform] Pattern : base rotation-pure purgée (artefact), node libéré")
				nd.transform = Transform2D(Vector2(1, 0), Vector2(0, 1), nd.position)
				dead_keys.append(key)
				continue
			# Legacy repair: a REFLECTED basis (det < 0) stored on a
			# pattern comes from the old symmetry implementation (maps
			# saved before the fix). Fold it ONCE into the geometry
			# (mirrored appearance preserved) then purge the entry —
			# symmetries now live in the distort corners.
			if det < 0.0:
				nd.transform = Transform2D(
					Vector2(d.xx, d.xy),
					Vector2(d.yx, d.yy),
					Vector2(d.ox, d.oy)
				)
				if _has_distort_corners(nd):
					_soft_bake_pattern(nd)
				else:
					_bake_pattern_state(nd)
				print("[FreeTransform] Pattern: legacy reflected basis baked into geometry, entry purged")
				dead_keys.append(key)
				continue
		# Pour les patterns, DD peut reset la position — on utilise la
		# position stockée quand FT est ACTIF (FT gère alors les moves via
		# IDX_MOVE qui synchronise le store).
		# FT OFF : même logique de REPLI que les autres assets. Écraser la
		# base à chaque frame ferait la guerre à DD pendant un
		# rotate/resize natif : DD calcule la position pour SA base, nous
		# remettons la nôtre, et la position dérive à chaque frame (le
		# pattern s'éloigne de la box). On ne touche donc PAS au node
		# pendant une édition native — on replie sa base dans le store —
		# et on ne restaure que sur la signature d'un reset DD (base
		# identité ; position seulement si remise à zéro).
		var origin = nd.position
		if _is_pattern(nd):
			if _enabled:
				origin = Vector2(d.ox, d.oy)
				nd.position = origin
			else:
				var curp = nd.transform
				var identp = abs(curp.x.x - 1.0) < 0.001 and abs(curp.x.y) < 0.001 \
						and abs(curp.y.x) < 0.001 and abs(curp.y.y - 1.0) < 0.001
				var samep = abs(curp.x.x - d.xx) < 0.0001 and abs(curp.x.y - d.xy) < 0.0001 \
						and abs(curp.y.x - d.yx) < 0.0001 and abs(curp.y.y - d.yy) < 0.0001
				if samep:
					# Base inchangée : seul un move natif a pu avoir lieu →
					# replie la position et ne touche à rien.
					d.ox = curp.origin.x
					d.oy = curp.origin.y
					continue
				if not identp:
					# Rotate/resize natif en cours → replie la base
					# complète dans le store, node laissé à DD.
					d.xx = curp.x.x; d.xy = curp.x.y
					d.yx = curp.y.x; d.yy = curp.y.y
					d.ox = curp.origin.x; d.oy = curp.origin.y
					continue
				# Base identité = reset DD → restaure la base stockée ;
				# position restaurée seulement si elle a été remise à zéro.
				if nd.position == Vector2.ZERO \
						and Vector2(d.ox, d.oy) != Vector2.ZERO:
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
	var main = _get_sprite_node(node)
	# L'ombre vanilla se distingue par show_behind_parent (Prop._EnterTree la
	# crée ainsi). Les sprites d'ombre des mods tiers sont eux aussi enfants du
	# Prop — DropShadowObjects place le sien en child 0 avec
	# show_behind_parent = false — donc un simple get_child(0) attrapait le
	# mauvais nœud : FT écrasait le material du mod et laissait l'ombre vanilla
	# non déformée.
	for i in range(node.get_child_count()):
		var ch = node.get_child(i)
		if ch == null or not (ch is Sprite) or ch == main:
			continue
		if ch.show_behind_parent:
			return ch
	return null


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

	# Auto-réparation : l'ancien soft bake transformait le working original
	# (_ft_pattern_orig), corrompant la fenêtre d'échantillonnage texture et
	# la paramétrisation (u,v) — et cette corruption PERSISTE en JSON via
	# _save_ft_data. _ft_pattern_reset (jamais touché par le soft bake) est
	# la référence sûre : si le working diverge du reset, on le restaure.
	# Effet de bord assumé : un pattern hard-baké puis re-skewé retrouve la
	# fenêtre texture d'origine (densité restaurée) — jamais de garbling.
	if _dbg_key != "" and _g.ModMapData.has("_ft_pattern_reset") \
			and _g.ModMapData["_ft_pattern_reset"].has(_dbg_key):
		var rflat = _g.ModMapData["_ft_pattern_reset"][_dbg_key]
		if rflat is Array and rflat.size() >= 6:
			var diverged = orig.size() * 2 != rflat.size()
			if not diverged:
				for i in range(orig.size()):
					if abs(orig[i].x - rflat[i * 2]) > 1.0 \
							or abs(orig[i].y - rflat[i * 2 + 1]) > 1.0:
						diverged = true
						break
			if diverged:
				_g.ModMapData["_ft_pattern_orig"][_dbg_key] = rflat.duplicate()
				orig = []
				for i in range(0, rflat.size(), 2):
					orig.append(Vector2(rflat[i], rflat[i + 1]))

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
	# A blur-only material (DD's pattern shader + blur, no warp corners) must
	# be replaced by the warp shader (which carries the blur too).
	if not need_shader and not (node.material is ShaderMaterial and node.material.has_meta("_ft_warp")):
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
		var _pcode = PATTERN_DISTORT_SHADER_CUSTOM_COLOR_SRC if has_custom_color else PATTERN_DISTORT_SHADER_SRC
		var _pblur = _blur_active(node)
		if _pblur:
			var _pbc = _ft_inject_tile_blur(_pcode, ["albedo"])
			if _pbc != "":
				_pcode = _pbc
		sh.code = _pcode
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

		_ft_materials[id] = {"warp": mat, "original": orig_mat, "blur": _pblur, "kind": "pattern"}
		node.material = mat
		_ft_apply_blur_uniforms(node)

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
# Empreinte de la config CMT (Colour and Modify Things) d'un node — "" si
# aucune. Lecture SEULE dans le store partagé de CMT (UchideshiNodeData, écrit
# par son CustomDataManager) : aucun couplage de code, juste ModMapData.
# Sert à détecter une désactivation CMT que sa propre garde ne nettoie pas
# (is_node_using_universal_shader compare l'instance de Shader, et notre
# shader FUSIONNÉ n'est pas la sienne -> CMT ne touche pas au material, donc
# aucun swap n'est observable ; seule sa CONFIG bouge).
func _ft_cmt_data_fingerprint(node) -> String:
	if node == null or not is_instance_valid(node) or not node.has_meta("node_id"):
		return ""
	var store = _g.ModMapData.get("UchideshiNodeData", null)
	if not (store is Dictionary) or not store.has("data"):
		return ""
	var key = "node-id-" + str(node.get_meta("node_id"))
	if not store["data"].has(key):
		return ""
	return JSON.print(store["data"][key])


func _ft_get_merged_warp_shader(src_code: String, with_blur: bool = false):
	# Retourne le Shader warp fusionné pour ce code source (ou null si la
	# fusion échoue). Mis en cache par hash : CMT ne possède que 2-3 shaders
	# distincts (universalshader, colorable_hsl), le cache reste minuscule.
	# with_blur: the blur is injected on top of the merged warp (own cache key).
	var ck = str(src_code.hash()) + "_" + str(src_code.length()) + ("_blur" if with_blur else "")
	if _ft_merged_shader_cache.has(ck):
		return _ft_merged_shader_cache[ck]
	var code = _ft_merge_warp_into_shader(src_code)
	if with_blur and code != "":
		var bcode = _ft_inject_blur(code, "ft_")
		if bcode != "":
			code = bcode
	var sh = null
	if code != "":
		sh = Shader.new()
		sh.code = code
	_ft_merged_shader_cache[ck] = sh
	return sh


func _ft_merge_warp_into_shader(src_code: String) -> String:
	# Injecte le warp bilinéaire FT dans un shader canvas_item étranger.
	# Retourne "" si la structure du shader n'est pas reconnue (le fallback
	# est alors le remplacement classique du material).
	if src_code.find("void fragment") < 0:
		return ""
	var code = src_code

	# ── 1. Header (uniforms + varying + fonctions ft_*) : inséré avant la
	# première déclaration top-level, donc après shader_type/render_mode.
	var ins = -1
	for tok in ["\nuniform ", "\nvarying ", "\nconst ", "\nvoid "]:
		var p = code.find(tok)
		if p >= 0 and (ins < 0 or p < ins):
			ins = p
	if ins < 0:
		var st = code.find("shader_type")
		if st < 0:
			return ""
		ins = code.find(";", st)
		if ins < 0:
			return ""
		ins += 1
	var header = FT_WARP_MERGE_HEADER
	if code.find("void vertex") < 0:
		header += FT_WARP_MERGE_VERTEX_FN
	code = code.insert(ins, "\n" + header + "\n")

	# ── 2. Warp du VERTEX en tête du vertex() existant (le vertex ajouté par
	# le header contient déjà le warp — le garde-fou évite le doublon).
	if code.find("ft_v_local=VERTEX") < 0:
		var vp = code.find("void vertex")
		if vp < 0:
			return ""
		var vb = code.find("{", vp)
		if vb < 0:
			return ""
		code = code.insert(vb + 1, FT_WARP_MERGE_VERTEX_BODY)

	# ── 3. Fragment : remplace chaque lecture de UV par l'UV warpé, calculé
	# une seule fois. \bUV\b ne touche ni SCREEN_UV ni world_uv/path_uv/etc.
	var fp = code.find("void fragment")
	if fp < 0:
		return ""
	var fb = code.find("{", fp)
	if fb < 0:
		return ""
	var fe = _ft_find_matching_brace(code, fb)
	if fe < 0:
		return ""
	var body = code.substr(fb + 1, fe - fb - 1)
	var rx = RegEx.new()
	if rx.compile("\\bUV\\b") != OK:
		return ""
	body = rx.sub(body, "ft_uv", true)
	body = "\n\tvec2 ft_uv=ft_warp_uv(ft_v_local);" + body
	return code.substr(0, fb + 1) + body + code.substr(fe, code.length() - fe)


func _ft_find_matching_brace(code: String, open_idx: int) -> int:
	# Index de l'accolade fermante correspondante, en ignorant les
	# commentaires // et /* */. -1 si non trouvée.
	var depth = 0
	var i = open_idx
	var n = code.length()
	while i < n:
		var c = code[i]
		if c == "/" and i + 1 < n and code[i + 1] == "/":
			var nl = code.find("\n", i)
			if nl < 0:
				return -1
			i = nl + 1
			continue
		if c == "/" and i + 1 < n and code[i + 1] == "*":
			var ce = code.find("*/", i + 2)
			if ce < 0:
				return -1
			i = ce + 2
			continue
		if c == "{":
			depth += 1
		elif c == "}":
			depth -= 1
			if depth == 0:
				return i
		i += 1
	return -1


func _ft_copy_shader_params(src_mat, dst_mat) -> void:
	# Recopie tous les uniforms explicitement définis du material source vers
	# le material fusionné (les non-définis gardent les défauts du shader,
	# conservés à l'identique dans le code fusionné).
	if src_mat == null or dst_mat == null or not (src_mat is ShaderMaterial):
		return
	if src_mat.shader == null:
		return
	var plist = VisualServer.shader_get_param_list(src_mat.shader.get_rid())
	for p in plist:
		var pname = str(p.get("name", ""))
		if pname == "":
			continue
		if pname.begins_with("shader_param/"):
			pname = pname.substr(13, pname.length() - 13)
		if pname.begins_with("ft_"):
			continue
		var v = src_mat.get_shader_param(pname)
		if v != null:
			dst_mat.set_shader_param(pname, v)


func _apply_distort_shader(node: Node2D, world_corners: Array, shader_corners = null, blur_only: bool = false) -> void:
	# blur_only: installs the same material with IDENTITY corners (the warp
	# is then a no-op, only the blur acts). Nothing is stored in _ft_distort
	# and crop / edge crop are left alone (the blur composes with them).
	var _ck = _ft_node_key(node)
	if not blur_only:
		# Crop et distort sont mutuellement exclusifs sur un même node.
		if _ck != "" and _g.ModMapData.has("_ft_crop") and _g.ModMapData["_ft_crop"].has(_ck):
			_remove_crop(node)
		_remove_edgecrop(node)
	var sprite = _get_sprite_node(node)
	if sprite == null: return
	var _blur_on = _blur_active(node)

	var lc = []
	if blur_only:
		# Identity corners = the Sprite rect in vertex space (+-real/2).
		var _bt = sprite.get("texture")
		var _brr = sprite.get("region_rect")
		var _bw = 128.0
		var _bh = 128.0
		if _bt != null and _brr is Rect2 and _brr.size.length() > 0.0:
			_bw = _brr.size.x; _bh = _brr.size.y
		elif _bt != null:
			_bw = _bt.get_size().x; _bh = _bt.get_size().y
		lc = [Vector2(-_bw * 0.5, -_bh * 0.5), Vector2(_bw * 0.5, -_bh * 0.5),
			Vector2(_bw * 0.5, _bh * 0.5), Vector2(-_bw * 0.5, _bh * 0.5)]
	elif shader_corners is Array and shader_corners.size() == 4:
		# Coins DÉJÀ en espace shader (±real/2), tels que stockés dans
		# _ft_distort : réinstallation directe, AUCUNE reconversion. La
		# reconversion monde→local→ratio de padding n'est PAS un aller-retour
		# exact (elle re-multiplie par real/(real+48)) : chaque passage
		# rétrécissait les coins stockés — visible en boucle dès qu'un rebuild
		# était déclenché (ex. swap de material par le highlight de survol).
		lc = shader_corners
	else:
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
		# (ne pas sauvegarder notre propre shader si on re-installe pour un autre
		# mode — mais on récupère l'original qu'il avait mémorisé, ex. le
		# material CMT, pour ne pas le perdre)
		if original_mat is ShaderMaterial and original_mat.has_meta("_ft_warp") and original_mat.get_meta("_ft_warp") == true:
			original_mat = original_mat.get_meta("_ft_orig_mat") if original_mat.has_meta("_ft_orig_mat") else null

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

		# Compat CMT (Colour and Modify Things) : si le material courant vient
		# de CMT (universalshader → apply_grayscale, colorable_hsl → apply_hsl),
		# on FUSIONNE le warp dans son code au lieu de le remplacer — les
		# réglages couleur/HSL restent visibles pendant distort/perspective/skew.
		var merged_sh = null
		if original_mat is ShaderMaterial and original_mat.shader != null:
			var src_m = original_mat.shader.code
			if ("apply_grayscale" in src_m) or ("apply_hsl" in src_m):
				merged_sh = _ft_get_merged_warp_shader(src_m, _blur_on)

		if merged_sh != null:
			mat.shader = merged_sh
			mat.set_meta("_ft_warp", true)
			mat.set_meta("_ft_merged", true)
			# Recopie tous les uniforms du material CMT (couleurs, HSL, textures…)
			_ft_copy_shader_params(original_mat, mat)
			# Empreinte de la config CMT au moment de la fusion : la boucle de
			# heal la compare pour détecter une désactivation CMT sans swap de
			# material (cf. _ft_cmt_data_fingerprint).
			mat.set_meta("_ft_cmt_fp", _ft_cmt_data_fingerprint(node))
		else:
			var _code = DISTORT_SHADER_CUSTOM_COLOR_SRC if has_custom_color else DISTORT_SHADER_SRC
			if _blur_on:
				var _bcode = _ft_inject_blur(_code, "")
				if _bcode != "":
					_code = _bcode
			sh.code = _code
			mat.shader = sh
			mat.set_meta("_ft_warp", true)

			if has_custom_color:
				mat.set_shader_param("tint_r",        tint_r_val)
				mat.set_shader_param("min_redness",   min_redness)
				mat.set_shader_param("red_tolerance", red_tol)
				mat.set_shader_param("min_saturation",min_sat)

		# Mémorise l'original SUR le mat aussi : si l'entrée _ft_materials est
		# perdue (rebuild après swap CMT), on peut encore retrouver l'original.
		mat.set_meta("_ft_orig_mat", original_mat)

		# UV région : texture réelle (ou region_rect si sprite sheet).
		# Noms préfixés ft_ dans la variante fusionnée (collision-proof).
		var _uvp = "ft_" if merged_sh != null else ""
		var uv_tex = sprite.get("texture")
		var uv_rr  = sprite.get("region_rect")
		if uv_tex != null and uv_rr is Rect2 and uv_rr.size.length() > 0.0:
			var ts = uv_tex.get_size()
			mat.set_shader_param(_uvp + "uv_min", Vector2(uv_rr.position.x / ts.x, uv_rr.position.y / ts.y))
			mat.set_shader_param(_uvp + "uv_max", Vector2((uv_rr.position.x + uv_rr.size.x) / ts.x,
			                                              (uv_rr.position.y + uv_rr.size.y) / ts.y))
		else:
			mat.set_shader_param(_uvp + "uv_min", Vector2.ZERO)
			mat.set_shader_param(_uvp + "uv_max", Vector2.ONE)

		# "blur" = blur requested when this material was built; the restore
		# loops compare it with _blur_active() and rebuild on mismatch.
		_ft_materials[id] = {"warp": mat, "original": original_mat, "blur": _blur_on}
		sprite.material = mat

	var mat = _ft_materials[id]["warp"]
	var _cpfx = "ft_" if (mat is ShaderMaterial and mat.has_meta("_ft_merged")) else ""
	mat.set_shader_param(_cpfx + "corner_tl", lc[0])
	mat.set_shader_param(_cpfx + "corner_tr", lc[1])
	mat.set_shader_param(_cpfx + "corner_br", lc[2])
	mat.set_shader_param(_cpfx + "corner_bl", lc[3])

	# Stocke les coins en local pour persistance entre drags
	if not blur_only:
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
			var _scode = DISTORT_SHADER_SRC.replace(
				"COLOR=texture(TEXTURE,warp_uv(v_local));",
				"COLOR=vec4(0.0,0.0,0.0,texture(TEXTURE,warp_uv(v_local)).a*0.18);")
			if _ft_materials[id].get("blur", false):
				var _sbcode = _ft_inject_blur(_scode, "")
				if _sbcode != "":
					_scode = _sbcode
			ssh.code = _scode
			smat.shader = ssh
			smat.set_meta("_ft_shadow_warp", true)
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

	# Blur uniforms (sprite + shadow) — no-op when the material has no blur.
	_ft_apply_blur_uniforms(node)


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
				if nd.material == expected_mat and _ft_materials[key].get("blur", false) == _blur_active(nd):
					continue  # shader encore en place, état blur inchangé
				if nd.material == expected_mat:
					nd.material = _ft_materials[key].get("original", null)   # blur toggled: rebuild
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
			var sprite = _get_sprite_node(nd)
			if sprite == null: continue
			var mstate = _ft_prop_material_state(nd, sprite, key)
			if mstate != "rebuild":
				continue  # "ok" (in place) or "skip" (transient foreign material)
			# Réinstalle avec les coins stockés TELS QUELS (espace shader) —
			# jamais via la reconversion monde (non idempotente, cf. plus haut).
			_apply_distort_shader(nd, [], lc)
	for key in dead_keys:
		store.erase(key)
		_ft_materials.erase(key)


func _ft_prop_material_state(nd: Node2D, sprite, key: String) -> String:
	# State of the FT material (warp and/or blur) of a prop:
	#   "ok"      our material is on the sprite and up to date (shadow re-synced)
	#   "rebuild" missing, recognised swap (null / CMT / custom color), CMT
	#             config disabled, or blur state changed -> caller rebuilds
	#   "skip"    transient foreign material (DD hover highlight) -> leave it
	if not _ft_materials.has(key):
		return "rebuild"
	var ent = _ft_materials[key]
	var cur = sprite.material
	if cur == ent.get("warp"):
		# Shader encore en place. Cas particulier : material FUSIONNÉ dont la
		# config CMT a changé SANS swap — c'est la désactivation CMT, dont la
		# garde échoue sur notre shader fusionné (elle compare les instances
		# de Shader) : CMT ne nettoie pas le material, donc rien à détecter
		# côté swap. L'empreinte de config stockée à la fusion nous le dit ;
		# on repart alors d'un material NU et on rebâtit un warp non fusionné
		# (couleurs d'origine). Les materials d'avant cette version n'ont pas
		# d'empreinte -> comportement inchangé.
		var fp_stale = false
		if cur is ShaderMaterial and cur.has_meta("_ft_merged") and cur.has_meta("_ft_cmt_fp"):
			fp_stale = cur.get_meta("_ft_cmt_fp") != _ft_cmt_data_fingerprint(nd)
		if fp_stale:
			sprite.material = null
			_ft_materials.erase(key)
			return "rebuild"
		# Blur toggled on/off since the build: the shader code must change.
		if ent.get("blur", false) != _blur_active(nd):
			sprite.material = ent.get("original", null)
			_ft_materials.erase(key)
			return "rebuild"
		# Vanilla shadow: a crop unbake / third-party restore may have handed
		# it its original material back while ours is still on the sprite.
		var smat = ent.get("shadow_warp", null)
		if smat is ShaderMaterial:
			var shadow = _get_shadow_sprite(nd)
			if shadow != null and shadow.material != smat:
				_shadow_capture_orig(nd, shadow)
				shadow.material = smat
		return "ok"
	# Le material du sprite n'est plus notre warp. On ne rebâtit que sur un
	# swap RECONNU : null (reset CMT/DD) ou shader CMT / custom color (CMT
	# crée un NOUVEAU ShaderMaterial à chaque changement de réglage). Tout
	# autre material est transitoire — le highlight de survol de DD remplace
	# lui aussi le material et restaure le nôtre de lui-même au unhover ;
	# rebâtir pendant le survol écraserait le highlight et churnait à chaque
	# frame.
	var recognized = (cur == null)
	if not recognized and cur is ShaderMaterial and cur.shader != null:
		var cc = cur.shader.code
		if ("apply_grayscale" in cc) or ("apply_hsl" in cc) or ("tint_r" in cc):
			recognized = true
	if not recognized:
		return "skip"
	_ft_materials.erase(key)
	return "rebuild"


func _ft_drop_prop_material(node: Node2D) -> void:
	# Removes the FT material from the sprite (and the shadow) WITHOUT
	# touching the stores or the textures (a baked crop stays shared with
	# the shadow). The restore loops rebuild whatever is still needed.
	var key = _ft_node_key(node)
	var sprite = _get_sprite_node(node)
	if sprite != null and _ft_materials.has(key):
		sprite.material = _ft_materials[key].get("original", null)
	_ft_materials.erase(key)
	_ft_reset_shadow_material(node)


func _ft_reset_shadow_material(node: Node2D) -> void:
	# Gives the vanilla shadow its original material back (texture untouched:
	# a baked crop may still be sharing it). The capture entry is kept while
	# a crop / edge crop is active so _unbake_crop_texture can restore it.
	var key = _ft_node_key(node)
	var shadow = _get_shadow_sprite(node)
	if shadow == null:
		return
	if _ft_shadow_orig.has(key):
		shadow.material = _ft_shadow_orig[key].get("material", null)
		if not (_has_crop(node) or _has_edgecrop(node)):
			_ft_shadow_orig.erase(key)
	elif shadow.material is ShaderMaterial and shadow.material.has_meta("_ft_shadow_warp"):
		shadow.material = null


# ══ Blur (Gaussian + motion) ══════════════════════════════════════════════════
# Props only. Composes with distort (same material), crop / edge crop (baked
# textures) and the vanilla shadow. See FT_BLUR_HEADER for the shader side.

func _has_blur_entry(node) -> bool:
	var key = _ft_node_key(node)
	if key == "": return false
	return _g.ModMapData.get("_ft_blur", {}).has(key)


func _blur_active(node) -> bool:
	# True when the node needs the blur in its material (r > 0 or m > 0).
	if node == null or not is_instance_valid(node): return false
	if not _g.ModMapData.has("_ft_blur"): return false
	var p = _blur_params(node)
	return p["r"] > 0.0 or p["m"] > 0.0


func _blur_params(node) -> Dictionary:
	var out = {"r": 0.0, "m": 0.0, "a": 0.0}
	var key = _ft_node_key(node)
	if key == "": return out
	var st = _g.ModMapData.get("_ft_blur", {})
	if st.has(key):
		var e = st[key]
		out["r"] = clamp(float(e.get("r", 0.0)), 0.0, BLUR_RADIUS_MAX)
		out["m"] = clamp(float(e.get("m", 0.0)), 0.0, BLUR_MOTION_MAX)
		out["a"] = fmod(float(e.get("a", 0.0)), 360.0)
	return out


func _set_blur(node, r: float, m: float, a: float) -> void:
	# r == 0 and m == 0 -> the entry is removed (no entry = no blur).
	var key = _ft_node_key(node)
	if key == "": return
	r = clamp(r, 0.0, BLUR_RADIUS_MAX)
	m = clamp(m, 0.0, BLUR_MOTION_MAX)
	a = fmod(a, 360.0)
	if not _g.ModMapData.has("_ft_blur"):
		_g.ModMapData["_ft_blur"] = {}
	if r <= 0.0 and m <= 0.0:
		_g.ModMapData["_ft_blur"].erase(key)
	else:
		_g.ModMapData["_ft_blur"][key] = {"r": r, "m": m, "a": a}


func _remove_blur(node: Node2D) -> void:
	if node == null: return
	if not _has_blur_entry(node):
		return
	_g.ModMapData["_ft_blur"].erase(_ft_node_key(node))
	# Drop the material: the restore loops rebuild it (without blur) if a
	# distort is still active, otherwise the node keeps its original one.
	_ft_drop_blur_material(node)


func _ft_drop_blur_material(node: Node2D) -> void:
	match _blur_kind(node):
		"prop":
			_ft_drop_prop_material(node)
		"pattern":
			var key = _ft_node_key(node)
			if _ft_materials.has(key):
				if node.material == _ft_materials[key].get("warp"):
					node.material = _ft_materials[key].get("original", null)
				_ft_materials.erase(key)
		"path":
			_ft_line_restore(node)


func _blur_kind(nd) -> String:
	# "prop" / "pattern" / "path" / "" (not blurrable).
	if nd == null or not is_instance_valid(nd):
		return ""
	if _is_pattern(nd):
		return "pattern"
	if _is_path(nd):
		return "path"
	if _is_plain_prop(nd):
		return "prop"
	return ""   # walls are not supported (no reliable material to hook)


func _blur_target() -> Node2D:
	# One blurrable asset selected: a plain prop, a pattern, a path, or a
	# single wall (walls are not in _selected_objects).
	if _selected_objects.size() == 1 and is_instance_valid(_selected_objects[0]) \
			and _blur_kind(_selected_objects[0]) != "":
		return _selected_objects[0]
	return null


func _blur_world_dir(angle_deg: float) -> Vector2:
	# Screen convention, same as the dial: 0 = right, 90 = down.
	var rad = deg2rad(angle_deg)
	return Vector2(cos(rad), sin(rad))


func _ft_apply_blur_uniforms(node: Node2D) -> void:
	# Pushes the blur uniforms to the node's FT material(s). Cheap enough to
	# call every frame: a signature string skips redundant sets (the motion
	# direction is world-relative, so it follows the node's rotation).
	var key = _ft_node_key(node)
	if key == "" or not _ft_materials.has(key): return
	var ent = _ft_materials[key]
	if not ent.get("blur", false): return
	var kind = ent.get("kind", "prop")
	if kind != "prop":
		_ft_apply_tile_blur_uniforms(node, ent, kind)
		return
	var sprite = _get_sprite_node(node)
	if sprite == null: return
	var p = _blur_params(node)
	# Premultiplied + mipmapped copy of the sprite texture (cached per
	# texture). Follows crop / edge crop bakes since they swap the texture.
	var tex = sprite.get("texture")
	var btex = _ft_blur_get_premul_texture(tex)
	var lod_max = 6.0 if btex != null else 0.0
	var btex_id = btex.get_instance_id() if btex != null else 0
	# TEXTURE uv -> padded copy uv, and how far outside [uv_min,uv_max] the
	# taps may read (only when the sprite uses the whole texture: with a
	# region_rect the padding would expose the neighbouring sprites).
	var uvmap = Color(1.0, 1.0, 0.0, 0.0)
	var pad_uv = Vector2.ZERO
	if btex != null and tex is Texture:
		var ts = tex.get_size()
		var padded = ts + Vector2(2 * FT_BLUR_TEX_PAD, 2 * FT_BLUR_TEX_PAD)
		if ts.x > 0.0 and ts.y > 0.0 and padded.x > 0.0 and padded.y > 0.0:
			uvmap = Color(ts.x / padded.x, ts.y / padded.y,
				FT_BLUR_TEX_PAD / padded.x, FT_BLUR_TEX_PAD / padded.y)
			var rr = sprite.get("region_rect")
			var has_region = sprite.get("region_enabled") == true and rr is Rect2 and rr.size.length() > 0.0
			if not has_region:
				pad_uv = Vector2(FT_BLUR_TEX_PAD / ts.x, FT_BLUR_TEX_PAD / ts.y)
	# World direction -> sprite vertex space (follows node rotation / flip).
	var wd = _blur_world_dir(p["a"])
	var xf = node.global_transform * sprite.transform
	var ld = xf.basis_xform_inv(wd)
	if ld.length() < 0.0001:
		ld = Vector2(1, 0)
	ld = ld.normalized()
	var margin = p["r"] + p["m"] * 0.5 + 2.0
	var sig = "%.3f|%.3f|%.4f|%.4f|%d" % [p["r"], p["m"], ld.x, ld.y, btex_id]
	if ent.get("blur_sig", "") == sig:
		return
	ent["blur_sig"] = sig
	for mkey in ["warp", "shadow_warp"]:
		var m = ent.get(mkey, null)
		if m is ShaderMaterial:
			m.set_shader_param("ft_blur_radius", p["r"])
			m.set_shader_param("ft_blur_motion", p["m"])
			m.set_shader_param("ft_blur_dir", ld)
			m.set_shader_param("ft_blur_margin", Vector2(margin, margin))
			m.set_shader_param("ft_blur_lod_max", lod_max)
			m.set_shader_param("ft_blur_tex", btex)
			m.set_shader_param("ft_blur_has_tex", 1.0 if btex != null else 0.0)
			m.set_shader_param("ft_blur_uvmap", uvmap)
			m.set_shader_param("ft_blur_pad_uv", pad_uv)


func _ft_blur_get_premul_texture(src) -> Texture:
	# Returns (and caches) a premultiplied, mipmapped, transparent-padded
	# copy of src (FT_BLUR_TEX_PAD px per side), or null when its pixels
	# cannot be read back. Done natively by Image (fast).
	if src == null or not (src is Texture):
		return null
	var cid = src.get_instance_id()
	if _ft_blur_tex_cache.has(cid):
		var e = _ft_blur_tex_cache[cid]
		if e["src"].get_ref() == src:
			return e["tex"]
		_ft_blur_tex_cache.erase(cid)
	var img = src.get_data()
	if img == null or img.is_empty():
		print("[FreeTransform] Blur: cannot read texture data (", src, ") — fallback to direct sampling")
		return null
	img = img.duplicate()
	if img.is_compressed():
		if img.decompress() != OK:
			return null
	if img.has_mipmaps():
		img.clear_mipmaps()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	# Transparent padding so border taps never hit the clamped edge column.
	var w = img.get_width()
	var h = img.get_height()
	var padded = Image.new()
	padded.create(w + 2 * FT_BLUR_TEX_PAD, h + 2 * FT_BLUR_TEX_PAD, false, Image.FORMAT_RGBA8)
	padded.fill(Color(0, 0, 0, 0))
	padded.blit_rect(img, Rect2(0, 0, w, h), Vector2(FT_BLUR_TEX_PAD, FT_BLUR_TEX_PAD))
	img = padded
	img.premultiply_alpha()
	img.generate_mipmaps()
	var tex = ImageTexture.new()
	tex.create_from_image(img, Texture.FLAG_MIPMAPS | Texture.FLAG_FILTER)
	# Prune copies whose source texture is gone (baked crops get replaced).
	for k in _ft_blur_tex_cache.keys():
		if _ft_blur_tex_cache[k]["src"].get_ref() == null:
			_ft_blur_tex_cache.erase(k)
	_ft_blur_tex_cache[cid] = {"src": weakref(src), "tex": tex}
	return tex


func _restore_blur_from_store(select_active: bool = true) -> void:
	# Per-frame heal loop (like _restore_distort_from_store): installs the
	# blur material on props that need it, keeps uniforms in sync.
	var store = _g.ModMapData.get("_ft_blur", null)
	if store == null or not (store is Dictionary) or store.empty(): return
	var distort_store = _g.ModMapData.get("_ft_distort", {})
	var dead_keys = []
	for key in store.keys():
		var nd = _ft_node_from_key(key)
		if nd == null or not is_instance_valid(nd):
			dead_keys.append(key)
			continue
		var kind = _blur_kind(nd)
		if kind == "":
			continue
		if not _blur_active(nd):
			dead_keys.append(key)  # zero entry (should not exist) -> prune
			continue
		if kind == "pattern":
			# Same rule as the distort loop: while PatternShapeTool is active
			# DD works on its own material (preview / SetOptions) -- never
			# fight it, the blur comes back on the next Select Tool frame.
			if not select_active:
				continue
			# Distorted: the FT pattern warp carries the blur (distort loop).
			if distort_store.has(key):
				_ft_apply_blur_uniforms(nd)
				continue
			_ft_ensure_pattern_blur(nd, key)
			continue
		if kind == "path":
			_ft_ensure_line_blur(nd, key, kind)
			continue
		if distort_store.has(key):
			# The warp material already carries the blur (injected by
			# _apply_distort_shader, rebuilt by the distort loop on change).
			_ft_apply_blur_uniforms(nd)
			continue
		var sprite = _get_sprite_node(nd)
		if sprite == null: continue
		var mstate = _ft_prop_material_state(nd, sprite, key)
		if mstate == "ok":
			_ft_apply_blur_uniforms(nd)
			continue
		if mstate == "skip":
			continue
		_apply_distort_shader(nd, [], null, true)
	for key in dead_keys:
		store.erase(key)


# ── Blur on patterns, paths and walls (tiled samplers) ───────────────────────

func _ft_blur_get_tiled_texture(src) -> Texture:
	# Mipmapped, premultiplied, REPEATING copy of a tiling texture (no
	# padding: the taps wrap). Cached like the padded copies.
	if src == null or not (src is Texture):
		return null
	var cid = -src.get_instance_id()   # separate cache slot from the padded copy
	if _ft_blur_tex_cache.has(cid):
		var e = _ft_blur_tex_cache[cid]
		if e["src"].get_ref() == src:
			return e["tex"]
		_ft_blur_tex_cache.erase(cid)
	var img = src.get_data()
	if img == null or img.is_empty():
		return null
	img = img.duplicate()
	if img.is_compressed():
		if img.decompress() != OK:
			return null
	if img.has_mipmaps():
		img.clear_mipmaps()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	img.premultiply_alpha()
	img.generate_mipmaps()
	var tex = ImageTexture.new()
	tex.create_from_image(img, Texture.FLAG_REPEAT | Texture.FLAG_FILTER | Texture.FLAG_MIPMAPS)
	for k in _ft_blur_tex_cache.keys():
		if _ft_blur_tex_cache[k]["src"].get_ref() == null:
			_ft_blur_tex_cache.erase(k)
	_ft_blur_tex_cache[cid] = {"src": weakref(src), "tex": tex}
	return tex


func _ft_ensure_pattern_blur(nd: Node2D, key: String) -> void:
	# Blur-only pattern (no distort): DD's own Pattern / PatternCustomColor
	# shader code with the albedo read through the tiled blur.
	if _ft_materials.has(key):
		var ent = _ft_materials[key]
		if nd.material == ent.get("warp") and ent.get("blur", false):
			_ft_apply_blur_uniforms(nd)
			return
		if nd.material == ent.get("warp"):
			nd.material = ent.get("original", null)
		_ft_materials.erase(key)
	var orig = nd.material
	if orig is ShaderMaterial and orig.has_meta("_ft_blur"):
		orig = orig.get_meta("_ft_orig_mat") if orig.has_meta("_ft_orig_mat") else null
	if not (orig is ShaderMaterial) or orig.shader == null:
		return   # plain colour pattern (no texture): nothing to blur
	var code = _ft_inject_tile_blur(orig.shader.code, ["albedo"])
	if code == "":
		return
	var mat = ShaderMaterial.new()
	var sh = Shader.new()
	sh.code = code
	mat.shader = sh
	mat.set_meta("_ft_blur", true)
	mat.set_meta("_ft_orig_mat", orig)
	_ft_copy_shader_params(orig, mat)
	_ft_materials[key] = {"warp": mat, "original": orig, "blur": true, "kind": "pattern"}
	nd.material = mat
	_ft_apply_blur_uniforms(nd)


func _ft_line_nodes(nd: Node2D, _kind: String) -> Array:
	# The CanvasItem carrying the blur material: the path's own Line2D.
	return [nd]


func _ft_ensure_line_blur(nd: Node2D, key: String, kind: String) -> void:
	# Paths: a blur material (default canvas shader + blurred TEXTURE)
	# replaces the null material of the Line2D; re-checked every frame.
	var lines = _ft_line_nodes(nd, kind)
	if lines.empty():
		return
	var ent = _ft_materials.get(key, null)
	if ent != null and not ent.get("blur", false):
		_ft_materials.erase(key)
		ent = null
	if ent == null:
		var orig = lines[0].material
		if orig is ShaderMaterial and orig.has_meta("_ft_blur"):
			orig = orig.get_meta("_ft_orig_mat") if orig.has_meta("_ft_orig_mat") else null
		var code = ""
		if orig is ShaderMaterial and orig.shader != null:
			# A material another mod put on the path: blur its TEXTURE read.
			code = _ft_inject_tile_blur(orig.shader.code, ["TEXTURE"], ["2"])
		else:
			code = FT_BLUR_LINE_SHADER_SRC.replace("{H}", FT_BLUR_TILE_HEADER.replace("{S}", "2"))
		if code == "":
			return
		var mat = ShaderMaterial.new()
		var sh = Shader.new()
		sh.code = code
		mat.shader = sh
		mat.set_meta("_ft_blur", true)
		mat.set_meta("_ft_orig_mat", orig)
		if orig is ShaderMaterial:
			_ft_copy_shader_params(orig, mat)
		ent = {"warp": mat, "original": orig, "blur": true, "kind": kind}
		_ft_materials[key] = ent
	var mat = ent["warp"]
	for ln in lines:
		if ln.material != mat:
			ln.material = mat
	_ft_apply_blur_uniforms(nd)


func _ft_line_restore(nd: Node2D) -> void:
	var key = _ft_node_key(nd)
	if not _ft_materials.has(key):
		return
	var ent = _ft_materials[key]
	for ln in _ft_line_nodes(nd, ent.get("kind", "path")):
		if ln.material == ent.get("warp"):
			ln.material = ent.get("original", null)
	_ft_materials.erase(key)


func _ft_apply_tile_blur_uniforms(node: Node2D, ent: Dictionary, kind: String) -> void:
	var mat = ent.get("warp")
	if not (mat is ShaderMaterial):
		return
	var p = _blur_params(node)
	var wd = _blur_world_dir(p["a"])
	# World direction -> the node's local space (patterns / walls sample in
	# local px; a path's line texture runs along the path, see below).
	var ld = node.global_transform.basis_xform_inv(wd)
	if ld.length() < 0.0001:
		ld = Vector2(1, 0)
	ld = ld.normalized()
	var sig = ""
	if kind == "pattern":
		# Pattern.shader: uv = rotate_uv(VERTEX / size, rotation) -- same
		# rotation for the direction (albedo texel = 1 local px).
		var rot = 0.0
		var rv = mat.get_shader_param("rotation")
		if rv != null:
			rot = float(rv)
		var dr = Vector2(cos(rot) * ld.x + sin(rot) * ld.y, cos(rot) * ld.y - sin(rot) * ld.x)
		var albedo = mat.get_shader_param("albedo")
		var btex = _ft_blur_get_tiled_texture(albedo)
		var bid = btex.get_instance_id() if btex != null else 0
		sig = "%.3f|%.3f|%.4f|%.4f|%d" % [p["r"], p["m"], dr.x, dr.y, bid]
		if ent.get("blur_sig", "") == sig:
			return
		ent["blur_sig"] = sig
		mat.set_shader_param("ft_blur_radius", p["r"])
		mat.set_shader_param("ft_blur_motion", p["m"])
		mat.set_shader_param("ft_blur_dir", dr)
		mat.set_shader_param("ft_blur_px_scale", 1.0)
		mat.set_shader_param("ft_blur_tex", btex)
		mat.set_shader_param("ft_blur_has_tex", 1.0 if btex != null else 0.0)
		mat.set_shader_param("ft_blur_lod_max", 6.0 if btex != null else 0.0)
		return
	# Path (Line2D texture, instance "2"): tile mode maps one texture height
	# onto the line width, so texels per world px = tex_h / width. u runs
	# along the path, v across: the dial angle is taken RELATIVE to the path
	# (0 = along, 90 = across).
	var lines = _ft_line_nodes(node, kind)
	if lines.empty() or not (lines[0] is Line2D):
		return
	var ln = lines[0]
	var ltex = ln.texture
	var width = max(float(ln.width), 1.0)
	var pxs2 = 1.0
	if ltex is Texture and ltex.get_height() > 0:
		pxs2 = float(ltex.get_height()) / width
	var btex2 = _ft_blur_get_tiled_texture(ltex)
	var bid2 = btex2.get_instance_id() if btex2 != null else 0
	var ang = deg2rad(p["a"])
	var d2 = Vector2(cos(ang), sin(ang))
	sig = "%.3f|%.3f|%.4f|%.4f|%.4f|%d" % [p["r"], p["m"], d2.x, d2.y, pxs2, bid2]
	if ent.get("blur_sig", "") == sig:
		return
	ent["blur_sig"] = sig
	mat.set_shader_param("ft_blur_radius2", p["r"])
	mat.set_shader_param("ft_blur_motion2", p["m"])
	mat.set_shader_param("ft_blur_dir2", d2)
	mat.set_shader_param("ft_blur_px_scale2", pxs2)
	mat.set_shader_param("ft_blur_vclamp2", Vector2(0.0, 1.0))
	mat.set_shader_param("ft_blur_tex2", btex2)
	mat.set_shader_param("ft_blur_has_tex2", 1.0 if btex2 != null else 0.0)
	mat.set_shader_param("ft_blur_lod_max2", 6.0 if btex2 != null else 0.0)


# ── Blur widget (radius / motion / angle + Copy / Paste) ─────────────────────

func _update_blur_ui() -> void:
	if _blur_r_row == null or not is_instance_valid(_blur_r_row):
		return
	var show = _enabled and not _widget_force_hidden and _transform_mode == "blur" \
			and _blur_target() != null
	var rows = [_blur_r_row, _blur_m_row, _blur_tools_row]
	for row in rows:
		if row != null and is_instance_valid(row):
			row.visible = show
	if not show:
		return
	# Rows go in gi+1 .. gi+4 right under the Free Transform line.
	var parent = _blur_r_row.get_parent()
	if parent != null and _ui_group != null and is_instance_valid(_ui_group) \
			and _ui_group.get_parent() == parent:
		var gi = _ui_group.get_index()
		for i in range(rows.size()):
			var row = rows[i]
			if row != null and is_instance_valid(row) and row.get_index() != gi + 1 + i:
				parent.move_child(row, gi + 1 + i)
	if _blur_paste_btn != null and is_instance_valid(_blur_paste_btn):
		_blur_paste_btn.disabled = _blur_clip.empty()
	var p = _blur_params(_blur_target())
	_blur_syncing = true
	_blur_sync_controls(_blur_r_slider, _blur_r_spin, p["r"])
	_blur_sync_controls(null, _blur_m_spin, p["m"])
	_blur_sync_controls(null, _blur_a_spin, p["a"])
	_blur_syncing = false
	_blur_sync_dial(p["m"], p["a"])


func _blur_sync_controls(sld, spin, v: float) -> void:
	if sld != null and is_instance_valid(sld) and abs(sld.value - v) > 0.001:
		sld.value = v
	if spin != null and is_instance_valid(spin) and abs(spin.value - v) > 0.001:
		spin.value = v


func _on_blur_r_changed(value) -> void:
	if _blur_syncing: return
	_blur_syncing = true
	_blur_sync_controls(_blur_r_slider, _blur_r_spin, float(value))
	_blur_syncing = false
	_apply_blur_from_ui()


func _on_blur_m_changed(_value) -> void:
	if _blur_syncing: return
	_blur_sync_dial(float(_blur_m_spin.value), float(_blur_a_spin.value))
	_apply_blur_from_ui()


func _on_blur_a_changed(_value) -> void:
	if _blur_syncing: return
	var snap = _blur_dial.get_meta("snap_angle") if (_blur_dial != null and is_instance_valid(_blur_dial)) else -1.0
	if float(snap) >= 0.0:
		# Angle locked by a snap button: revert manual edits.
		_blur_syncing = true
		_blur_a_spin.value = round(float(snap))
		_blur_syncing = false
		return
	_blur_sync_dial(float(_blur_m_spin.value), float(_blur_a_spin.value))
	_apply_blur_from_ui()


func _apply_blur_from_ui() -> void:
	var nd = _blur_target()
	if nd == null:
		return
	# Capture the state BEFORE the burst (one undo for the whole drag).
	if _blur_before.empty():
		_blur_before = _capture_ft_unified([nd])
		_blur_before_node = nd
	_set_blur(nd, float(_blur_r_slider.value), float(_blur_m_spin.value), float(_blur_a_spin.value))
	_ft_blur_after_change(nd)
	_blur_dirty_ms = OS.get_ticks_msec()


func _ft_blur_after_change(nd: Node2D) -> void:
	# Live update: uniforms when the material already carries the blur,
	# otherwise drop the material and let the restore loops rebuild it
	# (with or without blur) on the next frame.
	var key = _ft_node_key(nd)
	if _blur_active(nd):
		if _ft_materials.has(key) and _ft_materials[key].get("blur", false):
			_ft_apply_blur_uniforms(nd)
		elif _ft_materials.has(key):
			_ft_drop_blur_material(nd)
	else:
		_ft_drop_blur_material(nd)


func _blur_set_and_record(nd: Node2D, r: float, m: float, a: float) -> void:
	# Immediate (non-burst) change: reset / paste.
	var before = _capture_ft_unified([nd])
	_set_blur(nd, r, m, a)
	_blur_syncing = true
	_blur_sync_controls(_blur_r_slider, _blur_r_spin, r)
	_blur_sync_controls(null, _blur_m_spin, m)
	_blur_sync_controls(null, _blur_a_spin, a)
	_blur_syncing = false
	_blur_sync_dial(m, a)
	_ft_blur_after_change(nd)
	_record_ft_unified_change(before, _capture_ft_unified([nd]))
	_save_ft_data()
	_blur_before = {}
	_blur_before_node = null


func _on_blur_reset_pressed(which: String) -> void:
	var nd = _blur_target()
	if nd == null:
		return
	var p = _blur_params(nd)
	if which == "r":
		p["r"] = 0.0
	elif which == "m":
		p["m"] = 0.0
	else:
		_blur_deactivate_snaps()
		p["a"] = 0.0
	_blur_set_and_record(nd, p["r"], p["m"], p["a"])


func _on_blur_copy_pressed() -> void:
	var nd = _blur_target()
	if nd == null:
		return
	_blur_clip = _blur_params(nd)


func _on_blur_paste_pressed() -> void:
	var nd = _blur_target()
	if nd == null or _blur_clip.empty():
		return
	_blur_set_and_record(nd, float(_blur_clip.get("r", 0.0)), float(_blur_clip.get("m", 0.0)),
		float(_blur_clip.get("a", 0.0)))


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
		if key in _tex_swap_keys: continue
		if _ft_external_swap_detected(nd, sprite, key):
			_begin_texture_swap_prompt()
			continue
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


func _ft_external_swap_detected(nd: Node2D, sprite, key: String) -> bool:
	# Vrai si la texture du Sprite a été remplacée de l'extérieur (ex. mod tiers
	# ChangeObjectTexture via SetTexture) : texture courante NON cuite et
	# différente de l'originale mise en cache (crop/edge crop partagent ce cache).
	if key == "" or not _crop_orig_tex.has(key):
		return false
	var cur = sprite.get("texture")
	if cur == null:
		return false
	if cur.has_meta("_ft_crop_baked"):
		return false
	return cur != _crop_orig_tex[key].get("texture", null)


func _ft_swap_is_crop(key) -> bool:
	# Un crop/edge crop est cuit dans la texture : le swap le détruit toujours
	# (géré par le path crop). Le distort, lui, n'est concerné que si la taille
	# de texture change.
	return _g.ModMapData.get("_ft_crop", {}).has(key) or _g.ModMapData.get("_ft_edgecrop", {}).has(key)


func _ft_geo_swap_detected(nd, sprite, key) -> bool:
	# Vrai si un prop avec distort a vu sa texture remplacée de l'extérieur ET que
	# la nouvelle texture a une taille différente (seul cas où le warp se décale).
	if _ft_swap_is_crop(key):
		return false
	if not _ft_geo_tex_ref.has(key):
		return false
	var cur = sprite.get("texture")
	if cur == null or cur.has_meta("_ft_crop_baked"):
		return false
	var ref = _ft_geo_tex_ref[key]
	if cur == ref["texture"]:
		return false
	return _crop_real_size(sprite) != ref["size"]


func _ft_watch_geometric(select_active: bool = true) -> void:
	# Maintient une référence de texture pour chaque prop avec distort et détecte
	# un changement de texture externe. Même taille => le distort se réapplique à
	# l'identique (préservé silencieusement). Taille différente => prompt.
	if not select_active:
		return
	if not _tex_swap_keys.empty():
		return
	if not _g.ModMapData.has("_ft_distort"):
		return
	var trigger = false
	var dead = []
	for key in _g.ModMapData["_ft_distort"].keys():
		if _ft_swap_is_crop(key):
			continue
		var nd = _ft_node_from_key(key)
		if nd == null or not is_instance_valid(nd):
			dead.append(key)
			continue
		if not _is_plain_prop(nd):
			continue
		var sprite = _get_sprite_node(nd)
		if sprite == null:
			continue
		var cur = sprite.texture
		if cur == null or cur.has_meta("_ft_crop_baked"):
			continue
		if not _ft_geo_tex_ref.has(key):
			_ft_geo_tex_ref[key] = {
				"texture": cur, "size": _crop_real_size(sprite),
				"region_enabled": sprite.region_enabled, "region_rect": sprite.region_rect,
			}
			continue
		var ref = _ft_geo_tex_ref[key]
		if cur == ref["texture"]:
			continue
		if _crop_real_size(sprite) == ref["size"]:
			# Même taille : on préserve et on met à jour la référence.
			ref["texture"] = cur
			ref["region_enabled"] = sprite.region_enabled
			ref["region_rect"] = sprite.region_rect
		else:
			trigger = true
	for k in dead:
		_ft_geo_tex_ref.erase(k)
	if trigger:
		_begin_texture_swap_prompt()


func _ft_collect_swapped_keys() -> Array:
	# Recense tous les props (crop ET edge crop) dont la texture vient d'être
	# remplacée de l'extérieur. ChangeObjectTexture traite la multi-sélection en
	# UN seul enregistrement d'historique : on regroupe donc la décision.
	var out = []
	for store_name in ["_ft_crop", "_ft_edgecrop"]:
		if not _g.ModMapData.has(store_name):
			continue
		for key in _g.ModMapData[store_name].keys():
			if key in out:
				continue
			var nd = _ft_node_from_key(key)
			if nd == null or not is_instance_valid(nd):
				continue
			var sprite = _get_sprite_node(nd)
			if sprite == null:
				continue
			if _ft_external_swap_detected(nd, sprite, key):
				out.append(key)
	# Props avec distort : seulement si la taille de texture a changé.
	if _g.ModMapData.has("_ft_distort"):
		for key in _g.ModMapData["_ft_distort"].keys():
			if key in out:
				continue
			var gnd = _ft_node_from_key(key)
			if gnd == null or not is_instance_valid(gnd):
				continue
			var gsprite = _get_sprite_node(gnd)
			if gsprite == null:
				continue
			if _ft_geo_swap_detected(gnd, gsprite, key):
				out.append(key)
	return out


func _ft_dialog_button_outline(btn) -> void:
	# Ajoute un contour blanc de 1 px autour d'un bouton, en conservant le fond
	# du thème quand c'est un StyleBoxFlat (sinon fond transparent).
	if btn == null:
		return
	for st in ["normal", "hover", "pressed", "focus", "disabled"]:
		var sb = btn.get_stylebox(st)
		var nb
		if sb is StyleBoxFlat:
			nb = sb.duplicate()
		else:
			nb = StyleBoxFlat.new()
			nb.bg_color = Color(0, 0, 0, 0)
			nb.content_margin_left = 10
			nb.content_margin_right = 10
			nb.content_margin_top = 4
			nb.content_margin_bottom = 4
		nb.set_border_width_all(1)
		nb.border_color = Color(1, 1, 1, 1)
		btn.add_stylebox_override(st, nb)


func _begin_texture_swap_prompt() -> void:
	# Ouvre une seule boîte de confirmation pour tous les props swappés.
	if not _tex_swap_keys.empty():
		return
	var keys = _ft_collect_swapped_keys()
	if keys.empty():
		return
	_tex_swap_keys = keys
	_tex_swap_confirmed = false
	# Affiche l'asset D'ORIGINE derrière le popup : le mod tiers a déjà posé la
	# nouvelle texture, donc on la mémorise (pour la réappliquer si l'utilisateur
	# confirme) puis on re-cuit le crop sur la texture initiale.
	for k in _tex_swap_keys:
		var nd = _ft_node_from_key(k)
		if nd == null or not is_instance_valid(nd):
			continue
		var sp = _get_sprite_node(nd)
		if sp == null:
			continue
		_tex_swap_new[k] = {
			"texture": sp.texture,
			"region_enabled": sp.region_enabled,
			"region_rect": sp.region_rect,
		}
		if _ft_swap_is_crop(k):
			if _g.ModMapData.has("_ft_edgecrop") and _g.ModMapData["_ft_edgecrop"].has(k):
				_bake_edgecrop_texture(nd)
			else:
				var pts = _load_crop_points(nd)
				if pts.size() >= 3:
					_bake_crop_texture(nd, pts)
		else:
			# Distort : on remet la texture d'origine ; _restore_distort_from_store
			# la ré-habillera automatiquement à la frame suivante.
			var ref = _ft_geo_tex_ref.get(k)
			if ref != null:
				sp.texture = ref["texture"]
				sp.region_enabled = ref.get("region_enabled", false)
				if ref.get("region_rect", null) is Rect2:
					sp.region_rect = ref["region_rect"]
	var dlg = ConfirmationDialog.new()
	dlg.window_title = "Free Transform"
	var n = keys.size()
	if n == 1:
		dlg.dialog_text = "This object has a Free Transform.\nChanging its texture will reset that transform.\n\nReset the transform and keep the new texture?\nCancel to revert the texture change."
	else:
		dlg.dialog_text = "%d objects have a Free Transform.\nChanging their texture will reset those transforms.\n\nReset the transforms and keep the new textures?\nCancel to revert the texture change." % n
	dlg.get_ok().text = "Reset transform"
	dlg.get_cancel().text = "Cancel"
	_ft_dialog_button_outline(dlg.get_ok())
	_ft_dialog_button_outline(dlg.get_cancel())
	dlg.connect("confirmed", self, "_on_tex_swap_confirmed")
	dlg.connect("popup_hide", self, "_on_tex_swap_dialog_hide")
	_tex_swap_dialog = dlg
	# Parentage identique aux autres popups du mod (cf. welcome_popup).
	var windows = _g.Editor.get_node_or_null("Windows") if _g.Editor else null
	if windows != null:
		windows.add_child(dlg)
	elif _g.World != null and is_instance_valid(_g.World):
		_g.World.get_tree().root.add_child(dlg)
	else:
		_tex_swap_keys = []
		_tex_swap_dialog = null
		return
	dlg.popup_centered()


func _on_tex_swap_confirmed() -> void:
	# OK = "Reset crop". NB : AcceptDialog appelle hide() PUIS emit("confirmed"),
	# donc popup_hide arrive AVANT ce signal. On se contente ici de marquer le
	# choix ; la résolution est différée (cf. _on_tex_swap_dialog_hide).
	_tex_swap_confirmed = true


func _on_tex_swap_dialog_hide() -> void:
	# Déclenché sur OK, Cancel, ESC et fermeture. Comme "confirmed" est émis
	# juste APRÈS popup_hide, on diffère d'une frame pour connaître le vrai choix.
	if _tex_swap_resolving:
		return
	_tex_swap_resolving = true
	call_deferred("_resolve_tex_swap")


func _resolve_tex_swap() -> void:
	if _tex_swap_confirmed:
		# Reset : on garde la nouvelle texture et on supprime le FT (crop OU distort/shear).
		for key in _tex_swap_keys:
			var nd = _ft_node_from_key(key)
			if nd != null and is_instance_valid(nd):
				if _ft_swap_is_crop(key):
					_reset_crop_keep_texture(nd, key)
				else:
					_ft_reset_geo_keep_texture(nd, key)
	else:
		# Annulation : retour à la texture (et donc au transform) d'origine.
		_revert_texture_swap()
	for key in _tex_swap_keys:
		_ft_geo_tex_ref.erase(key)
	_tex_swap_keys = []
	_tex_swap_new = {}
	_tex_swap_confirmed = false
	_tex_swap_resolving = false
	if _tex_swap_dialog != null and is_instance_valid(_tex_swap_dialog):
		_tex_swap_dialog.queue_free()
	_tex_swap_dialog = null


func _reset_crop_keep_texture(nd: Node2D, key: String) -> void:
	# Garde la NOUVELLE texture et supprime toute trace de crop/edge crop. Le
	# rendu courant montre l'original re-cuit (cf. _begin_texture_swap_prompt) :
	# on réapplique donc d'abord la nouvelle texture mémorisée.
	var sprite = _get_sprite_node(nd)
	if sprite != null and _tex_swap_new.has(key):
		var nt = _tex_swap_new[key]
		sprite.texture = nt["texture"]
		sprite.region_enabled = nt.get("region_enabled", false)
		if nt.get("region_rect", null) is Rect2:
			sprite.region_rect = nt["region_rect"]
	_tex_swap_new.erase(key)
	for store_name in ["_ft_crop", "_ft_crop_soft", "_ft_crop_feather", "_ft_crop_opacity", "_ft_edgecrop"]:
		if _g.ModMapData.has(store_name):
			_g.ModMapData[store_name].erase(key)
	_crop_orig_tex.erase(key)
	# Ombre vanilla (child 0) : la rattacher à la nouvelle texture pour une
	# silhouette correcte, puis oublier l'état d'origine mémorisé.
	var shadow = _get_shadow_sprite(nd)
	if shadow != null and is_instance_valid(shadow) and sprite != null:
		shadow.region_enabled = sprite.region_enabled
		if sprite.region_rect is Rect2:
			shadow.region_rect = sprite.region_rect
		shadow.texture = sprite.texture
	_ft_shadow_orig.erase(key)
	# Nettoie l'état d'édition si c'était le node crop courant.
	if _crop_node == nd:
		_crop_node = null
		_crop_points = []
		_crop_active_pt = -1


func _ft_reset_geo_keep_texture(nd: Node2D, key: String) -> void:
	# Garde la NOUVELLE texture et remet le prop à son transform vanilla
	# (suppression distort + shear/scale/rotation). Le rendu courant montre
	# l'original : on réapplique d'abord la nouvelle texture mémorisée.
	var sprite = _get_sprite_node(nd)
	if sprite != null and _tex_swap_new.has(key):
		var nt = _tex_swap_new[key]
		sprite.texture = nt["texture"]
		sprite.region_enabled = nt.get("region_enabled", false)
		if nt.get("region_rect", null) is Rect2:
			sprite.region_rect = nt["region_rect"]
	_tex_swap_new.erase(key)
	# Restaure le transform pré-FT si capturé, sinon neutralise.
	var orig = _g.ModMapData.get("_ft_orig_xform", {})
	if orig.has(key):
		var o = orig[key]
		nd.transform = Transform2D(Vector2(o.xx, o.xy), Vector2(o.yx, o.yy), Vector2(o.ox, o.oy))
	else:
		nd.scale = Vector2(1, 1)
		nd.rotation = 0.0
	if _g.ModMapData.has("_ft_orig_xform"):
		_g.ModMapData["_ft_orig_xform"].erase(key)
	_clear_shear_transform(nd)
	_remove_distort_shader(nd)


func _revert_texture_swap() -> void:
	# Le rendu d'origine est déjà affiché (restauré dans _begin_texture_swap_prompt).
	# ChangeObjectTexture crée UN enregistrement d'historique pour toute la
	# (multi)sélection : un seul Undo le défait proprement (pile cohérente).
	var hist = _g.Editor.History if _g.Editor else null
	if hist != null and hist.has_method("Undo"):
		hist.Undo()
	for key in _tex_swap_keys:
		_tex_swap_new.erase(key)
		var nd = _ft_node_from_key(key)
		if nd == null or not is_instance_valid(nd):
			continue
		if _ft_swap_is_crop(key):
			# Re-cuit immédiatement le crop (pas de frame non cropée).
			if _g.ModMapData.has("_ft_edgecrop") and _g.ModMapData["_ft_edgecrop"].has(key):
				_bake_edgecrop_texture(nd)
			else:
				var pts = _load_crop_points(nd)
				if pts.size() >= 3:
					_bake_crop_texture(nd, pts)
		else:
			# Distort : la texture d'origine est revenue (Undo) et reste affichée ;
			# le distort se réapplique automatiquement. Force la texture par sécurité.
			var ref = _ft_geo_tex_ref.get(key)
			var sprite = _get_sprite_node(nd)
			if sprite != null and ref != null:
				sprite.texture = ref["texture"]
				sprite.region_enabled = ref.get("region_enabled", false)
				if ref.get("region_rect", null) is Rect2:
					sprite.region_rect = ref["region_rect"]


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
		if key in _tex_swap_keys: continue
		if _ft_external_swap_detected(nd, sprite, key):
			_begin_texture_swap_prompt()
			continue
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


# ══ Options du menu contextuel, calculees SANS que FT soit actif ═══════════
# Consomme par ft_context.gd pour son sous-menu : lui n'a pas acces a la
# selection FT (_selected_objects n'est peuple que quand FT tourne) ni aux
# regles de disponibilite des modes. Retourne [{label, id}] avec {_sep=true}
# pour les separateurs ; les ids sont ceux de _on_transform_menu_id().
const _FT_TRANSFORM_MARK_KEYS = [
	"_ft_distort", "_ft_crop", "_ft_edgecrop", "_ft_blur", "_ft_transforms", "_ft_orig_xform",
	"_ft_width_warp", "_ft_pattern_orig", "_portal_offsets", "_ft_wall_reset",
	"_ft_path_reset",
]


func get_context_menu_options() -> Array:
	var out := []
	var props := []
	var tree = _g.World.get_tree() if _g.World != null else null
	if tree == null or tree.root == null:
		return out
	var vp = tree.root.get_node_or_null(_viewport_path)
	if vp != null:
		var world = vp.get_node_or_null("World")
		if world != null:
			var fresh : Array = []
			_collect_selected_props(world, fresh, 0)
			if _select_tool != null:
				var sel = _select_tool.get("Selected")
				if sel != null:
					for nd in sel:
						if is_instance_valid(nd) and (_is_pattern(nd) or _is_path(nd)) and not fresh.has(nd):
							fresh.append(nd)
			for nd in fresh:
				if _is_roof(nd) or _is_light(nd):
					continue
				if _is_path(nd):
					props.append(nd)
				elif not (nd is Line2D) and not _is_wall(nd):
					props.append(nd)
	var walls := _selected_walls()
	var lights := _selected_lights()

	if props.empty() and walls.empty():
		# Lights seules : seules les symetries s'appliquent.
		if lights.empty():
			return out
		out.append({label = "Horizontal Symmetry", id = 20})
		out.append({label = "Vertical Symmetry", id = 21})
		return out

	if props.empty():
		# Walls seuls.
		var labels_w = {0: "Scale", 1: "Skew", 2: "Distort", 3: "Perspective"}
		for mid in [0, 1, 2, 3]:
			out.append({label = labels_w[mid], id = mid})
		out.append({_sep = true, label = "", id = -1})
		out.append({label = "Horizontal Symmetry", id = 20})
		out.append({label = "Vertical Symmetry", id = 21})
		if _selection_has_ft_transform(walls):
			out.append({_sep = true, label = "", id = -1})
			out.append({label = "Reset Transform", id = 22})
		return out

	if walls.empty() and _all_portals_in(props):
		out.append({label = "Scale", id = 0})
		out.append({label = "Slide", id = 13})
		out.append({label = "Offset", id = 12})
		out.append({_sep = true, label = "", id = -1})
		out.append({label = "Horizontal Symmetry", id = 20})
		out.append({label = "Vertical Symmetry", id = 21})
		if _selection_has_ft_transform(props):
			out.append({_sep = true, label = "", id = -1})
			out.append({label = "Reset transform", id = 10})
		return out

	var labels = {0: "Scale", 1: "Skew", 2: "Distort", 3: "Perspective", 4: "Crop", 5: "Soft Crop", 6: "Edge Crop", 7: "Blur"}
	var all_paths = true
	var has_path = false
	for nd in props:
		if _is_path(nd):
			has_path = true
		elif is_instance_valid(nd):
			all_paths = false
	if not has_path:
		all_paths = false
	var modes = [0, 1, 2, 3]
	# Crop : un seul prop simple selectionne, comme dans _show_transform_menu_at.
	if not all_paths and props.size() == 1 and _is_plain_prop(props[0]):
		modes = [0, 1, 2, 3, 4, 5, 6, 7]
	elif walls.empty() and props.size() == 1 and _blur_kind(props[0]) != "":
		modes = [0, 1, 2, 3, 7]   # pattern / path: Blur only (no crop)
	for mid in modes:
		if mid == 4 or mid == 7:
			out.append({_sep = true, label = "", id = -1})
		out.append({label = labels[mid], id = mid})
	out.append({_sep = true, label = "", id = -1})
	out.append({label = "Horizontal Symmetry", id = 20})
	out.append({label = "Vertical Symmetry", id = 21})
	var resettable = props.duplicate()
	for w in walls:
		resettable.append(w)
	if _selection_has_ft_transform(resettable):
		out.append({_sep = true, label = "", id = -1})
		out.append({label = "Reset transform", id = 10})
	return out


func _all_portals_in(props: Array) -> bool:
	if props.empty():
		return false
	for nd in props:
		if is_instance_valid(nd) and not _is_portal(nd):
			return false
	return true


# Vrai des qu'un des assets porte une donnee FT persistee : c'est ce que
# Reset defait, donc l'entree n'a de sens que dans ce cas.
func _selection_has_ft_transform(nodes: Array) -> bool:
	if _g == null or _g.ModMapData == null or not (_g.ModMapData is Dictionary):
		return false
	for nd in nodes:
		if nd == null or not is_instance_valid(nd):
			continue
		var key = _ft_node_key(nd)
		if key == "":
			continue
		for store_key in _FT_TRANSFORM_MARK_KEYS:
			var store = _g.ModMapData.get(store_key)
			if store is Dictionary and store.has(key):
				return true
	return false


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

	if _selected_objects.size() == 0 and _walls_in_selection.size() == 0:
		# Sélection lights-only : seules les symétries s'appliquent
		# (position + angle miroir — pas de handles FT sur les lights).
		menu.add_item("Horizontal Symmetry", 20)
		menu.add_item("Vertical Symmetry", 21)
	elif _selected_objects.size() == 0:
		# Sélection walls-only : modes de transformation (Scale via les
		# handles free ; Skew/Distort/Perspective warpent les Points et
		# les portals des walls) + symétries.
		var mode_to_id_w = {"free": 0, "skew": 1, "distort": 2, "perspective": 3}
		var labels_w = {0: "Scale", 1: "Skew", 2: "Distort", 3: "Perspective"}
		var cur_id_w = mode_to_id_w.get(_transform_mode, 0)
		for mid in [0, 1, 2, 3]:
			var prefix_w = "» " if mid == cur_id_w else "  "
			menu.add_item(prefix_w + labels_w[mid], mid)
		menu.add_separator()
		menu.add_item("Horizontal Symmetry", 20)
		menu.add_item("Vertical Symmetry", 21)
		menu.add_separator()
		menu.add_item("Reset Transform", 22)
	elif is_portal_sel:
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
		var mode_to_id = {"free": 0, "skew": 1, "distort": 2, "perspective": 3, "crop": 4, "softcrop": 5, "edgecrop": 6, "blur": 7}
		var cur_id = mode_to_id.get(_transform_mode, 0)
		var labels = {0: "Scale", 1: "Skew", 2: "Distort", 3: "Perspective", 4: "Crop", 5: "Soft Crop", 6: "Edge Crop", 7: "Blur"}
		var has_path = _has_any_path()
		var all_paths = has_path and _all_paths()
		# Distort/Perspective supportés pour les paths (warp des EditPoints)
		var modes = [0, 1, 2, 3]
		# Crop : props simples uniquement (un seul objet sélectionné)
		if not all_paths and _selected_objects.size() == 1 and _is_plain_prop(_selected_objects[0]):
			modes = [0, 1, 2, 3, 4, 5, 6, 7]
		elif _selected_objects.size() == 1 and _blur_kind(_selected_objects[0]) != "":
			modes = [0, 1, 2, 3, 7]   # pattern / path: Blur only (no crop)
		for mid in modes:
			# Les modes Crop forment un bloc a part (ils n'agissent que sur un
			# prop simple) : separateur juste au-dessus. Idem pour Blur.
			if mid == 4 or mid == 7:
				menu.add_separator()
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
		Engine.set_meta("up_ft_popup_layer", layer)
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


func _ft_world_next_id() -> int:
	if _g.World == null or not is_instance_valid(_g.World):
		return -1
	var nid = _g.World.get("nextNodeID")
	return int(nid) if nid != null else -1


func _ft_selection_has_new_nodes(nodes: Array) -> bool:
	# True if any node was created after the lock was taken (see _ft_lock_next_id).
	if _ft_lock_next_id < 0:
		return false
	for nd in nodes:
		if nd == null or not is_instance_valid(nd):
			continue
		if nd.has_meta("node_id") and int(nd.get_meta("node_id")) >= _ft_lock_next_id:
			return true
	return false


func _same_selection(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for nd in a:
		if not (nd in b):
			return false
	return true


# Le PathwayWidget (Line2D pointillée) copie Pathway.Points uniquement dans
# OnChange() (select/highlight) — après un SetEditPoints il affiche les
# anciens points. On force la resynchronisation.
func _refresh_path_widget(nd: Node2D) -> void:
	var pw = nd.get("Widget")
	if pw != null and is_instance_valid(pw) and pw.has_method("OnChange"):
		pw.call("OnChange")


# Lights sélectionnées dans DD (exclues de _selected_objects — FT ne leur
# met pas de handles — mais les symétries du menu doivent les suivre).
# Source : RawSelectables (Type 6 = Light, node dans Thing). Les lights ne
# sont PAS dans SelectTool.Selected, et isSelected est porté par leur
# LightWidget enfant, pas par le Light2D lui-même.
func _selected_lights() -> Array:
	var out := []
	if _select_tool == null:
		return out
	# Accès DIRECT aux membres C# (pattern éprouvé de DragSelectWalls :
	# select_tool.RawSelectables / s.Thing / s.Type — .get() ne résout
	# pas ces membres).
	var raw = _select_tool.RawSelectables
	if raw == null:
		return out
	for sl in raw:
		if sl == null or sl.Thing == null or not is_instance_valid(sl.Thing):
			continue
		# Test structurel (parent = node Lights du level) plutôt que la
		# valeur numérique de l'enum SelectableType, invisible dans le
		# décompilé et donc incertaine.
		if _is_light(sl.Thing):
			out.append(sl.Thing)
	return out


func _flip_selection(horizontal: bool) -> void:
	# Flip immédiat (miroir) de TOUTE la sélection d'un bloc, autour du centre
	# de la transform box. Réversible : ré-appliquer le même flip annule.
	# - Props / patterns / paths : réflexion du global_transform autour du centre
	#   de la box (miroir monde), persistée dans _ft_transforms.
	# - Portals sélectionnés individuellement : flip dans le repère LOCAL (le
	#   node est aligné au mur) en négativant scale.x (H = le long du mur) ou
	#   scale.y (V = perpendiculaire), pour rester collé au mur. abs(scale.x)
	#   sert au Radius → taille inchangée.
	# - Walls sélectionnés : points, enfants visuels et portals attachés sont
	#   miroirés via l'API de DragSelectWalls (_apply_transform_to_wall accepte
	#   un Transform2D quelconque, réflexion incluse). Les portals attachés à
	#   un wall sélectionné sont retirés de flippable : ils sont transformés
	#   PAR le wall (sinon double transformation).
	# Tout est persisté (props via _reapply_shear_transforms, walls via leurs
	# Points C#) et annulable en UNE étape (record combiné).
	var flippable := []
	for nd in _selected_objects:
		if is_instance_valid(nd):
			flippable.append(nd)

	var dsw = _g.ModMapData.get("_drag_select_walls")
	var sel_walls := _selected_walls()
	if sel_walls.size() > 0:
		var wall_ids := {}
		for w in sel_walls:
			if w.has_meta("node_id"):
				wall_ids[int(w.get_meta("node_id"))] = true
		var kept := []
		for nd in flippable:
			if _is_portal(nd) and "WallID" in nd and wall_ids.has(int(nd.WallID)):
				continue
			kept.append(nd)
		flippable = kept

	var sel_lights := _selected_lights()
	if flippable.empty() and sel_walls.empty() and sel_lights.empty():
		return
	var box = _selection_aabb()
	# Étend la box aux walls sélectionnés : le centre du miroir est celui
	# du GROUPE complet, walls inclus.
	if sel_walls.size() > 0 and dsw != null and dsw.has_method("_compute_walls_aabb"):
		var wbox = dsw._compute_walls_aabb(sel_walls)
		if wbox.size != Vector2.ZERO:
			box = wbox if box.size == Vector2.ZERO else box.merge(wbox)
	# Étend la box aux lights sélectionnées (positions ponctuelles).
	var box_empty = box.size == Vector2.ZERO and flippable.empty() and sel_walls.empty()
	for l in sel_lights:
		if not is_instance_valid(l):
			continue
		var lrect = Rect2(l.global_position, Vector2.ZERO)
		if box_empty:
			box = lrect
			box_empty = false
		else:
			box = box.merge(lrect)
	if box.size == Vector2.ZERO and sel_lights.empty():
		return
	var center = box.position + box.size * 0.5

	# Capture AVANT : on s'assure que le transform complet courant est dans
	# _ft_transforms pour que l'undo restaure une réflexion proprement (en
	# Godot 3, pos/rot/scale seuls ne représentent pas un déterminant négatif
	# de façon fiable).
	for nd in flippable:
		_snapshot_orig_xform(nd)
		if _is_pattern(nd):
			# Patterns: NEVER store a basis (a reflected det<0 basis fights
			# both the distort pipeline and DD: _restore_distort_from_store
			# and _apply_distort_pattern assume an IDENTITY basis, and
			# _bake_pattern_state on the next drag destroyed the shape).
			# Prepare the node BEFORE the undo capture instead: fold any
			# existing basis into the geometry + initialize the distort
			# corners (visually identical) — the flip becomes a pure
			# corner mutation, cleanly undoable.
			_invalidate_stale_pattern_data(nd)
			var pt = nd.transform
			var pt_ident = abs(pt.x.x - 1.0) < 0.001 and abs(pt.x.y) < 0.001 \
					and abs(pt.y.x) < 0.001 and abs(pt.y.y - 1.0) < 0.001
			if not pt_ident:
				if _has_distort_corners(nd):
					_soft_bake_pattern(nd)
				else:
					_bake_pattern_state(nd)
			if not _has_distort_corners(nd):
				_apply_distort_pattern(nd, _prop_corners(nd), Array(nd.polygon))
			continue
		_store_shear_transform(nd, nd.transform)
	# Lights incluses dans la capture (restaurées via pos/rot/scale — le
	# modèle DD ne persiste que position + rotation, voir Lights.SaveLight).
	var before = _capture_ft_unified(flippable + sel_lights)

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
		if _is_portal(nd) and not _is_freestanding_portal(nd):
			# Wall-anchored portal : flip LOCAL (reste collé au mur).
			# H → scale.x, V → scale.y. Le Radius utilise abs(scale.x), donc
			# la taille ne change pas. La position n'est PAS miroirée : le
			# portal est piloté par son mur, un miroir monde le décollerait.
			var sc = nd.scale
			if horizontal:
				sc.x = -sc.x
			else:
				sc.y = -sc.y
			nd.scale = sc
		elif _is_path(nd):
			# Paths : bake la réflexion dans les EditPoints au lieu de
			# laisser une base reflétée sur le node. SetEditPoints (C#)
			# suppose une base IDENTITÉ : il pose Position = points[0] et
			# stocke des deltas parent-space — toute rotation/scale/miroir
			# sur le node fausse le rendu ET le undo (points re-projetés
			# avec la mauvaise base). Rotation/scale remis à neutre ;
			# Smooth() est appelé par SetEditPoints, et le watchdog de
			# largeurs réappliquera le profil (signature changée).
			var wpts = _get_path_edit_points_world(nd)
			if wpts.size() > 0:
				var new_pts = []
				for p in wpts:
					new_pts.append(R.xform(p))
				# Une réflexion (det < 0) inverse l'orientation de parcours :
				# le côté intérieur/extérieur de la texture (défini par
				# rapport au sens de parcours : perp(M·t) = −M·perp(t))
				# passerait du mauvais côté. On inverse l'ordre des points
				# pour rétablir le côté monde exact du miroir. NB : les
				# extrémités échangent leur rôle — un fade/grow asymétrique
				# (in ≠ out) change donc d'extrémité (propriétés C# non
				# réassignables sans recharger le path).
				new_pts.invert()
				# Profil de largeur (warp) : les fractions d'arc se
				# mesurent depuis le nouveau départ → f devient 1−f,
				# tableaux réinversés pour rester croissants.
				var wkey = _ft_node_key(nd)
				if wkey != "" and _g.ModMapData.has("_ft_width_warp") \
						and _g.ModMapData["_ft_width_warp"].has(wkey):
					var prof = _g.ModMapData["_ft_width_warp"][wkey]
					if prof != null and prof.has("fr") and prof.has("fa"):
						var nfr = []
						var nfa = []
						for i in range(prof["fr"].size() - 1, -1, -1):
							nfr.append(1.0 - prof["fr"][i])
							nfa.append(prof["fa"][i])
						prof["fr"] = nfr
						prof["fa"] = nfa
						_width_applied_sig.erase(wkey)
				nd.rotation = 0.0
				nd.scale = Vector2.ONE
				nd.call("SetEditPoints", new_pts)
				_refresh_path_widget(nd)
			_clear_shear_transform(nd)
			continue
		elif _is_pattern(nd):
			# Patterns: bake the mirror into the distort pipeline (mirror
			# the world corners + rebuild via _apply_distort_pattern)
			# instead of leaving a reflected basis (det<0) on the node.
			# A reflected basis broke everything: _restore_distort_from_store
			# computes wc = lc + position assuming identity (visual double
			# mirror), _bake_pattern_state on the next drag collapsed the
			# shape to its AABB, and _soft_bake_pattern left the reflected
			# _ft_transforms entry that _reapply_shear_transforms re-imposed
			# on the already-baked geometry (double application → the
			# pattern vanished). The bilinear warp is equivariant under
			# reflections: mirroring the 4 corners mirrors shape AND
			# texture exactly. Reversible: mirroring the corners again
			# cancels out.
			var pat_wc = _prop_corners(nd)
			var pat_new_wc = []
			for pcorner in pat_wc:
				pat_new_wc.append(R.xform(pcorner))
			_apply_distort_pattern(nd, pat_new_wc)
			_clear_shear_transform(nd)
			continue
		else:
			# Miroir monde : la base reflétée (déterminant négatif) produit le
			# miroir.
			nd.global_transform = R * nd.global_transform
		# Persiste la base ; _reapply_shear_transforms la réappliquera chaque
		# frame même si DD reset le scale.
		_store_shear_transform(nd, nd.transform)

	# Walls : miroir des Points, des enfants visuels et des portals via
	# DragSelectWalls. _apply_transform_to_wall détecte une base symétrique
	# (réflexion pure → w_rot = 0) et laisse alors la rotation des portals
	# inchangée ; or le miroir exact d'un angle θ est π−θ (H) ou −θ (V),
	# combiné à un flip local scale.y (une réflexion inverse la chiralité :
	# M·R(θ) = R(π−θ)·diag(1,−1) pour H, R(−θ)·diag(1,−1) pour V). On
	# corrige donc rotation + scale des portals après l'application.
	# Lights : vraie réflexion du transform (comme les props) — Light2D
	# rend sa texture via le transform complet du node, donc position ET
	# orientation/chiralité sont miroirées exactement, quelle que soit
	# l'orientation de base de la texture. L'undo pos/rot/scale reste
	# exact : les bases restent orthogonales (Godot les décompose en
	# rotation + scale.y négatif sans perte). Limite : DD ne sauvegarde
	# que position + rotation pour les lights (Lights.SaveLight), donc
	# la composante miroir de la texture ne survit pas à un save/reload
	# de la map — l'axe du faisceau, lui, est préservé au mieux.
	# Le LightWidget est un enfant : il suit automatiquement.
	for l in sel_lights:
		if not is_instance_valid(l):
			continue
		l.global_transform = R * l.global_transform
		# Persiste la base miroir : DD ne sauvegarde que position +
		# rotation pour les lights (Lights.SaveLight) — au reload la
		# composante miroir serait perdue. Le side-store _ft_transforms
		# (persisté dans la map) la réapplique (cas dédié lights dans
		# _reapply_shear_transforms). EXCEPTION : deux symétries composées
		# donnent une base ROTATION PURE (det > 0) — représentable
		# nativement par DD, donc rien à persister ; une entrée store
		# ferait au contraire boguer la rotation native (snap à 0° via
		# l'heuristique ident du repli). Purge dans ce cas.
		var lt = l.transform
		if (lt.x.x * lt.y.y - lt.x.y * lt.y.x) > 0.0 \
				and abs(lt.x.length() - 1.0) < 0.001 \
				and abs(lt.y.length() - 1.0) < 0.001 \
				and abs(lt.x.dot(lt.y)) < 0.001:
			_clear_shear_transform(l)
		else:
			_store_shear_transform(l, l.transform)

	var wall_entries_before := []
	var wall_entries_after := []
	if sel_walls.size() > 0 and dsw != null and dsw.has_method("_apply_transform_to_wall"):
		for w in sel_walls:
			if not is_instance_valid(w):
				continue
			_store_wall_reset(w)
			var pre = dsw._snapshot_wall(w)
			wall_entries_before.append({
				"wall": w,
				"snap": pre,
				"portal_scales": _capture_portal_scales(w),
				"width_warp": _ft_width_profile_copy(w),
				"shadow_dir": _drop_shadow_dir(w),
			})
			dsw._apply_transform_to_wall(w, pre, R)
			var rot_map = pre.get("portal_rots", {})
			for portal in rot_map:
				if not is_instance_valid(portal):
					continue
				var theta = rot_map[portal]
				portal.rotation = (PI - theta) if horizontal else (-theta)
				var psc = portal.scale
				psc.y = -psc.y
				portal.scale = psc
			if w.has_method("RemakeLines"):
				w.RemakeLines()
			_swap_drop_shadow_side(w)
			wall_entries_after.append({
				"wall": w,
				"snap": dsw._snapshot_wall(w),
				"portal_scales": _capture_portal_scales(w),
				"width_warp": _ft_width_profile_copy(w),
				"shadow_dir": _drop_shadow_dir(w),
			})

	_save_ft_data()
	# Record combiné (props + walls) → UNE seule étape de Ctrl+Z.
	_record_ft_with_walls(before, _capture_ft_unified(flippable + sel_lights),
			wall_entries_before, wall_entries_after)
	_save_ft_data()
	print("[FreeTransform] Symmetry %s appliquée (%d prop(s), %d wall(s), %d light(s))" % [("Horizontal" if horizontal else "Vertical"), flippable.size(), sel_walls.size(), sel_lights.size()])


# Le mod tiers Drop Shadow (DropShadowWalls.gd) choisit le côté de son ombre
# à partir de la normale gauche des points du wall — perp(dir) = (−dir.y,
# dir.x). Une réflexion inverse la chiralité : à ordre de points identique,
# cette normale désigne désormais le côté OPPOSÉ, donc l'ombre saute de
# l'autre côté alors que le bouton affiche toujours Side A.
#
# Les paths n'ont pas ce problème : leur miroir inverse déjà l'ordre des
# points (voir plus haut) pour préserver le côté monde. On ne peut pas faire
# pareil sur un wall — les portails attachés indexent les segments via
# WallPointIndex / WallDistance, qu'une inversion invaliderait. On échange
# donc le côté stocké, ce qui revient au même visuellement : le bouton
# bascule sur Side B, ce qu'il décrit honnêtement puisque le côté a bien
# changé dans le repère du mur.
#
# Le mod surveille le hash des points et reconstruit son ombre tout seul
# après la déformation : il suffit d'écrire la config avant qu'il ne passe.
const _DROP_SHADOW_DATA_KEY = "DropShadow"


func _drop_shadow_cfg(wall):
	if wall == null or not is_instance_valid(wall) or not wall.has_meta("node_id"):
		return null
	if _g == null or _g.ModMapData == null or not (_g.ModMapData is Dictionary):
		return null
	var store = _g.ModMapData.get(_DROP_SHADOW_DATA_KEY)
	if not (store is Dictionary):
		return null
	var nid = str(wall.get_meta("node_id"))
	if not store.has(nid):
		return null
	var cfg = store[nid]
	if not (cfg is Dictionary) or not cfg.has("direction"):
		return null
	return cfg


# -1 = pas d'ombre sur ce wall (ou mod absent) : rien à restaurer plus tard.
func _drop_shadow_dir(wall) -> int:
	var cfg = _drop_shadow_cfg(wall)
	if cfg == null:
		return -1
	return int(cfg["direction"])


# Restaure un côté capturé (undo/redo d'une symétrie, Reset Transform). Le mod
# reconstruit son ombre de lui-même puisque les points du wall changent dans la
# même opération.
func _set_drop_shadow_dir(wall, value: int) -> void:
	if value < 0:
		return
	var cfg = _drop_shadow_cfg(wall)
	if cfg == null or int(cfg["direction"]) == value:
		return
	cfg["direction"] = value


func _swap_drop_shadow_side(wall) -> void:
	var cfg = _drop_shadow_cfg(wall)
	if cfg == null:
		return
	# 0 = Side A, 1 = Side B, 2 = Both (rien à échanger).
	var dir_value = int(cfg["direction"])
	if dir_value == 0:
		cfg["direction"] = 1
	elif dir_value == 1:
		cfg["direction"] = 0


# Walls actuellement sélectionnés dans DD, via DragSelectWalls (qui expose
# son instance dans ModMapData et connaît le type SELECTABLE_WALL).
func _selected_walls() -> Array:
	var dsw = _g.ModMapData.get("_drag_select_walls")
	if dsw == null or not dsw.has_method("_get_selected_walls_and_ref"):
		return []
	var result = dsw._get_selected_walls_and_ref()
	if result is Array and result.size() > 0 and result[0] is Array:
		return result[0]
	return []


# Snapshot des scale des portals d'un wall. Le snapshot de DragSelectWalls
# ne couvre pas scale (il n'en a pas besoin pour move/rotate/scale) mais la
# symétrie négativise scale.y, donc l'undo doit pouvoir le restaurer.
func _capture_portal_scales(wall) -> Dictionary:
	var scales := {}
	var portals = wall.get("Portals")
	if portals != null:
		for p in portals:
			if is_instance_valid(p):
				scales[p] = p.scale
	return scales


# Resynchronise l'entrée _ft_transforms d'un node avec sa base courante,
# si une entrée existe (ex : objet ayant subi une symétrie). Sans ça,
# _reapply_shear_transforms écrase la base chaque frame avec l'ancienne
# matrice → rotation/scale "reset" juste après un drag en multi-sélection.
func _sync_store_basis(nd) -> void:
	if nd == null or not is_instance_valid(nd):
		return
	if not _g.ModMapData.has("_ft_transforms"):
		return
	var key = _ft_node_key(nd)
	if key == "" or not _g.ModMapData["_ft_transforms"].has(key):
		return
	var t = nd.transform
	var d = _g.ModMapData["_ft_transforms"][key]
	d.xx = t.x.x; d.xy = t.x.y
	d.yx = t.y.x; d.yy = t.y.y
	d.ox = t.origin.x; d.oy = t.origin.y


# Store "_ft_wall_reset" : état d'origine d'un wall (Points + portals),
# capturé au PREMIER transform FT et jamais écrasé — aplati en floats
# pour la persistance en map. Sert au "Reset Transform" du menu walls.
func _store_wall_reset(wall) -> void:
	var key = _ft_node_key(wall)
	if key == "":
		return
	if not _g.ModMapData.has("_ft_wall_reset"):
		_g.ModMapData["_ft_wall_reset"] = {}
	if _g.ModMapData["_ft_wall_reset"].has(key):
		return
	var raw = wall.get("Points")
	if raw == null or raw.size() < 2:
		return
	var flat = []
	for p in raw:
		flat.append(p.x)
		flat.append(p.y)
	var portals = {}
	var plist = wall.get("Portals")
	if plist != null:
		for portal in plist:
			if portal == null or not is_instance_valid(portal):
				continue
			if not portal.has_meta("node_id"):
				continue
			portals[str(int(portal.get_meta("node_id")))] = [
				portal.position.x, portal.position.y, portal.rotation,
				portal.Direction.x, portal.Direction.y]
	# Le côté d'ombre d'origine est capturé ici, avant toute déformation :
	# _store_wall_reset ne s'exécute qu'une fois par wall (early return si la
	# clé existe), donc un nombre impair de symétries suivi d'un Reset retrouve
	# bien le côté de départ.
	_g.ModMapData["_ft_wall_reset"][key] = {
		"pts": flat,
		"portals": portals,
		"shadow_dir": _drop_shadow_dir(wall),
	}


# Store "_ft_path_reset" : EditPoints d'origine (monde, aplatis) d'un
# path, capturés au PREMIER warp distort/perspective (post-bake — cible
# visuellement identique au pré-warp) et jamais écrasés. Sert au Reset.
func _store_path_reset(node) -> void:
	var key = _ft_node_key(node)
	if key == "":
		return
	if not _g.ModMapData.has("_ft_path_reset"):
		_g.ModMapData["_ft_path_reset"] = {}
	if _g.ModMapData["_ft_path_reset"].has(key):
		return
	var pts = _get_path_edit_points_world(node)
	if pts.size() < 2:
		return
	var flat = []
	for p in pts:
		flat.append(p.x)
		flat.append(p.y)
	_g.ModMapData["_ft_path_reset"][key] = flat


# Reset Transform des walls sélectionnés : restaure Points + portals de
# l'état d'origine, efface le profil de largeur, RemakeLines, et pousse
# un record combiné (un seul Ctrl+Z).
func _reset_walls_transform() -> void:
	var dsw = _g.ModMapData.get("_drag_select_walls")
	if dsw == null or not dsw.has_method("_snapshot_wall"):
		return
	var reset_store = _g.ModMapData.get("_ft_wall_reset", {})
	var entries_before = []
	var entries_after = []
	var count = 0
	for w in _walls_in_selection:
		if not is_instance_valid(w):
			continue
		var key = _ft_node_key(w)
		if key == "" or not reset_store.has(key):
			continue
		var data = reset_store[key]
		var flat = data.get("pts", [])
		if flat.size() < 4:
			continue
		entries_before.append({
			"wall": w,
			"snap": dsw._snapshot_wall(w),
			"portal_scales": _capture_portal_scales(w),
			"width_warp": _ft_width_profile_copy(w),
			"shadow_dir": _drop_shadow_dir(w),
		})
		_set_drop_shadow_dir(w, int(data.get("shadow_dir", -1)))
		var pts = PoolVector2Array()
		for i in range(0, flat.size(), 2):
			pts.append(Vector2(flat[i], flat[i + 1]))
		_set_wall_points(w, pts)
		var pmap = data.get("portals", {})
		var plist = w.get("Portals")
		if plist != null:
			for portal in plist:
				if portal == null or not is_instance_valid(portal):
					continue
				var pid = str(int(portal.get_meta("node_id"))) if portal.has_meta("node_id") else ""
				if pid != "" and pmap.has(pid):
					var pv = pmap[pid]
					portal.position = Vector2(pv[0], pv[1])
					portal.rotation = pv[2]
					if "Direction" in portal:
						portal.Direction = Vector2(pv[3], pv[4])
		if _g.ModMapData.has("_ft_width_warp"):
			_g.ModMapData["_ft_width_warp"].erase(key)
		_width_applied_sig.erase(key)
		if w.has_method("RemakeLines"):
			w.RemakeLines()
		_rebuild_wall_width_curves(w)
		entries_after.append({
			"wall": w,
			"snap": dsw._snapshot_wall(w),
			"portal_scales": _capture_portal_scales(w),
			"width_warp": null,
			"shadow_dir": _drop_shadow_dir(w),
		})
		count += 1
	if count > 0:
		_record_ft_with_walls({}, {}, entries_before, entries_after)
		_save_ft_data()
		print("[FreeTransform] Reset Transform : %d wall(s)" % count)


# Décime une polyline à ~max_pts points (stride uniforme, premier et
# dernier points toujours conservés).
func _decimate_polyline(pts, max_pts: int) -> Array:
	var out = []
	var np = pts.size()
	if np <= max_pts:
		for p in pts:
			out.append(p)
		return out
	var stride = float(np - 1) / float(max_pts - 1)
	for i in range(max_pts):
		out.append(pts[int(round(i * stride))])
	return out


# Coins [TL, TR, BR, BL] de l'AABB d'un jeu de points, avec padding minimal
# pour les walls plats (AABB dégénérée → inversion bilinéaire instable).
func _wall_aabb_corners(pts: Array) -> Array:
	if pts.empty():
		return []
	var mn = pts[0]; var mx = pts[0]
	for p in pts:
		mn.x = min(mn.x, p.x); mn.y = min(mn.y, p.y)
		mx.x = max(mx.x, p.x); mx.y = max(mx.y, p.y)
	if mx.x - mn.x < 1.0:
		mn.x -= 24.0; mx.x += 24.0
	if mx.y - mn.y < 1.0:
		mn.y -= 24.0; mx.y += 24.0
	return [mn, Vector2(mx.x, mn.y), mx, Vector2(mn.x, mx.y)]


# ══ Largeur variable (Niveau 1) ═════════════════════════════════════════
# Un warp non-uniforme devrait aussi amincir/épaissir le trait. Le moteur
# DD rend les lignes avec des largeurs PAR POINT : on y bake le facteur
# d'échelle GLOBAL (isotrope) du warp — cf. _area_warp_factor. Store persisté "_ft_width_warp" : { key: {"fr": [...],
# "fa": [...]} } — profil (fraction d'arc → facteur cumulé) le long de la
# polyline. Le node.width de DD reste intact (dégradation propre sans le
# mod : trait constant) ; les facteurs vivent dans curve.max_value.

# Copie du profil de largeur d'un node (null si absent).
func _ft_width_profile_copy(node):
	var key = _ft_node_key(node)
	if key == "":
		return null
	var store = _g.ModMapData.get("_ft_width_warp", null)
	if store == null or not store.has(key):
		return null
	return store[key].duplicate(true)


# Facteur d'échelle GLOBAL (isotrope) du warp au point p : racine du
# déterminant du jacobien local (zoom de surface), par différences
# centrées. Indépendant de l'orientation du trait — le côté pincé du quad
# donne un trait fin quel que soit le sens du path/wall, avec une
# variation régulière le long du quad. Un shear pur (aire conservée) ne
# change pas l'épaisseur ; un étirement uniforme k donne k.
func _area_warp_factor(p: Vector2, src: Array, nc: Array) -> float:
	var eps = 8.0
	var jx = (_warp_point(p + Vector2(eps, 0), src, nc) \
			- _warp_point(p - Vector2(eps, 0), src, nc)) / (2.0 * eps)
	var jy = (_warp_point(p + Vector2(0, eps), src, nc) \
			- _warp_point(p - Vector2(0, eps), src, nc)) / (2.0 * eps)
	return sqrt(abs(jx.cross(jy)))


# Fractions d'arc cumulées (0→1) d'une polyline. Dégénérée → ratios
# d'index. closed : le périmètre inclut le segment de fermeture
# (dernier→premier), le dernier point garde donc une fraction < 1.
func _polyline_arc_fractions(pts: Array, closed := false) -> Array:
	var out = []
	if pts.size() < 2:
		for _i in range(pts.size()):
			out.append(0.0)
		return out
	var cum = [0.0]
	for i in range(pts.size() - 1):
		cum.append(cum[i] + pts[i].distance_to(pts[i + 1]))
	var total = cum[cum.size() - 1]
	if closed:
		total += pts[pts.size() - 1].distance_to(pts[0])
	for i in range(pts.size()):
		out.append(cum[i] / total if total > 0.001 else float(i) / float(pts.size() - 1))
	return out


# Échantillonne un profil {"fr","fa"} à la fraction t (interp. linéaire).
func _sample_width_profile(entry, t: float) -> float:
	if entry == null or not (entry is Dictionary):
		return 1.0
	var fr = entry.get("fr", []); var fa = entry.get("fa", [])
	if fr.size() == 0 or fr.size() != fa.size():
		return 1.0
	if t <= fr[0]: return fa[0]
	for i in range(1, fr.size()):
		if t <= fr[i]:
			var span = fr[i] - fr[i - 1]
			var k = (t - fr[i - 1]) / span if span > 0.000001 else 0.0
			return lerp(fa[i - 1], fa[i], k)
	# Au-delà du dernier point : profil fermé → interpole vers le premier
	# point (segment de fermeture) ; ouvert → constant.
	if entry.get("cl", false):
		var last = fr.size() - 1
		var span2 = 1.0 - fr[last]
		var k2 = (t - fr[last]) / span2 if span2 > 0.000001 else 0.0
		return lerp(fa[last], fa[0], clamp(k2, 0.0, 1.0))
	return fa[fa.size() - 1]


# Construit une Curve Godot depuis (positions x, valeurs). Les facteurs
# peuvent dépasser 1 → portés par max_value (width DD intact).
func _build_width_curve(xs: Array, vals: Array) -> Curve:
	var c = Curve.new()
	c.min_value = 0.0
	var mx = 1.0
	for v in vals:
		mx = max(mx, v)
	c.max_value = mx * 1.05
	for i in range(xs.size()):
		c.add_point(Vector2(clamp(xs[i], 0.0, 1.0), vals[i]))
	return c


# Fraction d'arc de chaque point de query le long de polyline (les points
# sont supposés SUR la polyline — projection sur le segment le plus proche).
func _arc_fractions_on_polyline(polyline: Array, query: Array, closed := false) -> Array:
	var out = []
	if polyline.size() < 2:
		for _q in query:
			out.append(0.0)
		return out
	var cum = [0.0]
	for i in range(polyline.size() - 1):
		cum.append(cum[i] + polyline[i].distance_to(polyline[i + 1]))
	var total = cum[cum.size() - 1]
	if closed:
		total += polyline[polyline.size() - 1].distance_to(polyline[0])
	if total < 0.001:
		for _q in query:
			out.append(0.0)
		return out
	var nseg = polyline.size() - 1 + (1 if closed else 0)
	for q in query:
		var best_d = INF
		var best_arc = 0.0
		for i in range(nseg):
			var a = polyline[i]
			var b = polyline[(i + 1) % polyline.size()]
			var ab = b - a
			var l2 = ab.length_squared()
			var k = clamp((q - a).dot(ab) / l2, 0.0, 1.0) if l2 > 0.000001 else 0.0
			var proj = a + ab * k
			var dd = q.distance_squared_to(proj)
			if dd < best_d:
				best_d = dd
				best_arc = cum[i] + sqrt(l2) * k if i < cum.size() else cum[cum.size() - 1] + sqrt(l2) * k
		out.append(best_arc / total)
	return out


# Sous-divise une polyline (points colinéaires insérés, espacement max
# max_seg, plafond max_pts au total).
func _subdivide_polyline(pts: Array, max_seg: float, max_pts: int, closed := false) -> Array:
	# Le budget max_pts limite la DENSITÉ de sous-division, jamais les
	# points originaux : l'ancien break tronquait la queue des longues
	# polylines (> ~9 000 px), et les loops se refermaient alors en
	# diagonale à travers la forme. Si le budget est trop petit pour
	# l'espacement demandé, on élargit l'espacement uniformément.
	var total = 0.0
	for i in range(pts.size() - 1):
		total += pts[i].distance_to(pts[i + 1])
	if closed:
		total += pts[pts.size() - 1].distance_to(pts[0])
	var seg = max_seg
	var budget = max_pts - pts.size()
	if budget < 1:
		budget = 1
	if total / seg > float(budget):
		seg = total / float(budget)
	var out = [pts[0]]
	for i in range(pts.size() - 1):
		var a = pts[i]
		var b = pts[i + 1]
		var steps = int(max(1, ceil(a.distance_to(b) / seg)))
		for k in range(1, steps + 1):
			out.append(a.linear_interpolate(b, float(k) / float(steps)))
	# Segment de fermeture (points intermédiaires seulement, le renderer
	# referme lui-même sur le premier point)
	if closed:
		var a2 = pts[pts.size() - 1]
		var b2 = pts[0]
		var steps2 = int(max(1, ceil(a2.distance_to(b2) / seg)))
		for k in range(1, steps2):
			out.append(a2.linear_interpolate(b2, float(k) / float(steps2)))
	return out


# Résout le nom réel de la propriété "Super" du fork moteur sur une
# Line2D native (le binding C# PascalCase ne vaut que côté mono). Sonde
# une liste de candidats puis mémorise le premier qui existe.
var _super_prop_cache := ""
func _line_super_property(line) -> String:
	if _super_prop_cache != "" and line.get(_super_prop_cache) != null:
		return _super_prop_cache
	for cand in ["Super", "super", "super_mode", "use_super", "super_line"]:
		if line.get(cand) != null:
			_super_prop_cache = cand
			return cand
	return ""


# Applique un profil de largeur à une Line2D. Le moteur Godot modifié de
# DD rend les Pathways (et lignes "Super") avec des largeurs PAR POINT
# (set_point_width — cf. Pathway.GrowShrinkEnds) et ignore width_curve ;
# on pose donc la largeur point par point, avec repli width_curve si la
# méthode n'existe pas. base_w = largeur nominale ; entry = profil
# {"fr","fa"} échantillonné à la fraction d'arc de chaque point (null →
# facteur 1, sert à remettre à plat). taper = multiplicateurs par point
# additionnels (réplique du Grow/Shrink de DD), même taille que points.
func _apply_line_point_widths(line, entry, base_w: float, taper = null, allow_subdiv := false) -> void:
	if line == null or not is_instance_valid(line):
		return
	var pts = []
	for p in line.points:
		pts.append(p)
	if pts.size() < 2:
		return
	var lloop = bool(line.get("loop")) if line.get("loop") != null else false
	var frs = _polyline_arc_fractions(pts, lloop)
	var use_ppw = line.has_method("set_point_width")
	# Le renderer par point du moteur DD n'est actif qu'en mode "Super"
	# (Pathway l'active dans son constructeur, Wall.AddLine NON : sans ça,
	# set_point_width est stocké mais ignoré au rendu). On l'active dès
	# qu'un profil réel est posé — jamais désactivé ensuite (des largeurs
	# uniformes rendent identique au mode standard).
	if use_ppw and entry != null:
		# Le renderer par point n'est actif qu'en mode "Super" (Pathway
		# l'active dans son constructeur, Wall.AddLine non).
		var sup_name = _line_super_property(line)
		if sup_name != "" and not bool(line.get(sup_name)):
			line.set(sup_name, true)
		# Le builder du fork rend chaque segment à largeur CONSTANTE
		# (celle de son point de départ) — le dégradé apparent des paths
		# vient de la densité de leurs points lissés. On densifie donc
		# les polylines éparses (walls : 1 point par sommet) pour
		# retrouver un dégradé visuel. Points colinéaires insérés → aucun
		# impact sur la géométrie ni le tuilage de texture.
		if allow_subdiv:
			var need = false
			for i in range(pts.size() - 1):
				if pts[i].distance_to(pts[i + 1]) > 32.0:
					need = true
					break
			# Boucle : le segment de fermeture doit être vérifié et
			# sous-divisé aussi, sinon il reste un unique palier (voire
			# des artefacts de largeur sur la couture).
			if not need and lloop and pts[pts.size() - 1].distance_to(pts[0]) > 32.0:
				need = true
			if need:
				pts = _subdivide_polyline(pts, 24.0, 384, lloop)
				line.points = PoolVector2Array(pts)
				frs = _polyline_arc_fractions(pts, lloop)
	var xs = []
	var vals = []
	for i in range(pts.size()):
		var f = _sample_width_profile(entry, frs[i])
		var t = taper[i] if taper != null and i < taper.size() else 1.0
		if use_ppw:
			line.set_point_width(i, base_w * f * t)
		else:
			xs.append(frs[i])
			vals.append(f * t)
	if not use_ppw:
		line.width_curve = _build_width_curve(xs, vals) if entry != null else null


# Réplique le taper Grow/Shrink de DD (Pathway.GrowShrinkEnds) : facteurs
# par point [0..1] sur les points lissés. null si ni Grow ni Shrink.
func _path_growshrink_taper(node, count: int):
	# path_taper mod: when its "Custom Grow/Shrink" is ON for this path, its
	# linear ramp replaces the vanilla replica below.
	if Engine.has_meta("up_path_taper"):
		var pt = Engine.get_meta("up_path_taper")
		if pt != null and is_instance_valid(pt) and pt.has_method("compute_taper"):
			var custom = pt.compute_taper(node, count)
			if custom != null:
				return custom
	var grow = bool(node.get("Grow")) if node.get("Grow") != null else false
	var shrink = bool(node.get("Shrink")) if node.get("Shrink") != null else false
	if not grow and not shrink:
		return null
	var distance = int(count / 3) if count < 100 else 50
	var taper = []
	for _i in range(count):
		taper.append(1.0)
	if distance <= 0:
		return taper
	for i in range(1, distance + 1):
		var t = ease(float(i) / float(distance), -2.0)
		var w = lerp(1.0, 0.0, t)
		if grow and distance - i >= 0 and distance - i < count:
			taper[distance - i] = w
		if shrink:
			var idx = count - distance + i - 1
			if idx >= 0 and idx < count:
				taper[idx] = w
	return taper


# Applique le profil de largeur d'un path (points lissés du Pathway).
# Le profil est rééchantillonné par PROJECTION des points lissés sur la
# polyline des EditPoints (référence du profil) : le Chaikin fermé n'a
# pas d'extrémités fixes et introduit un déphasage entre les fractions
# d'arc des deux polylines — la projection y est immune (même méthode
# que les walls, éprouvée sur leurs loops).
func _apply_path_point_widths(node, entry) -> void:
	if node == null or not is_instance_valid(node) or not (node is Line2D):
		return
	var taper = _path_growshrink_taper(node, node.points.size())
	if entry == null:
		_apply_line_point_widths(node, null, node.width, taper)
		return
	var ploop = bool(node.get("loop")) if node.get("loop") != null else false
	# EditPoints en espace LOCAL du node (les points lissés le sont)
	var eplocal = []
	for p in _get_path_edit_points_world(node):
		eplocal.append(node.to_local(p))
	var spts = []
	for p in node.points:
		spts.append(p)
	if eplocal.size() < 2 or spts.size() < 2:
		_apply_line_point_widths(node, entry, node.width, taper)
		return
	var frs = _arc_fractions_on_polyline(eplocal, spts, ploop)
	var lfr = _polyline_arc_fractions(spts, ploop)
	var lfa = []
	for i in range(spts.size()):
		lfa.append(_sample_width_profile(entry, frs[i]))
	_apply_line_point_widths(node, {"fr": lfr, "fa": lfa, "cl": ploop}, node.width, taper)


# Reconstruit les width_curve des Line2D enfants d'un wall depuis le store
# (post-RemakeLines, undo, reload). Courbe par enfant, points de courbe aux
# ratios d'index — exactement l'échantillonnage interne de Line2D.
func _rebuild_wall_width_curves(wall) -> void:
	if wall == null or not is_instance_valid(wall):
		return
	var key = _ft_node_key(wall)
	var store = _g.ModMapData.get("_ft_width_warp", {})
	var entry = store.get(key) if key != "" else null
	var wall_pts = []
	var raw = wall.get("Points")
	if raw != null:
		for p in raw:
			wall_pts.append(p)
	for child in wall.get_children():
		if child.has_meta("_ft_probe"):
			continue
		var lines = []
		if child is Line2D:
			lines.append(child)
		elif child is Node2D:
			for sub in child.get_children():
				if sub is Line2D:
					lines.append(sub)
		for line in lines:
			var cpts = []
			for p in line.points:
				cpts.append(p)
			if cpts.size() < 2:
				continue
			# Profil du wall rééchantillonné en profil LOCAL à la ligne
			# (fractions d'arc de la ligne → facteur au point correspondant
			# du wall), puis application par point.
			var wloop = bool(wall.get("Loop")) if wall.get("Loop") != null else false
			var lloop = bool(line.get("loop")) if line.get("loop") != null else false
			var frs = _arc_fractions_on_polyline(wall_pts, cpts, wloop)
			var lfr = _polyline_arc_fractions(cpts, lloop)
			var lfa = []
			for i in range(cpts.size()):
				lfa.append(_sample_width_profile(entry, frs[i]) if entry != null else 1.0)
			_apply_line_point_widths(line, {"fr": lfr, "fa": lfa, "cl": lloop} if entry != null else null, line.width, null, true)


# Maintenance : réapplique les largeurs par point (reload, Smooth de DD,
# RemakeLines). Les largeurs par point n'ont pas de getter → détection par
# signature (nb de points + width) : tout Smooth/RemakeLines qui régénère
# la géométrie change la signature ou repasse les largeurs à l'uniforme,
# et on réapplique alors depuis le store.
func _reapply_width_warp() -> void:
	# Purge du store de l'ex-feature "cisaillement de texture" (retirée) :
	# les maps de test peuvent en garder une copie persistée.
	if _g.ModMapData.has("_ft_tex_shear"):
		_g.ModMapData.erase("_ft_tex_shear")
	var store = _g.ModMapData.get("_ft_width_warp", null)
	if store == null or not (store is Dictionary) or store.empty():
		return
	var dead = []
	for key in store.keys():
		var nd = _ft_node_from_key(key)
		if nd == null or not is_instance_valid(nd):
			dead.append(key)
			_width_applied_sig.erase(key)
			continue
		var sig
		if _is_path(nd):
			if not (nd is Line2D):
				continue
			sig = [nd.points.size(), nd.width]
			if _width_applied_sig.get(key) != sig:
				_apply_path_point_widths(nd, store[key])
				_width_applied_sig[key] = sig
		else:
			var total = 0
			for child in nd.get_children():
				if child is Line2D:
					total += child.points.size()
				elif child is Node2D:
					for sub in child.get_children():
						if sub is Line2D:
							total += sub.points.size()
			var wpts = nd.get("Points")
			sig = [total, wpts.size() if wpts != null else 0]
			if _width_applied_sig.get(key) != sig:
				_rebuild_wall_width_curves(nd)
				_width_applied_sig[key] = sig
	for key in dead:
		store.erase(key)


# Warp bilinéaire d'un point : (u,v) dans le quad source → quad destination.
func _warp_point(p: Vector2, src: Array, nc: Array) -> Vector2:
	var t = _inv_bilinear_cpu(p, src)
	var top = nc[0].linear_interpolate(nc[1], t.x)
	var bot = nc[3].linear_interpolate(nc[2], t.x)
	return top.linear_interpolate(bot, t.y)


# Direction locale du warp au point p, le long de la direction d (par
# différence centrée). Sert à réorienter portals et end-caps.
func _warp_direction(p: Vector2, d: Vector2, src: Array, nc: Array) -> Vector2:
	var eps = 8.0
	var d1 = _warp_point(p + d * eps, src, nc) - _warp_point(p - d * eps, src, nc)
	return d1.normalized() if d1.length() > 0.0001 else d


# Warp skew/distort/perspective d'un wall depuis son snapshot DSW :
# Points, Line2D enfants (retour visuel, RemakeLines différé au commit),
# end-caps, et portals (position + Direction + rotation, l'écart
# rotation↔direction — flip — est préservé). Les WallDistance ne sont pas
# réécrits : les trous sont recalculés depuis position/Direction/Radius
# par RemakeLines (même approche que le scale affine de DragSelectWalls).
func _apply_warp_to_wall(wall, snap: Dictionary, src: Array, nc: Array) -> void:
	var pts0 = snap.get("pts", [])
	if pts0.empty():
		return
	var new_pts = PoolVector2Array()
	for p in pts0:
		new_pts.append(_warp_point(p, src, nc))
	_set_wall_points(wall, new_pts)

	var children = snap.get("children", {})
	var pre_profile = _wall_drag_wprofile.get(wall)
	var child_frs = _wall_drag_childfr.get(wall, {})
	var child_dec = _wall_drag_childpts.get(wall, {})
	for child in children:
		if child == null or not is_instance_valid(child):
			continue
		var data = children[child]
		if data.has("points"):
			var opts = child_dec.get(child, data["points"])
			var lp = PoolVector2Array()
			for p in opts:
				lp.append(_warp_point(p, src, nc))
			child.points = lp
			# Largeur variable : facteur perpendiculaire composé avec le
			# profil pré-drag, échantillonné à la fraction d'arc pré-calculée.
			if child is Line2D and opts.size() >= 2:
				var cfr = child_frs.get(child, [])
				# Largeur par point (moteur DD) : facteur perpendiculaire
				# composé avec le profil pré-drag, aux fractions d'arc de
				# la polyline WARPÉE de l'enfant.
				var lp_arr = []
				for p in lp:
					lp_arr.append(p)
				var cloop = bool(child.get("loop")) if child.get("loop") != null else false
				var xs = _polyline_arc_fractions(lp_arr, cloop)
				var vals = []
				for i in range(opts.size()):
					var fprev = _sample_width_profile(pre_profile, cfr[i]) if i < cfr.size() else 1.0
					vals.append(fprev * _area_warp_factor(opts[i], src, nc))
				# Pas de re-sous-division pendant le drag (points déjà
				# bornés par la décimation ; pleine densité au commit).
				_apply_line_point_widths(child, {"fr": xs, "fa": vals, "cl": cloop}, child.width, null, false)
		elif data.has("position"):
			var cp = data["position"]
			child.position = _warp_point(cp, src, nc)
			var crot = data.get("rotation", 0.0)
			var cd = Vector2(cos(crot), sin(crot))
			child.rotation = _warp_direction(cp, cd, src, nc).angle()

	var portal_pos = snap.get("portals", {})
	var portal_rot = snap.get("portal_rots", {})
	var portal_dir = snap.get("portal_dirs", {})
	for portal in portal_pos:
		if portal == null or not is_instance_valid(portal):
			continue
		var p0 = portal_pos[portal]
		portal.position = _warp_point(p0, src, nc)
		var d0 = portal_dir.get(portal, Vector2.RIGHT)
		var d1 = _warp_direction(p0, d0, src, nc)
		if "Direction" in portal:
			portal.Direction = d1
		var r0 = portal_rot.get(portal, 0.0)
		portal.rotation = d1.angle() + (r0 - d0.angle())


# Applique une transformation affine monde aux walls dragués (une fois
# par frame de drag). RemakeLines est différé au commit : les enfants
# Line2D sont déjà transformés point à point par DSW, et RemakeLines est
# coûteux sur les walls à portals (même raison que le _ci_mode de DSW).
func _apply_walls_drag_transform(W: Transform2D) -> void:
	var dsw = _g.ModMapData.get("_drag_select_walls")
	if dsw == null or not dsw.has_method("_apply_transform_to_wall"):
		return
	for w in _wall_drag_walls:
		if is_instance_valid(w) and _wall_drag_snaps.has(w):
			dsw._apply_transform_to_wall(w, _wall_drag_snaps[w], W, false)


# Enregistre un changement FT en y joignant les walls si présents :
# record combiné en UNE étape de Ctrl+Z via _restore_flip_combined.
# Sans walls, délègue au record unifié standard.
func _record_ft_with_walls(before: Dictionary, after: Dictionary,
		walls_before: Array, walls_after: Array) -> void:
	if walls_before.empty():
		_record_ft_unified_change(before, after)
		return
	var undo_lib = _g.ModMapData.get("_undo_lib")
	if undo_lib == null:
		return
	undo_lib.record_callback(
		self, "_restore_flip_combined", [before, walls_before],
		self, "_restore_flip_combined", [after, walls_after])


# Undo/redo d'une transformation mixte (props + walls) en UNE étape —
# symétrie ou drag des handles FT : restaure d'abord l'état unifié FT
# (props/paths/patterns/portals autonomes), puis chaque wall via
# DragSelectWalls (Points + portals + enfants visuels), et enfin les
# scale de portals (non couverts par _restore_wall_state).
func _restore_flip_combined(unified: Dictionary, wall_entries: Array) -> void:
	if unified.size() > 0:
		_restore_ft_unified(unified)
	var dsw = _g.ModMapData.get("_drag_select_walls")
	if dsw == null or not dsw.has_method("_restore_wall_state"):
		return
	for e in wall_entries:
		var w = e.get("wall")
		if w == null or not is_instance_valid(w):
			continue
		dsw._restore_wall_state(w, e["snap"])
		# Côté de l'ombre Drop Shadow : suit l'état restauré, sinon un undo de
		# symétrie remettrait la géométrie d'origine avec le côté échangé.
		_set_drop_shadow_dir(w, int(e.get("shadow_dir", -1)))
		var scales = e.get("portal_scales", {})
		for portal in scales:
			if is_instance_valid(portal):
				portal.scale = scales[portal]
		# Profil de largeur : restaure ou efface, puis reconstruit les
		# width_curve des enfants (restaurés par _restore_wall_state).
		if e.has("width_warp"):
			var wkey = _ft_node_key(w)
			if wkey != "":
				if not _g.ModMapData.has("_ft_width_warp"):
					_g.ModMapData["_ft_width_warp"] = {}
				if e["width_warp"] == null:
					_g.ModMapData["_ft_width_warp"].erase(wkey)
				else:
					_g.ModMapData["_ft_width_warp"][wkey] = e["width_warp"].duplicate(true)
			_rebuild_wall_width_curves(w)


func _on_transform_menu_id(id: int) -> void:
	if id == 20 or id == 21:
		_flip_selection(id == 20)
		if _context_menu != null and is_instance_valid(_context_menu):
			_context_menu.queue_free()
		_context_menu = null
		return

	if id == 22:
		# Reset Transform des walls : état d'origine (Points + portals)
		_reset_walls_transform()
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

	var id_to_mode = {0: "free", 1: "skew", 2: "distort", 3: "perspective", 4: "crop", 5: "softcrop", 6: "edgecrop", 7: "blur"}
	var new_mode = id_to_mode.get(id, "free")

	# (Les paths sont désormais réellement warpés en distort/perspective —
	# l'ancien avertissement "affine best-effort" n'a plus lieu d'être.)

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
