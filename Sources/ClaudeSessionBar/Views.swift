import SwiftUI
import UniformTypeIdentifiers

/// In the macOS 27 SDK `@State` resolves to a SwiftUI macro whose plugin ships only with Xcode, so
/// building with just the Command Line Tools fails. Naming the property wrapper through an alias
/// bypasses the macro and works with every SDK.
typealias ViewState = SwiftUI.State

extension WorkState {
    var color: Color {
        switch self {
        case .waitingApproval, .blocked: return .red
        case .waitingReply: return .orange
        case .running: return .blue
        case .background: return .teal
        case .waitingExternal: return .purple
        case .done: return .green
        case .summarizing, .idle, .paused: return .gray
        }
    }
}

extension AccentTheme {
    var color: Color {
        switch self {
        case .blue: return Color(red: 0x0d / 255, green: 0x6e / 255, blue: 0xfd / 255)
        case .green: return Color(red: 0x19 / 255, green: 0x87 / 255, blue: 0x54 / 255)
        case .yellow: return Color(red: 0xff / 255, green: 0xc1 / 255, blue: 0x07 / 255)
        case .red: return Color(red: 0xdc / 255, green: 0x35 / 255, blue: 0x45 / 255)
        case .gray: return Color(red: 0x6c / 255, green: 0x75 / 255, blue: 0x7d / 255)
        }
    }

    /// Text and glyphs drawn on top of the colour; yellow is too light for white (as in Bootstrap).
    var onColor: Color {
        self == .yellow ? Color(red: 0x21 / 255, green: 0x25 / 255, blue: 0x29 / 255) : .white
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PopoverView: View {
    @ObservedObject var store: Store
    @ViewState private var contentHeight: CGFloat = 0

    /// A ScrollView has no intrinsic height, so a self-sizing popover would collapse it to nothing.
    /// Size it to the measured content instead, capped so long lists scroll.
    private var listHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        let cap = max(240, min(680, screen - 220))
        let measured = contentHeight > 0 ? contentHeight : CGFloat(store.visibleRows.count) * 80
        return min(measured, cap)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            GroupBar(store: store)
            Divider()
            if store.rows.isEmpty && store.groups.isEmpty && store.restorePending == nil {
                Text(tr("目前沒有開著的 Claude session", "No Claude sessions are running"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(28)
            } else {
                ScrollView {
                    VStack(spacing: 0) { rowList }
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                            })
                }
                .frame(height: listHeight)
                .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            }
            Divider()
            footer
        }
        .frame(width: 480)
    }

