extends Reference

# Callback History Record.
#
# Generic undo/redo via caller-provided methods. The record doesn't know
# anything about what's being changed; it just invokes the given method on
# the given target with the given arguments.
#
# Undo and redo get their own separate (target, method, args) triplets so
# an asymmetric action can still be reversed cleanly. Most of the time
# they'll share the target and method but differ in args.

var undo_target = null
var undo_method: String = ""
var undo_args: Array = []

var redo_target = null
var redo_method: String = ""
var redo_args: Array = []


func undo() -> void:
	if undo_target == null or not is_instance_valid(undo_target):
		return
	if not undo_target.has_method(undo_method):
		return
	undo_target.callv(undo_method, undo_args)


func redo() -> void:
	if redo_target == null or not is_instance_valid(redo_target):
		return
	if not redo_target.has_method(redo_method):
		return
	redo_target.callv(redo_method, redo_args)
