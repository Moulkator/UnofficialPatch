# LevelSettingsFix.gd
# Fait grandir la Tree de la section "Levels" du panel Level Settings pour
# qu'elle occupe tout l'espace vertical disponible, au lieu d'etre figee a
# une petite hauteur qui force a scroller des qu'on a quelques niveaux.

var _g
var _applied = false
var _retry_count = 0
const MAX_RETRIES = 600  # ~10s a 60fps avant d'abandonner silencieusement


func initialize() -> void:
	pass


func update(_delta) -> void:
	if _applied:
		return
	if _g == null or _g.Editor == null:
		return
	var panel = null
	if _g.Editor.Toolset != null and _g.Editor.Toolset.has_method("GetToolPanel"):
		panel = _g.Editor.Toolset.GetToolPanel("LevelSettings")
	if panel == null or not is_instance_valid(panel) or panel.get_child_count() == 0:
		_retry_count += 1
		if _retry_count > MAX_RETRIES:
			_applied = true  # abandon : evite de polluer update()
		return
	_apply_fix(panel)


func _apply_fix(panel) -> void:
	var tree = _find_tree(panel)
	if tree == null:
		_retry_count += 1
		if _retry_count > MAX_RETRIES:
			_applied = true
		return

	# 1) La Tree elle-meme : autoriser l'expansion verticale + retirer
	#    la min_size en hauteur (souvent figee par DD a ~150-200px).
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var ms = tree.rect_min_size
	if ms.y > 0:
		tree.rect_min_size = Vector2(ms.x, 0)

	# 2) Remonter dans les parents : si l'un d'eux est un Container avec
	#    size_flags fill non-expand, l'expansion de la Tree sera bloquee.
	#    On force expand_fill sur la chaine jusqu'au panel.
	var parent = tree.get_parent()
	var safety = 0
	while parent != null and parent != panel and safety < 16:
		if parent is Container:
			parent.size_flags_vertical = Control.SIZE_EXPAND_FILL
			var pms = parent.rect_min_size
			# On ne touche au min_size du parent que s'il est tres faible
			# (= contraint la Tree). On evite de detruire un layout volontaire.
			if pms.y > 0 and pms.y < 300:
				parent.rect_min_size = Vector2(pms.x, 0)
		parent = parent.get_parent()
		safety += 1

	_applied = true
	print("[LevelSettingsFix] Levels tree expanded to fill panel")


# Cherche recursivement le premier Tree dans la hierarchie du panel.
# Le panel LevelSettings n'en contient qu'un (la liste des levels).
func _find_tree(node):
	if node == null or not is_instance_valid(node):
		return null
	if node is Tree:
		return node
	for child in node.get_children():
		var r = _find_tree(child)
		if r != null:
			return r
	return null
