import Foundation

/// Incrementally parses Claude Code transcripts (.jsonl), remembering the byte offset per session
/// so each refresh only reads lines appended since the last one.
final class TranscriptReader {
    private struct Cursor {
        var url: URL
        var offset: UInt64 = 0
        var partial = Data()
        var info = TranscriptInfo()
    }

    private var cursors: [String: Cursor] = [:]
    private static let pullMarker = Data("/pull/".utf8)

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func read(sessionId: String, url: URL) -> TranscriptInfo {
        var cursor = cursors[sessionId] ?? Cursor(url: url)
        if cursor.url != url { cursor = Cursor(url: url) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return cursor.info }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < cursor.offset { cursor = Cursor(url: url) }
        if size > cursor.offset {
            try? handle.seek(toOffset: cursor.offset)
            let chunk = (try? handle.read(upToCount: Int(size - cursor.offset))) ?? Data()
            cursor.offset += UInt64(chunk.count)
            var buffer = cursor.partial
            buffer.append(chunk)
            var start = buffer.startIndex
            while let newline = buffer[start...].firstIndex(of: 0x0A) {
                apply(line: buffer[start..<newline], to: &cursor.info)
                start = buffer.index(after: newline)
            }
            cursor.partial = Data(buffer[start...])
        }
        cursors[sessionId] = cursor
        return cursor.info
    }

    func retain(only live: Set<String>) {
        cursors = cursors.filter { live.contains($0.key) }
    }

    private func apply(line: Data, to info: inout TranscriptInfo) {
        guard line.count > 2,
            let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
            let type = obj["type"] as? String
        else { return }
        switch type {
        case "ai-title":
            if let title = obj["aiTitle"] as? String, !title.isEmpty { info.aiTitle = title }
        case "last-prompt":
            if let prompt = obj["lastPrompt"] as? String { info.lastPrompt = prompt }
        case "user", "assistant":
            if obj["isSidechain"] as? Bool == true { return }
            let cwd = obj["cwd"] as? String
            let branch = (obj["gitBranch"] as? String).flatMap { $0.isEmpty || $0 == "HEAD" ? nil : $0 }
            if let branch { info.gitBranch = branch }
            if let cwd { info.cwd = cwd }
            info.branches.noteMessage(branch: branch, cwd: cwd)
            if type == "assistant" { Self.bashCommands(in: obj).forEach { info.branches.noteCommand($0) } }
            if obj["isMeta"] as? Bool == true { return }
            // Covers user prompts, assistant text and tool output (e.g. `gh pr create` printing the URL).
            if line.range(of: Self.pullMarker) != nil, let text = String(data: line, encoding: .utf8) {
                PRRef.find(in: text).forEach { info.notePR($0) }
            }
            guard let message = obj["message"] as? [String: Any] else { return }
            let timestamp = (obj["timestamp"] as? String).flatMap { Self.iso.date(from: $0) }
            if let timestamp { info.lastMessageAt = timestamp }
            if let uuid = obj["uuid"] as? String { info.lastMessageUUID = uuid }
            let text = Self.text(of: message["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if type == "user" {
                guard let prompt = Self.userPrompt(text) else { return }
                if let timestamp { info.lastUserAt = timestamp }
                info.pushTail("[user] " + prompt)
                info.branches.notePrompt(prompt)
            } else {
                info.pushTail("[assistant] " + text)
            }
        default:
            break
        }
    }

    private static func bashCommands(in obj: [String: Any]) -> [String] {
        guard let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            guard block["type"] as? String == "tool_use", block["name"] as? String == "Bash" else { return nil }
            return (block["input"] as? [String: Any])?["command"] as? String
        }
    }

    static func text(of content: Any?) -> String {
        if let string = content as? String { return string }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
    }

    /// The prompt as the user typed it, or nil for harness-injected messages (reminders,
    /// task notifications, …). Slash commands are stored wrapped in tags but are real input.
    static func userPrompt(_ text: String) -> String? {
        guard text.hasPrefix("<") else { return text }
        guard text.hasPrefix("<command-name>") || text.hasPrefix("<command-message>") else { return nil }
        let name = capture("command-name", in: text) ?? ""
        let args = capture("command-args", in: text) ?? ""
        return (name + " " + args).trimmingCharacters(in: .whitespaces)
    }

    private static func capture(_ tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
            let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }
}

/// Works out which branch a session is on. A message's `gitBranch` is whatever the shell's
/// directory has checked out at that moment, so once the shell falls back from a worktree to the
/// shared checkout, or another session switches that checkout, it names somebody else's branch.
/// A branch counts as the session's own when it created it with `git worktree add -b`, saw it in
/// another directory (a worktree), or its own `git checkout`/`git switch` changed the checkout.
/// Failing that, a checked-out branch the user names in a prompt still counts (Claude's own replies
/// name base branches like "develop" too often to count); a branch that merely happens to be
/// checked out does not.
struct BranchTracker {
    private(set) var own: (branch: String, directory: String)?
    private(set) var mentioned: (branch: String, directory: String)?
    private var seen: [String: String] = [:]
    private var home: String?
    private var homeBranch: String?
    private var messages = 0
    private var switchedAt: Int?
    private var homeChangedAt: Int?

    /// The transcript writes a message's `gitBranch` asynchronously, so the checkout can show up a
    /// message before or after the command that caused it.
    private static let switchWindow = 3

