import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The composer, or a notice when sending isn't allowed.
struct ComposerContainer: View {
    @ObservedObject var chat: ChatController
    let scrollToBottom: () -> Void

    var body: some View {
        switch chat.restriction {
        case .none:
            ComposerView(chat: chat, scrollToBottom: scrollToBottom)
        case .blocked:
            RestrictionNoticeView(icon: "hand.raised.fill", key: "restriction.blocked")
        case .verificationRequired:
            RestrictionNoticeView(icon: "person.badge.key.fill", key: "restriction.verification")
        }
    }
}

private struct RestrictionNoticeView: View {
    let icon: String
    let key: String
    @Environment(\.supportStrings) private var strings
    @Environment(\.chatTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .accessibilityHidden(true)
            Text(verbatim: strings(key))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(theme.font(.subheadline, weight: .medium))
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .glassBackground(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }
}

/// Composer metrics from the briefs: 44 pt round controls, a field that grows to six lines, a
/// hint line under it.
struct ComposerView: View {
    @ObservedObject var chat: ChatController
    let scrollToBottom: () -> Void

    @Environment(\.supportStrings) private var strings
    @Environment(\.chatTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    @State private var attachments: [DraftAttachment] = []
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showsPhotoPicker = false
    @State private var showsCamera = false
    @State private var showsFileImporter = false
    @State private var loadingPhotos = 0
    @State private var hint: String?
    @State private var shake: CGFloat = 0

    private var config: SdkConfig? { YapsSupport.shared.engine?.config }
    private var allowsImages: Bool { config?.allowsImages ?? true }
    private var allowsFiles: Bool { config?.allowsFiles ?? true }
    private var remainingSlots: Int { max(0, Validation.attachmentsPerMessage - attachments.count - loadingPhotos) }

    private var validation: ChatController.SendValidation { chat.validate(text: chat.draft, attachments: attachments) }
    private var canSend: Bool { validation == .ok && loadingPhotos == 0 }

    var body: some View {
        VStack(spacing: 8) {
            if !attachments.isEmpty || loadingPhotos > 0 {
                AttachmentTray(attachments: attachments, loading: loadingPhotos, remove: remove)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
            HStack(alignment: .bottom, spacing: 10) {
                if allowsImages || allowsFiles {
                    attachMenu
                }
                field
                sendButton
            }
            .padding(.horizontal, 12)
            hintLine
        }
        .padding(.bottom, 6)
        .animation(reduceMotion ? ChatMotion.reduced : (attachments.isEmpty && loadingPhotos == 0 ? ChatMotion.drawerFold : ChatMotion.drawerOpen),
                   value: attachments.isEmpty && loadingPhotos == 0)
        .animation(reduceMotion ? ChatMotion.reduced : ChatMotion.ui, value: attachments)
        .onAppear {
            if !chat.seededAttachments.isEmpty {
                attachments = chat.seededAttachments
                chat.seededAttachments = []
            }
        }
        .photosPicker(isPresented: $showsPhotoPicker, selection: $photoSelection,
                      maxSelectionCount: max(1, remainingSlots), selectionBehavior: .ordered, matching: .images)
        .onChange(of: photoSelection) { items in
            guard !items.isEmpty else { return }
            photoSelection = []
            Task { await loadPhotos(items) }
        }
        .fullScreenCover(isPresented: $showsCamera) {
            CameraPicker { image in
                Task { await addCameraImage(image) }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: FileAttachmentPolicy.allowedTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { addFiles(urls) }
        }
    }

    // MARK: Controls

    private var attachMenu: some View {
        Menu {
            if allowsImages {
                Button {
                    showsPhotoPicker = true
                } label: {
                    Label(strings("composer.photos"), systemImage: "photo.on.rectangle")
                }
                if CameraPicker.isAvailable {
                    Button {
                        showsCamera = true
                    } label: {
                        Label(strings("composer.camera"), systemImage: "camera")
                    }
                }
            }
            if allowsFiles {
                Button {
                    showsFileImporter = true
                } label: {
                    Label(strings("composer.files"), systemImage: "doc")
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(remainingSlots == 0 ? Color.secondary : Color.primary)
                .frame(width: 44, height: 44)
                .glassBackground(in: Circle(), interactive: true)
                .contentShape(Circle())
        }
        .disabled(remainingSlots == 0)
        .accessibilityLabel(Text(verbatim: strings("composer.attach")))
    }

    private var field: some View {
        TextField(strings("composer.placeholder"), text: $chat.draft, axis: .vertical)
            .font(theme.bubbleFont)
            .tracking(-0.2)
            .lineLimit(1...6)
            .focused($focused)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(minHeight: 44)
            .glassBackground(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                // Focus: the rim brightens, no accent ring.
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.primary.opacity(focused ? 0.22 : 0), lineWidth: 1)
                    .animation(.easeOut(duration: 0.2), value: focused)
            }
            .accessibilityLabel(Text(verbatim: strings("composer.placeholder")))
            .animation(reduceMotion ? nil : ChatMotion.ui, value: chat.draft.count / 30)
    }

    private var sendButton: some View {
        Button(action: send) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Circle().fill(Color.primary.opacity(0.07))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                    Circle().fill(theme.outgoingFill)
                        .overlay(Circle().strokeBorder(LinearGradient(colors: [Color.white.opacity(0.6), .clear],
                                                                      startPoint: .top, endPoint: .center), lineWidth: 1))
                        .opacity(canSend ? 1 : 0)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(canSend ? theme.accentInk : Color.secondary)
                        .offset(y: canSend ? 0 : 1.5)
                }
                .frame(width: 44, height: 44)
                if !attachments.isEmpty {
                    Text(verbatim: "\(attachments.count)")
                        .font(.system(size: 11, weight: .heavy))
                        .monospacedDigit()
                        .foregroundStyle(theme.background)
                        .frame(minWidth: 20, minHeight: 20)
                        .padding(.horizontal, 1)
                        .background(Capsule().fill(Color.primary))
                        .overlay(Capsule().strokeBorder(theme.background, lineWidth: 2))
                        .offset(x: 5, y: -5)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                        .accessibilityHidden(true)
                }
            }
            .animation(reduceMotion ? ChatMotion.reduced : .easeOut(duration: 0.2), value: canSend)
            .animation(reduceMotion ? ChatMotion.reduced : ChatMotion.pop, value: attachments.count)
        }
        .buttonStyle(.squish(0.88))
        .disabled(!canSend)
        .modifier(Shake(amount: shake))
        .accessibilityLabel(Text(verbatim: sendLabel))
    }

    private var sendLabel: String {
        attachments.isEmpty ? strings("composer.send") : "\(strings("composer.send")) · \(attachments.count)"
    }

    /// One neutral hint line: why sending is blocked, or a limit that was hit.
    @ViewBuilder
    private var hintLine: some View {
        let text = validation == .tooLong ? strings("composer.tooLong") : hint
        ZStack {
            if let text {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 12, weight: .semibold))
                    Text(verbatim: text)
                }
                .font(theme.font(.footnote, weight: .medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
                .id(text)
                .transition(.opacity.combined(with: .offset(y: 6)))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(reduceMotion ? ChatMotion.reduced : .easeOut(duration: 0.22), value: text)
    }

    private func send() {
        guard canSend else { return }
        let sent: Bool
        if reduceMotion {
            sent = chat.send(text: chat.draft, attachments: attachments)
        } else {
            sent = withAnimation(ChatMotion.flight) { chat.send(text: chat.draft, attachments: attachments) }
        }
        if sent {
            attachments = []
            hint = nil
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            scrollToBottom()
        } else {
            refuse()
        }
    }

    // MARK: Attachments

    private func remove(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    /// Refuses where it happened: the send button shakes once and the hint says why.
    private func refuse(_ key: String? = nil) {
        if let key { showHint(key) }
        guard !reduceMotion else { return }
        withAnimation(.interpolatingSpring(stiffness: 600, damping: 12)) { shake += 1 }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    private func showHint(_ key: String) {
        let value = strings(key)
        hint = value
        Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if hint == value { hint = nil }
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        let items = Array(items.prefix(max(0, Validation.attachmentsPerMessage - attachments.count - loadingPhotos)))
        loadingPhotos += items.count
        for item in items {
            defer { loadingPhotos -= 1 }
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                showHint("composer.photoLoadFailed")
                continue
            }
            let prepared = await Task.detached(priority: .userInitiated) { ImageProcessor.prepareJPEG(from: data) }.value
            guard let prepared else {
                showHint("composer.photoLoadFailed")
                continue
            }
            append(prepared)
        }
    }

    private func addCameraImage(_ image: UIImage) async {
        guard remainingSlots > 0 else { return refuse("composer.tooManyAttachments") }
        loadingPhotos += 1
        defer { loadingPhotos -= 1 }
        let prepared = await Task.detached(priority: .userInitiated) { ImageProcessor.prepareJPEG(from: image) }.value
        guard let prepared else { return showHint("composer.photoLoadFailed") }
        append(prepared)
    }

    private func append(_ prepared: ImageProcessor.Prepared) {
        guard attachments.count < Validation.attachmentsPerMessage else { return refuse("composer.tooManyAttachments") }
        let preview = UIImage(data: prepared.data)?.preparingThumbnail(of: CGSize(width: 232, height: 184))
        let name = "IMG_\(Int(Date().timeIntervalSince1970 * 1000) % 100_000).jpg"
        attachments.append(DraftAttachment(kind: .image, data: prepared.data, contentType: "image/jpeg", filename: name,
                                           width: prepared.width, height: prepared.height, preview: preview))
    }

    private func addFiles(_ urls: [URL]) {
        for url in urls {
            guard attachments.count < Validation.attachmentsPerMessage else { return refuse("composer.tooManyAttachments") }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let contentType = FileAttachmentPolicy.contentType(for: url),
                  let data = try? Data(contentsOf: url) else {
                refuse("composer.fileUnsupported")
                continue
            }
            guard data.count <= Validation.maxFileBytes else {
                refuse("composer.fileTooLarge")
                continue
            }
            attachments.append(DraftAttachment(kind: .file, data: data, contentType: contentType,
                                               filename: url.lastPathComponent, preview: nil))
        }
    }
}

/// One damped horizontal shake (±7 pt).
private struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let progress = amount - amount.rounded(.down)
        let offset = 7 * sin(progress * .pi * 4) * (1 - progress)
        return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}

/// The picked files before sending, after the `mobile-attachment-tray` brief: a glass drawer with
/// a shelf of 128 pt tiles (radius 20, 116 × 92 preview at radius 14, middle-truncated name, size
/// meta, a 26 pt corner badge) and a meter that fills one accent segment per file.
private struct AttachmentTray: View {
    let attachments: [DraftAttachment]
    let loading: Int
    let remove: (UUID) -> Void

    @Environment(\.chatTheme) private var theme
    @Environment(\.supportStrings) private var strings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(attachments) { attachment in
                        AttachmentTile(attachment: attachment, remove: { remove(attachment.id) })
                            .transition(.asymmetric(insertion: .scale(scale: 0.94).combined(with: .opacity),
                                                    removal: .scale(scale: 0.55).combined(with: .opacity).combined(with: .offset(y: -40))))
                    }
                    ForEach(0..<loading, id: \.self) { _ in
                        LoadingTile()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
            meter
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        }
        .glassBackground(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, 12)
    }

    private var totalBytes: Int { attachments.reduce(0) { $0 + $1.data.count } }

    private var meter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: "\(attachments.count + loading)")
                    .font(theme.font(.subheadline, weight: .bold))
                    .contentTransitionNumeric()
                Text(verbatim: strings.format("tray.ofFiles", Validation.attachmentsPerMessage))
                    .font(theme.font(.footnote))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let size = Formatters.fileSize(totalBytes, locale: strings.locale), totalBytes > 0 {
                    Text(verbatim: size)
                        .font(theme.font(.footnote))
                        .foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            HStack(spacing: 2) {
                ForEach(0..<Validation.attachmentsPerMessage, id: \.self) { index in
                    Capsule()
                        .fill(index < attachments.count ? AnyShapeStyle(theme.accent)
                              : index < attachments.count + loading ? AnyShapeStyle(theme.accent.opacity(0.35))
                              : AnyShapeStyle(Color.primary.opacity(0.08)))
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AttachmentTile: View {
    let attachment: DraftAttachment
    let remove: () -> Void
    @Environment(\.chatTheme) private var theme
    @Environment(\.supportStrings) private var strings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
                .frame(width: 116, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(verbatim: attachment.filename)
                .font(theme.font(.footnote, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 8)
                .padding(.horizontal, 4)
            Text(verbatim: meta)
                .font(theme.font(.caption))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 2)
                .padding(.horizontal, 4)
        }
        .padding(6)
        .padding(.bottom, 4)
        .frame(width: 128, alignment: .leading)
        .background(TileSurface())
        .overlay(alignment: .topTrailing) {
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.black.opacity(0.55)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.squish(0.9))
            .offset(x: 3, y: -3)
            .accessibilityLabel(Text(verbatim: "\(strings("composer.removeAttachment")): \(attachment.filename)"))
        }
        .accessibilityElement(children: .contain)
    }

    private var meta: String {
        let size = Formatters.fileSize(attachment.data.count, locale: strings.locale) ?? ""
        let kind = (attachment.filename as NSString).pathExtension.uppercased()
        return kind.isEmpty ? size : "\(size) · \(kind)"
    }

    @ViewBuilder
    private var preview: some View {
        if let image = attachment.preview {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                Rectangle().fill(Color.primary.opacity(0.05))
                Image(systemName: FileAttachmentView.symbol(for: attachment.filename))
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct LoadingTile: View {
    @Environment(\.supportStrings) private var strings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .frame(width: 116, height: 92)
                .overlay(ProgressView())
            Capsule().fill(Color.primary.opacity(0.08)).frame(width: 72, height: 9).padding(.top, 12).padding(.horizontal, 4)
            Capsule().fill(Color.primary.opacity(0.05)).frame(width: 44, height: 8).padding(.top, 6).padding(.horizontal, 4)
        }
        .padding(6)
        .padding(.bottom, 8)
        .frame(width: 128, alignment: .leading)
        .background(TileSurface())
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: strings("a11y.photo")))
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Tile surface: a few percent off the tray, a hairline and an inset top light.
private struct TileSurface: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        shape.fill(Color.primary.opacity(0.05))
            .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.1), Color.primary.opacity(0.06)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
    }
}

/// Camera capture through `UIImagePickerController`. Hidden unless the host app declares
/// `NSCameraUsageDescription` and a camera exists.
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
            && Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

extension View {
    /// Figures count instead of snapping.
    func contentTransitionNumeric() -> some View {
        contentTransition(.numericText())
    }
}
