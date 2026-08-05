import Foundation

enum TranscriptProjectionDirection: Sendable {
    case head
    case tail
}

struct TranscriptTextMetrics: Equatable, Sendable {
    let byteCount: Int
    let lineCount: Int

    init(_ text: String) {
        byteCount = text.utf8.count
        lineCount = text.isEmpty
            ? 0
            : text.utf8.reduce(into: 1) { count, byte in
                if byte == 0x0A { count += 1 }
            }
    }

    func appending(_ text: String) -> TranscriptTextMetrics {
        let appended = TranscriptTextMetrics(text)
        guard lineCount > 0 else { return appended }
        guard appended.lineCount > 0 else { return self }
        return TranscriptTextMetrics(
            byteCount: byteCount + appended.byteCount,
            lineCount: lineCount + appended.lineCount - 1
        )
    }

    private init(byteCount: Int, lineCount: Int) {
        self.byteCount = byteCount
        self.lineCount = lineCount
    }
}

struct TranscriptTextProjection: Equatable, Sendable {
    let text: String
    let sourceByteCount: Int
    let sourceLineCount: Int
    let hiddenByteCount: Int
    let hiddenLineCount: Int
    let inspectedByteCount: Int

    var isTruncated: Bool { hiddenByteCount > 0 || hiddenLineCount > 0 }

    static func make(
        _ source: String,
        direction: TranscriptProjectionDirection,
        maximumBytes: Int,
        maximumLines: Int,
        metrics: TranscriptTextMetrics? = nil
    ) -> TranscriptTextProjection {
        let resolvedMetrics = metrics ?? TranscriptTextMetrics(source)
        let metricInspectionBytes = metrics == nil ? resolvedMetrics.byteCount : 0
        guard maximumBytes > 0, maximumLines > 0, !source.isEmpty else {
            return TranscriptTextProjection(
                text: "",
                sourceByteCount: resolvedMetrics.byteCount,
                sourceLineCount: resolvedMetrics.lineCount,
                hiddenByteCount: resolvedMetrics.byteCount,
                hiddenLineCount: resolvedMetrics.lineCount,
                inspectedByteCount: metricInspectionBytes
            )
        }
        guard resolvedMetrics.byteCount > maximumBytes
                || resolvedMetrics.lineCount > maximumLines else {
            return TranscriptTextProjection(
                text: source,
                sourceByteCount: resolvedMetrics.byteCount,
                sourceLineCount: resolvedMetrics.lineCount,
                hiddenByteCount: 0,
                hiddenLineCount: 0,
                inspectedByteCount: max(metricInspectionBytes, resolvedMetrics.byteCount)
            )
        }

        let displayed: String
        var inspectedByteCount = metricInspectionBytes
        let utf8 = source.utf8
        switch direction {
        case .head:
            var byteCount = 0
            var lineCount = 1
            var end = utf8.startIndex
            while end < utf8.endIndex, byteCount < maximumBytes {
                let byte = utf8[end]
                guard byte != 0x0A || lineCount < maximumLines else {
                    break
                }
                end = utf8.index(after: end)
                byteCount += 1
                inspectedByteCount += 1
                if byte == 0x0A { lineCount += 1 }
            }
            if end < utf8.endIndex, utf8[end] & 0xC0 == 0x80 {
                repeat {
                    end = utf8.index(before: end)
                } while end > utf8.startIndex && utf8[end] & 0xC0 == 0x80
            }
            displayed = String(decoding: utf8[..<end], as: UTF8.self)
        case .tail:
            var byteCount = 0
            var lineCount = 1
            var start = utf8.endIndex
            while start > utf8.startIndex, byteCount < maximumBytes {
                let previous = utf8.index(before: start)
                let byte = utf8[previous]
                guard byte != 0x0A || lineCount < maximumLines else {
                    break
                }
                start = previous
                byteCount += 1
                inspectedByteCount += 1
                if byte == 0x0A { lineCount += 1 }
            }
            while start < utf8.endIndex, utf8[start] & 0xC0 == 0x80 {
                start = utf8.index(after: start)
            }
            displayed = String(decoding: utf8[start...], as: UTF8.self)
        }

        let displayedMetrics = TranscriptTextMetrics(displayed)
        return TranscriptTextProjection(
            text: displayed,
            sourceByteCount: resolvedMetrics.byteCount,
            sourceLineCount: resolvedMetrics.lineCount,
            hiddenByteCount: max(0, resolvedMetrics.byteCount - displayedMetrics.byteCount),
            hiddenLineCount: max(0, resolvedMetrics.lineCount - displayedMetrics.lineCount),
            inspectedByteCount: inspectedByteCount
        )
    }
}

