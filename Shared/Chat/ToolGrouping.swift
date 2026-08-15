import Foundation

/// Codex-style presentation model for tool activity: consecutive tool calls
/// collapse into one summary line ("Read files, ran commands") with a single
/// live line while one is running, and every tool renders as a one-line
/// headline ("Ran git status") instead of a multi-line card. Grouping is a
/// pure function of the item list so the transcript and the iOS stack agree.
enum TranscriptEntry: Identifiable {
    case item(ConversationItem)
    case toolGroup(ToolGroup)

    var id: String {
        switch self {
        case .item(let item): item.id
        case .toolGroup(let group): group.id
        }
    }

    /// Runs of `minimumGroupSize`+ consecutive tool items become one group;
    /// everything else passes through unchanged. Callers filter noise first so
    /// a hidden row can never split a run.
    static func entries(
        of items: some Sequence<ConversationItem>,
        minimumGroupSize: Int = 2
    ) -> [TranscriptEntry] {
        var entries: [TranscriptEntry] = []
        var run: [ConversationItem] = []

        func flushRun() {
            guard !run.isEmpty else { return }
            if run.count >= minimumGroupSize {
                entries.append(.toolGroup(ToolGroup(items: run)))
            } else {
                entries.append(contentsOf: run.map(TranscriptEntry.item))
            }
            run.removeAll(keepingCapacity: true)
        }

        for item in items {
            if case .tool = item {
                run.append(item)
            } else {
                flushRun()
                entries.append(.item(item))
            }
        }
        flushRun()
        return entries
    }
}

/// A maximal run of consecutive tool items. Identity comes from the first
/// member so the group survives streaming appends without resetting its
/// expansion state.
struct ToolGroup: Identifiable {
    let items: [ConversationItem]

    var id: String { "toolgroup:\(items.first?.id ?? "empty")" }

    var tools: [ToolActivity] {
        items.compactMap {
            if case .tool(let tool) = $0 { return tool }
            return nil
        }
    }

    var hasFailure: Bool {
        tools.contains { $0.status == .failed }
    }

    /// The most recently started member still executing; drives the live
    /// line under a collapsed group.
    var runningTool: ToolActivity? {
        tools.last { $0.status == .running || $0.status == .pending }
    }

    /// Most frequent member kind, ties broken by first appearance, for the
    /// group icon.
    var dominantKind: ToolActivityKind {
        var counts: [ToolActivityKind: Int] = [:]
        var order: [ToolActivityKind] = []
        for tool in tools {
            if counts[tool.kind] == nil { order.append(tool.kind) }
            counts[tool.kind, default: 0] += 1
        }
        return order.max { lhs, rhs in
            let lhsCount = counts[lhs] ?? 0
            let rhsCount = counts[rhs] ?? 0
            if lhsCount != rhsCount { return lhsCount < rhsCount }
            // Stable max: keep the earlier kind on ties.
            return (order.firstIndex(of: lhs) ?? 0) > (order.firstIndex(of: rhs) ?? 0)
        } ?? .generic
    }

    /// "Read files, ran commands" — one phrase per member kind, ordered by
    /// first appearance, count-aware.
    var summaryText: String {
        var counts: [ToolActivityKind: Int] = [:]
        var order: [ToolActivityKind] = []
        for tool in tools {
            // MCP and generic tools read the same to users; merge their phrase.
            let kind = tool.kind == .mcp ? .generic : tool.kind
            if counts[kind] == nil { order.append(kind) }
            counts[kind, default: 0] += 1
        }
        let phrases = order.map { kind in
            Self.summaryPhrase(kind: kind, count: counts[kind] ?? 0)
        }
        guard let first = phrases.first else { return "Used tools" }
        let joined = ([first.capitalizedFirst] + phrases.dropFirst()).joined(separator: ", ")
        return joined
    }

    private static func summaryPhrase(kind: ToolActivityKind, count: Int) -> String {
        switch kind {
        case .shell: count == 1 ? "ran a command" : "ran commands"
        case .fileRead: count == 1 ? "read a file" : "read files"
        case .search: "searched"
        case .edit: count == 1 ? "edited a file" : "edited files"
        case .web: count == 1 ? "fetched a page" : "fetched pages"
        case .plan: "updated the plan"
        case .mcp, .generic: count == 1 ? "used a tool" : "used tools"
        }
    }
}

/// Collapsed summary line for a run of consecutive tool calls.
struct ToolGroupHeaderModel: Equatable {
    let groupID: String
    let summary: String
    let symbol: String
    let hasFailure: Bool
    let isExpanded: Bool

    var id: String { "\(groupID):header" }
}

/// The single live line under a collapsed group while a member tool runs.
/// Its text swaps in place as tools start and finish; the row itself keeps a
/// fixed single-line height so streaming never moves the transcript.
struct ToolGroupLiveModel: Equatable {
    let groupID: String
    let headline: String

