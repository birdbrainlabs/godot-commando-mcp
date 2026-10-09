@tool
extends EditorPlugin
## Godot Commando — v0.2
##
## Listens on ws://127.0.0.1:26470 for JSON commands and executes them live in
## the editor. Requires Godot 4.2+. Talk to it via the bundled MCP server, or
## anything else that can send JSON over a WebSocket.
##
## Every reply is JSON: {"ok": true, ...} or {"ok": false, "error": "..."}

const PORT := 26470

var _server := TCPServer.new()
var _peers: Array[WebSocketPeer] = []


func _enter_tree() -> void:
	var err := _server.listen(PORT, "127.0.0.1")
	if err != OK:
		push_error("Godot Commando: cannot listen on 127.0.0.1:%d (error %d). Is another instance running?" % [PORT, err])
	else:
		print("Godot Commando listening on ws://127.0.0.1:%d" % PORT)


func _exit_tree() -> void:
	if _server.is_listening():
		_server.stop()
	for peer in _peers:
		peer.close()
	_peers.clear()


func _process(_delta: float) -> void:
	while _server.is_listening() and _server.is_connection_available():
		var tcp := _server.take_connection()
		var ws := WebSocketPeer.new()
		if ws.accept_stream(tcp) == OK:
			_peers.append(ws)

	for i in range(_peers.size() - 1, -1, -1):
		var ws := _peers[i]
		ws.poll()
		var state := ws.get_ready_state()
		if state == WebSocketPeer.STATE_OPEN:
			while ws.get_available_packet_count() > 0:
				var raw := ws.get_packet().get_string_from_utf8()
				ws.send_text(_handle(raw))
		elif state == WebSocketPeer.STATE_CLOSED:
			_peers.remove_at(i)


func _handle(raw: String) -> String:
	var data: Variant = JSON.parse_string(raw)
	if data == null or typeof(data) != TYPE_DICTIONARY:
		return _err("invalid JSON payload")

	var action: String = data.get("action", "")
	match action:
		# --- basics -------------------------------------------------
		"ping":
			return _ok({"pong": true, "godot": Engine.get_version_info().string})
		"rescan":
			EditorInterface.get_resource_filesystem().scan()
			return _ok({"scanned": true})
		"reimport":
			return _reimport(data)
		"update_sprite_frames":
			return _update_sprite_frames(data)
		# --- scene inspection ----------------------------------------
		"get_scene_tree":
			return _get_scene_tree()
		"get_selection":
			return _get_selection()
		"get_node_properties":
			return _get_node_properties(data)
		# --- scene editing -------------------------------------------
		"create_node":
			return _create_node(data)
		"delete_node":
			return _delete_node(data)
		"set_property":
			return _set_property(data)
		"attach_script":
			return _attach_script(data)
		"validate_script":
			return _validate_script(data)
		"write_file":
			return _write_file(data)
		"read_file":
			return _read_file(data)
		# --- scene lifecycle -----------------------------------------
		"save_scene":
			var err := EditorInterface.save_scene()
			return _ok({"saved": err == OK}) if err == OK else _err("save failed (error %d)" % err)
		"open_scene":
			var p: String = data.get("path", "")
			if p.is_empty():
				return _err("open_scene requires 'path'")
			EditorInterface.open_scene_from_path(p)
			return _ok({"opened": p})
		"run_scene":
			var p: String = data.get("path", "")
			if p.is_empty():
				EditorInterface.play_current_scene()
			else:
				EditorInterface.play_custom_scene(p)
			return _ok({"running": true})
		"stop_scene":
			EditorInterface.stop_playing_scene()
			return _ok({"stopped": true})
		# --- vision --------------------------------------------------
		"capture_viewport":
			return _capture_viewport(data)
		_:
			return _err("unknown action: '%s'" % action)


# ------------------------------------------------------------------ helpers

func _root() -> Node:
	return EditorInterface.get_edited_scene_root()


func _find(np: String) -> Node:
	var root := _root()
	if root == null:
		return null
	if np.is_empty() or np == "." or np == "/" or np == root.name:
		return root
	return root.get_node_or_null(NodePath(np))


func _mark_unsaved() -> void:
	EditorInterface.mark_scene_as_unsaved()


# ------------------------------------------------------------------ M0 actions

func _reimport(data: Dictionary) -> String:
	var path: String = data.get("path", "")
	if path.is_empty():
		return _err("reimport requires 'path'")
	var fs := EditorInterface.get_resource_filesystem()
	fs.update_file(path)
	fs.reimport_files(PackedStringArray([path]))
	return _ok({"reimported": path})


