import SwiftUI
import SwiftData

/// Um capítulo carregado no leitor.
struct ReaderSegment: Equatable {
    let chapterIndex: Int
    let pages: [SourcePageItem]
}

/// Item da lista do leitor: páginas de vários capítulos encadeados e as transições entre eles.
enum ReaderItem: Identifiable, Hashable {
    case page(chapterIndex: Int, page: SourcePageItem, count: Int)
    /// Fim do capítulo `from`; `to` é o próximo na ordem de leitura (nil = não há).
    case transition(from: Int, to: Int?)
    /// Antes do primeiro capítulo carregado: leva ao anterior.
    case previous(chapterIndex: Int, to: Int)

    var id: String {
        switch self {
        case .page(let chapter, let page, _): return "\(chapter)-\(page.pageNumber)"
        case .transition(let from, _): return "t\(from)"
        case .previous(let chapter, _): return "p\(chapter)"
        }
    }

    var chapterIndex: Int {
        switch self {
        case .page(let chapter, _, _): return chapter
        case .transition(let from, _): return from
        case .previous(let chapter, _): return chapter
        }
    }

    var page: SourcePageItem? {
        if case .page(_, let page, _) = self { return page }
        return nil
    }
}

/// O que fica numa tela do modo paginado: uma página, duas lado a lado ou uma transição.
struct ReaderDisplayItem: Identifiable {
    let items: [ReaderItem]
    var id: String { items[0].id }
}

