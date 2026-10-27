import AppKit
import Combine
import SwiftUI

@main
enum Entry {
    static func main() {
        // Writing a prompt to a summarizer that already exited must not kill the app.
        signal(SIGPIPE, SIG_IGN)
        let args = CommandLine.arguments
        if args.contains("--check-icon") {
            let cases: [(Int, StatusIcon)] = [
                (0, .clear), (1, .clear), (2, .few), (5, .few), (6, .cake), (7, .many), (10, .many),
                (11, .overloaded), (18, .overloaded), (19, .cake), (20, .overloaded), (40, .overloaded),
            ]
            var ok = true
            for (count, expected) in cases {
                let icon = StatusIcon(waiting: count)
                let drawable = icon.image.size.width > 0 && icon.image.size.height > 0
                print((icon == expected && drawable ? "PASS " : "FAIL ") + "\(count) waiting -> \(icon) \(icon.image.size)")
                ok = ok && icon == expected && drawable
            }
            print(ok ? "ALL PASS" : "FAILED")
            exit(ok ? 0 : 1)
        }
        if let index = args.firstIndex(of: "--icon-sheet"), index + 1 < args.count {
            exit(SelfTest.writeIconSheet(to: args[index + 1]) ? 0 : 1)
        }
        if let index = args.firstIndex(of: "--make-icon"), index + 1 < args.count {
            let path = args[index + 1]
            let ok = path.hasSuffix(".png") ? AppIconRenderer.writePreview(to: path) : AppIconRenderer.writeIcns(to: path)
            exit(ok ? 0 : 1)
        }
        if args.contains("--check-worktree") { exit(SelfTest.checkWorktree() ? 0 : 1) }
        if args.contains("--check-pr") { exit(SelfTest.checkPR() ? 0 : 1) }
        if args.contains("--check-restore") { exit(SelfTest.checkRestore() ? 0 : 1) }
        if args.contains("--dump") || args.contains("--snapshot") || args.contains("--check-groups")
            || args.contains("--worktree-plan")
        {
            CLI.run(args)
            return
        }
        if let index = args.firstIndex(of: "--selftest"), index + 1 < args.count {
            SelfTest.outputDir = URL(fileURLWithPath: args[index + 1])
            SelfTest.clickFirstRow = args.contains("--click")
            SelfTest.dryRunJump = SelfTest.clickFirstRow
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // NSApplication.delegate is weak; keep ours alive for the whole run loop.
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// A plain NSStatusItem + NSPopover instead of SwiftUI's MenuBarExtra: the popover can be opened
/// programmatically (needed by --selftest) and its size follows the SwiftUI content exactly.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var icon: StatusIcon?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // CSB_APPEARANCE=light|dark renders README screenshots in either mode.
        switch ProcessInfo.processInfo.environment["CSB_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        let store = Store.shared
        if SelfTest.outputDir != nil {
            store.autoSummarize = false
        } else {
            store.trackOpenSessions = true
        }
        store.start()
        // Logout, restart and shutdown (including forced macOS updates) announce themselves here,
        // before iTerm quits and takes the sessions down one by one.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { _ in Store.shared.freezeOpenSessions() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        statusItem.button?.imagePosition = .imageLeading

        let host = NSHostingController(rootView: PopoverView(store: store))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        // Vibrant dark text cannot be captured by cacheDisplay; self-test renders in light mode.
        if SelfTest.outputDir != nil { popover.appearance = NSAppearance(named: .aqua) }
        // Keep the popover open during a self-test even if the user clicks elsewhere meanwhile.
        if SelfTest.outputDir != nil { popover.behavior = .applicationDefined }

        store.closePopover = { [weak self] in self?.popover.performClose(nil) }
        store.$rows
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusButton() }
            .store(in: &cancellables)
        updateStatusButton()

        SelfTest.scheduleIfRequested { [weak self] in self?.showPopover() }
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--screenshot"), index + 1 < args.count { captureScreen(to: args[index + 1]) }
    }

    /// --screenshot <png>: opens the popover and captures it together with the status item as shown
    /// on screen, then quits. Without Screen Recording permission (for the terminal that launched
    /// it) the app draws its own windows onto a plain menu bar strip instead.
    private func captureScreen(to path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            let backdrop = Screenshot.wallpaperBackdrop(for: self.statusItem.button?.window?.screen)
            showPopover()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                defer {
                    backdrop?.close()
                    NSApp.terminate(nil)
                }
                func screenFrame(_ view: NSView) -> NSRect? {
                    view.window?.convertToScreen(view.convert(view.bounds, to: nil))
                }
                guard let button = self.statusItem.button, let itemFrame = screenFrame(button),
                    let content = self.popover.contentViewController?.view, let contentFrame = screenFrame(content),
                    let main = NSScreen.screens.first
                else { return }
                var area = itemFrame.union(contentFrame).insetBy(dx: -16, dy: -24)
                area.size.height = itemFrame.maxY - area.minY
                // screencapture counts y downwards from the top of the main display.
                let rect = [area.minX, main.frame.maxY - area.maxY, area.width, area.height].map { String(Int($0)) }
                try? FileManager.default.removeItem(atPath: path)
                _ = Shell.run("/usr/sbin/screencapture", ["-x", "-R", rect.joined(separator: ","), path])
                if FileManager.default.fileExists(atPath: path) {
                    print("screenshot: \(path)")
                    return
                }
                let ok = Screenshot.write(
                    to: path, button: button, buttonFrame: itemFrame, content: content, contentFrame: contentFrame)
                print(ok ? "screenshot (rendered): \(path)" : "screenshot: failed")
            }
        }
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        let count = Store.shared.needsYouCount
        // CSB_FORCE_WAITING lets a self-test show any icon without real waiting sessions.
        let forced = ProcessInfo.processInfo.environment["CSB_FORCE_WAITING"].flatMap(Int.init)
        let newIcon = StatusIcon(waiting: forced ?? count)
        if newIcon != icon {
            icon = newIcon
            button.image = newIcon.image
        }
        button.title = count > 0 ? " \(count)" : ""
        button.toolTip = count > 0 ? waitingText(count) : "Claude Sessions"
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button else {
            if SelfTest.outputDir != nil { print("selftest: status item has no button") }
            return
        }
        Store.shared.refresh()
        // Ask before activating: iTerm's current window is the one the user just left.
        Store.shared.activeTTY = Demo.enabled ? Demo.activeTTY : ITerm.frontSessionTTY()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}

