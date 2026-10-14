import AppKit
import SwiftUI
import WebKit

enum Git {
    /// Runs git in `dir`; nil when it fails (not a repo, unknown ref, …).
    static func data(_ args: [String], in dir: String) -> Data? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(filePath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()  // before wait, or a full pipe deadlocks
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }

    static func run(_ args: [String], in dir: String) -> String? {
        data(args, in: dir).map { String(decoding: $0, as: UTF8.self) }
    }

    /// "+12 −3" for uncommitted changes vs HEAD; nil when clean or not a repo.
    /// ponytail: untracked files aren't counted; the review window lists them.
    static func shortstat(in dir: String) -> String? {
        guard let s = run(["diff", "--shortstat", "HEAD"], in: dir), !s.isEmpty else { return nil }
        let n = { (word: String) in s.firstMatch(of: try! Regex("(\\d+) \(word)")).map { Int($0.output[1].substring!)! } ?? 0 }
        return "+\(n("insertion")) −\(n("deletion"))"
    }
}

/// One review window: the changes in a tab's repo against a base ref, shown in Monaco's diff editor.
@Observable
final class Review {
    struct File: Identifiable {
        var id: String { path }
        let path: String
        let status: Character  // M, A, D, or ? for untracked
        var added: Int?
        var removed: Int?
    }

    struct Comment: Identifiable {
        let id = UUID()
        let path: String
        let start: Int, end: Int
        let code: String
        let text: String
        var lines: String { start == end ? "\(start)" : "\(start)-\(end)" }
    }

    weak var tab: Tab?
    var root: String?
    var base = "HEAD"
    var files: [File] = []
    var selected: String?
    var comments: [Comment] = []
    var sideBySide = true { didSet { js("diff.updateOptions({ renderSideBySide: \(sideBySide) })") } }
    var error: String?

    @ObservationIgnored let web: WKWebView
    /// What Monaco shows now, so a refresh with unchanged contents doesn't reset scroll and cursor.
    @ObservationIgnored private var shown: [String]?
    /// Monaco loads asynchronously; calls before it posts "ready" would hit an empty page.
    @ObservationIgnored private var ready = false

    init(tab: Tab) {
        self.tab = tab
        let cfg = WKWebViewConfiguration()
        web = WKWebView(frame: .zero, configuration: cfg)
        web.setValue(false, forKey: "drawsBackground")
        web.isInspectable = true
        cfg.userContentController.add(ScriptHandler { [weak self] in self?.receive($0) }, name: "ghostline")
        if let page = Bundle.main.url(forResource: "review", withExtension: "html") {
            web.loadFileURL(page, allowingReadAccessTo: Bundle.main.resourceURL!)
        }
    }

    // MARK: Git

    /// ponytail: git runs on the main thread; fine for normal repos, move off-main if a monorepo stutters.
    func reload() {
        guard let tab else { return }
        root = Git.run(["rev-parse", "--show-toplevel"], in: tab.pwd)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root else { (files, error) = ([], "Not a git repository"); return }
        guard let status = Git.run(["diff", "--name-status", "--no-renames", "-z", base], in: root) else {
            (files, error) = ([], "Can't diff against “\(base)”"); return
        }
        error = nil
        let fields = status.split(separator: "\0")
        var files = stride(from: 0, to: fields.count - 1, by: 2).map {
            File(path: String(fields[$0 + 1]), status: fields[$0].first ?? "M")
        }
        // numstat -z: "added\tremoved\tpath\0"; binary files show "-".
        for rec in (Git.run(["diff", "--numstat", "--no-renames", "-z", base], in: root) ?? "").split(separator: "\0") {
            let c = rec.split(separator: "\t", maxSplits: 2)
            guard c.count == 3, let i = files.firstIndex(where: { $0.path == c[2] }) else { continue }
            files[i].added = Int(c[0])
            files[i].removed = Int(c[1])
        }
        files += (Git.run(["ls-files", "--others", "--exclude-standard", "-z"], in: root) ?? "")
            .split(separator: "\0").map { File(path: String($0), status: "?") }
        self.files = files.sorted { $0.path < $1.path }
        if !self.files.contains(where: { $0.path == selected }) { selected = self.files.first?.path }
        show()
    }

