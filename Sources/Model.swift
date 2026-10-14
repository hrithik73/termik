import AppKit
import GhosttyKit
import Observation

@Observable
final class Tab: Identifiable {
    let id = UUID()
    var title = ""
    var pwd: String
    var status = StatusBoard()
    weak var project: Project?
    /// Once a program speaks OSC 7501, OSC 9;4 progress is ignored for this tab (per spec).
    @ObservationIgnored private var speaks7501 = false
    @ObservationIgnored private var lastNotified = Date.distantPast

    /// Split tree; mutated in place so its identity never changes.
    @ObservationIgnored lazy var root = Pane(leaf: SurfaceView(tab: self, cwd: pwd))
    var focused: SurfaceView?

    init(pwd: String, project: Project) {
        self.pwd = pwd
        self.project = project
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

    func closeAll() { leaves.forEach { $0.close() } }

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

    private init() {
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
        save()
    }

    func select(_ tab: Tab?, in project: Project) {
        current = project
        project.selected = tab
        tab?.status.markSeen()
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
        struct P: Codable { var id: UUID; var root: String; var name: String; var tabs: [String]; var selected: Int? }
        var projects: [P]
        var current: UUID?
    }

    private var file: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "Ghostline")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "state.json")
    }

    func save() {
        let s = Saved(projects: projects.map { p in
            .init(id: p.id, root: p.root, name: p.name, tabs: p.tabs.map(\.pwd),
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
            p.tabs = sp.tabs.map { Tab(pwd: FileManager.default.fileExists(atPath: $0) ? $0 : sp.root, project: p) }
            p.selected = sp.selected.flatMap { p.tabs.indices.contains($0) ? p.tabs[$0] : nil } ?? p.tabs.first
            projects.append(p)
        }
        current = projects.first { $0.id == s.current } ?? projects.first
    }
}
