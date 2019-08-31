#Networked Editor plugin
tool
extends Control


onready var peer_tree = $Input/Peers

var plugin = null
var editor_interface = null

var scene_tree_dock = null
var scene_tree_editor = null
var scene_tree = null

var network = NetworkedMultiplayerENet.new()

var editor_peers = {} #Network ID:EditorPeer

var open_scene_nodes = []
var current_scene_root = null
var current_scene = ""


#This is a hack to prevent the node_added/removed signals from triggering when opening/closing scenes etc
var node_rearranged_signals = 0
var scene_changed_signals = 0

signal process_started()

func _process(delta):
	emit_signal("process_started")
	node_rearranged_signals = 0
	scene_changed_signals = 0


func _ready():
	var root = peer_tree.create_item()
	peer_tree.set_hide_root(true)
	
	network.allow_object_decoding = true
	
	if editor_interface.get_open_scenes().size() > 0:
		push_warning("Close all scenes and open them again in order to let the plugin get their Root Node!")
	
	var inspector = editor_interface.get_inspector()
	inspector.connect("property_edited",self,"_inspector_property_edited")
	
	get_tree().connect("node_added",self,"_node_added")
	get_tree().connect("node_removed",self,"_node_removed")
	
	get_scene_tree_dock()
	if not scene_tree_dock.has_method("get_tree_editor"):
		push_warning("Scene Tree Dock doesn't have get_tree_editor() exposed!")
	else:
		scene_tree_editor = scene_tree_dock.get_tree_editor() #Not exposed to GDScript by default!
		#scene_tree_editor.connect("files_dropped",self,"_files_dropped") #TODO: Consider using this as add nodes/scene signal instead?
		scene_tree_editor.connect("node_prerename",self,"_node_prerename")
		scene_tree_editor.connect("nodes_rearranged",self,"_nodes_rearranged")
	
	plugin.connect("scene_changed",self,"_scene_changed")
	plugin.connect("scene_closed",self,"_scene_closed")
	
	network.connect("peer_disconnected",self,"_peer_disconnected")
	
	network.connect("connection_succeeded",self,"_connected_to_server")
	network.connect("server_disconnected",self,"_server_disconnected")


func _input(event):
	if event is InputEventKey:
		if event.scancode == KEY_CONTROL and event.pressed:
			var nodes = editor_interface.get_selection().get_transformable_selected_nodes()
			
			var paths = []
			var transform_data = []
			for node in nodes:
				paths.append(current_scene_root.get_path_to(node))
				if node is Spatial:
					transform_data.append(node.transform)
				if node is Node2D:
					transform_data.append(node.transform)
				if node is Control:
					transform_data.append(node.get_rect())
			
			for peer in get_scene_peers(current_scene):
				rpc_id(peer,"set_transforms",current_scene, paths,transform_data)


func _on_Host_pressed():
	print("Hosting")
	network.create_server( int($Input/Port.text) )
	get_tree().network_peer = network
	get_tree().multiplayer.set_root_node(self)
	
	peer_connected(get_tree().get_network_unique_id(), $Input/Name.text, editor_interface.get_open_scenes())
	
	toggle_conection_buttons(false)

func _on_Connect_pressed():
	print("Connecting")
	network.create_client($Input/IP.text, int($Input/Port.text) )
	get_tree().network_peer = network
	get_tree().multiplayer.set_root_node(self)
	
	toggle_conection_buttons(false)

func _on_Disconnect_pressed():
	print("Disconnecting")
	network.close_connection()
	toggle_conection_buttons(true)
	
	peer_tree.clear()
	var root = peer_tree.create_item()
	peer_tree.set_hide_root(true)


func toggle_conection_buttons(toggle):
	$Input/Host.disabled = !toggle
	$Input/Connect.disabled = !toggle
	$Input/Disconnect.disabled = toggle



puppet func load_peers(ids,names,scenes):
	var i = 0
	while i < ids.size():
		peer_connected(ids[i],names[i],scenes[i])
		i+=1

