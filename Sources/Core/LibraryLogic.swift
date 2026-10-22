import Foundation
import SwiftUI

/// Filtro de três estados do Mihon: ignorar, só os que têm, só os que não têm.
public enum TriState: Int, CaseIterable, Codable {
    case ignore = 0, include = 1, exclude = 2

    public var next: TriState { TriState(rawValue: (rawValue + 1) % 3) ?? .ignore }

    public func matches(_ value: Bool) -> Bool {
        switch self {
        case .ignore: return true
        case .include: return value
        case .exclude: return !value
        }
    }

    public var symbol: String {
        switch self {
        case .ignore: return "square"
        case .include: return "checkmark.square.fill"
        case .exclude: return "xmark.square.fill"
        }
    }
}

public enum LibrarySort: String, CaseIterable, Identifiable {
    case alphabetical, lastRead, lastUpdate, unread, totalChapters, latestChapter, dateAdded, random

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .alphabetical: return "Alfabética"
        case .lastRead: return "Última leitura"
        case .lastUpdate: return "Última atualização"
        case .unread: return "Não lidos"
        case .totalChapters: return "Total de capítulos"
        case .latestChapter: return "Último capítulo"
        case .dateAdded: return "Data de adição"
        case .random: return "Aleatória"
        }
    }
}

public enum LibraryDisplayMode: String, CaseIterable, Identifiable {
    case compactGrid, comfortableGrid, coverOnly, list

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .compactGrid: return "Grade compacta"
        case .comfortableGrid: return "Grade confortável"
        case .coverOnly: return "Só capas"
        case .list: return "Lista"
        }
    }
}

/// Ajustes da biblioteca (equivalente ao `LibraryPreferences` do Mihon).
@MainActor
@Observable
public final class LibrarySettings {
    public static let shared = LibrarySettings()

    private let defaults: UserDefaults

    public var displayMode: LibraryDisplayMode { didSet { defaults.set(displayMode.rawValue, forKey: "library_display") } }
    /// Colunas no retrato e na paisagem (0 = automático).
    public var portraitColumns: Int { didSet { defaults.set(portraitColumns, forKey: "library_columns_portrait") } }
    public var landscapeColumns: Int { didSet { defaults.set(landscapeColumns, forKey: "library_columns_landscape") } }
    public var filterUnread: TriState { didSet { save(filterUnread, "library_filter_unread") } }
    public var filterStarted: TriState { didSet { save(filterStarted, "library_filter_started") } }
    public var filterCompleted: TriState { didSet { save(filterCompleted, "library_filter_completed") } }
    public var filterBookmarked: TriState { didSet { save(filterBookmarked, "library_filter_bookmarked") } }
    public var filterDownloaded: TriState { didSet { save(filterDownloaded, "library_filter_downloaded") } }
    public var filterTracked: TriState { didSet { save(filterTracked, "library_filter_tracked") } }
    public var sort: LibrarySort { didSet { defaults.set(sort.rawValue, forKey: "library_sort") } }
    public var ascending: Bool { didSet { defaults.set(ascending, forKey: "library_sort_ascending") } }
    public var showUnreadBadge: Bool { didSet { defaults.set(showUnreadBadge, forKey: "library_badge_unread") } }
    public var showDownloadBadge: Bool { didSet { defaults.set(showDownloadBadge, forKey: "library_badge_download") } }
    public var showLanguageBadge: Bool { didSet { defaults.set(showLanguageBadge, forKey: "library_badge_language") } }
    public var showContinueButton: Bool { didSet { defaults.set(showContinueButton, forKey: "library_continue_button") } }
    public var showCategoryTabs: Bool { didSet { defaults.set(showCategoryTabs, forKey: "library_category_tabs") } }
    /// Categoria ao adicionar: "" = padrão, "ask" = perguntar, ou o id de uma categoria.
    public var defaultCategory: String { didSet { defaults.set(defaultCategory, forKey: "library_default_category") } }
    /// Última aba aberta.
    public var selectedCategory: String { didSet { defaults.set(selectedCategory, forKey: "library_selected_category") } }
    /// Muda a ordem aleatória a cada "embaralhar".
    public var randomSeed: Int { didSet { defaults.set(randomSeed, forKey: "library_random_seed") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func tri(_ key: String) -> TriState { TriState(rawValue: defaults.integer(forKey: key)) ?? .ignore }
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        displayMode = LibraryDisplayMode(rawValue: defaults.string(forKey: "library_display") ?? "") ?? .comfortableGrid
        portraitColumns = defaults.integer(forKey: "library_columns_portrait")
        landscapeColumns = defaults.integer(forKey: "library_columns_landscape")
        filterUnread = tri("library_filter_unread")
        filterStarted = tri("library_filter_started")
        filterCompleted = tri("library_filter_completed")
        filterBookmarked = tri("library_filter_bookmarked")
        filterDownloaded = tri("library_filter_downloaded")
        filterTracked = tri("library_filter_tracked")
        sort = LibrarySort(rawValue: defaults.string(forKey: "library_sort") ?? "") ?? .alphabetical
        ascending = bool("library_sort_ascending", true)
        showUnreadBadge = bool("library_badge_unread", true)
        showDownloadBadge = bool("library_badge_download", true)
        showLanguageBadge = bool("library_badge_language", true)
        showContinueButton = bool("library_continue_button", false)
        showCategoryTabs = bool("library_category_tabs", true)
        defaultCategory = defaults.string(forKey: "library_default_category") ?? ""
        selectedCategory = defaults.string(forKey: "library_selected_category") ?? ""
        randomSeed = defaults.integer(forKey: "library_random_seed")
    }

    public var hasActiveFilter: Bool {
        [filterUnread, filterStarted, filterCompleted, filterBookmarked, filterDownloaded, filterTracked].contains { $0 != .ignore }
    }

    private func save(_ value: TriState, _ key: String) {
        defaults.set(value.rawValue, forKey: key)
    }
}

/// O que se sabe de uma obra da biblioteca para filtrar e ordenar.
public struct LibraryEntry {
    public let id: String
    public let title: String
    public let altTitles: [String]
    public let author: String?
    public let artist: String?
    public let genres: [String]
    public let sourceNames: [String]
    public let sourceIds: [String]
    public let status: Int
    public let unreadCount: Int
    public let chapterCount: Int
    public let lastReadAt: Date?
    public let lastUpdated: Date?
    public let latestUploadAt: Date?
    public let favoriteAt: Date?
    public let isStarted: Bool
    public let hasBookmarks: Bool
    public let isDownloaded: Bool
    public let isTracked: Bool
}

/// Filtros, busca e ordem da biblioteca (sem UI, para testar).
public enum LibraryQuery {
    public struct Filters {
        public var unread: TriState = .ignore
        public var started: TriState = .ignore
        public var completed: TriState = .ignore
        public var bookmarked: TriState = .ignore
        public var downloaded: TriState = .ignore
        public var tracked: TriState = .ignore