public struct ReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    /// Id da obra unificada (biblioteca/progresso). Cada capítulo sabe sua fonte de origem.
    let mangaId: String
    let mangaTitle: String
    /// Do mais novo para o mais antigo (como na lista do detalhe).
    let allChapters: [SourceChapterItem]
    let coverUrl: String?

    @State private var settings = ReaderSettings.shared
    @State private var startChapterIndex: Int
    @State private var segments: [ReaderSegment] = []
    /// Id do `ReaderDisplayItem` na tela.
    @State private var position: String?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var loadingNextIndex: Int?
    @State private var nextLoadError: String?
    @State private var showControls = true
    @State private var isLandscape = false
    /// Capítulo mostrado por último (para marcar como lido ao passar para o seguinte).
    @State private var lastChapterIndex: Int?
    @State private var lastTick = Date()

    /// Ajustes desta obra (só gravados se ela estiver no banco).
    @State private var libraryManga: Manga?
    @State private var modeOverride: ReadingMode?
    @State private var orientationOverride: ReaderOrientation?

    // Webtoon
    @State private var webtoonScroller = ReaderScroller()
    @State private var zoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var panX: CGFloat = 0
    @State private var panStart: CGFloat = 0

    // Botões de volume
    @AppStorage(Preferences.Key.readerVolumeButtons) private var volumeButtonsEnabled = Preferences.Default.readerVolumeButtons
    @AppStorage(Preferences.Key.readerInvertVolumeButtons) private var invertVolumeButtons = Preferences.Default.readerInvertVolumeButtons
    @State private var edgeHint: ReaderEdgeHint?
    @State private var toast: String?
    @State private var showTapZones = false

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
        self._startChapterIndex = State(initialValue: initialChapterIndex)
        self.coverUrl = coverUrl
    }

    private var mode: ReadingMode { modeOverride ?? settings.defaultMode }
    private var orientation: ReaderOrientation { orientationOverride ?? settings.defaultOrientation }
    private var incognito: Bool { Preferences.incognito }

    // MARK: - Itens

    private var items: [ReaderItem] {
        var result: [ReaderItem] = []
        if let first = segments.first, let previous = previousChapterIndex(before: first.chapterIndex) {
            result.append(.previous(chapterIndex: first.chapterIndex, to: previous))
        }
        for (offset, segment) in segments.enumerated() {
            for page in segment.pages {
                result.append(.page(chapterIndex: segment.chapterIndex, page: page, count: segment.pages.count))
            }
            let next = nextChapterIndex(after: segment.chapterIndex)
            let isLast = offset == segments.count - 1
            // Entre capítulos já carregados a leitura segue direto, salvo aviso de capítulos faltando.
            if isLast || settings.alwaysShowTransition || missingChapters(from: segment.chapterIndex, to: next) > 0 {
                result.append(.transition(from: segment.chapterIndex, to: next))
            }
        }
        return result
    }

    private var useSpreads: Bool {
        mode.isHorizontalPaged && isLandscape && settings.dualPageInLandscape
    }

    private var displayItems: [ReaderDisplayItem] {
        let all = items
        guard useSpreads else { return all.map { ReaderDisplayItem(items: [$0]) } }
        var result: [ReaderDisplayItem] = []
        var index = 0
        while index < all.count {
            let item = all[index]
            if case .page(let chapter, let page, _) = item, page.pageNumber > 1, !isWide(page),
               index + 1 < all.count, case .page(let nextChapter, let nextPage, _) = all[index + 1],
               nextChapter == chapter, !isWide(nextPage) {
                result.append(ReaderDisplayItem(items: [item, all[index + 1]]))
                index += 2
            } else {
                result.append(ReaderDisplayItem(items: [item]))
                index += 1
            }
        }
        return result
    }

    private func isWide(_ page: SourcePageItem) -> Bool {
        guard let w = page.width, let h = page.height else { return false }
        return w > h
    }

    private var currentDisplay: ReaderDisplayItem? {
        let displays = displayItems
        return displays.first { $0.id == position } ?? displays.first { $0.items.contains { $0.id == position } }
    }

    /// Item que vale para o progresso (numa página dupla, a da direita na ordem de leitura).
    private var currentItem: ReaderItem? { currentDisplay?.items.last }

    private var currentChapterIndex: Int { currentItem?.chapterIndex ?? startChapterIndex }

    private var currentChapter: SourceChapterItem? {
        allChapters.indices.contains(currentChapterIndex) ? allChapters[currentChapterIndex] : nil
    }

    private var currentSegment: ReaderSegment? {
        segments.first { $0.chapterIndex == currentChapterIndex }
    }

    /// Página atual, contando de 1 (na transição, a última do capítulo).
    private var currentPage: Int {
        switch currentItem {
        case .page(_, let page, _): return page.pageNumber
        case .transition: return currentSegment?.pages.count ?? 1
        default: return 1
        }
    }

    private func displayId(page: Int, chapterIndex: Int) -> String? {
        let target = "\(chapterIndex)-\(page)"
        return displayItems.first { $0.items.contains { $0.id == target } }?.id
    }

    // MARK: - Ordem dos capítulos

    /// Próximo capítulo na ordem de leitura (a lista está do mais novo para o mais antigo),
    /// pulando lidos e repetidos se o usuário pediu.
    private func nextChapterIndex(after index: Int) -> Int? {
        guard allChapters.indices.contains(index) else { return nil }
        let current = allChapters[index]
        let progress = (settings.skipRead || settings.skipDuplicates) ? readProgress() : nil
        var candidate = index - 1
        while candidate >= 0 {
            let chapter = allChapters[candidate]
            let duplicate = settings.skipDuplicates && chapter.chapterNumber >= 0 && chapter.chapterNumber == current.chapterNumber
            let skipRead = settings.skipRead && progress?.isRead(chapter) == true
            if !duplicate && !skipRead { return candidate }
            candidate -= 1
        }
        return nil
    }

    private func previousChapterIndex(before index: Int) -> Int? {
        guard allChapters.indices.contains(index) else { return nil }
        var candidate = index + 1
        while candidate < allChapters.count {
            if !(settings.skipDuplicates && allChapters[candidate].chapterNumber == allChapters[index].chapterNumber) {
                return candidate
            }
            candidate += 1
        }
        return nil
    }

    /// Capítulos que faltam na numeração entre dois capítulos (ex.: do 10 para o 14 faltam 3).
    private func missingChapters(from: Int, to: Int?) -> Int {
        guard let to, allChapters.indices.contains(from), allChapters.indices.contains(to) else { return 0 }
        return ChapterGaps.missing(between: allChapters[from].chapterNumber, and: allChapters[to].chapterNumber)
    }

    private func readProgress() -> ChapterProgress {
        ChapterProgress(records: ChapterStore.records(mangaId: mangaId, context: modelContext), mangaId: mangaId)
    }

    // MARK: - Corpo

    public var body: some View {
        GeometryReader { proxy in
            ZStack {
                settings.background.color(colorScheme).ignoresSafeArea()

                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text(currentChapter?.name ?? "Carregando capítulo...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else if let error = errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.yellow)
                        Text(error)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button("Tentar novamente") {
                            Task { await openChapter(startChapterIndex) }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Fechar") { dismiss() }
                    }
                } else {
                    content(size: proxy.size)
                        .modifier(ReaderColorFilters(settings: settings))
                }

                if showTapZones {
                    TapZoneOverlay(cells: settings.tapZones.cells(inversion: settings.tapInversion, mirrored: mode.isRightToLeft))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if !showControls && settings.showPageNumber && !isLoading && errorMessage == nil, let segment = currentSegment {
                    VStack {
                        Spacer()
                        Text("\(currentPage) / \(segment.pages.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.45), in: Capsule())
                            .padding(.bottom, 6)
                    }
                    .allowsHitTesting(false)
                }

                if showControls && !isLoading && errorMessage == nil {
                    controls
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                if let message = edgeHint?.message ?? toast?.message {
                    VStack {
                        Spacer()
                        ReaderHintView(title: message.title, subtitle: message.subtitle)
                            .padding(.bottom, showControls ? 140 : 40)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .onAppear { isLandscape = proxy.size.width > proxy.size.height }
            .onChange(of: proxy.size) { _, size in isLandscape = size.width > size.height }
        }
        .statusBar(hidden: !showControls)
        .navigationBarHidden(true)
        .onVolumeButton(isEnabled: volumeButtonsEnabled && !isAnySheetPresented) { button in
            handleVolumeButton(button)
        }
        .task {
            loadMangaSettings()
            applyScreenSettings()
            await openChapter(startChapterIndex)
            if !settings.tapZonesExplained && settings.tapZones != .disabled {
                settings.tapZonesExplained = true
                flashTapZones()
            }
        }
        .onChange(of: position) { _, _ in
            positionChanged()
        }
        // Salva a página um instante depois de parar nela (e não a cada página que passa).
        .task(id: position) {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            saveProgress()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { lastTick = Date() } else { saveProgress() }
        }
        .onChange(of: mode) { _, _ in resetZoom() }
        .onChange(of: orientation) { _, _ in applyScreenSettings() }
        .onChange(of: settings.keepScreenOn) { _, _ in applyScreenSettings() }
        .onChange(of: settings.tapZones) { _, _ in flashTapZones() }
        .onChange(of: settings.tapInversion) { _, _ in flashTapZones() }
        .onDisappear {
            saveProgress()
            UIApplication.shared.isIdleTimerDisabled = false
            AppDelegate.lockOrientation(.all)
        }
        .task(id: edgeHint) {
            guard edgeHint != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { edgeHint = nil }
        }
        .task(id: toast) {
            guard toast != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { toast = nil }
        }
        .sheet(isPresented: $showChapterDrawer) {
            ChapterDrawerSheet(
                chapters: allChapters,
                currentIndex: currentChapterIndex,
                onSelectChapter: { index in
                    showChapterDrawer = false
                    hideControls()
                    Task { await openChapter(index) }
                }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSettingsSheet) {
            ReaderSettingsSheet(
                settings: settings,
                modeOverride: Binding(get: { modeOverride }, set: { setModeOverride($0) }),
                orientationOverride: Binding(get: { orientationOverride }, set: { setOrientationOverride($0) }),
                canSavePerManga: libraryManga != nil,
                onClose: { showSettingsSheet = false }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showInfoSheet) {
            ChapterInfoSheet(
                mangaTitle: mangaTitle,
                chapter: currentChapter,
                totalPages: currentSegment?.pages.count ?? 0,
                onClose: { showInfoSheet = false }
            )
            .presentationDetents([.fraction(0.4)])
        }
    }

    // MARK: - Conteúdo

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        if mode.isWebtoon {
            webtoon(size: size)
        } else {
            paged
        }
    }

    private func webtoon(size: CGSize) -> some View {
        ScrollView {
            LazyVStack(spacing: mode == .webtoonGaps ? 12 : 0) {
                ForEach(items) { item in
                    webtoonItem(item)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, size.width * settings.webtoonSidePadding / 100)
            .background(ScrollViewProbe(scroller: webtoonScroller))
        }
        .scrollPosition(id: $position)
        .scaleEffect(zoom)
        .offset(x: panX)
        .contentShape(Rectangle())
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in zoom = min(max(zoomBase * value.magnification, 1), 3) }
                .onEnded { _ in
                    zoomBase = zoom
                    clampPan(width: size.width)
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    guard zoom > 1 else { return }
                    panX = panStart + value.translation.width
                    clampPan(width: size.width)
                }
                .onEnded { _ in panStart = panX }
        )
        .onTapGesture(count: 2) {
            withAnimation(.easeInOut(duration: 0.25)) {
                if zoom > 1 { resetZoom() } else { zoom = 2; zoomBase = 2 }
            }
        }
        .onTapGesture(coordinateSpace: .local) { location in
            handleTap(CGPoint(x: location.x / max(size.width, 1), y: location.y / max(size.height, 1)))
        }
    }

    @ViewBuilder
    private func webtoonItem(_ item: ReaderItem) -> some View {
        switch item {
        case .page(_, let page, _):
            WebtoonPageView(page: page, cropBorders: settings.cropBorders, actions: pageActions)
        case .transition(let from, let to):
            transitionView(from: from, to: to)
                .frame(height: 320)
                .onAppear { reachedEnd(of: from) }
        case .previous(let chapter, let to):
            previousView(chapter: chapter, to: to)
                .frame(height: 220)
        }
    }

    @ViewBuilder
    private var paged: some View {
        let displays = displayItems
        let stack = ForEach(displays) { display in
            pagedItem(display)
                .environment(\.layoutDirection, .leftToRight)
                .containerRelativeFrame([.horizontal, .vertical])
        }
        Group {
            if mode == .pagedVertical {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) { stack }
                        .scrollTargetLayout()
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) { stack }
                        .scrollTargetLayout()
                }
            }
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $position)
        .environment(\.layoutDirection, mode.isRightToLeft ? .rightToLeft : .leftToRight)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func pagedItem(_ display: ReaderDisplayItem) -> some View {
        if display.items.count == 2 {
            let pages = display.items.compactMap(\.page)
            SpreadPageView(pages: mode.isRightToLeft ? pages.reversed() : pages, cropBorders: settings.cropBorders, onTap: handleTap)
        } else {
            switch display.items[0] {
            case .page(_, let page, _):
                PagedPageView(
                    page: page,
                    scale: settings.pageScale,
                    zoomStart: settings.zoomStart,
                    cropBorders: settings.cropBorders,
                    rotateWide: settings.rotateWidePages,
                    rightToLeft: mode.isRightToLeft,
                    onTap: handleTap,
                    actions: pageActions
                )
            case .transition(let from, let to):
                tappable(transitionView(from: from, to: to))
                    .onAppear { reachedEnd(of: from) }
            case .previous(let chapter, let to):
                tappable(previousView(chapter: chapter, to: to))
            }
        }
    }

    private func tappable(_ view: some View) -> some View {
        GeometryReader { proxy in
            view
                .frame(width: proxy.size.width, height: proxy.size.height)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    handleTap(CGPoint(x: location.x / max(proxy.size.width, 1), y: location.y / max(proxy.size.height, 1)))
                }
        }
    }

    private func transitionView(from: Int, to: Int?) -> some View {
        ChapterTransitionView(
            finished: allChapters[from].name,
            next: to.map { allChapters[$0].name },
            missing: missingChapters(from: from, to: to),
            isLoading: loadingNextIndex != nil && loadingNextIndex == to,
            error: segments.last?.chapterIndex == from ? nextLoadError : nil,
            onRetry: { appendNextChapter(force: true) },
            onClose: { dismiss() }
        )
    }

    private func previousView(chapter: Int, to: Int) -> some View {
        VStack(spacing: 10) {
            Text("Início de \(allChapters[chapter].name)")
                .font(.subheadline.bold())
            Text("Anterior: \(allChapters[to].name)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Abrir capítulo anterior") {
                Task { await openChapter(to, atLastPage: true) }
            }
            .buttonStyle(.bordered)
        }
        .foregroundStyle(settings.background == .white ? Color.black : Color.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pageActions: ReaderPageActions {
        ReaderPageActions(
            setAsCover: libraryManga == nil ? nil : { image in setCover(image) },
            onSaved: { message in showToast(message) }
        )
    }

    // MARK: - Controles

    private var controls: some View {
        VStack {
            HStack(spacing: 10) {
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

                if incognito {
                    Image(systemName: "eyeglasses")
                        .foregroundStyle(.white)
                        .accessibilityLabel("Modo anônimo")
                }

                Menu {
                    Picker("Modo de leitura", selection: Binding(get: { mode }, set: { setModeOverride($0) })) {
                        ForEach(ReadingMode.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                } label: {
                    Text(mode.shortTitle)
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial.opacity(0.8))
                        .clipShape(Capsule())
                }
                .accessibilityLabel("Modo de leitura: \(mode.title)")
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .background(LinearGradient(colors: [.black.opacity(0.85), .clear], startPoint: .top, endPoint: .bottom))

            Spacer()

            if let segment = currentSegment, segment.pages.count > 1 {
                pageSlider(segment)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }

            ReaderFloatingBar(
                hasPrevious: previousChapterIndex(before: currentChapterIndex) != nil,
                hasNext: nextChapterIndex(after: currentChapterIndex) != nil,
                onPrevious: {
                    guard let index = previousChapterIndex(before: currentChapterIndex) else { return }
                    hideControls()
                    Task { await openChapter(index) }
                },
                onNext: {
                    guard let index = nextChapterIndex(after: currentChapterIndex) else { return }
                    hideControls()
                    Task { await openChapter(index) }
                },
                onOpenChaptersList: { showChapterDrawer = true },
                onOpenSettings: { showSettingsSheet = true },
                onOpenComments: { showInfoSheet = true },
                onReportOrReload: { Task { await reloadCurrentChapter() } },
                onScrollToTop: {
                    if let id = displayId(page: 1, chapterIndex: currentChapterIndex) {
                        withAnimation(.easeInOut(duration: 0.4)) { position = id }
                    }
                    hideControls()
                }
            )
            .padding(.bottom, 16)
        }
    }

    /// Barra para pular de página. Fica aberta enquanto arrasta.
    private func pageSlider(_ segment: ReaderSegment) -> some View {
        let count = segment.pages.count
        let binding = Binding<Double>(
            get: { Double(min(max(currentPage, 1), count)) },
            set: { value in
                if let id = displayId(page: Int(value.rounded()), chapterIndex: segment.chapterIndex), id != position {
                    position = id
                }
            }
        )
        return HStack(spacing: 10) {
            Text("\(currentPage)")
                .frame(minWidth: 24)
            Slider(value: binding, in: 1...Double(count), step: 1)
                .tint(.white)
            Text("\(count)")
                .frame(minWidth: 24)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(red: 0.13, green: 0.13, blue: 0.14).opacity(0.95), in: Capsule())
        .environment(\.layoutDirection, mode.isRightToLeft ? .rightToLeft : .leftToRight)
    }

    private var isAnySheetPresented: Bool {
        showChapterDrawer || showSettingsSheet || showInfoSheet
    }

    private func hideControls() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showControls = false }
    }

    private func showToast(_ message: String) {
        withAnimation(.easeInOut(duration: 0.2)) { toast = message }
    }

    private func flashTapZones() {
        guard settings.tapZones != .disabled else { return }
        withAnimation(.easeInOut(duration: 0.2)) { showTapZones = true }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.easeInOut(duration: 0.3)) { showTapZones = false }
        }
    }

    // MARK: - Toques e botões

    private func handleTap(_ point: CGPoint) {
        if showControls {
            hideControls()
            return
        }
        switch settings.tapZones.action(at: point, inversion: settings.tapInversion, mirrored: mode.isRightToLeft) {
        case .menu:
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showControls = true }
        case .next:
            turnPage(forward: true)
        case .previous:
            turnPage(forward: false)
        }
    }

    private func handleVolumeButton(_ button: VolumeButton) {
        guard !isLoading, errorMessage == nil, !segments.isEmpty else { return }
        // Por padrão o botão de baixo avança, como rolar a página para baixo.
        let forward = (button == .down) != invertVolumeButtons
        guard showControls else {
            turnPage(forward: forward)
            return
        }
        hideControls()
        // Mudar o estado da tela atualiza a rolagem; vira só depois dessa atualização.
        DispatchQueue.main.async { turnPage(forward: forward) }
    }

    private func turnPage(forward: Bool) {
        if mode.isWebtoon {
            guard let moved = webtoonScroller.scroll(byScreens: forward ? 0.85 : -0.85) else { return }
            if !moved { reachedEdge(forward: forward) }
            return
        }
        let displays = displayItems
        guard let index = displays.firstIndex(where: { $0.id == currentDisplay?.id }) else { return }
        let target = index + (forward ? 1 : -1)
        guard displays.indices.contains(target) else {
            reachedEdge(forward: forward)
            return
        }
        withAnimation(.easeInOut(duration: 0.25)) { position = displays[target].id }
    }

    private func reachedEdge(forward: Bool) {
        let hint: ReaderEdgeHint
        if !forward {
            hint = .chapterStart
        } else if loadingNextIndex != nil {
            hint = .loadingNext
        } else if let last = segments.last, nextChapterIndex(after: last.chapterIndex) != nil {
            appendNextChapter(force: true)
            hint = .loadingNext
        } else {
            hint = .lastChapter
        }
        withAnimation(.easeInOut(duration: 0.2)) { edgeHint = hint }
    }

    private func resetZoom() {
        zoom = 1
        zoomBase = 1
        panX = 0
        panStart = 0
    }

    private func clampPan(width: CGFloat) {
        let limit = (zoom - 1) * width / 2
        panX = min(max(panX, -limit), limit)
        panStart = panX
    }

    // MARK: - Carregamento

    private func openChapter(_ index: Int, atLastPage: Bool = false) async {
        // Ao trocar de capítulo, guarda onde o anterior parou.
        saveProgress()
        guard allChapters.indices.contains(index) else {
            errorMessage = "Capítulo indisponível"
            isLoading = false
            return
        }
        startChapterIndex = index
        isLoading = true
        errorMessage = nil
        edgeHint = nil
        nextLoadError = nil
        loadingNextIndex = nil
        segments = []
        resetZoom()
        do {
            let segment = try await loadSegment(index)
            // Retoma onde parou; capítulo já lido recomeça do início.
            let saved = ChapterStore.record(for: allChapters[index], mangaId: mangaId, context: modelContext)
            let resume = atLastPage ? segment.pages.count
                : saved.map { $0.isRead ? 1 : min(max($0.lastPageRead, 1), segment.pages.count) } ?? 1
            segments = [segment]
            lastChapterIndex = index
            position = displayId(page: resume, chapterIndex: index)
            isLoading = false
            lastTick = Date()
            saveProgress()
            markReadIfFinished()
            prefetchAhead()
        } catch {
            errorMessage = "Falha ao carregar páginas: \(error.localizedDescription)"
            isLoading = false
        }
    }

    private func loadSegment(_ index: Int) async throws -> ReaderSegment {
        let pages = try await ChapterPageProvider.pages(for: allChapters[index], mangaId: mangaId)
        return ReaderSegment(chapterIndex: index, pages: pages)
    }

    /// Carrega o próximo capítulo no fim da lista, para a leitura continuar sem parar.
    private func appendNextChapter(force: Bool = false) {
        guard let last = segments.last, loadingNextIndex == nil,
              let next = nextChapterIndex(after: last.chapterIndex) else { return }
        if !force && nextLoadError != nil { return }
        loadingNextIndex = next
        nextLoadError = nil
        Task {
            do {
                let segment = try await loadSegment(next)
                if segments.last?.chapterIndex == last.chapterIndex {
                    segments.append(segment)
                }
            } catch {
                nextLoadError = error.localizedDescription
            }
            loadingNextIndex = nil
        }
    }

    private func reloadCurrentChapter() async {
        // Só as páginas deste capítulo: capas e outros capítulos continuam no cache.
        ImageCache.shared.remove(urlStrings: currentSegment?.pages.map(\.imageUrl) ?? [])
        await openChapter(currentChapterIndex)
        hideControls()
    }

    private func positionChanged() {
        let chapter = currentChapterIndex
        // Passou para o capítulo seguinte na rolagem contínua: o anterior foi terminado.
        if let last = lastChapterIndex, chapter < last {
            markRead(last)
            saveProgress(chapterIndex: last, page: segments.first { $0.chapterIndex == last }?.pages.count)
        }
        lastChapterIndex = chapter
        markReadIfFinished()
        prefetchAhead()
        if let segment = segments.last, segment.chapterIndex == chapter, currentPage >= segment.pages.count - 2 {
            appendNextChapter()
        }
    }

    private func reachedEnd(of chapterIndex: Int) {
        markRead(chapterIndex)
        appendNextChapter()
    }

    /// Baixa para o disco as próximas páginas antes de chegar nelas.
    private func prefetchAhead() {
        guard settings.preloadCount > 0, !settings.preloadOnlyOnWifi || NetworkMonitor.shared.isOnWifi else { return }
        let all = items
        guard let current = currentItem, let index = all.firstIndex(of: current) else { return }
        let upcoming = all.dropFirst(index + 1).compactMap(\.page).prefix(settings.preloadCount)
        Task {
            for page in upcoming {
                await ImageCache.shared.prefetch(urlString: page.imageUrl, referer: page.referer)
            }
        }
    }

    // MARK: - Progresso

    /// Grava a página atual no capítulo, no histórico e o tempo de leitura.
    private func saveProgress(chapterIndex: Int? = nil, page: Int? = nil) {
        let index = chapterIndex ?? currentChapterIndex
        guard !incognito, !segments.isEmpty, allChapters.indices.contains(index),
              let segment = segments.first(where: { $0.chapterIndex == index }) else { return }
        let ch = allChapters[index]
        let page = min(max(page ?? currentPage, 1), segment.pages.count)
        ChapterStore.saveProgress(page: page, totalPages: segment.pages.count, chapter: ch, mangaId: mangaId, context: modelContext)

        let chapterId = Chapter.storageId(mangaId: mangaId, sourceId: ch.sourceId, remoteUrl: ch.remoteUrl)
        var descriptor = FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.id == chapterId })
        descriptor.fetchLimit = 1
        let entry: HistoryEntry
        if let existing = try? modelContext.fetch(descriptor).first {
            entry = existing
        } else {
            entry = HistoryEntry(mangaId: mangaId, chapterId: chapterId, mangaTitle: mangaTitle, chapterName: ch.name, coverUrl: coverUrl)
            modelContext.insert(entry)
        }
        let now = Date()
        // Tempo parado numa página conta até 5 min (depois disso, provavelmente largou o aparelho).
        entry.timeRead += min(max(now.timeIntervalSince(lastTick), 0), 300)
        lastTick = now
        entry.mangaTitle = mangaTitle
        entry.chapterName = ch.name
        entry.coverUrl = coverUrl ?? entry.coverUrl
        entry.readAt = now
        entry.pageNumber = page
        entry.totalPages = segment.pages.count
        entry.sourceId = ch.sourceId
        entry.chapterRemoteUrl = ch.remoteUrl
        entry.mangaRemoteUrl = ch.mangaRemoteUrl
        libraryManga?.lastReadAt = now
        try? modelContext.save()
    }

    /// O capítulo conta como lido ao chegar na última página.
    private func markReadIfFinished() {
        guard let segment = currentSegment, currentPage >= segment.pages.count else { return }
        markRead(segment.chapterIndex)
    }

    private func markRead(_ index: Int) {
        guard !incognito, allChapters.indices.contains(index) else { return }
        let ch = allChapters[index]
        guard ChapterStore.record(for: ch, mangaId: mangaId, context: modelContext)?.isRead != true else { return }
        ChapterStore.setRead(true, chapter: ch, mangaId: mangaId, context: modelContext)
    }

    // MARK: - Ajustes da obra

    private func loadMangaSettings() {
        let id = mangaId
        var descriptor = FetchDescriptor<Manga>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        libraryManga = try? modelContext.fetch(descriptor).first
        modeOverride = libraryManga?.readingMode.flatMap(ReadingMode.init(rawValue:))
        orientationOverride = libraryManga?.orientation.flatMap(ReaderOrientation.init(rawValue:))
    }

    private func setModeOverride(_ newMode: ReadingMode?) {
        modeOverride = newMode
        libraryManga?.readingMode = newMode?.rawValue
        try? modelContext.save()
    }

    private func setOrientationOverride(_ newValue: ReaderOrientation?) {
        orientationOverride = newValue
        libraryManga?.orientation = newValue?.rawValue
        try? modelContext.save()
    }

    private func applyScreenSettings() {
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
        AppDelegate.lockOrientation(orientation.mask)
    }

    private func setCover(_ image: UIImage) {
        guard let manga = libraryManga, let data = image.jpegData(compressionQuality: 0.9),
              let name = CustomCoverStore.save(data) else { return }
        CustomCoverStore.remove(manga.customCoverPath)
        manga.customCoverPath = name
        try? modelContext.save()
        showToast("Capa da obra atualizada")
    }
}

