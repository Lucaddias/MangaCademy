import SwiftUI
import UIKit

/// Carrega a imagem de uma página do leitor no tamanho da tela.
@MainActor
@Observable
final class ReaderPageLoader {
    private(set) var image: ReaderImage?
    private(set) var failed = false

    func load(_ page: SourcePageItem, maxPixelWidth: Int, cropBorders: Bool) async {
        failed = false
        if let loaded = await ImageCache.shared.loadForDisplay(
            urlString: page.imageUrl, referer: page.referer, maxPixelWidth: maxPixelWidth, cropBorders: cropBorders
        ) {
            image = loaded
        } else if !Task.isCancelled {
            failed = true
        }
    }
}

/// Largura da tela em pixels, para decodificar as páginas no tamanho certo.
@MainActor
var readerScreenPixelWidth: Int {
    let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    let size = screen?.bounds.size ?? CGSize(width: 430, height: 932)
    return Int(max(size.width, size.height) * (screen?.scale ?? 3))
}

// MARK: - Webtoon

/// Página na rolagem contínua: ocupa a largura, com a altura da imagem.
public struct WebtoonPageView: View {
    let page: SourcePageItem
    var cropBorders = false
    var actions: ReaderPageActions?

    @State private var loader = ReaderPageLoader()

    public var body: some View {
        Group {
            if let image = loader.image {
                if image.tiles.isEmpty {
                    Image(uiImage: image.image)
                        .resizable()
                        .scaledToFit()
                } else {
                    VStack(spacing: 0) {
                        ForEach(image.tiles.indices, id: \.self) { index in
                            Image(uiImage: image.tiles[index])
                                .resizable()
                                .scaledToFit()
                        }
                    }
                }
            } else if loader.failed {
                ReaderPageError(pageNumber: page.pageNumber) {
                    Task { await loader.load(page, maxPixelWidth: readerScreenPixelWidth, cropBorders: cropBorders) }
                }
                .frame(height: 250)
            } else {
                ReaderPagePlaceholder(page: page)
            }
        }
        .frame(maxWidth: .infinity)
        .contextMenu {
            if let image = loader.image, let actions {
                ReaderPageMenu(image: image.image, page: page, actions: actions)
            }
        }
        .task(id: "\(page.imageUrl)#\(cropBorders)") {
            await loader.load(page, maxPixelWidth: readerScreenPixelWidth, cropBorders: cropBorders)
        }
    }
}

/// Enquanto a imagem carrega, ocupa o tamanho dela (se a fonte informa) ou uma tela inteira.
/// Assim a posição salva continua certa e o fim do capítulo não aparece antes da hora.
struct ReaderPagePlaceholder: View {
    let page: SourcePageItem

    var body: some View {
        let content = VStack(spacing: 8) {
            ProgressView()
            Text("Página \(page.pageNumber)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        if let width = page.width, let height = page.height, width > 0, height > 0 {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .aspectRatio(CGFloat(width) / CGFloat(height), contentMode: .fit)
                .background(Color.gray.opacity(0.1))
        } else {
            content
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.vertical)
                .background(Color.gray.opacity(0.1))
        }
    }
}

struct ReaderPageError: View {
    let pageNumber: Int
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.orange)
            Text("Erro ao carregar página \(pageNumber)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Tentar novamente", action: retry)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Toque longo

/// Ações do toque longo numa página.
struct ReaderPageActions {
    let setAsCover: ((UIImage) -> Void)?
    let onSaved: (String) -> Void
}

struct ReaderPageMenu: View {
    let image: UIImage
    let page: SourcePageItem
    let actions: ReaderPageActions

    var body: some View {
        ShareLink(item: Image(uiImage: image), preview: SharePreview("Página \(page.pageNumber)", image: Image(uiImage: image))) {
            Label("Compartilhar", systemImage: "square.and.arrow.up")
        }
        Button {
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            actions.onSaved("Página salva em Fotos")
        } label: {
            Label("Salvar em Fotos", systemImage: "square.and.arrow.down")
        }
        Button {
            UIPasteboard.general.image = image
            actions.onSaved("Página copiada")
        } label: {
            Label("Copiar", systemImage: "doc.on.doc")
        }
        if let setAsCover = actions.setAsCover {
            Button {
                setAsCover(image)
            } label: {
                Label("Definir como capa", systemImage: "photo")
            }
        }
    }
}

// MARK: - Paginado

/// Página do modo paginado: zoom com pinça e duplo toque, escala e posição inicial configuráveis.
struct PagedPageView: View {
    let page: SourcePageItem
    let scale: PageScale
    let zoomStart: ZoomStart
    let cropBorders: Bool
    let rotateWide: Bool
    let rightToLeft: Bool
    let onTap: (CGPoint) -> Void
    var actions: ReaderPageActions?

    @State private var loader = ReaderPageLoader()

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let image = loader.image {
                    let rotate = rotateWide && image.isWide && proxy.size.height > proxy.size.width
                    ZoomableImageView(
                        image: rotate ? image.image.rotatedClockwise() : image.image,
                        scale: scale,
                        zoomStart: zoomStart == .automatic ? (rightToLeft ? .right : .left) : zoomStart,
                        onTap: onTap
                    )
                    .contextMenu {
                        if let actions {
                            ReaderPageMenu(image: image.image, page: page, actions: actions)
                        }
                    }
                } else if loader.failed {
                    ReaderPageError(pageNumber: page.pageNumber) {
                        Task { await loader.load(page, maxPixelWidth: readerScreenPixelWidth, cropBorders: cropBorders) }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { location in
                            onTap(CGPoint(x: location.x / max(proxy.size.width, 1), y: location.y / max(proxy.size.height, 1)))
                        }
                }
            }
        }
        .task(id: "\(page.imageUrl)#\(cropBorders)") {
            await loader.load(page, maxPixelWidth: readerScreenPixelWidth, cropBorders: cropBorders)
        }
    }
}

