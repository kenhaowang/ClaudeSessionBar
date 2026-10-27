import AppKit

/// The terminal apps that sessions run in and new tabs open in. Both are driven through AppleScript.
enum TerminalApp: String, CaseIterable {
    case iterm, ghostty

    var bundleId: String { self == .iterm ? "com.googlecode.iterm2" : "com.mitchellh.ghostty" }
    var name: String { self == .iterm ? "iTerm2" : "Ghostty" }

    var runningApp: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleId }
    }

    var isRunning: Bool { runningApp != nil }
    var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil }

    init?(bundleId: String?) {
        guard let match = Self.allCases.first(where: { $0.bundleId == bundleId }) else { return nil }
        self = match
    }
}

/// Routes tab operations to iTerm2 or Ghostty. Sessions are looked up by tty in every running
/// terminal; new tabs go to the terminal the user was in last.
enum Terminals {
    private static let lastUsedKey = "lastTerminal"

    static func noteActivated(_ app: NSRunningApplication?) {
        guard let terminal = TerminalApp(bundleId: app?.bundleIdentifier) else { return }
        UserDefaults.standard.set(terminal.rawValue, forKey: lastUsedKey)
    }

    private static let choiceKey = "terminal"

    private static var lastUsed: TerminalApp? {
        TerminalApp(rawValue: UserDefaults.standard.string(forKey: lastUsedKey) ?? "")
    }

    /// Picked in the settings menu; nil means automatic.
    static var choice: TerminalApp? {
        get { TerminalApp(rawValue: UserDefaults.standard.string(forKey: choiceKey) ?? "") }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: choiceKey) }
    }

    /// The chosen terminal if installed; otherwise the last used, else whichever is running, else
    /// whichever is installed (iTerm2 first).
    static var preferred: TerminalApp {
        if let choice, choice.isInstalled { return choice }
        return automatic
    }

    static var automatic: TerminalApp {
        let order = [lastUsed].compactMap { $0 } + TerminalApp.allCases
        return order.first { $0.isRunning } ?? order.first { $0.isInstalled } ?? .iterm
    }

    /// --check-terminals: compiles (never runs) every script against the installed terminals.
    static func check() -> Bool {
        print("preferred: \(preferred.name)")
        var ok = true
        for terminal in TerminalApp.allCases {
            guard terminal.isInstalled else {
                print("\(terminal.name): not installed")
                continue
            }
            let scripts = terminal == .ghostty ? Ghostty.allScripts : ITerm.allScripts
            if terminal == .ghostty { print("Ghostty tty support: \(Ghostty.supportsTTY)") }
            for (label, source) in scripts {
                var error: NSDictionary?
                let compiled = NSAppleScript(source: source)?.compileAndReturnError(&error) ?? false
                print((compiled ? "PASS " : "FAIL ") + "\(terminal.name) \(label)" + (error.map { " \($0)" } ?? ""))
                ok = ok && compiled
            }
        }
        let saved = choice
        defer { choice = saved }
        for terminal in TerminalApp.allCases {
            choice = terminal
            let expected = terminal.isInstalled ? terminal : automatic
            let pass = preferred == expected
            print((pass ? "PASS " : "FAIL ") + "choice \(terminal.name) -> \(preferred.name)")
            ok = ok && pass
        }
        choice = nil
        let autoPass = preferred == automatic
        print((autoPass ? "PASS " : "FAIL ") + "choice automatic -> \(preferred.name)")
        ok = ok && autoPass
        print(ok ? "ALL PASS" : "FAILED")
        return ok
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// One command opens a tab in the front window; several open a new window with a tab each.
    static func openTabs(running commands: [String], completion: @escaping (Bool, TerminalApp) -> Void = { _, _ in }) {
        guard !commands.isEmpty else { return }
        let terminal = preferred
        activate(terminal) {
            let ok = terminal == .ghostty ? Ghostty.openTabs(commands) : ITerm.openTabs(commands)
            Log.jump.notice("openTabs \(terminal.name, privacy: .public) \(commands.count) -> \(ok)")
            completion(ok, terminal)
        }
    }

    /// Finds the session by tty (Ghostty versions without a `tty` property fall back to a terminal
    /// that is alone in the session's directory) and brings its tab to the front.
    static func focus(tty: String, cwd: String, completion: @escaping (Bool) -> Void) {
        let running = ([preferred] + TerminalApp.allCases).filter(\.isRunning)
        if running.contains(.iterm), ITerm.contains(tty: tty) {
            activate(.iterm) { completion(ITerm.select(tty: tty)) }
        } else if running.contains(.ghostty), let id = Ghostty.terminalId(tty: tty, cwd: cwd) {
            activate(.ghostty) { completion(Ghostty.focus(id: id)) }
        } else {
            completion(false)
        }
    }

    /// tty of the tab the user was just working in (read before this app takes focus).
    static func frontSessionTTY() -> String? {
        let front = TerminalApp(bundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) ?? lastUsed
        guard let front, front.isRunning else { return nil }
        return front == .ghostty ? Ghostty.frontTTY() : ITerm.frontTTY()
    }

    static func setName(tty: String, name: String) {
        if TerminalApp.iterm.isRunning, ITerm.setName(tty: tty, name: name) { return }
        if TerminalApp.ghostty.isRunning { Ghostty.setName(tty: tty, name: name) }
    }

    static func closeSession(tty: String) {
        if TerminalApp.iterm.isRunning, ITerm.close(tty: tty) { return }
        if TerminalApp.ghostty.isRunning { Ghostty.close(tty: tty) }
    }

    /// macOS only follows a window into its own Space (e.g. a full-screen window) when the app that
    /// orders it front is already active. Selecting first and activating afterwards leaves the user
    /// on the current Space looking at some other window, so activate, wait, then select.
    private static func activate(_ terminal: TerminalApp, then body: @escaping () -> Void) {
        guard let app = terminal.runningApp else {
            body()
            return
        }
        // Activation is cooperative since macOS 14: we must yield before the terminal may take focus.
        NSApp.yieldActivation(to: app)
        app.activate()
        waitUntilFrontmost(app, deadline: Date().addingTimeInterval(1), then: body)
    }

    private static func waitUntilFrontmost(
        _ app: NSRunningApplication, deadline: Date, then body: @escaping () -> Void
    ) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier || Date() >= deadline {
            // Give the activation a moment to settle before ordering a window front.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: body)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            waitUntilFrontmost(app, deadline: deadline, then: body)
        }
    }
}