    func show() {
        guard let root, let path = selected, let f = files.first(where: { $0.path == path }) else { return }
        let original = "?A".contains(f.status) ? Data() : Git.data(["show", "\(base):\(path)"], in: root) ?? Data()
        let modified = f.status == "D" ? Data() : (try? Data(contentsOf: url(path))) ?? Data()
        let binary = [original, modified].contains { $0.count > 2_000_000 || $0.contains(0) }
        let o = binary ? "Binary or large file" : String(decoding: original, as: UTF8.self)
        let m = binary ? "Binary or large file" : String(decoding: modified, as: UTF8.self)
        guard ready, [path, o, m] != shown else { return }
        shown = [path, o, m]
        call("show(f)", ["f": ["path": path, "original": o, "modified": m, "readOnly": binary || f.status == "D",
                               "marks": marks(path)]])
    }

    /// Restores the selected file to `base`; files that didn't exist there go to the Trash.
    func revert() {
        guard let root, let f = files.first(where: { $0.path == selected }),
              Ghostty.confirm("Discard changes to \(f.path)?", "It goes back to \(base). New files are moved to the Trash.") else { return }
        if "?A".contains(f.status) {
            _ = Git.run(["rm", "--cached", "-q", "--ignore-unmatch", "--", f.path], in: root)
            try? FileManager.default.trashItem(at: url(f.path), resultingItemURL: nil)
        } else {
            _ = Git.run(["restore", "--source", base, "--staged", "--worktree", "--", f.path], in: root)
        }
        reload()
    }

    private func url(_ path: String) -> URL { URL(filePath: root ?? "/").appending(path: path) }

    // MARK: Comments → agent

    /// Pastes the comments into the agent's terminal (not submitted, so you can add to it) and switches to it.
    func send() {
        guard let tab, !comments.isEmpty else { return }
        var s = "Review comments on your changes:\n"
        for c in comments {
            let lines = c.code.split(separator: "\n", omittingEmptySubsequences: false).prefix(5)
            let indent = lines.filter { !$0.allSatisfy(\.isWhitespace) }.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
            let code = lines.map { "  > \($0.dropFirst(min(indent, $0.count)))" }
            s += "\n\(c.path):\(c.lines)\n\(code.joined(separator: "\n"))\n  \(c.text)\n"
        }
        tab.paste(s)
        comments = []
        pushMarks()
    }

    func remove(_ c: Comment) {
        comments.removeAll { $0.id == c.id }
        pushMarks()
    }

    private func marks(_ path: String) -> [[String: Int]] {
        comments.filter { $0.path == path }.map { ["start": $0.start, "end": $0.end] }
    }

    private func pushMarks() { if let selected { call("setMarks(m)", ["m": marks(selected)]) } }

    // MARK: Web bridge

    private func receive(_ body: Any) {
        if (body as? [String: Any])?["type"] as? String == "ready" {
            ready = true
            return show()
        }
        guard let m = body as? [String: Any], let path = m["path"] as? String,
              files.contains(where: { $0.path == path }) else { return }
        switch m["type"] as? String {
        case "save":
            guard let text = m["text"] as? String else { return }
            do {
                try text.write(to: url(path), atomically: true, encoding: .utf8)
                shown?[2] = text  // Monaco already shows it; don't reload over the cursor
                reload()
            } catch {
                NSAlert(error: error).runModal()
            }
        case "comment":
            guard let text = m["text"] as? String, let start = m["start"] as? Int, let end = m["end"] as? Int else { return }
            comments.append(Comment(path: path, start: start, end: end, code: m["code"] as? String ?? "", text: text))
            pushMarks()
        default: break
        }
    }

    private func call(_ js: String, _ args: [String: Any]) {
        guard ready else { return }
        web.callAsyncJavaScript(js, arguments: args, in: nil, in: .page) { _ in }
    }

    private func js(_ s: String) { web.evaluateJavaScript("window.diff && \(s)") }
}

/// WKUserContentController retains its handlers; this keeps it from retaining the Review.
private final class ScriptHandler: NSObject, WKScriptMessageHandler {
    let receive: (Any) -> Void
    init(_ receive: @escaping (Any) -> Void) { self.receive = receive }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { receive(m.body) }
}

