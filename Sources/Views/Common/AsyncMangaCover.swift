import SwiftUI

/// Outra capa possível para a mesma obra (de outra fonte), com o Referer daquela fonte.
public struct CoverCandidate: Hashable {
    public let url: String
    public let referer: String?

    public init(url: String, referer: String?) {
        self.url = url
        self.referer = referer
    }
}

public struct AsyncMangaCover: View {
    let urlString: String?
    let cornerRadius: CGFloat
    let referer: String?
    let fallbacks: [CoverCandidate]
    
    @State private var image: UIImage?
    @State private var isLoading = false
    
    public init(urlString: String?, cornerRadius: CGFloat = 8, referer: String? = nil, fallbacks: [CoverCandidate] = []) {
        self.urlString = urlString
        self.cornerRadius = cornerRadius
        self.referer = referer
        self.fallbacks = fallbacks
    }
    
    private var candidates: [CoverCandidate] {
        var list: [CoverCandidate] = []
        if let urlString, !urlString.isEmpty { list.append(CoverCandidate(url: urlString, referer: referer)) }
        for candidate in fallbacks where !list.contains(where: { $0.url == candidate.url }) {
            list.append(candidate)
        }
        return list
    }
    
    public var body: some View {
        ZStack {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if isLoading {
                Rectangle()
                    .fill(Theme.fill)
                    .overlay(
                        ProgressView()
                            .scaleEffect(0.8)
                    )
            } else {
                Rectangle()
                    .fill(Theme.fill)
                    .overlay(
                        Image(systemName: "book.closed")
                            .font(.title2)
                            .foregroundStyle(Theme.inkTertiary)
                    )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: urlString) {
            let candidates = self.candidates
            guard let first = candidates.first else { return }
            image = ImageCache.shared.image(for: first.url)
            guard image == nil else { return }
            isLoading = true
            // Se a capa principal falhar (site fora do ar, anti-hotlink), tenta as das outras fontes
            for candidate in candidates {
                if let loaded = await ImageCache.shared.load(urlString: candidate.url, referer: candidate.referer) {
                    image = loaded
                    break
                }
                if Task.isCancelled { break }
            }
            isLoading = false
        }
    }
}