        public init() {}
    }

    public static func apply(_ entries: [LibraryEntry], filters: Filters, search: String, sort: LibrarySort, ascending: Bool, seed: Int = 0) -> [LibraryEntry] {
        let filtered = entries.filter { entry in
            filters.unread.matches(entry.unreadCount > 0)
                && filters.started.matches(entry.isStarted)
                && filters.completed.matches(entry.status == 2)
                && filters.bookmarked.matches(entry.hasBookmarks)
                && filters.downloaded.matches(entry.isDownloaded)
                && filters.tracked.matches(entry.isTracked)
                && matches(entry, search: search)
        }
        return sorted(filtered, by: sort, ascending: ascending, seed: seed)
    }

    /// Busca da biblioteca: texto livre (título e títulos alternativos) e os prefixos
    /// `autor:`, `genero:`/`gênero:`, `src:`/`fonte:` e `id:`. Termos separados por vírgula
    /// precisam bater todos.
    public static func matches(_ entry: LibraryEntry, search: String) -> Bool {
        let terms = search.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return terms.allSatisfy { term in
            let lower = term.lowercased()
            func value(after prefixes: [String]) -> String? {
                for prefix in prefixes where lower.hasPrefix(prefix) {
                    return String(term.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                }
                return nil
            }
            if let author = value(after: ["autor:", "author:", "artista:"]) {
                return [entry.author, entry.artist].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(author) }
            }
            if let genre = value(after: ["genero:", "gênero:", "genre:", "tag:"]) {
                return entry.genres.contains { $0.localizedCaseInsensitiveContains(genre) }
            }
            if let source = value(after: ["src:", "fonte:", "source:"]) {
                return entry.sourceNames.contains { $0.localizedCaseInsensitiveContains(source) }
                    || entry.sourceIds.contains { $0.localizedCaseInsensitiveContains(source) }
            }
            if let id = value(after: ["id:"]) {
                return entry.id.localizedCaseInsensitiveContains(id)
            }
            return ([entry.title] + entry.altTitles).contains { $0.localizedCaseInsensitiveContains(term) }
        }
    }