func _connected_to_server():
	print("Connected to Host")
	var opened_scenes = editor_interface.get_open_scenes()
	rpc_id(1,"connected_to_server", $Input/Name.text)

master func connected_to_server(peer_name, peer_scenes = []): #Called by connecting client
	var id = get_tree().get_rpc_sender_id()
	
	var ids = editor_peers.keys()
	var names = []
	var scenes = []
	for editor_peer in editor_peers.values():
		names.append(editor_peer.nickname)
		scenes.append(editor_peer.opened_scenes)
	
	rpc_id(id,"load_peers", ids,names,scenes) #Send peer data
	rpc("peer_connected",id,peer_name,peer_scenes)

puppetsync func peer_connected(id, peer_name, scenes = []): #Use this instead of signal for extra data
	print("Editor peer %s connected" % id)
	var editor_peer = EditorPeer.new()
	editor_peer.nickname = peer_name
	editor_peer.opened_scenes = scenes
	editor_peers[id] = editor_peer
	
	add_peer_tree_item(id,peer_name)
	for scene in scenes:
		add_scene_tree_item(id,scene)

func _peer_disconnected(id): #Signal for disconnection is good enough
	print("Editor peer %s disconnected" % id)
	editor_peers.erase(id)
	erase_peer_tree_item(id)

func _server_disconnected():
	print("Host disconnected")
	toggle_conection_buttons(true)
	
	peer_tree.clear()
	var root = peer_tree.create_item()
	peer_tree.set_hide_root(true)



remote func set_transforms(scene, node_paths,transform_data):
	var scene_root = get_scene_node(scene)
	
	var i = 0
	while i < node_paths.size():
		var path = node_paths[i]
		var node = scene_root.get_node(path)
		if node is Spatial:
			node.transform = transform_data[i]
		if node is Node2D:
			node.transform = transform_data[i]
		if node is Control:
			var rect = transform_data[i] as Rect2
			node.rect_position = rect.position
			node.rect_size = rect.size
		
		i+=1


func _inspector_property_edited(property):
	var nodes = editor_interface.get_selection().get_selected_nodes()
	#print("Edited property:%s from nodes:%s" % [property,nodes])
	
	for i in range(nodes.size()):
		var resource_class = ""
		var value = nodes[i].get(property)
		if value is Resource and not value.resource_path.empty():
			resource_class = value.get_class()
			value = value.resource_path
		
		var path = current_scene_root.get_path_to(nodes[i])
		
		for peer in get_scene_peers(current_scene):
			rpc_id(peer,"edit_property",current_scene ,path,property,value, resource_class)

remote func edit_property(scene, node_path,property,value, resource_class): 
	var scene_root = get_scene_node(scene)
	
	var node = scene_root.get_node(node_path)
	print("Node:%s Property:%s Value: %s set by peer %s" % [node,property,value,get_tree().get_rpc_sender_id()])
	if not resource_class.empty():
		var path = value
		value = load(path)
		if value == null: #Create dummy resource
			value = ClassDB.instance(resource_class)
			ResourceSaver.save(path, value)
	node.set(property,value)



func _node_added(node):
	if not node_belongs_in_edited_scene(node):
		return
	
	yield(self,"process_started")
	if node_rearranged_signals > 0 or scene_changed_signals > 0:
		return
	
	if node.owner != current_scene_root: #That node is a child of a packed scene instance, ignore
		return
	
	#print("Node added:%s Named:%s" % [node,node.name])
	var parent_path = current_scene_root.get_path_to(node.get_parent())
	var node_string = node.get_class()
	if not node.filename.empty():
		node_string = node.filename
	
	for peer in get_scene_peers(current_scene):
		rpc_id(peer,"add_node",current_scene ,parent_path,node.name,node_string)