enum AppleScript {
    static func quote(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    @discardableResult
    static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            Log.jump.error("AppleScript error: \(error.description, privacy: .public)")
            return nil
        }
        return result?.stringValue
    }
}

/// iTerm2, matching sessions by their tty (e.g. /dev/ttys040).
enum ITerm {
    static func contains(tty: String) -> Bool { AppleScript.run(inSession(tty: tty, "")) == "ok" }

    static func select(tty: String) -> Bool {
        let result = AppleScript.run(inSession(tty: tty, "select w\nselect t\nselect s"))
        Log.jump.notice("iTerm focus \(tty, privacy: .public) -> \(result ?? "error", privacy: .public)")
        return result == "ok"
    }

    static func frontTTY() -> String? { AppleScript.run(frontTTYScript) }

    private static let frontTTYScript =
        #"tell application id "com.googlecode.iterm2" to return tty of current session of current window"#

    @discardableResult
    static func setName(tty: String, name: String) -> Bool {
        AppleScript.run(inSession(tty: tty, "set name of s to \(AppleScript.quote(name))")) == "ok"
    }

    @discardableResult
    static func close(tty: String) -> Bool { AppleScript.run(inSession(tty: tty, "close s")) == "ok" }

    /// Types each command into a new tab's login shell, so the user's own PATH and shell setup apply.
    static func openTabs(_ commands: [String]) -> Bool {
        AppleScript.run(openTabsScript(commands)) == "ok"
    }

    private static func openTabsScript(_ commands: [String]) -> String {
        var lines = ["tell application id \"com.googlecode.iterm2\"", "activate"]
        if commands.count == 1 {
            lines += [
                "if (count of windows) is 0 then",
                "create window with default profile",
                "else",
                "tell current window to create tab with default profile",
                "end if",
                "tell current session of current window to write text \(AppleScript.quote(commands[0]))",
            ]
        } else {
            lines += [
                "set w to (create window with default profile)",
                "tell current session of w to write text \(AppleScript.quote(commands[0]))",
            ]
            for command in commands.dropFirst() {
                lines.append("tell w to set t to (create tab with default profile)")
                lines.append("tell current session of t to write text \(AppleScript.quote(command))")
            }
        }
        lines += ["end tell", "return \"ok\""]
        return lines.joined(separator: "\n")
    }

    /// Every script this app sends, for compiling against the installed iTerm2 (--check-terminals).
    static var allScripts: [(String, String)] {
        [
            ("lookup", inSession(tty: "/dev/null", "")), ("focus", inSession(tty: "/dev/null", "select w\nselect t\nselect s")),
            ("rename", inSession(tty: "/dev/null", "set name of s to \"x\"")), ("close", inSession(tty: "/dev/null", "close s")),
            ("front tty", frontTTYScript), ("open 1 tab", openTabsScript(["true"])),
            ("open 2 tabs", openTabsScript(["true", "true"])),
        ]
    }

