import SwiftUI

public struct WebtoonPageView: View {
    let page: SourcePageItem
    
    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var hasError = false
    
    public init(page: SourcePageItem) {
        self.page = page
    }
    
    public var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
            } else if isLoading {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Página \(page.pageNumber)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 300)
                .background(Color.black.opacity(0.1))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    Text("Erro ao carregar página \(page.pageNumber)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Tentar novamente") {
                        Task { await loadImage() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 250)
                .background(Color.black.opacity(0.05))
            }
        }
        .task(id: page.imageUrl) {
            await loadImage()
        }
    }
    
    private func loadImage() async {
        isLoading = true
        hasError = false
        if let img = await ImageCache.shared.load(urlString: page.imageUrl, referer: page.referer) {
            image = img
            isLoading = false
        } else {
            isLoading = false
            hasError = true
        }
    }
}