/// Buracos na numeração de capítulos.
enum ChapterGaps {
    /// Capítulos inteiros que faltam entre dois números (em qualquer ordem). Números
    /// desconhecidos (≤ 0) não contam.
    static func missing(between a: Double, and b: Double) -> Int {
        guard a > 0, b > 0 else { return 0 }
        let low = floor(min(a, b)), high = floor(max(a, b))
        return max(0, Int(high - low) - 1)
    }
}

// MARK: - Filtros de cor

private struct ReaderColorFilters: ViewModifier {
    let settings: ReaderSettings

    func body(content: Content) -> some View {
        let filtered = content
            .grayscale(settings.grayscale ? 1 : 0)
            .overlay {
                if settings.colorFilterEnabled {
                    settings.colorFilterColor
                        .opacity(0.5)
                        .blendMode(settings.colorFilterBlend.blendMode)
                        .allowsHitTesting(false)
                        .ignoresSafeArea()
                }
            }
            .overlay {
                if settings.dimming > 0 {
                    Color.black.opacity(settings.dimming)
                        .allowsHitTesting(false)
                        .ignoresSafeArea()
                }
            }
        if settings.invertColors {
            filtered.colorInvert()
        } else {
            filtered
        }
    }
}

// MARK: - Transição entre capítulos

