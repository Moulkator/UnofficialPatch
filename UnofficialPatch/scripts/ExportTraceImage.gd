var _g  # injected by UnofficialPatch
# Dungeondraft mod to export trace image
var script_class = "tool"

# Variables
var trace_sprite = null
var source_level_optionbutton = null
var export_trace_image_button = null
var _lib_mod_config = null

# Logging Functions
const ENABLE_LOGGING = true
var logging_level = 0

func outputlog(msg,level=0):
	if ENABLE_LOGGING:
		if level <= logging_level:
			printraw("(%d) <ExportTraceImage>: " % OS.get_ticks_msec())
			print(msg)
	else:
		pass

# Function to set a property on an object but block any signals for it
func set_property_but_block_signals(obj: Object, property: String, value):

	outputlog("set_property_but_block_signals: " + str(obj) + " property: " + str(property) + " value: " + str(value),3)

	obj.set_block_signals(true)
	if obj.get(property) != null:
		obj.set(property,value)
	obj.set_block_signals(false)

# Function set the trace_sprite_visibility
func set_trace_sprite_visibilty_on_export():

	outputlog("set_trace_sprite_visibilty_on_export",2)

	if export_trace_image_button.pressed:
		create_trace_sprite()

# Function to update the source level and move the trace image
func on_source_level_changed(index: int):

	outputlog("on_source_level_changed: index: " + str(index),2)

	if trace_sprite != null:
		if trace_sprite.get_parent() != null:
			var level = _g.World.levels[index]
			trace_sprite.get_parent().remove_child(trace_sprite)
			get_trace_parent(level).add_child(trace_sprite)
			apply_trace_sprite_z(level)

# Function to capture visibility of the trace image changing
func trace_image_visibility_changed():

	outputlog("trace_image_visibility_changed: " + str(_g.World.TraceImage.visible),2)
	# If we have the export window open then check if the export_trace_image_button is active
	if _g.Editor.Windows["Export"].visible:
		export_trace_image_button.pressed = not export_trace_image_button.pressed

# Function show or hide the trace image
func show_hide_traceimage(make_visible: bool, suppress_signal: bool):

	if _g.World.TraceImage == null: return

	if suppress_signal:
		set_property_but_block_signals(_g.World.TraceImage, "visible", make_visible)
	else:
		_g.World.TraceImage.visible = make_visible
	_g.World.TraceImageVisible = make_visible

# On export window launch
func on_launch_export_window():

	outputlog("on_launch_export_window", 2)

	# If the button is in the right state force a creation/deletion set event
	if export_trace_image_button.pressed == _g.World.TraceImageVisible:
		on_export_trace_image_button_toggled(_g.World.TraceImageVisible)
	# Otherwise use the standard toggle signals
	else:
		export_trace_image_button.pressed = _g.World.TraceImageVisible

# On export window closed, show or hide the traceimage based on the export button state adn delete the trace image
func on_close_export_window():

	outputlog("on_close_export_window", 2)

	show_hide_traceimage(export_trace_image_button.pressed, true)
	delete_trace_sprite()

# True when the selected export format is Universal VTT (.dd2vtt).
# The format picker is the "ExportModeOptions" OptionButton (PNG / JPEG /
# WEBP / Universal VTT, then mod formats). Matched by text so it keeps
# working if the order changes.
func is_uvtt_export_selected() -> bool:
	var export_dialog = _g.Editor.Windows["Export"]
	if export_dialog == null:
		return false
	var mode_opt = export_dialog.find_node("ExportModeOptions", true, false)
	if mode_opt == null:
		return false
	if mode_opt.selected < 0:
		return false
	return mode_opt.get_item_text(mode_opt.selected) == "Universal VTT"

# Parent node of the trace sprite.
# Image formats (PNG/JPG/WEBP): under Objects, as originally.
# Universal VTT: directly under the LEVEL node. Exporter.ExportObjectsLOS()
# iterates Objects with foreach (Prop prop in Objects.GetChildren()); a
# Sprite there would be cast to Prop -> InvalidCastException -> the JSON
# bake fails and DD leaves a "<name>.dd2vtt.png" without the .dd2vtt. The
# level node is rendered (so the trace lands in the embedded image) but is
# NOT serialized by the bake.
func get_trace_parent(level):
	if is_uvtt_export_selected():
		return level
	return level.Objects

