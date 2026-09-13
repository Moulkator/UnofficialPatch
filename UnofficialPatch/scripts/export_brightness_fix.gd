# export_brightness_fix.gd
# Fixes two issues with the Brightness / Focus sliders of the Export window.
#
# 1) Light sources appearing to change blend mode when Brightness or Focus
#    drops below 100%.
#    Vanilla pipeline: ExportFX (Polygon2D + BlurScreen.shader) redraws the
#    screen captured by LightPassBBC, i.e. BEFORE the ambient tint and the
#    light passes. DD re-applies the ambient via ExportFX.Modulate, but in
#    Godot 3 the modulate multiplies the WHOLE output, light passes included:
#    the additive light highlights get crushed by the ambient color.
#    Fix: swap ExportFX's material for an equivalent shader that applies the
#    ambient tint on the base pass only (AT_LIGHT_PASS branch, same trick as
#    DeferredLighting.shader), and keep the modulate white. ExportWindow
#    re-reads ExportFX.Material on every slider change, so its writes to
#    "color"/"blur" land in our material transparently.
#
# 2) Focus blur strength depending on the export PPI.
#    The vanilla shader samples SCREEN_TEXTURE at mip level "blur", i.e. the
#    blur radius is a fixed number of SCREEN pixels. At 70 ppi a tile is
#    3.6x fewer pixels than at 256 ppi, so the same mip level blurs 3.6x more
#    of the map. Fix: offset the mip level by log2(camera zoom) so the blur
#    radius is constant in MAP units (256 ppi = vanilla behaviour). The same
#    offset is applied in the editor preview, so what you see matches the
#    export whatever the current zoom. The blur range is also doubled
#    (BLUR_SCALE) since the vanilla maximum was rather weak.
#
# 3) Corrupted export (repeated / stale chunks) when DD is MINIMIZED during
#    the export. Godot skips rendering while OS.can_draw() is false, but
#    idle_frame keeps firing, so Exporter captures the same stale viewport
#    texture for every chunk. Fix: while Master.IsExporting and the window
#    is minimized, force a draw every frame with VisualServer.force_draw().
#
# NB: Main.update() does not run while the modal Export window is open,
# hence the SceneTree "idle_frame" hook (per-frame, so the mip offset is in
# place before the first exported chunk is captured).

var _g
var _shader = null

const SHADER_CODE = """
shader_type canvas_item;

uniform vec4 color : hint_color = vec4(0.0);
uniform float blur = 0.0;
uniform vec4 ambient : hint_color = vec4(1.0);
// log2(camera zoom): shifts the mip level so the blur radius is constant
// in map units instead of screen pixels (set every frame by the mod)
uniform float lod_offset = 0.0;
// Vanilla maps Focus 0% to mip level 4; scale it up for a stronger max blur
const float BLUR_SCALE = 2.0;

void fragment() {
	float lod = max(blur * BLUR_SCALE - lod_offset, 0.0);
	vec3 base = mix(textureLod(SCREEN_TEXTURE, SCREEN_UV, lod).rgb, color.rgb, color.a);
	if (AT_LIGHT_PASS) {
		// Light pass: do not tint, the light reveals the raw base
		// (same logic as DeferredLighting.shader)
		COLOR.rgb = base;
	} else {
		// Base pass: apply the ambient tint once
		COLOR.rgb = mix(base, base * ambient.rgb, ambient.a);
	}
}
"""


func initialize():
	_shader = Shader.new()
	_shader.code = SHADER_CODE
	# Cross-session guard: _g.Editor persists across map reloads, so a hook
	# registered by a previous mod instance would keep running. Disconnect
	# the previous one before registering ours.
	var tree = _g.Editor.get_tree()
	if Engine.has_meta("ebf_instance"):
		var old = Engine.get_meta("ebf_instance")
		if is_instance_valid(old) and tree.is_connected("idle_frame", old, "_tick"):
			tree.disconnect("idle_frame", old, "_tick")
	# Legacy Timer from older versions of this mod
	if Engine.has_meta("ebf_timer"):
		var old_t = Engine.get_meta("ebf_timer")
		if is_instance_valid(old_t):
			old_t.queue_free()
		Engine.remove_meta("ebf_timer")
	Engine.set_meta("ebf_instance", self)
	tree.connect("idle_frame", self, "_tick")
	print("[ExportBrightnessFix] initialized")


func update(_delta):
	pass


func _tick():
	_force_draw_if_minimized()
	var world = _g.World
	if world == null or not is_instance_valid(world):
		return
	var fx = world.get("ExportFX")
	if fx == null or not is_instance_valid(fx):
		return
	_ensure_shader(fx)
	if not fx.visible:
		return
	# Neutralize the vanilla modulate (applied AFTER the shader, so on the
	# light passes too): the tint goes through the "ambient" uniform instead
	if fx.modulate != Color(1, 1, 1, 1):
		fx.modulate = Color(1, 1, 1, 1)
	var mat = fx.material
	if mat == null or not (mat is ShaderMaterial):
		return
	# Blur radius independent of zoom / export PPI
	var cam = _g.Camera
	if cam != null and is_instance_valid(cam) and cam.zoom.x > 0.0:
		mat.set_shader_param("lod_offset", log(cam.zoom.x) / log(2.0))
	var source_level = world.get("SourceLevel")
	if source_level == null or not is_instance_valid(source_level):
		return
	var lpr = source_level.get("LightPassRender")
	if lpr == null or not is_instance_valid(lpr):
		return
	mat.set_shader_param("ambient", lpr.color)


func _force_draw_if_minimized():
	if not OS.window_minimized:
		return
	var tree = _g.Editor.get_tree() if _g.Editor != null else null
	if tree == null or tree.root == null:
		return
	var master = tree.root.get_node_or_null("Master")
	if master == null or master.get("IsExporting") != true:
		return
	# idle_frame runs before Exporter's awaited continuation (connected
	# earlier), so this draws the chunk panned during the previous frame;
	# Exporter waits two frames per chunk, so the capture sees a fresh render.
	VisualServer.force_draw(true)


func _ensure_shader(fx):
	var mat = fx.material
	if mat != null and mat is ShaderMaterial and mat.shader == _shader:
		return
	var new_mat = ShaderMaterial.new()
	new_mat.shader = _shader
	# Carry over the current slider values (DD then writes directly into
	# this material via ExportFX.Material)
	if mat != null and mat is ShaderMaterial:
		var c = mat.get_shader_param("color")
		if c != null:
			new_mat.set_shader_param("color", c)
		var b = mat.get_shader_param("blur")
		if b != null:
			new_mat.set_shader_param("blur", b)
	fx.material = new_mat
	print("[ExportBrightnessFix] Custom ExportFX shader installed")
