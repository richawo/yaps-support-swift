import SwiftUI
import UIKit

/// A small in-memory image cache with request coalescing.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSURL, UIImage>()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    init() {
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    func image(for url: URL) async -> UIImage? {
        if let cached = cached(url) { return cached }
        if let task = inFlight[url] { return await task.value }
        let task = Task<UIImage?, Never> {
            let data: Data?
            if url.isFileURL {
                data = try? Data(contentsOf: url)
            } else {
                data = try? await URLSession.shared.data(from: url).0
            }
            guard let data else { return nil }
            return await Task.detached(priority: .userInitiated) { UIImage(data: data)?.preparingForDisplay() }.value
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image {
            cache.setObject(image, forKey: url as NSURL, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        }
        return image
    }
}

struct RemoteImageView: View {
    enum Source: Equatable {
        case url(URL)
    }

    let source: Source
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(Color(uiColor: .tertiarySystemFill))
                if failed {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
        }
        .task(id: source) {
            guard case .url(let url) = source else { return }
            if let cached = ImageCache.shared.cached(url) {
                image = cached
                return
            }
            let loaded = await ImageCache.shared.image(for: url)
            image = loaded
            failed = loaded == nil
        }
    }
}

struct ImageViewerItem: Identifiable {
    let id = UUID()
    let url: URL
    let placeholder: URL?
}

struct ImageGridView: View {
    let images: [ChatRow.AttachmentContent]
    let isOutgoing: Bool
    @Binding var viewerImage: ImageViewerItem?
    let onFailedTap: () -> Void

    @Environment(\.chatTheme) private var theme
    @Environment(\.supportStrings) private var strings

    private let maxWidth: CGFloat = 240

    var body: some View {
        Group {
            if images.count == 1, let image = images.first {
                tile(image)
                    .frame(width: maxWidth, height: maxWidth / clampedRatio(image.aspectRatio))
            } else {
                let columns = [GridItem(.fixed(maxWidth / 2 - 2), spacing: 4), GridItem(.fixed(maxWidth / 2 - 2), spacing: 4)]
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(images) { image in
                        tile(image)
                            .frame(width: maxWidth / 2 - 2, height: maxWidth / 2 - 2)
                    }
                }
                .frame(width: maxWidth)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: max(8, theme.radius - 2), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: max(8, theme.radius - 2), style: .continuous).strokeBorder(theme.hairline, lineWidth: 0.5))
    }

    private func clampedRatio(_ ratio: CGFloat?) -> CGFloat {
        min(max(ratio ?? 1, 0.6), 1.8)
    }

    @ViewBuilder
    private func tile(_ attachment: ChatRow.AttachmentContent) -> some View {
        switch attachment {
        case .remoteImage(_, let thumbnail, let full, _, _):
            Button {
                viewerImage = ImageViewerItem(url: full, placeholder: thumbnail)
            } label: {
                RemoteImageView(source: .url(thumbnail ?? full))
            }
            .buttonStyle(.squish)
            .accessibilityLabel(Text(verbatim: strings("a11y.photo")))
            .accessibilityAddTraits(.isImage)
        case .localImage(_, let file, _, _):
            Button(action: onFailedTap) {
                RemoteImageView(source: .url(file))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: strings("a11y.photo")))
            .accessibilityAddTraits(.isImage)
        default:
            EmptyView()
        }
    }
}

struct FileAttachmentView: View {
    let attachment: ChatRow.AttachmentContent
    let isOutgoing: Bool
    @Environment(\.chatTheme) private var theme
    @Environment(\.supportStrings) private var strings
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if case .remoteFile(_, let url, _, _) = attachment { openURL(url) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(isOutgoing ? theme.accentInk : theme.accent)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isOutgoing ? theme.accentInk.opacity(0.18) : theme.accent.opacity(0.12)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: name)
                        .font(theme.font(.subheadline, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let size = Formatters.fileSize(size, locale: strings.locale) {
                        Text(verbatim: size)
                            .font(theme.font(.caption))
                            .opacity(0.7)
                    }
                }
                .foregroundStyle(isOutgoing ? theme.accentInk : theme.incomingForeground)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: 260, alignment: .leading)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: theme.radius, style: .continuous)
                .fill(isOutgoing ? theme.outgoingFill : theme.incomingFill))
        }
        .buttonStyle(.squish)
        .accessibilityLabel(Text(verbatim: "\(strings("a11y.file")): \(name)"))
    }

    private var name: String {
        switch attachment {
        case .remoteFile(_, _, let name, _), .localFile(_, _, let name, _): return name
        default: return ""
        }
    }

    private var size: Int? {
        switch attachment {
        case .remoteFile(_, _, _, let size), .localFile(_, _, _, let size): return size
        default: return nil
        }
    }

    private var icon: String { Self.symbol(for: name) }

    static func symbol(for filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "zip": return "doc.zipper"
        default: return "doc.text"
        }
    }
}

/// Full-screen, zoomable image viewer with pinch and double-tap zoom.
struct ImageViewer: View {
    let item: ImageViewerItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.supportStrings) private var strings
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let image {
                ZoomableImageView(image: image)
                    .ignoresSafeArea()
                    .accessibilityLabel(Text(verbatim: strings("a11y.photo")))
            } else {
                ProgressView().tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 12) {
                if let image {
                    ShareLink(item: Image(uiImage: image), preview: SharePreview(strings("a11y.photo"), image: Image(uiImage: image))) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(Text(verbatim: strings("menu.share")))
                }
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text(verbatim: strings("a11y.close")))
            }
            .foregroundStyle(.white)
            .glassBackground(in: Capsule(), interactive: true)
            .environment(\.colorScheme, .dark)
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .statusBarHidden()
        .task {
            if let placeholder = item.placeholder, let cached = ImageCache.shared.cached(placeholder) { image = cached }
            if let full = await ImageCache.shared.image(for: item.url) { image = full }
        }
    }
}

private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomingScrollView {
        let view = ZoomingScrollView()
        view.setImage(image)
        return view
    }

    func updateUIView(_ uiView: ZoomingScrollView, context: Context) {
        if uiView.imageView.image !== image { uiView.setImage(image) }
    }
}

final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setImage(_ image: UIImage) {
        imageView.image = image
        zoomScale = 1
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale == 1 { imageView.frame = bounds }
        centerImage()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    private func centerImage() {
        let offsetX = max((bounds.width - contentSize.width) / 2, 0)
        let offsetY = max((bounds.height - contentSize.height) / 2, 0)
        contentInset = UIEdgeInsets(top: offsetY, left: offsetX, bottom: offsetY, right: offsetX)
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > 1 {
            setZoomScale(1, animated: true)
        } else {
            let point = recognizer.location(in: imageView)
            let scale: CGFloat = 2.5
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(origin: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), size: size), animated: true)
        }
    }
}
