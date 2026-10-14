import AppKit
import GhosttyKit
import SwiftUI

struct RootView: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            TitleBar()
            Group {
                if let tab = store.selectedTab { TerminalCard(tab: tab) } else { EmptyState() }
            }
            .padding([.horizontal, .bottom], 12)
        }
        .overlay {
            if store.showPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.12).contentShape(.rect).onTapGesture { store.showPalette = false }
                    Palette().padding(.top, 70)
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(.ultraThinMaterial)
        .frame(minWidth: 520, minHeight: 320)
    }
}

// MARK: Title bar

private struct TitleBar: View {
    @Environment(Store.self) private var store

    var body: some View {
        HStack(spacing: 6) {
            ProjectMenu()
            Divider().frame(height: 16)
            if let p = store.current {
                ScrollView(.horizontal) {
                    HStack(spacing: 2) {
                        ForEach(p.tabs) { TabPill(tab: $0, project: p) }
                    }
                }
                .scrollIndicators(.never)
            }
            Spacer(minLength: 0)
            AgentsButton()
            Button { store.newTab() } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 24, height: 24).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New Tab  ⌘T")
        }
        .padding(.leading, 78) // traffic lights
        .padding(.trailing, 10)
        .frame(height: 38)
        .background {
            Color.clear.contentShape(.rect)
                .gesture(WindowDragGesture())
                .simultaneousGesture(TapGesture(count: 2).onEnded(Self.titleBarDoubleClick))
        }
    }

    /// Honors System Settings › Desktop & Dock › "Double-click a window's title bar to".
    private static func titleBarDoubleClick() {
        guard let window = NSApp.keyWindow else { return }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }
}

private struct ProjectMenu: View {
    @Environment(Store.self) private var store
    @State private var renaming: Project?
    @State private var newName = ""