    mutating func noteMessage(branch: String?, cwd: String?) {
        messages += 1
        guard let cwd else { return }
        if home == nil { home = cwd }
        // Claude Code keeps writing the branch of the directory the session started in, even after
        // the shell moves into a worktree, so a worktree's own branch is read from the worktree.
        if cwd != home, let worktree = worktreeBranch(containing: cwd) {
            seen[worktree.branch] = worktree.root
            own = (worktree.branch, worktree.root)
            return
        }
        guard let branch else { return }
        seen[branch] = cwd
        if cwd != home {
            if branch != homeBranch { own = (branch, cwd) }
            return
        }
        if let homeBranch, branch != homeBranch {
            homeChangedAt = messages
            if let switchedAt, messages - switchedAt <= Self.switchWindow {
                own = (branch, cwd)
                self.switchedAt = nil
                homeChangedAt = nil
            }
        }
        homeBranch = branch
    }

    private var worktreeBranches: [String: (branch: String, root: String)?] = [:]

    /// The branch checked out in the linked git worktree holding `directory`, read from its `.git`
    /// file and HEAD. Nil inside a main checkout (`.git` is a directory), on a detached HEAD, or once
    /// the worktree is gone.
    private mutating func worktreeBranch(containing directory: String) -> (branch: String, root: String)? {
        if let cached = worktreeBranches[directory] { return cached }
        let found = Self.readWorktreeBranch(containing: directory)
        worktreeBranches[directory] = found
        return found
    }

    static func readWorktreeBranch(containing directory: String) -> (branch: String, root: String)? {
        let files = FileManager.default
        var root = URL(fileURLWithPath: directory).standardizedFileURL
        while true {
            let dotGit = root.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if files.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                guard !isDirectory.boolValue,
                      let pointer = try? String(contentsOf: dotGit, encoding: .utf8),
                      let line = pointer.split(whereSeparator: \.isNewline).first,
                      line.hasPrefix("gitdir:") else { return nil }
                let gitDir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                let gitDirURL = gitDir.hasPrefix("/") ? URL(fileURLWithPath: gitDir) : root.appendingPathComponent(gitDir)
                guard let head = try? String(contentsOf: gitDirURL.appendingPathComponent("HEAD"), encoding: .utf8),
                      head.hasPrefix("ref: refs/heads/") else { return nil }
                let branch = head.dropFirst("ref: refs/heads/".count).trimmingCharacters(in: .whitespacesAndNewlines)
                return branch.isEmpty ? nil : (branch, root.path)
            }
            let parent = root.deletingLastPathComponent()
            if parent.path == root.path { return nil }
            root = parent
        }
    }

    /// Credits a branch seen checked out that the user's prompt names as a whole word.
    mutating func notePrompt(_ text: String) {
        let named = seen.filter { Self.names($0.key, in: text) }
        guard !named.isEmpty else { return }
        if let current = homeBranch, let directory = named[current] {
            mentioned = (current, directory)
        } else if let longest = named.max(by: { $0.key.count < $1.key.count }) {
            mentioned = (longest.key, longest.value)
        }
    }

    static func names(_ branch: String, in text: String) -> Bool {
        let nameCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._/-"))
        func isNameCharacter(_ index: String.Index) -> Bool {
            let c = text[index]
            return c.isASCII && c.unicodeScalars.allSatisfy { nameCharacters.contains($0) }
        }
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: branch, range: searchRange) {
            let startsWord = found.lowerBound == text.startIndex || !isNameCharacter(text.index(before: found.lowerBound))
            var end = found.upperBound
            // Sentence punctuation right after the name ("… on feat/x.") does not extend it.
            while end < text.endIndex, ".-/".contains(text[end]) { end = text.index(after: end) }
            if startsWord && (end == text.endIndex || !isNameCharacter(end)) { return true }
            searchRange = found.upperBound..<text.endIndex
        }
        return false
    }

    mutating func noteCommand(_ command: String) {
        if let created = Self.createdWorktreeBranch(command) {
            if let home { own = (created, home) }
            return
        }
        guard Self.switchesBranch(command) else { return }
        if let homeChangedAt, messages - homeChangedAt <= Self.switchWindow, let home, let homeBranch {
            own = (homeBranch, home)
            self.homeChangedAt = nil
        } else {
            switchedAt = messages
        }
    }

    /// The branch named by `-b`/`-B` in a `git worktree add` command.
    static func createdWorktreeBranch(_ command: String) -> String? {
        for args in gitInvocations(command) where args.starts(with: ["worktree", "add"]) {
            guard let flag = args.firstIndex(where: { $0 == "-b" || $0 == "-B" }), flag + 1 < args.count else { continue }
            let name = args[flag + 1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !name.isEmpty { return name }
        }
        return nil
    }

    static func switchesBranch(_ command: String) -> Bool {
        gitInvocations(command).contains { $0.first == "checkout" || $0.first == "switch" }
    }

    /// Arguments after `git` (and its global options) for each simple command that starts with
    /// `git`. Text that only mentions git, e.g. in a heredoc, a quoted string or a grep pattern,
    /// is not a git invocation.
    static func gitInvocations(_ command: String) -> [[String]] {
        let script = command.components(separatedBy: "<<").first ?? command
        var invocations: [[String]] = []
        for line in script.split(whereSeparator: \.isNewline) {
            var segment: [String] = []
            func flush() {
                if segment.first == "git" {
                    var index = 1
                    while index < segment.count, segment[index].hasPrefix("-") {
                        index += segment[index] == "-C" || segment[index] == "-c" ? 2 : 1
                    }
                    if index < segment.count { invocations.append(Array(segment[index...])) }
                }
                segment = []
            }
            for token in line.split(whereSeparator: \.isWhitespace).map(String.init) {
                if ["&&", "||", ";", "|"].contains(token) {
                    flush()
                } else if token.hasSuffix(";") {
                    segment.append(String(token.dropLast()))
                    flush()
                } else {
                    segment.append(token)
                }
            }
            flush()
        }
        return invocations
    }
}