private struct ChapterTransitionView: View {
    let finished: String
    let next: String?
    let missing: Int
    let isLoading: Bool
    let error: String?
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("Fim de")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(finished)
                    .font(.headline)
            }
            Divider().frame(width: 120)
            if let next {
                VStack(spacing: 4) {
                    Text("Próximo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(next)
                        .font(.headline)
                }
                if missing > 0 {
                    Label("\(missing) \(missing == 1 ? "capítulo faltando" : "capítulos faltando")", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                    Button("Tentar novamente", action: onRetry)
                        .buttonStyle(.bordered)
                } else if isLoading {
                    ProgressView()
                }
            } else {
                Text("Não há próximo capítulo")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Fechar leitor", action: onClose)
                    .buttonStyle(.bordered)
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .background(Color.black.opacity(0.85))
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Zonas de toque

private struct TapZoneOverlay: View {
    let cells: [[TapAction]]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { col in
                        let action = cells[row][col]
                        color(action)
                            .overlay {
                                Text(label(action))
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                            }
                    }
                }
            }
        }
        .ignoresSafeArea()
    }

    private func color(_ action: TapAction) -> Color {
        switch action {
        case .previous: return Color.blue.opacity(0.45)
        case .next: return Color.green.opacity(0.45)
        case .menu: return Color.gray.opacity(0.35)
        }
    }

    private func label(_ action: TapAction) -> String {
        switch action {
        case .previous: return "Anterior"
        case .next: return "Próxima"
        case .menu: return "Menu"
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
            ScrollViewReader { proxy in
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
                .onAppear {
                    if chapters.indices.contains(currentIndex) {
                        proxy.scrollTo(chapters[currentIndex].id, anchor: .center)
                    }
                }
            }
            .navigationTitle("Capítulos (\(chapters.count))")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Buscar capítulo...")
        }
    }
}

