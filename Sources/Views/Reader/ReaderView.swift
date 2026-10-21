import SwiftUI
import SwiftData

public struct ReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    /// Id da obra unificada (biblioteca/progresso). Cada capítulo sabe sua fonte de origem.
    let mangaId: String
    let mangaTitle: String
    let allChapters: [SourceChapterItem]
    let coverUrl: String?
    
    @State private var currentChapterIndex: Int
    @State private var pages: [SourcePageItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showControls = true
    @State private var isWebtoonMode = UserDefaults.standard.object(forKey: "default_reader_webtoon") as? Bool ?? true
    @State private var currentPage = 1
    
    // Sheets
    @State private var showChapterDrawer = false
    @State private var showSettingsSheet = false
    @State private var showInfoSheet = false
    
    public init(
        mangaId: String,
        mangaTitle: String,
        chapters: [SourceChapterItem],
        initialChapterIndex: Int,
        coverUrl: String?
    ) {
        self.mangaId = mangaId
        self.mangaTitle = mangaTitle
        self.allChapters = chapters
        self._currentChapterIndex = State(initialValue: initialChapterIndex)
        self.coverUrl = coverUrl
    }
    
    private var currentChapter: SourceChapterItem? {
        guard currentChapterIndex >= 0 && currentChapterIndex < allChapters.count else { return nil }
        return allChapters[currentChapterIndex]
    }
    
    // Chapters in manga list are usually descending (latest first, e.g. Ch. 146 is index 0, Ch. 1 is last index)
    // Next chapter in reading order = previous index in list (or next higher number)
    private var hasPreviousChapter: Bool {
        // Earlier chapter number (e.g. going from Ch 2 to Ch 1)
        return currentChapterIndex < allChapters.count - 1
    }
    
    private var hasNextChapter: Bool {
        // Next chapter number (e.g. going from Ch 1 to Ch 2)
        return currentChapterIndex > 0
    }
    
    public var body: some View {
        ScrollViewReader { scrollProxy in
            ZStack {
                Color.black.ignoresSafeArea()
                
                // Reading Canvas
                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                            .tint(.white)
                        Text(currentChapter?.name ?? "Carregando capítulo...")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                } else if let error = errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.yellow)
                        Text(error)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button("Tentar novamente") {
                            Task { await loadPages() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    Group {
                        if isWebtoonMode {
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    Color.clear
                                        .frame(height: 1)
                                        .id("page_top")
                                    
                                    ForEach(pages) { page in
                                        WebtoonPageView(page: page)
                                    }
                                }
                            }
                        } else {
                            TabView(selection: $currentPage) {
                                ForEach(pages) { page in
                                    WebtoonPageView(page: page)
                                        .tag(page.pageNumber)
                                }
                            }
                            .tabViewStyle(.page(indexDisplayMode: .never))
                        }
                    }
                    .onTapGesture {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            showControls.toggle()
                        }
                    }
                }
                
                // Floating Controls Overlay (Top Bar & Floating Bottom Bar)
                if showControls && !isLoading && errorMessage == nil {
                    VStack {
                        // Top Bar
                        HStack {
                            Button {
                                dismiss()
                            } label: {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(10)
                                    .background(.ultraThinMaterial.opacity(0.8))
                                    .clipShape(Circle())
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mangaTitle)
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(currentChapter?.name ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.8))
                                    .lineLimit(1)
                            }
                            
                            Spacer()
                            
                            Text("\(currentPage)/\(max(pages.count, 1))")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.ultraThinMaterial.opacity(0.8))
                                .clipShape(Capsule())
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .background(
                            LinearGradient(colors: [.black.opacity(0.85), .clear], startPoint: .top, endPoint: .bottom)
                        )
                        
                        Spacer()
                        
                        // Bottom Floating Bar (Replicating User Screenshot)
                        ReaderFloatingBar(
                            hasPrevious: hasPreviousChapter,
                            hasNext: hasNextChapter,
                            onPrevious: {
                                goToPreviousChapter()
                            },
                            onNext: {
                                goToNextChapter()
                            },
                            onOpenChaptersList: {
                                showChapterDrawer = true
                            },
                            onOpenSettings: {
                                showSettingsSheet = true
                            },
                            onOpenComments: {
                                showInfoSheet = true
                            },
                            onReportOrReload: {
                                Task { await reloadCurrentChapter() }
                            },
                            onScrollToTop: {
                                withAnimation(.easeInOut(duration: 0.4)) {
                                    scrollProxy.scrollTo("page_top", anchor: .top)
                                }
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    showControls = false
                                }
                            }
                        )
                        .padding(.bottom, 16)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .statusBar(hidden: !showControls)
            .navigationBarHidden(true)
            .task(id: currentChapterIndex) {
                await loadPages()
            }
            // Chapters Drawer Sheet
            .sheet(isPresented: $showChapterDrawer) {
                ChapterDrawerSheet(
                    chapters: allChapters,
                    currentIndex: currentChapterIndex,
                    onSelectChapter: { index in
                        currentChapterIndex = index
                        showChapterDrawer = false
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            showControls = false
                        }
                    }
                )
                .presentationDetents([.medium, .large])
            }
            // Settings Sheet
            .sheet(isPresented: $showSettingsSheet) {
                ReaderSettingsSheet(
                    isWebtoonMode: $isWebtoonMode,
                    onClose: {
                        showSettingsSheet = false
                    }
                )
                .presentationDetents([.fraction(0.35)])
            }
            // Info / Comments Sheet
            .sheet(isPresented: $showInfoSheet) {
                ChapterInfoSheet(
                    mangaTitle: mangaTitle,
                    chapter: currentChapter,
                    totalPages: pages.count,
                    onClose: {
                        showInfoSheet = false
                    }
                )
                .presentationDetents([.fraction(0.4)])
            }
        }
    }
    
    private func goToPreviousChapter() {
        guard hasPreviousChapter else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            currentChapterIndex += 1 // In descending lists, previous chapter is at index + 1
            showControls = false
        }
    }
    
    private func goToNextChapter() {
        guard hasNextChapter else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            currentChapterIndex -= 1 // In descending lists, next chapter is at index - 1
            showControls = false
        }
    }
    
    private func reloadCurrentChapter() async {
        ImageCache.shared.clearCache()
        await loadPages()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            showControls = false
        }
    }
    
    private func loadPages() async {
        guard let ch = currentChapter,
              let source = SourceManager.shared.getSource(id: ch.sourceId) else {
            errorMessage = "Capítulo ou fonte indisponível"
            isLoading = false
            return
        }
        
        isLoading = true
        errorMessage = nil
        currentPage = 1
        
        do {
            let loadedPages = try await source.fetchPages(
                chapterRemoteUrl: ch.remoteUrl,
                mangaRemoteUrl: ch.mangaRemoteUrl
            )
            guard !loadedPages.isEmpty else {
                errorMessage = "Nenhuma página encontrada neste capítulo (\(source.name))."
                isLoading = false
                return
            }
            pages = loadedPages
            isLoading = false
            
            // Progresso: marca o capítulo como lido e registra no histórico
            ReadTracker.setRead(true, chapter: ch, mangaId: mangaId, context: modelContext)
            let history = HistoryEntry(
                mangaId: mangaId,
                chapterId: Chapter.storageId(mangaId: mangaId, sourceId: ch.sourceId, remoteUrl: ch.remoteUrl),
                mangaTitle: mangaTitle,
                chapterName: ch.name,
                coverUrl: coverUrl,
                readAt: Date(),
                pageNumber: 1,
                totalPages: loadedPages.count
            )
            modelContext.insert(history)
            try? modelContext.save()
            
        } catch {
            errorMessage = "Falha ao carregar páginas (\(source.name)): \(error.localizedDescription)"
            isLoading = false
        }
    }
}

