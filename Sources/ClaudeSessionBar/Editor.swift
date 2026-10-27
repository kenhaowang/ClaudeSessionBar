import AppKit

/// Editors a session's worktree can be opened in; only the installed ones are offered.
enum Editor: String, CaseIterable, Identifiable {
    case cursor, vscode, windsurf, zed, pycharm, pycharmCE, sublime

    var id: String { rawValue }

    var name: String {
        switch self {
        case .cursor: return "Cursor"
        case .vscode: return "VS Code"
        case .windsurf: return "Windsurf"
        case .zed: return "Zed"
        case .pycharm: return "PyCharm"
        case .pycharmCE: return "PyCharm CE"
        case .sublime: return "Sublime Text"
        }
    }

    var bundleId: String {
        switch self {
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .vscode: return "com.microsoft.VSCode"
        case .windsurf: return "com.exafunction.windsurf"
        case .zed: return "dev.zed.Zed"
        case .pycharm: return "com.jetbrains.pycharm"
        case .pycharmCE: return "com.jetbrains.pycharm.ce"
        case .sublime: return "com.sublimetext.4"
        }
    }

    var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil }

    static var installed: [Editor] { allCases.filter(\.isInstalled) }

    func open(_ path: String) -> Bool {
        // Cursor's own CLI opens the folder in a new window even when another one is already open.
        if self == .cursor {
            let cli = "\(Paths.home.path)/.local/bin/cursor"
            if FileManager.default.isExecutableFile(atPath: cli),
                Shell.run(cli, [path], env: ClaudeCLI.environment, timeout: 20)?.status == 0
            {
                return true
            }
        }
        return Shell.run("/usr/bin/open", ["-b", bundleId, path])?.status == 0
    }
}
