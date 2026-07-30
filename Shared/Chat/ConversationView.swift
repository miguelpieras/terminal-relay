import Foundation
import SwiftUI

enum ConversationViewportAction: Equatable {
    case preserve
    case anchorInitialLatest
    case anchorLatest
}

struct ConversationViewportPolicy: Equatable {
    private enum Phase: Equatable {
        case awaitingContent
        case initialAnchorPending
        case positioned
    }

    private var phase: Phase = .awaitingContent

    var acceptsBottomMeasurements: Bool {
        phase == .positioned
    }

    mutating func actionForContentUpdate(
        hasContent: Bool,
        isPagination: Bool,
        wasNearBottom: Bool
    ) -> ConversationViewportAction {
        if phase == .awaitingContent, hasContent {
            phase = .initialAnchorPending
            return .anchorInitialLatest
        }
        guard phase == .positioned, !isPagination else {
            return .preserve
        }
        return wasNearBottom ? .anchorLatest : .preserve
    }

    mutating func completeInitialAnchor() {
        guard phase == .initialAnchorPending else { return }
        phase = .positioned
    }
}

private struct ConversationViewportUpdateToken: Equatable {
    let sequence: Int64
    let lastItemID: String?
    let pendingApprovalCount: Int
    let pendingQuestionCount: Int

    var hasContent: Bool {
        lastItemID != nil || pendingApprovalCount > 0 || pendingQuestionCount > 0
    }
}

struct ConversationView: View {
    @ObservedObject private var store: ConversationStore

    let coordinator: ConversationCoordinator
    let isReadOnly: Bool
    let showsComposer: Bool
    let startsCoordinator: Bool

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @State private var escapeRouter = ComposerEscapeRouter()
    #endif
    @State private var viewportPolicy = ConversationViewportPolicy()

