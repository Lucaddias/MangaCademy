import SwiftUI

public struct MangaGridItem: View {
    let title: String
    let coverUrl: String?
    let coverReferer: String?
    let coverFallbacks: [CoverCandidate]
    let badgeText: String?
    let languageText: String?
    let sourceCount: Int
    let unreadCount: Int?

    public init(
        title: String,
        coverUrl: String?,
        coverReferer: String? = nil,
        coverFallbacks: [CoverCandidate] = [],
        badgeText: String? = nil,
        languageText: String? = nil,
        sourceCount: Int = 1,
        unreadCount: Int? = nil
    ) {
        self.title = title
        self.coverUrl = coverUrl
        self.coverReferer = coverReferer
        self.coverFallbacks = coverFallbacks
        self.badgeText = badgeText
        self.languageText = languageText
        self.sourceCount = sourceCount
        self.unreadCount = unreadCount
    }

    /// Atalho para obras unificadas do catálogo.
    public init(work: UnifiedWork, filter: LanguageFilter, unreadCount: Int? = nil) {
        let referer: (String) -> String? = { SourceManager.shared.getSource(id: $0)?.imageReferer }
        self.init(
            title: work.title,
            coverUrl: work.coverUrl,
            coverReferer: work.coverSourceId.flatMap(referer),
            coverFallbacks: work.fallbackCovers.prefix(3).compactMap { ref in
                ref.coverUrl.map { CoverCandidate(url: $0, referer: referer(ref.sourceId)) }
            },
            languageText: work.languageBadges(preferred: filter),
            sourceCount: Set(work.refs.map(\.sourceId)).count,
            unreadCount: unreadCount
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Moldura 2:3 fixa: capas com proporções diferentes são cortadas, nunca vazam da célula
            Color.clear
                .aspectRatio(2/3, contentMode: .fit)
                .overlay {
                    AsyncMangaCover(urlString: coverUrl, cornerRadius: 8, referer: coverReferer, fallbacks: coverFallbacks)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) {
                    if let count = unreadCount, count > 0 {
                        Text("\(count)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue)
                            .clipShape(Capsule())
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottom) {
                    // Idiomas à esquerda e nº de fontes à direita na mesma linha: não se sobrepõem
                    HStack(spacing: 4) {
                        if let languageText {
                            Text(languageText)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.black.opacity(0.65))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .accessibilityLabel("Idiomas: \(languageText)")
                        }
                        Spacer(minLength: 0)
                        if sourceCount > 1 {
                            Label("\(sourceCount)", systemImage: "square.stack.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.purple.opacity(0.85))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .layoutPriority(1)
                                .accessibilityLabel("Disponível em \(sourceCount) fontes")
                        }
                    }
                    .padding(5)
                }
                .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)

            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(2, reservesSpace: true)
                .foregroundStyle(.primary)

            if let badge = badgeText, !badge.isEmpty {
                BadgeView(badge, color: .secondary)
            }
        }
    }
}
