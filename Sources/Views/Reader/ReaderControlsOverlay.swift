import SwiftUI

public struct ReaderControlsOverlay: View {
    let title: String
    let chapterName: String
    let currentPage: Int
    let totalPages: Int
    let isWebtoonMode: Bool
    let onToggleMode: () -> Void
    let onDismiss: () -> Void
    
    public init(
        title: String,
        chapterName: String,
        currentPage: Int,
        totalPages: Int,
        isWebtoonMode: Bool,
        onToggleMode: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.title = title
        self.chapterName = chapterName
        self.currentPage = currentPage
        self.totalPages = totalPages
        self.isWebtoonMode = isWebtoonMode
        self.onToggleMode = onToggleMode
        self.onDismiss = onDismiss
    }
    
    public var body: some View {
        VStack {
            // Top Bar
            HStack {
                Button(action: onDismiss) {
                    Image(systemName: "chevron.left")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.ultraThinMaterial.opacity(0.8))
                        .clipShape(Circle())
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(chapterName)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
                
                Spacer()
                
                Button(action: onToggleMode) {
                    Image(systemName: isWebtoonMode ? "arrow.up.and.down" : "arrow.left.and.right")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.ultraThinMaterial.opacity(0.8))
                        .clipShape(Circle())
                }
            }
            .padding()
            .background(
                LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom)
            )
            
            Spacer()
            
            // Bottom Bar
            HStack {
                Text("\(currentPage) / \(totalPages)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial.opacity(0.9))
                    .clipShape(Capsule())
            }
            .padding(.bottom, 24)
        }
    }
}
