import Foundation

/// Made-up sessions for README screenshots (`CSB_DEMO=1`), so no real project shows up in them.
enum Demo {
    static let enabled = ProcessInfo.processInfo.environment["CSB_DEMO"] == "1"

    /// The row drawn as iTerm's current tab.
    static let activeTTY = "/dev/ttys002"

    private static let cwd = "/Users/demo/code/shop-api"
    private static let owner = "acme"
    private static let repo = "shop-api"

    private struct Entry {
        let tty: String
        let name: (String, String)
        let branch: String
        let minutesAgo: Double
        var status = "idle"
        var hookState: String?
        var notification: String?
        var summaryState = "idle"
        var summary: (String, String) = ("", "")
        var waitingFor: (String, String) = ("", "")
        var group: String?
        var pr: PRStatus?
    }

    private static func pr(
        _ number: Int, _ title: String, state: String = "OPEN", review: String = "", ci: CIState,
        failed: [String] = []
    ) -> PRStatus {
        PRStatus(
            number: number, title: title, state: state, isDraft: false, reviewDecision: review, ci: ci,
            failedChecks: failed, fetchedAt: Date())
    }

    private static let entries: [Entry] = [
        Entry(
            tty: "/dev/ttys001", name: ("付款 webhook 失敗重試", "Retry failed payment webhooks"),
            branch: "feat/webhook-retry", minutesAgo: 2, hookState: "waiting_approval",
            notification: "Claude needs your permission to use Bash", group: "dev",
            pr: pr(128, "Retry failed payment webhooks", review: "REVIEW_REQUIRED", ci: .pending)),
        Entry(
            tty: "/dev/ttys002", name: ("日報時間差 8 小時", "Daily report is 8 hours off"),
            branch: "fix/report-timezone", minutesAgo: 14, summaryState: "waiting_decision",
            summary: ("改用店家時區計算日報", "Daily report now uses the store's time zone"),
            waitingFor: ("要你決定：過去 30 天的報表要不要一起重算", "Your call: also recompute the last 30 days of reports?"),
            group: "dev",
            pr: pr(131, "Fix daily report time zone", review: "CHANGES_REQUESTED", ci: .failure, failed: ["unit-tests"])),
        Entry(
            tty: "/dev/ttys003", name: ("回覆 #117 的 review 意見", "Answer review comments on #117"),
            branch: "feat/coupon-limit", minutesAgo: 40, summaryState: "waiting_answer",
            summary: ("三則意見已修兩則", "Two of three comments addressed"),
            waitingFor: ("問你：上限要算每人還是每筆訂單", "Question for you: limit per customer or per order?"),
            group: "review",
            pr: pr(117, "Limit coupon redemptions", review: "CHANGES_REQUESTED", ci: .success)),
        Entry(
            tty: "/dev/ttys004", name: ("升級 Django 5.2", "Upgrade to Django 5.2"),
            branch: "chore/django-5.2", minutesAgo: 3, status: "busy", group: "dev"),
        Entry(
            tty: "/dev/ttys005", name: ("跑完整測試", "Run the full test suite"),
            branch: "chore/django-5.2", minutesAgo: 25, hookState: "idle_bg", group: "dev"),
        Entry(
            tty: "/dev/ttys006", name: ("Review #120 搜尋 API", "Review #120 search API"),
            branch: "main", minutesAgo: 95, summaryState: "waiting_external",
            summary: ("留了 4 則意見", "Left 4 review comments"),
            waitingFor: ("等作者回覆 review", "Waiting for the author to respond"), group: "review",
            pr: pr(120, "Add product search API", review: "REVIEW_REQUIRED", ci: .success)),
        Entry(
            tty: "/dev/ttys007", name: ("新人上手文件", "Onboarding guide"),
            branch: "docs/onboarding", minutesAgo: 60 * 26, summaryState: "done",
            summary: ("文件已合併", "Guide merged"),
            pr: pr(119, "Write onboarding guide", state: "MERGED", review: "APPROVED", ci: .success)),
        Entry(
            tty: "/dev/ttys008", name: ("訂單查詢變慢", "Slow order search"),
            branch: "main", minutesAgo: 60 * 24 * 4,
            summary: ("找到缺少的索引，還沒動手", "Found the missing index, not started yet")),
    ]

    private static func sessionId(_ index: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012d", index + 1)
    }

    private static func text(_ pair: (String, String)) -> String { tr(pair.0, pair.1) }

    static func sessions() -> [RawSession] {
        let now = Date().timeIntervalSince1970
        return entries.enumerated().map { index, entry in
            let sid = sessionId(index)
            let spoke = Date(timeIntervalSince1970: now - entry.minutesAgo * 60)
            var transcript = TranscriptInfo()
            transcript.aiTitle = text(entry.name)
            transcript.gitBranch = entry.branch
            transcript.cwd = cwd
            transcript.lastUserAt = spoke
            transcript.lastMessageAt = spoke.addingTimeInterval(30)
            transcript.lastMessageUUID = "demo-\(index)"
            if let pr = entry.pr { transcript.prMentions = [PRRef(owner: owner, repo: repo, number: pr.number)] }
            let hook = entry.hookState.map {
                HookState(
                    sessionId: sid, transcriptPath: nil, state: $0, at: now, lastPromptAt: spoke.timeIntervalSince1970,
                    notification: entry.notification)
            }
            return RawSession(
                agent: AgentEntry(
                    pid: 90000 + index, id: nil, cwd: cwd, kind: "interactive", sessionId: sid, name: nil,
                    status: entry.status, state: nil),
                tty: entry.tty, hook: hook, transcript: transcript, repoKey: "\(owner)/\(repo)")
        }
    }

    static func summaries() -> [String: Summary] {
        var result: [String: Summary] = [:]
        for (index, entry) in entries.enumerated() {
            result[sessionId(index)] = Summary(
                uuid: "demo-\(index)", at: Date().timeIntervalSince1970, state: entry.summaryState,
                summary: text(entry.summary), waitingFor: text(entry.waitingFor), suggestedName: text(entry.name),
                closable: false, lang: L10n.language.rawValue)
        }
        return result
    }

    static func groups() -> GroupData {
        var data = GroupData()
        data.groups = [
            SessionGroup(id: "dev", name: tr("開發", "Development")),
            SessionGroup(id: "review", name: "PR Review"),
        ]
        for (index, entry) in entries.enumerated() {
            if let group = entry.group { data.assignments[sessionId(index)] = group }
        }
        data.selected = "all"
        return data
    }

    static func prStatuses() -> [String: PRStatus] {
        var result: [String: PRStatus] = [:]
        for entry in entries {
            if let pr = entry.pr { result[PRRef(owner: owner, repo: repo, number: pr.number).url] = pr }
        }
        return result
    }
}