/// Duas páginas lado a lado (paisagem / iPad).
struct SpreadPageView: View {
    let pages: [SourcePageItem]
    let cropBorders: Bool
    let onTap: (CGPoint) -> Void

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(pages) { page in
                    SpreadHalf(page: page, cropBorders: cropBorders)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                onTap(CGPoint(x: location.x / max(proxy.size.width, 1), y: location.y / max(proxy.size.height, 1)))
            }
        }
    }

    private struct SpreadHalf: View {
        let page: SourcePageItem
        let cropBorders: Bool
        @State private var loader = ReaderPageLoader()

        var body: some View {
            Group {
                if let image = loader.image {
                    Image(uiImage: image.image).resizable().scaledToFit()
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: page.imageUrl) {
                await loader.load(page, maxPixelWidth: readerScreenPixelWidth / 2, cropBorders: cropBorders)
            }
        }
    }
}

extension UIImage {
    func rotatedClockwise() -> UIImage {
        guard let cgImage else { return self }
        return UIImage(cgImage: cgImage, scale: scale, orientation: .right)
    }
}

/// UIScrollView com zoom em volta da imagem (o SwiftUI não tem zoom de verdade no iOS 17).
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let scale: PageScale
    let zoomStart: ZoomStart
    let onTap: (CGPoint) -> Void

    func makeUIView(context: Context) -> ZoomingScrollView {
        let view = ZoomingScrollView()
        view.onTap = onTap
        return view
    }

    func updateUIView(_ view: ZoomingScrollView, context: Context) {
        view.onTap = onTap
        view.configure(image: image, scale: scale, zoomStart: zoomStart)
    }

    final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate {
        private let imageView = UIImageView()
        private var scaleType: PageScale = .fitScreen
        private var zoomStart: ZoomStart = .left
        private var lastBounds: CGSize = .zero
        var onTap: ((CGPoint) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            delegate = self
            showsVerticalScrollIndicator = false
            showsHorizontalScrollIndicator = false
            decelerationRate = .fast
            contentInsetAdjustmentBehavior = .never
            backgroundColor = .clear
            addSubview(imageView)

            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            addGestureRecognizer(doubleTap)
            let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
            singleTap.require(toFail: doubleTap)
            addGestureRecognizer(singleTap)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) não usado") }

        func configure(image: UIImage, scale: PageScale, zoomStart: ZoomStart) {
            let changed = imageView.image !== image || scale != scaleType || zoomStart != self.zoomStart
            scaleType = scale
            self.zoomStart = zoomStart
            guard changed else { return }
            imageView.image = image
            resetZoom()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if bounds.size != lastBounds {
                lastBounds = bounds.size
                resetZoom()
            }
            centerContent()
        }

        private func baseScale(for size: CGSize) -> CGFloat {
            guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
            let fitWidth = bounds.width / size.width
            let fitHeight = bounds.height / size.height
            switch scaleType {
            case .fitScreen: return min(fitWidth, fitHeight)
            case .fitWidth: return fitWidth
            case .fitHeight: return fitHeight
            case .original: return 1 / UIScreen.main.scale
            case .smart:
                // Páginas bem mais altas que a tela (tiras) ajustam à largura; o resto, à tela.
                return size.height / size.width > (bounds.height / bounds.width) * 1.6 ? fitWidth : min(fitWidth, fitHeight)
            }
        }

        private func resetZoom() {
            guard let image = imageView.image, bounds.width > 0 else { return }
            let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
            minimumZoomScale = 1
            maximumZoomScale = 1
            zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: size)
            contentSize = size
            let base = baseScale(for: size)
            minimumZoomScale = base
            maximumZoomScale = max(base * 4, 1)
            zoomScale = base
            centerContent()
            // Posição inicial quando a página é mais larga ou mais alta que a tela.
            let maxX = max(0, contentSize.width - bounds.width)
            let x: CGFloat
            switch zoomStart {
            case .right: x = maxX
            case .center: x = maxX / 2
            default: x = 0
            }
            contentOffset = CGPoint(x: x - contentInset.left, y: -contentInset.top)
        }

        private func centerContent() {
            let dx = max(0, (bounds.width - contentSize.width) / 2)
            let dy = max(0, (bounds.height - contentSize.height) / 2)
            contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent() }

        @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            if zoomScale > minimumZoomScale * 1.05 {
                setZoomScale(minimumZoomScale, animated: true)
            } else {
                let target = min(minimumZoomScale * 2.5, maximumZoomScale)
                let point = gesture.location(in: imageView)
                let size = CGSize(width: bounds.width / target, height: bounds.height / target)
                zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }

        @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            let point = gesture.location(in: self)
            let local = CGPoint(x: point.x - contentOffset.x, y: point.y - contentOffset.y)
            onTap?(CGPoint(x: local.x / max(bounds.width, 1), y: local.y / max(bounds.height, 1)))
        }
    }
}
