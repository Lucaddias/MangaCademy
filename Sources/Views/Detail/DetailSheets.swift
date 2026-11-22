import SwiftUI
import SwiftData
import PhotosUI

/// Filtros, ordem e exibição da lista de capítulos.
struct ChapterOptionsSheet: View {
    @Binding var flags: ChapterListFlags
    @State private var savedAsDefault = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Filtrar") {
                    triRow("Não lidos", \.unread)
                    triRow("Com marcador", \.bookmarked)
                    triRow("Baixados", \.downloaded)
                }
                Section("Ordenar") {
                    Picker("Ordem", selection: $flags.sort) {
                        ForEach(ChapterListFlags.Sort.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Decrescente", isOn: $flags.descending)
                }
                Section("Exibição") {
                    Picker("Nome", selection: $flags.showNumber) {
                        Text("Nome da fonte").tag(false)
                        Text("Número do capítulo").tag(true)
                    }
                    Toggle("Esconder capítulos faltando", isOn: $flags.hideMissing)
                }
                Section {
                    Button(savedAsDefault ? "Definido como padrão ✓" : "Definir como padrão") {
                        ChapterListFlags.globalDefault = flags
                        savedAsDefault = true
                    }
                } footer: {
                    Text("Obras sem ajuste próprio usam o padrão.")
                }
            }
            .themedList()
            .navigationTitle("Capítulos")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func triRow(_ title: String, _ keyPath: WritableKeyPath<ChapterListFlags, TriState>) -> some View {
        Button {
            flags[keyPath: keyPath] = flags[keyPath: keyPath].next
        } label: {
            HStack {
                Image(systemName: flags[keyPath: keyPath].symbol)
                    .foregroundStyle(flags[keyPath: keyPath] == .exclude ? Theme.critical : Theme.accent)
                Text(title).foregroundStyle(Theme.ink)
            }
        }
    }
}

/// Esconder scans/fontes da obra e escolher a fonte preferida nos capítulos repetidos.
struct ScanlatorFilterSheet: View {
    let scanlators: [String]
    let sourceIds: [String]
    @Binding var excluded: Set<String>
    @Binding var preferredSourceId: String?
    let canSave: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Fonte preferida", selection: $preferredSourceId) {
                        Text("Automática (a mais completa)").tag(String?.none)
                        ForEach(sourceIds, id: \.self) { id in
                            Text(SourceManager.shared.sourceName(id: id)).tag(String?.some(id))
                        }
                    }
                } footer: {
                    Text("Quando o mesmo capítulo existe em várias fontes, fica o da fonte preferida.")
                }
                if sourceIds.count > 1 {
                    Section("Fontes") {
                        ForEach(sourceIds, id: \.self) { id in
                            toggle(SourceManager.shared.sourceName(id: id), key: ScanlatorFilter.sourceKey(id))
                        }
                    }
                }
                Section {
                    if scanlators.isEmpty {
                        Text("As fontes desta obra não informam as scans.")
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    ForEach(scanlators, id: \.self) { scan in
                        toggle(scan, key: scan)
                    }
                } header: {
                    Text("Scans")
                } footer: {
                    if !canSave { Text("Só fica salvo para obras da biblioteca.") }
                }
            }
            .themedList()
            .navigationTitle("Scans e fontes")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func toggle(_ title: String, key: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { !excluded.contains(key) },
            set: { show in
                if show { excluded.remove(key) } else { excluded.insert(key) }
            }
        ))
    }
}

