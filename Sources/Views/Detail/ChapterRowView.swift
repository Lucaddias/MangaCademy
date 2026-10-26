import SwiftUI

public struct ChapterRowView: View {
    let title: String
    let scanlator: String?
    let isRead: Bool
    let isBookmarked: Bool
    let onToggleRead: () -> Void
    let onToggleBookmark: () -> Void
    var downloadState: ChapterDownloadState?
    var onDownload: () -> Void = {}
    
    init(
        title: String,
        scanlator: String? = nil,
        isRead: Bool = false,
        isBookmarked: Bool = false,
        onToggleRead: @escaping () -> Void = {},
        onToggleBookmark: @escaping () -> Void = {}
    ) {
        self.title = title
        self.scanlator = scanlator
        self.isRead = isRead
        self.isBookmarked = isBookmarked
        self.onToggleRead = onToggleRead
        self.onToggleBookmark = onToggleBookmark
    }
    
    public var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(isRead ? .regular : .semibold)
                    .foregroundStyle(isRead ? Theme.inkTertiary : Theme.ink)
                    .lineLimit(1)
                
                if let scanlator = scanlator, !scanlator.isEmpty {
                    Text(scanlator)
                        .font(.caption2)
                        .foregroundStyle(Theme.inkTertiary)
                        .lineLimit(1)
                }
            }
            
            Spacer()

            // O marcador só aparece marcado; marcar fica no deslizar e no toque longo
            if isBookmarked {
                Button(action: onToggleBookmark) {
                    Image(systemName: "bookmark.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.caution)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Tirar marcador")
            }
            
            if let downloadState {
                DownloadIndicator(state: downloadState, action: onDownload)
            }

            Button(action: onToggleRead) {
                Image(systemName: isRead ? "checkmark.circle.fill" : "circle")
                    .font(.subheadline)
                    .foregroundStyle(isRead ? Theme.accent : Theme.inkTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRead ? "Marcar como não lido" : "Marcar como lido")
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    func download(_ state: ChapterDownloadState, action: @escaping () -> Void) -> ChapterRowView {
        var copy = self
        copy.downloadState = state
        copy.onDownload = action
        return copy
    }
}

/// Fila, progresso ou baixado. O toque baixa, cancela ou apaga (quem chama decide).
struct DownloadIndicator: View {
    let state: ChapterDownloadState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                switch state {
                case .none:
                    Image(systemName: "arrow.down.circle").foregroundStyle(Theme.inkTertiary)
                case .queued:
                    Image(systemName: "clock").foregroundStyle(Theme.inkSecondary)
                case .downloading(let fraction):
                    ZStack {
                        Circle().stroke(Theme.fill, lineWidth: 2)
                        Circle().trim(from: 0, to: max(fraction, 0.03))
                            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 15, height: 15)
                case .failed:
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.critical)
                case .downloaded:
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.positive)
                }
            }
            .font(.subheadline)
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch state {
        case .none: return "Baixar"
        case .queued: return "Na fila, toque para cancelar"
        case .downloading: return "Baixando, toque para cancelar"
        case .failed: return "Falhou, toque para tentar de novo"
        case .downloaded: return "Baixado, toque para apagar"
        }
    }
}