    var body: some View {
        // Worst state among the projects you're not looking at, so background agents stay visible.
        let others = store.projects.filter { $0 !== store.current }
            .compactMap(\.top).max { $0.state.urgency < $1.state.urgency }
        Menu {
            ForEach(Array(store.projects.enumerated()), id: \.element.id) { i, p in
                Toggle(p.name, isOn: Binding(get: { store.current === p }, set: { _ in store.gotoProject(i) }))
            }
            Divider()
            Button("Add Project…") { store.addProject() }
            if let p = store.current {
                Button("Rename Project…") { newName = p.name; renaming = p }
                Button("Change Folder…") { store.changeRoot(of: p) }
                Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: p.root) }
                Button("Close Project") { store.closeProject(p) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(store.current?.name ?? "Ghostline").font(.system(size: 12.5, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                if let others { StatusBadge(record: others) }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(store.current?.root ?? "")
        .alert("Rename Project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { renaming?.name = name }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct TabPill: View {
    @Environment(Store.self) private var store
    let tab: Tab
    let project: Project
    @State private var hovering = false

    var body: some View {
        let selected = project.selected === tab
        HStack(spacing: 6) {
            AgentIcon(app: tab.status.app)
            Text(tab.name)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 200, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            ZStack {
                if hovering {
                    Button { store.close(tab) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                } else if let top = tab.status.top {
                    StatusBadge(record: top)
                }
            }
            .frame(width: 12)
        }
        .foregroundStyle(selected ? .primary : .secondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
        .contentShape(Capsule())
        .onTapGesture { store.select(tab, in: project) }
        .onHover { hovering = $0 }
        .help(tab.status.top?.msg ?? tab.pwd)
        .contextMenu { Button("Close Tab") { store.close(tab) } }
    }
}

// MARK: Agents

/// Title-bar counts of agents by state across all projects; opens the agents list.
private struct AgentsButton: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        let tops = store.agents.compactMap(\.status.top)
        Button { store.showAgents.toggle() } label: {
            HStack(spacing: 8) {
                ForEach([AgentState.blocked, .error, .working, .done], id: \.self) { state in
                    let matching = tops.filter { $0.state == state }
                    if let first = matching.first {
                        HStack(spacing: 3) {
                            StatusBadge(record: first)
                            Text("\(matching.count)").font(.system(size: 11, weight: .medium).monospacedDigit())
                        }
                    }
                }
                if tops.allSatisfy({ $0.state == .idle }) {
                    Image(systemName: "sparkles").font(.system(size: 11, weight: .medium))
                    if !tops.isEmpty { Text("\(tops.count)").font(.system(size: 11, weight: .medium).monospacedDigit()) }
                }
            }
            .padding(.horizontal, 8).frame(height: 24).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Agents  ⌘⇧A")
        .popover(isPresented: $store.showAgents, arrowEdge: .bottom) {
            AgentList { store.showAgents = false }.frame(width: 380)
        }
    }
}

/// Every agent across projects, most urgent first. Click to jump; review its changes.
struct AgentList: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    var picked: (() -> Void)?

    var body: some View {
        let agents = store.agents.sorted {
            ($0.status.top?.state.urgency ?? 0, $1.since) > ($1.status.top?.state.urgency ?? 0, $0.since)
        }
        VStack(alignment: .leading, spacing: 2) {
            if agents.isEmpty {
                Text("No agents running").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(20)
            }
            ForEach(agents) { tab in
                AgentRow(tab: tab) {
                    store.focus(tab)
                    picked?() ?? dismiss()
                } review: {
                    openWindow(id: "review", value: tab.id)
                    picked?() ?? dismiss()
                }
            }
        }
        .padding(6)
    }
}

private struct AgentRow: View {
    let tab: Tab
    let open: () -> Void
    let review: () -> Void
    @State private var hovering = false

    var body: some View {
        let top = tab.status.top
        HStack(spacing: 8) {
            AgentIcon(app: tab.status.app)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(tab.project?.name ?? "").fontWeight(.semibold)
                    Text("· \(tab.name)").foregroundStyle(.secondary)
                }
                .font(.system(size: 12.5)).lineLimit(1)
                Text(top?.msg ?? top?.state.rawValue.capitalized ?? "")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let stat = tab.diffStat {
                Button(stat, action: review)
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                    .help("Review changes")
            }
            TimelineView(.periodic(from: .now, by: 10)) { ctx in
                Text(Self.elapsed(ctx.date.timeIntervalSince(tab.since)))
                    .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary)
            }
            if let top { StatusBadge(record: top).frame(width: 12) } else { Color.clear.frame(width: 12) }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
        .contentShape(.rect)
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Go to Tab", action: open)
            Button("Review Changes", action: review)
        }
    }

    static func elapsed(_ t: TimeInterval) -> String {
        t < 60 ? "now" : t < 3600 ? "\(Int(t / 60))m" : t < 86400 ? "\(Int(t / 3600))h" : "\(Int(t / 86400))d"
    }
}

// MARK: Command palette

/// ⌘P: jump to any tab or project, paste a snippet, or run an action, by typing a few letters.
private struct Palette: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var index = 0
    @FocusState private var focused: Bool

    struct Item: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: AnyView
        let run: () -> Void
    }

    var body: some View {
        @Bindable var store = store
        let query = store.paletteQuery
        let results = query.hasPrefix("/") || query.hasPrefix("~") ? folders(query) : Self.filter(items, query)
        VStack(spacing: 0) {
            TextField("Go to a tab or project, paste a snippet, run an action, or type a path…", text: $store.paletteQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .padding(12)
                .focused($focused)
                .onKeyPress(.downArrow) { index = min(index + 1, results.count - 1); return .handled }
                .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
                .onKeyPress(.tab) {
                    // Complete to the highlighted folder.
                    guard let item = results[safe: index], item.id.hasPrefix("dir-") else { return .ignored }
                    store.paletteQuery = item.title + "/"
                    return .handled
                }
                .onSubmit { if let item = results[safe: index] { run(item) } }
                .onChange(of: query) { index = 0 }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { i, item in
                            HStack(spacing: 8) {
                                item.icon.frame(width: 18)
                                Text(item.title).font(.system(size: 13)).lineLimit(1)
                                Text(item.subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(i == index ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
                            .contentShape(.rect)
                            .onTapGesture { run(item) }
                            .id(item.id)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: index) { proxy.scrollTo(results[safe: index]?.id) }
            }
        }
        .frame(width: 580)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
        .onAppear {
            store.loadSnippets()
            focused = true
        }
    }

    /// Tabs first (the common case), then projects, snippets, actions.
    private var items: [Item] {
        var items: [Item] = []
        for p in store.projects {
            for t in p.tabs {
                let top = t.status.top
                items.append(Item(id: "tab-\(t.id)", title: t.name, subtitle: [p.name, top?.msg].compactMap { $0 }.joined(separator: " · "),
                                  icon: AnyView(AgentIcon(app: t.status.app).overlay(alignment: .bottomTrailing) {
                                      if let top { StatusBadge(record: top).scaleEffect(0.8).offset(x: 4, y: 3) }
                                  })) { store.focus(t) })
            }
        }
        for (i, p) in store.projects.enumerated() {
            items.append(Item(id: "project-\(p.id)", title: p.name, subtitle: "Project", icon: Self.symbol("folder")) { store.gotoProject(i) })
        }
        for s in store.snippets {
            items.append(Item(id: "snippet-\(s.id)", title: s.title, subtitle: "Snippet", icon: Self.symbol("text.bubble")) {
                store.selectedTab?.paste(s.text)
            })
        }
        let tab = store.selectedTab
        items += [
            Item(id: "a-review", title: "Review Changes", subtitle: "⌘⇧R", icon: Self.symbol("plusminus")) {
                if let tab { openWindow(id: "review", value: tab.id) }
            },
            Item(id: "a-agents", title: "Show Agents", subtitle: "⌘⇧A", icon: Self.symbol("sparkles")) { store.showAgents = true },
            Item(id: "a-next", title: "Next Agent Needing You", subtitle: "⌥⌘J", icon: Self.symbol("bell")) { store.nextAttention() },
            Item(id: "a-tab", title: "New Tab", subtitle: "⌘T", icon: Self.symbol("plus")) { store.newTab() },
            Item(id: "a-open", title: "Add Project…", subtitle: "⌘⇧O", icon: Self.symbol("folder.badge.plus")) { store.addProject() },
            Item(id: "a-snippets", title: "Edit Snippets…", subtitle: "Opens the folder", icon: Self.symbol("square.and.pencil")) {
                NSWorkspace.shared.open(Store.snippetsDir)
            },
        ]
        return items
    }

    /// "~/dev/gh" lists folders in ~/dev starting with "gh"; a trailing "/" lists the folder itself first.
    private func folders(_ query: String) -> [Item] {
        let path = (query as NSString).expandingTildeInPath
        let dir = query.hasSuffix("/") ? path : (path as NSString).deletingLastPathComponent
        let prefix = query.hasSuffix("/") ? "" : (path as NSString).lastPathComponent.lowercased()
        let isDir = { (p: String) in
            var d: ObjCBool = false
            return FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue
        }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.lowercased().hasPrefix(prefix) && (!$0.hasPrefix(".") || prefix.hasPrefix(".")) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var paths = names.map { (dir as NSString).appendingPathComponent($0) }.filter(isDir)
        if query.hasSuffix("/"), isDir(path) { paths.insert(path, at: 0) }
        // Captured now: closing the palette clears it before the item runs.
        let changing = store.changingRoot
        return paths.prefix(50).map { p in
            let title = (p as NSString).abbreviatingWithTildeInPath
            if let changing {
                return Item(id: "dir-\(p)", title: title, subtitle: "Use for \(changing.name)", icon: Self.symbol("folder")) {
                    store.setRoot(p, of: changing)
                }
            }
            let open = store.projects.contains { ($0.root as NSString).standardizingPath == p }
            return Item(id: "dir-\(p)", title: title, subtitle: open ? "Open Project" : "Add Project",
                        icon: Self.symbol("folder")) { store.open(root: p) }
        }
    }

    private static func symbol(_ name: String) -> AnyView {
        AnyView(Image(systemName: name).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary))
    }

    /// Letters of the query in order (fuzzy), title prefix matches first.
    static func filter(_ items: [Item], _ query: String) -> [Item] {
        let q = query.lowercased().filter { !$0.isWhitespace }
        guard !q.isEmpty else { return items }
        let hits = items.filter { item in
            var rest = Substring(q)
            for ch in (item.title + " " + item.subtitle).lowercased() where ch == rest.first { rest = rest.dropFirst() }
            return rest.isEmpty
        }
        let prefix = { (i: Item) in i.title.lowercased().filter { !$0.isWhitespace }.hasPrefix(q) }
        return hits.filter(prefix) + hits.filter { !prefix($0) }
    }

    private func run(_ item: Item) {
        close()
        item.run()
    }

    private func close() {
        store.showPalette = false
        // Hand the keyboard back to the terminal.
        DispatchQueue.main.async {
            if let v = store.selectedTab.flatMap({ $0.focused ?? $0.leaves.first }) { v.window?.makeFirstResponder(v) }
        }
    }
}

// MARK: Terminal card

private struct TerminalCard: View {
    let tab: Tab

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                AgentIcon(app: tab.status.app)
                Text(tab.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if let name = tab.project?.name {
                    Text("· \(name)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4).padding(.bottom, 8)
            .help(tab.pwd)
            // Read here so SwiftUI tracks layout and focus changes.
            TerminalHost(tab: tab, layout: tab.root.signature, focused: tab.focused)
        }
    }
}

/// Icon for the program named by OSC 7501 `app`. Plain terminal when nothing reported.
struct AgentIcon: View {
    let app: String?

    var body: some View {
        let (symbol, color) = Self.style(app)
        Group {
            if NSImage(named: symbol) != nil {
                Image(symbol).resizable().scaledToFit().frame(width: 11, height: 11)
            } else {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
            }
        }
        .foregroundStyle(color)
        .frame(width: 16)
    }

    // Brand logos (simple-icons, CC0) live in Assets.xcassets; names without one fall back to SF Symbols.
    static func style(_ app: String?) -> (String, Color) {
        switch app?.lowercased() {
        case nil: ("chevron.right", .secondary)
        case "claude-code", "claude": ("claude", Color(red: 0.85, green: 0.47, blue: 0.34))
        case "codex": ("codex", .primary)
        case "gemini", "gemini-cli": ("gemini", .blue)
        case "opencode": ("chevron.left.forwardslash.chevron.right", .mint)
        case "aider": ("a.circle", .green)
        case "cursor", "cursor-agent": ("cursorarrow", .primary)
        default: ("gearshape.2", .secondary)
        }
    }
}

struct StatusBadge: View {
    let record: StatusRecord

    var body: some View {
        Group {
            switch record.state {
            case .blocked:
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.orange)
                    .symbolEffect(.pulse, options: .repeating)
            case .error:
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10)).foregroundStyle(.red)
            case .working:
                if let p = record.progress {
                    Circle().trim(from: 0, to: Double(p) / 100)
                        .stroke(.secondary, style: .init(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .background(Circle().stroke(.quaternary, lineWidth: 1.5))
                        .frame(width: 10, height: 10)
                } else {
                    ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12)
                }
            case .done:
                Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.green)
            case .idle, .clear:
                EmptyView()
            }
        }
        .transition(.scale.combined(with: .opacity))
        .animation(.spring(duration: 0.3), value: record.state)
        .help([record.app, record.kind, record.msg].compactMap { $0 }.joined(separator: " · "))
    }
}

private struct EmptyState: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "terminal").font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
            Button("New Tab  ⌘T") { store.newTab() }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Terminal host

