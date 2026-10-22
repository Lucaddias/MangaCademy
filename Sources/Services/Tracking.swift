import Foundation
import Security
import SwiftData

// MARK: - Modelo

/// Status de leitura no rastreador (valores guardados em `TrackRecord.status`).
enum TrackStatus: Int, CaseIterable, Identifiable {
    case reading = 1, completed, onHold, dropped, planToRead, rereading

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .reading: return "Lendo"
        case .completed: return "Completo"
        case .onHold: return "Pausado"
        case .dropped: return "Abandonado"
        case .planToRead: return "Planejo ler"
        case .rereading: return "Relendo"
        }
    }
}

struct TrackSearchResult: Identifiable, Hashable {
    var id: String { remoteId }
    let remoteId: String
    let title: String
    let coverUrl: String?
    let summary: String?
    let totalChapters: Int
    let remoteUrl: String?
    let publishing: String?
}

/// Estado remoto de um vínculo.
struct TrackRemoteState {
    var status: TrackStatus?
    var score: Double?
    var lastChapterRead: Double?
    var totalChapters: Int?
    var startDate: Date?
    var finishDate: Date?
}

enum TrackerError: LocalizedError {
    case notLoggedIn, missingClientId, badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "Entre na sua conta do rastreador em Ajustes › Rastreamento."
        case .missingClientId: return "Este rastreador precisa de um client ID registrado (veja Ajustes › Rastreamento)."
        case .badResponse(let message): return message
        }
    }
}

enum TrackerLogin {
    /// OAuth no navegador do sistema.
    case oauth(URL)
    /// Usuário e senha da conta do serviço.
    case password
}

@MainActor
protocol Tracker: AnyObject {
    var id: String { get }
    var name: String { get }
    /// Notas possíveis (ex.: 0...10 de 0,5 em 0,5).
    var scores: [Double] { get }
    var isLoggedIn: Bool { get }
    var login: TrackerLogin? { get }

    func completeOAuth(callback: URL) async throws
    func login(username: String, password: String) async throws
    func logout()
    func search(_ query: String) async throws -> [TrackSearchResult]
    /// Cria ou atualiza a entrada na lista do usuário.
    func update(_ record: TrackRecord) async throws
    func refresh(_ record: TrackRecord) async throws -> TrackRemoteState
}

extension Tracker {
    func completeOAuth(callback: URL) async throws {}
    func login(username: String, password: String) async throws {}
}

// MARK: - Keychain

enum Keychain {
    private static let service = "com.lucadias.MihonReader.trackers"

