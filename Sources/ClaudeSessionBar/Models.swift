import Foundation

enum WorkState: String, Codable {
    case waitingApproval, waitingReply, blocked, running, background, summarizing, waitingExternal,
        idle, paused, done

    var label: String {
        switch self {
        case .waitingApproval: return tr("等你核准", "Needs approval")
        case .waitingReply: return tr("等你回覆", "Needs reply")
        case .blocked: return tr("卡住了", "Blocked")
        case .running: return tr("執行中", "Running")
        case .background: return tr("背景執行", "Background")
        case .summarizing: return tr("判斷中", "Analyzing")
        case .waitingExternal: return tr("等外部", "Waiting on others")
        case .idle: return tr("閒置", "Idle")
        case .paused: return tr("暫停", "Paused")
        case .done: return tr("完成", "Done")
        }
    }

    var needsYou: Bool { self == .waitingApproval || self == .waitingReply || self == .blocked }

    /// What the "waiting" numbers count. A turn that just ended (still being summarized) is
    /// counted right away; Haiku takes it back out if it turns out to be done or waiting on others.
    var countsAsWaiting: Bool { needsYou || self == .summarizing }

    /// Claude is actively doing something, so a summary of the last turn would be outdated immediately.
    var isLive: Bool { self == .running || self == .waitingApproval || self == .background }

    var rank: Int {
        switch self {
        case .waitingApproval: return 0
        case .waitingReply: return 1
        case .blocked: return 2
        case .running: return 3
        case .background: return 4
        case .summarizing: return 5
        case .waitingExternal: return 6
        case .idle: return 7
        case .paused: return 8
        case .done: return 9
        }
    }
}

enum ManualState: String, Codable, CaseIterable {
    case waitingMe, waitingExternal, paused, done

    var label: String {
        switch self {
        case .waitingMe: return tr("等我處理", "Needs me")
        case .waitingExternal: return tr("等外部（CI、review…）", "Waiting on others (CI, review…)")
        case .paused: return tr("暫停", "Paused")
        case .done: return tr("完成", "Done")
        }
    }

    var workState: WorkState {
        switch self {
        case .waitingMe: return .waitingReply
        case .waitingExternal: return .waitingExternal
        case .paused: return .paused
        case .done: return .done
        }
    }
}

struct Override: Codable {
    let state: ManualState
    let at: Double
}

struct SessionGroup: Codable, Identifiable, Equatable {
    let id: String
    var name: String
}

/// Persisted as groups.json. Assignments are keyed by sessionId. Files written by v0.2 also carry
/// `collapsed`/`ungroupedCollapsed`; decoding ignores those keys.
struct GroupData: Codable, Equatable {
    var groups: [SessionGroup] = []
    var assignments: [String: String] = [:]
    /// Raw `GroupFilter` of the selected tab; optional so older files still decode.
    var selected: String?
    /// Raw `GroupFilter`s in the order the user dragged the tabs into, 全部 and 未分組 included.
    var tabOrder: [String]?
}

enum GroupFilter: Equatable {
    case all
    case ungrouped
    case group(String)

    init(raw: String?) {
        switch raw {
        case nil, "all": self = .all
        case "ungrouped": self = .ungrouped
        case let id?: self = .group(id)
        }
    }

    var raw: String {
        switch self {
        case .all: return "all"
        case .ungrouped: return "ungrouped"
        case .group(let id): return id
        }
    }
}

struct GroupSection: Identifiable {
    /// nil is the implicit "未分組" section.
    let group: SessionGroup?
    let rows: [SessionRow]

    var id: String { group?.id ?? "ungrouped" }
    var name: String { group?.name ?? tr("未分組", "Ungrouped") }
    var needsYouCount: Int { rows.filter { $0.state.needsYou }.count }
}

/// A session's branch has no worktree yet; shown inline in that row until confirmed or cancelled.
struct WorktreeProposal: Equatable {
    let sessionId: String
    let branch: String
    let mainRoot: String
    let path: String
    let editor: Editor
}

enum DragKind: Equatable {
    case tab(GroupFilter)
    case session(String)
}

/// Where a hovering drag would land relative to a tab chip.
enum DropSide: Equatable {
    case before, after
    /// A session dragged onto a group tab: file it there.
    case onto
}