    @ViewBuilder private var rowList: some View {
        if let pending = store.restorePending {
            RestoreBanner(pending: pending, store: store)
            Divider()
        }
        let rows = store.visibleRows
        if rows.isEmpty {
            Text(emptyText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        }
        ForEach(rows) { row in
            SessionRowView(row: row, store: store, showGroup: store.filter == .all)
            if row.id != rows.last?.id { Divider().padding(.leading, 30) }
        }
    }

    private var emptyText: String {
        switch store.filter {
        case .all: return tr("目前沒有開著的 Claude session", "No Claude sessions are running")
        case .ungrouped: return tr("所有 session 都已經分組了", "Every session is in a group")
        case .group: return tr("這個群組還沒有 session\n把 session 拖到上方的群組標籤，或在 session 選單選「移到群組」", "No sessions in this group yet\nDrag a session onto a group tab above, or use “Move to Group” in its menu")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Claude Sessions").font(.headline).lineLimit(1).fixedSize()
                    .onTapGesture { store.accent = store.accent.next }
                    .help(tr("點一下換主題色", "Click to change the accent colour"))
                if Today.isCakeDay { Text(verbatim: "🎂").font(.headline) }
                Spacer(minLength: 4)
                SortSwitch(store: store)
            }
            HStack(spacing: 10) {
                if store.needsYouCount > 0 {
                    Text(waitingText(store.needsYouCount))
                        .lineLimit(1)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.18)))
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 4)
                Button {
                    store.showNewSessionMenu()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 17))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(store.accent.onColor, store.accent.color)
                }
                .buttonStyle(.borderless)
                .contextMenu {
                    Button(tr("選擇資料夾…", "Choose Folder…")) { store.chooseNewSessionDirectory() }
                }
                .help(tr("在 \((store.newSessionDirectory as NSString).abbreviatingWithTildeInPath) 開新的 Claude session，可選要放進哪個群組",
                         "Start a new Claude session in \((store.newSessionDirectory as NSString).abbreviatingWithTildeInPath) and pick its group"))
                Button {
                    store.showSettingsMenu()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(tr("設定：終端機、語言", "Settings: terminal, language"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let notice = store.notice {
                Text(notice).font(.caption).foregroundStyle(.orange).lineLimit(1)
            } else if !store.hooksInstalled {
                Label(tr("hooks 未安裝，抓不到「等你核准」", "Hooks not installed — “Needs approval” can't be detected"), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text(tr("更新於 ", "Updated ") + store.lastRefresh.formatted(.dateTime.hour().minute().second().locale(L10n.locale)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(tr("登入時啟動", "Launch at Login"), isOn: Binding(get: { store.launchAtLogin }, set: { store.launchAtLogin = $0 }))
                .toggleStyle(.checkbox)
                .tint(store.accent.color)
                .font(.caption)
            Button(tr("結束 App", "Quit")) { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Places children left to right and wraps onto a new line when the width runs out, so every
/// group tab stays visible without horizontal scrolling.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// The group tabs under the title: 全部 / 未分組 / user groups / ＋.
struct GroupBar: View {
    @ObservedObject var store: Store
    @ViewState private var plusDropSide: DropSide?

    private var selectedGroup: SessionGroup? {
        guard case .group(let id) = store.filter else { return nil }
        return store.groups.first { $0.id == id }
    }

    var body: some View {
        FlowLayout {
            ForEach(store.visibleTabs, id: \.raw) { tab in
                GroupChip(tab: tab, store: store)
            }
            if store.newGroupTarget == .bar {
                NewGroupChipField(store: store)
            } else {
                Button {
                    store.newGroupTarget = .bar
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 10))
                        if store.groups.isEmpty { Text(tr("新增群組", "New Group")) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, store.groups.isEmpty ? 10 : 8)
                    .padding(.vertical, 4)
                    .background(Capsule().strokeBorder(Color.secondary.opacity(0.4), style: .init(dash: [3])))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(tr("新增群組；把標籤拖到這裡會移到最後", "New group; drop a tab here to move it to the end"))
                .overlay(alignment: .leading) {
                    if store.dragKind != nil && plusDropSide != nil { InsertionBar(color: store.accent.color).offset(x: -4) }
                }
                .onDrop(of: [.text], delegate: TabDropDelegate(target: nil, store: store, width: 0, side: $plusDropSide))
                .onChange(of: store.dragKind) { _, kind in
                    if kind == nil { plusDropSide = nil }
                }
            }
            if let group = selectedGroup {
                Menu {
                    GroupMenuItems(group: group, store: store)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(tr("「\(group.name)」群組設定", "“\(group.name)” group settings"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct GroupMenuItems: View {
    let group: SessionGroup
    @ObservedObject var store: Store

    var body: some View {
        Button(tr("改名…", "Rename…")) { store.editingGroupId = group.id }
        Button(tr("往左移", "Move Left")) { store.moveTab(.group(group.id), by: -1) }
            .disabled(store.visibleTabs.first == .group(group.id))
        Button(tr("往右移", "Move Right")) { store.moveTab(.group(group.id), by: 1) }
            .disabled(store.visibleTabs.last == .group(group.id))
        Divider()
        Button(tr("刪除群組（session 會移回未分組）", "Delete Group (sessions go back to Ungrouped)")) { store.deleteGroup(group.id) }
    }
}

struct GroupChip: View {
    let tab: GroupFilter
    @ObservedObject var store: Store
    @ViewState private var dropSide: DropSide?
    @ViewState private var width: CGFloat = 0
    @ViewState private var draftName = ""
    @FocusState private var nameFocused: Bool

    /// Tabs and session rows both drag plain strings; a tab's payload carries this prefix so a
    /// drop can tell "reorder the tabs" from "file this session" (session ids are UUIDs).
    static let dragPrefix = "tab:"

    static func tab(fromDragItem item: String) -> GroupFilter? {
        guard item.hasPrefix(dragPrefix) else { return nil }
        return GroupFilter(raw: String(item.dropFirst(dragPrefix.count)))
    }

    private var filter: GroupFilter { tab }
    private var title: String { store.title(of: tab) }

    private var icon: String? {
        switch tab {
        case .all: return nil
        case .ungrouped: return "tray"
        case .group: return "folder"
        }
    }

    /// Set for user-created groups, which can be renamed and deleted.
    private var group: SessionGroup? {
        guard case .group(let id) = tab else { return nil }
        return store.groups.first { $0.id == id }
    }

    private var isSelected: Bool { store.filter == filter }
    private var isSessionDropTarget: Bool { store.dragKind != nil && dropSide == .onto }
    private var isRenaming: Bool { group != nil && store.editingGroupId == group?.id }
    /// "全部" is not a place a session can be moved to.
    private var acceptsSessions: Bool { filter != .all }

    var body: some View {
        Group {
            if let group, isRenaming {
                TextField(tr("群組名稱", "Group name"), text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .frame(width: 120)
                    .focused($nameFocused)
                    .onSubmit { store.renameGroup(group.id, to: draftName) }
                    .onExitCommand { store.editingGroupId = nil }
                    .onAppear {
                        draftName = group.name
                        nameFocused = true
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().strokeBorder(store.accent.color, lineWidth: 1.5))
            } else if let group {
                draggableChip.contextMenu { GroupMenuItems(group: group, store: store) }
            } else {
                draggableChip
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { width = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, newWidth in width = newWidth }
            }
        )
        .overlay(alignment: dropSide == .after ? .trailing : .leading) {
            if store.dragKind != nil && (dropSide == .before || dropSide == .after) {
                InsertionBar(color: store.accent.color).offset(x: dropSide == .after ? 4 : -4)
            }
        }
        .onDrop(of: [.text], delegate: TabDropDelegate(target: tab, store: store, width: width, side: $dropSide))
        .onChange(of: store.dragKind) { _, kind in
            if kind == nil { dropSide = nil }
        }
        .onAppear {
            if let forced = SelfTest.forcedDropIndicator, forced.tab == tab.raw { dropSide = forced.side }
        }
    }

    private var draggableChip: some View {
        chip.onDrag {
            store.dragKind = .tab(tab)
            return NSItemProvider(object: (Self.dragPrefix + tab.raw) as NSString)
        } preview: {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(store.accent.color.opacity(0.85)))
                .foregroundStyle(.white)
        }
    }

    private var chip: some View {
        let counts = store.counts(for: filter)
        return HStack(spacing: 4) {
            if let icon { Image(systemName: isSelected ? icon + ".fill" : icon).font(.system(size: 10)) }
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 150, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Text(verbatim: "\(counts.total)").monospacedDigit().opacity(0.65).fixedSize()
            if counts.needsYou > 0 {
                Text(verbatim: "\(counts.needsYou)")
                    .font(.system(size: 9, weight: .bold))
                    .monospacedDigit()
                    .fixedSize()
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange))
                    .foregroundStyle(.white)
            }
        }
        // FlowLayout proposes the measured size back; rounding could otherwise squeeze the badge.
        .fixedSize()
        .font(.caption.weight(isSelected ? .semibold : .regular))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(chipFill))
        .overlay(Capsule().strokeBorder(isSessionDropTarget ? store.accent.color : Color.clear, lineWidth: 1.5))
        .foregroundStyle(isSelected ? store.accent.onColor : Color.primary)
        .contentShape(Capsule())
        .onTapGesture { store.select(filter) }
        .help(group == nil ? tr("拖曳可調整順序", "Drag to reorder") : tr("拖曳可調整順序；右鍵可改名或刪除；把 session 拖到這裡就會歸進這組", "Drag to reorder; right-click to rename or delete; drop a session here to file it"))
    }

    private var chipFill: Color {
        if isSelected { return store.accent.color }
        if isSessionDropTarget { return store.accent.color.opacity(0.25) }
        return Color.primary.opacity(0.07)
    }
}

struct NewGroupChipField: View {
    @ObservedObject var store: Store
    @ViewState private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder.badge.plus").font(.system(size: 10)).foregroundStyle(.secondary)
            TextField(tr("群組名稱，Enter 建立", "Group name, Enter to create"), text: $name)
                .textFieldStyle(.plain)
                .font(.caption)
                .frame(width: 130)
                .focused($focused)
                .onSubmit { store.createGroup(named: name) }
                .onExitCommand { store.newGroupTarget = nil }
            Button {
                store.newGroupTarget = nil
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().strokeBorder(store.accent.color, lineWidth: 1.5))
        .onAppear { focused = true }
    }
}

struct NewGroupField: View {
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    @ViewState private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.badge.plus").foregroundStyle(.secondary)
            TextField(tr("新群組名稱，按 Enter 建立", "New group name, Enter to create"), text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { onSubmit(name) }
                .onExitCommand { onCancel() }
            Button(tr("取消", "Cancel"), action: onCancel).controlSize(.small)
        }
        .onAppear { focused = true }
    }
}

struct SessionRowView: View {
    let row: SessionRow
    @ObservedObject var store: Store
    /// In the "全部" tab each row says which group it belongs to.
    var showGroup = false
    @ViewState private var hovering = false
    @ViewState private var draftName = ""
    @FocusState private var nameFocused: Bool

    private var isRenaming: Bool { store.renamingId == row.id }
    private var isConfirmingClose: Bool { store.confirmingCloseId == row.id }
    private var isCreatingGroup: Bool { store.newGroupTarget == .row(row.id) }
    private var isActiveTab: Bool { row.tty != nil && row.tty == store.activeTTY }
    private var worktreeProposal: WorktreeProposal? {
        store.worktreeProposal?.sessionId == row.id ? store.worktreeProposal : nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(row.state.color)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                titleLine
                metaLine
                if let pr = row.pr { PRLine(pr: pr, status: row.prStatus, accent: store.accent.color) }
                detailLines
                if isConfirmingClose { closeConfirmation }
                if let proposal = worktreeProposal { worktreeConfirmation(proposal) }
                if isCreatingGroup {
                    NewGroupField(
                        onSubmit: { store.createGroup(named: $0, assigning: row.id) },
                        onCancel: { store.newGroupTarget = nil })
                }
            }
            Menu { menuItems } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(hovering ? 1 : 0.35)
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .opacity(row.isStale && !isConfirmingClose && !isRenaming ? 0.55 : 1)
        .background(hovering ? Color.primary.opacity(0.06) : Color.clear)
        .overlay {
            if isActiveTab {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(store.accent.color, lineWidth: 2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            Log.jump.notice("tap \(row.displayName, privacy: .public)")
            if !isRenaming && !isConfirmingClose && !isCreatingGroup && worktreeProposal == nil { store.jump(row) }
        }
        .contextMenu { menuItems }
        .onDrag {
            store.dragKind = .session(row.id)
            return NSItemProvider(object: row.id as NSString)
        } preview: {
            Label(row.displayName, systemImage: "terminal")
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
        }
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            if isRenaming {
                TextField(tr("名稱", "Name"), text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit { store.rename(row, to: draftName) }
                    .onExitCommand { store.renamingId = nil }
                    .onAppear {
                        draftName = row.displayName
                        nameFocused = true
                    }
            } else {
                Text(row.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if row.isBackground { Pill(text: tr("背景", "Background"), color: .gray) }
                if isActiveTab { Pill(text: tr("目前分頁", "Current Tab"), color: store.accent.color) }
            }
            Spacer(minLength: 4)
            Text(RelativeTime.text(row.lastSpokeAt))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(row.isStale ? Color.orange : Color.secondary)
                .help(tr("距離你上次在這個 session 發言", "Time since you last spoke in this session"))
        }
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            StateBadge(state: row.state, manual: row.isManual, updating: row.summaryUpdating)
            if showGroup, let groupName = store.groupName(of: row.id) {
                Label(groupName, systemImage: "folder")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(store.accent.color)
            }
            if let branch = row.branch {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(branch)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder private var detailLines: some View {
        if row.state == .running, let prompt = row.lastPrompt {
            Text("› " + prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if row.state.needsYou, let waitingFor = row.waitingFor {
            Text(waitingFor).font(.caption).lineLimit(2)
        } else if let detail = row.waitingFor ?? row.summary {
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        if row.isStale {
            Text(tr("超過 3 天沒互動，可考慮關閉", "No activity for 3+ days — consider closing"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var closeConfirmation: some View {
        HStack(spacing: 8) {
            Text(row.state == .running ? tr("還在執行中，確定要結束？", "Still running — end it anyway?") : tr("結束這個 session？", "End this session?"))
                .font(.caption)
                .foregroundStyle(row.state == .running ? Color.red : Color.primary)
            Button(tr("結束", "End")) { store.close(row, closeTab: false) }
            if row.tty != nil { Button(tr("結束並關閉分頁", "End & Close Tab")) { store.close(row, closeTab: true) } }
            Button(tr("取消", "Cancel")) { store.confirmingCloseId = nil }
        }
        .controlSize(.small)
        .padding(.top, 2)
    }

    private func worktreeConfirmation(_ proposal: WorktreeProposal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr("「\(proposal.branch)」還沒有 worktree，要建立在 \(Self.tildePath(proposal.path)) 並用 \(proposal.editor.name) 開啟嗎？", "“\(proposal.branch)” has no worktree yet. Create it at \(Self.tildePath(proposal.path)) and open it in \(proposal.editor.name)?"))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(tr("建立並開啟", "Create & Open")) { store.confirmWorktreeProposal() }
                Button(tr("取消", "Cancel")) { store.worktreeProposal = nil }
            }
            .controlSize(.small)
        }
        .padding(.top, 2)
    }

    static func tildePath(_ path: String) -> String {
        let home = Paths.home.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    @ViewBuilder private var menuItems: some View {
        Button(tr("切換到這個 session", "Go to Session")) { store.jump(row) }
        if let branch = row.branch {
            ForEach(store.editors) { editor in
                Button(tr("在 \(editor.name) 開啟 \(branch)", "Open \(branch) in \(editor.name)")) { store.open(row, in: editor) }
            }
        }
        Button(tr("改名…", "Rename…")) { store.renamingId = row.id }
        if row.hasCustomName { Button(tr("恢復自動名稱", "Restore Automatic Name")) { store.rename(row, to: "") } }
        Menu(tr("移到群組", "Move to Group")) {
            let current = store.groupId(of: row.id)
            ForEach(store.groups) { group in
                Button {
                    store.assign(row.id, to: group.id)
                } label: {
                    if current == group.id {
                        Label(group.name, systemImage: "checkmark")
                    } else {
                        Text(group.name)
                    }
                }
            }
            if !store.groups.isEmpty { Divider() }
            Button(tr("新增群組…", "New Group…")) { store.newGroupTarget = .row(row.id) }
            if current != nil { Button(tr("移出群組", "Remove from Group")) { store.assign(row.id, to: nil) } }
        }
        Menu(tr("設定狀態", "Set Status")) {
            Button(tr("自動判斷", "Automatic")) { store.setOverride(row, nil) }
            Divider()
            ForEach(ManualState.allCases, id: \.self) { state in
                Button(state.label) { store.setOverride(row, state) }
            }
        }
        Button(tr("重新判斷狀態", "Re-evaluate Status")) { store.resummarize(row) }
        Divider()
        Button(tr("結束 session…", "End Session…")) { store.confirmingCloseId = row.id }
    }
}

struct StateBadge: View {
    let state: WorkState
    let manual: Bool
    let updating: Bool

    var body: some View {
        HStack(spacing: 3) {
            if manual { Image(systemName: "hand.raised.fill").font(.system(size: 8)) }
            Text(state.label)
            if updating { Text(tr("· 更新中", "· updating")).opacity(0.7) }
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(state.color.opacity(0.16)))
        .foregroundStyle(state.color)
        .help(manual ? tr("手動設定的狀態，你下次在這個 session 發言後會恢復自動判斷", "Set by hand; goes back to automatic the next time you speak in this session") : "")
    }
}

struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

/// The "|" shown in the gap where a dragged tab would land.
struct InsertionBar: View {
    let color: Color

    var body: some View {
        Capsule()
            .fill(color)
            .frame(width: 3)
            .padding(.vertical, -3)
    }
}

/// Drop handling for a tab chip, or for the ＋ button when `target` is nil (move to the end).
/// While hovering it only knows what kind of drag started (Store.dragKind); on drop it reads the
/// payload, so a stale kind can never reorder tabs or file a session by mistake.
struct TabDropDelegate: DropDelegate {
    let target: GroupFilter?
    let store: Store
    let width: CGFloat
    @Binding var side: DropSide?

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.text]) }

    func dropEntered(info: DropInfo) { side = hoverSide(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        side = hoverSide(info)
        return DropProposal(operation: side == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) { side = nil }

    func performDrop(info: DropInfo) -> Bool {
        let after = info.location.x >= width / 2
        side = nil
        // Clear before reordering: the reorder moves another tab under the cursor, and any hover
        // callback it triggers must not draw a new bar for a drag that is already over.
        store.dragKind = nil
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        let target = self.target
        let store = self.store
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let payload = object as? String else { return }
            DispatchQueue.main.async {
                if let dragged = GroupChip.tab(fromDragItem: payload) {
                    if let target {
                        store.moveTab(dragged, nextTo: target, after: after)
                    } else {
                        store.moveTabToEnd(dragged)
                    }
                } else if let target, target != .all {
                    if case .group(let id) = target {
                        store.assign(payload, to: id)
                    } else {
                        store.assign(payload, to: nil)
                    }
                }
            }
        }
        return true
    }

    private func hoverSide(_ info: DropInfo) -> DropSide? {
        switch store.dragKind {
        case .tab(let dragged):
            guard let target else { return .before }
            if dragged == target { return nil }
            return info.location.x < width / 2 ? .before : .after
        case .session:
            guard let target, target != .all else { return nil }
            return .onto
        case nil:
            return nil
        }
    }
}

/// "#17660 · 開啟中 · 待 review · ✓ CI 通過" under a session that links a pull request.
struct PRLine: View {
    let pr: PRRef
    let status: PRStatus?
    let accent: Color

    var body: some View {
        HStack(spacing: 5) {
            Button {
                if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
            } label: {
                // verbatim: a LocalizedStringKey would format the number as "#17,660".
                Label {
                    Text(verbatim: "#\(pr.number)")
                } icon: {
                    Image(systemName: "arrow.triangle.pull")
                }
                .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .foregroundStyle(accent)
            .help((status?.title.nilIfEmpty ?? pr.url) + tr("（點擊用瀏覽器開啟）", " (click to open in the browser)"))
            if let status {
                separator
                Text(stateLabel(status)).foregroundStyle(stateColor(status))
                if status.isOpen, let review = reviewLabel(status) {
                    separator
                    Text(review.text).foregroundStyle(review.color)
                }
                if status.isOpen, let ci = ciLabel(status) {
                    separator
                    Label(ci.text, systemImage: ci.icon)
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(ci.color)
                        .help(status.failedChecks.isEmpty ? "" : tr("失敗的檢查：", "Failed checks: ") + status.failedChecks.joined(separator: tr("、", ", ")))
                }
            } else {
                Text(tr("讀取 PR 狀態中…", "Loading PR status…")).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .lineLimit(1)
    }

    private var separator: some View { Text("·").foregroundStyle(.tertiary) }

    /// "continuous-integration/drone/pr" → "drone/pr".
    static func shortCheckName(_ name: String) -> String {
        name.hasPrefix("continuous-integration/") ? String(name.dropFirst("continuous-integration/".count)) : name
    }

    private func stateLabel(_ status: PRStatus) -> String {
        switch status.state {
        case "OPEN": return status.isDraft ? tr("草稿", "Draft") : tr("開啟中", "Open")
        case "MERGED": return tr("已合併", "Merged")
        case "CLOSED": return tr("已關閉", "Closed")
        default: return status.state
        }
    }

    private func stateColor(_ status: PRStatus) -> Color {
        switch status.state {
        case "OPEN": return status.isDraft ? .secondary : .green
        case "MERGED": return .purple
        case "CLOSED": return .red
        default: return .secondary
        }
    }

    private func reviewLabel(_ status: PRStatus) -> (text: String, color: Color)? {
        switch status.reviewDecision {
        case "APPROVED": return (tr("已核准", "Approved"), .green)
        case "CHANGES_REQUESTED": return (tr("需要修改", "Changes requested"), .red)
        case "REVIEW_REQUIRED": return (tr("待 review", "Review required"), .secondary)
        default: return nil
        }
    }

    private func ciLabel(_ status: PRStatus) -> (text: String, icon: String, color: Color)? {
        switch status.ci {
        case .success: return (tr("CI 通過", "CI passed"), "checkmark.circle.fill", .green)
        case .pending: return (tr("CI 執行中", "CI running"), "clock.fill", .orange)
        case .failure:
            let first = status.failedChecks.first.map { tr("：", ": ") + Self.shortCheckName($0) } ?? ""
            let more = status.failedChecks.count > 1 ? tr(" 等 \(status.failedChecks.count) 項", " (+\(status.failedChecks.count - 1) more)") : ""
            return (tr("CI 失敗", "CI failed") + first + more, "xmark.circle.fill", .red)
        case .none: return nil
        }
    }
}

/// "重新開機前有 N 個 session 沒有開回來" with reopen-all, per-session reopen and dismiss.
struct RestoreBanner: View {
    let pending: RestorePending
    @ObservedObject var store: Store
    @ViewState private var expanded = true

    private var title: String {
        let count = pending.sessions.count
        let noun = count == 1 ? "session" : "sessions"
        switch pending.reason {
        case .reboot: return tr("重新開機前有 \(count) 個 session 沒有開回來", "\(count) \(noun) from before the restart \(count == 1 ? "hasn't" : "haven't") been reopened")
        case .bulk: return tr("有 \(count) 個 session 同時結束了（可能是 iTerm 關閉或當掉）", "\(count) \(noun) ended at the same time (iTerm may have quit or crashed)")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(store.accent.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(tr("中斷於 ", "Interrupted ") + Date(timeIntervalSince1970: pending.interruptedAt).formatted(.dateTime.month().day().hour().minute().locale(L10n.locale)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(expanded ? tr("收合", "Hide") : tr("清單", "Show")) { expanded.toggle() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            HStack(spacing: 8) {
                Button(tr("全部重新開啟", "Reopen All")) { store.reopen(pending.sessions) }
                    .buttonStyle(.borderedProminent)
                    .tint(store.accent.color)
                Button(tr("忽略", "Dismiss")) { store.dismissRestore() }
            }
            .controlSize(.small)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(pending.sessions) { session in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(session.name).font(.caption.weight(.medium)).lineLimit(1)
                                HStack(spacing: 6) {
                                    if let group = store.groupName(of: session.sessionId) {
                                        Label(group, systemImage: "folder").labelStyle(.titleAndIcon)
                                    }
                                    if let branch = session.branch { Text(branch).lineLimit(1).truncationMode(.middle) }
                                    Text(RelativeTime.text(session.lastSpokeAt.map { Date(timeIntervalSince1970: $0) }))
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Button(tr("開啟", "Open")) { store.reopen([session]) }
                                .controlSize(.small)
                                .help("cd \(session.cwd) && claude --resume \(session.sessionId)")
                        }
                    }
                }
                .padding(.leading, 24)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(store.accent.color.opacity(0.08))
    }
}

/// Two-segment sort switch. AppKit's segmented control ignores SwiftUI tint, so it is drawn here
/// to follow the accent theme like the group tabs do.
struct SortSwitch: View {
    @ObservedObject var store: Store

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SortMode.allCases) { mode in
                let selected = store.sortMode == mode
                Text(mode.label)
                    .font(.caption.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .foregroundStyle(selected ? store.accent.onColor : Color.primary)
                    .background(RoundedRectangle(cornerRadius: 5).fill(selected ? store.accent.color : Color.clear))
                    .contentShape(Rectangle())
                    .onTapGesture { store.sortMode = mode }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
        .help(tr("排序", "Sort"))
    }
}
