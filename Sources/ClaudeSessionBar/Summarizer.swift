import Foundation

struct SummaryJob {
    let sessionId: String
    let uuid: String
    let prompt: String
    let language: AppLanguage
}

/// Asks Haiku (through the user's own `claude` login) what a session is waiting for.
enum Summarizer {
    static func run(_ job: SummaryJob, claude: String) -> Summary? {
        try? FileManager.default.createDirectory(at: Paths.summarizerWorkDir, withIntermediateDirectories: true)
        var env = ClaudeCLI.environment
        // hook.py ignores events while this is set; otherwise every summary would trigger another one.
        env["CSB_SUMMARIZER"] = "1"
        let args = [
            "-p", "--model", "haiku", "--no-session-persistence", "--tools", "", "--strict-mcp-config",
            "--output-format", "text",
        ]
        guard
            let out = Shell.run(
                claude, args, stdin: job.prompt, env: env, cwd: Paths.summarizerWorkDir, timeout: 90),
            out.status == 0
        else { return nil }
        var summary = parse(out.stdout, uuid: job.uuid)
        summary?.lang = job.language.rawValue
        return summary
    }

    static func parse(_ output: String, uuid: String) -> Summary? {
        guard let open = output.firstIndex(of: "{"), let close = output.lastIndex(of: "}"), open < close,
            let obj = (try? JSONSerialization.jsonObject(with: Data(output[open...close].utf8)))
                as? [String: Any]
        else { return nil }
        return Summary(
            uuid: uuid,
            at: Date().timeIntervalSince1970,
            state: obj["state"] as? String ?? "",
            summary: obj["summary"] as? String ?? "",
            waitingFor: obj["waiting_for"] as? String ?? "",
            suggestedName: obj["suggested_name"] as? String ?? "",
            closable: obj["closable"] as? Bool ?? false)
    }

    static func prompt(name: String, cwd: String, branch: String?, tail: [String], language: AppLanguage) -> String {
        guard language == .zh else { return englishPrompt(name: name, cwd: cwd, branch: branch, tail: tail) }
        return """
        你是 Claude Code session 的狀態整理器。下面是一個 session 最後幾則對話，[user] 是使用者、[assistant] 是 Claude。
        這個 session 目前沒有在執行，輪到使用者處理。
        目前顯示名稱：\(name)
        工作目錄：\(cwd)
        branch：\(branch ?? "未知")

        請只輸出一個 JSON 物件，不要任何其他文字或 code fence：
        {"state": "...", "summary": "...", "waiting_for": "...", "suggested_name": "...", "closable": false}

        欄位規則：
        - state 只能是以下之一：
          waiting_answer：Claude 問了問題，等使用者回答
          waiting_decision：等使用者決定要不要進行某個動作（commit、push、merge、執行指令、套用修改等）
          waiting_external：在等外部事件（CI、別人 review、部署、對方回覆），使用者暫時不用做事
          blocked：卡在錯誤或障礙，需要使用者介入排除
          done：任務完成，沒有待辦
        - summary：一句話說目前進度，繁體中文 30 字內
        - waiting_for：使用者下一步要做什麼，繁體中文 40 字內；waiting_external 時寫在等什麼；done 時給空字串
        - suggested_name：繁體中文短標題 15 字內，保留 ticket 編號（如 GEN-4234、OPE-5913）或 PR 號；目前顯示名稱已經貼切就原樣沿用
        - closable：done 且沒有任何待辦時才是 true

        對話：
        \(tail.joined(separator: "\n\n"))
        """
    }

    private static func englishPrompt(name: String, cwd: String, branch: String?, tail: [String]) -> String {
        """
        You summarize the state of a Claude Code session. Below are the last few messages of the session; [user] is the user and [assistant] is Claude.
        The session is not running right now; it is the user's turn.
        Current display name (may be in another language): \(name)
        Working directory: \(cwd)
        Branch: \(branch ?? "unknown")

        Output exactly one JSON object and nothing else (no prose, no code fence). Every text field must be in English:
        {"state": "...", "summary": "...", "waiting_for": "...", "suggested_name": "...", "closable": false}

        Field rules:
        - state must be one of:
          waiting_answer: Claude asked a question and is waiting for the user's answer
          waiting_decision: waiting for the user to decide whether to do something (commit, push, merge, run a command, apply a change, ...)
          waiting_external: waiting on something outside (CI, someone's review, a deploy, a reply); the user has nothing to do for now
          blocked: stuck on an error or obstacle that needs the user to step in
          done: the task is finished with nothing left to do
        - summary: one sentence on the current progress, in English, at most 12 words
        - waiting_for: what the user should do next, in English, at most 15 words; for waiting_external say what it is waiting on; empty string when done
        - suggested_name: a short title of at most 6 words, always written in English (translate the current display name if it is in another language); keep ticket ids (e.g. GEN-4234, OPE-5913) and PR numbers; if the current display name is already English and fits, keep it as is
        - closable: true only when done and nothing is left to do

        Conversation:
        \(tail.joined(separator: "\n\n"))
        """
    }
}
