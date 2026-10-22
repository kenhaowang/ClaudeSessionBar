import AppKit

/// `--selftest <dir>`: launches the real menu bar app, opens its popover the same way a click does,
/// then records the frame of every visible window and renders it to PNG.
enum SelfTest {
    static var outputDir: URL?
    /// `--click`: send a synthetic mouse click to the first row and report which row's tap fired.
    static var clickFirstRow = false
    /// While set, Store.jump only records the row instead of driving iTerm (no Automation prompt).
    static var dryRunJump = false
    static var jumpedRow: String?
    /// CSB_FORCE_DROP="<tab raw>:before|after|onto" draws that chip's drop indicator, since a real
    /// drag cannot be scripted.
    /// CSB_HOLD_DRAG=1 keeps a forced drag "in progress"; without it the drag-end watcher sees no
    /// mouse button down and clears the indicator, which is how the stuck-bar fix is checked.
    static let holdDrag = ProcessInfo.processInfo.environment["CSB_HOLD_DRAG"] == "1"
    static let forcedDropIndicator: (tab: String, side: DropSide)? = {
        guard let value = ProcessInfo.processInfo.environment["CSB_FORCE_DROP"],
            let colon = value.lastIndex(of: ":")
        else { return nil }
        let sides: [String: DropSide] = ["before": .before, "after": .after, "onto": .onto]
        guard let side = sides[String(value[value.index(after: colon)...])] else { return nil }
        return (String(value[..<colon]), side)
    }()

