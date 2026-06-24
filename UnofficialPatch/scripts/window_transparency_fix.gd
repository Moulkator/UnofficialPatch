# window_transparency_fix.gd
#
# When Assets opens a second time over New, Dungeondraft incorrectly dims
# Assets itself even though it is the foreground window.
# Fix: the last visible window in the Windows node is always the topmost one
# and must never be dimmed.

var _g

var _startup_timer = 5.0
var _check_timer = 0.0
var _log_lines = []

func initialize():
	pass

func update(delta):
	if _startup_timer > 0.0:
		_startup_timer -= delta
		return

	_check_timer -= delta
	if _check_timer > 0.0:
		return
	_check_timer = 0.1

	var tree = Engine.get_main_loop()
	if tree == null:
		return
	var root = tree.root
	if not is_instance_valid(root):
		return

	var windows = root.get_node_or_null("Master/Editor/Windows")
	if windows == null:
		return

	# Find the last visible child = the topmost window.
	var topmost = null
	for child in windows.get_children():
		if not is_instance_valid(child):
			continue
		if not (child is CanvasItem):
			continue
		if child.visible:
			topmost = child

	# The topmost window must always be fully opaque.
	if topmost != null and topmost.modulate.a < 0.99:
		# Log this occurrence before fixing it.
		var visible_names = []
		for child in windows.get_children():
			if is_instance_valid(child) and child is CanvasItem and child.visible:
				visible_names.append(child.name + "(a=" + str(child.modulate.a) + ")")
		var entry = "FIXED topmost=" + topmost.name + " | all_visible=" + str(visible_names)
		_log_lines.append(entry)
		_flush_log()
		topmost.modulate.a = 1.0

func _flush_log():
	var file = File.new()
	var err = file.open("user://UnofficialPatch/wtf_transparency.txt", File.WRITE)
	if err != OK:
		return
	for line in _log_lines:
		file.store_line(line)
	file.close()

