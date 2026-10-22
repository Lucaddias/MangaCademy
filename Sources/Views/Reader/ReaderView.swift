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
    
    // Botões de volume
    @AppStorage(ReaderPreferences.volumeButtonsKey) private var volumeButtonsEnabled = true
    @AppStorage(ReaderPreferences.invertVolumeButtonsKey) private var invertVolumeButtons = false
    @State private var webtoonScroller = ReaderScroller()
    @State private var pagedScroller = ReaderScroller()
    @State private var edgeHint: ReaderEdgeHint?
    
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
                                        .background(ScrollViewProbe(scroller: webtoonScroller))
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
                                        .background(ScrollViewProbe(scroller: pagedScroller))
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
                
                if let edgeHint, !isLoading, errorMessage == nil {
                    VStack {
                        Spacer()
                        ReaderEdgeHintView(hint: edgeHint)
                            .padding(.bottom, showControls ? 96 : 40)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .statusBar(hidden: !showControls)
            .navigationBarHidden(true)
            .onVolumeButton(isEnabled: volumeButtonsEnabled && !isAnySheetPresented) { button in
                handleVolumeButton(button)
            }
            .task(id: currentChapterIndex) {
                await loadPages()
            }
            .task(id: edgeHint) {
                guard let hint = edgeHint else { return }
                try? await Task.sleep(for: hint.duration)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    edgeHint = nil
                }
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
                .presentationDetents([.medium, .large])
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
    
    private var isAnySheetPresented: Bool {
        showChapterDrawer || showSettingsSheet || showInfoSheet
    }
    
    private func handleVolumeButton(_ button: VolumeButton) {
        guard !isLoading, errorMessage == nil, !pages.isEmpty else { return }
        // Por padrão o botão de baixo avança, como rolar a página para baixo.
        let forward = (button == .down) != invertVolumeButtons
        
        let shownHint = edgeHint
        guard showControls || shownHint != nil else {
            turnPage(forward: forward, shownHint: nil)
            return
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            showControls = false
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            edgeHint = nil
        }
        // Mudar o estado da tela atualiza o TabView, que cancelaria uma rolagem começada
        // agora e voltaria para a página selecionada; vira só depois dessa atualização.
        DispatchQueue.main.async {
            turnPage(forward: forward, shownHint: shownHint)
        }
    }
    
    private func turnPage(forward: Bool, shownHint: ReaderEdgeHint?) {
        let moved: Bool
        if isWebtoonMode {
            guard let scrolled = webtoonScroller.scroll(byScreens: forward ? 0.85 : -0.85) else { return }
            moved = scrolled
        } else if let turned = pagedScroller.turnPage(by: forward ? 1 : -1, pageCount: pages.count) {
            // O TabView atualiza currentPage sozinho ao fim da rolagem.
            moved = turned
        } else {
            let index = pages.firstIndex { $0.pageNumber == currentPage } ?? 0
            let target = index + (forward ? 1 : -1)
            moved = pages.indices.contains(target)
            if moved {
                currentPage = pages[target].pageNumber
            }
        }
        
        if !moved {
            reachedChapterEdge(forward: forward, shownHint: shownHint)
        }
    }
    
    /// No fim do capítulo o primeiro clique só avisa e o segundo abre o próximo,
    /// para um clique a mais não pular capítulo sem querer.
    private func reachedChapterEdge(forward: Bool, shownHint: ReaderEdgeHint?) {
        let hint: ReaderEdgeHint
        if !forward {
            hint = .chapterStart
        } else if !hasNextChapter {
            hint = .lastChapter
        } else if case .nextChapter = shownHint {
            goToNextChapter()
            return
        } else {
            hint = .nextChapter(allChapters[currentChapterIndex - 1].name)
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            edgeHint = hint
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
        edgeHint = nil
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

// MARK: - Reader Preferences
enum ReaderPreferences {
    static let volumeButtonsKey = "reader_volume_buttons"
    static let invertVolumeButtonsKey = "reader_volume_buttons_inverted"
    
    static func volumeButtonsFooter(inverted: Bool) -> String {
        let (forward, back) = inverted ? ("Volume +", "Volume −") : ("Volume −", "Volume +")
        return "\(forward) avança e \(back) volta. No fim do capítulo, aperte de novo para abrir o próximo. Enquanto ligado, os botões não mudam o volume dentro do leitor."
    }
}

// MARK: - Reader Settings Sheet
private struct ReaderSettingsSheet: View {
    @Binding var isWebtoonMode: Bool
    let onClose: () -> Void
    
    @AppStorage(ReaderPreferences.volumeButtonsKey) private var volumeButtons = true
    @AppStorage(ReaderPreferences.invertVolumeButtonsKey) private var invertVolumeButtons = false
    
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
                
                Section {
                    Toggle("Virar página com o volume", isOn: $volumeButtons)
                    Toggle("Inverter botões", isOn: $invertVolumeButtons)
                        .disabled(!volumeButtons)
                } header: {
                    Text("Botões de Volume")
                } footer: {
                    Text(ReaderPreferences.volumeButtonsFooter(inverted: invertVolumeButtons))
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

// MARK: - Chapter Edge Hint
private enum ReaderEdgeHint: Equatable {
    case nextChapter(String)
    case lastChapter
    case chapterStart

    /// O aviso de próximo capítulo é também a janela para confirmar com o segundo clique.
    var duration: Duration {
        if case .nextChapter = self { return .seconds(4) }
        return .seconds(2)
    }
}

private struct ReaderEdgeHintView: View {
    let hint: ReaderEdgeHint
    
    private var title: String {
        switch hint {
        case .nextChapter, .lastChapter: return "Fim do capítulo"
        case .chapterStart: return "Início do capítulo"
        }
    }
    
    private var subtitle: String? {
        switch hint {
        case .nextChapter(let name): return "Aperte de novo para abrir: \(name)"
        case .lastChapter: return "Não há próximo capítulo"
        case .chapterStart: return nil
        }
    }
    
    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.subheadline.bold())
                .foregroundStyle(.white)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // Mesmo fundo da ReaderFloatingBar, legível sobre páginas claras.
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.13, green: 0.13, blue: 0.14).opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 6)
        )
        .padding(.horizontal, 32)
    }
}

// MARK: - Reader Scroll
/// Rola o UIScrollView por trás do leitor. No iOS 17 o ScrollView do SwiftUI só rola até uma
/// view (e páginas de webtoon costumam ser mais altas que a tela), e mudar a seleção do TabView
/// paginado com `withAnimation` faz ele avançar uma página a mais.
private final class ReaderScroller {
    weak var scrollView: UIScrollView?
    /// Destino da última rolagem animada: cliques seguidos partem dele, não do meio da animação.
    private var pending: (offset: CGPoint, until: Date)?
    
    private func baseOffset(of scrollView: UIScrollView) -> CGPoint {
        // Se o usuário arrastou, vale a posição real.
        if let pending, pending.until > Date(), !scrollView.isTracking, !scrollView.isDecelerating {
            return pending.offset
        }
        return scrollView.contentOffset
    }
    
    private func animate(_ scrollView: UIScrollView, to offset: CGPoint) {
        pending = (offset, Date().addingTimeInterval(1))
        scrollView.setContentOffset(offset, animated: true)
    }
    
    /// Webtoon: rola uma fração da altura visível. Retorna false se já estava no limite
    /// e nil se o scroll view ainda não foi encontrado.
    func scroll(byScreens fraction: CGFloat) -> Bool? {
        guard let scrollView else { return nil }
        let inset = scrollView.adjustedContentInset
        let visibleHeight = scrollView.bounds.height - inset.top - inset.bottom
        let minY = -inset.top
        let maxY = max(minY, scrollView.contentSize.height + inset.bottom - scrollView.bounds.height)
        let current = baseOffset(of: scrollView)
        let target = min(max(current.y + visibleHeight * fraction, minY), maxY)
        guard abs(target - current.y) > 1 else { return false }
        animate(scrollView, to: CGPoint(x: current.x, y: target))
        return true
    }
    
    /// Paginado: desliza até a página vizinha. Retorna false se não há página nessa direção
    /// e nil se o scroll view ainda não foi encontrado.
    func turnPage(by delta: Int, pageCount: Int) -> Bool? {
        guard let scrollView, scrollView.bounds.width > 0 else { return nil }
        let width = scrollView.bounds.width
        let current = baseOffset(of: scrollView)
        let target = Int((current.x / width).rounded()) + delta
        guard (0..<pageCount).contains(target) else { return false }
        animate(scrollView, to: CGPoint(x: CGFloat(target) * width, y: current.y))
        return true
    }
}

/// Entrega ao `ReaderScroller` o UIScrollView que o SwiftUI cria por trás do ScrollView.
private struct ScrollViewProbe: UIViewRepresentable {
    let scroller: ReaderScroller
    
    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.onAttach = { [scroller] scrollView in
            scroller.scrollView = scrollView
        }
        return view
    }
    
    func updateUIView(_ uiView: ProbeView, context: Context) {}
    
    final class ProbeView: UIView {
        var onAttach: ((UIScrollView) -> Void)?
        
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView {
                    onAttach?(scrollView)
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
