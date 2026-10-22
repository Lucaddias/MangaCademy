import SwiftUI
import SwiftData

/// Criar, renomear, apagar e reordenar categorias da biblioteca.
struct CategoryManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MangaCategory.order) private var categories: [MangaCategory]

    @State private var editing: MangaCategory?
    @State private var isCreating = false
    @State private var name = ""
    @State private var deleting: MangaCategory?

    var body: some View {
        List {
            if categories.isEmpty {
                ContentUnavailableView(
                    "Nenhuma categoria",
                    systemImage: "folder",
                    description: Text("Categorias viram abas na biblioteca. Obras sem categoria ficam em “Padrão”.")
                )
            }
            ForEach(categories) { category in
                Button {
                    name = category.name
                    editing = category
                } label: {
                    Label(category.name, systemImage: "folder")
                        .foregroundStyle(.primary)
                }
                .swipeActions {
                    Button("Apagar", role: .destructive) { deleting = category }
                }
            }
            .onMove(perform: move)
        }
        .navigationTitle("Categorias")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    name = ""
                    isCreating = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Nova categoria")
            }
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .alert("Nova categoria", isPresented: $isCreating) {
            TextField("Nome", text: $name)
            Button("Cancelar", role: .cancel) {}
            Button("Criar") { create() }
        }
        .alert("Renomear categoria", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Nome", text: $name)
            Button("Cancelar", role: .cancel) {}
            Button("Salvar") {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { editing?.name = trimmed }
                try? modelContext.save()
            }
        }
        .confirmationDialog(
            "Apagar “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Apagar categoria", role: .destructive) {
                if let deleting { delete(deleting) }
            }
        } message: {
            Text("As obras não saem da biblioteca; as que ficarem sem categoria vão para “Padrão”.")
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !categories.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        modelContext.insert(MangaCategory(name: trimmed, order: (categories.map(\.order).max() ?? -1) + 1))
        try? modelContext.save()
    }

    private func move(from source: IndexSet, to destination: Int) {
        var list = categories
        list.move(fromOffsets: source, toOffset: destination)
        for (index, category) in list.enumerated() where category.order != index {
            category.order = index
        }
        try? modelContext.save()
    }

    private func delete(_ category: MangaCategory) {
        let id = category.id
        let mangas = (try? modelContext.fetch(FetchDescriptor<Manga>())) ?? []
        for manga in mangas where manga.categoryIds.contains(id) {
            manga.categoryIds.removeAll { $0 == id }
        }
        if LibrarySettings.shared.defaultCategory == id { LibrarySettings.shared.defaultCategory = "" }
        modelContext.delete(category)
        try? modelContext.save()
    }
}

/// Escolher as categorias de uma ou mais obras.
struct CategoryPickerSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \MangaCategory.order) private var categories: [MangaCategory]

    let mangas: [Manga]
    @State private var selected: Set<String>
    @State private var newName = ""
    @State private var isCreating = false

    init(mangas: [Manga]) {
        self.mangas = mangas
        // Com várias obras, começa com as categorias que todas têm em comum.
        let sets = mangas.map { Set($0.categoryIds) }
        _selected = State(initialValue: sets.dropFirst().reduce(sets.first ?? []) { $0.intersection($1) })
    }

    var body: some View {
        NavigationStack {
            List {
                if categories.isEmpty {
                    Text("Nenhuma categoria criada ainda.")
                        .foregroundStyle(.secondary)
                }
                ForEach(categories) { category in
                    Button {
                        if selected.contains(category.id) { selected.remove(category.id) } else { selected.insert(category.id) }
                    } label: {
                        HStack {
                            Text(category.name).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: selected.contains(category.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(category.id) ? Color.accentColor : .secondary)
                        }
                    }
                }
                Button {
                    isCreating = true
                } label: {
                    Label("Nova categoria", systemImage: "plus")
                }
            }
            .navigationTitle(mangas.count == 1 ? "Categorias" : "Categorias de \(mangas.count) obras")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        let ids = categories.map(\.id).filter(selected.contains)
                        for manga in mangas { manga.categoryIds = ids }
                        try? modelContext.save()
                        dismiss()
                    }
                }
            }
            .alert("Nova categoria", isPresented: $isCreating) {
                TextField("Nome", text: $newName)
                Button("Cancelar", role: .cancel) {}
                Button("Criar") {
                    let trimmed = newName.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    let category = MangaCategory(name: trimmed, order: (categories.map(\.order).max() ?? -1) + 1)
                    modelContext.insert(category)
                    selected.insert(category.id)
                    newName = ""
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Folha "Filtrar · Ordenar · Exibição" da biblioteca.
struct LibrarySettingsSheet: View {
    @Bindable var settings: LibrarySettings
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            Form {
                Picker("", selection: $tab) {
                    Text("Filtrar").tag(0)
                    Text("Ordenar").tag(1)
                    Text("Exibição").tag(2)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                switch tab {
                case 0:
                    Section {
                        triRow("Não lidos", $settings.filterUnread)
                        triRow("Iniciados", $settings.filterStarted)
                        triRow("Completos", $settings.filterCompleted)
                        triRow("Com marcador", $settings.filterBookmarked)
                        triRow("Baixados", $settings.filterDownloaded)
                        triRow("Rastreados", $settings.filterTracked)
                    } footer: {
                        Text("Toque para alternar: incluir ✓, excluir ✕ ou ignorar.")
                    }
                case 1:
                    Section {
                        ForEach(LibrarySort.allCases) { option in
                            Button {
                                if settings.sort == option {
                                    if option == .random { settings.randomSeed += 1 } else { settings.ascending.toggle() }
                                } else {
                                    settings.sort = option
                                }
                            } label: {
                                HStack {
                                    Text(option.title).foregroundStyle(.primary)
                                    Spacer()
                                    if settings.sort == option {
                                        Image(systemName: option == .random ? "shuffle" : (settings.ascending ? "arrow.up" : "arrow.down"))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                        }
                    }
                default:
                    Section("Modo") {
                        Picker("Exibição", selection: $settings.displayMode) {
                            ForEach(LibraryDisplayMode.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                    if settings.displayMode != .list {
                        Section("Colunas") {
                            Stepper(settings.portraitColumns == 0 ? "Retrato: automático" : "Retrato: \(settings.portraitColumns)", value: $settings.portraitColumns, in: 0...8)
                            Stepper(settings.landscapeColumns == 0 ? "Paisagem: automático" : "Paisagem: \(settings.landscapeColumns)", value: $settings.landscapeColumns, in: 0...12)
                        }
                    }
                    Section("Selos") {
                        Toggle("Não lidos", isOn: $settings.showUnreadBadge)
                        Toggle("Baixados", isOn: $settings.showDownloadBadge)
                        Toggle("Idioma", isOn: $settings.showLanguageBadge)
                    }
                    Section("Outros") {
                        Toggle("Botão continuar lendo", isOn: $settings.showContinueButton)
                        Toggle("Mostrar abas de categorias", isOn: $settings.showCategoryTabs)
                    }
                }
            }
            .navigationTitle("Biblioteca")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func triRow(_ title: String, _ value: Binding<TriState>) -> some View {
        Button {
            value.wrappedValue = value.wrappedValue.next
        } label: {
            HStack {
                Image(systemName: value.wrappedValue.symbol)
                    .foregroundStyle(value.wrappedValue == .exclude ? Color.red : Color.accentColor)
                Text(title).foregroundStyle(.primary)
            }
        }
    }
}