enum TranscriptSourcePart: Hashable, Sendable {
    case messageContent(String)
    case reasoning
    case toolInput
    case toolOutput
    case toolError
    case diff
    case plan
    case genericDetail
}

struct TranscriptSourceHandle: Hashable, Sendable, Identifiable {
    let itemID: String
    let part: TranscriptSourcePart
    let title: String
    let contentType: String
    let isTruncatedAtSource: Bool
    let originalByteCount: Int?

    var id: String { "\(itemID):\(String(describing: part))" }
}

struct TranscriptFullContent: Equatable, Identifiable, Sendable {
    let handle: TranscriptSourceHandle
    let text: String
    let retainedByteCount: Int
    let retainedLineCount: Int

    var id: String { handle.id }
}

struct TranscriptRowProjection: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable {
        case message
        case reasoning
        case tool
        case diff
        case plan
        case generic
    }

    static let maximumDisplayBytes = 64 * 1_024
    static let maximumDisplayLines = 120

    let id: String
    let sourceItemID: String
    let kind: Kind
    let contentRevision: UInt64
    let displayItem: ConversationItem
    let hiddenByteCount: Int
    let hiddenLineCount: Int
    let sourceHandles: [TranscriptSourceHandle]
    let accessibilitySummary: String

    var isTruncated: Bool { hiddenByteCount > 0 || hiddenLineCount > 0 }

    static func make(
        item: ConversationItem,
        contentRevision: UInt64,
        metricsBySource: [TranscriptSourcePart: TranscriptTextMetrics] = [:]
    ) -> TranscriptRowProjection {
        var remainingBytes = maximumDisplayBytes
        var remainingLines = maximumDisplayLines
        var hiddenBytes = 0
        var hiddenLines = 0
        var handles: [TranscriptSourceHandle] = []

        func project(
            _ text: String,
            direction: TranscriptProjectionDirection,
            sourcePart: TranscriptSourcePart? = nil
        ) -> TranscriptTextProjection {
            let result = TranscriptTextProjection.make(
                text,
                direction: direction,
                maximumBytes: remainingBytes,
                maximumLines: remainingLines,
                metrics: sourcePart.flatMap { metricsBySource[$0] }
            )
            let displayed = TranscriptTextMetrics(result.text)
            remainingBytes = max(0, remainingBytes - displayed.byteCount)
            remainingLines = max(0, remainingLines - displayed.lineCount)
            hiddenBytes += result.hiddenByteCount
            hiddenLines += result.hiddenLineCount
            return result
        }

        let displayItem: ConversationItem
        let kind: Kind
        let summary: String
        switch item {
        case .message(var message):
            kind = .message
            summary = message.role == .user ? "You" : "Assistant"
            let direction: TranscriptProjectionDirection =
                message.role == .user ? .head : .tail
            var projectedContents: [MessageContent] = []
            for var content in message.contents {
                let part = TranscriptSourcePart.messageContent(content.id)
                let result = project(
                    content.text,
                    direction: direction,
                    sourcePart: part
                )
                content.text = result.text
                if result.isTruncated {
                    handles.append(
                        TranscriptSourceHandle(
                            itemID: message.id,
                            part: part,
                            title: message.role == .user ? "Message" : "Assistant response",
                            contentType: content.kind == .code ? "Code" : "Message",
                            isTruncatedAtSource: content.isTruncated,
                            originalByteCount: content.originalByteCount
                        )
                    )
                }
                projectedContents.append(content)
            }
            message.contents = projectedContents
            displayItem = .message(message)
        case .reasoning(var reasoning):
            kind = .reasoning
            summary = reasoning.isStreaming ? "Thinking" : "Reasoning summary"
            let result = project(
                reasoning.text,
                direction: .tail,
                sourcePart: .reasoning
            )
            reasoning.text = result.text
            if result.isTruncated {
                handles.append(
                    TranscriptSourceHandle(
                        itemID: reasoning.id,
                        part: .reasoning,
                        title: "Reasoning summary",
                        contentType: "Reasoning",
                        isTruncatedAtSource: false,
                        originalByteCount: nil
                    )
                )
            }
            displayItem = .reasoning(reasoning)
        case .tool(var tool):
            kind = .tool
            summary = tool.title
            tool.title = project(tool.title, direction: .head).text
            if let input = tool.input {
                let result = project(input, direction: .head, sourcePart: .toolInput)
                tool.input = result.text
                if result.isTruncated {
                    handles.append(
                        TranscriptSourceHandle(
                            itemID: tool.id,
                            part: .toolInput,
                            title: "\(tool.title) input",
                            contentType: "Tool input",
                            isTruncatedAtSource: tool.isTruncated,
                            originalByteCount: tool.originalByteCount
                        )
                    )
                }
            }
            if let output = tool.output {
                let result = project(
                    output,
                    direction: tool.status == .running ? .tail : .head,
                    sourcePart: .toolOutput
                )
                tool.output = result.text
                if result.isTruncated {
                    handles.append(
                        TranscriptSourceHandle(
                            itemID: tool.id,
                            part: .toolOutput,
                            title: "\(tool.title) output",
                            contentType: "Tool output",
                            isTruncatedAtSource: tool.isTruncated,
                            originalByteCount: tool.originalByteCount
                        )
                    )
                }
            }
            if let error = tool.errorMessage {
                let result = project(error, direction: .tail, sourcePart: .toolError)
                tool.errorMessage = result.text
                if result.isTruncated {
                    handles.append(
                        TranscriptSourceHandle(
                            itemID: tool.id,
                            part: .toolError,
                            title: "\(tool.title) error",
                            contentType: "Tool error",
                            isTruncatedAtSource: tool.isTruncated,
                            originalByteCount: tool.originalByteCount
                        )
                    )
                }
            }
            displayItem = .tool(tool)
        case .diff(var diff):
            kind = .diff
            summary = diff.path ?? "File changes"
            if let path = diff.path {
                diff.path = project(path, direction: .head).text
            }
            let result = project(diff.unifiedDiff, direction: .head, sourcePart: .diff)
            diff.unifiedDiff = result.text
            if result.isTruncated {
                handles.append(
                    TranscriptSourceHandle(
                        itemID: diff.id,
                        part: .diff,
                        title: diff.path ?? "File changes",
                        contentType: "Diff",
                        isTruncatedAtSource: diff.isTruncated,
                        originalByteCount: nil
                    )
                )
            }
            displayItem = .diff(diff)
        case .plan(var plan):
            kind = .plan
            summary = plan.title ?? "Plan"
            if let title = plan.title {
                plan.title = project(title, direction: .head).text
            }
            var steps: [ChatPlanStep] = []
            for var step in plan.steps {
                let result = project(step.title, direction: .head)
                step.title = result.text
                steps.append(step)
            }
            plan.steps = steps
            if hiddenBytes > 0 || hiddenLines > 0 {
                handles.append(
                    TranscriptSourceHandle(
                        itemID: plan.id,
                        part: .plan,
                        title: plan.title ?? "Plan",
                        contentType: "Plan",
                        isTruncatedAtSource: false,
                        originalByteCount: nil
                    )
                )
            }
            displayItem = .plan(plan)
        case .generic(var generic):
            kind = .generic
            summary = generic.title
            generic.title = project(generic.title, direction: .head).text
            generic.type = project(generic.type, direction: .head).text
            if let detail = generic.detail {
                let result = project(detail, direction: .head, sourcePart: .genericDetail)
                generic.detail = result.text
                if result.isTruncated {
                    handles.append(
                        TranscriptSourceHandle(
                            itemID: generic.id,
                            part: .genericDetail,
                            title: generic.title,
                            contentType: "Activity detail",
                            isTruncatedAtSource: false,
                            originalByteCount: nil
                        )
                    )
                }
            }
            displayItem = .generic(generic)
        }

        return TranscriptRowProjection(
            id: item.id,
            sourceItemID: item.id,
            kind: kind,
            contentRevision: contentRevision,
            displayItem: displayItem,
            hiddenByteCount: hiddenBytes,
            hiddenLineCount: hiddenLines,
            sourceHandles: handles,
            accessibilitySummary: summary
        )
    }
}