    var id: String { "\(groupID):live" }
}

extension ToolGroup {
    func headerModel(isExpanded: Bool) -> ToolGroupHeaderModel {
        ToolGroupHeaderModel(
            groupID: id,
            summary: summaryText,
            symbol: dominantKind.symbolName,
            hasFailure: hasFailure,
            isExpanded: isExpanded
        )
    }
}

extension ToolActivityKind {
    var symbolName: String {
        switch self {
        case .shell: "terminal"
        case .fileRead: "doc.text"
        case .search: "magnifyingglass"
        case .edit: "pencil.and.outline"
        case .mcp: "shippingbox"
        case .web: "globe"
        case .plan: "checklist"
        case .generic: "wrench.and.screwdriver"
        }
    }
}

extension ToolActivity {
    /// One-line, Codex-style description: verb + the most salient input
    /// detail ("Ran git status", "Reading checkout.js"). Falls back to the
    /// provider title when the input carries nothing extractable.
    var compactHeadline: String {
        let isActive = status == .running || status == .pending
        switch kind {
        case .shell:
            if let command = inputDetail(keys: ["command", "cmd"]) {
                return "\(isActive ? "Running" : "Ran") \(command)"
            }
        case .fileRead:
            if let path = inputDetail(keys: ["file_path", "path", "filePath", "file"]) {
                return "\(isActive ? "Reading" : "Read") \(Self.displayName(forPath: path))"
            }
        case .edit:
            if let path = inputDetail(keys: ["file_path", "path", "filePath", "file"]) {
                return "\(isActive ? "Editing" : "Edited") \(Self.displayName(forPath: path))"
            }
        case .search:
            if let pattern = inputDetail(keys: ["pattern", "query", "q"]) {
                return "\(isActive ? "Searching" : "Searched") for \(pattern)"
            }
        case .web:
            if let url = inputDetail(keys: ["url", "query", "prompt"]) {
                return "\(isActive ? "Fetching" : "Fetched") \(Self.displayName(forURL: url))"
            }
        case .plan:
            return isActive ? "Updating the plan" : "Updated the plan"
        case .mcp, .generic:
            break
        }
        // A title that is already a phrase (Codex emits sentences, MCP tools
        // carry their own names) beats a generic verb.
        if title.contains(" ") || kind == .mcp || kind == .generic,
           let line = Self.flattenedLine(title) {
            return line
        }
        switch kind {
        case .shell: return isActive ? "Running a command" : "Ran a command"
        case .fileRead: return isActive ? "Reading a file" : "Read a file"
        case .edit: return isActive ? "Editing a file" : "Edited a file"
        case .search: return isActive ? "Searching" : "Searched"
        case .web: return isActive ? "Fetching a page" : "Fetched a page"
        case .plan, .mcp, .generic:
            return Self.flattenedLine(title)
                ?? (isActive ? "Using a tool" : "Used a tool")
        }
    }

    /// Status suffix for the compact line; only outcomes worth a glance
    /// ("failed", "exit 1", "cancelled") — success stays silent.
    var compactOutcome: String? {
        switch status {
        case .failed:
            if let exitCode, exitCode != 0 { return "exit \(exitCode)" }
            return "failed"
        case .cancelled:
            return "cancelled"
        case .completed, .running, .pending:
            if let exitCode, exitCode != 0 { return "exit \(exitCode)" }
            return nil
        }
    }

    /// First matching string value from the JSON input object. Providers
    /// serialize tool input as a compact JSON object; a raw non-JSON input is
    /// itself the detail (Codex command strings).
    private func inputDetail(keys: [String]) -> String? {
        guard let input, !input.isEmpty else { return nil }
        guard input.utf8.count <= 32 * 1024 else { return nil }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else {
            return Self.flattenedLine(trimmed)
        }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        for key in keys {
            if let value = dictionary[key] as? String,
               let line = Self.flattenedLine(value) {
                return line
            }
        }
        return nil
    }

    private static func displayName(forPath path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    private static func displayName(forURL value: String) -> String {
        guard let url = URL(string: value), let host = url.host else {
            return value
        }
        return host
    }

    /// Whitespace-normalized single line, bounded by characters AND bytes —
    /// a dense extended grapheme cluster can hide kilobytes in few
    /// characters, and headlines end up in fixed-height table rows.
    private static func flattenedLine(
        _ value: String,
        maximumCharacters: Int = 200,
        maximumBytes: Int = 512
    ) -> String? {
        let flattened = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !flattened.isEmpty else { return nil }
        var bounded = TranscriptTextProjection.boundedUTF8Prefix(
            flattened,
            maximumBytes: maximumBytes
        )
        if bounded.count > maximumCharacters {
            bounded = String(bounded.prefix(maximumCharacters))
        }
        guard !bounded.isEmpty else { return nil }
        return bounded == flattened ? bounded : bounded + "…"
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
