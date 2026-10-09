#!/usr/bin/env python3
"""Godot Commando — MCP server.

Exposes the Godot Commando editor plugin as MCP tools, so any MCP client
(Claude Desktop, Claude Code, Cursor, ...) can inspect and edit the scene
that's open in the Godot editor.

Requires the Godot Commando plugin enabled in a running Godot editor
(it listens on ws://127.0.0.1:26470).

Run standalone for a smoke test:  python godot_commando_mcp.py --selftest
Normally launched by the MCP client via the config in the README.
"""

import json
import os
import sys
import tempfile

from mcp.server.fastmcp import FastMCP, Image

try:
    import websocket  # websocket-client
except ImportError:
    sys.exit("Missing dependency: websocket-client")

GODOT_WS_URL = os.environ.get("GODOT_COMMANDO_WS", "ws://127.0.0.1:26470")

mcp = FastMCP("godot-commando")


def bridge(payload: dict) -> dict:
    """Send one command to the Godot bridge, return its JSON reply."""
    try:
        ws = websocket.create_connection(GODOT_WS_URL, timeout=15)
    except Exception as e:
        return {
            "ok": False,
            "error": f"Cannot reach the Godot editor at {GODOT_WS_URL} ({e}). "
            "Make sure the editor is open and the Godot Commando plugin is enabled.",
        }
    try:
        ws.send(json.dumps(payload))
        return json.loads(ws.recv())
    except Exception as e:
        return {"ok": False, "error": f"bridge error: {e}"}
    finally:
        ws.close()


def _s(result: dict) -> str:
    return json.dumps(result, indent=2)


# ------------------------------------------------------------------ tools

@mcp.tool()
def godot_ping() -> str:
    """Check that the Godot editor is reachable. Returns the Godot version."""
    return _s(bridge({"action": "ping"}))


@mcp.tool()
def get_scene_tree() -> str:
    """Get the full node tree of the scene currently open in the Godot editor:
    every node's name, type, path (relative to the scene root), attached
    scripts, and children."""
    return _s(bridge({"action": "get_scene_tree"}))


@mcp.tool()
def get_selection() -> str:
    """Get the node(s) the developer currently has selected in the editor.
    Use this to resolve commands like 'this node' or 'the selected sprite'."""
    return _s(bridge({"action": "get_selection"}))


@mcp.tool()
def get_node_properties(node_path: str, properties: list[str] | None = None) -> str:
    """Read property values from a node. node_path is relative to the scene
    root (from get_scene_tree). Omit properties to get a useful default set
    (position, scale, visible, ...)."""
    payload = {"action": "get_node_properties", "node_path": node_path}
    if properties:
        payload["properties"] = properties
    return _s(bridge(payload))


@mcp.tool()
def create_node(type: str, name: str, parent_path: str = "") -> str:
    """Create a new node in the open scene. type is a Godot class name like
    'Sprite2D', 'Area2D', 'OmniLight3D'. parent_path is relative to the scene
    root; empty means the root itself."""
    return _s(bridge({
        "action": "create_node", "type": type, "name": name, "parent_path": parent_path,
    }))


@mcp.tool()
def delete_node(node_path: str) -> str:
    """Delete a node (and its children) from the open scene. Cannot delete
    the scene root."""
    return _s(bridge({"action": "delete_node", "node_path": node_path}))


@mcp.tool()
def set_property(node_path: str, property: str, value) -> str:
    """Set a property on a node. Values are coerced to the property's type:
    [x, y] for Vector2, [x, y, z] for Vector3, '#rrggbb' or [r,g,b,a] for
    Color, a 'res://...' path for resource properties like texture."""
    return _s(bridge({
        "action": "set_property", "node_path": node_path,
        "property": property, "value": value,
    }))


@mcp.tool()
def write_script(path: str, content: str, attach_to: str = "") -> str:
    """Write a GDScript file into the project (path must start with res://).
    If attach_to is given (a node path), the script is attached to that node."""
    result = bridge({"action": "write_file", "path": path, "content": content})
    if result.get("ok") and attach_to:
        result["attach"] = bridge({
            "action": "attach_script", "node_path": attach_to, "script_path": path,
        })
    return _s(result)


@mcp.tool()
def read_file(path: str) -> str:
    """Read a text file from the project (scripts, scenes, resources).
    Path must start with res://."""
    return _s(bridge({"action": "read_file", "path": path}))


@mcp.tool()
def validate_script(content: str) -> str:
    """Check GDScript source WITHOUT writing or running it: does it parse, and
    do the classes it references (extends / .new()) actually exist in this
    Godot project? Returns syntax_ok, unknown_classes, and valid. Call this
    before write_script. Note: dynamic calls can't be fully verified —
    'valid' means 'nothing provably wrong', not 'guaranteed correct'."""
    return _s(bridge({"action": "validate_script", "content": content}))


@mcp.tool()
def save_scene() -> str:
    """Save the scene currently open in the editor."""
    return _s(bridge({"action": "save_scene"}))


@mcp.tool()
def open_scene(path: str) -> str:
    """Open a scene file (res://...) in the editor."""
    return _s(bridge({"action": "open_scene", "path": path}))


@mcp.tool()
def run_scene(path: str = "") -> str:
    """Play a scene. Empty path plays the scene currently open in the editor."""
    return _s(bridge({"action": "run_scene", "path": path}))


@mcp.tool()
def stop_scene() -> str:
    """Stop the running scene."""
    return _s(bridge({"action": "stop_scene"}))


@mcp.tool()
def rescan_filesystem() -> str:
    """Rescan the project filesystem after files changed on disk."""
    return _s(bridge({"action": "rescan"}))


@mcp.tool()
def reimport_file(path: str) -> str:
    """Reimport a changed asset (res://...) — e.g. a PNG that was re-exported."""
    return _s(bridge({"action": "reimport", "path": path}))


@mcp.tool()
def update_sprite_frames(texture: str, resource_path: str,
                         frame_size: list[int], animations: list[dict]) -> str:
    """Build or update a SpriteFrames resource from a spritesheet texture.
    frame_size is [w, h]; each animation is {"name", "frames": [indices],
    "fps", "loop"}. Nodes already using the resource update in place."""
    return _s(bridge({
        "action": "update_sprite_frames", "texture": texture,
        "resource_path": resource_path, "frame_size": frame_size,
        "animations": animations,
    }))


@mcp.tool()
def capture_viewport(kind: str = "2d") -> Image:
    """Capture a screenshot of the editor viewport ('2d' or '3d') and return
    it as an image. Use this to SEE the scene — verify a change looked right,
    or diagnose a visual problem."""
    fd, tmp = tempfile.mkstemp(suffix=".png")
    os.close(fd)
    result = bridge({"action": "capture_viewport", "kind": kind, "out_path": tmp})
    if not result.get("ok"):
        raise RuntimeError(result.get("error", "capture failed"))
    return Image(path=tmp)


# ------------------------------------------------------------------ entry

def selftest() -> None:
    print("Pinging Godot bridge at", GODOT_WS_URL)
    print(_s(bridge({"action": "ping"})))


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
    else:
        mcp.run()
