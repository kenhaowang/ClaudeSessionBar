import AppKit

/// iTerm2 control through AppleScript, matching sessions by their tty (e.g. /dev/ttys040).
enum ITerm {
    private static var runningApp: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.googlecode.iterm2" }
    }

    static var isRunning: Bool { runningApp != nil }

    /// macOS only follows a window into its own Space (e.g. a full-screen window) when the app that
    /// orders it front is already active. Selecting first and activating afterwards leaves the user
    /// on the current Space looking at some other iTerm window, so activate, wait, then select.
    static func focus(tty: String, completion: @escaping (Bool) -> Void) {
        activateThen {
            let result = run(inSession(tty: tty, "select w\nselect t\nselect s"))
            Log.jump.notice(
                "focus \(tty, privacy: .public) -> \(result ?? "error", privacy: .public); front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?", privacy: .public)"
            )
            completion(result == "ok")
        }
    }

    /// Activation is cooperative since macOS 14: we must yield before iTerm may take focus.
    private static func activateThen(_ body: @escaping () -> Void) {
        guard let iterm = runningApp else {
            body()
            return
        }
        NSApp.yieldActivation(to: iterm)
        iterm.activate()
        waitUntilFrontmost(iterm, deadline: Date().addingTimeInterval(1), then: body)
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

    /// tty of the session iTerm currently shows in its front window.
    static func frontSessionTTY() -> String? {
        guard isRunning else { return nil }
        return run(#"tell application "iTerm2" to return tty of current session of current window"#)
    }

    static func setName(tty: String, name: String) {
        guard isRunning else { return }
        run(inSession(tty: tty, "set name of s to \(quote(name))"))
    }

    static func closeSession(tty: String) {
        guard isRunning else { return }
        run(inSession(tty: tty, "close s"))
    }

    static func openAttach(jobId: String) {
        activateThen { openTab(running: "claude attach " + shellQuote(jobId)) }
    }

    static func openNewSession(command: String) {
        activateThen { openTab(running: command) }
    }

    /// Opens a tab in iTerm's current window (or a new window when none is open) and types
    /// `command` into its login shell, so the user's own PATH and shell setup apply.
    private static func openTab(running command: String) {
        let result = run(
            """
            tell application "iTerm2"
                activate
                if (count of windows) is 0 then
                    create window with default profile
                else
                    tell current window to create tab with default profile
                end if
                tell current session of current window
                    write text \(quote(command))
                    return tty
                end tell
            end tell
            """)
        Log.jump.notice("openTab \(command, privacy: .public) -> \(result ?? "error", privacy: .public)")
    }

    /// One command opens a tab in the current window; several open a new window with a tab each.
    static func openTabs(running commands: [String]) {
        guard commands.count > 1 else {
            if let command = commands.first { activateThen { openTab(running: command) } }
            return
        }
        var lines = [
            "tell application \"iTerm2\"",
            "activate",
            "set w to (create window with default profile)",
            "tell current session of w to write text \(quote(commands[0]))",
        ]
        for command in commands.dropFirst() {
            lines.append("tell w to set t to (create tab with default profile)")
            lines.append("tell current session of t to write text \(quote(command))")
        }
        lines.append("end tell")
        activateThen {
            let result = run(lines.joined(separator: "\n"))
            Log.jump.notice("openTabs \(commands.count) -> \(result ?? "error", privacy: .public)")
        }
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func inSession(tty: String, _ body: String) -> String {
        """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is \(quote(tty)) then
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

    private static func quote(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    @discardableResult
    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            Log.jump.error("AppleScript error: \(error.description, privacy: .public)")
            return nil
        }
        return result?.stringValue
    }
}