func _update_sprite_frames(data: Dictionary) -> String:
	var tex_path: String = data.get("texture", "")
	var res_path: String = data.get("resource_path", "")
	var fsize: Array = data.get("frame_size", [])
	var anims: Array = data.get("animations", [])

	if tex_path.is_empty() or res_path.is_empty() or fsize.size() != 2:
		return _err("update_sprite_frames requires 'texture', 'resource_path', 'frame_size' [w,h]")
	if anims.is_empty():
		return _err("update_sprite_frames requires at least one animation")

	var tex := load(tex_path) as Texture2D
	if tex == null:
		return _err("could not load texture: %s (did you reimport first?)" % tex_path)

	var fw := int(fsize[0])
	var fh := int(fsize[1])
	if fw <= 0 or fh <= 0:
		return _err("frame_size must be positive")
	var cols := int(tex.get_width() / float(fw))
	if cols <= 0:
		return _err("texture narrower than one frame")

	var frames: SpriteFrames = null
	if ResourceLoader.exists(res_path):
		frames = load(res_path) as SpriteFrames
	if frames == null:
		frames = SpriteFrames.new()

	var anim_names: Array[String] = []
	for anim_v in anims:
		if typeof(anim_v) != TYPE_DICTIONARY:
			continue
		var anim: Dictionary = anim_v
		var anim_name: String = anim.get("name", "default")
		if frames.has_animation(anim_name):
			frames.clear(anim_name)
		else:
			frames.add_animation(anim_name)
		frames.set_animation_speed(anim_name, float(anim.get("fps", 10)))
		frames.set_animation_loop(anim_name, bool(anim.get("loop", true)))
		for idx_v in anim.get("frames", []):
			var idx := int(idx_v)
			var col := idx % cols
			var row := int(floor(float(idx) / float(cols)))
			var atlas := AtlasTexture.new()
			atlas.atlas = tex
			atlas.region = Rect2(col * fw, row * fh, fw, fh)
			frames.add_frame(anim_name, atlas)
		anim_names.append(anim_name)

	frames.take_over_path(res_path)
	var err := ResourceSaver.save(frames, res_path)
	if err != OK:
		return _err("failed to save %s (error %d)" % [res_path, err])

	EditorInterface.get_resource_filesystem().scan()
	return _ok({"resource": res_path, "animations": anim_names})


# ------------------------------------------------------------------ inspection

func _node_info(node: Node, root: Node) -> Dictionary:
	var info := {
		"name": String(node.name),
		"type": node.get_class(),
		"path": String(root.get_path_to(node)),
	}
	if node.get_script() != null:
		var s: Script = node.get_script()
		info["script"] = s.resource_path
	var children: Array = []
	for child in node.get_children():
		children.append(_node_info(child, root))
	if not children.is_empty():
		info["children"] = children
	return info


func _get_scene_tree() -> String:
	var root := _root()
	if root == null:
		return _err("no scene is open in the editor")
	return _ok({
		"scene": root.scene_file_path,
		"tree": _node_info(root, root),
	})


func _get_selection() -> String:
	var root := _root()
	if root == null:
		return _err("no scene is open in the editor")
	var selected := EditorInterface.get_selection().get_selected_nodes()
	var out: Array = []
	for node in selected:
		out.append({
			"name": String(node.name),
			"type": node.get_class(),
			"path": String(root.get_path_to(node)),
		})
	return _ok({"selected": out})


func _get_node_properties(data: Dictionary) -> String:
	var node := _find(data.get("node_path", ""))
	if node == null:
		return _err("node not found: '%s'" % data.get("node_path", ""))
	var wanted: Array = data.get("properties", [])
	var props := {}
	if wanted.is_empty():
		# A curated set of commonly useful properties.
		wanted = ["position", "rotation", "scale", "visible", "modulate", "texture", "text"]
	for p_v in wanted:
		var p := String(p_v)
		var names := node.get_property_list().map(func(d): return d.get("name"))
		if p in names:
			props[p] = var_to_str(node.get(p))
	return _ok({"path": String(data.get("node_path", "")), "type": node.get_class(), "properties": props})


# ------------------------------------------------------------------ editing

func _create_node(data: Dictionary) -> String:
	var root := _root()
	if root == null:
		return _err("no scene is open in the editor")
	var type: String = data.get("type", "")
	if not ClassDB.class_exists(type):
		return _err("unknown node type: '%s'" % type)
	if not ClassDB.is_parent_class(type, "Node"):
		return _err("'%s' is not a Node type" % type)

	var parent := _find(data.get("parent_path", ""))
	if parent == null:
		return _err("parent not found: '%s'" % data.get("parent_path", ""))

	var node: Node = ClassDB.instantiate(type)
	var wanted_name: String = data.get("name", type)
	node.name = wanted_name
	parent.add_child(node)
	node.owner = root
	_mark_unsaved()
	return _ok({"created": String(root.get_path_to(node)), "type": type})


