import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AgentComposerView: View {
    @ObservedObject var session: TerminalSession

    let worker: ServerProfile

    @AppStorage(AgentLaunchDefaults.StorageKey.claudeModel)
    private var claudeModel = AgentLaunchDefaults.standard.claudeModel
    @AppStorage(AgentLaunchDefaults.StorageKey.claudeReasoningEffort)
    private var claudeReasoningEffort = AgentLaunchDefaults.standard.claudeReasoningEffort

    @State private var draft = ""
    @State private var attachments: [ComposerAttachment] = []
    @State private var pasteNotice: String?

    private var canSend: Bool {
        session.status == .running
            && !attachments.contains(where: \.isUploading)
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || attachments.contains(where: \.isUploaded))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !attachments.isEmpty {
                attachmentStrip
            }

            if let pasteNotice {
                Text(pasteNotice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }

            HStack(alignment: .bottom, spacing: 8) {
                commandMenu
                pasteButton

                ZStack(alignment: .topLeading) {
                    PromptEditor(
                        text: $draft,
                        onSubmit: send,
                        onPasteImages: addImages
                    )

                    if draft.isEmpty {
                        Text("Message \(session.kind == .claude ? "Claude" : "Codex")…")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 9)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 36, maxHeight: 86)
                .background(
                    Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.14), lineWidth: 1)
                }

                modelControls

                if session.isWorking {
                    Button {
                        session.interrupt()
                    } label: {
                        Image(systemName: "stop.fill")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.bordered)
                    .help("Interrupt current work")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send message (Return)")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.bar)
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
            Image(systemName: "slider.horizontal.3")
                .frame(width: 20, height: 20)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(session.status != .running || session.isWorking)
        .help("Agent commands")
    }

    private var pasteButton: some View {
        Button {
            let images = ClipboardImage.read()
            if images.isEmpty {
                pasteNotice = "Copy an image, then paste it here."
            } else {
                addImages(images)
            }
        } label: {
            Image(systemName: "photo.badge.plus")
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderless)
        .disabled(session.status != .running)
        .help("Paste image from clipboard (⌘V)")
    }

    @ViewBuilder
    private var modelControls: some View {
        if session.kind == .claude {
            Menu {
                Section("Model") {
                    ForEach(["fable", "opus", "sonnet"], id: \.self) { model in
                        Button {
                            claudeModel = model
                            sendCommand("/model \(model)")
                        } label: {
                            if claudeModel == model {
                                Label(model.capitalized, systemImage: "checkmark")
                            } else {
                                Text(model.capitalized)
                            }
                        }
                    }

                    Button("Choose another…") {
                        session.sendCommand("/model", focusesTerminal: true)
                    }
                }

                Section("Reasoning effort") {
                    ForEach(AgentReasoningEffort.allCases) { effort in
                        Button {
                            claudeReasoningEffort = effort
                            sendCommand("/effort \(effort.rawValue)")
                        } label: {
                            if claudeReasoningEffort == effort {
                                Label(effort.displayName, systemImage: "checkmark")
                            } else {
                                Text(effort.displayName)
                            }
                        }
                    }
                }
            } label: {
                Label(
                    "\(claudeModel.capitalized) · \(claudeReasoningEffort.displayName)",
                    systemImage: "dial.medium"
                )
                .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(session.status != .running)
            .help("Change Claude model or reasoning effort")
        } else {
            Button {
                session.sendCommand("/model", focusesTerminal: true)
            } label: {
                Label("Model & effort", systemImage: "dial.medium")
            }
            .buttonStyle(.borderless)
            .disabled(session.status != .running)
            .help("Change Codex model and reasoning effort")
        }
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
        textView.textContainerInset = NSSize(width: 5, height: 7)
        textView.minSize = NSSize(width: 0, height: 36)
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

    override func keyDown(with event: NSEvent) {
        let usesReturn = event.keyCode == 36 || event.keyCode == 76
        if usesReturn, !event.modifierFlags.contains(.shift) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
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
