import Foundation

/// A pull request mentioned in a session (by its full GitHub URL).
struct PRRef: Hashable {
    let owner: String
    let repo: String
    let number: Int

    var url: String { "https://github.com/\(owner)/\(repo)/pull/\(number)" }
    var repoKey: String { "\(owner)/\(repo)".lowercased() }

    private static let pattern = try! NSRegularExpression(
        pattern: #"https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/(\d+)"#)

    static func find(in text: String) -> [PRRef] {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            guard let owner = Range(match.range(at: 1), in: text), let repo = Range(match.range(at: 2), in: text),
                let number = Range(match.range(at: 3), in: text), let value = Int(text[number])
            else { return nil }
            return PRRef(owner: String(text[owner]), repo: String(text[repo]), number: value)
        }
    }

    /// "owner/repo" of a git remote URL (https or ssh form), lowercased.
    static func repoKey(ofRemote remote: String) -> String? {
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "github.com") else { return nil }
        var rest = trimmed[range.upperBound...].drop { $0 == ":" || $0 == "/" }
        if rest.hasSuffix(".git") { rest = rest.dropLast(4) }
        let parts = rest.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1])".lowercased()
    }
}

enum CIState: Equatable {
    case success, failure, pending, none
}

struct PRStatus: Equatable {
    let number: Int
    let title: String
    /// OPEN, MERGED or CLOSED.
    let state: String
    let isDraft: Bool
    /// APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED or "".
    let reviewDecision: String
    let ci: CIState
    let failedChecks: [String]
    let fetchedAt: Date

    var isOpen: Bool { state == "OPEN" }

    /// Open PRs change often (CI especially); merged or closed ones hardly ever.
    var refreshInterval: TimeInterval {
        guard isOpen else { return 1800 }
        return ci == .pending ? 60 : 120
    }

    static func parse(_ json: Data, fetchedAt: Date = Date()) -> PRStatus? {
        guard let obj = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
            let number = obj["number"] as? Int
        else { return nil }
        var failed: [String] = []
        var pending = 0
        var total = 0
        for check in obj["statusCheckRollup"] as? [[String: Any]] ?? [] {
            total += 1
            let name = (check["name"] as? String) ?? (check["context"] as? String) ?? "?"
            if check["__typename"] as? String == "CheckRun" {
                let conclusion = check["conclusion"] as? String ?? ""
                if check["status"] as? String != "COMPLETED" {
                    pending += 1
                } else if ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"].contains(conclusion) {
                    failed.append(name)
                }
            } else {
                switch check["state"] as? String ?? "" {
                case "PENDING", "EXPECTED": pending += 1
                case "FAILURE", "ERROR": failed.append(name)
                default: break
                }
            }
        }
        let ci: CIState = !failed.isEmpty ? .failure : pending > 0 ? .pending : total > 0 ? .success : .none
        return PRStatus(
            number: number,
            title: obj["title"] as? String ?? "",
            state: obj["state"] as? String ?? "",
            isDraft: obj["isDraft"] as? Bool ?? false,
            reviewDecision: obj["reviewDecision"] as? String ?? "",
            ci: ci,
            failedChecks: failed,
            fetchedAt: fetchedAt)
    }
}

enum GitHub {
    static let ghPath: String? = {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "\(Paths.home.path)/.local/bin/gh"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return found }
        guard let out = Shell.run("/bin/zsh", ["-lc", "command -v gh"], timeout: 5), out.status == 0 else { return nil }
        let resolved = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return resolved.isEmpty ? nil : resolved
    }()

    static func fetch(_ pr: PRRef) -> PRStatus? {
        guard let gh = ghPath,
            let out = Shell.run(
                gh,
                ["pr", "view", pr.url, "--json", "number,title,state,isDraft,reviewDecision,statusCheckRollup"],
                env: ClaudeCLI.environment, timeout: 30),
            out.status == 0
        else { return nil }
        return PRStatus.parse(Data(out.stdout.utf8))
    }

    /// "owner/repo" of the origin remote of the repository containing `directory`.
    static func repoKey(of directory: String) -> String? {
        guard let out = Shell.run("/usr/bin/git", ["-C", directory, "remote", "get-url", "origin"]), out.status == 0
        else { return nil }
        return PRRef.repoKey(ofRemote: out.stdout)
    }
}