    static func set(_ value: String?, for key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        guard let value else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Registro

@MainActor
@Observable
final class TrackerManager {
    static let shared = TrackerManager()

    let trackers: [Tracker] = [AniListTracker(), MangaUpdatesTracker()]
    /// Muda a cada login/logout, para a interface se atualizar.
    private(set) var version = 0

    var updateOnRead: Bool {
        didSet { UserDefaults.standard.set(updateOnRead, forKey: "track_update_on_read") }
    }

    private init() {
        updateOnRead = UserDefaults.standard.object(forKey: "track_update_on_read") as? Bool ?? true
    }

    func tracker(_ id: String) -> Tracker? { trackers.first { $0.id == id } }

    func changed() { version += 1 }

    /// Depois de marcar um capítulo como lido: avança o progresso nos rastreadores vinculados.
    func chapterRead(_ chapterNumber: Double, mangaId: String, context: ModelContext) {
        guard updateOnRead, chapterNumber > 0 else { return }
        let id = mangaId
        let records = (try? context.fetch(FetchDescriptor<TrackRecord>(predicate: #Predicate { $0.mangaId == id }))) ?? []
        for record in records where chapterNumber > record.lastChapterRead {
            guard let tracker = tracker(record.trackerId), tracker.isLoggedIn else { continue }
            record.lastChapterRead = floor(chapterNumber)
            if record.status == TrackStatus.planToRead.rawValue { record.status = TrackStatus.reading.rawValue }
            if record.startDate == nil { record.startDate = Date() }
            if record.totalChapters > 0, Int(record.lastChapterRead) >= record.totalChapters {
                record.status = TrackStatus.completed.rawValue
                record.finishDate = record.finishDate ?? Date()
            }
            try? context.save()
            Task { try? await tracker.update(record) }
        }
    }
}

// MARK: - AniList

/// AniList (GraphQL). A busca é pública; editar a lista exige login OAuth com um client ID
/// registrado em anilist.co/settings/developer (redirect `mangacademy://anilist`).
@MainActor
final class AniListTracker: Tracker {
    let id = "anilist"
    let name = "AniList"
    let scores = stride(from: 0.0, through: 10.0, by: 0.5).map { $0 }
    private let endpoint = URL(string: "https://graphql.anilist.co")!

    static var clientId: String {
        (Bundle.main.object(forInfoDictionaryKey: "AniListClientID") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    private var token: String? { Keychain.get("anilist_token") }
    var isLoggedIn: Bool { token != nil }

    var login: TrackerLogin? {
        guard !Self.clientId.isEmpty else { return nil }
        return .oauth(URL(string: "https://anilist.co/api/v2/oauth/authorize?client_id=\(Self.clientId)&response_type=token")!)
    }

    func completeOAuth(callback: URL) async throws {
        // O token vem no fragmento: mangacademy://anilist#access_token=...&token_type=Bearer
        let fragment = callback.fragment ?? ""
        let pairs = fragment.split(separator: "&").map { $0.split(separator: "=", maxSplits: 1).map(String.init) }
        guard let token = pairs.first(where: { $0.first == "access_token" })?.last else {
            throw TrackerError.badResponse("O AniList não devolveu o token.")
        }
        Keychain.set(token, for: "anilist_token")
    }

    func logout() { Keychain.set(nil, for: "anilist_token") }

    private func query(_ query: String, variables: [String: Any], auth: Bool) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if auth {
            guard let token else { throw TrackerError.notLoggedIn }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TrackerError.badResponse("Resposta inválida do AniList.") }
        if let errors = root["errors"] as? [[String: Any]], let message = errors.first?["message"] as? String {
            if message.localizedCaseInsensitiveContains("invalid token") { logout() }
            throw TrackerError.badResponse("AniList: \(message)")
        }
        return root["data"] as? [String: Any] ?? [:]
    }

    func search(_ text: String) async throws -> [TrackSearchResult] {
        let fields = "id title { userPreferred romaji } coverImage { large } description(asHtml: false) chapters status siteUrl"
        let data: [String: Any]
        if text.hasPrefix("id:"), let id = Int(text.dropFirst(3).trimmingCharacters(in: .whitespaces)) {
            data = try await query("query ($id: Int) { Page { media(id: $id, type: MANGA) { \(fields) } } }", variables: ["id": id], auth: false)
        } else {
            data = try await query("query ($q: String) { Page(perPage: 25) { media(search: $q, type: MANGA) { \(fields) } } }", variables: ["q": text], auth: false)
        }
        let media = ((data["Page"] as? [String: Any])?["media"] as? [[String: Any]]) ?? []
        return media.compactMap { item in
            guard let id = item["id"] as? Int else { return nil }
            let title = item["title"] as? [String: Any]
            return TrackSearchResult(
                remoteId: String(id),
                title: (title?["userPreferred"] as? String) ?? (title?["romaji"] as? String) ?? "",
                coverUrl: (item["coverImage"] as? [String: Any])?["large"] as? String,
                summary: (item["description"] as? String)?.replacingOccurrences(of: "<br>", with: "\n"),
                totalChapters: item["chapters"] as? Int ?? 0,
                remoteUrl: item["siteUrl"] as? String,
                publishing: item["status"] as? String
            )
        }
    }

    private static let statusNames: [TrackStatus: String] = [
        .reading: "CURRENT", .completed: "COMPLETED", .onHold: "PAUSED", .dropped: "DROPPED", .planToRead: "PLANNING", .rereading: "REPEATING",
    ]

    private static func fuzzyDate(_ date: Date?) -> [String: Any]? {
        guard let date else { return nil }
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return ["year": parts.year ?? 0, "month": parts.month ?? 0, "day": parts.day ?? 0]
    }

    func update(_ record: TrackRecord) async throws {
        guard let mediaId = Int(record.remoteId) else { return }
        var variables: [String: Any] = [
            "mediaId": mediaId,
            "status": Self.statusNames[TrackStatus(rawValue: record.status) ?? .reading] ?? "CURRENT",
            "progress": Int(record.lastChapterRead),
            "score": record.score,
            "private": record.isPrivate,
        ]
        variables["startedAt"] = Self.fuzzyDate(record.startDate) ?? NSNull()
        variables["completedAt"] = Self.fuzzyDate(record.finishDate) ?? NSNull()
        _ = try await query("""
        mutation ($mediaId: Int, $status: MediaListStatus, $progress: Int, $score: Float, $private: Boolean, $startedAt: FuzzyDateInput, $completedAt: FuzzyDateInput) {
          SaveMediaListEntry(mediaId: $mediaId, status: $status, progress: $progress, score: $score, private: $private, startedAt: $startedAt, completedAt: $completedAt) { id }
        }
        """, variables: variables, auth: true)
    }

    func refresh(_ record: TrackRecord) async throws -> TrackRemoteState {
        guard let mediaId = Int(record.remoteId) else { return TrackRemoteState() }
        let data = try await query("""
        query ($id: Int) { Media(id: $id) { chapters mediaListEntry { status progress score(format: POINT_10_DECIMAL) startedAt { year month day } completedAt { year month day } } } }
        """, variables: ["id": mediaId], auth: true)
        let media = data["Media"] as? [String: Any]
        var state = TrackRemoteState(totalChapters: media?["chapters"] as? Int)
        if let entry = media?["mediaListEntry"] as? [String: Any] {
            if let name = entry["status"] as? String { state.status = Self.statusNames.first { $0.value == name }?.key }
            state.lastChapterRead = (entry["progress"] as? Int).map(Double.init)
            state.score = entry["score"] as? Double
            func date(_ value: Any?) -> Date? {
                guard let parts = value as? [String: Any], let year = parts["year"] as? Int else { return nil }
                return Calendar.current.date(from: DateComponents(year: year, month: parts["month"] as? Int ?? 1, day: parts["day"] as? Int ?? 1))
            }
            state.startDate = date(entry["startedAt"])
            state.finishDate = date(entry["completedAt"])
        }
        return state
    }
}

// MARK: - MangaUpdates

/// MangaUpdates (API v1). Login com usuário e senha da conta, sem client ID.
@MainActor
final class MangaUpdatesTracker: Tracker {
    let id = "mangaupdates"
    let name = "MangaUpdates"
    let scores = stride(from: 0.0, through: 10.0, by: 0.5).map { $0 }
    let login: TrackerLogin? = .password
    private let api = "https://api.mangaupdates.com/v1"

    private var token: String? { Keychain.get("mangaupdates_token") }
    var isLoggedIn: Bool { token != nil }

    /// Listas do MangaUpdates: 0 lendo, 1 desejo, 2 completo, 3 abandonado, 4 pausado.
    private static let lists: [TrackStatus: Int] = [.reading: 0, .planToRead: 1, .completed: 2, .dropped: 3, .onHold: 4, .rereading: 0]

    private func request(_ method: String, _ path: String, body: Any? = nil, auth: Bool = true) async throws -> Any? {
        var request = URLRequest(url: URL(string: api + path)!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if auth {
            guard let token else { throw TrackerError.notLoggedIn }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 401 { logout() }
            let reason = (json as? [String: Any])?["reason"] as? String ?? "HTTP \(http.statusCode)"
            throw TrackerError.badResponse("MangaUpdates: \(reason)")
        }
        return json
    }

    func login(username: String, password: String) async throws {
        let json = try await request("PUT", "/account/login", body: ["username": username, "password": password], auth: false)
        guard let token = ((json as? [String: Any])?["context"] as? [String: Any])?["session_token"] as? String else {
            throw TrackerError.badResponse("Usuário ou senha incorretos.")
        }
        Keychain.set(token, for: "mangaupdates_token")
    }

    func logout() { Keychain.set(nil, for: "mangaupdates_token") }

    func search(_ text: String) async throws -> [TrackSearchResult] {
        if text.hasPrefix("id:") {
            let id = text.dropFirst(3).trimmingCharacters(in: .whitespaces)
            guard let item = try await request("GET", "/series/\(id)", auth: false) as? [String: Any] else { return [] }
            return [Self.result(item)].compactMap { $0 }
        }
        let json = try await request("POST", "/series/search", body: ["search": text, "perpage": 25], auth: false)
        let results = ((json as? [String: Any])?["results"] as? [[String: Any]]) ?? []
        return results.compactMap { Self.result($0["record"] as? [String: Any] ?? [:]) }
    }

    private static func result(_ item: [String: Any]) -> TrackSearchResult? {
        guard let id = item["series_id"] as? Int64 ?? (item["series_id"] as? Int).map(Int64.init) else { return nil }
        let image = ((item["image"] as? [String: Any])?["url"] as? [String: Any])?["original"] as? String
        return TrackSearchResult(
            remoteId: String(id),
            title: (item["title"] as? String)?.replacingOccurrences(of: "&amp;", with: "&") ?? "",
            coverUrl: image,
            summary: item["description"] as? String,
            totalChapters: 0,
            remoteUrl: item["url"] as? String,
            publishing: item["year"] as? String
        )
    }

    func update(_ record: TrackRecord) async throws {
        guard let seriesId = Int64(record.remoteId) else { return }
        let entry: [String: Any] = [
            "series": ["id": seriesId],
            "list_id": Self.lists[TrackStatus(rawValue: record.status) ?? .reading] ?? 0,
            "status": ["chapter": Int(record.lastChapterRead)],
        ]
        // Atualiza; se a obra ainda não está em nenhuma lista, adiciona.
        do {
            _ = try await request("POST", "/lists/series/update", body: [entry])
        } catch {
            _ = try await request("POST", "/lists/series", body: [entry])
        }
        if record.score > 0 {
            _ = try await request("PUT", "/series/\(seriesId)/rating", body: ["rating": record.score])
        }
    }

    func refresh(_ record: TrackRecord) async throws -> TrackRemoteState {
        let json = try await request("GET", "/lists/series/\(record.remoteId)") as? [String: Any]
        var state = TrackRemoteState()
        if let listId = json?["list_id"] as? Int { state.status = Self.lists.first { $0.value == listId && $0.key != .rereading }?.key }
        if let chapter = (json?["status"] as? [String: Any])?["chapter"] as? Int { state.lastChapterRead = Double(chapter) }
        if let rating = try? await request("GET", "/series/\(record.remoteId)/rating") as? [String: Any], let value = rating["rating"] as? Double {
            state.score = value
        }
        return state
    }
}