# ── Lighting-aware z ──────────────────────────────────────────────────
# DD lights a level by capturing the screen (LightPassBBC) and redrawing it
# through DeferredLighting.shader: whatever is drawn before the capture is
# lit, whatever comes after is not. During export the source level sits at
# z -2000, so the sprite uses an ABSOLUTE z computed from the live nodes to
# land on the same side of the lighting pass as on the map.

const CANVAS_Z_MAX = 4096
const CANVAS_Z_MIN = -4096

# Sum of z_index from node up to (excluding) stop, honouring z_as_relative.
func _rel_z(node, stop) -> int:
	var z := 0
	var n = node
	while n != null and n != stop:
		if n is Node2D:
			z += n.z_index
			if not n.z_as_relative:
				return z
		n = n.get_parent()
	return z

# Absolute z of a node.
func _abs_z(node) -> int:
	return _rel_z(node, null)

# z of the lighting pass relative to its Level node, or null.
func _lighting_rel_z(level):
	if level == null:
		return null
	var best = null
	for prop in ["LightPassBBC", "LightPassRender"]:
		var node = level.get(prop)
		if node != null and is_instance_valid(node):
			var z = _rel_z(node, level)
			if best == null or z < best:
				best = z
	return best

# Lighting option set by trace_extended (saved in ModMapData). Fallback when
# absent: lit if the trace sits below the lighting pass on the map.
func _trace_is_lit(level) -> bool:
	if _g.get("ModMapData") != null and _g.ModMapData is Dictionary:
		var st = _g.ModMapData.get("_trace_extended")
		if st is Dictionary and st.has("lit"):
			return bool(st["lit"])
	var lz = _lighting_rel_z(level)
	if lz == null or _g.World.TraceImage == null:
		return true
	return _g.World.TraceImage.z_index < lz

func apply_trace_sprite_z(level) -> void:
	if trace_sprite == null or _g.World.TraceImage == null:
		return
	trace_sprite.z_as_relative = false
	var level_z = _abs_z(level)
	var trace_z = int(_g.World.TraceImage.z_index)
	var lz = _lighting_rel_z(level)
	var z
	if lz == null:
		z = level_z + trace_z
	elif _trace_is_lit(level):
		# Same layer as on the map, kept below the source level's lighting.
		z = level_z + int(min(trace_z, lz - 1))
	else:
		# Above every lighting pass (source at -2000, overlay at 0) and above
		# ExportFX (brightness/focus redraw of the captured screen).
		z = lz + 1
		var fx = _g.World.get("ExportFX")
		if fx != null and is_instance_valid(fx):
			z = int(max(z, _abs_z(fx) + 1))
	trace_sprite.z_index = int(clamp(z, CANVAS_Z_MIN, CANVAS_Z_MAX))
	outputlog("trace_sprite z_index set to: " + str(trace_sprite.z_index), 2)

# Function to create a trace sprite as a visible copy of the Trace Image
func create_trace_sprite():

	outputlog("create_trace_sprite", 2)

	# If there is no trace image then do nothing
	if _g.World.TraceImage == null:
		outputlog("_g.World.TraceImage is null. Delete the traceimage if it exists.",2)
		delete_trace_sprite()
		return

	if not _g.World.TraceImage.is_connected("visibility_changed", self, "trace_image_visibility_changed"):
		_g.World.TraceImage.connect("visibility_changed", self, "trace_image_visibility_changed")

	# If the trace image on export button is disabled
	if not export_trace_image_button.pressed:
		outputlog("export_trace_image_button is not pressed. Delete the traceimage if it exists.",2)
		delete_trace_sprite()
		return

	var level = _g.World.levels[source_level_optionbutton.selected]
	var target_parent = get_trace_parent(level)
	# If there is a current trace image sprite then update it
	if trace_sprite != null:
		outputlog("move trace image to current level",2)
		trace_sprite.visible = true
		if trace_sprite.get_parent() != null:
			if trace_sprite.get_parent() != target_parent:
				trace_sprite.get_parent().remove_child(trace_sprite)
				target_parent.add_child(trace_sprite)
	# If there is no trace image sprite then make one
	else:
		outputlog("create new trace image",2)
		trace_sprite = Sprite.new()
		# Add it to the current level (Objects for images, level node for UVTT)
		target_parent.add_child(trace_sprite)

	trace_sprite.texture = _g.World.TraceImage.texture
	trace_sprite.position = _g.World.TraceImage.position
	trace_sprite.scale = _g.World.TraceImage.scale
	trace_sprite.rotation = _g.World.TraceImage.rotation
	# Layer + lighting option from trace_extended, as an absolute z.
	apply_trace_sprite_z(level)
	# Copy material (carries the combined blur + blend-mode shader if active).
	trace_sprite.material = _g.World.TraceImage.material
	
	# Set the opacity to TraceImage opacity
	trace_sprite.set_modulate(Color(1.0,1.0,1.0,_g.Editor.Tools["TraceImage"].Opacity.value))