/// Shows the selected tab's split tree. Other tabs' surfaces stay alive off-window.
private struct TerminalHost: NSViewRepresentable {
    let tab: Tab
    let layout: String
    let focused: SurfaceView?

    func makeNSView(context: Context) -> SplitHost { SplitHost() }
    func updateNSView(_ host: SplitHost, context: Context) { host.show(tab, layout: layout) }
}

private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

/// Layout snaps (one reflow per terminal, no stretched glyphs); new panes fade in and focus dimming cross-fades.
final class SplitHost: NSView {
    private var tab: Tab?
    private var layout = ""
    private var leaves: [ObjectIdentifier: LeafView] = [:]

    func show(_ tab: Tab, layout: String) {
        let sameTab = self.tab === tab
        if !sameTab || layout != self.layout || subviews.isEmpty {
            let old = sameTab ? leaves : [:]
            leaves = [:]
            subviews.forEach { $0.removeFromSuperview() }
            let root = build(tab.root, old, fade: sameTab && !reduceMotion)
            root.frame = bounds
            root.autoresizingMask = [.width, .height]
            addSubview(root)
            self.tab = tab
            self.layout = layout
        }
        updateDim(animated: sameTab)
        guard let target = tab.focused ?? tab.leaves.first else { return }
        DispatchQueue.main.async {
            if let w = target.window, w.firstResponder !== target { w.makeFirstResponder(target) }
        }
    }

