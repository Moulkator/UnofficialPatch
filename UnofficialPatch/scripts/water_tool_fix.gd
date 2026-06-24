# water_tool_fix.gd
# Toggle water animation on/off with persistence
# Fixes black lines at map edges by disabling distortion near map bounds

var _g

var water_brush = null
var _water_panel = null
var _button = null
var _animation_disabled = false
var _shader = null
var _mat = null
var _settings_path = "user://UnofficialPatch/bugfixes_water_anim.cfg"
var _bounds_set = false
var _last_map_w = 0
var _last_map_h = 0
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
