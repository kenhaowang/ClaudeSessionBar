# Claude Session Bar

English | [繁體中文](README.md)

A menu bar dashboard for Claude Code sessions on macOS: it lists every open session, tells you what each one is waiting on, and jumps to the matching iTerm2 tab with one click.

> This is an unofficial personal project. It is not affiliated with or endorsed by Anthropic.

## Requirements

- macOS 14 or later, with the Xcode Command Line Tools (Swift 5.9+)
- [iTerm2](https://iterm2.com/) — sessions must run in iTerm2 for click-to-jump and opening new tabs
- The [Claude Code](https://docs.claude.com/en/docs/claude-code) CLI (`claude`), logged in
- Optional: [GitHub CLI](https://cli.github.com/) (`gh`) for PR / CI status, [Cursor](https://cursor.com/) for opening branches

## Install / update

```bash
./build.sh install                       # build, copy to ~/Applications and launch
/usr/bin/python3 install_hooks.py        # add the hooks to ~/.claude/settings.json (backs it up first)
```

The first time you click a session, macOS asks whether the app may control iTerm2 — click "Allow".

## Uninstall

```bash
/usr/bin/python3 install_hooks.py --uninstall
rm -rf ~/Applications/ClaudeSessionBar.app ~/.claude/session-dashboard
```

## Where the data comes from

| Information | Source |
|---|---|
| Session list, running / idle | `claude agents --json` |
| Title, branch, when you last spoke | `~/.claude/projects/**/<sessionId>.jsonl` |
| Waiting for permission, background work | hooks write to `~/.claude/session-dashboard/state/` |
| What it is waiting on, suggested name | `claude -p --model haiku` after each turn (uses your own Claude login and counts toward your usage), cached in `summaries/` |
| Custom names, manual states | `names.json`, `overrides.json` |

A manually set state goes back to automatic the next time you send that session a message.

## New session

The blue ＋ in the header opens a new tab in iTerm2's current window and runs `claude` in a folder of your choice. It defaults to your home directory; right-click ＋ and pick "Choose Folder…" to change it.

## Restoring sessions after a restart

The app records open sessions in `open-sessions.json`. Before macOS logs out, restarts or shuts down (including forced updates) it freezes that record; on the next launch it compares, and any session that did not come back is listed in a banner at the top. You can reopen them all, or one by one, with `cd <original dir> && claude --resume <id>` (`--resume` keeps the id, so groups and names carry over). Without a restart, a banner also appears when 3 or more sessions disappear at once (e.g. iTerm2 crashed).

## PR and CI status

A session's PR is the last PR link in its conversation that belongs to the same repo (by git origin). Status, reviews and CI (both check runs and commit statuses) come from `gh pr view`. Open PRs refresh every 2 minutes (every minute while CI runs), merged / closed ones every 30 minutes. Click `#number` to open the PR in the browser.

## Open a branch in Cursor

A session's "⋯" menu has "Open <branch> in Cursor": if the branch is already checked out in a worktree (including the main checkout) Cursor opens it directly; otherwise the row asks whether to create `.claude/worktrees/<branch, with / replaced by ->` and only runs `git worktree add` after you confirm.

Note: the branch is whatever was checked out when the session's last message was written; when several sessions share one checkout, another session may have switched it.

## Groups

- The row of tabs under the title is All / Ungrouped / your groups; click a tab to show only that group, tabs wrap when they don't fit
- The number on a tab is its session count; the small orange badge is how many are waiting on you
- ＋ creates a group; or pick "Move to Group → New Group…" in a session's "⋯" menu to create one and file the session at once
- Drag a session onto a group tab to move it there; drag it onto "Ungrouped" to take it out
- Tabs can be reordered by dragging, "All" and "Ungrouped" included; a blue "|" marks the drop point — the left half of a tab inserts before it, the right half after it, and dropping on ＋ moves it to the end
- Right-click a group tab (or use the "⋯" next to the selected one) to rename it, move it left / right, or delete it (its sessions go back to Ungrouped)
- In "All", each session shows the group it belongs to
- Groups, tab order and the selected tab are stored in `groups.json`, keyed by sessionId

## Debugging

```bash
.build/release/ClaudeSessionBar --dump               # print the current state (including groups)
.build/release/ClaudeSessionBar --dump --summarize   # run the Haiku summaries first, then print
.build/release/ClaudeSessionBar --snapshot out.png   # render the popover offscreen to an image (add --dark for dark mode)

# Launch the real menu bar app, open its popover, take screenshots, then quit
build/ClaudeSessionBar.app/Contents/MacOS/ClaudeSessionBar --selftest /tmp/csb-selftest

# Show where "Open in Cursor" would go for each session (read-only)
.build/release/ClaudeSessionBar --worktree-plan

# Print each session's PR status (calls gh)
.build/release/ClaudeSessionBar --dump --prs

# Check the restart-restore logic (point it at an empty temp folder)
mkdir -p /tmp/csb-restore && CSB_DASHBOARD_DIR=/tmp/csb-restore .build/release/ClaudeSessionBar --check-restore

# Check PR link parsing and CI evaluation
.build/release/ClaudeSessionBar --check-pr

# Check worktree creation (runs in a throwaway test repo, deleted afterwards)
.build/release/ClaudeSessionBar --check-worktree

# Check group operations; always point it at a copy, or it edits your real groups.json
cp -R ~/.claude/session-dashboard /tmp/csb-copy && rm -f /tmp/csb-copy/groups.json
CSB_DASHBOARD_DIR=/tmp/csb-copy .build/release/ClaudeSessionBar --check-groups
```

## License

[MIT](LICENSE)