    public static func sorted(_ entries: [LibraryEntry], by sort: LibrarySort, ascending: Bool, seed: Int = 0) -> [LibraryEntry] {
        let alphabetical: (LibraryEntry, LibraryEntry) -> Bool = {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        func date(_ a: Date?, _ b: Date?, _ lhs: LibraryEntry, _ rhs: LibraryEntry) -> Bool {
            let x = a ?? .distantPast, y = b ?? .distantPast
            return x == y ? alphabetical(lhs, rhs) : x < y
        }
        func number(_ a: Int, _ b: Int, _ lhs: LibraryEntry, _ rhs: LibraryEntry) -> Bool {
            a == b ? alphabetical(lhs, rhs) : a < b
        }
        let result: [LibraryEntry]
        switch sort {
        case .alphabetical: result = entries.sorted(by: alphabetical)
        case .lastRead: result = entries.sorted { date($0.lastReadAt, $1.lastReadAt, $0, $1) }
        case .lastUpdate: result = entries.sorted { date($0.lastUpdated, $1.lastUpdated, $0, $1) }
        case .latestChapter: result = entries.sorted { date($0.latestUploadAt, $1.latestUploadAt, $0, $1) }
        case .dateAdded: result = entries.sorted { date($0.favoriteAt, $1.favoriteAt, $0, $1) }
        case .unread: result = entries.sorted { number($0.unreadCount, $1.unreadCount, $0, $1) }
        case .totalChapters: result = entries.sorted { number($0.chapterCount, $1.chapterCount, $0, $1) }
        case .random:
            // Estável para a mesma semente: a ordem só muda ao embaralhar de novo.
            return entries.sorted { hash($0.id, seed) < hash($1.id, seed) }
        }
        return ascending ? result : result.reversed()
    }

    private static func hash(_ id: String, _ seed: Int) -> UInt64 {
        var value: UInt64 = 1469598103934665603 &+ UInt64(bitPattern: Int64(seed))
        for byte in id.utf8 {
            value ^= UInt64(byte)
            value = value &* 1099511628211
        }
        return value
    }
}

/// Filtros, ordem e exibição da lista de capítulos, guardados num Int (`Manga.chapterFlags`).
public struct ChapterListFlags: Equatable {
    public enum Sort: Int, CaseIterable, Identifiable {
        case number = 0, uploadDate = 1, source = 2

        public var id: Int { rawValue }

        public var title: String {
            switch self {
            case .number: return "Número"
            case .uploadDate: return "Data de envio"
            case .source: return "Ordem da fonte"
            }
        }
    }

    public var unread: TriState = .ignore
    public var bookmarked: TriState = .ignore
    public var downloaded: TriState = .ignore
    public var sort: Sort = .number
    public var descending = true
    /// Mostra "Capítulo N" em vez do nome dado pela fonte.
    public var showNumber = false
    public var hideMissing = false

    public init() {}

    public init(rawValue: Int) {
        unread = TriState(rawValue: rawValue & 0b11) ?? .ignore
        bookmarked = TriState(rawValue: (rawValue >> 2) & 0b11) ?? .ignore
        downloaded = TriState(rawValue: (rawValue >> 4) & 0b11) ?? .ignore
        sort = Sort(rawValue: (rawValue >> 6) & 0b11) ?? .number
        // Bit invertido para que 0 (valor padrão do banco) seja "decrescente".
        descending = (rawValue >> 8) & 1 == 0
        showNumber = (rawValue >> 9) & 1 == 1
        hideMissing = (rawValue >> 10) & 1 == 1
    }

    public var rawValue: Int {
        var value = unread.rawValue
        value |= bookmarked.rawValue << 2
        value |= downloaded.rawValue << 4
        value |= sort.rawValue << 6
        if !descending { value |= 1 << 8 }
        if showNumber { value |= 1 << 9 }
        if hideMissing { value |= 1 << 10 }
        return value
    }

    public var hasActiveFilter: Bool {
        unread != .ignore || bookmarked != .ignore || downloaded != .ignore
    }

    /// Padrão global (o "definir como padrão" do Mihon).
    public static var globalDefault: ChapterListFlags {
        get { ChapterListFlags(rawValue: UserDefaults.standard.integer(forKey: "chapter_flags_default")) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "chapter_flags_default") }
    }