/// Fontes da obra unificada: separar uma unificação errada, anexar à mão e trocar a capa.
struct ManageSourcesSheet: View {
    let model: WorkDetailModel
    let onChange: () -> Void
    let onCoverChange: (WorkSourceRef) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.work.refs) { ref in
                        HStack(spacing: 12) {
                            AsyncMangaCover(urlString: ref.coverUrl, cornerRadius: 4, referer: SourceManager.shared.getSource(id: ref.sourceId)?.imageReferer)
                                .frame(width: 36, height: 54)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ref.sourceName).font(.subheadline.bold())
                                Text(ref.title).font(.caption).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                            }
                            Spacer()
                            if ref.coverUrl != nil && ref.coverUrl == model.work.coverUrl {
                                Image(systemName: "photo.fill").foregroundStyle(Theme.inkSecondary)
                            }
                        }
                        .swipeActions {
                            if model.work.refs.count > 1 {
                                Button("Separar", role: .destructive) {
                                    Task {
                                        await model.detach(refId: ref.id)
                                        onChange()
                                    }
                                }
                            }
                        }
                        .contextMenu {
                            if ref.coverUrl != nil {
                                Button { onCoverChange(ref) } label: { Label("Usar esta capa", systemImage: "photo") }
                            }
                            if model.work.refs.count > 1 {
                                Button(role: .destructive) {
                                    Task {
                                        await model.detach(refId: ref.id)
                                        onChange()
                                    }
                                } label: {
                                    Label("Separar desta obra", systemImage: "scissors")
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Deslize para separar uma fonte unificada por engano. Toque e segure para usar a capa dela.")
                }
                Section {
                    NavigationLink {
                        AttachSourceView(title: model.displayTitle) { ref in
                            Task {
                                await model.attach(ref)
                                onChange()
                            }
                            dismiss()
                        }
                    } label: {
                        Label("Adicionar fonte manualmente", systemImage: "plus")
                    }
                }
            }
            .themedList()
            .navigationTitle("Fontes desta obra")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Escolhe uma fonte, busca a obra nela e anexa o resultado.
private struct AttachSourceView: View {
    let title: String
    let onPick: (WorkSourceRef) -> Void

    @State private var filter = ""

    private var sources: [MangaSource] {
        let all = SourceManager.shared.sources.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return filter.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        List(sources, id: \.id) { source in
            NavigationLink {
                SourceSearchPicker(source: source, initialQuery: title, onPick: onPick)
            } label: {
                HStack {
                    Text(source.name)
                    Spacer()
                    Text(LanguageCode.shortLabel(source.language)).font(.caption).foregroundStyle(Theme.inkSecondary)
                }
            }
        }
        .themedList()
        .searchable(text: $filter, prompt: "Fonte")
        .navigationTitle("Escolha a fonte")
    }
}

private struct SourceSearchPicker: View {
    let source: MangaSource
    let initialQuery: String
    let onPick: (WorkSourceRef) -> Void

    @State private var query = ""
    @State private var results: [SourceMangaItem] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        List {
            if isLoading { ProgressView().frame(maxWidth: .infinity) }
            if let error { Text(error).foregroundStyle(Theme.critical).font(.caption) }
            ForEach(results) { item in
                Button {
                    onPick(WorkSourceRef(sourceId: source.id, sourceName: source.name, remoteUrl: item.remoteUrl, title: item.title, coverUrl: item.coverUrl, languages: item.languages))
                } label: {
                    HStack(spacing: 12) {
                        AsyncMangaCover(urlString: item.coverUrl, cornerRadius: 4, referer: source.imageReferer)
                            .frame(width: 36, height: 54)
                        Text(item.title).foregroundStyle(Theme.ink)
                    }
                }
            }
        }
        .themedList()
        .searchable(text: $query, prompt: "Buscar em \(source.name)")
        .onSubmit(of: .search) { Task { await search() } }
        .navigationTitle(source.name)
        .task {
            guard query.isEmpty else { return }
            query = initialQuery
            await search()
        }
    }

    private func search() async {
        isLoading = true
        error = nil
        do {
            results = try await source.search(query: query, page: 1).items
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

/// Notas do usuário sobre a obra (Markdown).
struct NotesEditorSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let manga: Manga
    @State private var text = ""

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding(.horizontal)
                .navigationTitle("Notas")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Salvar") {
                            manga.notes = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            try? modelContext.save()
                            dismiss()
                        }
                    }
                }
                .onAppear { text = manga.notes }
        }
    }
}