/// Headless modes for checking the data layer without the menu bar:
///   --dump [--summarize]              print the session table
///   --snapshot <png> [--dark]         render the popover content offscreen
enum CLI {
    static func run(_ args: [String]) {
        let store = Store.shared
        store.autoSummarize = false
        store.autoFetchPRs = false
        store.loadPersisted()
        store.refreshSync()
        if args.contains("--prs") { store.fetchPRsSync() }
        if args.contains("--summarize") {
            store.summarizeAllSync()
            store.refreshSync()
        }
        if args.contains("--check-groups") { exit(SelfTest.checkGroups(store) ? 0 : 1) }
        if args.contains("--dump") { dump(store) }
        if args.contains("--worktree-plan") { SelfTest.printWorktreePlan(store) }
        if let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count {
            snapshot(store, to: args[index + 1], dark: args.contains("--dark"))
        }
    }

    private static func dump(_ store: Store) {
        for section in store.sections {
            if !store.groups.isEmpty { print("[\(section.name)] \(section.rows.count)") }
            for row in section.rows {
                let fields = [
                    row.state.label + (row.summaryUpdating ? "*" : ""),
                    RelativeTime.text(row.lastSpokeAt),
                    row.displayName,
                    row.branch ?? "-",
                    row.tty ?? "-",
                    row.waitingFor ?? row.summary ?? "",
                    row.pr.map { pr in
                        guard let s = row.prStatus else { return "#\(pr.number) (not fetched)" }
                        let ci = "\(s.ci)" + (s.failedChecks.isEmpty ? "" : " \(s.failedChecks)")
                        return "#\(pr.number) \(s.state)\(s.isDraft ? " draft" : "") review=\(s.reviewDecision.isEmpty ? "-" : s.reviewDecision) ci=\(ci)"
                    } ?? "",
                ]
                print(fields.joined(separator: " | "))
            }
        }
    }

    private static func snapshot(_ store: Store, to path: String, dark: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let host = NSHostingView(rootView: PopoverView(store: store).background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.appearance = host.appearance
        window.contentView = host
        // Let the measured list height propagate before sizing the final image.
        for _ in 0..<3 {
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("snapshot: \(path) (\(Int(host.bounds.width))x\(Int(host.bounds.height)))")
    }
}
