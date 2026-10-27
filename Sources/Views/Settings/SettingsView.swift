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
    @AppStorage(Preferences.Key.languageFilter) private var filterRaw: String = Preferences.Default.languageFilter.rawValue
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
                Group {
                    Section {
                        NavigationLink {
                            ExtensionsView()
                        } label: {
                            LabeledContent("Extensões Keiyoushi") {
                                Text("\(repository.supportedSourceCount)/\(repository.totalSourceCount)")
                                    .monospacedDigit()
                            }
                        }
                        .accessibilityValue("\(repository.supportedSourceCount) de \(repository.totalSourceCount) fontes ativas")

                        // Antes era a aba "Fontes" do Explorar
                        NavigationLink("Fontes") {
                            SourcesListView()
                                .navigationTitle("Fontes")
                                .navigationBarTitleDisplayMode(.inline)
                        }

                        Picker("Idioma preferido", selection: $filterRaw) {
                            ForEach(LanguageFilter.allCases) { Text($0.title).tag($0.rawValue) }
                        }

                        Toggle("Mostrar fontes +18", isOn: $showNsfw)

                        Button {
                            Task { await repository.refreshLive() }
                        } label: {
                            HStack {
                                Text("Atualizar índice")
                                Spacer()
                                if repository.isLoading {
                                    ProgressView()
                                } else if let updated = repository.lastUpdated {
                                    Text(updated.formatted(.relative(presentation: .named)))
                                        .foregroundStyle(Theme.inkTertiary)
                                }
                            }
                        }
                        .disabled(repository.isLoading)
                    } header: {
                        Text("Fontes")
                    } footer: {
                        if let error = repository.lastError {
                            Text("Falha ao atualizar: \(error)")
                                .foregroundStyle(Theme.critical)
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
                        Text("Inclui obras que só existem em fontes +18.")
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
                        Button {
                            ImageCache.shared.clearCache()
                            MetadataCache.shared.clear()
                            cacheCleared = true
                        } label: {
                            HStack {
                                Text("Limpar cache de imagens")
                                    .foregroundStyle(Theme.critical)
                                Spacer()
                                if cacheCleared {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.positive)
                                }
                            }
                        }
                    }

                    Section("Sobre") {
                        LabeledContent("Versão", value: appVersion)
                        LabeledContent("Repositório", value: "keiyoushi/extensions")
                    }
                }
                .listRowBackground(Theme.surface)
            }
            .themedList()
            .navigationTitle("Ajustes")
            .navigationDestination(for: SourceRoute.self) { route in
                if let source = SourceManager.shared.getSource(id: route.id) {
                    SourceBrowseView(source: source)
                }
            }
            .navigationDestination(for: UnifiedWork.self) { work in
                MangaDetailView(work: work)
            }
        }
    }
}
