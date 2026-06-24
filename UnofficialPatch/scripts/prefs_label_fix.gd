# prefs_label_fix.gd
# Small always-on fix : populate the empty "Window BG Tint" Label in
# Preferences > Interface > BGTints. In vanilla DD, that Label has an empty
# string by default, which makes the BGTint section look broken.
#
# This used to be done by popup_blur.gd, but Blurred Popup Background can
# now be disabled in Unofficial Patch settings. We split the label fix out
# so it always runs, regardless of the Blurred Background toggle.

var _g
var _fixed := false


func initialize() -> void:
	pass


func update(_delta) -> void:
	if _fixed:
		return
	if _g == null or _g.Editor == null:
		return
	var prefs = _g.Editor.get_node_or_null("Windows/Preferences")
	if prefs == null:
		return
	var label3 = prefs.get_node_or_null("Margins/VAlign/Interface/BGTints/Label3")
	if label3 == null or not (label3 is Label):
		return
	if label3.text == "":
		label3.text = "Window BG Tint"
		print("[PrefsLabelFix] Fixed missing 'Window BG Tint' label")
	_fixed = true
