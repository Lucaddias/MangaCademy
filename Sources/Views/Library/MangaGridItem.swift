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
    var displayMode: LibraryDisplayMode = .comfortableGrid
    var downloadCount: Int?
    var isSelected = false
    var inLibrary = false
    var onContinue: (() -> Void)?

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

    /// Mesma obra, com o visual da biblioteca.
    func library(
        mode: LibraryDisplayMode,
        downloadCount: Int?,
        isSelected: Bool,
        onContinue: (() -> Void)?
    ) -> MangaGridItem {
        var copy = self
        copy.displayMode = mode
        copy.downloadCount = downloadCount
        copy.isSelected = isSelected
        copy.onContinue = onContinue
        return copy
    }

    /// Marca no catálogo as obras que já estão na biblioteca.
    func markedInLibrary(_ value: Bool) -> MangaGridItem {
        var copy = self
        copy.inLibrary = value
        return copy
    }

    public var body: some View {
        Group {
            if displayMode == .list {
                listRow
            } else {
                gridCell
            }
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.18).clipShape(RoundedRectangle(cornerRadius: 8)))
                    .overlay(alignment: .topLeading) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(6)
                    }
            }
        }
    }

    private var listRow: some View {
        HStack(spacing: 12) {
            AsyncMangaCover(urlString: coverUrl, cornerRadius: 6, referer: coverReferer, fallbacks: coverFallbacks)
                .frame(width: 46, height: 69)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                if let languageText {
                    Text(languageText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            badges
            if let onContinue {
                continueButton(onContinue)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 3) {
            if let count = downloadCount, count > 0 {
                Text("\(count)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.teal)
                    .clipShape(Capsule())
                    .accessibilityLabel("\(count) baixados")
            }
            if let count = unreadCount, count > 0 {
                Text("\(count)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue)
                    .clipShape(Capsule())
                    .accessibilityLabel("\(count) não lidos")
            }
            if inLibrary {
                Image(systemName: "heart.fill")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(Color.pink)
                    .clipShape(Circle())
                    .accessibilityLabel("Na biblioteca")
            }
        }
    }

    private func continueButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .font(.caption)
                .foregroundStyle(.white)
                .padding(8)
                .background(Color.accentColor.opacity(0.9))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Continuar lendo")
    }

    private var gridCell: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Moldura 2:3 fixa: capas com proporções diferentes são cortadas, nunca vazam da célula
            Color.clear
                .aspectRatio(2/3, contentMode: .fit)
                .overlay {
                    AsyncMangaCover(urlString: coverUrl, cornerRadius: 8, referer: coverReferer, fallbacks: coverFallbacks)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .opacity(inLibrary ? 0.55 : 1)
                .overlay(alignment: .topTrailing) {
                    badges.padding(6)
                }
                .overlay(alignment: .bottomTrailing) {
                    if let onContinue, displayMode != .list {
                        continueButton(onContinue).padding(6).padding(.bottom, displayMode == .compactGrid ? 30 : 18)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if displayMode == .compactGrid {
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
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
                    .opacity(displayMode == .compactGrid ? 0 : 1)
                }
                .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)

            if displayMode == .comfortableGrid {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2, reservesSpace: true)
                    .foregroundStyle(.primary)
            }

            if let badge = badgeText, !badge.isEmpty {
                BadgeView(badge, color: .secondary)
            }
        }
    }
}
