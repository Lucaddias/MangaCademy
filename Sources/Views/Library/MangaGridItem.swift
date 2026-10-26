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
    /// Linha extra embaixo do título (ex.: último capítulo em "Recentes").
    var caption: String?

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

    func caption(_ text: String?) -> MangaGridItem {
        var copy = self
        copy.caption = text
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
                RoundedRectangle(cornerRadius: Theme.Radius.cover)
                    .stroke(Theme.accent, lineWidth: 3)
                    .background(Theme.accentSoft.clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover)))
                    .overlay(alignment: .topLeading) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Theme.onAccent, Theme.accent)
                            .padding(6)
                    }
            }
        }
    }

    private var listRow: some View {
        HStack(spacing: Theme.Space.m) {
            AsyncMangaCover(urlString: coverUrl, cornerRadius: Theme.Radius.thumb, referer: coverReferer, fallbacks: coverFallbacks)
                .frame(width: 46, height: 69)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(title)
                    .textRole(.bodyStrong)
                    .lineLimit(2)
                if let languageText {
                    Text(languageText)
                        .textRole(.caption)
                }
                if let caption {
                    Text(caption)
                        .textRole(.caption)
                        .lineLimit(1)
                }
            }
            Spacer()
            badges
            if let onContinue {
                continueButton(onContinue)
            }
        }
        .padding(.vertical, Theme.Space.s)
        .contentShape(Rectangle())
    }

    /// Só não lidos levam a cor da marca; o resto fica no véu neutro da capa.
    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 3) {
            if let count = downloadCount, count > 0 {
                CoverBadge(text: "\(count)", systemImage: "arrow.down")
                    .accessibilityLabel("\(count) baixados")
            }
            if let count = unreadCount, count > 0 {
                CoverBadge(text: "\(count)", tint: Theme.accent, foreground: Theme.onAccent)
                    .accessibilityLabel("\(count) não lidos")
            }
            if inLibrary {
                Image(systemName: "heart.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(5)
                    .background(Theme.accent, in: Circle())
                    .accessibilityLabel("Na biblioteca")
            }
        }
    }

    private func continueButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .font(.caption)
                .foregroundStyle(Theme.onAccent)
                .padding(8)
                .background(Theme.accent, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Continuar lendo")
    }

    private var gridCell: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            // Moldura 2:3 fixa: capas com proporções diferentes são cortadas, nunca vazam da célula
            Color.clear
                .aspectRatio(2/3, contentMode: .fit)
                .overlay {
                    AsyncMangaCover(urlString: coverUrl, cornerRadius: Theme.Radius.cover, referer: coverReferer, fallbacks: coverFallbacks)
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover))
                .opacity(inLibrary ? 0.5 : 1)
                // Contorno fino no lugar da sombra: some no escuro e não suja capas claras
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.cover)
                        .strokeBorder(Theme.hairline, lineWidth: 0.5)
                }
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
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover))
                    }
                }
                .overlay(alignment: .bottom) {
                    // Idiomas à esquerda e nº de fontes à direita na mesma linha: não se sobrepõem
                    HStack(spacing: 4) {
                        if let languageText {
                            CoverBadge(text: languageText)
                                .truncationMode(.tail)
                                .accessibilityLabel("Idiomas: \(languageText)")
                        }
                        Spacer(minLength: 0)
                        if sourceCount > 1 {
                            CoverBadge(text: "\(sourceCount)", systemImage: "square.stack")
                                .fixedSize()
                                .layoutPriority(1)
                                .accessibilityLabel("Disponível em \(sourceCount) fontes")
                        }
                    }
                    .padding(5)
                    .opacity(displayMode == .compactGrid ? 0 : 1)
                }

            if displayMode == .comfortableGrid {
                Text(title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2, reservesSpace: true)
            }

            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(Theme.inkTertiary)
                    .lineLimit(1)
            }

            if let badge = badgeText, !badge.isEmpty {
                BadgeView(badge, color: Theme.inkSecondary)
            }
        }
    }
}
