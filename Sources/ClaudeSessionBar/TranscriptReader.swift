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
            if let branch = obj["gitBranch"] as? String, !branch.isEmpty, branch != "HEAD" {
                info.gitBranch = branch
            }
            if let cwd = obj["cwd"] as? String { info.cwd = cwd }
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
            } else {
                info.pushTail("[assistant] " + text)
            }
        default:
            break
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
