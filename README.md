# Claude Session Bar

繁體中文 | [English](README.en.md)

選單列上的 Claude Code session 儀表板：列出所有開著的 session、判斷「在等你做什麼」、點一下切到對應的 iTerm 分頁。

> 這是個人的非官方專案，與 Anthropic 沒有關聯，也未經其認可。

<p align="center"><img src="docs/screenshot-zh.png" width="512" alt="選單列圖示與展開的 session 列表"></p>

## 需求

- macOS 14 以上，並安裝 Xcode Command Line Tools（Swift 5.9+）
- [iTerm2](https://iterm2.com/)：session 需要跑在 iTerm2 裡，才能點擊切換和開新分頁
- [Claude Code](https://docs.claude.com/en/docs/claude-code) CLI（`claude`）並已登入
- 選用：[GitHub CLI](https://cli.github.com/)（`gh`）用來顯示 PR／CI 狀態；[Cursor](https://cursor.com/) 用來開啟分支

## 安裝

1. 確認已安裝 Xcode Command Line Tools（`swift --version` 有輸出就是有；沒有的話執行下面第一行）：

   ```bash
   xcode-select --install
   ```

2. 下載原始碼並編譯安裝：

   ```bash
   git clone https://github.com/kenhaowang/ClaudeSessionBar.git
   cd ClaudeSessionBar
   ./build.sh install                   # 編譯、裝到 ~/Applications/ClaudeSessionBar.app 並啟動
   ```

   App 是在你自己的電腦上編譯並簽署，不會被 Gatekeeper 擋下。

3. 安裝 Claude Code hooks（讓 App 知道哪個 session 在等你核准權限、哪個剛跑完）：

   ```bash
   /usr/bin/python3 install_hooks.py    # 寫進 ~/.claude/settings.json，有舊檔會先備份
   ```

   Claude Code 在 session 啟動時才讀 hooks，已經開著的 session 要重開才會套用。

4. 選單列出現圖示後點開：
   - 第一次點擊 session 時，macOS 會詢問是否允許控制 iTerm2，要按「允許」
   - 底部可以勾選「登入時啟動」
   - 點「＋」→ 最下面的「工作目錄：…（更換…）」，設定開新 session 的資料夾

## 更新

```bash
cd ClaudeSessionBar
git pull
./build.sh install                       # 會先關掉舊的再啟動新的
/usr/bin/python3 install_hooks.py        # hooks 有更新時才需要；重跑不會重複寫入
```

## 移除

```bash
/usr/bin/python3 install_hooks.py --uninstall
rm -rf ~/Applications/ClaudeSessionBar.app ~/.claude/session-dashboard
```

## 資料從哪來

| 資訊 | 來源 |
|---|---|
| session 清單、執行中／閒置 | `claude agents --json` |
| 標題、branch、你上次發言時間 | `~/.claude/projects/**/<sessionId>.jsonl` |
| 等你核准權限、背景工作 | hooks 寫入 `~/.claude/session-dashboard/state/` |
| 在等你做什麼、建議名稱 | 每輪結束後用 `claude -p --model haiku` 判斷（用你自己的 Claude 登入，會算進你的用量），存在 `summaries/` |
| 自訂名稱、手動狀態 | `names.json`、`overrides.json` |

手動設定的狀態會在你下次對那個 session 發言後自動恢復成自動判斷。

## 開新 session

標題列的「＋」會跳出選單，在 iTerm 目前的視窗開新分頁、在工作目錄執行 `claude`：

- 「直接開新分頁」：不放進任何群組
- 「新 session 放到：」下面列出所有群組，選一個就開新分頁並直接歸到那組
- 「新增資料夾…」：輸入名稱建立新群組，並把新 session 放進去
- 「工作目錄：<資料夾>（更換…）」：更換開新 session 的資料夾（預設是家目錄；在「＋」上按右鍵選「選擇資料夾…」也可以）

新 session 會用 `claude --session-id <預先產生的 id>` 啟動，所以一開起來就在選好的群組裡。

## 重開機後恢復 session

App 會把開著的 session 記在 `open-sessions.json`。macOS 登出／重開／關機（含強制更新）前會先凍結這份記錄；開機後 App 一啟動就比對，沒回來的 session 會出現在列表最上方的提示，可以全部或逐一用 `cd <原目錄> && claude --resume <id>` 開回來（`--resume` 沿用原 id，群組、名稱都接得上）。沒重開機時，同時少了 3 個以上（例如 iTerm 當掉）也會提示。

## PR 與 CI 狀態

session 對話裡最後出現、且屬於同一個 repo（看 git origin）的 PR 連結，就是這個 session 的 PR。用 `gh pr view` 抓狀態、review、CI（check run 與 commit status 都算），開著的 PR 每 2 分鐘更新（CI 跑中 1 分鐘）、已合併／關閉的 30 分鐘。點 `#號碼` 用瀏覽器開 PR。

## 在 Cursor 開啟分支

session 的「⋯」選單有「在 Cursor 開啟 <分支>」：分支已經在某個 worktree（含主目錄）就直接用 Cursor 開；沒有的話會在該列詢問是否建立 `.claude/worktrees/<分支，/ 換成 ->`，確認後才執行 `git worktree add`。

注意：分支取自 session 最後一則訊息當下 checkout 所在的分支；多個 session 共用同一份 checkout 時，可能是別的 session 切過去的分支。

## 分組

- 標題下方是一排群組標籤：全部／未分組／你建立的群組；點標籤就只看那一組，放不下會自動換行
- 標籤上的數字是 session 數，橘色小圈是「在等你」的數量
- 「＋」新增群組；或在 session 的「⋯」選單選「移到群組 → 新增群組…」，建立後直接放進去
- 把 session 拖到群組標籤上就會移過去；拖到「未分組」就是移出
- 標籤可以拖曳排序，「全部」和「未分組」也可以；拖動時會出現藍色「|」標出落點：游標在目標標籤左半邊就插在它前面、右半邊就插在後面，拖到「＋」上就移到最後
- 群組標籤按右鍵（或選中後右邊的「⋯」）可以改名、往左／右移、刪除（刪除後 session 回到未分組）
- 在「全部」裡，每個 session 會顯示它所屬的群組
- 群組、標籤順序與目前選中的標籤存在 `groups.json`，以 sessionId 對應

## 除錯

```bash
.build/release/ClaudeSessionBar --dump               # 印出目前的判斷結果（含分組）
.build/release/ClaudeSessionBar --dump --summarize   # 先補跑 Haiku 再印
.build/release/ClaudeSessionBar --snapshot out.png   # 離線把選單內容畫成圖片（加 --dark 看暗色）

# 啟動真正的選單列 App、自己打開彈出視窗並截圖，然後結束
build/ClaudeSessionBar.app/Contents/MacOS/ClaudeSessionBar --selftest /tmp/csb-selftest

# 每個 session 的「在 Cursor 開啟」會開哪裡（唯讀）
.build/release/ClaudeSessionBar --worktree-plan

# 印出每個 session 的 PR 狀態（會呼叫 gh）
.build/release/ClaudeSessionBar --dump --prs

# 重開機恢復邏輯檢查（要指向空的暫存資料夾）
mkdir -p /tmp/csb-restore && CSB_DASHBOARD_DIR=/tmp/csb-restore .build/release/ClaudeSessionBar --check-restore

# PR 連結解析與 CI 判斷檢查
.build/release/ClaudeSessionBar --check-pr

# worktree 建立邏輯檢查（在暫存的測試 repo 跑，跑完刪除）
.build/release/ClaudeSessionBar --check-worktree

# 用虛構的 session 重新產生 README 截圖（真的螢幕截圖，終端機需有「螢幕錄製」權限；沒有的話改用 App 自己畫的圖）
CSB_DEMO=1 CSB_LANG=zh CSB_DASHBOARD_DIR=/tmp/csb-demo \
  build/ClaudeSessionBar.app/Contents/MacOS/ClaudeSessionBar --screenshot docs/screenshot-zh.png

# 群組操作檢查；一定要指向副本，否則會改到真的 groups.json
cp -R ~/.claude/session-dashboard /tmp/csb-copy && rm -f /tmp/csb-copy/groups.json
CSB_DASHBOARD_DIR=/tmp/csb-copy .build/release/ClaudeSessionBar --check-groups
```

## 版本

目前版本：**v1.1**（[所有版本](https://github.com/kenhaowang/ClaudeSessionBar/releases)）

### v1.1（2026-10-27）

- 「＋」改成選單：可以直接開新分頁、選擇新 session 要放進哪個群組，或當場新增資料夾並放進去
- 工作目錄顯示在「＋」選單最下面，可直接更換

### v1.0.0（2026-10-22）

第一個公開版本。

- 選單列圖示會依「在等你」的 session 數量變化
- 列出所有開著的 Claude Code session，顯示等你核准、等你回覆、執行中、背景執行、閒置、完成等狀態，點一下切到對應的 iTerm2 分頁
- 每輪結束後用 Haiku 判斷 session 在等你做什麼，並建議名稱
- 自訂 session 名稱、手動設定狀態（下次發言後自動恢復）
- 群組：建立、改名、刪除、拖曳排序，把 session 拖進群組
- 「＋」在 iTerm2 開新分頁啟動 `claude`，資料夾可在右鍵選單設定
- 重開機或 iTerm2 當掉後，提示沒開回來的 session 並可一鍵 `claude --resume`
- 顯示 session 對應 PR 的狀態、review 與 CI（需要 `gh`）
- 在 Cursor 開啟 session 的分支，必要時建立 git worktree
- 中英文介面切換、登入時啟動

## 授權

[MIT](LICENSE)
