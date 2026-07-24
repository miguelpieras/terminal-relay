import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AgentComposerView: View {
    @ObservedObject var session: TerminalSession

    let worker: ServerProfile

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

    @State private var draft = ""
    @State private var attachments: [ComposerAttachment] = []
    @State private var pasteNotice: String?
    @State private var isEditorFocused = false
    @State private var isShowingModelPanel = false
    @State private var isAdvancedExpanded = true
    @State private var selectedModelSection: ModelPanelSection?

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
        session.status == .running
            && !attachments.contains(where: \.isUploading)
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || attachments.contains(where: \.isUploaded))
    }

    private var editorHeight: CGFloat {
        let lineCount = max(
            1,
            draft.split(separator: "\n", omittingEmptySubsequences: false).count
        )
        return min(72, 30 + (CGFloat(lineCount - 1) * 20))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                PromptEditor(
                    text: $draft,
                    onSubmit: send,
                    onPasteImages: addImages,
                    onEscape: session.sendEscape,
                    onFocusChange: { isEditorFocused = $0 }
                )

                if draft.isEmpty, !isEditorFocused {
                    Text("Do anything")
                        .font(.system(size: 16))
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

            if let pasteNotice {
                Text(pasteNotice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .padding(.bottom, 8)
            }

            HStack(spacing: 10) {
                commandMenu
                Spacer(minLength: 8)

                modelControls

                if session.isWorking {
                    Button {
                        session.interrupt()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.black.opacity(0.72))
                            .frame(width: 30, height: 30)
                            .background(Color.white.opacity(0.58), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Interrupt current work")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.black.opacity(canSend ? 0.9 : 0.62))
                            .frame(width: 30, height: 30)
                            .background(
                                Color.white.opacity(canSend ? 0.92 : 0.58),
                                in: Circle()
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send message (Return)")
                }
            }
            .frame(height: 30)
        }
        .padding(.top, 6)
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.bottom, 5)
        .background(
            Color(red: 0.165, green: 0.165, blue: 0.165),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(red: 0.071, green: 0.071, blue: 0.078))
        .onExitCommand {
            session.sendEscape()
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 6) {
                        Image(nsImage: attachment.preview)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 26, height: 26)
                            .clipShape(RoundedRectangle(cornerRadius: 5))

                        Text(attachment.name)
                            .font(.caption)

                        if attachment.isUploading {
                            ProgressView()
                                .controlSize(.mini)
                        } else if attachment.errorMessage != nil {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help(attachment.errorMessage ?? "")
                        }

                        Button {
                            attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
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

    private var commandMenu: some View {
        Menu {
            Button("New chat") {
                sendCommand(session.kind == .codex ? "/new" : "/clear")
            }
            Button("Compact context") {
                sendCommand("/compact")
            }
            Divider()
            Button("Show status") {
                sendCommand(session.kind == .codex ? "/status" : "/context")
            }
            Button("Show usage") {
                sendCommand("/usage")
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                Text("Custom")
                    .font(.system(size: 13))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(session.status != .running || session.isWorking)
        .help("Agent commands")
    }

    private var modelControls: some View {
        Button {
            withAnimation(.easeOut(duration: 0.14)) {
                isShowingModelPanel.toggle()
                selectedModelSection = nil
            }
        } label: {
            ZStack {
                (
                    Text(modelDisplayName)
                        .foregroundColor(.primary)
                    + Text(" \(selectedReasoningEffort.displayName.capitalized)")
                        .foregroundColor(.secondary)
                )
                .font(.system(size: 13))
                .lineLimit(1)

                HStack {
                    Spacer()
                    Image(systemName: isShowingModelPanel ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.trailing, 11)
            }
            .frame(width: 190, height: 30)
            .background(
                Color.white.opacity(isShowingModelPanel ? 0.1 : 0),
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .textSelection(.disabled)
        .onHover { isHovering in
            (isHovering ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        .disabled(session.status != .running)
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
                if isAdvancedExpanded {
                    panelModelControl
                    panelEffortControl
                    panelSpeedControl

                    Divider()
                        .overlay(Color.white.opacity(0.08))
                }

                Button {
                    withAnimation(.easeOut(duration: 0.14)) {
                        isAdvancedExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("Advanced")
                        Image(systemName: isAdvancedExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                        Spacer()
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(height: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: 215)
            .panelSurface()

            if let selectedModelSection {
                sectionPanel(selectedModelSection)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .textSelection(.disabled)
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
            if session.kind == .codex {
                withAnimation(.easeOut(duration: 0.14)) {
                    selectedModelSection = selectedModelSection == .speed ? nil : .speed
                }
            } else {
                pasteNotice = "Speed control is available for Codex sessions."
            }
        } label: {
            panelRow(
                title: "Speed",
                value: codexFastModeEnabled ? "Fast" : "Standard",
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
                selectionRow(title: "Standard", isSelected: !codexFastModeEnabled) {
                    setCodexFastMode(false)
                }
                selectionRow(title: "Fast", isSelected: codexFastModeEnabled) {
                    setCodexFastMode(true)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: 205)
        .panelSurface()
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
            sendCommand("/model \(model)")
        } else if let option = Self.codexModels.first(where: { $0.id == model }) {
            let effort: AgentReasoningEffort =
                codexReasoningEffort == .ultra && !option.supportsUltra
                ? .max
                : codexReasoningEffort
            codexModel = option.id
            codexReasoningEffort = effort
            session.selectCodexModel(pickerIndex: option.pickerIndex, effort: effort)
        }
        closeModelPanel()
    }

    private func setReasoningEffort(_ effort: AgentReasoningEffort) {
        if session.kind == .claude {
            claudeReasoningEffort = effort
            sendCommand("/effort \(effort.rawValue)")
        } else if let option = Self.codexModels.first(where: { $0.id == codexModel }) {
            codexReasoningEffort = effort
            session.selectCodexModel(pickerIndex: option.pickerIndex, effort: effort)
        }
        closeModelPanel()
    }

    private func setCodexFastMode(_ isEnabled: Bool) {
        codexFastModeEnabled = isEnabled
        sendCommand(isEnabled ? "/fast on" : "/fast off")
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

    private func send() {
        guard canSend else { return }

        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func sendCommand(_ command: String) {
        session.sendCommand(command)
    }

    private func addImages(_ images: [ClipboardImage]) {
        guard session.status == .running else { return }
        pasteNotice = nil

        for image in images {
            let attachment = ComposerAttachment(
                name: "Image \(attachments.count + 1)",
                preview: image.preview
            )
            attachments.append(attachment)

            Task {
                do {
                    let path = try await AgentAttachmentService.upload(
                        pngData: image.pngData,
                        session: session,
                        worker: worker
                    )
                    guard let index = attachments.firstIndex(where: {
                        $0.id == attachment.id
                    }) else { return }
                    attachments[index].state = .uploaded(path)
                } catch {
                    guard let index = attachments.firstIndex(where: {
                        $0.id == attachment.id
                    }) else { return }
                    attachments[index].state = .failed(error.localizedDescription)
                }
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
    func panelSurface() -> some View {
        background(
            Color(red: 0.165, green: 0.165, blue: 0.165),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    }

    func modelPanelCursor() -> some View {
        contentShape(Rectangle())
            .onHover { isHovering in
                (isHovering ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
    }
}

private struct ComposerAttachment: Identifiable {
    enum State {
        case uploading
        case uploaded(String)
        case failed(String)
    }

    let id = UUID()
    let name: String
    let preview: NSImage
    var state: State = .uploading

    var isUploading: Bool {
        if case .uploading = state { return true }
        return false
    }

    var isUploaded: Bool {
        remotePath != nil
    }

    var remotePath: String? {
        if case .uploaded(let path) = state { return path }
        return nil
    }

    var errorMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
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

    private static func make(from image: NSImage) -> ClipboardImage? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return ClipboardImage(pngData: pngData, preview: image)
    }
}

private struct PromptEditor: NSViewRepresentable {
    @Binding var text: String

    let onSubmit: () -> Void
    let onPasteImages: ([ClipboardImage]) -> Void
    let onEscape: () -> Void
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
        textView.font = .systemFont(ofSize: 16)
        textView.textContainerInset = NSSize(width: 5, height: 5)
        textView.minSize = NSSize(width: 0, height: 30)
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
        textView.onSubmit = onSubmit
        textView.onPasteImages = onPasteImages
        textView.onEscape = onEscape
        textView.onFocusChange = onFocusChange

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.onSubmit = onSubmit
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
    var onPasteImages: (([ClipboardImage]) -> Void)?
    var onEscape: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }

        let usesReturn = event.keyCode == 36 || event.keyCode == 76
        if usesReturn, !event.modifierFlags.contains(.shift) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
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
        let images = ClipboardImage.read()
        if images.isEmpty {
            super.paste(sender)
        } else {
            onPasteImages?(images)
        }
    }
}
