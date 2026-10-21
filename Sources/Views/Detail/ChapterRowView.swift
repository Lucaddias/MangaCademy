import SwiftUI

public struct ChapterRowView: View {
    let title: String
    let scanlator: String?
    let isRead: Bool
    let isBookmarked: Bool
    let onToggleRead: () -> Void
    let onToggleBookmark: () -> Void
    
    public init(
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
}
