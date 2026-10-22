import AppKit
import Foundation
import ServiceManagement

/// Main-thread state for the UI. Scanning happens on `scanQueue`; everything else on main.
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var rows: [SessionRow] = []
    @Published private(set) var lastRefresh = Date()
    @Published private(set) var notice: String?
    @Published private(set) var hooksInstalled = false
    @Published var renamingId: String?
    @Published var confirmingCloseId: String?
    @Published private(set) var groupData = GroupData()
    @Published var editingGroupId: String?
    @Published var newGroupTarget: NewGroupTarget?
    @Published var sortMode: SortMode =
        SortMode(rawValue: UserDefaults.standard.string(forKey: "sortMode") ?? "") ?? .state
    {
        didSet { UserDefaults.standard.set(sortMode.rawValue, forKey: "sortMode") }
    }

    @Published var newSessionDirectory: String =
        UserDefaults.standard.string(forKey: "newSessionDirectory") ?? Paths.defaultNewSessionDirectory
    {
        didSet { UserDefaults.standard.set(newSessionDirectory, forKey: "newSessionDirectory") }
    }

    @Published var language: AppLanguage = L10n.language {
        didSet {
            L10n.language = language
            UserDefaults.standard.set(language.rawValue, forKey: "language")
            apply(raws)
        }
    }

    var autoSummarize = true
    var autoFetchPRs = true
    /// Only the real menu bar app records open sessions; CLI and self-test runs must not.
    var trackOpenSessions = false
    private var restoreTracker: RestoreTracker?
    @Published private(set) var restorePending: RestorePending?
    private var prStatuses: [String: PRStatus] = [:]
    private var prInFlight: Set<String> = []
    private var prFailures: [String: Date] = [:]

    private(set) var names: [String: String] = [:]
    private var overrides: [String: Override] = [:]
    private var summaries: [String: Summary] = [:]
    private var inFlight: Set<String> = []
    private var failures: [String: (uuid: String, at: Date)] = [:]
    private var raws: [RawSession] = []

    private let scanner = Scanner()
    private let scanQueue = DispatchQueue(label: "ClaudeSessionBar.scan")
    private var scanning = false
    private var timer: Timer?
    private var watcher: DirectoryWatcher?
    private var refreshPending = false
    private var noticeToken = UUID()
    private let maxConcurrentSummaries = 3

    var needsYouCount: Int { rows.filter { $0.state.countsAsWaiting }.count }

    var sortedRows: [SessionRow] {
        func spoke(_ row: SessionRow) -> Double { row.lastSpokeAt?.timeIntervalSince1970 ?? 0 }
        switch sortMode {
        case .state:
            return rows.sorted { ($0.state.rank, -spoke($0)) < ($1.state.rank, -spoke($1)) }
        case .stalest:
            return rows.sorted { spoke($0) < spoke($1) }
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                flash(tr("無法設定登入時啟動：", "Couldn't set launch at login: ") + error.localizedDescription)
            }
            objectWillChange.send()
        }
    }

    // MARK: - Lifecycle

    func start() {
        loadPersisted()
        Housekeeping.prune()
        refresh()
        // Claude Code rewrites its session registry on every busy/idle change and the hooks write
        // a state file at each prompt and turn end, so watching both reacts within a fraction of a
        // second; the timer is only a fallback.
        try? FileManager.default.createDirectory(at: Paths.hookState, withIntermediateDirectories: true)
        watcher = DirectoryWatcher(paths: [Paths.sessions.path, Paths.hookState.path]) { [weak self] in
            Log.jump.notice("refresh: file change")
            self?.refresh()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func loadPersisted() {
        if restoreTracker == nil { restoreTracker = RestoreTracker() }
        restorePending = restoreTracker?.pending
        names = JSONFile.read([String: String].self, from: Paths.names) ?? [:]
        overrides = JSONFile.read([String: Override].self, from: Paths.overrides) ?? [:]
        groupData = JSONFile.read(GroupData.self, from: Paths.groups) ?? GroupData()
        summaries = Summary.loadAll()
        hooksInstalled = Housekeeping.hooksInstalled()
    }

    func refresh() {
        guard !scanning else {
            // A change landed mid-scan; scan once more afterwards so it is not lost.
            refreshPending = true
            return
        }
        scanning = true
        scanQueue.async { [weak self] in
            guard let self else { return }
            let raws = self.scanner.scan()
            DispatchQueue.main.async {
                self.scanning = false
                self.hooksInstalled = Housekeeping.hooksInstalled()
                self.apply(raws)
                if self.refreshPending {
                    self.refreshPending = false
                    self.refresh()
                }
            }
        }
    }

    func refreshSync() {
        apply(scanQueue.sync { scanner.scan() })
    }

    // MARK: - Row building

    private func apply(_ raws: [RawSession]) {
        self.raws = raws
        expireOverrides()
        let before = needsYouCount
        rows = raws.map(buildRow)
        if needsYouCount != before { Log.jump.notice("waiting count \(before) -> \(self.needsYouCount)") }
        lastRefresh = Date()
        if trackOpenSessions, let tracker = restoreTracker {
            if tracker.observe(restorableSessions()) { restorePending = tracker.pending }
        }
        if autoSummarize { scheduleSummaries() }
        if autoFetchPRs { schedulePRFetches() }
    }

    private func lastSpoke(_ raw: RawSession) -> Date? {
        let fromHook = raw.hook?.lastPromptAt.map { Date(timeIntervalSince1970: $0) }
        return [raw.transcript?.lastUserAt, fromHook].compactMap { $0 }.max()
    }

    /// A manual status only holds until the user talks to that session again.
    private func expireOverrides() {
        var changed = false
        for raw in raws {
            let sid = raw.agent.sessionId
            guard let override = overrides[sid], let spoke = lastSpoke(raw) else { continue }
            if spoke.timeIntervalSince1970 > override.at {
                overrides[sid] = nil
                changed = true
            }
        }
        if changed { JSONFile.write(overrides, to: Paths.overrides) }
    }

    private func buildRow(_ raw: RawSession) -> SessionRow {
        let agent = raw.agent
        let transcript = raw.transcript
        let sid = agent.sessionId
        let summary = summaries[sid]
        let fresh = summary != nil && summary?.uuid == transcript?.lastMessageUUID && summary?.language == language

        var state = autoState(raw, summary: summary)
        var manual = false
        if let override = overrides[sid] {
            state = override.state.workState
            manual = true
        }

        var waitingFor = summary?.waitingFor.nilIfEmpty
        if state == .waitingApproval {
            waitingFor = raw.hook?.notification?.nilIfEmpty ?? tr("Claude 在等你核准權限", "Claude is waiting for your permission")
        }

        return SessionRow(
            id: sid,
            pid: agent.pid,
            isBackground: agent.isBackground,
            jobId: agent.id,
            tty: raw.tty,
            cwd: transcript?.cwd ?? agent.cwd,
            branch: transcript?.gitBranch,
            displayName: currentName(raw),
            hasCustomName: names[sid] != nil,
            state: state,
            isManual: manual,
            summaryUpdating: summary != nil && !fresh && !state.isLive && state != .summarizing,
            summary: summary?.summary.nilIfEmpty,
            waitingFor: waitingFor,
            lastPrompt: transcript?.lastPrompt?.nilIfEmpty,
            lastSpokeAt: lastSpoke(raw),
            pr: pullRequest(of: raw),
            prStatus: pullRequest(of: raw).flatMap { prStatuses[$0.url] })
    }

    /// The PR linked most recently in the conversation, from the session's own repository (links
    /// to other repos, e.g. examples in docs, are ignored).
    private func pullRequest(of raw: RawSession) -> PRRef? {
        guard let mentions = raw.transcript?.prMentions else { return nil }
        return mentions.last { raw.repoKey == nil || $0.repoKey == raw.repoKey }
    }

    // MARK: - Restore after restart

    /// Live sessions that can be resumed later (a session with no messages has no transcript).
    private func restorableSessions() -> [RestorableSession] {
        raws.compactMap { raw in
            guard raw.transcript?.lastMessageUUID != nil else { return nil }
            return RestorableSession(
                sessionId: raw.agent.sessionId, cwd: raw.agent.cwd, name: currentName(raw),
                branch: raw.transcript?.gitBranch, lastSpokeAt: lastSpoke(raw)?.timeIntervalSince1970)
        }
    }

    func freezeOpenSessions() {
        restoreTracker?.freeze()
        Log.jump.notice("power off: froze \(self.raws.count) open sessions")
    }

    func reopen(_ sessions: [RestorableSession]) {
        guard !sessions.isEmpty else { return }
        closePopover?()
        ITerm.openTabs(running: sessions.map { "cd " + ITerm.shellQuote($0.cwd) + " && claude --resume " + $0.sessionId })
        restoreTracker?.remove(Set(sessions.map(\.sessionId)))
        restorePending = restoreTracker?.pending
    }

    func dismissRestore() {
        restoreTracker?.dismissAll()
        restorePending = nil
    }

    // MARK: - Pull requests

    private func prNeedsFetch(_ pr: PRRef, now: Date) -> Bool {
        if prInFlight.contains(pr.url) { return false }
        if let status = prStatuses[pr.url], now.timeIntervalSince(status.fetchedAt) < status.refreshInterval {
            return false
        }
        if let failed = prFailures[pr.url], now.timeIntervalSince(failed) < 300 { return false }
        return true
    }

    private func schedulePRFetches() {
        guard GitHub.ghPath != nil else { return }
        let now = Date()
        for pr in Set(rows.compactMap(\.pr)) where prNeedsFetch(pr, now: now) {
            guard prInFlight.count < 2 else { return }
            prInFlight.insert(pr.url)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let status = GitHub.fetch(pr)
                DispatchQueue.main.async { self?.finishPRFetch(pr, status) }
            }
        }
    }

    private func finishPRFetch(_ pr: PRRef, _ status: PRStatus?) {
        prInFlight.remove(pr.url)
        if let status {
            prStatuses[pr.url] = status
            prFailures[pr.url] = nil
        } else {
            prFailures[pr.url] = Date()
        }
        apply(raws)
    }

    /// CLI only: fetch every linked PR and wait.
    func fetchPRsSync() {
        let prs = Array(Set(rows.compactMap(\.pr)))
        var results = [PRStatus?](repeating: nil, count: prs.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: prs.count) { index in
            let status = GitHub.fetch(prs[index])
            lock.lock()
            results[index] = status
            lock.unlock()
        }
        for (pr, status) in zip(prs, results) { if let status { prStatuses[pr.url] = status } }
        apply(raws)
    }

    private func currentName(_ raw: RawSession) -> String {
        let sid = raw.agent.sessionId
        return names[sid] ?? summaries[sid]?.suggestedName.nilIfEmpty ?? raw.transcript?.aiTitle
            ?? raw.agent.name ?? tr("未命名", "Untitled")
    }

    private func autoState(_ raw: RawSession, summary: Summary?) -> WorkState {
        let agent = raw.agent
        let lastMessage = raw.transcript?.lastMessageAt?.timeIntervalSince1970 ?? 0
        // A permission prompt is only current while nothing has been written after it.
        if let hook = raw.hook, hook.at >= lastMessage {
            if hook.state == "waiting_approval" { return .waitingApproval }
            if hook.state == "waiting_input" { return .waitingReply }
        }
        if agent.isBackground {
            switch agent.state {
            case "blocked": return .waitingReply
            case "working", "running": return .running
            default: break
            }
        } else if agent.status == "busy" {
            return .running
        }
        if let hook = raw.hook, hook.state == "idle_bg", hook.at >= lastMessage { return .background }
        if raw.transcript?.lastMessageUUID == nil { return .idle }
        if let summary, summary.uuid == raw.transcript?.lastMessageUUID, summary.language == language {
            return summary.workState
        }
        if summary != nil { return .summarizing }
        return ClaudeCLI.path == nil ? .idle : .summarizing
    }

    // MARK: - Summaries

    private func summaryJob(for raw: RawSession, now: Date) -> SummaryJob? {
        let sid = raw.agent.sessionId
        guard !inFlight.contains(sid), let transcript = raw.transcript,
            let uuid = transcript.lastMessageUUID, !transcript.tail.isEmpty
        else { return nil }
        if let existing = summaries[sid], existing.uuid == uuid, existing.language == language { return nil }
        if let failure = failures[sid], failure.uuid == uuid, now.timeIntervalSince(failure.at) < 600 {
            return nil
        }
        // Without a Stop hook confirming the turn ended, give the transcript a moment to settle.
        let turnEnded = raw.hook.map { ($0.state == "idle" || $0.state == "idle_bg") && $0.at >= (transcript.lastMessageAt?.timeIntervalSince1970 ?? 0) } ?? false
        if !turnEnded, let last = transcript.lastMessageAt, now.timeIntervalSince(last) < 2 { return nil }
        if autoState(raw, summary: nil).isLive { return nil }
        let prompt = Summarizer.prompt(
            name: currentName(raw), cwd: transcript.cwd ?? raw.agent.cwd, branch: transcript.gitBranch,
            tail: transcript.tail, language: language)
        return SummaryJob(sessionId: sid, uuid: uuid, prompt: prompt, language: language)
    }

    private func scheduleSummaries() {
        guard let claude = ClaudeCLI.path else { return }
        let now = Date()
        // Most recently active first, so a turn that just ended is not stuck behind old sessions.
        let ordered = raws.sorted {
            ($0.transcript?.lastMessageAt ?? .distantPast) > ($1.transcript?.lastMessageAt ?? .distantPast)
        }
        for raw in ordered {
            guard inFlight.count < maxConcurrentSummaries else { return }
            guard let job = summaryJob(for: raw, now: now) else { continue }
            inFlight.insert(job.sessionId)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let result = Summarizer.run(job, claude: claude)
                DispatchQueue.main.async { self?.finish(job, result) }
            }
        }
    }

    private func finish(_ job: SummaryJob, _ result: Summary?) {
        inFlight.remove(job.sessionId)
        if let result {
            summaries[job.sessionId] = result
            result.save(sessionId: job.sessionId)
            failures[job.sessionId] = nil
        } else {
            failures[job.sessionId] = (job.uuid, Date())
        }
        apply(raws)
    }

    /// CLI only: summarize every eligible session and wait for the results.
    func summarizeAllSync() {
        guard let claude = ClaudeCLI.path else { return }
        let jobs = raws.compactMap { summaryJob(for: $0, now: Date()) }
        var results = [Summary?](repeating: nil, count: jobs.count)
        let lock = NSLock()
        let gate = DispatchSemaphore(value: maxConcurrentSummaries)
        DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
            gate.wait()
            let summary = Summarizer.run(jobs[index], claude: claude)
            gate.signal()
            lock.lock()
            results[index] = summary
            lock.unlock()
        }
        for (job, summary) in zip(jobs, results) {
            guard let summary else { continue }
            summaries[job.sessionId] = summary
            summary.save(sessionId: job.sessionId)
        }
    }

    // MARK: - Groups

    /// Every tab in display order. Stale ids are dropped and tabs missing from the saved order
    /// (older files, new groups) are filled in: 全部 first, 未分組 second, groups at the end.
    var tabOrder: [GroupFilter] {
        let groupIds = groupData.groups.map(\.id)
        let valid = Set(["all", "ungrouped"] + groupIds)
        var raws: [String] = []
        for raw in groupData.tabOrder ?? [] where valid.contains(raw) && !raws.contains(raw) {
            raws.append(raw)
        }
        if !raws.contains("all") { raws.insert("all", at: 0) }
        if !raws.contains("ungrouped") { raws.insert("ungrouped", at: min(1, raws.count)) }
        for id in groupIds where !raws.contains(id) { raws.append(id) }
        return raws.map { GroupFilter(raw: $0) }
    }

    /// 未分組 only means something once at least one group exists.
    var visibleTabs: [GroupFilter] {
        groupData.groups.isEmpty ? tabOrder.filter { $0 != .ungrouped } : tabOrder
    }

    /// User groups in tab order, so menus list them the way the tabs show them.
    var groups: [SessionGroup] {
        tabOrder.compactMap { tab in
            guard case .group(let id) = tab else { return nil }
            return groupData.groups.first { $0.id == id }
        }
    }

    /// What is being dragged right now, recorded when the drag starts. Drop targets use it only to
    /// choose between the insertion bar (tabs) and the highlight (sessions) while hovering; the
    /// drop itself decides from the payload. Indicators are drawn only while this is set.
    @Published var dragKind: DragKind? {
        didSet { if dragKind != nil && oldValue == nil { watchForDragEnd() } }
    }
    private var dragEndWatch: Timer?

    /// SwiftUI does not reliably send dropExited once a drag is over (e.g. a drop reorders the
    /// tabs under a still-hovering cursor, or a drag is abandoned over empty space), which left
    /// an insertion bar stuck on screen. Ending the drag when the mouse button comes up clears
    /// every indicator no matter which callbacks arrived.
    private func watchForDragEnd() {
        dragEndWatch?.invalidate()
        guard !SelfTest.holdDrag else { return }
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] timer in
            guard NSEvent.pressedMouseButtons == 0 else { return }
            timer.invalidate()
            self?.dragKind = nil
        }
        // Common modes: the run loop is in event-tracking mode for the whole drag.
        RunLoop.main.add(timer, forMode: .common)
        dragEndWatch = timer
    }

    /// Drops a tab next to `target`, matching the insertion bar shown while hovering.
    func moveTab(_ tab: GroupFilter, nextTo target: GroupFilter, after: Bool) {
        guard tab != target else { return }
        var order = tabOrder.map(\.raw)
        guard let from = order.firstIndex(of: tab.raw) else { return }
        order.remove(at: from)
        guard let targetIndex = order.firstIndex(of: target.raw) else { return }
        order.insert(tab.raw, at: after ? targetIndex + 1 : targetIndex)
        groupData.tabOrder = order
        saveGroups()
    }

    func moveTabToEnd(_ tab: GroupFilter) {
        var order = tabOrder.map(\.raw)
        guard let from = order.firstIndex(of: tab.raw) else { return }
        order.remove(at: from)
        order.append(tab.raw)
        groupData.tabOrder = order
        saveGroups()
    }

    func moveTab(_ tab: GroupFilter, by offset: Int) {
        var order = visibleTabs.map(\.raw)
        guard let index = order.firstIndex(of: tab.raw), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
        if groupData.groups.isEmpty { order.insert("ungrouped", at: min(1, order.count)) }
        groupData.tabOrder = order
        saveGroups()
    }

    func title(of tab: GroupFilter) -> String {
        switch tab {
        case .all: return tr("全部", "All")
        case .ungrouped: return tr("未分組", "Ungrouped")
        case .group(let id): return groupData.groups.first { $0.id == id }?.name ?? ""
        }
    }

    func groupId(of sessionId: String) -> String? {
        guard let id = groupData.assignments[sessionId], groupData.groups.contains(where: { $0.id == id })
        else { return nil }
        return id
    }

    func groupName(of sessionId: String) -> String? {
        guard let id = groupId(of: sessionId) else { return nil }
        return groupData.groups.first { $0.id == id }?.name
    }

    /// The selected tab, falling back to "全部" when its group no longer exists.
    var filter: GroupFilter {
        let filter = GroupFilter(raw: groupData.selected)
        if case .group(let id) = filter, !groupData.groups.contains(where: { $0.id == id }) { return .all }
        return filter
    }

    func select(_ filter: GroupFilter) {
        groupData.selected = filter.raw
        saveGroups()
    }

    func rows(in filter: GroupFilter) -> [SessionRow] {
        switch filter {
        case .all: return sortedRows
        case .ungrouped: return sortedRows.filter { groupId(of: $0.id) == nil }
        case .group(let id): return sortedRows.filter { groupId(of: $0.id) == id }
        }
    }

    var visibleRows: [SessionRow] { rows(in: filter) }

    func counts(for filter: GroupFilter) -> (total: Int, needsYou: Int) {
        let rows = rows(in: filter)
        return (rows.count, rows.filter { $0.state.countsAsWaiting }.count)
    }

    /// "未分組" first, then user groups in their own order. Used by --dump and --check-groups.
    var sections: [GroupSection] {
        var result: [GroupSection] = []
        let ungrouped = rows(in: .ungrouped)
        if !ungrouped.isEmpty || groupData.groups.isEmpty {
            result.append(GroupSection(group: nil, rows: ungrouped))
        }
        for group in groups {
            result.append(GroupSection(group: group, rows: rows(in: .group(group.id))))
        }
        return result
    }

    func createGroup(named name: String, assigning sessionId: String? = nil) {
        newGroupTarget = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let group = SessionGroup(id: UUID().uuidString, name: trimmed)
        groupData.groups.append(group)
        if let sessionId { groupData.assignments[sessionId] = group.id }
        saveGroups()
    }

    func renameGroup(_ id: String, to name: String) {
        editingGroupId = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = groupData.groups.firstIndex(where: { $0.id == id }) else { return }
        groupData.groups[index].name = trimmed
        saveGroups()
    }

    /// Sessions in a deleted group fall back to "未分組"; nothing else is touched.
    func deleteGroup(_ id: String) {
        groupData.groups.removeAll { $0.id == id }
        groupData.assignments = groupData.assignments.filter { $0.value != id }
        groupData.tabOrder?.removeAll { $0 == id }
        if groupData.selected == id { groupData.selected = nil }
        saveGroups()
    }

    func assign(_ sessionId: String, to groupId: String?) {
        groupData.assignments[sessionId] = groupId
        saveGroups()
    }

    func groupDataContainsAssignment(to groupId: String) -> Bool {
        groupData.assignments.values.contains(groupId)
    }

    private func saveGroups() {
        JSONFile.write(groupData, to: Paths.groups)
    }

    // MARK: - Actions

    /// Set by AppDelegate; the popover must be gone before iTerm takes focus.
    var closePopover: (() -> Void)?

    func jump(_ row: SessionRow) {
        Log.jump.notice("jump \(row.displayName, privacy: .public) tty=\(row.tty ?? "nil", privacy: .public)")
        if SelfTest.dryRunJump {
            SelfTest.jumpedRow = row.displayName
            return
        }
        closePopover?()
        let fallback = { [weak self] in
            if row.isBackground, let jobId = row.jobId {
                ITerm.openAttach(jobId: jobId)
            } else {
                self?.flash(tr("找不到這個 session 所在的 iTerm 分頁", "Couldn't find this session's iTerm tab"))
            }
        }
        guard let tty = row.tty else {
            fallback()
            return
        }
        ITerm.focus(tty: tty) { found in
            if !found { fallback() }
        }
    }

    @Published var worktreeProposal: WorktreeProposal?
    /// tty of the iTerm tab the user was last working in, read when the popover opens.
    @Published var activeTTY: String?

    /// Opens the worktree that has the session's branch checked out in Cursor, or asks (inline in
    /// the row) before creating one under .claude/worktrees.
    func openInCursor(_ row: SessionRow) {
        guard let branch = row.branch else {
            flash(tr("這個 session 沒有分支資訊", "This session has no branch"))
            return
        }
        let directory = row.cwd
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let entries = Worktree.list(repoDirectory: directory)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let entries, let main = entries.first else {
                    self.flash(directory + tr(" 不在 git repo 裡", " is not in a git repository"))
                    return
                }
                if let existing = entries.first(where: { $0.branch == branch }) {
                    Log.jump.notice("cursor open existing \(existing.path, privacy: .public)")
                    if !Worktree.openInCursor(existing.path) { self.flash(tr("無法開啟 Cursor", "Couldn't open Cursor")) }
                    return
                }
                self.worktreeProposal = WorktreeProposal(
                    sessionId: row.id, branch: branch, mainRoot: main.path,
                    path: Worktree.suggestedPath(mainRoot: main.path, branch: branch))
            }
        }
    }

    func confirmWorktreeProposal() {
        guard let proposal = worktreeProposal else { return }
        worktreeProposal = nil
        flash(tr("建立 worktree 中：", "Creating worktree: ") + proposal.branch + "…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let error = Worktree.add(mainRoot: proposal.mainRoot, path: proposal.path, branch: proposal.branch)
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.flash(tr("建立 worktree 失敗：", "Creating the worktree failed: ") + error)
                    return
                }
                Log.jump.notice("cursor open new worktree \(proposal.path, privacy: .public)")
                if !Worktree.openInCursor(proposal.path) { self.flash(tr("worktree 已建立，但無法開啟 Cursor", "Worktree created, but Cursor couldn't be opened")) }
            }
        }
    }

    func openNewSession() {
        closePopover?()
        ITerm.openNewSession(in: newSessionDirectory)
    }

    func chooseNewSessionDirectory() {
        closePopover?()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: newSessionDirectory)
        panel.message = tr("選擇「＋」開新 Claude session 的資料夾", "Choose the folder where ＋ starts new Claude sessions")
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { newSessionDirectory = url.path }
    }

    func rename(_ row: SessionRow, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        names[row.id] = trimmed.nilIfEmpty
        JSONFile.write(names, to: Paths.names)
        renamingId = nil
        if let tty = row.tty, !trimmed.isEmpty { ITerm.setName(tty: tty, name: trimmed) }
        apply(raws)
    }

    func setOverride(_ row: SessionRow, _ state: ManualState?) {
        overrides[row.id] = state.map { Override(state: $0, at: Date().timeIntervalSince1970) }
        JSONFile.write(overrides, to: Paths.overrides)
        apply(raws)
    }

    func resummarize(_ row: SessionRow) {
        summaries[row.id] = nil
        failures[row.id] = nil
        try? FileManager.default.removeItem(at: Paths.summaries.appendingPathComponent(row.id + ".json"))
        apply(raws)
    }

    func close(_ row: SessionRow, closeTab: Bool) {
        confirmingCloseId = nil
        if row.isBackground, let jobId = row.jobId, let claude = ClaudeCLI.path {
            DispatchQueue.global().async {
                _ = Shell.run(claude, ["stop", jobId], env: ClaudeCLI.environment, timeout: 20)
            }
        } else {
            guard Scanner.isClaudeProcess(pid: row.pid) else {
                flash(tr("這個 session 已經結束了", "This session has already ended"))
                refresh()
                return
            }
            kill(pid_t(row.pid), SIGTERM)
        }
        if closeTab, let tty = row.tty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { ITerm.closeSession(tty: tty) }
        }
        flash(tr("已結束：", "Ended: ") + row.displayName)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refresh() }
    }

    private func flash(_ message: String) {
        notice = message
        let token = UUID()
        noticeToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.noticeToken == token { self?.notice = nil }
        }
    }
}