remote func add_node(scene, parent_path,node_name,node_str): 
	var instance = null
	if ClassDB.class_exists(node_str):
		instance = ClassDB.instance(node_str)
	else:
		var packed_scene = load(node_str)
		if packed_scene == null: #Create dummy packed scene
			packed_scene = PackedScene.new()
			var node = Node.new()
			node.name = node_name
			node.owner = node
			packed_scene.pack(node)
			ResourceSaver.save(node_str, packed_scene)
		instance = packed_scene.instance()
	if not instance:
		return
	
	var scene_root = get_scene_node(scene)
	
	instance.name = node_name
	var parent = scene_root.get_node(parent_path)
	
	print("Node %s Named:%s added as child to %s by peer %s" % [instance,instance.name,parent.name,get_tree().get_rpc_sender_id()])
	
	#Dis/connect signals to avoid recursively calling
	get_tree().disconnect("node_added",self,"_node_added")
	parent.add_child(instance)
	instance.set_owner(scene_root)
	get_tree().connect("node_added",self,"_node_added")


func _node_removed(node):
	if not node_belongs_in_edited_scene(node):
		return
	
	#Get these now, or won't be available once it resumes later
	var og_owner = node.owner
	var path = get_path_to(node)
	
	yield(self,"process_started")
	if node_rearranged_signals > 0 or scene_changed_signals > 0:
		return
	
	if og_owner != current_scene_root: #That node is a child of a packed scene instance, ignore
		return
	
	#print("Node removed:%s Named:%s" % [node,node.name])
	path = convert_to_scene_path(path)
	
	for peer in get_scene_peers(current_scene):
		rpc_id(peer,"remove_node",current_scene, path)

remote func remove_node(scene, node_path):
	var scene_root = get_scene_node(scene)
	var node = scene_root.get_node(node_path)
	print("Node %s Named:%s removed by peer %s" % [node,node.name,get_tree().get_rpc_sender_id()])
	
	#Dis/connect signals to avoid recursively calling
	get_tree().disconnect("node_removed",self,"_node_removed")
	node.free()
	get_tree().connect("node_removed",self,"_node_removed")


func _node_prerename(node, new_name):
	#print("Prerename:%s to %s" % [node,new_name])
	
	for peer in get_scene_peers(current_scene):
		var path = current_scene_root.get_path_to(node)
		rpc_id(peer,"rename_node",current_scene, path,new_name)

remote func rename_node(scene, node_path,new_name):
	var scene_root = get_scene_node(scene)
	scene_root.get_node(node_path).name = new_name
	
	#Sometimes the TreeItem won't update with its new name/path until another tree change is done so force it now
	scene_tree_editor.update_tree()


func _nodes_rearranged(paths, to_path, type): #Type 0 = Reparenting Type 1 = Reordering
	node_rearranged_signals += 1
	
	#print("Rearranged:%s to %s type:%s" % [paths,to_path,type])
	
	var converted_paths = []
	
	for path in paths:
		var relative_path = convert_to_scene_path(path)
		converted_paths.append(relative_path)
	
	if type == 0:
		var to_node = get_node(to_path)
		var converted_to = current_scene_root.get_path_to(to_node)
		for peer in get_scene_peers(current_scene):
			rpc_id(peer,"reparent_nodes",current_scene, converted_paths, converted_to)
	
	elif type == 1:
		var index = get_node(to_path).get_index()
		for peer in get_scene_peers(current_scene):
			rpc_id(peer,"reorder_nodes",current_scene, converted_paths,index)


remote func reparent_nodes(scene, node_paths,to_path):
	var scene_root = get_scene_node(scene)
	
	get_tree().disconnect("node_added",self,"_node_added")
	get_tree().disconnect("node_removed",self,"_node_removed")
	var new_parent = scene_root.get_node(to_path)
	for path in node_paths:
		var node = scene_root.get_node(path)
		node.get_parent().remove_child(node)
		new_parent.add_child(node)
		node.set_owner(scene_root)
	get_tree().connect("node_added",self,"_node_added")
	get_tree().connect("node_removed",self,"_node_removed")

