import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AgentComposerView: View {
    @ObservedObject var session: TerminalSession

    let worker: ServerProfile
    let onNativeEscape: (Bool) -> Void

    @AppStorage(AgentLaunchDefaults.StorageKey.codexModel)
    private var codexModel = AgentLaunchDefaults.standard.codexModel
    @AppStorage(AgentLaunchDefaults.StorageKey.codexReasoningEffort)
    private var codexReasoningEffort = AgentLaunchDefaults.standard.codexReasoningEffort
    @AppStorage(AgentLaunchDefaults.StorageKey.claudeModel)
    private var claudeModel = AgentLaunchDefaults.standard.claudeModel
    @AppStorage(AgentLaunchDefaults.StorageKey.claudeReasoningEffort)
    private var claudeReasoningEffort = AgentLaunchDefaults.standard.claudeReasoningEffort
    @AppStorage("agentComposer.codexFastModeEnabled")
    private var codexFastModeEnabled = false
    @AppStorage("agentComposer.claudeFastModeEnabled")
    private var claudeFastModeEnabled = false

    @State private var draft = ""
    @State private var attachments: [ComposerAttachment] = []
    @State private var pasteNotice: String?
    @State private var isEditorFocused = false
    @State private var isShowingModelPanel = false
    @State private var selectedModelSection: ModelPanelSection?
    @State private var pendingNativeSubmissions: [PendingNativeSubmission] = []
    @State private var nativeSubmissionInFlightID: UUID?
    @State private var nativeSubmissionAttachmentCount = 0
    @StateObject private var modelPanelClickMonitor = ModelPanelClickMonitor()

    private static let codexModels = [
        CodexModelOption(id: "gpt-5.6-sol", name: "5.6 Sol", pickerIndex: 0),
        CodexModelOption(id: "gpt-5.6-terra", name: "5.6 Terra", pickerIndex: 1),
        CodexModelOption(
            id: "gpt-5.6-luna",
            name: "5.6 Luna",
            pickerIndex: 2,
            supportsUltra: false
        )
    ]

    private var canSend: Bool {
        AgentComposerSendPolicy.canSend(
            status: session.status,
            usesNativeChat: session.usesNativeChat,
            isWorking: session.isWorking,
            draft: draft,
            hasUploadingAttachments: attachments.contains(where: \.isUploading),
            hasFailedAttachments: attachments.contains { $0.errorMessage != nil },
            hasUploadedAttachments: !attachments.isEmpty,
            isSubmitting: nativeSubmissionInFlightID != nil
        )
    }

    private var editorHeight: CGFloat {
        let lineCount = max(
            2,
            draft.split(separator: "\n", omittingEmptySubsequences: false).count
        )
        return min(80, 8 + (CGFloat(lineCount) * 18))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                PromptEditor(
                    text: $draft,
                    onSubmit: send,
                    onPasteFiles: pasteFiles,
                    onPasteImages: addImages,
                    onEscape: handleEscape,
                    onFocusChange: { isEditorFocused = $0 }
                )

                if draft.isEmpty, !isEditorFocused {
                    Text("Ask anything")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 10)
                        .padding(.top, 5)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: editorHeight)

            if !attachments.isEmpty {
                attachmentStrip
                    .padding(.bottom, 8)
            }

            if nativeSubmissionInFlightID != nil,
               nativeSubmissionAttachmentCount > 0 {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Uploading attachments…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
            }

            if let pasteNotice {
                Text(pasteNotice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .padding(.bottom, 8)
            }

            HStack(spacing: 10) {
                modelControls

                if supportsFileAttachments {
                    Button(action: chooseFiles) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 30, height: 30)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(session.status != .running || nativeSubmissionInFlightID != nil)
                    .accessibilityLabel("Attach files")
                    .help("Attach files")
                }

                Spacer(minLength: 8)

                if session.isWorking {
                    Button {
                        session.interrupt()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(stopButtonForeground)
                            .frame(width: 30, height: 30)
                            .background(stopButtonBackground, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop current turn")
                    .accessibilityHint(
                        "Stops only the current turn. Press Escape twice to use the keyboard."
                    )
                    .help("Stop current work (Escape twice)")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(sendButtonForeground)
                            .frame(width: 30, height: 30)
                            .background(sendButtonBackground, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel("Send message")
                    .accessibilityHint("Return sends. Shift Return inserts a new line.")
                    .help("Send message (Return)")
                }
            }
            .frame(height: 30)
        }
        .padding(.top, 6)
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.bottom, 5)
        .frame(maxWidth: session.usesNativeChat ? 760 : .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(composerSurface)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(composerBorder, lineWidth: 1)
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(session.usesNativeChat ? Color.clear : composerBackdrop)
        .background {
            if let store = session.chatCoordinator?.store,
               !pendingNativeSubmissions.isEmpty {
                NativeComposerStoreObserver(store: store) { snapshot in
                    reconcileNativeSubmission(with: snapshot)
                }
            }
        }
        .onExitCommand {
            if !session.usesNativeChat || !session.isWorking {
                handleEscape(isRepeat: false)
            }
        }
        .onAppear {
            modelPanelClickMonitor.start {
                closeModelPanel()
            }
            modelPanelClickMonitor.isActive = isShowingModelPanel
            synchronizeNativeChatLaunchOptions()
        }
        .onChange(of: isShowingModelPanel) { _, isShowing in
            modelPanelClickMonitor.isActive = isShowing
        }
        .onDisappear {
            modelPanelClickMonitor.stop()
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 6) {
                        if let preview = attachment.preview {
                            Image(nsImage: preview)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 26, height: 26)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        } else {
                            Image(systemName: "doc")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                                .frame(width: 26, height: 26)
                        }

                        Text(attachment.name)
                            .font(.caption)

                        if attachment.isUploading {
                            ProgressView()
                                .controlSize(.mini)
                        } else if attachment.errorMessage != nil {
                            Button {
                                if let index = attachments.firstIndex(where: {
                                    $0.id == attachment.id
                                }) {
                                    attachments[index].state = .ready
                                }
                            } label: {
                                Image(systemName: "arrow.clockwise.circle.fill")
                                    .foregroundStyle(.orange)
                            }
                            .buttonStyle(.plain)
                            .help("Retry: \(attachment.errorMessage ?? "Upload failed")")
                            .accessibilityLabel("Retry \(attachment.name)")
                        }

                        Button {
                            attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Remove \(attachment.name)")
                    }
                    .padding(.leading, 4)
                    .padding(.trailing, 7)
                    .padding(.vertical, 4)
                    .background(
                        Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var modelControls: some View {
        Button {
            withAnimation(.easeOut(duration: 0.14)) {
                isShowingModelPanel.toggle()
                selectedModelSection = nil
            }
        } label: {
            HStack(spacing: 4) {
                (
                    Text(modelDisplayName)
                        .foregroundColor(.primary)
                    + Text(" \(selectedReasoningEffort.displayName.capitalized)")
                        .foregroundColor(.secondary)
                )
                .font(.system(size: 13))
                .lineLimit(1)

                Image(systemName: isShowingModelPanel ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                Color.white.opacity(isShowingModelPanel ? 0.1 : 0),
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .textSelection(.disabled)
        .onHover { isHovering in
            modelPanelClickMonitor.isPointerInsideControl = isHovering
            (isHovering ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        .disabled(session.status != .running)
        .accessibilityLabel("Model and reasoning controls")
        .accessibilityValue(
            "\(modelDisplayName), \(selectedReasoningEffort.displayName.capitalized), \(isFastModeEnabled ? "Fast" : "Standard")"
        )
        .help("Change \(session.kind.displayName) model or reasoning effort")
        .overlay(alignment: .bottomTrailing) {
            if isShowingModelPanel {
                modelSelectionPanel
                    .offset(y: -38)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .zIndex(20)
            }
        }
        .zIndex(20)
    }

    private var modelSelectionPanel: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(spacing: 0) {
                panelModelControl
                panelEffortControl
                panelSpeedControl
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: 215)
            .panelSurface(nativeChat: session.usesNativeChat)

            if let selectedModelSection {
                sectionPanel(selectedModelSection)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .textSelection(.disabled)
        .onHover { isHovering in
            modelPanelClickMonitor.isPointerInsidePanel = isHovering
        }
    }

    private var panelModelControl: some View {
        Button {
            withAnimation(.easeOut(duration: 0.14)) {
                selectedModelSection = selectedModelSection == .model ? nil : .model
            }
        } label: {
            panelRow(title: "Model", value: modelDisplayName, section: .model)
        }
        .buttonStyle(.plain)
        .modelPanelCursor()
    }

    private var panelEffortControl: some View {
        Button {
            withAnimation(.easeOut(duration: 0.14)) {
                selectedModelSection = selectedModelSection == .effort ? nil : .effort
            }
        } label: {
            panelRow(
                title: "Effort",
                value: selectedReasoningEffort.displayName.capitalized,
                section: .effort
            )
        }
        .buttonStyle(.plain)
        .modelPanelCursor()
    }

    private var panelSpeedControl: some View {
        Button {
            withAnimation(.easeOut(duration: 0.14)) {
                selectedModelSection = selectedModelSection == .speed ? nil : .speed
            }
        } label: {
            panelRow(
                title: "Speed",
                value: isFastModeEnabled ? "Fast" : "Standard",
                section: .speed
            )
        }
        .buttonStyle(.plain)
        .modelPanelCursor()
    }

    private func panelRow(
        title: String,
        value: String,
        section: ModelPanelSection
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.primary)
            Spacer()
            (
                Text(value)
                    .foregroundColor(.secondary)
                + Text("  ")
                + Text(Image(systemName: "chevron.right"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
            )
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(
            Color.white.opacity(selectedModelSection == section ? 0.1 : 0),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func sectionPanel(_ section: ModelPanelSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(section.title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 34)

            switch section {
            case .model:
                ForEach(modelOptions, id: \.id) { model in
                    selectionRow(
                        title: model.name,
                        isSelected: selectedModelID == model.id
                    ) {
                        setModel(model.id)
                    }
                }

            case .effort:
                ForEach(availableReasoningEfforts) { effort in
                    selectionRow(
                        title: effort.displayName.capitalized,
                        isSelected: selectedReasoningEffort == effort
                    ) {
                        setReasoningEffort(effort)
                    }
                }

                if session.kind == .codex,
                   availableReasoningEfforts.contains(where: { $0 == .max || $0 == .ultra }) {
                    Text("Consumes usage limits faster")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 2)
                        .padding(.bottom, 6)
                }

            case .speed:
                selectionRow(title: "Standard", isSelected: !isFastModeEnabled) {
                    setFastMode(false)
                }
                selectionRow(title: "Fast", isSelected: isFastModeEnabled) {
                    setFastMode(true)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: 205)
        .panelSurface(nativeChat: session.usesNativeChat)
    }

    private func selectionRow(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modelPanelCursor()
    }

    private var modelOptions: [(id: String, name: String)] {
        if session.kind == .codex {
            return Self.codexModels.map { ($0.id, $0.name) }
        }
        return ["fable", "opus", "sonnet"].map { ($0, $0.capitalized) }
    }

    private var selectedModelID: String {
        session.kind == .codex ? codexModel : claudeModel
    }

    private var availableReasoningEfforts: [AgentReasoningEffort] {
        if session.kind == .claude {
            return AgentReasoningEffort.allCases.filter { $0 != .ultra }
        }
        guard let selectedModel = Self.codexModels.first(where: { $0.id == codexModel }),
              !selectedModel.supportsUltra else {
            return AgentReasoningEffort.allCases
        }
        return AgentReasoningEffort.allCases.filter { $0 != .ultra }
    }

    private func setModel(_ model: String) {
        if session.kind == .claude {
            claudeModel = model
            if model != "opus" {
                claudeFastModeEnabled = false
            }
            if !session.usesNativeChat {
                sendCommand("/model \(model)")
            }
        } else if let option = Self.codexModels.first(where: { $0.id == model }) {
            let effort: AgentReasoningEffort =
                codexReasoningEffort == .ultra && !option.supportsUltra
                ? .max
                : codexReasoningEffort
            codexModel = option.id
            codexReasoningEffort = effort
            if !session.usesNativeChat {
                session.selectCodexModel(pickerIndex: option.pickerIndex, effort: effort)
            }
        }
        synchronizeNativeChatLaunchOptions()
        closeModelPanel()
    }

    private func setReasoningEffort(_ effort: AgentReasoningEffort) {
        if session.kind == .claude {
            claudeReasoningEffort = effort
            if !session.usesNativeChat {
                sendCommand("/effort \(effort.rawValue)")
            }
        } else if let option = Self.codexModels.first(where: { $0.id == codexModel }) {
            codexReasoningEffort = effort
            if !session.usesNativeChat {
                session.selectCodexModel(pickerIndex: option.pickerIndex, effort: effort)
            }
        }
        synchronizeNativeChatLaunchOptions()
        closeModelPanel()
    }

    private func setFastMode(_ isEnabled: Bool) {
        if session.kind == .codex {
            guard codexFastModeEnabled != isEnabled else {
                closeModelPanel()
                return
            }
            codexFastModeEnabled = isEnabled
            if !session.usesNativeChat {
                sendCommand(isEnabled ? "/fast on" : "/fast off")
            }
        } else {
            guard claudeFastModeEnabled != isEnabled else {
                closeModelPanel()
                return
            }
            claudeFastModeEnabled = isEnabled
            if isEnabled {
                claudeModel = "opus"
            }
            if !session.usesNativeChat {
                sendCommand("/fast")
            }
        }
        synchronizeNativeChatLaunchOptions()
        closeModelPanel()
    }

    private func closeModelPanel() {
        withAnimation(.easeOut(duration: 0.14)) {
            selectedModelSection = nil
            isShowingModelPanel = false
        }
    }

    private var modelDisplayName: String {
        let model = session.kind == .codex ? codexModel : claudeModel
        return model
            .replacingOccurrences(of: "gpt-", with: "")
            .split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    private var selectedReasoningEffort: AgentReasoningEffort {
        session.kind == .codex ? codexReasoningEffort : claudeReasoningEffort
    }

    private var isFastModeEnabled: Bool {
        session.kind == .codex ? codexFastModeEnabled : claudeFastModeEnabled
    }

    private var supportsFileAttachments: Bool {
        session.usesNativeChat
            && session.kind == .codex
            && session.chatCoordinator?.store.state.capabilities
                .supportsFileAttachments == true
    }

    private func send() {
        guard canSend else { return }

        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if session.usesNativeChat {
            guard let coordinator = session.chatCoordinator else { return }
            let requestID = UUID().uuidString.lowercased()
            let submissionID = UUID()
            let submittedDraft = draft
            let submittedAttachments = attachments
            nativeSubmissionInFlightID = submissionID
            nativeSubmissionAttachmentCount = submittedAttachments.count
            draft = ""
            attachments.removeAll()
            pasteNotice = nil
            Task {
                await uploadAndSendNative(
                    coordinator: coordinator,
                    submissionID: submissionID,
                    requestID: requestID,
                    text: text,
                    submittedDraft: submittedDraft,
                    submittedAttachments: submittedAttachments
                )
            }
            return
        }

        let remotePaths = attachments.compactMap(\.remotePath)
        var prompt = text
        if !remotePaths.isEmpty {
            if prompt.isEmpty {
                prompt = "Please review the attached \(remotePaths.count == 1 ? "image" : "images")."
            }
            prompt += "\n\nAttached \(remotePaths.count == 1 ? "image" : "images"):\n"
            prompt += remotePaths.map { "- `\($0)`" }.joined(separator: "\n")
        }

        session.sendPrompt(prompt)
        draft = ""
        attachments.removeAll()
        pasteNotice = nil
    }

    @MainActor
    private func uploadAndSendNative(
        coordinator: ConversationCoordinator,
        submissionID: UUID,
        requestID: String,
        text: String,
        submittedDraft: String,
        submittedAttachments: [ComposerAttachment]
    ) async {
        var structuredAttachments: [ChatAttachmentReference] = []
        do {
            for attachment in submittedAttachments {
                structuredAttachments.append(
                    try await AgentAttachmentService.upload(
                        attachment.draft,
                        requestID: requestID,
                        session: session,
                        worker: worker
                    )
                )
            }
        } catch {
            await AgentAttachmentService.discardUpload(
                requestID: requestID,
                session: session,
                worker: worker
            )
            restoreNativeComposer(
                draft: submittedDraft,
                attachments: submittedAttachments.map {
                    var restored = $0
                    restored.state = .failed(error.localizedDescription)
                    return restored
                }
            )
            if nativeSubmissionInFlightID == submissionID {
                nativeSubmissionInFlightID = nil
            }
            return
        }

        var prompt = text
        if prompt.isEmpty, !structuredAttachments.isEmpty {
            prompt = "Please review the attached \(structuredAttachments.count == 1 ? "file" : "files")."
        }
        synchronizeNativeChatLaunchOptions()
        let submission = PendingNativeSubmission(
            id: submissionID,
            requestID: requestID,
            prompt: prompt,
            draft: submittedDraft,
            attachments: submittedAttachments,
            structuredAttachments: structuredAttachments
        )
        pendingNativeSubmissions.append(submission)
        if pendingNativeSubmissions.count > ChatAttachmentPolicy.maximumCount {
            pendingNativeSubmissions.removeFirst(
                pendingNativeSubmissions.count - ChatAttachmentPolicy.maximumCount
            )
        }
        let wasSent = await coordinator.send(
            text: prompt,
            attachments: structuredAttachments,
            requestID: requestID
        )
        guard wasSent else {
            pendingNativeSubmissions.removeAll { $0.id == submission.id }
            coordinator.store.clearComposer()
            await AgentAttachmentService.discardUpload(
                requestID: requestID,
                session: session,
                worker: worker
            )
            restoreNativeComposer(
                draft: submittedDraft,
                attachments: submittedAttachments.map {
                    var restored = $0
                    restored.state = .ready
                    return restored
                }
            )
            if nativeSubmissionInFlightID == submissionID {
                nativeSubmissionInFlightID = nil
            }
            pasteNotice = "The attachments were not added. Retry to upload them again."
            return
        }
        guard pendingNativeSubmissions.contains(where: { $0.id == submission.id }) else {
            return
        }
        reconcileNativeSubmission(
            with: NativeComposerStoreSnapshot(
                draft: coordinator.store.draft,
                attachments: coordinator.store.attachments,
                connectionState: coordinator.store.state.connectionState,
                turnState: coordinator.store.state.turnState,
                activeTurnID: coordinator.store.state.activeTurnID
            )
        )
    }

    private func restoreNativeComposer(
        draft restoredDraft: String,
        attachments restoredAttachments: [ComposerAttachment]
    ) {
        if draft.isEmpty {
            draft = restoredDraft
        } else if !restoredDraft.isEmpty, draft != restoredDraft {
            draft = "\(restoredDraft)\n\n\(draft)"
        }
        let existingAttachmentIDs = Set(attachments.map(\.id))
        attachments.insert(
            contentsOf: restoredAttachments.filter {
                !existingAttachmentIDs.contains($0.id)
            },
            at: 0
        )
    }

    private func reconcileNativeSubmission(
        with snapshot: NativeComposerStoreSnapshot
    ) {
        let matchingIndex = pendingNativeSubmissions.firstIndex {
            $0.id == nativeSubmissionInFlightID
                && AgentComposerRestorationPolicy.shouldRestore(
                    submittedPrompt: $0.prompt,
                    submittedAttachments: $0.structuredAttachments,
                    restoredDraft: snapshot.draft,
                    restoredAttachments: snapshot.attachments
                )
        } ?? pendingNativeSubmissions.firstIndex {
            AgentComposerRestorationPolicy.shouldRestore(
                submittedPrompt: $0.prompt,
                submittedAttachments: $0.structuredAttachments,
                restoredDraft: snapshot.draft,
                restoredAttachments: snapshot.attachments
            )
        }

        if let matchingIndex {
            let submission = pendingNativeSubmissions.remove(at: matchingIndex)
            session.chatCoordinator?.store.clearComposer()
            Task {
                await AgentAttachmentService.discardUpload(
                    requestID: submission.requestID,
                    session: session,
                    worker: worker
                )
            }
            if nativeSubmissionInFlightID == submission.id {
                nativeSubmissionInFlightID = nil
            }
            restoreNativeComposer(
                draft: submission.draft,
                attachments: submission.attachments.map {
                    var restored = $0
                    restored.state = .ready
                    return restored
                }
            )
            return
        }

        if AgentComposerSubmissionPolicy.shouldReleaseSendLatch(
            connectionState: snapshot.connectionState,
            turnState: snapshot.turnState,
            activeTurnID: snapshot.activeTurnID
        ) {
            if let activeID = nativeSubmissionInFlightID,
               snapshot.activeTurnID != nil || snapshot.turnState.isActive {
                pendingNativeSubmissions.removeAll { $0.id == activeID }
            }
            nativeSubmissionInFlightID = nil
        }
    }

    private func synchronizeNativeChatLaunchOptions() {
        guard session.usesNativeChat else { return }
        session.updateChatLaunchOptions(
            model: session.kind == .codex ? codexModel : claudeModel,
            reasoningEffort: selectedReasoningEffort.rawValue,
            fastMode: isFastModeEnabled
        )
    }

    private func handleEscape(isRepeat: Bool) {
        if session.usesNativeChat {
            if session.isWorking {
                if isShowingModelPanel, !isRepeat {
                    closeModelPanel()
                }
                onNativeEscape(isRepeat)
            } else {
                if isShowingModelPanel, !isRepeat {
                    closeModelPanel()
                }
            }
        } else if !isRepeat {
            session.sendEscape()
        }
    }

    private var composerSurface: Color {
        session.usesNativeChat
            ? Color(red: 43.0 / 255.0, green: 43.0 / 255.0, blue: 43.0 / 255.0)
            : Color(red: 0.165, green: 0.165, blue: 0.165)
    }

    private var composerBorder: Color {
        session.usesNativeChat
            ? Color.primary.opacity(0.10)
            : Color.white.opacity(0.08)
    }

    private var composerBackdrop: Color {
        session.usesNativeChat
            ? Color(red: 23.0 / 255.0, green: 24.0 / 255.0, blue: 24.0 / 255.0)
            : Color(red: 0.071, green: 0.071, blue: 0.078)
    }

    private var sendButtonForeground: Color {
        if session.usesNativeChat {
            return canSend ? Color(nsColor: .windowBackgroundColor) : .secondary
        }
        return Color.black.opacity(canSend ? 0.9 : 0.62)
    }

    private var sendButtonBackground: Color {
        if session.usesNativeChat {
            return Color.primary.opacity(canSend ? 0.9 : 0.08)
        }
        return Color.white.opacity(canSend ? 0.92 : 0.58)
    }

    private var stopButtonForeground: Color {
        session.usesNativeChat
            ? Color(nsColor: .windowBackgroundColor)
            : Color.black.opacity(0.72)
    }

    private var stopButtonBackground: Color {
        session.usesNativeChat ? Color.primary.opacity(0.9) : Color.white.opacity(0.58)
    }

    private func sendCommand(_ command: String) {
        session.sendCommand(command)
    }

    private func chooseFiles() {
        guard supportsFileAttachments else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.begin { response in
            guard response == .OK else { return }
            addFiles(panel.urls)
        }
    }

    private func pasteFiles(_ urls: [URL]) -> Bool {
        guard supportsFileAttachments else { return false }
        guard session.status == .running,
              nativeSubmissionInFlightID == nil else {
            pasteNotice = "Files can be attached when the session is connected."
            return true
        }
        addFiles(urls)
        return true
    }

    private func addFiles(_ urls: [URL]) {
        pasteNotice = nil
        for url in urls {
            do {
                let resourceValues = try url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .fileSizeKey,
                    .isSymbolicLinkKey,
                ])
                guard resourceValues.isRegularFile == true,
                      resourceValues.isSymbolicLink != true else {
                    throw AgentAttachmentUploadError.failed
                }
                if let fileSize = resourceValues.fileSize,
                   fileSize > ChatAttachmentPolicy.maximumFileBytes {
                    throw AgentAttachmentUploadError.tooLarge
                }
                let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
                if let type, type.conforms(to: .image),
                   let image = NSImage(contentsOf: url),
                   let clipboardImage = ClipboardImage.make(from: image) {
                    try appendDraft(
                        ChatAttachmentDraft(
                            displayName: safeDisplayName(url.lastPathComponent),
                            mediaType: "image/png",
                            kind: .image,
                            fileExtension: "png",
                            data: clipboardImage.pngData
                        )
                    )
                } else {
                    let loaded = try Data(contentsOf: url, options: .mappedIfSafe)
                    let data = Data(loaded)
                    try appendDraft(
                        ChatAttachmentDraft(
                            displayName: safeDisplayName(url.lastPathComponent),
                            mediaType: type?.preferredMIMEType ?? "application/octet-stream",
                            kind: .file,
                            fileExtension: type?.preferredFilenameExtension
                                ?? url.pathExtension,
                            data: data
                        )
                    )
                }
            } catch {
                pasteNotice = error.localizedDescription
                break
            }
        }
    }

    private func appendDraft(_ draft: ChatAttachmentDraft) throws {
        let existingBytes = attachments.reduce(0) { $0 + $1.draft.byteCount }
        guard ChatAttachmentPolicy.accepts(
            byteCount: draft.byteCount,
            existingCount: attachments.count,
            existingBytes: existingBytes
        ) else {
            if draft.byteCount > ChatAttachmentPolicy.maximumFileBytes {
                throw AgentAttachmentUploadError.tooLarge
            }
            throw AgentAttachmentUploadError.failed
        }
        attachments.append(ComposerAttachment(draft: draft, state: .ready))
    }

    private func safeDisplayName(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            let replacement = CharacterSet.controlCharacters.contains(scalar) ? "_" : String(scalar)
            guard result.utf8.count + replacement.utf8.count <= 512 else { break }
            result.append(contentsOf: replacement)
        }
        return result.isEmpty ? "Attachment" : result
    }

    private func addImages(_ images: [ClipboardImage]) {
        guard session.status == .running else { return }
        pasteNotice = nil

        for image in images {
            do {
                let index = attachments.count + 1
                try appendDraft(
                    ChatAttachmentDraft(
                        displayName: "Image \(index)",
                        mediaType: "image/png",
                        kind: .image,
                        fileExtension: "png",
                        data: image.pngData
                    )
                )
                if !session.usesNativeChat,
                   let attachment = attachments.last {
                    attachments[attachments.count - 1].state = .uploading
                    Task {
                        do {
                            let reference = try await AgentAttachmentService.upload(
                                attachment.draft,
                                requestID: UUID().uuidString.lowercased(),
                                session: session,
                                worker: worker
                            )
                            guard let found = attachments.firstIndex(where: {
                                $0.id == attachment.id
                            }) else { return }
                            attachments[found].state = .uploaded(reference)
                        } catch {
                            guard let found = attachments.firstIndex(where: {
                                $0.id == attachment.id
                            }) else { return }
                            attachments[found].state = .failed(error.localizedDescription)
                        }
                    }
                }
            } catch {
                pasteNotice = error.localizedDescription
                break
            }
        }
    }
}

private enum ModelPanelSection {
    case model
    case effort
    case speed

    var title: String {
        switch self {
        case .model: "Model"
        case .effort: "Effort"
        case .speed: "Speed"
        }
    }
}

private struct CodexModelOption {
    let id: String
    let name: String
    let pickerIndex: Int
    var supportsUltra = true
}

private extension View {
    func panelSurface(nativeChat: Bool) -> some View {
        background(
            nativeChat
                ? Color(nsColor: .controlBackgroundColor)
                : Color(red: 0.165, green: 0.165, blue: 0.165),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    nativeChat
                        ? Color(nsColor: .separatorColor)
                        : Color.white.opacity(0.16),
                    lineWidth: 1
                )
        }
        .shadow(
            color: .black.opacity(nativeChat ? 0.14 : 0.28),
            radius: 18,
            y: 8
        )
    }

    func modelPanelCursor() -> some View {
        contentShape(Rectangle())
            .onHover { isHovering in
                (isHovering ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
    }
}

@MainActor
private final class ModelPanelClickMonitor: ObservableObject {
    var isActive = false
    var isPointerInsideControl = false
    var isPointerInsidePanel = false

    private var eventMonitor: Any?

    func start(onOutsideClick: @escaping @MainActor () -> Void) {
        stop()
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self,
                  self.isActive,
                  !self.isPointerInsideControl,
                  !self.isPointerInsidePanel else {
                return event
            }
            DispatchQueue.main.async {
                onOutsideClick()
            }
            return event
        }
    }

    func stop() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        isActive = false
        isPointerInsideControl = false
        isPointerInsidePanel = false
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }
}

private struct ComposerAttachment: Identifiable {
    enum State {
        case ready
        case uploading
        case uploaded(ChatAttachmentReference)
        case failed(String)
    }

    let draft: ChatAttachmentDraft
    var state: State

    var id: String { draft.id }
    var name: String { draft.displayName }
    var preview: NSImage? {
        draft.kind == .image ? NSImage(data: draft.data) : nil
    }

    var isUploading: Bool {
        if case .uploading = state { return true }
        return false
    }

    var isUploaded: Bool {
        remotePath != nil
    }

    var remotePath: String? {
        if case .uploaded(let reference) = state { return reference.path }
        return nil
    }

    var errorMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }
}

private struct PendingNativeSubmission {
    let id: UUID
    let requestID: String
    let prompt: String
    let draft: String
    let attachments: [ComposerAttachment]
    let structuredAttachments: [ChatAttachmentReference]
}

private struct NativeComposerStoreSnapshot: Equatable {
    let draft: String
    let attachments: [ChatAttachmentReference]
    let connectionState: ChatConnectionState
    let turnState: TurnState
    let activeTurnID: String?
}

private struct NativeComposerStoreObserver: View {
    @ObservedObject var store: ConversationStore

    let onSnapshot: (NativeComposerStoreSnapshot) -> Void

    private var snapshot: NativeComposerStoreSnapshot {
        NativeComposerStoreSnapshot(
            draft: store.draft,
            attachments: store.attachments,
            connectionState: store.state.connectionState,
            turnState: store.state.turnState,
            activeTurnID: store.state.activeTurnID
        )
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                onSnapshot(snapshot)
            }
            .onChange(of: snapshot) { _, snapshot in
                onSnapshot(snapshot)
            }
    }
}

enum ClipboardFileURLs {
    static func read(from pasteboard: NSPasteboard = .general) -> [URL] {
        pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }
}

private struct ClipboardImage {
    let pngData: Data
    let preview: NSImage

    static func read(from pasteboard: NSPasteboard = .general) -> [ClipboardImage] {
        let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        let fileImages = fileURLs.compactMap { url -> ClipboardImage? in
            guard let type = UTType(filenameExtension: url.pathExtension),
                  type.conforms(to: .image),
                  let image = NSImage(contentsOf: url) else {
                return nil
            }
            return make(from: image)
        }
        if !fileImages.isEmpty {
            return fileImages
        }

        if let pngData = pasteboard.data(forType: .png),
           let image = NSImage(data: pngData) {
            return [ClipboardImage(pngData: pngData, preview: image)]
        }
        guard let image = NSImage(pasteboard: pasteboard),
              let converted = make(from: image) else {
            return []
        }
        return [converted]
    }

    static func make(from image: NSImage) -> ClipboardImage? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return ClipboardImage(pngData: pngData, preview: image)
    }
}

enum AgentComposerSendPolicy {
    static func canSend(
        status: TerminalSessionStatus,
        usesNativeChat: Bool,
        isWorking: Bool,
        draft: String,
        hasUploadingAttachments: Bool,
        hasFailedAttachments: Bool,
        hasUploadedAttachments: Bool,
        isSubmitting: Bool = false
    ) -> Bool {
        status == .running
            && (!usesNativeChat || !isWorking)
            && !isSubmitting
            && !hasUploadingAttachments
            && !hasFailedAttachments
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || hasUploadedAttachments)
    }
}

enum AgentComposerRestorationPolicy {
    static func shouldRestore(
        submittedPrompt: String,
        submittedAttachments: [ChatAttachmentReference],
        restoredDraft: String,
        restoredAttachments: [ChatAttachmentReference]
    ) -> Bool {
        restoredDraft == submittedPrompt
            && restoredAttachments == submittedAttachments
    }
}

enum AgentComposerSubmissionPolicy {
    static func shouldReleaseSendLatch(
        connectionState: ChatConnectionState,
        turnState: TurnState,
        activeTurnID: String?
    ) -> Bool {
        if activeTurnID != nil || turnState.isActive {
            return true
        }
        switch connectionState {
        case .offlineAgentRunning, .failed, .stopped, .unsupportedWorker:
            return true
        case .connecting, .streaming, .awaitingApproval, .interrupted, .unknown:
            return false
        }
    }
}

enum AgentComposerKeyAction: Equatable {
    case submit
    case insertNewline
    case escape
    case system
}

enum AgentComposerKeyPolicy {
    static func action(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> AgentComposerKeyAction {
        if keyCode == 53 {
            return .escape
        }
        let usesReturn = keyCode == 36 || keyCode == 76
        guard usesReturn else { return .system }
        return modifiers.contains(.shift) ? .insertNewline : .submit
    }
}

private struct PromptEditor: NSViewRepresentable {
    @Binding var text: String

    let onSubmit: () -> Void
    let onPasteFiles: ([URL]) -> Bool
    let onPasteImages: ([ClipboardImage]) -> Void
    let onEscape: (Bool) -> Void
    let onFocusChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .systemFont(ofSize: 14)
        textView.insertionPointColor = .secondaryLabelColor
        textView.textContainerInset = NSSize(width: 5, height: 5)
        textView.minSize = NSSize(width: 0, height: 44)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.setAccessibilityLabel("Message")
        textView.setAccessibilityHelp("Return sends. Shift Return inserts a new line.")
        textView.onSubmit = onSubmit
        textView.onPasteFiles = onPasteFiles
        textView.onPasteImages = onPasteImages
        textView.onEscape = onEscape
        textView.onFocusChange = onFocusChange

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        DispatchQueue.main.async {
            guard let window = textView.window else { return }
            window.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.insertionPointColor = .secondaryLabelColor
        textView.onSubmit = onSubmit
        textView.onPasteFiles = onPasteFiles
        textView.onPasteImages = onPasteImages
        textView.onEscape = onEscape
        textView.onFocusChange = onFocusChange
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}

private final class ComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onPasteFiles: (([URL]) -> Bool)?
    var onPasteImages: (([ClipboardImage]) -> Void)?
    var onEscape: ((Bool) -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    override func keyDown(with event: NSEvent) {
        switch AgentComposerKeyPolicy.action(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags
        ) {
        case .escape:
            onEscape?(event.isARepeat)
        case .submit:
            onSubmit?()
        case .insertNewline, .system:
            super.keyDown(with: event)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            onFocusChange?(true)
        }
        return didBecomeFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let didResignFirstResponder = super.resignFirstResponder()
        if didResignFirstResponder {
            onFocusChange?(false)
        }
        return didResignFirstResponder
    }

    override func paste(_ sender: Any?) {
        let fileURLs = ClipboardFileURLs.read()
        if !fileURLs.isEmpty, onPasteFiles?(fileURLs) == true {
            return
        }
        let images = ClipboardImage.read()
        if images.isEmpty {
            super.paste(sender)
        } else {
            onPasteImages?(images)
        }
    }
}