# Function to delete the trace sprite when the export window is closed.
func delete_trace_sprite():

	outputlog("delete_trace_sprite", 2)

	# Delete the trace_sprite
	if trace_sprite != null:
		if trace_sprite.get_parent() != null:
			trace_sprite.get_parent().remove_child(trace_sprite)
		trace_sprite.queue_free()
		trace_sprite = null

# Function to enable or disable the trace image on export
func on_export_trace_image_button_toggled(button_pressed: bool):

	outputlog("on_export_trace_image_button_toggled: " + str(button_pressed),2)

	show_hide_traceimage(false, true)

	if button_pressed:
		create_trace_sprite()
	else:
		delete_trace_sprite()


#########################################################################################################
##
## _LIB CONFIG FUNCTIONS
##
#########################################################################################################

func make_lib_configs():

	if _g == null or _g.get("API") == null or _g.API.get("ModConfigApi") == null:
		return

	# Create a config builder to ensure we can update the offset if needed
	var _lib_config_builder = _g.API.ModConfigApi.create_config()
	_lib_config_builder\
		.h_box_container().enter()\
			.label("Core Log Level ")\
			.option_button("core_log_level", 0, ["0","1","2","3","4"])\
		.exit()
	_lib_mod_config = _lib_config_builder.build()

	logging_level = int(_lib_mod_config.core_log_level)

#########################################################################################################
##
## MAIN START FUNCTION
##
#########################################################################################################

# Main Script
func start() -> void:

	outputlog("ExportTraceImage Mod Has been loaded.")

	# If _Lib is installed, use ModConfigApi directly without registering via
	# emit_signal (crashes when _g is not yet injected by UnofficialPatch).
	# NOTE: no UpdateChecker registration here — the suite registers once in
	# Main.gd.
	if Engine.has_signal("_lib_register_mod"):
		make_lib_configs()

	# Find the export window
	var export_dialog = _g.Editor.Windows["Export"]
	if export_dialog == null:
		print("[ETI] Export dialog not found, skipping")
		return
	export_dialog.connect("about_to_show", self, "on_launch_export_window")
	export_dialog.connect("popup_hide", self, "on_close_export_window")
	var okay_btn = export_dialog.find_node("OkayButton")
	if okay_btn != null:
		okay_btn.connect("pressed", self, "set_trace_sprite_visibilty_on_export")
	source_level_optionbutton = export_dialog.find_node("SourceLevelOptions")
	if source_level_optionbutton != null:
		source_level_optionbutton.connect("item_selected", self, "on_source_level_changed")
	# Don't add the button if it already exists (duplicate mod)
	var valign = export_dialog.find_node("VAlign")
	if valign != null:
		for child in valign.get_children():
			if child is CheckButton and child.get("text") == "Export Trace Image":
				print("[ETI] button already exists, skipping")
				return
	export_trace_image_button = CheckButton.new()
	export_trace_image_button.text = "Export Trace Image"
	export_trace_image_button.name = "ExportTraceImageBtn"
	export_trace_image_button.hint_tooltip = "Enable to export the trace image with the settings as configured in the Trace Image tool."
	export_trace_image_button.connect("toggled", self, "on_export_trace_image_button_toggled")
	export_trace_image_button.size_flags_horizontal = 4
	if valign != null:
		valign.add_child(export_trace_image_button)
		if okay_btn != null:
			valign.move_child(export_trace_image_button, okay_btn.get_index())
