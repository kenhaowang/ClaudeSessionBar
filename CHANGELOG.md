# 版本紀錄 / Changelog

格式參考 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，版本號遵循 [Semantic Versioning](https://semver.org/lang/zh-TW/)。

## [1.0.0] - 2026-10-22

第一個公開版本。

### 功能

- 選單列圖示依「在等你」的 session 數量變化：🌳 0–1、🍌 2–5、🍊 7–10、🔥 11 以上、🎂 剛好 6 或 19
- 列出所有開著的 Claude Code session，顯示等你核准、等你回覆、執行中、背景執行、閒置、完成等狀態，點一下切到對應的 iTerm2 分頁
- 每輪結束後用 Haiku 判斷 session 在等你做什麼，並建議名稱
- 自訂 session 名稱、手動設定狀態（下次發言後自動恢復）
- 群組：建立、改名、刪除、拖曳排序，把 session 拖進群組
- 「＋」在 iTerm2 開新分頁啟動 `claude`，資料夾可在右鍵選單設定
- 重開機或 iTerm2 當掉後，提示沒開回來的 session 並可一鍵 `claude --resume`
- 顯示 session 對應 PR 的狀態、review 與 CI（需要 `gh`）
- 在 Cursor 開啟 session 的分支，必要時建立 git worktree
- 中英文介面切換、登入時啟動

[1.0.0]: https://github.com/kenhaowang/ClaudeSessionBar/releases/tag/v1.0.0
