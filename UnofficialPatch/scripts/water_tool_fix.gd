# water_tool_fix.gd
# Toggle water animation on/off with persistence
# Fixes black lines at map edges by disabling distortion near map bounds
# Fixes nested island bug: drawing water inside a hole detaches sibling holes
# from their outer polygon (DFS grouping bug in WaterMesh.UpdateMesh_TriangleNet),
# flooding unrelated interiors. Fixed by flattening the PolyTree via Save()/Load().
# Applies the "Half-Grid Snapping" preference to the WaterBrush shape modes:
# WaterBrush.Enable() never sets WorldUI.UseHalfSnap, so the water tool silently
# inherits whatever the previously active tool left there. We re-apply the
# preference every frame while the water tool is active.
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
	_apply_half_snap(delta)


# --- Half-grid snapping ------------------------------------------------------
# Global.Preferences is a static C# property, unreachable from GDScript, so we
# read the same value DD reads: [Preferences] half_grid_snap in user://config.ini.
# DD only applies the checkbox on Save (which also writes the file), so re-reading
# the file when the Preferences window is open/closes keeps us in sync.

var _half_snap_pref = false
var _half_snap_loaded = false
var _prefs_window_was_visible = false
var _half_snap_reread_timer = 0.0

func _read_half_snap_pref():
	var cfg = ConfigFile.new()
	if cfg.load("user://config.ini") == OK:
		_half_snap_pref = bool(cfg.get_value("Preferences", "half_grid_snap", false))
	else:
		_half_snap_pref = false
	_half_snap_loaded = true


func _apply_half_snap(delta):
	var editor = _g.get("Editor")
	if editor == null or not is_instance_valid(editor):
		return

	if not _half_snap_loaded:
		_read_half_snap_pref()

	# Re-read while the Preferences window is open (Save without Close) and
	# once more when it closes.
	var prefs_win = editor.get_node_or_null("Windows/Preferences")
	var prefs_visible = prefs_win != null and prefs_win.visible
	if prefs_visible:
		_half_snap_reread_timer += delta
		if _half_snap_reread_timer >= 1.0:
			_half_snap_reread_timer = 0.0
			_read_half_snap_pref()
	elif _prefs_window_was_visible:
		_half_snap_reread_timer = 0.0
		_read_half_snap_pref()
	_prefs_window_was_visible = prefs_visible

	if editor.get("ActiveToolName") != "WaterBrush":
		return
	var world = _g.get("World")
	if world == null:
		return
	var ui = world.get("UI")
	if ui == null or not is_instance_valid(ui):
		return
	if ui.get("UseHalfSnap") != _half_snap_pref:
		ui.set("UseHalfSnap", _half_snap_pref)
