import Foundation

/// Finds (or creates) the git worktree that has a branch checked out, and opens it in Cursor.
enum Worktree {
    struct Entry: Equatable {
        let path: String
        let branch: String?
    }

    private static let git = "/usr/bin/git"

    /// Every worktree of the repository containing `directory`; the main worktree comes first.
    static func list(repoDirectory directory: String) -> [Entry]? {
        guard let out = Shell.run(git, ["-C", directory, "worktree", "list", "--porcelain"]), out.status == 0
        else { return nil }
        return parse(porcelain: out.stdout)
    }

    static func parse(porcelain: String) -> [Entry] {
        var entries: [Entry] = []
        var path: String?
        var branch: String?
        for line in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                if let path { entries.append(Entry(path: path, branch: branch)) }
                path = String(line.dropFirst("worktree ".count))
                branch = nil
            } else if line.hasPrefix("branch refs/heads/") {
                branch = String(line.dropFirst("branch refs/heads/".count))
            }
        }
        if let path { entries.append(Entry(path: path, branch: branch)) }
        return entries
    }

    /// Same place Claude Code's own worktrees live: <main worktree>/.claude/worktrees/<branch>.
    static func suggestedPath(mainRoot: String, branch: String) -> String {
        let name = branch.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "-" }
        return mainRoot + "/.claude/worktrees/" + String(name)
    }

    /// Returns git's error message on failure. A branch that only exists on the remote is picked
    /// up by git's own DWIM (it creates a local tracking branch).
    static func add(mainRoot: String, path: String, branch: String) -> String? {
        guard
            let out = Shell.run(
                git, ["-C", mainRoot, "worktree", "add", path, branch], timeout: 180, captureStderr: true)
        else { return tr("無法執行 git", "Couldn't run git") }
        guard out.status != 0 else { return nil }
        let message = out.stdout.split(separator: "\n").last { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") }
        return String(message ?? out.stdout.split(separator: "\n").last ?? Substring(tr("git worktree add 失敗", "git worktree add failed")))
    }

    static func openInCursor(_ path: String) -> Bool {
        let cli = "\(Paths.home.path)/.local/bin/cursor"
        if FileManager.default.isExecutableFile(atPath: cli),
            Shell.run(cli, [path], env: ClaudeCLI.environment, timeout: 20)?.status == 0
        {
            return true
        }
        return Shell.run("/usr/bin/open", ["-a", "Cursor", path])?.status == 0
    }
}
