import SwiftUI
import SwiftData

public struct SettingsView: View {
    @State private var cacheCleared = false
    @State private var repository = KeiyoushiRepository.shared
    @State private var readerSettings = ReaderSettings.shared
    @State private var librarySettings = LibrarySettings.shared
    @State private var downloads = DownloadManager.shared
    @Query(sort: \MangaCategory.order) private var categories: [MangaCategory]
    @AppStorage("chapter_swipe_start") private var swipeStart = ChapterSwipeAction.toggleBookmark.rawValue
    @AppStorage("chapter_swipe_end") private var swipeEnd = ChapterSwipeAction.toggleRead.rawValue
    @AppStorage(Preferences.Key.showNsfwSources) private var showNsfw = Preferences.Default.showNsfwSources
    @AppStorage(Preferences.Key.blockAdultTags) private var blockAdult = Preferences.Default.blockAdultTags
    @AppStorage(Preferences.Key.readerVolumeButtons) private var volumeButtons = Preferences.Default.readerVolumeButtons
    @AppStorage(Preferences.Key.readerInvertVolumeButtons) private var invertVolumeButtons = Preferences.Default.readerInvertVolumeButtons

    public init() {}

    /// "1.0.0 (1)", lido do Info.plist do app.
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ExtensionsView()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Extensões Keiyoushi")
                                .font(.headline)
                            Text("\(repository.supportedSourceCount) de \(repository.totalSourceCount) fontes ativas no app")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle("Mostrar fontes +18", isOn: $showNsfw)

                    Button {
                        Task { await repository.refreshLive() }
                    } label: {
                        HStack {
                            Text("Atualizar índice do repositório")
                            Spacer()
                            if repository.isLoading {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(repository.isLoading)
                } header: {
                    Text("Fontes")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let error = repository.lastError {
                            Text("Falha ao atualizar: \(error)")
                                .foregroundStyle(.red)
                        } else if let updated = repository.lastUpdated {
                            Text("Índice de \(updated.formatted(date: .abbreviated, time: .shortened)). Atualizar traz domínios novos dos sites.")
                        }
                    }
                }

                Section("Biblioteca") {
                    NavigationLink("Categorias (\(categories.count))") { CategoryManagerView() }
                    NavigationLink("Atualizações") { UpdateSettingsView() }
                    Picker("Categoria ao adicionar", selection: $librarySettings.defaultCategory) {
                        Text("Padrão").tag("")
                        Text("Perguntar sempre").tag("ask")
                        ForEach(categories) { Text($0.name).tag($0.id) }
                    }
                    Picker("Deslizar para a direita", selection: $swipeStart) {
                        ForEach(ChapterSwipeAction.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Picker("Deslizar para a esquerda", selection: $swipeEnd) {
                        ForEach(ChapterSwipeAction.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                }

                Section {
                    Toggle("Bloquear obras com tag adulta", isOn: $blockAdult)
                } header: {
                    Text("Conteúdo")
                } footer: {
                    Text("Esconde do catálogo e da busca as obras que alguma fonte marca com a tag Adult, Adulto ou +18. Tags como “Vida Adulta” não são bloqueadas.")
                }

                Section {
                    Picker("Modo de leitura padrão", selection: $readerSettings.defaultMode) {
                        ForEach(ReadingMode.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Virar página com o volume", isOn: $volumeButtons)
                    Toggle("Inverter botões de volume", isOn: $invertVolumeButtons)
                        .disabled(!volumeButtons)
                } header: {
                    Text("Leitor")
                } footer: {
                    if volumeButtons {
                        Text(ReaderPreferences.volumeButtonsFooter(inverted: invertVolumeButtons))
                    }
                }

                Section("Downloads") {
                    NavigationLink {
                        DownloadQueueView()
                    } label: {
                        LabeledContent("Fila de downloads", value: downloads.queue.isEmpty ? "" : "\(downloads.queue.count)")
                    }
                    NavigationLink("Ajustes de download") { DownloadSettingsView() }
                }

                Section("Dados") {
                    NavigationLink("Estatísticas") { StatsView() }
                    NavigationLink("Rastreamento") { TrackersSettingsView() }
                    NavigationLink("Backup e restauração") { BackupView() }
                    NavigationLink("Aparência e segurança") { SecurityAppearanceView() }
                    NavigationLink("Limpeza e avançado") { DataCleanupView() }
                }

                Section(header: Text("Armazenamento & Cache")) {
                    Button(role: .destructive) {
                        ImageCache.shared.clearCache()
                        MetadataCache.shared.clear()
                        cacheCleared = true
                    } label: {
                        HStack {
                            Text("Limpar Cache de Imagens")
                            Spacer()
                            if cacheCleared {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }

                Section(header: Text("Sobre o Aplicativo")) {
                    HStack {
                        Text("Versão")
                        Spacer()
                        Text(appVersion)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Repositório de fontes")
                        Spacer()
                        Text("keiyoushi/extensions")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Configurações")
        }
    }
}
