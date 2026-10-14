import AppKit
import GhosttyKit
import Observation

@Observable
final class Tab: Identifiable {
    let id: UUID
    var title = ""
    var pwd: String
    var status = StatusBoard() {
        didSet { if oldValue.top?.state != status.top?.state { stateChanged() } }
    }
    /// When the badge's current state began, for "working 4m".
    var since = Date()
    /// `git diff --shortstat HEAD` as "+12 −3"; refreshed on state changes.
    var diffStat: String?
    weak var project: Project?
    /// Once a program speaks OSC 7501, OSC 9;4 progress is ignored for this tab (per spec).
    @ObservationIgnored private var speaks7501 = false
    @ObservationIgnored private var lastNotified = Date.distantPast

    /// Claude session to resume when the first pane starts (restored from the last run).
    @ObservationIgnored private var resume: String?

    /// Split tree; mutated in place so its identity never changes.
    @ObservationIgnored lazy var root = Pane(leaf: SurfaceView(tab: self, cwd: pwd, initialInput: resume.map { "claude --resume \($0)\n" }))
    var focused: SurfaceView?

    init(id: UUID = UUID(), pwd: String, project: Project) {
        self.id = id
        self.pwd = pwd
        self.project = project
        // The hook writes whatever Claude reports; only a plain id may reach the shell.
        resume = (try? String(contentsOf: sessionFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty.flatMap { $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } ? $0 : nil }
    }

    /// Where `hooks/ghostline-session` records this tab's Claude session id (via GHOSTLINE_SESSION_FILE).
    var sessionFile: URL { Store.dir.appending(path: "sessions/\(id.uuidString)") }

    /// Pastes into the agent's prompt (bracketed, not submitted) and switches to this tab.
    func paste(_ text: String) {
        guard let surface = (focused ?? leaves.first)?.surface else { return }
        text.withCString { ghostty_surface_text(surface, $0, UInt(strlen($0))) }
        Store.shared.focus(self)
    }

    var leaves: [SurfaceView] { root.leaves }

    func split(_ v: SurfaceView, _ dir: ghostty_action_split_direction_e) {
        guard let leaf = root.find(v) else { return }
        let new = SurfaceView(tab: self, cwd: pwd, inherit: v.surface)
        let a = Pane(leaf: v), b = Pane(leaf: new)
        a.parent = leaf; b.parent = leaf
        leaf.vertical = dir == GHOSTTY_SPLIT_DIRECTION_RIGHT || dir == GHOSTTY_SPLIT_DIRECTION_LEFT
        leaf.ratio = 0.5
        leaf.view = nil
        leaf.children = dir == GHOSTTY_SPLIT_DIRECTION_LEFT || dir == GHOSTTY_SPLIT_DIRECTION_UP ? [b, a] : [a, b]
        focused = new
    }

    /// Closes one pane; its sibling takes the parent's place. The last pane closes the tab.
    func closePane(_ v: SurfaceView) {
        guard let leaf = root.find(v), let parent = leaf.parent,
              let sib = parent.children.first(where: { $0 !== leaf }) else { return Store.shared.close(self) }
        v.close()
        parent.vertical = sib.vertical
        parent.ratio = sib.ratio
        parent.view = sib.view
        parent.children = sib.children
        parent.children.forEach { $0.parent = parent }
        if focused === v || focused == nil { focused = parent.leaves.first }
    }

    func closeAll() {
        leaves.forEach { $0.close() }
        try? FileManager.default.removeItem(at: sessionFile)
    }

    /// Ghostty's goto_split: previous/next in tree order, or the nearest pane in a direction.
    func neighbor(of v: SurfaceView, _ dir: ghostty_action_goto_split_e) -> SurfaceView? {
        let all = leaves
        guard all.count > 1, let i = all.firstIndex(where: { $0 === v }) else { return nil }
        switch dir {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS: return all[(i - 1 + all.count) % all.count]
        case GHOSTTY_GOTO_SPLIT_NEXT: return all[(i + 1) % all.count]
        default: break
        }
        // Window coordinates, y up; 2pt slack for the divider.
        let frame = { (s: SurfaceView) in s.convert(s.bounds, to: nil) }
        let from = frame(v)
        return all.filter { $0 !== v }.map { ($0, frame($0)) }
            .filter { _, r in
                switch dir {
                case GHOSTTY_GOTO_SPLIT_LEFT: r.maxX <= from.minX + 2
                case GHOSTTY_GOTO_SPLIT_RIGHT: r.minX >= from.maxX - 2
                case GHOSTTY_GOTO_SPLIT_UP: r.minY >= from.maxY - 2
                default: r.maxY <= from.minY + 2
                }
            }
            .min { hypot($0.1.midX - from.midX, $0.1.midY - from.midY) < hypot($1.1.midX - from.midX, $1.1.midY - from.midY) }?.0
    }

    var name: String {
        if let t = status.top?.title { return t }
        if !title.isEmpty { return title }
        return (pwd as NSString).lastPathComponent
    }

    var isVisible: Bool { NSApp.isActive && Store.shared.selectedTab === self }

    func receive(_ r: StatusRecord) {
        speaks7501 = true
        let before = status.top?.state
        status.apply(r)
        if isVisible { status.markSeen() }
        // Rate-limited heads-up when a background agent needs you or finishes.
        if let top = status.top, top.state != before, top.state == .blocked || top.state == .done,
           !isVisible, Date().timeIntervalSince(lastNotified) > 5 {
            lastNotified = Date()
            let who = top.app ?? "Program"
            Ghostty.notify("\(who) \(top.state == .blocked ? "needs you" : "is done") · \(project?.name ?? "")",
                           top.msg ?? name)
        }
    }

    private func stateChanged() {
        since = Date()
        Store.shared.updateBadge()
        let dir = pwd
        DispatchQueue.global().async {
            let stat = Git.shortstat(in: dir)
            DispatchQueue.main.async { self.diffStat = stat }
        }
    }

    func progressReport(_ p: ghostty_action_progress_report_s) {
        guard !speaks7501 else { return }
        let progress = p.progress >= 0 ? Int(p.progress) : nil
        switch p.state {
        case GHOSTTY_PROGRESS_STATE_REMOVE: status.apply(StatusRecord(state: .clear))
        case GHOSTTY_PROGRESS_STATE_ERROR: status.apply(StatusRecord(state: .error, progress: progress))
        default: status.apply(StatusRecord(state: .working, progress: progress))
        }
    }
}

/// A node in a tab's split tree: a leaf holds a surface, a split holds two children.
@Observable
final class Pane {
    var view: SurfaceView?
    /// Side by side (NSSplitView.isVertical) vs stacked.
    var vertical = true
    var children: [Pane] = []
    @ObservationIgnored weak var parent: Pane?
    /// Ignored so dragging a divider doesn't rebuild the layout.
    @ObservationIgnored var ratio: CGFloat = 0.5
    @ObservationIgnored weak var splitView: PaneSplitView?

