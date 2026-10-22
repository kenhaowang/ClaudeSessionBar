import Foundation

/// Collects everything known about live sessions. Runs on a single background queue.
final class Scanner {
    private let reader = TranscriptReader()
    private var transcriptCache: [String: URL] = [:]
    private var repoKeys: [String: String?] = [:]

    private struct ProcInfo {
        let tty: String?
        let command: String
    }

    func scan() -> [RawSession] {
        let procs = processTable()
        let agents = loadAgents(procs: procs)
        let hooks = loadHookStates()

        var attachTTY: [String: String] = [:]
        for proc in procs.values {
            guard let tty = proc.tty, let range = proc.command.range(of: "claude attach ") else { continue }
            if let id = proc.command[range.upperBound...].split(separator: " ").first {
                attachTTY[String(id)] = tty
            }
        }

        reader.retain(only: Set(agents.map(\.sessionId)))
        return agents.map { agent in
            let hook = hooks[agent.sessionId]
            let tty = agent.isBackground ? agent.id.flatMap { attachTTY[$0] } : procs[agent.pid]?.tty
            let transcript = transcriptURL(for: agent, hook: hook).map {
                reader.read(sessionId: agent.sessionId, url: $0)
            }
            if repoKeys[agent.cwd] == nil { repoKeys[agent.cwd] = .some(GitHub.repoKey(of: agent.cwd)) }
            return RawSession(
                agent: agent, tty: tty, hook: hook, transcript: transcript, repoKey: repoKeys[agent.cwd] ?? nil)
        }
    }

    static func isClaudeProcess(pid: Int) -> Bool {
        guard let out = Shell.run("/bin/ps", ["-o", "command=", "-p", String(pid)]) else { return false }
        return out.stdout.contains("claude")
    }

    private func processTable() -> [Int: ProcInfo] {
        guard let out = Shell.run("/bin/ps", ["-axo", "pid=,tty=,command="]) else { return [:] }
        var table: [Int: ProcInfo] = [:]
        for line in out.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int(parts[0]) else { continue }
            let tty = parts[1] == "??" ? nil : "/dev/" + parts[1]
            table[pid] = ProcInfo(tty: tty, command: String(parts[2]))
        }
        return table
    }

    private func loadAgents(procs: [Int: ProcInfo]) -> [AgentEntry] {
        if let claude = ClaudeCLI.path,
            let out = Shell.run(claude, ["agents", "--json"], env: ClaudeCLI.environment, timeout: 10),
            out.status == 0,
            let agents = try? JSONDecoder().decode([AgentEntry].self, from: Data(out.stdout.utf8))
        {
            return agents
        }
        let files =
            (try? FileManager.default.contentsOfDirectory(at: Paths.sessions, includingPropertiesForKeys: nil))
            ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let entry = JSONFile.read(RegistryEntry.self, from: file),
                procs[entry.pid]?.command.contains("claude") == true
            else { return nil }
            return AgentEntry(
                pid: entry.pid, id: entry.jobId, cwd: entry.cwd,
                kind: entry.kind == "bg" ? "background" : (entry.kind ?? "interactive"),
                sessionId: entry.sessionId, name: entry.name, status: entry.status, state: nil)
        }
    }

    private func loadHookStates() -> [String: HookState] {
        let files =
            (try? FileManager.default.contentsOfDirectory(at: Paths.hookState, includingPropertiesForKeys: nil))
            ?? []
        var states: [String: HookState] = [:]
        for file in files where file.pathExtension == "json" {
            if let state = JSONFile.read(HookState.self, from: file) { states[state.sessionId] = state }
        }
        return states
    }

    private func transcriptURL(for agent: AgentEntry, hook: HookState?) -> URL? {
        let fm = FileManager.default
        if let path = hook?.transcriptPath, fm.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        let direct = Paths.projects.appendingPathComponent(Paths.projectSlug(agent.cwd))
            .appendingPathComponent(agent.sessionId + ".jsonl")
        if fm.fileExists(atPath: direct.path) { return direct }
        if let cached = transcriptCache[agent.sessionId] { return cached }
        let dirs = (try? fm.contentsOfDirectory(at: Paths.projects, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let candidate = dir.appendingPathComponent(agent.sessionId + ".jsonl")
            if fm.fileExists(atPath: candidate.path) {
                transcriptCache[agent.sessionId] = candidate
                return candidate
            }
        }
        return nil
    }
}
