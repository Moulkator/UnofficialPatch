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
			if _g.World.TraceImage != null:
				trace_sprite.z_index = _g.World.TraceImage.z_index + get_trace_z_offset(level)

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

# Detecte si le format d'export selectionne est Universal VTT (.dd2vtt).
# Le bouton de format est l'OptionButton "ExportModeOptions" (items :
# PNG / JPEG / WEBP / Universal VTT, puis formats de mods). On teste par
# texte pour rester robuste si l'ordre change.
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

# Nœud parent du trace sprite.
# En image (PNG/JPG/WEBP) : sous Objects, comme a l'origine.
# En Universal VTT : sous le nœud du NIVEAU directement. Objects est itere
# par Exporter.ExportObjectsLOS() avec foreach (Prop prop in
# Objects.GetChildren()) ; un Sprite y serait casté en Prop ->
# InvalidCastException -> le bake JSON plante et DD laisse un
# "<nom>.dd2vtt.png" sans .dd2vtt. Le nœud du niveau est rendu (le calque
# part donc bien dans l'image embarquee du .dd2vtt) mais n'est PAS
# serialise par le bake.
func get_trace_parent(level):
	if is_uvtt_export_selected():
		return level
	return level.Objects

# Decalage de z selon le parent, pour conserver le meme calque qu'en mode
# image : sous le niveau, on ajoute le z_index du nœud Objects.
func get_trace_z_offset(level) -> int:
	if is_uvtt_export_selected():
		var obj = level.Objects
		if obj != null:
			return int(obj.z_index)
	return 0

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
		# Add it to the current level (Objects en image, nœud du niveau en UVTT)
		target_parent.add_child(trace_sprite)

	trace_sprite.texture = _g.World.TraceImage.texture
	trace_sprite.position = _g.World.TraceImage.position
	trace_sprite.scale = _g.World.TraceImage.scale
	trace_sprite.rotation = _g.World.TraceImage.rotation
	# Use the TraceImage's current z_index (set by trace_extended layer slider,
	# or default), compense selon le parent pour garder le meme calque.
	trace_sprite.z_index = _g.World.TraceImage.z_index + get_trace_z_offset(level)
	# Copy material (carries the combined blur + blend-mode shader if active).
	# Blend modes read SCREEN_TEXTURE, so the sprite must draw above the baked
	# map (its z_index already places it there) for the composite to be correct.
	trace_sprite.material = _g.World.TraceImage.material
	outputlog("trace_sprite z_index set to: " + str(trace_sprite.z_index), 2)
	
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
## VERSION CHECKER FUNCTIONS
##
#########################################################################################################

# Check whether a semver strng 2 is greater than string one. Only works on simple comparisons - DO NOT USE THIS FUNCTION OUTSIDE THIS CONTEXT
func compare_semver(semver1: String, semver2: String) -> bool:

	outputlog("compare_semver: semver1: " + str(semver1) + " semver2" + str(semver2),2)
	var semver1data = get_semver_data(semver1)
	var semver2data = get_semver_data(semver2)

	if semver1data == null || semver2data == null : return false

	if semver1data["major"] != semver2data["major"]:
		return semver1data["major"] < semver2data["major"]
	if semver1data["minor"] != semver2data["minor"]:
		return semver1data["minor"] < semver2data["minor"]
	if semver1data["patch"] != semver2data["patch"]:
		return semver1data["patch"] < semver2data["patch"]
	
	return false

# Parse the semver string
func get_semver_data(semver: String):

	var data = {}

	if semver.split(".").size() < 3: return null

	return {
		"major": int(semver.split(".")[0]),
		"minor": int(semver.split(".")[1]),
		"patch": int(semver.split(".")[2].split("-")[0])
	}

#########################################################################################################
##
## MAIN START FUNCTION
##
#########################################################################################################

# Main Script
func start() -> void:

	outputlog("ExportTraceImage Mod Has been loaded.")

	# If _Lib is installed, use ModConfigApi and ModRegistry directly without
	# registering via emit_signal (crashes when _g is not yet injected by UnofficialPatch)
	if Engine.has_signal("_lib_register_mod"):
		make_lib_configs()
		if _g != null and _g.get("API") != null and _g.API.get("ModRegistry") != null:
			var _lib_info = _g.API.ModRegistry.get_mod_info("CreepyCre._Lib")
			if _lib_info != null:
				var _lib_mod_meta = _lib_info.get("mod_meta")
				if _lib_mod_meta != null and compare_semver("1.1.2", _lib_mod_meta["version"]):
					var update_checker = _g.API.UpdateChecker
					update_checker.register(_g.API.UpdateChecker.builder()\
						.fetcher(update_checker.github_fetcher("uchideshi34", "ExportTraceImage"))\
						.downloader(update_checker.github_downloader("uchideshi34", "ExportTraceImage"))\
						.build())

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
	# Ne pas ajouter le bouton si deja present (doublon de mod)
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
