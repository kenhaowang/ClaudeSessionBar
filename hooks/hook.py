"""Claude Code hook for Claude Session Bar: records per-session state for the menu bar app.

Must stay compatible with /usr/bin/python3 (3.9) and must never fail or block the session.
"""

import json
import os
import sys
import time

STATE_DIR = os.path.expanduser("~/.claude/session-dashboard/state")


def main() -> None:
    if os.environ.get("CSB_SUMMARIZER"):
        return
    data = json.load(sys.stdin)
    sid = data.get("session_id")
    if not sid:
        return
    event = data.get("hook_event_name", "")
    path = os.path.join(STATE_DIR, sid + ".json")

    if event == "SessionEnd":
        if os.path.exists(path):
            os.remove(path)
        return

    try:
        with open(path) as f:
            state = json.load(f)
    except (OSError, ValueError):
        state = {}

    now = time.time()
    if event == "UserPromptSubmit":
        state["state"] = "running"
        state["last_prompt_at"] = now
        state.pop("notification", None)
    elif event == "Notification":
        ntype = data.get("notification_type") or ""
        message = data.get("message") or ""
        if ntype == "permission_prompt" or (not ntype and "permission" in message.lower()):
            state["state"] = "waiting_approval"
        elif ntype == "elicitation_dialog":
            state["state"] = "waiting_input"
        else:
            # idle_prompt and friends carry no new state.
            return
        state["notification"] = message[:200]
    elif event == "Stop":
        state["state"] = "idle_bg" if data.get("background_tasks") else "idle"
    else:
        return

    state["session_id"] = sid
    state["transcript_path"] = data.get("transcript_path") or state.get("transcript_path")
    state["event"] = event
    state["at"] = now
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, ensure_ascii=False)
    os.replace(tmp, path)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
