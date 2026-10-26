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
    @State private var confirmClear = false

    public init() {}

    public var body: some View {
        NavigationStack {
            Group {
                if historyEntries.isEmpty {
                    ContentUnavailableView("Nada lido ainda", systemImage: "clock")
                } else {
                    List {
                        ForEach(historyEntries) { entry in
                            HStack(spacing: Theme.Space.m) {
                                AsyncMangaCover(urlString: entry.coverUrl, cornerRadius: Theme.Radius.thumb)
                                    .frame(width: 44, height: 66)
                                    .onTapGesture { openWork(entry) }

                                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                    Text(entry.mangaTitle)
                                        .textRole(.bodyStrong)
                                        .lineLimit(1)
                                    Text(entry.chapterName)
                                        .textRole(.meta)
                                        .lineLimit(1)
                                    HStack(spacing: Theme.Space.s) {
                                        // Onde parou vira uma barra, não texto
                                        if entry.totalPages > 0 {
                                            PageProgress(page: entry.pageNumber, total: entry.totalPages)
                                        }
                                        Text(entry.readAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                                            .textRole(.caption)
                                            .lineLimit(1)
                                            .fixedSize()
                                    }
                                }
                            }
                            .padding(.vertical, Theme.Space.xs)
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
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(Theme.hairline)
                            .listRowInsets(EdgeInsets(top: Theme.Space.xs, leading: Theme.Space.margin, bottom: Theme.Space.xs, trailing: Theme.Space.margin))
                        }
                        .onDelete(perform: deleteEntries)
                        .listSectionSeparator(.hidden)
                    }
                    .listStyle(.plain)
                }
            }
            .themedList()
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
                        Button { confirmClear = true } label: { Image(systemName: "trash") }
                            .accessibilityLabel("Limpar histórico")
                    }
                }
            }
            .confirmationDialog("Limpar todo o histórico?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Limpar", role: .destructive) { clearAll() }
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

/// Página onde a leitura parou, como uma barra curta.
private struct PageProgress: View {
    let page: Int
    let total: Int

    var body: some View {
        Capsule()
            .fill(Theme.fill)
            .frame(width: 44, height: 3)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 44 * min(max(Double(page) / Double(total), 0.04), 1))
            }
            .accessibilityLabel("Página \(page) de \(total)")
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
                            .foregroundStyle(Theme.caution)
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
            // Fundo sempre preto: cores e botões no tom escuro
            .environment(\.colorScheme, .dark)
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