/// Capa em tela cheia: compartilhar, salvar, trocar por uma foto e voltar à original.
struct CoverSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let coverUrl: String?
    let referer: String?
    let manga: Manga?

    @State private var image: UIImage?
    @State private var pickerItem: PhotosPickerItem?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            VStack {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    ProgressView()
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(Theme.inkSecondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    if let image {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview("Capa", image: Image(uiImage: image))) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        Spacer()
                        Button {
                            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                            message = "Capa salva em Fotos"
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                        }
                        .accessibilityLabel("Salvar em Fotos")
                    }
                    if let manga {
                        Spacer()
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Image(systemName: "photo.badge.plus")
                        }
                        .accessibilityLabel("Escolher capa")
                        if manga.customCoverPath != nil {
                            Spacer()
                            Button(role: .destructive) {
                                CustomCoverStore.remove(manga.customCoverPath)
                                manga.customCoverPath = nil
                                try? modelContext.save()
                                dismiss()
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                            }
                            .accessibilityLabel("Voltar à capa original")
                        }
                    }
                }
            }
        }
        .task {
            if let coverUrl { image = await ImageCache.shared.load(urlString: coverUrl, referer: referer) }
        }
        .onChange(of: pickerItem) { _, item in
            Task {
                guard let item, let manga, let data = try? await item.loadTransferable(type: Data.self),
                      let picked = UIImage(data: data), let jpeg = picked.jpegData(compressionQuality: 0.9),
                      let name = CustomCoverStore.save(jpeg) else { return }
                CustomCoverStore.remove(manga.customCoverPath)
                manga.customCoverPath = name
                try? modelContext.save()
                image = picked
                message = "Capa personalizada salva"
            }
        }
    }
}

/// Resultados da busca unificada (gênero, autor ou título tocados no detalhe).
struct SearchResultsView: View {
    @Environment(\.modelContext) private var modelContext
    let query: String
    /// Busca por tag: obras populares que têm a tag (e as outras que o usuário marcar).
    var isTag = false
    @AppStorage(Preferences.Key.languageFilter) private var filterRaw: String = Preferences.Default.languageFilter.rawValue
    @AppStorage(Preferences.Key.showNsfwSources) private var showNsfw = Preferences.Default.showNsfwSources
    @AppStorage(Preferences.Key.blockAdultTags) private var blockAdult = Preferences.Default.blockAdultTags
    @State private var feed = CatalogFeed()

    private var filter: LanguageFilter { LanguageFilter(rawValue: filterRaw) ?? .portuguese }

    private var title: String {
        guard isTag else { return query }
        let key = GenreTags.key(for: query)
        return key.hasPrefix("~") ? query : GenreTags.label(for: key)
    }

    var body: some View {
        ScrollView {
            if isTag {
                TagChipsBar(tags: feed.availableTags, selection: Binding(get: { feed.tagFilter }, set: { feed.setTagFilter($0) }))
                    .padding(.top, 8)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 105, maximum: 130), spacing: 14)], spacing: 16) {
                ForEach(feed.works) { work in
                    NavigationLink(value: work) {
                        MangaGridItem(work: work, filter: filter)
                    }
                    .buttonStyle(.plain)
                    .onAppear { feed.onAppear(of: work) }
                }
            }
            .padding()
            if feed.isExhausted {
                Text(feed.works.isEmpty ? (isTag ? "Nenhuma obra com essas tags." : "Nada encontrado para “\(query)”.") : "Fim dos resultados")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
                    .padding()
            } else {
                VStack(spacing: 6) {
                    ProgressView()
                    if isTag {
                        Text("\(feed.works.count) de \(feed.loadedCount) obras verificadas têm as tags")
                            .font(.caption)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
                .padding()
                .onAppear { feed.requestMore() }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard feed.totalSources == 0 else { return }
            if isTag { feed.setTagFilter([GenreTags.key(for: query)]) }
            reload()
        }
        .onChange(of: showNsfw) { _, _ in reload() }
        .onChange(of: blockAdult) { _, _ in reload() }
    }

    private func reload() {
        Self.configureSafety(feed, context: modelContext)
        feed.reset(filter: .all, mode: isTag ? .popular : .search(query), includeNsfw: showNsfw)
    }

    static func configureSafety(_ feed: CatalogFeed, context: ModelContext) {
        let safety = LocalIdentitySafety.Gate(context: context)
        feed.canMergeIdentities = { safety.decide($0) }
    }
}
