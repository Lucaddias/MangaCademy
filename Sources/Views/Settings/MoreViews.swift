import SwiftUI
import SwiftData
import WebKit

/// Números da biblioteca e da leitura (como Mais › Estatísticas no Mihon).
struct StatsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var stats: Stats?

    struct Stats {
        var library = 0
        var completed = 0
        var started = 0
        var chaptersRead = 0
        var unread = 0
        var readingTime: Double = 0
        var downloaded = 0
        var tracked = 0
        var meanScore: Double?
        var sources = 0
    }

    var body: some View {
        List {
            if let stats {
                Section("Biblioteca") {
                    row("Obras", "\(stats.library)")
                    row("Completas", "\(stats.completed)")
                    row("Iniciadas", "\(stats.started)")
                    row("Fontes usadas", "\(stats.sources)")
                }
                Section("Capítulos") {
                    row("Lidos", "\(stats.chaptersRead)")
                    row("Não lidos", "\(stats.unread)")
                    row("Baixados", "\(stats.downloaded)")
                    row("Tempo de leitura", Self.duration(stats.readingTime))
                }
                Section("Rastreamento") {
                    row("Obras rastreadas", "\(stats.tracked)")
                    row("Nota média", stats.meanScore.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "–")
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Estatísticas")
        .navigationBarTitleDisplayMode(.inline)
        .task { stats = compute() }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value).monospacedDigit()
    }

    static func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "–"
    }

    private func compute() -> Stats {
        var stats = Stats()
        let favorites = (try? modelContext.fetch(FetchDescriptor<Manga>(predicate: #Predicate { $0.isFavorite == true }))) ?? []
        let ids = Set(favorites.map(\.id))
        let chapters = (try? modelContext.fetch(FetchDescriptor<Chapter>())) ?? []
        stats.library = favorites.count
        stats.completed = favorites.filter { $0.status == 2 }.count
        stats.started = Set(chapters.filter { ids.contains($0.mangaId) && ($0.isRead || $0.lastPageRead > 0) }.map(\.mangaId)).count
        stats.chaptersRead = chapters.filter(\.isRead).count
        stats.unread = favorites.reduce(0) { $0 + $1.unreadCount }
        stats.sources = Set(favorites.flatMap { manga in UnifiedWork.refs(fromJSON: manga.sourcesJSON).map(\.sourceId) + [manga.sourceId] }).count
        stats.readingTime = ((try? modelContext.fetch(FetchDescriptor<HistoryEntry>())) ?? []).reduce(0) { $0 + $1.timeRead }
        stats.downloaded = favorites.reduce(0) { $0 + DownloadStore.shared.downloadedCount(mangaId: $1.id) }
        let tracks = (try? modelContext.fetch(FetchDescriptor<TrackRecord>())) ?? []
        stats.tracked = Set(tracks.map(\.mangaId)).count
        let scores = tracks.map(\.score).filter { $0 > 0 }
        stats.meanScore = scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count)
        return stats
    }
}

/// Segurança (bloqueio, seletor de apps) e aparência (tema).
struct SecurityAppearanceView: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Aparência") {
                Picker("Tema", selection: $settings.theme) {
                    Text("Sistema").tag(0)
                    Text("Claro").tag(1)
                    Text("Escuro").tag(2)
                }
                .pickerStyle(.segmented)
            }
            Section {
                Toggle("Bloquear com \(AppSettings.biometryName)", isOn: $settings.lockEnabled)
                if settings.lockEnabled {
                    Picker("Pedir depois de", selection: $settings.lockAfterMinutes) {
                        Text("Sempre").tag(0)
                        Text("1 minuto").tag(1)
                        Text("5 minutos").tag(5)
                        Text("15 minutos").tag(15)
                        Text("1 hora").tag(60)
                    }
                }
                Toggle("Esconder no seletor de apps", isOn: $settings.hideInSwitcher)
            } header: {
                Text("Segurança")
            } footer: {
                Text("O modo anônimo (não gravar histórico) fica no menu do leitor.")
            }
        }
        .navigationTitle("Aparência e segurança")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Limpeza do banco e dados de navegação (Mais › Ajustes › Dados/Avançado no Mihon).
struct DataCleanupView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var keepRead = true
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Toggle("Manter obras com capítulos lidos", isOn: $keepRead)
                Button("Limpar obras fora da biblioteca", role: .destructive) { cleanDatabase() }
            } footer: {
                Text("Apaga do banco as obras que não estão na biblioteca (abertas pelo catálogo) e os capítulos delas sem progresso.")
            }
            Section {
                Button("Limpar cookies e dados da WebView", role: .destructive) { clearWebData() }
            } header: {
                Text("Avançado")
            } footer: {
                Text("Desfaz verificações do Cloudflare e logins feitos pela WebView.")
            }
        }
        .navigationTitle("Dados")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Dados", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: {
            Text(message ?? "")
        }
    }

    private func cleanDatabase() {
        let mangas = (try? modelContext.fetch(FetchDescriptor<Manga>(predicate: #Predicate { $0.isFavorite == false }))) ?? []
        let chapters = (try? modelContext.fetch(FetchDescriptor<Chapter>())) ?? []
        let favorites = Set(((try? modelContext.fetch(FetchDescriptor<Manga>(predicate: #Predicate { $0.isFavorite == true }))) ?? []).map(\.id))
        let withProgress = Set(chapters.filter { $0.isRead || $0.isBookmarked || $0.lastPageRead > 0 }.map(\.mangaId))
        var removedMangas = 0
        for manga in mangas where !(keepRead && withProgress.contains(manga.id)) {
            modelContext.delete(manga)
            removedMangas += 1
        }
        var removedChapters = 0
        for chapter in chapters where !favorites.contains(chapter.mangaId) && !chapter.isRead && !chapter.isBookmarked && chapter.lastPageRead == 0 {
            modelContext.delete(chapter)
            removedChapters += 1
        }
        try? modelContext.save()
        message = "\(removedMangas) obras e \(removedChapters) capítulos apagados."
    }

    private func clearWebData() {
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        message = "Cookies e dados da WebView apagados."
    }
}

/// Primeiro uso: idioma, conteúdo adulto, avisos e backup do Mihon.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Preferences.Key.languageFilter) private var filterRaw: String = Preferences.Default.languageFilter.rawValue
    @AppStorage(Preferences.Key.blockAdultTags) private var blockAdult = Preferences.Default.blockAdultTags
    @State private var notificationsAsked = false
    @State private var showBackup = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Leia mangás, manhwas e webtoons de centenas de fontes, como no Mihon.")
                        .font(.callout)
                }
                Section {
                    Picker("Idioma", selection: $filterRaw) {
                        ForEach(LanguageFilter.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Idioma preferido")
                } footer: {
                    Text("O Explorar mostra obras de todos os idiomas; os capítulos neste idioma aparecem primeiro.")
                }
                Section {
                    Toggle("Esconder conteúdo adulto", isOn: $blockAdult)
                }
                Section {
                    Button(notificationsAsked ? "Pedido enviado" : "Avisar sobre capítulos novos") {
                        Task {
                            _ = await UpdateNotifier.requestPermission()
                            notificationsAsked = true
                        }
                    }
                    .disabled(notificationsAsked)
                    Button("Importar backup do Mihon ou do MangaCademy") { showBackup = true }
                }
            }
            .navigationTitle("Bem-vindo")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Começar") {
                        AppSettings.shared.onboardingDone = true
                        dismiss()
                    }
                }
            }
            .navigationDestination(isPresented: $showBackup) { BackupView() }
        }
        .interactiveDismissDisabled()
    }
}
