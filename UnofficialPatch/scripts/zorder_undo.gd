extends Reference

# zorder_undo.gd
# ─────────────────────────────────────────────────────────────────────────────
# Undo/redo support for the SelectTool panel's "Bring to Front" and
# "Send to Back" buttons.
#
# Vanilla DD wires those two buttons straight to SelectTool.BringToFront() /
# SendToBack(), which just call parent.MoveToFront/MoveToBack on every
# selected thing WITHOUT creating any HistoryRecord — so Ctrl+Z never
# reverts a z-order change.
#
# Fix (no vanilla code touched, buttons stay connected to DD):
#   * We take OWNERSHIP of the button: DD's native "pressed" connection is
#     disconnected and replaced by a single handler of ours that does
#     snapshot → direct call to SelectTool.BringToFront()/SendToBack() →
#     record. One connection, deterministic order, immune to how "pressed"
#     is triggered (mouse click, or emit_signal from third-party shortcut
#     mods like Minor Utils) and to whatever other mods (LayersPanel, CMT,
#     Minor Utils...) connect to the same button. Signal-order bracketing
#     was tried first and proved unreliable in multi-mod setups.
#     The native connection is restored on cleanup().
#   * After the native call we read the new indices; if anything moved we
#     push a callback record into DD's History via undo_lib (level 3).
#   * Undo restores the old indices, redo the new ones, both through
#     move_child() — the exact operation MoveToFront/MoveToBack performs,
#     so DD sees nothing it wouldn't have done itself.
#
# Restoring a permutation from partial data is safe here because the native
# action only relocates SELECTED things: the relative order of unselected
# siblings is never disturbed, so applying the saved indices to the moved
# things (sorted ascending) reconstructs the original arrangement exactly.
#
# The two buttons are local variables in SelectToolPanel.cs (not fields), so
# panel.get("...") can't reach them — we locate them by their icon resource
# path ("misc/over.png" / "misc/under.png"), which is unique in that panel.
# ─────────────────────────────────────────────────────────────────────────────

var _g

var _front_btn_wr: WeakRef = null
var _back_btn_wr: WeakRef = null
var _hook_attempts := 0
const MAX_HOOK_ATTEMPTS := 600

# Pre-state captured just before the native call, consumed just after.
# Array of {"wr": WeakRef(thing), "pwr": WeakRef(parent), "old": int, "new": int}
var _pending: Array = []
var _has_pending := false


func initialize() -> void:
	print("[ZOrderUndo] Ready")


func cleanup() -> void:
	_unhook_button(_front_btn_wr, "_on_front_pressed", "BringToFront")
	_unhook_button(_back_btn_wr, "_on_back_pressed", "SendToBack")
	_front_btn_wr = null
	_back_btn_wr = null
	_pending = []
	_has_pending = false


func update(_delta: float) -> void:
	# (Re)hook whenever the buttons are missing or were freed (panel rebuild).
	if not _buttons_valid():
		_try_hook_buttons()


# ─── Hooking ─────────────────────────────────────────────────────────────────

func _buttons_valid() -> bool:
	if _front_btn_wr == null or _back_btn_wr == null:
		return false
	var f = _front_btn_wr.get_ref()
	var b = _back_btn_wr.get_ref()
	return f != null and is_instance_valid(f) and b != null and is_instance_valid(b)


func _try_hook_buttons() -> void:
	if _hook_attempts > MAX_HOOK_ATTEMPTS:
		return  # give up quietly (panel never found / unexpected DD build)
	_hook_attempts += 1
	if _g == null or _g.get("Editor") == null:
		return
	var editor = _g.Editor
	if not is_instance_valid(editor) or editor.get("Toolset") == null:
		return
	var panel = editor.Toolset.GetToolPanel("SelectTool")
	if panel == null or not is_instance_valid(panel):
		return

	# Search inside layerSection first — the exact container DD puts the two
	# buttons in (and where Minor Utils' shortcuts grab them), so we can't
	# accidentally hook a same-icon button added elsewhere by another mod.
	var search_root = panel.get("layerSection")
	if search_root == null or not (search_root is Node):
		search_root = panel
	var front_btn = _find_button_by_icon(search_root, "misc/over.png")
	var back_btn = _find_button_by_icon(search_root, "misc/under.png")
	if front_btn == null or back_btn == null:
		return

	var select_tool = _get_select_tool()
	if select_tool == null:
		return
	_take_ownership(front_btn, select_tool, "BringToFront", "_on_front_pressed")
	_take_ownership(back_btn, select_tool, "SendToBack", "_on_back_pressed")

	_front_btn_wr = weakref(front_btn)
	_back_btn_wr = weakref(back_btn)
	_hook_attempts = 0  # reset so a later panel rebuild gets a fresh budget
	print("[ZOrderUndo] Bring to Front / Send to Back buttons hooked")


func _find_button_by_icon(root: Node, icon_suffix: String):
	# Index-based walk (no get_children() allocation in a possibly deep tree).
	for i in range(root.get_child_count()):
		var c = root.get_child(i)
		if c is Button:
			var ic = c.get("icon")
			if ic != null and ic is Texture and ic.resource_path.ends_with(icon_suffix):
				return c
		var found = _find_button_by_icon(c, icon_suffix)
		if found != null:
			return found
	return null


