import Foundation
import os

/// Query with: /usr/bin/log show --last 10m --predicate 'subsystem == "com.kenhao.ClaudeSessionBar"'
enum Log {
    static let jump = Logger(subsystem: "com.kenhao.ClaudeSessionBar", category: "jump")
}

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let claude = home.appendingPathComponent(".claude")
    static let sessions = claude.appendingPathComponent("sessions")
    static let projects = claude.appendingPathComponent("projects")
    static let settings = claude.appendingPathComponent("settings.json")
    /// CSB_DASHBOARD_DIR lets tests run against a copy instead of the user's real names/groups.
    static let dashboard: URL = {
        if let override = ProcessInfo.processInfo.environment["CSB_DASHBOARD_DIR"] {
            return URL(fileURLWithPath: override)
        }
        return claude.appendingPathComponent("session-dashboard")
    }()
    static let hookState = dashboard.appendingPathComponent("state")
    static let summaries = dashboard.appendingPathComponent("summaries")
    static let names = dashboard.appendingPathComponent("names.json")
    static let overrides = dashboard.appendingPathComponent("overrides.json")
    static let groups = dashboard.appendingPathComponent("groups.json")
    static let openSessions = dashboard.appendingPathComponent("open-sessions.json")
    static let restorePending = dashboard.appendingPathComponent("restore-pending.json")
    /// Where the header's ＋ button starts a new `claude` session until the user picks a folder.
    static let defaultNewSessionDirectory = home.path
    // Must stay outside $HOME: Claude Code walks up from cwd and would load ~/CLAUDE.md.
    static let summarizerWorkDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("claude-session-bar")

    /// Claude Code stores transcripts under the cwd with every non-alphanumeric character replaced by "-".
    static func projectSlug(_ cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }
}

enum JSONFile {
    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

enum AppLanguage: String {
    case zh, en
}

enum L10n {
    /// Mirrors Store.language so model types and helpers can translate without a store reference.
    /// CSB_LANG lets tests pick a language without touching the user's saved choice.
    static var language: AppLanguage =
        AppLanguage(rawValue: ProcessInfo.processInfo.environment["CSB_LANG"] ?? "")
        ?? AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .zh

    static var locale: Locale { Locale(identifier: language == .en ? "en_US" : "zh_Hant_TW") }
}

/// The UI string for the current language.
func tr(_ zh: String, _ en: String) -> String {
    L10n.language == .en ? en : zh
}

enum Shell {
    struct Output {
        let status: Int32
        let stdout: String
    }

    static func run(
        _ path: String, _ args: [String], stdin: String? = nil,
        env: [String: String]? = nil, cwd: URL? = nil, timeout: TimeInterval = 10, captureStderr: Bool = false
    ) -> Output? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        if let env { process.environment = env }
        if let cwd { process.currentDirectoryURL = cwd }
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = captureStderr ? outPipe : FileHandle.nullDevice
        let inPipe = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe
        do { try process.run() } catch { return nil }
        if let stdin {
            try? inPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return Output(status: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self))
    }
}

enum ClaudeCLI {
    static let path: String? = {
        let candidates = [
            "\(Paths.home.path)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        guard let out = Shell.run("/bin/zsh", ["-lc", "command -v claude"], timeout: 5), out.status == 0
        else { return nil }
        let resolved = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return resolved.isEmpty ? nil : resolved
    }()

    /// Apps launched from Finder get launchd's minimal PATH, which lacks the usual CLI locations.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = "\(Paths.home.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = extra + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        return env
    }
}

enum RelativeTime {
    static func text(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return tr("剛剛", "just now") }
        if seconds < 3600 { return tr("\(Int(seconds / 60)) 分鐘前", "\(Int(seconds / 60))m ago") }
        if seconds < 86400 { return tr("\(Int(seconds / 3600)) 小時前", "\(Int(seconds / 3600))h ago") }
        return tr("\(Int(seconds / 86400)) 天前", "\(Int(seconds / 86400))d ago")
    }
}

enum Housekeeping {
    /// Drops hook/summary files of sessions that have been gone for a while.
    static func prune(olderThanDays days: Double = 14) {
        let cutoff = Date().addingTimeInterval(-days * 86400)
        let fm = FileManager.default
        for dir in [Paths.hookState, Paths.summaries] {
            let files =
                (try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                if let modified, modified < cutoff { try? fm.removeItem(at: file) }
            }
        }
    }

    static func hooksInstalled() -> Bool {
        guard let text = try? String(contentsOf: Paths.settings, encoding: .utf8) else { return false }
        return text.contains("session-dashboard/hook.py")
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

enum Today {
    /// CSB_TODAY=YYYY-MM-DD lets tests pretend it is another day.
    static var date: Date {
        if let override = ProcessInfo.processInfo.environment["CSB_TODAY"] {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            if let date = formatter.date(from: override) { return date }
        }
        return Date()
    }

    /// June 19 gets a cake next to the title, by request.
    static var isCakeDay: Bool {
        let parts = Calendar.current.dateComponents([.month, .day], from: date)
        return parts.month == 6 && parts.day == 19
    }
}

func waitingText(_ count: Int) -> String {
    let noun = count == 1 ? "session" : "sessions"
    return tr("\(count) 個 \(noun) 在等你看", "\(count) \(noun) waiting for you")
}