    static func scheduleIfRequested(open: @escaping () -> Void) {
        guard let outputDir else { return }
        setvbuf(stdout, nil, _IONBF, 0)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 20)
            print("selftest: watchdog timeout")
            exit(2)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            print("selftest: opening popover")
            open()
            // Start a pretend drag once the chips exist, so the forced indicator really appears
            // and (without CSB_HOLD_DRAG) is then cleared by the mouse-up watcher.
            if forcedDropIndicator != nil { Store.shared.dragKind = .tab(.all) }
            // CSB_FORCE_WORKTREE_PROPOSAL=1 shows the "create a worktree?" box on the first row.
            if ProcessInfo.processInfo.environment["CSB_FORCE_WORKTREE_PROPOSAL"] == "1",
                let row = Store.shared.visibleRows.first, let branch = row.branch
            {
                Store.shared.worktreeProposal = WorktreeProposal(
                    sessionId: row.id, branch: branch, mainRoot: Store.shared.newSessionDirectory,
                    path: Worktree.suggestedPath(mainRoot: Store.shared.newSessionDirectory, branch: branch))
            }
            print("selftest: windows after open: \(NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible)" })")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                capture(into: outputDir)
                guard clickFirstRow else {
                    NSApp.terminate(nil)
                    return
                }
                clickRow(atTopOffset: 110)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let expected = Store.shared.visibleRows.first?.displayName ?? "?"
                    print("selftest: click expected=\(expected) tapped=\(jumpedRow ?? "none")")
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// `--check-groups`: exercises every group operation the menus call, including a reload from
    /// disk. Run it with CSB_DASHBOARD_DIR pointing at a scratch copy.
    static func checkGroups(_ store: Store) -> Bool {
        var failures = 0
        func expect(_ ok: Bool, _ label: String) {
            print((ok ? "PASS " : "FAIL ") + label)
            if !ok { failures += 1 }
        }
        let ids = store.rows.prefix(2).map(\.id)
        guard ids.count == 2 else {
            print("FAIL need at least two live sessions")
            return false
        }
        func section(_ name: String) -> GroupSection? { store.sections.first { $0.name == name } }

        store.createGroup(named: "   ")
        expect(store.groups.isEmpty, "blank name creates nothing")
        store.createGroup(named: "Alpha")
        store.createGroup(named: "Beta", assigning: ids[0])
        expect(store.groups.map(\.name) == ["Alpha", "Beta"], "groups created in order")
        expect(section("Beta")?.rows.map(\.id) == [ids[0]], "new group from a row takes that row")
        expect(section("未分組")?.rows.contains { $0.id == ids[0] } == false, "assigned row leaves 未分組")

        let alpha = store.groups[0].id
        let beta = store.groups[1].id
        store.assign(ids[1], to: alpha)
        expect(section("Alpha")?.rows.map(\.id) == [ids[1]], "assign moves row into group")
        store.assign(ids[1], to: beta)
        expect(section("Alpha")?.rows.isEmpty == true && section("Beta")?.rows.count == 2, "reassign moves, not copies")

        store.renameGroup(alpha, to: "  ")
        expect(store.groups[0].name == "Alpha", "blank rename is ignored")
        store.renameGroup(alpha, to: "Alpha 2")
        expect(store.groups[0].name == "Alpha 2", "rename")

        func order() -> [String] { store.tabOrder.map(\.raw) }
        expect(order() == ["all", "ungrouped", alpha, beta], "default tab order: 全部, 未分組, groups")
        store.moveTab(.group(beta), by: -1)
        expect(store.groups.map(\.id) == [beta, alpha], "menu 往左移 reorders groups")
        store.moveTab(.all, nextTo: .group(alpha), after: true)
        expect(order() == ["ungrouped", beta, alpha, "all"], "drop 全部 on the right half of a tab lands after it")
        store.moveTab(.ungrouped, nextTo: .group(alpha), after: true)
        expect(order() == [beta, alpha, "ungrouped", "all"], "drag 未分組 too")
        store.moveTab(.all, nextTo: .group(beta), after: false)
        expect(order() == ["all", beta, alpha, "ungrouped"], "left half lands before the target")
        store.moveTab(.all, nextTo: .group(beta), after: false)
        expect(order() == ["all", beta, alpha, "ungrouped"], "dropping into the gap it already sits in is a no-op")
        store.moveTab(.ungrouped, nextTo: .all, after: true)
        expect(order() == ["all", "ungrouped", beta, alpha], "right half while moving left lands after the target")
        store.moveTabToEnd(.group(beta))
        expect(order() == ["all", "ungrouped", alpha, beta], "drop on ＋ moves the tab to the end")
        store.moveTab(.all, by: -1)
        expect(order() == ["all", "ungrouped", alpha, beta], "moving the first tab left is a no-op")
        store.moveTab(.all, nextTo: .all, after: false)
        expect(order() == ["all", "ungrouped", alpha, beta], "dropping a tab on itself is a no-op")
        expect(GroupChip.tab(fromDragItem: "tab:ungrouped") == .ungrouped, "tab drag payload decodes")
        expect(GroupChip.tab(fromDragItem: ids[0]) == nil, "session drag payload is not mistaken for a tab")

        expect(store.filter == .all && store.visibleRows.count == store.rows.count, "default tab is 全部 with every row")
        store.select(.group(beta))
        expect(store.visibleRows.map(\.id).sorted() == ids.sorted(), "group tab shows only its rows")
        expect(store.counts(for: .group(beta)).total == 2, "group chip count")
        store.select(.ungrouped)
        expect(!store.visibleRows.contains { ids.contains($0.id) }, "未分組 tab hides grouped rows")
        expect(
            store.counts(for: .ungrouped).total + store.counts(for: .group(beta)).total
                + store.counts(for: .group(alpha)).total == store.rows.count,
            "tab counts add up to all rows")
        store.select(.group(beta))

        store.loadPersisted()
        store.refreshSync()
        expect(store.groups.map(\.name) == ["Alpha 2", "Beta"], "names and group order survive reload")
        expect(order() == ["all", "ungrouped", alpha, beta], "tab order survives reload")
        expect(section("Beta")?.rows.count == 2, "assignments survive reload")
        expect(store.filter == .group(beta), "selected tab survives reload")

        store.deleteGroup(beta)
        expect(store.groups.map(\.name) == ["Alpha 2"], "delete group")
        expect(store.filter == .all, "deleting the selected group falls back to 全部")
        expect(order() == ["all", "ungrouped", alpha], "deleted group leaves the tab order")
        expect(Set(section("未分組")?.rows.map(\.id) ?? []).isSuperset(of: ids), "deleted group's rows return to 未分組")
        store.loadPersisted()
        expect(!store.groupDataContainsAssignment(to: beta), "no dangling assignments on disk")

        // v0.2 wrote per-group `collapsed` and `ungroupedCollapsed`, and no `selected`.
        let legacy = """
            {"groups":[{"id":"g1","name":"Legacy","collapsed":true}],"assignments":{"\(ids[0])":"g1"},"ungroupedCollapsed":false}
            """
        try? Data(legacy.utf8).write(to: Paths.groups)
        store.loadPersisted()
        store.refreshSync()
        expect(store.groups.map(\.name) == ["Legacy"], "v0.2 groups.json still loads")
        expect(store.groupName(of: ids[0]) == "Legacy" && store.filter == .all, "v0.2 assignments kept, tab defaults to 全部")
        expect(order() == ["all", "ungrouped", "g1"], "files without tabOrder get the default order")

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        return failures == 0
    }

    /// `--worktree-plan`: read-only; what "在 Cursor 開啟" would do for each live session.
    static func printWorktreePlan(_ store: Store) {
        var cache: [String: [Worktree.Entry]] = [:]
        for row in store.sortedRows {
            guard let branch = row.branch else {
                print("\(row.displayName) | (no branch)")
                continue
            }
            let entries = cache[row.cwd] ?? Worktree.list(repoDirectory: row.cwd) ?? []
            cache[row.cwd] = entries
            if let existing = entries.first(where: { $0.branch == branch }) {
                print("\(row.displayName) | \(branch) | open \(existing.path)")
            } else if let main = entries.first {
                print("\(row.displayName) | \(branch) | ask to create \(Worktree.suggestedPath(mainRoot: main.path, branch: branch))")
            } else {
                print("\(row.displayName) | \(branch) | not a git repo: \(row.cwd)")
            }
        }
    }

    /// `--check-worktree`: exercises Worktree against a throwaway repo (with a fake remote) in the
    /// temp directory, then deletes it.
    static func checkWorktree() -> Bool {
        var failures = 0
        func expect(_ ok: Bool, _ label: String) {
            print((ok ? "PASS " : "FAIL ") + label)
            if !ok { failures += 1 }
        }
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("csb-worktree-check-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let remote = base.appendingPathComponent("remote.git").path
        let main = base.appendingPathComponent("main").path
        func git(_ args: [String], in dir: String) -> Bool {
            Shell.run("/usr/bin/git", ["-C", dir] + args, timeout: 30, captureStderr: true)?.status == 0
        }
        try? fm.createDirectory(atPath: base.path, withIntermediateDirectories: true)
        guard git(["init", "-q", "--bare", remote], in: base.path), git(["init", "-q", "-b", "develop", main], in: base.path),
            git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"], in: main),
            git(["remote", "add", "origin", remote], in: main), git(["push", "-q", "origin", "develop"], in: main),
            git(["branch", "feat/local-only"], in: main),
            git(["push", "-q", "origin", "develop:fix/remote-only"], in: main),
            git(["fetch", "-q", "origin"], in: main)
        else {
            print("FAIL could not set up the scratch repo")
            return false
        }

        let initial = Worktree.list(repoDirectory: main) ?? []
        expect(initial.count == 1 && initial.first?.branch == "develop", "lists the main worktree and its branch")
        let mainRoot = initial.first?.path ?? main
        expect(Worktree.list(repoDirectory: base.path) == nil, "a directory outside any repo is reported as nil")

        let localPath = Worktree.suggestedPath(mainRoot: mainRoot, branch: "feat/local-only")
        expect(localPath == mainRoot + "/.claude/worktrees/feat-local-only", "branch slashes become dashes in the folder name")
        expect(Worktree.add(mainRoot: mainRoot, path: localPath, branch: "feat/local-only") == nil, "creates a worktree for a local branch")
        expect(Worktree.list(repoDirectory: main)?.contains(Worktree.Entry(path: localPath, branch: "feat/local-only")) == true,
            "new worktree shows up with its branch")
        expect(Worktree.list(repoDirectory: localPath)?.first?.path == mainRoot, "listing from inside a worktree still puts main first")

        let remotePath = Worktree.suggestedPath(mainRoot: mainRoot, branch: "fix/remote-only")
        expect(Worktree.add(mainRoot: mainRoot, path: remotePath, branch: "fix/remote-only") == nil, "creates a worktree for a remote-only branch")
        expect(Worktree.list(repoDirectory: main)?.contains { $0.branch == "fix/remote-only" } == true, "remote-only branch is now checked out locally")

        let clash = Worktree.add(mainRoot: mainRoot, path: localPath, branch: "develop")
        expect(clash != nil, "reports an error instead of failing silently")
        print("      (git said: \(clash ?? "nothing"))")

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        return failures == 0
    }

    /// `--check-pr`: PR link extraction, remote parsing and CI aggregation on fixed inputs.
    static func checkPR() -> Bool {
        var failures = 0
        func expect(_ ok: Bool, _ label: String) {
            print((ok ? "PASS " : "FAIL ") + label)
            if !ok { failures += 1 }
        }
        let text = #"see https://github.com/octo-org/Hello-World/pull/1347 and https://github.com/example/repo/pull/42."#
        let refs = PRRef.find(in: text)
        expect(refs.map(\.number) == [1347, 42], "finds every PR URL in text")
        expect(refs.first?.repoKey == "octo-org/hello-world", "repo key is owner/repo, lowercased")
        expect(PRRef.repoKey(ofRemote: "https://github.com/octo-org/Hello-World.git\n") == "octo-org/hello-world", "https remote")
        expect(PRRef.repoKey(ofRemote: "git@github.com:octo-org/Hello-World.git") == "octo-org/hello-world", "ssh remote")
        expect(PRRef.repoKey(ofRemote: "https://gitlab.com/a/b.git") == nil, "non-GitHub remote")

        var info = TranscriptInfo()
        [17660, 42, 17675, 17660].forEach { info.notePR(PRRef(owner: "o", repo: "r", number: $0)) }
        expect(info.prMentions.map(\.number) == [42, 17675, 17660], "re-mentioning a PR makes it the latest")

        func status(_ rollup: String, state: String = "OPEN", review: String = "") -> PRStatus? {
            PRStatus.parse(Data(#"{"number":1,"title":"t","state":"\#(state)","isDraft":false,"reviewDecision":"\#(review)","statusCheckRollup":[\#(rollup)]}"#.utf8))
        }
        let ok = #"{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"}"#
        let skipped = #"{"__typename":"CheckRun","name":"docs","status":"COMPLETED","conclusion":"SKIPPED"}"#
        let running = #"{"__typename":"CheckRun","name":"test","status":"IN_PROGRESS","conclusion":""}"#
        let failed = #"{"__typename":"CheckRun","name":"unit","status":"COMPLETED","conclusion":"FAILURE"}"#
        let droneOK = #"{"__typename":"StatusContext","context":"continuous-integration/drone/pr","state":"SUCCESS"}"#
        let droneRunning = #"{"__typename":"StatusContext","context":"continuous-integration/drone/pr","state":"PENDING"}"#
        let droneFailed = #"{"__typename":"StatusContext","context":"continuous-integration/drone/pr","state":"FAILURE"}"#
        expect(status("\(ok),\(skipped),\(droneOK)")?.ci == .success, "all green (skipped counts as fine)")
        expect(status("\(ok),\(running)")?.ci == .pending, "a running check means pending")
        expect(status("\(ok),\(droneRunning)")?.ci == .pending, "a pending commit status means pending")
        expect(status("\(running),\(failed)")?.ci == .failure, "any failure wins over pending")
        expect(status("\(ok),\(droneFailed)")?.failedChecks == ["continuous-integration/drone/pr"], "failed commit status is named")
        expect(status("")?.ci == CIState.none, "no checks at all")
        let merged = status(ok, state: "MERGED", review: "APPROVED")
        expect(merged?.isOpen == false && merged?.refreshInterval == 1800, "merged PRs refresh rarely")
        expect(status(running)?.refreshInterval == 60 && status(ok)?.refreshInterval == 120, "open PRs refresh faster while CI runs")
        expect(PRStatus.parse(Data("not json".utf8)) == nil, "bad gh output is rejected")

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        return failures == 0
    }

    /// `--check-restore`: RestoreTracker scenarios. Run with CSB_DASHBOARD_DIR pointing at an empty
    /// scratch directory; it writes open-sessions.json and restore-pending.json there.
    static func checkRestore() -> Bool {
        var failures = 0
        func expect(_ ok: Bool, _ label: String) {
            print((ok ? "PASS " : "FAIL ") + label)
            if !ok { failures += 1 }
        }
        func session(_ id: String) -> RestorableSession {
            RestorableSession(sessionId: id, cwd: "/tmp/repo", name: "S-\(id)", branch: nil, lastSpokeAt: nil)
        }
        func reset() {
            try? FileManager.default.removeItem(at: Paths.openSessions)
            try? FileManager.default.removeItem(at: Paths.restorePending)
        }
        func ids(_ tracker: RestoreTracker) -> [String] { tracker.pending?.sessions.map(\.sessionId) ?? [] }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let a = session("A"), b = session("B"), c = session("C"), d = session("D")

        reset()
        let first = RestoreTracker(bootTime: t0.addingTimeInterval(-3600))
        first.observe([a, b], now: t0)
        expect(first.pending == nil, "first run with no snapshot offers nothing")
        let snapshot = JSONFile.read(OpenSessionsSnapshot.self, from: Paths.openSessions)
        expect(snapshot?.sessions.map(\.sessionId) == ["A", "B"], "open sessions are written to open-sessions.json")

        let afterReboot = RestoreTracker(bootTime: t0.addingTimeInterval(600))
        afterReboot.observe([], now: t0.addingTimeInterval(700))
        expect(ids(afterReboot) == ["A", "B"] && afterReboot.pending?.reason == .reboot, "after a restart every lost session is offered")
        expect(RestoreTracker(bootTime: t0).pending?.sessions.count == 2, "the offer survives the app restarting again")
        afterReboot.observe([a], now: t0.addingTimeInterval(800))
        expect(ids(afterReboot) == ["B"], "a session resumed by hand drops out of the offer")
        afterReboot.dismissAll()
        expect(afterReboot.pending == nil && !FileManager.default.fileExists(atPath: Paths.restorePending.path), "忽略 clears the offer")

        reset()
        RestoreTracker(bootTime: t0.addingTimeInterval(-3600)).observe([a, b, c, d], now: t0)
        let noRebootTwo = RestoreTracker(bootTime: t0.addingTimeInterval(-3600))
        noRebootTwo.observe([a, b], now: t0.addingTimeInterval(60))
        expect(noRebootTwo.pending == nil, "without a restart, two closed sessions are just closed tabs")
        reset()
        RestoreTracker(bootTime: t0.addingTimeInterval(-3600)).observe([a, b, c, d], now: t0)
        let noRebootThree = RestoreTracker(bootTime: t0.addingTimeInterval(-3600))
        noRebootThree.observe([d], now: t0.addingTimeInterval(60))
        expect(ids(noRebootThree) == ["A", "B", "C"] && noRebootThree.pending?.reason == .bulk, "three gone while the app was not running counts")

        reset()
        let running = RestoreTracker(bootTime: t0.addingTimeInterval(-3600))
        running.observe([a, b, c, d], now: t0)
        running.observe([a, b, c], now: t0.addingTimeInterval(3))
        expect(running.pending == nil, "one tab closed while running is not offered")
        running.observe([], now: t0.addingTimeInterval(6))
        expect(ids(running) == ["A", "B", "C"] && running.pending?.reason == .bulk, "sessions ending together while running are offered")
        running.observe([b], now: t0.addingTimeInterval(9))
        expect(ids(running) == ["A", "C"], "reopened sessions leave the offer")
        running.remove(["A"])
        expect(ids(running) == ["C"], "reopening one removes just that one")

        reset()
        let shutdown = RestoreTracker(bootTime: t0.addingTimeInterval(-3600))
        shutdown.observe([a, b, c], now: t0)
        shutdown.freeze(now: t0.addingTimeInterval(1))
        shutdown.observe([a], now: t0.addingTimeInterval(4))
        shutdown.observe([], now: t0.addingTimeInterval(7))
        expect(shutdown.pending == nil, "no offer while shutting down (sessions are expected to end)")
        let frozen = JSONFile.read(OpenSessionsSnapshot.self, from: Paths.openSessions)
        expect(frozen?.sessions.map(\.sessionId) == ["A", "B", "C"], "a frozen snapshot keeps everything open at power-off")
        let boot = RestoreTracker(bootTime: t0.addingTimeInterval(120))
        boot.observe([], now: t0.addingTimeInterval(200))
        expect(ids(boot) == ["A", "B", "C"], "after the restart all three are offered")

        reset()
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        return failures == 0
    }

    /// `--icon-sheet <png>`: the four menu bar icons at 4×, on a dark and a light strip.
    static func writeIconSheet(to path: String) -> Bool {
        let icons: [StatusIcon] = [.clear, .few, .many, .overloaded, .cake]
        let scale: CGFloat = 4
        let cell = NSSize(width: 40 * scale, height: 26 * scale)
        let size = NSSize(width: cell.width * CGFloat(icons.count), height: cell.height * 2)
        let image = NSImage(size: size, flipped: true) { _ in
            for (strip, background) in [NSColor(white: 0.12, alpha: 1), NSColor(white: 0.93, alpha: 1)].enumerated() {
                for (index, icon) in icons.enumerated() {
                    let origin = NSPoint(x: CGFloat(index) * cell.width, y: CGFloat(strip) * cell.height)
                    background.setFill()
                    NSRect(origin: origin, size: cell).fill()
                    let picture = icon.image
                    let drawn = NSSize(width: picture.size.width * scale, height: picture.size.height * scale)
                    picture.draw(in: NSRect(
                        x: origin.x + (cell.width - drawn.width) / 2, y: origin.y + (cell.height - drawn.height) / 2,
                        width: drawn.width, height: drawn.height))
                }
            }
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
            let data = rep.representation(using: .png, properties: [:])
        else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// Clicks inside the popover `offset` points below the top of the SwiftUI content, left of the
    /// row's menu button, the way a user's mouse would.
    private static func clickRow(atTopOffset offset: CGFloat) {
        guard let window = NSApp.windows.first(where: { "\(type(of: $0))".contains("Popover") && $0.isVisible }),
            let host = findHostingView(in: window.contentView)
        else {
            print("selftest: popover hosting view not found")
            return
        }
        let local = NSPoint(x: 150, y: host.isFlipped ? offset : host.bounds.height - offset)
        let location = host.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard
                let event = NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
            else { continue }
            window.sendEvent(event)
        }
        print("selftest: clicked at \(location) in \(type(of: host))")
    }

    private static func findHostingView(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if "\(type(of: view))".contains("HostingView") { return view }
        for sub in view.subviews {
            if let found = findHostingView(in: sub) { return found }
        }
        return nil
    }

    private static func capture(into dir: URL) {
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            let kind = String(describing: type(of: window))
            // Each display has a status bar window; only the one actually on screen is interesting.
            if kind.contains("StatusBar") && !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) {
                continue
            }
            print("selftest: window[\(index)] \(kind) frame=\(window.frame)")
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            // The popover's material background is not part of the cached bitmap; paint the
            // appearance's window color underneath so dark-mode text stays readable.
            let image = NSImage(size: view.bounds.size)
            image.lockFocus()
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                NSRect(origin: .zero, size: view.bounds.size).fill()
            }
            rep.draw(in: NSRect(origin: .zero, size: view.bounds.size))
            image.unlockFocus()
            let url = dir.appendingPathComponent("window-\(index).png")
            if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
                try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            }
            print("selftest: saved \(url.path) appearance=\(view.effectiveAppearance.name.rawValue)")
        }
    }
}