    private func build(_ p: Pane, _ old: [ObjectIdentifier: LeafView], fade: Bool) -> NSView {
        if let v = p.view {
            let id = ObjectIdentifier(v)
            let leaf = old[id] ?? LeafView(v)
            if old[id] == nil && fade { leaf.fadeIn() }
            leaves[id] = leaf
            return leaf
        }
        let split = PaneSplitView(p)
        p.children.forEach { split.addSubview(build($0, old, fade: fade)) }
        return split
    }

    private func updateDim(animated: Bool) {
        let alpha = leaves.count > 1 ? Ghostty.shared.unfocusedSplit.alpha : 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated && !reduceMotion ? 0.15 : 0
            for leaf in leaves.values { leaf.dim.animator().alphaValue = leaf.surface === tab?.focused ? 0 : alpha }
        }
    }
}

/// A surface plus the overlay that dims it while unfocused.
final class LeafView: NSView {
    let surface: SurfaceView
    let dim = NSView()

    init(_ surface: SurfaceView) {
        self.surface = surface
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = Ghostty.shared.background.cgColor
        addSubview(surface)
        addSubview(dim)
        dim.wantsLayer = true
        dim.layer?.backgroundColor = Ghostty.shared.unfocusedSplit.fill.cgColor
        dim.alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Inset keeps text off the card edges; the dim still covers the whole card.
    override func layout() {
        super.layout()
        surface.frame = bounds.insetBy(dx: 12, dy: 10)
        dim.frame = bounds
    }

    /// Clicks pass through the dim overlay to the terminal.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === dim ? surface : v
    }

