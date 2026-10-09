# Godot Commando

Let an AI assistant work inside your open Godot editor.

Godot Commando is two small pieces:

1. **A Godot editor plugin** (`addons/godot_commando/`) that listens on a local
   WebSocket (`ws://127.0.0.1:26470`) and runs JSON commands live in the editor:
   read the scene tree, add and remove nodes, set properties, write and check
   scripts, run the scene, take a screenshot of the viewport.
2. **An MCP server** (`addons/godot_commando/server/godot_commando_mcp.py`) that
   exposes those commands as tools for any MCP client: Claude Code, Claude
   Desktop, Cursor, or anything else that speaks the
   [Model Context Protocol](https://modelcontextprotocol.io).

With both running you can say "add a Sprite2D under Player, point it at
`res://art/player.png`, and show me the viewport" and watch it happen in the
editor you already have open. No file-watching, no restarts, no copy-pasting
scripts.

Built by one person to speed up their own small games. It is developed on
macOS with Godot 4.7 and Claude Code; other platforms should work but are not
tested.

## Tools

| Tool | What it does |
| --- | --- |
| `godot_ping` | Confirm the editor is reachable, return the Godot version |
| `get_scene_tree` | Dump the open scene as a tree |
| `get_selection` | Which nodes are selected in the editor |
| `get_node_properties` | Read properties of one node |
| `create_node` / `delete_node` | Add or remove a node |
| `set_property` | Change a property on a node |
| `write_script` | Write a GDScript file, optionally attach it to a node |
| `read_file` | Read a `res://` file |
| `validate_script` | Check GDScript for errors without saving it |
| `save_scene` / `open_scene` | Save or switch scenes |
| `run_scene` / `stop_scene` | Play or stop a scene |
| `rescan_filesystem` / `reimport_file` | Pick up assets changed on disk |
| `update_sprite_frames` | Build a SpriteFrames resource from a spritesheet |
| `capture_viewport` | Screenshot the 2D or 3D editor viewport, returned as an image |
| `get_editor_setting` / `set_editor_setting` | Read or change an Editor Settings value |
| `list_editor_settings` | Find Editor Settings keys by prefix |

The screenshot tool is the one that matters most: it lets the assistant see
what it just did instead of guessing.

The editor-settings tools change the editor itself, not your project. For
example, `set_editor_setting run/window_placement/game_embed_mode embed` so
Play stays inside the editor instead of opening a separate window. Dropdown
settings take the option name (`embed`, `floating`, `disabled`) or its number.

## Install

### 1. The Godot plugin

Copy `addons/godot_commando/` into your project's `addons/` folder, then in
Godot open **Project → Project Settings → Plugins** and enable
**Godot Commando**. The Output panel prints
`Godot Commando listening on ws://127.0.0.1:26470`.

Requires Godot 4.2 or newer.

### 2. The MCP server

```bash
pip install -r requirements.txt
```

Smoke test with the editor open:

```bash
python3 addons/godot_commando/server/godot_commando_mcp.py --selftest
```

### 3. Point your MCP client at it

Claude Code, from inside your Godot project folder:

```bash
claude mcp add godot -- python3 /path/to/godot-commando-mcp/addons/godot_commando/server/godot_commando_mcp.py
```

Claude Desktop or any client that takes a JSON config:

```json
{
  "mcpServers": {
    "godot": {
      "command": "python3",
      "args": ["/path/to/godot-commando-mcp/addons/godot_commando/server/godot_commando_mcp.py"]
    }
  }
}
```

Set `GODOT_COMMANDO_WS` if you changed the port.

## How it works

The plugin is a single `EditorPlugin` script. It polls a `TCPServer` each
frame, upgrades connections to WebSocket, and dispatches each JSON message by
its `action` field to a handler that calls the editor API directly. Every
reply is `{"ok": true, ...}` or `{"ok": false, "error": "..."}`.

The MCP server is a thin `FastMCP` wrapper: one function per action, each
opening a short-lived WebSocket to the plugin. Keeping all the logic on the
Godot side means the Python half never needs to know anything about Godot.

## Safety notes

- The bridge binds to `127.0.0.1` only. Nothing outside your machine can reach
  it.
- Anything that can connect to that port can edit your open project. Treat it
  like having the editor open.
- `write_script` and `set_property` change files in your project. Keep the
  project in version control.
- `set_editor_setting` changes your editor for every project, and the change
  sticks. Check it with `get_editor_setting` first if you want to put it back.

## License

MIT. See `LICENSE`.
