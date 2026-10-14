import Foundation

/// OSC 7501 program status. Spec: https://www.superlogical.com/rex/docs/build/program-status
/// libghostty validates the body (limits, base64, ids) before it reaches us.
enum AgentState: String, Equatable {
    case idle, working, done, blocked, error, clear

    /// Higher wins when a tab or project shows one badge for many records.
    var urgency: Int {
        switch self {
        case .blocked: 5
        case .error: 4
        case .working: 3
        case .done: 2
        case .idle: 1
        case .clear: 0
        }
    }
}

struct StatusRecord: Equatable {
    var id = ""  // "" is the root record
    var state: AgentState
    var kind: String?
    var progress: Int?
    var app: String?
    var title: String?
    var msg: String?
    var updated = Date()

    /// Parses `state=working:app=cargo:msg=<base64>`.
    init?(body: String) {
        var kv: [Substring: Substring] = [:]
        for pair in body.split(separator: ":") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            kv[pair[..<eq]] = pair[pair.index(after: eq)...]  // last value wins
        }
        guard let s = kv["state"], let state = AgentState(rawValue: String(s)) else { return nil }
        self.state = state
        id = kv["id"].map(String.init) ?? ""
        kind = state == .blocked ? kv["kind"].map(String.init) : nil
        progress = kv["progress"].flatMap { Int($0) }.map { min(max($0, 0), 100) }
        app = kv["app"].map(String.init)
        title = kv["title"].flatMap(Self.text)
        msg = kv["msg"].flatMap(Self.text)
    }

    init(id: String = "", state: AgentState, progress: Int? = nil) {
        self.id = id
        self.state = state
        self.progress = progress
    }

    /// Base64 (padding optional) → plain text with control, bidi and invisible
    /// format characters stripped. Program text is untrusted.
    static func text(_ b64: Substring) -> String? {
        var s = String(b64)
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        guard let data = Data(base64Encoded: s), let str = String(data: data, encoding: .utf8) else { return nil }
        let clean = String(String.UnicodeScalarView(str.unicodeScalars.filter {
            $0.properties.generalCategory != .control && $0.properties.generalCategory != .format
        }))
        return clean.isEmpty ? nil : clean
    }
}

/// Every record one terminal holds, plus the spec's lifetime rules.
struct StatusBoard: Equatable {
    private(set) var records: [String: StatusRecord] = [:]
    static let cap = 256

    mutating func apply(_ r: StatusRecord) {
        guard r.state == .clear else {
            records[r.id] = r
            if records.count > Self.cap, let oldest = records.values.min(by: { $0.updated < $1.updated }) {
                records[oldest.id] = nil
            }
            return
        }
        if r.id.isEmpty { records.removeAll(); return }
        records = records.filter { $0.key != r.id && !$0.key.hasPrefix(r.id + "/") }
    }

    /// The program exited or a new prompt began: drop live states, keep results.
    mutating func processEnded() {
        records = records.filter { $0.value.state == .done || $0.value.state == .error }
    }

    /// The user looked at the tab, so "done" results have been seen. The agent is still
    /// there, so it drops to idle rather than vanishing from the agents list.
    mutating func markSeen() {
        for (k, r) in records where r.state == .done { records[k]?.state = .idle }
    }

    /// The record to show on the tab badge.
    var top: StatusRecord? {
        records.values.max { ($0.state.urgency, $0.updated) < ($1.state.urgency, $1.updated) }
    }

    /// The program name for the tab icon. Children inherit `app` from ancestors, so
    /// the root (or any record) naming an app is enough.
    var app: String? {
        top?.app ?? records[""]?.app ?? records.values.lazy.compactMap(\.app).first
    }
}