    func fadeIn() {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0
        a.toValue = 1
        a.duration = 0.18
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(a, forKey: "fadeIn")
    }
}

/// Native split with a transparent gap between pane cards; keeps its Pane's ratio in sync with drags and window resizes.
final class PaneSplitView: NSSplitView, NSSplitViewDelegate {
    private weak var pane: Pane?
    /// Ratio writes are ignored until the first real layout, so the initial zero-size pass can't clobber it.
    private var settled = false

    init(_ pane: Pane) {
        self.pane = pane
        super.init(frame: .zero)
        isVertical = pane.vertical
        dividerStyle = .thin
        delegate = self
        pane.splitView = self
    }

    required init?(coder: NSCoder) { fatalError() }

    override var dividerThickness: CGFloat { 10 }
    override func drawDivider(in rect: NSRect) {}

    var length: CGFloat { (isVertical ? bounds.width : bounds.height) - dividerThickness }

    func applyRatio() {
        guard let pane, length > 0 else { return }
        setPosition((pane.ratio * length).rounded(), ofDividerAt: 0)
        settled = true
    }

    override func layout() {
        super.layout()
        if !settled { applyRatio() }
    }

    func splitViewDidResizeSubviews(_ n: Notification) {
        guard settled, let pane, length > 0, let first = subviews.first else { return }
        pane.ratio = (isVertical ? first.frame.width : first.frame.height) / length
    }