func _delete_node(data: Dictionary) -> String:
	var root := _root()
	if root == null:
		return _err("no scene is open in the editor")
	var node := _find(data.get("node_path", ""))
	if node == null:
		return _err("node not found: '%s'" % data.get("node_path", ""))
	if node == root:
		return _err("refusing to delete the scene root")
	var path := String(root.get_path_to(node))
	node.get_parent().remove_child(node)
	node.queue_free()
	_mark_unsaved()
	return _ok({"deleted": path})


func _set_property(data: Dictionary) -> String:
	var node := _find(data.get("node_path", ""))
	if node == null:
		return _err("node not found: '%s'" % data.get("node_path", ""))
	var prop: String = data.get("property", "")
	if prop.is_empty():
		return _err("set_property requires 'property'")

	var names := node.get_property_list().map(func(d): return d.get("name"))
	if not prop in names:
		return _err("node %s has no property '%s'" % [node.get_class(), prop])

	var raw: Variant = data.get("value")
	var current: Variant = node.get(prop)
	var value: Variant = _coerce(raw, current)
	node.set(prop, value)
	_mark_unsaved()
	var after: Variant = node.get(prop)
	var reply := {
		"path": String(data.get("node_path", "")),
		"property": prop,
		"value": var_to_str(after),
	}
	# Diagnostics when the set didn't stick — shows where the value got lost.
	if var_to_str(after) != var_to_str(value):
		reply["warning"] = "read-back differs from the value that was set"
		reply["debug"] = {
			"received": var_to_str(raw),
			"received_type": type_string(typeof(raw)),
			"current_type": type_string(typeof(current)),
			"coerced": var_to_str(value),
			"coerced_type": type_string(typeof(value)),
		}
	return _ok(reply)


## Convert a JSON value into the Variant type the property currently holds.
## JSON can only carry strings/numbers/bools/arrays/dicts, so anything typed
## (Vector2, Color, resources...) needs explicit conversion or set() no-ops.
func _coerce(value: Variant, current: Variant) -> Variant:
	var t := typeof(current)
	var vt := typeof(value)

	# Some relay layers stringify structured arguments ("[150, 250]" instead of
	# [150, 250]). If the target property is NOT a string, unwrap first.
	if vt == TYPE_STRING and t != TYPE_STRING and t != TYPE_STRING_NAME:
		var unwrapped: Variant = JSON.parse_string(value)
		if unwrapped == null:
			unwrapped = str_to_var(value)
		if unwrapped != null and typeof(unwrapped) != TYPE_STRING:
			return _coerce(unwrapped, current)

	if t == TYPE_VECTOR2:
		if vt == TYPE_ARRAY and value.size() >= 2:
			return Vector2(float(value[0]), float(value[1]))
		if vt == TYPE_DICTIONARY and value.has("x") and value.has("y"):
			return Vector2(float(value["x"]), float(value["y"]))
		if vt == TYPE_STRING:
			var parsed: Variant = str_to_var(value)
			if typeof(parsed) == TYPE_VECTOR2:
				return parsed
	elif t == TYPE_VECTOR2I:
		if vt == TYPE_ARRAY and value.size() >= 2:
			return Vector2i(int(value[0]), int(value[1]))
	elif t == TYPE_VECTOR3:
		if vt == TYPE_ARRAY and value.size() >= 3:
			return Vector3(float(value[0]), float(value[1]), float(value[2]))
	elif t == TYPE_COLOR:
		if vt == TYPE_STRING:
			return Color.html(value)
		if vt == TYPE_ARRAY and value.size() >= 3:
			var a := 1.0 if value.size() < 4 else float(value[3])
			return Color(float(value[0]), float(value[1]), float(value[2]), a)
	elif t == TYPE_INT:
		if vt == TYPE_FLOAT:
			return int(value)
	elif t == TYPE_FLOAT:
		if vt == TYPE_INT:
			return float(value)
	elif t == TYPE_OBJECT or t == TYPE_NIL:
		# e.g. assigning a texture by res:// path (current may be null when unset)
		if vt == TYPE_STRING and String(value).begins_with("res://") and ResourceLoader.exists(value):
			return load(value)
	return value