    private static func inSession(tty: String, _ body: String) -> String {
        """
        tell application id "com.googlecode.iterm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is \(AppleScript.quote(tty)) then
                            \(body)
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "notfound"
        """
    }
}

/// Ghostty 1.3+ (its AppleScript dictionary). Terminals only expose `tty` in builds after 1.3.1.
enum Ghostty {
    private static let tell = "tell application id \"com.mitchellh.ghostty\""

    /// Read from the app's scripting definition, since asking for a missing property is an error.
    static var supportsTTY: Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: TerminalApp.ghostty.bundleId),
            let sdef = try? String(contentsOf: url.appendingPathComponent("Contents/Resources/Ghostty.sdef"), encoding: .utf8)
        else { return false }
        return sdef.contains("code=\"Gtty\"")
    }

    static func terminalId(tty: String, cwd: String) -> String? {
        if supportsTTY { return terminalId(tty: tty) }
        let dir = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        let id = AppleScript.run(cwdLookupScript(dir: dir))
        return id?.nilIfEmpty
    }

    private static func terminalId(tty: String) -> String? {
        AppleScript.run(ttyLookupScript(tty: tty))?.nilIfEmpty
    }

    private static func cwdLookupScript(dir: String) -> String {
        """
        \(tell)
            set found to {}
            repeat with t in terminals
                set d to working directory of t
                if d is \(AppleScript.quote(dir)) or d is \(AppleScript.quote(dir + "/")) then set end of found to id of t
            end repeat
        end tell
        if (count of found) is 1 then return item 1 of found
        return ""
        """
    }

    private static func ttyLookupScript(tty: String) -> String {
        """
        \(tell)
            repeat with t in terminals
                if tty of t is \(AppleScript.quote(tty)) then return id of t
            end repeat
        end tell
        return ""
        """
    }

    private static let frontTTYScript = "\(tell) to return tty of focused terminal of selected tab of front window"

    /// Every script this app sends, for compiling against the installed Ghostty (--check-terminals).
    static var allScripts: [(String, String)] {
        var scripts = [
            ("cwd lookup", cwdLookupScript(dir: "/tmp")), ("focus", onTerminal(id: "x", "focus t")),
            ("open 1 tab", openTabsScript(["true"])), ("open 2 tabs", openTabsScript(["true", "true"])),
        ]
        if supportsTTY {
            scripts += [
                ("tty lookup", ttyLookupScript(tty: "/dev/null")), ("front tty", frontTTYScript),
                ("rename", onTerminal(id: "x", "perform action \"set_tab_title:x\" on t")),
                ("close", onTerminal(id: "x", "close t")),
            ]
        }
        return scripts
    }

    static func focus(id: String) -> Bool {
        let result = AppleScript.run(onTerminal(id: id, "focus t"))
        Log.jump.notice("Ghostty focus \(id, privacy: .public) -> \(result ?? "error", privacy: .public)")
        return result == "ok"
    }

    static func frontTTY() -> String? {
        guard supportsTTY else { return nil }
        return AppleScript.run(frontTTYScript)
    }

    static func setName(tty: String, name: String) {
        guard supportsTTY, let id = terminalId(tty: tty) else { return }
        AppleScript.run(onTerminal(id: id, "perform action \(AppleScript.quote("set_tab_title:" + name)) on t"))
    }

    static func close(tty: String) {
        guard supportsTTY, let id = terminalId(tty: tty) else { return }
        AppleScript.run(onTerminal(id: id, "close t"))
    }

    /// `initial input` is typed into the new tab's login shell, so the user's PATH and shell setup apply.
    static func openTabs(_ commands: [String]) -> Bool {
        AppleScript.run(openTabsScript(commands)) == "ok"
    }

    private static func openTabsScript(_ commands: [String]) -> String {
        var lines = [tell, "activate"]
        for (index, command) in commands.enumerated() {
            lines.append("set cfg\(index) to new surface configuration")
            lines.append("set initial input of cfg\(index) to \(AppleScript.quote(command + "\n"))")
        }
        if commands.count == 1 {
            lines += [
                "if (count of windows) is 0 then",
                "new window with configuration cfg0",
                "else",
                "new tab in front window with configuration cfg0",
                "end if",
            ]
        } else {
            lines.append("set w to new window with configuration cfg0")
            for index in commands.indices.dropFirst() {
                lines.append("new tab in w with configuration cfg\(index)")
            }
        }
        lines += ["end tell", "return \"ok\""]
        return lines.joined(separator: "\n")
    }

    private static func onTerminal(id: String, _ body: String) -> String {
        """
        \(tell)
            repeat with t in terminals
                if id of t is \(AppleScript.quote(id)) then
                    \(body)
                    return "ok"
                end if
            end repeat
        end tell
        return "notfound"
        """
    }
}
