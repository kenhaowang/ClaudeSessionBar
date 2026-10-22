import Foundation

/// Enough to reopen a session with `cd <cwd> && claude --resume <sessionId>`; `--resume` keeps the
/// session id, so names, groups and summaries carry over.
struct RestorableSession: Codable, Equatable, Identifiable {
    let sessionId: String
    /// Directory the session was started in; `--resume` looks the transcript up from there.
    let cwd: String
    let name: String
    let branch: String?
    let lastSpokeAt: Double?

    var id: String { sessionId }
}

struct OpenSessionsSnapshot: Codable {
    var savedAt: Double
    var sessions: [RestorableSession]
}

struct RestorePending: Codable, Equatable {
    enum Reason: String, Codable {
        /// The machine restarted (e.g. a forced macOS update) since the snapshot was taken.
        case reboot
        /// Several sessions ended at once without a restart, e.g. iTerm crashed or was quit.
        case bulk
    }

    var reason: Reason
    var interruptedAt: Double
    var sessions: [RestorableSession]
}

/// Remembers which sessions are open (open-sessions.json) and works out which ones were lost to a
/// restart or crash (restore-pending.json) so they can be reopened.
final class RestoreTracker {
    /// Closing one or two tabs is normal; this many ending together is not.
    static let bulkThreshold = 3

    private(set) var pending: RestorePending?
    private(set) var isFrozen = false
    private var previous: OpenSessionsSnapshot?
    private var lastLive: [RestorableSession] = []
    private var started = false
    private var lastWrite = Date.distantPast
    private let bootTime: Date

    init(bootTime: Date = RestoreTracker.systemBootTime()) {
        self.bootTime = bootTime
        pending = JSONFile.read(RestorePending.self, from: Paths.restorePending)
        if pending?.sessions.isEmpty == true { pending = nil }
        previous = JSONFile.read(OpenSessionsSnapshot.self, from: Paths.openSessions)
    }

    static func systemBootTime() -> Date {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &bootTime, &size, nil, 0) == 0 else { return .distantPast }
        return Date(timeIntervalSince1970: TimeInterval(bootTime.tv_sec))
    }

    /// Feed every refresh's live sessions. Returns true when the restorable list changed.
    @discardableResult
    func observe(_ live: [RestorableSession], now: Date = Date()) -> Bool {
        let liveIds = Set(live.map(\.sessionId))
        var changed = false
        if !started {
            started = true
            // The snapshot is from before this app started: whatever it lists that is not running
            // now went down while the app was not watching.
            if let previous {
                let lost = previous.sessions.filter { !liveIds.contains($0.sessionId) }
                let rebooted = bootTime.timeIntervalSince1970 > previous.savedAt
                if !lost.isEmpty && (rebooted || lost.count >= Self.bulkThreshold) {
                    add(lost, reason: rebooted ? .reboot : .bulk, at: previous.savedAt)
                    changed = true
                }
            }
        } else if !isFrozen {
            let vanished = lastLive.filter { !liveIds.contains($0.sessionId) }
            if vanished.count >= Self.bulkThreshold {
                add(vanished, reason: .bulk, at: now.timeIntervalSince1970)
                changed = true
            }
        }
        // Reopened by hand (or a scan hiccup that already recovered).
        if var current = pending {
            let before = current.sessions.count
            current.sessions.removeAll { liveIds.contains($0.sessionId) }
            if current.sessions.count != before {
                pending = current.sessions.isEmpty ? nil : current
                changed = true
            }
        }
        if changed { savePending() }

        if !isFrozen && (Set(lastLive.map(\.sessionId)) != liveIds || now.timeIntervalSince(lastWrite) > 60) {
            writeSnapshot(live, at: now)
        }
        lastLive = live
        return changed
    }

    /// Called when macOS announces a logout, restart or shutdown: keep the list as it is now,
    /// because the sessions are about to exit one by one as iTerm quits.
    func freeze(now: Date = Date()) {
        guard !isFrozen else { return }
        writeSnapshot(lastLive, at: now)
        isFrozen = true
    }

    func remove(_ sessionIds: Set<String>) {
        guard var current = pending else { return }
        current.sessions.removeAll { sessionIds.contains($0.sessionId) }
        pending = current.sessions.isEmpty ? nil : current
        savePending()
    }

    func dismissAll() {
        pending = nil
        savePending()
    }

    private func add(_ sessions: [RestorableSession], reason: RestorePending.Reason, at time: Double) {
        var merged = pending?.sessions ?? []
        for session in sessions where !merged.contains(where: { $0.sessionId == session.sessionId }) {
            merged.append(session)
        }
        pending = RestorePending(reason: reason, interruptedAt: time, sessions: merged)
    }

    private func savePending() {
        if let pending {
            JSONFile.write(pending, to: Paths.restorePending)
        } else {
            try? FileManager.default.removeItem(at: Paths.restorePending)
        }
    }

    private func writeSnapshot(_ live: [RestorableSession], at now: Date) {
        JSONFile.write(OpenSessionsSnapshot(savedAt: now.timeIntervalSince1970, sessions: live), to: Paths.openSessions)
        lastWrite = now
    }
}