func _attach_script(data: Dictionary) -> String:
	var node := _find(data.get("node_path", ""))
	if node == null:
		return _err("node not found: '%s'" % data.get("node_path", ""))
	var path: String = data.get("script_path", "")
	if not ResourceLoader.exists(path):
		return _err("script not found: %s" % path)
	var script := load(path)
	if not script is Script:
		return _err("%s is not a script" % path)
	node.set_script(script)
	_mark_unsaved()
	return _ok({"attached": path, "to": String(data.get("node_path", ""))})


## Harness: check GDScript source against reality before it touches the project.
## Layer 1 — does it parse (Godot's own compiler, not an opinion).
## Layer 2 — do referenced classes exist (ClassDB + the project's script classes).
## Honest by design: dynamic calls can't be statically verified, so the report
## distinguishes "provably wrong" from "couldn't check".
func _validate_script(data: Dictionary) -> String:
	var content: String = data.get("content", "")
	if content.is_empty():
		return _err("validate_script requires 'content'")

	# --- Layer 1: parse check via Godot's real compiler
	var script := GDScript.new()
	script.source_code = content
	var parse_err := script.reload(false)
	var syntax_ok := parse_err == OK

	var result := {
		"syntax_ok": syntax_ok,
	}
	if not syntax_ok:
		result["error_code"] = parse_err
		result["note"] = "Parse failed — Godot's Output panel shows the exact line/message."
		result["valid"] = false
		return _ok(result)

	# --- Layer 2: class-existence checks (extends targets and X.new() calls)
	var known_user_classes := {}
	for entry in ProjectSettings.get_global_class_list():
		known_user_classes[String(entry.get("class", ""))] = true

	var referenced := {}
	var re_extends := RegEx.new()
	re_extends.compile("(?m)^\\s*extends\\s+([A-Za-z_][A-Za-z0-9_]*)")
	for m in re_extends.search_all(content):
		referenced[m.get_string(1)] = "extends"
	var re_new := RegEx.new()
	re_new.compile("\\b([A-Z][A-Za-z0-9_]*)\\s*\\.\\s*new\\s*\\(")
	for m in re_new.search_all(content):
		referenced[m.get_string(1)] = ".new()"

	var checked: Array = []
	var unknown: Array = []
	for cls in referenced.keys():
		var exists := ClassDB.class_exists(cls) or known_user_classes.has(cls)
		checked.append({"class": cls, "via": referenced[cls], "exists": exists})
		if not exists:
			unknown.append(cls)

	result["classes_checked"] = checked
	result["unknown_classes"] = unknown
	result["valid"] = unknown.is_empty()
	if not unknown.is_empty():
		result["note"] = "These classes don't exist in this project or engine — likely invented API."
	else:
		result["note"] = "Parses clean; referenced classes exist. Dynamic method calls are not statically verifiable."
	return _ok(result)


func _write_file(data: Dictionary) -> String:
	var path: String = data.get("path", "")
	var content: String = data.get("content", "")
	if not path.begins_with("res://"):
		return _err("path must start with res://")
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return _err("cannot write %s (error %d)" % [path, FileAccess.get_open_error()])
	f.store_string(content)
	f.close()
	EditorInterface.get_resource_filesystem().scan()
	return _ok({"written": path, "bytes": content.length()})


func _read_file(data: Dictionary) -> String:
	var path: String = data.get("path", "")
	if not FileAccess.file_exists(path):
		return _err("file not found: %s" % path)
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return _err("cannot read %s" % path)
	var content := f.get_as_text()
	f.close()
	return _ok({"path": path, "content": content})


# ------------------------------------------------------------------ vision

func _capture_viewport(data: Dictionary) -> String:
	var out_path: String = data.get("out_path", "")
	if out_path.is_empty():
		return _err("capture_viewport requires 'out_path' (absolute filesystem path)")
	var kind: String = data.get("kind", "2d")
	var image: Image = null
	if kind == "3d":
		var vp3 := EditorInterface.get_editor_viewport_3d(0)
		if vp3 == null:
			return _err("no 3D viewport")
		image = vp3.get_texture().get_image()
	else:
		var vp2 := EditorInterface.get_editor_viewport_2d()
		if vp2 == null:
			return _err("no 2D viewport")
		image = vp2.get_texture().get_image()
	if image == null:
		return _err("could not capture viewport image")
	var err := image.save_png(out_path)
	if err != OK:
		return _err("failed to save capture to %s (error %d)" % [out_path, err])
	return _ok({"saved": out_path, "size": [image.get_width(), image.get_height()]})


# ------------------------------------------------------------------ replies

func _ok(payload: Dictionary) -> String:
	payload["ok"] = true
	return JSON.stringify(payload)


func _err(message: String) -> String:
	push_warning("Command Center: %s" % message)
	return JSON.stringify({"ok": false, "error": message})