// MARK: - Reader Preferences
enum ReaderPreferences {
    static func volumeButtonsFooter(inverted: Bool) -> String {
        let (forward, back) = inverted ? ("Volume +", "Volume −") : ("Volume −", "Volume +")
        return "\(forward) avança e \(back) volta. No fim do capítulo, o próximo é aberto em seguida. Enquanto ligado, os botões não mudam o volume dentro do leitor."
    }
}

// MARK: - Reader Settings Sheet
private struct ReaderSettingsSheet: View {
    @Bindable var settings: ReaderSettings
    @Binding var modeOverride: ReadingMode?
    @Binding var orientationOverride: ReaderOrientation?
    let canSavePerManga: Bool
    let onClose: () -> Void

    @AppStorage(Preferences.Key.readerVolumeButtons) private var volumeButtons = Preferences.Default.readerVolumeButtons
    @AppStorage(Preferences.Key.readerInvertVolumeButtons) private var invertVolumeButtons = Preferences.Default.readerInvertVolumeButtons
    @AppStorage(Preferences.Key.incognito) private var incognito = Preferences.Default.incognito

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Nesta obra", selection: $modeOverride) {
                        Text("Padrão (\(settings.defaultMode.shortTitle))").tag(ReadingMode?.none)
                        ForEach(ReadingMode.allCases) { mode in
                            Text(mode.title).tag(ReadingMode?.some(mode))
                        }
                    }
                    Picker("Padrão", selection: $settings.defaultMode) {
                        ForEach(ReadingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                } header: {
                    Text("Modo de leitura")
                } footer: {
                    if !canSavePerManga {
                        Text("O modo desta obra só fica salvo para obras da biblioteca.")
                    }
                }

                Section("Toque") {
                    Picker("Zonas de toque", selection: $settings.tapZones) {
                        ForEach(TapZoneLayout.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Inverter zonas", selection: $settings.tapInversion) {
                        ForEach(TapInversion.allCases) { Text($0.title).tag($0) }
                    }
                }

                Section("Paginado") {
                    Picker("Escala", selection: $settings.pageScale) {
                        ForEach(PageScale.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Posição inicial do zoom", selection: $settings.zoomStart) {
                        ForEach(ZoomStart.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Duas páginas na horizontal", isOn: $settings.dualPageInLandscape)
                    Toggle("Girar páginas largas no retrato", isOn: $settings.rotateWidePages)
                }

                Section("Webtoon") {
                    VStack(alignment: .leading) {
                        Text("Margem lateral: \(Int(settings.webtoonSidePadding))%")
                        Slider(value: $settings.webtoonSidePadding, in: 0...25, step: 5)
                    }
                }

                Section("Geral") {
                    Toggle("Cortar bordas", isOn: $settings.cropBorders)
                    Picker("Fundo", selection: $settings.background) {
                        ForEach(ReaderBackground.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Mostrar número da página", isOn: $settings.showPageNumber)
                    Toggle("Manter tela ligada", isOn: $settings.keepScreenOn)
                    Picker("Orientação nesta obra", selection: $orientationOverride) {
                        Text("Padrão (\(settings.defaultOrientation.title))").tag(ReaderOrientation?.none)
                        ForEach(ReaderOrientation.allCases) { Text($0.title).tag(ReaderOrientation?.some($0)) }
                    }
                    Picker("Orientação padrão", selection: $settings.defaultOrientation) {
                        ForEach(ReaderOrientation.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Sempre mostrar transição de capítulo", isOn: $settings.alwaysShowTransition)
                }

                Section("Cores") {
                    VStack(alignment: .leading) {
                        Text("Escurecer: \(Int(settings.dimming * 100))%")
                        Slider(value: $settings.dimming, in: 0...0.8)
                    }
                    Toggle("Escala de cinza", isOn: $settings.grayscale)
                    Toggle("Inverter cores", isOn: $settings.invertColors)
                    Toggle("Filtro de cor", isOn: $settings.colorFilterEnabled)
                    if settings.colorFilterEnabled {
                        ColorPicker("Cor do filtro", selection: $settings.colorFilterColor, supportsOpacity: false)
                        Picker("Mistura", selection: $settings.colorFilterBlend) {
                            ForEach(ColorFilterBlend.allCases) { Text($0.title).tag($0) }
                        }
                    }
                }

                Section("Capítulos") {
                    Toggle("Pular capítulos lidos", isOn: $settings.skipRead)
                    Toggle("Pular capítulos repetidos", isOn: $settings.skipDuplicates)
                    Stepper("Pré-carregar \(settings.preloadCount) páginas", value: $settings.preloadCount, in: 0...10)
                    Toggle("Pré-carregar só no Wi‑Fi", isOn: $settings.preloadOnlyOnWifi)
                }

                Section {
                    Toggle("Modo anônimo", isOn: $incognito)
                } footer: {
                    Text("Enquanto ligado, nada vai para o histórico e o progresso não é salvo.")
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
                    if let chapter {
                        LabeledContent("Fonte", value: SourceManager.shared.sourceName(id: chapter.sourceId))
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

// MARK: - Avisos
private enum ReaderEdgeHint: Equatable {
    case loadingNext
    case lastChapter
    case chapterStart

    var message: (title: String, subtitle: String?) {
        switch self {
        case .loadingNext: return ("Fim do capítulo", "Carregando o próximo…")
        case .lastChapter: return ("Fim do capítulo", "Não há próximo capítulo")
        case .chapterStart: return ("Início do capítulo", nil)
        }
    }
}

private extension String {
    var message: (title: String, subtitle: String?) { (self, nil) }
}

private struct ReaderHintView: View {
    let title: String
    let subtitle: String?

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
/// Rola o UIScrollView por trás do Webtoon. No iOS 17 o ScrollView do SwiftUI só rola até uma
/// view, e páginas de webtoon costumam ser mais altas que a tela.
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

    /// Rola uma fração da altura visível. Retorna false se já estava no limite
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
        pending = (CGPoint(x: current.x, y: target), Date().addingTimeInterval(1))
        scrollView.setContentOffset(CGPoint(x: current.x, y: target), animated: true)
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