remote func reorder_nodes(scene, node_paths,index):
	var scene_root = get_scene_node(scene)
	
	var i = 0
	while i < node_paths.size():
		var path = node_paths[i]
		var node = scene_root.get_node(path)
		node.get_parent().move_child(node,index+i +1)
		
		i+=1


#The editor adds/removes also a bunch of nodes when doing certain actions, so we filter them with this
func node_belongs_in_edited_scene(node):
	var parent_node = node.get_parent()
	while not parent_node == null:
		if parent_node == get_tree().edited_scene_root:
			return true
		parent_node = parent_node.get_parent()
	return false



#Sending the scene as is doesn't handle subresources well and sends their data directly instead of file paths/refs
#The editor doesn't like manipulating directly the root node either and will crash when interacting with the new nodes/closing scenes
#If only there was a way to write/read files in memory...
remote func request_delta_scene(scene_path):
	var scene_root = get_scene_node(scene_path)
	
	var path = scene_path
	if scene_root: #Scene is open, sent that in its actual state
		var packed_scene = PackedScene.new()
		packed_scene.pack(scene_root)
		path = "res://addons/networked_editor/temp_send_delta.tscn"
		ResourceSaver.save(path,packed_scene)
	
	var file = File.new()
	file.open(path,File.READ)
	var scene_data = file.get_as_text()
	file.close()
	
	rpc_id(get_tree().get_rpc_sender_id(),"receive_delta_scene",scene_path,scene_data)

remote func receive_delta_scene(scene_path,scene_data):
	print("Received delta scene")
	
	var file = File.new()
	file.open(scene_path,File.WRITE) #NOTE: This will overwrite the scene
	file.store_string(scene_data)
	file.close()
	
	get_tree().disconnect("node_added",self,"_node_added")
	get_tree().disconnect("node_removed",self,"_node_removed")
	plugin.disconnect("scene_changed",self,"_scene_changed")
	plugin.disconnect("scene_closed",self,"_scene_closed")
	
	editor_interface.reload_scene_from_path(scene_path)
	
	#Update the opened scene node ref, that gets freed and will make notifying remotely scene closed not work etc
	var i = 0
	while i < open_scene_nodes.size():
		var node = open_scene_nodes[i]
		if not is_instance_valid(node): #Node freed on scene reload
			print("Reloaded scene from received delta")
			open_scene_nodes[i] = get_tree().root
			break
		i+=1
	
	get_tree().connect("node_added",self,"_node_added")
	get_tree().connect("node_removed",self,"_node_removed")
	plugin.connect("scene_changed",self,"_scene_changed")
	plugin.connect("scene_closed",self,"_scene_closed")


func _scene_changed(scene_node):
	scene_changed_signals += 1
	
	current_scene_root = scene_node
	if scene_node == null:
		current_scene = ""
		return
	current_scene = scene_node.filename
	
	if not scene_node in open_scene_nodes:
		open_scene_nodes.append(scene_node)
	
	#What we want is a scene opened signal but the engine doesn't have one so use this one as workaround
	var filepaths = editor_interface.get_open_scenes()
	var my_peer = editor_peers[get_tree().get_network_unique_id()]
	for filepath in filepaths:
		if not filepath in my_peer.opened_scenes: #New one
			_scene_opened(filepath)

func _scene_opened(filepath):
	print("Scene opened: %s" % filepath)
	rpc("scene_opened",filepath)
	
	if $Input/SceneSync.pressed:
		print("Requesting delta scene")
		rpc_id(1,"request_delta_scene",filepath)

sync func scene_opened(filepath):
	var peer_id = get_tree().get_rpc_sender_id()
	if peer_id == 0:
		peer_id = get_tree().get_network_unique_id()
	
	editor_peers[peer_id].opened_scenes.append(filepath)
	
	print("Peer %s opened scene %s" % [peer_id,filepath])
	add_scene_tree_item(peer_id,filepath)


