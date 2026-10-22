import SwiftUI
import SwiftData

public struct HistoryView: View {
    @Query(sort: \HistoryEntry.readAt, order: .reverse)
    private var historyEntries: [HistoryEntry]
    @Query(filter: #Predicate<Manga> { $0.isFavorite == true })
    private var libraryMangas: [Manga]

    @Environment(\.modelContext) private var modelContext

    @State private var resumingEntry: HistoryEntry?
    @State private var detailWork: UnifiedWork?

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
                                    .onTapGesture { openWork(entry) }

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
                            .contentShape(Rectangle())
                            .onTapGesture { resumingEntry = entry }
                            .contextMenu {
                                Button {
                                    resumingEntry = entry
                                } label: {
                                    Label("Continuar leitura", systemImage: "book")
                                }
                                Button {
                                    openWork(entry)
                                } label: {
                                    Label("Ver obra", systemImage: "info.circle")
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityHint("Continua a leitura")
                            .accessibilityAction(named: "Ver obra") { openWork(entry) }
                        }
                        .onDelete(perform: deleteEntries)
                    }
                }
            }
            .navigationTitle("Histórico")
            .navigationDestination(item: $detailWork) { work in
                MangaDetailView(work: work)
            }
            .fullScreenCover(item: $resumingEntry) { entry in
                HistoryReaderLauncher(entry: entry, onOpenWork: { openWork(entry) })
            }
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

    /// Abre a obra: a da biblioteca (com todas as fontes) ou a da fonte em que foi lida.
    private func openWork(_ entry: HistoryEntry) {
        if let manga = libraryMangas.first(where: { $0.id == entry.mangaId }) {
            detailWork = UnifiedWork(libraryManga: manga)
        } else {
            detailWork = UnifiedWork(storedId: entry.mangaId, title: entry.mangaTitle, coverUrl: entry.coverUrl)
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

/// Reabre o leitor no capítulo do histórico, na página onde parou.
private struct HistoryReaderLauncher: View {
    let entry: HistoryEntry
    let onOpenWork: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var resumed: HistoryResume.Resumed?
    @State private var errorMessage: String?

    var body: some View {
        if let resumed {
            ReaderView(
                mangaId: entry.mangaId,
                mangaTitle: entry.mangaTitle,
                chapters: resumed.chapters,
                initialChapterIndex: resumed.index,
                coverUrl: entry.coverUrl
            )
        } else {
            ZStack {
                Color.black.ignoresSafeArea()
                if let errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.yellow)
                        Text(errorMessage)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        HStack {
                            Button("Fechar") { dismiss() }
                                .buttonStyle(.bordered)
                            Button("Ver obra") {
                                dismiss()
                                onOpenWork()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    VStack(spacing: 16) {
                        ProgressView()
                            .tint(.white)
                        Text(entry.chapterName)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
            .task {
                do {
                    resumed = try await HistoryResume.resume(entry, context: modelContext)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
