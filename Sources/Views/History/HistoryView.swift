import SwiftUI
import SwiftData

public struct HistoryView: View {
    @Query(sort: \HistoryEntry.readAt, order: .reverse)
    private var historyEntries: [HistoryEntry]
    
    @Environment(\.modelContext) private var modelContext
    
    public init() {}
    
    public var body: some View {
        NavigationStack {
            Group {
                if historyEntries.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "clock")
                            .font(.system(size: 60))
                            .foregroundStyle(.secondary)
                        Text("Nenhum histórico")
                            .font(.headline)
                        Text("Os capítulos que você ler aparecerão aqui.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    List {
                        ForEach(historyEntries) { entry in
                            HStack(spacing: 12) {
                                AsyncMangaCover(urlString: entry.coverUrl, cornerRadius: 6)
                                    .frame(width: 50, height: 75)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.mangaTitle)
                                        .font(.subheadline.bold())
                                        .lineLimit(1)
                                    Text(entry.chapterName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    
                                    HStack {
                                        Text(entry.readAt, format: .dateTime.day().month().hour().minute())
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                        Spacer()
                                        if entry.totalPages > 0 {
                                            Text("Pág. \(entry.pageNumber)/\(entry.totalPages)")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .onDelete(perform: deleteEntries)
                    }
                }
            }
            .navigationTitle("Histórico")
            .toolbar {
                if !historyEntries.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Limpar Tudo") {
                            clearAll()
                        }
                    }
                }
            }
        }
    }
    
    private func deleteEntries(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(historyEntries[index])
        }
        try? modelContext.save()
    }
    
    private func clearAll() {
        for entry in historyEntries {
            modelContext.delete(entry)
        }
        try? modelContext.save()
    }
}
