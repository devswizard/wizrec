#!/usr/bin/python3 -I
"""Prints the GUI session state of the current user for scripts/ui-checks.

  ioreg -n Root -d1 -a | /usr/bin/python3 -I screen-state.py

"unlocked": this user's session is on the console and its screen is unlocked (UI checks can
drive the GUI). "locked": the screen is locked (CGSSessionScreenIsLocked), so System Events
and AXUIElement calls stall. "off-console": no console session for this user (fast user
switching, logged out, SSH only). Reads the session dictionaries that CGSessionCopyCurrentDictionary
also returns (IOConsoleUsers on the registry root).
"""
import os
import plistlib
import sys


def find_users(node):
    if isinstance(node, dict):
        if "IOConsoleUsers" in node:
            return node["IOConsoleUsers"]
        children = node.values()
    elif isinstance(node, list):
        children = node
    else:
        return None
    for child in children:
        found = find_users(child)
        if found is not None:
            return found
    return None


try:
    users = find_users(plistlib.loads(sys.stdin.buffer.read())) or []
except Exception:
    users = []
mine = [u for u in users if u.get("kCGSSessionUserIDKey") == os.getuid() and u.get("kCGSSessionOnConsoleKey")]
if not mine:
    print("off-console")
elif any(u.get("CGSSessionScreenIsLocked") for u in mine):
    print("locked")
else:
    print("unlocked")