func _scene_closed(filepath):
	for node in open_scene_nodes:
		if node.filename == filepath:
			open_scene_nodes.erase(node)
	
	print("Scene closed: %s" % filepath)
	rpc("scene_closed",filepath)

sync func scene_closed(filepath):
	var peer_id = get_tree().get_rpc_sender_id()
	if peer_id == 0:
		peer_id = get_tree().get_network_unique_id()
	
	editor_peers[peer_id].opened_scenes.erase(filepath)
	
	print("Peer %s closed scene %s" % [peer_id,filepath])
	erase_scene_tree_item(peer_id,filepath)


func get_scene_node(filepath):
	for node in open_scene_nodes:
		if node.filename == filepath:
			return node
	return null



func add_peer_tree_item(id,nickname):
	var root = peer_tree.get_root()
	var peer = peer_tree.create_item(root)
	peer.set_metadata(0,id)
	peer.set_text(0, "%s:%s" % [nickname,id] )

func erase_peer_tree_item(id):
	var root = peer_tree.get_root()
	var child = root.get_children()
	while not child == null:
		if child.get_metadata(0) == id:
			root.remove_child(child)
			break
		child = child.get_next()

func get_peer_tree_item(id):
	var root = peer_tree.get_root()
	var child = root.get_children()
	while not child == null:
		if child.get_metadata(0) == id:
			return child
		child = child.get_next()
	return null


func add_scene_tree_item(peer_id,scene_filepath):
	var peer = get_peer_tree_item(peer_id)
	var scene = peer_tree.create_item(peer)
	scene.set_text(0, scene_filepath)

func erase_scene_tree_item(peer_id,scene_filepath): #TODO: The tree doesn't redraw whenever an item is erased? Mouse over it and it updates
	var peer = get_peer_tree_item(peer_id)
	var child = peer.get_children()
	while not child == null:
		if child.get_text(0) == scene_filepath:
			peer.remove_child(child)
			break
		child = child.get_next()


func get_scene_peers(scene): #Gets the peers that also have that scene open
	var peers = []
	for peer_id in get_tree().get_network_connected_peers():
		var scenes = editor_peers[peer_id].opened_scenes
		if scene in scenes:
			peers.append(peer_id)
	return peers


class EditorPeer:
	var nickname = "EditorPeer"
	var opened_scenes = []



var _all_scene_nodes = []

func get_scene_tree_dock():
	var upper_node = get_parent()
	while not upper_node == null:
		var parent = upper_node.get_parent()
		if parent:
			upper_node = parent
		else:
			break
	
	get_nodes(upper_node)
	_all_scene_nodes.clear()

func get_nodes(node):
	for child in node.get_children():
		_all_scene_nodes.append(child)
		if child.get_class() == "SceneTreeDock":
			scene_tree_dock = child
			return
		if child.get_child_count() > 0:
			get_nodes(child)



func convert_to_scene_path(node_path): #For when Node.get_path_to(node) doesn't work
	var relative_start = 0
	
	var i = 0
	while i < node_path.get_name_count():
		var node = node_path.get_name(i)
		if node == current_scene_root.name:
			relative_start = i
			break
		i+=1
	
	var path_string = ""
	
	var j = relative_start
	while j < node_path.get_name_count():
		path_string += "/%s" % node_path.get_name(j) 
		j+=1
	path_string.erase(0,current_scene_root.name.length() + 2) #Remove unwanted "/SceneRoot/" from path
	
	return NodePath(path_string)


#TODO: Handling resource dependencies by creating dummy resources with a later option to do a file transfer
#to replace them by the actual ones

#TODO: Implement a way to cache nodepaths for efficiency?


#NOTE: There is only one Scene Tree Dock but multiple (9?) Scene Tree Editors

#NOTE: SceneTreeDock.get_tree_editor() is not exposed to GDScript by default

#NOTE: Undoing won't send any signal events back!