# Take ownership of one button: remove DD's native "pressed" connection and
# route "pressed" to our handler, which performs the native call itself
# between the snapshot and the record. Other mods' connections on the same
# button are left untouched and keep firing whenever they were connected —
# they no longer matter, since our snapshot/native/record sequence is a
# single synchronous handler.
func _take_ownership(btn, select_tool, native_method: String, handler: String) -> void:
	if btn.is_connected("pressed", self, handler):
		return
	if btn.is_connected("pressed", select_tool, native_method):
		btn.disconnect("pressed", select_tool, native_method)
	# If the native connection was already gone (another mod took it, or an
	# unexpected build), that's fine: our handler calls the native method
	# directly, so the button keeps working either way.
	btn.connect("pressed", self, handler)


func _unhook_button(wr: WeakRef, handler: String, native_method: String) -> void:
	if wr == null:
		return
	var btn = wr.get_ref()
	if btn == null or not is_instance_valid(btn):
		return
	if btn.is_connected("pressed", self, handler):
		btn.disconnect("pressed", self, handler)
	# Restore DD's native connection so the button keeps working without us.
	var select_tool = _get_select_tool()
	if select_tool != null and not btn.is_connected("pressed", select_tool, native_method):
		btn.connect("pressed", select_tool, native_method)


func _snapshot_selection() -> void:
	_pending = []
	_has_pending = false
	var select_tool = _get_select_tool()
	if select_tool == null:
		return
	# Selected is a C# getter returning a fresh List<Node2D> — safe to read.
	var sel = select_tool.get("Selected")
	if sel == null:
		return
	for thing in sel:
		if thing == null or not is_instance_valid(thing):
			continue
		var p = thing.get_parent()
		if p == null:
			continue
		_pending.append({
			"wr": weakref(thing),
			"pwr": weakref(p),
			"old": thing.get_index(),
			"new": -1,
		})
	_has_pending = not _pending.empty()


# ─── Ownership handlers: snapshot → native move → record ─────────────────────

func _on_front_pressed() -> void:
	_do_native_with_record("BringToFront")


func _on_back_pressed() -> void:
	_do_native_with_record("SendToBack")


func _do_native_with_record(native_method: String) -> void:
	var select_tool = _get_select_tool()
	if select_tool == null:
		return
	_snapshot_selection()
	select_tool.call(native_method)
	_record_if_changed()


func _record_if_changed() -> void:
	if not _has_pending:
		return
	var entries = _pending
	_pending = []
	_has_pending = false

	var changed := false
	for e in entries:
		var thing = e["wr"].get_ref()
		if thing == null or not is_instance_valid(thing):
			continue
		e["new"] = thing.get_index()
		if e["new"] != e["old"]:
			changed = true
	if not changed:
		return  # not editing, single unmoved item, etc. — nothing to undo

	var undo = _g.ModMapData.get("_undo_lib") if _g.ModMapData != null else null
	if undo == null:
		print("[ZOrderUndo] WARN: undo_lib not available, z-order change not undoable")
		return
	var ok = undo.record_callback(
		self, "_apply_zorder", [entries, true],
		self, "_apply_zorder", [entries, false])


# ─── Undo/redo application ───────────────────────────────────────────────────

# Reapplies the saved child indices ("old" when use_old, else "new") via
# move_child(). Entries are applied in ascending target-index order, which
# reconstructs the exact permutation (see header comment). Things that were
# freed or reparented since the record was made are skipped.
func _apply_zorder(entries: Array, use_old: bool) -> void:
	var key = "old" if use_old else "new"
	var todo := []
	for e in entries:
		var idx = e[key]
		if not (idx is int) or idx < 0:
			continue
		var thing = e["wr"].get_ref()
		if thing == null or not is_instance_valid(thing):
			continue
		var parent = e["pwr"].get_ref()
		if parent == null or not is_instance_valid(parent):
			continue
		if thing.get_parent() != parent:
			continue  # reparented since (level move, delete/undo churn) — skip
		todo.append({"thing": thing, "parent": parent, "idx": idx})
	if todo.empty():
		return
	todo.sort_custom(self, "_cmp_idx")
	for t in todo:
		var idx = t["idx"]
		var cc = t["parent"].get_child_count()
		if idx >= cc:
			idx = cc - 1
		t["parent"].move_child(t["thing"], idx)
	# Tell preserve_selection_undo that this undo/redo DID touch the previous
	# selection: a z-order change is invisible to its transform fingerprints
	# (only child indices moved), so without this hint it would refuse to
	# restore the selection after Ctrl+Z on a front/back action.
	Engine.set_meta("_zorder_undo_applied_frame", Engine.get_idle_frames())


func _cmp_idx(a, b) -> bool:
	# sort_custom is unstable in Godot 3; tie-break on instance id so equal
	# indices (cross-parent) keep a deterministic order.
	if a["idx"] == b["idx"]:
		return a["thing"].get_instance_id() < b["thing"].get_instance_id()
	return a["idx"] < b["idx"]


# ─── Helpers ─────────────────────────────────────────────────────────────────

func _get_select_tool():
	if _g == null or _g.get("Editor") == null:
		return null
	var editor = _g.Editor
	if not is_instance_valid(editor):
		return null
	var tools = editor.get("Tools")
	if tools == null or not (tools is Dictionary) or not tools.has("SelectTool"):
		return null
	return tools["SelectTool"]