    init(
        coordinator: ConversationCoordinator,
        isReadOnly: Bool = false,
        showsComposer: Bool = true,
        startsCoordinator: Bool = true
    ) {
        self.coordinator = coordinator
        _store = ObservedObject(wrappedValue: coordinator.store)
        self.isReadOnly = isReadOnly
        self.showsComposer = showsComposer
        self.startsCoordinator = startsCoordinator
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            if !isReadOnly {
                compactNotice
            }
            if !isReadOnly, showsComposer {
                composer
            }
        }
        .background(Color.chatCanvas)
        .task {
            if startsCoordinator {
                coordinator.start()
            }
        }
        .onDisappear {
            Task {
                await coordinator.detach()
            }
        }
        #if os(iOS)
        .onKeyPress(.escape, phases: [.down, .repeat]) { keyPress in
            guard !isReadOnly, showsComposer else { return .ignored }
            switch escapeRouter.route(
                activeTurnID: store.state.activeTurnID,
                timestamp: ProcessInfo.processInfo.systemUptime,
                isRepeat: keyPress.phase.contains(.repeat)
            ) {
            case .passThrough:
                return .ignored
            case .consume:
                return .handled
            case .interrupt:
                Task {
                    await coordinator.interrupt()
                }
                return .handled
            }
        }
        #endif
        .sheet(
            item: Binding(
                get: { store.state.filePreview },
                set: { value in
                    if value == nil { store.dismissFilePreview() }
                }
            )
        ) { preview in
            FilePreviewSheet(preview: preview) {
                store.dismissFilePreview()
            }
        }
    }

    private var transcript: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        historyControl

                        ForEach(store.state.items) { item in
                            timelineView(for: item)
                                .id(item.id)
                        }

                        ForEach(store.state.approvals) { approval in
                            ApprovalCard(
                                approval: approval,
                                store: store,
                                coordinator: coordinator,
                                isReadOnly: isReadOnly
                            )
                            .id("approval:\(approval.id)")
                        }

                        ForEach(store.state.questions) { question in
                            QuestionCard(
                                question: question,
                                store: store,
                                coordinator: coordinator,
                                isReadOnly: isReadOnly
                            )
                            .id("question:\(question.id)")
                        }

                        if store.state.items.isEmpty,
                           store.state.approvals.isEmpty,
                           store.state.questions.isEmpty {
                            emptyConversation
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("chat-bottom")
                            .background {
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: ConversationBottomPreferenceKey.self,
                                        value: proxy.frame(in: .named("conversation-scroll")).maxY
                                    )
                                }
                            }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, horizontalTranscriptPadding)
                    .padding(.top, 22)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: "conversation-scroll")
                .onPreferenceChange(ConversationBottomPreferenceKey.self) { bottomY in
                    guard viewportPolicy.acceptsBottomMeasurements else { return }
                    let nearBottom = bottomY <= geometry.size.height + 180
                    if nearBottom != store.isNearBottom {
                        store.setNearBottom(nearBottom)
                    }
                }
                .onChange(of: viewportUpdateSignal, initial: true) { _, update in
                    handleViewportUpdate(update, proxy: proxy)
                }
                .onChange(of: store.state.items.first?.id) { oldValue, newValue in
                    guard let oldValue,
                          let newValue,
                          oldValue != newValue,
                          !store.isNearBottom else {
                        return
                    }
                    proxy.scrollTo(oldValue, anchor: .top)
                }
                .overlay(alignment: .bottomTrailing) {
                    if !store.isNearBottom {
                        Button {
                            store.jumpToLatest()
                            scrollToBottom(proxy)
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.caption.weight(.semibold))
                                .frame(width: 28, height: 28)
                                .background(.regularMaterial, in: Circle())
                                .overlay {
                                    Circle()
                                        .strokeBorder(Color.secondary.opacity(0.16))
                                }
                                .frame(
                                    width: ChatInteractionTargetLayout.jumpButtonDimension,
                                    height: ChatInteractionTargetLayout.jumpButtonDimension
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(ChatInteractionTargetLayout.jumpButtonOuterPadding)
                        .accessibilityLabel(
                            store.unreadCount > 0
                                ? "\(store.unreadCount) new messages. Jump to latest"
                                : "Jump to latest"
                        )
                        .accessibilityHint("Moves to the newest conversation update.")
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.16),
                    value: store.isNearBottom
                )
            }
        }
    }

    @ViewBuilder
    private var historyControl: some View {
        if store.state.hasOlderHistory {
            HStack {
                Spacer()
                Button {
                    Task {
                        await coordinator.loadOlderHistory()
                    }
                } label: {
                    if store.isLoadingOlderHistory {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(store.state.didTruncateHistory ? "Load earlier content" : "Load earlier")
                    }
                }
                .buttonStyle(.plain)
                .chatMinimumInteractionTarget()
                .font(.caption)
                .foregroundStyle(.secondary)
                .controlSize(.small)
                .disabled(store.isLoadingOlderHistory || isReadOnly)
                .accessibilityHint("Loads up to 50 earlier messages without moving your reading position.")
                Spacer()
            }
            .id("history:\(store.state.oldestItemID ?? "start")")
        }
    }

    @ViewBuilder
    private func timelineView(for item: ConversationItem) -> some View {
        switch item {
        case .message(let message):
            ChatMessageView(
                message: message,
                onOpenExternal: { openURL($0) },
                onOpenRepository: { link in
                    Task {
                        await coordinator.previewFile(link)
                    }
                }
            )
        case .reasoning(let reasoning):
            ReasoningCard(reasoning: reasoning, store: store)
        case .tool(let tool):
            ToolActivityCard(tool: tool, store: store)
        case .diff(let diff):
            DiffCard(diff: diff, store: store)
        case .plan(let plan):
            PlanCard(plan: plan)
        case .generic(let generic):
            GenericActivityCard(item: generic, store: store)
        }
    }

    private var emptyConversation: some View {
        VStack(spacing: 8) {
            if store.state.connectionState == .connecting {
                ProgressView()
                    .controlSize(.small)
                Text("Connecting…")
                    .foregroundStyle(.secondary)
            } else {
                Text(isReadOnly ? "No messages" : "What can I help you build?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var compactNotice: some View {
        if let notice = compactNoticeContent {
            HStack(spacing: 6) {
                if notice.isProgress {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "exclamationmark.circle")
                }
                Text(notice.message)
                    .lineLimit(2)
                if notice.canRetry {
                    Button("Retry") {
                        coordinator.retry()
                    }
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
                if store.state.lastErrorMessage != nil {
                    Button {
                        store.clearLastError()
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss message")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, horizontalTranscriptPadding)
            .padding(.vertical, 2)
        }
    }

    private var composer: some View {
        ConversationComposer(store: store, coordinator: coordinator)
            .frame(maxWidth: 760)
            .padding(.horizontal, horizontalTranscriptPadding)
            .padding(.top, 6)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
    }

    private var horizontalTranscriptPadding: CGFloat {
        #if os(iOS)
        16
        #else
        28
        #endif
    }

    private var viewportUpdateSignal: ConversationViewportUpdateToken {
        ConversationViewportUpdateToken(
            sequence: store.state.lastAppliedSequence,
            lastItemID: store.state.items.last?.id,
            pendingApprovalCount: store.state.approvals.count,
            pendingQuestionCount: store.state.questions.count
        )
    }

    private var compactNoticeContent: (message: String, canRetry: Bool, isProgress: Bool)? {
        if let message = store.state.lastErrorMessage {
            let canRetry = store.state.connectionState == .failed
                || store.state.connectionState == .offlineAgentRunning
                || store.state.connectionState == .unsupportedWorker
            return (message, canRetry, false)
        }
        switch store.state.connectionState {
        case .connecting where !store.state.items.isEmpty:
            return ("Connecting…", false, true)
        case .offlineAgentRunning:
            return ("Connection interrupted.", true, false)
        case .unsupportedWorker:
            return ("Native chat is unavailable on this worker.", true, false)
        case .failed:
            return ("Unable to connect.", true, false)
        case .stopped:
            return ("Session ended.", false, false)
        default:
            return nil
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if reduceMotion || store.state.turnState.isActive {
            proxy.scrollTo("chat-bottom", anchor: .bottom)
        } else {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
        }
    }

    private func handleViewportUpdate(
        _ update: ConversationViewportUpdateToken,
        proxy: ScrollViewProxy
    ) {
        switch viewportPolicy.actionForContentUpdate(
            hasContent: update.hasContent,
            isPagination: store.isLoadingOlderHistory,
            wasNearBottom: store.isNearBottom
        ) {
        case .preserve:
            break
        case .anchorLatest:
            scrollToBottom(proxy)
        case .anchorInitialLatest:
            Task { @MainActor in
                // Wait for the lazy transcript to install the bottom anchor,
                // then repeat once after layout so a large snapshot cannot
                // leave a resumed conversation at its oldest row.
                await Task.yield()
                proxy.scrollTo("chat-bottom", anchor: .bottom)
                await Task.yield()
                proxy.scrollTo("chat-bottom", anchor: .bottom)
                viewportPolicy.completeInitialAnchor()
                store.setNearBottom(true)
            }
        }
    }
}

private struct ConversationBottomPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ChatMessageView: View {
    let message: ChatMessage
    let onOpenExternal: (URL) -> Void
    let onOpenRepository: (ChatRepositoryLink) -> Void

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user {
                Spacer(minLength: 44)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 10) {
                ForEach(message.contents) { content in
                    contentView(content)
                }
                if message.isStreaming {
                    StreamingIndicator()
                }
            }
            .padding(message.role == .user ? 12 : 0)
            .background {
                if message.role == .user {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                }
            }
            .frame(maxWidth: message.role == .user ? 640 : .infinity, alignment: message.role == .user ? .trailing : .leading)

            if message.role != .user {
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message.role == .user ? "You" : "Assistant")
    }

    @ViewBuilder
    private func contentView(_ content: MessageContent) -> some View {
        switch content.kind {
        case .code:
            CodeBlockView(
                id: content.id,
                code: content.text,
                language: content.language,
                isStreaming: !content.isComplete
            )
        case .imagePlaceholder:
            Label(content.text, systemImage: "photo")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .plainText where message.role == .user:
            Text(content.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .generic where message.role == .user:
            Text(content.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        default:
            RichMarkdownView(
                text: content.text,
                isStreaming: !content.isComplete,
                onOpenExternal: onOpenExternal,
                onOpenRepository: onOpenRepository
            )
        }
    }
}

private struct StreamingIndicator: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text("Working")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Assistant is responding")
    }
}

private struct ReasoningCard: View {
    let reasoning: ChatReasoning
    @ObservedObject var store: ConversationStore

    var isExpanded: Bool { store.expandedItemIDs.contains(reasoning.id) }

    var body: some View {
        DisclosureCard(
            title: reasoning.isStreaming ? "Thinking…" : "Reasoning summary",
            symbol: "brain.head.profile",
            statusColor: reasoning.isStreaming ? .blue : .secondary,
            isExpanded: isExpanded,
            toggle: { store.toggleExpanded(itemID: reasoning.id) }
        ) {
            Text(reasoning.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct ToolActivityCard: View {
    let tool: ToolActivity
    @ObservedObject var store: ConversationStore

    private var isExpanded: Bool {
        store.expandedItemIDs.contains(tool.id)
    }

    var body: some View {
        DisclosureCard(
            title: tool.title,
            subtitle: subtitle,
            symbol: toolSymbol,
            statusColor: statusColor,
            isExpanded: isExpanded,
            toggle: { store.toggleExpanded(itemID: tool.id) }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if let input = tool.input, !input.isEmpty {
                    ToolSection(title: "Input", content: input, itemID: "\(tool.id):input", store: store)
                }
                if let output = tool.output, !output.isEmpty {
                    ToolSection(title: "Output", content: output, itemID: "\(tool.id):output", store: store)
                }
                if let error = tool.errorMessage, !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if tool.input == nil, tool.output == nil, tool.errorMessage == nil {
                    Text(tool.status == .running ? "Waiting for output…" : "No additional output")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var subtitle: String? {
        var values: [String] = [tool.status.rawValue.capitalized]
        if let duration = tool.durationMilliseconds {
            values.append(Duration.milliseconds(duration).formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated)))
        }
        if let exitCode = tool.exitCode {
            values.append("exit \(exitCode)")
        }
        return values.joined(separator: " · ")
    }

    private var toolSymbol: String {
        switch tool.kind {
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

    private var statusColor: Color {
        switch tool.status {
        case .running: .blue
        case .completed: .green
        case .failed: .red
        case .cancelled: .orange
        case .pending: .secondary
        }
    }
}

private struct ToolSection: View {
    let title: String
    let content: String
    let itemID: String
    @ObservedObject var store: ConversationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    ChatClipboard.copy(content)
                    store.markCopied(itemID: itemID)
                } label: {
                    Label(store.copiedItemID == itemID ? "Copied" : "Copy", systemImage: store.copiedItemID == itemID ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .chatMinimumInteractionTarget(includesWidth: true)
                .accessibilityLabel(store.copiedItemID == itemID ? "\(title) copied" : "Copy \(title.lowercased())")
            }
            CodeBlockView(
                id: itemID,
                code: content,
                language: nil,
                isStreaming: false
            )
        }
    }
}

private struct DiffCard: View {
    let diff: ChatDiff
    @ObservedObject var store: ConversationStore

    private var isExpanded: Bool {
        store.expandedItemIDs.contains(diff.id)
    }

    var body: some View {
        DisclosureCard(
            title: diff.path ?? "File changes",
            subtitle: diff.isTruncated ? "Preview truncated" : nil,
            symbol: "doc.badge.gearshape",
            statusColor: .blue,
            isExpanded: isExpanded,
            toggle: { store.toggleExpanded(itemID: diff.id) }
        ) {
            DiffTextView(diff: diff.unifiedDiff)
        }
    }
}

private struct DiffTextView: View {
    let diff: String

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                    Text(verbatim: String(line))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(lineColor(String(line)))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(lineBackground(String(line)))
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .textSelection(.enabled)
        }
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func lineColor(_ line: String) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-"), !line.hasPrefix("---") { return .red }
        return .primary
    }

    private func lineBackground(_ line: String) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") { return .green.opacity(0.1) }
        if line.hasPrefix("-"), !line.hasPrefix("---") { return .red.opacity(0.1) }
        return .clear
    }
}

private struct PlanCard: View {
    let plan: ChatPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(plan.title ?? "Plan")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(plan.steps) { step in
                Label(
                    step.title,
                    systemImage: step.isCompleted ? "checkmark.circle.fill" : "circle"
                )
                .font(.callout)
                .foregroundStyle(step.isCompleted ? .secondary : .primary)
                .accessibilityLabel("\(step.isCompleted ? "Completed" : "Pending"): \(step.title)")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }
}

private struct GenericActivityCard: View {
    let item: ChatGenericItem
    @ObservedObject var store: ConversationStore

    private var isExpanded: Bool { store.expandedItemIDs.contains(item.id) }

    var body: some View {
        DisclosureCard(
            title: item.title,
            subtitle: item.type,
            symbol: "square.stack.3d.up",
            statusColor: .secondary,
            isExpanded: isExpanded,
            toggle: { store.toggleExpanded(itemID: item.id) }
        ) {
            if let detail = item.detail {
                Text(detail)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            } else {
                Text("No additional details")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DisclosureCard<Content: View>: View {
    let title: String
    var subtitle: String?
    let symbol: String
    let statusColor: Color
    let isExpanded: Bool
    let toggle: () -> Void
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        subtitle: String? = nil,
        symbol: String,
        statusColor: Color,
        isExpanded: Bool,
        toggle: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.statusColor = statusColor
        self.isExpanded = isExpanded
        self.toggle = toggle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 7) {
                    Image(systemName: symbol)
                        .foregroundStyle(statusColor)
                        .font(.caption)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .chatMinimumInteractionTarget()
            .padding(.vertical, ChatInteractionTargetLayout.compactControlVerticalPadding)
            .accessibilityLabel("\(title), \(isExpanded ? "expanded" : "collapsed")")
            .accessibilityHint(isExpanded ? "Collapses details." : "Expands details.")

            if isExpanded {
                content()
                    .padding(.leading, 23)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }
        }
    }
}

private struct ApprovalCard: View {
    let approval: ApprovalRequest
    @ObservedObject var store: ConversationStore
    let coordinator: ConversationCoordinator
    let isReadOnly: Bool

    private var isResponding: Bool {
        store.respondingInteractionIDs.contains(approval.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: approval.status == .pending ? "hand.raised.fill" : "checkmark.shield")
                    .foregroundStyle(approval.status == .pending ? .orange : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(approval.title)
                        .font(.headline)
                    Text(approvalStatusLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let reason = approval.reason {
                Text(reason)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            if let context = approval.context {
                CodeBlockView(
                    id: "\(approval.id):context",
                    code: context,
                    language: nil,
                    isStreaming: false
                )
            }

            if approval.status == .pending, !isReadOnly {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        ForEach(approval.decisions) { decision in
                            approvalButton(for: decision)
                        }
                    }

                    VStack(spacing: 8) {
                        ForEach(approval.decisions) { decision in
                            approvalButton(for: decision)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.24))
        }
        .accessibilityElement(children: .contain)
        .onDisappear {
            store.clearDestructiveApprovalConfirmation(approvalID: approval.id)
        }
    }

    @ViewBuilder
    private func approvalButton(for decision: ApprovalDecision) -> some View {
        Button {
            Task {
                await coordinator.respond(
                    to: approval.id,
                    decisionID: decision.id
                )
            }
        } label: {
            if isResponding {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text(buttonLabel(for: decision))
            }
        }
        .buttonStyle(.borderedProminent)
        .chatMinimumInteractionTarget()
        .tint(decision.id.lowercased().contains("deny") ? Color.red : Color.accentColor)
        .disabled(isResponding)
        .accessibilityHint(
            decision.isDestructive
                ? "Requires a second confirmation."
                : "Responds once to this approval request."
        )
    }

    private var approvalStatusLabel: String {
        switch approval.status {
        case .pending: "Your approval is required"
        case .approved: "Approved"
        case .denied: "Denied"
        case .expired: "Request expired"
        }
    }

    private func buttonLabel(for decision: ApprovalDecision) -> String {
        if decision.isDestructive,
           store.pendingDestructiveApprovalConfirmation
            == DestructiveApprovalConfirmation(
                approvalID: approval.id,
                decisionID: decision.id
            ) {
            return "Confirm \(decision.label)"
        }
        return decision.label
    }
}

enum ComposerReturnAction: Equatable {
    case insertNewline
    case send
    case ignore
}

enum ComposerInputPolicy {
    static func returnAction(
        commandKeyPressed: Bool,
        canSend: Bool
    ) -> ComposerReturnAction {
        guard commandKeyPressed else { return .insertNewline }
        return canSend ? .send : .ignore
    }
}

enum ComposerEscapeAction: Equatable {
    case ignored
    case armed
    case interrupt
}

struct ComposerEscapePolicy: Equatable, Sendable {
    let maximumInterval: TimeInterval
    let minimumInterval: TimeInterval

    private var trackedTurnID: String?
    private var firstEscapeTimestamp: TimeInterval?
    private var lastInterruptTimestamp: TimeInterval?

    init(
        maximumInterval: TimeInterval = 0.8,
        minimumInterval: TimeInterval = 0.05
    ) {
        self.maximumInterval = maximumInterval
        self.minimumInterval = minimumInterval
    }

    mutating func action(
        activeTurnID: String?,
        timestamp: TimeInterval,
        isRepeat: Bool
    ) -> ComposerEscapeAction {
        guard let activeTurnID, timestamp.isFinite else {
            reset()
            return .ignored
        }

        if trackedTurnID != activeTurnID {
            trackedTurnID = activeTurnID
            firstEscapeTimestamp = nil
            lastInterruptTimestamp = nil
        }

        guard !isRepeat else {
            return .ignored
        }

        if let lastInterruptTimestamp {
            let interval = timestamp - lastInterruptTimestamp
            if interval >= 0, interval < minimumInterval {
                return .ignored
            }
            self.lastInterruptTimestamp = nil
        }

        guard let firstEscapeTimestamp else {
            self.firstEscapeTimestamp = timestamp
            return .armed
        }

        let interval = timestamp - firstEscapeTimestamp
        if interval < 0 || interval > maximumInterval {
            self.firstEscapeTimestamp = timestamp
            return .armed
        }
        guard interval >= minimumInterval else {
            return .ignored
        }

        self.firstEscapeTimestamp = nil
        lastInterruptTimestamp = timestamp
        return .interrupt
    }

    private mutating func reset() {
        trackedTurnID = nil
        firstEscapeTimestamp = nil
        lastInterruptTimestamp = nil
    }
}

enum ComposerEscapeRoute: Equatable {
    case passThrough
    case consume
    case interrupt
}

struct ComposerEscapeRouter: Equatable, Sendable {
    private var policy = ComposerEscapePolicy()

    mutating func route(
        activeTurnID: String?,
        timestamp: TimeInterval,
        isRepeat: Bool
    ) -> ComposerEscapeRoute {
        guard activeTurnID != nil else {
            _ = policy.action(
                activeTurnID: nil,
                timestamp: timestamp,
                isRepeat: isRepeat
            )
            return .passThrough
        }

        switch policy.action(
            activeTurnID: activeTurnID,
            timestamp: timestamp,
            isRepeat: isRepeat
        ) {
        case .ignored, .armed:
            return .consume
        case .interrupt:
            return .interrupt
        }
    }
}

enum QuestionResponsePresentation {
    static func canSubmit(
        request: QuestionRequest,
        selectedOptions: [String: Set<String>],
        text: [String: String],
        secretTextByField: [String: String]
    ) -> Bool {
        request.resolvedFields.allSatisfy { field in
            let key = request.draftKey(for: field)
            switch field.kind {
            case .singleChoice, .multipleChoice:
                return !(selectedOptions[key] ?? []).isEmpty
                    || (field.allowsOther
                        && !(text[key] ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty)
            case .freeText:
                return !(text[key] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            case .secret:
                return !(secretTextByField[field.id] ?? "").isEmpty
            }
        }
    }

    static func answers(
        request: QuestionRequest,
        selectedOptions: [String: Set<String>],
        text: [String: String],
        secretTextByField: [String: String]
    ) -> [ChatQuestionAnswer] {
        request.resolvedFields.map { field in
            let key = request.draftKey(for: field)
            return ChatQuestionAnswer(
                questionID: field.id,
                selectedOptionIDs: (selectedOptions[key] ?? []).sorted(),
                text: field.kind == .secret
                    ? secretTextByField[field.id]
                    : text[key]
            )
        }
    }
}

private struct QuestionCard: View {
    let question: QuestionRequest
    @ObservedObject var store: ConversationStore
    let coordinator: ConversationCoordinator
    let isReadOnly: Bool

    @State private var secretTextByField: [String: String] = [:]

    private var isResponding: Bool {
        store.respondingInteractionIDs.contains(question.id)
    }

    private var fields: [QuestionField] {
        question.resolvedFields
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: question.status == .pending ? "questionmark.bubble.fill" : "checkmark.bubble")
                    .foregroundStyle(question.status == .pending ? .blue : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(fields.count == 1 ? fields[0].prompt : question.prompt)
                        .font(.headline)
                    if fields.count > 1, question.status == .pending {
                        Text("\(fields.count) answers required")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if question.status != .pending {
                        Text(question.status == .answered ? "Answered" : "Request expired")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if question.status == .pending, !isReadOnly {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                        if index > 0 {
                            Divider()
                        }
                        questionField(field, showsPrompt: fields.count > 1)
                    }
                }

                Button {
                    let answers = answerPayload
                    secretTextByField.removeAll()
                    Task {
                        await coordinator.answer(
                            questionID: question.id,
                            answers: answers
                        )
                    }
                } label: {
                    if isResponding {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Submit Answer")
                    }
                }
                .buttonStyle(.borderedProminent)
                .chatMinimumInteractionTarget()
                .disabled(!canSubmit || isResponding)
                .accessibilityHint("Submits this answer once.")
            }
        }
        .padding(14)
        .background(Color.blue.opacity(0.065))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.blue.opacity(0.2))
        }
        .accessibilityElement(children: .contain)
        .onChange(of: question.status) { _, status in
            if status != .pending {
                secretTextByField.removeAll()
            }
        }
        .onDisappear {
            secretTextByField.removeAll()
        }
    }

    private var canSubmit: Bool {
        QuestionResponsePresentation.canSubmit(
            request: question,
            selectedOptions: store.selectedQuestionOptions,
            text: store.questionText,
            secretTextByField: secretTextByField
        )
    }

    private var answerPayload: [ChatQuestionAnswer] {
        QuestionResponsePresentation.answers(
            request: question,
            selectedOptions: store.selectedQuestionOptions,
            text: store.questionText,
            secretTextByField: secretTextByField
        )
    }

    @ViewBuilder
    private func questionField(_ field: QuestionField, showsPrompt: Bool) -> some View {
        let key = question.draftKey(for: field)
        let selectedOptions = store.selectedQuestionOptions[key] ?? []

        VStack(alignment: .leading, spacing: 9) {
            if showsPrompt {
                Text(field.prompt)
                    .font(.subheadline.weight(.semibold))
            }

            if !field.options.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(field.options) { option in
                        Button {
                            store.toggleQuestionOption(
                                questionID: key,
                                optionID: option.id,
                                allowsMultiple: field.kind == .multipleChoice
                            )
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(
                                    systemName: selectedOptions.contains(option.id)
                                        ? (field.kind == .multipleChoice
                                            ? "checkmark.square.fill"
                                            : "largecircle.fill.circle")
                                        : (field.kind == .multipleChoice ? "square" : "circle")
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label)
                                        .foregroundStyle(.primary)
                                    if let detail = option.detail {
                                        Text(detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .chatMinimumInteractionTarget()
                        .accessibilityLabel(
                            "\(option.label), \(selectedOptions.contains(option.id) ? "selected" : "not selected")"
                        )
                    }
                }
            }

            if field.kind == .freeText || field.allowsOther {
                TextField(
                    field.allowsOther ? "Or type another answer" : "Type your answer",
                    text: Binding(
                        get: { store.questionText[key] ?? "" },
                        set: { store.updateQuestionText(questionID: key, text: $0) }
                    ),
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
            } else if field.kind == .secret {
                SecureField(
                    "Enter securely",
                    text: Binding(
                        get: { secretTextByField[field.id] ?? "" },
                        set: { secretTextByField[field.id] = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .privacySensitive()
                .accessibilityHint(
                    "This answer is sent directly and is not retained in conversation state."
                )
            }
        }
    }
}

#if os(iOS)
struct MobileComposerModelOption: Equatable, Identifiable {
    let id: String
    let name: String
    let supportsUltra: Bool
}

enum MobileComposerLaunchPolicy {
    static let codexModels = [
        MobileComposerModelOption(
            id: "gpt-5.6-sol",
            name: "5.6 Sol",
            supportsUltra: true
        ),
        MobileComposerModelOption(
            id: "gpt-5.6-terra",
            name: "5.6 Terra",
            supportsUltra: true
        ),
        MobileComposerModelOption(
            id: "gpt-5.6-luna",
            name: "5.6 Luna",
            supportsUltra: false
        ),
    ]

    static let claudeModels = [
        MobileComposerModelOption(
            id: "fable",
            name: "Fable",
            supportsUltra: false
        ),
        MobileComposerModelOption(
            id: "opus",
            name: "Opus",
            supportsUltra: false
        ),
        MobileComposerModelOption(
            id: "sonnet",
            name: "Sonnet",
            supportsUltra: false
        ),
    ]

    static func models(for provider: ChatProvider) -> [MobileComposerModelOption] {
        provider == .codex ? codexModels : claudeModels
    }

    static func availableEfforts(
        provider: ChatProvider,
        model: String
    ) -> [AgentReasoningEffort] {
        let supportsUltra = models(for: provider)
            .first(where: { $0.id == model })?
            .supportsUltra == true
        return AgentReasoningEffort.allCases.filter {
            $0 != .ultra || supportsUltra
        }
    }

    static func normalizedEffort(
        _ effort: AgentReasoningEffort,
        provider: ChatProvider,
        model: String
    ) -> AgentReasoningEffort {
        availableEfforts(provider: provider, model: model).contains(effort)
            ? effort
            : .max
    }
}
#endif

private struct ConversationComposer: View {
    @ObservedObject var store: ConversationStore
    let coordinator: ConversationCoordinator

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    #if os(iOS)
    @AppStorage(AgentLaunchDefaults.StorageKey.codexModel)
    private var codexModel = AgentLaunchDefaults.standard.codexModel
    @AppStorage(AgentLaunchDefaults.StorageKey.codexReasoningEffort)
    private var codexReasoningEffort = AgentLaunchDefaults.standard.codexReasoningEffort
    @AppStorage(AgentLaunchDefaults.StorageKey.claudeModel)
    private var claudeModel = AgentLaunchDefaults.standard.claudeModel
    @AppStorage(AgentLaunchDefaults.StorageKey.claudeReasoningEffort)
    private var claudeReasoningEffort = AgentLaunchDefaults.standard.claudeReasoningEffort
    #endif

    private var canSend: Bool {
        !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !store.state.turnState.isActive
            && (store.state.connectionState == .streaming
                || store.state.connectionState == .interrupted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(store.attachments) { attachment in
                            HStack(spacing: 6) {
                                Image(systemName: "paperclip")
                                Text(attachment.displayName)
                                    .lineLimit(1)
                                Button {
                                    store.removeAttachment(id: attachment.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .chatMinimumInteractionTarget(includesWidth: true)
                                .accessibilityLabel("Remove \(attachment.displayName)")
                            }
                            .font(.caption)
                            .padding(.horizontal, 9)
                            .padding(.vertical, ChatInteractionTargetLayout.attachmentChipVerticalPadding)
                            .background(Color.secondary.opacity(0.09), in: Capsule())
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            composerInput
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .background(Color.chatComposer, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.12))
            }
        }
        #if os(iOS)
        .onAppear {
            synchronizeMobileLaunchOptions()
        }
        #endif
    }

    @ViewBuilder
    private var composerInput: some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: 0) {
            promptEditor
            HStack(spacing: 4) {
                mobileModelControl
                mobileEffortControl
                Spacer(minLength: 8)
                turnActionButton
            }
        }
        #else
        HStack(alignment: .bottom, spacing: 10) {
            promptEditor
            turnActionButton
        }
        #endif
    }

    private var promptEditor: some View {
        ZStack(alignment: .topLeading) {
            if store.draft.isEmpty {
                Text("Ask anything")
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 9)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $store.draft)
                .font(.body)
                .tint(.primary)
                .scrollContentBackground(.hidden)
                .frame(
                    minHeight: dynamicTypeSize.isAccessibilitySize ? 74 : 42,
                    maxHeight: 150
                )
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Message")
                .accessibilityHint("Command Return sends. Return inserts a new line.")
                .onKeyPress(.return, phases: .down) { keyPress in
                    switch ComposerInputPolicy.returnAction(
                        commandKeyPressed: keyPress.modifiers.contains(.command),
                        canSend: canSend
                    ) {
                    case .insertNewline:
                        return .ignored
                    case .send:
                        Task {
                            await coordinator.sendDraft()
                        }
                        return .handled
                    case .ignore:
                        return .handled
                    }
                }
        }
    }

    @ViewBuilder
    private var turnActionButton: some View {
        if store.state.turnState.isActive {
            Button {
                Task {
                    await coordinator.interrupt()
                }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.caption2.weight(.bold))
                    .frame(width: 30, height: 30)
                    .background(Color.primary, in: Circle())
                    .foregroundStyle(Color.chatButtonForeground)
                    .frame(width: actionHitTargetSize, height: actionHitTargetSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop current turn")
            .accessibilityHint("Stops the current turn. Press Escape twice to stop from the keyboard.")
        } else {
            Button {
                Task {
                    await coordinator.sendDraft()
                }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.callout.weight(.bold))
                    .frame(width: 30, height: 30)
                    .background(
                        canSend ? Color.primary : Color.secondary.opacity(0.14),
                        in: Circle()
                    )
                    .foregroundStyle(
                        canSend ? Color.chatButtonForeground : Color.secondary
                    )
                    .frame(width: actionHitTargetSize, height: actionHitTargetSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send message")
            .accessibilityHint("Sends the message and any ready attachments.")
        }
    }

    private var actionHitTargetSize: CGFloat {
        #if os(iOS)
        44
        #else
        30
        #endif
    }

    #if os(iOS)
    private var mobileModelControl: some View {
        Menu {
            ForEach(
                MobileComposerLaunchPolicy.models(for: coordinator.identity.provider)
            ) { model in
                Button {
                    selectMobileModel(model.id)
                } label: {
                    if selectedMobileModel == model.id {
                        Label(model.name, systemImage: "checkmark")
                    } else {
                        Text(model.name)
                    }
                }
            }
        } label: {
            compactMenuLabel(mobileModelDisplayName)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Model")
        .accessibilityValue(mobileModelDisplayName)
    }

    private var mobileEffortControl: some View {
        Menu {
            ForEach(availableMobileEfforts) { effort in
                Button {
                    selectMobileEffort(effort)
                } label: {
                    if selectedMobileEffort == effort {
                        Label(effort.displayName, systemImage: "checkmark")
                    } else {
                        Text(effort.displayName)
                    }
                }
            }
        } label: {
            compactMenuLabel(selectedMobileEffort.displayName)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reasoning effort")
        .accessibilityValue(selectedMobileEffort.displayName)
    }

    private func compactMenuLabel(_ title: String) -> some View {
        HStack(spacing: 3) {
            Text(title)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var selectedMobileModel: String {
        coordinator.identity.provider == .codex ? codexModel : claudeModel
    }

    private var selectedMobileEffort: AgentReasoningEffort {
        let effort = coordinator.identity.provider == .codex
            ? codexReasoningEffort
            : claudeReasoningEffort
        return MobileComposerLaunchPolicy.normalizedEffort(
            effort,
            provider: coordinator.identity.provider,
            model: selectedMobileModel
        )
    }

    private var availableMobileEfforts: [AgentReasoningEffort] {
        MobileComposerLaunchPolicy.availableEfforts(
            provider: coordinator.identity.provider,
            model: selectedMobileModel
        )
    }

    private var mobileModelDisplayName: String {
        MobileComposerLaunchPolicy.models(for: coordinator.identity.provider)
            .first(where: { $0.id == selectedMobileModel })?
            .name
            ?? selectedMobileModel
    }

    private func selectMobileModel(_ model: String) {
        if coordinator.identity.provider == .codex {
            codexModel = model
            codexReasoningEffort = MobileComposerLaunchPolicy.normalizedEffort(
                codexReasoningEffort,
                provider: .codex,
                model: model
            )
        } else {
            claudeModel = model
            claudeReasoningEffort = MobileComposerLaunchPolicy.normalizedEffort(
                claudeReasoningEffort,
                provider: .claude,
                model: model
            )
        }
        synchronizeMobileLaunchOptions()
    }

    private func selectMobileEffort(_ effort: AgentReasoningEffort) {
        if coordinator.identity.provider == .codex {
            codexReasoningEffort = effort
        } else {
            claudeReasoningEffort = effort
        }
        synchronizeMobileLaunchOptions()
    }

    private func synchronizeMobileLaunchOptions() {
        coordinator.updateLaunchOptions(
            model: selectedMobileModel,
            reasoningEffort: selectedMobileEffort.rawValue,
            fastMode: nil
        )
    }
    #endif
}

private struct FilePreviewSheet: View {
    let preview: ChatFilePreview
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            CodeBlockView(
                id: "preview:\(preview.id)",
                code: preview.content,
                language: URL(fileURLWithPath: preview.path).pathExtension,
                isStreaming: false
            )
            .padding()
            .navigationTitle(preview.path)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if preview.isTruncated {
                    Label(
                        "Preview truncated\(preview.originalByteCount.map { " from \($0.formatted()) bytes" } ?? "")",
                        systemImage: "scissors"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 320)
    }
}

private extension Color {
    static var chatCanvas: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    static var chatComposer: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    static var chatButtonForeground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}