    func splitView(_ s: NSSplitView, constrainMinCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat { p + 80 }
    func splitView(_ s: NSSplitView, constrainMaxCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat { p - 80 }
}

extension Pane {
    /// Changes when panes are added, removed or re-oriented; drives SplitHost rebuilds.
    var signature: String {
        if let view { return "\(ObjectIdentifier(view).hashValue)" }
        return "(\(vertical ? "|" : "-")\(children.map(\.signature).joined(separator: ",")))"
    }

    /// Ghostty's resize_split: move the nearest divider on that axis by `amount` points.
    func resize(_ r: ghostty_action_resize_split_s) {
        let sideways = r.direction == GHOSTTY_RESIZE_SPLIT_LEFT || r.direction == GHOSTTY_RESIZE_SPLIT_RIGHT
        var p = parent
        while let q = p, q.vertical != sideways { p = q.parent }
        guard let p, let s = p.splitView, s.length > 0 else { return }
        let sign: CGFloat = r.direction == GHOSTTY_RESIZE_SPLIT_RIGHT || r.direction == GHOSTTY_RESIZE_SPLIT_DOWN ? 1 : -1
        p.ratio = min(max(p.ratio + sign * CGFloat(r.amount) / s.length, 0.05), 0.95)
        s.applyRatio()
    }

    func equalize() {
        ratio = 0.5
        splitView?.applyRatio()
        children.forEach { $0.equalize() }
    }
}

// MARK: Menu

struct AppCommands: Commands {
    let store: Store
    @Environment(\.openWindow) private var openWindow

    private var focusedPane: SurfaceView? { store.selectedTab.flatMap { $0.focused ?? $0.leaves.first } }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { store.newTab() }.keyboardShortcut("t")
            Button("Add Project…") { store.addProject() }.keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            // Routed through Ghostty bindings so menu and keybind behave the same (cwd inherit, close confirm).
            Button("Split Right") { focusedPane?.splitRight(nil) }.keyboardShortcut("d")
            Button("Split Down") { focusedPane?.splitDown(nil) }.keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("Close Pane") { focusedPane?.closePane(nil) }.keyboardShortcut("w")
            Button("Close Tab") { if let t = store.selectedTab { store.close(t) } }.keyboardShortcut("w", modifiers: [.command, .option])
        }
        CommandMenu("Agents") {
            Button("Command Palette") { store.showPalette.toggle() }.keyboardShortcut("p")
            Divider()
            Button("Show Agents") { store.showAgents.toggle() }.keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Next Agent Needing You") { store.nextAttention() }.keyboardShortcut("j", modifiers: [.command, .option])  // ⌘J is Ghostty's scroll_to_selection
            Divider()
            Button("Review Changes") { if let t = store.selectedTab { openWindow(id: "review", value: t.id) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
        CommandMenu("Snippets") {
            ForEach(Array(store.snippets.prefix(9).enumerated()), id: \.element.id) { i, snippet in
                Button(snippet.title) { store.selectedTab?.paste(snippet.text) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option])
            }
            Divider()
            Button("Reload Snippets") { store.loadSnippets() }
            Button("Edit Snippets…") { NSWorkspace.shared.open(Store.snippetsDir) }
        }
        CommandMenu("Projects") {
            ForEach(0..<9, id: \.self) { i in
                Button(store.projects.indices.contains(i) ? store.projects[i].name : "Project \(i + 1)") { store.gotoProject(i) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .control])
                    .disabled(!store.projects.indices.contains(i))
            }
        }
    }
}
