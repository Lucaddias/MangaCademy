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
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(isRead ? .regular : .semibold)
                    .foregroundStyle(isRead ? .secondary : .primary)
                    .lineLimit(1)
                
                if let scanlator = scanlator, !scanlator.isEmpty {
                    Text(scanlator)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            if let downloadState {
                DownloadIndicator(state: downloadState, action: onDownload)
            }

            Button(action: onToggleBookmark) {
                Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.footnote)
                    .foregroundStyle(isBookmarked ? Color.yellow : Color.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            
            Button(action: onToggleRead) {
                Image(systemName: isRead ? "checkmark.circle.fill" : "circle")
                    .font(.subheadline)
                    .foregroundStyle(isRead ? Color.blue : Color.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
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
                    Image(systemName: "arrow.down.circle").foregroundStyle(Color.secondary.opacity(0.6))
                case .queued:
                    Image(systemName: "clock").foregroundStyle(.secondary)
                case .downloading(let fraction):
                    ZStack {
                        Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                        Circle().trim(from: 0, to: max(fraction, 0.03))
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 15, height: 15)
                case .failed:
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                case .downloaded:
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
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