    init(leaf: SurfaceView) { view = leaf }

    var leaves: [SurfaceView] { view.map { [$0] } ?? children.flatMap(\.leaves) }

    func find(_ v: SurfaceView) -> Pane? {
        view === v ? self : children.lazy.compactMap { $0.find(v) }.first
    }
}

@Observable
final class Project: Identifiable {
    let id: UUID
    var name: String
    var root: String
    var tabs: [Tab] = []
    var selected: Tab?

    init(id: UUID = UUID(), root: String) {
        self.id = id
        self.root = root
        self.name = (root as NSString).lastPathComponent
    }

    /// Worst state across tabs, for the project row.
    var top: StatusRecord? {
        tabs.compactMap(\.status.top).max { $0.state.urgency < $1.state.urgency }
    }
}

@Observable
final class Store {
    static let shared = Store()
    var projects: [Project] = []
    var current: Project?

    var selectedTab: Tab? { current?.selected }
    /// The agents popover in the title bar.
    var showAgents = false
    var showPalette = false
    var snippets: [Snippet] = []

    /// Every tab with a program reporting status, across all projects.
    var agents: [Tab] { projects.flatMap(\.tabs).filter { $0.status.top != nil } }

    func tab(_ id: UUID?) -> Tab? { projects.lazy.flatMap(\.tabs).first { $0.id == id } }

    private init() {
        loadSnippets()
        load()
        if projects.isEmpty { open(root: NSHomeDirectory()) }
    }

    // MARK: Projects

    func openProjectPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open Project"
        if panel.runModal() == .OK, let url = panel.url { open(root: url.path(percentEncoded: false)) }
    }

    func open(root: String) {
        if let existing = projects.first(where: { $0.root == root }) { return select(existing.selected ?? existing.tabs.first, in: existing) }
        let p = Project(root: root)
        projects.append(p)
        newTab(in: p)
    }

    func closeProject(_ p: Project) {
        p.tabs.forEach { $0.closeAll() }
        projects.removeAll { $0 === p }
        if current === p { current = projects.first }
        updateBadge()
        save()
    }

    func gotoProject(_ index: Int) {
        guard projects.indices.contains(index) else { return }
        let p = projects[index]
        select(p.selected ?? p.tabs.first, in: p)
    }

    // MARK: Tabs

    func newTab(in project: Project? = nil) {
        guard let p = project ?? current ?? projects.first else { return openProjectPanel() }
        let tab = Tab(pwd: p.root, project: p)
        p.tabs.append(tab)
        select(tab, in: p)
        save()
    }