// MARK: Views

struct ReviewWindow: View {
    @State private var review: Review?

    init(tab: Tab?) { _review = State(initialValue: tab.map(Review.init)) }

    var body: some View {
        if let review {
            ReviewView(review: review)
        } else {
            ContentUnavailableView("Tab closed", systemImage: "terminal")
        }
    }
}

private struct ReviewView: View {
    @Bindable var review: Review

    var body: some View {
        NavigationSplitView {
            List(selection: $review.selected) {
                Section("Changes") {
                    ForEach(review.files) { FileRow(file: $0).tag(Optional($0.path)) }
                }
                if !review.comments.isEmpty {
                    Section("Comments") {
                        ForEach(review.comments) { c in
                            CommentRow(comment: c) { review.remove(c) }
                                .onTapGesture { review.selected = c.path }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 260)
        } detail: {
            WebHost(web: review.web)
                .overlay {
                    if review.files.isEmpty {
                        ContentUnavailableView(review.error ?? "No changes", systemImage: review.error == nil ? "checkmark.circle" : "exclamationmark.triangle",
                                               description: Text(review.error == nil ? "Working tree matches \(review.base)" : ""))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.background)
                    }
                }
        }
        .navigationTitle(review.tab.map { "Review · \($0.project?.name ?? "") · \($0.name)" } ?? "Review")
        .navigationSubtitle(review.files.isEmpty ? "" : "\(review.files.count) files · ⌘↩ on a selection to comment, ⌘S to save")
        .toolbar {
            ToolbarItemGroup {
                TextField("Base", text: $review.base)
                    .frame(width: 110)
                    .onSubmit { review.reload() }
                    .help("Compare against this ref (HEAD, main, a commit…)")
                Button("Refresh", systemImage: "arrow.clockwise") { review.reload() }
                    .keyboardShortcut("r")
                Picker("Layout", selection: $review.sideBySide) {
                    Image(systemName: "rectangle.split.2x1").tag(true)
                    Image(systemName: "rectangle").tag(false)
                }
                .pickerStyle(.segmented)
                .help("Side by side / inline")
                Button("Open", systemImage: "arrow.up.forward.app") {
                    if let root = review.root, let s = review.selected { NSWorkspace.shared.open(URL(filePath: root).appending(path: s)) }
                }
                .help("Open in the default editor")
                .disabled(review.selected == nil)
                Button("Discard", systemImage: "arrow.uturn.backward") { review.revert() }
                    .help("Discard this file's changes")
                    .disabled(review.selected == nil)
                Button { review.send() } label: {
                    Label("Send \(review.comments.count) to Agent", systemImage: "paperplane.fill").labelStyle(.titleAndIcon)
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(review.comments.isEmpty)
                .help("Paste the comments into the agent's terminal  ⌘⇧↩")
            }
        }
        .onAppear { review.reload() }
        .onChange(of: review.selected) { review.show() }
        // The agent changed state (finished a turn, needs you): its edits may have landed.
        .onChange(of: review.tab?.since) { review.reload() }
    }
}

private struct FileRow: View {
    let file: Review.File

    var body: some View {
        let name = (file.path as NSString).lastPathComponent
        let dir = (file.path as NSString).deletingLastPathComponent
        HStack(spacing: 6) {
            Text(file.status == "?" ? "U" : String(file.status))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(file.status == "D" ? .red : file.status == "M" ? .orange : .green)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).lineLimit(1).strikethrough(file.status == "D")
                if !dir.isEmpty { Text(dir).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
            }
            Spacer(minLength: 4)
            if let a = file.added, let r = file.removed {
                HStack(spacing: 3) {
                    Text("+\(a)").foregroundStyle(.green)
                    Text("−\(r)").foregroundStyle(.red)
                }
                .font(.system(size: 10, design: .monospaced))
            }
        }
        .help(file.path)
    }
}

private struct CommentRow: View {
    let comment: Review.Comment
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\((comment.path as NSString).lastPathComponent):\(comment.lines)")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Text(comment.text).lineLimit(3)
            }
            Spacer(minLength: 0)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .contentShape(.rect)
    }
}

private struct WebHost: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ v: WKWebView, context: Context) {}
}
