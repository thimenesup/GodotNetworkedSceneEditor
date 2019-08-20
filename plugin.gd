#Networked Editor plugin
tool
extends EditorPlugin

var dock = null

func _enter_tree():
	dock = preload("dock.tscn").instance()
	dock.plugin = self
	dock.editor_interface = get_editor_interface()
	
	add_control_to_dock(DOCK_SLOT_LEFT_UL, dock)

func _exit_tree():
	remove_control_from_docks(dock)
	dock.free()