    /// Aplica filtros e ordem. `isRead`, `isBookmarked` e `isDownloaded` dizem o estado de cada capítulo.
    public func apply(
        _ chapters: [SourceChapterItem],
        isRead: (SourceChapterItem) -> Bool,
        isBookmarked: (SourceChapterItem) -> Bool,
        isDownloaded: (SourceChapterItem) -> Bool
    ) -> [SourceChapterItem] {
        let filtered = chapters.filter {
            unread.matches(!isRead($0)) && bookmarked.matches(isBookmarked($0)) && downloaded.matches(isDownloaded($0))
        }
        let ascending: [SourceChapterItem]
        switch sort {
        case .number:
            // A lista já vem do maior para o menor número.
            ascending = filtered.reversed()
        case .uploadDate:
            ascending = filtered.enumerated().sorted { a, b in
                let x = a.element.uploadDate ?? .distantPast, y = b.element.uploadDate ?? .distantPast
                return x == y ? a.offset > b.offset : x < y
            }.map(\.element)
        case .source:
            ascending = filtered.sorted { a, b in
                a.sourceId == b.sourceId ? a.orderIndex > b.orderIndex : a.sourceId < b.sourceId
            }
        }
        return descending ? ascending.reversed() : ascending
    }

    public func displayName(_ chapter: SourceChapterItem) -> String {
        guard showNumber, chapter.chapterNumber >= 0 else { return chapter.name }
        let number = chapter.chapterNumber
        let text = number.rounded() == number ? String(Int(number)) : String(format: "%g", number)
        return "Capítulo \(text)"
    }
}

/// Ações de deslizar na linha do capítulo (configuráveis, como no Mihon).
public enum ChapterSwipeAction: String, CaseIterable, Identifiable {
    case toggleRead, toggleBookmark, download, markPreviousRead, disabled

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .toggleRead: return "Marcar lido/não lido"
        case .toggleBookmark: return "Marcador"
        case .download: return "Baixar/apagar download"
        case .markPreviousRead: return "Marcar anteriores como lidos"
        case .disabled: return "Nada"
        }
    }

    static var leading: ChapterSwipeAction {
        ChapterSwipeAction(rawValue: UserDefaults.standard.string(forKey: "chapter_swipe_start") ?? "") ?? .toggleBookmark
    }

    static var trailing: ChapterSwipeAction {
        ChapterSwipeAction(rawValue: UserDefaults.standard.string(forKey: "chapter_swipe_end") ?? "") ?? .toggleRead
    }
}

/// Scanlators e fontes escondidos numa obra (`Manga.excludedScanlators`).
/// Fontes entram com o prefixo `src:`.
public enum ScanlatorFilter {
    public static func sourceKey(_ sourceId: String) -> String { "src:\(sourceId)" }

    public static func isExcluded(_ chapter: SourceChapterItem, excluded: Set<String>) -> Bool {
        guard !excluded.isEmpty else { return false }
        if excluded.contains(sourceKey(chapter.sourceId)) { return true }
        return scanlators(of: chapter).contains { excluded.contains($0) }
    }

    /// Um capítulo pode vir de várias scans ("Scan A & Scan B").
    public static func scanlators(of chapter: SourceChapterItem) -> [String] {
        guard let raw = chapter.scanlator?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return [] }
        return raw.components(separatedBy: CharacterSet(charactersIn: "&,")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Previsão de lançamento (o "smart update" do Mihon): intervalo mediano entre capítulos.
public enum UpdateSchedule {
    /// Data prevista do próximo capítulo, ou nil se não há dados suficientes.
    public static func nextUpdate(uploadDates: [Date], now: Date = Date()) -> Date? {
        guard let interval = medianInterval(uploadDates), let last = uploadDates.max() else { return nil }
        var next = last.addingTimeInterval(interval)
        // Atrasou: a previsão anda de intervalo em intervalo até passar de agora.
        while next < now { next = next.addingTimeInterval(interval) }
        return next
    }

    /// Intervalo mediano entre os últimos lançamentos (entre 1 e 28 dias).
    public static func medianInterval(_ dates: [Date]) -> TimeInterval? {
        let days = Set(dates.map { Calendar.current.startOfDay(for: $0) }).sorted().suffix(10)
        guard days.count >= 3 else { return nil }
        let gaps = zip(days.dropFirst(), days).map { $0.timeIntervalSince($1) }.sorted()
        let median = gaps[gaps.count / 2]
        return min(max(median, 86_400), 28 * 86_400)
    }
}
