import SwiftUI
import SwiftData
import AuthenticationServices

/// Folha "Rastreamento" do detalhe: vincular a obra e editar status, progresso, nota e datas.
struct TrackingSheet: View {
    let mangaId: String
    let title: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var records: [TrackRecord]
    @State private var manager = TrackerManager.shared
    @State private var searching: SearchTarget?
    @State private var message: String?

    private struct SearchTarget: Identifiable {
        let tracker: Tracker
        let id: String
    }

    init(mangaId: String, title: String) {
        self.mangaId = mangaId
        self.title = title
        let id = mangaId
        _records = Query(filter: #Predicate<TrackRecord> { $0.mangaId == id })
    }

    var body: some View {
        NavigationStack {
            List {
                let _ = manager.version
                ForEach(manager.trackers, id: \.id) { tracker in
                    Section(tracker.name) {
                        if let record = records.first(where: { $0.trackerId == tracker.id }) {
                            TrackRecordEditor(record: record, tracker: tracker, onError: { message = $0 })
                            Button("Desvincular", role: .destructive) {
                                modelContext.delete(record)
                                try? modelContext.save()
                            }
                        } else if tracker.isLoggedIn {
                            Button("Vincular", systemImage: "link") { searching = SearchTarget(tracker: tracker, id: tracker.id) }
                        } else {
                            NavigationLink("Entrar para vincular") { TrackersSettingsView() }
                        }
                    }
                }
            }
            .themedList()
            .navigationTitle("Rastreamento")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
            .sheet(item: $searching) { target in
                TrackSearchView(tracker: target.tracker, initialQuery: title) { result in
                    bind(result, tracker: target.tracker)
                }
            }
            .alert("Rastreamento", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") {}
            } message: {
                Text(message ?? "")
            }
        }
    }

    private func bind(_ result: TrackSearchResult, tracker: Tracker) {
        let record = TrackRecord(mangaId: mangaId, trackerId: tracker.id, remoteId: result.remoteId, title: result.title)
        record.totalChapters = result.totalChapters
        record.remoteUrl = result.remoteUrl
        record.status = TrackStatus.reading.rawValue
        // Começa com o que já foi lido aqui.
        let read = ChapterStore.records(mangaId: mangaId, context: modelContext).filter(\.isRead).map(\.chapterNumber).max() ?? 0
        record.lastChapterRead = floor(read)
        modelContext.insert(record)
        try? modelContext.save()
        Task {
            do {
                // Se já existe na lista do usuário, traz o progresso de lá (o maior vale).
                let remote = try await tracker.refresh(record)
                if let chapter = remote.lastChapterRead, chapter > record.lastChapterRead { record.lastChapterRead = chapter }
                if let status = remote.status { record.status = status.rawValue }
                if let score = remote.score { record.score = score }
                if let total = remote.totalChapters, total > 0 { record.totalChapters = total }
                record.startDate = remote.startDate ?? record.startDate
                record.finishDate = remote.finishDate ?? record.finishDate
                try await tracker.update(record)
                try? modelContext.save()
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

/// Campos de um vínculo; cada mudança é enviada ao rastreador.
private struct TrackRecordEditor: View {
    @Bindable var record: TrackRecord
    let tracker: Tracker
    let onError: (String) -> Void

    var body: some View {
        Group {
            if let url = record.remoteUrl.flatMap(URL.init(string:)) {
                Link(destination: url) { Label(record.title, systemImage: "arrow.up.right.square") }
            } else {
                Text(record.title)
            }
            Picker("Status", selection: $record.status) {
                ForEach(TrackStatus.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Stepper(value: $record.lastChapterRead, in: 0...Double(max(record.totalChapters, 100_000))) {
                Text("Capítulo \(Int(record.lastChapterRead))" + (record.totalChapters > 0 ? " de \(record.totalChapters)" : ""))
            }
            Picker("Nota", selection: $record.score) {
                Text("Sem nota").tag(0.0)
                ForEach(tracker.scores.filter { $0 > 0 }, id: \.self) { Text($0.formatted()).tag($0) }
            }
            DatePicker("Início", selection: Binding(get: { record.startDate ?? Date() }, set: { record.startDate = $0 }), displayedComponents: .date)
            DatePicker("Fim", selection: Binding(get: { record.finishDate ?? Date() }, set: { record.finishDate = $0 }), displayedComponents: .date)
        }
        .onChange(of: record.status) { push() }
        .onChange(of: record.lastChapterRead) { push() }
        .onChange(of: record.score) { push() }
        .onChange(of: record.startDate) { push() }
        .onChange(of: record.finishDate) { push() }
    }

    private func push() {
        Task {
            do { try await tracker.update(record) } catch { onError(error.localizedDescription) }
        }
    }
}

/// Busca no rastreador. `id:123` vai direto à obra.
private struct TrackSearchView: View {
    let tracker: Tracker
    let initialQuery: String
    let onPick: (TrackSearchResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [TrackSearchResult] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(Theme.critical).font(.footnote) }
                ForEach(results) { result in
                    Button {
                        onPick(result)
                        dismiss()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            AsyncMangaCover(urlString: result.coverUrl, cornerRadius: 6)
                                .frame(width: 50, height: 75)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.title).font(.subheadline.bold())
                                if let publishing = result.publishing { Text(publishing).font(.caption).foregroundStyle(Theme.inkSecondary) }
                                if let summary = result.summary {
                                    Text(summary).font(.caption).foregroundStyle(Theme.inkSecondary).lineLimit(3)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .themedList()
            .overlay { if isLoading { ProgressView() } }
            .navigationTitle(tracker.name)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Título ou id:123")
            .onSubmit(of: .search) { run() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
            }
            .task {
                if query.isEmpty {
                    query = initialQuery
                    run()
                }
            }
        }
    }

    private func run() {
        let text = query.trimmed
        guard !text.isEmpty else { return }
        isLoading = true
        error = nil
        Task {
            do { results = try await tracker.search(text) } catch { self.error = error.localizedDescription }
            isLoading = false
        }
    }
}

/// Ajustes › Rastreamento: entrar e sair de cada serviço.
struct TrackersSettingsView: View {
    @State private var manager = TrackerManager.shared
    @State private var passwordLogin: PasswordTarget?
    @State private var message: String?

    private struct PasswordTarget: Identifiable {
        let tracker: Tracker
        let id: String
    }

    var body: some View {
        Form {
            let _ = manager.version
            Section {
                ForEach(manager.trackers, id: \.id) { tracker in
                    HStack {
                        Text(tracker.name)
                        Spacer()
                        if tracker.isLoggedIn {
                            Button("Sair", role: .destructive) {
                                tracker.logout()
                                manager.changed()
                            }
                        } else if let login = tracker.login {
                            Button("Entrar") { start(login, tracker: tracker) }
                        } else {
                            Text("Precisa de client ID").font(.caption).foregroundStyle(Theme.inkSecondary)
                        }
                    }
                }
            } footer: {
                Text("AniList precisa de um app registrado em anilist.co/settings/developer com redirecionamento mangacademy://anilist; o ID vai na chave AniListClientID do Info.plist.")
            }
            Section {
                Toggle("Atualizar ao marcar como lido", isOn: $manager.updateOnRead)
            }
        }
        .themedList()
        .navigationTitle("Rastreamento")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $passwordLogin) { target in
            PasswordLoginView(tracker: target.tracker) { manager.changed() }
        }
        .alert("Rastreamento", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: {
            Text(message ?? "")
        }
    }

    private func start(_ login: TrackerLogin, tracker: Tracker) {
        switch login {
        case .password:
            passwordLogin = PasswordTarget(tracker: tracker, id: tracker.id)
        case .oauth(let url):
            Task {
                do {
                    let callback = try await OAuthSession.start(url: url, scheme: "mangacademy")
                    try await tracker.completeOAuth(callback: callback)
                    manager.changed()
                } catch {
                    if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin { message = error.localizedDescription }
                }
            }
        }
    }
}

private struct PasswordLoginView: View {
    let tracker: Tracker
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Usuário", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Senha", text: $password)
                    .textContentType(.password)
                if let error { Text(error).foregroundStyle(Theme.critical).font(.footnote) }
            }
            .themedList()
            .navigationTitle(tracker.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isLoading {
                        ProgressView()
                    } else {
                        Button("Entrar") { submit() }.disabled(username.isEmpty || password.isEmpty)
                    }
                }
            }
        }
    }

    private func submit() {
        isLoading = true
        error = nil
        Task {
            do {
                try await tracker.login(username: username, password: password)
                onDone()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }
}

/// `ASWebAuthenticationSession` com async/await.
@MainActor
enum OAuthSession {
    private static var current: ASWebAuthenticationSession?
    private static let anchor = Anchor()

    private final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }

    static func start(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback { continuation.resume(returning: callback) } else { continuation.resume(throwing: error ?? TrackerError.notLoggedIn) }
            }
            session.presentationContextProvider = anchor
            current = session
            session.start()
        }
    }
}
