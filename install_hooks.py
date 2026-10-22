"""Install (default) or remove (--uninstall) the Claude Session Bar hooks in ~/.claude/settings.json.

Only touches hook entries whose command points at session-dashboard/hook.py; a timestamped backup
of settings.json is written before every change.
"""

import json
import os
import shutil
import sys
import time

SETTINGS = os.path.expanduser("~/.claude/settings.json")
HOOK_SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hooks", "hook.py")
HOOK_DST = os.path.expanduser("~/.claude/session-dashboard/hook.py")
COMMAND = '/usr/bin/python3 "{}"'.format(HOOK_DST)
EVENTS = ["UserPromptSubmit", "Notification", "Stop", "SessionEnd"]
MARK = "session-dashboard/hook.py"


def is_ours(group: dict) -> bool:
    return any(MARK in h.get("command", "") for h in group.get("hooks", []))


def main() -> None:
    uninstall = "--uninstall" in sys.argv
    settings = {}
    backup = None
    if os.path.exists(SETTINGS):
        with open(SETTINGS) as f:
            settings = json.load(f)
        backup = "{}.bak-csb-{}".format(SETTINGS, time.strftime("%Y%m%d%H%M%S"))
        shutil.copy2(SETTINGS, backup)
    else:
        os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)

    if not uninstall:
        os.makedirs(os.path.dirname(HOOK_DST), exist_ok=True)
        shutil.copy2(HOOK_SRC, HOOK_DST)

    hooks = settings.setdefault("hooks", {})
    for event in EVENTS:
        groups = [g for g in hooks.get(event, []) if not is_ours(g)]
        if not uninstall:
            groups.append({"hooks": [{"type": "command", "command": COMMAND, "timeout": 5}]})
        if groups:
            hooks[event] = groups
        else:
            hooks.pop(event, None)
    if not hooks:
        settings.pop("hooks")

    tmp = SETTINGS + ".tmp"
    with open(tmp, "w") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, SETTINGS)
    print("{} hooks ({}); backup: {}".format(
        "removed" if uninstall else "installed", ", ".join(EVENTS), backup or "none (no settings.json before)"))


if __name__ == "__main__":
    main()