enum NewGroupTarget: Equatable {
    case bar
    case row(String)
}

/// Bootstrap's primary / success / warning / danger / secondary; tapping the title cycles them.
enum AccentTheme: String, CaseIterable {
    case blue, green, yellow, red, gray

    var next: AccentTheme {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

enum SortMode: String, CaseIterable, Identifiable {
    case state, stalest

    var id: String { rawValue }
    var label: String { self == .state ? tr("依狀態", "By Status") : tr("最久沒理", "Stalest") }
}

/// One row of `claude agents --json`.
struct AgentEntry: Decodable {
    let pid: Int
    let id: String?
    let cwd: String
    let kind: String
    let sessionId: String
    let name: String?
    let status: String?
    let state: String?

    var isBackground: Bool { kind != "interactive" }
}

/// `~/.claude/sessions/<pid>.json`, used only when `claude agents --json` is unavailable.
struct RegistryEntry: Decodable {
    let pid: Int
    let sessionId: String
    let cwd: String
    let kind: String?
    let name: String?
    let status: String?
    let jobId: String?
}

/// Written by hooks/hook.py.
struct HookState: Decodable {
    let sessionId: String
    let transcriptPath: String?
    let state: String?
    let at: Double
    let lastPromptAt: Double?
    let notification: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case state, at
        case lastPromptAt = "last_prompt_at"
        case notification
    }
}

struct TranscriptInfo {
    var aiTitle: String?
    var lastPrompt: String?
    var gitBranch: String?
    var cwd: String?
    var lastUserAt: Date?
    var lastMessageAt: Date?
    var lastMessageUUID: String?
    var tail: [String] = []
    /// Distinct PRs linked in the conversation, most recently mentioned last.
    var prMentions: [PRRef] = []

    mutating func pushTail(_ text: String) {
        tail.append(String(text.prefix(1500)))
        if tail.count > 6 { tail.removeFirst(tail.count - 6) }
    }

    mutating func notePR(_ pr: PRRef) {
        prMentions.removeAll { $0 == pr }
        prMentions.append(pr)
        if prMentions.count > 10 { prMentions.removeFirst(prMentions.count - 10) }
    }
}

struct Summary: Codable {
    var uuid: String
    var at: Double
    var state: String
    var summary: String
    var waitingFor: String
    var suggestedName: String
    var closable: Bool
    /// Language the text fields were written in; nil for summaries made before English existed.
    var lang: String? = nil

    var language: AppLanguage { lang.flatMap(AppLanguage.init(rawValue:)) ?? .zh }

    var workState: WorkState {
        switch state {
        case "waiting_answer", "waiting_decision", "in_progress": return .waitingReply
        case "waiting_external": return .waitingExternal
        case "blocked": return .blocked
        case "done": return .done
        default: return .idle
        }
    }

    static func loadAll() -> [String: Summary] {
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: Paths.summaries, includingPropertiesForKeys: nil)) ?? []
        var result: [String: Summary] = [:]
        for file in files where file.pathExtension == "json" {
            if let summary = JSONFile.read(Summary.self, from: file) {
                result[file.deletingPathExtension().lastPathComponent] = summary
            }
        }
        return result
    }

    func save(sessionId: String) {
        JSONFile.write(self, to: Paths.summaries.appendingPathComponent(sessionId + ".json"))
    }
}

struct RawSession {
    let agent: AgentEntry
    let tty: String?
    let hook: HookState?
    let transcript: TranscriptInfo?
    /// "owner/repo" of the session's git origin, used to ignore links to unrelated repositories.
    let repoKey: String?
}

struct SessionRow: Identifiable, Equatable {
    let id: String
    let pid: Int
    let isBackground: Bool
    let jobId: String?
    let tty: String?
    let cwd: String
    let branch: String?
    let displayName: String
    let hasCustomName: Bool
    let state: WorkState
    let isManual: Bool
    let summaryUpdating: Bool
    let summary: String?
    let waitingFor: String?
    let lastPrompt: String?
    let lastSpokeAt: Date?
    let pr: PRRef?
    let prStatus: PRStatus?

    var isStale: Bool {
        guard let lastSpokeAt else { return false }
        return Date().timeIntervalSince(lastSpokeAt) >= 3 * 86400
    }
}