    func close(_ tab: Tab) {
        guard let p = tab.project, let i = p.tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.closeAll()
        p.tabs.remove(at: i)
        if p.selected === tab { select(p.tabs.isEmpty ? nil : p.tabs[min(i, p.tabs.count - 1)], in: p) }
        updateBadge()
        save()
    }

    func select(_ tab: Tab?, in project: Project) {
        current = project
        project.selected = tab
        tab?.status.markSeen()
        updateBadge()
    }

    /// Selects a tab from anywhere (menu bar, review window) and brings the main window forward.
    func focus(_ tab: Tab) {
        let window = selectedTab?.leaves.first?.window
        if let p = tab.project { select(tab, in: p) }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Cycles through the agents that need you, most urgent kind first (blocked, then error, then done).
    func nextAttention() {
        let all = projects.flatMap(\.tabs)
        let need = all.filter { [.blocked, .error, .done].contains($0.status.top?.state) }
        guard let u = need.compactMap(\.status.top?.state.urgency).max() else { return NSSound.beep() }
        let group = need.filter { $0.status.top?.state.urgency == u }
        let here = all.firstIndex { $0 === selectedTab } ?? -1
        focus(group.first { t in all.firstIndex { $0 === t }! > here } ?? group[0])
    }

    /// Dock badge: how many agents are waiting on you.
    func updateBadge() {
        let n = agents.filter { $0.status.top?.state == .blocked }.count
        NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    /// Ghostty's goto_tab: 1-based index, or -1 previous, -2 next, -3 last. Scoped to the current project.
    func gotoTab(_ n: Int) {
        guard let p = current, !p.tabs.isEmpty else { return }
        let i = p.tabs.firstIndex { $0 === p.selected } ?? 0
        let target: Int = switch n {
        case -1: (i - 1 + p.tabs.count) % p.tabs.count
        case -2: (i + 1) % p.tabs.count
        case -3: p.tabs.count - 1
        default: min(n, p.tabs.count) - 1
        }
        select(p.tabs[target], in: p)
    }

    // MARK: Persistence (projects + tab cwds; scrollback isn't restored)

    private struct Saved: Codable {
        /// `ids` parallels `tabs`; optional so older state files still load.
        struct P: Codable { var id: UUID; var root: String; var name: String; var tabs: [String]; var ids: [UUID]?; var selected: Int? }
        var projects: [P]
        var current: UUID?
    }

    static let dir: URL = {
        let dir = URL.applicationSupportDirectory.appending(path: "Ghostline")
        try? FileManager.default.createDirectory(at: dir.appending(path: "sessions"), withIntermediateDirectories: true)
        return dir
    }()

    private var file: URL { Self.dir.appending(path: "state.json") }

    func save() {
        let s = Saved(projects: projects.map { p in
            .init(id: p.id, root: p.root, name: p.name, tabs: p.tabs.map(\.pwd), ids: p.tabs.map(\.id),
                  selected: p.tabs.firstIndex { $0 === p.selected })
        }, current: current?.id)
        try? JSONEncoder().encode(s).write(to: file)
    }

    private func load() {
        guard let data = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        for sp in s.projects {
            let p = Project(id: sp.id, root: sp.root)
            p.name = sp.name
            // A cwd that no longer exists falls back to the project root.
            p.tabs = sp.tabs.enumerated().map { i, pwd in
                Tab(id: sp.ids?[safe: i] ?? UUID(), pwd: FileManager.default.fileExists(atPath: pwd) ? pwd : sp.root, project: p)
            }
            p.selected = sp.selected.flatMap { p.tabs.indices.contains($0) ? p.tabs[$0] : nil } ?? p.tabs.first
            projects.append(p)
        }
        current = projects.first { $0.id == s.current } ?? projects.first
    }
}

// MARK: Snippets

/// A saved prompt: one Markdown file in ~/.config/ghostline/snippets, named by its title.
struct Snippet: Identifiable {
    var id: String { title }
    let title: String
    let text: String
}

extension Store {
    static var snippetsDir: URL { URL(filePath: NSHomeDirectory()).appending(path: ".config/ghostline/snippets") }

    /// Reads the snippets folder, seeding a few examples the first time.
    func loadSnippets() {
        let fm = FileManager.default, dir = Self.snippetsDir
        if !fm.fileExists(atPath: dir.path(percentEncoded: false)) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for (title, text) in [
                ("Run tests and fix failures", "Run the test suite. Fix any failures, then rerun until everything passes."),
                ("Commit with a clear message", "Commit the current changes with a clear, conventional commit message. Don't push."),
                ("Summarize your changes", "Summarize what you changed and why, file by file, and call out anything risky or unfinished."),
            ] { try? text.write(to: dir.appending(path: "\(title).md"), atomically: true, encoding: .utf8) }
        }
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        snippets = files.filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { url in
                (try? String(contentsOf: url, encoding: .utf8)).map {
                    Snippet(title: url.deletingPathExtension().lastPathComponent, text: $0.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