// MARK: - Chapter Drawer Sheet
private struct ChapterDrawerSheet: View {
    let chapters: [SourceChapterItem]
    let currentIndex: Int
    let onSelectChapter: (Int) -> Void
    
    @State private var search = ""
    
    private var filtered: [(index: Int, chapter: SourceChapterItem)] {
        let indexed = chapters.enumerated().map { (index: $0.offset, chapter: $0.element) }
        if search.isEmpty { return indexed }
        return indexed.filter { $0.chapter.name.localizedCaseInsensitiveContains(search) }
    }
    
    var body: some View {
        NavigationStack {
            List(filtered, id: \.chapter.id) { item in
                Button {
                    onSelectChapter(item.index)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.chapter.name)
                                .font(.subheadline)
                                .fontWeight(item.index == currentIndex ? .bold : .regular)
                                .foregroundStyle(item.index == currentIndex ? Color.blue : Color.primary)
                            
                            if let scan = item.chapter.scanlator {
                                Text(scan)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        
                        Spacer()
                        
                        if item.index == currentIndex {
                            Image(systemName: "checkmark")
                                .font(.footnote.bold())
                                .foregroundStyle(.blue)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Capítulos (\(chapters.count))")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Buscar capítulo...")
        }
    }
}

// MARK: - Reader Settings Sheet
private struct ReaderSettingsSheet: View {
    @Binding var isWebtoonMode: Bool
    let onClose: () -> Void
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Modo de Leitura")) {
                    Picker("Exibição", selection: $isWebtoonMode) {
                        Text("Webtoon (Rolagem Contínua)").tag(true)
                        Text("Manga Paginado (Slide Horizontal)").tag(false)
                    }
                    .pickerStyle(.inline)
                }
            }
            .navigationTitle("Ajustes do Leitor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Pronto", action: onClose)
                }
            }
        }
    }
}

// MARK: - Chapter Info Sheet
private struct ChapterInfoSheet: View {
    let mangaTitle: String
    let chapter: SourceChapterItem?
    let totalPages: Int
    let onClose: () -> Void
    
    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("Informações")) {
                    LabeledContent("Obra", value: mangaTitle)
                    LabeledContent("Capítulo", value: chapter?.name ?? "-")
                    if let scan = chapter?.scanlator, !scan.isEmpty {
                        LabeledContent("Scanlator", value: scan)
                    }
                    LabeledContent("Páginas", value: "\(totalPages)")
                }
            }
            .navigationTitle("Detalhes do Capítulo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fechar", action: onClose)
                }
            }
        }
    }
}
